import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import VistileCore

/// 工作台的两窗口动作执行器（方案 §8.2、§5、§6.3、§7.2、§9、§21 M2）。
///
/// 所有真实写入都只有一条路：`GeometryOperationScheduler`。
/// - 每一步都带操作上下文，并在执行前重新核对会话/代次/相位/令牌/许可/预算；
/// - 日志先行：`prepare` 成功后才发第一笔 AX 写入（`.journalPrepared`）；
/// - 进主区的方式由 `MainPlacementPolicy` 决定：可调尺寸=占满主区，固定尺寸=真实尺寸仅移动，
///   放不下=拒绝并保持 A 与两栏不动；
/// - 失败只补偿"确实动过"的窗口，逆序执行；无需保留外部焦点时才把 A 真的激活；
/// - 补偿事实（`WorkbenchCompensationResult`）必须先于 `mainSwitchFailed` 回报。
@MainActor
final class WorkbenchSwitchCoordinator {
    var onEvent: ((SessionEvent) -> Void)?
    /// 主区停靠模式（设置可切换）：写前实读的放置决策必须与 reducer 计划同一份。
    var mainAreaDocking: MainAreaDocking = .respectful

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
    static let switchDeadline: Duration = .milliseconds(2_500)
    /// 交互路径的 AX 句柄复核预算：目录偶发读超时时，2s 的默认预算会让点击看起来"卡住/模糊很久"。
    /// 交互路径用完 1s 就按失败收口；恢复/退出仍走 `WindowCatalog.axConfirmBudget` 的 2s（宁可慢也要还原）。
    static let interactiveAXBudget: TimeInterval = 1.0

    private let catalog: WindowCatalog
    private let writer: GeometryWriting
    private let store: WindowJournalStore
    private let recovery: RecoveryCoordinator
    private let focus: FocusCoordinator
    private let permissions: PermissionChecking
    private let metrics: Metrics
    private let recorder: CompatibilityRecorder
    private let scheduler: GeometryOperationScheduler

    /// 由 AppCoordinator 注入：从唯一状态机读出这次交换此刻的态度。
    var directive: (TransitionToken) -> SwitchDirective = { _ in .proceed }
    /// 当前令牌已有排队的外部焦点：旧交换只补偿几何，不再抢回任何窗口的焦点。
    var shouldPreserveExternalFocus: (TransitionToken) -> Bool = { _ in false }
    var frontmostProcessID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    /// 在途操作：只有它的结果与后续步骤还算数。
    private(set) var activeContext: GeometryOperationContext?
    private var watchdog: Task<Void, Never>?
    private var deadline: GeometryOperationScheduler.Stamp?
    private(set) var didTimeOut = false
    /// 同一次动作只补偿一次：超时与失败路径可能都走到补偿，不能重复写窗口。
    private var didRollback = false
    /// 本次动作真正动过的窗口与动过的方式：补偿只允许覆盖这些事实（方案 §6.3）。
    private var sideEffects: [SideEffect] = []
    /// 步骤耗时打点：连到统一日志里，实机调优才有"哪一步慢"的证据，而不是只看总时长。
    private var stepClock: CFTimeInterval = 0
    /// 本次动作名义上负责的窗口：清理"计划已落盘但从未写入"的事务时只能按这份名单，
    /// 别的操作名下的事务一个都不许碰（方案 §6.4、A12）。
    private var activeIdentities: [WindowIdentity] = []
    /// latest-wins 合并键前缀：布局微调同一主窗口只保留最后一个未执行目标。
    private var settleCounter = 0

    /// 一次步骤产生的真实副作用：补偿按逆序还原。
    private struct SideEffect: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            /// 写了 frame；`wasMinimized` 记录这个窗口原本是 Vistile 为本次操作解除的最小化（方案 §10.1）。
            case geometry(restoredMinimized: Bool)
            /// 只把它带到过前台：不需要写几何，但补偿必须重新确认真实前台。
            case activation
            /// Vistile 为本次操作解除过最小化：解除成功当场登记，任何提前返回都必须收回去（方案 §6.4）。
            case minimizeRelease
        }
        let identity: WindowIdentity
        let kind: Kind
    }

    init(catalog: WindowCatalog,
         writer: GeometryWriting,
         store: WindowJournalStore,
         recovery: RecoveryCoordinator,
         focus: FocusCoordinator,
         permissions: PermissionChecking,
         metrics: Metrics,
         recorder: CompatibilityRecorder,
         scheduler: GeometryOperationScheduler) {
        self.catalog = catalog
        self.writer = writer
        self.store = store
        self.recovery = recovery
        self.focus = focus
        self.permissions = permissions
        self.metrics = metrics
        self.recorder = recorder
        self.scheduler = scheduler
    }

    var isBusy: Bool { activeContext != nil }
    var didReachDeadline: Bool { didTimeOut }

    /// 交换 + 模式过渡 + 布局微调共用的忙判据：调度器里还有活也算忙（方案 §5.4）。
    var isBusyIncludingScheduler: Bool { activeContext != nil || !scheduler.isIdle }

    // MARK: - 模式过渡（进入工作台 / 返回总览）

    /// AX 通道排队时长（方案 §20.2 的独立端点）：从提交作业到真正拿到许可开始执行。
    /// 混在"进入主区"总耗时里就永远分不清是写入慢还是排在别人后面。
    private func noteQueueDelay(_ queuedAt: CFTimeInterval, context: String) {
        metrics.measure("工作台:AX 排队",
                        milliseconds: (CACurrentMediaTime() - queuedAt) * 1000,
                        context: context)
    }

    /// 写后读回单独打点（方案 §20.2）：读回带着 3×70ms 的有界重试，混进"写入"总耗时里
    /// 就分不清是 AX 写慢，还是应用刚被改几何时短暂读不到。
    private func noteReadBack(_ report: GeometryWriteReport) {
        guard let readBackMS = report.readBackMS else { return }
        metrics.measure("工作台:几何读回", milliseconds: readBackMS, context: report.outcome.message)
    }

    func perform(_ plan: WorkbenchTransitionPlan) {
        let kind: GeometryOperationKind = plan.kind == .enteringWorkbench ? .enterWorkbench : .returnOverview
        let context = plan.operationContext
        guard context.matches(sessionID: scheduler.sessionID, epoch: scheduler.sessionEpoch) else {
            onEvent?(.workbenchTransitionFinished(token: plan.token, kind: plan.kind,
                                                  result: .rejected("会话代次已更新，本次过渡未开始")))
            return
        }
        let queuedAt = CACurrentMediaTime()
        let admitted = scheduler.perform(GeometryOperationScheduler.Operation(context: context,
                                    identities: transitionIdentities(of: plan),
                                    coalesceKey: "transition:\(plan.identity.journalKey)",
                                    deadline: scheduler.deadline(after: Self.switchDeadline),
                                    onSkipped: { [weak self] reason in
                                        // 被丢弃的作业不会再进 run：先交还会话所有权，再按"未写入"回报（方案 §5.5）。
                                        self?.endLifetime(context)
                                        self?.reportSkipped(reason, context: context, token: plan.token,
                                                            kind: plan.kind)
                                    },
                                    run: { [weak self] permit in
                                        self?.noteQueueDelay(queuedAt,
                                                             context: plan.kind == .enteringWorkbench ? "进入工作台" : "返回总览")
                                        await self?.runTransition(plan, context: context, permit: permit)
                                    }))
        guard admitted else {
            // 连准入都没拿到（相位已关闭/代次已变）：这次过渡从未开始，必须给状态机一个真实结论。
            onEvent?(.workbenchTransitionFinished(token: plan.token, kind: plan.kind,
                                                  result: .rejected("调度器未受理本次过渡（会话或相位已变）")))
            return
        }
        beginLifetime(context, identities: transitionIdentities(of: plan))
    }

    private func transitionIdentities(of plan: WorkbenchTransitionPlan) -> [WindowIdentity] {
        [plan.identity] + plan.railHandoffs.map(\.identity)
    }

    private func runTransition(_ plan: WorkbenchTransitionPlan,
                               context: GeometryOperationContext,
                               permit: GeometryWritePermit) async {
        defer { endLifetime(context) }
        switch plan.kind {
        case .enteringWorkbench:
            let started = CACurrentMediaTime()
            guard stillValid(context, token: plan.token) else { return }
            let outcome: WorkbenchStepOutcome
            if await catalog.hasBlockingSheet(identity: plan.identity) {
                // 选中的窗口挂着用户还没处理的对话框：不动它，也不进 L 型（方案 §8.2.4、§10.4）。
                outcome = .rejected(sheetRefusal(identity: plan.identity))
            } else if !verifyJournalPrepared(context: context, identities: [plan.identity]) {
                // 轨道上的卡片只是动画端点，不写 AX：进入这一步要核对的只有主窗口。
                outcome = .rejected("几何事务未原子落盘，未写入任何窗口")
            } else {
                let placement = await placeMain(plan.identity,
                                                mainRect: plan.snapshot.mainRect,
                                                topRailRect: plan.snapshot.layout.topRailRect,
                                                sideRailRect: plan.snapshot.layout.sideRailRect,
                                                context: context,
                                                permit: permit,
                                                activate: true,
                                                fallbackTarget: plan.targetFrame)
                outcome = placement.step
            }
            let final = enforceDeadline(outcome)
            metrics.measure("工作台:进入主区",
                            milliseconds: (CACurrentMediaTime() - started) * 1000,
                            context: final.message)
            VistileLog.session.log(level: .info,
                                   "[过渡] 进入工作台 对象=\(plan.identity.journalKey, privacy: .public) 结论=\(final.message, privacy: .public)")
            guard activeContext == context else { return }
            if final.allowsContinue == false {
                // 失败先补偿再回报：journal 与 state 必须同时收口（方案 §6.4）。
                await compensate(reason: final.message, context: context, token: plan.token,
                                reActivate: nil, transition: true)
            }
            onEvent?(.workbenchTransitionFinished(token: plan.token, kind: .enteringWorkbench, result: final))

        case .returningOverview:
            let started = CACurrentMediaTime()
            guard stillValid(context, token: plan.token) else { return }
            let outcome = await restoreMain(plan.identity, context: context, permit: permit)
            let final = enforceDeadline(outcome)
            metrics.measure("工作台:返回总览",
                            milliseconds: (CACurrentMediaTime() - started) * 1000,
                            context: final.message)
            VistileLog.session.log(level: .info,
                                   "[过渡] 返回总览 对象=\(plan.identity.journalKey, privacy: .public) 结论=\(final.message, privacy: .public)")
            guard activeContext == context else { return }
            onEvent?(.workbenchTransitionFinished(token: plan.token, kind: .returningOverview, result: final))
        }
    }

    // MARK: - A/B 交换

    func perform(_ plan: WorkbenchSwitchPlan) {
        let context = plan.intent.operationContext
        let token = plan.intent.token
        guard context.matches(sessionID: scheduler.sessionID, epoch: scheduler.sessionEpoch) else {
            reportSwitchFailure(token: token,
                                reason: "会话代次已更新，本次交换未开始",
                                compensation: nil)
            return
        }
        let identities: [WindowIdentity] = [plan.intent.to, plan.intent.from].compactMap { $0 }
        let queuedAt = CACurrentMediaTime()
        let admitted = scheduler.perform(GeometryOperationScheduler.Operation(context: context,
                                    identities: identities,
                                    coalesceKey: "switch:\(token.id.uuidString)",
                                    deadline: scheduler.deadline(after: Self.switchDeadline),
                                    onSkipped: { [weak self] reason in
                                        // 被丢弃的交换没碰过任何窗口：交还会话所有权后按"未写入"失败收口（方案 §5.5）。
                                        self?.endLifetime(context)
                                        self?.reportSwitchFailure(token: token,
                                                                  reason: SetupMessages.skipped(reason),
                                                                  compensation: nil)
                                    },
                                    run: { [weak self] permit in
                                        self?.noteQueueDelay(queuedAt, context: "主区交换")
                                        await self?.runSwitch(plan, context: context, permit: permit)
                                    }))
        guard admitted else {
            reportSwitchFailure(token: token,
                                reason: "调度器未受理本次交换（会话或相位已变）",
                                compensation: nil)
            return
        }
        beginLifetime(context, identities: identities)
    }

    private func runSwitch(_ plan: WorkbenchSwitchPlan,
                           context: GeometryOperationContext,
                           permit: GeometryWritePermit) async {
        defer { endLifetime(context) }
        let intent = plan.intent
        let token = intent.token
        let started = CACurrentMediaTime()
        defer {
            metrics.measure("工作台:主区交换",
                            milliseconds: (CACurrentMediaTime() - started) * 1000,
                            context: intent.source.displayName)
        }

        // prepare：权限、目录、模态与日志先核对；缺任何一项都不写窗口（方案 §8.2.3、§8.2.4、§7.2）。
        guard stillValid(context, token: token) else { return }
        guard await proceedOrStop(plan, context: context, after: .succeeded(readBack: nil), token: token) else { return }
        let prepared = await prepare(plan: plan, context: context)
        report(step: .prepare, outcome: prepared, identity: intent.to, token: token, context: context)
        guard await proceedOrStop(plan, context: context, after: prepared, token: token) else { return }

        // moveToMain：B 进主区。方式由 MainPlacementPolicy 决定，读回为准（方案 §9.1、§9.2）。
        let movePlacement = await placeMain(intent.to,
                                            mainRect: plan.mainRect,
                                            topRailRect: plan.topRailRect,
                                            sideRailRect: plan.sideRailRect,
                                            context: context,
                                            permit: permit,
                                            activate: false,
                                            fallbackTarget: plan.mainTargetFrame)
        let moved = enforceDeadline(movePlacement.step)
        report(step: .moveToMain, outcome: moved, identity: intent.to, token: token, context: context)
        guard await proceedOrStop(plan, context: context, after: moved, token: token) else { return }

        // activateMain：真实主窗口必须可操作；只有相反证据才算失败（方案 §12.2）。
        guard stillValid(context, token: token) else { return }
        guard await proceedOrStop(plan, context: context, after: moved, token: token) else { return }
        let activationOutcome: WorkbenchStepOutcome
        if intent.followsExternalFocus {
            activationOutcome = await verifyExternalFocus(intent.to)
        } else {
            sideEffects.append(SideEffect(identity: intent.to, kind: .activation))
            let activation = await focus.activateAndRaise(intent.to, permit: permit)
            activationOutcome = activation.isProvenBehind
                ? .rejected("未确认 \(intent.to.journalKey) 已到前台（\(activation.evidence)）")
                : .succeeded(readBack: nil)
        }
        report(step: .activateMain, outcome: activationOutcome, identity: intent.to, token: token, context: context)
        guard await proceedOrStop(plan, context: context, after: activationOutcome, token: token) else { return }

        // restorePrevious：A 回它原来的 slot 位置。写过 A 之后 B 是否还在前面，必须实测一次，不能靠推断。
        var restoreOutcome: WorkbenchStepOutcome = .succeeded(readBack: nil)
        if let from = intent.from, let resting = plan.restingTargetFrame {
            guard stillValid(context, token: token) else { return }
            let restorePlacement = await placeMain(from,
                                                   mainRect: resting,
                                                   topRailRect: .null,
                                                   sideRailRect: .null,
                                                   context: context,
                                                   permit: permit,
                                                   activate: false,
                                                   fallbackTarget: resting)
            restoreOutcome = enforceDeadline(restorePlacement.step)
            if !restoreOutcome.isFailure {
                // A 的写回也会让出主 Actor：复核 B 前先处理这期间排队的外部焦点。
                guard await proceedOrStop(plan, context: context, after: restoreOutcome, token: token) else { return }
                // 把 B 再提到前台并读回一次：A 已经被动过，B 的前景色此时是提交的凭据，
                // 不能因为"A 是另一个应用"就不查——同应用兄弟窗口最常见，跨应用则是 A 的应用被顶起来（方案 §8.2、§18 A09）。
                if intent.followsExternalFocus {
                    restoreOutcome = await verifyExternalFocus(intent.to)
                } else {
                    let recheck = await focus.activateAndRaise(intent.to, permit: permit)
                    if recheck.isProvenBehind {
                        restoreOutcome = .rejected("写回原主后 B 不再处于前台（\(recheck.evidence)）")
                    }
                }
            }
        }
        report(step: .restorePrevious, outcome: restoreOutcome, identity: intent.from, token: token, context: context)
        guard await proceedOrStop(plan, context: context, after: restoreOutcome, token: token) else { return }

        // commit：placement 的提交只在 reducer 里发生；这里只证明"该写的都写完了"。
        report(step: .commit, outcome: .succeeded(readBack: nil), identity: intent.to, token: token, context: context)
        guard await proceedOrStop(plan, context: context, after: .succeeded(readBack: nil), token: token) else { return }
        onEvent?(.mainSwitchCommitted(token: token))
    }

    // MARK: - 布局微调（侧栏切换 / 分隔线收敛）

    /// 布局微调同样站在会话生命周期与忙判据里：同一主窗口的连续目标 latest-wins（方案 §5.3、§11.2）。
    ///
    /// `context` 由状态机给出（effect `.settleMainFrame` 自带操作上下文）：日志与写入必须共用同一个身份，
    /// 执行器不能自己再造一个上下文，否则 reducer 收到的回执对不上任何一次操作（方案 §7.1）。
    /// 省略时（旧调用与宿主测试）按当前会话现场生成，仍走同一条准入与队列。
    func settle(_ identity: WindowIdentity,
                targetFrame: CGRect,
                displayID: UInt32,
                token: TransitionToken,
                mainRect: CGRect,
                topRailRect: CGRect,
                sideRailRect: CGRect,
                context supplied: GeometryOperationContext? = nil,
                animationMS: Int = 0) {
        settleCounter += 1
        let context = supplied ?? scheduler.makeContext(token: token, kind: .settleLayout)
        let queuedAt = CACurrentMediaTime()
        let ok = scheduler.perform(GeometryOperationScheduler.Operation(context: context,
                                             identities: [identity],
                                             coalesceKey: "settle:\(identity.journalKey)",
                                             deadline: scheduler.deadline(after: Self.switchDeadline
                                                + .milliseconds(max(0, animationMS))),
                                             onSkipped: { [weak self] reason in
                                                 self?.finishSettle(identity: identity, token: token, context: context,
                                                                    targetFrame: targetFrame, displayID: displayID,
                                                                    outcome: .rejected(SetupMessages.skipped(reason)),
                                                                    geometry: nil)
                                             },
                                             run: { [weak self] permit in
                                                 guard let self else { return }
                                                 self.noteQueueDelay(queuedAt, context: "布局结算")
                                                 let settleStarted = CACurrentMediaTime()
                                                 // §20.2 的"最终 settle"端点：结算从开始执行到回报完成的整段。
                                                 defer { self.metrics.measure("工作台:布局结算",
                                                                              milliseconds: (CACurrentMediaTime() - settleStarted) * 1000,
                                                                              context: identity.journalKey) }
                                                 // 生命周期在通道里认领，不在发起时：排队中的第二次结算若先抢走
                                                 // 会话所有权，在途那次的读回与回报会被判成"已被撤销"（方案 §5.4）。
                                                 self.beginLifetime(context, identities: [identity])
                                                 defer { self.endLifetime(context) }
                                                 guard self.stillValid(context, token: token) else {
                                                     // 会话这一刻已换：一个窗口都没碰，但必须给 reducer 真实结论（方案 §6.1）。
                                                     self.finishSettle(identity: identity, token: token,
                                                                       context: context, targetFrame: targetFrame,
                                                                       displayID: displayID,
                                                                       outcome: .rejected("会话已更新，未写入几何"),
                                                                       geometry: nil)
                                                     return
                                                 }
                                                 let placement = await self.placeMain(identity,
                                                                                       mainRect: mainRect,
                                                                                       topRailRect: topRailRect,
                                                                                       sideRailRect: sideRailRect,
                                                                                       context: context,
                                                                                       permit: permit,
                                                                                       activate: false,
                                                                                       fallbackTarget: targetFrame)
                                                 if placement.step.isFailure {
                                                     // 布局微调失败不走交换补偿：这里单独把解除过的最小化收回去。
                                                     await self.undoMinimizeRelease(identity: identity,
                                                                                   context: context,
                                                                                   reason: placement.step.message)
                                                 }
                                                 self.finishSettle(identity: identity,
                                                                   token: token,
                                                                   context: context,
                                                                   targetFrame: targetFrame,
                                                                   displayID: displayID,
                                                                   outcome: placement.step,
                                                                   geometry: placement.geometry)
                                             }))
        if !ok {
            finishSettle(identity: identity, token: token, context: context, targetFrame: targetFrame,
                         displayID: displayID,
                         outcome: .rejected("调度器未受理本次布局微调（会话或相位已变）"), geometry: nil)
        }
    }

    private func finishSettle(identity: WindowIdentity,
                              token: TransitionToken,
                              context: GeometryOperationContext,
                              targetFrame: CGRect,
                              displayID: UInt32,
                              outcome: WorkbenchStepOutcome,
                              geometry: GeometryOutcome?) {
        // 写没写过都必须是真实结论：没写的失败原因原样带给 reducer（方案 §6.1）。
        let writeOutcome = geometry ?? .rejected(.preconditionFailed(outcome.message))
        if case .rejected = writeOutcome {
            onStatus?("主窗口尺寸未调整：\(outcome.message)")
        }
        guard activeContext == nil || activeContext?.operationID == context.operationID else { return }
        onEvent?(.geometryWriteFinished(GeometryWriteResult(identity: identity,
                                                            token: token,
                                                            operationID: context.operationID,
                                                            targetFrame: targetFrame,
                                                            displayID: displayID,
                                                            outcome: writeOutcome,
                                                            beforeFrame: nil,
                                                            context: context)))
    }

    // MARK: - 取消

    /// 取消（锁屏、Space 切换、退出）：撤销普通授权，停止后续步骤，不再写任何窗口。
    /// 已经写过的窗口由在途动作自己按真实副作用补偿；补偿走独立授权，不受这次撤销影响。
    func cancel() {
        _ = scheduler.cancelOrdinaryWrites(sessionID: scheduler.sessionID)
        // 取消即交还会话所有权：命令可能还压在 AX 队列里，但这次交换/过渡对用户已经结束了。
        // 之后回来的读回会因为 `activeContext` 已换而被步骤守卫挡掉，不再改状态机（方案 §5.5）。
        if let context = activeContext { endLifetime(context) }
        watchdog?.cancel()
        watchdog = nil
        didTimeOut = false
    }

    /// 当前是否在跑一次交换/过渡（供 TransitionActivity 汇总，方案 §13.2）。
    var activity: TransitionActivity {
        guard let activeContext else { return TransitionActivity() }
        switch activeContext.kind {
        case .mainSwitch: return TransitionActivity(mainSwitch: true)
        case .enterWorkbench, .returnOverview: return TransitionActivity(modeTransition: true)
        case .settleLayout, .promoteCandidate: return TransitionActivity(layoutSettle: true)
        case .compensation: return TransitionActivity(rollback: true)
        case .sessionRestore: return TransitionActivity()
        }
    }

    // MARK: - 准备与日志

    private func prepare(plan: WorkbenchSwitchPlan,
                         context: GeometryOperationContext) async -> WorkbenchStepOutcome {
        let intent = plan.intent
        guard permissions.status.isComplete else { return .rejected("权限已收回，未写入任何窗口") }
        if intent.followsExternalFocus {
            let focus = await verifyExternalFocus(intent.to)
            if focus.isFailure { return focus }
        }
        for identity in [intent.to, intent.from].compactMap({ $0 }) {
            guard catalog.record(for: identity) != nil else {
                return identity == intent.to ? .targetGone : .rejected("原主窗口已不在目录里")
            }
        }
        // A 挂着用户还没处理的对话框：不擅自关闭，也不动任何窗口（方案 §8.2.4、§10.4）。
        if let from = intent.from, await catalog.hasBlockingSheet(identity: from) {
            return .rejected(sheetRefusal(identity: from))
        }
        // 日志先行：这一批事务要么整体落盘、要么这次交换一个窗口都不写（方案 §7.2）。
        // 旧主只有在确实要被写回落点时才有事务，所以核对的身份跟着计划走。
        var affected: [WindowIdentity] = [intent.to]
        if let from = intent.from, plan.restingTargetFrame != nil { affected.append(from) }
        guard verifyJournalPrepared(context: context, identities: affected) else {
            return .rejected("几何事务未原子落盘，已拒绝写入")
        }
        return .succeeded(readBack: nil)
    }

    /// 日志先行的唯一判据：这批写前事务已经按**本次操作**落盘（方案 §7.1、§7.2）。
    ///
    /// 批次由状态机经 `.prepareJournal` 效果原子写入，宿主不再自己攒一份事务重写一遍——
    /// 两处各写就会各数一次修订号，写后事实也不知道该认谁。这里只核对落盘事实。
    private func verifyJournalPrepared(context: GeometryOperationContext,
                                       identities: [WindowIdentity]) -> Bool {
        for identity in identities where store.entry(for: identity)?.operationID != context.operationID {
            reportJournalFailure(context: context,
                                 identities: identities,
                                 reason: "\(identity.journalKey) 的写前事务没有按本次操作落盘")
            return false
        }
        return true
    }

    private func reportJournalFailure(context: GeometryOperationContext,
                                      identities: [WindowIdentity],
                                      reason: String) {
        VistileLog.session.log(level: .error,
                               "[日志] 批量落盘失败 操作=\(context.operationID.uuidString.prefix(8), privacy: .public) 原因=\(reason, privacy: .public)")
        onEvent?(.journalPreparationFailed(context: context, identities: identities, reason: reason))
    }

    /// 追加一条已发生的事实（方案 §7.2、§7.3）。
    ///
    /// 守卫按"条目属于本次操作"判断，而不是日志全局 revision：
    /// 日志是会话级共享的，退出清理、布局结算等无关流程都会推进 revision；
    /// 拿全局序号当守卫，会把一次合法的同操作追加判死（实机「期望 7，当前 8」即此）。
    /// 整批同成同败；失败时调用方必须停止后续写入并交给补偿。
    private func updateJournal(context: GeometryOperationContext,
                               identity: WindowIdentity,
                               mutation: JournalMutation,
                               additional: [JournalMutation] = []) async -> Bool {
        let request = JournalUpdateRequest(operationID: context.operationID,
                                           identity: identity,
                                           mutation: mutation)
        let written = await store.update(request, additional: additional)
        guard written.isPersisted else {
            let reason = written.reason ?? "未知原因"
            VistileLog.session.log(level: .error,
                                   "[日志] 事实追加失败 \(identity.journalKey, privacy: .public) 原因=\(reason, privacy: .public)")
            onEvent?(.journalUpdateFailed(context: context, identity: identity, reason: reason))
            return false
        }
        return true
    }

    private func sheetRefusal(identity: WindowIdentity) -> String {
        let name = catalog.record(for: identity)?.applicationName ?? "该应用"
        return "请先处理当前对话框（\(name)）"
    }

    // MARK: - 放置

    /// 一次几何写入之后的两侧事实：给 reducer 的步骤结论，和原始写入结果。
    private struct PlacementResult {
        let step: WorkbenchStepOutcome
        let geometry: GeometryOutcome?

        static func refused(_ reason: String) -> PlacementResult {
            PlacementResult(step: .rejected(reason), geometry: nil)
        }
    }

    /// 把真实窗口送到主区（或 A 的落点）。方式由 `MainPlacementPolicy` 算，这里只执行算出来的那条路径。
    ///
    /// 关键约束：
    /// - 写前 frame 必须实读成功；目录里的 frame 只是投影，不能替代（方案 §6.2）。
    /// - 固定尺寸窗口走 position-only，绝不为了"看起来占满主区"而写尺寸（方案 §9.1）。
    /// - 读回必须经 `MainPlacementPolicy.verify`：越界或压栏先做一次有界修正，仍不合格就补偿且不提交（方案 §9.2）。
    private func placeMain(_ identity: WindowIdentity,
                           mainRect: CGRect,
                           topRailRect: CGRect,
                           sideRailRect: CGRect,
                           context: GeometryOperationContext,
                           permit: GeometryWritePermit,
                           activate: Bool,
                           fallbackTarget: CGRect) async -> PlacementResult {
        guard permissions.status.isComplete else {
            return .refused("权限已收回，未写入窗口几何")
        }
        guard var record = catalog.record(for: identity) else {
            return PlacementResult(step: .targetGone, geometry: .targetGone)
        }
        // 事务必须在日志里且仍要求恢复：否则这次写入无从补偿（方案 §7.2）。
        guard let entry = store.entry(for: identity), entry.state.requiresRestore else {
            return .refused("几何事务未落盘，已拒绝写入")
        }

        // 最小化窗口先解除：拿不到句柄就不谎称"已经展开"（方案 §10.1）。
        var restoredFromMinimized = false
        if record.isMinimized || record.capture == .pausedMinimized {
            guard let element = catalog.axEntry(for: record)?.element else {
                return .refused("\(record.applicationName) 的最小化窗口缺少 AX 句柄")
            }
            // 最小化写入与几何写入共用同一条许可：撤销后队列里那笔命令不得再执行（方案 §5.2）。
            switch await writer.setMinimized(false, element: element, permit: permit) {
            case let .refused(reason):
                return .refused("解除最小化未获写入许可：\(reason)")
            case let .notApplied(reason):
                return .refused("\(record.applicationName) 未解除最小化（\(reason)）")
            case .changed:
                break
            }
            restoredFromMinimized = true
            // 解除成功就是一条已经发生的副作用：当场登记，之后任何提前返回都要把它收回去（方案 §6.4）。
            sideEffects.append(SideEffect(identity: identity, kind: .minimizeRelease))
            await catalog.refreshAndWait(reason: .windowEvent)
            guard let fresh = catalog.record(for: identity) else {
                await undoMinimizeRelease(identity: identity, context: context,
                                          reason: "解除最小化后目录里找不到该窗口")
                return PlacementResult(step: .targetGone, geometry: .targetGone)
            }
            guard fresh.allowsAutoFocus else {
                await undoMinimizeRelease(identity: identity, context: context,
                                          reason: "解除最小化后仍不可聚焦")
                return .refused("解除最小化后该窗口仍不可聚焦")
            }
            record = fresh
        }

        // 句柄取不到先复核目录（带截止时间反复复核：窗口移动中的瞬时坏采样，或捕捉权限成串短暂被拒），
        // 预算用尽仍拿不到才按事实拒绝。
        guard let ax = await catalog.axEntryAfterReview(for: record, budget: Self.interactiveAXBudget) else {
            await undoMinimizeRelease(identity: identity, context: context,
                                      reason: "拿不到 AX 句柄（身份未唯一确定）")
            return .refused("拿不到 AX 句柄（身份未唯一确定）")
        }
        // 写前实读：读不到就不写。目录快照可能落后一整轮，不能拿来当基准（方案 §6.2）。
        guard let before = await writer.currentFrame(of: ax.element) else {
            await undoMinimizeRelease(identity: identity, context: context,
                                      reason: "写前读不到当前 frame")
            return .refused("写前读不到当前 frame，拒绝盲目写入")
        }
        // 放置能力：可调尺寸窗口的决策只看"可 resize"这一条（策略恒定走 resize+move），
        // 再单独探测一次可写性纯属多一次跨进程往返（实机每笔 5–20ms，读超时时 0.35s）。
        // 只有固定尺寸/不可移动的窗口才需要这次探测；最终判据仍是写后读回（方案 §6.1、§9.2）。
        let movable: Bool
        let resizable: Bool
        if record.allowsGeometryControl {
            movable = true
            resizable = true
        } else {
            switch await writer.geometryWriteability(element: ax.element) {
            case .writeable:
                movable = true
                resizable = true
            case .sizeNotSettable:
                movable = true
                resizable = false
            case .positionNotSettable:
                movable = false
                resizable = false
            case .unreadable:
                // 读不到不是事实：交给写入自身的读回结论，但可移动性只能按目录最新采样保守处理。
                let current = catalog.record(for: identity) ?? record
                record = current
                movable = current.isMovable
                resizable = current.isResizable
            }
        }

        let decision = MainPlacementPolicy.decide(mainRect: mainRect,
                                                  currentFrame: before,
                                                  isMovable: movable,
                                                  isResizable: resizable,
                                                  docking: mainAreaDocking)
        guard let planned = decision.targetFrame else {
            // 放不下：不宣布进入主区，A 与两栏保持不动（方案 §9.1）。
            await undoMinimizeRelease(identity: identity, context: context,
                                      reason: decisionUnavailableReason(decision))
            return .refused(decisionUnavailableReason(decision))
        }
        // 写前实读同时决定两件事：推测原位置的修正，和本次操作的 before 快照。
        // 两者放进**同一批**原子落盘：同成同败，且只花一次磁盘往返（方案 §6.2、§7.3）。
        // 纠正只能走 `.correctOriginal`——upsert 的合并规则故意不覆盖 originalFrame。
        let correctedOriginal = entry.hasSpeculativeOriginal
            && !WindowTransaction.framesClose(before, entry.originalFrame, tolerance: 2)
        var extraMutations: [JournalMutation] = []
        if correctedOriginal {
            extraMutations.append(.correctOriginal(identity, frame: before, displayID: record.displayID))
        }
        let recorded = await updateJournal(context: context,
                                          identity: identity,
                                          mutation: .upsert(entry.markingOperationBefore(frame: before,
                                                                                         displayID: record.displayID,
                                                                                         operationID: context.operationID)),
                                          additional: extraMutations)
        guard recorded else {
            // 纠正与操作前快照是同一批：落盘失败＝基准不可信，一次 AX 写入都不许发生（方案 §7.3）。
            let reason = correctedOriginal
                ? "原位置（写前实读）与操作前快照未能同批落盘"
                : "操作前几何未能记入日志"
            await undoMinimizeRelease(identity: identity, context: context, reason: reason)
            return .refused("\(reason)，已拒绝写入")
        }
        if correctedOriginal {
            VistileLog.session.log(level: .info,
                                   "[原位置] \(identity.journalKey, privacy: .public) 目录快照=\(RecoveryCoordinator.text(entry.originalFrame), privacy: .public) 写前实读=\(RecoveryCoordinator.text(before), privacy: .public) 结论=按实读修正（与操作前快照同批落盘）")
        }
        guard stillValid(context, token: context.transitionToken) else {
            await undoMinimizeRelease(identity: identity, context: context, reason: "操作已被撤销")
            return .refused("操作已被撤销，未写入几何")
        }

        let started = CACurrentMediaTime()
        focus.beginProgrammaticWrite(identity)
        let write: GeometryWriteReport
        if decision.writesSize {
            write = await writer.apply(frame: planned, element: ax.element, permit: permit)
        } else {
            // move-only：只写位置，尺寸保持实读值（方案 §9.1）。
            write = await writer.applyPosition(planned.origin, element: ax.element, permit: permit)
        }
        focus.endProgrammaticWrite(identity, frame: write.displayFrame)
        metrics.measure("工作台:几何写入",
                        milliseconds: (CACurrentMediaTime() - started) * 1000,
                        context: write.outcome.message)
        noteReadBack(write)
        // 只有真的写过一个属性才算"动过"，才进入补偿清单（方案 §6.3）。
        if write.didWriteSize || write.didWritePosition {
            sideEffects.append(SideEffect(identity: identity,
                                          kind: .geometry(restoredMinimized: restoredFromMinimized)))
        } else if restoredFromMinimized {
            sideEffects.append(SideEffect(identity: identity, kind: .geometry(restoredMinimized: true)))
        }
        VistileLog.session.log(level: .info,
                               "[写入] \(identity.journalKey, privacy: .public) 方式=\(decision.writesSize ? "尺寸+位置" : "仅移动", privacy: .public) 目标=\(RecoveryCoordinator.text(planned), privacy: .public) 写前=\(RecoveryCoordinator.text(before), privacy: .public) 读回=\(write.readBack.map(RecoveryCoordinator.text) ?? "-", privacy: .public) size错误=\(write.sizeWriteError) position错误=\(write.positionWriteError) 结论=\(write.outcome.message, privacy: .public)")

        // 许可中途被撤销：一半几何已经落地，这不是"落位"，只能按部分事实交给补偿（方案 §5.2）。
        if write.isCancelled {
            if let refusal = await keepWriteFact(context: context, identity: identity, report: write,
                                                 target: planned, record: record,
                                                 element: ax.element, permit: permit) {
                return PlacementResult(step: refusal, geometry: write.outcome)
            }
            return PlacementResult(step: .rejected(write.outcome.message), geometry: write.outcome)
        }

        guard let readBack = write.readBack else {
            let outcome: WorkbenchStepOutcome
            switch write.outcome {
            case .targetGone: outcome = .targetGone
            default: outcome = .rejected(write.outcome.message)
            }
            if let refusal = await keepWriteFact(context: context, identity: identity, report: write,
                                                 target: planned, record: record,
                                                 element: ax.element, permit: permit) {
                return PlacementResult(step: refusal, geometry: write.outcome)
            }
            return PlacementResult(step: outcome, geometry: write.outcome)
        }

        // 写入被应用拒绝：读回的是"根本没动过"的旧几何。它既不是落位，也不是可修正的偏差，
        // 有界修正只服务于 §9.2"应用接受但改了尺寸"，对着拒绝再写一次只会重复同一个失败。
        if case .rejected = write.outcome {
            if let refusal = await keepWriteFact(context: context, identity: identity, report: write,
                                                 target: planned, record: record,
                                                 element: ax.element, permit: permit) {
                return PlacementResult(step: refusal, geometry: write.outcome)
            }
            return PlacementResult(step: .rejected(write.outcome.message), geometry: write.outcome)
        }

        // 读回包含性判定：受限不等于合格（方案 §9.2）。
        let verification = MainPlacementPolicy.verify(readBack: readBack,
                                                      mainRect: mainRect,
                                                      topRailRect: topRailRect,
                                                      sideRailRect: sideRailRect)
        switch verification {
        case let .accepted(frame):
            if let refusal = await keepWriteFact(context: context, identity: identity, report: write,
                                                 target: planned, record: record,
                                                 element: ax.element, permit: permit) {
                return PlacementResult(step: refusal, geometry: write.outcome)
            }
            let outcome: WorkbenchStepOutcome = write.outcome.settlesGeometryTransaction
                ? .succeeded(readBack: frame)
                : .constrained(readBack: frame, note: write.outcome.message)
            if activate {
                return await confirmActivation(outcome: outcome, identity: identity, geometry: write.outcome,
                                               record: record)
            }
            return PlacementResult(step: outcome, geometry: write.outcome)

        case let .correctPosition(corrected):
            // 一次有界修正：只改位置，尺寸不动；修正后仍不合格就补偿、不提交（方案 §9.2）。
            guard permit.isGranted, stillValid(context, token: context.transitionToken) else {
                return PlacementResult(step: .rejected("操作已撤销，未做位置修正"), geometry: write.outcome)
            }
            let fixed = await writer.applyPosition(corrected.origin, element: ax.element, permit: permit)
            noteReadBack(fixed)
            guard let finalReadBack = fixed.readBack else {
                if let refusal = await keepWriteFact(context: context, identity: identity, report: fixed,
                                                    target: corrected, record: record,
                                                    element: ax.element, permit: permit) {
                    return PlacementResult(step: refusal, geometry: fixed.outcome)
                }
                return PlacementResult(step: .rejected("有界修正后读不回 frame"), geometry: fixed.outcome)
            }
            let recheck = MainPlacementPolicy.verify(readBack: finalReadBack,
                                                     mainRect: mainRect,
                                                     topRailRect: topRailRect,
                                                     sideRailRect: sideRailRect)
            if let refusal = await keepWriteFact(context: context, identity: identity, report: fixed,
                                                 target: corrected, record: record,
                                                 element: ax.element, permit: permit) {
                return PlacementResult(step: refusal, geometry: fixed.outcome)
            }
            switch recheck {
            case let .accepted(frame):
                let outcome: WorkbenchStepOutcome = .constrained(
                    readBack: frame,
                    note: "写回后越界，已一次有界修正到 \(RecoveryCoordinator.text(frame))")
                if activate {
                    return await confirmActivation(outcome: outcome, identity: identity,
                                                   geometry: fixed.outcome, record: record)
                }
                return PlacementResult(step: outcome, geometry: fixed.outcome)
            case .correctPosition, .rejected:
                // 修正后仍不合格：交给补偿，placement 不提交（方案 §9.2）。
                let reason = Self.verificationFailure(recheck)
                return PlacementResult(step: .outsideMain(readBack: finalReadBack, reason: reason),
                                       geometry: fixed.outcome)
            }

        case .rejected(let reason):
            if let refusal = await keepWriteFact(context: context, identity: identity, report: write,
                                                 target: planned, record: record,
                                                 element: ax.element, permit: permit) {
                return PlacementResult(step: refusal, geometry: write.outcome)
            }
            // 尺寸本身放不下主区：这不是"受限但可以继续"，必须补偿且不提交（方案 §9.2）。
            return PlacementResult(step: .outsideMain(readBack: readBack, reason: reason),
                                   geometry: write.outcome)
        }
    }

    private func confirmActivation(outcome: WorkbenchStepOutcome,
                                   identity: WindowIdentity,
                                   geometry: GeometryOutcome?,
                                   record: WindowRecord) async -> PlacementResult {
        sideEffects.append(SideEffect(identity: identity, kind: .activation))
        let facts = await focus.activateAndRaise(identity)
        if facts.isProvenBehind {
            return PlacementResult(step: .rejected("\(record.applicationName) 没能带到前台（\(facts.evidence)）"),
                                   geometry: geometry)
        }
        return PlacementResult(step: outcome, geometry: geometry)
    }

    /// 把写入事实追加进日志（计划 → 已写 → 已验证）。失败已通过事件回报，调用方据返回值继续补偿。
    ///
    /// 返回 nil = 事实已落盘，这一步可以按原结论继续；非 nil = 这一步必须立刻收口的结论，
    /// 因为日志不知道窗口动过，再往下走就是把一次无从恢复的移动当成成功（方案 §7.3、§18 A17）。
    private func keepWriteFact(context: GeometryOperationContext,
                               identity: WindowIdentity,
                               report: GeometryWriteReport,
                               target: CGRect,
                               record: WindowRecord,
                               element: AXUIElement,
                               permit: GeometryWritePermit) async -> WorkbenchStepOutcome? {
        guard let existing = store.entry(for: identity) else {
            return await unrecordedWriteOutcome(identity: identity, element: element,
                                                permit: permit, report: report)
        }
        let planned = existing.markingPlanned(frame: target, displayID: record.displayID)
        let updated: WindowTransaction
        // "有读回"不等于"应用接受了"：被拒的写入读回的是没动过的旧几何，
        // 记成 written 会让退出恢复以为窗口已经停在目标上，跳过本该做的核对（方案 §6.1）。
        switch report.outcome {
        case let .exact(frame), let .constrained(frame):
            updated = planned.markingWritten(readBack: frame,
                                             displayID: record.displayID,
                                             note: report.outcome.message)
        case let .cancelled(_, _, readBack):
            // 部分写入是已经发生的事实：按读回记 written，恢复照着这块几何回位（方案 §5.2）。
            if let readBack {
                updated = planned.markingWritten(readBack: readBack,
                                                 displayID: record.displayID,
                                                 note: report.outcome.message)
            } else {
                updated = planned.markingWriteFailed(report.outcome.message,
                                                     observedFrame: report.frameBeforeWrite)
            }
        case .rejected, .unreadable, .targetGone:
            // 写入被拒/读不回：状态停在"尝试过但结果未知或未接受"，恢复据此保守核对。
            // 有读回就把读回记进去——它是判断"这次尝试到底动没动窗口"的证据（方案 §6.4）。
            updated = planned.markingWriteFailed(report.outcome.message,
                                                 observedFrame: report.readBack ?? report.frameBeforeWrite)
        }
        let persisted = await updateJournal(context: context, identity: identity, mutation: .upsert(updated))
        guard persisted else {
            return await unrecordedWriteOutcome(identity: identity, element: element,
                                                permit: permit, report: report)
        }
        return nil
    }

    /// 写后事实落不下去时的收口：真的动过窗口就照写前实读立刻回位，回位结果如实写进结论（方案 §7.3、§18 A17）。
    private func unrecordedWriteOutcome(identity: WindowIdentity,
                                        element: AXUIElement,
                                        permit: GeometryWritePermit,
                                        report: GeometryWriteReport) async -> WorkbenchStepOutcome {
        guard report.didChangeGeometry, let before = report.frameBeforeWrite else {
            return .rejected("写后事实未能落盘，且无法确认窗口是否动过：本步不提交")
        }
        let back = await writer.apply(frame: before, element: element, permit: permit)
        noteReadBack(back)
        let restored = back.readBack.map { WindowTransaction.framesClose($0, before, tolerance: 2) } ?? false
        recorder.note("写后事实未落盘：\(identity.journalKey) 按写前实读 \(RecoveryCoordinator.text(before))"
                      + " 回位\(restored ? "成功" : "失败")")
        return .rejected(restored
            ? "写后事实未能落盘，已按写前实读 \(RecoveryCoordinator.text(before)) 回位"
            : "写后事实未能落盘，按写前实读 \(RecoveryCoordinator.text(before)) 回位也未确认：\(back.outcome.message)")
    }

    /// 把「Vistile 本次解除的最小化」收回去（方案 §6.4、§10.1）。
    ///
    /// 三条约束：
    /// - 走**恢复授权**（`.compensation`）而不是普通许可：普通许可可能已经被取消屏障撤销，
    ///   但"把已经发生的副作用收回去"不属于新操作，不能被同一道屏障挡住；
    /// - 只收回我们改过的那一条事实：目录已经显示最小化就当作已恢复，不重复写；
    /// - 窗口消失/没有句柄/恢复写入失败时无法收口，返回 false：调用方必须把它计入补偿事实，
    ///   不能让状态机在没有证据的情况下宣称"回滚成功"。
    @discardableResult
    private func undoMinimizeRelease(identity: WindowIdentity,
                                     context: GeometryOperationContext,
                                     reason: String) async -> Bool {
        guard sideEffects.contains(where: { $0.identity == identity && $0.kind == .minimizeRelease }) else {
            return true
        }
        guard let record = catalog.record(for: identity) else {
            sideEffects.removeAll { $0.identity == identity && $0.kind == .minimizeRelease }
            recorder.note("解除最小化后窗口已不在目录里，无需恢复（\(reason)）")
            return true
        }
        if record.isMinimized {
            // 已经是用户（或应用自己）想要的最小化状态：状态一致，不再写一次。
            sideEffects.removeAll { $0.identity == identity && $0.kind == .minimizeRelease }
            return true
        }
        guard let element = catalog.axEntry(for: record)?.element else {
            recorder.note("解除最小化后取不到 AX 句柄，未恢复 \(identity.journalKey) 的最小化状态")
            return false
        }
        let compensationContext = scheduler.makeContext(token: context.transitionToken, kind: .compensation)
        let outcome: MinimizeWriteOutcome? = await scheduler.request(
            context: compensationContext,
            identities: [identity],
            work: { [weak self] permit in
                guard let self else { return .refused(reason: "执行器已释放") }
                return await self.writer.setMinimized(true, element: element, permit: permit)
            })
        if outcome?.didChange == true {
            sideEffects.removeAll { $0.identity == identity && $0.kind == .minimizeRelease }
            recorder.note("已按原样恢复 \(record.applicationName) 的最小化状态（\(reason)）")
            return true
        }
        // 恢复失败：义务留在 sideEffects 里，后续补偿路径还会再试，并在诊断里留痕。
        recorder.record("最小化恢复", subject: record.applicationName, result: .failed,
                        detail: "解除最小化后未能恢复（\(reason)）：\(outcome.map(String.init(describing:)) ?? "未获调度器受理")")
        return false
    }

    private func decisionUnavailableReason(_ decision: MainPlacementDecision) -> String {
        if case let .unavailable(reason) = decision { return reason }
        return "主区放置方式无法确定"
    }

    // MARK: - 写回原位置

    /// 返回总览：写回 resting frame 并让同一套恢复规则收口事务（方案 §4.4、§6.5）。
    private func restoreMain(_ identity: WindowIdentity,
                             context: GeometryOperationContext,
                             permit: GeometryWritePermit) async -> WorkbenchStepOutcome {
        guard let entry = store.entry(for: identity) else {
            return .rejected("事务日志里没有该窗口的记录，未写回几何")
        }
        guard entry.state.requiresRestore else {
            // 已经被恢复过（例如用户在返回前手动改回原状）：不是失败，也不是"我们写回成功"。
            return .succeeded(readBack: nil)
        }
        let started = CACurrentMediaTime()
        let item = await recovery.restore(entry: entry, token: context.transitionToken, deadline: deadline)
        metrics.measure("工作台:写回原尺寸",
                        milliseconds: (CACurrentMediaTime() - started) * 1000,
                        context: item.outcome.message)
        VistileLog.session.log(level: .info,
                               "[写回] \(identity.journalKey, privacy: .public) 结论=\(item.outcome.message, privacy: .public)")
        return Self.stepOutcome(for: item, identity: identity)
    }

    /// 恢复结论映射到步骤结论：只有 settled 类结论才算继续，降级要写清是哪块屏（方案 §8）。
    static func stepOutcome(for item: RestoreItemResult, identity: WindowIdentity) -> WorkbenchStepOutcome {
        switch item.outcome {
        case .restored, .alreadyAtOriginal, .keptUserGeometry, .userMoved, .settledDegraded:
            return .succeeded(readBack: nil)
        case let .constrained(readBack, deviation):
            return .constrained(readBack: readBack,
                                note: "写回偏差 \(String(format: "%.1f", deviation))pt，实际 \(RecoveryCoordinator.text(readBack))")
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

    // MARK: - 补偿

    /// 失败补偿：只逆序还原"确实动过"的窗口；无需保留外部焦点时才激活旧主，最后回报完整事实。
    /// 补偿用独立授权（`.compensation`），不受普通操作撤销屏障影响（方案 §5.1、§6.3）。
    private func compensate(reason: String,
                            context: GeometryOperationContext,
                            token: TransitionToken,
                            reActivate: WindowIdentity?,
                            transition: Bool) async {
        guard !didRollback else { return }
        didRollback = true
        recorder.note("工作台补偿：\(reason)")
        scheduler.reserveCompensation(for: context)
        defer { scheduler.releaseCompensation(operationID: context.operationID) }

        var items: [WorkbenchCompensationResult.Item] = []
        var seen = Set<WindowIdentity>()
        var minimizeReleases: [WindowIdentity] = []
        /// 写前实读（与本次 operationID 绑定）：补偿判定的权威目标。
        /// reducer 手里的计划期快照可能落后于用户在 Vistile 之外对窗口的移动（方案 §6.2、§6.4）。
        var beforeReads: [WindowIdentity: CGRect] = [:]
        // 逆序：后写的先回位，避免中间态把已回位的窗口再次顶走（方案 §6.3）。
        for effect in sideEffects.reversed() {
            if effect.kind == .minimizeRelease {
                if !minimizeReleases.contains(effect.identity) { minimizeReleases.append(effect.identity) }
                continue
            }
            guard seen.insert(effect.identity).inserted else { continue }
            let action = await compensateWindow(effect.identity, context: context)
            let displayID = catalog.record(for: effect.identity)?.displayID
            items.append(.init(identity: effect.identity, action: action, displayID: displayID))
            if let entry = store.entry(for: effect.identity),
               entry.operationID == context.operationID,
               let before = entry.operationBeforeFrame {
                beforeReads[effect.identity] = before
            }
        }
        for identity in activeIdentities where !seen.contains(identity) {
            items.append(.init(identity: identity, action: .notWritten,
                               displayID: catalog.record(for: identity)?.displayID))
        }
        // 最小化在几何回位之后再恢复：顺序反过来会先把窗口藏起来，几何补偿就写不进"看不见的窗口"。
        var unresolvedMinimizeRestorations: [WindowIdentity] = []
        for identity in minimizeReleases {
            let restored = await undoMinimizeRelease(identity: identity, context: context,
                                                     reason: "本次操作失败，回滚最小化状态")
            if !restored { unresolvedMinimizeRestorations.append(identity) }
        }
        sideEffects.removeAll()
        // 这批里"落盘了计划但一次都没写"的身份没有恢复依据：把义务从账上撤掉。
        // 留着会让下次启动去核对一个从没碰过的窗口，也把 A42 的"每个恢复义务都对应真实写入"打破（方案 §6.4、§18）。
        await releaseUnwrittenPlans()

        var activatedMain: WindowIdentity?
        if let reActivate, !transition, !shouldPreserveExternalFocus(token) {
            // 几何补偿期间也可能出现新的外部焦点，实际激活前必须再查一次。
            // 未被外部焦点接管时才把 A 带回前台：`setKeyboardFocus(.targetApplication)` 只改状态机描述，
            // 不会改变系统前台，用户看到半套交换（方案 §6.3）。
            let facts = await focus.activateAndRaise(reActivate)
            if !facts.isProvenBehind { activatedMain = reActivate }
        }
        // 模式过渡失败：没有"旧主"要带回，焦点事实按未确认处理（isComplete 自然为假）。
        let compensation = WorkbenchCompensationResult(items: items, activatedMain: activatedMain,
                                                       beforeReads: beforeReads,
                                                       unresolvedMinimizeRestorations: unresolvedMinimizeRestorations)
        // 补偿事实先于失败事件回报：reducer 只能在看到真实结局后收口（方案 §6.4）。
        onEvent?(.geometryRestoreSettled(token: token,
                                         items: items.map {
                                             RestoreItemResult(identity: $0.identity,
                                                               outcome: Self.restoreOutcome($0.action),
                                                               applicationName: applicationName(for: $0.identity))
                                         }))
        // 模式过渡的终止回调只有一处：`runTransition` 在补偿之后自己发。
        // 这里再发一次就是同一个令牌两次终止，状态机按第二次收口，用户看到的是半套结论（方案 §15、§18 A39）。
        if !transition {
            reportSwitchFailure(token: token, reason: reason, compensation: compensation)
        }
    }

    /// 撤掉"本次操作名下、但窗口从未被移动过"的事务：没有真实写入就没有恢复依据（方案 §6.4、§18 A42）。
    /// 只按本次操作名义负责的窗口清理；已经写过的、以及别的操作名下的事务一律原样留给恢复路径（A12）。
    private func releaseUnwrittenPlans() async {
        guard let context = activeContext else { return }
        let stale = store.snapshot.entries.values.filter { entry in
            activeIdentities.contains(entry.identity) && !Self.owesRestoreObligation(entry, of: context)
        }
        for entry in stale {
            let written = await store.drop(entry.identity)
            guard !written.isPersisted else { continue }
            // 撤账没落盘不能当作已撤：状态与日志的分歧要回报，下次启动照旧核对（方案 §7.3）。
            onStatus?("未写入的事务清理未落盘：\(entry.identity.journalKey)（\(written.reason ?? "未知原因")）")
        }
    }

    /// 这个事务还欠一次恢复吗？判据全部来自已记录的几何事实，不按"计划过"推断（方案 §6.4、§7.2）。
    /// - 从未执行过 AX 写入：窗口还在它本来的位置，没有恢复依据。
    /// - 写过但被拒/失败：只有读回同时等于"本操作前实读"和"会话原位置"才算从头到尾没动过；
    ///   任一项不等，就是退出时必须还原的差值（A12：回滚成功也不许 drop A 的会话事务）。
    static func owesRestoreObligation(_ entry: WindowTransaction, of context: GeometryOperationContext) -> Bool {
        guard Self.didWriteGeometry(entry) else { return false }
        guard entry.state == .failed, let observed = entry.lastProvisionalFrame else { return true }
        // 只有"这次操作自己写失败"才适用下面的读回判据：更早操作留下的失败记录与本操作无关，不许顺手撤账（A12）。
        guard entry.operationID == context.operationID else { return true }
        let untouchedByOperation = entry.operationBeforeFrame
            .map { WindowTransaction.framesClose(observed, $0, tolerance: 2) } ?? false
        let atSessionOriginal = WindowTransaction.framesClose(observed, entry.originalFrame, tolerance: 2)
        return !(untouchedByOperation && atSessionOriginal)
    }

    private func applicationName(for identity: WindowIdentity) -> String {
        catalog.record(for: identity)?.applicationName
            ?? NSRunningApplication(processIdentifier: identity.processID)?.localizedName ?? "未知应用"
    }

    static func restoreOutcome(_ action: CompensationAction) -> RestoreOutcome {
        switch action {
        case .restoredTo: return .restored
        case .alreadyInPlace: return .alreadyAtOriginal
        case .notWritten: return .notAttempted("")
        case let .refused(reason): return .rejected(reason)
        }
    }

    /// 单个身份的补偿：目标取操作前快照（`compensationTargetFrame`），没有快照才退回会话原位置。
    private func compensateWindow(_ identity: WindowIdentity,
                                  context: GeometryOperationContext) async -> CompensationAction {
        guard let entry = store.entry(for: identity) else {
            return .refused(reason: "日志里没有该事务，补偿无法确认目标位置")
        }
        guard Self.didWriteGeometry(entry) else { return .notWritten }
        guard let target = entry.compensationTargetFrame() else {
            return .refused(reason: "既没有操作前快照也没有原位置")
        }
        let compensationContext = scheduler.makeContext(token: context.transitionToken, kind: .compensation)
        let result: CompensationAction? = await scheduler.request(
            context: compensationContext,
            identities: [identity],
            work: { [weak self] permit -> CompensationAction in
                guard let self else { return .refused(reason: "执行器已释放") }
                guard let record = self.catalog.record(for: identity),
                      let ax = await self.catalog.axEntryAfterReview(for: record) else {
                    return .refused(reason: "补偿时拿不到句柄")
                }
                guard let current = await self.writer.currentFrame(of: ax.element) else {
                    return .refused(reason: "补偿前读不到当前 frame")
                }
                if WindowTransaction.framesClose(current, target, tolerance: 2) {
                    return .alreadyInPlace(frame: current)
                }
                let written = await self.writer.apply(frame: target, element: ax.element, permit: permit)
                self.noteReadBack(written)
                guard let readBack = written.readBack else {
                    return .refused(reason: written.outcome.message)
                }
                if WindowTransaction.framesClose(readBack, target, tolerance: 2) {
                    // 补偿只把窗口送回"本操作之前"，会话事务仍然要求恢复：
                    // A 的回轨事务不能因为一次失败交换就被结算掉（方案 §6.3、§6.4）。
                    return .restoredTo(frame: readBack)
                }
                return .refused(reason: "补偿读回 \(RecoveryCoordinator.text(readBack)) 与目标 \(RecoveryCoordinator.text(target)) 不一致")
            })
        guard let result else {
            return .refused(reason: "补偿未获调度器受理（会话或相位已变）")
        }
        return result
    }

    /// 是否真的写过几何：计划了但从未有读回/临时值 = 没动过窗口。
    static func didWriteGeometry(_ entry: WindowTransaction) -> Bool {
        if entry.state == .verified || entry.state == .written { return true }
        if entry.state == .failed { return true }
        return entry.lastProvisionalFrame != nil
    }

    /// 判定结论里的失败原因（`.correctPosition` 分支只需要一句话）。
    static func verificationFailure(_ verification: PlacementVerification) -> String {
        switch verification {
        case let .accepted(frame): return "读回 \(RecoveryCoordinator.text(frame)) 已合格"
        case let .correctPosition(to): return "仍需修正到 \(RecoveryCoordinator.text(to)) 才能合格"
        case let .rejected(reason): return reason
        }
    }

    private func reportSwitchFailure(token: TransitionToken,
                                     reason: String,
                                     compensation: WorkbenchCompensationResult?) {
        onEvent?(.mainSwitchFailed(token: token, reason: reason, compensation: compensation))
    }

    private func verifyExternalFocus(_ identity: WindowIdentity) async -> WorkbenchStepOutcome {
        guard frontmostProcessID() == identity.processID,
              let record = catalog.record(for: identity), let element = catalog.axEntry(for: record)?.element,
              let focused = await writer.focusedWindowElement(pid: identity.processID),
              frontmostProcessID() == identity.processID, CFEqual(focused, element) else {
            return .rejected("前台窗口已改变或暂时无法确认，未重新激活旧目标")
        }
        return .succeeded(readBack: nil)
    }

    // MARK: - reducer 态度

    /// 每步之后与激活前问一次 reducer：继续、回滚、还是令牌已作废；外部焦点优先保留。
    private func proceedOrStop(_ plan: WorkbenchSwitchPlan,
                               context: GeometryOperationContext,
                               after outcome: WorkbenchStepOutcome,
                               token: TransitionToken) async -> Bool {
        guard activeContext == context else { return false }
        let preserveExternalFocus = shouldPreserveExternalFocus(token)
        let reActivate = plan.intent.followsExternalFocus || preserveExternalFocus ? nil : plan.intent.from
        if preserveExternalFocus {
            await compensate(reason: "外部焦点已改变，停止旧交换并保留当前焦点",
                             context: context, token: token, reActivate: reActivate, transition: false)
            return false
        }
        if didTimeOut || isPastDeadline {
            didTimeOut = true
            await compensate(reason: "超过 \(Int(Self.switchDeadline.totalNanoseconds / 1_000_000))ms 未收敛",
                             context: context, token: token,
                             reActivate: reActivate, transition: false)
            return false
        }
        if outcome.isFailure {
            await compensate(reason: outcome.message, context: context, token: token,
                             reActivate: reActivate, transition: false)
            return false
        }
        switch directive(token) {
        case .proceed:
            return true
        case let .rollback(reason):
            await compensate(reason: reason, context: context, token: token,
                             reActivate: reActivate, transition: false)
            return false
        case .aborted:
            return false
        }
    }

    private func report(step: WorkbenchSwitchStep,
                        outcome: WorkbenchStepOutcome,
                        identity: WindowIdentity?,
                        token: TransitionToken,
                        context: GeometryOperationContext) {
        guard activeContext == context else { return }
        // 每一步的真实结论与耗时进诊断日志：实机调优要靠它还原"哪一步、什么事实、花了多久"。
        let stamp = CACurrentMediaTime()
        let deltaMS = stepClock > 0 ? Int((stamp - stepClock) * 1000) : 0
        stepClock = stamp
        VistileLog.session.log(level: .info,
                               "[交换] 步骤=\(step.displayName, privacy: .public) 对象=\(identity?.journalKey ?? "-", privacy: .public) 耗时=\(deltaMS)ms 结论=\(outcome.message, privacy: .public)")
        onEvent?(.mainSwitchStepFinished(WorkbenchSwitchStepResult(token: token,
                                                                   step: step,
                                                                   outcome: outcome,
                                                                   identity: identity)))
    }

    // MARK: - 上下文核对与限时

    /// 每一步之前的统一核对：会话、代次、相位、令牌、预算，一项对不上就不再写窗口（方案 §5.5）。
    private func stillValid(_ context: GeometryOperationContext, token: TransitionToken) -> Bool {
        guard activeContext == context else { return false }
        guard context.matches(sessionID: scheduler.sessionID, epoch: scheduler.sessionEpoch) else {
            onStatus?("会话已更新，停止后续步骤")
            return false
        }
        guard !isPastDeadline else {
            didTimeOut = true
            return false
        }
        return true
    }

    private func beginLifetime(_ context: GeometryOperationContext,
                               identities: [WindowIdentity] = []) {
        activeContext = context
        activeIdentities = identities
        deadline = scheduler.deadline(after: Self.switchDeadline)
        didTimeOut = false
        didRollback = false
        sideEffects = []
        stepClock = CACurrentMediaTime()
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self, deadline] in
            guard let deadline else { return }
            let wait = max(deadline.nanoseconds &- (self?.scheduler.now.nanoseconds ?? 0), 0)
            try? await Task.sleep(nanoseconds: wait)
            guard !Task.isCancelled else { return }
            self?.deadlineExpired(context)
        }
    }

    /// 到点收敛：真实时间由看门狗触发；注入时钟的测试直接调它，不靠睡眠赌时序（方案 §15.2）。
    func deadlineExpired(_ context: GeometryOperationContext) {
        guard activeContext == context, !didTimeOut else { return }
        didTimeOut = true
        recorder.note("工作台\(context.kind.rawValue)超过 \(Int(Self.switchDeadline.totalNanoseconds / 1_000_000))ms 未收敛，按超时处理")
        onStatus?("\(context.kind.rawValue)超时，正在收敛")
        onEvent?(.transitionTimedOut(context.transitionToken))
    }

    private func endLifetime(_ context: GeometryOperationContext) {
        watchdog?.cancel()
        watchdog = nil
        guard activeContext == context else { return }
        activeContext = nil
        activeIdentities = []
        deadline = nil
    }

    /// 超过总限时：把结果改写成失败，几何由调用方补偿（方案 §10.5）。
    private func enforceDeadline(_ outcome: WorkbenchStepOutcome) -> WorkbenchStepOutcome {
        guard isPastDeadline else { return outcome }
        didTimeOut = true
        guard !outcome.isFailure else { return outcome }
        return .rejected("超过 \(Int(Self.switchDeadline.totalNanoseconds / 1_000_000))ms 未收敛")
    }

    private var isPastDeadline: Bool {
        guard let deadline else { return false }
        return scheduler.remaining(until: deadline) == 0
    }

    private func reportSkipped(_ reason: SetupMessages.SkipReason,
                               context: GeometryOperationContext,
                               token: TransitionToken,
                               kind: WorkbenchTransitionKind) {
        onEvent?(.workbenchTransitionFinished(token: token, kind: kind,
                                              result: .rejected(SetupMessages.skipped(reason))))
    }
}

/// 调度器丢弃作业的人类可读原因（诊断与测试断言共用）。
enum SetupMessages {
    typealias SkipReason = GeometryOperationScheduler.Skip

    static func skipped(_ reason: SkipReason) -> String {
        switch reason {
        case .cancelled: return "操作已被取消屏障撤销，未写入几何"
        case .sessionChanged: return "会话已更换，本次操作未执行"
        case .budgetExpired: return "限时预算已尽，未开始新的写入"
        }
    }
}
