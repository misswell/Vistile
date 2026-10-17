import Foundation
import CoreGraphics

/// 一次操作中某个窗口的**写入前实读**（方案 §6.3）。
/// 与会话 original 是两个独立事实：original 用于最终退出，before 用于此次失败补偿。
public struct OperationGeometrySnapshot: Hashable, Sendable {
    public let identity: WindowIdentity
    public let beforeFrame: CGRect
    public let beforeDisplayID: UInt32?
    /// 落点：补偿时把该窗口送回哪里。首次取 `beforeFrame`，宿主回报写前实读后可纠正一次。
    public var compensationTarget: CGRect
    /// 本次操作是否已经对它发生过真实写入（方案 §6.4：补偿义务按事实判定，不按"有没有事务"判定）。
    public var didWrite = false
    /// 已有读回值时不再重复补偿。
    public var readBack: CGRect?

    public init(identity: WindowIdentity,
                beforeFrame: CGRect,
                beforeDisplayID: UInt32?,
                compensationTarget: CGRect? = nil) {
        self.identity = identity
        self.beforeFrame = beforeFrame
        self.beforeDisplayID = beforeDisplayID
        self.compensationTarget = compensationTarget ?? beforeFrame
    }

    /// 写前实读纠正：只有从未写入过才允许改，改过的窗口不能再"退回"到猜测值。
    public mutating func correctBeforeRead(frame: CGRect, displayID: UInt32?) {
        guard !didWrite else { return }
        compensationTarget = frame
    }

    public mutating func markWritten(readBack: CGRect?) {
        didWrite = true
        self.readBack = readBack
    }
}

/// 一次操作的前态快照：随计划交给宿主，补偿按它的**逆序**执行（方案 §6.3、§6.4）。
public struct WorkbenchOperationSnapshot: Hashable, Sendable {
    public let context: GeometryOperationContext
    /// 有副作用的步骤顺序；补偿时倒序遍历。
    public var writtenOrder: [WindowIdentity]
    public private(set) var before: [WindowIdentity: OperationGeometrySnapshot]

    public init(context: GeometryOperationContext,
                writtenOrder: [WindowIdentity] = [],
                before: [WindowIdentity: OperationGeometrySnapshot] = [:]) {
        self.context = context
        self.writtenOrder = writtenOrder
        self.before = before
    }

    public func entry(for identity: WindowIdentity) -> OperationGeometrySnapshot? { before[identity] }

    public mutating func record(_ entry: OperationGeometrySnapshot, writtenStep: Bool) {
        before[entry.identity] = entry
        if writtenStep, !writtenOrder.contains(entry.identity) { writtenOrder.append(entry.identity) }
    }

    public mutating func markWritten(_ identity: WindowIdentity, readBack: CGRect?) {
        guard var entry = before[identity] else { return }
        entry.markWritten(readBack: readBack)
        before[identity] = entry
    }

    public mutating func correctBeforeRead(_ identity: WindowIdentity, frame: CGRect, displayID: UInt32?) {
        guard var entry = before[identity] else { return }
        entry.correctBeforeRead(frame: frame, displayID: displayID)
        before[identity] = entry
    }

    /// 补偿顺序：后写的先回，避免把已经归位的窗口再次覆盖（方案 §6.4）。
    public var compensationOrder: [WindowIdentity] { writtenOrder.reversed() }

    /// 存在真实写入就必须有恢复依据：写过但没有 before 事实的操作只能进 recoveryRequired（方案 §18 A42）。
    public var hasUnexplainedWrite: Bool {
        writtenOrder.contains { before[$0] == nil }
    }

    public func compensationTargets() -> [(identity: WindowIdentity, target: CGRect)] {
        compensationOrder.compactMap { identity in
            before[identity].map { (identity, $0.compensationTarget) }
        }
    }
}

/// 用户这次选择的来源（方案 §6）。总览 slot 与轨道 slot 是两套独立的位置空间。
public enum WorkbenchSelectionSource: Hashable, Sendable {
    case overview(slot: SlotID, revision: Int)
    case rail(slot: RailSlotID)
    case returnToSameMain
    case accessibility

    public var displayName: String {
        switch self {
        case .overview: return "总览"
        case .rail: return "轨道"
        case .returnToSameMain: return "原主窗口"
        case .accessibility: return "辅助功能"
        }
    }
}

/// A/B 两窗口交换意图（方案 §8）。携带令牌与 placement 版本：
/// 只有 placement 没被更新过的回调才允许提交。
public struct WorkbenchSwitchIntent: Hashable, Sendable {
    public var railSlot: RailSlotID? {
        if case let .rail(slot) = source { return slot }
        return nil
    }

    public let token: TransitionToken
    /// 旧主窗口；首次选择时为 nil。
    public let from: WindowIdentity?
    public let to: WindowIdentity
    public let source: WorkbenchSelectionSource
    public let placementRevision: UInt64
    public let targetDisplayID: UInt32
    /// 本次操作的身份（方案 §5.3）：普通交换、自动替补都用它做写入准入与回执对账。
    public let operationContext: GeometryOperationContext
    /// 操作前快照（方案 §6.3）：宿主按它逆序补偿，不再靠"有没有事务"猜成功与否。
    public let beforeOperation: WorkbenchOperationSnapshot

    public init(token: TransitionToken,
                from: WindowIdentity?,
                to: WindowIdentity,
                source: WorkbenchSelectionSource,
                placementRevision: UInt64,
                targetDisplayID: UInt32,
                operationContext: GeometryOperationContext,
                beforeOperation: WorkbenchOperationSnapshot) {
        self.token = token
        self.from = from
        self.to = to
        self.source = source
        self.placementRevision = placementRevision
        self.targetDisplayID = targetDisplayID
        self.operationContext = operationContext
        self.beforeOperation = beforeOperation
    }

    /// 操作类型：替补与手动交换走同一条执行链，但失败落点不同（方案 §10）。
    public var kind: GeometryOperationKind { operationContext.kind }
    public var isPromotion: Bool { kind == .promoteCandidate }
}

/// 交换的执行步骤（方案 §8.2）。步骤顺序固定，placement 只在全部确定后提交。
public enum WorkbenchSwitchStep: String, Hashable, Sendable, CaseIterable {
    case prepare
    case moveToMain
    case activateMain
    case restorePrevious
    case commit

    public var displayName: String {
        switch self {
        case .prepare: return "准备"
        case .moveToMain: return "目标进主区"
        case .activateMain: return "前景确认"
        case .restorePrevious: return "原主窗口回轨"
        case .commit: return "提交"
        }
    }
}

/// reducer 算好的交换计划：主区目标矩形与旧主的落点都在核心层算一次，
/// 日志里记的与实际写入的必须是同一个值（方案 §6.2、§8.1）。
public struct WorkbenchSwitchPlan: Hashable, Sendable {
    public let intent: WorkbenchSwitchIntent
    public let displayID: UInt32
    /// B 的目标：主区矩形（应用可能按自身约束返回更小的实际值，以读回为准）。
    public let mainTargetFrame: CGRect
    /// A 的落点：它原来的预览位置（restingFrame），首次选择时为 nil。
    public let restingTargetFrame: CGRect?
    /// A 回到的是哪个 slot；nil 表示 A 不属于任何轨道（例如首次进入）。
    public let restingSlot: RailSlotID?
    /// 本次交换使用的几何投影：动画端点（B 的卡片矩形、主区矩形）都从它算。
    public let snapshot: WorkbenchLayoutSnapshot
    /// 宿主渲染两栏所需事实。
    public let presentation: WorkbenchPresentation
    /// 主区与两条栏的交互矩形（方案 §9.2）：读回必须逐条对它验证，
    /// 不能让宿主自己再算一遍——两处算法就会有两处结论。
    public let mainRect: CGRect
    public let topRailRect: CGRect
    public let sideRailRect: CGRect
    /// 核心层算好的放置路径（方案 §9.1）：仅移动时宿主只写 position，不得顺手写 size。
    public let placement: MainPlacementDecision

    public init(intent: WorkbenchSwitchIntent,
                displayID: UInt32,
                mainTargetFrame: CGRect,
                restingTargetFrame: CGRect?,
                restingSlot: RailSlotID?,
                snapshot: WorkbenchLayoutSnapshot,
                presentation: WorkbenchPresentation,
                placement: MainPlacementDecision) {
        self.intent = intent
        self.displayID = displayID
        self.mainTargetFrame = mainTargetFrame
        self.restingTargetFrame = restingTargetFrame
        self.restingSlot = restingSlot
        self.snapshot = snapshot
        self.presentation = presentation
        self.mainRect = snapshot.layout.mainRect
        self.topRailRect = snapshot.layout.topRailRect
        self.sideRailRect = snapshot.layout.sideRailRect
        self.placement = placement
    }

    /// 补偿时逐个身份回放的落点（方案 §6.4）：宿主不再自己决定"回到哪"。
    public var compensationTargets: [(identity: WindowIdentity, target: CGRect)] {
        intent.beforeOperation.compensationTargets()
    }

    /// 读回是否仍在主区内且不侵入两条栏（方案 §9.2）。
    public func verifyPlacement(readBack: CGRect) -> PlacementVerification {
        MainPlacementPolicy.verify(readBack: readBack,
                                   mainRect: mainRect,
                                   topRailRect: topRailRect,
                                   sideRailRect: sideRailRect)
    }
}

/// 一个步骤的结果。只有读回事实，不含"我以为成功"。
public enum WorkbenchStepOutcome: Hashable, Sendable {
    case succeeded(readBack: CGRect?)
    /// 应用按自身最小/最大尺寸返回：可以继续，但事实要写下来。
    /// constrained 只说明"写入被接受并做了约束"，**不等于仍在主区内**——主区合格由
    /// `MainPlacementPolicy.verify` 单独判定，越界时改用 `.outsideMain`（方案 §9.2）。
    case constrained(readBack: CGRect, note: String)
    /// 读回有效但越出主区或侵入两条栏超容差：不能提交，必须补偿（方案 §9.2）。
    case outsideMain(readBack: CGRect, reason: String)
    case rejected(String)
    case targetGone

    public var allowsContinue: Bool {
        switch self {
        case .succeeded, .constrained: return true
        case .outsideMain, .rejected, .targetGone: return false
        }
    }

    public var isFailure: Bool { !allowsContinue }

    /// 有读回事实的步骤：主区合格性必须逐条验证，不能只看"结果允许继续"。
    public var readBackFrame: CGRect? {
        switch self {
        case let .succeeded(readBack): return readBack
        case let .constrained(readBack, _), let .outsideMain(readBack, _): return readBack
        case .rejected, .targetGone: return nil
        }
    }

    public var message: String {
        switch self {
        case .succeeded: return "成功"
        case let .constrained(_, note): return "受限：\(note)"
        case let .outsideMain(_, reason): return "越出主区：\(reason)"
        case let .rejected(reason): return "被拒绝：\(reason)"
        case .targetGone: return "窗口或进程已消失"
        }
    }
}

public struct WorkbenchSwitchStepResult: Hashable, Sendable {
    public let token: TransitionToken
    public let step: WorkbenchSwitchStep
    public let outcome: WorkbenchStepOutcome
    public let identity: WindowIdentity?

    public init(token: TransitionToken,
                step: WorkbenchSwitchStep,
                outcome: WorkbenchStepOutcome,
                identity: WindowIdentity?) {
        self.token = token
        self.step = step
        self.outcome = outcome
        self.identity = identity
    }
}

/// 模式过渡（总览↔工作台）的计划。与 A/B 交换共用同一套几何执行器。
public enum WorkbenchTransitionKind: String, Hashable, Sendable {
    case enteringWorkbench
    case returningOverview

    public var displayName: String {
        switch self {
        case .enteringWorkbench: return "进入工作台"
        case .returningOverview: return "返回总览"
        }
    }
}

/// 其余卡片在冻结总览与轨道之间的过渡端点（方案 §4.2.5、§10.1）。
/// to 为 nil 表示目标 slot 在可视区之外：宿主按溢出指示淡化，不伪造位置。
public struct RailHandoff: Hashable, Sendable {
    public let identity: WindowIdentity
    public let slot: RailSlotID
    public let from: CGRect
    public let to: CGRect?

    public init(identity: WindowIdentity, slot: RailSlotID, from: CGRect, to: CGRect?) {
        self.identity = identity
        self.slot = slot
        self.from = from
        self.to = to
    }
}

public struct WorkbenchTransitionPlan: Hashable, Sendable {
    public let kind: WorkbenchTransitionKind
    public let token: TransitionToken
    /// 本次模式过渡的操作上下文（方案 §5.3）：写入许可、排空与回执对账都按它，
    /// 只有一个自增 generation 不足以判定异步有效性。
    public let operationContext: GeometryOperationContext
    public let identity: WindowIdentity
    public let displayID: UInt32
    public let snapshot: WorkbenchLayoutSnapshot
    /// 真实窗口要写入的目标：进入=主区停靠目标；返回=restingFrame（原始/用户保留尺寸）。
    public let targetFrame: CGRect
    /// 代理动画起点（主窗口的屏幕矩形）；nil 表示从当前实际位置接续。
    public let animationFrom: CGRect?
    /// 代理动画终点；nil 表示淡出，不做飞行动画。
    public let animationTo: CGRect?
    /// 其余卡片在两个位置空间之间的过渡端点。
    public let railHandoffs: [RailHandoff]
    public let animationMS: Int
    /// 宿主渲染两栏所需事实。
    public let presentation: WorkbenchPresentation
    /// 主窗口进主区的放置路径（方案 §9.1）：仅移动时只写 position，不可容纳时根本不该有这个计划。
    public let placement: MainPlacementDecision

    public init(kind: WorkbenchTransitionKind,
                token: TransitionToken,
                operationContext: GeometryOperationContext,
                identity: WindowIdentity,
                displayID: UInt32,
                snapshot: WorkbenchLayoutSnapshot,
                targetFrame: CGRect,
                animationFrom: CGRect?,
                animationTo: CGRect?,
                railHandoffs: [RailHandoff],
                animationMS: Int,
                presentation: WorkbenchPresentation,
                placement: MainPlacementDecision) {
        self.kind = kind
        self.token = token
        self.operationContext = operationContext
        self.identity = identity
        self.displayID = displayID
        self.snapshot = snapshot
        self.targetFrame = targetFrame
        self.animationFrom = animationFrom
        self.animationTo = animationTo
        self.railHandoffs = railHandoffs
        self.animationMS = animationMS
        self.presentation = presentation
        self.placement = placement
    }
}
