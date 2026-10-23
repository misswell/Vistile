import Foundation
import CoreGraphics

/// 工作台状态逻辑（方案 §7）：由唯一 SessionReducer 调用的纯逻辑层，不独立执行 AX。
/// 处理"总览↔工作台"模式过渡、轨道占用、A/B 交换的提交点；
/// 认不出的（或不在工作台情境的）事件返回 nil，交回 SessionReducer 既有逻辑。
///
/// 时序纪律（方案 §7.1、§15）：每一笔会动真实窗口几何的操作都先 `prepare` 日志，
/// 只有 `journalPrepared(context)` 才把几何 effect 放出去。因此
/// - prepare 失败 = 一次 AX 都没写：按操作类型落回原状态，不需要补偿；
/// - 写入之后失败 = 事实已发生：停止后续步骤并要求操作补偿，绝不按"没发生"处理。
public enum WorkbenchReducer {

    // MARK: - 事件入口

    static func reduce(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect]? {
        // 会话不可见（隐藏/恢复中）时工作台事件一律不认领：旧完成回调不能复活工作台（方案 §4.5、§10.5）。
        guard state.phase.isVisible else { return nil }
        switch event {
        case let .overviewCardSelected(identity, _, _):
            return beginEnterWorkbench(&state, identity: identity)
        case let .railCardSelected(slot, identity):
            return beginRailSelection(&state, slot: slot, identity: identity)
        case let .railCardDragged(from, to):
            return handleRailDrag(&state, from: from, to: to)
        case let .railPinToggled(identity):
            return toggleRailPin(&state, identity: identity)
        case let .railScrolled(rail, offset):
            return handleRailScroll(&state, rail: rail, offset: offset)
        case let .railSideChanged(side):
            return handleSideChanged(&state, side: side)
        case .returnToOverviewRequested:
            return beginReturnOverview(&state)
        case let .workbenchTransitionFinished(token, kind, result):
            return finishModeTransition(&state, token: token, kind: kind, result: result)
        case let .mainSwitchStepFinished(result):
            return recordSwitchStep(&state, result)
        case let .mainSwitchCommitted(token):
            return commitMainSwitch(&state, token: token)
        case let .mainSwitchFailed(token, reason, compensation):
            return failMainSwitch(&state, token: token, reason: reason, compensation: compensation)
        case let .promotionFinished(context, identity, geometry, activated):
            return handlePromotionFinished(&state, context: context, identity: identity,
                                           geometry: geometry, activated: activated)
        case let .journalPrepared(context):
            return handleJournalPrepared(&state, context: context)
        case let .journalPreparationFailed(context, identities, reason):
            return handleJournalPreparationFailed(&state, context: context, identities: identities, reason: reason)
        case let .journalUpdateFailed(context, identity, reason):
            return handleJournalUpdateFailed(&state, context: context, identity: identity, reason: reason)
        case let .workbenchRailSizePreview(topHeight, sideWidth):
            return handleRailSizePreview(&state, topHeight: topHeight, sideWidth: sideWidth)
        case let .workbenchRailSizeChanged(topHeight, sideWidth):
            return handleRailSizeChanged(&state, topHeight: topHeight, sideWidth: sideWidth)
        case let .workbenchSearchFocusChanged(focused):
            return handleSearchFocus(&state, focused: focused)
        case let .geometryWriteFinished(result):
            // 布局微调与交换中的有界位置修正都不在过渡令牌语义里，凭各自的在途标记对账（方案 §9.2、§11.2）。
            if let pending = state.workbench.mainFrameWrite,
               pending.token == result.token, pending.identity == result.identity {
                return applyMainFrameResult(&state, result)
            }
            if let pending = state.workbench.switchCorrection,
               pending.token == result.token, pending.identity == result.identity {
                return applySwitchCorrection(&state, result)
            }
            return nil
        case let .transitionTimedOut(token):
            guard isWorkbenchToken(state, token) else { return nil }
            return handleTimeout(&state, token: token)
        default:
            break
        }

        guard isEngaged(state) else { return nil }
        switch event {
        case let .backgroundClicked(interaction):
            // 点击栏内空白：保持主窗口与模式，只登记可信交互，不收起、不穿透（方案 §7.2）。
            state.trustedInteraction = interaction
            return []
        case .cardClicked, .expandRequested:
            // 工作台里的卡片选择必须走 railCardSelected；旧展开路径不能在这里复活。
            return []
        case .escapePressed:
            return handleEscape(&state)
        case .globalShortcut, .returnShortcut:
            // 任意可见的工作台形态 → 隐藏并恢复（方案 §4.5）。
            state.pendingTarget = nil
            return SessionReducer.exitToHidden(&state)
        case .organizeRequested:
            return organizeRail(&state)
        default:
            return nil
        }
    }

    /// 工作台事件占据中：模式已完成切换，或正在模式过渡。
    private static func isEngaged(_ state: SessionState) -> Bool {
        state.mode == .workbench || state.workbench.modeTransition.isTransitioning
    }

    /// 令牌只对工作台自己的过渡/交换/备料有效，否则交回既有超时逻辑。
    private static func isWorkbenchToken(_ state: SessionState, _ token: TransitionToken) -> Bool {
        if state.workbench.armed?.context.transitionToken == token { return true }
        if state.workbench.modeTransition.token == token { return true }
        if state.workbench.mainSwitch.intent?.token == token { return true }
        if state.workbench.mainFrameWrite?.token == token { return true }
        return state.workbench.switchCorrection?.token == token
    }

    /// `recoveryRequired` 之下只允许重试补偿或安全退出：新的普通操作一律拒绝并说清原因（方案 §6.4、§15）。
    /// 拒绝不能等于"点什么都不动"：说出原因后按日志收口退出恢复，下一次打开才是干净会话。
    private static func recoveryBlock(_ state: inout SessionState) -> [SessionEffect]? {
        guard let recovery = state.workbench.recoveryRequired else { return nil }
        var effects: [SessionEffect] = [.presentHint(.workbenchSwitchFailed(recovery.reason))]
        effects.append(contentsOf: SessionReducer.exitToHidden(&state))
        return effects
    }

    // MARK: - 日志闸门（方案 §7.1、§7.2）

    /// 备好操作：只发批量落盘请求，几何 effect 与内存改动都寄存着，等 `journalPrepared` 才一次放出。
    /// 因此 prepare 失败天然等于"一次 AX 都没写"，落回原状态不需要任何补偿。
    private static func arm(_ state: inout SessionState,
                            context: GeometryOperationContext,
                            transactions: [WindowIdentity: WindowTransaction],
                            before: WorkbenchOperationSnapshot,
                            effects: [SessionEffect],
                            staged: StagedWorkbench) -> [SessionEffect] {
        state.workbench.armed = ArmedGeometryOperation(context: context,
                                                       effects: effects,
                                                       transactions: transactions,
                                                       before: before,
                                                       staged: staged)
        syncTransitionActivity(&state)
        let affected = affectedIdentities(before: before, transactions: transactions)
        let mutations: [JournalMutation] = affected.compactMap { identity in
            transactions[identity].map { JournalMutation.upsert($0) }
        }
        return [.prepareJournal(JournalPrepareRequest(context: context,
                                                      mutations: mutations,
                                                      affectedIdentities: affected))]
    }

    /// 批次里的顺序就是补偿顺序的依据：先按有副作用的步骤序，再补齐其余身份（按稳定键）。
    private static func affectedIdentities(before: WorkbenchOperationSnapshot,
                                           transactions: [WindowIdentity: WindowTransaction]) -> [WindowIdentity] {
        var result: [WindowIdentity] = []
        var seen = Set<WindowIdentity>()
        for identity in before.writtenOrder where transactions[identity] != nil && seen.insert(identity).inserted {
            result.append(identity)
        }
        for identity in transactions.keys.filter({ !seen.contains($0) })
            .sorted(by: { $0.journalKey < $1.journalKey }) {
            result.append(identity)
        }
        return result
    }

    private static func handleJournalPrepared(_ state: inout SessionState,
                                              context: GeometryOperationContext) -> [SessionEffect] {
        // 整体对上上下文才放行：旧会话或旧操作迟到的成功回执不能启动新写入（方案 §7.5）。
        guard let armed = state.workbench.armed, armed.context == context else { return [] }
        // 落盘期间世界可能已经变了：窗口关闭、轨道占用变化都要重查，点击时的资格不是几百毫秒后的资格（方案 §15）。
        if let reason = revalidationFailure(state, armed: armed) {
            return landPreparationFailure(&state, armed: armed, reason: reason)
        }
        state.workbench.armed = nil
        for (identity, transaction) in armed.transactions { state.transactions[identity] = transaction }
        state.workbench.applyStaged(armed.staged)
        state.phase = armed.staged.phase
        state.keyboardFocus = armed.staged.keyboardFocus
        state.workbench.activeContext = context
        state.workbench.runningOperation = armed.before
        syncTransitionActivity(&state)
        return armed.effects
    }

    private static func revalidationFailure(_ state: SessionState,
                                            armed: ArmedGeometryOperation) -> String? {
        for identity in armed.transactions.keys where state.records[identity] == nil {
            return "日志落盘期间窗口已消失：\(identity.journalKey)"
        }
        if case let .switching(intent, _) = armed.staged.mainSwitch,
           intent.placementRevision != state.workbench.placement.revision {
            return "日志落盘期间轨道占用已变化，本次交换未开始"
        }
        if let main = armed.staged.mainFrameWrite?.identity, state.records[main] == nil {
            return "日志落盘期间主窗口已消失"
        }
        return nil
    }

    private static func handleJournalPreparationFailed(_ state: inout SessionState,
                                                       context: GeometryOperationContext,
                                                       identities: [WindowIdentity],
                                                       reason: String) -> [SessionEffect] {
        if let armed = state.workbench.armed, armed.context == context {
            return landPreparationFailure(&state, armed: armed, reason: reason)
        }
        // 操作已经开始：这就是"写入之后落盘失败"，不能按未写入收口（方案 §7.2 末段）。
        if state.workbench.activeContext == context {
            return handlePostWriteJournalFailure(&state, context: context, identities: identities, reason: reason)
        }
        return []
    }

    /// prepare 失败落点（方案 §7.2 表）：一次 AX 都没写，按操作类型回到原状态，且必须可以再选。
    private static func landPreparationFailure(_ state: inout SessionState,
                                               armed: ArmedGeometryOperation,
                                               reason: String) -> [SessionEffect] {
        state.workbench.armed = nil
        state.workbench.pendingRailSelection = nil
        // 未落盘的事务从不进内存：这里只清意图，事务与 journal 都还是操作前的样子。
        switch armed.context.kind {
        case .enterWorkbench:
            state.workbench.modeTransition = .idle
            state.workbench.snapshot = nil
            state.mode = .overview
            state.phase = .overview
            state.keyboardFocus = .overview
            syncTransitionActivity(&state)
            return [.setKeyboardFocus(.overview), .hideWorkbench, .presentHint(.journalWriteFailed(reason))]

        case .mainSwitch:
            guard let intent = armed.staged.mainSwitch.intent, let old = intent.from,
                  state.workbench.placement.main == old, state.records[old] != nil else {
                // 旧主已经不在（或本来就没有旧主）：没有"A 仍在主区"可宣称，按空主区收口。
                return landEmptyMain(&state, hint: .journalWriteFailed(reason))
            }
            // A 保持工作台：placement、滚动、焦点都不动，只留一个可重试的失败态。
            state.workbench.mainSwitch = .failed(intent: intent, reason: reason)
            state.phase = .focused(target: old)
            state.keyboardFocus = .targetApplication
            syncTransitionActivity(&state)
            return [.setKeyboardFocus(.targetApplication), .presentHint(.journalWriteFailed(reason))]
                + layoutEffects(state)

        case .promoteCandidate:
            return landEmptyMain(&state, hint: .journalWriteFailed(reason))

        case .returnOverview:
            state.workbench.modeTransition = .idle
            if let main = state.workbench.placement.main, state.records[main] != nil {
                state.phase = .focused(target: main)
                state.keyboardFocus = .targetApplication
                syncTransitionActivity(&state)
                return [.setKeyboardFocus(.targetApplication), .presentHint(.journalWriteFailed(reason))]
            }
            state.phase = .overview
            state.keyboardFocus = .overview
            syncTransitionActivity(&state)
            return [.setKeyboardFocus(.overview), .presentHint(.journalWriteFailed(reason))]

        case .settleLayout:
            // 已提交布局原样保留：暂存的新投影从未落地，pending frame write 也从未建立（方案 §7.2、§11.2）。
            state.workbench.mainFrameWrite = nil
            syncTransitionActivity(&state)
            return [.presentHint(.journalWriteFailed(reason))] + layoutEffects(state)

        case .compensation, .sessionRestore:
            // 补偿与会话恢复不走 prepare 准入：它们面向已经发生的事实，这里只报告原因。
            syncTransitionActivity(&state)
            return [.presentHint(.journalWriteFailed(reason))]
        }
    }

    /// 替补或无旧主的交换没能开始：主区继续空、候选仍在轨道、键盘留在 Vistile 一侧（方案 §7.2、§10）。
    private static func landEmptyMain(_ state: inout SessionState, hint: HintKind) -> [SessionEffect] {
        state.workbench.mainSwitch = .idle
        state.workbench.activeContext = nil
        state.workbench.runningOperation = nil
        if state.workbench.placement.main == nil, state.mode == .workbench {
            state.phase = .overview
            state.keyboardFocus = .overview
            syncTransitionActivity(&state)
            return [.setKeyboardFocus(.overview), .presentHint(hint)] + layoutEffects(state)
        }
        if let main = state.workbench.placement.main, state.records[main] != nil {
            state.phase = .focused(target: main)
            state.keyboardFocus = .targetApplication
        } else {
            state.phase = .overview
            state.keyboardFocus = .overview
        }
        syncTransitionActivity(&state)
        return [.setKeyboardFocus(state.keyboardFocus), .presentHint(hint)] + layoutEffects(state)
    }

    private static func handleJournalUpdateFailed(_ state: inout SessionState,
                                                  context: GeometryOperationContext,
                                                  identity: WindowIdentity,
                                                  reason: String) -> [SessionEffect] {
        if let armed = state.workbench.armed, armed.context == context {
            return landPreparationFailure(&state, armed: armed, reason: reason)
        }
        guard state.workbench.activeContext == context else { return [] }
        let written = state.workbench.runningOperation.map { operation in
            operation.writtenOrder.filter { operation.entry(for: $0)?.didWrite == true }
        } ?? []
        // 写前事实（原位置纠正/操作前快照）落盘失败时，一次 AX 写入都还没发生：
        // 不需要排空通道、更不能撤销会话所有权——`drainGeometry` 会调宿主 cancel 把在途交换
        // 的回报全部挡掉，状态机就永远停在 rollingBack，之后的点击全被"交换在途"吞掉。
        // 这里只保留在途标记，让宿主按补偿结果回报 mainSwitchFailed / 过渡结论（方案 §7.3、§5.4）。
        let wroteNothing = written.isEmpty
            && state.workbench.runningOperation?.entry(for: identity)?.didWrite != true
        if wroteNothing {
            return []
        }
        var identities = Set(written)
        identities.insert(identity)
        return handlePostWriteJournalFailure(&state,
                                             context: context,
                                             identities: identities.sorted { $0.journalKey < $1.journalKey },
                                             reason: reason)
    }

    /// 真实写入之后的日志失败：停后续步骤，等补偿；journal 与事务原样保留（方案 §7.2 末段、§6.4）。
    ///
    /// **不能在这里发 `.drainGeometry`**：排空入口会撤销普通准入并让宿主 `switchCoordinator.cancel()`
    /// 交还会话所有权；而这次操作的失败结论（`mainSwitchFailed` / 过渡终止）正是由那条在途执行链
    /// 补偿后回报的。先取消它，回报就会被"会话已换"的门禁全部挡掉，状态机永远停在 rollingBack
    /// （0.1.13 实机：交换后整个界面不再响应点击，日志里持续报"过渡/交换在途"）。
    /// 排空只属于隐藏/退出入口（方案 §5.4）；操作自身的失败由宿主补偿后收口。
    private static func handlePostWriteJournalFailure(_ state: inout SessionState,
                                                      context: GeometryOperationContext,
                                                      identities: [WindowIdentity],
                                                      reason: String) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        if let intent = state.workbench.mainSwitch.intent, intent.operationContext == context {
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: reason)
            state.workbench.switchCorrection = nil
            syncTransitionActivity(&state)
            effects.append(.presentHint(.journalWriteFailed(reason)))
            return effects
        }
        effects.append(contentsOf: markRecoveryRequired(&state,
                                                        reason: reason,
                                                        identities: identities,
                                                        context: context))
        effects.append(.presentHint(.journalWriteFailed(reason)))
        syncTransitionActivity(&state)
        return effects
    }

    /// 进入显式"未能恢复一致"：几何不再可信，键盘收回 Vistile，等待重试或安全退出（方案 §15）。
    private static func markRecoveryRequired(_ state: inout SessionState,
                                             reason: String,
                                             identities: [WindowIdentity],
                                             context: GeometryOperationContext?) -> [SessionEffect] {
        state.workbench.recoveryRequired = WorkbenchRecoveryRequired(reason: reason,
                                                                    identities: identities,
                                                                    context: context)
        state.workbench.switchCorrection = nil
        guard let target = identities.first ?? state.workbench.placement.main ?? state.phase.controlledTarget,
              state.records[target] != nil else {
            state.keyboardFocus = .overview
            return [.setKeyboardFocus(.overview)]
        }
        state.phase = .recoveryRequired(target: target, reason: reason)
        state.keyboardFocus = .overview
        return [.setKeyboardFocus(.overview)]
    }

    /// 过渡活动事实的唯一维护点：备料中看暂存，已开始看落地状态（方案 §13.2）。
    private static func syncTransitionActivity(_ state: inout SessionState) {
        var activity = TransitionActivity()
        activity.focusProxy = state.workbench.transitionActivity.focusProxy
        activity.cancellationRequested = state.workbench.transitionActivity.cancellationRequested
        if let staged = state.workbench.armed?.staged {
            activity.modeTransition = staged.modeTransition.isTransitioning
            activity.mainSwitch = staged.mainSwitch.isBusy
            activity.layoutSettle = staged.mainFrameWrite != nil
        } else {
            activity.modeTransition = state.workbench.modeTransition.isTransitioning
            activity.mainSwitch = state.workbench.mainSwitch.isBusy
            activity.layoutSettle = state.workbench.mainFrameWrite != nil
        }
        activity.rollback = state.workbench.mainSwitch.isRollingBack
        state.workbench.transitionActivity = activity
    }

    /// 当前操作写过哪些窗口：补偿与"恢复依据"判定都用它（方案 §6.3、§18 A42）。
    private static func writtenIdentities(_ state: SessionState) -> [WindowIdentity] {
        guard let operation = state.workbench.runningOperation else { return [] }
        return operation.writtenOrder.filter { operation.entry(for: $0)?.didWrite == true }
    }

    // MARK: - 总览 → 工作台（方案 §4.2）

    private static func beginEnterWorkbench(_ state: inout SessionState, identity: WindowIdentity) -> [SessionEffect] {
        // 只在总览落地态、且没有进行中的工作台动作时开始；未点击前绝不改真实窗口（方案 §4.1）。
        guard state.mode == .overview, case .overview = state.phase,
              state.workbench.modeTransition == .idle else { return [] }
        // 上一笔操作还在落盘：不覆盖它备好的意图，第二次点击必须等前一次收敛（方案 §7.1、§10.4）。
        guard state.workbench.armed == nil else { return [] }
        if let blocked = recoveryBlock(&state) { return blocked }
        return startEnterWorkbench(&state, identity: identity)
    }

    private static func startEnterWorkbench(_ state: inout SessionState, identity: WindowIdentity) -> [SessionEffect] {
        if state.workbench.activeContext != nil { return [] }
        guard let record = state.records[identity] else { return [.presentHint(.cannotLocateWindow)] }
        guard record.allowsAutoFocus else {
            return [.presentHint(record.confidence.isAmbiguous ? .ambiguousWindow : .cannotLocateWindow)]
        }
        guard let display = workbenchDisplay(state, identity: identity, record: record) else {
            return [.presentHint(.displayUnavailable(record.applicationName))]
        }
        guard let baseLayout = workbenchLayout(for: display, state: state) else {
            return [.presentHint(.displayUnavailable(record.applicationName))]
        }
        // 放置路径由核心层算一次：不可容纳就不进主区，日志与写入都还没有开始（方案 §9.1）。
        // 但目录缓存只是乐观预检：缓存 frame 可能落后于真实窗口，固定尺寸窗口的缓存尺寸也可能过期。
        // 可移动且主区有效时交给宿主用写前实读重新决策，不把其实放得下的窗口提前挡在门外（方案 §6.2）。
        let mainRect = baseLayout.mainRect
        let decision = MainPlacementPolicy.decide(mainRect: mainRect,
                                                  currentFrame: actualFrame(state, identity) ?? record.frame,
                                                  isMovable: record.isMovable,
                                                  isResizable: record.allowsGeometryControl)
        let targetFrame: CGRect
        let placement: MainPlacementDecision
        if let planned = decision.targetFrame {
            targetFrame = planned
            placement = decision
        } else if canDeferPlacement(record: record, mainRect: mainRect) {
            // 临时计划目标取主区：宿主会拿写前实读重新算，真实放不下仍由它按失败/补偿收口。
            targetFrame = mainRect
            placement = .resizeAndMove(target: mainRect)
        } else {
            return [.presentHint(.restrictedWindow(unavailableReason(decision)))]
        }
        // 本次进入后的轨道占用：只用于动画端点与展示事实；placement 在过渡成功后才提交。
        var prospective = state.workbench.placement
        let layout = initializeRailOccupants(&prospective, state: state, target: identity, layout: baseLayout)
        // 重入沿用上次离开时的偏移，只按新布局 clamp，绝不硬编码 0（方案 §12）。
        let snapshot = WorkbenchLayoutSnapshot(displayID: display.id,
                                               layout: layout,
                                               topScrollOffset: state.workbench.reentryScrollOffset(rail: .top, layout: layout),
                                               sideScrollOffset: state.workbench.reentryScrollOffset(rail: .side, layout: layout),
                                               revision: state.workbench.layoutRevision + 1)

        let token = state.nextTransitionToken()
        let context = state.nextOperationContext(kind: .enterWorkbench, token: token)
        let before = WorkbenchOperationSnapshot(context: context,
                                                writtenOrder: [identity],
                                                before: [identity: OperationGeometrySnapshot(identity: identity,
                                                                                             beforeFrame: targetFrame == layout.mainRect ? record.frame : (actualFrame(state, identity) ?? record.frame),
                                                                                             beforeDisplayID: record.displayID)])
        guard let transaction = SessionReducer.preparedTransaction(state, target: identity,
                                                                   planned: targetFrame, displayID: display.id)?
            .markingOperationBefore(frame: before.entry(for: identity)?.beforeFrame,
                                    displayID: record.displayID,
                                    operationID: context.operationID) else { return [] }
        var staged = StagedWorkbench()
        staged.snapshot = snapshot
        staged.layoutRevision = snapshot.revision
        staged.modeTransition = .enteringWorkbench(token: token, target: identity)
        staged.phase = .expanding(target: identity, token: token)
        staged.keyboardFocus = state.keyboardFocus
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           operationContext: context,
                                           identity: identity,
                                           displayID: display.id,
                                           snapshot: snapshot,
                                           targetFrame: targetFrame,
                                           animationFrom: state.cellRect(for: identity),
                                           animationTo: targetFrame,
                                           railHandoffs: railHandoffs(state, snapshot: snapshot,
                                                                      placement: prospective,
                                                                      excluding: identity, entering: true),
                                           animationMS: layout.style.entryAnimationMS(reduceMotion: state.policy.reduceMotion),
                                           presentation: WorkbenchPresenter.make(state: state,
                                                                                 snapshot: snapshot,
                                                                                 placement: prospective),
                                           placement: placement)
        // 写前事务与操作快照先原子落盘，宿主确认后才允许第一笔 AX 写入（方案 §7.1、§6.2）。
        return arm(&state,
                   context: context,
                   transactions: [identity: transaction],
                   before: before,
                   effects: [.enterWorkbench(plan)],
                   staged: staged)
    }

    private static func finishModeTransition(_ state: inout SessionState,
                                             token: TransitionToken,
                                             kind: WorkbenchTransitionKind,
                                             result: WorkbenchStepOutcome) -> [SessionEffect] {
        switch kind {
        case .enteringWorkbench:
            guard case let .enteringWorkbench(current, target) = state.workbench.modeTransition,
                  current == token else { return [] }
            state.workbench.modeTransition = .idle
            state.workbench.activeContext = nil
            state.workbench.runningOperation = nil
            syncTransitionActivity(&state)
            // constrained 只说明"写入被接受并做了约束"，仍在主区才算合格（方案 §9.2）。
            guard result.allowsContinue, isMainAreaTrustworthy(state, readBack: result.readBackFrame),
                  state.records[target] != nil, let snapshot = state.workbench.snapshot else {
                // 失败留在原总览：不提交 placement、不留下半套轨道（方案 §4.2.7）。
                state.workbench.snapshot = nil
                state.mode = .overview
                state.phase = .overview
                state.keyboardFocus = .overview
                return [.cancelWorkbenchTransition, .hideWorkbench, .setKeyboardFocus(.overview),
                        .presentHint(.workbenchTransitionFailed(result.message))]
            }
            var placement = state.workbench.placement
            let extended = initializeRailOccupants(&placement, state: state, target: target, layout: snapshot.layout)
            state.workbench.placement = placement
            if extended != snapshot.layout {
                let updated = snapshot.replacing(layout: extended, revision: state.workbench.layoutRevision + 1)
                state.workbench.snapshot = updated
                state.workbench.layoutRevision = updated.revision
            }
            state.workbench.activeDisplayID = snapshot.displayID
            state.workbench.lastSelectedMain = target
            // 主窗口已确定：这次会话的关闭事件重新获得一次自动替补额度（方案 §10）。
            state.workbench.hasAutoPromotionAttempted = false
            state.mode = .workbench
            state.phase = .focused(target: target)
            state.keyboardFocus = .targetApplication
            var effects = recordObservedWrite(&state, identity: target, outcome: result)
            effects.append(.setKeyboardFocus(.targetApplication))
            effects.append(.updateWorkbenchLayout(WorkbenchPresenter.make(state: state,
                                                                          snapshot: state.workbench.snapshot ?? snapshot,
                                                                          placement: state.workbench.placement)))
            // 进入过程中攒下的栏尺寸更新在这一刻落地（方案 §13.2）。
            effects.append(contentsOf: applyDeferredRailSize(&state))
            return effects

        case .returningOverview:
            guard case let .returningOverview(current) = state.workbench.modeTransition,
                  current == token else { return [] }
            state.workbench.modeTransition = .idle
            state.workbench.activeContext = nil
            state.workbench.runningOperation = nil
            syncTransitionActivity(&state)
            let main = state.workbench.placement.main
            if !result.allowsContinue, let main, state.records[main] != nil {
                // 返回失败：留在工作台，主窗口恢复可操作（方案 §8.3、§10.2）。
                state.phase = .focused(target: main)
                state.keyboardFocus = .targetApplication
                return [.cancelWorkbenchTransition, .setKeyboardFocus(.targetApplication),
                        .presentHint(.workbenchTransitionFailed(result.message))]
            }
            // 成功：L 型上下文保存下来（occupants/side/scroll/偏好），activeMain 归零（方案 §4.4）。
            state.workbench.saveScrollOffsets()
            state.mode = .overview
            state.workbench.placement.setMain(nil)
            state.phase = .overview
            state.keyboardFocus = .overview
            var effects: [SessionEffect] = []
            if let main {
                effects = recordObservedWrite(&state, identity: main, outcome: result)
                if case .succeeded(readBack: nil) = result {
                    // 写回已经由恢复路径完成并结算（日志条目已删）：state 侧同步收口。
                    // 否则这条事务会以"待恢复"余留在内存里，下一次中断恢复拿不到日志条目，
                    // 会误报"尺寸未能恢复"（方案 §6.4）。
                    state.transactions.removeValue(forKey: main)
                    effects.append(.clearJournal(sessionID: state.sessionID, settledIdentities: [main]))
                }
            }
            effects.append(contentsOf: [.setKeyboardFocus(.overview), .hideWorkbench, .showOverview(displayID: nil)])
            return effects
        }
    }

    // MARK: - 工作台 → 总览（方案 §4.4）

    private static func beginReturnOverview(_ state: inout SessionState) -> [SessionEffect] {
        guard state.mode == .workbench else { return [] }
        guard state.workbench.modeTransition == .idle else { return [] }
        if let blocked = recoveryBlock(&state) { return blocked }
        if state.workbench.mainSwitch.isBusy {
            // 交换进行中：记住意图，等这次收敛后再回总览（方案 §4.5、§7.2）。
            state.workbench.pendingReturnToOverview = true
            state.workbench.pendingRailSelection = nil
            return []
        }
        // 上一笔操作还在落盘：交换类的记下"要回总览"，其余一律等它自己收敛（方案 §7.2、§10.4）。
        if let armed = state.workbench.armed {
            if armed.staged.mainSwitch.isBusy {
                state.workbench.pendingReturnToOverview = true
                state.workbench.pendingRailSelection = nil
            }
            return []
        }
        guard let snapshot = state.workbench.snapshot else { return [] }
        guard let main = state.workbench.placement.main, let record = state.records[main] else {
            // 没有主窗口：没有真实几何要动，直接落回总览。
            state.workbench.saveScrollOffsets()
            state.mode = .overview
            state.workbench.placement.setMain(nil)
            state.phase = .overview
            state.keyboardFocus = .overview
            return [.setKeyboardFocus(.overview), .hideWorkbench, .showOverview(displayID: nil)]
        }
        let token = state.nextTransitionToken()
        let context = state.nextOperationContext(kind: .returnOverview, token: token)
        let targetFrame = state.transactions[main]?.restoreTargetFrame(preserveUserGeometry: state.policy.preserveUserGeometry)
            ?? record.frame
        let beforeFrame = actualFrame(state, main) ?? record.frame
        let before = WorkbenchOperationSnapshot(context: context,
                                                writtenOrder: [main],
                                                before: [main: OperationGeometrySnapshot(identity: main,
                                                                                         beforeFrame: beforeFrame,
                                                                                         beforeDisplayID: record.displayID)])
        var transactions: [WindowIdentity: WindowTransaction] = [:]
        if let transaction = SessionReducer.preparedTransaction(state, target: main,
                                                                planned: targetFrame,
                                                                displayID: state.transactions[main]?.originalDisplayID ?? record.displayID) {
            transactions[main] = transaction.markingOperationBefore(frame: beforeFrame,
                                                                    displayID: record.displayID,
                                                                    operationID: context.operationID)
        }
        var staged = StagedWorkbench()
        staged.modeTransition = .returningOverview(token: token)
        staged.phase = .collapsing(target: main, token: token)
        staged.keyboardFocus = state.keyboardFocus
        let plan = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: token,
                                           operationContext: context,
                                           identity: main,
                                           displayID: snapshot.displayID,
                                           snapshot: snapshot,
                                           targetFrame: targetFrame,
                                           animationFrom: snapshot.layout.mainRect,
                                           animationTo: state.cellRect(for: main),
                                           railHandoffs: railHandoffs(state, snapshot: snapshot,
                                                                      placement: state.workbench.placement,
                                                                      excluding: main, entering: false),
                                           animationMS: snapshot.layout.style.returnAnimationMS(reduceMotion: state.policy.reduceMotion),
                                           presentation: WorkbenchPresenter.make(state: state,
                                                                                  snapshot: snapshot,
                                                                                  placement: state.workbench.placement),
                                           placement: .resizeAndMove(target: targetFrame))
        return arm(&state,
                   context: context,
                   transactions: transactions,
                   before: before,
                   effects: [.returnToOverview(plan)],
                   staged: staged)
    }

    // MARK: - 轨道选择与 A/B 交换（方案 §4.3、§8）

    private static func beginRailSelection(_ state: inout SessionState,
                                           slot: RailSlotID,
                                           identity: WindowIdentity) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle else { return [] }
        if let blocked = recoveryBlock(&state) { return blocked }
        // 事实对不上（占用已变化）就不写几何；以 placement 为准。
        guard state.workbench.placement.occupant(at: slot) == identity else { return [] }
        guard state.workbench.placement.main != identity else { return [] }
        if state.workbench.mainSwitch.isBusy {
            // 交换已进入写入通道：只保存最新目标，前一次收敛后再处理（方案 §7.2、§10.4）。后到的点击覆盖先前意图。
            state.workbench.pendingRailSelection = WorkbenchPendingSelection(identity: identity, slot: slot)
            state.workbench.pendingReturnToOverview = false
            return []
        }
        // 尚未写入的自动替补意图可以被用户的手动选择顶掉：preparing 阶段最新选择优先（方案 §10 第 291 行、§15）。
        // 这条判定必须排在"armed 里有一次在途交换"之前：替补的 staged 同样是 `.switching`，
        // 走排队会让一个连一个像素都没写的意图真的去写 B，再写 C。
        if state.workbench.armed?.context.kind == .promoteCandidate {
            state.workbench.armed = nil
            state.workbench.pendingRailSelection = nil
            syncTransitionActivity(&state)
        } else if let armed = state.workbench.armed, armed.staged.mainSwitch.isBusy {
            // 前一次意图已经进过写入通道：只保存最新目标，等它收敛后再处理（方案 §7.2、§10.4）。
            state.workbench.pendingRailSelection = WorkbenchPendingSelection(identity: identity, slot: slot)
            state.workbench.pendingReturnToOverview = false
            return []
        }
        return startSwitch(&state, to: identity, slot: slot, kind: .mainSwitch)
    }

    private static func startSwitch(_ state: inout SessionState,
                                    to identity: WindowIdentity,
                                    slot: RailSlotID,
                                    kind: GeometryOperationKind) -> [SessionEffect] {
        guard state.workbench.activeContext == nil || kind == .promoteCandidate else { return [] }
        guard let record = state.records[identity] else { return [.presentHint(.cannotLocateWindow)] }
        guard record.allowsAutoFocus else {
            return [.presentHint(record.confidence.isAmbiguous ? .ambiguousWindow : .cannotLocateWindow)]
        }
        guard let snapshot = state.workbench.snapshot else { return [] }
        let placement = state.workbench.placement
        let token = state.nextTransitionToken()
        let context = state.nextOperationContext(kind: kind, token: token)
        // 放置方式在核心层算一次：仅移动路径不写 size，不可容纳就根本不发起操作（方案 §9.1）。
        // 与进入同理：缓存 frame 只当乐观预检，可移动且主区有效时让宿主用写前实读重新决策（方案 §6.2）。
        let mainRect = snapshot.layout.mainRect
        let decision = MainPlacementPolicy.decide(mainRect: mainRect,
                                                  currentFrame: actualFrame(state, identity) ?? record.frame,
                                                  isMovable: record.isMovable,
                                                  isResizable: record.allowsGeometryControl)
        let mainTarget: CGRect
        let placementDecision: MainPlacementDecision
        if let planned = decision.targetFrame {
            mainTarget = planned
            placementDecision = decision
        } else if canDeferPlacement(record: record, mainRect: mainRect) {
            // 临时计划目标取主区：宿主会拿写前实读重新算，真实放不下仍由它按失败/补偿收口。
            mainTarget = mainRect
            placementDecision = .resizeAndMove(target: mainRect)
        } else {
            return [.presentHint(.workbenchMainFrameFailed(unavailableReason(decision)))]
        }
        // 旧主（若存在）回到它的 resting frame：原始尺寸或用户明确保留的尺寸（方案 §8.1）。
        var restingTarget: CGRect?
        if let from = placement.main, let fromRecord = state.records[from] {
            restingTarget = state.transactions[from]?
                .restoreTargetFrame(preserveUserGeometry: state.policy.preserveUserGeometry)
                ?? fromRecord.frame
        }
        // 操作前实读快照：补偿按它逆序回位，而不是按会话 original（方案 §6.2、§6.3）。
        var before = WorkbenchOperationSnapshot(context: context)
        before.record(OperationGeometrySnapshot(identity: identity,
                                                beforeFrame: actualFrame(state, identity) ?? record.frame,
                                                beforeDisplayID: record.displayID),
                      writtenStep: true)
        if let from = placement.main, let fromRecord = state.records[from], restingTarget != nil {
            before.record(OperationGeometrySnapshot(identity: from,
                                                    beforeFrame: actualFrame(state, from) ?? fromRecord.frame,
                                                    beforeDisplayID: fromRecord.displayID),
                          writtenStep: true)
        }

        let intent = WorkbenchSwitchIntent(token: token,
                                           from: placement.main,
                                           to: identity,
                                           source: .rail(slot: slot),
                                           placementRevision: placement.revision,
                                           targetDisplayID: snapshot.displayID,
                                           operationContext: context,
                                           beforeOperation: before)
        var transactions: [WindowIdentity: WindowTransaction] = [:]
        // 写前事务：B 的目标是主区；A 的目标是它的回落点。都在同一批次里原子落盘（方案 §7.1、§8.2.3）。
        if let transaction = SessionReducer.preparedTransaction(state, target: identity,
                                                                planned: mainTarget, displayID: snapshot.displayID) {
            transactions[identity] = transaction.markingOperationBefore(
                frame: before.entry(for: identity)?.beforeFrame,
                displayID: record.displayID,
                operationID: context.operationID)
        }
        if let from = placement.main, let restingTarget,
           let transaction = SessionReducer.preparedTransaction(state, target: from,
                                                                planned: restingTarget,
                                                                displayID: state.transactions[from]?.originalDisplayID ?? snapshot.displayID) {
            transactions[from] = transaction.markingOperationBefore(
                frame: before.entry(for: from)?.beforeFrame,
                displayID: state.records[from]?.displayID ?? transaction.originalDisplayID,
                operationID: context.operationID)
        }
        var staged = StagedWorkbench()
        staged.mainSwitch = .switching(intent: intent, step: .prepare)
        if let from = placement.main {
            staged.phase = .switching(from: from, to: identity, token: token)
        } else {
            staged.phase = .focused(target: identity)
        }
        staged.keyboardFocus = state.keyboardFocus
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: snapshot.displayID,
                                       mainTargetFrame: mainTarget,
                                       restingTargetFrame: restingTarget,
                                       restingSlot: placement.main.flatMap { placement.slot(of: $0) },
                                       snapshot: snapshot,
                                       presentation: WorkbenchPresenter.make(state: state,
                                                                              snapshot: snapshot,
                                                                              placement: placement),
                                       placement: placementDecision)
        return arm(&state,
                   context: context,
                   transactions: transactions,
                   before: before,
                   effects: [.beginMainSwitch(plan)],
                   staged: staged)
    }

    private static func recordSwitchStep(_ state: inout SessionState,
                                         _ result: WorkbenchSwitchStepResult) -> [SessionEffect] {
        guard case let .switching(intent, _) = state.workbench.mainSwitch,
              intent.token == result.token else { return [] }
        guard result.outcome.allowsContinue else {
            // 失败：宿主按逆序补偿；补偿完成前不提交 placement（方案 §8.3）。
            if let identity = result.identity, result.outcome.readBackFrame != nil {
                state.workbench.runningOperation?.markWritten(identity, readBack: result.outcome.readBackFrame)
            }
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: result.outcome.message)
            state.workbench.switchCorrection = nil
            syncTransitionActivity(&state)
            return []
        }
        var effects: [SessionEffect] = []
        // 主区几何步骤：读回必须逐条对 mainRect 与两条栏验证，只有 accepted 才允许后续提交（方案 §9.2）。
        if result.step == .moveToMain, let identity = result.identity, let readBack = result.outcome.readBackFrame,
           let snapshot = state.workbench.snapshot {
            switch MainPlacementPolicy.verify(readBack: readBack,
                                              mainRect: snapshot.layout.mainRect,
                                              topRailRect: snapshot.layout.topRailRect,
                                              sideRailRect: snapshot.layout.sideRailRect) {
            case .accepted:
                break
            case let .correctPosition(to: corrected):
                guard state.workbench.switchCorrection == nil else {
                    // 已经修正过一次仍越界：不提交，交给宿主逆序补偿（方案 §9.2）。
                    state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "位置修正后仍越出主区")
                    syncTransitionActivity(&state)
                    return [.presentHint(.workbenchMainFrameFailed("位置修正后仍越出主区"))]
                }
                state.workbench.runningOperation?.markWritten(identity, readBack: readBack)
                state.workbench.switchCorrection = WorkbenchFrameWrite(token: intent.token, identity: identity)
                // 有界修正仍属于本操作上下文：日志先行，再写一次 position（方案 §7.1、§9.2）。
                effects.append(.settleMainFrame(identity, targetFrame: corrected, context: intent.operationContext,
                                                animationMS: snapshot.layout.style.settleAnimationMS(reduceMotion: state.policy.reduceMotion)))
                // 步骤不前进：等修正读回再决定继续还是补偿。
                return effects
            case let .rejected(reason):
                state.workbench.runningOperation?.markWritten(identity, readBack: readBack)
                state.workbench.mainSwitch = .rollingBack(intent: intent, reason: reason)
                syncTransitionActivity(&state)
                return [.presentHint(.workbenchMainFrameFailed(reason))]
            }
        }
        // 动过真实几何的步骤：把读回事实记回事务，退出恢复才知道"最后落在哪"（方案 §8.2.3）。
        if result.step == .moveToMain || result.step == .restorePrevious, let identity = result.identity {
            effects += recordObservedWrite(&state, identity: identity, outcome: result.outcome)
        }
        state.workbench.mainSwitch = .switching(intent: intent, step: nextStep(after: result.step))
        syncTransitionActivity(&state)
        return effects
    }

    /// 模式过渡/交换的几何写入完成后，把读回事实记回事务（方案 §6.5、§8.2.3）。
    /// 只记"写入确实发生并有读回"的结果；被拒/目标消失由宿主的补偿与恢复路径按事实结算，
    /// 这里不写失败戳，避免和宿主回滚抢同一格日志。
    private static func recordObservedWrite(_ state: inout SessionState,
                                            identity: WindowIdentity,
                                            outcome: WorkbenchStepOutcome) -> [SessionEffect] {
        switch outcome {
        case .rejected, .targetGone:
            return []
        case let .succeeded(readBack):
            if readBack == nil {
                // 没有读回值也要记下"这一步确实写过"：补偿义务按事实判定，不按有没有数值判定（方案 §6.4）。
                state.workbench.runningOperation?.markWritten(identity, readBack: nil)
                return []
            }
        case .constrained, .outsideMain:
            break
        }
        guard var transaction = state.transactions[identity] else { return [] }
        let displayID = transaction.plannedDisplayID ?? transaction.originalDisplayID
        switch outcome {
        case let .succeeded(readBack):
            guard let readBack else { return [] }
            transaction = transaction.markingVerified(readBack: readBack, displayID: displayID)
        case let .constrained(readBack, note):
            transaction = transaction.markingWritten(readBack: readBack, displayID: displayID, note: note)
        case let .outsideMain(readBack, reason):
            transaction = transaction.markingWritten(readBack: readBack, displayID: displayID, note: reason)
        case .rejected, .targetGone:
            return []
        }
        state.transactions[identity] = transaction
        state.workbench.runningOperation?.markWritten(identity, readBack: outcome.readBackFrame)
        return [.updateJournal(JournalUpdateRequest(operationID: state.workbench.runningOperation?.context.operationID
                                                        ?? transaction.operationID,
                                                    identity: identity,
                                                    mutation: .upsert(transaction)))]
    }

    private static func commitMainSwitch(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        // 只认 `.switching`：`.rollingBack`/`.failed` 也暴露同一个 intent，但那时补偿还没结算，
        // 提交就等于宣称一个日志不可信的交换已经成功（方案 §7.2 末段、§18 A17）。
        guard case let .switching(intent, _) = state.workbench.mainSwitch, intent.token == token else { return [] }
        var placement = state.workbench.placement
        let target = intent.to
        var effects: [SessionEffect] = []
        if let from = intent.from, state.records[from] != nil, placement.main == from,
           let slot = intent.railSlot, placement.occupant(at: slot) == target {
            // Commit selection only; rail occupants retain their original slots.
            placement.swapMain(with: slot)
        } else if intent.from == nil || state.records[intent.from!] == nil {
            // 没有旧主（首次选择、自动替补），或旧主已在途中关闭：
            // B becomes main while retaining its thumbnail slot.
            placement.setMain(target)
        } else {
            // 事实已变化：不假提交，也不动已写入的窗口（方案 §8.3）。
            let reason = "轨道占用已变化，未提交交换"
            state.workbench.mainSwitch = .failed(intent: intent, reason: reason)
            state.workbench.pendingRailSelection = nil
            if let main = placement.main { state.phase = .focused(target: main) }
            syncTransitionActivity(&state)
            return [.presentHint(.workbenchSwitchFailed(reason))]
        }
        state.workbench.placement = placement
        state.workbench.lastSelectedMain = target
        state.workbench.mainSwitch = .idle
        state.workbench.activeContext = nil
        state.workbench.runningOperation = nil
        state.workbench.switchCorrection = nil
        state.workbench.hasAutoPromotionAttempted = false
        state.phase = .focused(target: target)
        state.keyboardFocus = .targetApplication
        syncTransitionActivity(&state)
        effects.append(.setKeyboardFocus(.targetApplication))
        effects.append(contentsOf: layoutEffects(state))
        // 交换期间攒下的栏尺寸更新在交换收敛这一刻落地（方案 §13.2）。
        effects.append(contentsOf: applyDeferredRailSize(&state))
        // latest-wins：前一次已经收敛，现在处理等着的最后意图（方案 §10.4）。
        if state.workbench.pendingReturnToOverview {
            state.workbench.pendingReturnToOverview = false
            effects.append(contentsOf: beginReturnOverview(&state))
        } else if let pending = state.workbench.pendingRailSelection {
            state.workbench.pendingRailSelection = nil
            if pending.identity != target {
                effects.append(contentsOf: startSwitch(&state, to: pending.identity, slot: pending.slot,
                                                       kind: .mainSwitch))
            }
        }
        return effects
    }

    /// 交换失败并已补偿：只有补偿事实说"A 确实回到 beforeA 且 A 被激活"才能宣称主窗口不变（方案 §6.4）。
    private static func failMainSwitch(_ state: inout SessionState,
                                       token: TransitionToken,
                                       reason: String,
                                       compensation: WorkbenchCompensationResult?) -> [SessionEffect] {
        guard let intent = state.workbench.mainSwitch.intent, intent.token == token else { return [] }
        state.workbench.switchCorrection = nil
        let old = intent.from
        if let compensation, canClaimOldMainStillMain(state, intent: intent, old: old, compensation: compensation) {
            state.workbench.mainSwitch = .idle
            state.workbench.activeContext = nil
            state.workbench.runningOperation = nil
            state.workbench.pendingRailSelection = nil
            state.phase = .focused(target: old!)
            state.keyboardFocus = .targetApplication
            syncTransitionActivity(&state)
            var effects: [SessionEffect] = [.setKeyboardFocus(.targetApplication),
                                            .presentHint(.workbenchSwitchFailed(reason))]
            // 回滚到主区不等于会话已恢复：A 的事务与日志条目必须原样留着等最终退出（方案 §6.4、A12）。
            effects.append(contentsOf: recordCompensationFacts(&state, intent: intent, compensation: compensation,
                                                              reason: reason))
            effects.append(contentsOf: layoutEffects(state))
            // 失败回滚完成后，等着的「全部窗口」意图仍然有效（方案 §4.5）。
            if state.workbench.pendingReturnToOverview {
                state.workbench.pendingReturnToOverview = false
                effects.append(contentsOf: beginReturnOverview(&state))
            }
            return effects
        }
        // 无旧主（自动替补）失败：候选按事实回到本次操作写入前的位置，几何就是可信的——
        // 主区继续空、候选留在轨道，用户还能自己选别人（方案 §10、§18 A27）。
        if old == nil, let compensation, canClaimCandidateIsHome(state, intent: intent, compensation: compensation) {
            state.workbench.pendingRailSelection = nil
            var effects = landEmptyMain(&state, hint: .workbenchSwitchFailed(reason))
            effects.append(contentsOf: recordCompensationFacts(&state, intent: intent, compensation: compensation,
                                                              reason: reason))
            return effects
        }
        // 补偿不完整、缺事实、或旧主本身已经不可信：转入显式 recoveryRequired，绝不发 .focused(A)（方案 §6.4）。
        let missing = intent.beforeOperation.writtenOrder.filter { compensation?.action(for: $0) == nil }
        let unresolved = compensation.map { $0.unresolvedIdentities } ?? []
        var identities = Set(unresolved).union(Set(missing))
        if let operation = state.workbench.runningOperation {
            identities.formUnion(operation.writtenOrder.filter { operation.entry(for: $0)?.didWrite == true })
        }
        if identities.isEmpty, let old { identities.insert(old) }
        if identities.isEmpty { identities.insert(intent.to) }
        state.workbench.mainSwitch = .failed(intent: intent, reason: reason)
        state.workbench.pendingRailSelection = nil
        let sorted = identities.sorted { $0.journalKey < $1.journalKey }
        var effects = markRecoveryRequired(&state,
                                          reason: "交换失败且未能恢复一致：\(reason)",
                                          identities: sorted,
                                          context: intent.operationContext)
        effects.append(.presentHint(.workbenchSwitchFailed(reason)))
        effects.append(contentsOf: recordCompensationFacts(&state, intent: intent, compensation: compensation ?? .init(items: [], activatedMain: nil),
                                                           reason: reason))
        syncTransitionActivity(&state)
        return effects
    }

    /// 「A 仍在主区」的判定：placement 从未提交、补偿事实齐全、A 回到本次操作写入前的位置、且 A 确实被激活。
    /// 写入前位置以宿主写前实读（`compensation.beforeReads`）为准，缺它才退回计划期快照（方案 §6.2、§6.4）。
    private static func canClaimOldMainStillMain(_ state: SessionState,
                                                 intent: WorkbenchSwitchIntent,
                                                 old: WindowIdentity?,
                                                 compensation: WorkbenchCompensationResult) -> Bool {
        guard let old, state.records[old] != nil else { return false }
        guard state.workbench.placement.main == old else { return false }
        guard compensation.activatedMain == old, compensation.isComplete else { return false }
        // 落点以宿主写前实读为准；没有实读事实时才退回计划期推测值（方案 §6.2、§6.4）。
        guard let target = compensationTarget(for: old, intent: intent, compensation: compensation) else {
            return false
        }
        switch compensation.action(for: old) {
        case .notWritten:
            // A 从未被写过：它本来就在 beforeA 的位置，这是事实而不是推定。
            return true
        case let .restoredTo(frame), let .alreadyInPlace(frame):
            return WindowTransaction.framesClose(frame, target, tolerance: 2)
        case .refused, nil:
            return false
        }
    }

    /// 「候选已归位」的判定：本次操作没有旧主（自动替补/空主区提升），补偿把每个写入过的身份
    /// 都送回了操作前的位置。`isComplete` 在这里不能用——它要求旧主被重新激活，而替补没有旧主。
    private static func canClaimCandidateIsHome(_ state: SessionState,
                                                intent: WorkbenchSwitchIntent,
                                                compensation: WorkbenchCompensationResult) -> Bool {
        guard state.workbench.placement.main == nil, state.workbench.placement.slot(of: intent.to) != nil else {
            return false
        }
        // 解除过但没恢复的最小化：真实系统状态没有收回原样，不能宣称"候选已归位"（方案 §6.4）。
        guard compensation.unresolvedMinimizeRestorations.isEmpty else { return false }
        for identity in intent.beforeOperation.writtenOrder {
            // 有宿主写前实读时不需要计划期条目；两者都没有才算缺事实。
            guard compensationTarget(for: identity, intent: intent, compensation: compensation) != nil else {
                return false
            }
            guard let action = compensation.action(for: identity), action.isResolved else { return false }
        }
        guard let target = compensationTarget(for: intent.to, intent: intent, compensation: compensation) else {
            return false
        }
        switch compensation.action(for: intent.to) {
        case .notWritten:
            // 候选从未被写过：它还停在原格，这是事实而不是推定。
            return true
        case let .restoredTo(frame), let .alreadyInPlace(frame):
            return WindowTransaction.framesClose(frame, target, tolerance: 2)
        case .refused, nil:
            return false
        }
    }

    /// 把补偿事实追加进日志：写过什么、回到哪里，都要留得下来（方案 §6.4、§7.3）。
    private static func recordCompensationFacts(_ state: inout SessionState,
                                                intent: WorkbenchSwitchIntent,
                                                compensation: WorkbenchCompensationResult,
                                                reason: String) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        for item in compensation.items {
            guard var transaction = state.transactions[item.identity] else { continue }
            switch item.action {
            case let .restoredTo(frame), let .alreadyInPlace(frame):
                transaction = transaction.markingVerified(readBack: frame,
                                                          displayID: item.displayID ?? transaction.originalDisplayID)
            case .refused:
                transaction = transaction.markingFailed("补偿失败：\(reason)")
            case .notWritten:
                continue
            }
            state.transactions[item.identity] = transaction
            effects.append(.updateJournal(JournalUpdateRequest(operationID: intent.operationContext.operationID,
                                                               identity: item.identity,
                                                               mutation: .upsert(transaction))))
        }
        return effects
    }

    private static func nextStep(after step: WorkbenchSwitchStep) -> WorkbenchSwitchStep {
        let all = WorkbenchSwitchStep.allCases
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return .commit }
        return all[index + 1]
    }

    // MARK: - 轨道交互

    private static func handleRailDrag(_ state: inout SessionState,
                                       from: RailSlotID,
                                       to: RailSlotID) -> [SessionEffect] {
        guard state.mode == .workbench, !state.workbench.mainSwitch.isBusy,
              state.workbench.modeTransition == .idle else { return [] }
        var placement = state.workbench.placement
        guard placement.swapSlots(from, to) else { return [] }
        state.workbench.placement = placement
        return layoutEffects(state)
    }

    private static func handleRailScroll(_ state: inout SessionState,
                                         rail: RailKind,
                                         offset: CGFloat) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.snapshot != nil else { return [] }
        let before = state.workbench.scrollOffset(rail: rail)
        // 偏移的唯一写入点：投影与"上次上下文"一次改完，两份数值不可能互相覆盖（方案 §12）。
        state.workbench.scroll(rail: rail, offset: offset)
        guard state.workbench.scrollOffset(rail: rail) != before else { return [] }
        return layoutEffects(state)
    }

    private static func handleSideChanged(_ state: inout SessionState, side: RailSide) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy else { return [] }
        if let blocked = recoveryBlock(&state) { return blocked }
        guard state.workbench.side != side, let snapshot = state.workbench.snapshot,
              let display = state.displays.first(where: { $0.id == snapshot.displayID }) else { return [] }
        state.workbench.side = side
        guard let layout = workbenchLayout(for: display, state: state) else { return [] }
        let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
        return settleMainFrame(&state, snapshot: updated, layoutAlreadyApplied: false)
    }

    /// 拖动中的实时预览：只改本机投影（方案 §11.2）。节流后的写入与松手后的最终读回
    /// 都走 handleRailSizeChanged——只有那条路径会 settleMain 并留下事务记录。
    private static func handleRailSizePreview(_ state: inout SessionState,
                                              topHeight: CGFloat?,
                                              sideWidth: CGFloat?) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy else { return [] }
        // 预览取代尚未落盘的上一次调整：拖动继续，写入以最后一次松手为准（方案 §15）。
        if state.workbench.armed?.context.kind == .settleLayout { state.workbench.armed = nil }
        guard applyRailSize(&state, topHeight: topHeight, sideWidth: sideWidth) != nil else { return [] }
        syncTransitionActivity(&state)
        return layoutEffects(state)
    }

    private static func handleRailSizeChanged(_ state: inout SessionState,
                                              topHeight: CGFloat?,
                                              sideWidth: CGFloat?) -> [SessionEffect] {
        // 过渡在途（含"进入中"：那时 mode 还没切到 workbench）：不接受重配，只把偏好攒下来，
        // 等这一刻过渡收敛后一次算清（方案 §13.2：合并可延后的尺寸重配，不阻止取消/释放）。
        if state.workbench.modeTransition.isTransitioning || state.workbench.mainSwitch.isBusy {
            if let topHeight { state.workbench.topHeightPreference = topHeight }
            if let sideWidth { state.workbench.sideWidthPreference = sideWidth }
            state.workbench.railSizeRecomputePending = true
            return []
        }
        guard state.mode == .workbench else { return [] }
        if let blocked = recoveryBlock(&state) { return blocked }
        state.workbench.railSizeRecomputePending = false
        guard applyRailSize(&state, topHeight: topHeight, sideWidth: sideWidth) != nil else { return [] }
        guard let updated = state.workbench.snapshot else { return [] }
        // 松手后的最终读回收口：先落盘再写，拖动中的节流写入由宿主做（方案 §7.1、§11.2）。
        return settleMainFrame(&state, snapshot: updated, layoutAlreadyApplied: true)
    }

    /// 过渡期间攒下的栏尺寸偏好，在过渡收敛这一刻一次重算投影并把主区带过去（方案 §13.2）。
    /// 没有攒过就什么都不做：普通进入/交换不该多一次布局写入。
    @discardableResult
    private static func applyDeferredRailSize(_ state: inout SessionState) -> [SessionEffect] {
        guard state.workbench.railSizeRecomputePending else { return [] }
        state.workbench.railSizeRecomputePending = false
        guard state.workbench.modeTransition == .idle, !state.workbench.mainSwitch.isBusy,
              state.workbench.recoveryRequired == nil else { return [] }
        guard applyRailSize(&state, topHeight: nil, sideWidth: nil) != nil,
              let snapshot = state.workbench.snapshot else { return [] }
        return settleMainFrame(&state, snapshot: snapshot, layoutAlreadyApplied: true)
    }

    /// 两条栏尺寸偏好落进状态并重算冻结投影；算不出新布局（没有 snapshot/屏幕已不在）返回 nil。
    /// nil = 这一维没有新偏好：两条分隔线是独立拖动的，不能顺手清掉另一维（方案 §11.2）。
    /// 注意：这里只改本机投影，真实窗口的写入等 `journalPrepared`（方案 §7.1）。
    private static func applyRailSize(_ state: inout SessionState,
                                      topHeight: CGFloat?,
                                      sideWidth: CGFloat?) -> WorkbenchLayoutSnapshot? {
        if let topHeight { state.workbench.topHeightPreference = topHeight }
        if let sideWidth { state.workbench.sideWidthPreference = sideWidth }
        guard let snapshot = state.workbench.snapshot,
              let display = state.displays.first(where: { $0.id == snapshot.displayID }),
              let layout = workbenchLayout(for: display, state: state) else { return nil }
        let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
        state.workbench.snapshot = updated
        state.workbench.layoutRevision = updated.revision
        return updated
    }

    /// 布局变化后把真实主窗口带到新的 mainRect：不改变 placement，只更新事务计划（方案 §11）。
    /// `layoutAlreadyApplied` 为 false 时（侧栏切换）新投影只暂存，prepare 失败就整体不动（方案 §7.2）。
    private static func settleMainFrame(_ state: inout SessionState,
                                        snapshot: WorkbenchLayoutSnapshot,
                                        layoutAlreadyApplied: Bool) -> [SessionEffect] {
        guard let main = state.workbench.placement.main, let record = state.records[main] else {
            return layoutEffects(state)
        }
        let decision = MainPlacementPolicy.decide(mainRect: snapshot.layout.mainRect,
                                                 currentFrame: actualFrame(state, main) ?? record.frame,
                                                 isMovable: record.isMovable,
                                                 isResizable: record.allowsGeometryControl)
        guard let target = decision.targetFrame else {
            // 放不下就只改投影不写窗口，并说清原因（方案 §9.1）。
            if !layoutAlreadyApplied {
                state.workbench.snapshot = state.workbench.snapshot ?? snapshot
            }
            return layoutEffects(state) + [.presentHint(.workbenchMainFrameFailed("主窗口尺寸无法贴合新布局，未做调整"))]
        }
        let token = state.nextTransitionToken()
        let context = state.nextOperationContext(kind: .settleLayout, token: token)
        // 布局调整是"最新一次松手优先"：上一次还没落盘的调整意图被这一次整体取代（方案 §15）。
        if state.workbench.armed?.context.kind == .settleLayout { state.workbench.armed = nil }
        // 别的操作还在落盘：这一次只改投影，不并发第二条写入通道（方案 §10.4）。
        guard state.workbench.armed == nil else { return layoutEffects(state) }
        let beforeFrame = actualFrame(state, main) ?? record.frame
        let before = WorkbenchOperationSnapshot(context: context,
                                                writtenOrder: [main],
                                                before: [main: OperationGeometrySnapshot(identity: main,
                                                                                         beforeFrame: beforeFrame,
                                                                                         beforeDisplayID: record.displayID)])
        guard let transaction = SessionReducer.preparedTransaction(state, target: main, planned: target,
                                                                  displayID: snapshot.displayID) else {
            return layoutEffects(state)
        }
        var staged = StagedWorkbench()
        if !layoutAlreadyApplied {
            staged.snapshot = snapshot
            staged.layoutRevision = snapshot.revision
        }
        staged.mainFrameWrite = WorkbenchFrameWrite(token: token, identity: main)
        staged.phase = state.phase
        staged.keyboardFocus = state.keyboardFocus
        return arm(&state,
                   context: context,
                   transactions: [main: transaction.markingOperationBefore(frame: beforeFrame,
                                                                           displayID: record.displayID,
                                                                           operationID: context.operationID)],
                   before: before,
                   effects: layoutEffects(state) + [
                       .settleMainFrame(main, targetFrame: target, context: context,
                                        animationMS: snapshot.layout.style.settleAnimationMS(reduceMotion: state.policy.reduceMotion)),
                   ],
                   staged: staged)
    }

    static func applyMainFrameResult(_ state: inout SessionState, _ result: GeometryWriteResult) -> [SessionEffect] {
        state.workbench.mainFrameWrite = nil
        state.workbench.activeContext = nil
        state.workbench.runningOperation = nil
        syncTransitionActivity(&state)
        guard var transaction = state.transactions[result.identity] else { return [] }
        var effects: [SessionEffect] = []
        switch result.outcome {
        case let .exact(readBack):
            transaction = transaction.markingVerified(readBack: readBack, displayID: result.displayID)
        case let .constrained(readBack):
            transaction = transaction.markingWritten(readBack: readBack, displayID: result.displayID,
                                                     note: result.outcome.message)
        case let .cancelled(wroteSize, wrotePosition, readBack):
            // 许可撤销时的部分写入同样是"改过"：保留恢复义务（方案 §5.2）。
            transaction = (wroteSize || wrotePosition)
                ? transaction.markingWritten(readBack: readBack, displayID: result.displayID, note: result.outcome.message)
                : transaction.markingWriteFailed(result.outcome.message)
        case .rejected, .unreadable:
            transaction = transaction.markingWriteFailed(result.outcome.message)
            effects.append(.presentHint(.workbenchMainFrameFailed(result.outcome.message)))
        case .targetGone:
            state.transactions.removeValue(forKey: result.identity)
            return [.updateJournal(JournalUpdateRequest(operationID: result.operationID,
                                                        identity: result.identity,
                                                        mutation: .remove(result.identity)))]
        }
        state.transactions[result.identity] = transaction
        effects.insert(.updateJournal(JournalUpdateRequest(operationID: result.operationID,
                                                           identity: result.identity,
                                                           mutation: .upsert(transaction))), at: 0)
        return effects
    }

    /// 交换中那次有界位置修正的读回：合格就继续，不合格就补偿，不提交 placement（方案 §9.2）。
    private static func applySwitchCorrection(_ state: inout SessionState,
                                              _ result: GeometryWriteResult) -> [SessionEffect] {
        state.workbench.switchCorrection = nil
        guard var transaction = state.transactions[result.identity] else { return [] }
        var effects: [SessionEffect] = []
        switch result.outcome {
        case let .exact(readBack):
            transaction = transaction.markingVerified(readBack: readBack, displayID: result.displayID)
            if !isMainAreaTrustworthy(state, readBack: readBack) {
                effects.append(.presentHint(.workbenchMainFrameFailed("位置修正后仍越出主区")))
                if let intent = state.workbench.mainSwitch.intent {
                    state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "位置修正后仍越出主区")
                }
            }
        case let .constrained(readBack):
            transaction = transaction.markingWritten(readBack: readBack, displayID: result.displayID,
                                                     note: result.outcome.message)
            if !isMainAreaTrustworthy(state, readBack: readBack) {
                effects.append(.presentHint(.workbenchMainFrameFailed("位置修正后仍越出主区")))
                if let intent = state.workbench.mainSwitch.intent {
                    state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "位置修正后仍越出主区")
                }
            }
        case let .cancelled(wroteSize, wrotePosition, readBack):
            transaction = (wroteSize || wrotePosition)
                ? transaction.markingWritten(readBack: readBack, displayID: result.displayID, note: result.outcome.message)
                : transaction.markingWriteFailed(result.outcome.message)
            if let intent = state.workbench.mainSwitch.intent {
                state.workbench.mainSwitch = .rollingBack(intent: intent, reason: result.outcome.message)
            }
        case .rejected, .unreadable:
            transaction = transaction.markingWriteFailed(result.outcome.message)
            if let intent = state.workbench.mainSwitch.intent {
                state.workbench.mainSwitch = .rollingBack(intent: intent, reason: result.outcome.message)
            }
            effects.append(.presentHint(.workbenchMainFrameFailed(result.outcome.message)))
        case .targetGone:
            state.transactions.removeValue(forKey: result.identity)
            return [.updateJournal(JournalUpdateRequest(operationID: result.operationID,
                                                        identity: result.identity,
                                                        mutation: .remove(result.identity)))]
        }
        state.transactions[result.identity] = transaction
        state.workbench.runningOperation?.markWritten(result.identity, readBack: result.outcome.readBackFrame)
        effects.insert(.updateJournal(JournalUpdateRequest(operationID: result.operationID,
                                                           identity: result.identity,
                                                           mutation: .upsert(transaction))), at: 0)
        syncTransitionActivity(&state)
        return effects
    }

    /// 不可容纳时把核心层算出的原因原样说给用户，不在两处各编一句话（方案 §9.1）。
    private static func unavailableReason(_ decision: MainPlacementDecision) -> String {
        if case let .unavailable(reason) = decision { return reason }
        return "窗口无法放进主区"
    }

    /// 缓存 frame 的"放不下"只是乐观预检，不能据此提前拒绝（方案 §6.2、§9.1）。
    /// 窗口可移动且主区本身有效时，宿主会用写前实读重新决策——缓存尺寸过大不等于真实尺寸过大；
    /// 不可移动或主区无效时缓存结论就是硬事实，宿主也动不了它，没必要起步。
    private static func canDeferPlacement(record: WindowRecord, mainRect: CGRect) -> Bool {
        guard record.isMovable else { return false }
        return mainRect.width > MainPlacementPolicy.containmentTolerance
            && mainRect.height > MainPlacementPolicy.containmentTolerance
    }

    /// 补偿判定的操作前位置：宿主写前实读是权威事实，缺它时才退回计划期推测值（方案 §6.2、§6.4）。
    /// 外部把窗口移动过之后，计划期算出的落点已经不成立，拿它判补偿成败会误报失败。
    private static func compensationTarget(for identity: WindowIdentity,
                                           intent: WorkbenchSwitchIntent,
                                           compensation: WorkbenchCompensationResult) -> CGRect? {
        if let observed = compensation.beforeReads[identity] { return observed }
        return intent.beforeOperation.entry(for: identity)?.compensationTarget
    }

    /// 读回是否仍在主区且不侵入两条栏；没有读回值时不凭猜测否定（方案 §9.2）。
    private static func isMainAreaTrustworthy(_ state: SessionState, readBack: CGRect?) -> Bool {
        guard let readBack, let snapshot = state.workbench.snapshot else { return true }
        return MainPlacementPolicy.verify(readBack: readBack,
                                          mainRect: snapshot.layout.mainRect,
                                          topRailRect: snapshot.layout.topRailRect,
                                          sideRailRect: snapshot.layout.sideRailRect).isAccepted
    }

    /// 目录里或事务里最近一次的真实几何；不能用"应该在哪"代替"实际在哪"（方案 §6.2）。
    private static func actualFrame(_ state: SessionState, _ identity: WindowIdentity) -> CGRect? {
        if let readBack = state.transactions[identity]?.lastProvisionalFrame { return readBack }
        return state.records[identity]?.frame
    }

    /// 固定在顶部：只写 rail 偏好与跨会话记忆，卡片此刻不动（方案 §6.2）。
    private static func toggleRailPin(_ state: inout SessionState,
                                      identity: WindowIdentity) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy,
              state.workbench.placement.occupants.values.contains(identity),
              let record = state.records[identity] else { return [] }
        let key = record.preferenceKey
        state.workbench.placement.setPinned(key, pinned: !state.workbench.placement.pinned.contains(key))
        return layoutEffects(state) + [persistRailMemory(state)]
    }

    /// 用户主动「整理轨道」：这是唯一允许重排已放置窗口的动作（方案 §4.4）。
    /// 它只重排投影与占用，绝不写真实窗口几何，因此不需要日志闸门。
    private static func organizeRail(_ state: inout SessionState) -> [SessionEffect] {
        guard state.mode == .workbench, !state.workbench.mainSwitch.isBusy,
              state.workbench.modeTransition == .idle,
              state.workbench.armed == nil,
              let snapshot = state.workbench.snapshot,
              !state.workbench.placement.occupants.isEmpty else { return [] }
        var placement = state.workbench.placement
        let keys = placement.occupants.values.reduce(into: [WindowIdentity: String]()) { result, identity in
            if let record = state.records[identity] { result[identity] = record.preferenceKey }
        }
        // 资格来自「可以展示」，位置由 placement 决定；整理时按用户意图（总览顺序 + pin）重排（方案 §11）。
        let ordered = organizeOrder(state: state, placement: placement)
        var layout = snapshot.layout
        placement.reorganize(slotOrder: extendedSlotOrder(layout: layout, needed: ordered.count),
                             ordered: ordered,
                             keys: keys)
        state.workbench.placement = placement
        // 整理后可能用到了可见容量之外的 slot：内容轨道必须同步延长，否则那些窗口滚不到。
        layout = layout.extending(sideSlots: maxSideOrdinal(placement) + 1)
        if layout != snapshot.layout {
            let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
            state.workbench.snapshot = updated
            state.workbench.layoutRevision = updated.revision
        }
        return layoutEffects(state) + [persistRailMemory(state)]
    }

    /// 整理顺序（方案 §4.4、§6.2）：固定在顶部的应用先占顶栏，其余按总览稳定顺序；
    /// 不在总览里的成员排在最后，用与应用名/身份同源的确定性键收尾。
    private static func organizeOrder(state: SessionState,
                                      placement: WorkbenchPlacement) -> [WindowIdentity] {
        // 整理按"用户视角的稳定顺序"重排，不带 placement 的位置键：否则整理永远整不出结果（方案 §11）。
        let stable = overviewOrder(state)
        let rankOf = Dictionary(stable.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        func isPinned(_ identity: WindowIdentity) -> Bool {
            guard let record = state.records[identity] else { return false }
            return placement.pinned.contains(record.preferenceKey)
        }
        return placement.occupants.values.sorted { lhs, rhs in
            let lPinned = isPinned(lhs)
            let rPinned = isPinned(rhs)
            if lPinned != rPinned { return lPinned }
            let lRank = rankOf[lhs] ?? Int.max
            let rRank = rankOf[rhs] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            let lName = state.records[lhs]?.applicationName ?? ""
            let rName = state.records[rhs]?.applicationName ?? ""
            if lName != rName { return lName < rName }
            if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
            return lhs.windowID < rhs.windowID
        }
    }

    /// 跨会话轨道记忆：只含应用级键与 pin，不含窗口标题（方案 §16）。
    private static func persistRailMemory(_ state: SessionState) -> SessionEffect {
        .persistWorkbenchRailMemory(orderPreference: state.workbench.placement.orderPreference,
                                    pinnedKeys: state.workbench.placement.pinned)
    }

    private static func handleSearchFocus(_ state: inout SessionState, focused: Bool) -> [SessionEffect] {
        guard state.mode == .workbench else { return [] }
        if focused {
            state.keyboardFocus = .railSearch
            return []
        }
        guard state.keyboardFocus == .railSearch else { return [] }
        state.keyboardFocus = .targetApplication
        return [.setKeyboardFocus(.targetApplication)]
    }

    /// Esc（方案 §4.5）：过渡中 → 安全退出；搜索 → 关搜索还焦点；主应用 → 原样交给应用。
    private static func handleEscape(_ state: inout SessionState) -> [SessionEffect] {
        if state.workbench.armed != nil {
            // 尚未落盘：一次 AX 都没写，直接撤掉意图并安全退出（方案 §7.2）。
            state.workbench.armed = nil
            syncTransitionActivity(&state)
        }
        if state.workbench.modeTransition.isTransitioning || state.workbench.mainSwitch.isBusy {
            state.pendingTarget = nil
            return SessionReducer.exitToHidden(&state)
        }
        switch state.keyboardFocus {
        case .targetApplication:
            return []
        case .railSearch:
            state.searchQuery = ""
            state.keyboardFocus = .targetApplication
            return [.setKeyboardFocus(.targetApplication)]
        case .overview, .none:
            return SessionReducer.exitToHidden(&state)
        }
    }

    // MARK: - 超时（方案 §10.5、§8.3）

    private static func handleTimeout(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        // 备好未落盘的操作超时：一次 AX 都没写，按 prepare 失败落点收口（方案 §7.2）。
        if let armed = state.workbench.armed, armed.context.transitionToken == token {
            return landPreparationFailure(&state, armed: armed, reason: "日志批量落盘超时，未写入任何窗口")
        }
        if state.workbench.modeTransition.token == token {
            let kind = state.workbench.modeTransition
            state.workbench.modeTransition = .idle
            state.workbench.activeContext = nil
            state.workbench.runningOperation = nil
            if case let .enteringWorkbench(_, target) = kind {
                state.workbench.snapshot = nil
                state.phase = .overview
                state.keyboardFocus = .overview
                // 超时后补偿归宿主执行器完成（restoreQuietly）：state 侧同步收口，
                // 否则内存里会留下一条没有日志条目的"待恢复"，退出时误报"尺寸未能恢复"（方案 §6.4）。
                state.transactions.removeValue(forKey: target)
                syncTransitionActivity(&state)
                return [.cancelWorkbenchTransition, .hideWorkbench, .setKeyboardFocus(.overview),
                        .presentHint(.workbenchTransitionFailed("进入工作台超时，已留在总览"))]
            }
            if let main = state.workbench.placement.main, state.records[main] != nil {
                state.phase = .focused(target: main)
                state.keyboardFocus = .targetApplication
                syncTransitionActivity(&state)
                return [.cancelWorkbenchTransition, .setKeyboardFocus(.targetApplication),
                        .presentHint(.workbenchTransitionFailed("返回总览超时，仍在工作台"))]
            }
            state.phase = .overview
            syncTransitionActivity(&state)
            return [.cancelWorkbenchTransition, .presentHint(.workbenchTransitionFailed("返回总览超时"))]
        }
        if let intent = state.workbench.mainSwitch.intent, intent.token == token {
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "交换超时")
            state.workbench.switchCorrection = nil
            // 补偿由宿主串行执行器完成，完成后回报 mainSwitchFailed 与完整补偿事实。
            syncTransitionActivity(&state)
            return []
        }
        if state.workbench.switchCorrection?.token == token {
            state.workbench.switchCorrection = nil
            if let intent = state.workbench.mainSwitch.intent {
                state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "主区位置修正超时")
            }
            syncTransitionActivity(&state)
            return [.presentHint(.workbenchMainFrameFailed("主区位置修正未在期限内读回"))]
        }
        if state.workbench.mainFrameWrite?.token == token {
            state.workbench.mainFrameWrite = nil
            state.workbench.activeContext = nil
            state.workbench.runningOperation = nil
            syncTransitionActivity(&state)
            return [.presentHint(.workbenchMainFrameFailed("主窗口未在期限内完成调整"))]
        }
        return []
    }

    // MARK: - 目录同步与窗口关闭

    /// 关闭/消失：原 slot 留空不前移；主窗口自动替补最多一次（方案 §6.2）。
    /// 由 SessionReducer 的窗口关闭优先级分支调用。
    static func handleWindowClosed(_ state: inout SessionState, identity: WindowIdentity) -> [SessionEffect] {
        guard isEngaged(state) else { return [] }
        var effects: [SessionEffect] = []
        // 模式过渡目标关闭：取消过渡，留在原模式（方案 §4.2.7）。
        if state.workbench.modeTransition.target == identity {
            state.workbench.modeTransition = .idle
            state.workbench.activeContext = nil
            state.workbench.runningOperation = nil
            state.workbench.snapshot = nil
            state.workbench.placement.vacate(identity)
            state.phase = .overview
            state.keyboardFocus = .overview
            syncTransitionActivity(&state)
            return [.cancelWorkbenchTransition, .hideWorkbench, .setKeyboardFocus(.overview),
                    .presentHint(.workbenchTransitionFailed("目标窗口已关闭"))]
        }
        // 备料中的操作目标关闭：还没写任何窗口，直接按 prepare 失败落点收口（方案 §7.2）。
        if let armed = state.workbench.armed, armed.transactions[identity] != nil {
            return landPreparationFailure(&state, armed: armed, reason: "落盘期间窗口已关闭：\(identity.journalKey)")
        }
        // 交换中的窗口关闭交给宿主补偿后回报 mainSwitchFailed（方案 §8.3）。
        if case let .switching(intent, _) = state.workbench.mainSwitch,
           intent.to == identity || intent.from == identity {
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "交换中的窗口已关闭")
        }
        var placement = state.workbench.placement
        guard placement.contains(identity) else {
            syncTransitionActivity(&state)
            return effects
        }
        let wasMain = placement.main == identity
        placement.vacate(identity)
        state.workbench.placement = placement
        if wasMain, !state.workbench.mainSwitch.isBusy {
            effects.append(contentsOf: promoteCandidateIfNeeded(&state))
        }
        // 等着的目标已经关闭：直接丢弃，别再发起一次注定失败的交换。
        if state.workbench.pendingRailSelection?.identity == identity {
            state.workbench.pendingRailSelection = nil
        }
        effects.append(contentsOf: layoutEffects(state))
        syncTransitionActivity(&state)
        return effects
    }

    /// 主窗口没了：把替补建模成一个完整操作 `promote(candidate, sourceSlot, from: nil)`（方案 §10）。
    /// 顺序是建事务 → 落盘 → 放置 → 验证 → 激活 → 提交并从原 slot 移除；
    /// 一次关闭事件只尝试一个候选，没有候选就保持主区空态让用户自己选。
    private static func promoteCandidateIfNeeded(_ state: inout SessionState) -> [SessionEffect] {
        guard state.workbench.placement.main == nil else { return [] }
        guard state.workbench.hasAutoPromotionAttempted == false else {
            return emptyMainStateEffects(&state)
        }
        guard let candidate = firstControllableCandidate(placement: state.workbench.placement, state: state),
              let sourceSlot = state.workbench.placement.slot(of: candidate),
              state.workbench.snapshot != nil,
              state.records[candidate] != nil else {
            // 主区空态：轨道还在，键盘仍在 Vistile 一侧以便继续选择（方案 §10）。
            return emptyMainStateEffects(&state)
        }
        state.workbench.hasAutoPromotionAttempted = true
        return startSwitch(&state, to: candidate, slot: sourceSlot, kind: .promoteCandidate)
    }

    private static func emptyMainStateEffects(_ state: inout SessionState) -> [SessionEffect] {
        state.phase = .overview
        state.keyboardFocus = .overview
        syncTransitionActivity(&state)
        return [.setKeyboardFocus(.overview)]
    }

    /// 替补的事实回报：几何合格且激活成立才提交 B 为主，否则 B 留在原 slot、主区继续空（方案 §10）。
    private static func handlePromotionFinished(_ state: inout SessionState,
                                                context: GeometryOperationContext,
                                                identity: WindowIdentity,
                                                geometry: WorkbenchStepOutcome,
                                                activated: Bool) -> [SessionEffect] {
        guard let intent = state.workbench.mainSwitch.intent, intent.isPromotion,
              intent.operationContext == context, intent.to == identity else { return [] }
        let written = state.workbench.runningOperation?.entry(for: identity)?.didWrite ?? false
        guard geometry.allowsContinue, isMainAreaTrustworthy(state, readBack: geometry.readBackFrame), activated else {
            return failPromotion(&state, intent: intent, written: written,
                                 reason: geometry.message + (activated ? "" : "；未确认前台"))
        }
        return commitMainSwitch(&state, token: intent.token)
    }

    private static func failPromotion(_ state: inout SessionState,
                                      intent: WorkbenchSwitchIntent,
                                      written: Bool,
                                      reason: String) -> [SessionEffect] {
        state.workbench.switchCorrection = nil
        if written {
            // 已经写过：不能按"没发生"处理，等宿主按 before 快照逆序补偿后回报（方案 §6.4）。
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: reason)
            syncTransitionActivity(&state)
            return [.drainGeometry(intent.operationContext), .presentHint(.workbenchSwitchFailed(reason))]
        }
        // 未写入：B 保留原 slot，主区继续空，用户可以另选（方案 §10）。
        state.workbench.mainSwitch = .idle
        state.workbench.activeContext = nil
        state.workbench.runningOperation = nil
        return emptyMainStateEffects(&state) + [.presentHint(.workbenchSwitchFailed(reason))] + layoutEffects(state)
    }

    /// 目录回来后的轨道同步：关闭的留空，新窗口填空或尾部追加（方案 §6.2、§4.4.7）。
    static func syncCatalog(_ state: inout SessionState, generation _: UInt64) -> [SessionEffect] {
        guard state.mode == .workbench, let snapshot = state.workbench.snapshot else { return [] }
        var placement = state.workbench.placement
        // 主窗口从目录里消失（没有独立关闭事件时）：同样让位，不指向已不存在的身份。
        if let main = placement.main, state.records[main] == nil {
            placement.setMain(nil)
        }
        for identity in placement.occupants.values where state.records[identity] == nil {
            placement.vacate(identity)
        }
        let layout = fillRailOccupants(&placement, state: state, layout: snapshot.layout)
        guard placement != state.workbench.placement || layout != snapshot.layout else { return [] }
        state.workbench.placement = placement
        if layout != snapshot.layout {
            let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
            state.workbench.snapshot = updated
            state.workbench.layoutRevision = updated.revision
        }
        var effects: [SessionEffect] = []
        if placement.main == nil, !state.workbench.mainSwitch.isBusy, state.workbench.modeTransition == .idle {
            effects.append(contentsOf: promoteCandidateIfNeeded(&state))
        }
        effects.append(contentsOf: layoutEffects(state))
        syncTransitionActivity(&state)
        return effects
    }

    // MARK: - 轨道初始化与占用

    /// 首次生成或恢复既有上下文（方案 §4.2.3、§4.4.6、§6）：
    /// 中文：恢复固定轨道；主窗口也保留卡片，选择只更新主区身份。
    /// English: Restore stable rails, including the main thumbnail; selection changes only main identity.
    /// 返回补位后内容轨道延长过的布局。
    @discardableResult
    private static func initializeRailOccupants(_ placement: inout WorkbenchPlacement,
                                                state: SessionState,
                                                target: WindowIdentity,
                                                layout: WorkbenchLayout) -> WorkbenchLayout {
        if placement.isEmpty {
            var fresh = WorkbenchPlacement()
            // 跨会话记忆（整理顺序、pin）跟着新会话走：重新落位不等于忘掉用户说过的话（方案 §16）。
            fresh.adoptMemory(orderPreference: placement.orderPreference, pinned: placement.pinned)
            fresh.setMain(target)
            let extended = fillRailOccupants(&fresh, state: state, layout: layout)
            placement = fresh
            return extended
        }
        placement.setMain(target)
        return fillRailOccupants(&placement, state: state, layout: layout)
    }

    /// 把还没有轨道位置的展示成员放进空格；没有空格就在侧栏尾部追加逻辑 slot（方案 §6.2、§11）。
    /// 不移动任何已有 occupant，也不抢主、不改滚动偏移。返回内容轨道延长后的布局（溢出卡片靠滚动到达）。
    private static func fillRailOccupants(_ placement: inout WorkbenchPlacement,
                                          state: SessionState,
                                          layout: WorkbenchLayout) -> WorkbenchLayout {
        let missing = stableOrder(state).filter { identity in
            state.records[identity] != nil && mayBeDisplayed(state.records[identity]!)
                && placement.slot(of: identity) == nil
        }
        guard !missing.isEmpty else { return layout }
        var vacant = vacantSlots(placement: placement, layout: layout)
        // 追加序号必须同时避开既有占用与还没消费的空格，否则 place 会失败而静默丢窗口。
        var nextSide = max(layout.sideSlotCount, maxSideOrdinal(placement) + 1)
        var neededSide = layout.sideSlotCount
        for identity in missing {
            if !vacant.isEmpty {
                let slot = vacant.removeFirst()
                if placement.place(identity, at: slot), slot.rail == .side {
                    neededSide = max(neededSide, slot.ordinal + 1)
                }
                continue
            }
            let slot = RailSlotID(displayID: layout.displayID, rail: .side, ordinal: nextSide)
            nextSide += 1
            if placement.place(identity, at: slot) {
                neededSide = max(neededSide, slot.ordinal + 1)
            }
        }
        return layout.extending(sideSlots: neededSide)
    }

    private static func vacantSlots(placement: WorkbenchPlacement, layout: WorkbenchLayout) -> [RailSlotID] {
        layout.slotOrder.filter { placement.occupant(at: $0) == nil }
    }

    private static func maxSideOrdinal(_ placement: WorkbenchPlacement) -> Int {
        placement.occupants.keys
            .filter { $0.rail == .side }
            .map(\.ordinal)
            .max() ?? -1
    }

    /// 整理用的 slot 顺序：可见容量之外按需延长侧栏轨道，绝不在整理时丢窗口（方案 §6.2）。
    private static func extendedSlotOrder(layout: WorkbenchLayout, needed: Int) -> [RailSlotID] {
        var order = layout.slotOrder
        var ordinal = layout.sideSlotCount
        while order.count < needed {
            order.append(RailSlotID(displayID: layout.displayID, rail: .side, ordinal: ordinal))
            ordinal += 1
        }
        return order
    }

    private static func firstControllableCandidate(placement: WorkbenchPlacement,
                                                   state: SessionState) -> WindowIdentity? {
        placement.occupants.sorted { $0.key < $1.key }
            .map(\.value)
            .first { state.records[$0]?.allowsAutoFocus == true }
    }

    /// 「可以展示」与「可以自动聚焦」是两件事（方案 §11）：
    /// 不可聚焦、不可控的窗口照样进 L 型栏，限制由 `record.restriction` 在卡片上标注。
    /// 冻结网格只是位置来源之一，绝不能当资格过滤器用。
    static func mayBeDisplayed(_ record: WindowRecord) -> Bool {
        record.frame.width > 0 && record.frame.height > 0
    }

    /// 稳定顺序（方案 §11）：已有 placement 位置 → 已有总览 slot → 首次发现序号 → 稳定身份。
    /// 应用名与标题更新都不能改变它，已占位的窗口因此不会因为一次目录回调而移动。
    static func stableOrder(_ state: SessionState) -> [WindowIdentity] {
        let displayed = state.records.values.filter { mayBeDisplayed($0) }.map(\.identity)
        let placed = placedRanks(state)
        return displayed.sorted { lhs, rhs in
            if lhs == rhs { return false }
            let lp = placed[lhs], rp = placed[rhs]
            if let lp, let rp {
                if lp != rp { return lp < rp }
                return false
            } else if lp != nil {
                return true
            } else if rp != nil {
                return false
            }
            if let l = overviewSlotIndex(state, lhs), let r = overviewSlotIndex(state, rhs) {
                if l != r { return l < r }
            } else if overviewSlotIndex(state, lhs) != nil {
                return true
            } else if overviewSlotIndex(state, rhs) != nil {
                return false
            }
            let ls = state.discoverySequence[lhs] ?? Int.max
            let rs = state.discoverySequence[rhs] ?? Int.max
            if ls != rs { return ls < rs }
            if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
            if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
            return lhs.journalKey < rhs.journalKey
        }
    }

    /// 已有 placement 的位置键：主区最前，轨道成员按 slot 自身顺序。它们只是"不许动"的依据。
    private static func placedRanks(_ state: SessionState) -> [WindowIdentity: Int] {
        var ranks: [WindowIdentity: Int] = [:]
        if let main = state.workbench.placement.main { ranks[main] = 0 }
        for (offset, pair) in state.workbench.placement.occupants.sorted(by: { $0.key < $1.key }).enumerated() {
            if ranks[pair.value] == nil { ranks[pair.value] = offset + 1 }
        }
        return ranks
    }

    private static func overviewSlotIndex(_ state: SessionState, _ identity: WindowIdentity) -> Int? {
        state.gridCell(for: identity)?.cell.slot?.index
    }

    /// 总览视角的稳定顺序（不含 placement 位置键）：主动整理时按用户意图重排就用它（方案 §4.4）。
    static func overviewOrder(_ state: SessionState) -> [WindowIdentity] {
        let displayed = state.records.values.filter { mayBeDisplayed($0) }.map(\.identity)
        return displayed.sorted { lhs, rhs in
            if let l = overviewSlotIndex(state, lhs), let r = overviewSlotIndex(state, rhs), l != r { return l < r }
            if overviewSlotIndex(state, lhs) != nil, overviewSlotIndex(state, rhs) == nil { return true }
            if overviewSlotIndex(state, lhs) == nil, overviewSlotIndex(state, rhs) != nil { return false }
            let ls = state.discoverySequence[lhs] ?? Int.max
            let rs = state.discoverySequence[rhs] ?? Int.max
            if ls != rs { return ls < rs }
            if lhs.processID != rhs.processID { return lhs.processID < rhs.processID }
            if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
            return lhs.journalKey < rhs.journalKey
        }
    }

    // MARK: - 呈现与几何辅助

    /// 当前状态的展示事实（无 snapshot 时为空）。
    static func presentation(_ state: SessionState) -> WorkbenchPresentation? {
        guard let snapshot = state.workbench.snapshot else { return nil }
        return WorkbenchPresenter.make(state: state, snapshot: snapshot, placement: state.workbench.placement)
    }

    /// 只有 snapshot 有效时才发出的布局重投影 effect。
    private static func layoutEffects(_ state: SessionState) -> [SessionEffect] {
        presentation(state).map { [.updateWorkbenchLayout($0)] } ?? []
    }

    private static func workbenchDisplay(_ state: SessionState,
                                         identity: WindowIdentity,
                                         record: WindowRecord) -> DisplayInfo? {
        // 用户固定了工作台屏幕时先用它；没设置或该屏已拔掉，才跟随点击的卡片（方案 §13）。
        if let preferred = state.workbench.preferredDisplayID,
           let display = state.displays.first(where: { $0.id == preferred }) {
            return display
        }
        if let displayID = state.gridCell(for: identity)?.displayID,
           let display = state.displays.first(where: { $0.id == displayID }) {
            return display
        }
        return SessionReducer.targetDisplay(for: record, state: state)
    }

    private static func workbenchLayout(for display: DisplayInfo, state: SessionState) -> WorkbenchLayout? {
        guard display.visibleFrame.width > 1, display.visibleFrame.height > 1 else { return nil }
        let style = WorkbenchStyle()
        var layout = WorkbenchLayoutEngine.layout(displayID: display.id,
                                                  visibleFrame: display.visibleFrame,
                                                  side: state.workbench.side,
                                                  style: style,
                                                  topHeightOverride: state.workbench.topHeightPreference,
                                                  sideWidthOverride: state.workbench.sideWidthPreference)
        if layout.isMainAreaConstrained {
            // 小屏自动紧凑，不产生无法辨识的卡片（方案 §5.5）。
            layout = WorkbenchLayoutEngine.layout(displayID: display.id,
                                                  visibleFrame: display.visibleFrame,
                                                  side: state.workbench.side,
                                                  style: style,
                                                  compact: true,
                                                  topHeightOverride: state.workbench.topHeightPreference,
                                                  sideWidthOverride: state.workbench.sideWidthPreference)
        }
        // 侧栏切换、分隔线收敛、显示器变化都重算几何：内容轨道按当前占用续长，已用 slot 不因重算失联。
        return layout.extending(sideSlots: maxSideOrdinal(state.workbench.placement) + 1)
    }

    /// 其余卡片在两个位置空间之间的过渡端点（方案 §4.2.5、§10.2）。
    private static func railHandoffs(_ state: SessionState,
                                     snapshot: WorkbenchLayoutSnapshot,
                                     placement: WorkbenchPlacement,
                                     excluding main: WindowIdentity,
                                     entering: Bool) -> [RailHandoff] {
        placement.occupants.sorted { $0.key < $1.key }.compactMap { slot, identity in
            guard identity != main, state.records[identity] != nil else { return nil }
            let cardRect = snapshot.rect(for: slot)
            if entering {
                guard let from = state.cellRect(for: identity) else { return nil }
                return RailHandoff(identity: identity, slot: slot, from: from, to: cardRect)
            }
            guard let from = cardRect else { return nil }
            return RailHandoff(identity: identity, slot: slot, from: from, to: state.cellRect(for: identity))
        }
    }
}
