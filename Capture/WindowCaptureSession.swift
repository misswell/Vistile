import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VistileCore

/// 单窗口捕获会话：一个窗口最多一个活跃 stream（方案 §7 不变量）。
/// 停止后晚到帧因 generation 不匹配被 mailbox 丢弃，不会污染新会话。
final class WindowCaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let identity: WindowIdentity
    let generation: UInt64

    private(set) var config: StreamConfig
    private(set) var lastError: String?
    private(set) var publishedFrames: Int = 0
    private(set) var idleFrames: Int = 0
    private(set) var droppedFrames: Int = 0

    private let window: SCWindow
    private let mailbox: FrameMailbox<MetalFrame>
    private let metal: MetalContext
    private let sampleQueue: DispatchQueue
    private var stream: SCStream?
    private var didDeliverFirstFrame = false

    /// 首帧、失败、新帧通知；后两者可能在采样队列触发。
    var onFirstFrame: ((Date) -> Void)?
    var onFailure: ((String) -> Void)?
    var onFramePublished: ((MetalFrame) -> Void)?

    init(identity: WindowIdentity,
         generation: UInt64,
         window: SCWindow,
         config: StreamConfig,
         mailbox: FrameMailbox<MetalFrame>,
         metal: MetalContext,
         sampleQueue: DispatchQueue) {
        self.identity = identity
        self.generation = generation
        self.window = window
        self.config = config
        self.mailbox = mailbox
        self.metal = metal
        self.sampleQueue = sampleQueue
        super.init()
    }

    var isRunning: Bool { stream != nil }

    func start() async -> Bool {
        let configuration = SCStreamConfiguration()
        configuration.apply(config)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            lastError = "addStreamOutput: \(error.localizedDescription)"
            onFailure?(lastError!)
            return false
        }
        do {
            try await stream.startCapture()
        } catch {
            lastError = "startCapture: \(error.localizedDescription)"
            onFailure?(lastError!)
            return false
        }
        self.stream = stream
        return true
    }

    /// 几何变化只改配置，不重建流（方案 §9）。
    func update(configuration candidate: StreamConfig) async -> Bool {
        guard candidate != config else { return true }
        guard let stream else {
            config = candidate
            return false
        }
        let configuration = SCStreamConfiguration()
        configuration.apply(candidate)
        do {
            try await stream.updateConfiguration(configuration)
            config = candidate
            return true
        } catch {
            lastError = "updateConfiguration: \(error.localizedDescription)"
            return false
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        // 代际推进后，采样队列里晚到的帧会被 mailbox 拒绝。
        mailbox.advanceGeneration()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        let statusNumber = attachment(sampleBuffer, SCStreamFrameInfo.status.rawValue) as? NSNumber
        let frameStatus = statusNumber.flatMap { SCFrameStatus(rawValue: $0.intValue) } ?? .complete
        guard frameStatus != .suspended, frameStatus != .stopped, frameStatus != .blank else {
            // 系统暂停（例如最小化）：保留最后画面，状态由目录给出，不标成捕获失败。
            return
        }

        let scaleFactor = (attachment(sampleBuffer, SCStreamFrameInfo.scaleFactor.rawValue) as? NSNumber)?
            .doubleValue ?? 1
        let contentRect = (attachment(sampleBuffer, SCStreamFrameInfo.contentRect.rawValue) as? NSValue)?.rectValue ?? .zero
        let contentScale = (attachment(sampleBuffer, SCStreamFrameInfo.contentScale.rawValue) as? NSValue)?.sizeValue ?? .zero

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let meta = CapturedFrameMeta(
            pixelWidth: CVPixelBufferGetWidth(imageBuffer),
            pixelHeight: CVPixelBufferGetHeight(imageBuffer),
            contentRect: contentRect,
            // scaleFactor 是显示分辨率与点的比例；内容留边由 contentRect/contentScale 表达。
            scaleFactor: CGFloat(scaleFactor),
            sourceSize: CGSize(width: contentScale.width, height: contentScale.height),
            isValid: true,
            isIdle: frameStatus == .idle,
            presentTime: CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        )

        // idle 帧保留最后画面：只计数，不覆盖纹理（方案 §9.8）。
        guard meta.shouldUpdateTexture else {
            idleFrames += 1
            return
        }
        guard let texture = metal.texture(from: imageBuffer) else {
            droppedFrames += 1
            return
        }
        let payload = MetalFrame(texture: texture.texture,
                                 storage: texture.storage,
                                 meta: meta,
                                 publishedAt: Date())
        publishedFrames += 1
        if mailbox.publish(payload, generation: generation, at: payload.publishedAt) {
            if !didDeliverFirstFrame {
                didDeliverFirstFrame = true
                onFirstFrame?(payload.publishedAt)
            }
            onFramePublished?(payload)
        } else {
            droppedFrames += 1
        }
    }

    private func attachment(_ sampleBuffer: CMSampleBuffer, _ key: String) -> AnyObject? {
        CMGetAttachment(sampleBuffer, key: key as CFString, attachmentModeOut: nil)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error.localizedDescription
        self.stream = nil
        onFailure?(error.localizedDescription)
    }

    /// 背压丢帧只影响帧率上限，不是会话失败；记录但保持 live。
    func stream(_ stream: SCStream, didDropSampleBuffer sampleBuffer: CMSampleBuffer, for type: SCStreamOutputType) {
        droppedFrames += 1
    }
}
