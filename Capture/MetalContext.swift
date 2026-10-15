import CoreMedia
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit
import VistileCore

/// GPU 帧负载。纹理与其 CVMetalTexture 引用必须一起存活，
/// command buffer 完成前不能释放（方案 §9.5）。
struct MetalFrame: @unchecked Sendable {
    let texture: MTLTexture
    let storage: CVMetalTexture
    let meta: CapturedFrameMeta
    let publishedAt: Date
}

/// 一个设备、一个命令队列、一个纹理缓存，供全部卡片共享。
final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache

    private init(device: MTLDevice, commandQueue: MTLCommandQueue, textureCache: CVMetalTextureCache) {
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache
    }

    static func make() -> MetalContext? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { return nil }
        return MetalContext(device: device, commandQueue: queue, textureCache: cache)
    }

    /// BGRA8 与屏幕捕获输出一致；失败返回 nil，调用方保留上一帧而不是标成失败。
    func texture(from pixelBuffer: CVPixelBuffer) -> MetalFrame? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var reference: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                              textureCache,
                                                              pixelBuffer,
                                                              nil,
                                                              .bgra8Unorm,
                                                              width,
                                                              height,
                                                              0,
                                                              &reference)
        guard status == kCVReturnSuccess, let reference,
              let texture = CVMetalTextureGetTexture(reference) else { return nil }
        return MetalFrame(texture: texture,
                          storage: reference,
                          meta: CapturedFrameMeta(pixelWidth: width,
                                                  pixelHeight: height,
                                                  contentRect: .zero,
                                                  scaleFactor: 1,
                                                  sourceSize: CGSize(width: width, height: height),
                                                  isValid: true,
                                                  isIdle: false,
                                                  presentTime: 0),
                          publishedAt: Date())
    }

    /// 低频更新用公开的单窗口截图接口：CGImage 先落进 BGRA pixel buffer，
    /// 再走与视频帧相同的纹理缓存路径，保证降级画面与流画面格式一致。
    func texture(from image: CGImage) -> MetalFrame? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         image.width,
                                         image.height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGImageByteOrderInfo.order32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return texture(from: pixelBuffer)
    }

    /// 断开显示器或设备重置后重建缓存；不重建则新帧会持续失败。
    func purgeTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}

/// SCStreamConfiguration 与核心层 StreamConfig 的唯一映射点。
extension SCStreamConfiguration {
    func apply(_ config: StreamConfig) {
        width = config.pixelWidth
        height = config.pixelHeight
        queueDepth = config.queueDepth
        capturesAudio = config.capturesAudio
        showsCursor = config.showsCursor
        minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        pixelFormat = kCVPixelFormatType_32BGRA
        // 单窗口视频不采集音频、不画指针；阴影由源窗口自身决定，不做逐帧重建。
    }
}
