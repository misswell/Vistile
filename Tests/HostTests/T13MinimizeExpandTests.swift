import AppKit
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// T13 最小化窗口展开（方案 §11）。
///
/// 展开一条最小化的窗口只有两种诚实结局：先真正解除最小化并按身份重取句柄，或者拒绝展开。
/// 这里用替身 AX 把两种结局都钉住：解除失败时一个几何字节都不写、不发 expandCompleted；
/// 成功时顺序必须是"解除最小化 → 目录换代 → 写几何"，旧 AX 索引不得复用。
/// 窗口几何全部 offscreen（x = −20 000），替身不碰真实 AX，也不碰用户桌面。
@MainActor
final class T13MinimizeExpandTests: XCTestCase {
    private let sessionID = UUID()
    private var permissions: FakePermissions!
    private var catalogSource: FakeCatalogSource!
    private var processIdentity: FakeProcessIdentity!
    private var writer: FakeGeometryWriter!
    private var catalog: WindowCatalog!
    private var settings: SettingsModel!
    private var recovery: RecoveryCoordinator!
    private var journalDirectory: URL!
    private var scratchDirectories: [URL] = []
    private var testDefaultsSuites: [String] = []

    private var displayID: UInt32 { HostFixtures.display.id }
    private var expandedFrame: CGRect {
        CGRect(x: HostFixtures.offscreenOrigin.x + 40, y: 40, width: 1_200, height: 760)
    }

    override func setUpWithError() throws {
        permissions = FakePermissions()
        catalogSource = FakeCatalogSource()
        processIdentity = FakeProcessIdentity()
        writer = FakeGeometryWriter()
        settings = SettingsModel(defaults: transientDefaults())
        journalDirectory = try makeScratchDirectory()
        // 最小化事实只有一个来源：应用（替身写入器）。目录每次换代都去读它。
        catalogSource.minimizedReader = { [weak catalogSource, weak writer] identity in
            guard let element = catalogSource?.element(for: identity) else { return false }
            return writer?.isMinimized(for: element) ?? false
        }
    }

    override func tearDown() {
        catalog = nil
        recovery = nil
        settings = nil
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

    /// 总览发现时窗口就已经最小化：目录必须标成暂停，且不算被限制。
    private func startCatalog(minimized: [Int]) async {
        catalogSource.addWindows(Array(0...3))
        catalog = WindowCatalog(permissions: permissions,
                               axSource: catalogSource,
                               contentSource: catalogSource,
                               displaySource: FakeDisplaySource(displays: [HostFixtures.display]))
        for index in minimized {
            let identity = HostFixtures.identity(index)
            if let element = catalogSource.element(for: identity) {
                writer.setMinimizedState(true, for: element)
            }
        }
        await catalog.refreshAndWait(reason: .reconcile)
        for index in [0, 1, 2, 3] {
            let identity = HostFixtures.identity(index)
            if let element = catalogSource.element(for: identity) {
                writer.setInitialFrame(FakeCatalogSource.frame(for: index), for: element)
            }
        }
    }

    private func makeStore() -> WindowJournalStore {
        WindowJournalStore(fileName: "session-journal.json",
                           sessionID: sessionID,
                           baseDirectory: journalDirectory)
    }

    private func startFocus(store: WindowJournalStore) throws -> FocusCoordinator {
        recovery = RecoveryCoordinator(store: store,
                                      writer: writer,
                                      catalog: catalog,
                                      settings: settings,
                                      permissions: permissions,
                                      processIdentity: processIdentity)
        let metal = try HostFixtures.metalContext()
        return FocusCoordinator(catalog: catalog,
                                metal: metal,
                                writer: writer,
                                store: store,
                                settings: settings,
                                metrics: .shared,
                                recorder: CompatibilityRecorder(fileName: "host-test-\(UUID().uuidString)"),
                                recovery: recovery,
                                permissions: permissions)
    }

    private func plannedTransaction(_ identity: WindowIdentity) -> WindowTransaction {
        let index = Int(identity.windowID) - 9_000
        return WindowTransaction(sessionID: sessionID,
                                 identity: identity,
                                 bundleID: "com.test.app\(identity.windowID)",
                                 originalFrame: FakeCatalogSource.frame(for: index),
                                 originalDisplayID: displayID)
            .markingPlanned(frame: expandedFrame, displayID: displayID)
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

    // MARK: - 发现时已最小化

    func testMinimizedWindowIsPausedAtDiscovery() async {
        await startCatalog(minimized: [0])
        let record = catalog.record(for: HostFixtures.identity(0))
        XCTAssertEqual(record?.isMinimized, true)
        XCTAssertEqual(record?.capture, .pausedMinimized, "最小化必须标暂停，不能当成实时卡片")
        XCTAssertEqual(record?.restriction, nil, "最小化不是被限制：用户点它就是要它回来")
        XCTAssertEqual(catalog.record(for: HostFixtures.identity(1))?.capture, .idle)
    }

    func testUnminimizesAndRebindsHandleBeforeWritingGeometry() async throws {
        await startCatalog(minimized: [0])
        let store = makeStore()
        let focus = try startFocus(store: store)
        let identity = HostFixtures.identity(0)
        let element = try XCTUnwrap(catalogSource.element(for: identity))
        store.apply(plannedTransaction(identity))

        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        var events: [SessionEvent] = []
        focus.onEvent = { events.append($0) }

        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { !writer.recordedActions.isEmpty && writer.recordedActions.contains("写") }
        focus.cancelAnimation()

        XCTAssertEqual(writer.recordedActions.first, "解除最小化",
                       "顺序必须是先解除最小化再写几何：\(writer.recordedActions)")
        XCTAssertEqual(writer.isMinimized(for: element), false)
        XCTAssertEqual(writer.writtenFrames.first, expandedFrame)
        // 句柄按身份重取：目录换代后它已经不是最小化。
        XCTAssertEqual(catalog.record(for: identity)?.isMinimized, false)
        XCTAssertNotEqual(catalog.record(for: identity)?.capture, .pausedMinimized)
        XCTAssertFalse(events.contains { if case .transitionTimedOut = $0 { return true }; return false },
                       "解除成功却报超时，等于把一次正常展开说成失败")
    }

    func testUnminimizeFailureWritesNothingAndNeverClaimsSuccess() async throws {
        await startCatalog(minimized: [0])
        let store = makeStore()
        let focus = try startFocus(store: store)
        let identity = HostFixtures.identity(0)
        let element = try XCTUnwrap(catalogSource.element(for: identity))
        writer.refusesUnminimize = true
        store.apply(plannedTransaction(identity))

        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        var events: [SessionEvent] = []
        var statuses: [String] = []
        focus.onEvent = { events.append($0) }
        focus.onStatus = { statuses.append($0) }

        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { events.contains { if case .transitionTimedOut = $0 { return true }; return false } }
        focus.cancelAnimation()

        XCTAssertEqual(writer.unminimizeAttempts, 1)
        XCTAssertEqual(writer.totalWrites, 0, "窗口还在 Dock 里就改它的尺寸，等于写一个看不见的窗口")
        XCTAssertEqual(writer.raiseCount, 0, "没解除最小化就不该前景化")
        XCTAssertEqual(writer.isMinimized(for: element), true)
        XCTAssertTrue(events.contains { if case .transitionTimedOut = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .expandCompleted = $0 { return true }; return false },
                       "不发送 expandCompleted：状态机不能停在假的聚焦态")
        XCTAssertFalse(events.contains { if case .geometryWriteFinished = $0 { return true }; return false })
        XCTAssertTrue(statuses.contains { $0.contains("最小化") }, "拒绝原因必须能显示给用户：\(statuses)")
    }

    /// 解除最小化会让目录换代：几何必须写到换代后按身份取到的句柄上，旧句柄一律不用（§11 第 3 条）。
    func testStaleHandleIsNotReusedAfterUnminimize() async throws {
        await startCatalog(minimized: [0])
        let store = makeStore()
        let focus = try startFocus(store: store)
        let identity = HostFixtures.identity(0)
        let stale = try XCTUnwrap(catalogSource.element(for: identity))
        // 换代后这个身份对应的是另一个 AX 对象（不同 pid → 替身里可区分）。
        let refreshed = AXUIElementCreateApplication(424_242)
        writer.setInitialFrame(FakeCatalogSource.frame(for: 0), for: refreshed)
        catalogSource.swapElementOnNextRead(identity, to: refreshed)
        store.apply(plannedTransaction(identity))

        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { writer.recordedActions.contains("写") }
        focus.cancelAnimation()

        XCTAssertEqual(writer.recordedActions.first, "解除最小化")
        let written = await writer.currentFrame(of: refreshed)
        XCTAssertEqual(written, expandedFrame, "几何写到了换代后的句柄上")
        let untouched = await writer.currentFrame(of: stale)
        XCTAssertEqual(untouched, FakeCatalogSource.frame(for: 0),
                       "旧句柄必须保持原样：把旧 AX 索引用到别的窗口上就是改错窗口")
    }

    // MARK: - 收回不重新最小化（§11 第 6 条）

    func testCollapseAndRestoreNeverReMinimizeTheWindow() async throws {
        await startCatalog(minimized: [0])
        let store = makeStore()
        let focus = try startFocus(store: store)
        let identity = HostFixtures.identity(0)
        let element = try XCTUnwrap(catalogSource.element(for: identity))
        store.apply(plannedTransaction(identity))

        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        focus.cardRectProvider = { _ in CGRect(x: HostFixtures.offscreenOrigin.x + 60, y: 60, width: 320, height: 200) }
        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { writer.totalWrites > 0 }

        // 收回：走恢复原几何，再反向动画。
        let collapseToken = TransitionToken(generation: 2)
        focus.isTokenCurrent = { $0 == collapseToken }
        focus.restoreGeometry(identity, token: collapseToken)
        await pendingUntil { writer.totalWrites > 1 }
        focus.collapse(identity, token: collapseToken, animationMS: 60)
        await pendingUntil { focus.isIdle }
        focus.cancelAnimation()

        XCTAssertEqual(writer.isMinimized(for: element), false,
                       "用户点最小化卡片是要求它回来，收回时不许偷偷塞回 Dock")
        XCTAssertEqual(writer.recordedActions.filter { $0 == "最小化" }.count, 0)
        XCTAssertEqual(writer.recordedActions.filter { $0 == "解除最小化" }.count, 1,
                       "解除最小化只做一次：\(writer.recordedActions)")
        XCTAssertEqual(writer.writtenFrames.last, FakeCatalogSource.frame(for: 0),
                       "恢复的是原几何，不是 Dock 位置")
    }

    // MARK: - 已有最后一帧后再最小化（§11 收尾）

    func testMinimizingAfterLastFrameKeepsPictureAndResumesCapture() async throws {
        let metal = try HostFixtures.metalContext()
        var runs: [FakeCaptureRun] = []
        let catalog = HostCapture.catalog()
        let coordinator = CaptureCoordinator(metal: metal,
                                            catalog: catalog,
                                            sampleQueue: DispatchQueue(label: "com.misswell.Vistile.test.minimize"),
                                            runFactory: { request in
                                                let run = FakeCaptureRun(request: request)
                                                runs.append(run)
                                                return run
                                            },
                                            singleFrame: { _, _ in .unavailable })
        defer { coordinator.stopAll(releasingMailboxes: true) }
        let identity = HostFixtures.identity(0)

        coordinator.sync(targets: [captureTarget(0, minimized: false)], tier: .balanced, isAnimating: false)
        await pump()
        XCTAssertEqual(coordinator.activeStreamCount, 1, "未最小化时应有直播流")
        let frame = try HostFixtures.metalFrame(metal: metal, width: 160, height: 100)
        runs[0].frameForPublish = frame
        runs[0].emitFrame()
        await pump()
        XCTAssertNotNil(coordinator.mailbox(for: identity).lastPublishedAt, "最后一帧必须进信箱")

        // 运行中最小化：停流但保留信箱，卡片继续显示最后一帧（方案 §11）。
        coordinator.sync(targets: [captureTarget(0, minimized: true)], tier: .balanced, isAnimating: false)
        await pump(6)
        XCTAssertEqual(coordinator.mode(for: identity), .paused)
        XCTAssertNotNil(coordinator.mailbox(for: identity).lastPublishedAt, "最小化不能把已抓到的画面抹掉")

        // 解除最小化后重新捕获：新的一轮必须起来。
        coordinator.sync(targets: [captureTarget(0, minimized: false)], tier: .balanced, isAnimating: false)
        await pump(6)
        XCTAssertEqual(coordinator.mode(for: identity), .live)
        XCTAssertEqual(runs.count, 2, "解除最小化后要重新起流，不能只改状态不发帧")
    }

    // MARK: - 辅助

    private func captureTarget(_ index: Int, minimized: Bool) -> CaptureTarget {
        var record = HostFixtures.record(index, slot: index)
        record.isMinimized = minimized
        record.capture = minimized ? .pausedMinimized : .idle
        return CaptureTarget(record: record, cellWidth: 320, backingScale: 2, isPriority: false)
    }

    private func pump(_ times: Int = 4) async {
        for _ in 0..<times {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VistileHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchDirectories.append(url)
        return url
    }

    private func transientDefaults() -> UserDefaults {
        let suite = "VistileHostTests.\(UUID().uuidString)"
        testDefaultsSuites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
}
