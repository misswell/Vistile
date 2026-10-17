import Foundation
import VistileCore

/// 日志落盘的事实：函数返回不等于已经可恢复。失败原因要能显示给用户（方案 §6.2）。
enum JournalWrite: Equatable {
    case persisted
    case failed(reason: String)

    var isPersisted: Bool { self == .persisted }
    var reason: String? { if case let .failed(reason) = self { return reason }; return nil }
}

/// 日志整份落盘的接缝（方案 §15.1）：生产实现仍走宿主自己的串行 queue 做原子写；
/// 测试注入可控实现，确定性构造"某批失败、某批阻塞"，不必碰真实磁盘故障也不必赌时序。
protocol JournalDiskWriting {
    /// 把整份日志 JSON 原子写入 `url`。`.failed` 表示本批没有落盘，调用方不得提交。
    func writeJournal(_ data: Data, to url: URL) async -> JournalWrite
}

/// 生产落盘实现：与原来完全一致——同一个串行 queue、原子写入，崩溃中途不留半个 JSON。
struct SerialQueueJournalWriter: JournalDiskWriting {
    let queue: DispatchQueue

    func writeJournal(_ data: Data, to url: URL) async -> JournalWrite {
        await withCheckedContinuation { (continuation: CheckedContinuation<JournalWrite, Never>) in
            queue.async {
                do {
                    try data.write(to: url, options: [.atomic])
                    continuation.resume(returning: .persisted)
                } catch {
                    continuation.resume(returning: .failed(reason: error.localizedDescription))
                }
            }
        }
    }
}

/// 事务日志落盘服务（方案 §7、§6.2、§6.4）。
///
/// 三条不变量：
/// 1. 主线程不等磁盘：同步读只读锁内已提交快照，落盘一律走异步串行通道。
///    唯一允许的同步 IO 是启动那一次读取——不读就没法判断"有没有待恢复事务"。
/// 2. 批次原子：`prepare` 一次提交一组变更；任一变更失败或落盘失败，内存与文件都还是提交前的内容。
///    取快照 → 应用 → 编码 → 落盘 → 提交整段在同一个串行事务里，同一时刻只有一批在途，
///    后一批必然基于前一批提交后的快照，失败批次不会把后来批次的内容抹掉。
/// 3. 内存与磁盘一致：没落盘成功的变更不会出现在同步读结果里，
///    调用方不能拿着"以为记下了"的 entry 去宣称"写前有可靠记录"。
final class WindowJournalStore {

    /// 几何已恢复但日志没清理掉的事实：留档，下次启动继续核对（方案 §7.4）。
    struct SettlementMarker: Equatable, Codable {
        let journalKey: String
        let identity: WindowIdentity
        let reason: String
    }

    /// 提交序号：每次成功落盘 +1。后置写入可带着自己看到的序号，
    /// 对不上说明日志已被别的流程改过（例如回滚已删条目），必须拒绝而不是盲写。
    /// 加锁读取：外部会在任意线程读它，普通 stored property 会构成数据竞争。
    var revision: UInt64 { withLock { revisionValue } }
    private var revisionValue: UInt64 = 0

    private let url: URL
    private let backlogURL: URL
    private let queue: DispatchQueue
    private let journalWriter: JournalDiskWriting
    private let lock = NSLock()
    /// 已提交（= 磁盘内容）快照；同步读走它，不等磁盘。
    /// 它只在整批落盘成功之后、持有通道时被整体替换，是唯一提交点。
    private var committed: SessionJournal
    private var backlog: [SettlementMarker] = []
    /// 落盘串行通道（FIFO 异步互斥）：一个完整的日志事务独占通道，
    /// 同一时刻只有一批在途，否则旧快照会覆盖新快照。
    private var holdingChannel = false
    private var channelWaiters: [CheckedContinuation<Void, Never>] = []
    /// 启动时读取失败的原因；nil 表示没有历史文件或已成功读取。
    private(set) var loadIssue: String?

    init(fileName: String = "session-journal.json",
         sessionID: UUID = UUID(),
         baseDirectory: URL? = nil,
         journalWriter: JournalDiskWriting? = nil) {
        let diskQueue = DispatchQueue(label: "com.misswell.Vistile.journal.disk", qos: .utility)
        queue = diskQueue
        self.journalWriter = journalWriter ?? SerialQueueJournalWriter(queue: diskQueue)
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
        backlogURL = root.appendingPathComponent((fileName as NSString).deletingPathExtension
                                                 + "-settlement-backlog.json")
        switch Self.read(url: url) {
        case .loaded(let loaded):
            committed = loaded
        case .noFile:
            committed = SessionJournal(sessionID: sessionID)
        case let .unreadable(reason, _):
            // 读不回得来的日志不当成空日志：待恢复事务继续按未完成处理。
            loadIssue = reason
            committed = SessionJournal(sessionID: sessionID)
        }
        backlog = Self.readBacklog(url: backlogURL)
    }

    // MARK: - 同步读（只读已提交快照）

    /// 已提交的不可变读快照：主线程可以直接取，不会等磁盘。
    var snapshot: SessionJournal { withLock { committed } }

    var unfinished: [WindowTransaction] { withLock { committed.unfinished } }

    func entry(for identity: WindowIdentity) -> WindowTransaction? {
        withLock { committed.entries[identity.journalKey] }
    }

    /// 补记事务时用同一 sessionID，避免退出后日志里出现两个会话。
    var currentSessionID: UUID { withLock { committed.sessionID } }

    func settledIdentities(sessionID: UUID) -> [WindowIdentity] {
        withLock {
            committed.entries.values.filter { $0.sessionID == sessionID && !$0.state.requiresRestore }
                .map(\.identity)
        }
    }

    var settlementBacklog: [SettlementMarker] { withLock { backlog } }

    /// 诊断/测试用：当前排在落盘通道外等待的批次数（不含正在落盘的那一批）。
    /// 生产路径不读它；宿主测试用它确定性地等到后续批次已经入队/暂存，再放行前一批的落盘。
    var pendingBatchCount: Int { withLock { channelWaiters.count } }

    // MARK: - 异步写

    /// 写几何之前必须成功的原子批次（方案 §7.2）。
    /// 失败 = 内存与文件都还是上一份提交内容，调用方据此拒绝写入。
    func prepare(_ request: JournalPrepareRequest) async -> JournalWrite {
        await mutate({ journal in
            for mutation in request.mutations {
                if let reason = Self.apply(mutation, to: &journal) {
                    return .rejected(reason: reason)
                }
            }
            return .accept
        }, label: "prepare \(request.operationID.uuidString.prefix(8))")
    }

    /// 单条后置更新：写后记账、纠正原位置。带序号守卫时能拒绝过期写入。
    func update(_ request: JournalUpdateRequest, expectedRevision: UInt64? = nil) async -> JournalWrite {
        await mutate({ journal in
            if let reason = Self.apply(request.mutation, to: &journal) {
                return .rejected(reason: reason)
            }
            return .accept
        }, label: "update \(request.operationID?.uuidString.prefix(8) ?? "-")",
           expectedRevision: expectedRevision)
    }

    /// 多条后置更新合成**一次**原子落盘（方案 §7.3）：写前实读既要纠正推测原位置、
    /// 又要记下本次操作的 before 快照，两件事必须同批成功/同批失败，
    /// 且不能因此多花一次磁盘往返。任一条不成立则整批作废，调用方据此拒绝写入。
    func update(_ request: JournalUpdateRequest,
                additional mutations: [JournalMutation],
                expectedRevision: UInt64? = nil) async -> JournalWrite {
        await mutate({ journal in
            if let reason = Self.apply(request.mutation, to: &journal) {
                return .rejected(reason: reason)
            }
            for mutation in mutations {
                if let reason = Self.apply(mutation, to: &journal) {
                    return .rejected(reason: reason)
                }
            }
            return .accept
        }, label: "update+\(mutations.count) \(request.operationID?.uuidString.prefix(8) ?? "-")",
           expectedRevision: expectedRevision)
    }

    /// 测试与旧路径用的单条补记：写几何前的一批事务请走 `prepare`，那里失败必须挡住写入。
    @discardableResult
    func apply(_ transaction: WindowTransaction, expectedRevision: UInt64? = nil) async -> JournalWrite {
        await mutate({ journal in
            journal.apply(transaction)
            return .accept
        }, label: "upsert \(transaction.identity)", expectedRevision: expectedRevision)
    }

    /// 恢复成功后的收尾：调用方必须检查结果（方案 §7.4）。
    /// 条目不存在或状态不允许收尾时返回失败，绝不静默当作已清理。
    func markRestored(_ identity: WindowIdentity, expectedRevision: UInt64? = nil) async -> JournalWrite {
        await mutate({ journal in
            guard journal.entries[identity.journalKey] != nil else {
                return .rejected(reason: "日志里没有该事务，无法记为已恢复：\(identity)")
            }
            journal.markRestored(identity)
            // 记完之后仍然要求恢复 = 这次收尾没起作用。
            if journal.entries[identity.journalKey]?.state.requiresRestore == true {
                return .rejected(reason: "事务状态无法从 \(String(describing: journal.entries[identity.journalKey]?.state)) 收为已恢复：\(identity)")
            }
            return .accept
        }, label: "markRestored \(identity)", expectedRevision: expectedRevision)
    }

    /// 首个写入前用实读纠正推测的原位置：只在从未写过的事务上生效（方案 §6.2）。
    /// 纠正失败必须让调用方知道，因为它不能再拿推测位置去写入。
    func correctOriginal(_ identity: WindowIdentity,
                         frame: CGRect,
                         displayID: UInt32) async -> JournalWrite {
        await mutate({ journal in
            guard let existing = journal.entries[identity.journalKey] else {
                return .rejected(reason: "日志里没有该事务，无法纠正原位置：\(identity)")
            }
            guard existing.hasSpeculativeOriginal else {
                return .rejected(reason: "事务不是从未写过的状态，原位置不再改写：\(identity)")
            }
            journal.correctOriginal(identity, frame: frame, displayID: displayID)
            guard journal.entries[identity.journalKey]?.originalFrame == frame else {
                return .rejected(reason: "纠正后日志仍未落住该位置：\(identity)")
            }
            return .accept
        }, label: "correctOriginal \(identity)")
    }

    func drop(_ identity: WindowIdentity, expectedRevision: UInt64? = nil) async -> JournalWrite {
        await mutate({ journal in
            guard journal.entries[identity.journalKey] != nil else {
                return .rejected(reason: "日志里没有该事务，删除请求作废：\(identity)")
            }
            journal.remove(identity)
            return .accept
        }, label: "remove \(identity)", expectedRevision: expectedRevision)
    }

    /// 只清指定会话中已经结束的条目：其他会话、以及本会话未完成/失败过的记录必须留下（方案 §6.4）。
    func clearSettled(sessionID: UUID, settledIdentities: [WindowIdentity]) async -> JournalWrite {
        await mutate({ journal in
            journal.prune(sessionID: sessionID, settledIdentities: settledIdentities)
            return .accept
        }, label: "clearSettled \(sessionID.uuidString.prefix(8))")
    }

    /// 记下"几何已恢复、日志待清理"：留档写不进也不能假装清理成功（方案 §7.4）。
    @discardableResult
    func recordSettlementFailure(_ marker: SettlementMarker) async -> JournalWrite {
        let markers: [SettlementMarker] = withLock {
            var next = backlog
            if !next.contains(where: { $0.journalKey == marker.journalKey }) { next.append(marker) }
            backlog = next
            return next
        }
        return await channel { await self.writeBacklog(markers) }
    }

    /// 留档项在下一次启动核对成功后销账。
    @discardableResult
    func clearSettlementFailure(journalKey: String) async -> JournalWrite {
        let markers: [SettlementMarker]? = withLock {
            guard backlog.contains(where: { $0.journalKey == journalKey }) else { return nil }
            backlog.removeAll { $0.journalKey == journalKey }
            return backlog
        }
        guard let markers else { return .persisted }
        return await channel { await self.writeBacklog(markers) }
    }

    /// 留档本身也是原子写；写不进时内存清单仍在，下次启动照旧核对。
    /// 与主日志共用可注入的落盘接缝：留档失败也要能被确定性测试注入，而不是只能靠真实磁盘故障。
    private func writeBacklog(_ markers: [SettlementMarker]) async -> JournalWrite {
        guard let data = try? JSONEncoder().encode(markers) else {
            return .failed(reason: "留档无法编码")
        }
        return await journalWriter.writeJournal(data, to: backlogURL)
    }

    // MARK: - 内部：串行事务（取快照 + 应用 + 编码 + 落盘 + 提交）

    private enum Step {
        case accept
        case rejected(reason: String)
    }

    /// 一个完整逻辑事务：取已提交快照 → 应用变更 → 编码 → 落盘 → 提交或失败。
    ///
    /// 整段都持有落盘通道（方案 §7.2 不变量 2）：同一时刻只有一批在途，
    /// 后一批拿到的必然是前一批提交之后的已提交快照；失败批次只丢弃自己那一次计算结果，
    /// `committed` 在落盘成功之前从未被改动，因此不存在"回滚把后来批次的暂存抹掉"的分叉。
    private func mutate(_ step: (inout SessionJournal) -> Step,
                        label: String,
                        expectedRevision: UInt64? = nil) async -> JournalWrite {
        await channel {
            let outcome: BatchOutcome = withLock {
                if let expectedRevision, expectedRevision != revisionValue {
                    return .refused(reason: "日志序号已过期（期望 \(expectedRevision)，当前 \(revisionValue)）：\(label) 未写入")
                }
                var next = committed
                switch step(&next) {
                case let .rejected(reason):
                    return .refused(reason: reason)
                case .accept:
                    guard let data = try? next.encoded() else {
                        return .refused(reason: "日志无法编码，\(label) 未写入")
                    }
                    return .ready(next, data)
                }
            }
            guard case let .ready(snapshotToCommit, data) = outcome else {
                if case let .refused(reason) = outcome { return .failed(reason: reason) }
                return .failed(reason: "日志变更未受理：\(label)")
            }
            let written = await journalWriter.writeJournal(data, to: url)
            guard written.isPersisted else {
                // 失败批次不提交：已提交快照与磁盘都还是落盘前的内容，后续批次基于它继续。
                return written
            }
            withLock {
                committed = snapshotToCommit
                revisionValue &+= 1
            }
            return .persisted
        }
    }

    /// 一批变更的计算结果：`ready` 只是"算好并编码好"，真正提交要等落盘成功。
    private enum BatchOutcome {
        case ready(SessionJournal, Data)
        case refused(reason: String)
    }

    /// Core 的 journal API 是值语义且没有抛错版本，这里把"能不能套"翻成可选原因。
    private static func apply(_ mutation: JournalMutation, to journal: inout SessionJournal) -> String? {
        switch mutation {
        case let .upsert(transaction):
            journal.apply(transaction)
            return nil
        case let .remove(identity):
            guard journal.entries[identity.journalKey] != nil else {
                return "日志里没有该事务，删除请求作废：\(identity)"
            }
            journal.remove(identity)
            return nil
        case let .correctOriginal(identity, frame, displayID):
            guard let existing = journal.entries[identity.journalKey] else {
                return "日志里没有该事务，无法纠正原位置：\(identity)"
            }
            guard existing.hasSpeculativeOriginal else {
                return "事务不是从未写过的状态，原位置不再改写：\(identity)"
            }
            journal.correctOriginal(identity, frame: frame, displayID: displayID)
            return nil
        }
    }

    /// FIFO 异步互斥：一个完整日志事务独占通道（取快照 → 应用 → 编码 → 落盘 → 提交），
    /// 同一时刻只有一批在途。
    private func channel<T>(_ work: () async -> T) async -> T {
        await acquire()
        let value = await work()
        release()
        return value
    }

    private func acquire() async {
        let acquired: Bool = withLock {
            if holdingChannel { return false }
            holdingChannel = true
            return true
        }
        guard !acquired else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            channelWaiters.append(continuation)
            lock.unlock()
        }
    }

    private func release() {
        let handoff: CheckedContinuation<Void, Never>? = withLock {
            guard !channelWaiters.isEmpty else {
                holdingChannel = false
                return nil
            }
            // 通道不空手交出：直接把持有权交给下一个等待者，保证顺序。
            return channelWaiters.removeFirst()
        }
        handoff?.resume()
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 读取与留档

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

    /// 留档读取：解不出来就按"没有留档"回答，但绝不因此把日志当成空日志（那是另一条路径管的）。
    private static func readBacklog(url: URL) -> [SettlementMarker] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([SettlementMarker].self, from: data)) ?? []
    }
}
