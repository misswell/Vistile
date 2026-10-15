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
    case targetApplication
}

public enum SuspendReason: Hashable, Sendable {
    case permissionLost
    case displayDisconnected
    case screenLocked
    case userSwitched
    case spaceChanged
    case systemStopped
}

public enum SessionPhase: Hashable, Sendable {
    case hidden
    case preparing
    case overview
    case expanding(target: WindowIdentity, token: TransitionToken)
    case focused(target: WindowIdentity)
    case collapsing(target: WindowIdentity, token: TransitionToken)
    case switching(from: WindowIdentity, to: WindowIdentity, token: TransitionToken)
    case suspended(reason: SuspendReason)
    case recovering(token: TransitionToken)

    public var isVisible: Bool {
        switch self {
        case .hidden, .suspended: return false
        default: return true
        }
    }

    /// 同一会话至多一个受控前景窗口。
    public var controlledTarget: WindowIdentity? {
        switch self {
        case let .expanding(target, _), let .focused(target), let .collapsing(target, _): return target
        case let .switching(_, to, _): return to
        default: return nil
        }
    }

    public var token: TransitionToken? {
        switch self {
        case let .expanding(_, token), let .collapsing(_, token), let .switching(_, _, token), let .recovering(token): return token
        default: return nil
        }
    }

    public var isTransitioning: Bool {
        switch self {
        case .expanding, .collapsing, .switching, .recovering: return true
        default: return false
        }
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
    public var density: LayoutDensity
    public var tier: CaptureTier
    public var reduceMotion: Bool
    public var reconcileInterval: TimeInterval

    public init(backgroundClickSwitches: Bool = false,
                preserveUserGeometry: Bool = false,
                foregroundWidthRatio: Double = 0.86,
                foregroundHeightRatio: Double = 0.88,
                foregroundEdgeInset: CGFloat = 32,
                density: LayoutDensity = .standard,
                tier: CaptureTier = .balanced,
                reduceMotion: Bool = false,
                reconcileInterval: TimeInterval = 2) {
        self.backgroundClickSwitches = backgroundClickSwitches
        self.preserveUserGeometry = preserveUserGeometry
        self.foregroundWidthRatio = Self.clamped(foregroundWidthRatio)
        self.foregroundHeightRatio = Self.clamped(foregroundHeightRatio)
        self.foregroundEdgeInset = foregroundEdgeInset
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
    public var records: [WindowIdentity: WindowRecord] = [:]
    public var slots = SlotRegistry(capacity: 0)
    public var catalogGeneration: UInt64 = 0
    public var transitionGeneration: UInt64 = 0
    public var keyboardFocus: KeyboardFocus = .none
    /// latest-wins：过渡期间只保留最后一个目标请求。
    public var pendingTarget: WindowIdentity?
    /// 本次会话由 Vistile 写过的几何事务，用于退出时恢复。
    public var transactions: [WindowIdentity: WindowTransaction] = [:]
    /// 恢复/销毁/退出任务不可被 pendingTarget 覆盖。
    public var isExitPending: Bool = false
    /// 一次查询仍在进行时不再叠加（方案 §6.7）。
    public var isDiscoveryInFlight: Bool = false
    public var searchQuery: String = ""
    public var policy = SessionPolicy()
    public var style: OverviewStyle = .standard
    public var sessionID = UUID()
    /// 内部背景点击产生的失焦不应触发退出。
    public var trustedInteraction: InteractionToken?
    /// 显示器 -> 该屏可用区，由宿主写入后供 reducer 决策使用。
    public var displays: [DisplayInfo] = []

    public init() {}

    public var recordsInSlotOrder: [WindowRecord] {
        slots.slots.compactMap { content in
            content.identity.flatMap { records[$0] }
        }
    }

    public func record(for identity: WindowIdentity) -> WindowRecord? {
        records[identity]
    }

    public mutating func nextTransitionToken() -> TransitionToken {
        transitionGeneration += 1
        return TransitionToken(generation: transitionGeneration)
    }

    public var hasPendingGeometryRestore: Bool {
        transactions.values.contains { $0.state.requiresRestore }
    }

    public func displayID(of identity: WindowIdentity) -> UInt32? {
        records[identity]?.displayID
    }
}
