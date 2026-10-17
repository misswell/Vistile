import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import VistileCore

/// 展开、收回与恢复的有序执行器（方案 §10.2、§10.3）。
/// 顺序不变量：事务先落盘 → 写 AX → 读回 → 动画 → 汇报事件。
/// 三条硬规则：同一窗口的操作串行；每个 await 之后重查令牌；只有读回一致才宣称到位（方案 §6.3）。
@MainActor
final class FocusCoordinator {
    var onEvent: ((SessionEvent) -> Void)?
    var onStatus: ((String) -> Void)?

    /// 卡片画面矩形（CG 全局）由总览布局提供，代理不能自己猜起点。
    var cardRectProvider: ((WindowIdentity) -> CGRect?)?
    /// 动画起点用的画面纹理。
    var textureProvider: ((WindowIdentity) -> MetalFrame?)?
    /// 令牌是否仍然是状态机当前那一次过渡；过期写入只做补偿，不改状态。
    var isTokenCurrent: ((TransitionToken) -> Bool)?

    /// 程序写入与用户拖动不能靠一个瞬时布尔区分：写入结束后仍按读回值判定（方案 §6.5）。
    private static let attributionWindow: TimeInterval = 0.6

    private let catalog: WindowCatalog
    private let writer: GeometryWriting
    private let store: WindowJournalStore
    private let settings: SettingsModel
    private let metrics: Metrics
    private let recorder: CompatibilityRecorder
    private let metal: MetalContext
    private let recovery: RecoveryCoordinator
    private let permissions: PermissionChecking
    private let scheduler: GeometryOperationScheduler

    private var proxy: TransitionProxyWindow?
    private var activeToken: TransitionToken?
    private var activeIdentity: WindowIdentity?
    private var activeDirection: Direction = .expand
    /// 当前这次过渡的预算与起点：超时那条记录要把"到底等了多久、预算是多少"写出来，否则下次复跑无从对比。
    private var transitionBudgetMS = 0
    private var transitionStartedAt = CACurrentMediaTime()
    private var watchdog: Timer?
    private var busy: Set<WindowIdentity> = []
    private var writing: Set<WindowIdentity> = []
    private var lastWritten: [WindowIdentity: (frame: CGRect, at: TimeInterval)] = [:]

    private enum Direction { case expand, collapse }

    init(catalog: WindowCatalog,
         metal: MetalContext,
         writer: GeometryWriting = AXWindowResolver(),
         store: WindowJournalStore,
         settings: SettingsModel,
         metrics: Metrics,
         recorder: CompatibilityRecorder,
         recovery: RecoveryCoordinator,
         permissions: PermissionChecking,
         scheduler: GeometryOperationScheduler) {
        self.catalog = catalog
        self.metal = metal
        self.writer = writer
        self.store = store
        self.settings = settings
        self.metrics = metrics
        self.recorder = recorder
        self.recovery = recovery
        self.permissions = permissions
        self.scheduler = scheduler
    }

    var isAnimating: Bool { activeToken != nil }

    /// 代理动画是否仍在跑：合并进 TransitionActivity，取代零散的 isAnimating 判断（方案 §13.2）。
    var activity: TransitionActivity {
        TransitionActivity(focusProxy: activeToken != nil)
    }

    /// 退出前必须等到所有窗口通道排空：不能并行走第二条恢复路径（方案 §6.6）。
    var isIdle: Bool { activeToken == nil && busy.isEmpty }

    // MARK: - 展开

    func expand(_ identity: WindowIdentity,
                targetFrame: CGRect,
                token: TransitionToken,
                animationMS: Int) {
        guard isTokenCurrent?(token) ?? true else { return }
        guard let record = catalog.record(for: identity) else {
            report(token: token, reason: "找不到目标窗口")
            return
        }
        guard let display = catalog.mapper.display(id: record.displayID) ?? catalog.mapper.primaryDisplay else {
            report(token: token, reason: "目标所在显示器已不可用")
            return
        }
        guard permissions.status.isComplete else {
            report(token: token, reason: "权限已收回，未写入窗口几何")
            return
        }
        // 总超时从这一次动作的入口开始算，而不是从动画开始算（方案 §6.3）。
        beginAnimation(token, identity: identity, budgetMS: animationMS + 1_500)
        metrics.begin("过渡:展开")
        // 展开的几何写入只经调度器排队：取消屏障撤销的是同一个许可（方案 §5.2）。
        let context = scheduler.makeContext(token: token, kind: .enterWorkbench)
        guard scheduler.perform(GeometryOperationScheduler.Operation(
            context: context,
            identities: [identity],
            coalesceKey: "expand:\(identity.journalKey)",
            deadline: scheduler.deadline(after: .milliseconds(animationMS + 1_500)),
            onSkipped: { [weak self] reason in
                self?.report(token: token, reason: SetupMessages.skipped(reason))
            },
            run: { [weak self] permit in
                guard let self else { return }
                self.busy.insert(identity)
                await self.performExpand(record: record,
                                         display: display,
                                         targetFrame: targetFrame,
                                         token: token,
                                         context: context,
                                         permit: permit,
                                         animationMS: animationMS)
                self.busy.remove(identity)
            })) else {
            report(token: token, reason: "会话已更新，展开未排队")
            return
        }
    }

    private func performExpand(record: WindowRecord,
                               display: DisplayInfo,
                               targetFrame: CGRect,
                               token: TransitionToken,
                               context: GeometryOperationContext,
                               permit: GeometryWritePermit,
                               animationMS: Int) async {
        let identity = record.identity
        guard isCurrent(token, identity) else { return }
        // 事务必须已经落盘：缺事务就写 AX，窗口会失去可恢复的原 frame（方案 §6.2）。
        guard store.entry(for: identity)?.state.requiresRestore == true else {
            report(token: token, reason: "几何事务未落盘，已拒绝写入")
            return
        }
        // 排队期间目录可能已经换了一代：以最新记录为准，但只写 reducer 给的那个 frame。
        var current = catalog.record(for: identity) ?? record
        var ax = catalog.axEntry(for: current)
        if current.isMinimized || current.capture == .pausedMinimized {
            guard let element = ax?.element else {
                // 没有句柄就无从解除最小化：不能说"已经展开了"。
                report(token: token, reason: "\(current.applicationName) 的最小化窗口缺少 AX 句柄")
                return
            }
            let released = await writer.setMinimized(false, element: element)
            guard isCurrent(token, identity) else { return }
            guard released else {
                recorder.record("最小化解除", subject: current.applicationName, result: .failed,
                                detail: "写入 kAXMinimized=false 后读回仍是最小化")
                report(token: token, reason: "\(current.applicationName) 未解除最小化")
                return
            }
            // 解除最小化会让目录换代：句柄必须按身份重取，旧 AX 索引不得复用（方案 §11）。
            await catalog.refreshAndWait(reason: .windowEvent)
            guard isCurrent(token, identity) else { return }
            guard let fresh = catalog.record(for: identity) else {
                report(token: token, reason: "解除最小化后目录里找不到该窗口")
                return
            }
            // "其他桌面"的禁用规则照旧：不因为刚解除最小化就绕过（方案 §11 第 7 条）。
            guard fresh.allowsAutoFocus else {
                noteBlocked(fresh, "解除最小化后仍不能聚焦：\(fresh.restriction.map { "\($0)" } ?? "身份未唯一确定")")
                report(token: token, reason: "\(fresh.applicationName) 的窗口当前不可聚焦")
                return
            }
            current = fresh
            ax = catalog.axEntry(for: fresh)
        }
        var applied = targetFrame
        if let ax, current.allowsGeometryControl {
            let started = CACurrentMediaTime()
            writing.insert(identity)
            let write = await writer.apply(frame: targetFrame, element: ax.element, permit: permit)
            writing.remove(identity)
            lastWritten[identity] = (write.displayFrame, CACurrentMediaTime())
            metrics.measure("几何写入", milliseconds: (CACurrentMediaTime() - started) * 1000,
                            context: write.outcome.message)
            if let readBackMS = write.readBackMS {
                metrics.measure("几何读回", milliseconds: readBackMS, context: write.outcome.message)
            }
            guard isCurrent(token, identity) else {
                // 令牌已过期：状态已经不属于这次过渡，但几何可能已被改掉，必须补偿回原 frame。
                if write.didChangeGeometry, let entry = store.entry(for: identity) {
                    recorder.note("过渡令牌已过期，正在补偿恢复：\(identity.journalKey)")
                    _ = await recovery.restore(entry: entry, token: token)
                }
                return
            }
            applied = write.displayFrame
            onEvent?(.geometryWriteFinished(GeometryWriteResult(identity: identity,
                                                                token: token,
                                                                operationID: context.operationID,
                                                                targetFrame: targetFrame,
                                                                displayID: display.id,
                                                                outcome: write.outcome,
                                                                beforeFrame: write.frameBeforeWrite,
                                                                context: context)))
            if case let .constrained(readBack) = write.outcome {
                recorder.updateRow(application: current.applicationName,
                                   version: "",
                                   resize: .failed,
                                   knownLimitation: "写入后读回 \(RecoveryCoordinator.text(readBack))，未回到目标尺寸")
                onStatus?("\(current.applicationName) 未完全接受目标尺寸")
            }
        } else {
            // 无法或未授权改尺寸：只做前景与 Raise，卡片继续可点，明确降级（方案 §10.1）。
            noteBlocked(current, current.allowsAutoFocus
                ? "AX 报告该窗口不可调整尺寸，或本代次句柄不可用"
                : "身份未唯一确定，禁止几何写入")
        }
        let ordering = await bringToFront(record: current, element: ax?.element, permit: permit)
        guard isCurrent(token, identity) else { return }
        // 有相反证据时不把它当成功展开：走回总览与恢复分支（方案 §12.2）。
        if ordering.isProvenBehind {
            report(token: token, reason: "\(current.applicationName) 没能带到前台（\(ordering.evidence)）")
            return
        }
        animate(identity: identity,
                token: token,
                from: cardRectProvider?(identity) ?? applied,
                to: applied,
                animationMS: animationMS,
                reverse: false)
    }

    // MARK: - 收回

    func collapse(_ identity: WindowIdentity, token: TransitionToken, animationMS: Int) {
        guard isTokenCurrent?(token) ?? true else { return }
        beginAnimation(token, identity: identity, budgetMS: animationMS + 200)
        metrics.begin("过渡:收回")
        let context = scheduler.makeContext(token: token, kind: .returnOverview)
        _ = scheduler.perform(GeometryOperationScheduler.Operation(
            context: context,
            identities: [identity],
            coalesceKey: "collapse:\(identity.journalKey)",
            run: { [weak self] _ in
                guard let self else { return }
                self.busy.insert(identity)
                defer { self.busy.remove(identity) }
                guard self.isCurrent(token, identity) else { return }
                // 同一条串行通道已保证 .restoreGeometry 先跑完（方案 §10.3）：这里只读真实 frame 再反向动画。
                let from = await self.currentFrame(of: identity)
                guard self.isCurrent(token, identity) else { return }
                let card = self.cardRectProvider?(identity) ?? self.catalog.mapper.visibleFrame(for: from ?? .zero)
                self.animate(identity: identity,
                             token: token,
                             from: from ?? card,
                             to: card,
                             animationMS: animationMS,
                             reverse: true)
            }))
    }

    /// 恢复只写回事务里记录的原 frame；同一 token 的反向动画由同一条通道排在它后面。
    func restoreGeometry(_ identity: WindowIdentity, token: TransitionToken) {
        Task { [weak self] in
            guard let self else { return }
            let item = await self.restoreOne(identity, token: token)
            self.onEvent?(.geometryRestoreSettled(token: token, items: [item]))
        }
    }

    /// 退出、锁屏、Space 切换：逐条恢复并单独回报结果，最后统一收口（方案 §6.4）。
    /// 每条恢复都带自己的预算检查（RecoveryCoordinator 内部完成），过期就保留日志停下。
    func restoreAll(_ identities: [WindowIdentity],
                    token: TransitionToken,
                    deadline: GeometryOperationScheduler.Stamp? = nil) {
        Task { [weak self] in
            guard let self else { return }
            for identity in identities {
                let item = await self.restoreOne(identity, token: token, deadline: deadline)
                self.onEvent?(.geometryRestoreSettled(token: token, items: [item]))
            }
            self.stopAnimation()
            self.onEvent?(.restoreCompleted(token))
        }
    }

    private func restoreOne(_ identity: WindowIdentity,
                            token: TransitionToken,
                            deadline: GeometryOperationScheduler.Stamp? = nil) async -> RestoreItemResult {
        guard let entry = store.entry(for: identity) else {
            // 日志里没有：可能属于别的会话，也可能写盘失败。按事实回报，不谎报已恢复。
            return RestoreItemResult(identity: identity,
                                     outcome: .notAttempted("事务日志中没有该窗口的记录"),
                                     applicationName: catalog.record(for: identity)?.applicationName ?? "未知应用")
        }
        guard entry.state.requiresRestore else {
            return RestoreItemResult(identity: identity,
                                     outcome: .alreadyAtOriginal,
                                     applicationName: recovery.applicationName(for: entry))
        }
        return await recovery.restore(entry: entry, token: token, deadline: deadline)
    }

    /// "只把这一个窗口提到前面"到底有没有发出去。
    /// 发不出去时调用方必须知道：一次静默的 no-op 在探针里会被读成"产品没提升成功"，
    /// 在真实点击里则是用户点了卡片却什么都没发生。
    enum RaiseOutcome: Equatable {
        case issued(axIndex: Int)
        case recordMissing
        case handleMissing(String)
        /// 调度器没给准入（会话已换、相位已关闭、取消屏障已落下）：这次唤起一个调用都没发（方案 §5.2）。
        case notAdmitted

        var wasIssued: Bool {
            if case .issued = self { return true }
            return false
        }

        var detail: String {
            switch self {
            case let .issued(axIndex): return "已发出 AX Raise（索引 #\(axIndex)）"
            case .recordMissing: return "目录里没有该窗口身份，Raise 没有发出"
            case let .handleMissing(reason): return "拿不到 AX 句柄，Raise 没有发出：\(reason)"
            case .notAdmitted: return "会话准入已撤销，Raise 没有进入 AX 队列"
            }
        }
    }

    /// 只把窗口提到前面，不写任何几何。
    ///
    /// `context` 是调用方（状态机 effect）给的身份：唤起必须与这次会话的准入、取消屏障同一条通道，
    /// 不能在隐藏之后还排进一条新命令（方案 §5.2、§5.3）。省略时按当前会话现场生成。
    @discardableResult
    func raiseOnly(_ identity: WindowIdentity,
                   context suppliedContext: GeometryOperationContext? = nil) -> RaiseOutcome {
        guard let record = catalog.record(for: identity) else { return .recordMissing }
        guard let element = catalog.axEntry(for: record)?.element else {
            guard let index = record.confidence.resolvedAXIndex else {
                return .handleMissing("身份未解析出 AX 索引")
            }
            return .handleMissing("本代次句柄表里没有索引 #\(index) 的窗口")
        }
        // 只做前景/层级：仍然必须经调度器排队，否则它会插进一次几何写入中间（方案 §5.3）。
        let context = suppliedContext
            ?? scheduler.makeContext(token: TransitionToken(generation: 0), kind: .settleLayout)
        guard scheduler.perform(GeometryOperationScheduler.Operation(
            context: context,
            identities: [identity],
            coalesceKey: "raise:\(identity.journalKey)",
            run: { [weak self] permit in
                await self?.bringToFront(record: record, element: element, permit: permit)
            })) else {
            return .notAdmitted
        }
        return .issued(axIndex: record.confidence.resolvedAXIndex ?? -1)
    }

    /// 外部中断（挂起、退出）时立刻结束代理，避免残留浮层。
    func cancelAnimation() {
        stopAnimation()
    }

    // MARK: - 工作台共用（方案 §8.2）

    /// 工作台交换执行器走同一条 AX 通道写几何：写入期间与写后短窗口的归因
    /// 必须由同一份记账决定，否则我们自己的写入会被读成用户拖动（方案 §6.5）。
    func beginProgrammaticWrite(_ identity: WindowIdentity) {
        writing.insert(identity)
    }

    func endProgrammaticWrite(_ identity: WindowIdentity, frame: CGRect) {
        writing.remove(identity)
        lastWritten[identity] = (frame, CACurrentMediaTime())
    }

    /// 工作台交换的「前景确认」步骤读回的事实。只用公开激活 + AX Raise + 读回，
    /// 与展开路径完全同一条实现（含同应用兄弟窗口的读回判定）。
    struct ActivationFacts: Equatable {
        var activationRequested = false
        var activationReturned = false
        var raiseReturned = false
        var focusedWindowMatches: Bool?
        var frontApplicationMatches: Bool?

        var isVerifiedFront: Bool { focusedWindowMatches == true || frontApplicationMatches == true }
        /// 只有相反证据才算失败：读不到不等于失败（方案 §12.2）。
        var isProvenBehind: Bool { focusedWindowMatches == false && frontApplicationMatches == false }

        var evidence: String {
            func text(_ value: Bool?) -> String {
                switch value {
                case .some(true): return "是"
                case .some(false): return "否"
                case nil: return "不可读"
                }
            }
            return "activate=\(activationReturned) raise=\(raiseReturned) "
                + "focused读回=\(text(focusedWindowMatches)) 前台=\(text(frontApplicationMatches))"
        }
    }

    @discardableResult
    func activateAndRaise(_ identity: WindowIdentity,
                          permit: GeometryWritePermit? = nil) async -> ActivationFacts {
        guard let record = catalog.record(for: identity) else {
            var facts = ActivationFacts()
            facts.frontApplicationMatches = false
            onStatus?("前景化失败：目录里已没有该窗口")
            return facts
        }
        let started = CACurrentMediaTime()
        let report = await bringToFront(record: record,
                                       element: catalog.axEntry(for: record)?.element,
                                       permit: permit)
        // §20.2 把"激活"单列为一个采样端点：它和几何写入是两次不同的跨进程往返，
        // 混在过渡总耗时里就看不出到底是前景化慢还是写入慢。
        metrics.measure("激活+Raise",
                        milliseconds: (CACurrentMediaTime() - started) * 1000,
                        context: "请求=\(report.activationRequested) 激活返回=\(report.activationReturned) "
                            + "raise 返回=\(report.raiseReturned) 焦点一致=\(report.focusedWindowMatches) "
                            + "前景一致=\(report.frontApplicationMatches)")
        return ActivationFacts(activationRequested: report.activationRequested,
                               activationReturned: report.activationReturned,
                               raiseReturned: report.raiseReturned,
                               focusedWindowMatches: report.focusedWindowMatches,
                               frontApplicationMatches: report.frontApplicationMatches)
    }

    /// 写后归因表按窗口累积，空闲时必须回收（方案 §14 内存）。
    func pruneIdleChannels() {
        for identity in Array(lastWritten.keys) where !busy.contains(identity) {
            lastWritten[identity] = nil
        }
    }

    /// AX 通知的几何变化归因：写入中 = 程序；写后短窗口内读回对得上 = 程序；对不上 = 不确定。
    func changeSource(for identity: WindowIdentity, observed frame: CGRect) -> GeometryChangeSource {
        if writing.contains(identity) { return .programmatic }
        guard let last = lastWritten[identity] else { return .user }
        guard CACurrentMediaTime() - last.at < Self.attributionWindow else { return .user }
        return WindowTransaction.framesClose(frame, last.frame, tolerance: 2) ? .programmatic : .uncertain
    }

    // MARK: - 通道（只有一条：GeometryOperationScheduler）

    /// 每个 await 之后重新确认：令牌仍是当前过渡，且权限仍在（方案 §6.3）。
    private func isCurrent(_ token: TransitionToken, _ identity: WindowIdentity) -> Bool {
        guard activeToken == token, isTokenCurrent?(token) ?? true else { return false }
        guard permissions.status.isComplete else { return false }
        return catalog.record(for: identity) != nil
    }

    // MARK: - 步骤实现

    private func currentFrame(of identity: WindowIdentity) async -> CGRect? {
        guard let record = catalog.record(for: identity) else { return nil }
        guard let element = catalog.axEntry(for: record)?.element else { return record.frame }
        return await writer.currentFrame(of: element) ?? record.frame
    }

    /// 前景化的实测结果：只由读回事实构成，不写"我以为成功"（方案 §12.2）。
    private struct FrontOrderingReport {
        var activationRequested = false
        var activationReturned = false
        var raiseReturned = false
        /// 目标是否就是应用的当前 focused window。nil = 读不到，不等于"不是"。
        var focusedWindowMatches: Bool?
        /// 目标进程是否确实是当前前台进程（读 NSRunningApplication，不是 activate 的返回值）。
        var frontApplicationMatches: Bool?

        var isVerifiedFront: Bool { focusedWindowMatches == true || frontApplicationMatches == true }
        /// 只有相反证据才允许判定失败：读不到不等于失败，但也不能记成成功。
        var isProvenBehind: Bool { focusedWindowMatches == false && frontApplicationMatches == false }

        var evidence: String {
            "activate=\(activationReturned) raise=\(raiseReturned) focused读回=\(text(focusedWindowMatches)) 前台=\(text(frontApplicationMatches))"
        }

        private func text(_ value: Bool?) -> String {
            switch value {
            case .some(true): return "是"
            case .some(false): return "否"
            case nil: return "不可读"
            }
        }
    }

    /// 前景化：公开激活 API + AX Raise + 设为 focused window，不使用私有层级调用。
    /// 返回读回事实；调用方不得把"没报错"当成"已经在前面"。
    @discardableResult
    private func bringToFront(record: WindowRecord,
                             element: AXUIElement?,
                             permit: GeometryWritePermit? = nil) async -> FrontOrderingReport {
        let identity = record.identity
        var report = FrontOrderingReport()
        // 唤起同样是跨进程动作：许可已撤销（隐藏/退出/换会话）就一个调用都不发（方案 §5.2）。
        guard permit?.isGranted ?? true else {
            onStatus?("唤起未发出：本次操作许可已撤销")
            return report
        }
        if let element {
            report.raiseReturned = await writer.raise(element: element)
            _ = await writer.focus(element: element)
            // 读回而不是信任写入返回：同应用多窗口时，兄弟窗口占着 focused window 也必须看得出来。
            if let focused = await writer.focusedWindow(pid: identity.processID) {
                report.focusedWindowMatches = CFEqual(focused.element, element)
            }
        }
        guard let application = NSRunningApplication(processIdentifier: identity.processID) else {
            onStatus?("激活失败：进程已退出")
            report.frontApplicationMatches = false
            recorder.record("前景化", subject: record.applicationName, result: .failed,
                            detail: "进程已退出，无法前景化（\(report.evidence)）")
            return report
        }
        // 目标应用激活是"原生前台输入"的前提；失败时只记录，不伪装成功。
        // macOS 14 起 .activateIgnoringOtherApps 已失效，只能接受系统的前台限制策略。
        report.activationRequested = true
        report.activationReturned = application.activate(options: [])
        report.frontApplicationMatches = application.isActive
        // 这里只证明"目标到了前台"，它没有兄弟窗口可对照，因此不能写矩阵的「层级」格：
        // 那一列的定义是"展开时目标在总览前且不带动兄弟窗口"，只有 P0-3 能判。
        // 0.1.1–0.1.5 五份报告里 UGit 与 ChatGPT 的「层级=通过」就是这行代填的，属过度断言。
        recorder.record("前景化", subject: record.applicationName,
                        result: report.isProvenBehind ? .failed : (report.isVerifiedFront ? .passed : .unverified),
                        detail: "前台读回 \(report.evidence)；矩阵「层级」格由 P0-3 判，不由此项代填")
        if !report.activationReturned { onStatus?("激活 \(record.applicationName) 请求未被系统接受：\(report.evidence)") }
        return report
    }

    private func noteBlocked(_ record: WindowRecord, _ reason: String) {
        recorder.updateRow(application: record.applicationName,
                           version: "",
                           resize: .blocked,
                           knownLimitation: reason)
        onStatus?("跳过尺寸调整：\(record.applicationName)（\(reason)）")
    }

    // MARK: - 代理动画

    private func beginAnimation(_ token: TransitionToken, identity: WindowIdentity, budgetMS: Int) {
        activeToken = token
        activeIdentity = identity
        transitionBudgetMS = budgetMS
        transitionStartedAt = CACurrentMediaTime()
        scheduleWatchdog(token, budgetMS: budgetMS)
    }

    private func animate(identity: WindowIdentity,
                         token: TransitionToken,
                         from source: CGRect,
                         to destination: CGRect,
                         animationMS: Int,
                         reverse: Bool) {
        activeDirection = reverse ? .collapse : .expand
        guard source.width > 1, source.height > 1, destination.width > 1, destination.height > 1 else {
            finish(token)
            return
        }
        let display = catalog.record(for: identity).flatMap { catalog.mapper.display(id: $0.displayID) }
            ?? catalog.mapper.primaryDisplay
        guard let display, let window = ensureProxy(on: display) else {
            finish(token)
            return
        }
        let view = window.proxyView
        view.configure(cgOrigin: display.frame.origin, scale: display.backingScale)
        let sourceFrame = textureProvider?(identity)
        view.setSource(sourceFrame, sourceAspect: sourceAspect(for: identity, frame: sourceFrame, cellRect: source))
        view.onComplete = { [weak self] in self?.finish(token) }
        // 打断续接：上一段动画仍在跑时必须从画面当前位置继续，而不是从旧起点重放。
        let startRect = view.isAnimating ? view.currentRectInCG : source
        // 减少动态效果时做真正的短淡化（固定在终点矩形），而不是把同一段缩放动画调快。
        let fadeOnly = settings.sessionPolicy().reduceMotion
        window.orderFrontRegardless()
        view.animate(fromCG: startRect,
                     toCG: destination,
                     durationMS: animationMS,
                     reverse: reverse,
                     mode: fadeOnly ? .fade : .scale,
                     startAlpha: fadeOnly ? (reverse ? 1 : 0) : 1,
                     endAlpha: fadeOnly ? (reverse ? 0 : 1) : 1)
    }

    /// 动画画面比例取有效捕获内容或真实源窗口，不能用"含标题条的格子比例"（方案 §4.3）。
    private func sourceAspect(for identity: WindowIdentity, frame: MetalFrame?, cellRect: CGRect) -> CGFloat {
        if let meta = frame?.meta {
            if let size = meta.sourceSizeInPoints, size.width > 1, size.height > 1 {
                return max(0.2, size.width / size.height)
            }
            if meta.pixelWidth > 1, meta.pixelHeight > 1 {
                return max(0.2, CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight))
            }
        }
        if let record = catalog.record(for: identity), record.frame.width > 1, record.frame.height > 1 {
            return max(0.2, record.frame.width / record.frame.height)
        }
        return max(0.2, cellRect.width / max(1, cellRect.height))
    }

    private func ensureProxy(on display: DisplayInfo) -> TransitionProxyWindow? {
        let appKitFrame = catalog.mapper.cgToAppKit(display.frame)
        if let proxy {
            // 跨屏动画时移动承载窗口，避免把另一层屏幕的画面混进来。
            if proxy.frame != appKitFrame { proxy.setFrame(appKitFrame, display: false) }
            return proxy
        }
        let created = TransitionProxyWindow(screenFrame: appKitFrame, metal: metal)
        proxy = created
        return created
    }

    private func finish(_ token: TransitionToken) {
        guard activeToken == token else { return }
        let direction = activeDirection
        stopAnimation()
        switch direction {
        case .expand:
            metrics.end("过渡:展开")
            onEvent?(.expandCompleted(token))
        case .collapse:
            metrics.end("过渡:收回")
            onEvent?(.collapseCompleted(token))
        }
    }

    private func stopAnimation() {
        watchdog?.invalidate()
        watchdog = nil
        proxy?.proxyView.stop()
        proxy?.orderOut(nil)
        activeToken = nil
        activeIdentity = nil
    }

    /// 有界总超时：AX 排队、动画回调丢失都不能让状态机无限期停在过渡态。
    private func scheduleWatchdog(_ token: TransitionToken, budgetMS: Int) {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(budgetMS) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimeout(token) }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func handleTimeout(_ token: TransitionToken) {
        guard activeToken == token else { return }
        let identity = activeIdentity
        let direction = activeDirection
        let budget = transitionBudgetMS
        let waited = Int((CACurrentMediaTime() - transitionStartedAt) * 1000)
        let lastWrite = identity.flatMap { lastWritten[$0] }
        let application = identity.flatMap { catalog.record(for: $0)?.applicationName } ?? "未知应用"
        stopAnimation()
        let lastWriteText: String
        if let lastWrite {
            lastWriteText = "已写入 \(lastWrite.frame)（\(Int((CACurrentMediaTime() - lastWrite.at) * 1000))ms 前）"
        } else {
            lastWriteText = "没有写入记录"
        }
        // 只写"超时了"没法定位：方向、预算、几何是否已落、隔了多久才是下一次复跑要对比的事实。
        recorder.record("过渡超时",
                        subject: identity?.journalKey ?? "unknown",
                        result: .failed,
                        detail: "\(direction == .expand ? "展开" : "收回")在 \(budget)ms 内未确认（实际等了 \(waited)ms）；"
                              + "目标=\(application)，令牌=\(token.generation)，"
                              + "几何\(lastWriteText)，"
                              + "已按状态机降级")
        onStatus?("过渡超时，已降级处理")
        // 超时不能把窗口留在中间尺寸：已经改过几何就补一次恢复（方案 §6.3）。
        // 恢复只有一个执行者：RecoveryCoordinator 站在同一条调度通道里做逐条恢复，
        // 这里不再自己起第二条写入路径，也不绕过准入（方案 §14.2）。
        if let identity, let entry = store.entry(for: identity), entry.state.requiresRestore {
            Task { [weak self] in
                guard let self else { return }
                let item = await self.recovery.restore(entry: entry, token: token)
                self.onStatus?("超时补偿恢复：\(item.outcome.message)")
            }
        }
        onEvent?(.transitionTimedOut(token))
    }

    private func report(token: TransitionToken, reason: String) {
        onStatus?("展开被拒绝：\(reason)")
        recorder.record("展开前置条件", subject: reason, result: .blocked, detail: reason)
        // 前置条件失败发生在 beginAnimation 之前：不能停掉别人的动画，但必须让状态机离开过渡态。
        if activeToken == token { stopAnimation() }
        onEvent?(.transitionTimedOut(token))
    }
}
