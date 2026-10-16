import Foundation
import CoreGraphics

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

    public init(token: TransitionToken,
                from: WindowIdentity?,
                to: WindowIdentity,
                source: WorkbenchSelectionSource,
                placementRevision: UInt64,
                targetDisplayID: UInt32) {
        self.token = token
        self.from = from
        self.to = to
        self.source = source
        self.placementRevision = placementRevision
        self.targetDisplayID = targetDisplayID
    }
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

    public init(intent: WorkbenchSwitchIntent,
                displayID: UInt32,
                mainTargetFrame: CGRect,
                restingTargetFrame: CGRect?,
                restingSlot: RailSlotID?,
                snapshot: WorkbenchLayoutSnapshot,
                presentation: WorkbenchPresentation) {
        self.intent = intent
        self.displayID = displayID
        self.mainTargetFrame = mainTargetFrame
        self.restingTargetFrame = restingTargetFrame
        self.restingSlot = restingSlot
        self.snapshot = snapshot
        self.presentation = presentation
    }
}

/// 一个步骤的结果。只有读回事实，不含"我以为成功"。
public enum WorkbenchStepOutcome: Hashable, Sendable {
    case succeeded(readBack: CGRect?)
    /// 应用按自身最小/最大尺寸返回：可以继续，但事实要写下来。
    case constrained(readBack: CGRect, note: String)
    case rejected(String)
    case targetGone

    public var allowsContinue: Bool {
        switch self {
        case .succeeded, .constrained: return true
        case .rejected, .targetGone: return false
        }
    }

    public var isFailure: Bool { !allowsContinue }

    public var message: String {
        switch self {
        case .succeeded: return "成功"
        case let .constrained(_, note): return "受限：\(note)"
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

    public init(kind: WorkbenchTransitionKind,
                token: TransitionToken,
                identity: WindowIdentity,
                displayID: UInt32,
                snapshot: WorkbenchLayoutSnapshot,
                targetFrame: CGRect,
                animationFrom: CGRect?,
                animationTo: CGRect?,
                railHandoffs: [RailHandoff],
                animationMS: Int,
                presentation: WorkbenchPresentation) {
        self.kind = kind
        self.token = token
        self.identity = identity
        self.displayID = displayID
        self.snapshot = snapshot
        self.targetFrame = targetFrame
        self.animationFrom = animationFrom
        self.animationTo = animationTo
        self.railHandoffs = railHandoffs
        self.animationMS = animationMS
        self.presentation = presentation
    }
}
