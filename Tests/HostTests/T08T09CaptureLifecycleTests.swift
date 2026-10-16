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
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
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
            coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
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
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
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
        coordinator.sync(targets: targets(6), tier: .balanced, isAnimating: false)
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
        coordinator.sync(targets: targets(2), tier: .balanced, isAnimating: false)
        await pump()
        XCTAssertEqual(coordinator.allMailboxes().count, 2)
        let gone = HostFixtures.identity(0)

        // 第一次同步只负责停流；信箱与纹理要等这一轮彻底不在 runs 里才回收。
        coordinator.sync(targets: [HostCapture.target(1)], tier: .balanced, isAnimating: false)
        await pump()
        XCTAssertEqual(coordinator.activeStreamCount, 1)
        coordinator.sync(targets: [HostCapture.target(1)], tier: .balanced, isAnimating: false)
        await pump()

        XCTAssertEqual(releasedWindows, [gone], "已销毁窗口的纹理回收钩子没接上（renderer.forget）")
        XCTAssertNil(coordinator.allMailboxes().first { $0.identity == gone },
                     "窗口已经没了还留着信箱，画面会一直挂在总览上")
    }

    // MARK: - T09 旧回调隔离

    func testLateCallbacksAfterStopAllCannotTouchTheNewRun() async throws {
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
        await pump()
        let frame = try HostFixtures.metalFrame(metal: metal, width: 160, height: 100)
        let old = runs[0]
        old.frameForPublish = frame

        coordinator.stopAll()
        await coordinator.waitForQuiet()
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
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
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
        await pump(6)
        XCTAssertEqual(failedFacts, 1)
        let old = runs[0]

        failNextStart = false
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
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
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
        await pump()
        let old = runs[0]
        coordinator.stopAll()
        await coordinator.waitForQuiet()
        coordinator.sync(targets: targets(1), tier: .balanced, isAnimating: false)
        await pump()
        let current = runs[1]

        await old.stop()
        await pump()
        XCTAssertEqual(current.totalStops, 0, "旧一轮的停止路径碰到了新一轮的实例")
        XCTAssertEqual(coordinator.activeStreamCount, 1)
    }
}
