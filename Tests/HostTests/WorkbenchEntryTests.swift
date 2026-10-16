import AppKit
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// 入口链路与初选交接的宿主回归（方案 §18.2 H15/H16）。
///
/// 两项都要"从真实入口到真实视图事件"的整条链路：目录、捕获、几何写入、权限与事务日志
/// 全部用替身注入（方案 §15.1），面板一律摆在主屏之外的负坐标；测试宿主不注册全局热键、
/// 也不往用户菜单栏插图标。
///
/// 显式未覆盖（不计为通过，留给已授权正式版的实机验收 §19）：
/// - 真实组合键的物理按下：这里只调用与生产同一条 `hotKey.onFire` 接线，不做 RegisterEventHotKey。
/// - 菜单弹层的真实显示与鼠标点击：这里用 `NSApp.sendAction` 走 AppKit 同一条动作分发。
@MainActor
final class WorkbenchEntryTests: XCTestCase {
    private var permissions: FakePermissions!
    private var catalogSource: FakeCatalogSource!
    private var writer: FakeGeometryWriter!
    private var settings: SettingsModel!
    private var recorder: CompatibilityRecorder!
    private var store: WindowJournalStore!
    private var journalDirectory: URL!
    private var scratchDirectories: [URL] = []
    private var testDefaultsSuites: [String] = []
    private var metal: MetalContext!
    private var renderer: OverviewRenderer!
    private var catalog: WindowCatalog!
    private var capture: CaptureCoordinator!
    private var coordinator: AppCoordinator!
    private var runs: [WindowIdentity: FakeCaptureRun] = [:]

    private var displayID: UInt32 { HostFixtures.display.id }

    override func setUpWithError() throws {
        try super.setUpWithError()
        permissions = FakePermissions()
        catalogSource = FakeCatalogSource()
        writer = FakeGeometryWriter()
        settings = SettingsModel(defaults: transientDefaults())
        recorder = CompatibilityRecorder(fileName: "workbench-entry-host-test-\(UUID().uuidString)")
        journalDirectory = try makeScratchDirectory()
        metal = try HostFixtures.metalContext()
        renderer = try HostFixtures.renderer(metal: metal)
        // 最小化事实只有一个来源：应用（替身写入器）。
        catalogSource.minimizedReader = { [weak catalogSource, weak writer] identity in
            guard let element = catalogSource?.element(for: identity) else { return false }
            return writer?.isMinimized(for: element) ?? false
        }
        catalogSource.addWindows([0, 1, 2, 3])
    }

    override func tearDown() {
        coordinator?.hideNow()
        coordinator?.capture.stopAll(releasingMailboxes: true)
        coordinator = nil
        capture = nil
        catalog = nil
        runs = [:]
        renderer = nil
        metal = nil
        // 测试临时拿到的前台激活必须还给系统。
        NSApp.deactivate()
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

    // MARK: - 组装

    private func makeCoordinator() -> AppCoordinator {
        catalog = WindowCatalog(permissions: permissions,
                                axSource: catalogSource,
                                contentSource: catalogSource,
                                displaySource: FakeDisplaySource(displays: [HostFixtures.display]),
                                sheetSource: catalogSource)
        capture = CaptureCoordinator(metal: metal,
                                     catalog: catalog,
                                     sampleQueue: DispatchQueue(label: "com.misswell.Vistile.entrytests.capture"),
                                     runFactory: { [weak self] request in
                                         let run = FakeCaptureRun(request: request)
                                         self?.runs[request.identity] = run
                                         return run
                                     },
                                     singleFrame: { _, _ in .failed })
        store = WindowJournalStore(fileName: "session-journal.json",
                                   sessionID: UUID(),
                                   baseDirectory: journalDirectory)
        let coordinator = AppCoordinator(settings: settings,
                                         permissions: permissions,
                                         metrics: .shared,
                                         recorder: recorder,
                                         metal: metal,
                                         renderer: renderer,
                                         catalog: catalog,
                                         capture: capture,
                                         journal: store,
                                         writer: writer,
                                         registersGlobalHotKey: false)
        coordinator.start()
        self.coordinator = coordinator
        return coordinator
    }

    private func waitForVisibleOverview() throws {
        waitUntil(timeout: 5) { self.coordinator.state.phase.isVisible }
        XCTAssertTrue(coordinator.state.phase.isVisible,
                      "入口打开后必须真的进到可见会话，实际 phase=\(coordinator.state.phase)")
        waitUntil(timeout: 5) { self.coordinator.state.records.count == 4 }
    }

    private func overviewView() throws -> OverviewContentView {
        let controller = try XCTUnwrap(coordinator.controllers[displayID],
                                       "总览面板必须按屏建好")
        return controller.contentView
    }

    // MARK: - H15 全部入口：先显示总览，不写 AX

    func testEveryEntryOpensOverviewFirstWithoutAnyGeometryWrite() throws {
        let coordinator = makeCoordinator()
        // "重启"：全新协调器没有任何会话，重启后第一次打开必须先落在总览（方案 §4.1、§16）。
        XCTAssertFalse(coordinator.state.phase.isVisible, "启动完成时还在隐藏态")
        XCTAssertEqual(coordinator.state.mode, .overview)
        XCTAssertTrue(coordinator.workbenchControllers.isEmpty, "没点卡片之前不存在两栏面板")

        let menuBar = MenuBarController(coordinator: coordinator,
                                        settings: settings,
                                        permissions: PermissionManager(),
                                        installsStatusItem: false)
        XCTAssertNil(menuBar.statusItem, "测试宿主不往用户菜单栏插图标")
        menuBar.menuNeedsUpdate(menuBar.statusMenu)
        XCTAssertTrue(menuBar.openItem.isEnabled, "隐藏态「打开窗口总览」必须可用")
        XCTAssertFalse(menuBar.backItem.isEnabled, "还没进工作台，「回到全部窗口」是空动作")
        XCTAssertFalse(menuBar.hideItem.isEnabled, "隐藏态「隐藏」没有对象")

        // 菜单入口：走 AppKit 真实动作分发，而不是直接调协调器方法。
        let menuOpen = try XCTUnwrap(menuBar.openItem.action, "「打开窗口总览」必须挂着动作")
        NSApp.sendAction(menuOpen, to: menuBar.openItem.target, from: menuBar.openItem)
        try waitForVisibleOverview()

        XCTAssertEqual(coordinator.state.mode, .overview, "菜单打开落在总览，绝不能直接进工作台")
        XCTAssertNil(coordinator.workbenchPresentation, "没点卡片就没有 L 型投影")
        XCTAssertTrue(coordinator.workbenchControllers.isEmpty)
        XCTAssertEqual(coordinator.cardClickCount, 0)
        let controller = try XCTUnwrap(coordinator.controllers[displayID])
        XCTAssertTrue(controller.isVisible, "总览面板必须真的上屏")
        XCTAssertEqual(coordinator.cardRects.count, 4, "四张卡片各自有命中几何")
        XCTAssertEqual(writer.totalWrites, 0, "只打开总览：一个窗口都不许动")
        XCTAssertEqual(writer.raiseCount + writer.focusCount, 0, "打开总览不激活任何真实窗口")
        XCTAssertTrue(store.unfinished.isEmpty, "没写过几何就没有待恢复事务")

        menuBar.menuNeedsUpdate(menuBar.statusMenu)
        XCTAssertFalse(menuBar.openItem.isEnabled, "已经开着时「打开」不能重复入口")
        XCTAssertTrue(menuBar.hideItem.isEnabled, "可见态「隐藏」必须可用")

        // 隐藏后走快捷键入口：同一个会话里也必须先回总览。
        NSApp.sendAction(try XCTUnwrap(menuBar.hideItem.action),
                         to: menuBar.hideItem.target,
                         from: menuBar.hideItem)
        waitUntil(timeout: 5) { !self.coordinator.state.phase.isVisible }
        XCTAssertFalse(coordinator.state.phase.isVisible, "菜单「隐藏」必须真的收起会话")

        let fire = try XCTUnwrap(coordinator.hotKey.onFire, "start() 必须把快捷键接到打开动作上")
        fire()
        try waitForVisibleOverview()

        XCTAssertEqual(coordinator.state.mode, .overview, "快捷键打开同样先落在总览（方案 §11）")
        XCTAssertNil(coordinator.workbenchPresentation)
        XCTAssertTrue(coordinator.workbenchControllers.isEmpty)
        XCTAssertEqual(writer.totalWrites, 0, "两次入口合计仍然零 AX 写入")
    }

    // MARK: - H16 初选真实事件：点击之后才建两栏并交接真实窗口

    func testCardClickBuildsRailsAndHandsOverTheRealWindow() throws {
        let coordinator = makeCoordinator()
        coordinator.toggleOverview()
        try waitForVisibleOverview()

        let view = try overviewView()
        view.layoutSubtreeIfNeeded()
        let identity = HostFixtures.identity(0)
        let cell = try XCTUnwrap(coordinator.cardRects[identity], "初选目标必须有总览格子")
        let point = HostFixtures.viewPoint(of: cell, in: view, cgOrigin: HostFixtures.offscreenOrigin)
        XCTAssertTrue(view.bounds.contains(point), "取样点必须落在内容视图内")

        // 前提：这一击之前没有任何两栏面板与几何写入。
        XCTAssertTrue(coordinator.workbenchControllers.isEmpty, "点击之前不许建两栏（方案 §4.1）")
        XCTAssertNil(coordinator.workbenchPresentation)
        XCTAssertEqual(writer.totalWrites, 0)

        // 事务必须先落盘，才轮到写 AX（方案 §6.2）：写入发起那一刻旁路核对。
        var journalSettledBeforeWrite: Bool?
        writer.onWillWrite = { [weak store] _ in
            journalSettledBeforeWrite = store?.entry(for: identity)?.state.requiresRestore == true
        }

        let down = HostEvents.mouse(.leftMouseDown, in: view.window, point: point)
        let up = HostEvents.mouse(.leftMouseUp, in: view.window, point: point)
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        XCTAssertEqual(coordinator.cardClickCount, 1, "真实视图事件必须只转成一次卡片选择")
        XCTAssertEqual(coordinator.viewBackgroundClickCount, 0, "落在卡片上的点击不是背景点击")

        waitUntil(timeout: 5) { self.coordinator.state.mode == .workbench }
        XCTAssertEqual(coordinator.state.mode, .workbench,
                       "选择之后必须真的进到工作台，实际 phase=\(coordinator.state.phase)")

        // 真实窗口交接：写的是被选中的那一个，且只有它。
        XCTAssertEqual(writer.totalWrites, 1, "进入工作台只允许写主窗口一次：\(writer.writtenFrames)")
        XCTAssertEqual(journalSettledBeforeWrite, true, "第一次 AX 写入之前事务必须已经在日志里")
        XCTAssertGreaterThanOrEqual(writer.focusCount + writer.raiseCount, 1, "主窗口必须被带到前台")

        let presentation = try XCTUnwrap(coordinator.workbenchPresentation)
        XCTAssertEqual(presentation.mainIdentity, identity)
        XCTAssertEqual(presentation.cards.count, 3, "其余三个窗口进两栏")
        let written = try XCTUnwrap(writer.writtenFrames.first)
        XCTAssertTrue(presentation.snapshot.layout.mainRect.contains(written),
                      "写进去的几何必须落在主区内：written=\(written) main=\(presentation.snapshot.layout.mainRect)")

        let controller = try XCTUnwrap(coordinator.workbenchControllers[displayID],
                                       "进入工作台必须建出这一屏的两栏面板")
        XCTAssertTrue(controller.isVisible, "两栏必须真的上屏，而不是只建了对象")
        XCTAssertFalse(coordinator.controllers[displayID]?.isVisible ?? true,
                       "总览全屏层必须收起，否则会盖住真实窗口")

        // 两栏面板同样摆在主屏之外：测试期间不落进用户桌面。
        XCTAssertEqual(coordinator.workbenchControllers.count, 1, "单屏只建一套两栏面板")
        XCTAssertTrue(store.unfinished.contains { $0.identity == identity },
                      "写过的窗口必须留下待恢复事务，退出时才能还原")
    }

    // MARK: - 工具区自适应（方案 §11.2 下界 96pt 与 §5.1 工具区）

    func testToolbarFitsTheMinimumCornerHeightWithoutHidingFacts() throws {
        let controller = WorkbenchWindowController(display: HostFixtures.display,
                                                   mapper: HostFixtures.mapper,
                                                   metal: metal)
        defer { controller.hide() }
        let fixture = HostWorkbench.fixture()
        let presentation = fixture.presentation
        controller.update(presentation: presentation,
                          renderer: renderer,
                          mailboxProvider: { _ in nil },
                          showsTitles: true,
                          searchQuery: "",
                          hint: "屏幕录制尚未就绪")
        let toolbar = controller.toolbarView

        // 最小角落：内区高度 ×0.11 的 clamp 下界 96（方案 §11.2），本机实测 96.36。
        for height in [96.36, 118, 160] as [CGFloat] {
            toolbar.frame = NSRect(x: 0, y: 0, width: 202, height: height)
            toolbar.needsLayout = true
            toolbar.layoutSubtreeIfNeeded()
            for subview in toolbar.subviews {
                XCTAssertGreaterThanOrEqual(subview.frame.minX, 0,
                                            "高度 \(height)：\(type(of: subview)) 横向溢出")
                XCTAssertGreaterThanOrEqual(subview.frame.minY, 0,
                                            "高度 \(height)：\(type(of: subview)) 纵向溢出 \(subview.frame)")
                XCTAssertLessThanOrEqual(subview.frame.maxY, height,
                                         "高度 \(height)：\(type(of: subview)) 超出工具区 \(subview.frame)")
                XCTAssertLessThanOrEqual(subview.frame.maxX, toolbar.bounds.width,
                                         "高度 \(height)：\(type(of: subview)) 超出右边界 \(subview.frame)")
                XCTAssertGreaterThan(subview.frame.width, 0, "高度 \(height)：出现了零宽子视图")
            }
            // 五个入口在最小高度下也全部存在且可命中：不靠隐藏事实换取不溢出。
            XCTAssertGreaterThan(toolbar.allWindowsButtonFrame.width, 0)
            XCTAssertGreaterThan(toolbar.moreButtonFrame.width, 0)
            XCTAssertGreaterThan(toolbar.searchFieldFrame.width, 0)
            let texts = toolbar.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(texts.contains { $0.hasPrefix("可见") }, "高度 \(height)：计数事实不许消失")
            XCTAssertTrue(texts.contains("屏幕录制尚未就绪"), "高度 \(height)：提示文字不许消失")
        }
    }

    // MARK: - 组装辅助

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VistileEntryTests-\(UUID().uuidString)", isDirectory: true)
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
