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
        // 面板窗口 = 栏 ∪ 空带：分隔线命中区必须落在某个窗口里才收得到鼠标（方案 §11.2）。
        XCTAssertEqual(controller.topPanelFrame, HostFixtures.mapper.cgToAppKit(layout.topPanelWindowRect).integral)
        XCTAssertEqual(controller.sidePanelFrame, HostFixtures.mapper.cgToAppKit(layout.sidePanelWindowRect).integral)

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
                       fixture.layout.style.topHeightRange.upperBound,
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

    // MARK: - H08 设备级事实：串行执行，最终尺寸不被旧写入覆盖

    func testSettleSerializesWritesAndFinalFrameWins() async throws {
        let permissions = FakePermissions()
        let catalogSource = FakeCatalogSource()
        let writer = FakeGeometryWriter()
        let settings = SettingsModel(defaults: transientDefaults())
        let recorder = CompatibilityRecorder(fileName: "workbench-divider-test-\(UUID().uuidString)")
        let journalDirectory = try makeScratchDirectory()
        let store = WindowJournalStore(fileName: "session-journal.json",
                                       sessionID: sessionID,
                                       baseDirectory: journalDirectory)
        let processIdentity = FakeProcessIdentity()

        catalogSource.addWindows([0])
        let catalog = WindowCatalog(permissions: permissions,
                                    axSource: catalogSource,
                                    contentSource: catalogSource,
                                    displaySource: FakeDisplaySource(displays: [HostFixtures.display]))
        await catalog.refreshAndWait(reason: .reconcile)
        let recovery = RecoveryCoordinator(store: store,
                                           writer: writer,
                                           catalog: catalog,
                                           settings: settings,
                                           permissions: permissions,
                                           processIdentity: processIdentity)

        let a = HostFixtures.identity(0)
        let element = try XCTUnwrap(catalogSource.element(for: a))
        let initial = FakeCatalogSource.frame(for: 0)
        writer.setInitialFrame(initial, for: element)
        store.apply(WindowTransaction(sessionID: sessionID,
                                      identity: a,
                                      bundleID: "com.test.app\(a.windowID)",
                                      originalFrame: initial,
                                      originalDisplayID: HostFixtures.display.id)
            .markingPlanned(frame: initial, displayID: HostFixtures.display.id)
            .markingWritten(readBack: initial, displayID: HostFixtures.display.id))

        let focus = FocusCoordinator(catalog: catalog,
                                     metal: metal,
                                     writer: writer,
                                     store: store,
                                     settings: settings,
                                     metrics: .shared,
                                     recorder: recorder,
                                     recovery: recovery,
                                     permissions: permissions)
        let coordinator = WorkbenchSwitchCoordinator(catalog: catalog,
                                                     writer: writer,
                                                     store: store,
                                                     recovery: recovery,
                                                     focus: focus,
                                                     permissions: permissions,
                                                     metrics: .shared,
                                                     recorder: recorder)
        var events: [SessionEvent] = []
        coordinator.onEvent = { events.append($0) }
        coordinator.directive = { _ in .proceed }

        // 拖动里相邻两次结算：第一次写入被卡在途中，第二次（更靠近松手值）随即排队。
        let first = initial.insetBy(dx: 40, dy: 20)
        let second = first.offsetBy(dx: -30, dy: 30)
        let token1 = TransitionToken(generation: 1)
        let token2 = TransitionToken(generation: 2)
        writer.gatesNextWrite = true
        coordinator.settle(a, targetFrame: first, displayID: HostFixtures.display.id, token: token1)
        await pendingUntil { writer.isBlockedInWrite }
        coordinator.settle(a, targetFrame: second, displayID: HostFixtures.display.id, token: token2)
        XCTAssertEqual(writer.totalWrites, 0, "第一次写入还没回来，第二次只能排队")
        writer.openGate()

        await pendingUntil { self.geometryResults(events).count == 2 }
        XCTAssertEqual(writer.writtenFrames, [first, second], "两次写入按发起顺序串行执行")
        let settled = await writer.currentFrame(of: element)
        XCTAssertEqual(settled, second, "设备上的最终几何 = 最后一次结算的目标：旧写入不覆盖它")
        XCTAssertEqual(geometryResults(events).map(\.token), [token1, token2], "每次结算各有自己的令牌回报")
        XCTAssertEqual(geometryResults(events).map(\.targetFrame), [first, second])

        // 迟到的旧令牌读回不得清掉在途写入：reducer 的令牌守卫由核心 W23 覆盖，这里断言事件如实分开。
        coordinator.cancel()
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
