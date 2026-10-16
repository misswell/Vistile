import Testing
import Foundation
import CoreGraphics
@testable import VistileCore

private func collapseToken(_ effects: [SessionEffect]) -> TransitionToken? {
    for effect in effects {
        if case let .collapse(_, token, _) = effect { return token }
    }
    return nil
}

private func recoveringToken(_ effects: [SessionEffect]) -> TransitionToken? {
    for effect in effects {
        if case let .restoreAll(token, _) = effect { return token }
    }
    return nil
}

private func restoreAllIdentities(_ effects: [SessionEffect]) -> [WindowIdentity] {
    for effect in effects {
        if case let .restoreAll(_, identities) = effect { return identities }
    }
    return []
}

private func clearedSettled(_ effects: [SessionEffect]) -> [WindowIdentity]? {
    for effect in effects {
        if case let .clearJournal(_, settled) = effect { return settled }
    }
    return nil
}

private func expandTarget(_ effects: [SessionEffect]) -> WindowIdentity? {
    for effect in effects {
        if case let .expand(identity, _, _, _) = effect { return identity }
    }
    return nil
}

private func expandFrame(_ effects: [SessionEffect]) -> CGRect? {
    for effect in effects {
        if case let .expand(_, frame, _, _) = effect { return frame }
    }
    return nil
}

private func journaled(_ effects: [SessionEffect]) -> WindowTransaction? {
    for effect in effects {
        if case let .writeJournal(transaction) = effect { return transaction }
    }
    return nil
}

private func containsEffect(_ effects: [SessionEffect], _ predicate: (SessionEffect) -> Bool) -> Bool {
    effects.contains(where: predicate)
}

private func hasHint(_ effects: [SessionEffect], _ hint: HintKind) -> Bool {
    containsEffect(effects) { if case .presentHint(let value) = $0 { return value == hint }; return false }
}

@Suite("SessionReducer")
struct SessionReducerTests {
    private func overview(count: Int = 4, policy: SessionPolicy = SessionPolicy()) -> (SessionState, [WindowRecord]) {
        var state = Fixtures.state(withCount: count, policy: policy)
        _ = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
        let list = Fixtures.records(count)
        let effects = Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.granted, reopenIfReady: true))
        let request = Fixtures.discoverRequest(effects)
        #expect(request != nil)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request!, records: list))
        #expect(state.phase == .overview)
        return (state, list)
    }

    @Test("快捷键打开：条件满足 -> 发现 -> 目录更新 -> 总览并启动捕获")
    func openFlow() {
        let (state, list) = overview(count: 4)
        #expect(state.keyboardFocus == .overview)
        #expect(state.slots.slots.count == 4)
        #expect(state.recordsInSlotOrder.count == 4)
        #expect(list.count == 4)
        #expect(state.openConditions?.canOpen == true)
    }

    @Test("旧请求的发现结果被忽略")
    func staleRequestIgnored() {
        var (state, _) = overview(count: 3)
        let before = state.records
        var staleRecords = Fixtures.records(3)
        var renamed = staleRecords[0]
        renamed.title = "已被替换"
        staleRecords[0] = renamed
        // 上一个会话的请求：代次更大也不接受。
        let stale = DiscoveryRequest(sessionID: UUID(), requestID: 1, generation: 99, reason: .reconcile)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: stale, records: staleRecords))
        #expect(state.records == before)
        // 请求号对不上同样丢弃。
        let bogus = DiscoveryRequest(sessionID: state.sessionID, requestID: (state.pendingDiscovery?.requestID ?? 0) + 50,
                                     generation: 9_999, reason: .reconcile)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: bogus, records: staleRecords))
        #expect(state.records == before)
    }

    @Test("单击卡片：计划先落盘，展开只写计划里的那个 frame")
    func journalPrecedesExpand() {
        var (state, list) = overview(count: 3)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        let journalIndex = effects.firstIndex { if case .writeJournal = $0 { return true }; return false }
        let expandIndex = effects.firstIndex { if case .expand = $0 { return true }; return false }
        #expect(journalIndex != nil)
        #expect(expandIndex != nil)
        if let journalIndex, let expandIndex {
            #expect(journalIndex < expandIndex)
        }
        // 落盘的事务已经是"修改意图"，且与要写的 frame 完全一致。
        let transaction = journaled(effects)
        #expect(transaction?.state == .mutationPlanned)
        #expect(transaction?.plannedFrame == expandFrame(effects))
        #expect(transaction?.originalFrame == list[1].frame)
        #expect(state.transactions[list[1].identity]?.state == .mutationPlanned)
        #expect(state.phase.controlledTarget == list[1].identity)
    }

    @Test("格子不因聚焦与返回而改变")
    func slotsStableAcrossFocus() {
        var (state, list) = overview(count: 5)
        let before = state.slots.slots
        var effects = Fixtures.dispatch(&state, .cardClicked(list[2].identity))
        let token = Fixtures.expandToken(effects)
        effects = Fixtures.dispatch(&state, .expandCompleted(token ?? TransitionToken(generation: 0)))
        effects = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        _ = Fixtures.dispatch(&state, .collapseCompleted(collapseToken(effects) ?? TransitionToken(generation: 0)))
        #expect(state.slots.slots == before)
        #expect(state.phase == .overview)
    }

    @Test("总览态点背景不引发切换：不能留下令牌吞掉后来的真实外部激活")
    func backgroundClickInOverviewLeavesNoToken() {
        var (state, _) = overview(count: 3)
        _ = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        // 用户真的切去别的应用：总览要退出，而不是被上一次内部点击的令牌挡掉（方案 §12.2）。
        let effects = Fixtures.dispatch(&state, .focusLost(origin: .otherApplication(bundleID: "com.example.other")))
        #expect(!effects.isEmpty, "外部激活被内部令牌抑制：总览会赖在前台不放")
        #expect(state.phase != .overview)
    }

    @Test("背景点击造成的收起仍要认出自己触发的前台变更")
    func backgroundClickCollapseStillSuppressesOwnActivation() {
        var (state, list) = overview(count: 3)
        var effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        effects = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        #expect(state.phase == .focused(target: list[0].identity))
        _ = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        #expect(state.phase.token != nil)
        // 自己点背景把前台给了目标应用之外的进程：这次不是外部离开。
        let own = Fixtures.dispatch(&state, .focusLost(origin: .otherApplication(bundleID: "com.example.other")))
        #expect(own.isEmpty)
        #expect(state.phase.isVisible)
    }

    @Test("受控目标被关闭：先停代理再回总览，晚到的旧令牌回调无效")
    func closedTargetStopsProxy() {
        var (state, list) = overview(count: 3)
        var effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let token = Fixtures.expandToken(effects)!
        // 动画进行到一半时窗口被销毁：画面飞的是这个窗口的矩形，必须当场停下。
        effects = Fixtures.dispatch(&state, .windowClosed(list[0].identity))
        #expect(state.phase == .overview)
        #expect(containsEffect(effects) { if case .cancelTransition = $0 { return true }; return false })
        #expect(state.phase.controlledTarget == nil)
        _ = Fixtures.dispatch(&state, .expandCompleted(token))
        #expect(state.phase == .overview, "旧代理的完成回调不能把已经回总览的状态改回报错的前台")
    }

    @Test("聚焦中的目标被关闭：同样要收掉代理并清除引用")
    func closedFocusedTargetStopsProxy() {
        var (state, list) = overview(count: 3)
        var effects = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        effects = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        #expect(state.phase == .focused(target: list[1].identity))
        effects = Fixtures.dispatch(&state, .windowClosed(list[1].identity))
        #expect(state.phase == .overview)
        #expect(containsEffect(effects) { if case .cancelTransition = $0 { return true }; return false })
    }

    @Test("过渡期间的目标请求 latest-wins")
    func latestWinsTarget() {
        var (state, list) = overview(count: 4)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let firstToken = Fixtures.expandToken(effects)
        #expect(firstToken != nil)
        _ = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        _ = Fixtures.dispatch(&state, .cardClicked(list[2].identity))
        #expect(state.pendingTarget == list[2].identity)
        let followUp = Fixtures.dispatch(&state, .expandCompleted(firstToken!))
        #expect(expandTarget(followUp) == list[2].identity)
        #expect(state.pendingTarget == nil)
        #expect(state.phase == .switching(from: list[0].identity, to: list[2].identity, token: state.phase.token!))
    }

    @Test("旧 token 的晚到回调不能复活旧状态")
    func staleTokenCallbacksIgnored() {
        var (state, list) = overview(count: 3)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let oldToken = Fixtures.expandToken(effects)!
        let collapseEffects = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        let currentToken = collapseToken(collapseEffects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(oldToken))
        _ = Fixtures.dispatch(&state, .collapseCompleted(oldToken))
        #expect(state.phase == .collapsing(target: list[0].identity, token: currentToken))
        _ = Fixtures.dispatch(&state, .collapseCompleted(currentToken))
        #expect(state.phase == .overview)
    }

    @Test("旧 token 的写入结果不改事务状态")
    func staleWriteResultIgnored() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let oldToken = Fixtures.expandToken(effects)!
        let before = state.transactions[list[0].identity]
        _ = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        // 收起已经开始，旧展开的写入结果晚到。
        let late = Fixtures.dispatch(&state, Fixtures.writeResult(list[0].identity, token: oldToken,
                                                          outcome: .exact(readBack: CGRect(x: 1, y: 1, width: 10, height: 10))))
        #expect(late.isEmpty)
        #expect(state.transactions[list[0].identity] == before)
    }

    @Test("快速 A→B→背景→退出 最终回到 hidden 且事务逐条结束")
    func fastSwitchThenExit() {
        var policy = SessionPolicy()
        policy.backgroundClickSwitches = true
        var (state, list) = overview(count: 4, policy: policy)
        let a = list[0].identity
        let b = list[1].identity

        var effects = Fixtures.dispatch(&state, .cardClicked(a))
        let tokenA = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(a, token: tokenA,
                                                  outcome: .exact(readBack: CGRect(x: 40, y: 40, width: 1_200, height: 800))))
        _ = Fixtures.dispatch(&state, .expandCompleted(tokenA))
        #expect(state.phase == .focused(target: a))

        // B 只落下了写入意图，还没收到任何 AX 结果：退出时同样必须进批次。
        effects = Fixtures.dispatch(&state, .cardClicked(b))
        let tokenB = Fixtures.expandToken(effects)!
        #expect(state.transactions[b]?.state == .mutationPlanned)
        _ = Fixtures.dispatch(&state, .expandCompleted(tokenB))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(b, token: tokenB,
                                                          outcome: .constrained(readBack: CGRect(x: 60, y: 60, width: 1_000, height: 700))))

        effects = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        let collapse = collapseToken(effects)!
        _ = Fixtures.dispatch(&state, .collapseCompleted(collapse))
        #expect(state.phase == .overview)

        effects = Fixtures.dispatch(&state, .globalShortcut)
        let batchToken = recoveringToken(effects)!
        #expect(Set(restoreAllIdentities(effects)) == Set([a, b]))
        _ = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken,
                                                              items: [Fixtures.restoreItem(a, .restored),
                                                                      Fixtures.restoreItem(b, .alreadyAtOriginal)]))
        effects = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)
        #expect(state.transactions.isEmpty)
        #expect(Set(clearedSettled(effects) ?? []) == Set([a, b]))
        #expect(containsEffect(effects) { if case .stopAllCapture = $0 { return true }; return false })
    }

    @Test("无法唯一对应时禁止写 AX，只提示")
    func ambiguousTargetIsNotWritten() {
        var state = Fixtures.state(withCount: 1)
        let blocked = Fixtures.record(500, 2_000, confidence: .ambiguous(alternatives: [0, 1]))
        state.records = [blocked.identity: blocked]
        state.slots = SlotRegistry(capacity: 8)
        _ = state.slots.assign(blocked.identity, memoryKey: blocked.memoryKey)
        state.phase = .overview
        let effects = Fixtures.dispatch(&state, .cardClicked(blocked.identity))
        #expect(effects == [.presentHint(.ambiguousWindow)])
        #expect(state.phase == .overview)
        #expect(state.transactions.isEmpty)
        #expect(!blocked.allowsAutoFocus)
    }

    @Test("默认点击背景卡片只回总览")
    func backgroundCardClickReturnsToOverviewByDefault() {
        var (state, list) = overview(count: 3)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        #expect(state.phase == .focused(target: list[0].identity))
        _ = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        #expect(state.phase.isTransitioning)
        #expect(state.policy.backgroundClickSwitches == false)
    }

    @Test("开启直接切换后点击另一卡片切换窗口")
    func backgroundSwitchEnabledSwitches() {
        var policy = SessionPolicy()
        policy.backgroundClickSwitches = true
        var (state, list) = overview(count: 3, policy: policy)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        let switchEffects = Fixtures.dispatch(&state, .cardClicked(list[2].identity))
        #expect(state.phase == .switching(from: list[0].identity, to: list[2].identity, token: state.phase.token!))
        #expect(expandTarget(switchEffects) == list[2].identity)
    }

    @Test("聚焦真实应用时 Esc 不截获")
    func appEscNotIntercepted() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        #expect(state.keyboardFocus == .targetApplication)
        let before = state.phase
        #expect(Fixtures.dispatch(&state, .escapePressed).isEmpty)
        #expect(state.phase == before)
    }

    @Test("返回总览后 Esc 才退出")
    func escExitsFromOverview() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let collapseEffects = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        let token = collapseToken(collapseEffects) ?? Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .collapseCompleted(token))
        #expect(state.phase == .overview)
        #expect(state.keyboardFocus == .overview)
        // 点过卡片就留下了写入意图：Esc 先把窗口收进恢复批次，收到结果才落 hidden。
        let exitEffects = Fixtures.dispatch(&state, .escapePressed)
        let batchToken = recoveringToken(exitEffects)!
        #expect(state.phase == .recovering(destination: .hidden, token: batchToken))
        #expect(restoreAllIdentities(exitEffects) == [list[0].identity])
        _ = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken,
                                                              items: [Fixtures.restoreItem(list[0].identity, .alreadyAtOriginal)]))
        _ = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)
        #expect(state.transactions.isEmpty)
    }

    @Test("没点过卡片时 Esc 直接关闭，不等永远不会来的恢复结果")
    func escFromCleanOverviewClosesImmediately() {
        var (state, _) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .escapePressed)
        #expect(state.phase == .hidden)
        #expect(!containsEffect(effects) { if case .restoreAll = $0 { return true }; return false })
        #expect(containsEffect(effects) { if case .clearJournal = $0 { return true }; return false })
    }

    @Test("内部背景点击造成的失焦不触发退出")
    func internalInteractionDoesNotExit() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        let interaction = InteractionToken()
        let collapseEffects = Fixtures.dispatch(&state, .backgroundClicked(interaction: interaction))
        let token = collapseToken(collapseEffects)
        #expect(token != nil)
        _ = Fixtures.dispatch(&state, .focusLost(origin: .internalInteraction(interaction)))
        #expect(state.phase == .collapsing(target: list[0].identity, token: token!))
    }

    @Test("主动唤起目标应用不算外部离开")
    func activatingOwnTargetDoesNotExit() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        _ = Fixtures.dispatch(&state, .focusLost(origin: .otherApplication(bundleID: "com.test.app")))
        #expect(state.phase == .focused(target: list[0].identity))
    }

    @Test("Cmd-Tab 外部获得焦点时恢复并退出")
    func externalFocusLossRestoresAndExits() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let token = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(token))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(list[0].identity, token: token,
                                                   outcome: .exact(readBack: CGRect(x: 10, y: 10, width: 1_000, height: 700))))
        let exitEffects = Fixtures.dispatch(&state, .focusLost(origin: .commandTab))
        #expect(state.phase == .recovering(destination: .hidden, token: state.phase.token!))
        #expect(containsEffect(exitEffects) { if case .restoreAll = $0 { return true }; return false })
        let batchToken = recoveringToken(exitEffects)!
        _ = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken,
                                                              items: [Fixtures.restoreItem(list[0].identity, .restored)]))
        let done = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)
        #expect(containsEffect(done) { if case .hideOverview = $0 { return true }; return false })
        #expect(state.transactions.isEmpty)
    }

    @Test("目标销毁后不再尝试恢复该窗口")
    func destroyedTargetSkipsRestore() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let token = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(token))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(list[0].identity, token: token,
                                                   outcome: .exact(readBack: CGRect(x: 10, y: 10, width: 1_000, height: 700))))
        let closeEffects = Fixtures.dispatch(&state, .windowClosed(list[0].identity))
        #expect(state.phase == .overview)
        #expect(state.transactions.isEmpty)
        #expect(containsEffect(closeEffects) { if case .dropJournal = $0 { return true }; return false })
    }

    @Test("点击背景期间的其他应用切换不触发退出")
    func backgroundClickAbsorbsExternalActivation() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        _ = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        let token = state.phase.token
        #expect(state.phase.isTransitioning)
        _ = Fixtures.dispatch(&state, .focusLost(origin: .otherApplication(bundleID: "com.someother.app")))
        #expect(state.phase.token == token)
        #expect(state.phase.isTransitioning)
    }

    @Test("切换窗口完成后进入 focused")
    func switchCompletesIntoFocused() {
        var policy = SessionPolicy()
        policy.backgroundClickSwitches = true
        var (state, list) = overview(count: 3, policy: policy)
        var effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects)!))
        effects = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        let switchToken = Fixtures.expandToken(effects)!
        #expect(state.phase == .switching(from: list[0].identity, to: list[1].identity, token: switchToken))
        _ = Fixtures.dispatch(&state, .expandCompleted(switchToken))
        #expect(state.phase == .focused(target: list[1].identity))
    }

    @Test("reconcile 查询进行中不叠加")
    func reconcileDoesNotStack() {
        var (state, _) = overview(count: 2)
        let first = Fixtures.dispatch(&state, .reconcileTick)
        #expect(containsEffect(first) { if case .discover = $0 { return true }; return false })
        #expect(Fixtures.dispatch(&state, .reconcileTick).isEmpty)
        let request = Fixtures.discoverRequest(first)
        #expect(request != nil)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request!, records: Fixtures.records(2)))
        #expect(containsEffect(Fixtures.dispatch(&state, .reconcileTick)) { if case .discover = $0 { return true }; return false })
    }

    @Test("hidden 状态取消低频轮询")
    func exitCancelsReconcile() {
        var (state, _) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .hidden)
        #expect(containsEffect(effects) { if case .cancelReconcile = $0 { return true }; return false })
    }

    @Test("显示器断开且无待恢复事务时直接重查目录")
    func displaysChangedWithoutRestore() {
        var (state, _) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .displaysChanged)
        #expect(state.phase == .overview)
        #expect(Fixtures.discoverRequest(effects) != nil)
    }

    // MARK: - 方案 §5.3 必测序列

    @Test("Space 改变 → 恢复 → hidden → 再按快捷键能重新进入总览")
    func spaceChangedThenReopen() {
        var (state, list) = overview(count: 3)
        let a = list[0].identity
        var effects = Fixtures.dispatch(&state, .cardClicked(a))
        let tokenA = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(tokenA))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(a, token: tokenA,
                                                          outcome: .exact(readBack: CGRect(x: 30, y: 30, width: 1_100, height: 700))))

        effects = Fixtures.dispatch(&state, .spaceChanged)
        #expect(state.phase == .recovering(destination: .hidden, token: state.phase.token!))
        #expect(restoreAllIdentities(effects) == [a])
        #expect(containsEffect(effects) { if case .stopAllCapture = $0 { return true }; return false })
        let batchToken = recoveringToken(effects)!
        _ = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken, items: [Fixtures.restoreItem(a, .restored)]))
        _ = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)
        #expect(state.transactions.isEmpty)

        // 再一次快捷键必须走完整循环，不能卡在 recovering。
        effects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
        #expect(containsEffect(effects) { if case .evaluateOpenConditions = $0 { return true }; return false })
        effects = Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.granted, reopenIfReady: true))
        let request = Fixtures.discoverRequest(effects)
        #expect(request != nil)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request!, records: Fixtures.records(3)))
        #expect(state.phase == .overview)
        #expect(state.slots.slots.count == 3)
    }

    @Test("无待恢复事务时 Space 改变直接落 hidden，不等恢复结果")
    func spaceChangedWithoutPendingRestoreClosesImmediately() {
        var (state, _) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .spaceChanged)
        #expect(state.phase == .hidden)
        #expect(!containsEffect(effects) { if case .restoreAll = $0 { return true }; return false })
    }

    @Test("锁屏时正在聚焦：恢复后落 hidden，解锁再开")
    func lockWhileFocusedThenReopen() {
        var (state, list) = overview(count: 2)
        let a = list[0].identity
        var effects = Fixtures.dispatch(&state, .cardClicked(a))
        let tokenA = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(tokenA))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(a, token: tokenA,
                                                          outcome: .exact(readBack: CGRect(x: 30, y: 30, width: 1_100, height: 700))))

        effects = Fixtures.dispatch(&state, .screenLocked)
        let batchToken = recoveringToken(effects)!
        #expect(state.phase == .recovering(destination: .hidden, token: batchToken))
        _ = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken, items: [Fixtures.restoreItem(a, .restored)]))
        _ = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)

        effects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
    }

    @Test("录屏权限丢失：destination 带原因，恢复权限不自动抢焦点")
    func permissionLossAndRestore() {
        var (state, list) = overview(count: 2)
        let a = list[0].identity
        var effects = Fixtures.dispatch(&state, .cardClicked(a))
        let tokenA = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(tokenA))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(a, token: tokenA,
                                                          outcome: .exact(readBack: CGRect(x: 30, y: 30, width: 1_100, height: 700))))

        effects = Fixtures.dispatch(&state, .permissionLost(.screenRecording))
        let batchToken = recoveringToken(effects)!
        #expect(state.phase == .recovering(destination: .hiddenAfterPermissionLost(.screenRecording), token: batchToken))
        #expect(hasHint(effects, .permissionMissing(.screenRecording)))
        _ = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken, items: [Fixtures.restoreItem(a, .restored)]))
        effects = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)
        // 退出时必须把真实原因再提示一次，不能一律说成缺录屏权限以外的东西。
        #expect(hasHint(effects, .permissionMissing(.screenRecording)))

        // 权限恢复本身不自动打开总览：只请求重新评估条件。
        effects = Fixtures.dispatch(&state, .permissionRestored(.screenRecording))
        #expect(state.phase == .hidden)
        #expect(!containsEffect(effects) { if case .showOverview = $0 { return true }; return false })
        #expect(containsEffect(effects) {
            if case .evaluateOpenConditions(let reopen) = $0 { return reopen == false }
            return false
        })

        // 用户再次调用快捷键才重新进入。
        _ = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
    }

    @Test("权限不足时打开：回 hidden 并说明缺哪一项，不留在 preparing")
    func openBlockedByMissingPermission() {
        var state = Fixtures.state(withCount: 2)
        var effects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
        effects = Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.blocked, reopenIfReady: true))
        #expect(state.phase == .hidden)
        #expect(hasHint(effects, .permissionMissing(.screenRecording)))
        #expect(!containsEffect(effects) { if case .discover = $0 { return true }; return false })

        // 下一次调用必须能重新评估，不形成永久死路。
        effects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
        #expect(containsEffect(effects) { if case .evaluateOpenConditions = $0 { return true }; return false })
    }

    @Test("目录查询失败：清掉在途标记并按真实原因提示")
    func discoveryFailureIsVisibleAndRetryable() {
        let failure = DiscoveryFailure.contentUnavailable("SCShareableContent 超时")
        var state = Fixtures.state(withCount: 2)
        _ = Fixtures.dispatch(&state, .globalShortcut)
        let effects = Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.granted, reopenIfReady: true))
        let request = Fixtures.discoverRequest(effects)!
        #expect(state.isDiscoveryInFlight)

        let failed = Fixtures.dispatch(&state, .catalogDiscoveryFailed(request: request, failure: failure))
        #expect(state.phase == .hidden)
        #expect(!state.isDiscoveryInFlight)
        #expect(hasHint(failed, failure.hint))

        // 旧请求的晚到结果既不能污染新会话，也不能清掉新的在途请求。
        _ = Fixtures.dispatch(&state, .globalShortcut)
        let second = Fixtures.discoverRequest(Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.granted,
                                                                                              reopenIfReady: true)))!
        #expect(second.requestID != request.requestID)
        _ = Fixtures.dispatch(&state, .catalogDiscoveryFailed(request: request, failure: .axUnavailable))
        #expect(state.isDiscoveryInFlight)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request, records: Fixtures.records(2)))
        #expect(state.phase == .preparing)
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: second, records: Fixtures.records(2)))
        #expect(state.phase == .overview)
    }

    @Test("恢复批次里失败项保留，成功项单独清除")
    func partialRestoreKeepsFailedEntry() {
        var policy = SessionPolicy()
        policy.backgroundClickSwitches = true
        var (state, list) = overview(count: 2, policy: policy)
        let a = list[0].identity
        let b = list[1].identity
        var effects = Fixtures.dispatch(&state, .cardClicked(a))
        var token = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(token))
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(a, token: token,
                                                          outcome: .exact(readBack: CGRect(x: 30, y: 30, width: 1_100, height: 700))))
        effects = Fixtures.dispatch(&state, .cardClicked(b))
        token = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(token))

        effects = Fixtures.dispatch(&state, .quitRequested)
        let batchToken = recoveringToken(effects)!
        effects = Fixtures.dispatch(&state, .geometryRestoreSettled(token: batchToken,
                                                                   items: [Fixtures.restoreItem(a, .restored, name: "A"),
                                                                           Fixtures.restoreItem(b, .rejected("AX 拒绝写入(-25205)"), name: "B")]))
        #expect(hasHint(effects, .restoreFailed("B")))
        #expect(state.transactions[b]?.state == .failed)
        #expect(state.transactions[b]?.restoreAttempts == 1)
        // 失败项要重新落盘，成功项从 journal 移除。
        #expect(containsEffect(effects) { if case .writeJournal = $0 { return true }; return false })

        effects = Fixtures.dispatch(&state, .restoreCompleted(batchToken))
        #expect(state.phase == .hidden)
        #expect(Set(clearedSettled(effects) ?? []) == [a])
        #expect(state.transactions.count == 1)
        #expect(state.transactions[b] != nil)
        #expect(hasHint(effects, .restoreIncomplete(1)))
    }

    @Test("只有写入意图的窗口也进恢复批次")
    func plannedWindowIsIncludedInRestoreBatch() {
        var (state, list) = overview(count: 2)
        let a = list[0].identity
        _ = Fixtures.dispatch(&state, .cardClicked(a))
        #expect(state.transactions[a]?.state == .mutationPlanned)
        let effects = Fixtures.dispatch(&state, .quitRequested)
        #expect(restoreAllIdentities(effects) == [a])
        #expect(state.phase.recoveryDestination == .hidden)
    }
}

@Suite("WindowMatcher")
struct WindowMatcherTests {
    @Test("同名同尺寸且位置重合时判定为无法唯一映射")
    func identicalWindowsAreAmbiguous() {
        let frame = CGRect(x: 100, y: 100, width: 900, height: 600)
        let captureWindows = [
            Fixtures.capture(500, 1, frame: frame, title: "未命名"),
            Fixtures.capture(500, 2, frame: frame, title: "未命名")
        ]
        let axWindows = [Fixtures.ax(0, frame: frame, title: "未命名"), Fixtures.ax(1, frame: frame, title: "未命名")]
        let result = WindowMatcher.match(capture: captureWindows, ax: axWindows)
        for (_, confidence) in result {
            #expect(confidence.isAmbiguous)
            #expect(!confidence.allowsAXWrite)
        }
    }

    @Test("同名同尺寸但位置不同可以唯一区分")
    func separatedWindowsAreUnique() {
        let a = CGRect(x: 100, y: 100, width: 900, height: 600)
        let b = CGRect(x: 640, y: 320, width: 900, height: 600)
        let captureWindows = [
            Fixtures.capture(500, 1, frame: a, title: "报告.txt"),
            Fixtures.capture(500, 2, frame: b, title: "报告.txt")
        ]
        let axWindows = [Fixtures.ax(0, frame: b, title: "报告.txt"), Fixtures.ax(1, frame: a, title: "报告.txt")]
        let result = WindowMatcher.match(capture: captureWindows, ax: axWindows)
        #expect(result[WindowIdentity.test(500, 1)]?.resolvedAXIndex == 1)
        #expect(result[WindowIdentity.test(500, 2)]?.resolvedAXIndex == 0)
    }

    @Test("同一 AX 窗口不会被两个捕获窗口占用")
    func assignmentIsOneToOne() {
        let captureWindows = [
            Fixtures.capture(500, 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "A"),
            Fixtures.capture(500, 2, frame: CGRect(x: 20, y: 20, width: 800, height: 600), title: "A")
        ]
        let axWindows = [Fixtures.ax(0, frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "A")]
        let result = WindowMatcher.match(capture: captureWindows, ax: axWindows)
        let resolved = result.values.compactMap { $0.resolvedAXIndex }
        #expect(Set(resolved).count == resolved.count)
    }

    @Test("边框容差内的小尺寸差异不影响匹配")
    func toleranceAllowsFrameDifference() {
        let captureWindows = [Fixtures.capture(500, 1, frame: CGRect(x: 100, y: 100, width: 902, height: 604), title: "终端")]
        let axWindows = [Fixtures.ax(0, frame: CGRect(x: 100, y: 100, width: 900, height: 600), title: "终端")]
        let result = WindowMatcher.match(capture: captureWindows, ax: axWindows)
        #expect(result[WindowIdentity.test(500, 1)]?.resolvedAXIndex == 0)
    }

    @Test("进程重启后旧身份不会被视为同一窗口")
    func processRestartInvalidatesIdentity() {
        let old = WindowIdentity(processID: 500, processStartIdentity: 11, windowID: 9)
        let reused = WindowIdentity(processID: 500, processStartIdentity: 22, windowID: 9)
        #expect(old != reused)
        #expect(!old.sameProcess(reused))
        #expect(Set([old, reused]).count == 2)
    }

    @Test("Sheet 类窗口不参与匹配")
    func sheetLikeIsSkipped() {
        let captureWindows = [Fixtures.capture(500, 1, frame: CGRect(x: 100, y: 100, width: 400, height: 300), title: "打开")]
        let axWindows = [Fixtures.ax(0, frame: CGRect(x: 100, y: 100, width: 400, height: 300), title: "打开", subrole: "AXDialog")]
        let result = WindowMatcher.match(capture: captureWindows, ax: axWindows)
        #expect(result[WindowIdentity.test(500, 1)] == .unmatched)
    }
}

@Suite("支持范围")
struct WindowEligibilityTests {
    @Test("普通无标题窗口不因标题为空被排除")
    func untitledWindowIncluded() {
        let snapshot = Fixtures.capture(500, 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), title: "")
        #expect(WindowEligibilityRules.evaluate(snapshot, ownProcessIDs: [], ownWindowIDs: []).isIncluded)
    }

    @Test("自身进程与总览窗口被排除，阻止无限镜像")
    func ownProcessExcluded() {
        let snapshot = Fixtures.capture(500, 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(WindowEligibilityRules.evaluate(snapshot, ownProcessIDs: [500], ownWindowIDs: []).reason == .ownProcess)
        #expect(WindowEligibilityRules.evaluate(snapshot, ownProcessIDs: [], ownWindowIDs: [1]).reason == .ownOverlay)
    }

    @Test("桌面、Dock、菜单栏与浮层不进入卡片")
    func nonNormalLayersExcluded() {
        let desktop = Fixtures.capture(500, 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: -1)
        let dock = Fixtures.capture(500, 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 20)
        let tooltip = Fixtures.capture(500, 3, frame: CGRect(x: 0, y: 0, width: 800, height: 600), layer: 24)
        #expect(WindowEligibilityRules.evaluate(desktop, ownProcessIDs: [], ownWindowIDs: []).reason == .desktopOrDock)
        #expect(WindowEligibilityRules.evaluate(dock, ownProcessIDs: [], ownWindowIDs: []).reason == .menuBarOrPanel)
        #expect(WindowEligibilityRules.evaluate(tooltip, ownProcessIDs: [], ownWindowIDs: []).reason == .menuBarOrPanel)
    }

    @Test("受保护内容与离屏被排除")
    func protectedAndOffscreen() {
        let protected = Fixtures.capture(500, 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600), sharing: 0)
        let offscreen = Fixtures.capture(500, 2, frame: CGRect(x: 0, y: 0, width: 800, height: 600), onScreen: false)
        #expect(WindowEligibilityRules.evaluate(protected, ownProcessIDs: [], ownWindowIDs: []).reason == .protectedContent)
        #expect(WindowEligibilityRules.evaluate(offscreen, ownProcessIDs: [], ownWindowIDs: []).reason == .offScreen)
    }

    @Test("被总览覆盖不等于离开当前 Space")
    func occludedIsNotOtherSpace() {
        let record = Fixtures.record(500, 1)
        var occluded = record
        occluded.restriction = .spaceUnverified
        #expect(!occluded.allowsAutoFocus)
        #expect(occluded.grade == .previewOnly)
        #expect(record.restriction == nil)
    }
}
