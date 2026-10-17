import Foundation
import CoreGraphics

/// AX 写入的真实结果。"函数返回没有报错"不等于窗口到位（方案 §6.1）。
public enum GeometryOutcome: Hashable, Sendable {
    /// 读回值在容差内与目标一致。
    case exact(readBack: CGRect)
    /// 有明确证据应用接受了部分写入、并按自身最小/最大尺寸做了调整。
    case constrained(readBack: CGRect)
    /// 写入被拒绝：AX 返回错误，或写前写后完全一致而目标不同。
    case rejected(GeometryRejectReason)
    /// 读不回 frame：不允许宣称成功。
    case unreadable
    /// 句柄已失效：窗口或进程没了。
    case targetGone
    /// 许可在命令中途被撤销（方案 §5.2）：这些是**已发生的部分写入事实**，不是"零写入"。
    case cancelled(wroteSize: Bool, wrotePosition: Bool, readBack: CGRect?)

    public var readBackFrame: CGRect? {
        switch self {
        case let .exact(frame), let .constrained(frame): return frame
        case let .cancelled(_, _, readBack): return readBack
        default: return nil
        }
    }

    /// 展开阶段允许继续正常使用：exact，或有证据的 constrained（改用实际读回值做展示目标）。
    /// 中途取消与拒绝都不允许：写入状态不明时只能走恢复 fence（方案 §5.2）。
    public var allowsExpandedUse: Bool {
        switch self {
        case .exact, .constrained: return true
        default: return false
        }
    }

    /// 只有 exact 才能自动结束几何事务；任意偏差不算恢复成功（方案 §6.1）。
    public var settlesGeometryTransaction: Bool {
        if case .exact = self { return true }
        return false
    }

    /// 已经改变过窗口几何：过期操作需要进入补偿恢复。
    /// 部分写入同样是"改过"：不能因为撤销就当成没动过（方案 §5.2）。
    public var didChangeGeometry: Bool {
        switch self {
        case .exact, .constrained: return true
        case let .cancelled(wroteSize, wrotePosition, _): return wroteSize || wrotePosition
        case .rejected(let reason): return reason.didChangeGeometry
        case .unreadable, .targetGone: return false
        }
    }

    public var message: String {
        switch self {
        case .exact: return "写入读回一致"
        case let .constrained(frame): return "应用按自身尺寸约束返回 \(RecoveryText.frame(frame))"
        case let .rejected(reason): return "写入被拒绝：\(reason.message)"
        case .unreadable: return "写入后无法读回 frame"
        case .targetGone: return "窗口句柄已失效"
        case let .cancelled(wroteSize, wrotePosition, readBack):
            let facts: [String] = [wroteSize ? "尺寸已写" : nil, wrotePosition ? "位置已写" : nil].compactMap { $0 }
            return "写入许可被撤销：\(facts.isEmpty ? "尚未改动几何" : facts.joined(separator: "、"))"
                + (readBack.map { "，读回 \(RecoveryText.frame($0))" } ?? "")
        }
    }
}

public enum GeometryRejectReason: Hashable, Sendable {
    case sizeWrite(code: Int)
    case positionWrite(code: Int)
    /// 两次写入都报告成功，但写前写后完全一致而目标不同：应用根本没接受。
    case unchangedByWrite(previous: CGRect)
    /// 写前就读不到 frame：此时不得盲目写入。
    case beforeWriteUnreadable
    /// 写前的业务前提不成立（权限、事务未落盘、句柄未确定）：一次 AX 写入都没发生。
    case preconditionFailed(String)

    /// 是否已经动过窗口几何。没写过的原因不能算"改过"，否则会触发多余的补偿（方案 §6.1）。
    public var didChangeGeometry: Bool {
        switch self {
        case .sizeWrite, .positionWrite: return true
        case .unchangedByWrite, .beforeWriteUnreadable, .preconditionFailed: return false
        }
    }

    public var message: String {
        switch self {
        case let .sizeWrite(code): return "尺寸写入返回错误码 \(code)"
        case let .positionWrite(code): return "位置写入返回错误码 \(code)"
        case let .unchangedByWrite(previous): return "写前写后一致（\(RecoveryText.frame(previous))），目标未被接受"
        case .beforeWriteUnreadable: return "写入前读不到当前 frame"
        case let .preconditionFailed(reason): return reason
        }
    }
}

/// 一次几何写入完成后回报给状态机的事实。
public struct GeometryWriteResult: Hashable, Sendable {
    public let identity: WindowIdentity
    /// 写入属于哪一次过渡；令牌不再匹配时结果只能丢弃并触发补偿。
    public let token: TransitionToken
    public let operationID: UUID
    public let targetFrame: CGRect
    public let displayID: UInt32
    public let outcome: GeometryOutcome
    /// 写前真实 frame：部分写入时必须据此判断"已经改了什么"（方案 §5.2）。
    public let beforeFrame: CGRect?
    /// 写入所属操作上下文；缺上下文的回报无法判定是否属于当前操作，只能进补偿。
    public let context: GeometryOperationContext?

    public init(identity: WindowIdentity,
                token: TransitionToken,
                operationID: UUID,
                targetFrame: CGRect,
                displayID: UInt32,
                outcome: GeometryOutcome,
                beforeFrame: CGRect? = nil,
                context: GeometryOperationContext? = nil) {
        self.identity = identity
        self.token = token
        self.operationID = operationID
        self.targetFrame = targetFrame
        self.displayID = displayID
        self.outcome = outcome
        self.beforeFrame = beforeFrame
        self.context = context
    }

    /// 回报是否属于给定操作：令牌与操作标识都必须一致。
    public func matches(_ context: GeometryOperationContext?) -> Bool {
        guard let reported = self.context, let context else { return false }
        return reported.operationID == context.operationID
            && reported.matches(sessionID: context.sessionID, epoch: context.sessionEpoch)
    }

    /// 回报里是否已存在真实几何副作用（方案 §6.4：不能只用"有没有事务"推断）。
    public var didChangeGeometry: Bool { outcome.didChangeGeometry }
}

/// 外部几何变化来源。程序写入与用户拖动不能只靠一个瞬时布尔集合区分（方案 §6.5）。
public enum GeometryChangeSource: Hashable, Sendable {
    case user
    case programmatic
    /// 写入刚结束、通知延迟到达且回读结果对不上任何一方：此时不得宣称用户明确修改。
    case uncertain

    public var recordsUserOverride: Bool { self == .user }
}

/// 窗口存活事实：只有明确证据才允许判定"已消失"（方案 §6.4）。
public enum WindowLiveness: Hashable, Sendable {
    case alive
    case closedWindow
    case processExited
    /// 缺权限、AX 暂时读不到、身份歧义都属此类：不能当成窗口已消失而删除记录。
    case unknown(reason: String)

    public var isConfirmedGone: Bool {
        self == .closedWindow || self == .processExited
    }

    public init(record: WindowRecord?,
                processIsSameInstance: Bool,
                isConfirmedGone: Bool = false) {
        if !processIsSameInstance {
            self = .processExited
        } else if isConfirmedGone {
            // "确认销毁"是目录给出的事实，不是"记录没了"的猜测（方案 §8.3）。
            self = .closedWindow
        } else if record != nil {
            self = .alive
        } else {
            self = .unknown(reason: "目录中没有该窗口记录")
        }
    }

}

/// 逐条恢复结果：批次"处理完毕"与"全部恢复成功"是两件事（方案 §6.4）。
public enum RestoreOutcome: Hashable, Sendable {
    /// 读回与恢复目标在容差内一致。
    case restored
    /// 用户选择保留聚焦期间手动调整的尺寸，事务按预期结束。
    case keptUserGeometry
    /// 当前 frame 已经是原 frame，无需写入。
    case alreadyAtOriginal
    /// 原屏不可用后按回退落点结算：读回与降级目标一致。
    /// 这是"已收口但不是原始几何"，不能伪装成 restored（方案 §8）。
    case settledDegraded(readBack: CGRect, displayID: UInt32?)
    /// 已确认进程退出或窗口销毁。
    case windowGone
    /// 不擅自覆盖用户移动后的位置：事务结束，但保留诊断。
    case userMoved(current: CGRect)
    /// 应用按自身最小/最大尺寸约束返回：必须带读回值才能判断是否仍在主区（方案 §9）。
    case constrained(readBack: CGRect, deviation: Double)
    case rejected(String)
    case unreadable
    /// 权限或句柄此刻不可用：没有尝试写入，事务必须保留。
    case notAttempted(String)

    /// 是否可以从 state 与 journal 中移除该事务。
    public var isSettled: Bool {
        switch self {
        case .restored, .keptUserGeometry, .alreadyAtOriginal, .settledDegraded,
             .windowGone, .userMoved: return true
        case .constrained, .rejected, .unreadable, .notAttempted: return false
        }
    }

    public var isFailure: Bool {
        switch self {
        case .constrained, .rejected, .unreadable: return true
        case .notAttempted(let reason): return !reason.isEmpty
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .restored: return "已恢复原尺寸"
        case .keptUserGeometry: return "按设置保留用户尺寸"
        case .alreadyAtOriginal: return "窗口已在原位置"
        case let .settledDegraded(readBack, displayID):
            return "原显示不可用，已按回退落点 \(RecoveryText.frame(readBack))"
                + (displayID.map { "（显示 \($0)）" } ?? "") + "结算"
        case .windowGone: return "窗口或进程已不存在"
        case let .userMoved(current): return "窗口已被移动到 \(RecoveryText.frame(current))，未擅自覆盖"
        case let .constrained(readBack, deviation):
            return "恢复读回偏差 \(String(format: "%.1f", deviation))pt，实际 \(RecoveryText.frame(readBack))"
        case let .rejected(reason): return "恢复写入被拒绝：\(reason)"
        case .unreadable: return "恢复后无法读回 frame"
        case let .notAttempted(reason): return "未执行恢复：\(reason)"
        }
    }
}

public struct RestoreItemResult: Hashable, Sendable {
    public let identity: WindowIdentity
    public let outcome: RestoreOutcome
    public let applicationName: String

    public init(identity: WindowIdentity, outcome: RestoreOutcome, applicationName: String) {
        self.identity = identity
        self.outcome = outcome
        self.applicationName = applicationName
    }
}

/// 一批恢复处理完毕；每个窗口单独带结果。
public struct RestoreBatchResult: Hashable, Sendable {
    public let token: TransitionToken
    public let items: [RestoreItemResult]

    public init(token: TransitionToken, items: [RestoreItemResult]) {
        self.token = token
        self.items = items
    }

    public var settledIdentities: [WindowIdentity] {
        items.filter { $0.outcome.isSettled }.map(\.identity)
    }

    public var unresolvedIdentities: [WindowIdentity] {
        items.filter { !$0.outcome.isSettled }.map(\.identity)
    }

    public var hasUnresolved: Bool { items.contains { !$0.outcome.isSettled } }
}

/// 一次失败补偿里，单个身份的真实处置（方案 §6.4）。
/// 用枚举而非布尔，是为了能区分"没写过所以不用补偿"和"写了但补偿失败"。
public enum CompensationAction: Hashable, Sendable {
    /// 已写回操作前几何并读回一致。
    case restoredTo(frame: CGRect)
    /// 补偿被拒绝或读回不符：journal 必须保留。
    case refused(reason: String)
    /// 该步骤根本没写入：无需补偿。
    case notWritten
    /// 写回前就已经在操作前位置，属于已到位。
    case alreadyInPlace(frame: CGRect)

    /// 补偿是否已经把该窗口送回操作前状态。
    public var isResolved: Bool {
        switch self {
        case .restoredTo, .notWritten, .alreadyInPlace: return true
        case .refused: return false
        }
    }

    public var message: String {
        switch self {
        case let .restoredTo(frame): return "已补偿回 \(RecoveryText.frame(frame))"
        case let .refused(reason): return "补偿失败：\(reason)"
        case .notWritten: return "未写入，无需补偿"
        case let .alreadyInPlace(frame): return "已在操作前位置 \(RecoveryText.frame(frame))"
        }
    }
}

/// 一次交换失败的完整补偿回报：各身份处置 + 焦点事实。
/// reducer 只能据此判定"回滚成功"或"进入 recoveryRequired"，不接受"失败已完成"这类无事实的结论。
public struct WorkbenchCompensationResult: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public let identity: WindowIdentity
        public let action: CompensationAction
        public let displayID: UInt32?

        public init(identity: WindowIdentity, action: CompensationAction, displayID: UInt32? = nil) {
            self.identity = identity
            self.action = action
            self.displayID = displayID
        }
    }

    public let items: [Item]
    /// 补偿后真正被激活的主区窗口；nil 表示焦点未回到旧主。
    public let activatedMain: WindowIdentity?
    /// 宿主写前实读并落盘的操作前位置（与 operationID 绑定）：补偿判定的权威事实。
    /// reducer 计划期算出的 `beforeOperation` 只是推测值；外部移动过窗口之后，
    /// 用它判"补偿是否回到操作前"会把正确的补偿误判成失败（方案 §6.2、§6.4）。
    public let beforeReads: [WindowIdentity: CGRect]
    /// 本次操作解除过、但没能恢复的最小化状态（方案 §6.4、§10.1）。
    /// 非空即表示补偿没有把真实系统状态收回原样：reducer 不能宣称"回滚完成/旧主仍在主区"。
    public let unresolvedMinimizeRestorations: [WindowIdentity]

    public init(items: [Item],
                activatedMain: WindowIdentity?,
                beforeReads: [WindowIdentity: CGRect] = [:],
                unresolvedMinimizeRestorations: [WindowIdentity] = []) {
        self.items = items
        self.activatedMain = activatedMain
        self.beforeReads = beforeReads
        self.unresolvedMinimizeRestorations = unresolvedMinimizeRestorations
    }

    /// 补偿完整：每个身份都已到位、旧主确实被激活，且没有留下"解除后收不回来"的最小化副作用。
    public var isComplete: Bool {
        items.allSatisfy { $0.action.isResolved } && activatedMain != nil
            && unresolvedMinimizeRestorations.isEmpty
    }

    public var unresolvedIdentities: [WindowIdentity] {
        items.filter { !$0.action.isResolved }.map(\.identity)
    }

    public func action(for identity: WindowIdentity) -> CompensationAction? {
        items.first { $0.identity == identity }?.action
    }
}

/// 发现失败原因。成功与失败都必须清除对应的 in-flight（方案 §5.2）。
public enum DiscoveryFailure: Hashable, Sendable {
    case permissionMissing(PermissionKind)
    case contentUnavailable(String)
    case axUnavailable
    case emptyCatalog

    public var message: String {
        switch self {
        case .permissionMissing(.screenRecording): return "缺少屏幕录制权限"
        case .permissionMissing(.accessibility): return "缺少辅助功能权限"
        case let .contentUnavailable(detail): return "窗口列表查询失败：\(detail)"
        case .axUnavailable: return "辅助功能接口不可用"
        case .emptyCatalog: return "没有可用的窗口"
        }
    }

    public var hint: HintKind {
        switch self {
        case let .permissionMissing(kind): return .permissionMissing(kind)
        default: return .discoveryFailed(message)
        }
    }
}

/// 打开总览的前置条件。快捷键重新按下时必须重新检查（方案 §5.1）。
public struct OpenConditions: Hashable, Sendable {
    public var screenRecording: Bool
    public var accessibility: Bool
    /// 需要重启应用才能恢复的捕获错误：不能用一句"缺少录屏权限"糊过去。
    public var restartRequired: Bool

    public init(screenRecording: Bool, accessibility: Bool, restartRequired: Bool = false) {
        self.screenRecording = screenRecording
        self.accessibility = accessibility
        self.restartRequired = restartRequired
    }

    public var canOpen: Bool { screenRecording && accessibility && !restartRequired }

    public var blockingHint: HintKind? {
        if !screenRecording { return .permissionMissing(.screenRecording) }
        if !accessibility { return .permissionMissing(.accessibility) }
        if restartRequired { return .discoveryFailed("捕获服务已停止，需要重新启动 Vistile") }
        return nil
    }
}

enum RecoveryText {
    static func frame(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }
}
