import Testing
import Foundation
import CoreGraphics
@testable import VistileCore

private func expandToken(_ effects: [SessionEffect]) -> TransitionToken? {
    for effect in effects {
        if case let .expand(_, token, _) = effect { return token }
    }
    return nil
}

private func collapseToken(_ effects: [SessionEffect]) -> TransitionToken? {
    for effect in effects {
        if case let .collapse(_, token, _) = effect { return token }
    }
    return nil
}

private func recoveringToken(_ effects: [SessionEffect]) -> TransitionToken? {
    for effect in effects {
        if case let .restoreAll(token) = effect { return token }
    }
    return nil
}

private func expandTarget(_ effects: [SessionEffect]) -> WindowIdentity? {
    for effect in effects {
        if case let .expand(identity, _, _) = effect { return identity }
    }
    return nil
}

private func containsEffect(_ effects: [SessionEffect], _ predicate: (SessionEffect) -> Bool) -> Bool {
    effects.contains(where: predicate)
}

@Suite("SessionReducer")
struct SessionReducerTests {
    private func overview(count: Int = 4, policy: SessionPolicy = SessionPolicy()) -> (SessionState, [WindowRecord]) {
        var state = Fixtures.state(withCount: count, policy: policy)
        _ = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .preparing)
        let list = Fixtures.records(count)
        _ = Fixtures.dispatch(&state, .catalogUpdated(records: list, generation: state.catalogGeneration, reason: .shortcut))
        #expect(state.phase == .overview)
        return (state, list)
    }

    @Test("快捷键打开：发现 -> 目录更新 -> 总览并启动捕获")
    func openFlow() {
        let (state, list) = overview(count: 4)
        #expect(state.keyboardFocus == .overview)
        #expect(state.slots.slots.count == 4)
        #expect(state.recordsInSlotOrder.count == 4)
        #expect(list.count == 4)
    }

    @Test("旧代际的发现结果被忽略")
    func staleGenerationIgnored() {
        var (state, _) = overview(count: 3)
        let before = state.records
        var stale = Fixtures.records(3)
        var renamed = stale[0]
        renamed.title = "已被替换"
        stale[0] = renamed
        _ = Fixtures.dispatch(&state, .catalogUpdated(records: stale, generation: state.catalogGeneration - 1, reason: .reconcile))
        #expect(state.records == before)
    }

    @Test("单击卡片：恢复记录必须先于写入")
    func journalPrecedesExpand() {
        var (state, list) = overview(count: 3)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        let journalIndex = effects.firstIndex { if case .writeJournal = $0 { return true } ; return false }
        let expandIndex = effects.firstIndex { if case .expand = $0 { return true } ; return false }
        #expect(journalIndex != nil)
        #expect(expandIndex != nil)
        if let journalIndex, let expandIndex {
            #expect(journalIndex < expandIndex)
        }
        #expect(state.transactions[list[1].identity] != nil)
        #expect(state.phase.controlledTarget == list[1].identity)
    }

    @Test("格子不因聚焦与返回而改变")
    func slotsStableAcrossFocus() {
        var (state, list) = overview(count: 5)
        let before = state.slots.slots
        var effects = Fixtures.dispatch(&state, .cardClicked(list[2].identity))
        let token = expandToken(effects)
        effects = Fixtures.dispatch(&state, .expandCompleted(token ?? TransitionToken(generation: 0)))
        effects = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        _ = Fixtures.dispatch(&state, .collapseCompleted(collapseToken(effects) ?? TransitionToken(generation: 0)))
        #expect(state.slots.slots == before)
        #expect(state.phase == .overview)
    }

    @Test("过渡期间的目标请求 latest-wins")
    func latestWinsTarget() {
        var (state, list) = overview(count: 4)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        let firstToken = try? #require(expandToken(effects))
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
        let oldToken = expandToken(effects)!
        let collapseEffects = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        let currentToken = collapseToken(collapseEffects)!
        _ = Fixtures.dispatch(&state, .expandCompleted(oldToken))
        _ = Fixtures.dispatch(&state, .collapseCompleted(oldToken))
        #expect(state.phase == .collapsing(target: list[0].identity, token: currentToken))
        _ = Fixtures.dispatch(&state, .collapseCompleted(currentToken))
        #expect(state.phase == .overview)
    }

    @Test("快速 A→B→背景→退出 最终回到 hidden 且不残留未恢复事务")
    func fastSwitchThenExit() {
        var (state, list) = overview(count: 4)
        let a = list[0].identity
        let b = list[1].identity

        var effects = Fixtures.dispatch(&state, .cardClicked(a))
        let tokenA = expandToken(effects)!
        _ = Fixtures.dispatch(&state, .geometryWritten(a, provisionalFrame: CGRect(x: 40, y: 40, width: 1_200, height: 800), displayID: 1))
        _ = Fixtures.dispatch(&state, .geometryVerified(a, readBack: CGRect(x: 40, y: 40, width: 1_200, height: 800)))
        _ = Fixtures.dispatch(&state, .cardClicked(b))
        effects = Fixtures.dispatch(&state, .expandCompleted(tokenA))
        let tokenB = expandToken(effects)!
        _ = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
        _ = Fixtures.dispatch(&state, .expandCompleted(tokenB))
        _ = Fixtures.dispatch(&state, .geometryRestored(a))
        let restoredA = state.transactions[a]?.state
        let pendingB = state.transactions[b]?.state.requiresRestore
        effects = Fixtures.dispatch(&state, .globalShortcut)
        if let collapse = collapseToken(effects) {
            _ = Fixtures.dispatch(&state, .collapseCompleted(collapse))
        }
        let exitEffects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .hidden)
        #expect(containsEffect(exitEffects) { if case .stopAllCapture = $0 { return true }; return false })
        #expect(containsEffect(exitEffects) { if case .clearJournal = $0 { return true }; return false })
        // 写过的窗口必须已经被恢复；未写入过 AX 的窗口不应被当成待恢复事务。
        #expect(restoredA == .restored)
        #expect(pendingB == false || pendingB == nil)
        #expect(state.transactions.isEmpty)
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
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
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
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
        let switchEffects = Fixtures.dispatch(&state, .cardClicked(list[2].identity))
        #expect(state.phase == .switching(from: list[0].identity, to: list[2].identity, token: state.phase.token!))
        #expect(expandTarget(switchEffects) == list[2].identity)
    }

    @Test("聚焦真实应用时 Esc 不截获")
    func appEscNotIntercepted() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
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
        let token = collapseToken(collapseEffects) ?? expandToken(effects)!
        _ = Fixtures.dispatch(&state, .collapseCompleted(token))
        #expect(state.phase == .overview)
        #expect(state.keyboardFocus == .overview)
        _ = Fixtures.dispatch(&state, .escapePressed)
        #expect(state.phase == .hidden)
    }

    @Test("内部背景点击造成的失焦不触发退出")
    func internalInteractionDoesNotExit() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
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
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
        _ = Fixtures.dispatch(&state, .focusLost(origin: .otherApplication(bundleID: "com.test.app")))
        #expect(state.phase == .focused(target: list[0].identity))
    }

    @Test("Cmd-Tab 外部获得焦点时恢复并退出")
    func externalFocusLossRestoresAndExits() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
        _ = Fixtures.dispatch(&state, .geometryWritten(list[0].identity, provisionalFrame: CGRect(x: 10, y: 10, width: 1_000, height: 700), displayID: 1))
        let exitEffects = Fixtures.dispatch(&state, .focusLost(origin: .commandTab))
        #expect(state.phase == .recovering(token: state.phase.token!))
        #expect(containsEffect(exitEffects) { if case .restoreAll = $0 { return true }; return false })
        let token = recoveringToken(exitEffects)!
        let done = Fixtures.dispatch(&state, .restoreCompleted(token))
        #expect(state.phase == .hidden)
        #expect(containsEffect(done) { if case .hideOverview = $0 { return true }; return false })
    }

    @Test("权限丢失立即挂起、停流并恢复")
    func permissionLossSuspends() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
        _ = Fixtures.dispatch(&state, .geometryWritten(list[0].identity, provisionalFrame: CGRect(x: 10, y: 10, width: 1_000, height: 700), displayID: 1))
        let suspendEffects = Fixtures.dispatch(&state, .permissionLost(.screenRecording))
        #expect(state.phase == .suspended(reason: .permissionLost))
        #expect(containsEffect(suspendEffects) { if case .stopAllCapture = $0 { return true }; return false })
        #expect(containsEffect(suspendEffects) { if case .restoreAll = $0 { return true }; return false })
    }

    @Test("目标销毁后不再尝试恢复该窗口")
    func destroyedTargetSkipsRestore() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
        _ = Fixtures.dispatch(&state, .geometryWritten(list[0].identity, provisionalFrame: CGRect(x: 10, y: 10, width: 1_000, height: 700), displayID: 1))
        let closeEffects = Fixtures.dispatch(&state, .windowClosed(list[0].identity))
        #expect(state.phase == .overview)
        #expect(state.transactions.isEmpty)
        #expect(containsEffect(closeEffects) { if case .dropJournal = $0 { return true }; return false })
    }

    @Test("Space 改变与锁屏都恢复并隐藏")
    func spaceAndLockBehave() {
        for event in [SessionEvent.spaceChanged, .screenLocked] {
            var (state, list) = overview(count: 2)
            let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
            _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
            _ = Fixtures.dispatch(&state, .geometryWritten(list[0].identity, provisionalFrame: CGRect(x: 10, y: 10, width: 1_000, height: 700), displayID: 1))
            let out = Fixtures.dispatch(&state, event)
            #expect(!state.phase.isVisible)
            #expect(containsEffect(out) { if case .stopAllCapture = $0 { return true }; return false })
            #expect(containsEffect(out) { if case .restoreAll = $0 { return true }; return false })
        }
    }

    @Test("点击背景期间的其他应用切换不触发退出")
    func backgroundClickAbsorbsExternalActivation() {
        var (state, list) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .cardClicked(list[0].identity))
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
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
        _ = Fixtures.dispatch(&state, .expandCompleted(expandToken(effects)!))
        effects = Fixtures.dispatch(&state, .cardClicked(list[1].identity))
        let switchToken = expandToken(effects)!
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
        _ = Fixtures.dispatch(&state, .catalogUpdated(records: Fixtures.records(2), generation: state.catalogGeneration, reason: .reconcile))
        #expect(containsEffect(Fixtures.dispatch(&state, .reconcileTick)) { if case .discover = $0 { return true }; return false })
    }

    @Test("hidden 状态取消低频轮询")
    func exitCancelsReconcile() {
        var (state, _) = overview(count: 2)
        let effects = Fixtures.dispatch(&state, .globalShortcut)
        #expect(state.phase == .hidden)
        #expect(containsEffect(effects) { if case .cancelReconcile = $0 { return true }; return false })
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
