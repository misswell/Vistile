import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import VistileCore

/// 过渡代理窗口：只承载动画层，不拥有真实窗口，也不接管输入。
/// 动画层能否稳定盖住真实窗口属于 P0 待验证能力，验证前不得当作已完成（方案 §10.2）。
final class TransitionProxyWindow: NSWindow {
    let proxyView: TransitionProxyView

    init(screenFrame: CGRect, metal: MetalContext) {
        proxyView = TransitionProxyView(frame: CGRect(origin: .zero, size: screenFrame.size), metal: metal)
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = proxyView
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
}

/// 用 Metal 把卡片画面从格子矩形插值到真实窗口矩形。
/// 宽高比不同：容器矩形插值 + 内容等比适配 + 短交叉淡化，禁止非均匀拉伸（方案 §10.2.5）。
final class TransitionProxyView: NSView {
    let metalLayer = CAMetalLayer()
    private var renderer: OverviewRenderer?
    private var heldFrame: MetalFrame?
    private var ticker: Timer?
    /// 动画起点用单调时钟（方案 §20.2）：`Date()` 是墙钟，NTP 步进或用户改表会把进行中的动画
    /// 一次性推完或拉回去——那正好是 §16 要排除的"回跳"，不能让计时器自己制造它。
    private var startStamp = CACurrentMediaTime()
    private var duration: TimeInterval = 0.24
    private var startRect: CGRect = .zero
    private var endRect: CGRect = .zero
    private var startAlpha: CGFloat = 1
    private var endAlpha: CGFloat = 1
    private var sourceAspect: CGFloat = 1.6
    /// CG 全局原点到视图左下的换算基准；代理只吃 CG 全局矩形，内部统一翻转一次。
    private var originInCG = CGPoint.zero
    var onComplete: (() -> Void)?

    init(frame frameRect: NSRect, metal: MetalContext) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        // 与总览、捕获纹理同一台设备：自建 device 会让 drawable 与纹理不兼容，代理一帧都画不出来。
        ImmediateLayerUpdates.configure(metalLayer)
        metalLayer.device = metal.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        // 视图还没进窗口，拿不到屏的倍率：先用保守值，真实倍率由 configure(scale:) 传入。
        metalLayer.contentsScale = 2
        layer?.addSublayer(metalLayer)
        // 代理必须透出真实画面，透明底色让位于卡片矩形之外的区域不被涂黑。
        renderer = OverviewRenderer(metal: metal)
        renderer?.background = SIMD4<Float>(0, 0, 0, 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(cgOrigin: CGPoint, scale: CGFloat) {
        originInCG = cgOrigin
        metalLayer.contentsScale = max(1, scale)
    }

    /// 动画保存的像素宽高比应取有效捕获内容/真实源窗口比例（由调用方传入）。
    func setSource(_ source: MetalFrame?, sourceAspect: CGFloat) {
        heldFrame = source
        self.sourceAspect = max(0.2, sourceAspect)
    }

    /// 动画是否仍在跑：打断续接必须据此选择起点，而不是从上一次起点重启。
    private(set) var isAnimating = false

    /// 动画被打断时从当前矩形继续，而不是从旧起点跳回（方案 §7）。
    func currentRect() -> CGRect { currentAnimationRect }

    private(set) var currentAnimationRect: CGRect = .zero
    /// 当前画面在 CG 全局坐标里的位置，供打断时接续。
    private(set) var currentRectInCG: CGRect = .zero

    /// 减少动态效果时不做几何插值，只在终点做短淡化。
    enum AnimationMode { case scale, fade }

    func animate(fromCG source: CGRect,
                 toCG destination: CGRect,
                 durationMS: Int,
                 reverse: Bool,
                 mode: AnimationMode = .scale,
                 startAlpha: CGFloat = 1,
                 endAlpha: CGFloat = 1) {
        // reverse 只影响调用方的语义（展开/收回），矩形与 alpha 插值本身是对称的。
        _ = reverse
        ticker?.invalidate()
        animationMode = mode
        startRect = viewRect(source)
        endRect = viewRect(destination)
        currentAnimationRect = startRect
        currentRectInCG = source
        startStamp = CACurrentMediaTime()
        duration = max(0.016, TimeInterval(durationMS) / 1000)
        self.startAlpha = startAlpha
        self.endAlpha = endAlpha
        metalLayer.opacity = Float(startAlpha)
        isAnimating = true
        let next = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.tick()
        }
        ticker = next
        RunLoop.main.add(next, forMode: .common)
    }

    func stop() {
        ticker?.invalidate()
        ticker = nil
        isAnimating = false
    }

    private var animationMode: AnimationMode = .scale

    private func tick() {
        let elapsed = CACurrentMediaTime() - startStamp
        let progress = min(1, elapsed / duration)
        let eased = easeInOut(progress)
        // fade：矩形固定在终点，只有 alpha 变化；"声称淡化"就必须真的改 alpha。
        let container = animationMode == .fade
            ? endRect
            : interpolatedRect(from: startRect, to: endRect, progress: CGFloat(eased))
        currentAnimationRect = container
        currentRectInCG = cgRect(fromView: container)
        let alpha = startAlpha + (endAlpha - startAlpha) * CGFloat(eased)
        metalLayer.opacity = Float(alpha)

        let content = aspectFit(sourceAspect: sourceAspect, in: container)
        guard let renderer else { return }
        let viewBounds = CGRect(origin: .zero, size: bounds.size)
        let cards = [CardDraw(identity: CardDraw.proxyIdentity,
                              imageRect: content,
                              opacity: Float(alpha),
                              frame: heldFrame)]
        renderer.draw(layer: metalLayer,
                      cards: cards,
                      placeholders: [],
                      viewBounds: viewBounds,
                      scale: max(1, metalLayer.contentsScale))
        if progress >= 1 {
            stop()
            onComplete?()
        }
    }

    /// 代理视图没有把 bounds 传给图层就没有任何可见像素。
    override func layout() {
        super.layout()
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
    }

    private func viewRect(_ cgRect: CGRect) -> CGRect {
        CGRect(x: cgRect.minX - originInCG.x,
               y: (bounds.height + originInCG.y) - cgRect.maxY,
               width: cgRect.width,
               height: cgRect.height)
    }

    private func cgRect(fromView rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + originInCG.x,
               y: (originInCG.y + bounds.height) - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// 容器矩形插值：允许宽高比变化，内容按等比例适配后再短交叉淡化。
    private func interpolatedRect(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    private func aspectFit(sourceAspect: CGFloat, in container: CGRect) -> CGRect {
        let containerAspect = container.width / max(1, container.height)
        if sourceAspect >= containerAspect {
            let height = container.width / max(0.0001, sourceAspect)
            return CGRect(x: container.minX, y: container.midY - height / 2, width: container.width, height: height)
        }
        let width = container.height * sourceAspect
        return CGRect(x: container.midX - width / 2, y: container.minY, width: width, height: container.height)
    }
}
