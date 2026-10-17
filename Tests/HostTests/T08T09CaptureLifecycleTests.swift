import AppKit
import Foundation
import Metal
import XCTest
import VistileCore
@testable import Vistile

/// T08/T09：捕获流的生命周期交错与旧回调隔离（方案 §7.2、§7.3、§15.2）。
///
/// 真实 `SCStream.startCapture` 何时返回、停止落在哪条流上都不是测试能安排的，用随机 sleep 猜时序
/// 只会得到偶发绿。这里把"一次运行"换成带门的替身（裁决仍走核心那套 `CaptureLifecycle`），
/// 断言落在协调器真正负责的四件事：谁去停、停几次、旧回调能否影响新的一轮、并发额度是否守住。
/// SCStream 自己那层（addStreamOutput/removeStreamOutput/stopCapture 的实际效果）归属实机项。
@MainActor
final class T08T09CaptureLifecycleTests: XCTestCase {
    private var metal: MetalContext!
    private var catalog: WindowCatalog!
    private var coordinator: CaptureCoordinator!
    private var runs: [FakeCaptureRun] = []
    private var facts: [CaptureFact] = []
    private var frameReports: [WindowIdentity] = []
    private var releasedWindows: [WindowIdentity] = []
    private var gateNextStart = false
    private var failNextStart = false

    override func setUpWithError() throws {
        metal = try HostFixtures.metalContext()
        catalog = HostCapture.catalog()
        coordinator = CaptureCoordinator(metal: metal,
                                        catalog: catalog,
                                        sampleQueue: DispatchQueue(label: "com.misswell.Vistile.test.capture.frames"),
                                        runFactory: { [weak self] request in
                                            let run = FakeCaptureRun(request: request)
                                            guard let self else { return run }
                                            run.gatesStart = self.gateNextStart
                                            run.failsStart = self.failNextStart
                                            self.runs.append(run)
                                            return run
                                        },
                                        singleFrame: { _, _ in .unavailable })
        coordinator.onFact = { [weak self] fact in self?.facts.append(fact) }
        coordinator.onFrame = { [weak self] identity in self?.frameReports.append(identity) }
        coordinator.onWindowReleased = { [weak self] identity in self?.releasedWindows.append(identity) }
    }

    override func tearDown() {
        coordinator?.stopAll(releasingMailboxes: true)
        for run in runs { run.openStartGate() }
        coordinator = nil
        catalog = nil
        runs = []
        facts = []
        frameReports = []
        releasedWindows = []
        gateNextStart = false
        failNextStart = false
        super.tearDown()
    }

    // MARK: - 组装

    /// 让主队列把已排队的任务跑完：启动/停止都是 MainActor 上的 Task，靠 await 交接而不是 sleep。
    private func pump(_ times: Int = 4) async {
        for _ in 0..<times {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func targets(_ count: Int) -> [CaptureTarget] {
        (0..<count).map { HostCapture.target($0) }
    }

    private func count(_ match: (CaptureFact) -> Bool) -> Int { facts.filter(match).count }
    private var startedFacts: Int { count { if case .started = $0 { return true }; return false } }
    private var failedFacts: Int { count { if case .failed = $0 { return true }; return false } }
    private var firstFrameFacts: Int { count { if case .firstFrame = $0 { return true }; return false } }

    // MARK: - T08 start/stop 交错

    func testStopWhileStartIsPendingStillStopsThatStream() async {
        gateNextStart = true
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(runs.count, 1)
        let run = runs[0]
        XCTAssertTrue(run.isSuspendedInStart, "start 没停在待决状态，这条测不到交错")
        XCTAssertEqual(coordinator.activeStreamCount, 1)

        coordinator.stopAll()
        XCTAssertEqual(run.totalStops, 0, "停止权不属于这次调用：它只能登记取消")

        run.openStartGate()
        await coordinator.waitForQuiet()
        XCTAssertEqual(run.madeHandleCount, 1)
        XCTAssertEqual(run.unstoppedHandleCount, 0, "被取消的一轮把底层实例留在了系统里")
        XCTAssertEqual(run.totalStops, 1, "同一条流被停了不止一次")
        XCTAssertTrue(run.phase == .stopped || run.phase == .idle)
        XCTAssertTrue(coordinator.isLogicallyIdle)
        XCTAssertEqual(coordinator.activeStreamCount, 0)
    }

    func testHundredOpenCloseCyclesLeaveNoUndrainedState() async {
        for _ in 0..<100 {
            coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
            await pump(2)
            coordinator.stopAll()
            await coordinator.waitForQuiet()
        }
        XCTAssertEqual(runs.count, 100, "每轮开关都该只登记一次运行")
        for run in runs {
            XCTAssertLessThanOrEqual(run.madeHandleCount, 1, "一个身份开出过第二条底层实例")
            XCTAssertEqual(run.unstoppedHandleCount, 0, "开关一百次后仍有没停掉的底层实例")
            XCTAssertEqual(run.totalStops, run.createdHandleCount)
        }
        XCTAssertTrue(coordinator.isLogicallyIdle)
        XCTAssertEqual(coordinator.activeStreamCount, 0)
        XCTAssertEqual(coordinator.queuedStartCount, 0)
        XCTAssertEqual(coordinator.polledCount, 0)
        XCTAssertEqual(coordinator.allMailboxes().count, 1,
                       "反复开关在同一条链上会把信箱越积越多")
    }

    func testStartFailureIsReportedExactlyOnce() async {
        failNextStart = true
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump(6)
        XCTAssertEqual(startedFacts, 1)
        XCTAssertEqual(failedFacts, 1, "同一轮启动失败对外报了两条：回调与返回各报一次")
        XCTAssertEqual(firstFrameFacts, 0)
        XCTAssertTrue(coordinator.isLogicallyIdle)
        XCTAssertEqual(coordinator.activeStreamCount, 0)
        XCTAssertEqual(runs[0].unstoppedHandleCount, 0)
    }

    func testConcurrentStartsStayInsideTheBudget() async {
        gateNextStart = true
        coordinator.sync(targets: targets(6), tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(coordinator.activeStreamCount, 2, "并发启动额度是 2，一次同步不许铺开六条流")
        XCTAssertEqual(coordinator.queuedStartCount, 4)

        for _ in 0..<6 {
            let suspended = runs.filter { $0.isSuspendedInStart }
            XCTAssertLessThanOrEqual(suspended.count, 2, "在途启动超出了并发额度")
            for run in suspended { run.openStartGate() }
            await pump()
        }
        XCTAssertEqual(coordinator.activeStreamCount, 6)
        XCTAssertEqual(coordinator.queuedStartCount, 0)
        XCTAssertEqual(startedFacts, 6)
    }

    func testDestroyedWindowReleasesMailboxAndReportsTextureReclaim() async {
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(coordinator.allMailboxes().count, 2)
        let gone = HostFixtures.identity(0)

        // 第一次同步只负责停流；信箱与纹理要等这一轮彻底不在 runs 里才回收。
        coordinator.sync(targets: [HostCapture.target(1)], tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(coordinator.activeStreamCount, 1)
        coordinator.sync(targets: [HostCapture.target(1)], tier: .balanced, activity: TransitionActivity())
        await pump()

        XCTAssertEqual(releasedWindows, [gone], "已销毁窗口的纹理回收钩子没接上（renderer.forget）")
        XCTAssertNil(coordinator.allMailboxes().first { $0.identity == gone },
                     "窗口已经没了还留着信箱，画面会一直挂在总览上")
    }

    // MARK: - T09/A37 旧回调隔离（方案 §18 A37：迟到的旧 run 回调不污染新 mailbox、资源计数不增）

    func testLateCallbacksAfterStopAllCannotTouchTheNewRun() async throws {
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump()
        let frame = try HostFixtures.metalFrame(metal: metal, width: 160, height: 100)
        let old = runs[0]
        old.frameForPublish = frame

        coordinator.stopAll()
        await coordinator.waitForQuiet()
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(runs.count, 2)
        let current = runs[1]
        current.frameForPublish = frame
        facts = []
        frameReports = []

        old.emitFirstFrame()
        old.emitFailure("晚到的失败")
        old.emitFrame()
        await pump(6)
        XCTAssertTrue(frameReports.isEmpty, "旧一轮的帧回调驱动了新总览的重绘")
        XCTAssertTrue(facts.isEmpty, "旧一轮的首帧/失败事实进了当前状态机")
        XCTAssertNil(coordinator.mailbox(for: HostFixtures.identity(0)).lastPublishedAt,
                     "旧一轮已经停止，却把半张图发布进了新一轮的信箱")

        // 同一时间线上，新一轮的事实必须照常上报：隔离不能过头。
        current.emitFirstFrame()
        current.emitFrame()
        await pump(6)
        XCTAssertEqual(firstFrameFacts, 1)
        XCTAssertEqual(frameReports, [HostFixtures.identity(0)])
    }

    func testSupersededRunInsideTheSameRoundCannotAffectCurrentRun() async {
        failNextStart = true
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump(6)
        XCTAssertEqual(failedFacts, 1)
        let old = runs[0]

        failNextStart = false
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(runs.count, 2, "上一轮启动失败后，下一轮必须能重来")
        XCTAssertEqual(coordinator.activeStreamCount, 1)
        facts = []

        // 同一 round、同一身份、新的一轮已经登记：旧 run 的晚到事实只能被丢掉。
        old.emitFirstFrame()
        old.emitFailure("旧一轮晚到的失败")
        await pump(6)
        XCTAssertTrue(facts.isEmpty, "旧 run 的晚到事实改写了新 run 的状态")
        XCTAssertEqual(coordinator.activeStreamCount, 1, "旧 run 的晚到失败把新流误停了")

        // 当前这一轮真的失败时，事实仍要出去（这是 latestRun 判据要守住的另一半）。
        runs[1].emitFailure("当前这轮失败")
        await pump(6)
        XCTAssertEqual(failedFacts, 1)
        XCTAssertEqual(coordinator.activeStreamCount, 0)
    }

    func testLateStopOnAnOldRunCannotStopTheNewStream() async {
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump()
        let old = runs[0]
        coordinator.stopAll()
        await coordinator.waitForQuiet()
        coordinator.sync(targets: targets(1), tier: .balanced, activity: TransitionActivity())
        await pump()
        let current = runs[1]

        await old.stop()
        await pump()
        XCTAssertEqual(current.totalStops, 0, "旧一轮的停止路径碰到了新一轮的实例")
        XCTAssertEqual(coordinator.activeStreamCount, 1)
    }

    // MARK: - A35 连续滚动：合并到一个意图，最后可见集合正确（方案 §13.2、§18 A35）

    /// 滚动或拖分隔线会在几十毫秒里给出几十个尺寸 delta。
    /// 协调器必须把它们合并成"最新那一个意图"，而不是每个 delta 都改一次码流配置。
    func testRapidSizeDeltasCoalesceIntoLatestIntent() async throws {
        coordinator.sync(targets: [HostCapture.target(0, cellWidth: 320)],
                         tier: .balanced, activity: TransitionActivity())
        await pump()
        XCTAssertEqual(coordinator.activeStreamCount, 1)
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.configurationUpdateCount, 0, "静止的一轮不该有任何重配")

        let widest: CGFloat = 320 + 30 * 8
        for step in 1...30 {
            coordinator.sync(targets: [HostCapture.target(0, cellWidth: 320 + CGFloat(step) * 8)],
                             tier: .balanced, activity: TransitionActivity())
        }
        // 250ms 节流窗口过后，最新那份意图必须被落实：等条件，不等固定 sleep 赌运气。
        let expected = StreamConfig.build(cellWidth: widest,
                                          backingScale: 2,
                                          sourceSize: HostCapture.target(0, cellWidth: widest).sourceSize,
                                          tier: .balanced)
        await pendingUntil(timeout: 3) { run.config == expected }

        XCTAssertLessThanOrEqual(run.configurationUpdateCount, 2,
                                 "30 个 delta 最多兑现两次重配：每个 delta 改一次码流就是滚动抖动")
        XCTAssertEqual(run.config, expected, "合并不能变成『永远不落实最新意图』")
        XCTAssertEqual(coordinator.activeStreamCount, 1, "尺寸调整不该让卡片换一条流")
    }

    /// 可见集合平移时：每张卡片最多启动一次，最后留下的必须正好是最后一次同步的那一组。
    func testScrollingSettlesOnTheLastVisibleSetWithoutRestartingCards() async throws {
        let windowSize = 4
        for offset in 0..<20 {
            let indices = Array(offset..<(offset + windowSize))
            coordinator.sync(targets: indices.map { HostCapture.target($0) },
                             tier: .balanced, activity: TransitionActivity())
            await pump()
        }
        await coordinator.waitForQuiet()

        let lastSet = Set((19..<(19 + windowSize)).map { HostFixtures.identity($0) })
        let liveIdentities = runs.filter { $0.liveHandles > 0 }.map(\.identity)
        XCTAssertEqual(Set(liveIdentities), lastSet,
                       "最后可见的那组必须都在直播，滚出去的都要停干净：\(liveIdentities)")
        let startedIdentities = runs.map(\.identity)
        XCTAssertEqual(Set(startedIdentities).count, startedIdentities.count,
                       "同一张卡片被反复重启就是启停失控：\(startedIdentities)")
        // 20 次平移覆盖到 0…22 共 23 张卡片：每张恰好建过一次流。
        // 这条先把分母钉住，否则后面的 stop 算式会在"中途批次根本没启动"时空洞通过。
        XCTAssertEqual(runs.count, 19 + windowSize,
                       "滑过的每张卡片都该起过一条流：实际 \(runs.count)")
        XCTAssertEqual(runs.reduce(0) { $0 + $1.totalStops }, runs.count - windowSize,
                       "每张滚出可见集合的卡片恰好停一次，多停或漏停都不对")
    }

    /// 等主 Actor 把已排队的任务跑完直到条件成立：节流窗口只能被跨过，不能被猜。
    private func pendingUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时（\(timeout)s）")
                return
            }
            await pump(2)
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
