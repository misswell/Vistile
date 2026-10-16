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

/// 决策需要的最小事实。带宽/尺寸等细节仍由 StreamConfig 负责，这里只决定"要不要流、什么档"。
public struct CaptureDemand: Hashable, Sendable {
    public let identity: WindowIdentity
    public let isCapturable: Bool
    public let isMinimized: Bool
    public let isPriority: Bool
    /// 已应用的直播流配置；该窗口当前没有流时填档位默认值。
    public let currentFPS: Int
    public let currentPixelWidth: Int

    public init(identity: WindowIdentity,
                isCapturable: Bool,
                isMinimized: Bool,
                isPriority: Bool,
                currentFPS: Int,
                currentPixelWidth: Int) {
        self.identity = identity
        self.isCapturable = isCapturable
        self.isMinimized = isMinimized
        self.isPriority = isPriority
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
    public static func plan(demands: [CaptureDemand],
                            liveStreams: Set<WindowIdentity>,
                            polledIntervals: [WindowIdentity: Int],
                            streamSoftLimit: Int,
                            thermal: ThermalState) -> CaptureModePlan {
        let ordered = demands.sorted(by: ordering)
        // 只有"可捕获且没最小化"的目标才占名额。
        let candidates = ordered.filter { $0.isCapturable && !$0.isMinimized }
        let prospective = candidates.count
        let limit = max(1, streamSoftLimit)
        let overBudget = prospective > limit || thermal == .serious || thermal == .critical
        let slots = min(prospective, limit)
        // 已经轮询着的目标要回到实时，必须整体回落到滞后线以下。
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
            // 名额内：档位阶梯按"想要直播的目标数 vs 软上限 + 热状态"决定，不再额外把窗口踢出名额。
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

        let starts = candidates.filter { demand in
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

    /// 稳定优先级：优先窗口排前面（先拿名额、最后降级），其余按窗口编号，避免每轮顺序抖动。
    private static func ordering(_ a: CaptureDemand, _ b: CaptureDemand) -> Bool {
        if a.isPriority != b.isPriority { return a.isPriority && !b.isPriority }
        if a.identity.windowID != b.identity.windowID { return a.identity.windowID < b.identity.windowID }
        return a.identity.journalKey < b.identity.journalKey
    }
}
