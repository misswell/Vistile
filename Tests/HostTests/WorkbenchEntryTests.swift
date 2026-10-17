import AppKit
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// 入口链路与初选交接的宿主回归（方案 §18.2 H15/H16），外加退出链的恢复所有权（A39）：
/// 只有把整个 `AppCoordinator` 装起来，才看得到"两个退出入口抢同一个窗口"这件事。
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
    /// 替身应用是本机不存在的假 PID：进程实例判定不注入就一律读成"进程已退出"，
    /// 退出恢复会直接按"窗口已消失"结算，永远走不到写回原 frame 那一步。
    private var processIdentity: FakeProcessIdentity!
    /// 协调器回报给用户的每一句话：入口失败时必须能直接看到"是哪一步拦住的"（方案 §14、§22）。
    private var statuses: [String] = []
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
        // 真实窗口的 AXSize/AXPosition 一直读得到，替身也必须一直答得出：
        // 写前实读读不到时生产按事实拒绝写入（方案 §6.2），所以这里给每个句柄一个初值几何。
        for index in [0, 1, 2, 3] {
            if let element = catalogSource.element(for: HostFixtures.identity(index)) {
                writer.setInitialFrame(FakeCatalogSource.frame(for: index), for: element)
            }
        }
    }

    override func tearDown() {
        coordinator?.hideNow()
        coordinator?.capture.stopAll(releasingMailboxes: true)
        coordinator = nil
        capture = nil
        catalog = nil
        runs = [:]
        statuses = []
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
        processIdentity = FakeProcessIdentity()
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
                                         registersGlobalHotKey: false,
                                         processIdentity: processIdentity)
        coordinator.start()
        coordinator.onStatus = { [weak self] text in self?.statuses.append(text) }
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
                       "选择之后必须真的进到工作台，实际 phase=\(coordinator.state.phase)，回报=\(statuses)")

        // 真实窗口交接：写的是被选中的那一个，且只有它。
        XCTAssertEqual(writer.totalWrites, 1, "进入工作台只允许写主窗口一次：\(writer.writtenFrames) 回报=\(statuses)")
        XCTAssertEqual(journalSettledBeforeWrite, true,
                       "第一次 AX 写入之前事务必须已经在日志里：回报=\(statuses)")
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

    // MARK: - A39 两种退出入口重复触发：仅一恢复所有者、一次终止回调（方案 §14.2、§14.4）

    /// 退出时同时存在两个恢复入口：⌘Q 走进来的终止链，和状态机为同一批窗口算出的 `.restoreAll` 效果；
    /// 第二次 ⌘Q 还会再敲一次链入口。链必须独占几何写入，收尾必须只回报一次。
    ///
    /// 判据都用替身应用上看到的外部事实：被写过的窗口只被恢复一次、停在原始 frame、事务落定后从日志消失。
    /// 「唯一恢复所有者」那条回报同时证明第二个恢复入口真的到过——否则这条断言会因为什么都没发生而空过。
    func testTwoQuitEntriesLeaveOneRecoveryOwnerAndOneTerminationCallback() async throws {
        let coordinator = makeCoordinator()
        coordinator.toggleOverview()
        try await awaitUntil(timeout: 5) { self.coordinator.state.records.count == 4 }
        let identity = HostFixtures.identity(0)
        try selectCard(identity)
        try await awaitUntil(timeout: 5) { self.coordinator.state.mode == .workbench }
        let original = FakeCatalogSource.frame(for: 0)
        XCTAssertTrue(store.unfinished.contains { $0.identity == identity },
                      "前提：进入工作台写过的窗口必须留下待恢复事务，否则退出没有东西可恢复：\(writer.writtenFrames)")
        XCTAssertEqual(writer.writtenFrames.filter { $0 == original }.count, 0,
                       "前提：退出之前谁都不该被写回原位")

        // 两个退出入口前后脚进来：菜单「退出」，以及紧随其后的第二次 ⌘Q。
        var firstSettledCount = 0
        var secondSettled = false
        coordinator.beginTermination { firstSettledCount += 1 }
        coordinator.beginTermination { secondSettled = true }

        try await awaitUntil(timeout: 5) { firstSettledCount > 0 }
        XCTAssertEqual(firstSettledCount, 1, "终止收尾只能回报一次")
        XCTAssertFalse(secondSettled, "第二个链入口不能自己再收尾一次：两遍回调会把终止答复发两遍")
        XCTAssertTrue(statuses.contains { $0.contains("唯一恢复所有者") },
                      "状态机的 .restoreAll 必须被链接住并留下轨迹：\(statuses)")

        let restoreWrites = writer.writtenFrames.filter { $0 == original }
        XCTAssertEqual(restoreWrites.count, 1,
                       "同一个窗口只许被恢复一次，第二条恢复路径会把原 frame 写两遍：\(writer.writtenFrames)")
        let element = try XCTUnwrap(catalogSource.element(for: identity))
        let frameAfterQuit = await writer.currentFrame(of: element)
        XCTAssertEqual(frameAfterQuit, original, "退出后窗口必须回到原始 frame")
        XCTAssertNil(store.entry(for: identity), "确认恢复完的事务不该留给下次启动")
        XCTAssertTrue(store.unfinished.isEmpty, "退出收敛后日志不该还挂着本会话事务")
        XCTAssertTrue(coordinator.focus.isIdle, "退出收敛后不能留下在途恢复")
        XCTAssertFalse(coordinator.switchCoordinator.isBusyIncludingScheduler, "工作台链也必须彻底交还")
        XCTAssertFalse(coordinator.workbenchControllers.values.contains { $0.isVisible },
                       "退出必须把两栏面板拆掉，恢复期间不能还盖着屏幕")
    }

    /// 真实视图事件选卡：与 H16 同一条链路，退出的前提状态得靠它把窗口真的写进主区。
    private func selectCard(_ identity: WindowIdentity) throws {
        let view = try overviewView()
        view.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(coordinator.cardRects[identity], "初选目标必须有总览格子")
        let point = HostFixtures.viewPoint(of: cell, in: view, cgOrigin: HostFixtures.offscreenOrigin)
        XCTAssertTrue(view.bounds.contains(point), "取样点必须落在内容视图内")
        view.mouseDown(with: HostEvents.mouse(.leftMouseDown, in: view.window, point: point))
        view.mouseUp(with: HostEvents.mouse(.leftMouseUp, in: view.window, point: point))
    }

    /// 异步用例里的等待：让出 MainActor 好让生产的任务链继续跑（同步用例用的 runloop 泵在异步体里不推进），
    /// 到点就失败，不靠固定 sleep 赌时序（方案 §18）。
    private func awaitUntil(timeout: TimeInterval = 2,
                            _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时（\(timeout)s）：phase=\(coordinator.state.phase) "
                        + "mode=\(coordinator.state.mode) 回报=\(statuses)")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
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
