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

    // MARK: - 日志闸门（方案 §7.1）

    /// 每一笔会动真实窗口几何的操作都先 `.prepareJournal`，几何 effect 寄存在 armed 操作里；
    /// 只有宿主确认落盘成功（`.journalPrepared(context:)`）才一次放出。
    /// 测试里补上这条确认，断言看到的序列就仍是"落盘之后的真实写入序列"。
    @discardableResult
    private func confirmJournal(_ state: inout SessionState, _ effects: [SessionEffect]) -> [SessionEffect] {
        var pending = effects
        var releasedAll: [SessionEffect] = []
        while !pending.isEmpty {
            let effect = pending.removeFirst()
            guard case let .prepareJournal(request) = effect else {
                releasedAll.append(effect)
                continue
            }
            // 落盘请求本身不含几何写入；确认后放行的 effect 可能又带一次 prepare，继续展开。
            pending.insert(contentsOf: Fixtures.dispatch(&state, .journalPrepared(context: request.context)), at: 0)
        }
        return releasedAll
    }

    /// 只走到"等落盘确认"为止：不确认，返回原始 effect。
    @discardableResult
    private func prepareOnly(_ state: inout SessionState, _ effects: [SessionEffect]) -> JournalPrepareRequest? {
        for effect in effects {
            if case let .prepareJournal(request) = effect { return request }
        }
        return nil
    }

    // MARK: - 流程骨架

    /// 派发事件并把日志闸门走到"已确认"为止。
    @discardableResult
    private func dispatchConfirmed(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect] {
        let raw = Fixtures.dispatch(&state, event)
        return confirmJournal(&state, raw)
    }

    @discardableResult
    private func select(_ state: inout SessionState, fromOverview target: WindowIdentity) -> [SessionEffect] {
        guard let slot = state.gridCell(for: target)?.cell.slot else {
            XCTFail("目标不在冻结网格里")
            return []
        }
        return dispatchConfirmed(&state, .overviewCardSelected(identity: target,
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
        return dispatchConfirmed(&state, .workbenchTransitionFinished(token: token,
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
        return dispatchConfirmed(&state, .railCardSelected(slot: slot, identity: identity))
    }

    /// 报告交换的每一步并提交。
    @discardableResult
    private func completeSwitch(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        var effects: [SessionEffect] = []
        for step in WorkbenchSwitchStep.allCases {
            effects += dispatchConfirmed(&state, .mainSwitchStepFinished(
                WorkbenchSwitchStepResult(token: token,
                                          step: step,
                                          outcome: .succeeded(readBack: nil),
                                          identity: nil)))
        }
        effects += dispatchConfirmed(&state, .mainSwitchCommitted(token: token))
        return effects
    }

    /// 走一次目录回调：注入新窗口等事实必须从发现请求进来。
    @discardableResult
    private func updateCatalog(_ state: inout SessionState, records: [WindowRecord]) throws -> [SessionEffect] {
        let effects = Fixtures.dispatch(&state, .reconcileTick)
        let request = try XCTUnwrap(Fixtures.discoverRequest(effects))
        return dispatchConfirmed(&state, .catalogUpdated(request: request, records: records))
    }

    @discardableResult
    private func returnToOverview(_ state: inout SessionState, success: Bool = true) throws -> WorkbenchTransitionPlan {
        let effects = dispatchConfirmed(&state, .returnToOverviewRequested)
        let plan = try XCTUnwrap(returnPlan(effects))
        _ = dispatchConfirmed(&state, .workbenchTransitionFinished(token: plan.token,
                                                                  kind: .returningOverview,
                                                                  result: success ? .succeeded(readBack: nil)
                                                                                  : .rejected("测试注入失败")))
        return plan
    }

    /// 交换失败后回报补偿事实：宿主已经按操作前快照逆序回位。
    @discardableResult
    private func reportSwitchFailure(_ state: inout SessionState,
                                     token: TransitionToken,
                                     reason: String,
                                     compensation: WorkbenchCompensationResult?) -> [SessionEffect] {
        dispatchConfirmed(&state, .mainSwitchFailed(token: token, reason: reason, compensation: compensation))
    }

    /// prepare 失败回执：一次 AX 都没写。
    @discardableResult
    private func rejectPrepare(_ state: inout SessionState,
                               _ request: JournalPrepareRequest,
                               reason: String = "测试注入：日志写入失败") -> [SessionEffect] {
        dispatchConfirmed(&state, .journalPreparationFailed(context: request.context,
                                                            identities: request.affectedIdentities,
                                                            reason: reason))
    }

    /// 写后落盘失败回执：事实已经发生。
    @discardableResult
    private func rejectUpdate(_ state: inout SessionState,
                              _ request: JournalPrepareRequest,
                              identity: WindowIdentity,
                              reason: String = "测试注入：写后落盘失败") -> [SessionEffect] {
        dispatchConfirmed(&state, .journalUpdateFailed(context: request.context,
                                                      identity: identity,
                                                      reason: reason))
    }

    /// 主窗口读回收口（布局结算与交换中的有界修正共用这条通道）。
    @discardableResult
    private func reportWrite(_ state: inout SessionState,
                             _ packet: SettlePacket,
                             outcome: GeometryOutcome) -> [SessionEffect] {
        dispatchConfirmed(&state, .geometryWriteFinished(GeometryWriteResult(identity: packet.identity,
                                                                            token: packet.context.transitionToken,
                                                                            operationID: packet.context.operationID,
                                                                            targetFrame: packet.target,
                                                                            displayID: state.workbench.activeDisplayID ?? 1,
                                                                            outcome: outcome,
                                                                            context: packet.context)))
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

    /// 主区结算包：目标 frame 与它所属的操作上下文（令牌在上下文里）。
    private typealias SettlePacket = (identity: WindowIdentity, target: CGRect, context: GeometryOperationContext)

    /// 日志里出现的写前事务：批量 prepare 的条目与写后追加的条目都算。
    private func journalWrites(_ effects: [SessionEffect]) -> [WindowTransaction] {
        var result: [WindowTransaction] = []
        for effect in effects {
            switch effect {
            case let .prepareJournal(request):
                for mutation in request.mutations {
                    if case let .upsert(transaction) = mutation { result.append(transaction) }
                }
            case let .updateJournal(request):
                if case let .upsert(transaction) = request.mutation { result.append(transaction) }
            default:
                break
            }
        }
        return result
    }

    private func prepareRequests(_ effects: [SessionEffect]) -> [JournalPrepareRequest] {
        effects.compactMap {
            if case let .prepareJournal(request) = $0 { return request }
            return nil
        }
    }

    private func journalRemovals(_ effects: [SessionEffect]) -> [WindowIdentity] {
        var result: [WindowIdentity] = []
        for effect in effects {
            if case let .updateJournal(request) = effect,
               case let .remove(identity) = request.mutation {
                result.append(identity)
            }
        }
        return result
    }

    private func settlePackets(_ effects: [SessionEffect]) -> [SettlePacket] {
        effects.compactMap {
            if case let .settleMainFrame(identity, targetFrame, context, _) = $0 {
                return (identity, targetFrame, context)
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

    /// 条目已结算：journal 只清理"不需要恢复"的窗口，因此这条 effect 就是"这个身份已经落定"。
    private func hasDropJournal(_ effects: [SessionEffect], identity: WindowIdentity) -> Bool {
        effects.contains {
            if case let .clearJournal(_, settled) = $0 { return settled.contains(identity) }
            return false
        }
    }

    private func hasSettleEffects(_ effects: [SessionEffect]) -> Bool {
        !settlePackets(effects).isEmpty || effects.contains {
            if case .beginMainSwitch = $0 { return true }
            if case .enterWorkbench = $0 { return true }
            if case .returnToOverview = $0 { return true }
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

        // 落盘请求就是这次操作的全部对外动作：确认之前一条 AX 写入都不许发出去。
        let rawSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))
        let pending = Fixtures.dispatch(&state, .railCardSelected(slot: rawSlot, identity: b))
        XCTAssertEqual(pending.count, 1, "prepare 之前唯一的 effect 就是落盘请求")
        let request = try XCTUnwrap(prepareRequests(pending).first)
        XCTAssertEqual(request.context.kind, .mainSwitch)
        XCTAssertEqual(Set(request.affectedIdentities), Set([a, b]))
        XCTAssertEqual(request.mutations.count, 2, "B 的目标与 A 的落点都要先写日志")
        XCTAssertTrue(journalWrites(pending).allSatisfy { $0.state == .mutationPlanned },
                      "落盘的是写前事务，不是读回结果")
        XCTAssertTrue(settlePackets(pending).isEmpty && switchPlan(pending) == nil,
                      "日志未确认前不得有 AX 写入")
        XCTAssertNil(state.workbench.activeContext, "操作尚未准入")
        // 已确认后的序列：只剩这一笔交换写入，排在日志之后。
        let effects = confirmJournal(&state, pending)
        let plan = try XCTUnwrap(switchPlan(effects))
        XCTAssertEqual(effects.count, 1, "落盘之后只发一条几何写入")
        if case .beginMainSwitch = effects.last! {} else {
            XCTFail("AX 写入必须排在日志之后")
        }
        XCTAssertEqual(plan.intent.from, a)
        XCTAssertEqual(plan.intent.to, b)
        XCTAssertEqual(plan.restingSlot, bSlot)
        XCTAssertEqual(plan.mainTargetFrame, state.workbench.snapshot?.mainRect, "B 的目标就是主区矩形")
        XCTAssertEqual(plan.intent.beforeOperation.writtenOrder, request.affectedIdentities,
                       "批次顺序就是补偿顺序的依据")

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
        XCTAssertEqual(state.workbench.scrollOffset(rail: .top), 0, "偏移的唯一来源就是投影：交换不引入第二份数值")
        XCTAssertEqual(state.workbench.scrollOffset(rail: .side), 0)
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
        XCTAssertEqual(state.workbench.scrollOffset(rail: .side), 120, "偏移落在投影里，不再有第二份独立数值")
        XCTAssertEqual(state.workbench.snapshot?.sideScrollOffset, 120, "投影与访问器是同一个事实")
        let scrolledSnapshot = try XCTUnwrap(state.workbench.snapshot)

        for target in [list[1].identity, list[2].identity] {
            let effects = selectRail(&state, identity: target)
            let plan = try XCTUnwrap(switchPlan(effects))
            completeSwitch(&state, token: plan.intent.token)
            XCTAssertEqual(state.workbench.placement.main, target)
            XCTAssertTrue(state.workbench.placement.maintainsInvariants)
            XCTAssertEqual(state.workbench.placement.members.count, 24, "每次交换都不得丢失或复制窗口")
            XCTAssertEqual(state.workbench.scrollOffset(rail: .side), 120, "交换不得重置滚动位置")
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
        let switchEffects = dispatchConfirmed(&state, .railCardSelected(slot: crossSlot, identity: list[0].identity))
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
        let slot = try XCTUnwrap(state.gridCell(for: target)?.cell.slot)
        let pending = Fixtures.dispatch(&state, .overviewCardSelected(identity: target,
                                                                     slot: slot,
                                                                     revision: state.layoutRevision))
        let request = try XCTUnwrap(prepareRequests(pending).first)
        XCTAssertEqual(request.context.kind, .enterWorkbench)
        XCTAssertEqual(request.affectedIdentities, [target])
        let transactions = journalWrites(pending)
        XCTAssertEqual(transactions.count, 1, "写入前必须有事务")
        XCTAssertEqual(transactions.first?.state, .mutationPlanned)
        XCTAssertEqual(transactions.first?.operationID, request.context.operationID,
                       "事务绑的就是这次被准入的操作")
        XCTAssertNotNil(transactions.first?.operationBeforeFrame, "补偿依据是操作前实读快照")
        XCTAssertFalse(hasWorkbenchEnter(pending), "落盘确认前不发进入 effect")
        let entering = confirmJournal(&state, pending)
        let plan = try XCTUnwrap(enterPlan(entering))
        XCTAssertEqual(plan.identity, target)
        XCTAssertEqual(plan.animationFrom, state.cellRect(for: target), "起点必须是冻结总览里的原格子")
        XCTAssertEqual(plan.animationTo, plan.targetFrame)
        XCTAssertEqual(plan.operationContext, request.context, "进入 effect 带的就是刚落盘的那个操作上下文")
        XCTAssertEqual(plan.railHandoffs.count, 5, "其余 5 个窗口都要有过渡端点")
        for handoff in plan.railHandoffs {
            XCTAssertEqual(handoff.from, state.cellRect(for: handoff.identity))
            XCTAssertEqual(handoff.to, plan.snapshot.rect(for: handoff.slot), "终点必须是对应轨道 slot 的矩形")
        }
        XCTAssertEqual(entering.count, 1, "落盘之后只发一条进入写入")
        if case .enterWorkbench = entering.last! {} else {
            XCTFail("AX 写入必须排在日志之后")
        }
        XCTAssertEqual(state.grids, grids, "进入工作台不改冻结总览")
        XCTAssertNotNil(state.transactions[target], "确认落盘后事务才进内存")

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

        // 返回同样是"先落盘再写"：批次里记的是主窗口写回的目标与操作前实读。
        let pendingReturn = Fixtures.dispatch(&state, .returnToOverviewRequested)
        let returnRequest = try XCTUnwrap(prepareRequests(pendingReturn).first)
        XCTAssertEqual(returnRequest.context.kind, .returnOverview)
        XCTAssertEqual(returnRequest.affectedIdentities, [target])
        XCTAssertTrue(hasSettleEffects(pendingReturn) == false, "落盘确认前不发返回写入")
        let effects = confirmJournal(&state, pendingReturn)
        let plan = try XCTUnwrap(returnPlan(effects))
        XCTAssertEqual(plan.identity, target)
        XCTAssertEqual(plan.operationContext, returnRequest.context)
        XCTAssertEqual(plan.targetFrame, list[0].frame, "写回原 restingFrame")
        XCTAssertEqual(plan.animationTo, state.cellRect(for: target), "回到冻结快照里的原格子")
        XCTAssertEqual(plan.railHandoffs.count, 5)
        for handoff in plan.railHandoffs {
            XCTAssertEqual(handoff.to, state.cellRect(for: handoff.identity))
        }

        let finish = dispatchConfirmed(&state, .workbenchTransitionFinished(token: plan.token,
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

    /// 呈现事实（方案 §20.2）：present=0 就是没有画面证据，回调多于呈现要能算出缺口，
    /// present 多于 tick（play 的同步第一帧）不算缺口。
    func testTransitionFlightFactsSeparatePresentsFromTicks() {
        let dry = TransitionFlightFacts(firstPresentDelayMS: nil, ticks: 12, presentedFrames: 0,
                                        anchoredAtRealInput: true)
        XCTAssertFalse(dry.hasPresentedPixels, "一次 present 都没有，tick 再多也不能当画面证据")
        XCTAssertEqual(dry.missedPresentFrames, 12)

        let flying = TransitionFlightFacts(firstPresentDelayMS: 8, ticks: 12, presentedFrames: 13,
                                           anchoredAtRealInput: false)
        XCTAssertTrue(flying.hasPresentedPixels)
        XCTAssertEqual(flying.missedPresentFrames, 0, "首帧是 play() 同步画的，present 比 tick 多不是缺口")

        let partial = TransitionFlightFacts(firstPresentDelayMS: 8, ticks: 12, presentedFrames: 9,
                                            anchoredAtRealInput: true)
        XCTAssertEqual(partial.missedPresentFrames, 3, "3 个回调没换成帧要能被数出来")
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

        // 松手：先落盘再结算，目标就是新主区几何；事务计划也更新到新目标。
        let pendingCommit = Fixtures.dispatch(&state, .workbenchRailSizeChanged(topHeight: 150, sideWidth: nil))
        let settleRequest = try XCTUnwrap(prepareRequests(pendingCommit).first)
        XCTAssertEqual(settleRequest.context.kind, .settleLayout)
        XCTAssertTrue(settlePackets(pendingCommit).isEmpty, "落盘确认前不写真实窗口")
        let commit = confirmJournal(&state, pendingCommit)
        let settles = settlePackets(commit)
        XCTAssertEqual(settles.count, 1, "松手只结算一次（有界去抖后）")
        let (identity, target, context) = try XCTUnwrap(settles.first)
        let layoutAfter = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(identity, main)
        XCTAssertEqual(context, settleRequest.context, "放行的写入带的就是刚落盘的那个操作上下文")
        XCTAssertEqual(target.width, layoutAfter.mainRect.width, accuracy: 0.5, "主窗口目标跟随新主区")
        XCTAssertEqual(state.workbench.mainFrameWrite?.token, context.transitionToken, "在途写入记下当前令牌")
        XCTAssertEqual(state.workbench.mainFrameWrite?.identity, main)
        XCTAssertEqual(state.transactions[main]?.plannedFrame, target, "事务计划同步到最终目标")

        // 迟到的旧令牌读回：不得清掉在途写入，也不得把旧几何写进事务（H08）。
        let stale = TransitionToken(generation: context.transitionToken.generation &- 1)
        let staleEffects = Fixtures.dispatch(&state, Fixtures.writeResult(main,
                                                                          token: stale,
                                                                          outcome: .exact(readBack: target.offsetBy(dx: 40, dy: 40))))
        XCTAssertTrue(staleEffects.isEmpty, "旧令牌读回必须被忽略")
        XCTAssertEqual(state.workbench.mainFrameWrite?.token, context.transitionToken,
                       "最终尺寸的在途写入不被旧读回覆盖")
        XCTAssertEqual(state.transactions[main]?.plannedFrame, target, "旧读回不得改写事务目标")

        // 同一令牌但换了窗口：同样不认领。
        let foreign = Fixtures.dispatch(&state, Fixtures.writeResult(list[1].identity,
                                                                     token: context.transitionToken,
                                                                     outcome: .exact(readBack: target)))
        XCTAssertTrue(foreign.isEmpty, "令牌对了但身份不对的读回也不认领")
        XCTAssertEqual(state.workbench.mainFrameWrite?.token, context.transitionToken)

        // 当前令牌读回：收口，事务标 verified。
        let final = Fixtures.dispatch(&state, Fixtures.writeResult(main, token: context.transitionToken,
                                                                   outcome: .exact(readBack: target)))
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

        // 备料阶段（落盘还没确认）：这次交换的占用还没定，整理必须等待（方案 §7.1、§10.4）。
        let armedBefore = state.workbench.placement
        let pending = Fixtures.dispatch(&state, .railCardSelected(slot: slot, identity: identity))
        let request = try XCTUnwrap(prepareRequests(pending).first)
        XCTAssertNil(switchPlan(pending), "落盘确认前不得发出交换写入")
        XCTAssertTrue(Fixtures.dispatch(&state, .organizeRequested).isEmpty, "备料期间不得整理轨道")
        XCTAssertEqual(state.workbench.placement, armedBefore, "拒绝整理不能顺手改占用")

        // 确认后交换真正开始：busy 期间整理与偏好都拒绝。
        let selectEffects = confirmJournal(&state, pending)
        let plan = try XCTUnwrap(switchPlan(selectEffects), "落盘确认后选择轨道卡片应发起主区交换")
        XCTAssertEqual(plan.intent.operationContext, request.context, "放行的就是刚落盘的那个操作")
        let token = try XCTUnwrap(state.workbench.mainSwitch.intent?.token)
        XCTAssertEqual(token, plan.intent.token)
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

    /// 恢复落点规划用的"原屏仍在、原 frame 仍在范围内"事实（与 RecoveryCaptureTests 同一夹具）。
    private static let recoveryVisible = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    /// 回归背景：进入工作台的停靠写入如果只标记 planned、不记读回，
    /// 返回总览改指原 frame 后恢复判定会看不到"停靠位是产品自己写的"，
    /// 把窗口判成"用户移动过"（skipUserMoved）而放弃写回 —— 窗口永远留在主区。
    func testW25EnteringRecordsDockReadBackSoRecoveryRestoresOriginal() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let originalA = list[0].frame
        let slot = try XCTUnwrap(state.gridCell(for: a)?.cell.slot)
        let pending = Fixtures.dispatch(&state, .overviewCardSelected(identity: a,
                                                                     slot: slot,
                                                                     revision: state.layoutRevision))
        XCTAssertEqual(journalWrites(pending).map(\.state), [.mutationPlanned], "写前计划先落盘")
        let entering = confirmJournal(&state, pending)
        let plan = try XCTUnwrap(enterPlan(entering))

        // 宿主读回与目标一致：事务必须记下「窗口此刻真的在停靠位」。
        let finish = finishEntering(&state, result: .succeeded(readBack: plan.targetFrame))
        let docked = try XCTUnwrap(state.transactions[a])
        XCTAssertEqual(docked.state, .verified)
        XCTAssertEqual(docked.lastProvisionalFrame, plan.targetFrame,
                       "读回事实是退出恢复判定「最后落在哪」的唯一依据")
        XCTAssertEqual(journalWrites(finish).map(\.state), [.verified], "读回事实要落盘，不许只活在内存里")

        // 返回总览把计划改指原 frame：恢复判定必须认得出停靠位是我们自己写的，写回原 frame。
        let back = dispatchConfirmed(&state, .returnToOverviewRequested)
        let backPlan = try XCTUnwrap(returnPlan(back))
        let planned = try XCTUnwrap(state.transactions[a])
        XCTAssertEqual(planned.plannedFrame, originalA, "计划改指原 restingFrame")
        // 落点由 RestorePlanner 一次算好（方案 §8）：原屏仍在、原 frame 仍在范围内 → 精确恢复。
        let destination = try XCTUnwrap(RestorePlanner.plan(entry: planned,
                                                           originalDisplayIsLive: true,
                                                           originalVisibleFrame: Self.recoveryVisible,
                                                           fallbackVisibleFrame: nil))
        XCTAssertEqual(destination.targetFrame, originalA, "落点就是原 frame，不再二次夹取")
        XCTAssertEqual(destination.targetDisplayID, 1, "落点仍在原屏")
        XCTAssertEqual(destination.reason, .exactOnOriginalDisplay)
        XCTAssertFalse(destination.isDowngraded)
        let decision = RecoveryPlanner.decide(entry: planned, currentFrame: plan.targetFrame,
                                              liveness: .alive, destination: destination,
                                              preserveUserGeometry: false)
        XCTAssertEqual(decision, .restore(to: destination),
                       "停在产品自己写的停靠位，不是「用户移动过」：必须恢复原 frame 而不是放弃")

        // 返回落地：写回读回同样记回事务。
        let landed = dispatchConfirmed(&state, .workbenchTransitionFinished(token: backPlan.token,
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
        let entryB = try XCTUnwrap(state.transactions[b])
        let destinationB = try XCTUnwrap(RestorePlanner.plan(entry: entryB,
                                                            originalDisplayIsLive: true,
                                                            originalVisibleFrame: Self.recoveryVisible,
                                                            fallbackVisibleFrame: nil))
        let decisionB = RecoveryPlanner.decide(entry: entryB,
                                               currentFrame: plan.mainTargetFrame, liveness: .alive,
                                               destination: destinationB, preserveUserGeometry: false)
        XCTAssertEqual(decisionB, .restore(to: destinationB),
                       "B 停在我们写的目标位：必须放回 B 的原 frame")
        XCTAssertEqual(destinationB.targetFrame, originalB, "B 的回滚/退出落点就是它自己的原 frame")
        XCTAssertEqual(destinationB.targetDisplayID, 1, "落点仍在原屏，不是窗口当前所在屏")

        let entryA = try XCTUnwrap(state.transactions[a])
        let destinationA = try XCTUnwrap(RestorePlanner.plan(entry: entryA,
                                                            originalDisplayIsLive: true,
                                                            originalVisibleFrame: Self.recoveryVisible,
                                                            fallbackVisibleFrame: nil))
        let decisionA = RecoveryPlanner.decide(entry: entryA,
                                               currentFrame: aDock, liveness: .alive,
                                               destination: destinationA, preserveUserGeometry: false)
        XCTAssertEqual(decisionA, .restore(to: destinationA),
                       "A 停在进入时写下的停靠位：回滚重试与退出恢复都必须认出来")
        XCTAssertEqual(destinationA.targetFrame, originalA, "A 的落点是会话原 frame，而不是操作前停靠位")
        XCTAssertEqual(destinationA.targetDisplayID, 1)
        // 补偿依据与恢复依据是两个独立事实：A 的操作前快照仍是停靠位。
        XCTAssertEqual(entryA.operationBeforeFrame, aDock, "补偿按操作前，退出按会话原 frame")
        XCTAssertEqual(entryA.operationID, plan.intent.operationContext.operationID)
    }

    // MARK: - 日志落盘故障族（方案 §18 A13–A18、§7.2、§7.5）

    /// A13（方案 §7.5）：进入工作台的写前事务没落盘 = 一次 AX 都不写；总线清干净后第二次必须能真正进入。
    func testEnterPrepareFailureWritesNothingAndRetryProceeds() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        let transactionsBefore = state.transactions
        let slot = try XCTUnwrap(state.gridCell(for: a)?.cell.slot)
        let pending = Fixtures.dispatch(&state, .overviewCardSelected(identity: a, slot: slot,
                                                                     revision: state.layoutRevision))
        let request = try XCTUnwrap(prepareOnly(&state, pending))
        XCTAssertEqual(request.context.kind, .enterWorkbench)

        let effects = rejectPrepare(&state, request, reason: "测试注入：日志目录写不进")
        XCTAssertFalse(hasWorkbenchEnter(effects), "日志没落盘就不许把窗口搬进主区")
        XCTAssertFalse(hasSettleEffects(effects), "未准入的操作不能有任何几何写入：\(effects)")
        XCTAssertNil(state.workbench.armed, "备料必须整套撤销，不许留下等回执的意图")
        XCTAssertEqual(state.mode, .overview, "进入失败回到总览，不能留下半个 L 型")
        XCTAssertFalse(state.workbench.modeTransition.isTransitioning, "busy 标记必须清干净")
        XCTAssertTrue(state.workbench.acceptsNewOrdinaryOperation, "用户还能再选一次（方案 §7.2 表）")
        XCTAssertEqual(state.transactions, transactionsBefore, "未落盘的事务从不进内存")
        XCTAssertTrue(hints(effects).contains(.journalWriteFailed("测试注入：日志目录写不进")),
                      "落盘失败要如实提示：\(hints(effects))")

        enterWorkbench(&state, target: a)
        XCTAssertEqual(state.mode, .workbench, "第二次落盘成功必须真正进入")
        XCTAssertEqual(state.workbench.placement.main, a)
    }

    /// A14（方案 §7.2）：A/B 批量里任何一条落不下去就是整批作废——内存里不能留下半套交换事务。
    func testBatchPrepareFailureKeepsJournalAndPlacementUntouched() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        let transactionsBefore = state.transactions
        let placementBefore = state.workbench.placement

        let slot = try XCTUnwrap(state.workbench.placement.slot(of: b))
        let pending = Fixtures.dispatch(&state, .railCardSelected(slot: slot, identity: b))
        let request = try XCTUnwrap(prepareOnly(&state, pending))
        XCTAssertEqual(request.mutations.count, 2, "B 的目标与 A 的落点必须同批落盘")
        XCTAssertEqual(Set(request.affectedIdentities), Set([a, b]))

        let effects = rejectPrepare(&state, request)
        XCTAssertNil(switchPlan(effects), "整批作废时不能只发交换的一半（方案 §7.2）")
        XCTAssertEqual(state.transactions, transactionsBefore, "半套事务就是下一次补偿读错位置的开始")
        XCTAssertEqual(state.workbench.placement, placementBefore, "主区与轨道保持操作前事实")
        XCTAssertEqual(state.workbench.mainSwitch.intent?.to, b, "失败意图留着，供提示与重试定位")
        XCTAssertFalse(state.workbench.mainSwitch.isBusy)
        XCTAssertTrue(state.workbench.acceptsNewOrdinaryOperation)

        let retry = selectRail(&state, identity: b)
        let plan = try XCTUnwrap(switchPlan(retry))
        completeSwitch(&state, token: plan.intent.token)
        XCTAssertEqual(state.workbench.placement.main, b, "整批重落后交换照常走完")
        XCTAssertEqual(state.workbench.placement.occupant(at: slot), a)
    }

    /// A15（方案 §7.2）：返回总览的写前事务落不下去时工作台原样保留——既不飞行，也不开始恢复。
    func testReturnPrepareFailureKeepsMainRailAndStartsNoFlight() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        enterWorkbench(&state, target: a)
        let placementBefore = state.workbench.placement
        let transactionsBefore = state.transactions
        let snapshotBefore = try XCTUnwrap(state.workbench.snapshot)

        let pending = Fixtures.dispatch(&state, .returnToOverviewRequested)
        let request = try XCTUnwrap(prepareOnly(&state, pending))
        XCTAssertEqual(request.context.kind, .returnOverview)

        let effects = rejectPrepare(&state, request)
        XCTAssertNil(returnPlan(effects), "日志没落盘就不许把窗口放飞回原位")
        XCTAssertFalse(effects.contains {
            if case .restoreAll = $0 { return true }
            if case .restoreGeometry = $0 { return true }
            return false
        }, "返回失败不得触发任何恢复写入：\(effects)")
        XCTAssertEqual(state.mode, .workbench, "返回失败留在工作台，不能停在两种都不完整的形态")
        XCTAssertEqual(state.workbench.placement, placementBefore, "原主与轨道一律不动")
        XCTAssertEqual(state.transactions, transactionsBefore)
        XCTAssertEqual(state.workbench.snapshot, snapshotBefore, "几何投影不预留返回结果")
        XCTAssertFalse(state.workbench.modeTransition.isTransitioning)
        XCTAssertTrue(state.workbench.acceptsNewOrdinaryOperation)

        try returnToOverview(&state)
        XCTAssertEqual(state.mode, .overview, "重试返回必须真的走完")
    }

    /// A17（方案 §7.2 末段、§7.3）：写后事实落不进日志不是"未写入"——停后续步骤、排空在途几何，
    /// 并把真实写入留下的恢复义务原样保留。
    func testObservedFactPersistFailureStopsStepsAndKeepsRestoreObligation() throws {
        var (state, list) = openState(count: 5)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        let slotB = try XCTUnwrap(state.workbench.placement.slot(of: b))
        let pending = Fixtures.dispatch(&state, .railCardSelected(slot: slotB, identity: b))
        let request = try XCTUnwrap(prepareOnly(&state, pending))
        let plan = try XCTUnwrap(switchPlan(confirmJournal(&state, pending)))

        let step = dispatchConfirmed(&state, .mainSwitchStepFinished(
            WorkbenchSwitchStepResult(token: plan.intent.token,
                                      step: .moveToMain,
                                      outcome: .succeeded(readBack: plan.mainTargetFrame),
                                      identity: b)))
        XCTAssertTrue(step.contains { if case .updateJournal = $0 { return true } else { return false } },
                      "写成功要追加一条已发生的事实：\(step)")
        XCTAssertEqual(state.transactions[b]?.state.requiresRestore, true,
                       "写过几何的事务必须欠着恢复，不管日志记没记住（方案 §6.4）")

        let effects = rejectUpdate(&state, request, identity: b, reason: "测试注入：写后落盘失败")
        XCTAssertTrue(effects.contains {
            if case .drainGeometry(plan.intent.operationContext) = $0 { return true }
            return false
        }, "在途几何按本次操作上下文排空：\(effects)")
        XCTAssertTrue(state.workbench.mainSwitch.isRollingBack, "写后落盘失败只能进补偿，不能继续提交")
        XCTAssertTrue(hints(effects).contains(.journalWriteFailed("测试注入：写后落盘失败")))

        let later = dispatchConfirmed(&state, .mainSwitchStepFinished(
            WorkbenchSwitchStepResult(token: plan.intent.token,
                                      step: .restorePrevious,
                                      outcome: .succeeded(readBack: nil),
                                      identity: a)))
        XCTAssertTrue(later.isEmpty, "补偿中的后续步骤不许再产生 effect：\(later)")
        let late = dispatchConfirmed(&state, .mainSwitchCommitted(token: plan.intent.token))
        XCTAssertTrue(late.isEmpty, "补偿没结算就不许提交：\(late)")
        XCTAssertEqual(state.workbench.placement.main, a, "主区仍是 A：补偿完成前绝不提交")
        XCTAssertEqual(state.transactions[b]?.state.requiresRestore, true,
                       "journal 与事务原样保留，等补偿或退出（方案 §7.2）")
    }

    /// A18（方案 §5.5、§7.5）：会话取消后代次前进，异步 prepare 的迟到回执不得启动旧操作。
    func testLateJournalPreparedAfterSessionCancelStartsNoWrite() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        let slot = try XCTUnwrap(state.gridCell(for: a)?.cell.slot)
        let pending = Fixtures.dispatch(&state, .overviewCardSelected(identity: a, slot: slot,
                                                                     revision: state.layoutRevision))
        let request = try XCTUnwrap(prepareOnly(&state, pending))
        let epochBefore = state.sessionEpoch

        _ = dispatchConfirmed(&state, .globalShortcut)
        XCTAssertTrue(state.sessionEpoch > epochBefore, "取消屏障必须真的前进代次（方案 §5.1）")
        XCTAssertNil(state.workbench.armed, "取消时备料整套撤回")
        XCTAssertFalse(request.context.matches(sessionID: state.sessionID, epoch: state.sessionEpoch),
                       "旧上下文在新一代次里不再成立")

        let late = Fixtures.dispatch(&state, .journalPrepared(context: request.context))
        XCTAssertTrue(late.isEmpty, "旧代次的成功回执不得启动任何写入：\(late)")
        XCTAssertFalse(hasWorkbenchEnter(late))
        XCTAssertNotEqual(state.mode, .workbench, "迟到的落盘成功不能把工作台重新拉起来")
    }

    // MARK: - 跨屏恢复与替补/轨道不变量（方案 §18 A19–A21、A26–A33、A36）

    /// A19（方案 §8）：窗口被搬到另一块屏工作过，恢复落点仍是会话原屏，不是"它此刻在哪块屏"。
    func testCrossDisplayMoveRestoresOriginalDisplayNotCurrentOne() throws {
        let second = CGRect(x: 1_920, y: 0, width: 1_440, height: 900)
        let originalFrame = CGRect(x: 2_000, y: 100, width: 1_280, height: 700)
        let entry = WindowTransaction(sessionID: UUID(), identity: Fixtures.identity(500, 5_000),
                                      bundleID: "com.test.app", originalFrame: originalFrame,
                                      originalDisplayID: 2)
            .markingPlanned(frame: CGRect(x: 0, y: 100, width: 1_280, height: 700), displayID: 1)
            .markingVerified(readBack: CGRect(x: 0, y: 100, width: 1_280, height: 700), displayID: 1)

        let destination = try XCTUnwrap(RestorePlanner.plan(entry: entry,
                                                            originalDisplayIsLive: true,
                                                            originalVisibleFrame: second,
                                                            fallbackVisibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080)))
        XCTAssertEqual(destination.targetDisplayID, 2, "落屏必须认原屏，不认窗口现在所在的 1 屏")
        XCTAssertEqual(destination.targetFrame, originalFrame)
        XCTAssertEqual(destination.reason, .exactOnOriginalDisplay)
        XCTAssertFalse(destination.isDowngraded)
        let decision = RecoveryPlanner.decide(entry: entry,
                                              currentFrame: CGRect(x: 0, y: 100, width: 1_280, height: 700),
                                              liveness: .alive, destination: destination,
                                              preserveUserGeometry: false)
        XCTAssertEqual(decision, .restore(to: destination), "写过产品的位置：必须写回原屏原框")
    }

    /// A20（方案 §8）：原屏分辨率变化或整块消失时，给出合法回退目标与原因，且结算判定用同一个落点。
    func testOriginalDisplayResizeAndUnplugGiveLegalDowngradeWithMatchingSettlement() throws {
        let written = CGRect(x: 40, y: 40, width: 1_280, height: 700)
        let bigOriginal = CGRect(x: 100, y: 100, width: 1_600, height: 900)

        // (a) 原屏仍在但可用区变小：只在原屏内夹取。
        let shrunk = WindowTransaction(sessionID: UUID(), identity: Fixtures.identity(501, 5_001),
                                       bundleID: "com.test.app", originalFrame: bigOriginal,
                                       originalDisplayID: 1)
            .markingPlanned(frame: written, displayID: 1)
            .markingVerified(readBack: written, displayID: 1)
        let shrunkVisible = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let adjusted = try XCTUnwrap(RestorePlanner.plan(entry: shrunk, originalDisplayIsLive: true,
                                                         originalVisibleFrame: shrunkVisible,
                                                         fallbackVisibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                                                         fallbackDisplayID: 2))
        XCTAssertEqual(adjusted.targetDisplayID, 1, "原屏还在就仍回原屏")
        XCTAssertEqual(adjusted.reason, .adjustedOnOriginalDisplay)
        XCTAssertTrue(shrunkVisible.insetBy(dx: -0.5, dy: -0.5).contains(adjusted.targetFrame),
                      "夹取后必须整块落在新的可用区里：\(adjusted.targetFrame)")
        XCTAssertEqual(adjusted.targetFrame.size, CGSize(width: 1_440, height: 900),
                       "尺寸大于可用区时先缩到可用区内")
        let adjustedDecision = RecoveryPlanner.decide(entry: shrunk, currentFrame: written, liveness: .alive,
                                                      destination: adjusted, preserveUserGeometry: false)
        XCTAssertEqual(adjustedDecision, .restore(to: adjusted), "结算用的就是这一个落点")

        // (b) 原屏被拔除：只能落进有明确身份的备用屏。
        let unplugged = try XCTUnwrap(RestorePlanner.plan(entry: shrunk, originalDisplayIsLive: false,
                                                          originalVisibleFrame: nil,
                                                          fallbackVisibleFrame: shrunkVisible,
                                                          fallbackDisplayID: 7))
        XCTAssertEqual(unplugged.targetDisplayID, 7, "回退屏身份必须来自事实，不能猜")
        XCTAssertEqual(unplugged.reason, .originalDisplayUnavailable)
        XCTAssertTrue(unplugged.isDowngraded, "原屏没保住就是降级，报告不得写精确恢复")
        XCTAssertTrue(shrunkVisible.insetBy(dx: -0.5, dy: -0.5).contains(unplugged.targetFrame))
        XCTAssertEqual(RecoveryPlanner.decide(entry: shrunk, currentFrame: written, liveness: .alive,
                                             destination: unplugged, preserveUserGeometry: false),
                       .restore(to: unplugged))

        // (c) 没有任何合法备用区：宁可不写，也不把窗口丢到坐标 (0,0) 之外。
        XCTAssertNil(RestorePlanner.plan(entry: shrunk, originalDisplayIsLive: false,
                                        originalVisibleFrame: nil, fallbackVisibleFrame: nil))
    }

    /// A21（方案 §8 规则 4）：用户明确保留的位置按它自己的矩形选屏，不能夹到别的屏上。
    func testUserOverridePicksTheDisplayThatActuallyContainsIt() throws {
        let first = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let second = CGRect(x: 1_920, y: 0, width: 1_440, height: 900)
        let override = CGRect(x: 2_000, y: 120, width: 1_200, height: 700)
        let entry = WindowTransaction(sessionID: UUID(), identity: Fixtures.identity(502, 5_002),
                                      bundleID: "com.test.app",
                                      originalFrame: CGRect(x: 40, y: 40, width: 1_200, height: 700),
                                      originalDisplayID: 1)
            .markingPlanned(frame: CGRect(x: 0, y: 100, width: 1_200, height: 700), displayID: 1)
            .markingVerified(readBack: CGRect(x: 0, y: 100, width: 1_200, height: 700), displayID: 1)
            .withUserOverride(override)

        let destination = try XCTUnwrap(RestorePlanner.plan(entry: entry, originalDisplayIsLive: true,
                                                            originalVisibleFrame: first,
                                                            fallbackVisibleFrame: second,
                                                            fallbackDisplayID: 2))
        XCTAssertEqual(destination.targetDisplayID, 2, "override 整个矩形在 2 屏上，落屏就必须是 2")
        XCTAssertEqual(destination.targetFrame, override, "用户保留的位置一个坐标都不许重算")
        XCTAssertEqual(destination.reason, .overrideOnDisplay)
        XCTAssertEqual(entry.restoreTargetFrame(preserveUserGeometry: true), override,
                       "补偿/退出取的都是同一个 override")

        // override 不在任何已知屏内：与矩形相交最多的那块屏夹取，不夹错屏。
        // (3200,200) 起、宽 1000：只有副屏（x 1920…3360）与它相交，原屏相交为 0。
        let stray = CGRect(x: 3_200, y: 200, width: 1_000, height: 600)
        let strayed = try XCTUnwrap(RestorePlanner.plan(entry: entry.withUserOverride(stray),
                                                       originalDisplayIsLive: true,
                                                       originalVisibleFrame: first,
                                                       fallbackVisibleFrame: second,
                                                       fallbackDisplayID: 2))
        XCTAssertEqual(strayed.targetDisplayID, 2, "副屏与 stray 相交更多：必须选副屏，不能盲用目录里的 1 屏")
        XCTAssertTrue(second.insetBy(dx: -0.5, dy: -0.5).contains(strayed.targetFrame),
                      "夹取结果必须整块落在选中的屏里：\(strayed.targetFrame)")
    }

    /// A26（方案 §10）：关掉主窗口后的自动替补是一次完整操作——建事务→落盘→写入→激活→提交，
    /// 替补窗口没有历史事务也要走完整顺序，并从原 slot 移除。
    func testAutoPromotionAfterClosingMainRunsPrepareWriteActivateCommitInOrder() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        XCTAssertNil(state.transactions[b]?.lastProvisionalFrame)
        let bSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))
        XCTAssertEqual(state.workbench.placement.occupant(at: bSlot), b, "B 一开始就占着自己的格")

        let closed = Fixtures.dispatch(&state, .windowClosed(a))
        XCTAssertEqual(prepareRequests(closed).count, 1, "替补的写前事务必须先整批落盘")
        let request = try XCTUnwrap(prepareRequests(closed).first)
        XCTAssertEqual(request.context.kind, .promoteCandidate)
        XCTAssertFalse(hasSettleEffects(closed), "落盘确认之前一条 AX 都不许发")

        let released = confirmJournal(&state, closed)
        let plan = try XCTUnwrap(switchPlan(released))
        XCTAssertTrue(plan.intent.isPromotion)
        XCTAssertNil(plan.intent.from, "旧主已经关闭：替补没有 from")
        XCTAssertEqual(plan.intent.to, b)
        XCTAssertEqual(plan.mainTargetFrame, state.workbench.snapshot?.mainRect)

        completeSwitch(&state, token: plan.intent.token)
        XCTAssertEqual(state.workbench.placement.main, b, "替补提交后成为主窗口")
        XCTAssertNil(state.workbench.placement.slot(of: b), "提交必须同时把它从原 slot 移除")
        XCTAssertTrue(state.workbench.placement.maintainsInvariants)
        XCTAssertEqual(state.workbench.placement.members.count, 3)
    }

    /// A27（方案 §10、§18）：替补在日志/写入/激活任一环节失败，只要补偿事实把候选送回操作前位置，
    /// 结果都必须是「候选留 slot、主区空、还能手动选 C」——不能因为失败本身就把会话锁进 recoveryRequired。
    func testFailedPromotionLeavesCandidateInSlotAndKeepsMainSelectable() throws {
        // (a) 落盘失败：一次都不写，主区空、B 还在原格。
        var (s1, list1) = openState(count: 4)
        let b1 = list1[1].identity
        enterWorkbench(&s1, target: list1[0].identity)
        let bSlot1 = try XCTUnwrap(s1.workbench.placement.slot(of: b1))
        let closed1 = Fixtures.dispatch(&s1, .windowClosed(list1[0].identity))
        let request1 = try XCTUnwrap(prepareRequests(closed1).first)
        let failed1 = rejectPrepare(&s1, request1)
        XCTAssertFalse(hasSettleEffects(failed1), "落盘没成功就不许开始替补写入：\(failed1)")
        XCTAssertNil(s1.workbench.placement.main, "主区继续空")
        XCTAssertEqual(s1.workbench.placement.occupant(at: bSlot1), b1, "B 留在原 slot")
        XCTAssertNil(s1.workbench.recoveryRequired, "一次 AX 都没写，几何没有任何未知：不该要求恢复")
        XCTAssertTrue(s1.workbench.acceptsNewOrdinaryOperation, "还能再手动选别人")
        let manual1 = selectRail(&s1, identity: list1[2].identity)
        let manualPlan1 = try XCTUnwrap(switchPlan(manual1))
        completeSwitch(&s1, token: manualPlan1.intent.token)
        XCTAssertEqual(s1.workbench.placement.main, list1[2].identity, "手动选择 C 必须能真正接管主区")

        // (b) 写入阶段失败 + (c) 激活阶段失败：补偿按操作前事实回位后，同样收口成"主区空、可再选"。
        for kind in [WorkbenchSwitchStep.moveToMain, .activateMain] {
            var (state, list) = openState(count: 4)
            let b = list[1].identity
            enterWorkbench(&state, target: list[0].identity)
            let bSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))
            let closed = Fixtures.dispatch(&state, .windowClosed(list[0].identity))
            let plan = try XCTUnwrap(switchPlan(confirmJournal(&state, closed)))
            XCTAssertTrue(plan.intent.isPromotion)
            // B 从未被写过：操作前事实就是目录里的真实矩形，补偿回位按它核对。
            let before = try XCTUnwrap(plan.intent.beforeOperation.entry(for: b))
            XCTAssertEqual(before.compensationTarget, list[1].frame,
                           "候选没动过：补偿落点必须等于它此刻的真实位置")
            _ = dispatchConfirmed(&state, .mainSwitchStepFinished(WorkbenchSwitchStepResult(
                token: plan.intent.token, step: kind,
                outcome: .rejected("测试注入：\(kind) 失败"), identity: b)))
            let effects = reportSwitchFailure(&state, token: plan.intent.token,
                                              reason: "测试注入：\(kind) 失败",
                                              compensation: WorkbenchCompensationResult(
                                                  items: [WorkbenchCompensationResult.Item(
                                                    identity: b, action: .restoredTo(frame: list[1].frame),
                                                    displayID: nil)],
                                                  activatedMain: nil))
            XCTAssertFalse(hasSettleEffects(effects), "补偿之后不许再写：\(effects)")
            XCTAssertNil(state.workbench.placement.main, "替补不提交：主区还是空的")
            XCTAssertEqual(state.workbench.placement.occupant(at: bSlot), b, "B 回到并保持它的 slot")
            XCTAssertNil(state.workbench.recoveryRequired, "\(kind) 失败但事实齐全：几何没有未知")
            XCTAssertTrue(state.workbench.acceptsNewOrdinaryOperation)
            let manual = selectRail(&state, identity: list[2].identity)
            let manualPlan = try XCTUnwrap(switchPlan(manual))
            completeSwitch(&state, token: manualPlan.intent.token)
            XCTAssertEqual(state.workbench.placement.main, list[2].identity,
                           "\(kind) 失败后手动选 C 必须真正接管主区")
            // 归位不等于义务结清：B 的事务仍欠退出时的恢复（方案 §6.4）。
            XCTAssertEqual(state.transactions[b]?.state.requiresRestore, true)
        }

        // (d) 补偿自己也被拒绝：落点未知，必须转入 recoveryRequired 并拒绝新的普通操作（方案 §15）。
        var (s4, list4) = openState(count: 4)
        let b4 = list4[1].identity
        enterWorkbench(&s4, target: list4[0].identity)
        let closed4 = Fixtures.dispatch(&s4, .windowClosed(list4[0].identity))
        let plan4 = try XCTUnwrap(switchPlan(confirmJournal(&s4, closed4)))
        let refused = reportSwitchFailure(&s4, token: plan4.intent.token, reason: "测试注入：回位被拒",
                                          compensation: WorkbenchCompensationResult(
                                              items: [WorkbenchCompensationResult.Item(
                                                identity: b4, action: .refused(reason: "测试注入：AX 拒绝"),
                                                displayID: nil)],
                                              activatedMain: nil))
        XCTAssertNotNil(s4.workbench.recoveryRequired, "补偿失败就是几何不可信：\(refused)")
        let blocked = selectRail(&s4, identity: list4[2].identity)
        XCTAssertFalse(hasSettleEffects(blocked), "recoveryRequired 之下新的几何操作一律不准入：\(blocked)")
    }

    // MARK: - 操作前快照以宿主实读为准（方案 §6.2、§6.4、§9.1）

    /// 固定尺寸窗口的目录记录：不可调尺寸，可移动与否由调用方指定。
    private func fixedSizeRecord(_ pid: Int32,
                                 _ window: UInt32,
                                 frame: CGRect,
                                 movable: Bool,
                                 app: String = "FixedApp") -> WindowRecord {
        WindowRecord(identity: Fixtures.identity(pid, window),
                     bundleID: "com.test.fixed",
                     applicationName: app,
                     title: "固定尺寸窗口",
                     confidence: .unique(score: 0.9, axIndex: 0),
                     frame: frame,
                     displayID: 1,
                     isMovable: movable,
                     isResizable: false,
                     sessionGeneration: 1)
    }

    /// 第 4 条回归 (a)：计划期的 beforeOperation 已经过时（外部把 A 移动过），
    /// 补偿结果带着宿主写前实读的 beforeReads。判定必须以实读为准：A 回到真实操作前位置、不进 recoveryRequired。
    func testExternalMoveBeforeFailureCompensationUsesHostBeforeReads() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        let plan = try XCTUnwrap(switchPlan(selectRail(&state, identity: b)))
        let plannedBeforeA = try XCTUnwrap(plan.intent.beforeOperation.entry(for: a)).compensationTarget

        // 交换已放出写入，A 此刻的真实位置与计划期缓存不同（外部移动过）。
        let realBeforeA = CGRect(x: 430, y: 260, width: 880, height: 620)
        state.records[a]?.frame = realBeforeA
        XCTAssertFalse(WindowTransaction.framesClose(plannedBeforeA, realBeforeA, tolerance: 2),
                       "前提：计划期 before 必须与写前实读对不上，否则这条用例测不到真实判定")

        _ = reportSwitchFailure(&state, token: plan.intent.token,
                                reason: "测试注入：后半段写入失败",
                                compensation: WorkbenchCompensationResult(
                                  items: [WorkbenchCompensationResult.Item(
                                            identity: b, action: .restoredTo(frame: list[1].frame)),
                                          WorkbenchCompensationResult.Item(
                                            identity: a, action: .restoredTo(frame: realBeforeA))],
                                  activatedMain: a,
                                  beforeReads: [a: realBeforeA, b: list[1].frame]))
        XCTAssertNil(state.workbench.recoveryRequired,
                     "补偿已回到写前实读的真实位置：几何没有未知，不该要求恢复")
        if case .idle = state.workbench.mainSwitch {} else {
            XCTFail("补偿完整就必须收口成 idle，不能停在 failed/rollingBack：\(state.workbench.mainSwitch)")
        }
        XCTAssertEqual(state.workbench.placement.main, a, "交换未提交：A 仍是主窗口")
        XCTAssertEqual(state.phase, .focused(target: a))
        XCTAssertTrue(state.workbench.acceptsNewOrdinaryOperation, "不误报失败结论：用户还能继续操作")
        XCTAssertEqual(state.transactions[a]?.lastProvisionalFrame, realBeforeA,
                       "补偿事实要按真实写前位置落盘，不能按过时的计划值")
        XCTAssertEqual(state.transactions[b]?.lastProvisionalFrame, list[1].frame)
    }

    /// 第 4 条回归 (b)：同样的外部移动，但补偿结果没有 beforeReads（宿主未回报实读）。
    /// 这是旧回退路径：仍按计划期落点判定，对不上就必须进 recoveryRequired——行为不许被放宽。
    func testExternalMoveBeforeFailureWithoutBeforeReadsStillRequiresRecovery() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        let plan = try XCTUnwrap(switchPlan(selectRail(&state, identity: b)))
        let plannedBeforeA = try XCTUnwrap(plan.intent.beforeOperation.entry(for: a)).compensationTarget
        let realBeforeA = CGRect(x: 430, y: 260, width: 880, height: 620)
        state.records[a]?.frame = realBeforeA
        XCTAssertFalse(WindowTransaction.framesClose(plannedBeforeA, realBeforeA, tolerance: 2))

        _ = reportSwitchFailure(&state, token: plan.intent.token,
                                reason: "测试注入：后半段写入失败",
                                compensation: WorkbenchCompensationResult(
                                  items: [WorkbenchCompensationResult.Item(
                                            identity: b, action: .restoredTo(frame: list[1].frame)),
                                          WorkbenchCompensationResult.Item(
                                            identity: a, action: .restoredTo(frame: realBeforeA))],
                                  activatedMain: a))
        XCTAssertNotNil(state.workbench.recoveryRequired,
                        "没有宿主实读事实时只能按旧回退判定：对不上就必须显式要求恢复")
        XCTAssertFalse(state.workbench.acceptsNewOrdinaryOperation)
    }

    /// 第 4 条回归 (e)：解除过的最小化没能收回来时，补偿事实不完整——即便几何与焦点都"看起来对"，
    /// 状态机也不能宣称回滚完成（方案 §6.4、§10.1）。
    func testUnrecoveredMinimizeRestorationForcesRecoveryRequired() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        let b = list[1].identity
        enterWorkbench(&state, target: a)
        let plan = try XCTUnwrap(switchPlan(selectRail(&state, identity: b)))
        let beforeA = try XCTUnwrap(plan.intent.beforeOperation.entry(for: a)).compensationTarget
        let beforeB = try XCTUnwrap(plan.intent.beforeOperation.entry(for: b)).compensationTarget

        let effects = reportSwitchFailure(&state, token: plan.intent.token,
                                          reason: "测试注入：后半段失败",
                                          compensation: WorkbenchCompensationResult(
                                            items: [WorkbenchCompensationResult.Item(
                                                      identity: a, action: .restoredTo(frame: beforeA)),
                                                    WorkbenchCompensationResult.Item(
                                                      identity: b, action: .restoredTo(frame: beforeB))],
                                            activatedMain: a,
                                            unresolvedMinimizeRestorations: [b]))
        XCTAssertNotNil(state.workbench.recoveryRequired,
                        "最小化没恢复＝真实系统状态不一致，不能按回滚成功收口：\(effects)")
        XCTAssertFalse(state.workbench.acceptsNewOrdinaryOperation)
    }

    /// 第 4 条回归 (c)：缓存 frame 过大但窗口可移动、主区有效——缓存只当乐观预检，
    /// 进入与交换都要产生计划并交给宿主用写前实读重新决策，而不是立即给受限提示。
    func testOversizedCachedFrameDefersToHostBeforeReadForMovableWindow() throws {
        // 进入：固定尺寸窗口的缓存 frame 比主区大，但它可移动，真实尺寸可能放得下。
        var entering = Fixtures.state(withCount: 0)
        let oversized = fixedSizeRecord(900, 9_001,
                                        frame: CGRect(x: 80, y: 80, width: 2_400, height: 1_600),
                                        movable: true)
        Fixtures.openToOverview(&entering, records: [oversized])
        let enterEffects = select(&entering, fromOverview: oversized.identity)
        let enter = try XCTUnwrap(enterPlan(enterEffects), "可移动窗口不该被缓存尺寸提前拒绝")
        let enterMainRect = enter.snapshot.layout.mainRect
        XCTAssertEqual(enter.targetFrame, enterMainRect, "临时计划目标取主区矩形")
        XCTAssertEqual(enter.placement, .resizeAndMove(target: enterMainRect),
                       "计划里的放置方式不能撒谎成 unavailable")
        XCTAssertFalse(hints(enterEffects).contains { if case .restrictedWindow = $0 { return true } else { return false } },
                       "不该出现提前拒绝的受限提示：\(hints(enterEffects))")
        finishEntering(&entering)
        XCTAssertEqual(entering.mode, .workbench, "交给宿主重新决策后仍应正常进入工作台")
        XCTAssertEqual(entering.workbench.placement.main, oversized.identity)

        // 交换：B 的缓存 frame 过大但可移动，同样要产生计划而不是立即给 workbenchMainFrameFailed。
        var swapping = Fixtures.state(withCount: 0)
        let a = Fixtures.record(910, 9_101,
                                frame: CGRect(x: 40, y: 40, width: 1_280, height: 800),
                                app: "AppA")
        let b = fixedSizeRecord(911, 9_102,
                                frame: CGRect(x: 60, y: 60, width: 2_400, height: 1_600),
                                movable: true)
        Fixtures.openToOverview(&swapping, records: [a, b])
        enterWorkbench(&swapping, target: a.identity)
        let switchEffects = selectRail(&swapping, identity: b.identity)
        let swap = try XCTUnwrap(switchPlan(switchEffects), "可移动窗口不该被缓存尺寸提前拒绝交换")
        let swapMainRect = swap.snapshot.layout.mainRect
        XCTAssertEqual(swap.mainTargetFrame, swapMainRect, "交换的临时计划目标取主区矩形")
        XCTAssertEqual(swap.placement, .resizeAndMove(target: swapMainRect))
        XCTAssertFalse(hints(switchEffects).contains {
            if case .workbenchMainFrameFailed = $0 { return true } else { return false }
        }, "不该出现提前拒绝的主区提示：\(hints(switchEffects))")
        XCTAssertEqual(swapping.workbench.placement.main, a.identity, "计划不等于提交：A 还在主区")
    }

    /// 第 4 条回归 (d)：不可移动窗口的缓存结论就是硬事实——仍然立即提示、零几何/日志效果。
    func testOversizedCachedFrameStillRejectsImmovableWindow() {
        var state = Fixtures.state(withCount: 0)
        let immovable = fixedSizeRecord(920, 9_201,
                                        frame: CGRect(x: 80, y: 80, width: 2_400, height: 1_600),
                                        movable: false)
        Fixtures.openToOverview(&state, records: [immovable])
        let effects = select(&state, fromOverview: immovable.identity)
        XCTAssertNil(enterPlan(effects), "不可移动的固定尺寸窗口放不下就是放不下，不许起步")
        XCTAssertEqual(effects.count, 1, "除了一句提示之外不许有日志/几何效果：\(effects)")
        guard case let .presentHint(.restrictedWindow(reason)) = effects[0] else {
            XCTFail("必须是受限提示：\(effects)")
            return
        }
        XCTAssertFalse(reason.isEmpty, "拒绝必须说清原因")
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.modeTransition.token, "没有产生过渡，也没有留下悬空令牌")
        XCTAssertNil(state.workbench.armed)
        XCTAssertTrue(state.transactions.isEmpty, "一次 AX 都没写：不该有几何事务")
    }

    /// A28（方案 §10、§15）：自动替补还在落盘时用户点了 C——最新手动意图生效，不出现两条并发通道。
    func testManualSelectionDuringPromotionArmingWins() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity, b = list[1].identity, c = list[2].identity
        enterWorkbench(&state, target: a)
        let bSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))
        let closed = Fixtures.dispatch(&state, .windowClosed(a))
        let promotion = try XCTUnwrap(prepareRequests(closed).first)
        XCTAssertEqual(promotion.context.kind, .promoteCandidate)
        XCTAssertNotNil(state.workbench.armed, "替补正等着落盘确认")

        let manualEffects = selectRail(&state, identity: c)
        let manualPlan = try XCTUnwrap(switchPlan(manualEffects))
        XCTAssertEqual(manualPlan.intent.to, c, "后到的手动选择优先：还没写入的自动替补让位")
        XCTAssertNotNil(state.workbench.placement.slot(of: b), "让位期间 B 一步都没被写过")
        completeSwitch(&state, token: manualPlan.intent.token)
        XCTAssertEqual(state.workbench.placement.main, c)
        XCTAssertEqual(state.workbench.placement.occupant(at: bSlot), b, "让位不等于搬家：B 一直没动")
        XCTAssertNil(state.workbench.pendingRailSelection, "最新意图已经落地，不许留下排队")

        // 迟到的替补落盘回执必须整体作废，不能再启一次写入。
        let late = Fixtures.dispatch(&state, .journalPrepared(context: promotion.context))
        XCTAssertTrue(late.isEmpty, "旧操作上下文的成功回执不得启动任何写入：\(late)")
        XCTAssertEqual(state.workbench.placement.main, c)

        // 另一半（方案 §10 第 291 行）：替补已经放出写入通道，这时点 C —— B 先收敛，再执行最新手动选择。
        var (s2, list2) = openState(count: 4)
        enterWorkbench(&s2, target: list2[0].identity)
        let released = Fixtures.dispatch(&s2, .windowClosed(list2[0].identity))
        let promotion2 = try XCTUnwrap(prepareRequests(released).first)
        let releasedEffects = confirmJournal(&s2, [ .prepareJournal(promotion2) ])
        let promotionPlan = try XCTUnwrap(switchPlan(releasedEffects))
        XCTAssertTrue(s2.workbench.mainSwitch.isBusy, "替补已进入写入通道")
        let queued = selectRail(&s2, identity: list2[2].identity)
        XCTAssertTrue(queued.isEmpty, "已写过的 B 不许被顶掉：这一笔只能排队，不能开第二条通道：\(queued)")
        XCTAssertEqual(s2.workbench.pendingRailSelection?.identity, list2[2].identity, "只保留最新目标")
        let converged = completeSwitch(&s2, token: promotionPlan.intent.token)
        let followUp = try XCTUnwrap(switchPlan(converged))
        XCTAssertEqual(followUp.intent.to, list2[2].identity, "B 收敛后立刻执行等着的手动选择")
        XCTAssertNil(s2.workbench.pendingRailSelection, "队列必须被消费掉，不许无限排队")
        completeSwitch(&s2, token: followUp.intent.token)
        XCTAssertEqual(s2.workbench.placement.main, list2[2].identity)
    }

    /// A29（方案 §6.2、§10.2）：总览格子已经排满时新增的窗口没有 gridCell，
    /// 但仍要进 L 型尾部，其他位置一律不动。
    func testWindowBeyondGridCapacityStillEntersRailTail() throws {
        var (state, list) = openState(count: 5)
        enterWorkbench(&state, target: list[0].identity)
        let capacity = state.slots.capacity
        XCTAssertGreaterThan(capacity, 5, "夹具屏幕至少要有可用的格子")
        let before = state.workbench.placement.occupants
        // 把总览格子填满，再多出来的窗口就没有 gridCell。
        var extra = list
        for index in 0..<(capacity + 3) {
            extra.append(Fixtures.record(Int32(1_000 + index), UInt32(20_000 + index),
                                         frame: CGRect(x: 60, y: 60, width: 1_280, height: 800),
                                         title: "溢出 \(index)", app: "Overflow\(index)",
                                         puid: UInt64(20_000 + index)))
        }
        try updateCatalog(&state, records: extra)

        let overflowed = extra.last!.identity
        XCTAssertNil(state.gridCell(for: overflowed), "格子满了就是满了：不能谎报一个 gridCell")
        let slot = try XCTUnwrap(state.workbench.placement.slot(of: overflowed),
                                 "没有格子的窗口也必须进 L 型，不能悄悄隐藏")
        let maxOrdinal = before.keys.filter { $0.rail == slot.rail }.map(\.ordinal).max() ?? 0
        let appendedCount = state.workbench.placement.occupants.count
        XCTAssertGreaterThanOrEqual(slot.ordinal, maxOrdinal, "溢出只落在轨道尾部")
        XCTAssertEqual(state.workbench.placement.main, list[0].identity, "新窗口不得抢主")
        for (occupiedSlot, identity) in before {
            XCTAssertEqual(state.workbench.placement.occupant(at: occupiedSlot), identity,
                           "已有占用不得因为新增而重排")
        }
        XCTAssertEqual(appendedCount, before.count + capacity + 3,
                       "新增的每一个窗口都要有归属：一个都不许悄悄丢掉")
        XCTAssertTrue(state.workbench.placement.maintainsInvariants)
    }

    /// A30（方案 §6.2）：标题更新、目录顺序变化都只是展示事实，绝不能搬动已占位的窗口。
    func testTitleUpdateAndCatalogReorderNeverMoveOccupants() throws {
        var (state, list) = openState(count: 6)
        enterWorkbench(&state, target: list[0].identity)
        let before = state.workbench.placement.occupants

        let renamed = list.map { record -> WindowRecord in
            var copy = record
            copy.title = "改名 \(record.identity.windowID)"
            return copy
        }
        try updateCatalog(&state, records: Array(renamed.reversed()))
        let after = state.workbench.placement.occupants
        XCTAssertEqual(after.count, before.count)
        for (slot, identity) in before {
            XCTAssertEqual(after[slot], identity, "标题/顺序变化不得搬动 occupant")
        }
        XCTAssertEqual(state.workbench.placement.main, list[0].identity)
        XCTAssertEqual(state.records[list[0].identity]?.title, "改名 \(list[0].identity.windowID)",
                       "标题事实要真的更新，否则这条断言只是空转")
    }

    /// A31（方案 §12）：滚动偏移的唯一来源是投影——返回总览再选回原 A，上次离开时的非零偏移还在。
    /// 顶栏容量按 floor 恰好容得下自己的卡片（WorkbenchLayoutEngine.capacity），可滚内容恒为 0：
    /// 溢出全部落在侧栏滚动轨道，所以"非零偏移保留"这一条只能由侧栏证明。
    func testScrollOffsetsSurviveReturnAndReentry() throws {
        var (state, list) = openState(count: 24)
        enterWorkbench(&state, target: list[0].identity)
        let snapshot = try XCTUnwrap(state.workbench.snapshot)
        XCTAssertGreaterThan(snapshot.layout.maxSideScroll, 0, "24 窗时侧栏必须真的可滚动")
        XCTAssertEqual(snapshot.layout.maxTopScroll, 0, "顶栏没有超出视口的内容：它本来就不该能滚")
        _ = Fixtures.dispatch(&state, .railScrolled(rail: .top, offset: 80))
        XCTAssertEqual(state.workbench.scrollOffset(rail: .top), 0, "越界偏移按合法范围 clamp，不许写进投影")
        _ = Fixtures.dispatch(&state, .railScrolled(rail: .side, offset: 120))
        XCTAssertEqual(state.workbench.scrollOffset(rail: .side), 120)

        try returnToOverview(&state)
        XCTAssertEqual(state.mode, .overview)
        enterWorkbench(&state, target: list[0].identity)
        XCTAssertEqual(state.workbench.scrollOffset(rail: .side), 120, "返回再进入必须带回上次离开的偏移")
        XCTAssertEqual(state.workbench.snapshot?.sideScrollOffset, 120, "偏移仍然只有投影这一个来源")

        // 内容变少后重入：带回来的偏移按新布局 clamp，不出现悬空的滚动位置。
        let trimmed = Array(list.dropLast(20))
        try updateCatalog(&state, records: trimmed)
        try returnToOverview(&state)
        enterWorkbench(&state, target: trimmed[0].identity)
        let clamped = state.workbench.scrollOffset(rail: .side)
        let reentered = try XCTUnwrap(state.workbench.snapshot)
        XCTAssertLessThanOrEqual(clamped, reentered.layout.maxSideScroll)
        XCTAssertGreaterThanOrEqual(clamped, 0)
    }

    /// A32（方案 §8、§12）：返回总览后选轨道里的 B——A/B 正确交换，滚动偏移一位不动。
    func testRailSelectionAfterReturnSwapsAndKeepsOffsets() throws {
        var (state, list) = openState(count: 20)
        let a = list[0].identity, b = list[1].identity
        enterWorkbench(&state, target: a)
        _ = Fixtures.dispatch(&state, .railScrolled(rail: .side, offset: 90))
        try returnToOverview(&state)
        enterWorkbench(&state, target: a)
        let bSlot = try XCTUnwrap(state.workbench.placement.slot(of: b))
        let sideOffset = state.workbench.scrollOffset(rail: .side)
        XCTAssertGreaterThan(sideOffset, 0, "重进入后侧栏应带着非零偏移")

        let effects = selectRail(&state, identity: b)
        let plan = try XCTUnwrap(switchPlan(effects))
        completeSwitch(&state, token: plan.intent.token)
        XCTAssertEqual(state.workbench.placement.main, b, "B 进主区")
        XCTAssertEqual(state.workbench.placement.occupant(at: bSlot), a, "A 回到 B 原来的格")
        XCTAssertEqual(state.workbench.scrollOffset(rail: .side), sideOffset, "交换不重置侧栏偏移")
    }

    /// A33（方案 §11.2）：内容变少或栏尺寸被拖出范围时，只按合法范围 clamp，不产生负主区。
    func testRailSizeAndContentShrinkClampToLegalRange() throws {
        var (state, list) = openState(count: 4)
        enterWorkbench(&state, target: list[0].identity)
        _ = dispatchConfirmed(&state, .workbenchRailSizeChanged(topHeight: 150, sideWidth: 240))
        let style = WorkbenchStyle()
        let clamped = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(clamped.topRailRect.height, min(150, style.topHeightRange.upperBound), accuracy: 0.001)
        XCTAssertEqual(clamped.sideRailRect.width, min(240, style.sideWidthRange.upperBound), accuracy: 0.001)

        // 拖出上下界：投影只到边界为止。
        _ = dispatchConfirmed(&state, .workbenchRailSizeChanged(topHeight: -500, sideWidth: 9_999))
        let bounded = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(bounded.topRailRect.height, style.topHeightRange.lowerBound, accuracy: 0.001,
                       "负值 clamp 到下界，不能把顶栏拖没")
        XCTAssertEqual(bounded.sideRailRect.width, style.sideWidthRange.upperBound, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(bounded.mainRect.width, style.minimumMainSize.width)
        XCTAssertGreaterThanOrEqual(bounded.mainRect.height, style.minimumMainSize.height)
        XCTAssertFalse(bounded.isDegenerate)

        // 内容关闭到只剩主窗口：布局投影仍合法，两栏尺寸不变。
        for record in list.dropFirst() {
            _ = Fixtures.dispatch(&state, .windowClosed(record.identity))
        }
        let afterClose = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(afterClose.topRailRect.height, bounded.topRailRect.height, accuracy: 0.001,
                       "关闭内容不重算栏尺寸偏好")
        XCTAssertFalse(afterClose.isDegenerate)
        XCTAssertTrue(state.workbench.placement.maintainsInvariants)
    }

    /// A36（方案 §13.2）：过渡进行中的尺寸更新一律延后，不留半套重配；
    /// 延后的那一次在过渡收敛时真的落地；取消/停止仍然立即生效。
    func testSizeUpdateDuringTransitionDefersReconfigurationAndCancelIsImmediate() throws {
        var (state, list) = openState(count: 4)
        let a = list[0].identity
        _ = select(&state, fromOverview: a)
        XCTAssertTrue(state.workbench.modeTransition.isTransitioning, "进入过渡在途")
        let snapshotBefore = try XCTUnwrap(state.workbench.snapshot)

        let deferred = Fixtures.dispatch(&state, .workbenchRailSizeChanged(topHeight: 160, sideWidth: 248))
        XCTAssertTrue(deferred.isEmpty, "过渡中不接受栏尺寸落地：\(deferred)")
        XCTAssertEqual(state.workbench.snapshot, snapshotBefore, "投影一个字节都不许变")
        XCTAssertTrue(state.workbench.railSizeRecomputePending, "延后不等于丢掉：这一笔要攒着等收敛")
        XCTAssertFalse(state.workbench.acceptsNewOrdinaryOperation, "过渡期间普通几何操作一律不准入")

        // 过渡收敛：攒下的尺寸在这一次算清，主区跟着新 mainRect 走。
        let converged = finishEntering(&state)
        XCTAssertFalse(state.workbench.railSizeRecomputePending, "攒下的重配必须被消费掉")
        let style = WorkbenchStyle()
        let afterConverge = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertEqual(afterConverge.topRailRect.height, min(160, style.topHeightRange.upperBound), accuracy: 0.001,
                       "延后的尺寸在收敛这一刻落地，不是丢掉")
        let settle = try XCTUnwrap(settlePackets(converged).first,
                                   "新 mainRect 要按日志闸门先落盘再写：\(converged)")
        XCTAssertEqual(settle.target, afterConverge.mainRect, "落地写的就是收敛后的新主区矩形")
        XCTAssertEqual(settle.identity, a)

        // 取消/停止不等过渡收敛：立即排空在途操作并前进代次。
        let epochBefore = state.sessionEpoch
        let cancelled = dispatchConfirmed(&state, .displaysChanged)
        XCTAssertTrue(state.sessionEpoch > epochBefore, "取消屏障立即前进代次（方案 §5.1）")
        XCTAssertNil(state.workbench.armed)
        XCTAssertNil(state.workbench.activeContext)
        XCTAssertTrue(state.gridsAreStale, "屏幕集合变了，旧的冻结几何不再适用")
        XCTAssertTrue(cancelled.contains { if case .hideWorkbench = $0 { return true } else { return false } },
                      "过渡中的尺寸变化要立刻撤下面板：\(cancelled)")
        XCTAssertTrue(state.workbench.transitionActivity.cancellationRequested,
                      "取消标记当场生效，宿主据此拆掉飞行中的过渡")
    }

    // MARK: - 随机序列不变量（方案 §18 A42）

    /// 一轮随机动作：做了什么、发出了哪些 effect。
    private struct RandomAction {
        let label: String
        let effects: [SessionEffect]
    }

    /// 成功交换与往返的组合循环必须始终保持：placement 唯一、无漏窗、无 busy 悬挂、
    /// 无未解释的恢复义务（方案 §18 A42）。失败时打印种子与完整动作序列，保证可原样复现。
    func testRandomOperationSequencePreservesInvariants() {
        let seed: UInt64 = 0x5EED_2026
        var rng = SeededGenerator(seed: seed)
        var (state, list) = openState(count: 12)
        let entering = enterWorkbench(&state, target: list[0].identity)
        XCTAssertEqual(state.mode, .workbench)

        // 宿主侧日志模型：effect 里每一条落盘动作都如实回放。
        var journal = SessionJournal(sessionID: state.sessionID)
        var written: [WindowIdentity] = []
        foldJournal(&journal, written: &written, from: entering, sessionID: state.sessionID)

        var actions: [String] = []
        for step in 0..<200 {
            let action: RandomAction
            switch Int.random(in: 0..<8, using: &rng) {
            case 0: action = selectRandomRailOccupant(&state, rng: &rng)
            case 1: action = settlePendingWork(&state)
            case 2: action = dragRandomSlots(&state, rng: &rng)
            case 3: action = scrollRandomRail(&state, rng: &rng)
            case 4: action = closeRandomOccupant(&state, rng: &rng)
            case 5: action = appendRandomWindow(&state, list: list, rng: &rng)
            case 6: action = changeRailSide(&state, rng: &rng)
            default: action = roundTripMode(&state, list: list, rng: &rng)
            }
            actions.append("  step\(step): \(action.label)")
            foldJournal(&journal, written: &written, from: action.effects, sessionID: state.sessionID)
            let violations = workbenchInvariantViolations(state, step: step, journal: journal, written: written)
            if !violations.isEmpty {
                XCTFail("不变量被破坏，可原样复现：seed=0x5EED_2026，停在第 \(step) 步\n"
                        + violations.joined(separator: "\n") + "\n"
                        + "动作序列：\n" + actions.joined(separator: "\n"))
                return
            }
        }
    }

    private func workbenchInvariantViolations(_ state: SessionState,
                                              step: Int,
                                              journal: SessionJournal,
                                              written: [WindowIdentity]) -> [String] {
        var violations: [String] = []
        let placement = state.workbench.placement
        let values = Array(placement.occupants.values)
        if !placement.maintainsInvariants { violations.append("第 \(step) 步不变量被破坏") }
        if Set(values).count != values.count { violations.append("第 \(step) 步出现重复占用") }
        if let main = placement.main, values.contains(main) {
            violations.append("第 \(step) 步主窗口同时出现在轨道上")
        }
        if !placement.members.isSubset(of: Set(state.records.keys)) {
            violations.append("第 \(step) 步轨道上出现已关闭窗口")
        }
        if placement.members.count > state.records.count {
            violations.append("第 \(step) 步成员数超出目录")
        }
        // 冻结格子的容量是硬上限：目录装得下时，主窗口必须有格子（返回总览要有落点）；
        // 装不下时 Core 允许"排队等待格"的窗口进轨道/主区，此时只要求它仍在目录里。
        if let main = placement.main, state.records.count <= state.gridCapacity,
           state.gridCell(for: main) == nil {
            violations.append("第 \(step) 步主窗口没有冻结格子（目录 \(state.records.count) 格子上限 \(state.gridCapacity)）")
        }
        for (slot, identity) in placement.occupants {
            guard let cell = state.gridCell(for: identity) else { continue }
            if cell.cell.identity != nil, cell.cell.identity != identity {
                violations.append("第 \(step) 步轨道 \(slot) 与网格指向了不同窗口")
            }
        }

        // A42 新增：任何一次真实写入都必须留下恢复义务——内存有义务、日志也在，
        // 且义务带着可核对的几何事实（写过却什么都没有 = 退出时无法复原）。
        for identity in written where state.records[identity] != nil {
            guard let transaction = state.transactions[identity] else {
                violations.append("第 \(step) 步 \(identity.journalKey) 真实写入后失去恢复义务")
                continue
            }
            if !transaction.state.requiresRestore {
                violations.append("第 \(step) 步 \(identity.journalKey) 写过但事务不再要求恢复")
            }
            if transaction.writtenFrameCandidates.isEmpty {
                violations.append("第 \(step) 步 \(identity.journalKey) 事务里没有任何几何事实")
            }
            guard let entry = journal.entries[identity.journalKey] else {
                violations.append("第 \(step) 步 \(identity.journalKey) 内存有义务但日志条目缺失")
                continue
            }
            if !entry.state.requiresRestore {
                violations.append("第 \(step) 步 \(identity.journalKey) 日志条目不再要求恢复，内存却仍视为已写入")
            }
        }

        // 未落盘的事务从不进内存（方案 §7.1）。
        if let armed = state.workbench.armed {
            for identity in armed.transactions.keys
            where state.transactions[identity]?.operationID == armed.context.operationID {
                violations.append("第 \(step) 步 \(identity.journalKey) 还没落盘就进了内存")
            }
        }
        // 在途操作必须自带补偿依据：写过但没有 before 事实，只能靠 recoveryRequired 兜住（方案 §6.4）。
        if let operation = state.workbench.runningOperation {
            if operation.hasUnexplainedWrite {
                violations.append("第 \(step) 步操作 \(operation.context.kind.rawValue) 有写入缺恢复依据")
            }
            for identity in operation.writtenOrder {
                guard let entry = operation.entry(for: identity), entry.didWrite else { continue }
                if state.transactions[identity]?.state.requiresRestore != true {
                    violations.append("第 \(step) 步 \(identity.journalKey) 本次操作写过却没有待恢复事务")
                }
            }
        }
        // 无 busy 悬挂：操作上下文收口时写入事实必须一起收口。
        if state.workbench.activeContext == nil, state.workbench.runningOperation != nil {
            violations.append("第 \(step) 步操作已收口但写入事实仍挂在状态上")
        }
        if state.workbench.armed == nil, state.workbench.activeContext == nil,
           state.workbench.mainFrameWrite != nil {
            violations.append("第 \(step) 步没有在途操作却留着主区写入标记")
        }
        if state.workbench.recoveryRequired == nil {
            XCTAssertFalse(state.workbench.transitionActivity.blocksGeometryReconfiguration
                            != (state.workbench.armed != nil
                                || state.workbench.modeTransition.isTransitioning
                                || state.workbench.mainSwitch.isBusy
                                || state.workbench.mainFrameWrite != nil),
                           "第 \(step) 步过渡活动事实与状态脱节")
        }
        return violations
    }

    /// 把 effect 里的落盘动作回放进测试侧日志模型，并维护"写过但还没结算"的身份清单。
    private func foldJournal(_ journal: inout SessionJournal,
                             written: inout [WindowIdentity],
                             from effects: [SessionEffect],
                             sessionID: UUID) {
        for effect in effects {
            switch effect {
            case let .prepareJournal(request):
                applyMutations(request.mutations, to: &journal, written: &written)
            case let .updateJournal(request):
                applyMutations([request.mutation], to: &journal, written: &written)
            case let .clearJournal(_, settled):
                journal.prune(sessionID: sessionID, settledIdentities: settled)
                // 结算＝恢复义务已完成并写回原位：不再要求"仍留有义务"。
                written.removeAll { settled.contains($0) }
            default:
                break
            }
        }
    }

    private func applyMutations(_ mutations: [JournalMutation],
                                to journal: inout SessionJournal,
                                written: inout [WindowIdentity]) {
        for mutation in mutations {
            switch mutation {
            case let .upsert(transaction):
                journal.apply(transaction)
                if transaction.lastProvisionalFrame != nil, !written.contains(transaction.identity) {
                    written.append(transaction.identity)
                }
            case let .remove(identity):
                journal.remove(identity)
                written.removeAll { $0 == identity }
            case let .correctOriginal(identity, frame, displayID):
                journal.correctOriginal(identity, frame: frame, displayID: displayID)
            }
        }
    }

    private func selectRandomRailOccupant(_ state: inout SessionState, rng: inout SeededGenerator) -> RandomAction {
        let candidates = state.workbench.placement.occupants
            .filter { $0.value != state.workbench.placement.main }
            .sorted { $0.key < $1.key }
        guard !candidates.isEmpty else { return RandomAction(label: "无轨道候选", effects: []) }
        let pick = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        return RandomAction(label: "选轨道卡片 w\(pick.value.windowID)",
                            effects: selectRail(&state, identity: pick.value))
    }

    /// 宿主会做的事：把还没收口的写入/交换收口（读回成功），别让它们永远悬着。
    private func settlePendingWork(_ state: inout SessionState) -> RandomAction {
        var effects: [SessionEffect] = []
        var label = "无待收口"
        if let write = state.workbench.mainFrameWrite,
           let planned = state.transactions[write.identity]?.plannedFrame {
            label = "主区写入读回 w\(write.identity.windowID)"
            effects += dispatchConfirmed(&state, Fixtures.writeResult(write.identity, token: write.token,
                                                                      outcome: .exact(readBack: planned),
                                                                      target: planned))
        }
        if let token = state.workbench.mainSwitch.intent?.token, state.workbench.mainSwitch.isBusy {
            label = "完成交换 t\(token.generation)"
            effects += completeSwitchWithReadBack(&state, token: token)
        }
        return RandomAction(label: label, effects: effects)
    }

    /// 带读回地走完交换的每一步：这样"写过"是真实事实，不变量才有的可查。
    private func completeSwitchWithReadBack(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        guard let intent = state.workbench.mainSwitch.intent else { return [] }
        var effects: [SessionEffect] = []
        for step in WorkbenchSwitchStep.allCases {
            let identity: WindowIdentity?
            let outcome: WorkbenchStepOutcome
            switch step {
            case .prepare:
                identity = nil
                outcome = .succeeded(readBack: nil)
            case .moveToMain:
                identity = intent.to
                outcome = .succeeded(readBack: state.transactions[intent.to]?.plannedFrame)
            case .restorePrevious:
                identity = intent.from
                outcome = .succeeded(readBack: intent.from.flatMap { state.transactions[$0]?.plannedFrame })
            case .activateMain, .commit:
                identity = nil
                outcome = .succeeded(readBack: nil)
            }
            effects += dispatchConfirmed(&state, .mainSwitchStepFinished(
                WorkbenchSwitchStepResult(token: token, step: step, outcome: outcome, identity: identity)))
        }
        effects += dispatchConfirmed(&state, .mainSwitchCommitted(token: token))
        return effects
    }

    private func dragRandomSlots(_ state: inout SessionState, rng: inout SeededGenerator) -> RandomAction {
        let slots = state.workbench.snapshot?.layout.slotOrder ?? []
        guard slots.count > 1 else { return RandomAction(label: "无可拖动 slot", effects: []) }
        let from = slots[Int.random(in: 0..<slots.count, using: &rng)]
        let to = slots[Int.random(in: 0..<slots.count, using: &rng)]
        return RandomAction(label: "拖动 \(from)→\(to)",
                            effects: Fixtures.dispatch(&state, .railCardDragged(from: from, to: to)))
    }

    private func scrollRandomRail(_ state: inout SessionState, rng: inout SeededGenerator) -> RandomAction {
        let offset = CGFloat(Int.random(in: 0...400, using: &rng))
        return RandomAction(label: "滚动 \(offset)",
                            effects: Fixtures.dispatch(&state, .railScrolled(rail: .side, offset: offset)))
    }

    private func closeRandomOccupant(_ state: inout SessionState, rng: inout SeededGenerator) -> RandomAction {
        let occupants = state.workbench.placement.occupants.values
            .filter { $0 != state.workbench.placement.main }
            .sorted { $0.windowID < $1.windowID }
        guard !occupants.isEmpty else { return RandomAction(label: "无轨道窗口可关", effects: []) }
        let closing = occupants[Int.random(in: 0..<occupants.count, using: &rng)]
        return RandomAction(label: "关闭 w\(closing.windowID)",
                            effects: dispatchConfirmed(&state, .windowClosed(closing)))
    }

    private func changeRailSide(_ state: inout SessionState, rng: inout SeededGenerator) -> RandomAction {
        let side: RailSide = Bool.random(using: &rng) ? .left : .right
        return RandomAction(label: "换侧 \(side.displayName)",
                            effects: dispatchConfirmed(&state, .railSideChanged(side)))
    }

    private func appendRandomWindow(_ state: inout SessionState,
                                    list: [WindowRecord],
                                    rng: inout SeededGenerator) -> RandomAction {
        guard state.mode == .workbench else { return RandomAction(label: "总览态不新增", effects: []) }
        let index = Int.random(in: 0..<10_000, using: &rng)
        let extra = Fixtures.record(800 + Int32(index % 50), UInt32(20_000 + index),
                                    frame: CGRect(x: 80, y: 80, width: 1_100, height: 700),
                                    title: "随机窗口 \(index)", app: "RandomApp")
        let known = list.map(\.identity)
        var records = list + state.records.values.filter { !known.contains($0.identity) }
        guard !records.contains(where: { $0.identity == extra.identity }) else {
            return RandomAction(label: "重复窗口不新增", effects: [])
        }
        records.append(extra)
        let effects = (try? updateCatalog(&state, records: records)) ?? []
        return RandomAction(label: "新增 w\(extra.identity.windowID)", effects: effects)
    }

    private func roundTripMode(_ state: inout SessionState,
                               list: [WindowRecord],
                               rng: inout SeededGenerator) -> RandomAction {
        guard state.mode == .workbench, !state.workbench.mainSwitch.isBusy else {
            return RandomAction(label: "交换中不往返", effects: [])
        }
        let effects = dispatchConfirmed(&state, .returnToOverviewRequested)
        guard let plan = returnPlan(effects) else {
            return RandomAction(label: "返回未发起", effects: effects)
        }
        var all = effects
        all += dispatchConfirmed(&state, .workbenchTransitionFinished(token: plan.token,
                                                                     kind: .returningOverview,
                                                                     result: .succeeded(readBack: nil)))
        XCTAssertEqual(state.mode, .overview)
        XCTAssertNil(state.workbench.placement.main)
        let candidates = list.map(\.identity).filter { state.gridCell(for: $0) != nil }
        guard !candidates.isEmpty else { return RandomAction(label: "回总览后无可选", effects: all) }
        let target = candidates[Int.random(in: 0..<candidates.count, using: &rng)]
        all += enterWorkbench(&state, target: target)
        XCTAssertEqual(state.mode, .workbench)
        return RandomAction(label: "往返 w\(target.windowID)", effects: all)
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
