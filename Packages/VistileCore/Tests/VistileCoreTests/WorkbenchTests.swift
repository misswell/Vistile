import XCTest
import CoreGraphics
@testable import VistileCore

/// 工作台核心纯逻辑测试（方案 §18.1 W01–W22）。
/// 全部从公开事件驱动、从 effect 与状态投影取事实，不断言与实现同形的内部细节。
/// W12（设置持久化迁移）随 M2 的 SettingsModel 落地，见任务清单。
final class WorkbenchTests: XCTestCase {

    // MARK: - 骨架

    private func openState(count: Int = 4,
                           policy: SessionPolicy = SessionPolicy()) -> (SessionState, [WindowRecord]) {
        var state = Fixtures.state(withCount: count, policy: policy)
        let list = Fixtures.records(count)
        Fixtures.openToOverview(&state, records: list)
        return (state, list)
    }

    @discardableResult
    private func select(_ state: inout SessionState, fromOverview target: WindowIdentity) -> [SessionEffect] {
        guard let slot = state.gridCell(for: target)?.cell.slot else {
            XCTFail("目标不在冻结网格里")
            return []
        }
        return Fixtures.dispatch(&state, .overviewCardSelected(identity: target,
                                                              slot: slot,
                                                              revision: state.layoutRevision))
    }

    @discardableResult
    private func finishEntering(_ state: inout SessionState,
                                result: WorkbenchStepOutcome = .succeeded(readBack: nil)) -> [SessionEffect] {
        guard let token = state.workbench.modeTransition.token else {
            XCTFail("没有进行中的模式过渡")
            return []
        }
        return Fixtures.dispatch(&state, .workbenchTransitionFinished(token: token,
                                                                      kind: .enteringWorkbench,
                                                                      result: result))
    }

    /// 走到工作台落地态：主窗口 = target。返回进入过程与落地两组 effect。
    @discardableResult
    private func enterWorkbench(_ state: inout SessionState, target: WindowIdentity) -> [SessionEffect] {
        let entering = select(&state, fromOverview: target)
        return entering + finishEntering(&state)
    }

    @discardableResult
    private func selectRail(_ state: inout SessionState, identity: WindowIdentity) -> [SessionEffect] {
        guard let slot = state.workbench.placement.slot(of: identity) else {
            XCTFail("身份不在轨道上")
            return []
        }
        return Fixtures.dispatch(&state, .railCardSelected(slot: slot, identity: identity))
    }

    /// 报告交换的每一步并提交。
    @discardableResult
    private func completeSwitch(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        for step in WorkbenchSwitchStep.allCases {
            effects += Fixtures.dispatch(&state, .mainSwitchStepFinished(
                WorkbenchSwitchStepResult(token: token,
                                          step: step,
                                          outcome: .succeeded(readBack: nil),
                                          identity: nil)))
        }
        effects += Fixtures.dispatch(&state, .mainSwitchCommitted(token: token))
        return effects
    }

    /// 走一次目录回调：注入新窗口等事实必须从发现请求进来。
    private func updateCatalog(_ state: inout SessionState, records: [WindowRecord]) throws {
        let effects = Fixtures.dispatch(&state, .reconcileTick)
        let request = try XCTUnwrap(Fixtures.discoverRequest(effects))
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request, records: records))
    }

    @discardableResult
    private func returnToOverview(_ state: inout SessionState, success: Bool = true) throws -> WorkbenchTransitionPlan {
        let effects = Fixtures.dispatch(&state, .returnToOverviewRequested)
        let plan = try XCTUnwrap(returnPlan(effects))
        _ = Fixtures.dispatch(&state, .workbenchTransitionFinished(token: plan.token,
                                                                   kind: .returningOverview,
                                                                   result: success ? .succeeded(readBack: nil)
                                                                                   : .rejected("测试注入失败")))
        return plan
    }

    // MARK: - effect 取值

    private func enterPlan(_ effects: [SessionEffect]) -> WorkbenchTransitionPlan? {
        for effect in effects {
            if case let .enterWorkbench(plan) = effect { return plan }
        }
        return nil
    }

    private func returnPlan(_ effects: [SessionEffect]) -> WorkbenchTransitionPlan? {
        for effect in effects {
            if case let .returnToOverview(plan) = effect { return plan }
        }
        return nil
    }

    private func switchPlan(_ effects: [SessionEffect]) -> WorkbenchSwitchPlan? {
        for effect in effects {
            if case let .beginMainSwitch(plan) = effect { return plan }
        }
        return nil
    }

    private func presentations(_ effects: [SessionEffect]) -> [WorkbenchPresentation] {
        effects.compactMap {
            if case let .updateWorkbenchLayout(presentation) = $0 { return presentation }
            return nil
        }
    }

    private func hints(_ effects: [SessionEffect]) -> [HintKind] {
        effects.compactMap {
            if case let .presentHint(hint) = $0 { return hint }
            return nil
        }
    }

    private func journalWrites(_ effects: [SessionEffect]) -> [WindowTransaction] {
        effects.compactMap {
            if case let .writeJournal(transaction) = $0 { return transaction }
            return nil
        }
    }

    private func settlePackets(_ effects: [SessionEffect]) -> [(identity: WindowIdentity, target: CGRect, token: TransitionToken)] {
        effects.compactMap {
            if case let .settleMainFrame(identity, targetFrame, token, _) = $0 {
                return (identity, targetFrame, token)
            }
            return nil
        }
    }

    private func hasWorkbenchEnter(_ effects: [SessionEffect]) -> Bool {
        effects.contains { if case .enterWorkbench = $0 { return true } else { return false } }
    }

    private func hasHideWorkbench(_ effects: [SessionEffect]) -> Bool {
        effects.contains { if case .hideWorkbench = $0 { return true } else { return false } }
    }

    private func hasShowOverview(_ effects: [SessionEffect]) -> Bool {
        effects.contains { if case .showOverview = $0 { return true } else { return false } }
    }

    private func hasCancelTransition(_ effects: [SessionEffect]) -> Bool {
        effects.contains { if case .cancelWorkbenchTransition = $0 { return true } else { return false } }
    }

    private func hasTransitionFailedHint(_ effects: [SessionEffect]) -> Bool {
        hints(effects).contains { if case .workbenchTransitionFailed = $0 { return true } else { return false } }
    }

    private func hasDropJournal(_ effects: [SessionEffect], identity: WindowIdentity) -> Bool {
        effects.contains {
            if case let .dropJournal(dropped) = $0 { return dropped == identity }
            return false
        }
    }

    // MARK: - W01 / W02 几何

    func testW01RailGeometryStaysInsideAndNeverOverlaps() {
        let style = WorkbenchStyle()
        let visible = CGRect(x: 0, y: 64, width: 1_512, height: 918)
        for side in [RailSide.left, RailSide.right] {
            let layout = WorkbenchLayoutEngine.layout(displayID: 1, visibleFrame: visible, side: side, style: style)
            XCTAssertFalse(layout.isDegenerate, "\(side.displayName)布局不应退化")

            XCTAssertFalse(layout.mainRect.intersects(layout.topRailRect), "主区不得压顶栏")
            XCTAssertFalse(layout.mainRect.intersects(layout.sideRailRect), "主区不得压侧栏")
            XCTAssertFalse(layout.topRailRect.intersects(layout.sideRailRect), "顶栏与侧栏各占自己的带位")

            for rect in [layout.mainRect, layout.topRailRect, layout.sideRailRect,
                         layout.cornerToolRect, layout.topViewport, layout.sideViewport] {
                XCTAssertGreaterThanOrEqual(rect.minX, visible.minX - 0.001)
                XCTAssertGreaterThanOrEqual(rect.minY, visible.minY - 0.001)
                XCTAssertLessThanOrEqual(rect.maxX, visible.maxX + 0.001)
                XCTAssertLessThanOrEqual(rect.maxY, visible.maxY + 0.001)
            }

            // 角落工具区只属于顶栏；卡片视口不得与它重叠（同一角落不重复分配）。
            XCTAssertTrue(layout.topRailRect.contains(layout.cornerToolRect))
            XCTAssertFalse(layout.topViewport.intersects(layout.cornerToolRect))
            XCTAssertFalse(layout.cornerToolRect.intersects(layout.sideRailRect))

            // 容量取整：末位卡片完整落在视口内，不出现半个卡片。
            if layout.topCapacity > 0 {
                XCTAssertLessThanOrEqual(layout.topContentLength, layout.topViewport.width + 0.001)
            }
            if layout.sideCapacity > 0 {
                XCTAssertLessThanOrEqual(layout.sideContentLength, layout.sideViewport.height + 0.001)
            }

            let inner = visible.insetBy(dx: layout.margin, dy: layout.margin)
            switch side {
            case .left:
                XCTAssertEqual(layout.sideRailRect.minX, inner.minX, accuracy: 0.001, "左栏贴内区左边")
                XCTAssertEqual(layout.cornerToolRect.minX, inner.minX, accuracy: 0.001)
            case .right:
                XCTAssertEqual(layout.sideRailRect.maxX, inner.maxX, accuracy: 0.001, "右栏贴内区右边")
                XCTAssertEqual(layout.cornerToolRect.maxX, inner.maxX, accuracy: 0.001)
            }
        }
    }

    func testW02AreaRatioIsRealAreaAndSmallScreensAreExplicitlyConstrained() {
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let big = WorkbenchLayoutEngine.layout(displayID: 1, visibleFrame: visible, side: .right)
        XCTAssertEqual(big.mainAreaRatio,
                       Double(big.mainRect.width * big.mainRect.height) / Double(visible.width * visible.height),
                       accuracy: 1e-9,
                       "设置里显示的是面积比，不是宽高百分比")
        XCTAssertFalse(big.isMainAreaConstrained, "1512×982 上主区应达到 800×500 基线")

        let small = WorkbenchLayoutEngine.layout(displayID: 1,
                                                 visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 600),
                                                 side: .right)
        XCTAssertTrue(small.isMainAreaConstrained, "低于基线必须明确受限")
        XCTAssertGreaterThan(small.mainRect.width, 0)
        XCTAssertGreaterThan(small.mainRect.height, 0)

        let tiny = WorkbenchLayoutEngine.layout(displayID: 1,
                                                visibleFrame: CGRect(x: 10, y: 20, width: 40, height: 30),
                                                side: .right)
        XCTAssertTrue(tiny.isDegenerate, "连一条栏都放不下时退化为只有主区")
        for rect in [tiny.mainRect, tiny.topRailRect, tiny.sideRailRect, tiny.topViewport, tiny.sideViewport] {
            XCTAssertGreaterThanOrEqual(rect.width, 0)
            XCTAssertGreaterThanOrEqual(rect.height, 0)
        }
    }

    // MARK: - W03 / W04 交换

    func testW03SwapOnlyTouchesMainAndSourceSlot() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        XCTAssertEqual(state.mode, .workbench)
        XCTAssertEqual(state.workbench.placement.main, a)

        let before = state.workbench.placement.occupants
        let snapshotBefore = state.workbench.snapshot
        let bSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))

        let effects = selectRail(&state, identity: b)
        let plan = try XCTUnwrap(switchPlan(effects))
        XCTAssertEqual(plan.intent.from, a)
        XCTAssertEqual(plan.intent.to, b)
        XCTAssertEqual(plan.restingSlot, bSlot)
        XCTAssertEqual(plan.mainTargetFrame, state.workbench.snapshot?.mainRect, "B 的目标就是主区矩形")

        // 事务必须先于 AX 写入，且只有一条非日志 effect。
        XCTAssertEqual(journalWrites(effects).count, 2, "B 的目标与 A 的落点都要先写日志")
        XCTAssertEqual(effects.count, 3)
        if case .beginMainSwitch = effects.last! {} else {
            XCTFail("AX 写入必须排在日志之后")
        }

        completeSwitch(&state, token: plan.intent.token)
        XCTAssertEqual(state.workbench.placement.main, b)
        XCTAssertEqual(state.workbench.placement.occupant(at: bSlot), a, "A 回到 B 原来的 slot")
        let after = state.workbench.placement.occupants
        XCTAssertEqual(after.count, before.count, "占用总数守恒")
        for (slot, identity) in before where identity != b {
            XCTAssertEqual(after[slot], identity, "除 main 与 sourceSlot 外，其他占用一律不动")
        }
        XCTAssertEqual(state.workbench.placement.members.count, 5)
        XCTAssertEqual(state.workbench.snapshot, snapshotBefore, "交换不改几何投影")
        XCTAssertEqual(state.workbench.topScrollOffset, 0)
        XCTAssertEqual(state.workbench.sideScrollOffset, 0)
        XCTAssertTrue(state.workbench.placement.maintainsInvariants)
    }

    func testW04ConsecutiveSwapsConserveWindowsAndKeepScroll() throws {
        var (state, list) = openState(count: 24)
        enterWorkbench(&state, target: list[0].identity)
        let snapshot = try XCTUnwrap(state.workbench.snapshot)
        XCTAssertGreaterThan(snapshot.layout.sideSlotCount, snapshot.layout.sideCapacity,
                             "24 个窗口必须把内容轨道延长到可见容量之外")
        XCTAssertGreaterThan(snapshot.layout.maxSideScroll, 0, "24 个窗口必须让侧栏真正可滚动")

        let scrolled = Fixtures.dispatch(&state, .railScrolled(rail: .side, offset: 120))
        XCTAssertFalse(presentations(scrolled).isEmpty, "滚动要立即重投影")
        XCTAssertEqual(state.workbench.sideScrollOffset, 120)
        let scrolledSnapshot = try XCTUnwrap(state.workbench.snapshot)

        for target in [list[1].identity, list[2].identity] {
            let effects = selectRail(&state, identity: target)
            let plan = try XCTUnwrap(switchPlan(effects))
            completeSwitch(&state, token: plan.intent.token)
            XCTAssertEqual(state.workbench.placement.main, target)
            XCTAssertTrue(state.workbench.placement.maintainsInvariants)
            XCTAssertEqual(state.workbench.placement.members.count, 24, "每次交换都不得丢失或复制窗口")
            XCTAssertEqual(state.workbench.sideScrollOffset, 120, "交换不得重置滚动位置")
            XCTAssertEqual(state.workbench.snapshot, scrolledSnapshot, "交换不改几何投影与滚动")
        }
        XCTAssertEqual(state.workbench.placement.members, Set(list.map(\.identity)))
    }

    // MARK: - W05 / W06 关闭与新增

    func testW05ClosingAMiddleCardOnlyLeavesItsSlotEmpty() throws {
        var (state, list) = openState(count: 8)
        enterWorkbench(&state, target: list[0].identity)
        let before = state.workbench.placement.occupants
        let closing = list[3].identity
        let slot = try XCTUnwrap(state.workbench.placement.slot(of: closing))

        let effects = Fixtures.dispatch(&state, .windowClosed(closing))
        XCTAssertNil(state.workbench.placement.occupant(at: slot), "原格变空")
        for (otherSlot, identity) in before where identity != closing {
            XCTAssertEqual(state.workbench.placement.occupant(at: otherSlot), identity, "后面的卡片不得前移")
        }
        XCTAssertEqual(state.workbench.placement.main, list[0].identity, "关闭卡片不动主窗口")
        XCTAssertEqual(state.workbench.placement.occupants.count, before.count - 1)

        let presentation = try XCTUnwrap(presentations(effects).last)
        XCTAssertTrue(presentation.emptySlots.contains(slot), "空格要在展示事实里保留自己的 slot")
        XCTAssertEqual(presentation.totalCount, 7)
    }

    func testW06NewWindowFillsVacancyThenAppendsWithoutStealingMain() throws {
        // 填空：8 个窗口占满顶栏，侧栏还空着。
        var (state, list) = openState(count: 8)
        enterWorkbench(&state, target: list[0].identity)
        let before = state.workbench.placement.occupants
        let extra = Fixtures.record(990, 9_001,
                                    frame: CGRect(x: 40, y: 40, width: 1_280, height: 800),
                                    title: "新窗口", app: "NewApp")
        try updateCatalog(&state, records: list + [extra])
        XCTAssertNotNil(state.gridCell(for: extra.identity), "新窗口此刻必须已有格子")
        let extraSlot = try XCTUnwrap(state.workbench.placement.slot(of: extra.identity))
        let firstVacant = try XCTUnwrap(state.workbench.snapshot?.layout.slotOrder.first { before[$0] == nil })
        XCTAssertEqual(extraSlot, firstVacant, "有空格必须进第一个空格")
        XCTAssertEqual(state.workbench.placement.main, list[0].identity, "新窗口不得抢主")
        for (slot, identity) in before {
            XCTAssertEqual(state.workbench.placement.occupant(at: slot), identity, "已有占用不得重排")
        }

        // 追加：14 个窗口（1 主 + 13 轨道）占满全部可见 slot，新窗口只能追加到侧栏尾部。
        var (full, fullList) = openState(count: 14)
        enterWorkbench(&full, target: fullList[0].identity)
        let layout = try XCTUnwrap(full.workbench.snapshot?.layout)
        XCTAssertEqual(layout.sideSlotCount, layout.sideCapacity, "未溢出时内容轨道不延长")
        XCTAssertTrue(layout.slotOrder.allSatisfy { full.workbench.placement.occupant(at: $0) != nil },
                      "14 个窗口应占满全部可见 slot")
        let beforeFull = full.workbench.placement.occupants
        let maxSide = beforeFull.keys.filter { $0.rail == .side }.map(\.ordinal).max() ?? -1
        let another = Fixtures.record(991, 9_002,
                                      frame: CGRect(x: 60, y: 60, width: 1_280, height: 800),
                                      title: "再来一个", app: "NewApp")
        try updateCatalog(&full, records: fullList + [another])
        XCTAssertNotNil(full.gridCell(for: another.identity))
        let appended = try XCTUnwrap(full.workbench.placement.slot(of: another.identity))
        XCTAssertEqual(appended.rail, .side, "溢出只能落在侧栏逻辑轨道上")
        XCTAssertEqual(appended.ordinal, maxSide + 1, "没有空格时在侧栏尾部追加")
        XCTAssertEqual(full.workbench.placement.main, fullList[0].identity)
        for (slot, identity) in beforeFull {
            XCTAssertEqual(full.workbench.placement.occupant(at: slot), identity)
        }

        // 溢出卡片必须能靠滚动到达（方案 §6.2、§5.4）。
        let overflowing = try XCTUnwrap(full.workbench.snapshot)
        XCTAssertGreaterThan(overflowing.layout.maxSideScroll, 0, "溢出后侧栏必须可滚动")
        let atTop = try XCTUnwrap(overflowing.rect(for: appended))
        XCTAssertFalse(overflowing.layout.sideViewport.contains(atTop), "置顶时溢出的卡片不完整可见")
        _ = Fixtures.dispatch(&full, .railScrolled(rail: .side, offset: overflowing.layout.maxSideScroll))
        let scrolled = try XCTUnwrap(full.workbench.snapshot)
        let atEnd = try XCTUnwrap(scrolled.rect(for: appended))
        let visible = scrolled.layout.sideViewport.intersection(atEnd)
        XCTAssertGreaterThanOrEqual(visible.height, atEnd.height - 1, "滚到底必须完整看到溢出窗口")
    }

    // MARK: - W07 查询/过滤

    func testW07SearchNeverChangesFrozenPositions() {
        var (state, list) = openState(count: 6)
        enterWorkbench(&state, target: list[0].identity)
        let grids = state.grids
        let placement = state.workbench.placement
        let order = WorkbenchReducer.stableOrder(state)

        _ = Fixtures.dispatch(&state, .searchChanged("窗口 2"))
        XCTAssertEqual(state.grids, grids, "筛选不得改冻结网格")
        XCTAssertEqual(state.workbench.placement, placement, "筛选不得改轨道占用")
        _ = Fixtures.dispatch(&state, .searchChanged(""))
        XCTAssertEqual(state.grids, grids)
        XCTAssertEqual(WorkbenchReducer.stableOrder(state), order, "清空后基础顺序不变")
        XCTAssertEqual(state.workbench.placement, placement)
    }

    // MARK: - W08 模式往返

    func testW08ModeRoundTripKeepsPlacementAndMainIdentity() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        enterWorkbench(&state, target: a)
        XCTAssertEqual(state.mode, .workbench)
        let occupants = state.workbench.placement.occupants

        let back = try returnToOverview(&state)
        XCTAssertEqual(back.animationFrom, state.workbench.snapshot?.mainRect)
        XCTAssertEqual(back.animationTo, state.cellRect(for: a))
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertEqual(state.workbench.placement.occupants, occupants, "返回总览保留 L 型上下文")

        enterWorkbench(&state, target: a)
        XCTAssertEqual(state.mode, .workbench)
        XCTAssertEqual(state.workbench.placement.main, a)
        XCTAssertEqual(state.workbench.placement.occupants, occupants, "重选原主恢复原样")
        XCTAssertEqual(state.workbench.placement.members.count, 5)
    }

    // MARK: - W09 latest-wins

    func testW09LatestSelectionWinsAfterPreviousConverges() throws {
        var (state, list) = openState(count: 6)
        enterWorkbench(&state, target: list[0].identity)

        let first = selectRail(&state, identity: list[1].identity)
        let token1 = try XCTUnwrap(switchPlan(first)?.intent.token)
        XCTAssertTrue(state.workbench.mainSwitch.isBusy)

        _ = selectRail(&state, identity: list[2].identity)
        XCTAssertEqual(state.workbench.pendingRailSelection?.identity, list[2].identity)
        _ = selectRail(&state, identity: list[3].identity)
        XCTAssertEqual(state.workbench.pendingRailSelection?.identity, list[3].identity, "只记最后一个目标")
        XCTAssertTrue(state.workbench.mainSwitch.isBusy, "前一次收敛前不得并发第二条写入通道")

        let committed = completeSwitch(&state, token: token1)
        XCTAssertEqual(state.workbench.placement.main, list[1].identity, "先提交第一次交换")
        let next = try XCTUnwrap(switchPlan(committed), "收敛后必须接着处理真正想点的那个")
        XCTAssertEqual(next.intent.to, list[3].identity)
        XCTAssertNil(state.workbench.pendingRailSelection)

        completeSwitch(&state, token: next.intent.token)
        XCTAssertEqual(state.workbench.placement.main, list[3].identity)
        XCTAssertTrue(state.workbench.placement.maintainsInvariants)
        XCTAssertEqual(state.workbench.placement.members.count, 6)
    }

    // MARK: - W10 退出优先级

    func testW10ExitEventsWinAndStaleCompletionsCannotReviveWorkbench() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        let switchEffects = selectRail(&state, identity: list[1].identity)
        let staleSwitch = try XCTUnwrap(switchPlan(switchEffects)?.intent.token)

        let locked = Fixtures.dispatch(&state, .screenLocked)
        XCTAssertFalse(state.phase.isVisible, "锁屏必须立刻停止会话")
        XCTAssertTrue(hasHideWorkbench(locked))
        if case .recovering = state.phase {} else { XCTFail("有未恢复事务时必须走恢复路径") }

        let recoverToken = try XCTUnwrap(state.phase.token)
        _ = Fixtures.dispatch(&state, .restoreCompleted(recoverToken))
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertTrue(state.workbench.placement.occupants.isEmpty)

        // 旧完成回调一律不得复活工作台。
        _ = Fixtures.dispatch(&state, .mainSwitchCommitted(token: staleSwitch))
        _ = Fixtures.dispatch(&state, .mainSwitchStepFinished(
            WorkbenchSwitchStepResult(token: staleSwitch, step: .commit,
                                      outcome: .succeeded(readBack: nil), identity: nil)))
        let staleFinish = Fixtures.dispatch(&state, .workbenchTransitionFinished(
            token: TransitionToken(generation: 99_999), kind: .enteringWorkbench,
            result: .succeeded(readBack: nil)))
        XCTAssertTrue(staleFinish.isEmpty)
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
    }

    func testW10SpaceChangeAndQuitAlsoTakePriority() throws {
        for event in [SessionEvent.spaceChanged, .quitRequested] {
            var (state, list) = openState(count: 4)
            enterWorkbench(&state, target: list[0].identity)
            let effects = Fixtures.dispatch(&state, event)
            XCTAssertFalse(state.phase.isVisible, "\(event) 必须优先于工作台")
            XCTAssertTrue(hasHideWorkbench(effects))
            XCTAssertEqual(state.workbench.modeTransition, .idle)
            XCTAssertEqual(state.workbench.mainSwitch, .idle)
        }
    }

    // MARK: - W11 多屏

    func testW11TargetDisplayAndSourceDisplayStaySeparate() throws {
        let d1 = DisplayInfo(id: 1,
                             frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                             visibleFrame: CGRect(x: 0, y: 64, width: 1_512, height: 918),
                             backingScale: 2, isPrimary: true)
        let d2 = DisplayInfo(id: 2,
                             frame: CGRect(x: 1_512, y: 0, width: 1_440, height: 900),
                             visibleFrame: CGRect(x: 1_512, y: 40, width: 1_440, height: 860),
                             backingScale: 2, isPrimary: false)
        let list = [
            Fixtures.record(501, 11, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                            title: "P1", app: "A", displayID: 1),
            Fixtures.record(502, 12, frame: CGRect(x: 1_700, y: 120, width: 900, height: 600),
                            title: "S1", app: "B", displayID: 2),
            Fixtures.record(503, 13, frame: CGRect(x: 1_700, y: 340, width: 900, height: 600),
                            title: "S2", app: "C", displayID: 2),
            Fixtures.record(504, 14, frame: CGRect(x: 300, y: 200, width: 900, height: 600),
                            title: "P2", app: "D", displayID: 1)
        ]
        var state = SessionState()
        state.policy = SessionPolicy()
        state.slots.capacity = 48
        for item in list { state.records[item.identity] = item }
        for item in list { state.slots.assign(item.identity, memoryKey: item.memoryKey) }
        state.catalogGeneration = 1
        state.displays = [d1, d2]
        Fixtures.openToOverview(&state, records: list)

        // 点 2 号屏上的窗口：工作台建在 2 号屏，主区几何来自 2 号屏的 visibleFrame。
        let target = list[1].identity
        let entering = select(&state, fromOverview: target)
        let plan = try XCTUnwrap(enterPlan(entering))
        XCTAssertEqual(plan.displayID, d2.id)
        XCTAssertEqual(plan.snapshot.displayID, d2.id)
        XCTAssertEqual(plan.snapshot.layout.visibleFrame, d2.visibleFrame)
        XCTAssertGreaterThanOrEqual(plan.targetFrame.minX, d2.visibleFrame.minX)
        XCTAssertLessThanOrEqual(plan.targetFrame.maxX, d2.visibleFrame.maxX)
        finishEntering(&state)
        XCTAssertEqual(state.workbench.activeDisplayID, d2.id)

        // 跨屏选主：1 号屏的窗口进 2 号屏的主区；A 的落点回到它自己的原始 frame。
        let crossSlot = try XCTUnwrap(state.workbench.placement.slot(of: list[0].identity))
        let switchEffects = Fixtures.dispatch(&state, .railCardSelected(slot: crossSlot, identity: list[0].identity))
        let plan2 = try XCTUnwrap(switchPlan(switchEffects))
        XCTAssertEqual(plan2.displayID, d2.id, "必须显式传活动屏，不能用 B 的原 displayID 推导")
        XCTAssertGreaterThanOrEqual(plan2.mainTargetFrame.minX, d2.visibleFrame.minX)
        XCTAssertLessThanOrEqual(plan2.mainTargetFrame.maxX, d2.visibleFrame.maxX)
        XCTAssertEqual(plan2.restingTargetFrame, list[1].frame, "A 回自己的原始 frame（在 1 号屏）")
        completeSwitch(&state, token: plan2.intent.token)
        XCTAssertEqual(state.workbench.placement.main, list[0].identity)
        XCTAssertEqual(state.records[list[0].identity]?.displayID, 1, "跨屏选主不改窗口的原始显示器记录")
    }

    func testW11FixedPreferredDisplayWinsAndFallsBackWhenUnplugged() throws {
        let d1 = DisplayInfo(id: 1,
                             frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                             visibleFrame: CGRect(x: 0, y: 64, width: 1_512, height: 918),
                             backingScale: 2, isPrimary: true)
        let d2 = DisplayInfo(id: 2,
                             frame: CGRect(x: 1_512, y: 0, width: 1_440, height: 900),
                             visibleFrame: CGRect(x: 1_512, y: 40, width: 1_440, height: 860),
                             backingScale: 2, isPrimary: false)
        let list = [
            Fixtures.record(511, 21, frame: CGRect(x: 100, y: 100, width: 900, height: 600),
                            title: "P1", app: "A", displayID: 1),
            Fixtures.record(512, 22, frame: CGRect(x: 1_700, y: 120, width: 900, height: 600),
                            title: "S1", app: "B", displayID: 2)
        ]
        var state = SessionState()
        state.policy = SessionPolicy()
        state.slots.capacity = 48
        for item in list { state.records[item.identity] = item }
        for item in list { state.slots.assign(item.identity, memoryKey: item.memoryKey) }
        state.catalogGeneration = 1
        state.displays = [d1, d2]
        Fixtures.openToOverview(&state, records: list)

        // 固定 2 号屏：点 1 号屏上的卡片，工作台仍建在 2 号屏（方案 §13 的可选固定显示器）。
        state.workbench.preferredDisplayID = 2
        let plan = try XCTUnwrap(enterPlan(select(&state, fromOverview: list[0].identity)))
        XCTAssertEqual(plan.displayID, d2.id)
        XCTAssertEqual(plan.snapshot.layout.visibleFrame, d2.visibleFrame)
        finishEntering(&state)

        // 拔掉 2 号屏后偏好必须退回"跟随点击"：不能拿失效 displayID 继续算几何（方案 §16）。
        _ = Fixtures.dispatch(&state, .globalShortcut)
        let recoverToken = try XCTUnwrap(state.phase.token)
        _ = Fixtures.dispatch(&state, .restoreCompleted(recoverToken))
        state.displays = [d1]
        Fixtures.openToOverview(&state, records: list)
        let fallback = try XCTUnwrap(enterPlan(select(&state, fromOverview: list[0].identity)))
        XCTAssertEqual(fallback.displayID, d1.id, "偏好屏不存在时必须退回点击卡片所在的屏")
    }

    // MARK: - W13 / W14 入口与不改窗口

    func testW13EveryOpenStartsAtOverviewAndNeverAutoEnters() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        XCTAssertEqual(state.mode, .workbench)

        _ = Fixtures.dispatch(&state, .globalShortcut)
        let token = try XCTUnwrap(state.phase.token)
        let landed = Fixtures.dispatch(&state, .restoreCompleted(token))
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertFalse(hasWorkbenchEnter(landed))
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertEqual(state.workbench.modeTransition, .idle)

        let reopened = Fixtures.openToOverview(&state, records: list)
        XCTAssertEqual(state.mode, .overview, "每次打开都必须先是总览")
        XCTAssertEqual(state.phase, .overview)
        XCTAssertNil(state.workbench.placement.main, "不得自动选主")
        XCTAssertFalse(hasWorkbenchEnter(reopened), "没有点击就不得进入工作台")
    }

    func testW14NothingTouchesRealWindowsBeforeSelection() {
        var state = Fixtures.state(withCount: 6)
        let list = Fixtures.records(6)
        _ = Fixtures.dispatch(&state, .globalShortcut)
        let openEffects = Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.granted,
                                                                          reopenIfReady: true))
        guard let request = Fixtures.discoverRequest(openEffects) else {
            XCTFail("打开流程必须先要一次目录")
            return
        }
        let catalogEffects = Fixtures.dispatch(&state, .catalogUpdated(request: request, records: list))

        for effect in openEffects + catalogEffects {
            switch effect {
            case .enterWorkbench, .expand, .collapse, .settleMainFrame, .beginMainSwitch, .updateWorkbenchLayout:
                XCTFail("未点击前不得进入工作台或改真实窗口：\(effect)")
            default:
                break
            }
        }
        XCTAssertTrue(state.transactions.isEmpty, "未选择前不得有几何事务")
        XCTAssertTrue(state.workbench.placement.isEmpty)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertNil(state.workbench.snapshot, "L 型面板为零：没有工作台投影")
        XCTAssertEqual(state.mode, .overview)
    }

    // MARK: - W15 / W16 首次选择

    func testW15FirstSelectionCreatesOneMainPlusPreviews() throws {
        var (state, list) = openState(count: 6)
        let target = list[0].identity
        let grids = state.grids
        let entering = select(&state, fromOverview: target)
        let plan = try XCTUnwrap(enterPlan(entering))
        XCTAssertEqual(plan.identity, target)
        XCTAssertEqual(plan.animationFrom, state.cellRect(for: target), "起点必须是冻结总览里的原格子")
        XCTAssertEqual(plan.animationTo, plan.targetFrame)
        XCTAssertEqual(plan.railHandoffs.count, 5, "其余 5 个窗口都要有过渡端点")
        for handoff in plan.railHandoffs {
            XCTAssertEqual(handoff.from, state.cellRect(for: handoff.identity))
            XCTAssertEqual(handoff.to, plan.snapshot.rect(for: handoff.slot), "终点必须是对应轨道 slot 的矩形")
        }
        XCTAssertFalse(journalWrites(entering).isEmpty, "写入前必须有事务")
        if case .enterWorkbench = entering.last! {} else {
            XCTFail("AX 写入必须排在日志之后")
        }
        XCTAssertEqual(state.grids, grids, "进入工作台不改冻结总览")

        let finish = finishEntering(&state)
        XCTAssertEqual(state.mode, .workbench)
        XCTAssertEqual(state.workbench.placement.main, target)
        XCTAssertEqual(state.workbench.placement.occupants.count, 5)
        XCTAssertEqual(state.workbench.placement.members, Set(list.map(\.identity)))
        XCTAssertEqual(Set(state.workbench.placement.occupants.values).count, 5, "没有重复占用")
        let presentation = try XCTUnwrap(presentations(finish).first)
        XCTAssertEqual(presentation.mainIdentity, target)
        XCTAssertEqual(presentation.cards.count, 5)
        XCTAssertEqual(presentation.totalCount, 6)
        XCTAssertEqual(presentation.visibleCount, 6)
    }

    func testW16FailedFirstSelectionStaysInOverview() throws {
        var (state, list) = openState(count: 4)
        let target = list[0].identity
        _ = select(&state, fromOverview: target)
        XCTAssertNotNil(state.transactions[target], "进入前就有事务计划")

        let finish = finishEntering(&state, result: .rejected("测试注入失败"))
        XCTAssertEqual(state.mode, .overview, "失败必须完整留在总览")
        XCTAssertEqual(state.phase, .overview)
        XCTAssertNil(state.workbench.snapshot)
        XCTAssertTrue(state.workbench.placement.isEmpty)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertTrue(state.workbench.placement.maintainsInvariants)
        XCTAssertEqual(state.workbench.modeTransition, .idle)
        XCTAssertTrue(hasCancelTransition(finish))
        XCTAssertTrue(hasHideWorkbench(finish))
        XCTAssertTrue(hasTransitionFailedHint(finish))
        XCTAssertNotNil(state.transactions[target], "未确认的改动留在事务里交给宿主回滚")
        XCTAssertNotNil(state.gridCell(for: target), "总览格子还在原位")
    }

    // MARK: - W17 / W18 返回与上下文

    func testW17ReturnRestoresFrozenOverviewAndConservesWindows() throws {
        var (state, list) = openState(count: 6)
        let target = list[0].identity
        let grids = state.grids
        enterWorkbench(&state, target: target)
        let occupants = state.workbench.placement.occupants

        let effects = Fixtures.dispatch(&state, .returnToOverviewRequested)
        let plan = try XCTUnwrap(returnPlan(effects))
        XCTAssertEqual(plan.identity, target)
        XCTAssertEqual(plan.targetFrame, list[0].frame, "写回原 restingFrame")
        XCTAssertEqual(plan.animationTo, state.cellRect(for: target), "回到冻结快照里的原格子")
        XCTAssertEqual(plan.railHandoffs.count, 5)
        for handoff in plan.railHandoffs {
            XCTAssertEqual(handoff.to, state.cellRect(for: handoff.identity))
        }

        let finish = Fixtures.dispatch(&state, .workbenchTransitionFinished(token: plan.token,
                                                                           kind: .returningOverview,
                                                                           result: .succeeded(readBack: nil)))
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertEqual(state.workbench.placement.occupants, occupants, "L 型上下文保存下来")
        XCTAssertEqual(state.grids, grids, "原总览快照原样恢复")
        XCTAssertEqual(state.grids.values.reduce(0) { $0 + $1.occupiedCount }, 6, "总数守恒，主窗口也在里面")
        XCTAssertTrue(hasShowOverview(finish))
        XCTAssertNil(state.transactions[target], "写回结算：事务不得以待恢复状态余留在内存里")
        XCTAssertTrue(hasDropJournal(finish, identity: target), "日志条目与 state 同步收口")
    }

    /// 回归：返回总览成功后恢复路径已写回并删掉日志条目，state 若不同步结算，
    /// 这条事务会以"待恢复"余留在内存里；下一次中断恢复拿不到日志条目，
    /// 会把已经写回的窗口误报成「尺寸未能恢复」（实机 0.1.10+20 的 Code 误报）。
    func testW26SettledReturnLeavesNoPhantomForInterruptedHide() throws {
        var (state, list) = openState(count: 4)
        let target = list[0].identity
        enterWorkbench(&state, target: target)
        try returnToOverview(&state)

        XCTAssertNil(state.transactions[target], "返回成功即结算")
        let hidden = Fixtures.dispatch(&state, .globalShortcut)
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertFalse(hidden.contains { if case .restoreAll = $0 { return true } else { return false } },
                       "没有未完成事务：不许再发起恢复批次，否则会为幻影事务误报恢复失败")
    }

    /// 回归：进入失败后宿主补偿成功并回报（run10 实机 0.1.10+22 的 Chrome 误报链）。
    /// 补偿结果必须先于过渡结果进入状态机，state 与 journal 同步结算；
    /// 否则退出恢复会去读一条已经被补偿删掉的日志条目，误报「尺寸未能恢复」。
    func testW27EnteringFailureCompensationSettlesBeforeTransitionEnd() throws {
        var (state, list) = openState(count: 4)
        let target = list[0].identity
        _ = select(&state, fromOverview: target)
        let token = try XCTUnwrap(state.workbench.modeTransition.token)
        XCTAssertEqual(state.transactions[target]?.state.requiresRestore, true, "进入前事务待恢复")

        // 宿主补偿成功：窗口就在原处，事务按事实结束。
        let settled = Fixtures.dispatch(&state, .geometryRestoreSettled(
            token: token,
            items: [Fixtures.restoreItem(target, .alreadyAtOriginal)]))
        XCTAssertFalse(state.transactions[target]?.state.requiresRestore ?? true,
                       "补偿结算必须同步进 state")
        XCTAssertTrue(hasDropJournal(settled, identity: target), "日志条目与 state 同步收口")

        let finish = finishEntering(&state, result: .rejected("进入没落定"))
        XCTAssertEqual(state.phase, .overview, "失败留在总览")
        XCTAssertTrue(hasTransitionFailedHint(finish))

        let hidden = Fixtures.dispatch(&state, .globalShortcut)
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertFalse(hidden.contains { if case .restoreAll = $0 { return true } else { return false } },
                       "补偿已结算的窗口不得再进恢复批次（幻影误报）")
        XCTAssertTrue(hidden.contains {
            if case let .clearJournal(_, settled) = $0 { return settled.contains(target) }
            return false
        }, "结算过的条目随会话一起清理")
    }

    /// 超时后补偿归宿主执行器：state 侧必须同步收口，退出时不许为幻影事务再发起恢复。
    func testW28EnteringTimeoutLeavesNoPhantomTransaction() throws {
        var (state, list) = openState(count: 4)
        let target = list[0].identity
        _ = select(&state, fromOverview: target)
        let token = try XCTUnwrap(state.workbench.modeTransition.token)

        let effects = Fixtures.dispatch(&state, .transitionTimedOut(token))
        XCTAssertEqual(state.phase, .overview, "超时留在总览")
        XCTAssertEqual(state.workbench.modeTransition, .idle)
        XCTAssertTrue(hasTransitionFailedHint(effects))
        XCTAssertNil(state.transactions[target], "补偿归宿主：state 侧同步收口，不留幻影")

        let hidden = Fixtures.dispatch(&state, .globalShortcut)
        XCTAssertEqual(state.phase, .hidden)
        XCTAssertFalse(hidden.contains { if case .restoreAll = $0 { return true } else { return false } },
                       "幻影已收口：退出不许再发起恢复批次")
    }

    /// from 为空的交换没有 switching 阶段：回滚补偿的结果只能凭 mainSwitch 意图令牌对上，不许被丢弃。
    func testW29SwitchRollbackSettlementAcceptedWithoutSwitchingPhase() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        let b = list[1].identity
        // 构造"主区空着"的交换现场：此时点轨道卡片，phase 是 focused，没有令牌。
        state.workbench.placement.setMain(nil)
        let effects = selectRail(&state, identity: b)
        let plan = try XCTUnwrap(switchPlan(effects))
        XCTAssertNil(plan.intent.from)
        XCTAssertEqual(state.phase, .focused(target: b), "没有 from 就没有 switching 阶段")

        let settled = Fixtures.dispatch(&state, .geometryRestoreSettled(
            token: plan.intent.token,
            items: [Fixtures.restoreItem(b, .alreadyAtOriginal)]))
        XCTAssertFalse(state.transactions[b]?.state.requiresRestore ?? true,
                       "补偿结算必须进 state：from 为空时没有阶段令牌可用，凭交换意图令牌对上")
        XCTAssertTrue(hasDropJournal(settled, identity: b))
    }

    func testW18ContextReselectionRestoresOrSwapsCorrectly() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        let occupants = state.workbench.placement.occupants
        let bSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))

        try returnToOverview(&state)
        enterWorkbench(&state, target: a)
        XCTAssertEqual(state.workbench.placement.main, a)
        XCTAssertEqual(state.workbench.placement.occupants, occupants, "重选原主：原样恢复")

        try returnToOverview(&state)
        enterWorkbench(&state, target: b)
        XCTAssertEqual(state.workbench.placement.main, b)
        XCTAssertEqual(state.workbench.placement.occupant(at: bSlot), a, "重选轨道上的 B：原主落到 B 的原 slot")
        XCTAssertEqual(state.workbench.placement.members, Set(list.map(\.identity)))
    }

    // MARK: - W19 Esc 与退出

    func testW19EscapeFollowsKeyboardOwnership() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        XCTAssertEqual(state.keyboardFocus, .targetApplication)

        // 主应用持有键盘：Esc 原样交给应用。
        XCTAssertTrue(Fixtures.dispatch(&state, .escapePressed).isEmpty)
        XCTAssertEqual(state.mode, .workbench)

        // 搜索持有键盘：Esc 先关搜索，不退出工作台。
        _ = Fixtures.dispatch(&state, .workbenchSearchFocusChanged(true))
        XCTAssertEqual(state.keyboardFocus, .railSearch)
        _ = Fixtures.dispatch(&state, .searchChanged("term"))
        let escaped = Fixtures.dispatch(&state, .escapePressed)
        XCTAssertEqual(state.searchQuery, "")
        XCTAssertEqual(state.keyboardFocus, .targetApplication)
        XCTAssertTrue(escaped.contains { if case .setKeyboardFocus(.targetApplication) = $0 { return true } else { return false } })
        XCTAssertEqual(state.mode, .workbench)

        // 全局快捷键：隐藏并恢复；重开仍先总览。
        let hidden = Fixtures.dispatch(&state, .globalShortcut)
        XCTAssertFalse(state.phase.isVisible)
        XCTAssertTrue(hasHideWorkbench(hidden))
        let token = try XCTUnwrap(state.phase.token)
        _ = Fixtures.dispatch(&state, .restoreCompleted(token))
        Fixtures.openToOverview(&state, records: list)
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
    }

    // MARK: - 搜索过滤规则（总览与两栏共用同一条）

    func testSearchRuleMatchesTitleAndApplicationName() {
        var record = Fixtures.records(1)[0]
        record.title = "季度报告 — 草稿"
        record.applicationName = "Preview"

        XCTAssertTrue(record.matches(searchQuery: ""), "空查询不过滤任何窗口")
        XCTAssertTrue(record.matches(searchQuery: "季度"))
        XCTAssertTrue(record.matches(searchQuery: "preview"), "应用名匹配且大小写不敏感")
        XCTAssertTrue(record.matches(searchQuery: "草稿"))
        XCTAssertFalse(record.matches(searchQuery: "safari"))
    }

    // MARK: - W20 过渡打断

    func testW20InterruptedTransitionNeverCommitsStaleTokens() throws {
        var (state, list) = openState(count: 4)
        let target = list[0].identity
        let entering = select(&state, fromOverview: target)
        let plan = try XCTUnwrap(enterPlan(entering))
        XCTAssertEqual(plan.animationFrom, state.cellRect(for: target), "起点接续冻结总览的卡片矩形")
        XCTAssertEqual(plan.animationTo, plan.targetFrame)
        XCTAssertEqual(plan.railHandoffs.compactMap(\.to).count, 3)
        XCTAssertEqual(state.workbench.modeTransition.token, plan.token)

        // 过渡中再次点卡片：不产生第二条过渡。
        XCTAssertTrue(select(&state, fromOverview: list[1].identity).isEmpty)
        XCTAssertEqual(state.workbench.modeTransition.token, plan.token)

        // 旧令牌的完成回调不得提交。
        let stale = Fixtures.dispatch(&state, .workbenchTransitionFinished(token: TransitionToken(generation: 7),
                                                                          kind: .enteringWorkbench,
                                                                          result: .succeeded(readBack: nil)))
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(state.mode, .overview, "过渡未完成前不得进入工作台")

        // 过渡中被退出：立刻收口，随后旧完成不再复活。
        let exit = Fixtures.dispatch(&state, .escapePressed)
        XCTAssertFalse(state.phase.isVisible)
        XCTAssertTrue(hasHideWorkbench(exit))
        let token = try XCTUnwrap(state.phase.token)
        _ = Fixtures.dispatch(&state, .restoreCompleted(token))
        _ = Fixtures.dispatch(&state, .workbenchTransitionFinished(token: plan.token,
                                                                   kind: .enteringWorkbench,
                                                                   result: .succeeded(readBack: nil)))
        XCTAssertEqual(state.mode, .overview)
        XCTAssertEqual(state.phase, .hidden)
    }

    // MARK: - W21 1 窗 / 0 窗 / 途中关闭

    func testW21SingleWindowZeroWindowsAndClosedTarget() throws {
        var (single, singleList) = openState(count: 1)
        let singleEffects = enterWorkbench(&single, target: singleList[0].identity)
        let singlePresentation = try XCTUnwrap(presentations(singleEffects).first)
        XCTAssertEqual(single.workbench.placement.main, singleList[0].identity)
        XCTAssertTrue(single.workbench.placement.occupants.isEmpty, "1 个窗口时两条栏都是空的")
        XCTAssertTrue(singlePresentation.cards.isEmpty)
        XCTAssertEqual(singlePresentation.totalCount, 1)
        XCTAssertEqual(singlePresentation.visibleCount, 1)

        var (empty, _) = openState(count: 0)
        XCTAssertTrue(empty.grids.isEmpty, "0 窗时总览为空")
        XCTAssertEqual(empty.mode, .overview)
        let ghost = Fixtures.identity(777, 777)
        let ghostEffects = Fixtures.dispatch(&empty, .overviewCardSelected(identity: ghost,
                                                                          slot: SlotID(index: 0),
                                                                          revision: empty.layoutRevision))
        XCTAssertEqual(empty.mode, .overview, "不存在的窗口点不出工作台")
        XCTAssertFalse(hasWorkbenchEnter(ghostEffects))
        XCTAssertTrue(hints(ghostEffects).contains { if case .cannotLocateWindow = $0 { return true } else { return false } })

        // 途中关闭目标：立即收口，不悬空。
        var (state, list) = openState(count: 4)
        let target = list[0].identity
        _ = select(&state, fromOverview: target)
        let closed = Fixtures.dispatch(&state, .windowClosed(target))
        XCTAssertEqual(state.phase, .overview)
        XCTAssertEqual(state.workbench.modeTransition, .idle)
        XCTAssertNil(state.workbench.snapshot)
        XCTAssertTrue(state.workbench.placement.isEmpty)
        XCTAssertFalse(state.workbench.mainSwitch.isBusy)
        XCTAssertTrue(hasCancelTransition(closed))
        XCTAssertTrue(hasHideWorkbench(closed))
        XCTAssertFalse(hints(closed).isEmpty, "失败必须说话")
    }

    // MARK: - W12 设置持久化迁移

    func testW12LegacySettingsNeverBypassOverviewEntryOrDoubleScaleMainArea() {
        let legacy = LegacyWorkbenchValues(defaultPresentationMode: "focused",
                                           lastPresentationMode: "workbench",
                                           foregroundWidthRatio: 0.86,
                                           foregroundHeightRatio: 0.88,
                                           backgroundClickSwitches: true)
        let (preferences, notes) = WorkbenchPreferences.migrating(from: legacy)

        XCTAssertTrue(WorkbenchPreferences.alwaysStartsAtOverview, "入口固定总览，旧模式键不得改变它")
        XCTAssertEqual(notes.count, 3, "三条迁移事实都要说出来，不能静默改掉用户设置")
        XCTAssertEqual(preferences.schemaVersion, WorkbenchPreferences.currentSchemaVersion)
        XCTAssertEqual(preferences.side, .right, "旧版本没有侧栏偏好，取默认右栏")
        XCTAssertNil(preferences.topHeightPreference)
        XCTAssertNil(preferences.sideWidthPreference)
        XCTAssertEqual(preferences.overflowBehavior, .scroll)

        // 旧比例不进新主区几何：主区矩形只由布局与策略决定，不因旧设置再缩放一次。
        let visible = CGRect(x: 0, y: 64, width: 1_512, height: 918)
        let layout = WorkbenchLayoutEngine.layout(displayID: 1, visibleFrame: visible, side: preferences.side)
        let main = FocusGeometry.dockedRect(in: layout.mainRect,
                                            currentSize: CGSize(width: 1_280, height: 800),
                                            isResizable: true)
        XCTAssertEqual(main.width, layout.mainRect.width, accuracy: 0.5,
                       "主区尺寸来自布局本身，旧比例不得再叠一次")
        XCTAssertEqual(main.height, layout.mainRect.height, accuracy: 0.5)
    }

    func testW12SanitizeDropsDegenerateRailPreferences() {
        var preferences = WorkbenchPreferences()
        preferences.topHeightPreference = .nan
        preferences.sideWidthPreference = -8
        preferences.pinnedKeys = ["", "com.apple.Safari"]
        preferences.railOrderPreference = ["": 0, "com.apple.Safari": 1]
        let clean = preferences.sanitized()
        XCTAssertNil(clean.topHeightPreference, "NaN 偏好必须当作没有偏好")
        XCTAssertNil(clean.sideWidthPreference, "负值偏好必须丢弃")
        XCTAssertEqual(clean.pinnedKeys, ["com.apple.Safari"])
        XCTAssertEqual(clean.railOrderPreference, ["com.apple.Safari": 1])
        XCTAssertEqual(clean.schemaVersion, WorkbenchPreferences.currentSchemaVersion)
    }

    /// 方案 §16：0.1.9 及以前把「应用标识|小写标题」写进了 slotOrder / priorityKeys，迁移只留应用标识。
    func testW12LegacyTitleDerivedKeysAreCleanedToAppLevel() {
        XCTAssertEqual(LegacyTitleDerivedKeys.bundleOnly("com.apple.Safari|已保存的文章"), "com.apple.safari")
        XCTAssertEqual(LegacyTitleDerivedKeys.bundleOnly("com.apple.Safari"), "com.apple.safari")
        XCTAssertEqual(LegacyTitleDerivedKeys.bundleOnly("name:Notes|待办"), "name:notes")
        XCTAssertEqual(LegacyTitleDerivedKeys.bundleOnly("|标题"), "", "空应用段不得把标题留下来")
        XCTAssertEqual(LegacyTitleDerivedKeys.bundleOnly("   "), "")

        let order = ["com.apple.Safari|文章 A": 5, "com.apple.Safari|文章 B": 2, "": 0, "name:Notes|待办": 7]
        XCTAssertEqual(LegacyTitleDerivedKeys.cleanOrder(order),
                       ["com.apple.safari": 2, "name:notes": 7],
                       "同一应用的多条旧记录合并取最靠前序号，空键丢弃")

        let keys = ["com.apple.Safari|文章 A", "com.apple.Safari|文章 B", "", "com.apple.Safari"]
        XCTAssertEqual(LegacyTitleDerivedKeys.cleanKeys(keys), ["com.apple.safari"], "去标题、去重、排序")

        XCTAssertEqual(LegacyTitleDerivedKeys.titleDerivedCount(inOrder: order), 3)
        XCTAssertEqual(LegacyTitleDerivedKeys.titleDerivedCount(inKeys: keys), 2)
        XCTAssertFalse(LegacyTitleDerivedKeys.cleanKeys(keys).contains { $0.contains("|") || $0.contains("文章") })
    }

    /// memoryKey 与 preferenceKey 同源：标题改动不得改变记忆键，任何持久化键都不得带窗口标题（方案 §16）。
    func testW12MemoryKeyNeverCarriesWindowTitle() {
        let first = Fixtures.record(1, 10, title: "机密：季度预算", app: "备忘录", bundle: "com.example.notes")
        let renamed = Fixtures.record(1, 10, title: "改过的标题", app: "备忘录", bundle: "com.example.notes")
        XCTAssertEqual(first.memoryKey, first.preferenceKey)
        XCTAssertEqual(first.memoryKey, "com.example.notes")
        XCTAssertEqual(first.memoryKey, renamed.memoryKey, "标题改动不得改变跨会话记忆键")
        XCTAssertFalse(first.memoryKey.contains("机密"))
        // 没有 bundleID 的进程退回应用名，仍然不含标题。
        let noBundle = Fixtures.record(2, 11, title: "无 bundle 窗口", app: "UGit", bundle: nil)
        XCTAssertEqual(noBundle.memoryKey, "name:ugit")
    }

    // MARK: - W22 动效等级

    func testW22ReducedMotionAndPressureOnlyChangeTiming() throws {
        XCTAssertEqual(WorkbenchStyle().entryAnimationMS(reduceMotion: true), 100)
        XCTAssertEqual(WorkbenchStyle().returnAnimationMS(reduceMotion: true), 100)
        XCTAssertEqual(WorkbenchStyle().switchAnimationMS(reduceMotion: true), 80)
        XCTAssertEqual(WorkbenchStyle().settleAnimationMS(reduceMotion: true), 0)
        XCTAssertEqual(WorkbenchStyle().entryAnimationMS(reduceMotion: false), 240)

        var (normal, list) = openState(count: 6, policy: SessionPolicy(tier: .balanced, reduceMotion: false))
        var (reduced, reducedList) = openState(count: 6, policy: SessionPolicy(tier: .powerSaving, reduceMotion: true))
        let normalEnter = select(&normal, fromOverview: list[0].identity)
        let reducedEnter = select(&reduced, fromOverview: reducedList[0].identity)
        XCTAssertEqual(enterPlan(normalEnter)?.animationMS, 240)
        XCTAssertEqual(enterPlan(reducedEnter)?.animationMS, 100, "减少动态效果只改时长")
        finishEntering(&normal)
        finishEntering(&reduced)

        XCTAssertEqual(normal.workbench.placement, reduced.workbench.placement, "最终布局与压力等级无关")
        XCTAssertEqual(normal.workbench.snapshot?.layout.mainRect, reduced.workbench.snapshot?.layout.mainRect)
        XCTAssertEqual(normal.workbench.snapshot?.layout.topRailRect, reduced.workbench.snapshot?.layout.topRailRect)
        XCTAssertEqual(normal.workbench.snapshot?.layout.sideRailRect, reduced.workbench.snapshot?.layout.sideRailRect)
    }

    func testW22FrameStatsMeasureP95RatioAndConsecutiveStutterRuns() throws {
        XCTAssertNil(FrameIntervalStats.measure([16.7, 16.7]), "两个间隔不足以判断，别拿它下结论")

        let clean = try XCTUnwrap(FrameIntervalStats.measure(Array(repeating: 16.7, count: 20)))
        XCTAssertEqual(clean.p95MS, 16.7, accuracy: 0.01)
        XCTAssertEqual(clean.longFrameRatio, 0)
        XCTAssertEqual(clean.longestStutterRun, 0)
        XCTAssertTrue(clean.meetsTarget)

        let stuttered = try XCTUnwrap(FrameIntervalStats.measure([16.7, 16.7, 16.7, 40, 40, 40,
                                                                  16.7, 16.7, 16.7, 40, 16.7]))
        XCTAssertEqual(stuttered.longestStutterRun, 3, "连续掉帧按时间顺序数，不按排序后的位置")
        XCTAssertFalse(stuttered.meetsTarget, "连续 3 帧明显卡顿就不合格（方案 §20.3）")

        // 比率边界：100 个间隔里恰好 1 个超 33.3ms = 1%，不超预算；第 2 个才超。
        var boundary = Array(repeating: 16.7, count: 99)
        boundary.insert(50, at: 10)
        let edge = try XCTUnwrap(FrameIntervalStats.measure(boundary))
        XCTAssertEqual(edge.longFrameRatio, 0.01, accuracy: 0.0001)
        XCTAssertTrue(edge.meetsTarget)
        boundary.insert(50, at: 40)
        XCTAssertFalse(try XCTUnwrap(FrameIntervalStats.measure(boundary)).meetsTarget)
    }

    func testW22MotionLevelDegradesOnBadStreakAndRecoversSlowlyWithHysteresis() throws {
        var controller = MotionLevelController()
        XCTAssertEqual(controller.level, .full, "默认从完整动效开始")
        let bad = try XCTUnwrap(FrameIntervalStats.measure([16.7, 50, 50, 50, 16.7, 50]))
        let good = try XCTUnwrap(FrameIntervalStats.measure(Array(repeating: 16.7, count: 20)))

        XCTAssertNil(controller.observe(bad), "单段卡顿只是噪声，降级看的是连续观测（方案 §20.4）")
        XCTAssertNil(controller.observe(good), "中间一段流畅就清掉坏连击")
        for _ in 0..<10 {
            _ = controller.observe(bad)
            _ = controller.observe(good)
        }
        XCTAssertEqual(controller.level, .full, "好一段坏一段的抖动序列永远不该改变等级")

        _ = controller.observe(bad)
        XCTAssertEqual(controller.observe(bad), .light, "连续两段超预算降一级，并返回新等级")
        XCTAssertTrue(controller.reason.contains("轻量"), "降级必须留下可读的原因：\(controller.reason)")

        for _ in 0..<7 { XCTAssertNil(controller.observe(good), "一段流畅不足以恢复") }
        XCTAssertEqual(controller.level, .light)
        XCTAssertEqual(controller.observe(good), .full, "连续八段流畅才升一级：升得比降慢一个量级")

        for _ in 0..<4 { _ = controller.observe(bad) }
        XCTAssertEqual(controller.level, .fade, "继续超预算一路降到最简淡化")
        XCTAssertNil(controller.observe(bad), "已经是最低档，没有更可降的")
        XCTAssertNil(controller.observe(bad))
    }

    func testW22ReduceMotionAndPressureSetTheBaseLevelAndResetObservations() throws {
        let good = try XCTUnwrap(FrameIntervalStats.measure(Array(repeating: 16.7, count: 20)))
        let bad = try XCTUnwrap(FrameIntervalStats.measure([16.7, 50, 50, 50, 16.7]))

        var reduced = MotionLevelController(reduceMotion: true)
        XCTAssertEqual(reduced.level, .fade, "系统减少动态效果直接钉在淡化")
        for _ in 0..<20 {
            XCTAssertNil(reduced.observe(good), "钉住期间观测不改变等级，也不该误报变化")
        }
        reduced.update(reduceMotion: false, pressureTier: .balanced)
        XCTAssertEqual(reduced.level, .full, "关闭减少动态效果回到基准")

        var saving = MotionLevelController(pressureTier: .powerSaving)
        XCTAssertEqual(saving.level, .light, "低功耗档位从轻量起步")
        XCTAssertNil(saving.observe(bad))
        XCTAssertEqual(saving.observe(bad), .fade, "基准是轻量时，连续超预算照样降到淡化")
        saving.update(reduceMotion: false, pressureTier: .balanced)

        var balanced = MotionLevelController()
        _ = balanced.observe(bad)
        _ = balanced.observe(bad)
        XCTAssertEqual(balanced.level, .light)
        balanced.update(reduceMotion: true, pressureTier: .balanced)
        XCTAssertEqual(balanced.level, .fade)
        balanced.update(reduceMotion: false, pressureTier: .balanced)
        XCTAssertEqual(balanced.level, .full, "基准一变就重置旧观测：旧结论只对旧基准有效")
    }

    // MARK: - W23 分隔线调整（方案 §5.2、§11.2、H08）

    func testW23DividerHitBandsSitInsideGapsAndClampToStyle() {
        let style = WorkbenchStyle()
        let visible = CGRect(x: 0, y: 64, width: 1_512, height: 918)
        for side in [RailSide.left, RailSide.right] {
            let layout = WorkbenchLayoutEngine.layout(displayID: 1, visibleFrame: visible, side: side, style: style)
            XCTAssertFalse(layout.isDegenerate, "\(side.displayName)布局不应退化")

            let topBand = CGRect(x: layout.topRailRect.minX,
                                 y: layout.topRailRect.maxY,
                                 width: layout.topRailRect.width,
                                 height: layout.mainRect.minY - layout.topRailRect.maxY)
            let top = layout.topDividerRect
            XCTAssertEqual(top.height, min(topBand.height, style.dividerHitWidth), accuracy: 0.001,
                           "命中带厚度取空带与 token 的较小者（6–8pt）")
            XCTAssertEqual(top.midY, topBand.midY, accuracy: 0.001, "居中落在顶栏与主区之间的空带里")
            XCTAssertFalse(top.intersects(layout.topRailRect), "命中区不得侵入顶栏")
            XCTAssertFalse(top.intersects(layout.mainRect), "命中区不得侵入主区")
            XCTAssertEqual(top.width, topBand.width, accuracy: 0.001, "命中区横跨整条空带")

            let sideBand: CGRect
            switch side {
            case .right:
                sideBand = CGRect(x: layout.mainRect.maxX,
                                  y: layout.sideRailRect.minY,
                                  width: layout.sideRailRect.minX - layout.mainRect.maxX,
                                  height: layout.sideRailRect.height)
            case .left:
                sideBand = CGRect(x: layout.sideRailRect.maxX,
                                  y: layout.sideRailRect.minY,
                                  width: layout.mainRect.minX - layout.sideRailRect.maxX,
                                  height: layout.sideRailRect.height)
            }
            let sideRect = layout.sideDividerRect
            XCTAssertEqual(sideRect.width, min(sideBand.width, style.dividerHitWidth), accuracy: 0.001)
            XCTAssertEqual(sideRect.midX, sideBand.midX, accuracy: 0.001, "左右栏各自镜像，居中落带")
            XCTAssertFalse(sideRect.intersects(layout.mainRect), "命中区不得侵入主区")
            XCTAssertFalse(sideRect.intersects(layout.sideRailRect), "命中区不得侵入侧栏")
            XCTAssertEqual(sideRect.height, sideBand.height, accuracy: 0.001)

            // 面板窗口覆盖整条空带：分隔线画在带中央，1pt 桌面缝隙不存在（方案 §11.2）。
            let topWindow = layout.topPanelWindowRect
            XCTAssertEqual(topWindow.minY, layout.topRailRect.minY, accuracy: 0.001)
            XCTAssertEqual(topWindow.maxY, layout.mainRect.minY, accuracy: 0.001, "面板窗口伸到主区上边为止")
            XCTAssertTrue(topWindow.contains(top), "命中区必须落在面板窗口里，否则收不到鼠标")
            XCTAssertFalse(topWindow.intersects(layout.mainRect), "伸进空带但不越 mainRect 边缘")

            let sideWindow = layout.sidePanelWindowRect
            XCTAssertTrue(sideWindow.contains(sideRect), "侧栏命中区必须落在它的面板窗口里")
            XCTAssertFalse(sideWindow.intersects(layout.mainRect))
            XCTAssertEqual(sideWindow.minY, layout.sideRailRect.minY, accuracy: 0.001)
            XCTAssertEqual(sideWindow.maxY, layout.sideRailRect.maxY, accuracy: 0.001)
            switch side {
            case .right:
                XCTAssertEqual(sideWindow.minX, layout.mainRect.maxX, accuracy: 0.001, "右栏面板向左伸到主区右边")
                XCTAssertEqual(sideWindow.maxX, layout.sideRailRect.maxX, accuracy: 0.001)
            case .left:
                XCTAssertEqual(sideWindow.maxX, layout.mainRect.minX, accuracy: 0.001, "左栏面板向右伸到主区左边")
                XCTAssertEqual(sideWindow.minX, layout.sideRailRect.minX, accuracy: 0.001)
            }
        }

        // 空带不足 token 宽度时命中区跟着变窄，不越出空带；1pt 空带不产生命中区。
        var tight = WorkbenchStyle()
        tight.gap = 4
        let tightLayout = WorkbenchLayoutEngine.layout(displayID: 1, visibleFrame: visible, side: .right, style: tight)
        XCTAssertEqual(tightLayout.topDividerRect.height, 4, accuracy: 0.001, "空带 4pt 时命中区 4pt")
        XCTAssertEqual(tightLayout.sideDividerRect.width, 4, accuracy: 0.001)

        var hairline = WorkbenchStyle()
        hairline.gap = 1
        let hairlineLayout = WorkbenchLayoutEngine.layout(displayID: 1, visibleFrame: visible, side: .right, style: hairline)
        XCTAssertEqual(hairlineLayout.topDividerRect, .zero, "1pt 空带够不到命中区")
        XCTAssertEqual(hairlineLayout.sideDividerRect, .zero)

        // 退化布局没有可拖的带。
        let tiny = WorkbenchLayoutEngine.layout(displayID: 1,
                                                visibleFrame: CGRect(x: 10, y: 20, width: 40, height: 30),
                                                side: .right)
        XCTAssertTrue(tiny.isDegenerate)
        XCTAssertEqual(tiny.topDividerRect, .zero)
        XCTAssertEqual(tiny.sideDividerRect, .zero)
    }

    func testW23DividerPreviewOnlyMovesLocalProjectionAndNeverSettles() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        let before = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertNil(state.workbench.mainFrameWrite, "落地态没有在途写入")

        let effects = Fixtures.dispatch(&state, .workbenchRailSizePreview(topHeight: 140, sideWidth: 220))
        let after = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(after.topRailRect.height, 140, accuracy: 0.001, "预览立刻改本机投影")
        XCTAssertEqual(after.sideRailRect.width, 220, accuracy: 0.001)
        XCTAssertNotEqual(after.mainRect, before.mainRect, "主区跟着栏一起重算")
        XCTAssertEqual(state.workbench.topHeightPreference, 140)
        XCTAssertEqual(state.workbench.sideWidthPreference, 220)
        XCTAssertFalse(presentations(effects).isEmpty, "预览必须推出新布局")
        XCTAssertTrue(settlePackets(effects).isEmpty, "拖动中每个鼠标事件写一次 AX 是方案禁止的实现")
        XCTAssertNil(state.workbench.mainFrameWrite, "预览不产生在途写入")
        XCTAssertTrue(journalWrites(effects).isEmpty, "预览不动事务记录")

        // 只拖一条分隔线：另一维的偏好必须原样保留，不能被 nil 顺手清掉（方案 §11.2）。
        _ = Fixtures.dispatch(&state, .workbenchRailSizePreview(topHeight: 120, sideWidth: nil))
        XCTAssertEqual(state.workbench.topHeightPreference, 120)
        XCTAssertEqual(state.workbench.sideWidthPreference, 220, "顶栏拖动不得重置侧栏宽度偏好")

        // 超出可调范围时投影被 clamp，绝不拖出负主区。
        _ = Fixtures.dispatch(&state, .workbenchRailSizePreview(topHeight: 9_999, sideWidth: 9_999))
        let clamped = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(clamped.topRailRect.height, WorkbenchStyle().topHeightRange.upperBound, accuracy: 0.001)
        XCTAssertEqual(clamped.sideRailRect.width, WorkbenchStyle().sideWidthRange.upperBound, accuracy: 0.001)
        XCTAssertGreaterThan(clamped.mainRect.width, 0)
        XCTAssertGreaterThan(clamped.mainRect.height, 0)
    }

    func testW23DividerCommitSettlesOnceAndStaleReadBackCannotOverwriteFinal() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        let main = try XCTUnwrap(state.workbench.placement.main)

        // 拖动过程中的多次预览：只有投影在动。
        for height in stride(from: CGFloat(110), through: 150, by: 10) {
            let preview = Fixtures.dispatch(&state, .workbenchRailSizePreview(topHeight: height, sideWidth: nil))
            XCTAssertTrue(settlePackets(preview).isEmpty)
        }
        XCTAssertNil(state.workbench.mainFrameWrite)

        // 松手：一次结算，目标就是新主区几何；事务计划也更新到新目标。
        let commit = Fixtures.dispatch(&state, .workbenchRailSizeChanged(topHeight: 150, sideWidth: nil))
        let settles = settlePackets(commit)
        XCTAssertEqual(settles.count, 1, "松手只结算一次（有界去抖后）")
        let (identity, target, token) = try XCTUnwrap(settles.first)
        let layoutAfter = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(identity, main)
        XCTAssertEqual(target.width, layoutAfter.mainRect.width, accuracy: 0.5, "主窗口目标跟随新主区")
        XCTAssertEqual(state.workbench.mainFrameWrite?.token, token, "在途写入记下当前令牌")
        XCTAssertEqual(state.workbench.mainFrameWrite?.identity, main)
        XCTAssertEqual(state.transactions[main]?.plannedFrame, target, "事务计划同步到最终目标")

        // 迟到的旧令牌读回：不得清掉在途写入，也不得把旧几何写进事务（H08）。
        let stale = TransitionToken(generation: token.generation &- 1)
        let staleEffects = Fixtures.dispatch(&state, Fixtures.writeResult(main,
                                                                          token: stale,
                                                                          outcome: .exact(readBack: target.offsetBy(dx: 40, dy: 40))))
        XCTAssertTrue(staleEffects.isEmpty, "旧令牌读回必须被忽略")
        XCTAssertEqual(state.workbench.mainFrameWrite?.token, token, "最终尺寸的在途写入不被旧读回覆盖")
        XCTAssertEqual(state.transactions[main]?.plannedFrame, target, "旧读回不得改写事务目标")

        // 同一令牌但换了窗口：同样不认领。
        let foreign = Fixtures.dispatch(&state, Fixtures.writeResult(list[1].identity,
                                                                     token: token,
                                                                     outcome: .exact(readBack: target)))
        XCTAssertTrue(foreign.isEmpty, "令牌对了但身份不对的读回也不认领")
        XCTAssertEqual(state.workbench.mainFrameWrite?.token, token)

        // 当前令牌读回：收口，事务标 verified。
        let final = Fixtures.dispatch(&state, Fixtures.writeResult(main, token: token, outcome: .exact(readBack: target)))
        XCTAssertNil(state.workbench.mainFrameWrite, "完成后清空在途写入")
        XCTAssertEqual(state.transactions[main]?.state, .verified)
        XCTAssertEqual(state.transactions[main]?.plannedFrame, target)
        XCTAssertEqual(journalWrites(final).count, 1, "读回结果落一次事务记录")
    }

    // MARK: - W24 整理与固定在顶部（方案 §4.4、§6.2、§16）

    /// 每窗独立 bundle 的记录集：pin 与顺序偏好是应用级键，共用一个 bundle 就分不出谁是谁。
    private func m3dRecords(count: Int = 6, titlePrefix: String = "窗口") -> [WindowRecord] {
        (0..<count).map { index in
            Fixtures.record(500 + Int32(index), UInt32(2_000 + index),
                            frame: CGRect(x: 40 + CGFloat(index) * 30, y: 40, width: 900, height: 600),
                            title: "\(titlePrefix) \(index) — 机密标题",
                            app: "App\(index)",
                            bundle: "com.test.app\(index)")
        }
    }

    private func openState(with list: [WindowRecord]) -> SessionState {
        var state = SessionState()
        state.policy = SessionPolicy()
        state.slots.capacity = max(list.count, 48)
        for item in list { state.records[item.identity] = item }
        for item in list { state.slots.assign(item.identity, memoryKey: item.memoryKey) }
        state.catalogGeneration = 1
        state.displays = Fixtures.displays
        Fixtures.openToOverview(&state, records: list)
        return state
    }

    private func persistRailMemories(_ effects: [SessionEffect]) -> [(orderPreference: [String: Int], pinnedKeys: Set<String>)] {
        effects.compactMap {
            if case let .persistWorkbenchRailMemory(orderPreference, pinnedKeys) = $0 {
                return (orderPreference, pinnedKeys)
            }
            return nil
        }
    }

    func testW24OrganizeCompactsGapsAndPutsPinnedAppsFirst() throws {
        let list = m3dRecords()
        var state = openState(with: list)
        enterWorkbench(&state, target: list[0].identity)
        let layout = try XCTUnwrap(state.workbench.snapshot?.layout)
        let occupiedSlots = state.workbench.placement.occupants.keys.sorted()
        let topFirst = try XCTUnwrap(occupiedSlots.first)
        let sideFirst = try XCTUnwrap(occupiedSlots.last)
        XCTAssertEqual(topFirst, layout.slotOrder.first, "进入工作台后从头连续占用")
        XCTAssertNotEqual(sideFirst, topFirst, "对调需要两个不同的占用位")
        let pinnedIdentity = try XCTUnwrap(state.workbench.placement.occupant(at: sideFirst))
        XCTAssertNotEqual(pinnedIdentity, list[0].identity, "主窗口不在轨道上，别拿它当 pin 目标")
        let pinnedKey = try XCTUnwrap(state.records[pinnedIdentity]?.preferenceKey)

        // 制造乱序与空位：把第一个与最后一个占用对调，再关掉（对调后）最后一位。
        let topOccupant = try XCTUnwrap(state.workbench.placement.occupant(at: topFirst))
        _ = Fixtures.dispatch(&state, .railCardDragged(from: topFirst, to: sideFirst))
        XCTAssertEqual(state.workbench.placement.occupant(at: topFirst), pinnedIdentity, "对调先制造乱序")
        _ = Fixtures.dispatch(&state, .windowClosed(topOccupant))
        XCTAssertGreaterThan(state.workbench.placement.occupants.count, 0)

        // 固定在顶部：只写偏好，卡片此刻不动（方案 §6.2）。
        let pinEffects = Fixtures.dispatch(&state, .railPinToggled(identity: pinnedIdentity))
        XCTAssertEqual(state.workbench.placement.occupant(at: topFirst), pinnedIdentity, "pin 立即不动任何卡片")
        let pinPayload = try XCTUnwrap(persistRailMemories(pinEffects).first)
        XCTAssertEqual(pinPayload.pinnedKeys, [pinnedKey])
        XCTAssertEqual(pinPayload.orderPreference, state.workbench.placement.orderPreference,
                       "落盘的顺序就是状态里的顺序，不另算一份")

        // 整理：空位压缩、固定优先占顶栏第一格、其余按总览冻结顺序。
        let organizeEffects = Fixtures.dispatch(&state, .organizeRequested)
        let after = try XCTUnwrap(state.workbench.snapshot?.layout)
        let members = state.workbench.placement.occupants.count
        let expectedFollowing = list.map { ($0.identity, state.gridCell(for: $0.identity)?.cell.slot?.index ?? Int.max) }
            .filter { $0.0 != list[0].identity && $0.0 != pinnedIdentity && state.workbench.placement.contains($0.0) }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let expectedOrder = [pinnedIdentity] + expectedFollowing
        XCTAssertEqual(expectedOrder.count, members)
        for (index, identity) in expectedOrder.enumerated() {
            XCTAssertEqual(state.workbench.placement.occupant(at: after.slotOrder[index]), identity,
                           "第 \(index) 位应为 \(identity.windowID)")
        }
        XCTAssertGreaterThanOrEqual(after.slotOrder.count, members, "整理用到的 slot 全在内容轨道里")

        // 顺序偏好只在整理时重写：rank 就是最终位次，键是应用级 preferenceKey。
        let payload = try XCTUnwrap(persistRailMemories(organizeEffects).first)
        XCTAssertEqual(payload.pinnedKeys, [pinnedKey])
        XCTAssertEqual(state.workbench.placement.orderPreference[pinnedKey], 0)
        XCTAssertEqual(payload.orderPreference.keys.count, members)
        for key in payload.orderPreference.keys {
            XCTAssertFalse(key.contains("机密"), "顺序偏好不得落窗口标题（方案 §16）：\(key)")
        }

        // 投影里 pin 标记由展示事实驱动，与位置无关（方案 §6.2）。
        let presentation = try XCTUnwrap(presentations(organizeEffects).last)
        XCTAssertEqual(presentation.card(for: pinnedIdentity)?.isPinned, true)
    }

    func testW24PinToggleIsAppScopedAndReversibleWithoutMovingCards() throws {
        let list = m3dRecords()
        var state = openState(with: list)
        enterWorkbench(&state, target: list[0].identity)
        let slot = try XCTUnwrap(state.workbench.placement.occupants.keys.sorted().first)
        let identity = try XCTUnwrap(state.workbench.placement.occupant(at: slot))
        let before = state.workbench.placement
        let key = try XCTUnwrap(state.records[identity]?.preferenceKey)

        let pin = Fixtures.dispatch(&state, .railPinToggled(identity: identity))
        XCTAssertEqual(state.workbench.placement.occupants, before.occupants, "pin 不改占用")
        XCTAssertEqual(state.workbench.placement.orderPreference, before.orderPreference, "pin 不动顺序偏好")
        XCTAssertEqual(persistRailMemories(pin).first?.pinnedKeys, [key])
        let pinnedPresentation = try XCTUnwrap(presentations(pin).last)
        XCTAssertEqual(pinnedPresentation.card(for: identity)?.isPinned, true)

        let unpin = Fixtures.dispatch(&state, .railPinToggled(identity: identity))
        XCTAssertEqual(persistRailMemories(unpin).first?.pinnedKeys, [])
        XCTAssertEqual(state.workbench.placement.pinned, [])

        // 主窗口不在轨道上：pin 只属于轨道卡片，对主窗口不发效果。
        let main = try XCTUnwrap(state.workbench.placement.main)
        let ghost = Fixtures.dispatch(&state, .railPinToggled(identity: main))
        XCTAssertTrue(ghost.isEmpty, "主窗口没有轨道位置，pin 请求不得认领")
        XCTAssertTrue(state.workbench.placement.pinned.isEmpty)

        // 拖动换位不写顺序偏好：只有明确的整理才重写 rank（方案 §4.4）。
        let slots = state.workbench.snapshot?.layout.slotOrder ?? []
        guard slots.count >= 2 else { return XCTFail("轨道容量不足") }
        let drag = Fixtures.dispatch(&state, .railCardDragged(from: slots[0], to: slots[1]))
        XCTAssertTrue(persistRailMemories(drag).isEmpty, "拖动不得顺手把顺序偏好落盘")
        XCTAssertEqual(state.workbench.placement.orderPreference, before.orderPreference)
    }

    func testW24AdoptedPinsApplyAtFirstOrganizeAfterRelaunch() throws {
        let list = m3dRecords()
        var state = openState(with: list)
        // 上次会话留下的记忆：固定在顶部的应用 + 一条过期 rank。
        state.workbench.placement.adoptMemory(orderPreference: ["com.test.app3": 0],
                                              pinned: ["com.test.app4"])
        enterWorkbench(&state, target: list[0].identity)
        XCTAssertEqual(state.workbench.placement.pinned, ["com.test.app4"],
                       "进入工作台不丢跨会话记忆")

        let effects = Fixtures.dispatch(&state, .organizeRequested)
        let layout = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(state.workbench.placement.occupant(at: layout.slotOrder[0])?.windowID, 2_004,
                       "固定的应用优先占顶栏第一格，即使它不是总览第一")

        // 整理按当时的「总览顺序」重排（方案 §4.4）：过期 rank 不得压过现在的总览顺序。
        let expected = list.map { ($0.identity, state.gridCell(for: $0.identity)?.cell.slot?.index ?? Int.max) }
            .filter { $0.0 != list[0].identity && state.records[$0.0]?.preferenceKey != "com.test.app4" }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        for (index, identity) in expected.enumerated() {
            XCTAssertEqual(state.workbench.placement.occupant(at: layout.slotOrder[index + 1]), identity,
                           "第 \(index + 1) 位应跟随总览顺序")
        }

        // 整理重写了顺序偏好：rank 是本次整理后的最终位次，过期值被取代。
        let payload = try XCTUnwrap(persistRailMemories(effects).first)
        XCTAssertEqual(payload.orderPreference["com.test.app4"], 0)
        XCTAssertEqual(state.workbench.placement.orderPreference["com.test.app3"],
                       expected.firstIndex { state.records[$0]?.preferenceKey == "com.test.app3" }.map { $0 + 1 },
                       "app3 的位次由本次总览顺序决定，而不是旧 rank 0")
    }

    func testW24OrganizeAndPinRefuseWhileSwitchIsBusy() throws {
        let list = m3dRecords()
        var state = openState(with: list)
        enterWorkbench(&state, target: list[0].identity)
        let slot = try XCTUnwrap(state.workbench.placement.occupants.keys.sorted().first)
        let identity = try XCTUnwrap(state.workbench.placement.occupant(at: slot))

        let selectEffects = Fixtures.dispatch(&state, .railCardSelected(slot: slot, identity: identity))
        XCTAssertNotNil(switchPlan(selectEffects), "选择轨道卡片应发起主区交换")
        let token = try XCTUnwrap(state.workbench.mainSwitch.intent?.token)
        XCTAssertTrue(state.workbench.mainSwitch.isBusy)

        let placementDuring = state.workbench.placement
        let organize = Fixtures.dispatch(&state, .organizeRequested)
        XCTAssertTrue(organize.isEmpty, "交换进行中不得整理轨道")
        XCTAssertEqual(state.workbench.placement, placementDuring)
        let pin = Fixtures.dispatch(&state, .railPinToggled(identity: identity))
        XCTAssertTrue(pin.isEmpty, "交换进行中不得改轨道偏好")
        XCTAssertEqual(state.workbench.placement, placementDuring)

        completeSwitch(&state, token: token)
        XCTAssertFalse(state.workbench.mainSwitch.isBusy)
        let nextSlot = try XCTUnwrap(state.workbench.placement.occupants.keys.sorted().first)
        let next = try XCTUnwrap(state.workbench.placement.occupant(at: nextSlot))
        let nextKey = try XCTUnwrap(state.records[next]?.preferenceKey)
        let after = Fixtures.dispatch(&state, .railPinToggled(identity: next))
        XCTAssertFalse(after.isEmpty, "收敛后同一个请求就被收下了")
        XCTAssertEqual(persistRailMemories(after).first?.pinnedKeys, [nextKey])
    }

    func testW24PreferenceKeyNeverCarriesWindowTitle() {
        let titled = Fixtures.record(600, 3_000, title: "绝密项目草案 — 窗口", app: "Notes", bundle: nil)
        XCTAssertEqual(titled.preferenceKey, "name:notes")
        XCTAssertFalse(titled.preferenceKey.contains("绝密"))
        let bundled = Fixtures.record(600, 3_001, title: "绝密项目草案", app: "Notes", bundle: "com.Example.Notes")
        XCTAssertEqual(bundled.preferenceKey, "com.example.notes")
        XCTAssertFalse(bundled.preferenceKey.contains("绝密"))
    }

    // MARK: - W25 工作台写入读回必须记回事务（方案 §6.5、§8.2.3）

    /// 回归背景：进入工作台的停靠写入如果只标记 planned、不记读回，
    /// 返回总览改指原 frame 后恢复判定会看不到"停靠位是产品自己写的"，
    /// 把窗口判成"用户移动过"（skipUserMoved）而放弃写回 —— 窗口永远留在主区。
    func testW25EnteringRecordsDockReadBackSoRecoveryRestoresOriginal() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let originalA = list[0].frame
        let entering = select(&state, fromOverview: a)
        let plan = try XCTUnwrap(enterPlan(entering))
        XCTAssertEqual(journalWrites(entering).map(\.state), [.mutationPlanned], "写前计划先落盘")

        // 宿主读回与目标一致：事务必须记下「窗口此刻真的在停靠位」。
        let finish = finishEntering(&state, result: .succeeded(readBack: plan.targetFrame))
        let docked = try XCTUnwrap(state.transactions[a])
        XCTAssertEqual(docked.state, .verified)
        XCTAssertEqual(docked.lastProvisionalFrame, plan.targetFrame,
                       "读回事实是退出恢复判定「最后落在哪」的唯一依据")
        XCTAssertEqual(journalWrites(finish).map(\.state), [.verified], "读回事实要落盘，不许只活在内存里")

        // 返回总览把计划改指原 frame：恢复判定必须认得出停靠位是我们自己写的，写回原 frame。
        let back = Fixtures.dispatch(&state, .returnToOverviewRequested)
        let backPlan = try XCTUnwrap(returnPlan(back))
        let planned = try XCTUnwrap(state.transactions[a])
        XCTAssertEqual(planned.plannedFrame, originalA, "计划改指原 restingFrame")
        let decision = RecoveryPlanner.decide(entry: planned, currentFrame: plan.targetFrame,
                                              liveness: .alive, isOriginalDisplayLive: true,
                                              clampedFrame: originalA, preserveUserGeometry: false)
        XCTAssertEqual(decision, .restore(to: originalA),
                       "停在产品自己写的停靠位，不是「用户移动过」：必须恢复原 frame 而不是放弃")

        // 返回落地：写回读回同样记回事务。
        let landed = Fixtures.dispatch(&state, .workbenchTransitionFinished(token: backPlan.token,
                                                                            kind: .returningOverview,
                                                                            result: .succeeded(readBack: originalA)))
        XCTAssertEqual(journalWrites(landed).map(\.state), [.verified])
        XCTAssertEqual(state.transactions[a]?.lastProvisionalFrame, originalA)
    }

    /// 交换同理：B 进主区、A 回轨道的每一步写入都要记读回，
    /// 交换中途失败时回滚重试与退出恢复才有事实基础把两个窗口都放回去。
    func testW25SwapStepsRecordReadBacksSoRollbackAndQuitCanRestore() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let b = list[1].identity
        let originalA = list[0].frame
        let originalB = list[1].frame
        let entering = select(&state, fromOverview: a)
        let enterPlan = try XCTUnwrap(enterPlan(entering))
        _ = finishEntering(&state, result: .succeeded(readBack: enterPlan.targetFrame))
        let aDock = enterPlan.targetFrame

        let effects = selectRail(&state, identity: b)
        let plan = try XCTUnwrap(switchPlan(effects))
        let token = plan.intent.token

        // 准备阶段没有几何事实：不许凭空写日志。
        let prepared = Fixtures.dispatch(&state, .mainSwitchStepFinished(WorkbenchSwitchStepResult(
            token: token, step: .prepare, outcome: .succeeded(readBack: nil), identity: b)))
        XCTAssertTrue(journalWrites(prepared).isEmpty, "没有读回的步骤不制造事务假象")

        // B 进主区：读回记回事务。
        let moved = Fixtures.dispatch(&state, .mainSwitchStepFinished(WorkbenchSwitchStepResult(
            token: token, step: .moveToMain, outcome: .succeeded(readBack: plan.mainTargetFrame), identity: b)))
        XCTAssertEqual(journalWrites(moved).map(\.state), [.verified])
        XCTAssertEqual(state.transactions[b]?.lastProvisionalFrame, plan.mainTargetFrame)

        // 写给 A 的落点被拒：失败戳由宿主回滚路径按事实结算，这里不抢写。
        let rejected = Fixtures.dispatch(&state, .mainSwitchStepFinished(WorkbenchSwitchStepResult(
            token: token, step: .restorePrevious, outcome: .rejected("测试注入拒绝"), identity: a)))
        XCTAssertTrue(journalWrites(rejected).isEmpty, "被拒的写入不写事务")
        guard case .rollingBack = state.workbench.mainSwitch else {
            return XCTFail("失败必须进入回滚态，交由宿主补偿")
        }

        // 回滚重试与退出恢复的事实基础：B 停在主区、A 停在停靠位，都要认得出并写回各自原几何。
        let decisionB = RecoveryPlanner.decide(entry: try XCTUnwrap(state.transactions[b]),
                                               currentFrame: plan.mainTargetFrame, liveness: .alive,
                                               isOriginalDisplayLive: true, clampedFrame: originalB,
                                               preserveUserGeometry: false)
        XCTAssertEqual(decisionB, .restore(to: originalB),
                       "B 停在我们写的目标位：必须放回 B 的原 frame")
        let decisionA = RecoveryPlanner.decide(entry: try XCTUnwrap(state.transactions[a]),
                                               currentFrame: aDock, liveness: .alive,
                                               isOriginalDisplayLive: true, clampedFrame: originalA,
                                               preserveUserGeometry: false)
        XCTAssertEqual(decisionA, .restore(to: originalA),
                       "A 停在进入时写下的停靠位：回滚重试与退出恢复都必须认出来")
    }

    // MARK: - 随机序列不变量

    func testRandomOperationSequencePreservesInvariants() {
        var rng = SeededGenerator(seed: 0x5EED_2026)
        var (state, list) = openState(count: 12)
        enterWorkbench(&state, target: list[0].identity)
        XCTAssertEqual(state.mode, .workbench)

        for step in 0..<200 {
            switch Int.random(in: 0..<8, using: &rng) {
            case 0:
                selectRandomRailOccupant(&state, rng: &rng)
            case 1:
                finishCurrentSwitchIfBusy(&state)
            case 2:
                dragRandomSlots(&state, rng: &rng)
            case 3:
                let offset = CGFloat(Int.random(in: 0...400, using: &rng))
                _ = Fixtures.dispatch(&state, .railScrolled(rail: .side, offset: offset))
            case 4:
                closeRandomOccupant(&state, rng: &rng)
            case 5:
                appendRandomWindow(&state, list: list, rng: &rng)
            case 6:
                let side: RailSide = Bool.random(using: &rng) ? .left : .right
                _ = Fixtures.dispatch(&state, .railSideChanged(side))
            default:
                roundTripMode(&state, list: list, rng: &rng)
            }
            assertWorkbenchInvariants(state, step: step)
        }
    }

    private func assertWorkbenchInvariants(_ state: SessionState, step: Int) {
        let placement = state.workbench.placement
        let values = Array(placement.occupants.values)
        XCTAssertTrue(placement.maintainsInvariants, "第 \(step) 步不变量被破坏")
        XCTAssertEqual(Set(values).count, values.count, "第 \(step) 步出现重复占用")
        XCTAssertFalse(values.contains(placement.main ?? WindowIdentity(processID: -1, processStartIdentity: 0, windowID: 0)),
                       "第 \(step) 步主窗口同时出现在轨道上")
        XCTAssertTrue(placement.members.isSubset(of: Set(state.records.keys)),
                      "第 \(step) 步轨道上出现已关闭窗口")
        XCTAssertTrue(placement.members.count <= state.records.count, "第 \(step) 步成员数超出目录")
        if let main = placement.main {
            XCTAssertNotNil(state.gridCell(for: main), "第 \(step) 步主窗口没有冻结格子")
        }
        for slot in placement.occupants.keys {
            XCTAssertNil(state.gridCell(for: placement.occupants[slot]!)?.cell.identity.flatMap {
                $0 == placement.occupants[slot] ? nil : $0
            }, "第 \(step) 步轨道与网格指向了不同窗口")
        }
    }

    private func selectRandomRailOccupant(_ state: inout SessionState, rng: inout SeededGenerator) {
        let candidates = state.workbench.placement.occupants
            .filter { $0.value != state.workbench.placement.main }
            .sorted { $0.key < $1.key }
        guard !candidates.isEmpty else { return }
        let pick = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        _ = Fixtures.dispatch(&state, .railCardSelected(slot: pick.key, identity: pick.value))
    }

    private func finishCurrentSwitchIfBusy(_ state: inout SessionState) {
        guard let token = state.workbench.mainSwitch.intent?.token, state.workbench.mainSwitch.isBusy else { return }
        completeSwitch(&state, token: token)
    }

    private func dragRandomSlots(_ state: inout SessionState, rng: inout SeededGenerator) {
        let slots = state.workbench.snapshot?.layout.slotOrder ?? []
        guard slots.count > 1 else { return }
        let from = slots[Int.random(in: 0..<slots.count, using: &rng)]
        let to = slots[Int.random(in: 0..<slots.count, using: &rng)]
        _ = Fixtures.dispatch(&state, .railCardDragged(from: from, to: to))
    }

    private func closeRandomOccupant(_ state: inout SessionState, rng: inout SeededGenerator) {
        let occupants = state.workbench.placement.occupants.values
            .filter { $0 != state.workbench.placement.main }
            .sorted { $0.windowID < $1.windowID }
        guard !occupants.isEmpty else { return }
        _ = Fixtures.dispatch(&state, .windowClosed(occupants[Int.random(in: 0..<occupants.count, using: &rng)]))
    }

    private func appendRandomWindow(_ state: inout SessionState, list: [WindowRecord], rng: inout SeededGenerator) {
        guard state.mode == .workbench else { return }
        let index = Int.random(in: 0..<10_000, using: &rng)
        let extra = Fixtures.record(800 + Int32(index % 50), UInt32(20_000 + index),
                                    frame: CGRect(x: 80, y: 80, width: 1_100, height: 700),
                                    title: "随机窗口 \(index)", app: "RandomApp")
        var records = list + Array(state.records.values.filter { !list.map(\.identity).contains($0.identity) })
        if records.contains(where: { $0.identity == extra.identity }) { return }
        records.append(extra)
        try? updateCatalog(&state, records: records)
    }

    private func roundTripMode(_ state: inout SessionState, list: [WindowRecord], rng: inout SeededGenerator) {
        guard state.mode == .workbench, !state.workbench.mainSwitch.isBusy else { return }
        let effects = Fixtures.dispatch(&state, .returnToOverviewRequested)
        guard let plan = returnPlan(effects) else { return }
        _ = Fixtures.dispatch(&state, .workbenchTransitionFinished(token: plan.token,
                                                                   kind: .returningOverview,
                                                                   result: .succeeded(readBack: nil)))
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
        let candidates = list.map(\.identity).filter { state.gridCell(for: $0) != nil }
        guard !candidates.isEmpty else { return }
        let target = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        enterWorkbench(&state, target: target)
        XCTAssertEqual(state.mode, .workbench)
    }
}

/// 固定种子的可复现随机数（SplitMix64）。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
