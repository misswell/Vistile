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

    /// 正在做操作补偿：这一状态只有宿主回报完整补偿事实后才能收口（方案 §6.4）。
    public var isRollingBack: Bool {
        if case .rollingBack = self { return true }
        return false
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

/// preparing 阶段的暂存（方案 §7.1、§15）：日志原子落盘成功后才一次性并入状态并放出几何 effect。
/// 内存里绝不允许出现"事务已改、日志没落"的中间态，所以事务与投影都先寄存在这里。
public struct ArmedGeometryOperation: Hashable, Sendable {
    /// 落盘成功的回执必须整体对上这个上下文；旧会话或旧操作迟到的回执一律无效（方案 §7.5）。
    public let context: GeometryOperationContext
    /// 落盘成功后按原顺序放出的 effect（过渡计划、面板显隐、键盘移交等）。
    public let effects: [SessionEffect]
    /// 只在这次落盘成功后才并入内存的事务。
    public let transactions: [WindowIdentity: WindowTransaction]
    /// 本次操作的前态快照：补偿依据，随计划一起交给宿主（方案 §6.3）。
    public let before: WorkbenchOperationSnapshot
    /// 落盘成功后一次性写入的工作台投影。
    public let staged: StagedWorkbench

    public init(context: GeometryOperationContext,
                effects: [SessionEffect],
                transactions: [WindowIdentity: WindowTransaction],
                before: WorkbenchOperationSnapshot,
                staged: StagedWorkbench) {
        self.context = context
        self.effects = effects
        self.transactions = transactions
        self.before = before
        self.staged = staged
    }
}

/// `ArmedGeometryOperation` 落盘成功后要一次性写入的工作台字段。
/// 独立成结构是为了让"未落盘"与"已开始"只有这一个切换点，不存在半套在途状态。
public struct StagedWorkbench: Hashable, Sendable {
    public var snapshot: WorkbenchLayoutSnapshot?
    public var layoutRevision: Int?
    public var modeTransition: ModeTransition = .idle
    public var mainSwitch: MainSwitchPhase = .idle
    public var activeDisplayID: UInt32?
    public var lastSelectedMain: WindowIdentity?
    public var mainFrameWrite: WorkbenchFrameWrite?
    public var phase: SessionPhase = .overview
    public var keyboardFocus: KeyboardFocus = .none

    public init() {}
}

/// 未能恢复一致的显式状态（方案 §15）：补偿不完整、或日志失败发生在真实写入之后才进入。
/// 语义是"这里的几何不可信"：普通操作全部拒绝，只允许重试或安全退出（方案 §6.4）。
public struct WorkbenchRecoveryRequired: Hashable, Sendable {
    public let reason: String
    /// 仍缺补偿依据或补偿失败的身份。
    public let identities: [WindowIdentity]
    /// 进入该状态的操作：退出恢复要按同一次操作的事实来判定。
    public let context: GeometryOperationContext?

    public init(reason: String,
                identities: [WindowIdentity],
                context: GeometryOperationContext?) {
        self.reason = reason
        self.identities = identities
        self.context = context
    }
}

/// 两条栏的滚动上下文（方案 §12）：离开工作台时最后一次的偏移与其来源布局。
/// 重入时按它重建投影；布局变小由 snapshot 自己 clamp。
public struct WorkbenchScrollOffsets: Hashable, Sendable {
    public var top: CGFloat
    public var side: CGFloat
    /// 记录时的显示器与布局版本：只用于判断能否精确恢复。
    public var displayID: UInt32?
    public var layoutRevision: Int?

    public init(top: CGFloat = 0,
                side: CGFloat = 0,
                displayID: UInt32? = nil,
                layoutRevision: Int? = nil) {
        self.top = top
        self.side = side
        self.displayID = displayID
        self.layoutRevision = layoutRevision
    }

    public func offset(rail: RailKind) -> CGFloat {
        rail == .top ? top : side
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
    /// 分隔线拖动后的偏好（原始值，布局时按可用区 clamp）；写盘由宿主在拖动结束时做（方案 §11.2、§16）。
    public var topHeightPreference: CGFloat?
    public var sideWidthPreference: CGFloat?
    public var layoutRevision: Int = 0
    /// 当前冻结的几何投影：进入工作台时确定，只有明确布局事件才重算。
    /// 滚动偏移的唯一权威来源：这里不再维护第二份互相覆盖的数值（方案 §12）。
    public var snapshot: WorkbenchLayoutSnapshot?
    /// 离开工作台时最后一次的滚动上下文：重入用它重建投影，不能硬编码 0（方案 §12）。
    public var savedScrollOffsets: WorkbenchScrollOffsets?
    public var modeTransition: ModeTransition = .idle
    public var mainSwitch: MainSwitchPhase = .idle
    public var pendingRailSelection: WorkbenchPendingSelection?
    /// 交换进行中按下的「全部窗口」：等这次收敛后再回总览（方案 §4.5）。两个 pending 互斥，后到者覆盖。
    public var pendingReturnToOverview = false
    public var mainFrameWrite: WorkbenchFrameWrite?
    /// 交换中已发出的那一次有界位置修正（方案 §9.2）：至多一次，第二次仍越界就只能补偿。
    public var switchCorrection: WorkbenchFrameWrite?
    /// 已放出操作的事实累积（方案 §6.3、§18 A42）：写过哪些窗口、读回是什么。
    /// 补偿判定与"存在真实写入就有恢复依据"都按它，不按"有没有事务"猜。
    public var runningOperation: WorkbenchOperationSnapshot?
    /// 返回总览时保存的最近主身份：只是布局上下文，重启后不得用于自动激活（方案 §16）。
    public var lastSelectedMain: WindowIdentity?
    /// 正在等待日志落盘的操作（方案 §15 的 preparing）：一次 AX 都没写，最新选择可替换。
    public var armed: ArmedGeometryOperation?
    /// 已放出并正在执行的操作上下文：隐藏/退出必须按它排空在途写入（方案 §5.2）。
    public var activeContext: GeometryOperationContext?
    /// 一次窗口关闭事件至多自动替补一个候选；失败后不得继续遍历其他应用（方案 §10）。
    public var hasAutoPromotionAttempted = false
    /// 显式"未能恢复一致"：非 nil 时普通操作全部拒绝（方案 §6.4、§15）。
    public var recoveryRequired: WorkbenchRecoveryRequired?
    /// 统一的过渡活动：尺寸重配抑制与隐藏前排空判定都用它，不再各看一个瞬时布尔（方案 §13.2）。
    public var transitionActivity = TransitionActivity()
    /// 过渡期间收到过栏尺寸更新：偏好已经记下，但投影要到收敛那一刻才重算一次（方案 §13.2）。
    public var railSizeRecomputePending = false

    public init() {}

    public var members: Set<WindowIdentity> { placement.members }

    public func slot(of identity: WindowIdentity) -> RailSlotID? { placement.slot(of: identity) }

    /// 普通几何操作的唯一准入：恢复一致状态之外，还不得有别的操作在途（方案 §5.1）。
    public var acceptsNewOrdinaryOperation: Bool {
        recoveryRequired == nil && !mainSwitch.isBusy && !modeTransition.isTransitioning
            && !transitionActivity.blocksGeometryReconfiguration
    }

    /// 需要排空的在途操作：preparing 中的意图与已开始写入的操作都要覆盖（方案 §5.2）。
    public var pendingDrainContexts: [GeometryOperationContext] {
        [armed?.context, activeContext].compactMap { $0 }
    }

    /// 偏移的唯一来源：有投影读投影，没投影读上次保存的上下文（方案 §12）。
    public func scrollOffset(rail: RailKind) -> CGFloat {
        if let snapshot { return snapshot.scrollOffset(rail: rail) }
        return savedScrollOffsets?.offset(rail: rail) ?? 0
    }

    /// 写入滚动偏移：投影与"上次上下文"一次改完，两者不可能互相覆盖。
    public mutating func scroll(rail: RailKind, offset: CGFloat) {
        if let snapshot {
            self.snapshot = snapshot.scrolling(rail: rail, to: snapshot.clampedScroll(rail: rail, offset: offset))
        }
        saveScrollOffsets()
    }

    /// 重入时按上次上下文创建投影：内容减少或屏幕范围缩小由布局 clamp（方案 §12）。
    public func reentryScrollOffset(rail: RailKind, layout: WorkbenchLayout) -> CGFloat {
        layout.clampedScroll(rail: rail, offset: savedScrollOffsets?.offset(rail: rail) ?? 0)
    }

    /// 把当前投影的偏移记为"离开工作台时的上下文"。
    public mutating func saveScrollOffsets() {
        guard let snapshot else { return }
        savedScrollOffsets = WorkbenchScrollOffsets(top: snapshot.topScrollOffset,
                                                   side: snapshot.sideScrollOffset,
                                                   displayID: snapshot.displayID,
                                                   layoutRevision: snapshot.revision)
    }

    /// 一次性并入已备好操作的投影：这是"未落盘"变成"已开始"的唯一切换点。
    mutating func applyStaged(_ staged: StagedWorkbench) {
        if let snapshot = staged.snapshot { self.snapshot = snapshot }
        if let layoutRevision = staged.layoutRevision { self.layoutRevision = layoutRevision }
        modeTransition = staged.modeTransition
        mainSwitch = staged.mainSwitch
        if let activeDisplayID = staged.activeDisplayID { self.activeDisplayID = activeDisplayID }
        lastSelectedMain = staged.lastSelectedMain
        mainFrameWrite = staged.mainFrameWrite
    }

    /// 会话结束：placement 只保留跨会话的顺序偏好与 pin（方案 §16）；
    /// side 与分隔线偏好属于用户设置，宿主另行持久化，这里保留默认不抖动。
    /// 滚动上下文按既定偏好保留：下次打开入口仍是总览，但回到工作台不该从 0 开始（方案 §12）。
    public mutating func resetForHiddenSession() {
        placement.resetForHiddenSession()
        activeDisplayID = nil
        savedScrollOffsets = nil
        snapshot = nil
        modeTransition = .idle
        mainSwitch = .idle
        pendingRailSelection = nil
        pendingReturnToOverview = false
        mainFrameWrite = nil
        switchCorrection = nil
        runningOperation = nil
        lastSelectedMain = nil
        armed = nil
        activeContext = nil
        hasAutoPromotionAttempted = false
        recoveryRequired = nil
        transitionActivity = TransitionActivity()
        railSizeRecomputePending = false
    }
}
