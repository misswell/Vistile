import AppKit
import Metal
import CoreGraphics
import Foundation
import XCTest
import VistileCore
@testable import Vistile

private final class T15ImageMappingThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var mainThreadValues: [Bool] = []

    func record() {
        lock.lock()
        mainThreadValues.append(Thread.isMainThread)
        lock.unlock()
    }

    var lastWasMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadValues.last
    }
}

/// T15：降级的稳定性（方案 §7.5、§9）。
///
/// 两件事必须同时成立，缺一个总览就是坏的：
/// 1. 降级来的轮询卡片在下一次 sync 时不能被当成"缺流的卡片"又启动直播流（全停全启的乒乓）；
/// 2. 轮询用的单窗口截图同一时刻最多一个在途，前一次没回来就跳过本轮，不叠并发请求。
/// 定时器与截图都由替身控制，断言落在"起了几条流、发起几次截图、峰值并发多少"这些可数的事实上。
/// 真 SCScreenshotManager 是否能在降级目标上稳定出图，属实的机器验收项。
@MainActor
final class T15PollingStabilityTests: XCTestCase {
    private var metal: MetalContext!
    private var catalog: WindowCatalog!
    private var coordinator: CaptureCoordinator!
    private var capturer: FakeSingleFrameCapturer!
    private var runs: [FakeCaptureRun] = []
    private var gateStarts = false
    private var mappingProbe = T15ImageMappingThreadProbe()
    private var facts: [CaptureFact] = []
    private var frameReports: [WindowIdentity] = []

    override func setUpWithError() throws {
        metal = try HostFixtures.metalContext()
        catalog = HostCapture.catalog()
        let frameCapturer = FakeSingleFrameCapturer()
        frameCapturer.image = try makeImage()
        capturer = frameCapturer
        runs = []
        gateStarts = false
        mappingProbe = T15ImageMappingThreadProbe()
        let mappingProbe = self.mappingProbe
        facts = []
        frameReports = []
        coordinator = CaptureCoordinator(metal: metal,
                                       catalog: catalog,
                                       sampleQueue: DispatchQueue(label: "com.misswell.Vistile.test.polling.frames"),
                                       runFactory: { [weak self] request in
                                           let run = FakeCaptureRun(request: request)
                                           if let self {
                                               run.gatesStart = self.gateStarts
                                               self.runs.append(run)
                                           }
                                           return run
                                       },
                                       singleFrame: { identity, _ in
                                           await frameCapturer.outcome(for: identity)
                                       },
                                       imageMappingObserver: { mappingProbe.record() })
        coordinator.onFact = { [weak self] fact in self?.facts.append(fact) }
        coordinator.onFrame = { [weak self] identity in self?.frameReports.append(identity) }
    }

    override func tearDown() {
        coordinator?.stopAll(releasingMailboxes: true)
        capturer?.openGate()
        for run in runs { run.openStartGate() }
        coordinator = nil
        catalog = nil
        capturer = nil
        runs = []
        gateStarts = false
        facts = []
        frameReports = []
        super.tearDown()
    }

    // MARK: - 推进时间

    /// 已排队的 MainActor 任务靠 await 交接跑完。
    private func pump(_ times: Int = 4) async {
        for _ in 0..<times {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    /// 定时器只在 runloop 真的转动时触发：这一段的时长由轮询间隔（1 秒）决定。
    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func targets(_ count: Int) -> [CaptureTarget] {
        (0..<count).map { HostCapture.target($0) }
    }

    private func target(_ index: Int, visibility: CaptureTargetVisibility) -> CaptureTarget {
        CaptureTarget(record: HostFixtures.record(index, slot: index),
                      cellWidth: 320,
                      backingScale: 2,
                      isPriority: false,
                      visibility: visibility)
    }

    private func makeImage() throws -> CGImage {
        guard let context = CGContext(data: nil,
                                      width: 160,
                                      height: 100,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "T15", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建位图上下文"])
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        guard let image = context.makeImage() else {
            throw NSError(domain: "T15", code: 2, userInfo: [NSLocalizedDescriptionKey: "CGImage 生成失败"])
        }
        return image
    }

    private func isDowngraded(_ fact: CaptureFact, identity: WindowIdentity, interval: Int) -> Bool {
        if case let .downgraded(target, intervalMilliseconds) = fact {
            return target == identity && intervalMilliseconds == interval
        }
        return false
    }

    private var startedFactCount: Int {
        facts.filter { if case .started = $0 { return true }; return false }.count
    }

    // MARK: - 不因下一次 sync 重启直播流

    func testDowngradedCardsAreNotPromotedByTheNextSync() async {
        capturer.gatesRequests = true
        coordinator.streamSoftLimit = 1
        coordinator.sync(targets: targets(3), tier: .balanced, activity: TransitionActivity())
        await pump(8)
        waitUntil(timeout: 2) { self.capturer.pendingRequestCount == 2 }
        let live = HostFixtures.identity(0)
        let polled = HostFixtures.identity(1)
        XCTAssertEqual(coordinator.activeStreamCount, 1, "软上限 1 只该有一条直播流")
        XCTAssertEqual(coordinator.polledCount, 2)
        XCTAssertEqual(coordinator.mode(for: live), .live)
        XCTAssertEqual(coordinator.mode(for: polled), .poll(intervalMilliseconds: 1_000))

        facts = []
        for _ in 0..<3 {
            coordinator.sync(targets: targets(3), tier: .balanced, activity: TransitionActivity())
            await pump(4)
        }
        XCTAssertEqual(coordinator.activeStreamCount, 1, "下一次 sync 把降级来的卡片又重启成直播流")
        XCTAssertEqual(coordinator.liveCount, 1)
        XCTAssertEqual(coordinator.polledCount, 2)
        XCTAssertEqual(startedFactCount, 0, "重复同步仍在为新流发启动事实")
        XCTAssertTrue(facts.filter { isDowngraded($0, identity: polled, interval: 1_000) }.isEmpty,
                      "重复同步仍在重新降级：轮询间隔被一轮轮刷新")
        capturer.openGate()
        waitUntil(timeout: 3) { self.coordinator.activePollCount == 0 }
    }

    /// 降到 3fps 的档位底后仍超预算：落到轮询，且再同步不回弹。
    func testBudgetDowngradeLandsInPollingAndStaysThere() async {
        coordinator.streamSoftLimit = 1
        coordinator.sync(targets: targets(2), tier: .powerSaving, activity: TransitionActivity())
        await pump(8)
        XCTAssertEqual(coordinator.mode(for: HostFixtures.identity(0)), .live)
        XCTAssertEqual(coordinator.mode(for: HostFixtures.identity(1)), .poll(intervalMilliseconds: 1_000))
        let streams = coordinator.activeStreamCount
        XCTAssertEqual(streams, 1)

        coordinator.sync(targets: targets(2), tier: .powerSaving, activity: TransitionActivity())
        await pump(8)
        XCTAssertEqual(coordinator.activeStreamCount, streams)
        XCTAssertEqual(coordinator.mode(for: HostFixtures.identity(1)), .poll(intervalMilliseconds: 1_000))
    }

    // MARK: - 单窗口截图不叠并发

    func testPollCaptureNeverStacksConcurrentRequests() {
        capturer.gatesRequests = true
        coordinator.streamSoftLimit = 1
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        let polled = HostFixtures.identity(1)
        waitUntil(timeout: 2) { self.capturer.calls(for: polled) >= 1 }
        XCTAssertEqual(capturer.calls(for: polled), 1, "第一次降级就该发一次单窗口截图")

        // 在途期间反复同步：既不该重排轮询，也不该叠第二个请求。
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        // 定时器每 1 秒触发一次；前一次还卡在门后，这几轮都必须被跳过。
        spin(2.5)
        XCTAssertEqual(capturer.calls(for: polled), 1, "上一次截图还没回来就又叠了一个请求")
        XCTAssertEqual(capturer.peakInFlight, 1, "同窗口出现两个在途截图请求")

        capturer.openGate()
        waitUntil(timeout: 4) { self.capturer.calls(for: polled) >= 2 }
        XCTAssertGreaterThanOrEqual(capturer.calls(for: polled), 2, "解除在途后轮询应当继续")
        XCTAssertEqual(capturer.peakInFlight, 1, "整个过程中同窗口的峰值并发超过 1")
    }

    func testGlobalPollBudgetIsTwoAndQueueStartsVisibleTargetsFirst() {
        capturer.gatesRequests = true
        coordinator.streamSoftLimit = 1
        let transition = target(0, visibility: .transition)
        let offscreen = target(1, visibility: .offscreen)
        let visible = target(2, visibility: .visible)
        let prefetch = target(3, visibility: .prefetch)

        coordinator.sync(targets: [transition, offscreen, visible, prefetch],
                         tier: .balanced,
                         activity: TransitionActivity())
        waitUntil(timeout: 2) { self.capturer.pendingRequestCount >= 2 }

        XCTAssertEqual(coordinator.activePollCount, 2,
                       "两路截图预算应作为全局事实暴露给压力验收")
        XCTAssertGreaterThanOrEqual(coordinator.queuedPollCount, 1,
                                    "超过全局截图预算的目标应留在待处理队列")
        XCTAssertEqual(capturer.calls(for: visible.identity), 1,
                       "可见目标应先于离屏目标拿到全局截图名额")
        XCTAssertEqual(capturer.calls(for: offscreen.identity), 0,
                       "离屏截图不应占用可见卡片等待的名额")
        XCTAssertLessThanOrEqual(capturer.peakInFlight, 2,
                                 "跨窗口低频截图必须受全局两路并发上限约束")
        capturer.openGate()
    }

    func testChangingPollIntervalInvalidatesOldResultAndKeepsNewRequestTracked() {
        capturer.gatesRequests = true
        coordinator.streamSoftLimit = 1
        let live = target(0, visibility: .visible)
        let polling = target(1, visibility: .visible)
        coordinator.sync(targets: [live, polling], tier: .balanced, activity: TransitionActivity())
        waitUntil(timeout: 2) { self.capturer.pendingRequestCount == 1 }

        let offscreen = target(1, visibility: .offscreen)
        coordinator.sync(targets: [live, offscreen], tier: .balanced, activity: TransitionActivity())
        XCTAssertEqual(coordinator.mode(for: polling.identity), .poll(intervalMilliseconds: 2_000))
        XCTAssertEqual(coordinator.activePollCount, 1,
                       "间隔更新不能提前释放仍在等待的旧截图操作")
        XCTAssertEqual(coordinator.queuedPollCount, 1,
                       "新代次应保留为待执行请求，直到旧截图真实完成")

        // 只完成旧请求，门仍关闭：旧图不应发布；当前代次的新请求应接管同一窗口的占位。
        capturer.openNextRequestKeepingGate()
        waitUntil(timeout: 3) {
            self.capturer.calls(for: polling.identity) == 2 && self.capturer.pendingRequestCount == 1
        }
        XCTAssertTrue(frameReports.filter { $0 == polling.identity }.isEmpty,
                      "切换轮询间隔后，旧代次截图仍然发布了")
        XCTAssertEqual(coordinator.activePollCount, 1,
                       "旧请求返回后应由新代次接管唯一窗口的活跃槽位")
        XCTAssertEqual(coordinator.queuedPollCount, 0,
                       "旧完成回调不能清空或重复保留新请求")
        XCTAssertLessThanOrEqual(capturer.peakInFlight, 1,
                                 "旧请求尚未完成时同一窗口又启动了重叠截图")

        coordinator.sync(targets: [live, offscreen], tier: .balanced, activity: TransitionActivity())
        XCTAssertEqual(capturer.calls(for: polling.identity), 2,
                       "旧请求完成不应清除新请求的在途标记，导致重复启动")
        capturer.openGate()
        waitUntil(timeout: 3) { self.frameReports.filter { $0 == polling.identity }.count == 1 }
    }

    func testStopAllAndReopenKeepOldScreenshotOperationsInGlobalBudget() {
        capturer.gatesRequests = true
        coordinator.streamSoftLimit = 1
        let allTargets = targets(5)
        coordinator.sync(targets: allTargets, tier: .balanced, activity: TransitionActivity())
        waitUntil(timeout: 2) { self.capturer.pendingRequestCount >= 2 }
        XCTAssertLessThanOrEqual(capturer.activeCount, 2)
        XCTAssertEqual(coordinator.activePollCount, 2)

        coordinator.stopAll()
        coordinator.sync(targets: allTargets, tier: .balanced, activity: TransitionActivity())
        waitUntil(timeout: 2) { self.capturer.activeCount >= 2 }

        XCTAssertEqual(coordinator.activePollCount, 2,
                       "stopAll 后旧截图仍应占据全局 active 计数")
        XCTAssertGreaterThan(coordinator.queuedPollCount, 0,
                             "重开会话的截图请求应排队等待旧操作收敛")
        XCTAssertEqual(capturer.activeCount, 2,
                       "stopAll 清理逻辑标记不能释放尚未完成的底层截图预算")
        XCTAssertLessThanOrEqual(capturer.peakInFlight, 2,
                                 "stopAll 后重开使旧、新会话截图超过全局并发上限")
        capturer.openGate()
    }

    func testStopAllAndReopenKeepOldStreamStartsInTwoStartBudget() async {
        gateStarts = true
        coordinator.streamSoftLimit = 5
        let allTargets = targets(5)
        coordinator.sync(targets: allTargets, tier: .balanced, activity: TransitionActivity())
        await pump(8)
        XCTAssertEqual(runs.filter(\.isSuspendedInStart).count, 2,
                       "初始启动应占满两路并发启动预算")
        XCTAssertEqual(coordinator.activeStartCount, 2)

        coordinator.stopAll()
        coordinator.sync(targets: allTargets, tier: .balanced, activity: TransitionActivity())
        await pump(8)
        XCTAssertEqual(runs.count, 2,
                       "旧 startCapture 尚未返回时，stopAll 后的新一轮不能另开启动任务")
        XCTAssertEqual(coordinator.activeStartCount, 2,
                       "stopAll 不能从活跃计数中抹掉尚未返回的 startCapture")
        XCTAssertGreaterThan(coordinator.queuedStartCount, 0,
                             "新一轮启动应排队等待旧 startCapture 返回")
        XCTAssertLessThanOrEqual(runs.filter(\.isSuspendedInStart).count, 2)

        gateStarts = false
        for run in runs { run.openStartGate() }
        await coordinator.waitForQuiet()
        await pump(8)
    }

    func testLowFrequencyImageMappingDoesNotRunOnMainThread() {
        coordinator.streamSoftLimit = 1
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        waitUntil(timeout: 3) { self.mappingProbe.lastWasMainThread != nil }
        XCTAssertEqual(mappingProbe.lastWasMainThread, false,
                       "CGImage 到 CVPixelBuffer/Metal texture 的同步转换不能占用主线程")
    }

    // MARK: - 降级卡片仍然是活的

    /// 低频帧必须走与流帧相同的纹理路径，而且颜色不能反：写错内存序整张图红蓝互换。
    func testLowFrequencyImageUsesTheSameTexturePath() throws {
        let red = try makeSolidImage(red: 1, green: 0, blue: 0)
        let mapped = try XCTUnwrap(metal.texture(from: red),
                                   "CGImage 换不成纹理：低频更新这条路在真实设备上断了，卡片会一直停在旧画面")
        XCTAssertEqual(mapped.meta.pixelWidth, red.width)
        XCTAssertEqual(mapped.meta.pixelHeight, red.height)
        let bytes = try readBackFirstPixel(of: mapped.texture)
        // 渲染层按 bgra8Unorm 采样：字节序必须是 B,G,R,A。
        XCTAssertEqual(Array(bytes[0..<3]), [0, 0, 255],
                       "纯红被存成了纯蓝：写 pixel buffer 用的位图信息不是 32BGRA 的内存序")
        XCTAssertEqual(bytes[3], 255)
    }

    /// 把纹理拷回 CPU：走真实 command buffer，GPU 结束后才算读到事实。
    private func readBackFirstPixel(of texture: MTLTexture) throws -> [UInt8] {
        let buffer = try XCTUnwrap(metal.device.makeBuffer(length: 16, options: []))
        let commandBuffer = try XCTUnwrap(metal.commandQueue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        encoder.copy(from: texture,
                     sourceSlice: 0,
                     sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                     to: buffer,
                     destinationOffset: 0,
                     destinationBytesPerRow: 4,
                     destinationBytesPerImage: 4,
                     options: [])
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(commandBuffer.status, .completed, "拷贝没跑完：\(commandBuffer.error?.localizedDescription ?? "")")
        let pointer = buffer.contents().assumingMemoryBound(to: UInt8.self)
        return [pointer[0], pointer[1], pointer[2], pointer[3]]
    }

    private func makeSolidImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(domain: "T15", code: 1, userInfo: [NSLocalizedDescriptionKey: "拿不到 sRGB 色彩空间"])
        }
        guard let context = CGContext(data: nil,
                                      width: 160,
                                      height: 100,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "T15", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建位图上下文"])
        }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        guard let image = context.makeImage() else {
            throw NSError(domain: "T15", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGImage 生成失败"])
        }
        return image
    }

    func testPolledCardStillPaintsAndReportsItsRealInterval() async {
        coordinator.streamSoftLimit = 1
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        await pump(12)
        let polled = HostFixtures.identity(1)
        // 低频帧要回主 actor 才能发布，必须异步等待，不能同步堵住主 actor。
        await waitUntilAsync(timeout: 10) { self.frameReports.contains(polled) }
        XCTAssertEqual(capturer.calls(for: polled), 1, "降级后根本没发起单窗口截图")
        XCTAssertTrue(facts.contains { isDowngraded($0, identity: polled, interval: 1_000) },
                      "降级事实没带上真实间隔：UI 会把轮询标成实时")
        XCTAssertTrue(frameReports.contains(polled), "降级卡片的单帧没驱动重绘，屏上会一直是旧画面")
        XCTAssertEqual(coordinator.mailbox(for: polled).pendingCount, 1, "低频帧没落进信箱")
        XCTAssertEqual(coordinator.mode(for: polled).displayPhase, .lowFrequency(intervalMilliseconds: 1_000))
    }

    /// 整轮作废后晚到的那一张不该再改卡片，也不该再对外发事实。
    func testLatePollResultAfterStopIsIgnored() {
        capturer.gatesRequests = true
        coordinator.streamSoftLimit = 1
        coordinator.sync(targets: targets(2), tier: .balanced, activity: TransitionActivity())
        let polled = HostFixtures.identity(1)
        waitUntil(timeout: 2) { self.capturer.calls(for: polled) >= 1 }
        facts = []
        frameReports = []

        coordinator.stopAll()
        capturer.openGate()
        spin(1)
        XCTAssertTrue(frameReports.isEmpty, "整轮作废后晚到的低频帧还在驱动重绘")
        XCTAssertTrue(facts.isEmpty, "整轮作废后晚到的低频帧仍在对外发事实")
    }
}
