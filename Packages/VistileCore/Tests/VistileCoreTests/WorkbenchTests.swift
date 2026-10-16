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
