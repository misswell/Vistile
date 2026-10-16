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

/// 恢复执行器：收回、退出、崩溃恢复共用同一条逐条恢复路径（方案 §6.4、§6.5）。
/// 不变量：先用事实判定（存活/frame/显示器），再写；只有读回与目标在容差内一致才算事务结束。
/// 事实不足时既不写入也不删记录，绝不能"看起来处理完了"。
@MainActor
final class RecoveryCoordinator {
    private let store: WindowJournalStore
    private let writer: GeometryWriting
    private let catalog: WindowCatalog
    private let settings: SettingsModel
    private let permissions: PermissionChecking
    private let processIdentity: ProcessIdentityChecking

    init(store: WindowJournalStore = WindowJournalStore(),
         writer: GeometryWriting = AXWindowResolver(),
         catalog: WindowCatalog,
         settings: SettingsModel,
         permissions: PermissionChecking,
         processIdentity: ProcessIdentityChecking = LiveProcessIdentity.shared) {
        self.store = store
        self.writer = writer
        self.catalog = catalog
        self.settings = settings
        self.permissions = permissions
        self.processIdentity = processIdentity
    }

    /// 事务日志里读不到的原始信息也要能说明白：诊断记录用应用名，不猜窗口。
    func applicationName(for entry: WindowTransaction) -> String {
        catalog.record(for: entry.identity)?.applicationName
            ?? NSRunningApplication(processIdentifier: entry.identity.processID)?.localizedName
            ?? entry.bundleID ?? "未知应用"
    }

    // MARK: - 逐条恢复

    /// 单条恢复：不落盘、不发事件，只回报事实；调用方负责按身份串行化。
    func restore(entry: WindowTransaction) async -> RestoreItemResult {
        let name = applicationName(for: entry)
        guard entry.state.requiresRestore else {
            return RestoreItemResult(identity: entry.identity, outcome: .alreadyAtOriginal, applicationName: name)
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

        guard let ax = catalog.axEntry(for: record) else {
            // 句柄读不到属于"事实不足"，不是窗口消失：事务必须保留（方案 §6.4）。
            let outcome: RestoreOutcome = liveness.isConfirmedGone ? .windowGone : .notAttempted("辅助功能句柄暂不可用")
            return item(entry, outcome, name)
        }
        let current = await writer.currentFrame(of: ax.element) ?? record.frame
        let display = catalog.mapper.display(id: entry.originalDisplayID)
        let decision = RecoveryPlanner.decide(entry: entry,
                                             currentFrame: current,
                                             liveness: liveness,
                                             isOriginalDisplayLive: display != nil,
                                             clampedFrame: clampTarget(entry.originalFrame, preferred: entry.originalDisplayID),
                                             preserveUserGeometry: settings.preserveUserGeometry)
        guard decision.shouldWriteAX, let target = decision.frame else {
            guard let settled = decision.settledOutcome else { return item(entry, .notAttempted("判定结果缺少目标几何"), name) }
            if settled.isSettled { settle(entry.identity, settled) }
            return item(entry, settled, name)
        }
        // 所有恢复写入都夹回存活屏幕：原 frame 可能因为拔屏或分辨率变化已经完全在外面。
        let written = await writer.apply(frame: clampTarget(target, preferred: record.displayID), element: ax.element)
        return finishWrite(entry, written, name: name)
    }

    /// 只有 exact 才结束事务；constrained/rejected/unreadable 一律留痕并保留记录（方案 §6.1）。
    private func finishWrite(_ entry: WindowTransaction,
                             _ report: GeometryWriteReport,
                             name: String) -> RestoreItemResult {
        switch report.outcome {
        case .exact:
            settle(entry.identity, .restored)
            return RestoreItemResult(identity: entry.identity, outcome: .restored, applicationName: name)
        case let .constrained(readBack):
            let deviation = Double(AXWindowResolver.deviation(readBack, report.target))
            return keep(entry.markingFailed("恢复读回偏差 \(String(format: "%.1f", deviation))pt"),
                        .constrained(deviation: deviation), name)
        case .rejected(let reason):
            return keep(entry.markingFailed(reason.message), .rejected(reason.message), name)
        case .unreadable:
            return keep(entry.markingFailed("恢复后读不回 frame"), .unreadable, name)
        case .targetGone:
            settle(entry.identity, .windowGone)
            return RestoreItemResult(identity: entry.identity, outcome: .windowGone, applicationName: name)
        }
    }

    private func item(_ entry: WindowTransaction, _ outcome: RestoreOutcome, _ name: String) -> RestoreItemResult {
        RestoreItemResult(identity: entry.identity, outcome: outcome, applicationName: name)
    }

    /// 事务结束：日志里删除，state 由 reducer 决定去留。
    private func settle(_ identity: WindowIdentity, _ outcome: RestoreOutcome) {
        store.markRestored(identity)
        if store.drop(identity).isPersisted { return }
        // 删不掉也要说清事实：下次启动仍会按保守策略复核这条记录。
        VistileLog.session.log(level: .error, "恢复事务落盘失败: \(identity.journalKey, privacy: .public)")
    }

    /// 未成功：写回可重试记录，绝不静默丢弃原 frame。
    private func keep(_ entry: WindowTransaction, _ outcome: RestoreOutcome, _ name: String) -> RestoreItemResult {
        if store.apply(entry).isPersisted == false {
            VistileLog.session.log(level: .error, "恢复失败状态落盘失败: \(entry.identity.journalKey, privacy: .public)")
        }
        return RestoreItemResult(identity: entry.identity, outcome: outcome, applicationName: name)
    }

    // MARK: - 启动恢复

    /// 启动时处理上次未结束的事务。返回逐条事实供诊断记录。
    @discardableResult
    func restoreOnLaunch(recorder: CompatibilityRecorder? = nil) async -> [RestoreItemResult] {
        let pending = store.unfinished
        guard !pending.isEmpty else { return [] }
        recorder?.note("发现 \(pending.count) 条未结束的几何事务，按保守策略处理")
        if let issue = store.loadIssue { recorder?.note("事务日志读取问题：\(issue)") }
        // 先建立一次目录，才能判断进程是否重启、窗口是否仍存活。
        // 这里等的是"这一轮查询真正结束"，不是固定睡眠：慢机器上 250ms 并不足以拿到 AX 句柄。
        await catalog.refreshAndWait(reason: .shortcut)

        var results: [RestoreItemResult] = []
        for entry in pending {
            let result = await restore(entry: entry)
            results.append(result)
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

    /// 正常退出的兜底：状态机路径没走完时由这里补做，逻辑与逐条恢复完全一致（方案 §6.6）。
    /// 不做并发第二条路径：调用方必须已经停止新的过渡。
    @discardableResult
    func restoreOnQuit() async -> [RestoreItemResult] {
        var results: [RestoreItemResult] = []
        for entry in store.unfinished {
            let result = await restore(entry: entry)
            results.append(result)
            VistileLog.session.log(level: .info, "退出恢复 \(result.applicationName, privacy: .public): \(result.outcome.message, privacy: .public)")
        }
        return results
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

    static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }

    private func clampTarget(_ frame: CGRect, preferred displayID: UInt32?) -> CGRect {
        let mapper = catalog.mapper
        guard let target = mapper.display(id: displayID ?? 0) ?? mapper.primaryDisplay else { return frame }
        return mapper.clamp(frame, to: target.id)
    }
}
