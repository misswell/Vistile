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
        controller = OverviewWindowController(display: HostFixtures.display, metal: metal)
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
        XCTAssertGreaterThan(after.presents, before.presents, "取了 drawable 却不 present，屏上永远不会变")
        XCTAssertEqual(after.presents - before.presents, 1, "一次绘制只 present 一个 drawable")
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
        XCTAssertEqual(afterSecond.presents - afterFirst.presents, 1)
    }

    /// 视图尺寸为 0（刚创建或被压扁）时不提交，也不因此进入忙循环。
    func testZeroSizedViewSubmitsNothing() {
        let orphan = OverviewContentView(frame: NSRect(origin: .zero, size: .zero), metal: metal)
        let before = renderer.diagnostics()
        orphan.redraw(using: renderer, records: records, frameByID: { _ in nil }, mailboxes: { _ in nil }, force: true)
        let after = renderer.diagnostics()
        XCTAssertEqual(after.draws, before.draws + 1)
        XCTAssertEqual(after.presents, before.presents)
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
}
