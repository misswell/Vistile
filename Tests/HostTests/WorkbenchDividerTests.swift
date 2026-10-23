import AppKit
import CoreGraphics
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// 分隔线拖动的宿主侧回归（方案 §11.2、§18.2 H08）。
///
/// 三条事实：命中区只落在冻结投影给出的空带中央（面板窗口伸进空带但不盖主区）；
/// 拖动报"抓取锚点 + 屏幕增量"并 clamp 到 token 范围；
/// 拖动中的 AX 写入被节流到 15–20Hz 且一次在途，松手后的最终尺寸不被旧写入覆盖。
/// 面板一律摆在屏外，事件用合成 NSEvent，AX 与写入器全用替身：不碰用户桌面。
@MainActor
final class WorkbenchDividerTests: XCTestCase {
    private var metal: MetalContext!
    private var renderer: OverviewRenderer!
    private var controller: WorkbenchWindowController!
    private var fixture: HostWorkbenchFixture!
    private var actions: [WorkbenchWindowController.Action] = []

    private let sessionID = UUID()
    private var scratchDirectories: [URL] = []
    private var testDefaultsSuites: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        metal = try HostFixtures.metalContext()
        renderer = try HostFixtures.renderer(metal: metal)
        controller = WorkbenchWindowController(display: HostFixtures.display,
                                               mapper: HostFixtures.mapper,
                                               metal: metal)
        controller.onAction = { [weak self] action in self?.actions.append(action) }
        fixture = HostWorkbench.fixture()
        sync(fixture)
    }

    override func tearDown() {
        controller?.hide()
        controller = nil
        renderer = nil
        metal = nil
        fixture = nil
        actions = []
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        for suite in testDefaultsSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        testDefaultsSuites = []
        super.tearDown()
    }

    private func sync(_ fixture: HostWorkbenchFixture) {
        controller.update(presentation: fixture.presentation,
                          renderer: renderer,
                          mailboxProvider: { _ in nil },
                          showsTitles: true,
                          searchQuery: "",
                          hint: nil)
    }

    private func send(_ type: NSEvent.EventType, to view: NSView, at localPoint: CGPoint) throws {
        let window = try XCTUnwrap(view.window, "视图必须挂在面板窗口里，否则事件坐标无参照")
        let event = HostEvents.mouse(type, in: window, point: view.convert(localPoint, to: nil))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: XCTFail("测试未覆盖的鼠标事件类型：\(type.rawValue)")
        }
    }

    private func center(of view: NSView) -> CGPoint {
        CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    private func syncLayout(top: CGFloat, width: CGFloat, side: RailSide = .right, size: CGSize? = nil) {
        let layout = WorkbenchLayoutEngine.layout(displayID: HostFixtures.display.id,
                                                  visibleFrame: CGRect(origin: HostFixtures.offscreenOrigin,
                                                                       size: size ?? HostFixtures.offscreenSize),
                                                  side: side, topHeightOverride: top, sideWidthOverride: width)
        fixture = HostWorkbenchFixture(state: fixture.state, placement: fixture.placement,
                                       snapshot: fixture.snapshot.replacing(layout: layout,
                                                                             revision: fixture.snapshot.revision + 1))
        sync(fixture)
    }

    private func send(_ type: NSEvent.EventType, to view: NSView, screenPoint: CGPoint) throws {
        let window = try XCTUnwrap(view.window)
        let local = view.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        try send(type, to: view, at: local)
    }

    private func windowPoint(of cgPoint: CGPoint, in view: NSView) throws -> CGPoint {
        let window = try XCTUnwrap(view.window)
        return window.convertPoint(fromScreen: HostFixtures.mapper.cgToAppKit(CGRect(origin: cgPoint, size: .zero)).origin)
    }

    private func draggedValues() -> [CGFloat] {
        actions.compactMap { if case let .railDividerDragged(_, value) = $0 { return value } else { return nil } }
    }

    private func endedValues() -> [CGFloat] {
        actions.compactMap { if case let .railDividerDragEnded(_, value) = $0 { return value } else { return nil } }
    }

    private func beganCount() -> Int {
        actions.filter { if case .railDividerDragBegan = $0 { return true } else { return false } }.count
    }

    // MARK: - 命中区与面板窗口

    func testDividerHitBandSitsInGapAndOnlyTheBandTakesTheDrag() throws {
        let layout = fixture.layout
        let mainFrame = HostFixtures.mapper.cgToAppKit(layout.mainRect)
        XCTAssertGreaterThanOrEqual(controller.topPanelFrame.minY, mainFrame.maxY)
        XCTAssertGreaterThanOrEqual(controller.sidePanelFrame.minX, mainFrame.maxX)
        XCTAssertTrue(controller.topPanelFrame.contains(HostFixtures.mapper.cgToAppKit(layout.topDividerRect)))
        XCTAssertTrue(controller.sidePanelFrame.contains(HostFixtures.mapper.cgToAppKit(layout.sideDividerRect)))

        XCTAssertEqual(controller.topDivider.frame.height, layout.topDividerRect.height, accuracy: 0.01)
        XCTAssertEqual(controller.sideDivider.frame.width, layout.sideDividerRect.width, accuracy: 0.01)
        XCTAssertEqual(controller.topDivider.frame.height, 8, accuracy: 0.01, "命中区 token 8pt")
        XCTAssertEqual(controller.topDivider.frame.width, layout.topRailRect.width, accuracy: 1, "顶部分隔线横跨整条空带")

        // 空带中央这一击必须落在分隔线上，否则拖动根本开始不了。
        let panel = try XCTUnwrap(controller.topDivider.window)
        let bandCenterY = (layout.topRailRect.maxY + layout.mainRect.minY) / 2
        let centerHit = try panel.contentView?.hitTest(try windowPoint(of: CGPoint(x: layout.topRailRect.midX,
                                                                                  y: bandCenterY),
                                                                       in: controller.topDivider))
        XCTAssertTrue(centerHit === controller.topDivider, "空带中央必须命中分隔线")

        // 带外（顶栏内部）不吃分隔线拖动：那里属于卡片。
        let railPoint = CGPoint(x: layout.topRailRect.midX, y: layout.topRailRect.maxY - 3)
        let railHit = try panel.contentView?.hitTest(try windowPoint(of: railPoint, in: controller.topDivider))
        XCTAssertFalse(railHit === controller.topDivider, "顶栏内部不得被分隔线命中区吃掉")

        // 侧栏同样：空带中央命中，栏内不命中。
        let sidePanel = try XCTUnwrap(controller.sideDivider.window)
        let sideBandCenterX = (layout.mainRect.maxX + layout.sideRailRect.minX) / 2
        let sideCenterHit = try sidePanel.contentView?.hitTest(try windowPoint(of: CGPoint(x: sideBandCenterX,
                                                                                          y: layout.sideRailRect.midY),
                                                                               in: controller.sideDivider))
        XCTAssertTrue(sideCenterHit === controller.sideDivider, "侧栏空带中央必须命中分隔线")
    }

    func testRoundedShellsPreserveMirroredViewportsAndFullDividerHitBands() throws {
        for side in [RailSide.left, .right] {
            syncLayout(top: 120.25, width: 220.25, side: side)
            let layout = fixture.layout
            let main = HostFixtures.mapper.cgToAppKit(layout.mainRect)
            for rail in [RailKind.top, .side] {
                let view = rail == .top ? controller.topRail : controller.sideRail
                let divider = rail == .top ? controller.topDivider : controller.sideDivider
                let window = try XCTUnwrap(view.window)
                let shell = try XCTUnwrap(window.contentView as? WorkbenchRailShellView)
                let railRect = rail == .top ? layout.topRailRect : layout.sideRailRect
                let viewport = rail == .top ? layout.topViewport : layout.sideViewport
                let band = rail == .top ? layout.topDividerRect : layout.sideDividerRect
                XCTAssertEqual(shell.shellLayer.frame,
                               window.convertFromScreen(HostFixtures.mapper.cgToAppKit(railRect)).intersection(shell.bounds))
                XCTAssertEqual(view.frame, window.convertFromScreen(HostFixtures.mapper.cgToAppKit(viewport)))
                XCTAssertEqual(divider.frame, window.convertFromScreen(HostFixtures.mapper.cgToAppKit(band)))
                XCTAssertEqual(shell.dividerHitLayer.frame, divider.frame.intersection(shell.bounds))
                XCTAssertEqual(shell.dividerHitLayer.backgroundColor?.alpha ?? 0, 0.01, accuracy: 0.001,
                               "Only the existing hit band gets a nonzero-alpha backing against window click-through")
                XCTAssertFalse(shell.shellLayer.frame.intersects(divider.frame), "The divider gap must remain outside the shell")
                XCTAssertFalse(window.frame.intersects(main), "Transparent corners must not enlarge a panel into mainRect")
                XCTAssertEqual(shell.shellLayer.cornerRadius, 18)
                let points: [CGPoint] = rail == .top
                    ? [CGPoint(x: 1, y: divider.bounds.midY), center(of: divider),
                       CGPoint(x: divider.bounds.maxX - 1, y: divider.bounds.midY)]
                    : [CGPoint(x: divider.bounds.midX, y: 1), center(of: divider),
                       CGPoint(x: divider.bounds.midX, y: divider.bounds.maxY - 1)]
                for point in points {
                    XCTAssertTrue(shell.hitTest(divider.convert(point, to: shell)) === divider,
                                  "The entire rectangular hit band must survive visual rounding on either side")
                }
                let mainCenter = window.convertPoint(fromScreen: CGPoint(x: main.midX, y: main.midY))
                XCTAssertNil(shell.hitTest(mainCenter))
            }
        }
    }

    func testWindowDispatchKeepsDraggingAfterPanelMovesWithoutTakingFocus() throws {
        let keyWindow = NSApp.keyWindow
        let active = NSApp.isActive
        controller.show()
        for side in [RailSide.left, .right] {
            for rail in [RailKind.top, .side] {
                actions = []
                syncLayout(top: 120, width: 220, side: side)
                let divider = rail == .top ? controller.topDivider : controller.sideDivider
                let monitors = DividerEventMonitors()
                divider.eventMonitoring = monitors.monitoring
                let window = try XCTUnwrap(divider.window)
                let start = window.convertPoint(toScreen: divider.convert(center(of: divider), to: nil))
                let delta = CGPoint(x: rail == .side ? (side == .left ? 30 : -30) : 0,
                                    y: rail == .top ? -30 : 0)
                let destination = CGPoint(x: start.x + delta.x, y: start.y + delta.y)
                let expected: CGFloat = rail == .top ? 150 : 250
                window.sendEvent(HostEvents.mouse(.leftMouseDown, in: window,
                                                  point: window.convertPoint(fromScreen: start)))
                window.sendEvent(HostEvents.mouse(.leftMouseDragged, in: window,
                                                  point: window.convertPoint(fromScreen: destination)))
                XCTAssertEqual(draggedValues(), [expected])
                syncLayout(top: rail == .top ? expected : 120,
                           width: rail == .side ? expected : 220, side: side)
                window.sendEvent(HostEvents.mouse(.leftMouseDragged, in: window,
                                                  point: window.convertPoint(fromScreen: destination)))
                window.sendEvent(HostEvents.mouse(.leftMouseUp, in: window,
                                                  point: window.convertPoint(fromScreen: destination)))
                XCTAssertEqual(beganCount(), 1)
                XCTAssertEqual(draggedValues(), [expected, expected])
                XCTAssertEqual(endedValues(), [expected])
                XCTAssertFalse(divider.isDragging)
                XCTAssertTrue(monitors.active.isEmpty)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, active)
    }

    func testWindowDispatchDoubleClickOnlyResetsTheHitDivider() throws {
        controller.show()
        for divider in [controller.topDivider, controller.sideDivider] {
            actions = []
            let window = try XCTUnwrap(divider.window)
            let point = divider.convert(center(of: divider), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                                                        modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil,
                                                        eventNumber: 0, clickCount: 2, pressure: 1))
            window.sendEvent(event)
            window.sendEvent(HostEvents.mouse(.leftMouseUp, in: window, point: point))
            XCTAssertEqual(actions.count, 1)
            guard case let .railDividerReset(rail) = actions.first else {
                return XCTFail("Window dispatch must reach the divider reset action")
            }
            XCTAssertEqual(rail, divider.rail)
            XCTAssertTrue(endedValues().isEmpty)
        }
    }

    // MARK: - 拖动换算

    func testTopDividerDragReportsAnchorDeltaAndClampsToRange() throws {
        let divider = controller.topDivider
        let startValue = fixture.layout.topRailRect.height
        let grab = center(of: divider)

        try send(.leftMouseDown, to: divider, at: grab)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x, y: grab.y - 25))
        try send(.leftMouseUp, to: divider, at: CGPoint(x: grab.x, y: grab.y - 25))

        XCTAssertEqual(beganCount(), 1, "越过阈值只报一次拖动开始：\(actions)")
        XCTAssertEqual(draggedValues().count, 1)
        XCTAssertEqual(try XCTUnwrap(draggedValues().first), startValue + 25, accuracy: 0.5,
                       "向下拖 25pt = 顶栏高 25pt：增量从按下点算起")
        XCTAssertEqual(try XCTUnwrap(endedValues().first), startValue + 25, accuracy: 0.5,
                       "松手值必须与最后一个预览一致")

        // 阈值内的抖动不是拖动：一个事件都不发。
        actions = []
        try send(.leftMouseDown, to: divider, at: grab)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x, y: grab.y - 1))
        try send(.leftMouseUp, to: divider, at: CGPoint(x: grab.x, y: grab.y - 1))
        XCTAssertTrue(actions.isEmpty, "1pt 抖动不得触发拖动链路：\(actions)")

        // 拖过头 clamp 到 token 上限，绝不把主区拖成负数。
        actions = []
        try send(.leftMouseDown, to: divider, at: grab)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x, y: grab.y - 600))
        try send(.leftMouseUp, to: divider, at: CGPoint(x: grab.x, y: grab.y - 600))
        XCTAssertEqual(try XCTUnwrap(endedValues().first),
                       fixture.layout.effectiveTopHeightRange.upperBound,
                       accuracy: 0.01)
    }

    func testSideDividerDragMirrorsForBothSides() throws {
        // 右栏：向左拖 = 加宽。
        let right = controller.sideDivider
        let rightStart = fixture.layout.sideRailRect.width
        let rightGrab = center(of: right)
        try send(.leftMouseDown, to: right, at: rightGrab)
        try send(.leftMouseDragged, to: right, at: CGPoint(x: rightGrab.x - 30, y: rightGrab.y))
        try send(.leftMouseUp, to: right, at: CGPoint(x: rightGrab.x - 30, y: rightGrab.y))
        XCTAssertEqual(try XCTUnwrap(endedValues().first), rightStart + 30, accuracy: 0.5,
                       "右栏向左拖 30pt = 侧栏宽 30pt")

        // 左栏镜像：向右拖 = 加宽。
        let leftFixture = HostWorkbench.fixture(count: 4, side: .left)
        fixture = leftFixture
        sync(leftFixture)
        actions = []
        let left = controller.sideDivider
        let leftStart = leftFixture.layout.sideRailRect.width
        let leftGrab = center(of: left)
        try send(.leftMouseDown, to: left, at: leftGrab)
        try send(.leftMouseDragged, to: left, at: CGPoint(x: leftGrab.x + 30, y: leftGrab.y))
        try send(.leftMouseUp, to: left, at: CGPoint(x: leftGrab.x + 30, y: leftGrab.y))
        XCTAssertEqual(try XCTUnwrap(endedValues().first), leftStart + 30, accuracy: 0.5,
                       "左栏向右拖 30pt = 侧栏宽 30pt")
    }

    func testMovingPanelAndPresentationChangesKeepMouseDownAnchor() throws {
        for rail in [RailKind.top, .side] {
            actions = []
            syncLayout(top: 120, width: 200)
            let divider = rail == .top ? controller.topDivider : controller.sideDivider
            let monitors = DividerEventMonitors()
            divider.eventMonitoring = monitors.monitoring
            let window = try XCTUnwrap(divider.window)
            let pressed = window.convertPoint(toScreen: divider.convert(center(of: divider), to: nil))
            try send(.leftMouseDown, to: divider, screenPoint: pressed)
            syncLayout(top: 140, width: 220)
            let moved = CGPoint(x: pressed.x - (rail == .side ? 30 : 0),
                                y: pressed.y - (rail == .top ? 30 : 0))
            try send(.leftMouseDragged, to: divider, screenPoint: moved)
            let expected: CGFloat = rail == .top ? 150 : 230
            XCTAssertEqual(try XCTUnwrap(draggedValues().last), expected, accuracy: 0.01)
            XCTAssertTrue(divider.hasEscapeMonitor)
            XCTAssertEqual(monitors.active, [.local, .global])
            syncLayout(top: rail == .top ? expected : 140, width: rail == .side ? expected : 220)
            try send(.leftMouseDragged, to: divider, screenPoint: moved)
            try send(.leftMouseUp, to: divider, screenPoint: moved)
            XCTAssertEqual(try XCTUnwrap(endedValues().last), expected, accuracy: 0.01)
            XCTAssertEqual(beganCount(), 1)
            XCTAssertFalse(divider.hasEscapeMonitor)
            XCTAssertTrue(monitors.active.isEmpty)
            XCTAssertEqual(monitors.removed, [.local, .global])
        }
    }

    func testCancelReportsOriginalValueOnceWithoutEndOrFocusChange() throws {
        let divider = controller.topDivider
        let window = try XCTUnwrap(divider.window)
        let keyWindow = NSApp.keyWindow
        let active = NSApp.isActive
        let start = divider.displayedValue
        let grab = center(of: divider)
        try send(.leftMouseDown, to: divider, at: grab)
        XCTAssertFalse(divider.hasEscapeMonitor)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x, y: grab.y - 30))
        XCTAssertTrue(divider.hasEscapeMonitor)
        syncLayout(top: start + 30, width: fixture.layout.sideRailRect.width)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                   characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                   isARepeat: false, keyCode: 53))
        NSApp.sendEvent(escape)
        XCTAssertFalse(divider.isDragging)
        divider.cancelDragging()
        try send(.leftMouseUp, to: divider, at: grab)
        let cancelled = actions.compactMap { action -> CGFloat? in
            if case let .railDividerDragCancelled(rail, value) = action, rail == .top { return value }
            return nil
        }
        XCTAssertEqual(cancelled, [start])
        XCTAssertTrue(endedValues().isEmpty)
        XCTAssertFalse(divider.isDragging)
        XCTAssertFalse(divider.hasEscapeMonitor)
        XCTAssertFalse(divider.isSizeLabelVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, active)
    }

    func testGlobalEscapeCancelsOnceWithoutLateCommitOrFocusChange() throws {
        let keyWindow = NSApp.keyWindow
        let active = NSApp.isActive
        for rail in [RailKind.top, .side] {
            actions = []
            let divider = rail == .top ? controller.topDivider : controller.sideDivider
            let monitors = DividerEventMonitors()
            divider.eventMonitoring = monitors.monitoring
            let window = try XCTUnwrap(divider.window)
            let start = divider.displayedValue
            let grab = center(of: divider)
            try send(.leftMouseDown, to: divider, at: grab)
            try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x - 1, y: grab.y - 1))
            XCTAssertTrue(monitors.active.isEmpty, "阈值内不得安装键盘监听")
            let moved = CGPoint(x: grab.x - 30, y: grab.y - 30)
            try send(.leftMouseDragged, to: divider, at: moved)
            try send(.leftMouseDragged, to: divider, at: moved)
            XCTAssertEqual(monitors.active, [.local, .global])
            let global = try XCTUnwrap(monitors.globalHandler)
            let local = try XCTUnwrap(monitors.localHandler)
            let ordinaryKey = HostEvents.key(0)
            global(ordinaryKey)
            XCTAssertTrue(local(ordinaryKey) === ordinaryKey)
            XCTAssertTrue(divider.isDragging)
            syncLayout(top: rail == .top ? start + 30 : fixture.layout.topRailRect.height,
                       width: rail == .side ? start + 30 : fixture.layout.sideRailRect.width)

            // 直接调用已注册回调，不把键盘事件发到真实前台应用。
            let escape = HostEvents.key(53)
            global(escape)
            XCTAssertFalse(divider.isDragging, "取消必须同步完成，不能排在 mouseUp 后面")
            XCTAssertTrue(monitors.active.isEmpty)
            global(escape)
            XCTAssertTrue(local(escape) === escape)
            divider.cancelDragging()
            try send(.leftMouseDragged, to: divider, at: moved)
            try send(.leftMouseUp, to: divider, at: grab)
            let cancelled = actions.compactMap { action -> CGFloat? in
                if case let .railDividerDragCancelled(kind, value) = action, kind == rail { return value }
                return nil
            }
            XCTAssertEqual(cancelled, [start])
            XCTAssertEqual(beganCount(), 1)
            XCTAssertEqual(draggedValues().count, 2)
            XCTAssertTrue(endedValues().isEmpty)
            XCTAssertEqual(monitors.removed, [.local, .global])
            XCTAssertNil(monitors.localHandler)
            XCTAssertNil(monitors.globalHandler)
            XCTAssertFalse(divider.hasEscapeMonitor)
            XCTAssertFalse(divider.isSizeLabelVisible)
            XCTAssertFalse(window.isKeyWindow)
            XCTAssertFalse(window.canBecomeKey)
        }
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(NSApp.isActive, active)
    }

    func testCleanupAndHideDoNotCommitOrCancel() throws {
        let divider = controller.sideDivider
        let monitors = DividerEventMonitors()
        divider.eventMonitoring = monitors.monitoring
        let grab = center(of: divider)
        try send(.leftMouseDown, to: divider, at: grab)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x - 30, y: grab.y))
        XCTAssertTrue(divider.hasEscapeMonitor)
        XCTAssertEqual(monitors.active, [.local, .global])
        actions = []
        divider.cancelMouseGesture()
        divider.cancelMouseGesture()
        try send(.leftMouseUp, to: divider, at: grab)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(divider.hasEscapeMonitor)
        XCTAssertTrue(monitors.active.isEmpty)
        XCTAssertEqual(monitors.removed, [.local, .global])
        try send(.leftMouseDown, to: divider, at: grab)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x - 30, y: grab.y))
        XCTAssertEqual(monitors.active, [.local, .global])
        let global = try XCTUnwrap(monitors.globalHandler)
        actions = []
        controller.hide()
        global(HostEvents.key(53))
        try send(.leftMouseUp, to: divider, at: grab)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(divider.hasEscapeMonitor)
        XCTAssertFalse(divider.isSizeLabelVisible)
        XCTAssertTrue(monitors.active.isEmpty)
        XCTAssertEqual(monitors.removed, [.local, .global, .local, .global])
    }

    func testDeinitRemovesBothEscapeMonitorsWithoutCallbacks() throws {
        let monitors = DividerEventMonitors()
        weak var releasedDivider: WorkbenchDividerView?
        var cancelled = 0
        var committed = 0
        // 不挂 superview/window，确保验证的是 deinit，而不是移除视图时的清理。
        try autoreleasepool {
            let divider = WorkbenchDividerView(rail: .top, frame: CGRect(x: 0, y: 0, width: 100, height: 8))
            releasedDivider = divider
            divider.eventMonitoring = monitors.monitoring
            divider.updatePresentation(value: 120, range: 96...320, side: .right, reduceMotion: true)
            divider.onDragCancelled = { cancelled += 1 }
            divider.onDragEnded = { _ in committed += 1 }
            divider.mouseDown(with: HostEvents.mouse(.leftMouseDown, in: nil, point: .zero))
            divider.mouseDragged(with: HostEvents.mouse(.leftMouseDragged, in: nil, point: CGPoint(x: 0, y: -30)))
            XCTAssertEqual(monitors.active, [.local, .global])
            _ = try XCTUnwrap(monitors.globalHandler)
        }
        XCTAssertNil(releasedDivider, "监听回调不能强引用分隔线")
        XCTAssertTrue(monitors.active.isEmpty)
        XCTAssertEqual(monitors.removed, [.local, .global])
        XCTAssertNil(monitors.localHandler)
        XCTAssertNil(monitors.globalHandler)
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(committed, 0)
    }

    func testDoubleClickOnlyRequestsReset() throws {
        for divider in [controller.topDivider, controller.sideDivider] {
            actions = []
            let window = try XCTUnwrap(divider.window)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                                                        location: divider.convert(center(of: divider), to: nil),
                                                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
            divider.mouseDown(with: event)
            try send(.leftMouseUp, to: divider, at: center(of: divider))
            XCTAssertEqual(actions.count, 1)
            guard case let .railDividerReset(rail) = try XCTUnwrap(actions.first) else {
                return XCTFail("Double-click must only request reset")
            }
            XCTAssertEqual(rail, divider.rail)
            XCTAssertFalse(divider.hasEscapeMonitor)
            XCTAssertTrue(endedValues().isEmpty)
        }
    }

    func testPresentationOwnsSizeLabelAndReusesDecorationLayers() throws {
        let divider = controller.topDivider
        let window = try XCTUnwrap(divider.window)
        divider.updatePresentation(value: fixture.layout.topRailRect.height,
                                   range: fixture.layout.effectiveTopHeightRange, side: .right, reduceMotion: true)
        divider.layoutSubtreeIfNeeded()
        let layers = (divider.layer?.sublayers ?? []).map(ObjectIdentifier.init)
        let value = divider.displayedValue
        let grab = center(of: divider)
        try send(.leftMouseDown, to: divider, at: grab)
        try send(.leftMouseDragged, to: divider, at: CGPoint(x: grab.x, y: grab.y - 30))
        XCTAssertTrue(divider.isSizeLabelVisible)
        XCTAssertEqual(divider.displayedValue, value)
        for size in 140...160 {
            divider.updatePresentation(value: CGFloat(size), range: 96...320, side: .right, reduceMotion: true)
            divider.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(divider.sizeLabelText, "Height 160 pt")
        XCTAssertEqual((divider.layer?.sublayers ?? []).map(ObjectIdentifier.init), layers)
        XCTAssertTrue((divider.layer?.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        let label = try XCTUnwrap(divider.superview?.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertNil(label.hitTest(CGPoint(x: label.frame.midX, y: label.frame.midY)))
        XCTAssertTrue(try XCTUnwrap(window.contentView).bounds.contains(label.frame))
        divider.cancelDragging()
    }

    func testKeyboardAndAccessibilityAdjustWithinEffectiveRangeWithoutFocus() throws {
        syncLayout(top: 120, width: 200, size: CGSize(width: 1_280, height: 800))
        let top = controller.topDivider
        let side = controller.sideDivider
        XCTAssertEqual(top.accessibilityLabel(), "Top rail height")
        XCTAssertEqual(side.accessibilityLabel(), "Side rail width")
        XCTAssertEqual(top.accessibilityIdentifier(), "workbench.topRailDivider")
        XCTAssertEqual(side.accessibilityIdentifier(), "workbench.sideRailDivider")
        XCTAssertTrue(top.accessibilityPerformIncrement())
        XCTAssertEqual(endedValues(), [128])
        actions = []
        top.keyDown(with: HostEvents.key(126, flags: HostEvents.option))
        XCTAssertEqual(endedValues(), [119])
        actions = []
        XCTAssertTrue(side.accessibilityPerformDecrement())
        XCTAssertEqual(endedValues(), [192])
        actions = []
        side.keyDown(with: HostEvents.key(123))
        XCTAssertEqual(endedValues(), [208])
        XCTAssertEqual(beganCount(), 0)
        XCTAssertTrue(draggedValues().isEmpty)
        XCTAssertFalse(try XCTUnwrap(top.window).canBecomeKey)
        XCTAssertFalse(try XCTUnwrap(side.window).canBecomeKey)
        syncLayout(top: 9_999, width: 9_999, size: CGSize(width: 1_280, height: 800))
        actions = []
        XCTAssertFalse(top.accessibilityPerformIncrement())
        XCTAssertFalse(side.accessibilityPerformIncrement())
        XCTAssertTrue(actions.isEmpty)
    }

    func testEffectiveDragLimitsAndFractionalPanelsDoNotCoverMainBorder() throws {
        for side in [RailSide.left, .right] {
            syncLayout(top: 120.25, width: 220.25, side: side, size: CGSize(width: 1_280, height: 800))
            let main = HostFixtures.mapper.cgToAppKit(fixture.layout.mainRect)
            XCTAssertGreaterThanOrEqual(controller.topPanelFrame.minY, main.maxY)
            if side == .left {
                XCTAssertLessThanOrEqual(controller.sidePanelFrame.maxX, main.minX)
            } else {
                XCTAssertGreaterThanOrEqual(controller.sidePanelFrame.minX, main.maxX)
            }
            for divider in [controller.topDivider, controller.sideDivider] {
                actions = []
                let grab = center(of: divider)
                let destination = CGPoint(x: grab.x + (side == .left ? 9_999 : -9_999), y: grab.y - 9_999)
                try send(.leftMouseDown, to: divider, at: grab)
                try send(.leftMouseDragged, to: divider, at: destination)
                try send(.leftMouseUp, to: divider, at: destination)
                let range = divider.rail == .top ? fixture.layout.effectiveTopHeightRange : fixture.layout.effectiveSideWidthRange
                XCTAssertEqual(try XCTUnwrap(endedValues().last), range.upperBound)
            }
        }
    }

    // MARK: - 节流策略（方案 §11.2：15–20Hz）

    func testWritePolicyCapsAtFifteenToTwentyHertzAndOneInFlight() {
        var policy = RailSizeWritePolicy()
        var writes = 0
        // 1 秒 60Hz 的鼠标事件流：允许的写入必须落在 15–20 次之间。
        for step in 0...60 {
            let now = Double(step) / 60.0
            if policy.allowsWrite(now: now, hasInFlightWrite: false) {
                policy.recordWrite(at: now)
                writes += 1
            }
        }
        XCTAssertGreaterThanOrEqual(writes, 15, "低于 15Hz 会让主窗口拖影")
        XCTAssertLessThanOrEqual(writes, 20, "高于 20Hz 就是每个鼠标事件都在写 AX：方案禁止")

        XCTAssertFalse(policy.allowsWrite(now: 100, hasInFlightWrite: true),
                       "一次在途：上一条写入没回来之前不得再排队")

        policy.reset()
        XCTAssertTrue(policy.allowsWrite(now: 100, hasInFlightWrite: false),
                      "新的拖动第一次移动立即可写")
    }

    // MARK: - H08/A07 设备级事实：串行执行，最终尺寸不被旧写入覆盖

    /// A07 前半（方案 §18 A07）：连续分隔线调整时，未执行的排队只留最新那一项，
    /// 且最后一次结算的目标获胜。"隐藏后无迟到微调"那半见
    /// `testRapidSettlesKeepOnlyTheNewestPendingAndHideLeavesNoLateNudge`。

    func testSettleSerializesWritesAndFinalFrameWins() async throws {
        let rig = try await makeRig()
        let a = HostFixtures.identity(0)
        let element = try XCTUnwrap(rig.catalogSource.element(for: a))
        let initial = FakeCatalogSource.frame(for: 0)
        rig.writer.setInitialFrame(initial, for: element)
        try await rig.prime(transactionFor: a, original: initial)

        // 拖动里相邻两次结算：第一次写入被卡在途中，第二次（更靠近松手值）随即排队。
        // `mainRect` 跟着每次结算自己的目标走——生产里 effect 发出前布局投影已更新（AppCoordinator.settleRects），
        // 写入方式仍由 `MainPlacementPolicy` 从主区实读算出，用例不另抄坐标。
        let layout = HostWorkbench.fixture(count: 1).layout
        let first = layout.mainRect.insetBy(dx: 40, dy: 20)
        let second = first.insetBy(dx: 20, dy: 10)
        let token1 = TransitionToken(generation: 1)
        let token2 = TransitionToken(generation: 2)
        rig.writer.setInitialFrame(layout.mainRect, for: element)
        rig.writer.gatesNextWrite = true
        rig.coordinator.settle(a, targetFrame: first, displayID: HostFixtures.display.id, token: token1,
                               mainRect: first, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        await pendingUntil { rig.writer.isBlockedInWrite }
        rig.coordinator.settle(a, targetFrame: second, displayID: HostFixtures.display.id, token: token2,
                               mainRect: second, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        XCTAssertEqual(rig.writer.totalWrites, 0, "第一次写入还没回来，第二次只能排队")
        rig.writer.openGate()

        await pendingUntil { self.geometryResults(rig.events).count == 2 }
        XCTAssertEqual(rig.writer.writtenFrames, [first, second], "两次写入按发起顺序串行执行")
        let settled = await rig.writer.currentFrame(of: element)
        XCTAssertEqual(settled, second, "设备上的最终几何 = 最后一次结算的目标：旧写入不覆盖它")
        XCTAssertEqual(geometryResults(rig.events).map(\.token), [token1, token2], "每次结算各有自己的令牌回报")
        XCTAssertEqual(geometryResults(rig.events).map(\.targetFrame), [first, second])

        // 迟到的旧令牌读回不得清掉在途写入：reducer 的令牌守卫由核心 W23 覆盖，这里断言事件如实分开。
        rig.coordinator.cancel()
    }

    // MARK: - A07（方案 §18 A07）：连续分隔线调整再隐藏

    /// 一路快速结算里，未执行的排队只能留下最新那一项；隐藏之后不得再有迟到微调写进窗口服务器。
    /// 判据取写入器实际落过的 frame 序列——这是设备事实，不是内部计数器。
    func testRapidSettlesKeepOnlyTheNewestPendingAndHideLeavesNoLateNudge() async throws {
        let rig = try await makeRig()
        let a = HostFixtures.identity(0)
        let element = try XCTUnwrap(rig.catalogSource.element(for: a))
        let initial = FakeCatalogSource.frame(for: 0)
        rig.writer.setInitialFrame(initial, for: element)
        try await rig.prime(transactionFor: a, original: initial)

        let layout = HostWorkbench.fixture(count: 1).layout
        rig.writer.setInitialFrame(layout.mainRect, for: element)

        // 第一次卡在"AX 调用还没开始"，随后四次连着进来：同 identity 的未执行计划 latest-wins。
        let inFlight = layout.mainRect.insetBy(dx: 40, dy: 20)
        rig.writer.gatesNextWrite = true
        rig.coordinator.settle(a, targetFrame: inFlight, displayID: HostFixtures.display.id,
                               token: TransitionToken(generation: 1),
                               mainRect: inFlight, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        await pendingUntil { rig.writer.isBlockedInWrite }

        var newest = inFlight
        for step in 1...4 {
            newest = newest.insetBy(dx: -10, dy: -5)
            rig.coordinator.settle(a, targetFrame: newest, displayID: HostFixtures.display.id,
                                   token: TransitionToken(generation: UInt64(step + 1)),
                                   mainRect: newest, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        }
        XCTAssertEqual(rig.writer.totalWrites, 0, "在途那次没回来之前，四次排队一次都不许动窗口")

        rig.writer.openGate()
        await pendingUntil { self.geometryResults(rig.events).count == 2 }
        XCTAssertEqual(rig.writer.writtenFrames, [inFlight, newest],
                       "四次拖动只有最新那一项落地：中间的必须被合并掉，不是被依次执行")
        let afterCoalescing = rig.writer.totalWrites
        let frameAfterCoalescing = await rig.writer.currentFrame(of: element)
        XCTAssertEqual(frameAfterCoalescing, newest, "设备上的尺寸 = 最新意图")

        // 隐藏（取消屏障）落在"下一次结算刚排上队、还没开始"这一刻。
        let hiddenTarget = newest.insetBy(dx: -10, dy: -5)
        rig.writer.gatesNextWrite = true
        rig.coordinator.settle(a, targetFrame: hiddenTarget, displayID: HostFixtures.display.id,
                               token: TransitionToken(generation: 6),
                               mainRect: hiddenTarget, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        await pendingUntil { rig.writer.isBlockedInWrite }
        rig.coordinator.cancel()
        rig.writer.openGate()
        await pendingUntil(timeout: 4) { !rig.coordinator.isBusy }

        XCTAssertEqual(rig.writer.totalWrites, afterCoalescing,
                       "隐藏后还有新的 AX 几何写入：迟到微调没被撤销屏障挡住")
        let frameAfterHide = await rig.writer.currentFrame(of: element)
        XCTAssertEqual(frameAfterHide, frameAfterCoalescing,
                       "隐藏后设备上的尺寸必须停在隐藏前那一步")
    }

    // MARK: - A06（方案 §18 A06）：旧队列积压后开启新会话

    /// 队列里还压着未执行的写入时会话换代：旧命令一律作废，且不能把新会话拖成永久失速。
    func testSessionAdoptionWhileBacklogIsQueuedDiscardsOldCommands() async throws {
        let rig = try await makeRig()
        let a = HostFixtures.identity(0)
        let element = try XCTUnwrap(rig.catalogSource.element(for: a))
        let initial = FakeCatalogSource.frame(for: 0)
        rig.writer.setInitialFrame(initial, for: element)
        try await rig.prime(transactionFor: a, original: initial)

        let layout = HostWorkbench.fixture(count: 1).layout
        rig.writer.setInitialFrame(layout.mainRect, for: element)

        let inFlight = layout.mainRect.insetBy(dx: 40, dy: 20)
        rig.writer.gatesNextWrite = true
        rig.coordinator.settle(a, targetFrame: inFlight, displayID: HostFixtures.display.id,
                               token: TransitionToken(generation: 1),
                               mainRect: inFlight, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        await pendingUntil { rig.writer.isBlockedInWrite }
        // 积压：在途还没回来，又排进两笔。
        let queued = inFlight.insetBy(dx: -10, dy: -5)
        rig.coordinator.settle(a, targetFrame: queued, displayID: HostFixtures.display.id,
                               token: TransitionToken(generation: 2),
                               mainRect: queued, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        XCTAssertEqual(rig.writer.totalWrites, 0)

        // 新会话接管：代次推进后，队列里那两笔属于旧会话。
        rig.scheduler.adopt(sessionID: UUID(), epoch: rig.scheduler.sessionEpoch + 1)
        rig.writer.openGate()
        await pendingUntil(timeout: 4) { !rig.writer.isBlockedInWrite }

        XCTAssertEqual(rig.writer.writtenFrames, [],
                       "换代后旧命令不许复活：一笔都不许落到窗口服务器上")
        let frameAfterAdoption = await rig.writer.currentFrame(of: element)
        XCTAssertEqual(frameAfterAdoption, layout.mainRect,
                       "原窗口几何一个字节都没被旧队列改过")

        // 新会话没被旧积压卡死：同一条链路仍能受理新结算。
        let fresh = layout.mainRect.insetBy(dx: -20, dy: -20)
        rig.coordinator.settle(a, targetFrame: fresh, displayID: HostFixtures.display.id,
                               token: TransitionToken(generation: 3),
                               mainRect: fresh, topRailRect: layout.topRailRect, sideRailRect: layout.sideRailRect)
        await pendingUntil(timeout: 4) { rig.writer.totalWrites > 0 }
        XCTAssertEqual(rig.writer.writtenFrames, [fresh], "新会话的第一笔照常执行")
    }

    // MARK: - #3/#5/#6 调度器契约回归

    /// #3：在途一笔 + 排队一笔时会话换代。排队等待者必须被结算为 nil（不是永久悬挂），
    /// 旧任务收口后不得改新会话，新会话照常准入并执行新操作。
    func testOpenSessionReleasesQueuedWaiterAndKeepsNewSessionUsable() async {
        let scheduler = HostScheduler.make(sessionID: sessionID)
        let gate = TestGate()
        var oldContextRejectedAfterSessionChange: Bool?
        let oldContext = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .settleLayout)
        let inFlight = Task { () -> Void in
            _ = await scheduler.request(context: oldContext, identities: []) { _ in
                await gate.wait()
                // 新会话已开：旧上下文再想拿许可见必须被拒，旧任务不许改新会话状态。
                oldContextRejectedAfterSessionChange = scheduler.begin(oldContext) == nil
            }
        }
        await pendingUntil { scheduler.inFlightCount == 1 }

        // 第二笔在 A 在途时排队：正常情况下它只能等 A 执行完。
        let queuedContext = scheduler.makeContext(token: TransitionToken(generation: 2), kind: .settleLayout)
        var queuedSawNil: Bool?
        let queued = Task { () -> Void in
            let result: Bool? = await scheduler.request(context: queuedContext, identities: []) { _ in true }
            queuedSawNil = result == nil
        }
        await pendingUntil { scheduler.queuedCount == 1 }
        XCTAssertNil(queuedSawNil, "A 没结束前排队那笔不得提前拿到结论：\(scheduler.busyDescription)")

        let oldSessionID = scheduler.sessionID
        scheduler.openSession()

        // 换代那一刻排队等待者就必须拿到 nil，而不是等 gate 打开才收口。
        await queued.value
        XCTAssertEqual(queuedSawNil, true, "换代后排队等待者必须返回 nil（未写入），不能永久悬挂")

        // 在途那笔自己收口之后，旧上下文已彻底失去准入，通道回到静默。
        gate.open()
        await inFlight.value
        XCTAssertEqual(oldContextRejectedAfterSessionChange, true,
                       "旧上下文换代后不得再拿到新写入许可")
        XCTAssertNotEqual(scheduler.sessionID, oldSessionID, "新会话身份必须已生效")
        XCTAssertTrue(scheduler.isIdle, "旧任务收口后通道必须静默：\(scheduler.busyDescription)")

        // 新会话不被旧积压拖死：新上下文照常准入并执行。
        let freshContext = scheduler.makeContext(token: TransitionToken(generation: 3), kind: .settleLayout)
        let freshResult: Bool? = await scheduler.request(context: freshContext, identities: []) { _ in true }
        XCTAssertEqual(freshResult, true, "新会话必须能正常准入并执行新操作")
        XCTAssertTrue(scheduler.isIdle, "新操作结束后通道必须静默：\(scheduler.busyDescription)")
    }

    /// #6：A 挂在 gate 上时，另一条独立任务提交 B。B 必须排队，不能在 A 的 `await` 期间
    /// 借着共享的"在通道里"状态就地执行。判据是动作序列，不是时间。
    func testIndependentRequestQueuesBehindSuspendedOperation() async {
        let scheduler = HostScheduler.make(sessionID: sessionID)
        let gate = TestGate()
        var actions: [String] = []
        let firstContext = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .settleLayout)
        let first = Task { () -> Void in
            _ = await scheduler.request(context: firstContext, identities: []) { _ in
                actions.append("A-开始")
                await gate.wait()
                actions.append("A-结束")
            }
        }
        await pendingUntil { scheduler.inFlightCount == 1 && actions == ["A-开始"] }

        // 独立任务在 A 的 await 处到达：它没有通道身份，只能排队。
        let secondContext = scheduler.makeContext(token: TransitionToken(generation: 2), kind: .settleLayout)
        let second = Task { () -> Void in
            _ = await scheduler.request(context: secondContext, identities: []) { _ in actions.append("B") }
        }
        await pendingUntil { scheduler.queuedCount == 1 }
        XCTAssertEqual(actions, ["A-开始"], "A 未结束或未合法取消前 B 不得开始：\(actions)")

        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(actions, ["A-开始", "A-结束", "B"],
                       "B 只能在 A 离开通道之后按顺序执行：\(actions)")
        XCTAssertTrue(scheduler.isIdle)
    }

    /// #6 的另一半：合法嵌套（补偿、同一次操作里的子动作）必须继续就地执行，
    /// 不能因为换成身份判断就把正常补偿路径卡死在队列里。
    func testNestedRequestInsideChannelRunsInlineAndKeepsOrder() async {
        let scheduler = HostScheduler.make(sessionID: sessionID)
        var actions: [String] = []
        var nestedResult: Int?
        let outerContext = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .mainSwitch)
        let outer = Task { () -> Void in
            _ = await scheduler.request(context: outerContext, identities: []) { _ in
                actions.append("外层-开始")
                let nestedContext = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .compensation)
                nestedResult = await scheduler.request(context: nestedContext, identities: []) { _ in
                    actions.append("嵌套")
                    return 7
                }
                actions.append("外层-结束")
            }
        }
        await outer.value

        XCTAssertEqual(nestedResult, 7, "嵌套请求必须就地拿到自己的结论")
        XCTAssertEqual(actions, ["外层-开始", "嵌套", "外层-结束"],
                       "嵌套只能在外层已有的通道位置就地执行、按原顺序完成：\(actions)")
        XCTAssertEqual(scheduler.queuedCount, 0, "嵌套不得在队列里留下第二张票")
        XCTAssertTrue(scheduler.isIdle)
    }

    /// #5：在途恢复写入永不返回时，注入的到点信号必须让 `drain(until:)` 返回 false。
    /// 到期后不再发起新的恢复写入，未完成事务原样留在日志里。全程手动时钟 + 手动唤醒，不赌真实 sleep。
    func testDrainDeadlineWinsAgainstHangingRestoreAndKeepsJournal() async throws {
        let clock = HostClock()
        let wakes = DeadlineWakes()
        let scheduler = GeometryOperationScheduler(now: { clock.stamp },
                                                   scheduleDeadline: { _, fire in wakes.append(fire) })
        scheduler.adopt(sessionID: sessionID, epoch: 0)
        let rig = try await makeRig(windowCount: 2, scheduler: scheduler)

        let identities = [HostFixtures.identity(0), HostFixtures.identity(1)]
        let expanded = CGRect(x: 120, y: 120, width: 1_000, height: 640)
        for (index, identity) in identities.enumerated() {
            await rig.store.apply(WindowTransaction(sessionID: sessionID,
                                                    identity: identity,
                                                    bundleID: "com.test.app\(identity.windowID)",
                                                    originalFrame: FakeCatalogSource.frame(for: index),
                                                    originalDisplayID: HostFixtures.display.id)
                .markingPlanned(frame: expanded, displayID: HostFixtures.display.id)
                .markingWritten(readBack: expanded, displayID: HostFixtures.display.id))
            if let element = rig.catalogSource.element(for: identity) {
                rig.writer.setInitialFrame(expanded, for: element)
            }
        }
        XCTAssertEqual(rig.store.unfinished.count, 2, "前置事实：两条事务都还欠恢复")

        let deadline = scheduler.deadline(after: .seconds(2))
        // 第一笔恢复的 AX 写入停在"命令已排队、调用还没返回"这一刻：模拟无响应应用。
        rig.writer.gatesNextWrite = true
        let restore = Task {
            await rig.recovery.restoreOnQuit(token: TransitionToken(generation: 1), deadline: deadline)
        }
        await pendingUntil { rig.writer.isBlockedInWrite }

        var drained: Bool?
        let drain = Task { drained = await scheduler.drain(until: deadline) }
        await pendingUntil { wakes.count == 1 }
        XCTAssertNil(drained, "写入永不返回时 drain 不得提前返回")

        // 早醒一次：必须重新挂到点上，不能把"提前唤醒"误判成到期。
        wakes.fireAll()
        await pendingUntil { wakes.count == 1 }
        XCTAssertNil(drained, "未真正到点时 drain 必须继续等待")
        XCTAssertTrue(rig.writer.isBlockedInWrite, "前置事实：写入仍然挂在那里")

        // 手动推进到点并触发唤醒：静默与截止竞速，截止先到 → false。
        clock.advance(seconds: 3)
        wakes.fireAll()
        await drain.value
        XCTAssertEqual(drained, false, "预算到点仍未静默时 drain 必须返回 false")
        XCTAssertEqual(rig.writer.totalWrites, 0, "挂起的那笔还没落笔，此时不得有写入")

        // 放行挂起的那一笔：它已在途，按事实结算；下一笔恢复必须因预算已尽而不再发起。
        rig.writer.openGate()
        let report = await restore.value
        XCTAssertEqual(report.items.count, 1, "只有到期前已经开始的那一笔被恢复：\(report.items)")
        XCTAssertEqual(report.deferredByDeadline.count, 1,
                       "预算已尽时必须按「推迟」回报：\(report.deferredByDeadline)")
        XCTAssertEqual(rig.writer.totalWrites, 1, "到期后不得再发起第二条恢复写入：\(rig.writer.writtenFrames)")

        let deferred = try XCTUnwrap(report.deferredByDeadline.first)
        XCTAssertEqual(rig.store.entry(for: deferred)?.state.requiresRestore, true,
                       "未确认恢复的事务必须原样留在日志里")
        XCTAssertEqual(rig.store.unfinished.map(\.identity), [deferred],
                       "日志里只该剩那一条没动的未完成事务")
        let deferredElement = try XCTUnwrap(rig.catalogSource.element(for: deferred))
        let deferredFrame = await rig.writer.currentFrame(of: deferredElement)
        XCTAssertEqual(deferredFrame, expanded, "被推迟的窗口必须还在展开尺寸：动过它就是新写入")
        XCTAssertTrue(scheduler.isIdle, "在途那笔收口后通道应回到静默：\(scheduler.busyDescription)")
    }

    /// 装配一条从交换协调器到写入器的真实链路：目录、日志、调度器、恢复、焦点全部是生产类型，
    /// 只有 AX 与几何写入是替身。共用同一处接线，避免在三份拷贝里各自漂移。
    /// `scheduler` 只在需要注入手动时钟 / 截止唤醒的契约用例里传入（#5）。
    private func makeRig(windowCount: Int = 1,
                         scheduler: GeometryOperationScheduler? = nil) async throws -> DividerRig {
        let rig = DividerRig(sessionID: sessionID,
                             metal: metal,
                             journalDirectory: try makeScratchDirectory(),
                             defaults: transientDefaults(),
                             windowCount: windowCount,
                             scheduler: scheduler)
        await rig.catalog.refreshAndWait(reason: .reconcile)
        rig.coordinator.directive = { _ in .proceed }
        rig.coordinator.onEvent = { event in rig.events.append(event) }
        return rig
    }

    private func geometryResults(_ events: [SessionEvent]) -> [GeometryWriteResult] {
        events.compactMap { if case let .geometryWriteFinished(result) = $0 { return result } else { return nil } }
    }

    private func pendingUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时（\(timeout)s）")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VistileDividerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchDirectories.append(url)
        return url
    }

    /// 测试不碰用户的偏好存储：每次用一次性 suite，结束再把该 domain 清掉。
    private func transientDefaults() -> UserDefaults {
        let name = "com.misswell.Vistile.hosttests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("无法创建一次性 defaults suite：\(name)")
            return .standard
        }
        testDefaultsSuites.append(name)
        return defaults
    }
}

/// 只保存监听回调和令牌，不注册系统监听，也不发送全局事件或要求 AX 权限。
@MainActor
private final class DividerEventMonitors {
    enum Kind: Hashable { case local, global }
    private(set) var active: Set<Kind> = []
    private(set) var removed: [Kind] = []
    private(set) var localHandler: ((NSEvent) -> NSEvent?)?
    private(set) var globalHandler: ((NSEvent) -> Void)?

    var monitoring: WorkbenchDividerView.EventMonitoring {
        WorkbenchDividerView.EventMonitoring(addLocal: { [self] mask, handler in
            XCTAssertEqual(mask, .keyDown)
            XCTAssertTrue(active.insert(.local).inserted, "不得重复注册局部监听")
            localHandler = handler
            return Kind.local
        }, addGlobal: { [self] mask, handler in
            XCTAssertEqual(mask, .keyDown)
            XCTAssertTrue(active.insert(.global).inserted, "不得重复注册全局监听")
            globalHandler = handler
            return Kind.global
        }, remove: { [self] token in
            guard let kind = token as? Kind else { return XCTFail("未知监听令牌") }
            XCTAssertNotNil(active.remove(kind), "每个监听令牌只能移除一次")
            removed.append(kind)
            switch kind {
            case .local: localHandler = nil
            case .global: globalHandler = nil
            }
        })
    }
}

/// 分隔线结算链路的真实装配：目录、日志、调度器、恢复、焦点、交换协调器都是生产类型，
/// 只有 AX 与几何写入用替身（面板一律摆屏外，不碰用户桌面）。
@MainActor
final class DividerRig {
    let catalogSource: FakeCatalogSource
    let writer: FakeGeometryWriter
    let catalog: WindowCatalog
    let store: WindowJournalStore
    let scheduler: GeometryOperationScheduler
    let recovery: RecoveryCoordinator
    let focus: FocusCoordinator
    let coordinator: WorkbenchSwitchCoordinator
    var events: [SessionEvent] = []

    init(sessionID: UUID,
         metal: MetalContext,
         journalDirectory: URL,
         defaults: UserDefaults,
         windowCount: Int,
         scheduler suppliedScheduler: GeometryOperationScheduler? = nil) {
        let permissions = FakePermissions()
        let catalogSource = FakeCatalogSource()
        let writer = FakeGeometryWriter()
        catalogSource.addWindows(Array(0..<windowCount))
        let catalog = WindowCatalog(permissions: permissions,
                                    axSource: catalogSource,
                                    contentSource: catalogSource,
                                    displaySource: FakeDisplaySource(displays: [HostFixtures.display]))
        let store = WindowJournalStore(fileName: "session-journal.json",
                                       sessionID: sessionID,
                                       baseDirectory: journalDirectory)
        let scheduler = suppliedScheduler ?? HostScheduler.make(sessionID: sessionID)
        let settings = SettingsModel(defaults: defaults)
        let recorder = CompatibilityRecorder(fileName: "workbench-divider-test-\(UUID().uuidString)")
        let recovery = RecoveryCoordinator(store: store,
                                           writer: writer,
                                           catalog: catalog,
                                           settings: settings,
                                           permissions: permissions,
                                           processIdentity: FakeProcessIdentity(),
                                           scheduler: scheduler)
        let focus = FocusCoordinator(catalog: catalog,
                                     metal: metal,
                                     writer: writer,
                                     store: store,
                                     settings: settings,
                                     metrics: .shared,
                                     recorder: recorder,
                                     recovery: recovery,
                                     permissions: permissions,
                                     scheduler: scheduler)
        let coordinator = WorkbenchSwitchCoordinator(catalog: catalog,
                                                     writer: writer,
                                                     store: store,
                                                     recovery: recovery,
                                                     focus: focus,
                                                     permissions: permissions,
                                                     metrics: .shared,
                                                     recorder: recorder,
                                                     scheduler: scheduler)
        self.catalogSource = catalogSource
        self.writer = writer
        self.catalog = catalog
        self.store = store
        self.scheduler = scheduler
        self.recovery = recovery
        self.focus = focus
        self.coordinator = coordinator
    }

    /// 结算要求该窗口已有事务（方案 §10.2：写前必须存在恢复记录）。用会话原位置把它备好。
    func prime(transactionFor identity: WindowIdentity, original: CGRect) async throws {
        await store.apply(WindowTransaction(sessionID: scheduler.sessionID,
                                            identity: identity,
                                            bundleID: "com.test.app\(identity.windowID)",
                                            originalFrame: original,
                                            originalDisplayID: HostFixtures.display.id)
            .markingPlanned(frame: original, displayID: HostFixtures.display.id)
            .markingWritten(readBack: original, displayID: HostFixtures.display.id))
    }
}

/// 测试用门闩：把在途操作按确定点挂起，由用例决定何时放行（不靠真实 sleep 赌时序）。
/// 用锁而不是 `@MainActor`：门闩本身要能在替身/调度器的闭包里直接 await。
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        lock.lock()
        let alreadyOpen = isOpen
        lock.unlock()
        if alreadyOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }
}

/// 注入给调度器的截止唤醒收集器：用例手动触发"到点"，不依赖真实计时器（方案 §14.4、§15.2）。
private final class DeadlineWakes: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@MainActor () -> Void] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    func append(_ fire: @escaping @MainActor () -> Void) {
        lock.lock(); pending.append(fire); lock.unlock()
    }

    @MainActor
    func fireAll() {
        lock.lock()
        let fires = pending
        pending = []
        lock.unlock()
        for fire in fires { fire() }
    }
}
