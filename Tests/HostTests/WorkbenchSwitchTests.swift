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
    private lazy var scheduler = HostScheduler.make(sessionID: sessionID)
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
        // 只读过的日志目录删不掉：先恢复权限再清临时目录（方案 §7 的故障注入不能留下垃圾）。
        makeJournalWritable()
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
    ///
    /// `armBatch` 决定这次交换的写前事务是否原子落盘（H14 用的就是"没落盘"那一档）：
    /// 宿主 prepare 步骤核对的唯一判据就是这个事实（方案 §7.1、§7.2）。
    @discardableResult
    private func beginHappyPath(minimized: [Int] = [],
                                armBatch: Bool = true,
                                bFrame: CGRect? = nil) async throws -> WorkbenchSwitchPlan {
        await startWorkbench(minimized: minimized)
        store = makeStore()
        let aFrame = dockedRect(for: a)
        await store.apply(workbenchTransaction(a, planned: aFrame)
            .markingWritten(readBack: aFrame, displayID: displayID))
        if let element = catalogSource.element(for: a) { writer.setInitialFrame(aFrame, for: element) }
        if let element = catalogSource.element(for: b) {
            // 默认让 B 的真实几何就是目录里那格；A25 需要"固定尺寸但放不下"，用它覆盖写前实读。
            writer.setInitialFrame(bFrame ?? FakeCatalogSource.frame(for: 1), for: element)
        }
        startRecovery()
        try startCoordinator()
        return try await switchPlan(arm: armBatch)
    }

    /// 与 reducer `arm` + AppCoordinator `.prepareJournal` 同构：把这次交换的写前事务整体落盘。
    /// 事务必须带本次操作的 operationID——那是宿主放行写入的凭据（方案 §7.1、§7.5）。
    private func armJournal(_ plan: WorkbenchSwitchPlan) async {
        let context = plan.intent.operationContext
        var mutations: [JournalMutation] = []
        var affected: [WindowIdentity] = []
        let targets: [(identity: WindowIdentity?, planned: CGRect?)] = [
            (plan.intent.to, plan.mainTargetFrame),
            (plan.intent.from, plan.restingTargetFrame),
        ]
        for target in targets {
            guard let identity = target.identity, let planned = target.planned,
                  let element = catalogSource.element(for: identity),
                  let before = await writer.currentFrame(of: element) else { continue }
            // 已有记录就保留它的原位置，只更新计划与操作前快照：和 `preparedTransaction` 同一条规则。
            let base = store.entry(for: identity) ?? workbenchTransaction(identity, planned: planned)
            affected.append(identity)
            mutations.append(.upsert(base.markingPlanned(frame: planned, displayID: displayID)
                .markingOperationBefore(frame: before, displayID: displayID, operationID: context.operationID)))
        }
        let written = await store.prepare(JournalPrepareRequest(context: context,
                                                               mutations: mutations,
                                                               affectedIdentities: affected))
        XCTAssertTrue(written.isPersisted, "写前事务必须整体落盘：\(written.reason ?? "未知原因")")
    }

    /// 模式过渡的写前事务：同一份凭据，只是要核对的身份只有主窗口一个。
    private func armJournal(_ plan: WorkbenchTransitionPlan) async {
        let context = plan.operationContext
        let element = catalogSource.element(for: plan.identity)
        guard let element, let before = await writer.currentFrame(of: element) else { return }
        let base = store.entry(for: plan.identity) ?? workbenchTransaction(plan.identity, planned: plan.targetFrame)
        let written = await store.prepare(JournalPrepareRequest(
            context: context,
            mutations: [.upsert(base.markingPlanned(frame: plan.targetFrame, displayID: displayID)
                .markingOperationBefore(frame: before, displayID: displayID, operationID: context.operationID))],
            affectedIdentities: [plan.identity]))
        XCTAssertTrue(written.isPersisted, "写前事务必须整体落盘：\(written.reason ?? "未知原因")")
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
                                       processIdentity: processIdentity,
                                       scheduler: scheduler)
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
                                     permissions: permissions,
                                     scheduler: scheduler)
        coordinator = WorkbenchSwitchCoordinator(catalog: catalog,
                                                 writer: writer,
                                                 store: store,
                                                 recovery: recovery,
                                                 focus: focus,
                                                 permissions: permissions,
                                                 metrics: .shared,
                                                 recorder: recorder,
                                                 scheduler: scheduler)
        coordinator.onEvent = { [weak self] event in self?.events.append(event) }
        coordinator.onStatus = { [weak self] status in self?.statuses.append(status) }
        coordinator.directive = { _ in .proceed }
    }

    /// reducer 算好的交换计划：B 进主区、A 回原几何（与 `startSwitch` 的输出同构）。
    ///
    /// 操作前快照取写入器的实时几何（方案 §6.2）：补偿目标必须是"取消那一刻窗口真的在哪儿"，
    /// 不能是测试另抄一份坐标。
    /// 与 reducer `startSwitch` 同构：计划里的操作上下文、操作前快照都要真的落盘一次，
    /// 因为宿主放行写入核对的就是这个凭据（方案 §7.1、§7.2）。`arm: false` 留给 H14 的"批次没落盘"那一档。
    private func switchPlan(token: TransitionToken = TransitionToken(generation: 1),
                            arm: Bool = true) async throws -> WorkbenchSwitchPlan {
        let slot = try XCTUnwrap(fixture.placement.slot(of: b), "B 必须占着轨道上的一个 slot")
        let context = scheduler.makeContext(token: token, kind: .mainSwitch)
        var preOperation: [(identity: WindowIdentity, frame: CGRect)] = []
        for identity in [b, a] {
            guard let element = catalogSource.element(for: identity),
                  let frame = await writer.currentFrame(of: element) else { continue }
            preOperation.append((identity: identity, frame: frame))
        }
        let intent = WorkbenchSwitchIntent(token: token,
                                           from: a,
                                           to: b,
                                           source: .rail(slot: slot),
                                           placementRevision: fixture.placement.revision,
                                           targetDisplayID: displayID,
                                           operationContext: context,
                                           beforeOperation: HostPlanFacts.operationSnapshot(context: context,
                                                                                           preOperation))
        let mainTarget = dockedRect(for: b)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                        displayID: displayID,
                                        mainTargetFrame: mainTarget,
                                        restingTargetFrame: FakeCatalogSource.frame(for: 0),
                                        restingSlot: slot,
                                        snapshot: fixture.snapshot,
                                        presentation: fixture.presentation,
                                        placement: HostPlanFacts.placement(target: mainTarget))
        if arm { await armJournal(plan) }
        return plan
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
        events.compactMap { if case let .mainSwitchFailed(_, reason, _) = $0 { return reason } else { return nil } }
    }

    /// 失败事件里附带的补偿事实：逐窗口的回位结局与被重新前景化的那个窗口。
    private func compensationResults() -> [WorkbenchCompensationResult] {
        events.compactMap {
            if case let .mainSwitchFailed(_, _, compensation) = $0 { return compensation } else { return nil }
        }
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
        writer.setWriteability(.writeable, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil { !self.committedTokens().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(committedTokens(), [plan.intent.token],
                       "窗口实测可写：坏采样不许把这个交换拦下来")
        XCTAssertEqual(writer.writtenFrames, [plan.mainTargetFrame, FakeCatalogSource.frame(for: 0)])
    }

    /// A24（方案 §9.1、§18）：确凿不接受尺寸、但真实尺寸放得进主区——只写位置，尺寸保持实读值。
    func testFixedSizedWindowToFitIsMovedWithoutAnySizeWrite() async throws {
        let plan = try await beginHappyPath()
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .reconcile)
        writer.setWriteability(.sizeNotSettable, for: try element(of: b))
        // 期望目标由生产同一条策略算出，测试不手抄坐标（方案 §9.1）。
        let moveOnly = try XCTUnwrap(MainPlacementPolicy.decide(mainRect: fixture.layout.mainRect,
                                                                currentFrame: FakeCatalogSource.frame(for: 1),
                                                                isMovable: true,
                                                                isResizable: false).targetFrame)

        coordinator.perform(plan)
        await pendingUntil { !self.committedTokens().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(committedTokens(), [plan.intent.token], "仅移动路径也是合格落位：交换要能提交")
        XCTAssertGreaterThanOrEqual(writer.writeabilityProbeCount, 1,
                                    "固定尺寸窗口仍必须做一次可写性探测：这决定 move-only 还是拒绝")
        XCTAssertEqual(writer.writtenFrames, [moveOnly, FakeCatalogSource.frame(for: 0)])
        XCTAssertEqual(writer.recordedActions.first, "移", "B 这一步只许写位置：\(writer.recordedActions)")
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(bFrame?.size, FakeCatalogSource.frame(for: 1).size,
                       "「保留原尺寸」必须是真实尺寸，不许是裁小后的说辞")
        XCTAssertTrue(fixture.layout.mainRect.contains(bFrame ?? .zero), "仅移动落位必须完全在主区内")
    }

    /// A25（方案 §9.1、§18）：确凿不接受尺寸且真实尺寸放不下主区——明确拒绝，一个字节都不写。
    func testConfirmedUnsizableWindowIsRefusedWithoutWrites() async throws {
        // 整屏大小必然放不进 L 型的主区（主区是可见区的一部分）：固定尺寸的窗口只能不进主区（方案 §9.1）。
        let tooLarge = CGRect(origin: FakeCatalogSource.frame(for: 1).origin, size: HostFixtures.offscreenSize)
        let plan = try await beginHappyPath(bFrame: tooLarge)
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .reconcile)
        writer.setWriteability(.sizeNotSettable, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "窗口放不下，交换不许宣布完成")
        XCTAssertTrue(failureReasons().contains { $0.contains("大于主区") },
                      "拒绝原因必须来自实测的尺寸事实：\(failureReasons())")
        XCTAssertEqual(writer.totalWrites, 0, "放不下就不该发起任何写入")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain])
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(bFrame, tooLarge, "B 留在原格")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(aFrame, dockedRect(for: a), "拒绝发生在写 B 之前：A 保持主窗口")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "A 仍是主窗口：事务保留，退出时还要还原它的原几何（方案 §6.4、A12）")
        XCTAssertNil(store.entry(for: b), "B 一个字节都没被写过：这次计划没有恢复依据（方案 §7.2、A42）")
    }

    /// 可写性都读不到时，不能替产品下"不可写"的结论：交给写入自身的读回判定。
    func testUnreadableWriteabilityFallsThroughToTheWriteItself() async throws {
        let plan = try await beginHappyPath()
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .reconcile)
        writer.setWriteability(.unreadable, for: try element(of: b))
        // 读不到可写性时，可移动性只能按目录最新采样保守处理：那次采样说不可调尺寸，
        // 于是走仅移动路径——这仍是"写入自己说话"，不是替窗口下结论（方案 §9.1）。
        let moveOnly = try XCTUnwrap(MainPlacementPolicy.decide(mainRect: fixture.layout.mainRect,
                                                                currentFrame: FakeCatalogSource.frame(for: 1),
                                                                isMovable: true,
                                                                isResizable: false).targetFrame)

        coordinator.perform(plan)
        await pendingUntil { !self.committedTokens().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(committedTokens(), [plan.intent.token],
                       "读不到不是事实：写入能读回一致就按成功走")
        XCTAssertEqual(writer.writtenFrames, [moveOnly, FakeCatalogSource.frame(for: 0)])
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
        // 写入被应用拒绝 = 窗口根本没动：补偿对着读回核一次「已在原位」，不再重复同一次失败写入。
        // 因此真实序列是三次：B 进主区、A 写回（被拒）、B 补偿回原几何。
        XCTAssertEqual(writer.writtenFrames,
                       [plan.mainTargetFrame, FakeCatalogSource.frame(for: 0),
                        FakeCatalogSource.frame(for: 1)],
                       "补偿只补真的动过的那个：A 被拒后仍在主区，不该再写它一次")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(aFrame, dockedRect(for: a), "写不回去的窗口保持现状，不能被假装移动")
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "回滚必须把 B 送回原几何")
        XCTAssertEqual(store.entry(for: a)?.state, .failed, "写不回去的事务必须留可重试记录")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true)
        XCTAssertEqual(store.entry(for: a)?.lastProvisionalFrame, dockedRect(for: a),
                       "失败事务记的是读回到的真实几何，不是计划值（方案 §6.1、§6.4）")
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey, b.journalKey]),
                       "两个窗口都被真的写过：补偿只是回到操作前位置，会话恢复义务要留到退出（方案 §6.4、A12、A42）")
    }

    // MARK: - A08/A09/A11 前景化失败与补偿失败（方案 §8.4、§6.4、§18）

    /// A08（方案 §18）：B 已进主区，但前景化被**确凿证明**没到前面——B 必须回到操作前位置，A 保持主区。
    ///
    /// 判据不是"返回值是 false"：焦点读回被同应用兄弟窗口占住才是外部事实（§12.2 只承认相反证据）。
    func testActivationFailureAfterMovingToMainRestoresTargetAndKeepsPreviousMain() async throws {
        let plan = try await beginHappyPath()
        let bElement = try element(of: b)
        writer.setSiblingHoldingFocus(true, for: bElement)

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "前景没到位就不许提交：\(committedTokens())")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain, .activateMain],
                       "失败必须落在前景确认这一步（方案 §8.2）")
        XCTAssertFalse(try XCTUnwrap(stepEvents().last).outcome.allowsContinue)
        // B 被写过一次（进主区），补偿把它送回操作前实读位置；A 从没被这次操作碰过，所以不该再写它。
        XCTAssertEqual(writer.writtenFrames, [plan.mainTargetFrame, FakeCatalogSource.frame(for: 1)],
                       "只许回滚真的动过的窗口：A 该保持在主区，不该被再写一次")
        let aFrame = try await currentFrame(of: a)
        XCTAssertEqual(aFrame, dockedRect(for: a), "A 必须还在主区，回滚不能把它挤出主区")
        let bFrame = try await currentFrame(of: b)
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "B 要回到操作前的真实位置")
        // 补偿不只有几何：B 刚被移出主区，主区那一格必须真的重新拿到前台，否则用户面对不可输入的主区（方案 §6.3）。
        XCTAssertGreaterThanOrEqual(writer.focusCallCount(for: try element(of: a)), 1,
                                    "回滚后要把原主重新前景化")
        XCTAssertEqual(try XCTUnwrap(compensationResults().last?.activatedMain), a,
                       "补偿回报要如实写明是哪个窗口被带回前台")
        XCTAssertEqual(writer.focusCallCount(for: bElement) >= 1, true,
                       "前景判据来自真实的前景化调用，不是状态机自己写的")
        XCTAssertFalse(failureReasons().isEmpty)
    }

    /// A09（方案 §18）：A 已经被写回轨道之后，B 的前景复核才失败——两侧都要回操作前，并把 A 重新提到前面。
    func testForegroundRecheckFailureAfterPreviousMainLeftsRollsBothBackAndReactivatesMain() async throws {
        let plan = try await beginHappyPath()
        let bElement = try element(of: b)
        // 第 1 次前景化（进主区后的确认）成功，第 2 次（A 回轨后的复核）才被兄弟窗口挡住。
        writer.setSiblingHoldingFocus(true, for: bElement, fromCall: 2)

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "复核失败还提交，就是把输入交给缓存画面：\(committedTokens())")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain, .activateMain, .restorePrevious],
                       "失败落在写回原主之后的前景复核（方案 §8.2 第 6 步）")
        XCTAssertEqual(writer.focusCallCount(for: bElement) >= 2, true,
                       "写回 A 之后必须再复核一次 B 的前景，不论 A 是不是同应用")
        let bFrame = try await currentFrame(of: b)
        let aFrame = try await currentFrame(of: a)
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "B 补偿回操作前实读位置")
        XCTAssertEqual(aFrame, dockedRect(for: a),
                       "A 已经离开过主区：补偿必须把它写回主区那一份操作前几何（方案 §8.4）")
        XCTAssertGreaterThanOrEqual(writer.focusCallCount(for: try element(of: a)), 1,
                                    "回滚后必须把原主重新前景化，否则用户面对的是一个不可输入的主区")
        XCTAssertEqual(writer.writtenFrames,
                       [plan.mainTargetFrame, FakeCatalogSource.frame(for: 0),
                        dockedRect(for: a), FakeCatalogSource.frame(for: 1)],
                       "写入序列如实可核对：B 进主区 → A 回轨 → 逆序补偿（A 先回主区，B 再回原几何，方案 §6.3、§6.4）")
    }

    /// A11（方案 §18、§6.4）：复核失败后补偿也失败——事务必须留在日志里，绝不提交、绝不宣称已到位。
    func testCompensationFailureKeepsJournalAndNeverCommits() async throws {
        let plan = try await beginHappyPath()
        let bElement = try element(of: b)
        let aTarget = try element(of: a)
        writer.setSiblingHoldingFocus(true, for: bElement, fromCall: 2)
        // 脚本在写入回调里换，生效于"下一次"写入：第 2 次（A 回轨）照常成功，
        // 从第 3 次（A 的补偿）起被拒，正好制造"补偿写不回去"。
        writer.onWillWrite = { [weak writer] _ in
            guard let writer else { return }
            if writer.totalWrites >= 2 { writer.setScript(.rejects, for: aTarget) }
        }

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }
        writer.onWillWrite = nil

        XCTAssertTrue(committedTokens().isEmpty, "补偿没到位就不许宣称交换成功：\(committedTokens())")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain, .activateMain, .restorePrevious])
        let aFrame = try await currentFrame(of: a)
        XCTAssertEqual(aFrame, FakeCatalogSource.frame(for: 0),
                       "补偿被拒时窗口停在它真实所在的地方，不许假装回到了主区")
        let bFrame = try await currentFrame(of: b)
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1),
                       "另一个窗口的补偿照旧完成")
        let items = try XCTUnwrap(compensationResults().last).items
        XCTAssertEqual(items.count, 2, "两个动过的窗口都要如实回报补偿结果：\(items)")
        guard let aItem = items.first(where: { $0.identity == a }) else {
            return XCTFail("补偿清单里必须含 A：\(items)")
        }
        guard case .refused = aItem.action else {
            return XCTFail("补偿失败要如实记成拒绝，不能记成已恢复：\(aItem.action)")
        }
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "补偿失败的窗口必须留下恢复义务，等退出或重试（方案 §6.4）")
        XCTAssertTrue(store.unfinished.map(\.journalKey).contains(a.journalKey),
                      "日志不能把还欠着恢复的窗口抹掉：\(store.unfinished.map(\.journalKey))")
        XCTAssertFalse(failureReasons().isEmpty, "补偿失败要如实回报：\(failureReasons())")
    }

    // MARK: - A13–A18 日志落盘故障族（方案 §7.2、§7.3、§7.5）

    /// 让日志目录只读：之后每一次落盘都必然失败，内存快照必须退回上一份提交内容。
    private func makeJournalUnwritable() {
        let root = journalDirectory.appendingPathComponent("Vistile")
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
            readOnlyJournalRoots.append(root)
        } catch {
            XCTFail("无法把日志目录改成只读：\(error)")
        }
    }

    private var readOnlyJournalRoots: [URL] = []

    /// 恢复可写：既让断言读得到磁盘，也让 tearDown 能删掉这份临时目录。
    private func makeJournalWritable() {
        for root in readOnlyJournalRoots {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
        readOnlyJournalRoots = []
    }

    /// A13（方案 §7.5）：写前事务没落盘时一次 AX 写入都不许发生；落好之后同一套流程要能重新进入。
    func testJournalPrepareFailureBlocksWritesAndRetryProceeds() async throws {
        let plan = try await beginHappyPath(armBatch: false)

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertEqual(writer.totalWrites, 0, "没有可恢复的事务记录就改窗口，等于把窗口交给运气（方案 §7.2）")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare], "失败必须停在 prepare，一步写入都不往后走")
        XCTAssertFalse(try XCTUnwrap(stepEvents().last).outcome.allowsContinue)
        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertFalse(coordinator.isBusy, "prepare 失败后忙判据必须清干净，用户还能再选一次")
        let bFrame = try await currentFrame(of: b)
        let aFrame = try await currentFrame(of: a)
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "B 一格都没动")
        XCTAssertEqual(aFrame, dockedRect(for: a), "A 保持主区")

        // 重试：这一次按 reducer 同构把整批事务落盘，交换必须能真正走完。
        // 第一次的失败理由要留着对账——事件清单是累计的，重试的判据是"不再新增失败"。
        let firstAttemptFailures = failureReasons()
        let retry = try await switchPlan(token: TransitionToken(generation: 2))
        coordinator.perform(retry)
        await pendingUntil { self.committedTokens().contains(retry.intent.token) }

        XCTAssertEqual(committedTokens(), [retry.intent.token])
        XCTAssertEqual(failureReasons(), firstAttemptFailures,
                       "重试路径不该再出现失败：\(failureReasons().dropFirst(firstAttemptFailures.count))")
        XCTAssertFalse(writer.writtenFrames.isEmpty, "重试成功后必须真的写了窗口")
        let retriedBFrame = try await currentFrame(of: b)
        let retriedAFrame = try await currentFrame(of: a)
        XCTAssertEqual(retriedBFrame, dockedRect(for: b), "重试后 B 真的进了主区")
        XCTAssertEqual(retriedAFrame, FakeCatalogSource.frame(for: 0), "重试后 A 真的回到停靠位")
        XCTAssertEqual(store.entry(for: b)?.operationID, retry.intent.operationContext.operationID,
                       "重试批次的操作凭据必须真的留在日志里")
        XCTAssertEqual(store.entry(for: b)?.state.requiresRestore, true,
                       "交换成功后 B 仍欠着恢复义务，等退出会话才结算（方案 §6.4）")
        await pendingUntil { !self.coordinator.isBusy }
    }

    /// A14（方案 §7.2）：A/B 批量里第二条失败时整批作废——内存与磁盘都不能留下半套事务。
    func testBatchPrepareIsAtomicWhenSecondMutationFails() async throws {
        store = makeStore()
        let context = scheduler.makeContext(token: TransitionToken(generation: 1), kind: .mainSwitch)
        let ghost = HostFixtures.identity(7)
        let request = JournalPrepareRequest(
            context: context,
            mutations: [.upsert(workbenchTransaction(b, planned: FakeCatalogSource.frame(for: 1))
                .markingOperationBefore(frame: FakeCatalogSource.frame(for: 1),
                                        displayID: displayID,
                                        operationID: context.operationID)),
                        .remove(ghost)],
            affectedIdentities: [b, ghost])

        let written = await store.prepare(request)

        XCTAssertFalse(written.isPersisted, "日志里没有的事务要让整批作废：\(written.reason ?? "无原因")")
        XCTAssertNotNil(written.reason)
        XCTAssertNil(store.entry(for: b), "第一条已经改过内存就是半套交换的开端（方案 §7.2 不变量 2）")
        let onDisk = WindowJournalStore(fileName: "session-journal.json",
                                       sessionID: sessionID,
                                       baseDirectory: journalDirectory).snapshot
        XCTAssertNil(onDisk.entries[b.journalKey], "磁盘上同样不能留下第一条")
        XCTAssertEqual(store.revision, 0, "作废的批次不许推进序号，否则后续守卫会被自己绕过")
    }

    /// A16（方案 §7.3）：写前实读与原位置对不上、而纠正又落不进日志 → 这次写入直接拒绝。
    func testOriginalCorrectionFailureRefusesEveryGeometryWrite() async throws {
        // B 的真实几何比目录快照偏 40pt：事务里的原位置是推测值，首个写入前必须纠正一次。
        let shifted = FakeCatalogSource.frame(for: 1).offsetBy(dx: 40, dy: 40)
        let plan = try await beginHappyPath(bFrame: shifted)
        makeJournalUnwritable()

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }
        makeJournalWritable()

        XCTAssertEqual(writer.totalWrites, 0,
                       "基准不可信还继续写，补偿就没有可回退的事实（方案 §7.3）")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain])
        XCTAssertTrue(try XCTUnwrap(stepEvents().last?.outcome.message).contains("原位置"),
                      "拒绝原因要指到真正失败的那一步：\(stepEvents().map(\.outcome.message))")
        XCTAssertTrue(committedTokens().isEmpty)
        let bFrame = try await currentFrame(of: b)
        let aFrame = try await currentFrame(of: a)
        XCTAssertEqual(bFrame, shifted, "B 保持实读到的位置")
        XCTAssertEqual(aFrame, dockedRect(for: a), "A 与轨道不受影响")
    }

    /// A17（方案 §7.2 末段、§7.3）：真实写入之后 observed 落盘失败 → 停后续步骤，并按写前实读把窗口回位。
    func testObservedFactPersistFailureRollsBackAndStopsBeforeCommit() async throws {
        let plan = try await beginHappyPath()
        // 第一次写 AX 的那一刻把日志目录改成只读：写入本身已经发生，事后再记就晚了。
        writer.onWillWrite = { [weak self] _ in
            guard let self, self.writer.totalWrites == 1 else { return }
            self.makeJournalUnwritable()
        }

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }
        writer.onWillWrite = nil
        makeJournalWritable()

        XCTAssertTrue(committedTokens().isEmpty, "写后事实没落盘却提交，就是宣称了一次无从恢复的交换")
        XCTAssertEqual(stepEvents().map(\.step), [.prepare, .moveToMain],
                       "observed 落不下去必须停在这里，不许继续前景化/写回原主")
        XCTAssertTrue(try XCTUnwrap(stepEvents().last?.outcome.message).contains("写后事实"),
                      "结论要说明失败的是记账这一步：\(stepEvents().map(\.outcome.message))")
        XCTAssertEqual(writer.writtenFrames, [plan.mainTargetFrame, FakeCatalogSource.frame(for: 1)],
                       "只有这一笔真实写入和它自己发起的回位：日志不知道窗口动过，别的窗口一律不许再动")
        let bFrame = try await currentFrame(of: b)
        let aFrame = try await currentFrame(of: a)
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1),
                       "无人记账的位移必须当场按写前实读回位（方案 §7.2：不能按未写入处理）")
        XCTAssertEqual(aFrame, dockedRect(for: a), "A 从没被这次操作碰过")
        XCTAssertTrue(events.contains { event in
            if case let .journalUpdateFailed(_, identity, _) = event { return identity == b }
            return false
        }, "落盘失败要进事件流，状态机据此进入 recoveryRequired（方案 §7.3）")
    }

    /// A18（方案 §7.1、§7.5）：异步准备完成时会话已经换代 → 旧操作一个字节都不许写。
    func testStaleOperationContextStartsNoWrite() async throws {
        let plan = try await beginHappyPath()
        scheduler.adopt(sessionID: UUID(), epoch: scheduler.sessionEpoch + 1)

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }

        XCTAssertEqual(writer.totalWrites, 0, "旧上下文的迟到启动等于往新会话里写旧窗口")
        XCTAssertTrue(stepEvents().isEmpty, "过期操作连 prepare 都不该开始：\(stepEvents().map(\.step))")
        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertFalse(failureReasons().isEmpty)
        let bFrame = try await currentFrame(of: b)
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1), "B 保持原位")
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

    // MARK: - H07c 最小化写入的许可与补偿（方案 §5.2、§6.4）

    /// 解除最小化的命令已经排到队列头、还没执行时取消：放行后必须零执行，
    /// 窗口仍是用户原来的最小化状态（许可要在 AX 队列内部再查一次，MainActor 上的取消传不进去）。
    func testCancelledMinimizeReleaseNeverTouchesTheWindow() async throws {
        let plan = try await beginHappyPath(minimized: [1])
        writer.gatesNextMinimize = true

        coordinator.perform(plan)
        await pendingUntil { self.writer.isBlockedInMinimize }
        XCTAssertTrue(committedTokens().isEmpty, "卡住的这一刻还没提交")

        coordinator.cancel()
        writer.openMinimizeGate()
        await pendingUntil { !self.writer.isBlockedInMinimize }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        XCTAssertEqual(writer.unminimizeAttempts, 0,
                       "许可撤销后队列里那笔写入必须零执行：\(writer.recordedActions)")
        XCTAssertTrue(writer.isMinimized(for: try element(of: b)),
                      "隐藏/取消之后窗口必须还是用户原来的最小化状态")
        XCTAssertFalse(writer.recordedActions.contains("解除最小化"),
                       "迟到的解除最小化会让用户看到一个 Vistile 已经关掉却还展开着的窗口")
        XCTAssertEqual(writer.totalWrites, 0, "取消后一个几何字节也不许写")
        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertFalse(stepEvents().contains { $0.step == .moveToMain },
                       "取消已经把会话所有权交还：迟到的步骤回报不得再改状态机（方案 §5.5）")
    }

    /// 解除最小化已经成功、随后写前事实落盘失败：这条提前返回路径必须把它收回去，
    /// 而不是等几何写入完成才登记副作用（方案 §6.4）。
    func testJournalFailureAfterMinimizeReleaseRestoresMinimizedState() async throws {
        let plan = try await beginHappyPath(minimized: [1])
        makeJournalUnwritable()

        coordinator.perform(plan)
        await pendingUntil(timeout: 4) {
            self.events.contains { if case .journalUpdateFailed = $0 { return true }; return false }
        }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }
        makeJournalWritable()

        XCTAssertEqual(writer.recordedActions.filter { $0 == "解除最小化" }.count, 1, "先解除最小化")
        XCTAssertTrue(writer.recordedActions.contains("最小化"),
                      "解除之后提前返回，必须按原样恢复最小化：\(writer.recordedActions)")
        XCTAssertTrue(writer.isMinimized(for: try element(of: b)),
                      "窗口不能留在 Vistile 已经放弃的展开状态")
        XCTAssertEqual(writer.totalWrites, 0, "日志落盘失败时不许写几何")
        XCTAssertTrue(committedTokens().isEmpty)
    }

    /// 解除最小化成功、几何写入被应用拒绝：补偿除了回位几何，还必须把最小化恢复（方案 §6.4）。
    func testRejectedGeometryAfterMinimizeReleaseRollsMinimizedStateBack() async throws {
        let plan = try await beginHappyPath(minimized: [1])
        writer.setScript(.rejects, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil(timeout: 4) { !self.failureReasons().isEmpty }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        XCTAssertTrue(writer.isMinimized(for: try element(of: b)),
                      "交换失败回滚后窗口必须回到最小化：\(writer.recordedActions)")
        XCTAssertEqual(writer.recordedActions.filter { $0 == "解除最小化" }.count, 1,
                       "只允许为这次操作解除一次最小化")
        XCTAssertTrue(committedTokens().isEmpty)
        // 补偿回执必须带"写前实读"这一权威事实，reducer 才能按它判定回滚成功（方案 §6.4）。
        let compensation = try XCTUnwrap(events.compactMap { event -> WorkbenchCompensationResult? in
            if case let .mainSwitchFailed(_, _, result) = event { return result }
            return nil
        }.last)
        XCTAssertEqual(compensation.beforeReads[b], FakeCatalogSource.frame(for: 1),
                       "写前实读必须随补偿回执回报：\(compensation.beforeReads)")
    }

    // MARK: - H07 途中句柄丢失：一个字节都不写

    func testVanishedHandlesWriteNothingAndKeepOnlyRealObligations() async throws {
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
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey]),
                       "A 真的还在主区：它的会话事务必须留给退出恢复（方案 §6.4、A12）")
        XCTAssertNil(store.entry(for: b),
                     "B 从未被写过：这条计划没有恢复依据，留着就是 A42 说的「未解释恢复义务」（方案 §7.2）")
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

    /// 性能：可调尺寸窗口的放置策略只看"能 resize"，不需要再做一次跨进程可写性探测；
    /// 只有固定尺寸/不可移动窗口才需要（探测结果决定 move-only 还是拒绝）。最终判据仍是写后读回。
    func testResizableSwitchSkipsRedundantWriteabilityProbe() async throws {
        let plan = try await beginHappyPath()
        coordinator.perform(plan)
        await pendingUntil { self.committedTokens().contains(plan.intent.token) }
        XCTAssertTrue(failureReasons().isEmpty, "\(failureReasons())")
        XCTAssertEqual(writer.writeabilityProbeCount, 0,
                       "可调尺寸窗口不该为每笔放置多付一次跨进程能力查询（实机 5–20ms、读超时 0.35s）")
    }

    // MARK: - A22 受限但仍在主区：记事实、提交、不覆盖预览栏（方案 §9.2、§9.3）

    func testConstrainedReadBackInsideMainIsRecordedAndSubmitted() async throws {
        let plan = try await beginHappyPath()
        writer.setScript(.constrainsInside, for: try element(of: b))
        // 应用自己收小的尺寸：目标位置不动、宽高各少 60pt，仍完全落在主区内（由替身如实读回）。
        let constrained = CGRect(x: plan.mainTargetFrame.minX, y: plan.mainTargetFrame.minY,
                                 width: plan.mainTargetFrame.width - 60,
                                 height: plan.mainTargetFrame.height - 60)

        coordinator.perform(plan)
        await pendingUntil { self.committedTokens().contains(plan.intent.token) }

        XCTAssertTrue(failureReasons().isEmpty, "应用按自身约束返回不是失败：\(failureReasons())")
        let move = try XCTUnwrap(stepEvents().first { $0.step == .moveToMain })
        guard case let .constrained(readBack, note) = move.outcome else {
            return XCTFail("约束必须如实记成 constrained，实际 \(move.outcome)")
        }
        XCTAssertEqual(readBack, constrained, "读回是事实：偏差要按真实几何记下来，不是计划值")
        XCTAssertTrue(note.contains("约束"))
        let bFrame = await writer.currentFrame(of: try element(of: b))
        XCTAssertEqual(bFrame, constrained, "真实窗口停在应用允许的尺寸上")
        XCTAssertEqual(store.entry(for: b)?.lastProvisionalFrame, constrained,
                       "事务记的必须是读回到的那块几何，退出恢复据此判断（方案 §6.1）")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(aFrame, FakeCatalogSource.frame(for: 0), "原主写回不受约束影响")
        XCTAssertFalse(fixture.layout.mainRect.intersects(fixture.layout.topRailRect),
                       "主区矩形不许与顶栏重叠：应用返回的尺寸只能落在自己的区域里")
        XCTAssertFalse(fixture.layout.mainRect.intersects(fixture.layout.sideRailRect),
                       "主区矩形不许与侧栏重叠")
    }

    // MARK: - A23 受限且越界：一次有界修正后仍越界就补偿、不提交（方案 §9.2、§9.3）

    func testConstrainedReadBackOutsideMainIsCorrectedOnceAndThenCompensated() async throws {
        let plan = try await beginHappyPath()
        writer.setScript(.constrains, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil { !self.failureReasons().isEmpty }
        await pendingUntil { !self.coordinator.isBusy }

        XCTAssertTrue(committedTokens().isEmpty, "读回越出主区却提交 placement，就是把越界说成落位")
        let move = try XCTUnwrap(stepEvents().first { $0.step == .moveToMain })
        XCTAssertFalse(move.outcome.allowsContinue, "越界读回不能让交换继续：\(move.outcome)")
        XCTAssertTrue(failureReasons().contains { $0.contains("主区") },
                      "失败原因要指明是主区包含性问题：\(failureReasons())")
        // 序列：B 进主区（越界读回）→ 一次有界位置修正（仍越界）→ 补偿把 B 送回原几何。
        XCTAssertEqual(writer.writtenFrames.first, plan.mainTargetFrame)
        XCTAssertEqual(writer.writtenFrames.count, 3, "有界修正只许一次：\(writer.writtenFrames)")
        XCTAssertEqual(writer.writtenFrames.last, FakeCatalogSource.frame(for: 1),
                       "补偿必须把 B 送回它本操作前的几何")
        let bFrame = await writer.currentFrame(of: try element(of: b))
        // 替身声明的是"这个应用每次都自己偏移 30pt"：补偿按目标发出，真实几何只能停在它允许的偏移上。
        // 这条读回与目标不一致就是 §6.4 说的补偿失败：不许当成已恢复。
        XCTAssertEqual(bFrame, FakeCatalogSource.frame(for: 1).offsetBy(dx: 30, dy: 30),
                       "补偿写入后的设备事实要按替身自己的约束如实核对：\(String(describing: bFrame))")
        let aFrame = await writer.currentFrame(of: try element(of: a))
        XCTAssertEqual(aFrame, dockedRect(for: a), "A 从没被这次交换动过，必须仍在主窗口位")
        XCTAssertEqual(store.entry(for: a)?.state.requiresRestore, true,
                       "A 的会话事务要留到最终退出恢复（方案 §6.4、A12）")
        XCTAssertEqual(store.entry(for: b)?.state.requiresRestore, true,
                       "补偿没能把 B 放回原格：恢复义务必须留着，交给退出路径复核（方案 §6.4）")
    }

    // MARK: - H14 意图没落盘：写前拒绝，零写入

    func testMissingJournalEntryRejectsBeforeAnyWrite() async throws {
        let plan = try await beginHappyPath(armBatch: false)

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
        XCTAssertEqual(Set(store.unfinished.map(\.journalKey)), Set([a.journalKey]),
                       "A 真的还在主区：它的会话事务必须留给退出恢复（方案 §6.4、A12）")
        XCTAssertNil(store.entry(for: b),
                     "B 从未被写过：这条计划没有恢复依据，留着就是 A42 说的「未解释恢复义务」（方案 §7.2）")
    }

    // MARK: - H13 进入路径：目标挂着 Sheet 时不进 L 型

    func testEnteringWorkbenchWithSheetOnTargetIsRefusedWithoutWrites() async throws {
        await startWorkbench(minimized: [])
        store = makeStore()
        await store.apply(workbenchTransaction(a, planned: dockedRect(for: a)))
        if let element = catalogSource.element(for: a) {
            writer.setInitialFrame(FakeCatalogSource.frame(for: 0), for: element)
        }
        startRecovery()
        try startCoordinator()
        catalogSource.setSheet(true, for: a)

        let token = TransitionToken(generation: 9)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           operationContext: scheduler.makeContext(token: token, kind: .enterWorkbench),
                                           identity: a,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: dockedRect(for: a),
                                           animationFrom: nil,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: dockedRect(for: a)))
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
        await store.apply(WindowTransaction(sessionID: sessionID,
                                           identity: a,
                                           bundleID: "com.test.app\(a.windowID)",
                                           originalFrame: main,
                                           originalDisplayID: displayID)
            .markingPlanned(frame: main, displayID: displayID))
        startRecovery()
        try startCoordinator()

        let enter = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                            token: TransitionToken(generation: 9),
                                            operationContext: scheduler.makeContext(token: TransitionToken(generation: 9), kind: .enterWorkbench),
                                            identity: a,
                                            displayID: displayID,
                                            snapshot: fixture.snapshot,
                                            targetFrame: main,
                                            animationFrom: nil,
                                            animationTo: fixture.layout.mainRect,
                                            railHandoffs: [],
                                            animationMS: 240,
                                            presentation: fixture.presentation,
                                            placement: HostPlanFacts.placement(target: main))
        await armJournal(enter)
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
            await store.apply(verified)
        }

        let back = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: TransitionToken(generation: 10),
                                           operationContext: scheduler.makeContext(token: TransitionToken(generation: 10), kind: .returnOverview),
                                           identity: a,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: rest,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: nil,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: rest))
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

    // MARK: - H06/H19/A04 在途卡住与取消：迟到的回调不许改变任何东西

    /// A04（方案 §18 A04、§5.5 第 2 条）：AX 命令已排队但还没开始执行时取消，
    /// 底层准入必须拒绝这笔旧命令——用「写入器实际落过的 frame 序列」证明，不是看内部标志。
    func testCancelDuringGatedWriteStopsTheSwitchAndLateCallbacksChangeNothing() async throws {
        _ = try await beginHappyPath()
        writer.gatesNextWrite = true
        let first = try await switchPlan(token: TransitionToken(generation: 1))

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
        // 这扇门锁在"AX 调用还没开始"这一刻（方案 §5.5 第 2 条：命令已排队未开始时退出，
        // 底层许可拒绝该写入）。放行后写入器必须自己查许可并回报未写入。
        writer.openGate()
        await pendingUntil(timeout: 2) { !self.writer.isBlockedInWrite }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(writer.writtenFrames, [],
                       "未开始的写入被撤销的许可挡回：取消后既没有迟到写入，也不许有新写入")
        XCTAssertEqual(events.count, eventsBeforeCancel,
                       "令牌作废后迟到的步骤结果不许再进状态机：\(events.suffix(4))")

        // 旧令牌的余波不影响之后的交换：新计划照常走完并提交。
        let second = try await switchPlan(token: TransitionToken(generation: 2))
        coordinator.perform(second)
        await pendingUntil(timeout: 4) { self.committedTokens().contains(second.intent.token) }
        XCTAssertEqual(committedTokens(), [second.intent.token])
        XCTAssertEqual(writer.writtenFrames,
                       [second.mainTargetFrame, FakeCatalogSource.frame(for: 0)])
    }

    // MARK: - A01 目录复核在途时取消：放行后零普通 AX 写入（方案 §18 A01、§6.1）

    /// 写入方拿不到句柄会进入带截止时间的目录复核循环；这一趟读同样可能无响应。
    /// 取消发生在这期间：放行后既不能把迟到结果提交给状态机，也不能落一笔普通 AX 写入。
    func testCancelDuringCatalogRecheckWritesNothingAndSessionRecovers() async throws {
        _ = try await beginHappyPath()
        let plan = try await switchPlan(token: TransitionToken(generation: 2))
        // 这一代句柄读不到：`axEntry` 为空，交换会走进复核循环（方案 §6.1）。
        catalogSource.publishesAX = false
        await catalog.refreshAndWait(reason: .windowEvent)
        XCTAssertNil(catalog.axEntry(for: try XCTUnwrap(catalog.record(for: b))),
                     "前置事实：这一代句柄读不到，否则走不到复核那一步")
        // 句柄下一轮就恢复，但那一轮查询先卡在闸门里：制造"复核期间取消"。
        catalogSource.publishesAX = true
        catalogSource.gatesNextCatalogLoad = true

        coordinator.perform(plan)
        await pendingUntil { self.catalogSource.isBlockedInCatalogLoad }
        XCTAssertTrue(coordinator.isBusy, "目录复核在途时交换必须仍标为在途")

        let eventsBeforeCancel = events.count
        XCTAssertEqual(eventsBeforeCancel, 1, "取消前只有 prepare 一步的回报")
        XCTAssertEqual(stepEvents().first?.step, .prepare)

        coordinator.cancel()
        XCTAssertFalse(coordinator.isBusy, "取消后不再有在途交换")
        catalogSource.openCatalogLoadGate()
        await pendingUntil { !self.catalogSource.isBlockedInCatalogLoad }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(writer.totalWrites, 0,
                       "复核放行后一次普通 AX 写入都不许发生：\(writer.writtenFrames)")
        XCTAssertEqual(events.count, eventsBeforeCancel,
                       "令牌作废后迟到的复核结果不许再进状态机：\(events.suffix(4))")
        XCTAssertTrue(committedTokens().isEmpty)
        // 一个像素都没写：B 不许留下"未解释恢复义务"，A 的会话事务照常留给退出恢复（方案 §7.2、A12）。
        XCTAssertNil(store.entry(for: b)?.lastProvisionalFrame)
        let untouchedBFrame = try await currentFrame(of: b)
        XCTAssertEqual(untouchedBFrame, FakeCatalogSource.frame(for: 1))

        // 会话没被卡住：下一次交换照常走完，这就是"恢复可完成"。
        let next = try await switchPlan(token: TransitionToken(generation: 3))
        coordinator.perform(next)
        await pendingUntil(timeout: 4) { self.committedTokens().contains(next.intent.token) }
        XCTAssertEqual(committedTokens(), [next.intent.token])
    }

    // MARK: - A02/A03 写前两趟实读在途时取消（方案 §18 A02/A03、§6.2）

    /// A02：可移动/可尺寸能力查询挂在跨进程调用里时取消——放行后不得绕过已撤销的许可。
    /// 只有固定尺寸窗口才需要这次探测（可调尺寸窗口的放置策略不需要它，宿主已跳过）。
    func testCancelDuringWriteabilityReadNeverWritesWithRevokedPermit() async throws {
        _ = try await beginHappyPath()
        catalogSource.setPublishedResizable(false, for: b)
        await catalog.refreshAndWait(reason: .windowEvent)
        let plan = try await switchPlan(token: TransitionToken(generation: 2))
        writer.gatesNextWriteabilityRead = true

        coordinator.perform(plan)
        await pendingUntil { self.writer.isBlockedInRead }
        XCTAssertEqual(writer.blockedReadGate, .writeability, "卡住的必须是能力查询这一趟")
        XCTAssertTrue(coordinator.isBusy)

        let eventsBeforeCancel = events.count
        coordinator.cancel()
        XCTAssertFalse(coordinator.isBusy)
        writer.openReadGate()
        await pendingUntil { !self.writer.isBlockedInRead }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(writer.totalWrites, 0,
                       "撤销的许可挡回后续写入：迟到读回不能绕过令牌：\(writer.writtenFrames)")
        XCTAssertEqual(events.count, eventsBeforeCancel, "迟到结果不进状态机：\(events.suffix(4))")
        XCTAssertTrue(committedTokens().isEmpty)

        let next = try await switchPlan(token: TransitionToken(generation: 3))
        coordinator.perform(next)
        await pendingUntil(timeout: 4) { self.committedTokens().contains(next.intent.token) }
        XCTAssertEqual(committedTokens(), [next.intent.token], "取消不能把会话锁死")
    }

    /// A03：写前实读 frame 还没回来时取消——迟到的读回结果不得提交成一次 apply。
    func testCancelDuringPreWriteFrameReadNeverCommitsLateApply() async throws {
        _ = try await beginHappyPath()
        let plan = try await switchPlan(token: TransitionToken(generation: 2))
        writer.gatesNextFrameRead = true

        coordinator.perform(plan)
        await pendingUntil { self.writer.isBlockedInRead }
        XCTAssertEqual(writer.blockedReadGate, .currentFrame, "卡住的必须是写前实读这一趟")
        XCTAssertTrue(coordinator.isBusy)

        let eventsBeforeCancel = events.count
        coordinator.cancel()
        writer.openReadGate()
        await pendingUntil { !self.writer.isBlockedInRead }
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(writer.totalWrites, 0, "迟到 apply 不被提交：\(writer.writtenFrames)")
        XCTAssertEqual(events.count, eventsBeforeCancel)
        XCTAssertTrue(committedTokens().isEmpty, "迟到读回不能宣布这次交换完成")
        // 日志停在"意图已落盘、写还没确认"：这正是下次启动保守核对的入口（方案 §6.2）。
        XCTAssertEqual(store.entry(for: b)?.state, .mutationPlanned)
        XCTAssertNil(store.entry(for: b)?.lastProvisionalFrame)
        let untouchedBFrame = try await currentFrame(of: b)
        XCTAssertEqual(untouchedBFrame, FakeCatalogSource.frame(for: 1))
        let untouchedAFrame = try await currentFrame(of: a)
        XCTAssertEqual(untouchedAFrame, dockedRect(for: a), "取消期间原主几何不许被顺手改动")
    }

    // MARK: - H19/A10 超时：到点先报，再按逆序补偿一次

    /// A10（方案 §18 A10）：门卡在"尺寸已写、位置还没写"制造真实的部分写入，
    /// 到点后只补这一笔真正动过的窗口，且只补一次——补偿对象取自设备事实，不取自计划。
    func testStalledWriteTimesOutAndRollsBackExactlyOnce() async throws {
        let plan = try await beginHappyPath()
        // 门在"尺寸已写、位置还没写"这一刻（方案 §5.5 第 3 条：AX 已开始时到点，
        // 恢复必须排在它之后并按部分事实回位）。用入口门就永远造不出部分写入。
        writer.gatesPositionWrite = true

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
            plans.append(try await switchPlan(token: TransitionToken(generation: UInt64(index + 1))))
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

    // MARK: - 写前实读的 original 修正必须与操作前快照同批落盘（方案 §6.2、§7.3）

    /// 事务里的 originalFrame 起初只是目录推测值；写前实读与它不一致时必须按实读修正，
    /// 而且**不能被随后那条"操作前快照"写回推测值**——两条事实必须同一批原子落盘。
    func testCorrectedOriginalSurvivesTheSameBatchAsOperationBefore() async throws {
        let speculative = FakeCatalogSource.frame(for: 1)
        // 用户在 Vistile 之外把 B 挪走了 120/90pt：目录仍是旧位置，写前实读才是真值。
        let realBefore = speculative.offsetBy(dx: 120, dy: 90)
        let plan = try await beginHappyPath(bFrame: realBefore)
        XCTAssertEqual(store.entry(for: b)?.originalFrame, speculative,
                       "前置事实：计划期事务里只有目录推测的原位置")
        XCTAssertTrue(store.entry(for: b)?.hasSpeculativeOriginal == true)

        coordinator.perform(plan)
        await pendingUntil { self.committedTokens().contains(plan.intent.token) }

        XCTAssertEqual(store.entry(for: b)?.originalFrame, realBefore,
                       "写前实读必须成为会话 original：同批落盘后不能被计划期推测值覆盖")
        let reopened = WindowJournalStore(fileName: "session-journal.json",
                                          sessionID: sessionID,
                                          baseDirectory: journalDirectory)
        XCTAssertEqual(reopened.entry(for: b)?.originalFrame, realBefore,
                       "磁盘与内存必须一致：重启后按实读原位置恢复")
    }

    // MARK: - 最小化恢复失败必须进入补偿事实（方案 §6.4、§10.1）

    /// 解除最小化成功、几何写入被拒、补偿又收不回最小化：不能让 reducer 在"回滚完成"的
    /// 假前提下收口——这条事实必须随补偿结果回报，状态机据此进 recoveryRequired。
    func testUnrecoveredMinimizeIsReportedInCompensationFacts() async throws {
        let plan = try await beginHappyPath(minimized: [1])
        writer.refusesMinimize = true
        writer.setScript(.rejects, for: try element(of: b))

        coordinator.perform(plan)
        await pendingUntil(timeout: 4) { !self.failureReasons().isEmpty }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        let compensation = try XCTUnwrap(events.compactMap { event -> WorkbenchCompensationResult? in
            if case let .mainSwitchFailed(_, _, result) = event { return result }
            return nil
        }.last)
        XCTAssertTrue(compensation.unresolvedMinimizeRestorations.contains(b),
                      "收不回来的最小化必须如实上报：\(compensation.unresolvedMinimizeRestorations)")
        XCTAssertFalse(compensation.isComplete, "有未收回的副作用时不能宣称补偿完整")
        XCTAssertEqual(writer.isMinimized(for: try element(of: b)), false,
                       "替身确认这次恢复真的失败了（窗口确实留在展开态）")
    }

    // MARK: - H24 日志序号前进不该判死一次合法交换（0.1.13 实机缺陷）

    /// 现场（0.1.13 实机）：进入工作台后立刻点一次交换，报
    /// 「日志序号已过期（期望 7，当前 8）：update 未写入」，随后整个界面不再响应任何点击。
    /// 根因有两层：① 追加事实用的是日志**全局** revision 当守卫，退出清理/布局结算等无关写入
    /// 也会推进它；② 写前事实落盘失败被当成"写后失败"，reducer 发 `.drainGeometry` 把在途交换
    /// 的会话所有权撤掉，`mainSwitchFailed` 永远回报不上来，状态机停在 rollingBack。
    /// 本条钉住第 ① 层：无关写入先落盘，本次交换仍必须能写入并提交。
    func testUnrelatedJournalWriteBeforePlacementDoesNotKillSwitch() async throws {
        let plan = try await beginHappyPath()
        // 写前实读处挂起：此刻 prepare 已完成、第一条事实尚未追加，正是实机竞态的窗口。
        writer.gatesNextFrameRead = true
        coordinator.perform(plan)
        await pendingUntil { self.writer.isBlockedInRead }
        XCTAssertTrue(committedTokens().isEmpty, "前置事实：交换还没提交")

        let stranger = HostFixtures.identity(3)
        let extra = await store.apply(WindowTransaction(sessionID: sessionID,
                                                        identity: stranger,
                                                        bundleID: "com.test.app\(stranger.windowID)",
                                                        originalFrame: FakeCatalogSource.frame(for: 3),
                                                        originalDisplayID: displayID))
        XCTAssertTrue(extra.isPersisted, "前置事实：无关流程的日志写入成功并推进 revision")
        writer.openReadGate()

        await pendingUntil(timeout: 6) {
            self.committedTokens().contains(plan.intent.token) || !self.failureReasons().isEmpty
        }
        await pendingUntil(timeout: 4) { !self.coordinator.isBusy }

        XCTAssertTrue(failureReasons().isEmpty,
                      "日志序号前进不等于这次交换失效：\(failureReasons())")
        XCTAssertTrue(committedTokens().contains(plan.intent.token),
                      "同操作的事实必须能写入：守卫应按条目归属判断，而不是全局序号")
        XCTAssertEqual(writer.writtenFrames.count, 2, "交换该写的两笔几何都要落地")
    }

    // MARK: - H25 写前事实落盘失败必须收口，不能把界面留在"交换在途"

    /// 写前事实（操作前快照/原位置纠正）落盘失败时，一次 AX 写入都还没发生：
    /// 必须按失败回报，让状态机离开 rollingBack 并恢复交互，而不是 drain+cancel 把回报全挡掉。
    func testPreWriteJournalFailureReportsAndKeepsSessionUsable() async throws {
        let plan = try await beginHappyPath()
        makeJournalUnwritable()

        coordinator.perform(plan)
        await pendingUntil(timeout: 6) { !self.failureReasons().isEmpty }
        await pendingUntil(timeout: 6) { !self.coordinator.isBusy }
        makeJournalWritable()

        XCTAssertFalse(failureReasons().isEmpty,
                       "写前事实落盘失败必须回报 mainSwitchFailed：否则 reducer 永远停在 rollingBack，点击全被吞掉")
        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertEqual(writer.totalWrites, 0, "日志先行失败：一个几何字节都不许写")
        XCTAssertEqual(writer.recordedActions.filter { $0 == "写" }.count, 0)

        // 会话仍可用：日志恢复可写后，同一套交换必须能正常完成（而不是"交换在途"永久挡住）。
        let plan2 = try await switchPlan(token: TransitionToken(generation: 2))
        coordinator.perform(plan2)
        await pendingUntil(timeout: 8) { self.committedTokens().contains(plan2.intent.token) }
        XCTAssertTrue(committedTokens().contains(plan2.intent.token),
                      "失败收口后必须能继续操作：\(statuses)")
    }

    /// 实机主形态：B 已经写进主区、**写后事实**落盘失败。旧实现发 `.drainGeometry` → 宿主
    /// `cancel()` 交还会话所有权 → 交换链的失败回报被门禁挡掉 → 界面永久"交换在途"。
    /// 修好后必须由交换链补偿并回报 `mainSwitchFailed`，且会话能继续操作。
    func testPostWriteJournalFailureStillReportsAndKeepsSessionUsable() async throws {
        let plan = try await beginHappyPath()
        // B 的第一笔几何写入发起那一刻让日志不可写：写后事实必失败，时序与实机一致。
        writer.onWillWrite = { [weak self] _ in self?.makeJournalUnwritable() }

        coordinator.perform(plan)
        await pendingUntil(timeout: 6) { !self.failureReasons().isEmpty }
        await pendingUntil(timeout: 6) { !self.coordinator.isBusy }
        writer.onWillWrite = nil
        makeJournalWritable()

        XCTAssertFalse(failureReasons().isEmpty,
                       "写后事实落盘失败必须由交换链补偿后回报，不能因为提前取消而静默")
        XCTAssertTrue(committedTokens().isEmpty)
        XCTAssertFalse(writer.totalWrites == 0, "前置事实：B 真的写过一笔几何")

        let plan2 = try await switchPlan(token: TransitionToken(generation: 2))
        coordinator.perform(plan2)
        await pendingUntil(timeout: 8) { self.committedTokens().contains(plan2.intent.token) }
        XCTAssertTrue(committedTokens().contains(plan2.intent.token),
                      "失败收口后必须能继续操作：\(statuses)")
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
