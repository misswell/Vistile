import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 工作台的两窗口动作执行器（方案 §8.2、§21 M2）：
/// 会话级串行——A/B 交换、模式过渡与布局微调共用一条队列，绝不同时写两个窗口；
/// 每次 AX 写入都先确认事务已落盘，写入后按读回判定；失败按逆序补偿后才报告结果。
/// 这里不自己决定"现在算什么状态"：每步结果都回报 reducer，再按 reducer 的态度继续或回滚。
@MainActor
final class WorkbenchSwitchCoordinator {
    var onEvent: ((SessionEvent) -> Void)?
    var onStatus: ((String) -> Void)?

    /// reducer 对本次交换当前的态度（由 AppCoordinator 从唯一状态机读出）。
    enum SwitchDirective: Equatable {
        case proceed
        case rollback(reason: String)
        /// 令牌已作废或状态已不属于这次交换：停在原地，不再写任何窗口。
        case aborted
    }

    /// 一次动作的总限时：AX 无响应或应用挂起必须有界收敛（方案 §8.3、§10.5）。
    /// 每步 AX 调用本身带 0.35s 消息超时，所以到期后最多再等一个步骤就能到检查点。
    static let switchDeadline: TimeInterval = 2.5

    private let catalog: WindowCatalog
    private let writer: GeometryWriting
    private let store: WindowJournalStore
    private let recovery: RecoveryCoordinator
    private let focus: FocusCoordinator
    private let permissions: PermissionChecking
    private let metrics: Metrics
    private let recorder: CompatibilityRecorder

    /// 在途令牌：只有它的结果与后续步骤还算数。
    private(set) var activeToken: TransitionToken?
    private var tail: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var deadline: Date?
    private(set) var didTimeOut = false
    /// 同一次动作只补偿一次：超时与失败路径可能都走到补偿，不能重复写窗口。
    private var didRollback = false
    /// 本次动作真正动过的窗口：补偿只允许写这些身份（方案 §8.3）。
    /// 被拦在准备/校验阶段的动作一个窗口都没动，回滚不许把仍在主区的 A 拉走。
    private var touched: Set<WindowIdentity> = []

    init(catalog: WindowCatalog,
         writer: GeometryWriting,
         store: WindowJournalStore,
         recovery: RecoveryCoordinator,
         focus: FocusCoordinator,
         permissions: PermissionChecking,
         metrics: Metrics,
         recorder: CompatibilityRecorder) {
        self.catalog = catalog
        self.writer = writer
        self.store = store
        self.recovery = recovery
        self.focus = focus
        self.permissions = permissions
        self.metrics = metrics
        self.recorder = recorder
    }

    /// 由 AppCoordinator 注入：从唯一状态机读出这次交换此刻的态度。
    var directive: (TransitionToken) -> SwitchDirective = { _ in .proceed }

    var isBusy: Bool { activeToken != nil }
    var didReachDeadline: Bool { didTimeOut }

    // MARK: - 模式过渡（进入工作台 / 返回总览）

    func perform(_ plan: WorkbenchTransitionPlan) {
        enqueue { [weak self] in
            guard let self else { return }
            self.beginLifetime(plan.token, name: plan.kind.displayName)
            defer { self.endLifetime(plan.token) }
            switch plan.kind {
            case .enteringWorkbench:
                let started = Date()
                var outcome: WorkbenchStepOutcome
                if await self.catalog.hasBlockingSheet(identity: plan.identity) {
                    // 选中的窗口挂着用户还没处理的对话框：不动它，也不进 L 型（方案 §8.2.4、§10.4）。
                    outcome = .rejected(self.sheetRefusal(identity: plan.identity))
                } else {
                    outcome = await self.placeMain(plan.identity,
                                                   targetFrame: plan.targetFrame,
                                                   token: plan.token,
                                                   activate: true).step
                }
                outcome = self.enforceDeadline(outcome)
                self.metrics.measure("工作台:进入主区",
                                     milliseconds: Date().timeIntervalSince(started) * 1000,
                                     context: outcome.message)
                VistileLog.session.log(level: .debug,
                                       "[过渡] 进入工作台 对象=\(plan.identity.journalKey, privacy: .public) 结论=\(outcome.message, privacy: .public)")
                // 令牌被取消（锁屏、Space、退出）后由系统级恢复接管：这里不再自开补偿。
                guard self.activeToken == plan.token else { return }
                if outcome.isFailure {
                    // 失败留在原总览，同时把已经改过的几何补偿回原 frame（方案 §4.2.7）。
                    // 补偿结果必须先回报：journal 已经结算而 state 还留在"待恢复"，
                    // 退出恢复就会去读一条不存在的日志条目，误报"尺寸未能恢复"（方案 §6.4）。
                    let item = await self.restoreQuietly(plan.identity, note: "进入工作台未完成")
                    if let item {
                        self.onEvent?(.geometryRestoreSettled(token: plan.token, items: [item]))
                    }
                }
                self.onEvent?(.workbenchTransitionFinished(token: plan.token,
                                                           kind: .enteringWorkbench,
                                                           result: outcome))

            case .returningOverview:
                let started = Date()
                var outcome = await self.restoreMain(plan.identity, token: plan.token)
                outcome = self.enforceDeadline(outcome)
                self.metrics.measure("工作台:返回总览",
                                     milliseconds: Date().timeIntervalSince(started) * 1000,
                                     context: outcome.message)
                VistileLog.session.log(level: .debug,
                                       "[过渡] 返回总览 对象=\(plan.identity.journalKey, privacy: .public) 结论=\(outcome.message, privacy: .public)")
                guard self.activeToken == plan.token else { return }
                self.onEvent?(.workbenchTransitionFinished(token: plan.token,
                                                           kind: .returningOverview,
                                                           result: outcome))
            }
        }
    }

    // MARK: - A/B 交换

    func perform(_ plan: WorkbenchSwitchPlan) {
        enqueue { [weak self] in
            guard let self else { return }
            self.beginLifetime(plan.intent.token, name: "主区交换")
            defer { self.endLifetime(plan.intent.token) }
            let intent = plan.intent
            let token = intent.token
            let started = Date()
            defer {
                self.metrics.measure("工作台:主区交换",
                                     milliseconds: Date().timeIntervalSince(started) * 1000,
                                     context: intent.source.displayName)
            }

            // prepare：事务、句柄与模态事实先核对，缺任何一项都不写窗口（方案 §8.2.3、§8.2.4）。
            let prepared = await self.prepare(intent: intent)
            self.report(step: .prepare, outcome: prepared, identity: intent.to, token: token)
            guard await self.proceedOrRollback(plan, after: prepared, token: token) else { return }

            // moveToMain：B 进主区。读回为准，应用按自身约束返回也算继续（要写进事实）。
            let movePlacement = await self.placeMain(intent.to,
                                                     targetFrame: plan.mainTargetFrame,
                                                     token: token,
                                                     activate: false)
            if movePlacement.geometry != nil { self.touched.insert(intent.to) }
            let moved = self.enforceDeadline(movePlacement.step)
            self.report(step: .moveToMain, outcome: moved, identity: intent.to, token: token)
            guard await self.proceedOrRollback(plan, after: moved, token: token) else { return }

            // activateMain：真实主窗口必须可操作；只有相反证据才算失败（方案 §12.2）。
            let activation = await self.focus.activateAndRaise(intent.to)
            let activationOutcome: WorkbenchStepOutcome = activation.isProvenBehind
                ? .rejected("未确认 \(intent.to.journalKey) 已到前台（\(activation.evidence)）")
                : .succeeded(readBack: nil)
            self.report(step: .activateMain, outcome: activationOutcome, identity: intent.to, token: token)
            guard await self.proceedOrRollback(plan, after: activationOutcome, token: token) else { return }

            // restorePrevious：A 回它原来的 slot 位置。写回后同应用兄弟窗口可能被顶到前面，要再确认一次。
            var restoreOutcome: WorkbenchStepOutcome = .succeeded(readBack: nil)
            if let from = intent.from, let resting = plan.restingTargetFrame {
                let restorePlacement = await self.placeMain(from, targetFrame: resting, token: token, activate: false)
                if restorePlacement.geometry != nil { self.touched.insert(from) }
                restoreOutcome = restorePlacement.step
                if !restoreOutcome.isFailure, from.processID == intent.to.processID {
                    // 同进程里改 A 的几何会把它带到兄弟窗口之前：把 B 再提到前台一次（方案 §17 同应用多窗口）。
                    let recheck = await self.focus.activateAndRaise(intent.to)
                    if recheck.isProvenBehind {
                        restoreOutcome = .rejected("写回原主后 B 不再处于前台（\(recheck.evidence)）")
                    }
                }
            }
            self.report(step: .restorePrevious, outcome: restoreOutcome, identity: intent.from, token: token)
            guard await self.proceedOrRollback(plan, after: restoreOutcome, token: token) else { return }

            // commit：placement 的提交只在 reducer 里发生；这里只证明"该写的都写完了"。
            self.report(step: .commit, outcome: .succeeded(readBack: nil), identity: intent.to, token: token)
            guard await self.proceedOrRollback(plan, after: .succeeded(readBack: nil), token: token) else { return }
            self.onEvent?(.mainSwitchCommitted(token: token))
        }
    }

    // MARK: - 布局微调（侧栏切换 / 分隔线收敛）

    func settle(_ identity: WindowIdentity, targetFrame: CGRect, displayID: UInt32, token: TransitionToken) {
        enqueue { [weak self] in
            guard let self else { return }
            let placed = await self.placeMain(identity, targetFrame: targetFrame, token: token, activate: false)
            // 写没写过都必须是真实结论：没写的失败原因原样带给 reducer（方案 §6.1）。
            let writeOutcome = placed.geometry ?? .rejected(.preconditionFailed(placed.step.message))
            if case .rejected = writeOutcome {
                self.onStatus?("主窗口尺寸未调整：\(placed.step.message)")
            }
            self.onEvent?(.geometryWriteFinished(GeometryWriteResult(identity: identity,
                                                                    token: token,
                                                                    operationID: UUID(),
                                                                    targetFrame: targetFrame,
                                                                    displayID: displayID,
                                                                    outcome: writeOutcome)))
        }
    }

    /// 取消（锁屏、Space 切换、退出）：停止后续步骤，不再写任何窗口。
    /// 已写入的窗口由事务日志交给既有恢复路径，不在这里另开一条补偿。
    func cancel() {
        watchdog?.cancel()
        watchdog = nil
        activeToken = nil
        deadline = nil
        didTimeOut = false
        didRollback = true
    }

    // MARK: - 串行队列

    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            _ = await previous?.value
            await body()
        }
    }

    // MARK: - 步骤实现

    /// 一次几何写入之后的两侧事实：给 reducer 的步骤结论，和原始写入结果。
    /// settle 需要原始结果，不能把 `.unreadable` 之类压平成一句字符串。
    private struct PlacementResult {
        let step: WorkbenchStepOutcome
        let geometry: GeometryOutcome?

        static func refused(_ reason: String) -> PlacementResult {
            PlacementResult(step: .rejected(reason), geometry: nil)
        }
    }

    private func prepare(intent: WorkbenchSwitchIntent) async -> WorkbenchStepOutcome {
        guard permissions.status.isComplete else { return .rejected("权限已收回，未写入任何窗口") }
        for identity in [intent.to, intent.from].compactMap({ $0 }) {
            guard catalog.record(for: identity) != nil else {
                return identity == intent.to ? .targetGone : .rejected("原主窗口已不在目录里")
            }
            guard store.entry(for: identity)?.state.requiresRestore == true else {
                return .rejected("几何事务未落盘（\(identity.journalKey)），拒绝写入")
            }
        }
        // A 挂着用户还没处理的对话框：不擅自关闭，也不动任何窗口（方案 §8.2.4、§10.4）。
        if let from = intent.from, await catalog.hasBlockingSheet(identity: from) {
            return .rejected(sheetRefusal(identity: from))
        }
        return .succeeded(readBack: nil)
    }

    private func sheetRefusal(identity: WindowIdentity) -> String {
        let name = catalog.record(for: identity)?.applicationName ?? "该应用"
        return "请先处理当前对话框（\(name)）"
    }

    /// 把真实窗口送到目标 frame（可同时带到前台）。返回的是读回事实，不是"我以为到位"。
    private func placeMain(_ identity: WindowIdentity,
                           targetFrame: CGRect,
                           token: TransitionToken,
                           activate: Bool) async -> PlacementResult {
        guard permissions.status.isComplete else {
            return .refused("权限已收回，未写入窗口几何")
        }
        guard store.entry(for: identity)?.state.requiresRestore == true else {
            return .refused("几何事务未落盘，已拒绝写入")
        }
        guard var record = catalog.record(for: identity) else {
            return PlacementResult(step: .targetGone, geometry: .targetGone)
        }

        // 最小化窗口先解除：拿不到句柄就不谎称"已经展开"（方案 §10.1）。
        if record.isMinimized || record.capture == .pausedMinimized {
            guard let element = catalog.axEntry(for: record)?.element else {
                return .refused("\(record.applicationName) 的最小化窗口缺少 AX 句柄")
            }
            let released = await writer.setMinimized(false, element: element)
            guard released else {
                return .refused("\(record.applicationName) 未解除最小化")
            }
            await catalog.refreshAndWait(reason: .windowEvent)
            guard let fresh = catalog.record(for: identity) else {
                return PlacementResult(step: .targetGone, geometry: .targetGone)
            }
            guard fresh.allowsAutoFocus else {
                return .refused("解除最小化后该窗口仍不可聚焦")
            }
            record = fresh
        }

        // 句柄取不到先复核目录（带截止时间反复复核：窗口移动中的瞬时坏采样，或捕捉权限成串短暂被拒），
        // 预算用尽仍拿不到才按事实拒绝。
        guard let ax = await catalog.axEntryAfterReview(for: record) else {
            return .refused("拿不到 AX 句柄（身份未唯一确定）")
        }
        // 目录里的"不可调整"来自上一次采样的快照：跨进程读一次超时就会被折叠成 false，
        // 把一次读不到当成窗口事实。身份已唯一、句柄在手时，用最新目录再判一次，
        // 仍说不可控就直接问窗口本身：只有读到确凿的不可写才拒绝；
        // 读不到同样不是事实，交给写入自身的读回结论（方案 §6.1）。
        if !record.allowsGeometryControl {
            let current = catalog.record(for: identity) ?? record
            record = current
            if !current.allowsGeometryControl {
                if !current.allowsAutoFocus {
                    return .refused("\(current.applicationName) 当前受限（\(current.restriction.map { "\($0)" } ?? "身份未唯一确定")），未写入几何")
                }
                switch await writer.geometryWriteability(element: ax.element) {
                case .sizeNotSettable:
                    return .refused("AX 确认该窗口不接受尺寸调整")
                case .positionNotSettable:
                    return .refused("AX 确认该窗口不接受位置调整")
                case .writeable, .unreadable:
                    break
                }
            }
        }

        let started = Date()
        // 事务创建时记下的"原位置"来自目录快照：快速往返里快照可能落后一整轮，把上一轮的主区
        // 位置当成原位置——返回时"已在原位置"直接跳过，窗口被永久留在主区。首个写入前用实读
        // 纠一次，只限从未写过的事务；写过的原位置已经过读回验证，不再改写（方案 §6.2）。
        if let entry = store.entry(for: identity), entry.hasSpeculativeOriginal,
           let before = await writer.currentFrame(of: ax.element),
           !WindowTransaction.framesClose(before, entry.originalFrame, tolerance: 2) {
            let persisted = store.correctOriginal(identity, frame: before, displayID: record.displayID)
            if !persisted.isPersisted {
                VistileLog.session.log(level: .error,
                                       "原位置修正落盘失败: \(identity.journalKey, privacy: .public)")
            }
            VistileLog.session.log(level: .debug,
                                   "[原位置] \(identity.journalKey, privacy: .public) 目录快照=\(RecoveryCoordinator.text(entry.originalFrame), privacy: .public) 写前实读=\(RecoveryCoordinator.text(before), privacy: .public) 结论=按实读修正")
        }
        focus.beginProgrammaticWrite(identity)
        let write = await writer.apply(frame: targetFrame, element: ax.element)
        focus.endProgrammaticWrite(identity, frame: write.displayFrame)
        metrics.measure("工作台:几何写入",
                        milliseconds: Date().timeIntervalSince(started) * 1000,
                        context: write.outcome.message)
        // 写前、目标与读回三值都进日志：实机验收判定"到位"必须能核对这三个值（方案 §6.1、§14）。
        VistileLog.session.log(level: .debug,
                               "[写入] \(identity.journalKey, privacy: .public) 目标=\(RecoveryCoordinator.text(targetFrame), privacy: .public) 写前=\(write.frameBeforeWrite.map(RecoveryCoordinator.text) ?? "-", privacy: .public) 读回=\(write.readBack.map(RecoveryCoordinator.text) ?? "-", privacy: .public) size错误=\(write.sizeWriteError) position错误=\(write.positionWriteError) 结论=\(write.outcome.message, privacy: .public)")

        let outcome: WorkbenchStepOutcome
        switch write.outcome {
        case let .exact(readBack):
            outcome = .succeeded(readBack: readBack)
        case let .constrained(readBack):
            let note = "应用按自身尺寸约束返回 \(RecoveryCoordinator.text(readBack))"
            recorder.updateRow(application: record.applicationName, version: "",
                               resize: .failed,
                               knownLimitation: note)
            outcome = .constrained(readBack: readBack, note: note)
        case let .rejected(reason):
            outcome = .rejected(reason.message)
        case .unreadable:
            outcome = .rejected("写入后无法读回 frame，不能宣称到位")
        case .targetGone:
            outcome = .targetGone
        }

        if activate, !outcome.isFailure {
            let facts = await focus.activateAndRaise(identity)
            if facts.isProvenBehind {
                return PlacementResult(step: .rejected("\(record.applicationName) 没能带到前台（\(facts.evidence)）"),
                                       geometry: write.outcome)
            }
        }
        return PlacementResult(step: outcome, geometry: write.outcome)
    }

    /// 返回总览：写回 resting frame 并让同一套恢复规则收口事务（方案 §4.4、§6.5）。
    private func restoreMain(_ identity: WindowIdentity, token: TransitionToken) async -> WorkbenchStepOutcome {
        guard let entry = store.entry(for: identity) else {
            return .rejected("事务日志里没有该窗口的记录，未写回几何")
        }
        guard entry.state.requiresRestore else {
            // 已经被恢复过（例如用户在返回前手动改回原状）：不是失败，也不是"我们写回成功"。
            return .succeeded(readBack: nil)
        }
        let started = Date()
        let item = await recovery.restore(entry: entry)
        metrics.measure("工作台:写回原尺寸",
                        milliseconds: Date().timeIntervalSince(started) * 1000,
                        context: item.outcome.message)
        VistileLog.session.log(level: .debug,
                               "[写回] \(identity.journalKey, privacy: .public) 结论=\(item.outcome.message, privacy: .public)")
        switch item.outcome {
        case .restored, .alreadyAtOriginal, .keptUserGeometry:
            return .succeeded(readBack: nil)
        case let .constrained(deviation):
            // RestoreOutcome 只带偏差，不带读回值：偏差是这一格的事实，读回仅用于展示。
            let readBack = catalog.record(for: identity)?.frame ?? entry.originalFrame
            return .constrained(readBack: readBack,
                                note: "写回偏差 \(String(format: "%.1f", deviation))pt")
        case .userMoved:
            // 用户自己把它拖走了：事务按预期结束，不覆盖用户位置（方案 §10.4）。
            return .succeeded(readBack: nil)
        case .windowGone:
            return .targetGone
        case let .rejected(reason):
            return .rejected(reason)
        case .unreadable:
            return .rejected("写回后无法读回 frame")
        case let .notAttempted(reason):
            return .rejected(reason)
        }
    }

    /// 失败补偿：把已经改过的窗口交回既有恢复路径，绝不静默留在半路。
    /// 返回逐条结果：调用方负责回报 reducer，让 state 侧与 journal 同步收口（方案 §6.4）。
    @discardableResult
    private func restoreQuietly(_ identity: WindowIdentity, note: String) async -> RestoreItemResult? {
        guard let entry = store.entry(for: identity), entry.state.requiresRestore else { return nil }
        let item = await recovery.restore(entry: entry)
        if item.outcome.isFailure {
            recorder.note("\(note)：\(identity.journalKey) 补偿恢复未完成（\(item.outcome.message)）")
        }
        return item
    }

    /// 交换失败：只逆序补偿这次真正动过的窗口，然后报告 mainSwitchFailed（placement 不提交）。
    /// 准备阶段被拦下时一个窗口都没动：A 必须保持主窗口不动（方案 §8.3）。
    /// 同一次动作只补偿一次；超时与步骤失败可能先后到达。
    private func rollback(_ plan: WorkbenchSwitchPlan, reason: String) async {
        guard !didRollback else { return }
        didRollback = true
        recorder.note("工作台交换回滚：\(reason)")
        var compensated: [RestoreItemResult] = []
        if let from = plan.intent.from, touched.contains(from),
           let item = await restoreQuietly(from, note: "交换回滚：原主窗口") {
            compensated.append(item)
        }
        if touched.contains(plan.intent.to),
           let item = await restoreQuietly(plan.intent.to, note: "交换回滚：目标窗口") {
            compensated.append(item)
        }
        // 补偿结果先于 mainSwitchFailed 回报：state 侧必须在收口前看到 journal 的真实结局。
        if !compensated.isEmpty {
            onEvent?(.geometryRestoreSettled(token: plan.intent.token, items: compensated))
        }
        onEvent?(.mainSwitchFailed(token: plan.intent.token, reason: reason))
    }

    // MARK: - reducer 态度

    /// 每步之后问一次 reducer：继续、回滚、还是令牌已作废。
    private func proceedOrRollback(_ plan: WorkbenchSwitchPlan,
                                   after outcome: WorkbenchStepOutcome,
                                   token: TransitionToken) async -> Bool {
        guard activeToken == token else { return false }
        if didTimeOut || isPastDeadline {
            didTimeOut = true
            await rollback(plan, reason: "超过 \(Int(Self.switchDeadline * 1000))ms 未收敛")
            return false
        }
        if outcome.isFailure {
            await rollback(plan, reason: outcome.message)
            return false
        }
        switch directive(token) {
        case .proceed:
            return true
        case let .rollback(reason):
            await rollback(plan, reason: reason)
            return false
        case .aborted:
            return false
        }
    }

    private func report(step: WorkbenchSwitchStep,
                        outcome: WorkbenchStepOutcome,
                        identity: WindowIdentity?,
                        token: TransitionToken) {
        guard activeToken == token else { return }
        // 每一步的真实结论进诊断日志：实机验收要靠它还原"哪一步、什么事实"（方案 §14）。
        VistileLog.session.log(level: .debug,
                               "[交换] 步骤=\(step.displayName, privacy: .public) 对象=\(identity?.journalKey ?? "-", privacy: .public) 结论=\(outcome.message, privacy: .public)")
        onEvent?(.mainSwitchStepFinished(WorkbenchSwitchStepResult(token: token,
                                                                   step: step,
                                                                   outcome: outcome,
                                                                   identity: identity)))
    }

    // MARK: - 令牌与限时

    /// 每次动作开始时建立生命周期：令牌生效、限时起算、补偿只做一次。
    private func beginLifetime(_ token: TransitionToken, name: String) {
        activeToken = token
        deadline = Date().addingTimeInterval(Self.switchDeadline)
        didTimeOut = false
        didRollback = false
        touched = []
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.switchDeadline * 1_000_000_000))
            guard !Task.isCancelled, let self, self.activeToken == token, !self.didTimeOut else { return }
            // 到点先把状态机推出在途态（reducer 收到后转入回滚/取消），
            // 补偿由串行队列里的同一次动作在下一个检查点完成——绝不与在途写入并发。
            self.didTimeOut = true
            self.recorder.note("工作台\(name)超过 \(Int(Self.switchDeadline * 1000))ms 未收敛，按超时处理")
            self.onStatus?("\(name)超时，正在收敛")
            self.onEvent?(.transitionTimedOut(token))
        }
    }

    private func endLifetime(_ token: TransitionToken) {
        watchdog?.cancel()
        watchdog = nil
        guard activeToken == token else { return }
        activeToken = nil
        deadline = nil
    }

    /// 超过总限时：把结果改写成失败，几何由调用方补偿（方案 §10.5）。
    private func enforceDeadline(_ outcome: WorkbenchStepOutcome) -> WorkbenchStepOutcome {
        guard isPastDeadline else { return outcome }
        didTimeOut = true
        guard !outcome.isFailure else { return outcome }
        return .rejected("超过 \(Int(Self.switchDeadline * 1000))ms 未收敛")
    }

    private var isPastDeadline: Bool {
        guard let deadline else { return false }
        return Date() >= deadline
    }
}
