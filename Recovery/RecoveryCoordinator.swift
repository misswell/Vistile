import AppKit
import Foundation
import VistileCore

/// 进程实例身份判定：PID 会被复用，"这个号还在"不等于"还是原来那个进程"（方案 §6.5）。
/// 真机读公开的启动标识，宿主测试注入固定结论，否则交错类回归只能对着真实进程跑。
protocol ProcessIdentityChecking {
    func isSameInstance(processID: pid_t, startIdentity: UInt64) -> Bool
}

/// 只用公开事实：NSRunningApplication + 进程启动标识。
final class LiveProcessIdentity: ProcessIdentityChecking, @unchecked Sendable {
    static let shared = LiveProcessIdentity()

    func isSameInstance(processID: pid_t, startIdentity: UInt64) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return false }
        return ProcessIdentityReader.startIdentity(for: app.processIdentifier) == startIdentity
    }
}

/// 一次会话恢复的批量结论：处理完了不等于全部恢复了（方案 §6.4、§14.3）。
struct RestoreRunReport: Hashable, Sendable {
    let items: [RestoreItemResult]
    /// 预算耗尽后没有继续尝试的身份：事务与日志都必须原样保留。
    let deferredByDeadline: [WindowIdentity]

    var unresolvedIdentities: [WindowIdentity] {
        items.filter { !$0.outcome.isSettled }.map(\.identity) + deferredByDeadline
    }

    var isFullySettled: Bool { unresolvedIdentities.isEmpty }
}

/// 恢复执行器：收回、退出、崩溃恢复共用同一条逐条恢复路径（方案 §6.4、§6.5、§8、§14）。
/// 不变量：先用事实判定（存活/frame/显示器），再写；只有读回与**最终规划落点**在容差内一致才算事务结束。
/// 事实不足时既不写入也不删记录，绝不能"看起来处理完了"。
@MainActor
final class RecoveryCoordinator {
    private let store: WindowJournalStore
    private let writer: GeometryWriting
    private let catalog: WindowCatalog
    private let settings: SettingsModel
    private let permissions: PermissionChecking
    private let processIdentity: ProcessIdentityChecking
    private let scheduler: GeometryOperationScheduler

    init(store: WindowJournalStore = WindowJournalStore(),
         writer: GeometryWriting = AXWindowResolver(),
         catalog: WindowCatalog,
         settings: SettingsModel,
         permissions: PermissionChecking,
         processIdentity: ProcessIdentityChecking = LiveProcessIdentity.shared,
         scheduler: GeometryOperationScheduler) {
        self.store = store
        self.writer = writer
        self.catalog = catalog
        self.settings = settings
        self.permissions = permissions
        self.processIdentity = processIdentity
        self.scheduler = scheduler
    }

    /// 事务日志里读不到的原始信息也要能说明白：诊断记录用应用名，不猜窗口。
    func applicationName(for entry: WindowTransaction) -> String {
        catalog.record(for: entry.identity)?.applicationName
            ?? NSRunningApplication(processIdentifier: entry.identity.processID)?.localizedName
            ?? entry.bundleID ?? "未知应用"
    }

    // MARK: - 逐条恢复

    /// 单条恢复：不落盘之外的动作都不做，只回报事实；写入必须站在调度器的恢复授权里。
    /// `deadline` 是退出流程共享预算的截止点：预算已尽就不再开始新的 AX 写入（方案 §14.2）。
    func restore(entry: WindowTransaction,
                 token: TransitionToken,
                 deadline: GeometryOperationScheduler.Stamp? = nil) async -> RestoreItemResult {
        let name = applicationName(for: entry)
        let context = scheduler.makeContext(token: token, kind: .sessionRestore)
        guard let result: RestoreItemResult = await scheduler.request(
            context: context,
            identities: [entry.identity],
            deadline: deadline,
            work: { permit in await self.performRestore(entry: entry, context: context, permit: permit) }
        ) else {
            // 未准入/被丢弃：一个字节都没写，事务继续留在日志里等下一次核对。
            return item(entry, .notAttempted("会话或预算已失效，本次未开始恢复写入"), name)
        }
        return result
    }

    private func performRestore(entry: WindowTransaction,
                                context: GeometryOperationContext,
                                permit: GeometryWritePermit) async -> RestoreItemResult {
        let name = applicationName(for: entry)
        guard entry.state.requiresRestore else {
            return item(entry, .alreadyAtOriginal, name)
        }
        guard permissionsReady else {
            return item(entry, .notAttempted(permissionsMissingReason), name)
        }
        let isConfirmedGone = catalog.isConfirmedGone(entry.identity)
        guard let record = catalog.record(for: entry.identity) else {
            // 目录确认销毁与"还没来得及记录"是两件事：前者可以直接结算，后者必须保留事务（方案 §6.4、§8.3）。
            return item(entry, isConfirmedGone ? .windowGone
                                               : .notAttempted("目录中还没有该窗口的记录，无法确认它是否仍存在"), name)
        }
        let liveness = WindowLiveness(record: record,
                                      processIsSameInstance: processIdentity.isSameInstance(
                                        processID: entry.identity.processID,
                                        startIdentity: entry.identity.processStartIdentity),
                                      isConfirmedGone: isConfirmedGone)

        // 句柄取不到先复核目录（带截止时间反复复核）：窗口刚被移动时两侧 frame 可能没对齐，
        // 捕捉权限查询也会成串短暂被拒，一次坏采样不等于事实不足。
        guard let ax = await catalog.axEntryAfterReview(for: record) else {
            // 句柄读不到属于"事实不足"，不是窗口消失：事务必须保留（方案 §6.4）。
            let outcome: RestoreOutcome = liveness.isConfirmedGone ? .windowGone
                                                                  : .notAttempted("辅助功能句柄暂不可用")
            return item(entry, outcome, name)
        }
        // 当前 frame 只认实读：读不到就把 nil 交给判定，由它给出"事实不足、保留事务"。
        let current = await writer.currentFrame(of: ax.element)
        // 落点只算一次：原始屏的可用区 + 明确备用屏，绝不在写入前按"窗口现在在哪块屏"再夹一遍（方案 §8）。
        let destination = planDestination(for: entry)
        let decision = RecoveryPlanner.decide(entry: entry,
                                              currentFrame: current,
                                              liveness: liveness,
                                              destination: destination,
                                              preserveUserGeometry: settings.preserveUserGeometry)
        // 判定依据要能复盘：跳过/写入的选择取决于当前实读、原位置与最终落点三个值（方案 §6.4）。
        VistileLog.session.log(level: .debug,
                               "[恢复判定] \(entry.identity.journalKey, privacy: .public) 当前=\(Self.text(current)), 原位置=\(Self.text(entry.originalFrame)), 落点=\(destination.map { Self.text($0.targetFrame) + " " + $0.reasonText } ?? "无"), 结论=\(decision.settledOutcome?.message ?? "写入恢复", privacy: .public)")

        guard decision.shouldWriteAX, let planned = destination else {
            guard let settled = decision.settledOutcome else {
                return item(entry, .notAttempted("判定结果缺少目标几何"), name)
            }
            if settled.isSettled {
                return await settle(entry, settled, name: name)
            }
            return await keep(entry, settled, name)
        }
        // 开始新的 AX 写入前最后一次预算检查：没有预算就停在这里，日志原样保留（方案 §14.2）。
        guard permit.isGranted else {
            return item(entry, .notAttempted("恢复许可已撤销，未开始写入"), name)
        }
        let written = await writer.apply(frame: planned.targetFrame, element: ax.element, permit: permit)
        return await finishWrite(entry, written, destination: planned, name: name)
    }

    /// 原始屏事实与明确备用屏：备用屏只取"主屏优先、否则另一块真实存在的屏"，并带上自己的身份。
    private func planDestination(for entry: WindowTransaction) -> RestoreDestination? {
        let mapper = catalog.mapper
        let original = mapper.display(id: entry.originalDisplayID)
        let fallback = mapper.primaryDisplay.flatMap { primary in
            primary.id == entry.originalDisplayID ? nil : primary
        } ?? mapper.displays.first(where: { $0.id != entry.originalDisplayID })
        return RestorePlanner.plan(entry: entry,
                                   originalDisplayIsLive: original != nil,
                                   originalVisibleFrame: original?.visibleFrame,
                                   fallbackVisibleFrame: fallback?.visibleFrame,
                                   fallbackDisplayID: fallback?.id)
    }

    /// 只有读回与**最终落点**在容差内一致才结束事务；其它结论一律留痕并保留记录（方案 §6.1、§8）。
    private func finishWrite(_ entry: WindowTransaction,
                             _ report: GeometryWriteReport,
                             destination: RestoreDestination,
                             name: String) async -> RestoreItemResult {
        let target = destination.targetFrame
        switch report.outcome {
        case .exact(let readBack):
            // 降级落点要说清"这是备用屏/夹取后的结果"，不能报成精确恢复（方案 §8）。
            if destination.isDowngraded {
                return await settle(entry,
                                    .settledDegraded(readBack: readBack, displayID: destination.targetDisplayID),
                                    name: name)
            }
            return await settle(entry, .restored, name: name)
        case let .constrained(readBack):
            let deviation = Double(AXWindowResolver.deviation(readBack, target))
            return await keep(entry.markingFailed("恢复读回与落点 \(Self.text(target)) 偏差 \(String(format: "%.1f", deviation))pt"),
                              .constrained(readBack: readBack, deviation: deviation), name)
        case .rejected(let reason):
            return await keep(entry.markingFailed(reason.message), .rejected(reason.message), name)
        case .unreadable:
            return await keep(entry.markingFailed("恢复后读不回 frame"), .unreadable, name)
        case .targetGone:
            return await settle(entry, .windowGone, name: name)
        case let .cancelled(wroteSize, wrotePosition, readBack):
            // 中途被撤销：写过哪一侧就是哪一侧，事务必须保留并按真实部分事实继续核对。
            let facts = report.outcome.message
            return await keep(entry.markingFailed(facts),
                              .rejected("恢复写入被撤销：\(facts)"),
                              name,
                              extra: "wroteSize=\(wroteSize) wrotePosition=\(wrotePosition) readBack=\(Self.text(readBack))")
        }
    }

    private func item(_ entry: WindowTransaction, _ outcome: RestoreOutcome, _ name: String) -> RestoreItemResult {
        RestoreItemResult(identity: entry.identity, outcome: outcome, applicationName: name)
    }

    /// 事务收口：状态改完还要真的把日志清掉；清不掉就留档，下次启动继续核对（方案 §7.4）。
    /// 任何一步落盘失败都不能对外宣称"已恢复"，只能说明"几何已恢复、日志待清理"。
    private func settle(_ entry: WindowTransaction,
                        _ outcome: RestoreOutcome,
                        name: String) async -> RestoreItemResult {
        let marked = await store.markRestored(entry.identity)
        guard marked.isPersisted else {
            VistileLog.session.log(level: .error,
                                   "恢复状态落盘失败: \(entry.identity.journalKey, privacy: .public) \(marked.reason ?? "", privacy: .public)")
            // 状态没落住 = 事务还在，按未完成回报。
            return item(entry, .notAttempted("恢复结果未能写入日志：\(marked.reason ?? "")"), name)
        }
        let dropped = await store.drop(entry.identity)
        if !dropped.isPersisted {
            _ = await store.recordSettlementFailure(.init(journalKey: entry.identity.journalKey,
                                                           identity: entry.identity,
                                                           reason: dropped.reason ?? "日志未能清理"))
            VistileLog.session.log(level: .error,
                                   "几何已恢复、日志待清理: \(entry.identity.journalKey, privacy: .public)")
        } else {
            _ = await store.clearSettlementFailure(journalKey: entry.identity.journalKey)
        }
        return RestoreItemResult(identity: entry.identity, outcome: outcome, applicationName: name)
    }

    /// 未成功：写回可重试记录，绝不静默丢弃原 frame；写不进也要把事实说清楚。
    private func keep(_ entry: WindowTransaction,
                      _ outcome: RestoreOutcome,
                      _ name: String,
                      extra: String = "") async -> RestoreItemResult {
        let written = await store.apply(entry)
        if !written.isPersisted {
            VistileLog.session.log(level: .error,
                                   "恢复失败状态落盘失败: \(entry.identity.journalKey, privacy: .public) \(written.reason ?? "", privacy: .public)")
        }
        if !extra.isEmpty {
            VistileLog.session.log(level: .debug, "[恢复留痕] \(extra, privacy: .public)")
        }
        return item(entry, outcome, name)
    }

    // MARK: - 启动恢复

    /// 启动时处理上次未结束的事务与"几何已恢复、日志待清理"的留档。返回逐条事实供诊断记录。
    @discardableResult
    func restoreOnLaunch(recorder: CompatibilityRecorder? = nil,
                         token: TransitionToken? = nil) async -> [RestoreItemResult] {
        let pending = store.unfinished
        let markers = store.settlementBacklog
        guard !pending.isEmpty || !markers.isEmpty else { return [] }
        if !pending.isEmpty { recorder?.note("发现 \(pending.count) 条未结束的几何事务，按保守策略处理") }
        if let issue = store.loadIssue { recorder?.note("事务日志读取问题：\(issue)") }
        // 留档项先核对一遍：几何可能已经恢复，只是当时日志没清掉（方案 §7.4）。
        for marker in markers {
            recorder?.note("日志待清理留档：\(marker.identity)，当时原因：\(marker.reason)")
        }
        // 先建立一次目录，才能判断进程是否重启、窗口是否仍存活。
        // 这里等的是"这一轮查询真正结束"，不是固定睡眠：慢机器上 250ms 并不足以拿到 AX 句柄。
        await catalog.refreshAndWait(reason: .shortcut)

        let transitionToken = token ?? TransitionToken(generation: 0)
        var results: [RestoreItemResult] = []
        for entry in pending {
            guard !Task.isCancelled else { break }
            let result = await restore(entry: entry, token: transitionToken)
            results.append(result)
            if result.outcome.isSettled {
                // 核对完成后销掉同一身份的待清理留档。
                _ = await store.clearSettlementFailure(journalKey: entry.identity.journalKey)
            }
            recorder?.note("启动恢复 \(result.applicationName)：\(result.outcome.message)")
            if result.outcome.isFailure {
                recorder?.updateRow(application: result.applicationName, version: "",
                                    restore: .failed, knownLimitation: result.outcome.message)
            } else if result.outcome.isSettled {
                recorder?.updateRow(application: result.applicationName, version: "", restore: .passed)
            }
        }
        return results
    }

    // MARK: - 退出兜底

    /// 正常退出的兜底：状态机路径没走完时由这里补做，逻辑与逐条恢复完全一致（方案 §6.6、§14.2）。
    /// 唯一的恢复执行者：调用方必须已经停止新的过渡，并且不再另起一条并发恢复路径。
    /// 预算耗尽时停止开始新的写入，剩余事务原样留在日志里。
    func restoreOnQuit(token: TransitionToken,
                       deadline: GeometryOperationScheduler.Stamp?) async -> RestoreRunReport {
        var items: [RestoreItemResult] = []
        var deferred: [WindowIdentity] = []
        for entry in store.unfinished {
            guard scheduler.canStartNewWrite(deadline: deadline) else {
                // 没预算就不写：日志保留，下次启动继续核对。
                deferred.append(entry.identity)
                continue
            }
            let result = await restore(entry: entry, token: token, deadline: deadline)
            items.append(result)
            VistileLog.session.log(level: .info,
                                   "退出恢复 \(result.applicationName, privacy: .public): \(result.outcome.message, privacy: .public)")
        }
        if !deferred.isEmpty {
            VistileLog.session.log(level: .error,
                                   "退出预算耗尽，\(deferred.count, privacy: .public) 条事务保留在日志中")
        }
        return RestoreRunReport(items: items, deferredByDeadline: deferred)
    }

    // MARK: - 事实

    /// 权限缺失时不写 AX、也不删事务：恢复推迟到权限回来或下次启动。
    var permissionsReady: Bool {
        permissions.status.screenRecording && permissions.status.accessibility
    }

    private var permissionsMissingReason: String {
        permissions.status.screenRecording
            ? "缺少辅助功能权限，无法写入窗口几何"
            : "缺少屏幕录制权限，无法确认窗口是否仍存在"
    }

    static func text(_ rect: CGRect?) -> String {
        guard let rect else { return "读不到" }
        return Self.text(rect)
    }

    static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }
}

extension RestoreDestination {
    /// 日志里要说得出这个落点为什么是它（方案 §8）。
    var reasonText: String { reason.reasonText }
}

extension RestoreDestinationReason {
    /// 日志里要说得出这个落点为什么是它（方案 §8）。
    var reasonText: String {
        switch self {
        case .exactOnOriginalDisplay: return "原屏原位"
        case .adjustedOnOriginalDisplay: return "原屏内夹取"
        case .originalDisplayUnavailable: return "原屏消失，降级备用屏"
        case .overrideOnDisplay: return "按用户保留位置"
        }
    }
}
