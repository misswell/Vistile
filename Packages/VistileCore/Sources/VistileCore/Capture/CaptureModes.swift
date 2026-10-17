import Foundation

/// 每个 identity 明确存在的期望模式（方案 §7.5）。
/// 缺了这个概念，"轮询中的卡片"在下一次同步时会被当成"没有流的卡片"而又去启动直播流。
public enum DesiredCaptureMode: Hashable, Sendable {
    case live
    case poll(intervalMilliseconds: Int)
    /// 最小化或不可捕获：不占流、不轮询，但保留最后一帧。
    case paused

    public var displayPhase: CapturePhase {
        switch self {
        case .live: return .live
        case let .poll(intervalMilliseconds): return .lowFrequency(intervalMilliseconds: intervalMilliseconds)
        case .paused: return .idle
        }
    }
}

/// 一张卡为什么需要画面（方案 §13.1 的捕获需求分级）。
///
/// 排序就是优先级：`transition` 最高、`paused` 最低，因此 `Comparable` 直接按等级比较，
/// 越靠前越该先拿到直播名额。
public enum CaptureVisibility: Int, Hashable, Sendable, CaseIterable, Comparable {
    /// 飞行交接的参与者：短期最高优先级，结束即释放额外优先级（方案 §13.1 表第一行）。
    case transition = 0
    /// 此刻在视口里的卡片：balanced 实时档，服从总直播路数与热状态预算。
    case visible = 1
    /// 相邻一屏以内的预取：低频预热，滚进来时已经有缓存帧。
    case prefetch = 2
    /// 远离视口：保留最后一帧，按资源压力 1–2 秒轮询或进一步暂停。
    case offscreen = 3
    /// 隐藏、锁屏、会话结束：不占流也不轮询。
    case paused = 4

    /// 默认档：未显式分级时按可见卡片处理，行为与旧版一致。
    public static let fallback: CaptureVisibility = .visible

    /// 只有这两档参与直播名额竞争（方案 §13.1）：
    /// 预取与离屏要的是"有缓存帧可显示"，不是持续码流。
    /// 将离屏排除在预算外，才能避免"目标总数一直很多"把可见卡片永远锁死在 poll。
    public var consumesLiveBudget: Bool {
        switch self {
        case .transition, .visible: return true
        case .prefetch, .offscreen, .paused: return false
        }
    }

    /// 等级数字：0 最高，用于比较与诊断。
    public var rank: Int { rawValue }

    public static func < (lhs: CaptureVisibility, rhs: CaptureVisibility) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// 决策需要的最小事实。带宽/尺寸等细节仍由 StreamConfig 负责，这里只决定"要不要流、什么档"。
public struct CaptureDemand: Hashable, Sendable {
    public let identity: WindowIdentity
    public let isCapturable: Bool
    public let isMinimized: Bool
    public let isPriority: Bool
    /// 这一档从哪来：过渡参与者 > 可见 > 邻近预取 > 离屏 > 隐藏（方案 §13.1）。
    public let visibility: CaptureVisibility
    /// 已应用的直播流配置；该窗口当前没有流时填档位默认值。
    public let currentFPS: Int
    public let currentPixelWidth: Int

    public init(identity: WindowIdentity,
                isCapturable: Bool,
                isMinimized: Bool,
                isPriority: Bool,
                visibility: CaptureVisibility = .fallback,
                currentFPS: Int,
                currentPixelWidth: Int) {
        self.identity = identity
        self.isCapturable = isCapturable
        self.isMinimized = isMinimized
        self.isPriority = isPriority
        self.visibility = visibility
        self.currentFPS = currentFPS
        self.currentPixelWidth = currentPixelWidth
    }
}

/// 先决定、后执行（方案 §7.5）：这份计划完整描述目标状态，
/// 协调层只负责把它兑现，不再自己判断该不该启动。
public struct CaptureModePlan: Hashable, Sendable {
    public var modes: [WindowIdentity: DesiredCaptureMode]
    /// 需要的流配置（降级档位）；.live 且带 lowerFPS/lowerOutputWidth 时是同一码。
    public var actions: [WindowIdentity: BudgetAction]
    public var streamsToStart: [WindowIdentity]
    public var streamsToStop: [WindowIdentity]
    public var overBudget: Bool

    public func mode(for identity: WindowIdentity) -> DesiredCaptureMode {
        modes[identity] ?? .paused
    }
}

public enum CaptureModePlanner {
    /// 升降级滞后：回到实时需要比软上限再低一截，避免在阈值边界每两秒全停全启。
    public static func restoreLimit(forSoftLimit limit: Int) -> Int {
        max(1, limit - max(1, limit / 4))
    }

    /// 计划是"想要直播的目标数"的纯函数，不能拿当前已启动的流数当预算判据：
    /// 那样降级把流停光后，下一轮看到的是 0 条流，于是又全部重启，形成乒乓。
    ///
    /// 可见性优先（方案 §13.1）：直播名额、`prospective`、`mayRestore` 都只看
    /// **占预算的那部分目标**（过渡参与者 + 可见卡片）。离屏与预取只保留最后一帧、
    /// 按低频轮询，绝不参与名额计数——否则"目标总数一直很多"会让可见卡片永远回不到实时。
    public static func plan(demands: [CaptureDemand],
                            liveStreams: Set<WindowIdentity>,
                            polledIntervals: [WindowIdentity: Int],
                            streamSoftLimit: Int,
                            thermal: ThermalState) -> CaptureModePlan {
        let ordered = demands.sorted(by: ordering)
        // 不可捕获 / 最小化的限制仍然最高优先执行（方案 §13.1）。
        let capturable = ordered.filter { $0.isCapturable && !$0.isMinimized }
        // 只有这一部分参与直播预算；其余按可见性各自的政策处理。
        let budgeted = capturable.filter { $0.visibility.consumesLiveBudget }
        let prospective = budgeted.count
        let limit = max(1, streamSoftLimit)
        let pressure = thermal == .serious || thermal == .critical
        let overBudget = prospective > limit || pressure
        let slots = min(prospective, limit)
        // 已经轮询着的**可见/过渡**目标要回到实时，必须整体回落到滞后线以下；
        // 判据里不再掺入离屏与预取的数量。
        let mayRestore = prospective <= restoreLimit(forSoftLimit: limit)

        var modes: [WindowIdentity: DesiredCaptureMode] = [:]
        var actions: [WindowIdentity: BudgetAction] = [:]
        var rank = 0
        for demand in ordered {
            guard demand.isCapturable, !demand.isMinimized else {
                modes[demand.identity] = .paused
                actions[demand.identity] = .keep
                continue
            }
            // 不参与直播预算的档位：先按自己的政策落定，绝不占用 `rank`（方案 §13.1 表）。
            if !demand.visibility.consumesLiveBudget {
                let mode = lowPriorityMode(for: demand, interval: polledIntervals[demand.identity],
                                           underPressure: pressure)
                modes[demand.identity] = mode
                actions[demand.identity] = switch mode {
                case let .poll(intervalMilliseconds): .poll(intervalMilliseconds: intervalMilliseconds)
                case .paused: .keep
                case .live: .keep
                }
                continue
            }
            let position = rank
            rank += 1
            let interval = polledIntervals[demand.identity]
            if position >= slots {
                // 超出名额：按稳定顺序降级，已有间隔就保持，不逐轮加深。
                let downgraded = interval ?? CaptureBudget.pollLadder[0]
                modes[demand.identity] = .poll(intervalMilliseconds: downgraded)
                actions[demand.identity] = .poll(intervalMilliseconds: downgraded)
                continue
            }
            if let interval, !mayRestore {
                modes[demand.identity] = .poll(intervalMilliseconds: interval)
                actions[demand.identity] = .poll(intervalMilliseconds: interval)
                continue
            }
            // 名额内：档位阶梯按"占预算的目标数 vs 软上限 + 热状态"决定，不再额外把窗口踢出名额。
            let action = CaptureBudget.nextAction(currentFPS: demand.currentFPS,
                                                  currentWidth: demand.currentPixelWidth,
                                                  streams: prospective,
                                                  streamSoftLimit: limit,
                                                  thermal: thermal,
                                                  isPriority: demand.isPriority)
            switch action {
            case let .poll(intervalMilliseconds):
                modes[demand.identity] = .poll(intervalMilliseconds: intervalMilliseconds)
            default:
                modes[demand.identity] = .live
            }
            actions[demand.identity] = action
        }

        let starts = budgeted.filter { demand in
            modes[demand.identity] == .live && !liveStreams.contains(demand.identity)
        }.map(\.identity)
        let stops = liveStreams.filter { identity in
            modes[identity] != .live
        }.sorted { $0.windowID < $1.windowID }

        return CaptureModePlan(modes: modes,
                               actions: actions,
                               streamsToStart: starts,
                               streamsToStop: stops,
                               overBudget: overBudget)
    }

    /// 不占直播预算的三档各自的政策（方案 §13.1 表）：
    /// - 邻近预取：低频预热，范围只在相邻一屏；已有间隔就保持，不逐轮加深。
    /// - 远离视口：保留最后一帧，约 1–2 秒轮询；资源吃紧时进一步暂停。
    /// - 隐藏/锁屏：停流停轮询，最后一帧按现有清理约定保留。
    private static func lowPriorityMode(for demand: CaptureDemand,
                                        interval: Int?,
                                        underPressure: Bool) -> DesiredCaptureMode {
        switch demand.visibility {
        case .paused:
            return .paused
        case .offscreen:
            guard !underPressure else { return .paused }
            // 离屏轮询从阶梯的 1–2 秒段起步，已有更浅的间隔也不去抢直播名额。
            let existing = interval ?? CaptureBudget.pollLadder[1]
            return .poll(intervalMilliseconds: max(existing, CaptureBudget.pollLadder[1]))
        case .prefetch:
            let existing = interval ?? CaptureBudget.pollLadder[0]
            return .poll(intervalMilliseconds: underPressure
                ? max(existing, CaptureBudget.pollLadder[1])
                : existing)
        case .transition, .visible:
            // 到这里不可能出现：占预算的目标走主循环。保守回落为可见档处理。
            return .poll(intervalMilliseconds: interval ?? CaptureBudget.pollLadder[0])
        }
    }

    /// 稳定优先级：可见性等级先决定谁先拿名额（方案 §13.1），
    /// 用户固定优先级只在其等级**内部**生效，其余按窗口编号避免每轮顺序抖动。
    private static func ordering(_ a: CaptureDemand, _ b: CaptureDemand) -> Bool {
        if a.visibility.rank != b.visibility.rank { return a.visibility.rank < b.visibility.rank }
        if a.isPriority != b.isPriority { return a.isPriority && !b.isPriority }
        if a.identity.windowID != b.identity.windowID { return a.identity.windowID < b.identity.windowID }
        return a.identity.journalKey < b.identity.journalKey
    }
}
