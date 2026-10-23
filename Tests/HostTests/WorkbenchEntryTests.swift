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
    /// 同一用例内重新构造 store 时复用：日志里已有文件时以文件内的会话为准。
    private let sessionID = UUID()
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

    /// 预取/抓帧请求只做记录：本类多数用例不需要真实帧。
    private var singleFrameRequests: [WindowIdentity] = []

    private func makeCoordinator(singleFrame: ((WindowIdentity, StreamConfig) async -> SingleFrameOutcome)? = nil) -> AppCoordinator {
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
                                     singleFrame: singleFrame ?? { _, _ in .failed })
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

    /// 打开总览必须把 App 激活并置前：菜单栏点击时 App 通常不是活动应用，
    /// 只 orderFrontRegardless 会被前台应用的同级窗口盖住（实机反馈"总览没有放到最前"）。
    func testOpeningOverviewActivatesApplicationAndRaisesPanels() throws {
        let coordinator = makeCoordinator()
        var activations = 0
        coordinator.activateApplication = { activations += 1 }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        XCTAssertGreaterThanOrEqual(activations, 1,
                                    "打开总览必须显式激活 App，否则可能落在前台应用窗口后面")
        XCTAssertTrue(try XCTUnwrap(coordinator.controllers[displayID]).isVisible)
    }

    /// 动效优化：打开总览即预建过渡承载层；点击路径上**一次抓帧都不发**。
    ///
    /// 这条用例替换掉旧的"hover 预取主区分辨率画面"：飞行改画圆角面板之后，
    /// 点击路径上不需要任何跨进程抓帧。捕获输出有硬上限（powerSaving 640px），
    /// 放大到主区必然模糊，所以"多抓几帧"这条路走不通，只能不画放大图。
    func testOverviewPrewarmsCarrierAndNeverCapturesOnClickPath() throws {
        let coordinator = makeCoordinator(singleFrame: { [weak self] identity, _ in
            self?.singleFrameRequests.append(identity)
            return .failed
        })
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        XCTAssertEqual(coordinator.prewarmedCarrierDisplayIDs, [displayID],
                       "打开总览就要预建承载层：首帧延迟里的窗口/图层/drawable 分配不该落在点击路径上")
        // 打开总览本身也不许抓帧：抓帧只由捕获调度按可见性决定。
        XCTAssertTrue(singleFrameRequests.isEmpty,
                      "打开总览不应发起一次性抓帧，实际发了 \(singleFrameRequests.count) 次")
        let identity = try XCTUnwrap(coordinator.state.records.keys
            .sorted { $0.journalKey < $1.journalKey }.first)
        let controller = try XCTUnwrap(coordinator.controllers[displayID])
        controller.contentView.onAction?(.cardClicked(identity))
        // 给点击路径上可能存在的异步抓帧留出窗口：真的有就会在这段时间里发出来。
        waitUntil(timeout: 1) { false }
        XCTAssertFalse(singleFrameRequests.contains(identity),
                       "点击卡片不应触发跨进程抓帧：飞行画的是圆角面板，不需要主区尺寸的截图")
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
        XCTAssertEqual(presentation.cards.count, 4, "四个窗口都保留轨道卡片，包括当前主窗口")
        XCTAssertTrue(presentation.card(for: identity)?.isCurrent ?? false,
                      "当前主窗口的轨道副本必须标记为 current")
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

    func testRailSizePreferencesAreIndependentPerDisplayAndResetToDefault() {
        settings.workbenchTopHeight = 125
        settings.workbenchSideWidth = 210
        settings.saveWorkbenchRailSizes(for: "display-a", topHeight: 240, sideWidth: 350)
        settings.saveWorkbenchRailSizes(for: "display-b", topHeight: 180, sideWidth: 270)
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-a").topHeight, 240)
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-b").sideWidth, 270)
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-c").topHeight, 125)
        settings.saveWorkbenchRailSizes(for: "display-a", topHeight: nil, sideWidth: 350)
        XCTAssertNil(settings.workbenchRailSizes(for: "display-a").topHeight)
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-a").sideWidth, 350)
        XCTAssertEqual(settings.workbenchTopHeight, 125)
        settings.saveWorkbenchRailSizes(for: "display-a", topHeight: .nan, sideWidth: -10)
        XCTAssertNil(settings.workbenchRailSizes(for: "display-a").topHeight)
        XCTAssertNil(settings.workbenchRailSizes(for: "display-a").sideWidth)
    }

    func testExternalFocusFollowsLatestWindowThroughHostWithoutActivatingIt() throws {
        let coordinator = makeCoordinator()
        coordinator.activateApplication = {}
        coordinator.frontmostProcessID = { nil }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        let view = try overviewView()
        view.onAction?(.cardClicked(HostFixtures.identity(0)))
        waitUntil(timeout: 5) { coordinator.state.mode == .workbench }
        XCTAssertEqual(coordinator.state.mode, .workbench)
        let before = coordinator.state.workbench.placement.occupants
        let focusWrites = writer.raiseCount + writer.focusCount
        let obsolete = HostFixtures.identity(1)
        let latest = HostFixtures.identity(2)
        writer.setExternalFocus(try XCTUnwrap(catalogSource.element(for: obsolete)), pid: obsolete.processID)
        writer.setExternalFocus(try XCTUnwrap(catalogSource.element(for: latest)), pid: latest.processID)
        coordinator.frontmostProcessID = { obsolete.processID }
        coordinator.requestWorkbenchFocusFollow()
        coordinator.frontmostProcessID = { latest.processID }
        coordinator.requestWorkbenchFocusFollow()
        waitUntil(timeout: 5) { coordinator.state.workbench.placement.main == latest }
        XCTAssertEqual(coordinator.state.workbench.placement.main, latest, "\(statuses)")
        XCTAssertEqual(coordinator.state.mode, .workbench)
        XCTAssertEqual(coordinator.state.workbench.placement.occupants, before)
        XCTAssertEqual(writer.raiseCount + writer.focusCount, focusWrites)
    }

    func testManualSelectionInvalidatesAnOlderHostFocusQuery() throws {
        let coordinator = makeCoordinator()
        coordinator.activateApplication = {}
        coordinator.frontmostProcessID = { nil }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        try overviewView().onAction?(.cardClicked(HostFixtures.identity(0)))
        waitUntil(timeout: 5) { coordinator.state.mode == .workbench }
        let stale = HostFixtures.identity(2)
        let selected = HostFixtures.identity(1)
        writer.setExternalFocus(try XCTUnwrap(catalogSource.element(for: stale)), pid: stale.processID)
        coordinator.frontmostProcessID = { stale.processID }
        coordinator.requestWorkbenchFocusFollow()
        let slot = try XCTUnwrap(coordinator.state.workbench.slot(of: selected))
        coordinator.dispatch(.railCardSelected(slot: slot, identity: selected))
        waitUntil(timeout: 5) { coordinator.state.workbench.placement.main == selected }
        XCTAssertEqual(coordinator.state.workbench.placement.main, selected)
        XCTAssertNil(coordinator.state.workbench.pendingExternalFocus)
        XCTAssertEqual(coordinator.state.mode, .workbench)
    }

    func testMainMinimizedBeforeDeferredSwitchStartsStillResolvesReplacement() throws {
        let coordinator = makeCoordinator()
        coordinator.activateApplication = {}
        coordinator.frontmostProcessID = { nil }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        let a = HostFixtures.identity(0), b = HostFixtures.identity(1), c = HostFixtures.identity(2)
        try overviewView().onAction?(.cardClicked(a))
        waitUntil(timeout: 5) { coordinator.state.mode == .workbench }
        coordinator.dispatch(.railCardSelected(slot: try XCTUnwrap(coordinator.state.workbench.slot(of: b)), identity: b))
        waitUntil(timeout: 5) { coordinator.state.workbench.mainSwitch.isBusy }
        XCTAssertEqual(writer.totalWrites, 1)
        writer.setMinimizedState(true, for: try XCTUnwrap(catalogSource.element(for: a)))
        writer.setExternalFocus(try XCTUnwrap(catalogSource.element(for: c)), pid: c.processID)
        coordinator.frontmostProcessID = { c.processID }
        coordinator.dispatch(.windowMinimized(a, true))
        waitUntil(timeout: 5) { coordinator.state.workbench.placement.main == c }
        XCTAssertEqual(coordinator.state.workbench.placement.main, c, "\(statuses)")
        XCTAssertEqual(coordinator.state.mode, .workbench)
        XCTAssertNil(coordinator.state.workbench.pendingReplacement)
        XCTAssertNil(coordinator.state.workbench.recoveryRequired)
    }

    // MARK: - 壁纸底：看起来只有一个真实窗口在最前

    /// 工作台必须有一层壁纸底，且**压在真实主窗口下一层**；窗口编号登记为自有窗口，
    /// 否则目录/采集会把它当成一张新卡片。返回总览时必须撤掉并注销。
    func testWorkbenchBackdropIsBelowMainAndFollowsLifecycle() throws {
        let coordinator = makeCoordinator()
        coordinator.toggleOverview()
        try waitForVisibleOverview()

        let view = try overviewView()
        view.layoutSubtreeIfNeeded()
        let identity = HostFixtures.identity(0)
        let cell = try XCTUnwrap(coordinator.cardRects[identity], "初选目标必须有总览格子")
        let point = HostFixtures.viewPoint(of: cell, in: view, cgOrigin: HostFixtures.offscreenOrigin)
        view.mouseDown(with: HostEvents.mouse(.leftMouseDown, in: view.window, point: point))
        view.mouseUp(with: HostEvents.mouse(.leftMouseUp, in: view.window, point: point))
        waitUntil(timeout: 5) { self.coordinator.state.mode == .workbench }
        XCTAssertEqual(coordinator.state.mode, .workbench)

        XCTAssertEqual(coordinator.backdropWindowCount, 1, "工作台必须铺一层壁纸底")
        XCTAssertTrue(coordinator.backdropIsOrderedBelowMain,
                      "壁纸底必须压在真实主窗口下一层，不能盖住主窗口")
        let backdropNumbers = coordinator.backdropWindowNumbers
        XCTAssertFalse(backdropNumbers.isEmpty)
        for number in backdropNumbers {
            XCTAssertTrue(catalog.isRegisteredOwnWindow(id: number),
                          "壁纸底必须登记为自有窗口，避免被目录当成一张卡片")
        }

        coordinator.dispatch(.returnShortcut)
        waitUntil(timeout: 5) { self.coordinator.state.phase == .overview }
        XCTAssertEqual(coordinator.backdropWindowCount, 0, "返回总览必须撤掉壁纸底")
        for number in backdropNumbers {
            XCTAssertFalse(catalog.isRegisteredOwnWindow(id: number),
                           "撤掉后必须注销自有窗口编号，不能残留过滤规则")
        }
    }

    // MARK: - 工作台里出现新窗口：纳入布局而不是整场消失

    func testNewWindowJoinsBackgroundThenFollowsConcreteFocusWithoutLeavingWorkbench() throws {
        let coordinator = makeCoordinator()
        coordinator.activateApplication = {}
        coordinator.frontmostProcessID = { nil }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        let identity = HostFixtures.identity(0)
        try overviewView().onAction?(.cardClicked(identity))
        waitUntil(timeout: 5) { coordinator.state.mode == .workbench }
        let homes = coordinator.state.workbench.placement.occupants
        let focusWrites = writer.raiseCount + writer.focusCount

        let added = HostFixtures.identity(4)
        catalogSource.addWindows([4])
        let element = try XCTUnwrap(catalogSource.element(for: added))
        writer.setInitialFrame(FakeCatalogSource.frame(for: 4), for: element)
        catalog.refresh(reason: .windowEvent)
        waitUntil(timeout: 3) { coordinator.state.records[added] != nil }
        XCTAssertNotNil(coordinator.state.workbench.slot(of: added))
        XCTAssertEqual(coordinator.state.workbench.placement.main, identity)
        XCTAssertEqual(writer.raiseCount + writer.focusCount, focusWrites)

        writer.setExternalFocus(element, pid: added.processID)
        coordinator.frontmostProcessID = { added.processID }
        coordinator.dispatch(.focusLost(origin: .otherApplication(bundleID: "com.test.app4")))
        waitUntil(timeout: 5) { coordinator.state.workbench.placement.main == added }
        XCTAssertEqual(coordinator.state.workbench.placement.main, added, "\(statuses)")
        XCTAssertEqual(coordinator.state.mode, .workbench)
        XCTAssertEqual(writer.raiseCount + writer.focusCount, focusWrites)
        for (slot, member) in homes {
            XCTAssertEqual(coordinator.state.workbench.placement.occupant(at: slot), member)
        }
    }

    // MARK: - 总览里出现新窗口：纳入卡片而不是整场消失

    /// 总览里打开新应用：新窗口作为新卡片留下，总览保持可见并重新置前。
    /// 以前这里会被当成"用户切走了"，整个总览直接消失。
    func testNewAppInOverviewKeepsOverviewAndAddsCard() throws {
        let coordinator = makeCoordinator()
        var activations = 0
        coordinator.activateApplication = { activations += 1 }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        let activationsAtOpen = activations

        catalogSource.addWindows([4])
        catalog.refresh(reason: .windowEvent)
        waitUntil(timeout: 3) { coordinator.state.records[HostFixtures.identity(4)] != nil }
        XCTAssertNotNil(coordinator.state.records[HostFixtures.identity(4)])

        let bundleID = "com.test.app\(HostFixtures.identity(4).windowID)"
        coordinator.dispatch(.focusLost(origin: .otherApplication(bundleID: bundleID)))
        waitUntil(timeout: 2) { activations > activationsAtOpen }
        XCTAssertEqual(coordinator.state.phase, .overview,
                       "开新 App 必须保持总览，而不是整场隐藏（phase=\(coordinator.state.phase)）")
        XCTAssertNotNil(coordinator.state.records[HostFixtures.identity(4)],
                        "新窗口必须作为卡片留在布局里")
        XCTAssertGreaterThan(activations, activationsAtOpen,
                             "总览被新应用抢走前台后必须重新激活并置前")
    }

    /// 新应用的窗口可能比前台变更晚一轮目录才出现：宽限期里目录合并到就必须保下总览。
    func testNewAppDiscoveredDuringGraceKeepsOverview() throws {
        let coordinator = makeCoordinator()
        var activations = 0
        coordinator.activateApplication = { activations += 1 }
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        let activationsAtOpen = activations

        // 只让替身"系统里有这个窗口"，先不推目录：模拟焦点先到、目录后到。
        catalogSource.addWindows([4])
        let bundleID = "com.test.app\(HostFixtures.identity(4).windowID)"
        coordinator.dispatch(.focusLost(origin: .otherApplication(bundleID: bundleID)))

        waitUntil(timeout: 3) { coordinator.state.records[HostFixtures.identity(4)] != nil }
        XCTAssertNotNil(coordinator.state.records[HostFixtures.identity(4)],
                        "宿主必须主动核对目录，不能只等 2s 轮询")
        waitUntil(timeout: 2) { activations > activationsAtOpen }
        XCTAssertGreaterThan(activations, activationsAtOpen,
                             "新窗口到达后必须把总览重新置前")

        // 越过完整宽限期（600+600ms）：决策必须已经作废，不能再补一次退出。
        RunLoop.current.run(until: Date().addingTimeInterval(1.4))
        XCTAssertEqual(coordinator.state.phase, .overview,
                       "新窗口在宽限内出现，不能被当成普通离开（phase=\(coordinator.state.phase)）")
    }

    /// 切到总览里已经存在的应用：仍然是普通离开，不能被新窗口宽限拖住。
    func testSwitchingToExistingAppFromOverviewStillHides() throws {
        let coordinator = makeCoordinator()
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        let existing = HostFixtures.identity(1)
        let bundleID = try XCTUnwrap(coordinator.state.records[existing]?.bundleID,
                                     "前提：已有卡片必须带 bundle 身份")
        coordinator.dispatch(.focusLost(origin: .otherApplication(bundleID: bundleID)))
        waitUntil(timeout: 2) { self.coordinator.state.phase == .hidden }
        XCTAssertEqual(coordinator.state.phase, .hidden,
                       "切到总览里已有的应用必须按正常离开处理")
    }

    /// 目标应用在打开总览时没有窗口、又没有带来新窗口（纯切换）：宽限结束必须退出。
    /// 这条同时守住"延迟结算不能再次进入分流"——否则每次宽限结束都会重新开始等待，永远退不出去。
    func testUnknownBundleWithoutNewWindowExitsAfterGrace() throws {
        let coordinator = makeCoordinator()
        coordinator.toggleOverview()
        try waitForVisibleOverview()
        coordinator.dispatch(.focusLost(origin: .otherApplication(bundleID: "com.test.noWindowApp")))
        waitUntil(timeout: 3) { self.coordinator.state.phase == .hidden }
        XCTAssertEqual(coordinator.state.phase, .hidden,
                       "没有新窗口的焦点丢失必须在宽限后收口，不能无限延期（phase=\(coordinator.state.phase)）")
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

    // MARK: - 事务日志：失败批次不得抹掉后来成功批次（方案 §7.2 不变量 2）

    /// 并发三批：A 落盘失败、B 成功、C 成功。
    ///
    /// 回归的是旧实现"锁内先暂存 staged、await 落盘之后才提交"的缺陷：A 失败回滚会把 B 基于 A 的暂存
    /// 抹成旧快照，随后 C 又以旧快照落盘，把已经报成功的 B 从磁盘和 `committed` 里静默抹掉。
    /// 现在整段事务独占通道：同一时刻一批在途、后一批基于最新已提交内容，失败批次只丢弃自己。
    func testConcurrentFailedBatchNeverErasesLaterSuccessfulBatches() async throws {
        let writer = ScriptedJournalDiskWriter(outcomes: [.failed(reason: "注入：第 1 批落盘失败"),
                                                          .persisted,
                                                          .persisted],
                                               gatedIndices: [0, 1])
        let store = journalStore(writer: writer)
        let a = HostFixtures.identity(0)
        let b = HostFixtures.identity(1)
        let c = HostFixtures.identity(2)

        let batchA = Task { await store.apply(journalTransaction(0)) }
        await writer.waitUntilEntered(1) // A 已进入落盘并挂起，仍占着通道
        let batchB = Task { await store.apply(journalTransaction(1)) }
        let batchC = Task { await store.apply(journalTransaction(2)) }
        // 等 B/C 真正排到通道外：旧实现此时已完成锁内暂存（缺陷成立的交错），
        // 新实现此时还没有开始计算。先等到这个条件再放行 A，交错才是确定的，不靠调度巧合。
        await waitForPendingBatches(store, count: 2)

        // A 在途：B/C 最多只是排在通道外，绝不可能已经开始落盘。
        XCTAssertEqual(writer.writeCount, 1, "同一时刻只允许一批在途，实际已有 \(writer.writeCount) 批")

        writer.release(0) // A 按脚本落盘失败返回
        await writer.waitUntilEntered(2) // 下一批进入落盘：通道已把持有权按顺序交棒
        XCTAssertEqual(writer.writeCount, 2, "第二批在途时第三批不能开始落盘")

        // 第二批的载荷只能建立在已提交快照上：A 失败后不得出现在后续任何批次里。
        // 并发两批谁先到通道不保证（都是 Task 调度），所以这里只断言"只有它自己"。
        let payloadSecond = try writer.journal(at: 1)
        let secondKeys = Set(payloadSecond.entries.keys)
        XCTAssertNil(payloadSecond.entries[a.journalKey], "已失败的 A 不得出现在后续批次的落盘内容里")
        XCTAssertTrue(secondKeys == [b.journalKey] || secondKeys == [c.journalKey],
                      "第二批只能包含自己的记录，实际=\(secondKeys)")

        writer.release(1)
        await writer.waitUntilEntered(3)
        let payloadThird = try writer.journal(at: 2)
        let thirdKeys = Set(payloadThird.entries.keys)
        XCTAssertNil(payloadThird.entries[a.journalKey], "已失败的 A 不得出现在后续批次的落盘内容里")
        XCTAssertEqual(thirdKeys, [b.journalKey, c.journalKey],
                       "第三批必须建立在第二批已提交内容之上，不能把它覆盖掉，实际=\(thirdKeys)")
        writer.release(2)

        let writeA = await batchA.value
        let writeB = await batchB.value
        let writeC = await batchC.value
        XCTAssertFalse(writeA.isPersisted, "第 1 批必须按注入失败：\(writeA)")
        XCTAssertTrue(writeB.isPersisted, "第 2 批必须落盘成功：\(writeB)")
        XCTAssertTrue(writeC.isPersisted, "第 3 批必须落盘成功：\(writeC)")
        XCTAssertEqual(writer.writeCount, 3, "三批各自只落盘一次")

        // 内存快照、磁盘 JSON、重新构造的 store 三者逐字段一致：B/C 都在，A 不在。
        let inMemory = store.snapshot
        XCTAssertNil(inMemory.entries[a.journalKey], "失败批次绝不能留在内存快照里")
        XCTAssertNotNil(inMemory.entries[b.journalKey], "已报成功的 B 不能被后来的批次抹掉")
        XCTAssertNotNil(inMemory.entries[c.journalKey])

        let onDisk = try diskJournal()
        XCTAssertEqual(onDisk, inMemory, "磁盘 JSON 必须与内存快照一致")

        let reopened = journalStore()
        XCTAssertNil(reopened.loadIssue, "重新打开必须能读懂日志：\(reopened.loadIssue ?? "")")
        XCTAssertEqual(reopened.snapshot, inMemory, "重启后读到的内容必须与内存/磁盘一致")
        XCTAssertNil(reopened.entry(for: a), "失败批次不得被充当为已提交")
        XCTAssertNotNil(reopened.entry(for: b))
        XCTAssertNotNil(reopened.entry(for: c))

        XCTAssertEqual(store.revision, 2, "只有成功落盘的两批推进序号，失败批不推进")
    }

    /// 序号语义：成功落盘才 +1，失败批次不推进；内存快照只反映已提交内容。
    func testRevisionAdvancesOnlyOnPersistedBatches() async throws {
        let writer = ScriptedJournalDiskWriter(outcomes: [.failed(reason: "注入：第 1 批落盘失败"),
                                                          .persisted,
                                                          .persisted])
        let store = journalStore(writer: writer)
        let b = HostFixtures.identity(1)
        let c = HostFixtures.identity(2)

        XCTAssertEqual(store.revision, 0, "新建日志序号从 0 开始")

        let failed = await store.apply(journalTransaction(0))
        XCTAssertFalse(failed.isPersisted)
        XCTAssertEqual(store.revision, 0, "失败批次不许推进序号，否则后续序号守卫会被自己绕过")
        XCTAssertTrue(store.snapshot.entries.isEmpty, "失败批次不得进入内存快照")

        let first = await store.apply(journalTransaction(1))
        XCTAssertTrue(first.isPersisted, "第 2 批必须落盘成功：\(first)")
        XCTAssertEqual(store.revision, 1, "成功批次推进一次序号")
        XCTAssertEqual(Set(store.snapshot.entries.keys), [b.journalKey])

        let second = await store.apply(journalTransaction(2))
        XCTAssertTrue(second.isPersisted, "第 3 批必须落盘成功：\(second)")
        XCTAssertEqual(store.revision, 2, "序号只会随成功落盘单调递增")
        XCTAssertEqual(Set(store.snapshot.entries.keys), [b.journalKey, c.journalKey])
        XCTAssertEqual(try diskJournal(), store.snapshot, "内存与磁盘一致")
    }

    /// 后续批次以已提交快照为起点：中间批次失败不会让下一批把此前已提交的内容覆盖掉。
    /// 同时核对序号守卫仍然基于已提交序号：过期写入在落盘前就被拒绝。
    func testLaterBatchStartsFromCommittedSnapshotAfterFailedBatch() async throws {
        let writer = ScriptedJournalDiskWriter(outcomes: [.persisted,
                                                          .failed(reason: "注入：第 2 批落盘失败"),
                                                          .persisted])
        let store = journalStore(writer: writer)
        let a = HostFixtures.identity(0)
        let b = HostFixtures.identity(1)
        let c = HostFixtures.identity(2)

        let writeA = await store.apply(journalTransaction(0))
        XCTAssertTrue(writeA.isPersisted, "第 1 批必须落盘成功：\(writeA)")
        XCTAssertEqual(store.revision, 1)

        let writeB = await store.apply(journalTransaction(1))
        XCTAssertFalse(writeB.isPersisted, "第 2 批必须按注入失败：\(writeB)")
        XCTAssertEqual(store.revision, 1, "失败批次不推进序号")
        XCTAssertEqual(Set(store.snapshot.entries.keys), [a.journalKey], "失败批次不得留在内存快照")
        XCTAssertEqual(try diskJournal(), store.snapshot, "失败批次不得留在磁盘")

        let writeC = await store.apply(journalTransaction(2))
        XCTAssertTrue(writeC.isPersisted, "第 3 批必须落盘成功：\(writeC)")
        XCTAssertEqual(store.revision, 2)

        // C 的载荷仍带着此前已提交的 A：后一批不会把已提交内容覆盖掉；失败的 B 不在其中。
        let payloadC = try writer.journal(at: 2)
        XCTAssertNotNil(payloadC.entries[a.journalKey], "已提交的 A 必须留在后续批次的落盘内容里")
        XCTAssertNil(payloadC.entries[b.journalKey], "已失败的 B 不得出现在后续批次的落盘内容里")
        XCTAssertNotNil(payloadC.entries[c.journalKey])

        let inMemory = store.snapshot
        XCTAssertEqual(Set(inMemory.entries.keys), [a.journalKey, c.journalKey])
        XCTAssertEqual(try diskJournal(), inMemory, "磁盘 JSON 必须与内存快照一致")
        XCTAssertEqual(journalStore().snapshot, inMemory, "重新构造 store 读到的内容必须一致")

        // 序号守卫：过期基准在落盘前被拒绝，既不改内存也不写盘。
        let writesBeforeRefusal = writer.writeCount
        let stale = await store.apply(journalTransaction(3), expectedRevision: 1)
        XCTAssertFalse(stale.isPersisted, "过期序号必须被拒绝：\(stale)")
        XCTAssertEqual(store.revision, 2, "被拒绝的批次不推进序号")
        XCTAssertEqual(writer.writeCount, writesBeforeRefusal, "被拒绝的批次不该落盘")
        XCTAssertEqual(store.snapshot, inMemory, "被拒绝的批次不改内存快照")
    }

    /// 等落盘通道外已有 `count` 批在排队。只等条件成立，不睡固定时长：
    /// 旧实现这时已经完成了锁内暂存，新实现这时还没开始计算，两种实现下的交错都确定。
    private func waitForPendingBatches(_ store: WindowJournalStore, count: Int) async {
        for _ in 0..<10_000 {
            if store.pendingBatchCount >= count { return }
            await Task.yield()
        }
        XCTFail("等待 \(count) 批进入落盘通道超时，实际排队 \(store.pendingBatchCount) 批")
    }

    // MARK: - 日志事务测试辅助

    private func journalStore(writer: JournalDiskWriting? = nil) -> WindowJournalStore {
        WindowJournalStore(fileName: "session-journal.json",
                           sessionID: sessionID,
                           baseDirectory: journalDirectory,
                           journalWriter: writer)
    }

    private var diskJournalURL: URL {
        journalDirectory.appendingPathComponent("Vistile").appendingPathComponent("session-journal.json")
    }

    /// 只读磁盘上的日志：解不出来直接失败，不允许把"读不出来"当成空日志。
    private func diskJournal() throws -> SessionJournal {
        try SessionJournal.decode(try Data(contentsOf: diskJournalURL))
    }

    /// 整秒时间戳：JSON 的 ISO8601 编码会丢小数秒，用整秒创建才能让内存与磁盘逐字段可比。
    private func journalTransaction(_ index: Int) -> WindowTransaction {
        let record = HostFixtures.record(index, slot: index)
        return WindowTransaction(sessionID: sessionID,
                                 identity: record.identity,
                                 bundleID: record.bundleID,
                                 originalFrame: record.frame,
                                 originalDisplayID: displayID,
                                 created: Date(timeIntervalSince1970: 1_700_000_000))
            .markingPlanned(frame: record.frame.offsetBy(dx: 120, dy: 60), displayID: displayID)
    }

    // MARK: - 迟到写入守卫：按"条目还在不在"判断，而不是全局 revision（0.1.13 实机）

    /// 实机「日志序号已过期（期望 7，当前 8）」：无关流程（退出清理/布局结算）写同一份日志
    /// 推进了全局 revision，一次合法的同操作追加被判死 → 交换失败 → 界面卡死。
    /// 守卫改为"条目仍存在"后：revision 前进不影响；条目已被补偿清理则必须拒绝迟到写入。
    func testJournalUpdateSurvivesUnrelatedRevisionAdvance() async throws {
        let store = journalStore()
        let a = HostFixtures.identity(0)
        let operation = UUID()
        let context = GeometryOperationContext(sessionID: sessionID,
                                               sessionEpoch: 0,
                                               operationID: operation,
                                               transitionToken: TransitionToken(generation: 1),
                                               kind: .mainSwitch)
        let prepared = journalTransaction(0).markingOperationBefore(frame: HostFixtures.record(0, slot: 0).frame,
                                                                    displayID: displayID,
                                                                    operationID: operation)
        let preparedWrite = await store.prepare(JournalPrepareRequest(context: context,
                                                                     mutations: [.upsert(prepared)],
                                                                     affectedIdentities: [a]))
        XCTAssertTrue(preparedWrite.isPersisted, "\(preparedWrite)")

        // 无关流程写日志：revision 前进，但条目仍在。
        let unrelated = await store.apply(journalTransaction(1))
        XCTAssertTrue(unrelated.isPersisted, "\(unrelated)")
        XCTAssertGreaterThan(store.revision, 1)

        let updated = prepared.markingWritten(readBack: prepared.plannedFrame, displayID: displayID)
        let sameOperation = await store.update(JournalUpdateRequest(operationID: operation, identity: a,
                                                                    mutation: .upsert(updated)),
                                               additional: [])
        XCTAssertTrue(sameOperation.isPersisted,
                      "全局 revision 前进不该判死一次合法的追加：\(sameOperation)")
        XCTAssertEqual(store.entry(for: a)?.state, .written)

        // 条目被补偿清理后，迟到写入必须拒绝：不能把已经结清的事务复活。
        let dropped = await store.drop(a)
        XCTAssertTrue(dropped.isPersisted, "\(dropped)")
        let late = await store.update(JournalUpdateRequest(operationID: operation, identity: a,
                                                           mutation: .upsert(updated)),
                                      additional: [])
        XCTAssertFalse(late.isPersisted, "条目已清理时必须拒绝迟到写入：\(late)")
    }

    func testShortcutCanOpenFocusedWindowWorkbenchWithoutShowingOverview() throws {
        let coordinator = makeCoordinator()
        let target = HostFixtures.identity(2)
        let element = try XCTUnwrap(catalogSource.element(for: target))
        writer.setExternalFocus(element, pid: target.processID)
        coordinator.frontmostProcessID = { target.processID }
        settings.opensCurrentWindowWorkbench = true
        var overviewActivations = 0
        coordinator.activateApplication = { overviewActivations += 1 }
        coordinator.hotKey.onFire?()
        waitUntil(timeout: 5) { coordinator.state.mode == .workbench }
        XCTAssertEqual(coordinator.state.workbench.placement.main, target)
        XCTAssertTrue(coordinator.controllers.values.allSatisfy { !$0.isVisible })
        XCTAssertEqual(overviewActivations, 0, "Direct entry must not flash or activate the overview")
        XCTAssertEqual(coordinator.workbenchPresentation?.cards.count, 4)
    }

    func testMenuOffersExplicitCurrentWindowWorkbenchEntry() throws {
        let coordinator = makeCoordinator()
        let target = HostFixtures.identity(1)
        writer.setExternalFocus(try XCTUnwrap(catalogSource.element(for: target)), pid: target.processID)
        coordinator.frontmostProcessID = { target.processID }
        let menu = MenuBarController(coordinator: coordinator, settings: settings,
                                     permissions: PermissionManager(), installsStatusItem: false,
                                     performsAutomaticUpdateCheck: false)
        menu.menuNeedsUpdate(menu.statusMenu)
        XCTAssertEqual(menu.currentWindowItem.title, "以当前窗口开启工作台")
        XCTAssertTrue(menu.currentWindowItem.isEnabled)
        XCTAssertTrue(menu.openItem.isEnabled)
        NSApp.sendAction(try XCTUnwrap(menu.currentWindowItem.action), to: menu.currentWindowItem.target, from: menu.currentWindowItem)
        waitUntil(timeout: 5) { coordinator.state.mode == .workbench }
        XCTAssertEqual(coordinator.state.workbench.placement.main, target)
        menu.menuNeedsUpdate(menu.statusMenu)
        XCTAssertFalse(menu.currentWindowItem.isEnabled)
    }

    func testUnresolvableCurrentWindowDoesNotMoveAnotherWindow() {
        let coordinator = makeCoordinator()
        coordinator.frontmostProcessID = { 987_654 }
        coordinator.openCurrentWindowWorkbench()
        waitUntil(timeout: 2) { !coordinator.isOpeningCurrentWindowWorkbench }
        XCTAssertEqual(coordinator.state.phase, .hidden)
        XCTAssertTrue(writer.writtenFrames.isEmpty)
        XCTAssertFalse(statuses.isEmpty)
    }

    func testSecondShortcutCancelsPendingDirectEntry() async throws {
        let coordinator = makeCoordinator()
        let target = HostFixtures.identity(1)
        writer.setExternalFocus(try XCTUnwrap(catalogSource.element(for: target)), pid: target.processID)
        coordinator.frontmostProcessID = { target.processID }
        settings.opensCurrentWindowWorkbench = true
        catalogSource.gatesNextCatalogLoad = true
        coordinator.performGlobalShortcut()
        try await awaitUntil(timeout: 2) { self.catalogSource.isBlockedInCatalogLoad }
        XCTAssertTrue(catalogSource.isBlockedInCatalogLoad)
        coordinator.performGlobalShortcut()
        catalogSource.openCatalogLoadGate()
        await catalog.refreshAndWait(reason: .harnessProbe)
        XCTAssertEqual(coordinator.state.phase, .hidden)
        XCTAssertTrue(writer.writtenFrames.isEmpty)
        XCTAssertFalse(coordinator.isOpeningCurrentWindowWorkbench)
    }

    func testShortcutEntryPreferencePersistsAndDefaultsToOverview() {
        let defaults = transientDefaults()
        let first = SettingsModel(defaults: defaults)
        XCTAssertFalse(first.opensCurrentWindowWorkbench)
        first.opensCurrentWindowWorkbench = true
        XCTAssertTrue(SettingsModel(defaults: defaults).opensCurrentWindowWorkbench)
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

/// 日志落盘的可控替身（方案 §15.1）：按批次脚本确定性失败/成功，并可在指定位次把落盘挂起，
/// 由测试用 continuation 放行——不用真实 sleep、不赌时序，也不依赖真实磁盘故障。
private final class ScriptedJournalDiskWriter: JournalDiskWriting {
    enum Outcome {
        case persisted
        case failed(reason: String)
    }

    private let lock = NSLock()
    private let outcomes: [Outcome]
    private let gatedIndices: Set<Int>
    private var enteredCount = 0
    private var payloads: [Data] = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var gateWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedGates: Set<Int> = []

    init(outcomes: [Outcome], gatedIndices: Set<Int> = []) {
        self.outcomes = outcomes
        self.gatedIndices = gatedIndices
    }

    /// 已经进入落盘入口的批次数（也是下一批的 0 起算序号）。
    var writeCount: Int { withLock { enteredCount } }

    /// 第 `index` 批（0 起算）实际写出的载荷。
    func journal(at index: Int) throws -> SessionJournal {
        let data: Data? = withLock { payloads.indices.contains(index) ? payloads[index] : nil }
        return try SessionJournal.decode(try XCTUnwrap(data, "第 \(index) 批没有落盘载荷"))
    }

    /// 等到第 `count` 批（1 起算）已经进入落盘。
    func waitUntilEntered(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if enteredCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                entryWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    /// 放行第 `index` 批（0 起算）；没有挂在该批上的等待者时无副作用。
    func release(_ index: Int) {
        lock.lock()
        releasedGates.insert(index)
        let gate = gateWaiters.removeValue(forKey: index)
        lock.unlock()
        gate?.resume()
    }

    func writeJournal(_ data: Data, to url: URL) async -> JournalWrite {
        let index: Int = withLock {
            let index = enteredCount
            enteredCount += 1
            payloads.append(data)
            return index
        }
        notifyEntryWaiters()
        if withLock({ gatedIndices.contains(index) }) {
            await waitForGate(index)
        }
        let outcome: Outcome = withLock { index < outcomes.count ? outcomes[index] : .persisted }
        switch outcome {
        case .persisted:
            // 成功批次真的落到临时目录里的同一个 URL：这样磁盘 JSON 与 reopen 的断言才有对象。
            do {
                try data.write(to: url, options: [.atomic])
                return .persisted
            } catch {
                return .failed(reason: error.localizedDescription)
            }
        case let .failed(reason):
            return .failed(reason: reason)
        }
    }

    private func notifyEntryWaiters() {
        lock.lock()
        let ready = entryWaiters.filter { enteredCount >= $0.count }
        entryWaiters.removeAll { enteredCount >= $0.count }
        lock.unlock()
        for waiter in ready { waiter.continuation.resume() }
    }

    private func waitForGate(_ index: Int) async {
        if withLock({ releasedGates.contains(index) }) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if releasedGates.contains(index) {
                lock.unlock()
                continuation.resume()
            } else {
                gateWaiters[index] = continuation
                lock.unlock()
            }
        }
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
