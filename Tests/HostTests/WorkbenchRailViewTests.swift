import AppKit
import VistileCore
import XCTest
@testable import Vistile

/// 工作台两栏的真实视图事件（方案 §18.2 H01/H02/H03/H09/H11/H12 的宿主侧）。
///
/// 这里用真 `WorkbenchWindowController`/`WorkbenchRailView` 与真 `NSEvent` 走一遍
/// "点击 → 命中 → 控制器动作"这条链路：断言落在视图与图层的可见事实上，
/// 不读视图内部变量。面板一律摆在主屏之外，测试期间不落进用户桌面。
@MainActor
final class WorkbenchRailViewTests: XCTestCase {
    private var metal: MetalContext!
    private var renderer: OverviewRenderer!
    private var controller: WorkbenchWindowController!
    private var fixture: HostWorkbenchFixture!
    private var actions: [WorkbenchWindowController.Action] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        metal = try HostFixtures.metalContext()
        renderer = try HostFixtures.renderer(metal: metal)
        controller = WorkbenchWindowController(display: HostFixtures.display,
                                               mapper: HostFixtures.mapper,
                                               metal: metal)
        controller.onAction = { [weak self] action in self?.actions.append(action) }
        fixture = HostWorkbench.fixture()
        sync()
    }

    override func tearDown() {
        controller?.hide()
        controller = nil
        renderer = nil
        metal = nil
        fixture = nil
        actions = []
        super.tearDown()
    }

    // MARK: - 组装

    private func sync(top: CGFloat = 0, side: CGFloat = 0, query: String = "",
                      placement: WorkbenchPlacement? = nil) {
        let snapshot = fixture.snapshot
            .scrolling(rail: .top, to: top)
            .scrolling(rail: .side, to: side)
        let presentation = WorkbenchPresenter.make(state: fixture.state,
                                                   snapshot: snapshot,
                                                   placement: placement ?? fixture.placement)
        controller.update(presentation: presentation,
                          renderer: renderer,
                          mailboxProvider: { _ in nil },
                          showsTitles: true,
                          searchQuery: query,
                          hint: nil)
    }

    private func panel(of view: WorkbenchRailView) throws -> NSWindow {
        try XCTUnwrap(view.window, "栏视图必须挂在面板窗口里，否则事件坐标无参照")
    }

    private func send(_ type: NSEvent.EventType, to view: WorkbenchRailView, at localPoint: CGPoint) throws {
        let event = HostEvents.mouse(type, in: try panel(of: view), point: view.convert(localPoint, to: nil))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: XCTFail("测试未覆盖的鼠标事件类型：\(type.rawValue)")
        }
    }

    private func wheel(deltaY: Int32, deltaX: Int32 = 0,
                       units: CGScrollEventUnit = .pixel,
                       phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) throws -> NSEvent {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cg = CGEvent(scrollWheelEvent2Source: source,
                         units: units,
                         wheelCount: 2,
                         wheel1: deltaY,
                         wheel2: deltaX,
                         wheel3: 0)
        // CoreGraphics phase constants differ from NSEvent.Phase raw values.
        let scrollPhase: Int64 = phase.contains(.began) ? 1 : phase.contains(.changed) ? 2
            : phase.contains(.ended) ? 4 : phase.contains(.cancelled) ? 8 : phase.contains(.mayBegin) ? 128 : 0
        let momentumPhase: Int64 = momentum.contains(.began) ? 1 : momentum.contains(.changed) ? 2
            : momentum.contains(.ended) ? 3 : 0
        cg?.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        cg?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        return try XCTUnwrap(cg.flatMap { NSEvent(cgEvent: $0) }, "无法合成滚轮事件")
    }

    private func topSlot(_ index: Int) -> RailSlotID {
        fixture.layout.slotOrder.filter { $0.rail == .top }[index]
    }

    private func sideSlot(_ index: Int) -> RailSlotID {
        fixture.layout.slotOrder.filter { $0.rail == .side }[index]
    }

    // MARK: - H01 点击链路

    func testCardClickReachesControllerOnceWithExactSlot() throws {
        let slot = topSlot(0)
        let identity = try XCTUnwrap(fixture.placement.occupant(at: slot))
        let view = controller.topRail
        let center = try XCTUnwrap(view.cellCenter(for: slot))
        XCTAssertEqual(view.hitTestCard(at: center)?.slot, slot,
                       "命中的事实必须真实存在，否则这一击落在空处，后面的断言毫无意义")

        try send(.leftMouseDown, to: view, at: center)
        try send(.leftMouseUp, to: view, at: center)

        XCTAssertEqual(actions.count, 1, "一次点击只能产生一个动作：\(actions)")
        guard case let .railCardClicked(clickedSlot, clickedIdentity) = try XCTUnwrap(actions.first) else {
            return XCTFail("动作类型不对：\(actions)")
        }
        XCTAssertEqual(clickedSlot, slot)
        XCTAssertEqual(clickedIdentity, identity, "点击携带的身份必须就是这一格的占用者")
    }

    func testClickInCardGapSelectsNothing() throws {
        let view = controller.topRail
        let first = try XCTUnwrap(view.cellCenter(for: topSlot(0)))
        let second = try XCTUnwrap(view.cellCenter(for: topSlot(1)))
        let gap = CGPoint(x: (first.x + second.x) / 2, y: first.y)
        XCTAssertNil(view.hitTestCard(at: gap), "两个卡片之间的空隙不该命中任何卡片")

        try send(.leftMouseDown, to: view, at: gap)
        try send(.leftMouseUp, to: view, at: gap)
        XCTAssertTrue(actions.isEmpty, "落在空隙的点击不能算一次选择：\(actions)")
    }

    // MARK: - H01/H09 拖动

    func testCrossRailDragEmitsDragAndNeverAClick() throws {
        let fromSlot = topSlot(0)
        let toSlot = sideSlot(0)
        let top = controller.topRail
        let side = controller.sideRail
        let start = try XCTUnwrap(top.cellCenter(for: fromSlot))
        let target = try XCTUnwrap(side.cellCenter(for: toSlot))

        try send(.leftMouseDown, to: top, at: start)
        try send(.leftMouseDragged, to: top, at: CGPoint(x: start.x + 30, y: start.y))
        // 松手事件仍然发给起点所在视图，落点换算回屏幕坐标：跨栏判定由控制器做。
        let sideWindowPoint = side.convert(target, to: nil)
        let screenPoint = try panel(of: side).convertPoint(toScreen: sideWindowPoint)
        let upPoint = try panel(of: top).convertPoint(fromScreen: screenPoint)
        top.mouseUp(with: HostEvents.mouse(.leftMouseUp, in: try panel(of: top), point: upPoint))

        XCTAssertEqual(actions.count, 1, "一次拖动只能产生一个动作：\(actions)")
        guard case let .railCardDragged(from, to) = try XCTUnwrap(actions.first) else {
            return XCTFail("拖动被当成了点击，等于用户一拖就误选：\(actions)")
        }
        XCTAssertEqual(from, fromSlot)
        XCTAssertEqual(to, toSlot, "落点必须命中侧栏真实存在的卡片")
    }

    // MARK: - H09 滚动与视口裁剪

    func testSideScrollProposesOffsetAndClippedCardsAreNotClickable() throws {
        fixture = HostWorkbench.fixture(count: 12, sideFirst: 8, sideSlots: 12)
        sync()

        let side = controller.sideRail
        let firstSlot = sideSlot(0)
        let lastSlot = sideSlot(7)
        XCTAssertNotNil(side.cellCenter(for: firstSlot), "未滚动时第一张侧栏卡片必须在视口里")
        XCTAssertNil(side.cellCenter(for: lastSlot), "超出可见容量的卡片不能出现在视口里")

        let event = try wheel(deltaY: -120)
        let delta = event.scrollingDeltaY
        XCTAssertNotEqual(delta, 0, "合成的滚轮事件必须带非零 delta，否则这条测试什么也没测")
        side.scrollWheel(with: event)
        XCTAssertEqual(actions.count, 1, "滚动只能产生一个动作：\(actions)")
        guard case let .railScrolled(scrolledRail, proposed) = actions.first else {
            return XCTFail("滚动发错成了别的动作：\(actions)")
        }
        XCTAssertEqual(scrolledRail, .side)
        XCTAssertEqual(proposed, 0 - delta, "滚动只提出新偏移，由 reducer 夹取；视图不自己改快照")

        // reducer 接受偏移后的投影：滚到底，第一张被裁出视口，最后一张完整滚进来。
        sync(side: fixture.layout.maxSideScroll)
        XCTAssertNil(side.cellCenter(for: firstSlot), "滚过去的卡片必须从视口消失")
        actions.removeAll()
        let visible = try XCTUnwrap(side.cellCenter(for: lastSlot), "滚进来的卡片必须可命中")
        XCTAssertEqual(side.hitTestCard(at: visible)?.slot, lastSlot, "命中事实必须先成立")
        try send(.leftMouseDown, to: side, at: visible)
        try send(.leftMouseUp, to: side, at: visible)
        XCTAssertEqual(actions.count, 1, "裁剪只影响可见性，不影响可见卡片的命中：\(actions)")
        guard case let .railCardClicked(slot, identity) = actions.first else {
            return XCTFail("可见卡片点击必须走选择路径：\(actions)")
        }
        XCTAssertEqual(slot, lastSlot)
        XCTAssertEqual(identity, try XCTUnwrap(fixture.placement.occupant(at: lastSlot)))
    }

    // MARK: - H02 键盘策略

    func testRailPanelsNeverTakeKeyOutsideSearch() throws {
        let panel = try XCTUnwrap(controller.topRail.window as? WorkbenchRailPanel)
        XCTAssertFalse(panel.canBecomeKey, "非搜索期间栏面板绝不能抢 key，否则目标应用收不到输入")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.becomesKeyOnlyIfNeeded, true)
        XCTAssertFalse(panel.acceptsKeyboard)

        controller.setSearchKeyboard(true)
        XCTAssertTrue(panel.acceptsKeyboard, "搜索编辑期间才允许接受键盘")
        XCTAssertTrue(panel.canBecomeKey, "搜索要能输入，key 策略必须跟着搜索状态走")

        controller.setSearchKeyboard(false)
        XCTAssertFalse(panel.acceptsKeyboard, "搜索结束必须立刻交回键盘")
        XCTAssertFalse(panel.canBecomeKey, "搜索结束后栏面板不能再接收键盘")
    }

    // MARK: - H03 Metal 设备与呈现几何

    func testRailsShareDeviceAndLayerGeometryMatchesBounds() throws {
        let top = controller.topRail
        let side = controller.sideRail
        XCTAssertTrue(top.metalLayer.device === metal.device, "顶栏必须用与总览同一台 Metal 设备")
        XCTAssertTrue(side.metalLayer.device === metal.device, "侧栏必须用同一台设备，否则无法出帧")
        for view in [top, side] {
            XCTAssertEqual(view.layer?.masksToBounds, true, "越出视口的卡片必须被裁掉")
            XCTAssertEqual(view.metalLayer.frame, CGRect(origin: .zero, size: view.bounds.size))
            let expected = CGSize(width: (view.bounds.width * 2).rounded(),
                                  height: (view.bounds.height * 2).rounded())
            XCTAssertEqual(view.metalLayer.drawableSize, expected,
                           "drawable 尺寸必须跟视图 bounds 走：残留旧尺寸会画到别人身上")
            XCTAssertGreaterThan(view.visibleCardCount, 0, "默认投影下每条栏都得有可命中的卡片")
        }
        XCTAssertEqual(top.visibleCardCount + side.visibleCardCount, 3, "两张顶栏卡片加一张侧栏卡片")
    }

    // MARK: - H11 坐标与屏幕

    func testPanelFramesAndCardCentersMatchProjectionAtNegativeOrigin() throws {
        let layout = fixture.layout
        XCTAssertFalse(layout.mainRect.intersects(layout.topRailRect), "顶栏绝不允许压到主区")
        XCTAssertFalse(layout.mainRect.intersects(layout.sideRailRect), "侧栏绝不允许压到主区")

        // 面板 frame 由投影取整而来：AppKit 本就会对窗口 frame 舍入，产品主动对齐。
        // 窗口 = 栏 ∪ 它与主区之间的空带（方案 §11.2）：分隔线命中区必须落在某个窗口里才收得到鼠标。
        XCTAssertEqual(controller.topPanelFrame, HostFixtures.mapper.cgToAppKit(layout.topPanelWindowRect).integral)
        XCTAssertEqual(controller.sidePanelFrame, HostFixtures.mapper.cgToAppKit(layout.sidePanelWindowRect).integral)

        // 卡片中心的完整往返：投影 CG → 面板窗口 → 视图本地，与视图自己算出的中心一致。
        let slot = topSlot(0)
        let cgRect = try XCTUnwrap(fixture.snapshot.rect(for: slot))
        let view = controller.topRail
        let local = try XCTUnwrap(view.cellCenter(for: slot))
        let appKit = HostFixtures.mapper.cgToAppKit(CGRect(x: cgRect.midX, y: cgRect.midY, width: 0, height: 0)).origin
        let windowPoint = try panel(of: view).convertPoint(fromScreen: appKit)
        let roundTrip = view.convert(windowPoint, from: nil)
        XCTAssertEqual(roundTrip.x, local.x, accuracy: 1, "负坐标原点的换算必须可逆")
        XCTAssertEqual(roundTrip.y, local.y, accuracy: 1, "负坐标原点的换算必须可逆")
    }

    func testMixedScaleDisplayKeepsRailOnItsOwnScale() throws {
        let scale1 = HostFixtures.display(id: HostFixtures.display.id,
                                          cgFrame: HostFixtures.visibleFrame,
                                          scale: 1,
                                          isPrimary: true)
        let secondary = WorkbenchWindowController(display: scale1,
                                                  mapper: CoordinateMapper(displays: [scale1]),
                                                  metal: metal)
        defer { secondary.hide() }
        secondary.update(presentation: fixture.presentation,
                         renderer: renderer,
                         mailboxProvider: { _ in nil },
                         showsTitles: true,
                         searchQuery: "",
                         hint: nil)
        XCTAssertEqual(secondary.topRail.metalLayer.contentsScale, 1,
                       "混合倍率下栏的像素密度必须跟随它所在的屏，不能所有屏共用 2x")
        XCTAssertEqual(secondary.topPanelFrame,
                       CoordinateMapper(displays: [scale1]).cgToAppKit(fixture.layout.topPanelWindowRect).integral,
                       "同一块屏的倍率变化不改变逻辑坐标")
    }

    // MARK: - H02/H17 「全部窗口」按钮

    func testAllWindowsButtonHitTestAndClickRoute() throws {
        let toolbar = controller.toolbarView
        toolbar.needsLayout = true
        toolbar.layoutSubtreeIfNeeded()
        let panel = try panel(of: controller.topRail)

        let center = CGPoint(x: toolbar.allWindowsButtonFrame.midX, y: toolbar.allWindowsButtonFrame.midY)
        let hit = try XCTUnwrap(panel.contentView?.hitTest(toolbar.convert(center, to: nil)) as? NSButton,
                                "工具区该点必须命中按钮，不能被卡片或空白吃掉")
        XCTAssertEqual(hit.title, "全部窗口")

        hit.performClick(nil)
        XCTAssertEqual(actions.count, 1, "点击必须只产生一次返回总览动作：\(actions)")
        guard case .returnToOverview = actions.first else {
            return XCTFail("「全部窗口」按钮必须走返回总览：\(actions)")
        }

        let sideButton = try XCTUnwrap(toolbar.subviews.compactMap { $0 as? NSButton }
            .first { $0.title.contains("侧栏") }, "工具区必须有侧栏方向按钮")
        XCTAssertTrue(sideButton.title.contains("左") || sideButton.title.contains("右"),
                      "方向必须写在标题上：\(sideButton.title)")
        sideButton.performClick(nil)
        XCTAssertEqual(actions.count, 2)
        guard case .toggleSide = actions.last else {
            return XCTFail("侧栏按钮必须走方向切换：\(actions)")
        }
    }

    // MARK: - 搜索过滤：总览与两栏共用同一条规则（方案 §5.5.5）

    func testSearchQueryHidesNonMatchingRailCardsFromHitTesting() throws {
        let hiddenSlot = topSlot(0)
        let keptSlot = topSlot(1)
        let hiddenCenter = try XCTUnwrap(controller.topRail.cellCenter(for: hiddenSlot))
        sync(query: "App3")

        let top = controller.topRail
        XCTAssertNil(top.cellCenter(for: hiddenSlot), "被过滤的卡片不许留下任何命中几何")
        XCTAssertNil(top.hitTestCard(at: hiddenCenter), "旧位置必须落空，不许点到看不见的卡片")
        XCTAssertEqual(top.visibleCardCount, 1, "「可见 n」只数过滤后还在的卡片")
        XCTAssertEqual(controller.sideRail.visibleCardCount, 0, "侧栏卡片按同一条规则一起过滤")

        let countText = controller.toolbarView.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            .first { $0.hasPrefix("可见") }
        XCTAssertEqual(countText, "可见 2 / 共 4", "工具栏计数只含过滤后可见的卡片，主区窗口永远算一个")

        try send(.leftMouseDown, to: top, at: hiddenCenter)
        try send(.leftMouseUp, to: top, at: hiddenCenter)
        XCTAssertTrue(actions.isEmpty, "被过滤卡片的位置点下去什么都不该发生：\(actions)")

        let keptCenter = try XCTUnwrap(top.cellCenter(for: keptSlot), "命中的卡片必须仍可点")
        try send(.leftMouseDown, to: top, at: keptCenter)
        try send(.leftMouseUp, to: top, at: keptCenter)
        XCTAssertEqual(actions.count, 1)
        guard case let .railCardClicked(slot, identity) = actions.first else {
            return XCTFail("可见卡片点击必须走选择路径：\(actions)")
        }
        XCTAssertEqual(slot, keptSlot)
        XCTAssertEqual(identity, try XCTUnwrap(fixture.placement.occupant(at: keptSlot)))

        // 清空查询后完全恢复：过滤只是视图层的一次重投影，slot 与滚动偏移从未变过。
        sync()
        XCTAssertEqual(top.visibleCardCount, 2)
        XCTAssertNotNil(top.cellCenter(for: hiddenSlot))
    }

    // MARK: - H13/§13 无障碍：两栏卡片可被朗读与激活

    func testRailAccessibilityExposesCardsAsButtonsAndActivationRoutesThroughClick() throws {
        let top = controller.topRail
        XCTAssertFalse(top.isAccessibilityElement(), "栏本身是容器，不是一个元素")
        XCTAssertEqual(top.accessibilityRole(), .group)
        XCTAssertEqual(top.accessibilityLabel(), "工作台顶栏")
        XCTAssertEqual(controller.sideRail.accessibilityLabel(), "工作台侧栏")

        let children = try XCTUnwrap(top.accessibilityChildren())
        XCTAssertEqual(children.count, 2, "顶栏两张卡片各暴露一个元素")
        let first = try XCTUnwrap(children.first as? CardAccessibilityElement)
        XCTAssertEqual(first.accessibilityRole(), .button)
        XCTAssertEqual(first.accessibilityRoleDescription(), "顶栏卡片 1", "位置按可见顺序朗读")
        XCTAssertEqual(first.accessibilityLabel(), "App2，窗口 2，实时画面",
                       "朗读必须包含应用、窗口名与真实捕获状态")

        let customActions = try XCTUnwrap(first.accessibilityCustomActions())
        XCTAssertEqual(customActions.map(\.name), ["切换到主工作区"], "可操作性要朗读出真实动作")
        let action = try XCTUnwrap(customActions.first)
        XCTAssertIdentical(action.target, first, "动作必须指向这个卡片元素")
        // 等价于 VoiceOver 触发这个动作：走与点击完全相同的一条路径。
        XCTAssertTrue(first.activateFromAccessibility(), "命名动作必须报告执行成功")
        XCTAssertEqual(actions.count, 1, "无障碍激活必须只产生一次动作：\(actions)")
        guard case let .railCardClicked(slot, identity) = actions.first else {
            return XCTFail("无障碍激活必须走卡片选择路径：\(actions)")
        }
        XCTAssertEqual(slot, topSlot(0))
        XCTAssertEqual(identity, try XCTUnwrap(fixture.placement.occupant(at: topSlot(0))))

        let sideChildren = try XCTUnwrap(controller.sideRail.accessibilityChildren())
        XCTAssertEqual(sideChildren.count, 1)
        let sideFirst = try XCTUnwrap(sideChildren.first as? CardAccessibilityElement)
        XCTAssertEqual(sideFirst.accessibilityRoleDescription(), "侧栏卡片 1")

        // VO-Space（按钮角色的标准激活）走同一条路径：不做看得见按不动的假按钮。
        actions.removeAll()
        XCTAssertTrue(sideFirst.accessibilityPerformPress())
        XCTAssertEqual(actions.count, 1)
        guard case let .railCardClicked(_, pressedIdentity) = actions.first else {
            return XCTFail("VO-Space 必须走卡片选择路径：\(actions)")
        }
        XCTAssertEqual(pressedIdentity, try XCTUnwrap(fixture.placement.occupant(at: sideSlot(0))))

        // 过滤后的位置编号按此刻可见的第几张重排，不暴露被过滤掉的空位。
        actions.removeAll()
        sync(query: "App3")
        let filtered = try XCTUnwrap(top.accessibilityChildren())
        XCTAssertEqual(filtered.count, 1)
        let only = try XCTUnwrap(filtered.first as? CardAccessibilityElement)
        XCTAssertEqual(only.accessibilityRoleDescription(), "顶栏卡片 1")
        XCTAssertTrue(try XCTUnwrap(only.accessibilityLabel()).contains("App3"))
    }

    // MARK: - H12 捕获需求的投影事实

    func testPresentationExcludesMainAndListsEveryRailCard() {
        let presentation = fixture.presentation
        let railIdentities = Set([1, 2, 3].map(HostFixtures.identity))
        XCTAssertEqual(Set(presentation.cards.map(\.identity)), railIdentities,
                       "两栏卡片必须恰好是轨道占用者")
        XCTAssertFalse(presentation.cards.contains { $0.identity == presentation.mainIdentity },
                       "主区是真实窗口，绝不能再出现在捕获需求里：那是重复取流")
        XCTAssertEqual(presentation.mainIdentity, HostFixtures.identity(0))
        XCTAssertEqual(presentation.topCards.count, 2)
        XCTAssertEqual(presentation.sideCards.count, 1)
        XCTAssertEqual(presentation.visibleCount, 4, "主区 1 + 可见卡片 3")
        XCTAssertEqual(presentation.totalCount, 4)
        XCTAssertFalse(presentation.isMainAreaConstrained, "1440×900 上主区不该被标受限")
    }

    // MARK: - M3d 固定在顶部（方案 §6.2；RailView action → 控制器链路，H01 同一路径）

    func testRailContextMenuPinsAndBadgeFollowsPresentation() throws {
        let view = controller.topRail
        let slot = topSlot(0)
        let identity = try XCTUnwrap(fixture.placement.occupant(at: slot))
        let key = try XCTUnwrap(fixture.state.records[identity]?.preferenceKey)
        let center = try XCTUnwrap(view.cellCenter(for: slot))

        // 卡片之间的空隙没有菜单：右键入口只属于真实卡片。
        let first = try XCTUnwrap(view.cellCenter(for: topSlot(0)))
        let second = try XCTUnwrap(view.cellCenter(for: topSlot(1)))
        let gap = CGPoint(x: (first.x + second.x) / 2, y: first.y)
        XCTAssertNil(view.contextMenu(forLocalPoint: gap), "空处右键不该弹出固定菜单")

        let menu = try XCTUnwrap(view.contextMenu(forLocalPoint: center))
        XCTAssertEqual(menu.items.count, 1, "菜单当前只承诺一件事：固定在顶部")
        XCTAssertEqual(menu.items.first?.title, "固定在顶部")
        menu.performActionForItem(at: 0)
        XCTAssertEqual(actions.count, 1, "一次菜单点击只能产生一个动作：\(actions)")
        guard case let .railPinToggled(pinnedIdentity) = actions.first else {
            return XCTFail("菜单项必须走固定动作：\(actions)")
        }
        XCTAssertEqual(pinnedIdentity, identity)

        // 投影说已固定：徽标、菜单标题、朗读文本都跟着同一条展示事实走。
        var pinnedPlacement = fixture.placement
        pinnedPlacement.adoptMemory(orderPreference: [:], pinned: [key])
        XCTAssertEqual(view.pinBadgeVisible(for: slot), false, "未固定时不画标记")
        sync(placement: pinnedPlacement)
        XCTAssertEqual(view.pinBadgeVisible(for: slot), true, "展示事实说已固定，卡片就必须画出标记")
        XCTAssertEqual(view.pinBadgeVisible(for: topSlot(1)), false, "别的卡片不许跟着亮")
        XCTAssertEqual(view.contextMenu(forLocalPoint: center)?.items.first?.title, "取消固定在顶部")
        let children = try XCTUnwrap(view.accessibilityChildren())
        let firstCard = try XCTUnwrap(children.first as? CardAccessibilityElement)
        XCTAssertEqual(firstCard.accessibilityRoleDescription(), "顶栏卡片 1")
        XCTAssertEqual(firstCard.accessibilityLabel(), "App2，窗口 2，实时画面，已固定在顶部",
                       "固定事实必须能被朗读出来，而不是只画一个色块")

        // 撤掉固定：标记与菜单标题都跟着回去。
        sync()
        XCTAssertEqual(view.pinBadgeVisible(for: slot), false)
        XCTAssertEqual(view.contextMenu(forLocalPoint: center)?.items.first?.title, "固定在顶部")
    }

    func testMoreMenuHostsOrganizeAndRoutesThroughToolbar() throws {
        let toolbar = controller.toolbarView
        toolbar.needsLayout = true
        toolbar.layoutSubtreeIfNeeded()
        let panel = try panel(of: controller.topRail)

        let center = CGPoint(x: toolbar.moreButtonFrame.midX, y: toolbar.moreButtonFrame.midY)
        let hit = try XCTUnwrap(panel.contentView?.hitTest(toolbar.convert(center, to: nil)) as? NSButton,
                                "工具区该点必须命中「更多」按钮，不能被卡片或空白吃掉")
        XCTAssertEqual(hit.title, "更多")

        XCTAssertEqual(toolbar.moreMenu.items.map(\.title), ["整理预览栏"],
                       "整理是唯一会重排轨道的动作，放在「更多」里（方案 §4.4）")
        toolbar.moreMenu.performActionForItem(at: 0)
        XCTAssertEqual(actions.count, 1, "一次菜单点击只能产生一个动作：\(actions)")
        guard case .organize = actions.first else {
            return XCTFail("整理菜单项必须走 organize 动作：\(actions)")
        }
    }

    // MARK: - M3d 边缘自动滚动（方案 §6.2；H09 拖动路径）

    func testDragNearViewportEdgeAutoScrollsAndStopsOnRelease() throws {
        fixture = HostWorkbench.fixture(count: 12, sideFirst: 8, sideSlots: 12)
        sync()
        let side = controller.sideRail
        let start = try XCTUnwrap(side.cellCenter(for: sideSlot(0)))
        let nearBottom = CGPoint(x: start.x, y: 6)

        func scrollProposals() -> [(RailKind, CGFloat)] {
            actions.compactMap {
                if case let .railScrolled(rail, proposed) = $0 { return (rail, proposed) }
                return nil
            }
        }
        func spinRunLoop(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        // 未越过拖动阈值：即使指针贴在边缘也不启动自动滚动。
        try send(.leftMouseDown, to: side, at: start)
        try send(.leftMouseDragged, to: side, at: CGPoint(x: start.x, y: start.y - 5))
        spinRunLoop(0.12)
        XCTAssertTrue(scrollProposals().isEmpty, "没到拖动阈值不该有任何自动滚动：\(actions)")

        // 越过阈值并停在边缘区内：30Hz 提出新偏移，方向是把下方卡片带进来。
        try send(.leftMouseDragged, to: side, at: nearBottom)
        spinRunLoop(0.12)
        let proposals = scrollProposals()
        XCTAssertFalse(proposals.isEmpty, "指针贴着视口边缘拖动必须有自动滚动")
        XCTAssertTrue(proposals.allSatisfy { $0.0 == .side }, "滚的是被拖的那条栏：\(proposals)")
        XCTAssertTrue(proposals.allSatisfy { $0.1 > 0 }, "下边缘方向 = offset 增大：\(proposals)")

        // 有界：这些提出值经 reducer 夹取后永远落在内容轨道长度之内。
        let bounded = proposals.reduce(CGFloat(0)) { _, proposal in
            fixture.snapshot.clampedScroll(rail: .side, offset: proposal.1)
        }
        XCTAssertLessThanOrEqual(bounded, fixture.layout.maxSideScroll, "自动滚动不得滚出内容轨道")
        XCTAssertGreaterThan(fixture.layout.maxSideScroll, 0, "这条 fixture 必须有可滚内容，否则测了个空")

        // 松手：定时器随手势一起收掉，等待期不再新增滚动。（松手可能额外产生一次拖动落点动作。）
        let countAtRelease = actions.count
        try send(.leftMouseUp, to: side, at: nearBottom)
        spinRunLoop(0.12)
        XCTAssertTrue(actions.dropFirst(countAtRelease).allSatisfy {
            if case .railScrolled = $0 { return false }
            return true
        }, "松手后还在自动滚 = 定时器泄漏：\(actions.dropFirst(countAtRelease))")
    }
    func testTopTrackpadKeepsDominantAxisThroughMomentum() throws {
        let top = controller.topRail
        let first = try wheel(deltaY: -24, deltaX: -1, phase: .began)
        XCTAssertTrue(first.hasPreciseScrollingDeltas)
        top.scrollWheel(with: first)
        let changed = try wheel(deltaY: -5, deltaX: -30, phase: .changed)
        top.scrollWheel(with: changed)
        top.scrollWheel(with: try wheel(deltaY: 0, phase: .ended))
        let momentum = try wheel(deltaY: -3, deltaX: -20, momentum: .began)
        top.scrollWheel(with: momentum)
        let offsets = actions.compactMap { action -> CGFloat? in
            if case let .railScrolled(.top, offset) = action { return offset }
            return nil
        }
        XCTAssertEqual(offsets, [-first.scrollingDeltaY, -changed.scrollingDeltaY, -momentum.scrollingDeltaY])
        actions.removeAll()
        let next = try wheel(deltaY: -2, deltaX: -18, phase: .began)
        top.scrollWheel(with: next)
        guard case let .railScrolled(.top, offset) = actions.first else { return XCTFail("Missing scroll") }
        XCTAssertEqual(offset, -next.scrollingDeltaX, "A new gesture must choose its own axis")
    }

    func testDiscreteWheelConvertsLinesToPoints() throws {
        let event = try wheel(deltaY: -3, units: .line)
        XCTAssertFalse(event.hasPreciseScrollingDeltas)
        controller.sideRail.scrollWheel(with: event)
        guard case let .railScrolled(.side, offset) = actions.last else { return XCTFail("Missing scroll") }
        XCTAssertEqual(offset, -event.scrollingDeltaY * 10)
    }

    func testSelectionKeepsThumbnailsInPlaceAndMovesOnlyTheCurrentBorder() throws {
        var placement = fixture.placement
        let main = try XCTUnwrap(placement.main)
        let mainSlot = try XCTUnwrap(fixture.layout.slotOrder.first { placement.occupant(at: $0) == nil })
        XCTAssertTrue(placement.place(main, at: mainSlot))
        sync(placement: placement)
        let target = try XCTUnwrap(fixture.presentation.cards.first)
        let before = placement.occupants
        func rail(_ slot: RailSlotID) -> WorkbenchRailView {
            slot.rail == .top ? controller.topRail : controller.sideRail
        }
        XCTAssertEqual(rail(mainSlot).chrome(for: mainSlot)?.border.borderWidth, 2)
        let startCenter = try XCTUnwrap(rail(target.slot).cellCenter(for: target.slot))
        XCTAssertTrue(placement.swapMain(with: target.slot))
        sync(placement: placement)
        XCTAssertEqual(placement.occupants, before)
        XCTAssertEqual(rail(target.slot).cellCenter(for: target.slot), startCenter)
        XCTAssertEqual(rail(target.slot).lastCards[target.slot]?.identity, target.identity)
        XCTAssertEqual(rail(mainSlot).lastCards[mainSlot]?.identity, main)
        XCTAssertEqual(rail(target.slot).chrome(for: target.slot)?.border.borderWidth, 2)
        XCTAssertEqual(rail(mainSlot).chrome(for: mainSlot)?.border.borderWidth, 1)
        XCTAssertTrue(rail(target.slot).accessibilityCardDescriptors.contains { $0.statusText.contains("当前窗口") })
    }

    func testTitleUsesAvailableWidthAndReservesStatusOnlyWhenVisible() {
        let chrome = CardChrome()
        let rect = CGRect(x: 0, y: 0, width: 200, height: 140)
        chrome.layout(in: rect, style: .standard, showsTitle: true, showsStatus: false)
        XCTAssertEqual(chrome.titleText.frame.minX, 8)
        XCTAssertEqual(chrome.titleText.frame.maxX, 192)
        let fullWidth = chrome.titleText.frame.width
        chrome.applyPinned(true)
        XCTAssertLessThanOrEqual(chrome.titleText.frame.maxX, chrome.pinBadge.frame.minX)
        chrome.applyPinned(false)
        XCTAssertEqual(chrome.titleText.frame.width, fullWidth)
        chrome.layout(in: rect, style: .standard, showsTitle: true, showsStatus: true)
        XCTAssertLessThan(chrome.titleText.frame.width, fullWidth)
        XCTAssertLessThanOrEqual(chrome.titleText.frame.maxX, chrome.statusText.frame.minX)
    }

}
