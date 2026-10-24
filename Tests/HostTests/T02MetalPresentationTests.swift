import AppKit
import Metal
import QuartzCore
import VistileCore
import XCTest
@testable import Vistile

/// T02 Metal 设备与呈现：两种 CAMetalLayer 与管线共用同一台设备，
/// 一次真实绘制确实请求了 present，GPU 完成回调没有错误，纹理按 command buffer 生命周期释放。
///
/// 这里只证明"提交链是通的"，不证明"屏幕上看到了正确画面"——后者必须由实机与录屏验收（方案 §4.4）。
final class T02MetalPresentationTests: XCTestCase {
    private var metal: MetalContext!
    private var renderer: OverviewRenderer!
    private var controller: OverviewWindowController!
    private var layout: GridLayout!
    private var records: [WindowIdentity: WindowRecord]!

    override func setUpWithError() throws {
        try super.setUpWithError()
        metal = try HostFixtures.metalContext()
        renderer = try HostFixtures.renderer(metal: metal)
        controller = OverviewWindowController(display: HostFixtures.display, mapper: HostFixtures.mapper, metal: metal)
        let built = HostFixtures.layout()
        layout = built.layout
        records = built.records
    }

    override func tearDown() {
        controller?.hide()
        controller = nil
        renderer = nil
        metal = nil
        layout = nil
        records = nil
        super.tearDown()
    }

    private var view: OverviewContentView { controller.contentView }

    private func sync(_ mailboxes: [WindowIdentity: FrameMailbox<MetalFrame>] = [:]) {
        controller.updateLayout(layout,
                                records: records,
                                renderer: renderer,
                                mailboxProvider: { mailboxes[$0] },
                                style: .standard,
                                showsTitles: true,
                                searchQuery: "")
    }

    // MARK: - 设备绑定

    func testOverviewLayerUsesSharedDevice() {
        XCTAssertNotNil(view.metalLayer.device, "未绑定 device 的 CAMetalLayer 永远不会有任何 drawable")
        XCTAssertTrue(view.metalLayer.device === renderer.device)
        XCTAssertTrue(view.metalLayer.device === metal.device)
        XCTAssertEqual(view.metalLayer.pixelFormat, .bgra8Unorm)
    }

    func testProxyLayerUsesSameDeviceAsPipeline() {
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        XCTAssertTrue(proxy.metalLayer.device === renderer.device,
                      "代理自建 device 时，drawable 与总览纹理不兼容，过渡一帧都画不出来")
        XCTAssertEqual(proxy.metalLayer.pixelFormat, .bgra8Unorm)
        XCTAssertTrue(proxy.metalLayer.framebufferOnly)
    }

    /// 代理图层没有 frame 就没有任何可见像素：R02 的原始缺陷之一。
    func testProxyLayerFrameFollowsViewSize() {
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        proxy.needsLayout = true
        proxy.layoutSubtreeIfNeeded()
        XCTAssertEqual(proxy.metalLayer.frame.size, proxy.bounds.size)
        XCTAssertGreaterThan(proxy.metalLayer.frame.width, 1)
    }

    @MainActor
    func testProxySynchronouslyDrawsAndAdvancesFromInjectedTime() throws {
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        defer { proxy.stop() }
        proxy.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        proxy.layout()
        proxy.setSource(try HostFixtures.metalFrame(metal: metal), sourceAspect: 2)
        let source = CGRect(x: HostFixtures.offscreenOrigin.x + 20, y: 40, width: 200, height: 120)
        let target = source.offsetBy(dx: 320, dy: 180).insetBy(dx: -100, dy: -80)
        proxy.animate(fromCG: source, toCG: target, durationMS: 1000, reverse: false, startAt: 100)

        XCTAssertEqual(proxy.renderCount, 1)
        XCTAssertEqual(proxy.currentRectInCG, source)
        XCTAssertTrue(proxy.hasDisplayLink)
        proxy.advance(to: 99)
        XCTAssertEqual(proxy.currentRectInCG, source)
        proxy.advance(to: 100.5)
        XCTAssertEqual(proxy.currentRectInCG, TransitionTimeline.interpolate(source, target, progress: 0.5))
        let content = proxy.presentedContentRect
        XCTAssertEqual(content.width / content.height, 2, accuracy: 0.0001)
        XCTAssertTrue(proxy.currentRect().contains(content))
        XCTAssertTrue(proxy.isAnimating)
    }

    @MainActor
    func testProxyFadeAppliesOpacityOnceAtTheDestination() throws {
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        defer { proxy.stop() }
        proxy.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        proxy.layout()
        let source = CGRect(x: HostFixtures.offscreenOrigin.x + 20, y: 40, width: 200, height: 120)
        let target = source.offsetBy(dx: 320, dy: 180)
        for (start, end) in [(CGFloat(0), CGFloat(1)), (CGFloat(1), CGFloat(0))] {
            proxy.setSource(try HostFixtures.metalFrame(metal: metal), sourceAspect: 2)
            proxy.animate(fromCG: source, toCG: target, durationMS: 1000, reverse: end == 0,
                          mode: .fade, startAlpha: start, endAlpha: end, startAt: 100)
            XCTAssertEqual(proxy.currentRectInCG, target)
            XCTAssertEqual(proxy.metalLayer.opacity * proxy.presentedCardOpacity, Float(start), accuracy: 0.0001)
            proxy.advance(to: 100.5)
            XCTAssertEqual(proxy.currentRectInCG, target)
            XCTAssertEqual(proxy.metalLayer.opacity * proxy.presentedCardOpacity, 0.5, accuracy: 0.0001,
                           "Layer opacity and card opacity must not square the fade")
            XCTAssertNil(proxy.metalLayer.animation(forKey: "opacity"))
            proxy.advance(to: 101)
            XCTAssertEqual(proxy.metalLayer.opacity * proxy.presentedCardOpacity, Float(end), accuracy: 0.0001)
            XCTAssertFalse(proxy.isAnimating)
            XCTAssertFalse(proxy.hasDisplayLink)
        }
    }

    @MainActor
    func testProxyStopAndCompletionReleaseSourceAndIgnoreLateTicks() throws {
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        defer { proxy.stop() }
        proxy.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        proxy.layout()
        let rect = CGRect(x: HostFixtures.offscreenOrigin.x + 20, y: 40, width: 200, height: 120)
        var completions = 0
        for completes in [false, true] {
            proxy.setSource(try HostFixtures.metalFrame(metal: metal), sourceAspect: 2)
            proxy.onComplete = { completions += 1 }
            proxy.animate(fromCG: rect, toCG: rect, durationMS: 1000, reverse: false, startAt: 100)
            XCTAssertTrue(proxy.hasSource)
            if completes { proxy.advance(to: 101) } else { proxy.stop() }
            let draws = proxy.renderCount
            XCTAssertFalse(proxy.hasSource)
            XCTAssertFalse(proxy.hasDisplayLink)
            XCTAssertFalse(proxy.isAnimating)
            XCTAssertNil(proxy.onComplete)
            proxy.advance(to: 102)
            proxy.advance(to: 103)
            XCTAssertEqual(proxy.renderCount, draws)
            XCTAssertEqual(completions, completes ? 1 : 0)
        }
    }

    @MainActor
    func testProxyCompletionCanStartANewAnimationWithoutOldCleanup() throws {
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        defer { proxy.stop() }
        proxy.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        proxy.layout()
        let frame = try HostFixtures.metalFrame(metal: metal)
        let first = CGRect(x: HostFixtures.offscreenOrigin.x + 20, y: 40, width: 200, height: 120)
        let second = first.offsetBy(dx: 200, dy: 100)
        var completions = 0
        proxy.onComplete = {
            completions += 1
            proxy.setSource(frame, sourceAspect: 2)
            proxy.onComplete = { completions += 1 }
            proxy.animate(fromCG: first, toCG: second, durationMS: 1000, reverse: false, startAt: 200)
        }
        proxy.animate(fromCG: first, toCG: first, durationMS: 1000, reverse: false, startAt: 100)
        proxy.advance(to: 101)
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(proxy.isAnimating)
        XCTAssertTrue(proxy.hasDisplayLink)
        XCTAssertTrue(proxy.hasSource)
        proxy.advance(to: 200.5)
        XCTAssertEqual(proxy.currentRectInCG, TransitionTimeline.interpolate(first, second, progress: 0.5))
        proxy.advance(to: 201)
        XCTAssertEqual(completions, 2)
        XCTAssertFalse(proxy.hasDisplayLink)
    }

    /// 显示时钟在无活动显示/离屏时可能整段不回调：动画仍须按自身时长收尾。
    /// 状态机等的是「动画结束」，不是「某一帧被画过」——否则只能等到 1.5s 超时降级。
    @MainActor
    func testProxyCompletionDeadlineCompletesWithoutDisplayLinkTicks() throws {
        let probe = CompletionProbe()
        let proxy = TransitionProxyView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize),
                                        metal: metal,
                                        makeCompletionTimer: { interval, body in
            probe.interval = interval
            probe.fire = { body(Timer(timeInterval: 1, repeats: false) { _ in }) }
            return Timer(timeInterval: 3600, repeats: false) { _ in }
        })
        defer { proxy.stop() }
        proxy.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        proxy.layout()
        proxy.setSource(try HostFixtures.metalFrame(metal: metal), sourceAspect: 2)
        let rect = CGRect(x: HostFixtures.offscreenOrigin.x + 20, y: 40, width: 200, height: 120)
        var completions = 0
        proxy.onComplete = { completions += 1 }
        proxy.animate(fromCG: rect, toCG: rect, durationMS: 100, reverse: false, startAt: 100)

        XCTAssertTrue(proxy.isAnimating)
        XCTAssertEqual(probe.interval, 0.12, accuracy: 0.001,
                       "到点收尾略晚于动画时长，避免与最后一帧抢跑")
        XCTAssertNotNil(probe.fire, "没有到点收尾时，显示时钟不回调就只能等状态机超时")
        probe.fire?()
        XCTAssertFalse(proxy.isAnimating)
        XCTAssertEqual(completions, 1)
        probe.fire?()
        XCTAssertEqual(completions, 1, "收尾必须只发生一次")
    }

    @MainActor
    func testProxyDisplayLinkDoesNotRetainItsView() {
        weak var released: TransitionProxyView?
        autoreleasepool {
            let proxy = TransitionProxyView(frame: .zero, metal: metal)
            released = proxy
            proxy.animate(fromCG: .zero, toCG: .zero, durationMS: 1000, reverse: false, startAt: 100)
            XCTAssertTrue(proxy.hasDisplayLink)
        }
        XCTAssertNil(released)
    }

    /// 尺寸、倍率与 drawableSize 必须一起换算：点当像素会直接表现为模糊或错位。
    func testDrawableSizeMatchesBackingScale() {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.metalLayer.contentsScale, HostFixtures.display.backingScale)
        XCTAssertEqual(view.metalLayer.drawableSize,
                       CGSize(width: view.bounds.width * 2, height: view.bounds.height * 2))
    }

    func testBindRepairsAForeignDeviceLayer() {
        let layer = CAMetalLayer()
        renderer.bind(layer)
        XCTAssertTrue(layer.device === metal.device)
        XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
    }

    // MARK: - 真实提交

    func testRealDrawRequestsPresentAndDrainsTextures() throws {
        let frame = try HostFixtures.metalFrame(metal: metal)
        let mailbox = FrameMailbox<MetalFrame>()
        mailbox.publish(frame, generation: mailbox.currentGeneration)
        let mailboxes = Dictionary(uniqueKeysWithValues: records.keys.map { ($0, mailbox) })

        let before = renderer.diagnostics()
        sync(mailboxes)
        let after = renderer.diagnostics()

        XCTAssertGreaterThan(after.draws, before.draws)
        XCTAssertGreaterThan(after.submissions, before.submissions, "实际 draw 必须提交 command buffer 和 present 请求")
        XCTAssertEqual(after.submissions - before.submissions, 1, "一次离屏绘制只提交一个 drawable；实际呈现由 presentedTime 单独确认")
        XCTAssertEqual(after.submissionFailures, before.submissionFailures)
        XCTAssertEqual(after.missingDrawables, before.missingDrawables)

        // in-flight 纹理要随 command buffer 完成回调释放，不能越积越多。
        XCTAssertGreaterThan(renderer.inFlightTextureCount, 0)
        waitUntil(timeout: 4) { self.renderer.inFlightTextureCount == 0 }
        XCTAssertEqual(renderer.inFlightTextureCount, 0, "提交后纹理未被释放，长时间开总览会一直吃显存")
        XCTAssertEqual(renderer.diagnostics().gpuErrors, 0, renderer.diagnostics().lastGPUError ?? "")
    }

    /// 静止画面不重复提交：版本没变、几何没变时不发新的绘制。
    func testIdleFramesDoNotKeepSubmitting() throws {
        let frame = try HostFixtures.metalFrame(metal: metal)
        let mailbox = FrameMailbox<MetalFrame>()
        mailbox.publish(frame, generation: mailbox.currentGeneration)
        let mailboxes = Dictionary(uniqueKeysWithValues: records.keys.map { ($0, mailbox) })
        sync(mailboxes)
        let afterFirst = renderer.diagnostics()

        sync(mailboxes)
        XCTAssertEqual(renderer.diagnostics().draws, afterFirst.draws,
                       "没有新帧且几何未变时不该再提交一次整屏绘制")
    }

    /// 新帧版本推进后要再提交一次，且仍然只 present 一个 drawable。
    func testFreshFrameTriggersAnotherPresent() throws {
        let frame = try HostFixtures.metalFrame(metal: metal)
        let mailbox = FrameMailbox<MetalFrame>()
        mailbox.publish(frame, generation: mailbox.currentGeneration)
        let mailboxes = Dictionary(uniqueKeysWithValues: records.keys.map { ($0, mailbox) })
        sync(mailboxes)
        let afterFirst = renderer.diagnostics()

        mailbox.publish(frame, generation: mailbox.currentGeneration)
        sync(mailboxes)
        let afterSecond = renderer.diagnostics()
        XCTAssertEqual(afterSecond.draws - afterFirst.draws, 1)
        XCTAssertEqual(afterSecond.submissions - afterFirst.submissions, 1)
    }

    /// 视图尺寸为 0（刚创建或被压扁）时不提交，也不因此进入忙循环。
    func testZeroSizedViewSubmitsNothing() {
        let orphan = OverviewContentView(frame: NSRect(origin: .zero, size: .zero), metal: metal)
        let before = renderer.diagnostics()
        orphan.redraw(using: renderer, mailboxes: { _ in nil }, force: true)
        let after = renderer.diagnostics()
        XCTAssertEqual(after.draws, before.draws + 1)
        XCTAssertEqual(after.submissions, before.submissions)
        XCTAssertEqual(after.submissionFailures, before.submissionFailures)
    }

    /// 设备变化后（拔屏、重置）绘制前仍要再确认一次绑定。
    func testDrawRebindsLayerToDevice() {
        view.metalLayer.device = nil
        sync()
        XCTAssertTrue(view.metalLayer.device === metal.device)
    }

    /// 释放后不留版本记录：否则重开总览会一直显示锁屏前的旧画面。
    func testReleaseAllDropsRetainedFrames() throws {
        let frame = try HostFixtures.metalFrame(metal: metal)
        let mailbox = FrameMailbox<MetalFrame>()
        mailbox.publish(frame, generation: mailbox.currentGeneration)
        sync(Dictionary(uniqueKeysWithValues: records.keys.map { ($0, mailbox) }))
        XCTAssertGreaterThan(renderer.retainedTextureCount, 0)
        renderer.releaseAll()
        XCTAssertEqual(renderer.retainedTextureCount, 0)
        waitUntil(timeout: 4) { self.renderer.inFlightTextureCount == 0 }
        XCTAssertNoThrow(try HostFixtures.metalFrame(metal: metal))
    }
    func testInputDrivenChromeDoesNotAcquireImplicitAnimations() {
        let chrome = CardChrome()
        view.layer?.addSublayer(chrome.container)
        chrome.layout(in: CGRect(x: 10, y: 10, width: 220, height: 140),
                      style: .standard, showsTitle: true, showsStatus: false)
        CATransaction.flush()
        chrome.layout(in: CGRect(x: 35, y: 25, width: 220, height: 140),
                      style: .standard, showsTitle: true, showsStatus: false)
        chrome.apply(title: "Window", status: nil, isSelected: true, isHovered: true,
                     accent: .controlAccentColor, style: .standard, showsTitle: true, scale: 2)
        CATransaction.flush()
        for layer in [chrome.container, chrome.border, chrome.titleBar, chrome.titleText] {
            XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true,
                          "Chrome must move with Metal content without an extra animation")
        }
        chrome.container.removeFromSuperlayer()
    }

    func testCarrierFadeDoesNotAcquireAnImplicitOpacityAnimation() throws {
        let carrier = TransitionCarrierView(frame: NSRect(origin: .zero, size: HostFixtures.offscreenSize), metal: metal)
        view.layer?.addSublayer(carrier.metalLayer)
        CATransaction.flush()
        carrier.metalLayer.opacity = 0.4
        CATransaction.flush()
        XCTAssertNil(carrier.metalLayer.animation(forKey: "opacity"),
                     "The display-link fade must not acquire a second animation clock")
        carrier.metalLayer.removeFromSuperlayer()
        carrier.stopNow()
    }

}

/// 捕获代理的到点收尾定时器：测试在主线程手动触发它，模拟显示时钟整段不回调。
private final class CompletionProbe: @unchecked Sendable {
    var interval: TimeInterval = 0
    var fire: (() -> Void)?
}
