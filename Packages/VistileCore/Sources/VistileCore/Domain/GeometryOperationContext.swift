import Foundation
import CoreGraphics

/// 会话的写入生命周期（方案 §5.1）。普通操作只在 `open` 准入；补偿与退出恢复用独立授权，
/// 不能复用已经撤销的普通操作令牌。
public enum GeometrySessionPhase: Hashable, Sendable {
    case open
    case closing
    case restoring
    case closed
}

/// 一次几何操作的类别：决定取消时走普通撤销还是恢复授权（方案 §5.1、§6.1）。
public enum GeometryOperationKind: String, Hashable, Sendable {
    case enterWorkbench
    case mainSwitch
    case returnOverview
    case settleLayout
    case promoteCandidate
    case compensation
    case sessionRestore

    /// 用户驱动的普通操作：可被取消屏障整体撤销；补偿与会话恢复不能被"过期事件"忽略。
    public var isOrdinary: Bool {
        switch self {
        case .enterWorkbench, .mainSwitch, .returnOverview, .settleLayout, .promoteCandidate: return true
        case .compensation, .sessionRestore: return false
        }
    }
}

/// 每个几何操作携带的不可变上下文（方案 §5.1）。事件有效性同时验证会话、代次与操作，
/// 不能只比较一个持续增加的 generation（方案 §15）。
public struct GeometryOperationContext: Hashable, Sendable, Identifiable {
    public let sessionID: UUID
    public let sessionEpoch: UInt64
    public let operationID: UUID
    public let transitionToken: TransitionToken
    public let kind: GeometryOperationKind

    public init(sessionID: UUID,
                sessionEpoch: UInt64,
                operationID: UUID,
                transitionToken: TransitionToken,
                kind: GeometryOperationKind) {
        self.sessionID = sessionID
        self.sessionEpoch = sessionEpoch
        self.operationID = operationID
        self.transitionToken = transitionToken
        self.kind = kind
    }

    public var id: UUID { operationID }

    /// 迟到回执的唯一判据：会话与代次都必须对上（方案 §5.5）。
    public func matches(sessionID: UUID, epoch: UInt64) -> Bool {
        sessionID == self.sessionID && epoch == self.sessionEpoch
    }
}

/// 线程安全写入许可（方案 §5.2）：宿主把它交给 AX 队列，命令在开始任何跨进程写入前检查它。
/// 只在 MainActor 之前检查是不够的——命令可能已经排进 AX 队列但尚未执行。
/// 这里不使用 MainActor 同步回调，避免 AX 队列与主线程互相等待。
public final class GeometryWritePermit: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = true

    public init() {}

    /// 已进入系统调用的命令按"在途"处理：中途无法保证撤销跨进程调用（方案 §5.2）。
    public var isGranted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }

    /// 原子撤销：之后排队的命令一律拒绝，但已在执行的仍要把真实写入计入恢复。
    public func revoke() {
        lock.lock()
        defer { lock.unlock() }
        granted = false
    }
}

/// 统一的过渡活动事实（方案 §13.2）：取代单独的 focus.isAnimating 作为捕获尺寸重配的抑制条件。
/// 过渡期间允许捕获启停与安全降级，只延后可合并的尺寸重配。
public struct TransitionActivity: Hashable, Sendable {
    public var focusProxy: Bool
    public var modeTransition: Bool
    public var mainSwitch: Bool
    public var layoutSettle: Bool
    public var rollback: Bool
    /// 取消或停止已请求：此时任何"延后"都必须立即失效，释放不能被过渡状态拖住（方案 §13.2）。
    public var cancellationRequested: Bool

    public init(focusProxy: Bool = false,
                modeTransition: Bool = false,
                mainSwitch: Bool = false,
                layoutSettle: Bool = false,
                rollback: Bool = false,
                cancellationRequested: Bool = false) {
        self.focusProxy = focusProxy
        self.modeTransition = modeTransition
        self.mainSwitch = mainSwitch
        self.layoutSettle = layoutSettle
        self.rollback = rollback
        self.cancellationRequested = cancellationRequested
    }

    public var isActive: Bool {
        focusProxy || modeTransition || mainSwitch || layoutSettle || rollback
    }

    /// 尺寸重配的唯一抑制判据：有过渡在跑、且没人要求取消时才延后。
    public var blocksGeometryReconfiguration: Bool { isActive && !cancellationRequested }

    /// 多来源合并：字段级 OR，任何一方说"还在动"就是还在动。
    public static func | (lhs: TransitionActivity, rhs: TransitionActivity) -> TransitionActivity {
        TransitionActivity(focusProxy: lhs.focusProxy || rhs.focusProxy,
                           modeTransition: lhs.modeTransition || rhs.modeTransition,
                           mainSwitch: lhs.mainSwitch || rhs.mainSwitch,
                           layoutSettle: lhs.layoutSettle || rhs.layoutSettle,
                           rollback: lhs.rollback || rhs.rollback,
                           cancellationRequested: lhs.cancellationRequested || rhs.cancellationRequested)
    }
}
