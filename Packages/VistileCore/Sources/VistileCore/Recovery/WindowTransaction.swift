import Foundation
import CoreGraphics

public enum TransactionState: String, Hashable, Sendable, Codable {
    /// 已保存原 frame，尚未计划修改。
    case prepared
    /// 修改意图已落盘，AX 写入尚未确认：崩溃在这里也必须按保守策略核对（方案 §6.2）。
    case mutationPlanned
    /// 已写临时 frame，等待读回。
    case written
    /// 读回值与目标一致。
    case verified
    /// 已恢复原 frame 并读回确认。
    case restored
    /// 写入或恢复失败，保留可重试记录。
    case failed

    public var requiresRestore: Bool {
        self == .mutationPlanned || self == .written || self == .verified || self == .failed
    }

    /// 计划已写入但结果未知：恢复前必须先读当前 frame 再判断。
    public var needsConservativeCheck: Bool { self == .mutationPlanned }
}

/// 一次临时几何修改的恢复记录。写 AX 之前必须存在（方案 §10.2）。
/// 隐私边界：只存身份、bundle id 与几何，不存标题正文和截图。
public struct WindowTransaction: Hashable, Sendable {
    public let sessionID: UUID
    public let identity: WindowIdentity
    public let bundleID: String?
    /// 原位置。创建时来自目录快照，是**推测值**；首个写入前的实读可以纠一次
    /// （`withCorrectedOriginal`），此后不再改变（方案 §6.2）。
    public internal(set) var originalFrame: CGRect
    public internal(set) var originalDisplayID: UInt32
    /// 准备写入的目标 frame。落盘早于任何 AX 写入，崩溃后才知道"本来要改成什么"。
    public var plannedFrame: CGRect?
    public var plannedDisplayID: UInt32?
    public var lastProvisionalFrame: CGRect?
    public var provisionalDisplayID: UInt32?
    /// 聚焦期间用户主动拖动/缩放后的尺寸（方案 §10.4）。
    public var userOverrideFrame: CGRect?
    /// 本次操作的**写入前实读**（方案 §6.2）：与 `originalFrame` 是两个独立事实。
    /// 会话 original 用于最终退出；操作 before 用于此次失败补偿，可以是 A 当前所在的主区位置。
    public var operationBeforeFrame: CGRect?
    public var operationBeforeDisplayID: UInt32?
    /// 这些 before 事实属于哪一次操作：迟到回执与补偿必须能对上。
    public var operationID: UUID?
    public var state: TransactionState
    public var restoreAttempts: Int
    public var failureReason: String?
    public let created: Date

    public init(sessionID: UUID,
                identity: WindowIdentity,
                bundleID: String?,
                originalFrame: CGRect,
                originalDisplayID: UInt32,
                created: Date = Date()) {
        self.sessionID = sessionID
        self.identity = identity
        self.bundleID = bundleID
        self.originalFrame = originalFrame
        self.originalDisplayID = originalDisplayID
        self.plannedFrame = nil
        self.plannedDisplayID = nil
        self.lastProvisionalFrame = nil
        self.provisionalDisplayID = nil
        self.userOverrideFrame = nil
        self.operationBeforeFrame = nil
        self.operationBeforeDisplayID = nil
        self.operationID = nil
        self.state = .prepared
        self.restoreAttempts = 0
        self.failureReason = nil
        self.created = created
    }

    /// 同一事务不能反复覆盖原 frame，因此 begin 对已存在记录是幂等的。
    /// 计划修改：在第一次 AX 写入之前持久化。
    public func markingPlanned(frame: CGRect, displayID: UInt32) -> WindowTransaction {
        var copy = self
        copy.plannedFrame = frame
        copy.plannedDisplayID = displayID
        copy.state = .mutationPlanned
        copy.failureReason = nil
        return copy
    }

    /// 已写入（读回可能仍为 nil）：事务确定需要恢复。
    public func markingWritten(readBack: CGRect?, displayID: UInt32, note: String? = nil) -> WindowTransaction {
        var copy = self
        copy.lastProvisionalFrame = readBack ?? copy.plannedFrame
        copy.provisionalDisplayID = displayID
        copy.state = .written
        copy.failureReason = note
        return copy
    }

    /// 读回与目标在容差内一致。
    public func markingVerified(readBack: CGRect, displayID: UInt32) -> WindowTransaction {
        var copy = self
        copy.lastProvisionalFrame = readBack
        copy.provisionalDisplayID = displayID
        copy.state = .verified
        copy.failureReason = nil
        return copy
    }

    public func markingRestored() -> WindowTransaction {
        var copy = self
        copy.state = .restored
        copy.failureReason = nil
        return copy
    }

    public func markingFailed(_ reason: String) -> WindowTransaction {
        var copy = self
        copy.state = .failed
        copy.failureReason = reason
        copy.restoreAttempts += 1
        return copy
    }

    /// 写入阶段失败：不消耗恢复重试次数，但事务仍需恢复。
    /// `observedFrame` 是这次尝试的真实读回。有读回就记读回——它是"窗口到底动没动"的唯一依据（方案 §6.4）；
    /// 读不到才退回计划值，表示结果未知，恢复必须保守核对。
    public func markingWriteFailed(_ reason: String, observedFrame: CGRect? = nil) -> WindowTransaction {
        var copy = self
        copy.state = .failed
        copy.failureReason = reason
        copy.lastProvisionalFrame = observedFrame ?? copy.lastProvisionalFrame ?? copy.plannedFrame
        return copy
    }

    /// 事务结束：不写 AX 的确定结论（已在原位、窗口已消失、用户移动过、按设置保留）。
    public func markingSettled(_ outcome: RestoreOutcome) -> WindowTransaction {
        var copy = self
        copy.state = .restored
        copy.failureReason = outcome.isFailure ? outcome.message : nil
        return copy
    }

    public func withUserOverride(_ frame: CGRect?) -> WindowTransaction {
        var copy = self
        copy.userOverrideFrame = frame
        return copy
    }

    /// 原位置仍是推测值：事务创建后从未尝试过写入。目录快照在快速往返里可能落后一整轮，
    /// 把上一轮的位置当成原位置——返回时"已在原位置"直接跳过，窗口被永久留在主区。
    public var hasSpeculativeOriginal: Bool {
        state == .mutationPlanned && lastProvisionalFrame == nil
    }

    /// 首个写入前的实读修正：把推测的原位置换成写前真实读到的位置。
    /// 只允许对从未写过的事务调用；其它状态原样返回（写过的原位置已经过读回验证，不再改写）。
    public func withCorrectedOriginal(frame: CGRect, displayID: UInt32) -> WindowTransaction {
        guard hasSpeculativeOriginal else { return self }
        var copy = self
        copy.originalFrame = frame
        copy.originalDisplayID = displayID
        return copy
    }

    /// 记下本次操作的写入前实读（方案 §6.2）。会话 original 一个字节都不动：
    /// 不能为了回滚 A 而改写 journal.originalFrame。
    public func markingOperationBefore(frame: CGRect?,
                                       displayID: UInt32?,
                                       operationID: UUID) -> WindowTransaction {
        var copy = self
        copy.operationBeforeFrame = frame
        copy.operationBeforeDisplayID = displayID
        copy.operationID = operationID
        return copy
    }

    /// 有操作前快照才有补偿依据；缺它时失败只能转入显式恢复状态（方案 §6.4）。
    public var hasOperationBefore: Bool { operationBeforeFrame != nil }

    /// 恢复目标：默认回到进入前尺寸；用户选择保留时回到手动尺寸。
    /// 这是**会话退出**的唯一目标，补偿路径不得借用（方案 §6.2）。
    public func restoreTargetFrame(preserveUserGeometry: Bool) -> CGRect {
        if preserveUserGeometry, let override = userOverrideFrame { return override }
        return originalFrame
    }

    /// 操作补偿的目标：回到本操作写入前的实际位置；没有快照时才退回会话 original。
    public func compensationTargetFrame() -> CGRect? {
        operationBeforeFrame ?? originalFrame
    }

    /// 用于判断"当前 frame 是否还是我们上次写的那个"的所有候选值。
    public var writtenFrameCandidates: [CGRect] {
        [lastProvisionalFrame, plannedFrame].compactMap { $0 }
    }

    public static func framesClose(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }

    public var journalKey: String {
        "\(identity.processID):\(identity.processStartIdentity):\(identity.windowID)"
    }
}

extension WindowTransaction: Codable {
    private enum CodingKeys: String, CodingKey {
        case sessionID, identity, bundleID, originalFrame, originalDisplayID
        case plannedFrame, plannedDisplayID, lastProvisionalFrame, provisionalDisplayID
        case userOverrideFrame, state, restoreAttempts, failureReason, created
        case operationBeforeFrame, operationBeforeDisplayID, operationID
    }

    /// 旧日志没有 plannedFrame 等新字段时按缺省兼容；无法识别的旧状态走保守路径，
    /// 不能解码失败后悄悄当成空日志（方案 §6.2）。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        identity = try container.decode(WindowIdentity.self, forKey: .identity)
        bundleID = try container.decodeIfPresent(String.self, forKey: .bundleID)
        originalFrame = try container.decode(CGRect.self, forKey: .originalFrame)
        originalDisplayID = try container.decode(UInt32.self, forKey: .originalDisplayID)
        plannedFrame = try container.decodeIfPresent(CGRect.self, forKey: .plannedFrame)
        plannedDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .plannedDisplayID)
        lastProvisionalFrame = try container.decodeIfPresent(CGRect.self, forKey: .lastProvisionalFrame)
        provisionalDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .provisionalDisplayID)
        userOverrideFrame = try container.decodeIfPresent(CGRect.self, forKey: .userOverrideFrame)
        // 老版本日志没有操作快照：按会话原位置安全恢复即可，不得解码失败（方案 §6.2）。
        operationBeforeFrame = try container.decodeIfPresent(CGRect.self, forKey: .operationBeforeFrame)
        operationBeforeDisplayID = try container.decodeIfPresent(UInt32.self, forKey: .operationBeforeDisplayID)
        operationID = try container.decodeIfPresent(UUID.self, forKey: .operationID)
        restoreAttempts = try container.decodeIfPresent(Int.self, forKey: .restoreAttempts) ?? 0
        let rawState = try container.decodeIfPresent(String.self, forKey: .state)
        let storedReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
        if let rawState, let known = TransactionState(rawValue: rawState) {
            state = known
            failureReason = storedReason
        } else {
            state = .failed
            failureReason = storedReason ?? "日志状态无法识别，按需要恢复处理"
        }
        created = try container.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

public enum JournalAction: Hashable, Sendable {
    case upsert(WindowTransaction)
    case remove(sessionID: UUID)
}

/// 一次操作需要的日志变更（方案 §7.1）。批量 prepare 要么整体落盘、要么整体不落盘，
/// 不允许出现"B 已持久化、A 失败却卡住"的中间业务状态。
public enum JournalMutation: Hashable, Sendable {
    case upsert(WindowTransaction)
    case remove(WindowIdentity)
    /// 写前实读纠正推测原位置：纠正失败必须拒绝本次写入（方案 §7.3）。
    case correctOriginal(WindowIdentity, frame: CGRect, displayID: UInt32)
}

/// 异步 prepare 请求：宿主持久化成功后回报 journalPrepared(context)。
/// 上下文是唯一的身份判据——会话、代次、操作、过渡令牌、操作类型必须整体对上，
/// 旧会话迟到的成功回执不得启动新会话的写入（方案 §7.1、§7.5）。
public struct JournalPrepareRequest: Hashable, Sendable, Identifiable {
    public let context: GeometryOperationContext
    public let mutations: [JournalMutation]
    /// 受影响窗口：prepare 失败时 reducer 按它收口，不能只看一个 controlledTarget。
    public let affectedIdentities: [WindowIdentity]

    public init(context: GeometryOperationContext,
                mutations: [JournalMutation],
                affectedIdentities: [WindowIdentity]) {
        self.context = context
        self.mutations = mutations
        self.affectedIdentities = affectedIdentities
    }

    public var id: UUID { context.operationID }
    public var sessionID: UUID { context.sessionID }
    public var operationID: UUID { context.operationID }
    public var transitionToken: TransitionToken { context.transitionToken }
}

/// 真实写入之后追加的日志更新（读回事实、纠正 observed frame）。
/// 它失败说明"确实写过"，只能触发操作补偿，不能按未写入处理（方案 §7.2）。
public struct JournalUpdateRequest: Hashable, Sendable {
    /// 属于哪一次操作；nil 只用于工作台之外的旧展开路径（那里没有操作级补偿）。
    public let operationID: UUID?
    public let identity: WindowIdentity
    public let mutation: JournalMutation

    public init(operationID: UUID? = nil, identity: WindowIdentity, mutation: JournalMutation) {
        self.operationID = operationID
        self.identity = identity
        self.mutation = mutation
    }
}

/// 崩溃恢复用的事务日志（方案 §10.5）。原子写入由宿主完成，这里只负责内容与判定。
public struct SessionJournal: Hashable, Sendable, Codable {
    public var entries: [String: WindowTransaction]
    public var sessionID: UUID

    public init(sessionID: UUID, entries: [String: WindowTransaction] = [:]) {
        self.sessionID = sessionID
        self.entries = entries
    }

    public mutating func apply(_ transaction: WindowTransaction) {
        // 幂等：已有同身份记录时只更新状态字段，绝不覆盖 originalFrame。
        if let existing = entries[transaction.journalKey] {
            var merged = existing
            merged.plannedFrame = transaction.plannedFrame ?? existing.plannedFrame
            merged.plannedDisplayID = transaction.plannedDisplayID ?? existing.plannedDisplayID
            merged.lastProvisionalFrame = transaction.lastProvisionalFrame ?? existing.lastProvisionalFrame
            merged.provisionalDisplayID = transaction.provisionalDisplayID ?? existing.provisionalDisplayID
            merged.userOverrideFrame = transaction.userOverrideFrame ?? existing.userOverrideFrame
            // 补偿依据同样只增不替：一条"只更新了状态"的记录不得把操作前快照抹成 nil（方案 §6.2）。
            merged.operationBeforeFrame = transaction.operationBeforeFrame ?? existing.operationBeforeFrame
            merged.operationBeforeDisplayID = transaction.operationBeforeDisplayID ?? existing.operationBeforeDisplayID
            merged.operationID = transaction.operationID ?? existing.operationID
            merged.state = transaction.state
            merged.restoreAttempts = transaction.restoreAttempts
            merged.failureReason = transaction.failureReason
            entries[transaction.journalKey] = merged
        } else {
            entries[transaction.journalKey] = transaction
        }
    }

    /// 原子批量应用（方案 §7.1）：先在副本上算完，任何一条不成立就整体不生效。
    /// 宿主的持久化服务用它替换内存快照，半套批次不可能存在。
    @discardableResult
    public mutating func applying(_ mutations: [JournalMutation]) -> Bool {
        var copy = self
        for mutation in mutations {
            switch mutation {
            case let .upsert(transaction):
                copy.apply(transaction)
            case let .remove(identity):
                copy.remove(identity)
            case let .correctOriginal(identity, frame, displayID):
                guard let entry = copy.entries[identity.journalKey], entry.hasSpeculativeOriginal else { return false }
                copy.entries[identity.journalKey] = entry.withCorrectedOriginal(frame: frame, displayID: displayID)
            }
        }
        self = copy
        return true
    }

    public mutating func markRestored(_ identity: WindowIdentity) {
        guard var entry = entries[identity.journalKey] else { return }
        entry = entry.markingRestored()
        entries[identity.journalKey] = entry
    }

    /// 写前实读纠正推测的原位置。这是 apply 合并规则（"绝不覆盖原 frame"）之外
    /// 唯一允许改写 originalFrame 的入口，只对从未写过的事务生效（方案 §6.2）。
    public mutating func correctOriginal(_ identity: WindowIdentity, frame: CGRect, displayID: UInt32) {
        guard let entry = entries[identity.journalKey], entry.hasSpeculativeOriginal else { return }
        entries[identity.journalKey] = entry.withCorrectedOriginal(frame: frame, displayID: displayID)
    }

    public mutating func remove(_ identity: WindowIdentity) {
        entries.removeValue(forKey: identity.journalKey)
    }

    public var unfinished: [WindowTransaction] {
        entries.values.filter { $0.state.requiresRestore }.sorted { $0.created < $1.created }
    }

    /// 只清指定会话中"已经结束"的条目：其他会话的未完成记录必须留下（方案 §6.4）。
    public mutating func prune(sessionID: UUID, settledIdentities: [WindowIdentity]) {
        for identity in settledIdentities {
            guard let entry = entries[identity.journalKey], entry.sessionID == sessionID else { continue }
            guard !entry.state.requiresRestore else { continue }
            entries.removeValue(forKey: identity.journalKey)
        }
    }

    /// 会话内仍待恢复的身份，供退出兜底与诊断使用。
    public func unfinishedIdentities(sessionID: UUID) -> [WindowIdentity] {
        entries.values.filter { $0.sessionID == sessionID && $0.state.requiresRestore }
            .map(\.identity)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SessionJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionJournal.self, from: data)
    }
}

public enum RecoveryDecision: Hashable, Sendable {
    /// 按规划好的唯一落点写回：原因说明这是精确原屏、原屏内夹取，还是原屏消失后的备用屏。
    case restore(to: RestoreDestination)
    /// 原屏已消失、窗口已在合法备用位且无需写入：这是降级结果，不是"已按原样恢复"（方案 §8）。
    case settleDegraded(destination: RestoreDestination)
    case skipAlreadyRestored
    case skipProcessRestarted
    case skipWindowGone
    case skipUserMoved(current: CGRect)
    case skipNeverWritten
    case skipPreserveUserGeometry(keep: CGRect)
    /// 事实不足（权限缺失、句柄暂不可读、身份歧义）：不写入、不删记录、保留事务（方案 §6.4）。
    case deferRestore(reason: String)

    public var shouldWriteAX: Bool {
        if case .restore = self { return true }
        return false
    }

    /// 不写 AX 时的确定性结论；需要写入的由读回结果决定。
    public var settledOutcome: RestoreOutcome? {
        switch self {
        case .restore: return nil
        case let .settleDegraded(destination):
            return .settledDegraded(readBack: destination.targetFrame, displayID: destination.targetDisplayID)
        case .skipAlreadyRestored, .skipNeverWritten: return .alreadyAtOriginal
        case .skipProcessRestarted, .skipWindowGone: return .windowGone
        case let .skipUserMoved(current): return .userMoved(current: current)
        case .skipPreserveUserGeometry: return .keptUserGeometry
        case let .deferRestore(reason): return .notAttempted(reason)
        }
    }

    public var frame: CGRect? {
        switch self {
        case let .restore(to: destination), let .settleDegraded(destination: destination):
            return destination.targetFrame
        case let .skipPreserveUserGeometry(keep: keep): return keep
        default: return nil
        }
    }
}

/// 保守恢复判定：收回、退出、崩溃恢复共用同一套规则（方案 §6.5）。
/// 只有同一进程身份、窗口确认存活、且当前 frame 仍接近"计划写入/实际写入"的值才自动恢复。
/// 落点由 `RestorePlanner` 一次算好传入：这里不再按当前所在屏二次夹取（方案 §8）。
public enum RecoveryPlanner {
    /// 自动重试上限：达到后停止擅自写入，但原始恢复信息必须保留（方案 §6.4）。
    public static let autoRestoreAttemptLimit = 3

    public static func decide(entry: WindowTransaction,
                              currentFrame: CGRect?,
                              liveness: WindowLiveness,
                              destination: RestoreDestination?,
                              preserveUserGeometry: Bool) -> RecoveryDecision {
        guard entry.state.requiresRestore else {
            return entry.state == .prepared ? .skipNeverWritten : .skipAlreadyRestored
        }
        guard entry.restoreAttempts < autoRestoreAttemptLimit else {
            return .deferRestore(reason: "自动恢复已尝试 \(entry.restoreAttempts) 次仍未成功，需人工处理或明确放弃")
        }
        switch liveness {
        case .processExited: return .skipProcessRestarted
        case .closedWindow: return .skipWindowGone
        case let .unknown(reason): return .deferRestore(reason: reason)
        case .alive: break
        }
        guard let currentFrame else {
            return .deferRestore(reason: "窗口确认存活但当前 frame 读不到")
        }

        if preserveUserGeometry, let override = entry.userOverrideFrame {
            return .skipPreserveUserGeometry(keep: override)
        }
        if WindowTransaction.framesClose(currentFrame, entry.originalFrame, tolerance: 2) {
            return .skipAlreadyRestored
        }
        guard let destination else {
            return .deferRestore(reason: "原始屏与备用屏都读不到可用区，无法确定恢复落点")
        }
        // 已经在规划落点上：降级落点要说清"这是备用屏的结果"，不能报成精确恢复（方案 §8）。
        if WindowTransaction.framesClose(currentFrame, destination.targetFrame, tolerance: 2) {
            return destination.isDowngraded ? .settleDegraded(destination: destination) : .skipAlreadyRestored
        }
        // planned 状态还没有读回值：用"计划写入的 frame"作为同样合法的判据。
        let candidates = entry.writtenFrameCandidates
        guard !candidates.isEmpty else {
            return .skipUserMoved(current: currentFrame)
        }
        // 4pt 容差：接近计划/实际写入的 frame 才认为"没有被人动过"。
        guard candidates.contains(where: { WindowTransaction.framesClose(currentFrame, $0, tolerance: 4) }) else {
            return .skipUserMoved(current: currentFrame)
        }
        return .restore(to: destination)
    }
}
