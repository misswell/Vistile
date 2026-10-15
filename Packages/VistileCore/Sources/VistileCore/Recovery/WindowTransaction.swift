import Foundation
import CoreGraphics

public enum TransactionState: String, Hashable, Sendable, Codable {
    /// 已保存原 frame，尚未写 AX。
    case prepared
    /// 已写临时 frame，等待读回。
    case written
    /// 读回值与目标一致。
    case verified
    /// 已恢复原 frame 并读回确认。
    case restored
    /// 写入或恢复失败，保留可重试记录。
    case failed

    public var requiresRestore: Bool {
        self == .written || self == .verified || self == .failed
    }
}

/// 一次临时几何修改的恢复记录。写 AX 之前必须存在（方案 §10.2）。
/// 隐私边界：只存身份、bundle id 与几何，不存标题正文和截图。
public struct WindowTransaction: Hashable, Sendable, Codable {
    public let sessionID: UUID
    public let identity: WindowIdentity
    public let bundleID: String?
    public let originalFrame: CGRect
    public let originalDisplayID: UInt32
    public var lastProvisionalFrame: CGRect?
    public var provisionalDisplayID: UInt32?
    /// 聚焦期间用户主动拖动/缩放后的尺寸（方案 §10.4）。
    public var userOverrideFrame: CGRect?
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
        self.lastProvisionalFrame = nil
        self.provisionalDisplayID = nil
        self.userOverrideFrame = nil
        self.state = .prepared
        self.restoreAttempts = 0
        self.failureReason = nil
        self.created = created
    }

    /// 同一事务不能反复覆盖原 frame，因此 begin 对已存在记录是幂等的。
    public func markingWritten(provisionalFrame: CGRect, displayID: UInt32) -> WindowTransaction {
        var copy = self
        copy.lastProvisionalFrame = provisionalFrame
        copy.provisionalDisplayID = displayID
        copy.state = .written
        return copy
    }

    public func markingVerified(readBack: CGRect, provisionalFrame: CGRect, tolerance: CGFloat) -> WindowTransaction {
        var copy = self
        copy.state = Self.framesClose(readBack, provisionalFrame, tolerance: tolerance) ? .verified : .written
        if copy.state == .written { copy.failureReason = "readback mismatch" }
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

    public func withUserOverride(_ frame: CGRect?) -> WindowTransaction {
        var copy = self
        copy.userOverrideFrame = frame
        return copy
    }

    /// 恢复目标：默认回到进入前尺寸；用户选择保留时回到手动尺寸。
    public func restoreTargetFrame(preserveUserGeometry: Bool) -> CGRect {
        if preserveUserGeometry, let override = userOverrideFrame { return override }
        return originalFrame
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

public enum JournalAction: Hashable, Sendable {
    case upsert(WindowTransaction)
    case remove(sessionID: UUID)
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
            merged.lastProvisionalFrame = transaction.lastProvisionalFrame ?? existing.lastProvisionalFrame
            merged.provisionalDisplayID = transaction.provisionalDisplayID ?? existing.provisionalDisplayID
            merged.userOverrideFrame = transaction.userOverrideFrame ?? existing.userOverrideFrame
            merged.state = transaction.state
            merged.restoreAttempts = transaction.restoreAttempts
            merged.failureReason = transaction.failureReason
            entries[transaction.journalKey] = merged
        } else {
            entries[transaction.journalKey] = transaction
        }
    }

    public mutating func markRestored(_ identity: WindowIdentity) {
        guard var entry = entries[identity.journalKey] else { return }
        entry = entry.markingRestored()
        entries[identity.journalKey] = entry
    }

    public mutating func remove(_ identity: WindowIdentity) {
        entries.removeValue(forKey: identity.journalKey)
    }

    public var unfinished: [WindowTransaction] {
        entries.values.filter { $0.state.requiresRestore }.sorted { $0.created < $1.created }
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
    case restore(to: CGRect)
    case clampAndRestore(to: CGRect)
    case skipAlreadyRestored
    case skipProcessRestarted
    case skipWindowGone
    case skipUserMoved(current: CGRect)
    case skipNeverWritten
    case skipPreserveUserGeometry(keep: CGRect)

    public var shouldWriteAX: Bool {
        switch self {
        case .restore, .clampAndRestore: return true
        default: return false
        }
    }
}

/// 下次启动的保守恢复判定：只有同一进程身份、窗口仍存活、且当前 frame 仍接近上次临时 frame 才自动恢复。
public enum RecoveryPlanner {
    public static func decide(entry: WindowTransaction,
                              currentFrame: CGRect?,
                              isWindowAlive: Bool,
                              isProcessAlive: Bool,
                              isOriginalDisplayLive: Bool,
                              clampedFrame: CGRect?,
                              preserveUserGeometry: Bool) -> RecoveryDecision {
        guard entry.state.requiresRestore else {
            return entry.state == .prepared ? .skipNeverWritten : .skipAlreadyRestored
        }
        guard isProcessAlive else { return .skipProcessRestarted }
        guard isWindowAlive else { return .skipWindowGone }
        guard let currentFrame else { return .skipWindowGone }

        if preserveUserGeometry, let override = entry.userOverrideFrame {
            return .skipPreserveUserGeometry(keep: override)
        }
        if WindowTransaction.framesClose(currentFrame, entry.originalFrame, tolerance: 2) {
            return .skipAlreadyRestored
        }
        guard let provisional = entry.lastProvisionalFrame else {
            return .skipUserMoved(current: currentFrame)
        }
        // 4pt 容差：接近上次写入的临时 frame 才认为"没有被人动过"。
        guard WindowTransaction.framesClose(currentFrame, provisional, tolerance: 4) else {
            return .skipUserMoved(current: currentFrame)
        }
        if isOriginalDisplayLive {
            return .restore(to: entry.originalFrame)
        }
        guard let clampedFrame else { return .skipUserMoved(current: currentFrame) }
        return .clampAndRestore(to: clampedFrame)
    }
}
