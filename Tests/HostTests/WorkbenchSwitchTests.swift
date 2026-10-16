import AppKit
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// 工作台 A/B 交换的宿主执行器回归（方案 §18.2 H04/H05/H06/H07/H10/H14/H19/H20/H22）。
///
/// 断言全部落在"外部写入之前与之后的事实"上：每次写入的目标、读回、事务日志与事件流，
/// 不看函数返回值。窗口几何一律 offscreen（x = −20 000），AX/写入/权限全用替身：
/// 不动用户桌面，也不碰真实 AX；可控挂起点（gate）用来确定性地制造交错与超时。
@MainActor
final class WorkbenchSwitchTests: XCTestCase {
    private let sessionID = UUID()
    private var permissions: FakePermissions!
    private var catalogSource: FakeCatalogSource!
    private var processIdentity: FakeProcessIdentity!
    private var writer: FakeGeometryWriter!
    private var catalog: WindowCatalog!
    private var settings: SettingsModel!
    private var recovery: RecoveryCoordinator!
    private var store: WindowJournalStore!
    private var recorder: CompatibilityRecorder!
    private var journalDirectory: URL!
    private var scratchDirectories: [URL] = []
    private var testDefaultsSuites: [String] = []

    private var fixture: HostWorkbenchFixture!
    private var coordinator: WorkbenchSwitchCoordinator!
    private var events: [SessionEvent] = []
    private var statuses: [String] = []
    private var heartbeat: Task<Void, Never>?

    private var displayID: UInt32 { HostFixtures.display.id }
    private var a: WindowIdentity { HostFixtures.identity(0) }
    private var b: WindowIdentity { HostFixtures.identity(1) }

    override func setUpWithError() throws {
        permissions = FakePermissions()
        catalogSource = FakeCatalogSource()
        processIdentity = FakeProcessIdentity()
        writer = FakeGeometryWriter()
        settings = SettingsModel(defaults: transientDefaults())
        recorder = CompatibilityRecorder(fileName: "workbench-host-test-\(UUID().uuidString)")
        journalDirectory = try makeScratchDirectory()
        // 最小化事实只有一个来源：应用（替身写入器）。目录每次换代都去读它。
        catalogSource.minimizedReader = { [weak catalogSource, weak writer] identity in
            guard let element = catalogSource?.element(for: identity) else { return false }
            return writer?.isMinimized(for: element) ?? false
        }
    }

    override func tearDown() {
        heartbeat?.cancel()
        heartbeat = nil
        coordinator?.cancel()
        coordinator = nil
        catalog = nil
        recovery = nil
        settings = nil
        fixture = nil
        events = []
        statuses = []
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

    /// 已进入工作台的会话：A 在真实主区（已写、已落盘），B 在侧栏第一格（真实几何未动）。
    @discardableResult
    private func beginHappyPath(minimized: [Int] = [], seedBJournal: Bool = true) async throws -> WorkbenchSwitchPlan {
        await startWorkbench(minimized: minimized)
        store = makeStore()
        let aFrame = seedBJournal ? dockedRect(for: a) : FakeCatalogSource.frame(for: 0)
        store.apply(workbenchTransaction(a, planned: aFrame)
            .markingWritten(readBack: aFrame, displayID: displayID))
        if seedBJournal { store.apply(workbenchTransaction(b, planned: dockedRect(for: b))) }
        if let element = catalogSource.element(for: a) { writer.setInitialFrame(aFrame, for: element) }
        if let element = catalogSource.element(for: b) {
            writer.setInitialFrame(FakeCatalogSource.frame(for: 1), for: element)
        }
        startRecovery()
        try startCoordinator()
        return try switchPlan()
    }

    private func startWorkbench(minimized: [Int]) async {
        catalogSource.addWindows([0, 1, 2, 3])
        catalog = WindowCatalog(permissions: permissions,
                                axSource: catalogSource,
                                contentSource: catalogSource,
                                displaySource: FakeDisplaySource(displays: [HostFixtures.display]),
                                sheetSource: catalogSource)
        for index in minimized {
            let identity = HostFixtures.identity(index)
            if let element = catalogSource.element(for: identity) {
                writer.setMinimizedState(true, for: element)
            }
        }
        await catalog.refreshAndWait(reason: .reconcile)
        fixture = HostWorkbench.fixture()
    }

    private func makeStore() -> WindowJournalStore {
        WindowJournalStore(fileName: "session-journal.json",
                           sessionID: sessionID,
                           baseDirectory: journalDirectory)
    }

    private func startRecovery() {
        recovery = RecoveryCoordinator(store: store,
                                       writer: writer,
                                       catalog: catalog,
                                       settings: settings,
                                       permissions: permissions,
                                       processIdentity: processIdentity)
    }

    private func startCoordinator() throws {
        let metal = try HostFixtures.metalContext()
        let focus = FocusCoordinator(catalog: catalog,
                                     metal: metal,
                                     writer: writer,
                                     store: store,
                                     settings: settings,
                                     metrics: .shared,
                                     recorder: recorder,
                                     recovery: recovery,
                                     permissions: permissions)
        coordinator = WorkbenchSwitchCoordinator(catalog: catalog,
                                                 writer: writer,
                                                 store: store,
                                                 recovery: recovery,
                                                 focus: focus,
                                                 permissions: permissions,
                                                 metrics: .shared,
                                                 recorder: recorder)
        coordinator.onEvent = { [weak self] event in self?.events.append(event) }
        coordinator.onStatus = { [weak self] status in self?.statuses.append(status) }
        coordinator.directive = { _ in .proceed }
    }

    /// reducer 算好的交换计划：B 进主区、A 回原几何（与 `startSwitch` 的输出同构）。
    private func switchPlan(token: TransitionToken = TransitionToken(generation: 1)) throws -> WorkbenchSwitchPlan {
        let slot = try XCTUnwrap(fixture.placement.slot(of: b), "B 必须占着轨道上的一个 slot")
        let intent = WorkbenchSwitchIntent(token: token,
                                           from: a,
                                           to: b,
                                           source: .rail(slot: slot),
                                           placementRevision: fixture.placement.revision,
                                           targetDisplayID: displayID)
        return WorkbenchSwitchPlan(intent: intent,
                                   displayID: displayID,
                                   mainTargetFrame: dockedRect(for: b),
                                   restingTargetFrame: FakeCatalogSource.frame(for: 0),
                                   restingSlot: slot,
                                   snapshot: fixture.snapshot,
                                   presentation: fixture.presentation)
    }

    /// 与 reducer `ensureTransaction` 同构：意图先落盘，宿主确认写成功后才允许动 AX。
    private func workbenchTransaction(_ identity: WindowIdentity, planned: CGRect) -> WindowTransaction {
        let index = Int(identity.windowID) - 9_000
        return WindowTransaction(sessionID: sessionID,
                                 identity: identity,
                                 bundleID: "com.test.app\(identity.windowID)",
                                 originalFrame: FakeCatalogSource.frame(for: index),
                                 originalDisplayID: displayID)
            .markingPlanned(frame: planned, displayID: displayID)
    }

    private func dockedRect(for identity: WindowIdentity) -> CGRect {
        let record = catalog.record(for: identity)
        return FocusGeometry.dockedRect(in: fixture.layout.mainRect,
                                        currentSize: record?.frame.size ?? CGSize(width: 1_280, height: 800),
                                        isResizable: record?.allowsGeometryControl ?? true)
    }

    private func element(of identity: WindowIdentity) throws -> AXUIElement {
        try XCTUnwrap(catalogSource.element(for: identity), "替身目录里必须有该窗口的句柄")
    }

    private func currentFrame(of identity: WindowIdentity) async throws -> CGRect? {
        await writer.currentFrame(of: try element(of: identity))
    }

    private func stepEvents() -> [WorkbenchSwitchStepResult] {
        events.compactMap { if case let .mainSwitchStepFinished(result) = $0 { return result } else { return nil } }
    }

    private func committedTokens() -> [TransitionToken] {
        events.compactMap { if case let .mainSwitchCommitted(token) = $0 { return token } else { return nil } }
    }

    private func failureReasons() -> [String] {
        events.compactMap { if case let .mainSwitchFailed(_, reason) = $0 { return reason } else { return nil } }
    }

    // MARK: - H22 正常交换：先到位、再确认前台、最后才提交

    func testSwitchCommitsAfterActivationAndRestoresPreviousMain() async throws {
        let plan = try await beginHappyPath()

        coordinator.perform(plan)
        await pendingUntil { self.committedTokens().contains(plan.intent.token) }

        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain, .activateMain, .restorePrevious, .commit],
                       "步骤顺序固定：真实窗口可操作后才允许提交（方案 §8.2）")
        XCTAssertEqual(stepEvents().compactMap(\.identity), [b, b, b, a, b],
                       "每一步都要如实带上它动过的窗口")
        XCTAssertEqual(committedTokens(), [plan.intent.token])
        XCTAssertTrue(failureReasons().isEmpty, "正常路径不该出现失败：\(failureReasons())")
        XCTAssertGreaterThanOrEqual(writer.raiseCount, 1, "移交前必须真的提过目标窗口")
        XCTAssertGreaterThan(writer.focusedWindowReadCount, 0,
                             "不清读回就把输入交给缓存画面，等于宣称可用")

        let bFrame = await writer.currentFrame(of: try element(of: b))
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(bFrame, dockedRect(for: b), "B 必须落在主区停靠矩形")
        XCTAssertEqual(aFrame, FakeCatalogSource.frame(for: 0), "A 必须回到它原来的几何")
        await pendingUntil { !self.coordinator.isBusy }
        XCTAssertFalse(coordinator.isBusy)
    }

    // MARK: - H04 目标写入被拒：不提交、补偿、不假成功

    func testTargetRejectionRollsBackAndNeverCommits() async throws {
        let plan = try await beginHappyPath()
        writer.setScript(.rejects, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "写入被拒绝却宣布交换完成，就是假成功")
        XCTAssertEqual(stepEvents().last?.step, .moveToMain)
        XCTAssertFalse(try XCTUnwrap(stepEvents().last).outcome.allowsContinue)
        XCTAssertEqual(writer.writtenFrames, [plan.mainTargetFrame],
                       "只允许一次被拒的目标写入：A 从没被这次动作动过，补偿不许写它")
        let bFrame = await writer.currentFrame(of: try element(of: b))
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "被拒绝的写入不能留下半截几何")
        XCTAssertEqual(aFrame, dockedRect(for: a), "B 写入失败时 A 保持主窗口，不许被拉走（方案 §8.3）")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "A 仍是主窗口：事务保留，退出时还要还原它的原几何")
        XCTAssertNil(store.entry(for: b), "B 一步都没动、也在原几何上，事务按事实结算")
    }

    // MARK: - 写前可调整性：坏采样不拒绝，确凿事实才拒绝

    /// 目录快照里的"不可调整"是采样时刻的折叠值：一次 AX 读超时会被记成 false。
    /// 身份已唯一、句柄在手时，写前直接问一次窗口本身——实测可写就必须照常交换。
    func testTransientUnresizableSampleIsRejudgedAgainstLiveWindow() async throws {
        let plan = try await beginHappyPath()
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .reconcile)
        writer.writeability = .writeable

        coordinator.perform(plan)
        await pendingUntil { !self.committedTokens().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(committedTokens(), [plan.intent.token],
                       "窗口实测可写：坏采样不许把这个交换拦下来")
        XCTAssertEqual(writer.writtenFrames, [plan.mainTargetFrame, FakeCatalogSource.frame(for: 0)])
    }

    /// 实测读到确凿的"不接受尺寸调整"才拒绝，而且一个字节都不写。
    func testConfirmedUnsizableWindowIsRefusedWithoutWrites() async throws {
        let plan = try await beginHappyPath()
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .reconcile)
        writer.writeability = .sizeNotSettable

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "窗口不接受尺寸调整，交换不许宣布完成")
        XCTAssertTrue(failureReasons().contains { $0.contains("AX 确认该窗口不接受尺寸调整") },
                      "拒绝原因必须来自实测事实：\(failureReasons())")
        XCTAssertEqual(writer.totalWrites, 0, "确凿不可写就不该发起任何写入")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain])
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "B 留在原格")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "A 仍是主窗口：事务保留，退出时还要还原它的原几何")
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey, b.journalKey]),
                       "一个窗口都没动过：两边的事务按原样留给恢复路径收尾")
    }

    /// 可写性都读不到时，不能替产品下"不可写"的结论：交给写入自身的读回判定。
    func testUnreadableWriteabilityFallsThroughToTheWriteItself() async throws {
        let plan = try await beginHappyPath()
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .reconcile)
        writer.writeability = .unreadable

        coordinator.perform(plan)
        await pendingUntil { !self.committedTokens().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(committedTokens(), [plan.intent.token],
                       "读不到不是事实：写入能读回一致就按成功走")
        XCTAssertEqual(writer.writtenFrames, [plan.mainTargetFrame, FakeCatalogSource.frame(for: 0)])
    }

    // MARK: - H05 原主写回失败：留痕、不假成功、目标补偿到位

    func testPreviousMainRestoreFailureIsReportedAndKeepsJournal() async throws {
        let plan = try await beginHappyPath()
        writer.setScript(.rejects, for: try element(of: a))

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertEqual(stepEvents().last?.step, .restorePrevious, "失败必须发生在写回原主的那一步")
        XCTAssertFalse(try XCTUnwrap(stepEvents().last).outcome.allowsContinue)
        XCTAssertTrue(failureReasons().contains { $0.contains("被拒绝") },
                      "拒绝原因要如实回报：\(failureReasons())")
        // A 写回失败后，回滚的逆序补偿会对 A 再试一次（restoreQuietly 走同一条恢复路径），
        // 所以是四次尝试：B 进主区、A 写回（被拒）、A 补偿重试（仍被拒）、B 补偿回原几何。
        XCTAssertEqual(writer.writtenFrames,
                       [plan.mainTargetFrame, FakeCatalogSource.frame(for: 0),
                        FakeCatalogSource.frame(for: 0), FakeCatalogSource.frame(for: 1)],
                       "补偿重试也要如实记录：不多写别的窗口，也不假装 A 已经回去")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(aFrame, dockedRect(for: a), "写不回去的窗口保持现状，不能被假装移动")
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "回滚必须把 B 送回原几何")
        XCTAssertEqual(store.entry(for: a)?.state, .failed, "写不回去的事务必须留可重试记录")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true)
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey]),
                       "只有未恢复成功的那个还留着")
    }

    // MARK: - H07 最小化：先解除、再写几何

    func testMinimizedRailTargetIsUnminimizedBeforeGeometryWrite() async throws {
        let plan = try await beginHappyPath(minimized: [1])
        XCTAssertEqual(catalog.record(for: b)?.isMinimized, true, "前置事实：B 此刻在 Dock 里")
        XCTAssertEqual(catalog.record(for: b)?.capture, .pausedMinimized)

        coordinator.perform(plan)
        await pendingUntil { self.committedTokens().contains(plan.intent.token) }

        XCTAssertEqual(writer.recordedActions.first, "解除最小化",
                       "顺序必须是先解除最小化再写几何：\(writer.recordedActions)")
        XCTAssertEqual(writer.unminimizeAttempts, 1)
        XCTAssertEqual(writer.recordedActions.filter { $0 == "写" }.count, 2)
        XCTAssertEqual(catalog.record(for: b)?.isMinimized, false, "解除后目录里的最小化事实必须换代")
        XCTAssertFalse(events.contains { if case .transitionTimedOut = $0 { return true }; return false },
                       "解除成功却报超时，等于把一次正常交换说成失败")
    }

    // MARK: - H07 途中句柄丢失：一个字节都不写

    func testVanishedHandlesLeaveBothJournalsForRecovery() async throws {
        let plan = try await beginHappyPath()
        // 先记下句柄齐全时的停靠几何：句柄丢失后目录换代，dockedRect 会退化成不可调尺寸的居中矩形。
        let aDocked = dockedRect(for: a)
        catalogSource.publishesAX = false
        await catalog.refreshAndWait(reason: .windowEvent)

        coordinator.perform(plan)
        // 句柄取不到会先花完约 2s 的复核预算才拒绝：等待窗口要盖住预算本身。
        await pendingUntil(timeout: 6) { !self.failureReasons().isEmpty }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty)
        let last = try XCTUnwrap(stepEvents().last)
        XCTAssertFalse(last.outcome.allowsContinue)
        XCTAssertEqual(writer.totalWrites, 0,
                       "句柄不可用时一个字节都不许写：写错窗口比不写更糟")
        XCTAssertTrue(failureReasons().contains { $0.contains("句柄") },
                      "原因必须说清是句柄问题：\(failureReasons())")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(aFrame, aDocked, "句柄丢失不该动到 A 的几何")
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1))
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey, b.journalKey]),
                       "补偿做不了就如实留账，交给退出恢复路径收尾")
    }

    // MARK: - H07b 句柄缺失只持续几轮：预算内复核要桥过去，不能当窗口事实

    func testHandleMissingForAFewGenerationsIsBridged() async throws {
        let plan = try await beginHappyPath()
        // 制造"目录已换代但整轮句柄读不到"的坏采样（复现实机捕捉权限成串短暂被拒）。
        catalogSource.publishesAX = false
        await catalog.refreshAndWait(reason: .windowEvent)
        XCTAssertNil(catalog.axEntry(for: try XCTUnwrap(catalog.record(for: b))),
                     "前置事实：这一代句柄读不到")

        // 之后连续三轮仍有坏样本，第四轮恢复：复核循环必须跨过多轮坏采样。
        catalogSource.publishesAX = true
        catalogSource.axUnavailableRounds = 3

        coordinator.perform(plan)
        await pendingUntil(timeout: 8) { self.committedTokens().contains(plan.intent.token) }

        XCTAssertTrue(failureReasons().isEmpty,
                      "坏采样只持续几轮，交换不该被拒绝：\(failureReasons())")
        XCTAssertEqual(writer.recordedActions.filter { $0 == "写" }.count, 2)
        XCTAssertEqual(catalog.record(for: b)?.confidence.allowsAXWrite, true,
                       "桥过去之后目录必须已经回到唯一身份")
    }

    // MARK: - H10 应用约束返回：记事实、继续、不覆盖预览栏

    func testConstrainedReadBackIsRecordedAndSwitchContinues() async throws {
        let plan = try await beginHappyPath()
        writer.setScript(.constrains, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil { self.committedTokens().contains(plan.intent.token) }

        XCTAssertTrue(failureReasons().isEmpty, "应用按自身约束返回不是失败：\(failureReasons())")
        let move = try XCTUnwrap(stepEvents().first { $0.step == .moveToMain })
        guard case let .constrained(readBack, note) = move.outcome else {
            return XCTFail("约束必须如实记成 constrained，实际 \(move.outcome)")
        }
        XCTAssertEqual(readBack, plan.mainTargetFrame.offsetBy(dx: 30, dy: 30), "读回是事实：偏差要记下来")
        XCTAssertTrue(note.contains("约束"))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(bFrame, readBack, "真实窗口停在应用允许的尺寸上")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(aFrame, FakeCatalogSource.frame(for: 0), "原主写回不受约束影响")
        XCTAssertFalse(fixture.layout.mainRect.intersects(fixture.layout.topRailRect),
                       "主区矩形不许与顶栏重叠：应用返回的尺寸只能落在自己的区域里")
        XCTAssertFalse(fixture.layout.mainRect.intersects(fixture.layout.sideRailRect),
                       "主区矩形不许与侧栏重叠")
    }

    // MARK: - H14 意图没落盘：写前拒绝，零写入

    func testMissingJournalEntryRejectsBeforeAnyWrite() async throws {
        let plan = try await beginHappyPath(seedBJournal: false)

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertEqual(writer.totalWrites, 0, "意图没落盘就动 AX，强退之后没人能把它放回去")
        XCTAssertTrue(failureReasons().contains { $0.contains("落盘") },
                      "原因必须指向日志问题：\(failureReasons())")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare], "准备阶段就该拦住，不该走到写入")
        XCTAssertNil(store.entry(for: b), "B 本来就没有记录，也不该被这次失败补出记录")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "准备阶段一个窗口都没动：A 的事务原样留给退出恢复路径（方案 §8.3）")
    }

    // MARK: - H13 对话框阻塞：挂着 Sheet 的窗口不许被写

    func testModalSheetOnCurrentMainBlocksSwitchAndNeverWrites() async throws {
        let plan = try await beginHappyPath()
        catalogSource.setSheet(true, for: a)

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "对话框还挂着，交换不许宣布完成")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare], "准备阶段就该拦住，不许走到写入")
        XCTAssertEqual(writer.totalWrites, 0, "有对话框的窗口一个字节都不许写（方案 §8.2.4）")
        XCTAssertTrue(failureReasons().contains { $0.contains("请先处理当前对话框") },
                      "原因必须指向对话框：\(failureReasons())")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(aFrame, dockedRect(for: a), "被拦住的交换不许动主区窗口")
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "B 留在原格")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "A 仍是主窗口：事务保留，退出时还要还原它的原几何")
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey, b.journalKey]),
                       "一个窗口都没动过：两边的事务按原样留给恢复路径收尾")
    }

    // MARK: - H13 进入路径：目标挂着 Sheet 时不进 L 型

    func testEnteringWorkbenchWithSheetOnTargetIsRefusedWithoutWrites() async throws {
        await startWorkbench(minimized: [])
        store = makeStore()
        store.apply(workbenchTransaction(a, planned: dockedRect(for: a)))
        if let element = catalogSource.element(for: a) {
            writer.setInitialFrame(FakeCatalogSource.frame(for: 0), for: element)
        }
        startRecovery()
        try startCoordinator()
        catalogSource.setSheet(true, for: a)

        let token = TransitionToken(generation: 9)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           identity: a,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: dockedRect(for: a),
                                           animationFrom: nil,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation)
        coordinator.perform(plan)
        await pendingUntil { self.events.contains { event in
            if case .workbenchTransitionFinished = event { return true }
            return false
        } }
        await pendingUntil { !self.coordinator.isBusy }

        let result = events.compactMap { event -> WorkbenchStepOutcome? in
            if case let .workbenchTransitionFinished(_, kind, result) = event, kind == .enteringWorkbench {
                return result
            }
            return nil
        }.first
        guard case let .rejected(reason)? = result else {
            return XCTFail("挂着对话框的窗口必须被拒绝进入，实际：\(String(describing: result))")
        }
        XCTAssertTrue(reason.contains("请先处理当前对话框"), "原因必须指向对话框：\(reason)")
        XCTAssertEqual(writer.totalWrites, 0, "拒绝发生在写入之前：一个字节都不许写（方案 §8.2.4）")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(aFrame, FakeCatalogSource.frame(for: 0), "被拒绝的进入不许动窗口几何")
        XCTAssertTrue(store.unfinished.isEmpty, "窗口没动过，事务按事实结清，退出时不做无谓恢复")
    }

    // MARK: - H23 目录快照滞后一整轮：写前实读把猜测的原位置纠回，返回必须真的写回

    /// 快速往返里目录快照可能落后一整轮（run9 冻结的根因）：
    /// 事务创建时 A 的"原位置"取的是上一轮主区位置（目录还停在那里），真实设备位置是停靠位置。
    /// 写前实读必须把猜测的原位置纠回真实值——否则返回时"已在原位置"直接跳过写入，
    /// 窗口被永久留在主区。断言全部落在设备事实与事务日志上。
    func testStaleCatalogSnapshotIsCorrectedBeforeFirstWrite() async throws {
        await startWorkbench(minimized: [])
        store = makeStore()
        let rest = FakeCatalogSource.frame(for: 0)
        let main = dockedRect(for: a)
        let axA = try element(of: a)
        writer.setInitialFrame(rest, for: axA)

        // 目录落后一整轮：还停在上一轮写进主区的位置；设备真实位置仍是 rest。
        catalogSource.setPublishedFrame(main, for: a)
        await catalog.refreshAndWait(reason: .windowEvent)
        XCTAssertEqual(catalog.record(for: a)?.frame, main,
                       "前置事实：目录快照停在上一轮的主区位置")

        // 与 reducer `ensureTransaction` 同构：原位置取目录快照，是猜测值。
        store.apply(WindowTransaction(sessionID: sessionID,
                                      identity: a,
                                      bundleID: "com.test.app\(a.windowID)",
                                      originalFrame: main,
                                      originalDisplayID: displayID)
            .markingPlanned(frame: main, displayID: displayID))
        startRecovery()
        try startCoordinator()

        let enter = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                            token: TransitionToken(generation: 9),
                                            identity: a,
                                            displayID: displayID,
                                            snapshot: fixture.snapshot,
                                            targetFrame: main,
                                            animationFrom: nil,
                                            animationTo: fixture.layout.mainRect,
                                            railHandoffs: [],
                                            animationMS: 240,
                                            presentation: fixture.presentation)
        coordinator.perform(enter)
        await pendingUntil { self.events.contains { event in
            if case let .workbenchTransitionFinished(_, kind, _) = event, kind == .enteringWorkbench { return true }
            return false
        } }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(writer.writtenFrames, [main], "进入只写一次几何")
        XCTAssertEqual(store.entry(for: a)?.originalFrame, rest,
                       "写前实读必须把猜测的原位置纠回真实停靠位置（目录快照曾停在本轮主区）")
        // 与 reducer `recordObservedWrite` 同构：写成功后事务进入已验证态。
        if let verified = store.entry(for: a)?.markingVerified(readBack: main, displayID: displayID) {
            store.apply(verified)
        }

        let back = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: TransitionToken(generation: 10),
                                           identity: a,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: rest,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: nil,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation)
        coordinator.perform(back)
        await pendingUntil { self.events.contains { event in
            if case let .workbenchTransitionFinished(_, kind, _) = event, kind == .returningOverview { return true }
            return false
        } }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(writer.writtenFrames, [main, rest],
                       "返回必须真的把窗口写回停靠位置：不纠原位置时这一步会因『已在原位置』被跳过")
        let finalFrame = try await currentFrame(of: a)
        XCTAssertEqual(finalFrame, rest, "设备上的最终几何 = 真实原位置")
    }

    // MARK: - H06/H19 在途卡住与取消：迟到的回调不许改变任何东西

    func testCancelDuringGatedWriteStopsTheSwitchAndLateCallbacksChangeNothing() async throws {
        _ = try await beginHappyPath()
        writer.gatesNextWrite = true
        let first = try switchPlan(token: TransitionToken(generation: 1))

        coordinator.perform(first)
        await pendingUntil { self.writer.isBlockedInWrite }
        XCTAssertTrue(coordinator.isBusy, "写入在途时交换必须标为在途")

        // AX 卡住期间主 Actor 不被阻塞：心跳仍在推进（方案 §20 主线程零同步等待）。
        var ticks = 0
        heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks += 1
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        await pendingUntil(timeout: 2) { ticks > 20 }
        heartbeat?.cancel()
        heartbeat = nil
        XCTAssertTrue(ticks > 20, "AX 卡住时主 Actor 必须还能干别的（心跳 \(ticks) 次）")

        let eventsBeforeCancel = events.count
        XCTAssertEqual(eventsBeforeCancel, 1, "取消前只有 prepare 一步的回报")
        XCTAssertEqual(stepEvents().first?.step, .prepare)

        coordinator.cancel()
        XCTAssertFalse(coordinator.isBusy, "取消后不再有在途交换")
        writer.openGate()
        await pendingUntil(timeout: 2) { self.writer.totalWrites >= 1 && !self.writer.isBlockedInWrite }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(writer.writtenFrames, [first.mainTargetFrame],
                       "取消之后不允许再出现新的写入")
        XCTAssertEqual(events.count, eventsBeforeCancel,
                       "令牌作废后迟到的步骤结果不许再进状态机：\(events.suffix(4))")

        // 旧令牌的余波不影响之后的交换：新计划照常走完并提交。
        let second = try switchPlan(token: TransitionToken(generation: 2))
        coordinator.perform(second)
        await pendingUntil(timeout: 4) { self.committedTokens().contains(second.intent.token) }
        XCTAssertEqual(committedTokens(), [second.intent.token])
        XCTAssertEqual(writer.writtenFrames,
                       [first.mainTargetFrame, second.mainTargetFrame, FakeCatalogSource.frame(for: 0)])
    }

    // MARK: - H19 超时：到点先报，再按逆序补偿一次

    func testStalledWriteTimesOutAndRollsBackExactlyOnce() async throws {
        let plan = try await beginHappyPath()
        writer.gatesNextWrite = true

        coordinator.perform(plan)
        await pendingUntil { self.writer.isBlockedInWrite }

        await pendingUntil(timeout: 6) { self.coordinator.didReachDeadline }
        XCTAssertTrue(writer.isBlockedInWrite, "这一次写入仍然卡着：超时必须能在写不进去时到点")
        XCTAssertTrue(events.contains { if case .transitionTimedOut = $0 { return true }; return false },
                      "超时必须先推出在途态：\(events)")
        XCTAssertTrue(statuses.contains { $0.contains("超时") }, "超时要有能显示给用户的说法：\(statuses)")
        XCTAssertTrue(committedTokens().isEmpty)

        writer.openGate()
        await pendingUntil(timeout: 4) { !self.failureReasons().isEmpty }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        XCTAssertEqual(writer.writtenFrames,
                       [plan.mainTargetFrame, FakeCatalogSource.frame(for: 1)],
                       "超时只补这一次真正动过的 B，且只补一次；A 没被动过就不许写")
        XCTAssertTrue(failureReasons().contains { $0.contains("未收敛") },
                      "失败原因必须写明是超时收敛问题：\(failureReasons())")
        XCTAssertTrue(committedTokens().isEmpty)
        let aFrame = await writer.currentFrame(of: try element(of: a))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(aFrame, dockedRect(for: a), "超时回滚后 A 保持主窗口（方案 §8.3）")
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1))
    }

    // MARK: - H20 连点：只有最新意图提交，队列有界

    func testRapidRetargetsConvergeToNewestIntentOnly() async throws {
        _ = try await beginHappyPath()
        var plans: [WorkbenchSwitchPlan] = []
        for index in 0..<20 {
            plans.append(try switchPlan(token: TransitionToken(generation: UInt64(index + 1))))
        }
        let newest = try XCTUnwrap(plans.last).intent.token
        // reducer 的 latest-wins：旧令牌在中途作废（aborted），既不算失败也不补偿。
        coordinator.directive = { token in token == newest ? .proceed : .aborted }

        for plan in plans { coordinator.perform(plan) }
        await pendingUntil(timeout: 8) { self.committedTokens().contains(newest) }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        XCTAssertEqual(committedTokens(), [newest], "只有最后一次意图允许提交")
        XCTAssertTrue(failureReasons().isEmpty, "被作废的旧意图不是失败：\(failureReasons())")
        XCTAssertEqual(stepEvents().filter { $0.step == .commit }.count, 1)
        XCTAssertEqual(writer.writtenFrames,
                       [try XCTUnwrap(plans.last).mainTargetFrame, FakeCatalogSource.frame(for: 0)],
                       "20 次连点只允许最新一次真的写窗口：写多了就是队列失控")
        XCTAssertFalse(coordinator.isBusy)
    }

    // MARK: - 辅助

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
            .appendingPathComponent("VistileWorkbenchTests-\(UUID().uuidString)", isDirectory: true)
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
