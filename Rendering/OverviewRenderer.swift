import AppKit
import CoreGraphics
import Foundation
import Metal
import simd
import VistileCore

/// 一张卡片需要 GPU 合成的画面矩形。坐标使用视图本地 AppKit 坐标（原点左下），
/// 由渲染器统一翻转到纹理坐标，避免调用点混用坐标系。
struct CardDraw {
    let identity: WindowIdentity
    let imageRect: CGRect
    var opacity: Float = 1
    /// 过渡代理与真实画面衔接时的短交叉淡化。
    var frame: MetalFrame?

    /// 代理画面不属于任何窗口，用一个固定的保留身份，避免与真实卡片纹理互相覆盖。
    static let proxyIdentity = WindowIdentity(processID: -1, processStartIdentity: 0, windowID: 0)
}

/// 渲染侧事实快照。只用于诊断与验收记录，不构成"画面已正确显示"的结论。
struct RendererDiagnostics: Hashable {
    let device: String
    let draws: Int
    let presents: Int
    let missingDrawables: Int
    let submissionFailures: Int
    let gpuErrors: Int
    let lastGPUError: String?
}

/// 一次总览绘制。全部卡片共用一个 command buffer，静止后不再提交（方案 §9.6）。
final class OverviewRenderer {
    private let metal: MetalContext
    private let pool = TexturePool()
    private let pipelines: RenderPipelines
    /// 每个身份已消费到的 mailbox 版本；未变化的卡片不会重复取纹理。
    private var consumedVersions: [WindowIdentity: UInt64] = [:]
    /// 最后一次有效纹理：idle 或暂停时继续显示，不伪造进度。
    private var retained: [WindowIdentity: MetalFrame] = [:]
    private var redrawScheduled = false

    var background = SIMD4<Float>(0.078, 0.082, 0.094, 1)

    // MARK: - 受控诊断（辅助判断，不替代录屏验收）
    /// 每帧写日志会自己变成性能问题，这里只累计事实；首错落一条日志，其余只计数。
    private struct Counters {
        var draws = 0
        var presents = 0
        var missingDrawables = 0
        var submissionFailures = 0
        var gpuErrors = 0
        var lastGPUError: String?
        var didLogGPUError = false
    }
    private var counters = Counters()
    private let diagnosticsLock = NSLock()

    init?(metal: MetalContext) {
        self.metal = metal
        guard let pipelines = RenderPipelines(device: metal.device, colorFormat: .bgra8Unorm) else { return nil }
        self.pipelines = pipelines
    }

    var inFlightTextureCount: Int { pool.inFlightCount }
    var retainedTextureCount: Int { retained.count }
    var device: MTLDevice { metal.device }

    /// draw / present / 取不到 drawable / 提交失败 / GPU 错误分开计数：
    /// "捕获到帧"与"画面真的上屏"不是同一事实（方案 §4.4）。
    func diagnostics() -> RendererDiagnostics {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return RendererDiagnostics(device: metal.device.name,
                                   draws: counters.draws,
                                   presents: counters.presents,
                                   missingDrawables: counters.missingDrawables,
                                   submissionFailures: counters.submissionFailures,
                                   gpuErrors: counters.gpuErrors,
                                   lastGPUError: counters.lastGPUError)
    }

    /// 合并到下一个主队列周期，避免几十个流各自触发一次整屏重绘。
    func scheduleRedraw(_ run: @escaping () -> Void) {
        guard !redrawScheduled else { return }
        redrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.redrawScheduled = false
            run()
        }
    }

    /// 拉取新帧；返回是否真的有变化，调用方据此决定要不要提交绘制。
    @discardableResult
    func absorbFrames(from sources: [(identity: WindowIdentity, mailbox: FrameMailbox<MetalFrame>)]) -> Bool {
        var changed = false
        for source in sources {
            let version = consumedVersions[source.identity] ?? 0
            guard let fresh = source.mailbox.latestIfChanged(aboveVersion: version) else { continue }
            consumedVersions[source.identity] = fresh.version
            retained[source.identity] = fresh.payload
            changed = true
        }
        return changed
    }

    func forget(_ identity: WindowIdentity) {
        retained.removeValue(forKey: identity)
        consumedVersions.removeValue(forKey: identity)
    }

    /// 过渡代理取起点画面：用总览已经持有的纹理，不额外拉一次捕获。
    func texture(for identity: WindowIdentity) -> MetalFrame? {
        retained[identity]
    }

    /// hidden、锁屏、睡眠后释放纹理与版本记录（方案 §9.7）。
    func releaseAll() {
        retained.removeAll()
        consumedVersions.removeAll()
        pool.dropAll()
    }

    // MARK: - 绘制

    /// 图层与管线必须属于同一设备：不兼容时纹理与 drawable 无法一起出现在一个 encoder 里。
    /// 视图创建图层后立即调用它，之后每次绘制前再确认一次（屏幕断开重建设备时也能自愈）。
    func bind(_ layer: CAMetalLayer) {
        if layer.device !== metal.device { layer.device = metal.device }
        if layer.pixelFormat != .bgra8Unorm { layer.pixelFormat = .bgra8Unorm }
    }

    func draw(layer: CAMetalLayer,
              cards: [CardDraw],
              placeholders: [(rect: CGRect, tint: SIMD4<Float>)],
              viewBounds: CGRect,
              scale: CGFloat) {
        bump { $0.draws += 1 }
        let pixels = CGSize(width: (viewBounds.width * scale).rounded(),
                            height: (viewBounds.height * scale).rounded())
        guard pixels.width > 1, pixels.height > 1 else { return }
        bind(layer)
        layer.drawableSize = pixels

        // 取不到 drawable 时直接等下一次帧变化/动画 tick，绝不在此处忙循环。
        guard let drawable = layer.nextDrawable() else {
            bump { $0.missingDrawables += 1 }
            return
        }
        guard let commandBuffer = metal.commandQueue.makeCommandBuffer() else {
            bump { $0.submissionFailures += 1 }
            noteFailure("command queue 无法建立 buffer")
            return
        }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(background.x),
                                                                 green: Double(background.y),
                                                                 blue: Double(background.z),
                                                                 alpha: Double(background.w))
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            // 失败分支不 present，drawable 随作用域结束释放，不能留半张画面在屏上。
            bump { $0.submissionFailures += 1 }
            noteFailure("render encoder 创建失败")
            return
        }

        // 卡片底与留边用纯色覆盖，保证等比例画面不被拉伸或裁切。
        encoder.setRenderPipelineState(pipelines.solid)
        for placeholder in placeholders {
            var uniforms = ShaderSource.DrawUniforms(tint: placeholder.tint, uvRect: SIMD4<Float>(0, 0, 1, 1))
            encoder.setViewport(viewport(placeholder.rect, viewBounds: viewBounds, scale: scale))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderSource.DrawUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.setRenderPipelineState(pipelines.textured)
        var used: [MetalFrame] = []
        for card in cards {
            guard let frame = card.frame ?? retained[card.identity] else { continue }
            let uv = contentUV(of: frame)
            var uniforms = ShaderSource.DrawUniforms(tint: SIMD4<Float>(1, 1, 1, card.opacity), uvRect: uv)
            encoder.setViewport(viewport(card.imageRect, viewBounds: viewBounds, scale: scale))
            encoder.setFragmentTexture(frame.texture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ShaderSource.DrawUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            used.append(frame)
        }
        encoder.endEncoding()

        let bufferID = pool.allocateBufferID()
        if !used.isEmpty { pool.retain(used, for: bufferID) }
        commandBuffer.addCompletedHandler { [weak self] finished in
            guard let self else { return }
            self.pool.release(bufferID: bufferID)
            // 完成回调在系统线程：只更新计数与首错文本，不每帧写日志。
            if let error = finished.error {
                self.bump { $0.gpuErrors += 1 }
                self.noteFailure(error.localizedDescription)
            }
        }
        // 一个 drawable 至多 present 一次；未 present 的 drawable 不会上屏（R02 的原始缺陷）。
        commandBuffer.present(drawable)
        bump { $0.presents += 1 }
        commandBuffer.commit()
    }

    private func bump(_ mutate: (inout Counters) -> Void) {
        diagnosticsLock.lock()
        mutate(&counters)
        diagnosticsLock.unlock()
    }

    private func noteFailure(_ text: String) {
        diagnosticsLock.lock()
        counters.lastGPUError = text
        let shouldLog = !counters.didLogGPUError
        counters.didLogGPUError = true
        diagnosticsLock.unlock()
        // 只在首错时落一条日志，避免每帧刷屏（方案 §4.2）。
        if shouldLog {
            VistileLog.ui.log("[renderer] 绘制失败：\(text, privacy: .public)")
        }
    }

    private func viewport(_ rect: CGRect, viewBounds: CGRect, scale: CGFloat) -> MTLViewport {
        MetalGeometry.viewport(for: MetalGeometry.pixelRect(cgRect: rect.standardized,
                                                           containerHeight: viewBounds.height,
                                                           scale: scale))
    }

    /// contentRect 与像素尺寸同单位；缺元数据时用整幅，禁止把点当像素（方案 §9.2）。
    private func contentUV(of frame: MetalFrame) -> SIMD4<Float> {
        let meta = frame.meta
        guard meta.contentRect.width > 0, meta.contentRect.height > 0 else { return SIMD4<Float>(0, 0, 1, 1) }
        return MetalGeometry.uvRect(contentRect: meta.contentRect,
                                    pixelSize: CGSize(width: meta.pixelWidth, height: meta.pixelHeight))
    }
}
