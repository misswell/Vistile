import Foundation
import VistileCore

/// 事务日志落盘：原子写入，内容仅身份 + 几何（方案 §10.5）。
final class WindowJournalStore {
    private let url: URL
    private let queue = DispatchQueue(label: "com.misswell.Vistile.journal", qos: .utility)
    private(set) var journal: SessionJournal

    init(fileName: String = "session-journal.json", sessionID: UUID = UUID()) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = directory.appendingPathComponent("Vistile", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent(fileName)
        journal = SessionJournal(sessionID: sessionID)
        journal = Self.read(url: url) ?? SessionJournal(sessionID: sessionID)
    }

    private static func read(url: URL) -> SessionJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? SessionJournal.decode(data)
    }

    func apply(_ transaction: WindowTransaction) {
        queue.sync(flags: .barrier) {
            journal.apply(transaction)
            persist()
        }
    }

    func markRestored(_ identity: WindowIdentity) {
        queue.sync(flags: .barrier) {
            journal.markRestored(identity)
            persist()
        }
    }

    func drop(_ identity: WindowIdentity) {
        queue.sync(flags: .barrier) {
            journal.remove(identity)
            persist()
        }
    }

    /// 正常退出：全部恢复后清空，不给下次启动留悬念。
    func clear(sessionID: UUID) {
        queue.sync(flags: .barrier) {
            journal = SessionJournal(sessionID: sessionID)
            persist()
        }
    }

    var unfinished: [WindowTransaction] {
        queue.sync { journal.unfinished }
    }

    func snapshot() -> SessionJournal {
        queue.sync { journal }
    }

    /// 补记事务时用同一 sessionID，避免退出后日志里出现两个会话。
    var currentSessionID: UUID {
        queue.sync { journal.sessionID }
    }

    func entry(for identity: WindowIdentity) -> WindowTransaction? {
        queue.sync { journal.entries[identity.journalKey] }
    }

    private func persist() {
        guard let data = try? journal.encoded() else { return }
        // 原子写入：崩溃中途不会留下半个 JSON。
        try? data.write(to: url, options: [.atomic])
    }
}
