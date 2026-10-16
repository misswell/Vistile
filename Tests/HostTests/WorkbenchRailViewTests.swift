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

    private func sync(top: CGFloat = 0, side: CGFloat = 0) {
        let snapshot = fixture.snapshot
            .scrolling(rail: .top, to: top)
            .scrolling(rail: .side, to: side)
        let presentation = WorkbenchPresenter.make(state: fixture.state,
                                                   snapshot: snapshot,
                                                   placement: fixture.placement)
        controller.update(presentation: presentation,
                          renderer: renderer,
                          mailboxProvider: { _ in nil },
                          showsTitles: true,
                          searchQuery: "",
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

    private func wheel(deltaY: Int32) throws -> NSEvent {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cg = CGEvent(scrollWheelEvent2Source: source,
                         units: .pixel,
                         wheelCount: 1,
                         wheel1: deltaY,
                         wheel2: 0,
                         wheel3: 0)
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
        XCTAssertEqual(controller.topPanelFrame, HostFixtures.mapper.cgToAppKit(layout.topRailRect).integral)
        XCTAssertEqual(controller.sidePanelFrame, HostFixtures.mapper.cgToAppKit(layout.sideRailRect).integral)

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
                       CoordinateMapper(displays: [scale1]).cgToAppKit(fixture.layout.topRailRect).integral,
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
}
