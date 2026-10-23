import Foundation
import CoreGraphics

/// 每次过渡携带令牌，晚到的异步回调必须因令牌不匹配被忽略（方案 §7）。
public struct TransitionToken: Hashable, Sendable, Identifiable {
    public let id: UUID
    public let generation: UInt64

    public init(id: UUID = UUID(), generation: UInt64) {
        self.id = id
        self.generation = generation
    }
}

/// 用于区分"内部点击背景"与"外部应用抢走焦点"，否则会刚点背景就被误判为失焦退出。
public struct InteractionToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

public enum KeyboardFocus: String, Hashable, Sendable {
    case none
    case overview
    /// 工作台顶栏搜索持有键盘：Esc 先关搜索并还原主应用焦点（方案 §4.5）。
    case railSearch
    case targetApplication
}

/// 恢复批次结束后要落到哪里。"正在恢复"和"因权限中断"必须分开表达（方案 §5.1）。
public enum RecoveryDestination: Hashable, Sendable {
    /// 正常退出、Space 切换、锁屏、显示器变化：批次结束后回隐藏态，用户可再次打开。
    case hidden
    /// 权限被收回打断了会话：结束后同样回隐藏态，但落地时说明真实原因，且保留未恢复事务。
    case hiddenAfterPermissionLost(PermissionKind)
}

public enum SessionPhase: Hashable, Sendable {
    case hidden
    case preparing
    case overview
    case expanding(target: WindowIdentity, token: TransitionToken)
    case focused(target: WindowIdentity)
    case collapsing(target: WindowIdentity, token: TransitionToken)
    case switching(from: WindowIdentity, to: WindowIdentity, token: TransitionToken)
    /// 只有一个"正在恢复"状态，且带明确目的地；不再有 suspended 这种多义状态。
    case recovering(destination: RecoveryDestination, token: TransitionToken)
    /// 补偿不完整后的显式状态（方案 §6.4、§15）：面板仍在，但主窗口几何与焦点不再可信，
    /// 不得冒充正常的 `.focused`；只接受重试或安全退出。
    case recoveryRequired(target: WindowIdentity, reason: String)

    /// recovering 属于拆台阶段：面板已隐藏、捕获已停，只剩几何恢复。
    public var isVisible: Bool {
        switch self {
        case .hidden, .recovering: return false
        default: return true
        }
    }

    /// 同一会话至多一个受控前景窗口。
    public var controlledTarget: WindowIdentity? {
        switch self {
        case let .expanding(target, _), let .focused(target), let .collapsing(target, _): return target
        case let .switching(_, to, _): return to
        case let .recoveryRequired(target, _): return target
        default: return nil
        }
    }

    public var token: TransitionToken? {
        switch self {
        case let .expanding(_, token), let .collapsing(_, token), let .switching(_, _, token),
             let .recovering(_, token): return token
        default: return nil
        }
    }

    public var isTransitioning: Bool {
        switch self {
        case .expanding, .collapsing, .switching, .recovering: return true
        default: return false
        }
    }

    /// 恢复/退出的异步结果只在这个目的地才允许落地。
    public var recoveryDestination: RecoveryDestination? {
        if case let .recovering(destination, _) = self { return destination }
        return nil
    }
}

/// 设置项中与状态机行为相关的部分，集中在此避免布尔散落在 View 与回调里。
public struct SessionPolicy: Hashable, Sendable {
    /// 点击背景卡片直接切换，默认关闭（方案 §2.7）。
    public var backgroundClickSwitches: Bool
    /// 保留聚焦期间用户手动调整的尺寸（方案 §10.4）。
    public var preserveUserGeometry: Bool
    public var foregroundWidthRatio: Double
    public var foregroundHeightRatio: Double
    public var foregroundEdgeInset: CGFloat
    /// 主区停靠模式：尊重原尺寸（默认）或充满主区；设置里可切换。
    public var mainAreaDocking: MainAreaDocking
    public var density: LayoutDensity
    public var tier: CaptureTier
    public var reduceMotion: Bool
    public var reconcileInterval: TimeInterval

    public init(backgroundClickSwitches: Bool = false,
                preserveUserGeometry: Bool = false,
                foregroundWidthRatio: Double = 0.86,
                foregroundHeightRatio: Double = 0.88,
                foregroundEdgeInset: CGFloat = 32,
                mainAreaDocking: MainAreaDocking = .respectful,
                density: LayoutDensity = .standard,
                tier: CaptureTier = .balanced,
                reduceMotion: Bool = false,
                reconcileInterval: TimeInterval = 2) {
        self.backgroundClickSwitches = backgroundClickSwitches
        self.preserveUserGeometry = preserveUserGeometry
        self.foregroundWidthRatio = Self.clamped(foregroundWidthRatio)
        self.foregroundHeightRatio = Self.clamped(foregroundHeightRatio)
        self.foregroundEdgeInset = foregroundEdgeInset
        self.mainAreaDocking = mainAreaDocking
        self.density = density
        self.tier = tier
        self.reduceMotion = reduceMotion
        self.reconcileInterval = reconcileInterval
    }

    /// 前景尺寸比例允许 75%–94%。
    public static func clamped(_ ratio: Double) -> Double { min(0.94, max(0.75, ratio)) }

    /// 动画时长：减少动态效果时改用短淡化。
    public func animationMS(isExpand: Bool, style: OverviewStyle) -> Int {
        if reduceMotion { return isExpand ? 120 : 100 }
        return isExpand ? style.clampedExpandMS : style.clampedCollapseMS
    }
}

public struct SessionState: Sendable {
    public var phase: SessionPhase = .hidden
    /// 展示模式（方案 §7）：与 phase 正交，phase 描述过渡中，mode 描述落地形态。
    /// 每次从 hidden 打开都必须从 .overview 开始，不保留上次的模式（方案 §4.1、§4.5）。
    public var mode: PresentationMode = .overview
    /// 工作台（主窗口＋L 型）的独立会话状态（方案 §6、§7）。
    public var workbench = WorkbenchState()
    public var records: [WindowIdentity: WindowRecord] = [:]
    public var slots = SlotRegistry(capacity: 0)
    public var catalogGeneration: UInt64 = 0
    public var requestCounter: UInt64 = 0
    public var transitionGeneration: UInt64 = 0
    /// 会话代次：与 sessionID 一起构成操作上下文的准入判据（方案 §5.3）。
    public var sessionEpoch: UInt64 = 0
    /// 目录合并按此给新窗口编号：首次发现顺序是稳定排序的并列裁决依据（方案 §11）。
    public var recordSequence: Int = 0
    public var keyboardFocus: KeyboardFocus = .none
    /// latest-wins：过渡期间只保留最后一个目标请求。
    public var pendingTarget: WindowIdentity?
    /// 本次会话由 Vistile 写过的几何事务，用于退出时恢复。
    public var transactions: [WindowIdentity: WindowTransaction] = [:]
    /// 恢复/销毁/退出任务不可被 pendingTarget 覆盖。
    public var isExitPending: Bool = false
    /// 一次查询仍在进行时不再叠加；成功与失败都要解锁（方案 §5.2、§6.7）。
    public var pendingDiscovery: DiscoveryRequest?
    /// 连续发现失败次数：达到上限后停止自动重试，但保留卡片与最后一帧。
    public var consecutiveDiscoveryFailures: Int = 0
    /// 宿主最近一次报告的打开条件，仅用于说明状态，不额外决定行为。
    public var openConditions: OpenConditions?
    public var searchQuery: String = ""
    public var policy = SessionPolicy()
    public var style: OverviewStyle = .standard
    public var sessionID = UUID()
    /// 内部背景点击产生的失焦不应触发退出。
    public var trustedInteraction: InteractionToken?
    /// 显示器 -> 该屏可用区，由宿主写入后供 reducer 决策使用。
    public var displays: [DisplayInfo] = []
    /// 首次发现序号：稳定排序的并列裁决依据（方案 §11）。
    /// 与目录返回顺序无关：标题更新、目录重排都不能改变它，已占位的窗口因此不会移动。
    public var discoverySequence: [WindowIdentity: Int] = [:]
    /// 每屏一份冻结网格（方案 §8.1）：行列与格子矩形只在明确允许重排的事件后重建。
    public var grids: [UInt32: DisplayGridSnapshot] = [:]
    public var layoutRevision: Int = 0
    /// 显示器配置变化后标脏：等下一次目录回来再重建，不用旧的窗口事实排格。
    public var gridsAreStale = false

    public init() {}

    public var recordsInSlotOrder: [WindowRecord] {
        slots.slots.compactMap { content in
            content.identity.flatMap { records[$0] }
        }
    }

    /// 所有屏格子之和：registry 容量只能由布局重建写入（方案 §8.2）。
    public var gridCapacity: Int { grids.values.reduce(0) { $0 + $1.capacity } }

    public func gridCell(for identity: WindowIdentity) -> (displayID: UInt32, cell: GridCell)? {
        for (displayID, grid) in grids {
            if let cell = grid.cell(for: identity) { return (displayID, cell) }
        }
        return nil
    }

    public func cellRect(for identity: WindowIdentity) -> CGRect? {
        grids[displayID(of: identity) ?? 0]?.rect(of: identity)
    }

    /// record.slot、registry、grid 三处占用关系必须一次写完。
    public mutating func syncRecordSlots() {
        for (identity, var record) in records {
            record.slot = slots.slot(for: identity)
            records[identity] = record
        }
    }

    /// 会话结束：冻结网格不再有意义，但跨会话的顺序偏好要保留（方案 §8.2）。
    /// 工作台同样清空：下次打开必须回到总览（方案 §4.5），不得从上次的主窗口恢复。
    public mutating func resetForHiddenSession() {
        grids = [:]
        gridsAreStale = false
        slots = SlotRegistry(capacity: slots.capacity, orderPreference: slots.orderPreference)
        mode = .overview
        workbench.resetForHiddenSession()
    }

    public func record(for identity: WindowIdentity) -> WindowRecord? {
        records[identity]
    }

    public mutating func nextTransitionToken() -> TransitionToken {
        transitionGeneration += 1
        return TransitionToken(generation: transitionGeneration)
    }

    /// 为一次几何操作生成上下文：会话、代次、操作与过渡令牌一次绑定（方案 §5.3）。
    /// 所有普通操作与补偿都必须带它，迟到回执按它整体判定，不能只比一个持续增加的 generation。
    public mutating func nextOperationContext(kind: GeometryOperationKind,
                                              token: TransitionToken) -> GeometryOperationContext {
        GeometryOperationContext(sessionID: sessionID,
                                 sessionEpoch: sessionEpoch,
                                 operationID: UUID(),
                                 transitionToken: token,
                                 kind: kind)
    }

    /// 会话结束前必须撤销的在途操作：preparing 意图与已放出的写入都要排空（方案 §5.2）。
    public var pendingDrainEffects: [SessionEffect] {
        workbench.pendingDrainContexts.map { SessionEffect.drainGeometry($0) }
    }

    /// 显式"未能恢复一致"的唯一判定入口。
    public var isRecoveryRequired: Bool { workbench.recoveryRequired != nil }

    /// 发现请求同时带会话身份与请求代次；只看 catalogGeneration 不足以判定异步有效性。
    mutating func nextDiscoveryRequest(reason: DiscoveryReason) -> DiscoveryRequest {
        catalogGeneration += 1
        requestCounter += 1
        let request = DiscoveryRequest(sessionID: sessionID,
                                       requestID: requestCounter,
                                       generation: catalogGeneration,
                                       reason: reason)
        pendingDiscovery = request
        return request
    }

    /// 只有与"当前仍在进行的那一次请求"完全对得上的回调才被接受。
    public func isCurrentDiscovery(_ request: DiscoveryRequest) -> Bool {
        guard let pending = pendingDiscovery else { return false }
        return pending == request && request.sessionID == sessionID
    }

    public var isDiscoveryInFlight: Bool { pendingDiscovery != nil }

    /// 有界重试：连续失败到达上限后不再自动重查，重新打开会话时清零。
    public var isDiscoveryBudgetExhausted: Bool {
        consecutiveDiscoveryFailures >= SessionState.discoveryRetryLimit
    }

    public var recoveryDestination: RecoveryDestination? { phase.recoveryDestination }

    public static let discoveryRetryLimit = 3

    public var hasPendingGeometryRestore: Bool {
        transactions.values.contains { $0.state.requiresRestore }
    }

    public func displayID(of identity: WindowIdentity) -> UInt32? {
        records[identity]?.displayID
    }
}
