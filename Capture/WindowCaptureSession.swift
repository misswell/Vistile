import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VistileCore

/// 单窗口捕获运行（方案 §7.1–§7.4、§10.1）。
///
/// 两条硬约束：一个窗口最多一个活跃 stream；实例只代表一次运行，runID 不复用。
/// 晚到帧靠信箱代次丢弃，晚到回调靠 runID 丢弃，因此停止之后到达的任何东西都污染不了下一轮。
final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, CaptureRunning, @unchecked Sendable {
    let identity: WindowIdentity
    let runID: CaptureRunID
    /// 本轮的信箱代次：管理者在切换运行时分配，本实例无权推进（方案 §7.4）。
    private let generation: UInt64
    /// 源窗口点尺寸：由目录给出，绝不从 contentScale 反推（方案 §10.1）。
    private let sourceSizeInPoints: CGSize?

    private let window: SCWindow
    private let mailbox: FrameMailbox<MetalFrame>
    private let metal: MetalContext
    private let sampleQueue: DispatchQueue

    private let lock = NSLock()
    private var lifecycle = CaptureLifecycle()
    /// SCStream 一创建就登记：startCapture 仍挂起时也必须能被停掉（方案 §7.2）。
    private var stream: SCStream?
    private var didReportFailure = false
    private var didDeliverFirstFrame = false
    private var storage: StreamConfig
    private var error: String?
    private var counts = CaptureFrameCounts()

    var onFirstFrame: ((CaptureRunID, Date) -> Void)?
    var onFailure: ((CaptureRunID, String) -> Void)?
    var onFramePublished: ((CaptureRunID, MetalFrame) -> Void)?

    init(identity: WindowIdentity,
         runID: CaptureRunID,
         generation: UInt64,
         window: SCWindow,
         sourceSizeInPoints: CGSize?,
         config: StreamConfig,
         mailbox: FrameMailbox<MetalFrame>,
         metal: MetalContext,
         sampleQueue: DispatchQueue) {
        self.identity = identity
        self.runID = runID
        self.generation = generation
        self.window = window
        self.sourceSizeInPoints = sourceSizeInPoints
        self.mailbox = mailbox
        self.metal = metal
        self.sampleQueue = sampleQueue
        self.storage = config
        super.init()
    }

    var phase: CaptureRunPhase { lock.withLock { lifecycle.phase } }
    var config: StreamConfig { lock.withLock { storage } }
    var lastError: String? { lock.withLock { error } }
    var frameCounts: CaptureFrameCounts { lock.withLock { counts } }

    // MARK: - 生命周期

    @discardableResult
    func start() async -> Bool {
        let configuration = SCStreamConfiguration()
        configuration.apply(config)
        let candidate = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                 configuration: configuration,
                                 delegate: self)
        do {
            try candidate.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            await finish(candidate, failure: "addStreamOutput: \(error.localizedDescription)")
            return false
        }
        // 先登记再 await：否则此刻到达的 stop() 只能对着 nil 空操作（R05 原始缺陷）。
        let registered = lock.withLock { () -> Bool in
            guard lifecycle.beginStart() else { return false }
            stream = candidate
            return true
        }
        guard registered else {
            await finish(candidate, failure: nil)
            return false
        }
        do {
            try await candidate.startCapture()
        } catch {
            await finish(candidate, failure: "startCapture: \(error.localizedDescription)")
            return false
        }
        switch lock.withLock({ lifecycle.startReturned() }) {
        case .enterRunning:
            return true
        case .mustStop, .alreadyHandled:
            // 取消后仍完成启动的局部 stream：停掉它，且不进入 running（方案 §7.2）。
            await finish(candidate, failure: nil)
            return false
        }
    }

    /// 请求停止。即便 start 还在等待也必须立刻标记取消；真正执行 stopCapture 的只有一条路径。
    func stop() async {
        switch lock.withLock({ lifecycle.requestStop() }) {
        case .thisCall:
            let target = lock.withLock { () -> SCStream? in
                let existing = stream
                stream = nil
                lifecycle.markStopped()
                return existing
            }
            await shutDown(target)
        case .pendingStart, .nobody:
            // pendingStart：start 返回后的那条路径负责停，两边都停或都不停都不行。
            return
        }
    }

    /// 几何变化只改配置，不重建流（方案 §9）。
    @discardableResult
    func update(configuration candidate: StreamConfig) async -> Bool {
        guard candidate != config else { return true }
        guard let target = lock.withLock({ () -> SCStream? in lifecycle.phase == .running ? stream : nil }) else {
            lock.withLock { storage = candidate }
            return false
        }
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.apply(candidate)
        do {
            try await target.updateConfiguration(streamConfiguration)
            lock.withLock { storage = candidate }
            return true
        } catch {
            lock.withLock { self.error = "updateConfiguration: \(error.localizedDescription)" }
            return false
        }
    }

    /// 收敛一条已经不再属于本轮的 stream：失败只在这里回报一次（方案 §7.2 最后一条）。
    private func finish(_ candidate: SCStream, failure: String?) async {
        let message = lock.withLock { () -> String? in
            if stream === candidate { stream = nil }
            lifecycle.markStopped()
            guard let failure, !didReportFailure, !lifecycle.cancellationRequested else { return nil }
            error = failure
            didReportFailure = true
            return failure
        }
        await shutDown(candidate)
        if let message { onFailure?(runID, message) }
    }

    private func shutDown(_ candidate: SCStream?) async {
        guard let candidate else { return }
        try? await candidate.stopCapture()
        // 输出也要摘掉：否则这条流的回调会继续投进已经作废的一轮（方案 §7.2）。
        try? candidate.removeStreamOutput(self, type: .screen)
    }

    private func bump(_ mutate: (inout CaptureFrameCounts) -> Void) {
        lock.withLock { mutate(&counts) }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        guard let status = readout.status else {
            // 没有 status 就不算完整帧：缺元数据时宁可丢掉这一帧，也不伪造画面（方案 §10.1）。
            bump { $0.rejectedByMetadata += 1 }
            return
        }
        guard status == .complete else {
            bump { $0.keptLastFrame += 1 }
            if status == .started { bump { $0.startedFrames += 1 } }
            return
        }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            bump { $0.rejectedByMetadata += 1 }
            return
        }
        let meta = CapturedFrameMeta(pixelWidth: CVPixelBufferGetWidth(imageBuffer),
                                     pixelHeight: CVPixelBufferGetHeight(imageBuffer),
                                     contentRectInPoints: readout.contentRectInPoints,
                                     pointPixelScale: readout.pointPixelScale ?? 1,
                                     contentScale: readout.contentScale,
                                     sourceSizeInPoints: sourceSizeInPoints,
                                     status: status,
                                     isValid: true,
                                     presentTime: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        guard let mapped = metal.texture(from: imageBuffer) else {
            bump { $0.dropped += 1 }
            return
        }
        let payload = MetalFrame(texture: mapped.texture,
                                 storage: mapped.storage,
                                 meta: meta,
                                 publishedAt: Date())
        guard mailbox.publish(payload, generation: generation, at: payload.publishedAt) else {
            // 代次不匹配：属于本轮之外的晚到帧，绝不改写新卡片的画面。
            bump { $0.stale += 1 }
            return
        }
        bump { $0.published += 1 }
        let delivered = lock.withLock { () -> Bool in
            guard !didDeliverFirstFrame else { return false }
            didDeliverFirstFrame = true
            return true
        }
        if delivered { onFirstFrame?(runID, payload.publishedAt) }
        onFramePublished?(runID, payload)
    }

    func stream(_ stream: SCStream, didDropSampleBuffer sampleBuffer: CMSampleBuffer, for type: SCStreamOutputType) {
        // 背压丢帧只影响帧率上限，不是会话失败（方案 §9.8）。
        bump { $0.dropped += 1 }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError stopError: Error) {
        let message = lock.withLock { () -> String? in
            guard !didReportFailure, !lifecycle.cancellationRequested else {
                error = stopError.localizedDescription
                return nil
            }
            error = stopError.localizedDescription
            didReportFailure = true
            if self.stream === stream { self.stream = nil }
            lifecycle.markStopped()
            return error
        }
        if let message { onFailure?(runID, message) }
    }
}
