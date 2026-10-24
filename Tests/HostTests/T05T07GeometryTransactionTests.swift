import AppKit
import ApplicationServices
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// T05/T06/T07：几何事务的可靠性与展开/退出交错（方案 §6.1–§6.6、§10.2、§10.5、§15.2）。
///
/// 全部断言落在"外部写入之前与之后的事实"上：
/// T05 恢复失败（含偏差、含事实不足）的事务必须留在日志里，只有确定结束的那条才单独清除；
/// T06 写 AX 之前磁盘上必须已经躺着这次修改的意图，日志落盘失败时一个字节都不许写；
/// T07 展开与退出交错时，最后一次写入必须是原 frame，未处理完的意图不许被清掉。
/// 窗口几何一律 offscreen（x = −20 000），写入走替身：不动用户桌面，也不碰真实 AX。
@MainActor
final class T05T07GeometryTransactionTests: XCTestCase {
    private let sessionID = UUID()
    private var permissions: FakePermissions!
    private var catalogSource: FakeCatalogSource!
    private var processIdentity: FakeProcessIdentity!
    private var writer: FakeGeometryWriter!
    private lazy var scheduler = HostScheduler.make(sessionID: sessionID)
    private var catalog: WindowCatalog!
    private var settings: SettingsModel!
    private var recovery: RecoveryCoordinator!
    private var journalDirectory: URL!
    private var scratchDirectories: [URL] = []
    private var testDefaultsSuites: [String] = []

    private var displayID: UInt32 { HostFixtures.display.id }
    /// 展开目标：夹在替身屏幕的可用区内，与 reducer 给 plannedFrame 的方式一致。
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

    /// 建立目录：窗口 0…3 可唯一匹配，句柄与记录同代次，替身写入器 seeded 到原始 frame。
    private func startCatalog(indices: [Int] = [0, 1, 2, 3]) async {
        catalogSource.addWindows(indices)
        catalog = WindowCatalog(permissions: permissions,
                               axSource: catalogSource,
                               contentSource: catalogSource,
                               displaySource: FakeDisplaySource(displays: [HostFixtures.display]))
        await catalog.refreshAndWait(reason: .reconcile)
        for index in indices {
            let identity = HostFixtures.identity(index)
            XCTAssertEqual(catalog.record(for: identity)?.allowsGeometryControl, true,
                           "窗口 \(index) 必须被判为可控，否则根本走不到写入路径")
            if let element = catalogSource.element(for: identity) {
                writer.setInitialFrame(FakeCatalogSource.frame(for: index), for: element)
            }
        }
    }

    private func makeStore(baseDirectory: URL? = nil) -> WindowJournalStore {
        WindowJournalStore(fileName: "session-journal.json",
                           sessionID: sessionID,
                           baseDirectory: baseDirectory ?? journalDirectory)
    }

    private func startRecovery(store: WindowJournalStore) {
        recovery = RecoveryCoordinator(store: store,
                                       writer: writer,
                                       catalog: catalog,
                                       settings: settings,
                                       permissions: permissions,
                                       processIdentity: processIdentity,
                                       scheduler: scheduler)
    }

    private func startFocus(
        store: WindowJournalStore,
        recorder: CompatibilityRecorder? = nil,
        activateApplication: ((pid_t) -> (returned: Bool, isActive: Bool)?)? = nil,
        makeWatchdogTimer: ((TimeInterval, @escaping @Sendable (Timer) -> Void) -> Timer)? = nil
    ) throws -> FocusCoordinator {
        let metal = try HostFixtures.metalContext()
        return FocusCoordinator(catalog: catalog,
                                metal: metal,
                                writer: writer,
                                store: store,
                                settings: settings,
                                metrics: .shared,
                                recorder: recorder ?? CompatibilityRecorder(fileName: "host-test-\(UUID().uuidString)"),
                                recovery: recovery,
                                permissions: permissions,
                                scheduler: scheduler,
                                activateApplication: activateApplication,
                                makeWatchdogTimer: makeWatchdogTimer)
    }

    // MARK: - T05 恢复失败留痕，结束项单独清除

    func testFailedAndDeviantRestoresStayInJournalWhileSettledOneIsRemoved() async throws {
        await startCatalog()
        let store = makeStore()
        startRecovery(store: store)

        let rejected = HostFixtures.identity(0)
        let deviating = HostFixtures.identity(1)
        let settled = HostFixtures.identity(2)
        let rejectedOriginal = FakeCatalogSource.frame(for: 0)
        let deviatingOriginal = FakeCatalogSource.frame(for: 1)

        // 三条都已经把窗口改成展开尺寸（读回 = 目标），退出时都要回到原 frame。
        for identity in [rejected, deviating, settled] {
            await store.apply(plannedTransaction(identity)
                .markingWritten(readBack: expandedFrame, displayID: displayID))
            if let element = catalogSource.element(for: identity) {
                writer.setInitialFrame(expandedFrame, for: element)
            }
        }
        writer.setScript(.rejects, for: try XCTUnwrap(catalogSource.element(for: rejected)))
        writer.setScript(.constrains, for: try XCTUnwrap(catalogSource.element(for: deviating)))
        // 第三条已经被用户带回原位：不写入，事务按事实结束。
        writer.setInitialFrame(FakeCatalogSource.frame(for: 2),
                               for: try XCTUnwrap(catalogSource.element(for: settled)))

        let results = await recovery.restoreOnQuit(token: TransitionToken(generation: 1),
                                                   deadline: nil).items
        let outcome = { (identity: WindowIdentity) in
            results.first { $0.identity == identity }?.outcome
        }

        guard case .rejected = outcome(rejected) else {
            return XCTFail("写入被拒绝要如实回报，实际 \(String(describing: outcome(rejected)))")
        }
        guard case .constrained(_, let deviation) = outcome(deviating), deviation > 0 else {
            return XCTFail("任意偏差不算恢复成功，实际 \(String(describing: outcome(deviating)))")
        }
        XCTAssertEqual(outcome(settled), .alreadyAtOriginal)

        // 失败项与偏差项：记录留着、原 frame 不能被改写、重试计数要能看出来。
        for (identity, original) in [(rejected, rejectedOriginal), (deviating, deviatingOriginal)] {
            let kept = store.entry(for: identity)
            XCTAssertEqual(kept?.state, .failed, "\(identity.windowID) 未恢复成功必须留可重试记录")
            XCTAssertEqual(kept?.originalFrame, original, "\(identity.windowID) 的原尺寸不能被子写入结果替换")
            XCTAssertEqual(kept?.restoreAttempts, 1)
            XCTAssertEqual(kept?.failureReason?.isEmpty == false, true)
            XCTAssertTrue(kept?.state.requiresRestore ?? false)
        }
        XCTAssertNil(store.entry(for: settled), "确定结束的才允许清除")

        // 落盘事实：换 store 从同一目录重读，结论必须一致（内存状态不算数）。
        let reloaded = makeStore()
        XCTAssertEqual(Set(reloaded.unfinished.map(\.identity)), Set([rejected, deviating]))

        // 收尾"只清已结束的"：把失败项一起交进去也必须留下。
        _ = await store.clearSettled(sessionID: sessionID, settledIdentities: [rejected, deviating, settled])
        XCTAssertEqual(Set(store.snapshot.entries.keys), Set([rejected.journalKey, deviating.journalKey]))
        XCTAssertFalse(store.unfinished.isEmpty, "仍有窗口未恢复时不能报告'已全部处理'")

        // 两次写入都是"试图回到原 frame"，不是把展开尺寸再写一遍。
        XCTAssertEqual(writer.writtenFrames.map(RecoveryCoordinator.text).sorted(),
                       [rejectedOriginal, deviatingOriginal].map(RecoveryCoordinator.text).sorted())
        XCTAssertEqual(writer.totalWrites, 2)
    }

    func testUnreadableAXHandleDefersWithoutDeletingOrWriting() async throws {
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        let identity = HostFixtures.identity(0)
        await store.apply(plannedTransaction(identity).markingWritten(readBack: expandedFrame, displayID: displayID))
        if let element = catalogSource.element(for: identity) {
            writer.setInitialFrame(expandedFrame, for: element)
        }

        // 下一轮查询读不到 AX 句柄：这是"事实不足"，不等于窗口消失。
        catalogSource.publishesAX = false
        await catalog.refreshAndWait(reason: .reconcile)
        XCTAssertNil(catalog.axEntry(for: try XCTUnwrap(catalog.record(for: identity))))

        let results = await recovery.restoreOnQuit(token: TransitionToken(generation: 1),
                                                   deadline: nil).items
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.outcome, .notAttempted("辅助功能句柄暂不可用"),
                       "句柄读不到属于事实不足：既不写也不删，还要说清原因")
        XCTAssertEqual(writer.totalWrites, 0, "事实不足不得盲写")
        XCTAssertEqual(store.entry(for: identity)?.state.requiresRestore, true, "事务必须原样保留")
        XCTAssertEqual(store.entry(for: identity)?.originalFrame, FakeCatalogSource.frame(for: 0))
    }

    func testReusedProcessIDSettlesInsteadOfResizingSomebodyElsesWindow() async throws {
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        let identity = HostFixtures.identity(0)
        await store.apply(plannedTransaction(identity).markingWritten(readBack: expandedFrame, displayID: displayID))
        if let element = catalogSource.element(for: identity) {
            writer.setInitialFrame(expandedFrame, for: element)
        }

        // PID 还在，但已经不是原来那个进程：写回去只会改到别人的窗口。
        processIdentity.markProcessRestarted(processID: identity.processID)
        let results = await recovery.restoreOnQuit(token: TransitionToken(generation: 1),
                                                   deadline: nil).items

        XCTAssertEqual(results.map(\.outcome), [.windowGone])
        XCTAssertEqual(writer.totalWrites, 0)
        XCTAssertNil(store.entry(for: identity), "原窗口已不存在，事务按事实结束")
    }

    // MARK: - 读回是事实：错误码不许覆盖读回证据（方案 §6.1）

    /// run10 实况：Chrome 位置写入返回 -25204「无法完成」，读回 66,184 与目标 66,183 只差 1pt。
    /// 错误码优先会把一个已经落位的窗口宣布为失败，再触发一次多余的"恢复"写入。
    func testCannotCompleteErrorWithReadBackAtTargetIsExact() {
        let target = CGRect(x: 66, y: 183, width: 1_505, height: 973)
        let before = CGRect(x: 54, y: 40, width: 1_746, height: 1_129)
        let readBack = CGRect(x: 66, y: 184, width: 1_505, height: 973)

        let report = AXWindowResolver.classify(target: target, before: before,
                                               sizeError: Int(AXError.success.rawValue),
                                               positionError: Int(AXError.cannotComplete.rawValue),
                                               readBack: readBack, tolerance: 2)

        XCTAssertEqual(report.outcome, .exact(readBack: readBack),
                       "读回在容差内就是到位：-25204 不许把已到位的窗口判失败")
        XCTAssertEqual(report.positionWriteError, Int(AXError.cannotComplete.rawValue),
                       "错误码仍要留在报告里：证据不许被隐藏")
        XCTAssertEqual(report.readBack, readBack)
    }

    func testWriteErrorWithoutReadBackArrivalStillRejects() {
        let target = CGRect(x: 66, y: 183, width: 1_505, height: 973)
        let before = CGRect(x: 54, y: 40, width: 1_746, height: 1_129)
        let error = Int(AXError.cannotComplete.rawValue)

        // 读回还在原位：没有任何"到位"证据，错误码就是结论。
        let unchanged = AXWindowResolver.classify(target: target, before: before,
                                                  sizeError: 0, positionError: error,
                                                  readBack: before, tolerance: 2)
        XCTAssertEqual(unchanged.outcome, .rejected(.positionWrite(code: error)))

        // 读回动了但没到目标：同样不构成到达证据。
        let partial = AXWindowResolver.classify(target: target, before: before,
                                                sizeError: 0, positionError: error,
                                                readBack: CGRect(x: 100, y: 100, width: 1_505, height: 973),
                                                tolerance: 2)
        XCTAssertEqual(partial.outcome, .rejected(.positionWrite(code: error)))

        // 读不回：错误码照旧，且不许宣称成功。
        let unreadable = AXWindowResolver.classify(target: target, before: before,
                                                   sizeError: 0, positionError: error,
                                                   readBack: nil, tolerance: 2)
        XCTAssertEqual(unreadable.outcome, .rejected(.positionWrite(code: error)))
    }

    func testSuccessCodesKeepExistingReadBackSemantics() {
        let target = CGRect(x: 66, y: 183, width: 1_505, height: 973)
        let before = CGRect(x: 54, y: 40, width: 1_746, height: 1_129)
        let partial = CGRect(x: 66, y: 40, width: 1_505, height: 1_129)

        func classify(_ readBack: CGRect?) -> GeometryWriteReport {
            AXWindowResolver.classify(target: target, before: before,
                                      sizeError: Int(AXError.success.rawValue),
                                      positionError: Int(AXError.success.rawValue),
                                      readBack: readBack, tolerance: 2)
        }

        XCTAssertEqual(classify(target).outcome, .exact(readBack: target))
        XCTAssertEqual(classify(before).outcome, .rejected(.unchangedByWrite(previous: before)))
        XCTAssertEqual(classify(partial).outcome, .constrained(readBack: partial))
        XCTAssertEqual(classify(nil).outcome, .unreadable)
    }

    // MARK: - T06 写前必须已有可靠记录；日志失败时不许写 AX

    func testJournalIntentIsOnDiskBeforeTheAXWriteHappens() async throws {
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        let focus = try startFocus(store: store)

        let identity = HostFixtures.identity(0)
        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        let journalFile = journalDirectory
        let journalSession = sessionID

        // 写入真正发生的那一刻去读磁盘：日志里必须已经躺着这次修改的意图。
        var entryAtWriteTime: WindowTransaction?
        writer.onWillWrite = { _ in
            entryAtWriteTime = WindowJournalStore(fileName: "session-journal.json",
                                                  sessionID: journalSession,
                                                  baseDirectory: journalFile)
                .snapshot.entries[identity.journalKey]
        }
        var sawWriteResult = false
        focus.onEvent = { event in
            if case .geometryWriteFinished = event { sawWriteResult = true }
        }

        await store.apply(plannedTransaction(identity))
        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { self.writer.totalWrites > 0 && sawWriteResult }

        let recorded = try XCTUnwrap(entryAtWriteTime, "写 AX 时磁盘上没有对应事务：等于没有可靠记录就改了窗口")
        XCTAssertEqual(recorded.state, .mutationPlanned, "修改意图必须早于任何 AX 写入落盘")
        XCTAssertEqual(recorded.plannedFrame, expandedFrame)
        // 计划值与实际写入值必须是同一个数（方案 §6.2）。
        XCTAssertEqual(writer.writtenFrames.first, recorded.plannedFrame)
        focus.cancelAnimation()
    }

    func testJournalPersistFailureBlocksEveryAXWrite() async throws {
        await startCatalog(indices: [0])
        // 让日志目录无法创建：原子写入必然失败。
        let blocked = try makeScratchDirectory()
        try Data("不是目录".utf8).write(to: blocked.appendingPathComponent("Vistile"))
        let store = makeStore(baseDirectory: blocked)
        startRecovery(store: store)
        let focus = try startFocus(store: store)

        let identity = HostFixtures.identity(0)
        let write = await store.apply(plannedTransaction(identity))
        XCTAssertFalse(write.isPersisted, "这种目录结构下日志写不进去：\(String(describing: write.reason))")
        XCTAssertNotNil(write.reason)
        // 落盘失败要回滚：内存里也不能假装"已经记下"，否则守卫形同虚设。
        XCTAssertNil(store.entry(for: identity))

        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        var timedOut = false
        var statuses: [String] = []
        focus.onEvent = { event in
            if case .transitionTimedOut = event { timedOut = true }
        }
        focus.onStatus = { statuses.append($0) }

        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { timedOut }

        XCTAssertEqual(writer.totalWrites, 0, "没有可靠事务时一个几何写入都不许发生")
        XCTAssertEqual(writer.raiseCount, 0, "连前景化也不该做：这次展开根本没开始")
        XCTAssertTrue(statuses.contains { $0.contains("事务") }, "拒绝原因要能显示给用户：\(statuses)")
        focus.cancelAnimation()
    }

    // MARK: - T07 展开与退出交错

    func testRevocationDuringRaisePreventsFocusAndActivation() async throws {
        try await assertForegroundStopsAfterRevocation(at: .raise)
    }

    func testRevocationDuringFocusPreventsReadBackAndActivation() async throws {
        try await assertForegroundStopsAfterRevocation(at: .focus)
    }

    func testRevocationDuringFocusedWindowReadPreventsActivation() async throws {
        try await assertForegroundStopsAfterRevocation(at: .focusedWindow)
    }

    private func assertForegroundStopsAfterRevocation(at gate: FakeGeometryWriter.ForegroundGate) async throws {
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        var activatedPIDs: [pid_t] = []
        let focus = try startFocus(store: store, activateApplication: {
            activatedPIDs.append($0)
            return (true, true)
        })
        let identity = HostFixtures.identity(0)
        let blocked = expectation(description: "前景化停在 \(gate)")
        writer.gateNextForegroundCall(gate) { blocked.fulfill() }
        defer { writer.openForegroundGate() }
        let context = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .settleLayout)
        let run = Task {
            await self.scheduler.request(context: context, identities: [identity]) { permit in
                await focus.activateAndRaise(identity, permit: permit)
            }
        }
        await fulfillment(of: [blocked], timeout: 5)
        XCTAssertEqual(writer.blockedForegroundGate, gate)
        XCTAssertEqual(writer.raiseCount, 1)
        XCTAssertTrue(activatedPIDs.isEmpty)

        scheduler.cancelOrdinaryWrites(sessionID: sessionID)
        XCTAssertEqual(scheduler.phase, .open, "相位仍开放：必须检查原许可，不能重新取得许可")
        writer.openForegroundGate()
        let result = await run.value
        let facts = try XCTUnwrap(result)
        await scheduler.fence(identities: [identity])

        XCTAssertEqual(writer.focusCount, gate == .raise ? 0 : 1,
                       "Raise 挂起时撤销，释放后不得再发 focus")
        XCTAssertEqual(writer.focusedWindowReadCount, gate == .focusedWindow ? 1 : 0,
                       "focus 挂起时撤销，释放后不得继续读取 focused window")
        XCTAssertTrue(activatedPIDs.isEmpty, "撤销后旧操作不得调用应用激活接缝")
        XCTAssertTrue(facts.raiseReturned, "已在途的 Raise 返回值仍是事实")
        XCTAssertFalse(facts.activationRequested)
        XCTAssertFalse(facts.activationReturned)
        XCTAssertNil(facts.focusedWindowMatches, "撤销后不采纳迟到的焦点读回")
        XCTAssertNil(facts.frontApplicationMatches)
        XCTAssertEqual(writer.totalWrites, 0)
    }

    func testGrantedForegroundPermitReachesApplicationActivation() async throws {
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        var activatedPIDs: [pid_t] = []
        let focus = try startFocus(store: store, activateApplication: {
            activatedPIDs.append($0)
            return (true, true)
        })
        let identity = HostFixtures.identity(0)
        let context = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .settleLayout)
        let result = await scheduler.request(context: context, identities: [identity]) { permit in
            await focus.activateAndRaise(identity, permit: permit)
        }
        let facts = try XCTUnwrap(result)

        XCTAssertEqual(writer.raiseCount, 1)
        XCTAssertEqual(writer.focusCount, 1)
        XCTAssertEqual(writer.focusedWindowReadCount, 1)
        XCTAssertEqual(activatedPIDs, [identity.processID], "接缝必须在真实前景化路径上被调用")
        XCTAssertTrue(facts.activationRequested)
        XCTAssertTrue(facts.activationReturned)
        XCTAssertEqual(facts.focusedWindowMatches, true)
        XCTAssertEqual(facts.frontApplicationMatches, true)
    }

    func testExpandTimeoutBeforeAnimationDoesNotInheritCollapseDirection() async throws {
        try await assertQueuedTimeoutDirection(expanding: true)
    }

    func testCollapseTimeoutBeforeAnimationDoesNotInheritExpandDirection() async throws {
        try await assertQueuedTimeoutDirection(expanding: false)
    }

    private func assertQueuedTimeoutDirection(expanding: Bool) async throws {
        scheduler = HostScheduler.make(clock: HostClock(), sessionID: sessionID)
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        let recorder = CompatibilityRecorder(fileName: "host-test-\(UUID().uuidString)")
        var timers: [Timer] = []
        var timerIntervals: [TimeInterval] = []
        let focus = try startFocus(store: store, recorder: recorder,
                                   activateApplication: { _ in (true, true) },
                                   makeWatchdogTimer: { interval, callback in
            let timer = Timer(fire: .distantFuture, interval: interval, repeats: false, block: callback)
            timers.append(timer)
            timerIntervals.append(interval)
            return timer
        })
        defer { focus.cancelAnimation() }
        focus.cardRectProvider = { _ in .zero }
        let identity = HostFixtures.identity(0)
        let previousToken = TransitionToken(generation: 1)
        let token = TransitionToken(generation: 2)
        var events: [SessionEvent] = []
        focus.onEvent = { events.append($0) }
        if expanding {
            focus.collapse(identity, token: previousToken, animationMS: 60)
        } else {
            await store.apply(plannedTransaction(identity))
            focus.expand(identity, targetFrame: expandedFrame, token: previousToken, animationMS: 60)
        }
        await scheduler.fence(identities: [identity])
        XCTAssertTrue(focus.isIdle)
        XCTAssertTrue(events.contains(expanding ? .collapseCompleted(previousToken) : .expandCompleted(previousToken)),
                      "前一轮相反方向必须真实完成")
        if !expanding {
            let entry = try XCTUnwrap(store.entry(for: identity))
            let restored = await recovery.restore(entry: entry, token: previousToken)
            XCTAssertEqual(restored.outcome, .restored)
        }
        events.removeAll()
        let writesBeforeTimeout = writer.totalWrites

        let blocked = expectation(description: "通道占用，下一轮尚未进入动画")
        let release = OneShot<Void>()
        defer { release.send(()) }
        let context = scheduler.makeContext(token: previousToken, kind: .settleLayout)
        XCTAssertTrue(scheduler.perform(GeometryOperationScheduler.Operation(
            context: context, identities: [identity], run: { _ in
                blocked.fulfill()
                await withCheckedContinuation { release.attach($0) }
            })))
        await fulfillment(of: [blocked], timeout: 5)
        if expanding {
            focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        } else {
            focus.collapse(identity, token: token, animationMS: 60)
        }
        XCTAssertTrue(focus.isAnimating)
        XCTAssertEqual(scheduler.queuedCount, 1)
        XCTAssertEqual(timers.count, 2)
        let timer = try XCTUnwrap(timers.last)
        XCTAssertFalse(timers[0].isValid, "前一轮 watchdog 应已收场")
        let budgetMS = expanding ? 1_560 : 260
        XCTAssertEqual(timerIntervals.last, TimeInterval(budgetMS) / 1000)
        timer.fire()

        XCTAssertFalse(focus.isAnimating)
        XCTAssertEqual(events, [.transitionTimedOut(token)])
        let direction = expanding ? "展开" : "收回"
        let previousDirection = expanding ? "收回" : "展开"
        let report = recorder.markdownText
        XCTAssertTrue(report.contains("\(direction)在 \(budgetMS)ms 内未确认"), report)
        XCTAssertFalse(report.contains("\(previousDirection)在 \(budgetMS)ms 内未确认"), report)
        release.send(())
        await scheduler.fence(identities: [identity])
        XCTAssertEqual(events, [.transitionTimedOut(token)], "超时后旧队列项不能再宣布完成")
        XCTAssertEqual(writer.totalWrites, writesBeforeTimeout)
        XCTAssertTrue(focus.isIdle)
    }

    func testExpiredTokenCompensatesInsteadOfLeavingWindowResized() async throws {
        await startCatalog(indices: [0])
        let store = makeStore()
        startRecovery(store: store)
        let focus = try startFocus(store: store)

        let identity = HostFixtures.identity(0)
        let original = FakeCatalogSource.frame(for: 0)
        let token = TransitionToken(generation: 1)
        var tokenIsCurrent = true
        focus.isTokenCurrent = { _ in tokenIsCurrent }

        var events: [SessionEvent] = []
        focus.onEvent = { events.append($0) }
        var statuses: [String] = []
        focus.onStatus = { statuses.append($0) }
        await store.apply(plannedTransaction(identity))

        // 写入正在进行时状态机已经走了（退出/会话关闭）。
        writer.gatesNextWrite = true
        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 200)
        await pendingUntil { self.writer.isBlockedInWrite }
        tokenIsCurrent = false
        // 补偿那一笔由替身报信，不等墙钟：原来这里 poll「1 秒内出现第二笔写入」，赌的是机器快，
        // 同一份代码在 CI 上重跑就绿了——那是测时序不是测行为（方案 §18「不加真实 sleep 赌时序」）。
        // "不是等总超时兜底"改用结构判据：补偿到位时不许出现「过渡超时」那条回报。
        let compensation = OneShot<Int>()
        writer.onWillWrite = { [weak writer] _ in
            guard let writer, writer.totalWrites >= 2 else { return }
            compensation.send(writer.totalWrites)
        }
        writer.openGate()
        // 看门狗只负责"没补偿时把挂死变成可读的失败"，通过的判据仍是第二笔写入这个事件本身：
        // 补偿真要来了，5 秒这个数字参与不了任何结论。
        Task { [weak compensation] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            compensation?.send(-1)
        }
        let arrived = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            compensation.attach(continuation)
        }
        writer.onWillWrite = nil
        XCTAssertEqual(arrived, 2, "补偿就是第二笔写入本身（报回 \(arrived) 笔）：\(writer.writtenFrames)")
        XCTAssertTrue(statuses.filter { $0.contains("过渡超时") }.isEmpty,
                      "补偿必须紧接在过期写入之后，不能是 200+1500ms 总超时兜底跑出来的：\(statuses)")
        // 事务结算发生在补偿那一笔的 work 闭包里（markRestored → drop）。
        // 栅栏等的就是"这一笔在通道上彻底走完"，所以既不用轮询也不设时长。
        await scheduler.fence(identities: [identity])
        XCTAssertEqual(writer.writtenFrames, [expandedFrame, original],
                       "过期写入改掉了 frame，就必须补偿回原尺寸")
        XCTAssertFalse(events.contains { if case .geometryWriteFinished = $0 { return true } else { return false } },
                       "过期操作的结果不得再进入状态机：\(events)")
        XCTAssertFalse(events.contains { if case .expandCompleted = $0 { return true } else { return false } },
                       "过期操作不得宣布展开完成：\(events)")
        XCTAssertNil(store.entry(for: identity), "补偿成功后事务才算结束")
        XCTAssertTrue(store.unfinished.isEmpty)
        focus.cancelAnimation()
    }

    /// A05（方案 §18 A05）：写入正在途中时退出——恢复必须排在这笔在途写入之后，
    /// 并把未完成的那一笔留在日志里，最终回到 original。
    func testQuitQueuesBehindInFlightExpandAndKeepsUnfinishedIntent() async throws {
        await startCatalog(indices: [0, 2, 3])
        let store = makeStore()
        startRecovery(store: store)
        let focus = try startFocus(store: store)

        let identity = HostFixtures.identity(0)
        let original = FakeCatalogSource.frame(for: 0)
        let expandToken = TransitionToken(generation: 1)
        let quitToken = TransitionToken(generation: 2)
        focus.isTokenCurrent = { _ in true }

        var restored: [RestoreItemResult] = []
        var sawRestoreCompleted = false
        focus.onEvent = { event in
            if case .geometryRestoreSettled(let token, let items) = event, token == quitToken {
                restored.append(contentsOf: items)
            }
            if case .restoreCompleted(let token) = event, token == quitToken { sawRestoreCompleted = true }
        }
        await store.apply(plannedTransaction(identity))

        writer.gatesNextWrite = true
        focus.expand(identity, targetFrame: expandedFrame, token: expandToken, animationMS: 60)
        await pendingUntil { self.writer.isBlockedInWrite }

        // 展开还没写完就退出：同一窗口的恢复只能排在通道后面，不能并行走第二条写入路径。
        focus.restoreAll([identity], token: quitToken)
        XCTAssertEqual(writer.totalWrites, 0, "进行中的写入不能被越过")

        writer.openGate()
        await pendingUntil(timeout: 3) { sawRestoreCompleted }

        XCTAssertEqual(writer.writtenFrames, [expandedFrame, original],
                       "最后一次写入必须是原 frame：迟到的展开不能把窗口留在展开尺寸")
        XCTAssertEqual(restored.first?.outcome, .restored)
        XCTAssertNil(store.entry(for: identity))
        await pendingUntil { focus.isIdle }

        // 未处理完的意图不能被"清理已结束"顺手删掉，别的会话的记录同样要留（方案 §6.4）。
        let pending = HostFixtures.identity(2)
        let otherSession = HostFixtures.identity(3)
        let otherSessionID = UUID()
        await store.apply(plannedTransaction(pending))
        await store.apply(WindowTransaction(sessionID: otherSessionID,
                                       identity: otherSession,
                                       bundleID: "com.test.app\(otherSession.windowID)",
                                       originalFrame: FakeCatalogSource.frame(for: 3),
                                       originalDisplayID: displayID).markingRestored())
        _ = await store.clearSettled(sessionID: sessionID, settledIdentities: [pending, otherSession])
        XCTAssertEqual(Set(store.snapshot.entries.keys),
                       Set([pending.journalKey, otherSession.journalKey]),
                       "本会话未完成记录与其他会话记录都必须保留")
        focus.cancelAnimation()
    }

    // MARK: - A38 无响应 AX 到退出期限：等待有界、日志保留、不再启动新恢复写入（方案 §14）

    /// 第一笔恢复的 AX 调用不返回，期限在这一期间到点。
    /// 放行之后：已经动过的那一笔按事实结算，另一笔**不得**再发起新的恢复写入，
    /// 未完成事务必须原样留在日志里交给下次启动核对（方案 §14.3–§14.5）。
    func testDeadlineDuringUnresponsiveRestoreKeepsJournalAndStartsNoFurtherWrite() async throws {
        let clock = HostClock()
        scheduler = HostScheduler.make(clock: clock, sessionID: sessionID)
        await startCatalog()
        let store = makeStore()
        startRecovery(store: store)

        let first = HostFixtures.identity(0)
        let second = HostFixtures.identity(1)
        for identity in [first, second] {
            await store.apply(plannedTransaction(identity)
                .markingWritten(readBack: expandedFrame, displayID: displayID))
            if let element = catalogSource.element(for: identity) {
                writer.setInitialFrame(expandedFrame, for: element)
            }
        }
        XCTAssertEqual(store.unfinished.count, 2, "前置事实：两条都还欠着恢复")

        let deadline = scheduler.deadline(after: .seconds(2))
        // 第一笔恢复的 AX 写入停在"命令已排到队列头"这一刻：模拟无响应应用。
        writer.gatesNextWrite = true
        let run = Task {
            await self.recovery.restoreOnQuit(token: TransitionToken(generation: 1), deadline: deadline)
        }
        await pendingUntil { self.writer.isBlockedInWrite }
        XCTAssertTrue(scheduler.canStartNewWrite(deadline: deadline), "前置事实：此刻预算还没用完")

        // 期限到点（手动时钟推进，不靠真实 sleep 赌时序）。
        clock.advance(seconds: 3)
        XCTAssertFalse(scheduler.canStartNewWrite(deadline: deadline), "前置事实：预算已尽")

        // 无响应的那一笔最终自己回来了：它已经在途，只能按事实结算，不算"新写入"。
        writer.openGate()
        await pendingUntil { !self.writer.isBlockedInWrite }
        let report = await run.value

        XCTAssertEqual(report.items.count, 1, "只有到期前已经开始的那一笔被恢复：\(report.items)")
        XCTAssertEqual(report.deferredByDeadline.count, 1,
                       "预算已尽时必须按「推迟」回报，不能悄悄跳过：\(report.deferredByDeadline)")
        let restored = try XCTUnwrap(report.items.first)
        let deferred = try XCTUnwrap(report.deferredByDeadline.first)
        XCTAssertEqual(writer.totalWrites, 1,
                       "到期后不得再发起第二条恢复写入：\(writer.writtenFrames)")
        XCTAssertEqual(writer.writtenFrames, [FakeCatalogSource.frame(for: Int(restored.identity.windowID) - 9_000)])
        let deferredElement = try XCTUnwrap(catalogSource.element(for: deferred))
        let deferredFrame = await writer.currentFrame(of: deferredElement)
        XCTAssertEqual(deferredFrame, expandedFrame,
                       "被推迟的窗口必须还在展开尺寸：动过它就是那条禁令的反例")
        XCTAssertEqual(store.entry(for: deferred)?.state.requiresRestore, true,
                       "未确认恢复的事务要留给下次启动：清掉就是把没做完的事当成做完了")
        XCTAssertNil(store.entry(for: restored.identity), "确认回到原位置的才允许结束")
        XCTAssertFalse(store.unfinished.isEmpty)

        // 下次启动核对：预算回来（deadline 为 nil）后那条推迟的能正常补上。
        let retry = await recovery.restoreOnQuit(token: TransitionToken(generation: 2), deadline: nil)
        XCTAssertEqual(retry.items.map(\.identity), [deferred])
        XCTAssertTrue(retry.deferredByDeadline.isEmpty, "预算回来后要能补上那条推迟的恢复")
        let restoredFrame = await writer.currentFrame(of: deferredElement)
        XCTAssertEqual(restoredFrame, FakeCatalogSource.frame(for: 1))
        XCTAssertNil(store.entry(for: deferred))
    }

    /// 退出等待只结算一次：到期与链收敛两条路谁先到算谁，另一条必须被忽略（方案 §14.4、A38/A39）。
    func testTerminationWaitResolvesOnceWithWhicheverArrivesFirst() async throws {
        let expiredFirst = OneShot<String>()
        expiredFirst.send("到期")
        expiredFirst.send("链收敛")
        let expiredResult = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            expiredFirst.attach(continuation)
        }
        XCTAssertEqual(expiredResult, "到期", "到期后迟到的链结论不许改写已生效的收口（方案 §14.5）")

        let chainFirst = OneShot<String>()
        chainFirst.send("链收敛")
        chainFirst.send("到期")
        let chainResult = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            chainFirst.attach(continuation)
        }
        XCTAssertEqual(chainResult, "链收敛", "链先收敛时到期那一笔要作废，否则终止回调会走两遍")
    }

    // MARK: - 辅助

    /// 与 reducer `ensureTransaction` 同构：意图先落盘，宿主确认写成功后才允许动 AX。
    private func plannedTransaction(_ identity: WindowIdentity) -> WindowTransaction {
        let index = Int(identity.windowID) - 9_000
        return WindowTransaction(sessionID: sessionID,
                                 identity: identity,
                                 bundleID: "com.test.app\(identity.windowID)",
                                 originalFrame: FakeCatalogSource.frame(for: index),
                                 originalDisplayID: displayID)
            .markingPlanned(frame: expandedFrame, displayID: displayID)
    }

    /// 等主 Actor 上的异步工作推进：await 让出主 Actor，替身的续接才有机会跑完。
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
            .appendingPathComponent("VistileHostTests-\(UUID().uuidString)", isDirectory: true)
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
