import Foundation
import VistileCore

/// 日志落盘的事实：函数返回不等于已经可恢复。失败原因要能显示给用户（方案 §6.2）。
enum JournalWrite: Equatable {
    case persisted
    case failed(reason: String)

    var isPersisted: Bool { self == .persisted }
    var reason: String? { if case let .failed(reason) = self { return reason }; return nil }
}

/// 事务日志落盘：原子写入，内容仅身份 + 几何（方案 §10.5）。
/// 读不回得来的日志不当成空日志：损坏文件先留档，再把问题暴露出来。
final class WindowJournalStore {
    private let url: URL
    private let queue = DispatchQueue(label: "com.misswell.Vistile.journal", qos: .utility)
    private(set) var journal: SessionJournal
    /// 启动时读取失败的原因；nil 表示没有历史文件或已成功读取。
    private(set) var loadIssue: String?

    init(fileName: String = "session-journal.json",
         sessionID: UUID = UUID(),
         baseDirectory: URL? = nil) {
        let directory = baseDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = directory.appendingPathComponent("Vistile", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            loadIssue = "日志目录无法创建：\(error.localizedDescription)"
        }
        url = root.appendingPathComponent(fileName)
        switch Self.read(url: url) {
        case .loaded(let loaded): journal = loaded
        case .noFile: journal = SessionJournal(sessionID: sessionID)
        case let .unreadable(reason, _):
            loadIssue = reason
            journal = SessionJournal(sessionID: sessionID)
        }
    }

    /// 读取结果：只有"没有文件"才是空日志；解析失败保留原文并给出原因。
    private enum LoadResult {
        case loaded(SessionJournal)
        case noFile
        case unreadable(reason: String, archivedTo: URL)
    }

    private static func read(url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable(reason: "事务日志存在但读不出来，按空日志启动会丢失待恢复事务", archivedTo: url)
        }
        do {
            return .loaded(try SessionJournal.decode(data))
        } catch {
            let archived = archiveCorrupt(url)
            return .unreadable(reason: "事务日志无法解析（\(error.localizedDescription)），原文已留档到 \(archived.lastPathComponent)",
                               archivedTo: archived)
        }
    }

    private static func archiveCorrupt(_ url: URL) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.appendingPathExtension("corrupt-\(stamp)")
        try? FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// 内存与磁盘必须一致：落盘失败时回滚，否则 entry(for:) 会假装"已经记下"，
    /// 让"写前必须有可靠记录"这条不变量只在调用方记得检查结果时才成立（方案 §6.2）。
    @discardableResult
    func apply(_ transaction: WindowTransaction) -> JournalWrite {
        mutate { journal.apply(transaction) }
    }

    @discardableResult
    func markRestored(_ identity: WindowIdentity) -> JournalWrite {
        mutate { journal.markRestored(identity) }
    }

    @discardableResult
    func drop(_ identity: WindowIdentity) -> JournalWrite {
        mutate { journal.remove(identity) }
    }

    /// 只清指定会话中已经结束的条目：其他会话、以及本会话未完成/失败过的记录必须留下（方案 §6.4）。
    @discardableResult
    func clearSettled(sessionID: UUID, settledIdentities: [WindowIdentity]) -> JournalWrite {
        mutate { journal.prune(sessionID: sessionID, settledIdentities: settledIdentities) }
    }

    private func mutate(_ change: () -> Void) -> JournalWrite {
        queue.sync(flags: .barrier) {
            let previous = journal
            change()
            let result = persist()
            if !result.isPersisted { journal = previous }
            return result
        }
    }

    func settledIdentities(sessionID: UUID) -> [WindowIdentity] {
        queue.sync {
            journal.entries.values.filter { $0.sessionID == sessionID && !$0.state.requiresRestore }.map(\.identity)
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

    private func persist() -> JournalWrite {
        do {
            let data = try journal.encoded()
            // 原子写入：崩溃中途不会留下半个 JSON。
            try data.write(to: url, options: [.atomic])
            return .persisted
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}
