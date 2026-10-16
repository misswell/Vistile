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

    public var readBackFrame: CGRect? {
        switch self {
        case let .exact(frame), let .constrained(frame): return frame
        default: return nil
        }
    }

    /// 展开阶段允许继续正常使用：exact，或有证据的 constrained（改用实际读回值做展示目标）。
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
    public var didChangeGeometry: Bool {
        switch self {
        case .exact, .constrained: return true
        case .rejected(let reason):
            if case .unchangedByWrite = reason { return false }
            return true
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

    public var message: String {
        switch self {
        case let .sizeWrite(code): return "尺寸写入返回错误码 \(code)"
        case let .positionWrite(code): return "位置写入返回错误码 \(code)"
        case let .unchangedByWrite(previous): return "写前写后一致（\(RecoveryText.frame(previous))），目标未被接受"
        case .beforeWriteUnreadable: return "写入前读不到当前 frame"
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

    public init(identity: WindowIdentity,
                token: TransitionToken,
                operationID: UUID,
                targetFrame: CGRect,
                displayID: UInt32,
                outcome: GeometryOutcome) {
        self.identity = identity
        self.token = token
        self.operationID = operationID
        self.targetFrame = targetFrame
        self.displayID = displayID
        self.outcome = outcome
    }
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

    public init(record: WindowRecord?, processIsSameInstance: Bool) {
        if !processIsSameInstance {
            self = .processExited
        } else if let record {
            self = record.capture == .closed ? .closedWindow : .alive
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
    /// 已确认进程退出或窗口销毁。
    case windowGone
    /// 不擅自覆盖用户移动后的位置：事务结束，但保留诊断。
    case userMoved(current: CGRect)
    case constrained(deviation: Double)
    case rejected(String)
    case unreadable
    /// 权限或句柄此刻不可用：没有尝试写入，事务必须保留。
    case notAttempted(String)

    /// 是否可以从 state 与 journal 中移除该事务。
    public var isSettled: Bool {
        switch self {
        case .restored, .keptUserGeometry, .alreadyAtOriginal, .windowGone, .userMoved: return true
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
        case .windowGone: return "窗口或进程已不存在"
        case let .userMoved(current): return "窗口已被移动到 \(RecoveryText.frame(current))，未擅自覆盖"
        case let .constrained(deviation): return "恢复读回偏差 \(String(format: "%.1f", deviation))pt"
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
