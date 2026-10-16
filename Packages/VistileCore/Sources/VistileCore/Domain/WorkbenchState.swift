import Foundation
import CoreGraphics

public enum RailSide: String, Hashable, Sendable, Codable, CaseIterable {
    case left
    case right

    public var toggled: RailSide { self == .right ? .left : .right }

    public var displayName: String {
        switch self {
        case .left: return "左侧"
        case .right: return "右侧"
        }
    }
}

public enum RailKind: String, Hashable, Sendable, Codable, CaseIterable {
    case top
    case side

    public var displayName: String {
        switch self {
        case .top: return "顶栏"
        case .side: return "侧栏"
        }
    }
}

/// 轨道上的逻辑位置。滚动只改变 viewport 的显示偏移，不改变 ordinal（方案 §6）。
public struct RailSlotID: Hashable, Sendable, Codable, Comparable {
    public let displayID: UInt32
    public let rail: RailKind
    public let ordinal: Int

    public init(displayID: UInt32, rail: RailKind, ordinal: Int) {
        self.displayID = displayID
        self.rail = rail
        self.ordinal = ordinal
    }

    public static func < (lhs: RailSlotID, rhs: RailSlotID) -> Bool {
        if lhs.displayID != rhs.displayID { return lhs.displayID < rhs.displayID }
        if lhs.rail != rhs.rail { return lhs.rail == .top && rhs.rail == .side }
        return lhs.ordinal < rhs.ordinal
    }
}

/// 固定位置模型（方案 §6）：一个主窗口 + 各轨道 slot 的占用关系。
/// 硬不变量在这里维持：main 不在 occupants 中；每个身份只出现一次；每个 slot 至多一个窗口。
/// 交换只改 main 与被点 slot 两处，其他 occupant、rect 与滚动偏移一概不动。
public struct WorkbenchPlacement: Hashable, Sendable {
    public private(set) var main: WindowIdentity?
    public private(set) var occupants: [RailSlotID: WindowIdentity]
    public private(set) var revision: UInt64
    /// 用户显式整理过的顺序偏好：键是应用级 preferenceKey（不含窗口标题），值越小越靠前（方案 §6.2、§16）。
    /// 只在明确的整理动作里重写；同键多窗口的相对先后由会话内 slot 顺序稳定决定。
    public private(set) var orderPreference: [String: Int]
    /// 用户显式"固定在顶部"的应用（preferenceKey）：下次主动整理时优先占顶栏（方案 §6.2）。
    public private(set) var pinned: Set<String>

    public init(main: WindowIdentity? = nil,
                occupants: [RailSlotID: WindowIdentity] = [:],
                revision: UInt64 = 0,
                orderPreference: [String: Int] = [:],
                pinned: Set<String> = []) {
        self.main = main
        self.occupants = occupants
        self.revision = revision
        self.orderPreference = orderPreference
        self.pinned = pinned
    }

    public var memberCount: Int { occupants.count + (main == nil ? 0 : 1) }

    public var members: Set<WindowIdentity> {
        var set = Set(occupants.values)
        if let main { set.insert(main) }
        return set
    }

    public var isEmpty: Bool { main == nil && occupants.isEmpty }

    public func occupant(at slot: RailSlotID) -> WindowIdentity? { occupants[slot] }

    public func slot(of identity: WindowIdentity) -> RailSlotID? {
        occupants.first { $0.value == identity }?.key
    }

    public func contains(_ identity: WindowIdentity) -> Bool {
        main == identity || occupants.values.contains(identity)
    }

    /// 目标窗口回到它原来的 slot；没有记录时返回 nil（不能随便挑一个位置）。
    public func homeSlot(of identity: WindowIdentity) -> RailSlotID? { slot(of: identity) }

    // MARK: - 变更（每一处成功变更推进一次 revision）

    /// 首次选择：把 A 放进主区。A 若已在某个 slot 上，那个 slot 让空。
    @discardableResult
    public mutating func setMain(_ identity: WindowIdentity?) -> Bool {
        guard main != identity else { return false }
        main = identity
        if let identity, let slot = slot(of: identity) {
            occupants.removeValue(forKey: slot)
        }
        revision += 1
        return true
    }

    /// A/B 交换：B 进主区，A 回 B 原来的 slot。只有这两个位置改变（方案 §6.1）。
    @discardableResult
    public mutating func swapMain(with slot: RailSlotID) -> Bool {
        guard let incoming = occupants[slot] else { return false }
        let outgoing = main
        occupants[slot] = outgoing
        main = incoming
        if outgoing == nil { occupants.removeValue(forKey: slot) }
        revision += 1
        return true
    }

    /// 新窗口填空位或追加逻辑 slot：不抢主、不移动任何已有 occupant（方案 §6.2）。
    /// 落位不写顺序偏好：rank 只在明确的整理里按用户意图重写（方案 §4.4），免得越攒越多的无主键落盘。
    @discardableResult
    public mutating func place(_ identity: WindowIdentity, at slot: RailSlotID) -> Bool {
        guard !contains(identity), occupants[slot] == nil else { return false }
        occupants[slot] = identity
        revision += 1
        return true
    }

    /// 关闭窗口：它占的 slot 变空，后面的卡片不前移（方案 §6.2）。
    @discardableResult
    public mutating func vacate(_ identity: WindowIdentity) -> Bool {
        guard let slot = slot(of: identity) else {
            if main == identity { main = nil; revision += 1; return true }
            return false
        }
        occupants.removeValue(forKey: slot)
        revision += 1
        return true
    }

    /// 拖动：交换两个 slot 的 occupant；空格也参与交换（拖到空格就是移过去）。
    @discardableResult
    public mutating func swapSlots(_ lhs: RailSlotID, _ rhs: RailSlotID) -> Bool {
        guard lhs != rhs else { return false }
        let left = occupants[lhs]
        let right = occupants[rhs]
        guard left != nil || right != nil else { return false }
        occupants[lhs] = right
        occupants[rhs] = left
        revision += 1
        return true
    }

    /// 用户主动整理：压缩空位并按算好的身份顺序重新分配（方案 §4.4、§6.2）。
    /// `ordered` 由 reducer 给出（固定在顶部的优先占顶栏，其余按总览稳定顺序）；
    /// 这是唯一会重排轨道的动作，顺带把结果写进顺序偏好（键是应用级 preferenceKey）。
    public mutating func reorganize(slotOrder: [RailSlotID],
                                    ordered: [WindowIdentity],
                                    keys: [WindowIdentity: String]) {
        let members = ordered.filter { occupants.values.contains($0) }
        occupants.removeAll()
        var ranks: [String: Int] = [:]
        for (index, identity) in members.enumerated() {
            if index < slotOrder.count { occupants[slotOrder[index]] = identity }
            if let key = keys[identity] { ranks[key] = ranks[key] ?? index }
        }
        orderPreference = ranks
        revision += 1
    }

    public mutating func setPinned(_ preferenceKey: String, pinned isPinned: Bool) {
        if isPinned { pinned.insert(preferenceKey) } else { pinned.remove(preferenceKey) }
    }

    /// 会话开始：把跨会话记忆（顺序偏好与 pin）注入新会话；键只含应用标识，不含窗口标题（方案 §16）。
    /// 不推进 revision：这不是一次占用关系变更，只是记住用户以前说过的话。
    public mutating func adoptMemory(orderPreference: [String: Int], pinned: Set<String>) {
        self.orderPreference = orderPreference
        self.pinned = pinned
    }

    /// 会话结束：跨会话只保留顺序偏好与 pin（方案 §16）。
    public mutating func resetForHiddenSession() {
        main = nil
        occupants.removeAll()
        revision += 1
    }

    /// 不变量自检：宿主与测试用它证明"没有窗口丢失或重复"。
    public var maintainsInvariants: Bool {
        if let main, occupants.values.contains(main) { return false }
        let values = Array(occupants.values)
        return Set(values).count == values.count
    }
}

/// 主区交换的阶段（方案 §7、§8.2）。step 只用于诊断，placement 只在 commit 时提交。
public enum MainSwitchPhase: Hashable, Sendable {
    case idle
    case switching(intent: WorkbenchSwitchIntent, step: WorkbenchSwitchStep)
    case rollingBack(intent: WorkbenchSwitchIntent, reason: String)
    case failed(intent: WorkbenchSwitchIntent, reason: String)

    public var isBusy: Bool {
        switch self {
        case .idle, .failed: return false
        case .switching, .rollingBack: return true
        }
    }

    public var intent: WorkbenchSwitchIntent? {
        switch self {
        case .idle: return nil
        case let .switching(intent, _), let .rollingBack(intent, _), let .failed(intent, _): return intent
        }
    }
}

/// 交换进行中用户点下的最新目标：等前一次收敛后再处理（方案 §7.2、§10.4）。
public struct WorkbenchPendingSelection: Hashable, Sendable {
    public let identity: WindowIdentity
    public let slot: RailSlotID

    public init(identity: WindowIdentity, slot: RailSlotID) {
        self.identity = identity
        self.slot = slot
    }
}

/// 主窗口几何微调（侧栏切换、分隔线收敛）的在途写入：
/// 结果回来时凭令牌对上，不覆盖其他流程的读回（方案 §11.2）。
public struct WorkbenchFrameWrite: Hashable, Sendable {
    public let token: TransitionToken
    public let identity: WindowIdentity

    public init(token: TransitionToken, identity: WindowIdentity) {
        self.token = token
        self.identity = identity
    }
}

/// 工作台会话状态（方案 §7）。与总览网格各自独立：两套快照通过 WindowIdentity 关联。
public struct WorkbenchState: Hashable, Sendable {
    /// 活动工作台显示器：首次选择时确定，会话内至多一个主区事务（方案 §13）。
    public var activeDisplayID: UInt32?
    /// 用户固定的工作台显示器偏好；nil = 跟随点击的卡片所在屏幕（方案 §13）。
    /// 与 activeDisplayID 不同：这是跨会话设置，会话隐藏不重置；屏幕不存在时退回跟随点击。
    public var preferredDisplayID: UInt32?
    public var placement = WorkbenchPlacement()
    public var side: RailSide = .right
    /// 两条栏各自的滚动偏移（pt）。滚动不改变 slot 编号。
    public var topScrollOffset: CGFloat = 0
    public var sideScrollOffset: CGFloat = 0
    /// 分隔线拖动后的偏好（原始值，布局时按可用区 clamp）；写盘由宿主在拖动结束时做（方案 §11.2、§16）。
    public var topHeightPreference: CGFloat?
    public var sideWidthPreference: CGFloat?
    public var layoutRevision: Int = 0
    /// 当前冻结的几何投影：进入工作台时确定，只有明确布局事件才重算。
    public var snapshot: WorkbenchLayoutSnapshot?
    public var modeTransition: ModeTransition = .idle
    public var mainSwitch: MainSwitchPhase = .idle
    public var pendingRailSelection: WorkbenchPendingSelection?
    /// 交换进行中按下的「全部窗口」：等这次收敛后再回总览（方案 §4.5）。两个 pending 互斥，后到者覆盖。
    public var pendingReturnToOverview = false
    public var mainFrameWrite: WorkbenchFrameWrite?
    /// 返回总览时保存的最近主身份：只是布局上下文，重启后不得用于自动激活（方案 §16）。
    public var lastSelectedMain: WindowIdentity?

    public init() {}

    public var members: Set<WindowIdentity> { placement.members }

    public func slot(of identity: WindowIdentity) -> RailSlotID? { placement.slot(of: identity) }

    public func scrollOffset(rail: RailKind) -> CGFloat {
        switch rail {
        case .top: return topScrollOffset
        case .side: return sideScrollOffset
        }
    }

    /// 滚动偏移按栏各自独立，越界由布局的轨道长度夹取。
    public mutating func scroll(rail: RailKind, offset: CGFloat) {
        let clamped = snapshot?.clampedScroll(rail: rail, offset: offset) ?? max(0, offset)
        switch rail {
        case .top: topScrollOffset = clamped
        case .side: sideScrollOffset = clamped
        }
    }

    /// 会话结束：placement 只保留跨会话的顺序偏好与 pin（方案 §16）；
    /// side 与分隔线偏好属于用户设置，宿主另行持久化，这里保留默认不抖动。
    public mutating func resetForHiddenSession() {
        placement.resetForHiddenSession()
        activeDisplayID = nil
        topScrollOffset = 0
        sideScrollOffset = 0
        snapshot = nil
        modeTransition = .idle
        mainSwitch = .idle
        pendingRailSelection = nil
        pendingReturnToOverview = false
        mainFrameWrite = nil
        lastSelectedMain = nil
    }
}
