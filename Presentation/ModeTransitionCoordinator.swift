import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import VistileCore

/// 过渡承载窗口：只承载动画层，不拥有真实窗口，也不接管输入（方案 §10.6）。
/// 只在动画期间存在（进入/返回/交换合计不超过约 400ms，最长保持也受状态机限时约束），
/// 忽略鼠标、不获取 key，画完立刻隐藏。
final class TransitionCarrierWindow: NSWindow {
    let carrierView: TransitionCarrierView

    init(screenFrame: CGRect, metal: MetalContext) {
        carrierView = TransitionCarrierView(frame: CGRect(origin: .zero, size: screenFrame.size), metal: metal)
        super.init(contentRect: screenFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = carrierView
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Only the focus panel owns this chrome. Geometry follows Metal's panel rect;
/// Core Animation moves colors, never a rotated rectangle or a CPU-driven clock.
@MainActor
final class TransitionFocusGlow {
    enum Phase { case idle, playing, holding, fading }
    enum Quality { case flowing, staticRim }

    struct Environment {
        var lowPower: Bool
        var thermalState: ProcessInfo.ThermalState

        static var current: Environment {
            Environment(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                        thermalState: ProcessInfo.processInfo.thermalState)
        }

        var requiresStaticRim: Bool { lowPower || thermalState != .nominal }
    }

    let container = CALayer()
    private let rim = CAGradientLayer()
    private let halo = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let haloMask = CAShapeLayer()
    private(set) var phase: Phase = .idle
    private(set) var quality: Quality = .staticRim
    /// Panel outline in carrier-view coordinates, excluding the halo's padding.
    private(set) var bounds: CGRect?
    private(set) var cornerRadius: CGFloat = 0
    private var animationBudget: TimeInterval = 0
    private var fadeFromOpacity: Float = 0
    private static let animationKey = "focus.colors"
    private static let haloPadding: CGFloat = 8
    private static let palette: [CGColor] = {
        let values: [UInt32] = [0x55DDF5, 0x668AFF, 0xBA86FF, 0xF58BB9, 0xF5B583]
        return values.map { hex in
            let red = CGFloat((hex >> 16) & 0xff) / 255
            let green = CGFloat((hex >> 8) & 0xff) / 255
            let blue = CGFloat(hex & 0xff) / 255
            return CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }()

    var isActive: Bool { bounds != nil && !container.isHidden }
    var isAnimating: Bool {
        rim.animation(forKey: Self.animationKey) != nil || halo.animation(forKey: Self.animationKey) != nil
    }

    init() {
        ImmediateLayerUpdates.configure(container, rim, halo, rimMask, haloMask)
        container.name = "transition.focusGlow"
        container.zPosition = 1
        container.isHidden = true
        // Masks leave the panel interior completely clear. Only the broad rim's
        // alpha is blurred; no full-panel filter, raster cache or animated path.
        for (gradient, mask) in [(halo, haloMask), (rim, rimMask)] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            gradient.colors = Self.palette + [Self.palette[0]]
            gradient.locations = [0, 0.2, 0.4, 0.6, 0.8, 1]
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 1, alpha: 1)
            gradient.mask = mask
            container.addSublayer(gradient)
        }
        rimMask.lineWidth = 1.5
        // A wide, low-opacity band reads as a soft bloom on dark panels without
        // a per-frame blur filter or a monochrome layer shadow.
        haloMask.lineWidth = 10
        halo.opacity = 0.55
    }

    func prepare(scene: TransitionScene, environment: Environment, budget: TimeInterval) {
        stop()
        phase = .playing
        quality = scene.fadeOnly || scene.level != .full || environment.requiresStaticRim ? .staticRim : .flowing
        animationBudget = budget
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for gradient in [rim, halo] { gradient.colors = Self.palette + [Self.palette[0]] }
        halo.isHidden = quality == .staticRim
        CATransaction.commit()
    }

    func update(rect: CGRect?, cornerRadius: CGFloat, opacity: CGFloat, scale: CGFloat) {
        guard phase == .playing || phase == .holding else { return }
        guard let rect, rect.width > 1, rect.height > 1, opacity > 0.01 else {
            removeAnimations()
            bounds = nil
            container.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
        if bounds != rect || self.cornerRadius != radius {
            bounds = rect
            self.cornerRadius = radius
            container.frame = rect
            rim.frame = container.bounds
            halo.frame = container.bounds.insetBy(dx: -Self.haloPadding, dy: -Self.haloPadding)
            rimMask.frame = rim.bounds
            haloMask.frame = halo.bounds
            let inset = rimMask.lineWidth / 2
            rimMask.path = CGPath(roundedRect: rim.bounds.insetBy(dx: inset, dy: inset),
                                  cornerWidth: max(0, radius - inset), cornerHeight: max(0, radius - inset), transform: nil)
            // Push the bloom just outside the panel so it reads as light leaving the edge.
            let haloRect = halo.bounds.insetBy(dx: Self.haloPadding / 2, dy: Self.haloPadding / 2)
            haloMask.path = CGPath(roundedRect: haloRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        for layer in [container, rim, halo, rimMask, haloMask] { layer.contentsScale = scale }
        container.opacity = Float(min(1, max(0, opacity)))
        container.isHidden = false
        CATransaction.commit()
        if quality == .flowing, !isAnimating { startColorFlow() }
    }

    func hold(environment: Environment) {
        guard phase == .playing else { return }
        phase = .holding
        if environment.requiresStaticRim { useStaticRim() }
    }

    /// Pressure notifications also reach a held panel without waking Metal.
    func reduceForEnvironment(_ environment: Environment) {
        guard phase == .playing || phase == .holding, environment.requiresStaticRim else { return }
        useStaticRim()
    }

    func beginFade() {
        guard phase != .idle else { return }
        phase = .fading
        removeAnimations()
        fadeFromOpacity = container.opacity
    }

    func fade(progress: CGFloat) {
        guard phase == .fading else { return }
        container.opacity = fadeFromOpacity * Float(1 - min(1, max(0, progress)))
    }

    func stop() {
        removeAnimations()
        container.isHidden = true
        container.opacity = 0
        bounds = nil
        phase = .idle
    }

    private func useStaticRim() {
        removeAnimations()
        quality = .staticRim
        halo.isHidden = true
    }

    private func startColorFlow() {
        // Cyclic color stops close the conic seam without ever rotating the mask.
        let colors = Self.palette
        let frames: [[CGColor]] = (0...colors.count).map { offset in
            let rotated = (0..<colors.count).map { colors[($0 + offset) % colors.count] }
            return rotated + [rotated[0]]
        }
        let animation = CAKeyframeAnimation(keyPath: "colors")
        animation.values = frames
        animation.duration = 4.2
        animation.calculationMode = .linear
        // Finite even if the host never gets another run-loop callback.
        animation.repeatDuration = max(0.016, animationBudget)
        for gradient in [rim, halo] { gradient.add(animation, forKey: Self.animationKey) }
    }

    private func removeAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for gradient in [rim, halo] {
            if let colors = (gradient.presentation() as? CAGradientLayer)?.colors { gradient.colors = colors }
        }
        for layer in [container, rim, halo, rimMask, haloMask] { layer.removeAllAnimations() }
        CATransaction.commit()
    }
}

/// 在一层短时透明 Metal 层里合成所有参与画面（方案 §10.6）：
/// 卡片容器按 ease-out 插值、内容等比适配、底板随飞行淡出；真实窗口是否到位不阻塞动画，
/// 到点后保持稳定并显示「正在切换」，等 confirm（真实窗口验证通过/提交）再短淡化交接。
/// 时间轴由 CADisplayLink 驱动，按真实 elapsed time 推进；静止或等待期间不发 tick。
final class TransitionCarrierView: NSView {
    let metalLayer = CAMetalLayer()
    let focusGlow = TransitionFocusGlow()
    /// Sampled at play/hold and on system pressure notifications, never per frame.
    var glowEnvironment: () -> TransitionFocusGlow.Environment = { .current }

    private var renderer: OverviewRenderer?
    private var originInCG = CGPoint.zero
    private(set) var scene: TransitionScene?
    /// 本段场景自带的令牌（`play` 时绑定，`stopNow` 时清空）。
    /// 完成回调必须回报它，不能在回调时刻去读协调器的"当前令牌"——
    /// 那已经是新场景的令牌，旧场景的迟到完成会替新场景提交状态（方案 §16.2）。
    private(set) var playingToken: TransitionToken?

    private struct CardState {
        var start: CGRect
        var end: CGRect
        var cellStart: CGRect?
        var cellEnd: CGRect?
        /// 面板（卡片外框）的显式端点：场景给出就优先用它，否则按底板/画面矩形推导。
        var panelFrom: CGRect?
        var panelTo: CGRect?
        var startAlpha: CGFloat
        var endAlpha: CGFloat
        var aspect: CGFloat
        var fadeFraction: CGFloat
        var frame: MetalFrame?
    }

    private var states: [WindowIdentity: CardState] = [:]
    private var drawOrder: [WindowIdentity] = []
    private var focusIdentity: WindowIdentity?

    private enum Phase { case idle, playing, holding, fading }
    private var phase: Phase = .idle
    private(set) var lastProgress: CGFloat = 0
    private var startTimestamp: CFTimeInterval = 0
    private var duration: TimeInterval = 0.24
    private var fadeStartTimestamp: CFTimeInterval = 0
    private var fadeDuration: TimeInterval = 0.11
    private var fadeFrom: CGFloat = 1
    private var backdropFrom: CGFloat = 0
    private var currentBackdropAlpha: CGFloat = 0
    /// 打断续接：上一次 tick 落在屏幕上的画面矩形与透明度（CG 全局）。
    private var presentedRects: [WindowIdentity: CGRect] = [:]
    private var presentedAlphas: [WindowIdentity: CGFloat] = [:]
    /// 上一次 tick 真正画出去的面板矩形（CG 全局）。只读观察点：
    /// 宿主测试据此证明"飞行画的是面板、不是被放大的捕获图"。
    private(set) var presentedPanelRects: [WindowIdentity: CGRect] = [:]
    private(set) var presentedFlow: FlowDraw?

    private var displayLink: CADisplayLink?
    private let tickBridge = TickBridge()
    private var lastTickAt: CFTimeInterval = 0
    /// 本段场景飞行期间的帧间隔样本（ms）；播放结束按场景给出 P95 与掉帧事实（方案 §20.3）。
    private var frameIntervalsMS: [Double] = []
    /// 本段场景每帧的绘制耗时（ms）：把"画得慢"与"主线程被占住"区分开。
    private var renderTimesMS: [Double] = []
    /// 首帧延迟的锚点：真实输入的时刻（方案 §20.2）。用 play() 自己的进入时间会把
    /// "点击后卡在目录复核里几百毫秒才起动画"这段洗掉。
    private var firstPresentAnchor: CFTimeInterval = 0
    /// 锚点是否来自真实输入（false = 没有前置点击，按 play() 进入时刻算）。
    private var anchorIsRealInput = false
    /// 本段开始时渲染器的 present 计数，用于算出这一段真正呈现了多少帧。
    private var presentationTracker: TransitionPresentationTracker?
    private var frameBudgetMS = FrameIntervalStats.defaultFrameBudgetMS
    private var didLogSevereFrame = false
    private var tickCount = 0
    private var rearmTimer: Timer?
    // Read-only timer handles let host tests fire real deadline paths without sleeping.
    private(set) var holdLabelTimer: Timer?
    private(set) var holdDeadlineTimer: Timer?
    private(set) var sceneDeadlineTimer: Timer?
    private var timerGeneration: UInt64 = 0
    private let holdBadge = CALayer()
    private let holdLabel = CATextLayer()
    private(set) var renderCount = 0
    var metalPresentCount: Int { renderer?.diagnostics().presents ?? 0 }
    var metalSubmissionCount: Int { renderer?.diagnostics().submissions ?? 0 }
    var hasDisplayLink: Bool { displayLink != nil }
    var isHoldIndicatorVisible: Bool { !holdBadge.isHidden || !holdLabel.isHidden }

    var onReachedEnd: ((TransitionToken) -> Void)?
    var onFinished: ((TransitionToken) -> Void)?
    /// 一段飞行的帧间隔统计（方案 §20.3）：每次过渡结束后给一次，供诊断与降级决策。
    var onFlightStats: ((TransitionScene.Kind, FrameIntervalStats) -> Void)?
    /// Display-link timing is useful for diagnosis, but is not presentation evidence.
    var onTickStats: ((TransitionScene.Kind, FrameIntervalStats) -> Void)?
    /// 一段飞行的呈现事实（方案 §20.2）：首帧延迟与实际 present 次数，每次飞行到位给一次。
    var onFlightFacts: ((TransitionScene.Kind, TransitionFlightFacts) -> Void)?

    var isPlaying: Bool { phase == .playing }
    var isHolding: Bool { phase == .holding }
    var isIdle: Bool { phase == .idle }

    /// 保持阶段的兜底：超过它就不再占着屏幕等状态机（状态机自身限时 2.5s，这里留 100ms 余量）。
    private static let holdDeadlineMS = 2400
    private static let handoffFadeMS = 110

    init(frame frameRect: NSRect, metal: MetalContext) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        ImmediateLayerUpdates.configure(metalLayer, holdBadge, holdLabel)
        metalLayer.device = metal.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = 2
        metalLayer.zPosition = 0
        layer?.addSublayer(metalLayer)
        layer?.addSublayer(focusGlow.container)
        // 参与画面全部由这一台渲染器合成；底色透明，未覆盖处透出真实窗口与桌面。
        renderer = OverviewRenderer(metal: metal)
        renderer?.background = SIMD4<Float>(0, 0, 0, 0)
        tickBridge.view = self
        setupHoldChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(cgOrigin: CGPoint, scale: CGFloat) {
        originInCG = cgOrigin
        metalLayer.contentsScale = max(1, scale)
    }

    // MARK: - 播放

    /// 播放一段场景。起点优先取"此刻屏幕上的呈现矩形"（打断续接），其次才是计划起点（方案 §10.4）。
    /// - Parameter anchorAt: 真实输入时刻（单调时钟），只用于首帧延迟；不给就按本方法进入时刻算。
    func play(_ scene: TransitionScene, sources: [WindowIdentity: MetalFrame], anchorAt: CFTimeInterval? = nil,
              startAt: CFTimeInterval? = nil) {
        let interrupting = phase != .idle
        // Keep presented geometry for continuation, but never inherit old chrome or callbacks.
        stopClock()
        stopTimers()
        hideHoldIndicator()
        stopGlow()
        self.scene = scene
        // 令牌与场景一起绑定：之后的每个回调都只报这个令牌，绝不在回调时刻回看协调器状态（方案 §16.2）。
        self.playingToken = scene.token
        states.removeAll()
        drawOrder = []
        focusIdentity = nil
        for card in scene.cards {
            var startRect = card.start
            var startAlpha = card.startAlpha
            if !scene.isStationarySwap, let presented = presentedRects[card.identity] {
                startRect = presented
                startAlpha = presentedAlphas[card.identity] ?? startAlpha
            }
            states[card.identity] = CardState(start: viewRect(startRect),
                                              end: viewRect(card.end ?? startRect),
                                              cellStart: card.cellStart.map { viewRect($0) },
                                              cellEnd: card.cellEnd.map { viewRect($0) },
                                              panelFrom: (scene.isStationarySwap ? card.panelFrom : (presentedPanelRects[card.identity] ?? card.panelFrom)).map { viewRect($0) },
                                              panelTo: card.panelTo.map { viewRect($0) },
                                              startAlpha: startAlpha,
                                              endAlpha: card.endAlpha,
                                              aspect: card.aspect,
                                              fadeFraction: card.fadeFraction,
                                              frame: sources[card.identity])
            if card.isFocus { focusIdentity = card.identity }
        }
        // 聚焦卡片最后画：飞行中它始终压在其它卡片之上，与"它要去主区"的语义一致。
        drawOrder = scene.cards.filter { !$0.isFocus }.map(\.identity) + scene.cards.filter(\.isFocus).map(\.identity)
        backdropFrom = interrupting
            ? currentBackdropAlpha
            : TransitionTimeline.backdropAlpha(scene.backdrop, progress: 0)
        duration = max(0.016, TimeInterval(scene.durationMS) / 1000)
        lastProgress = 0
        frameIntervalsMS.removeAll()
        renderTimesMS.removeAll()
        firstPresentAnchor = anchorAt ?? CACurrentMediaTime()
        anchorIsRealInput = anchorAt != nil
        presentationTracker?.close(ticks: tickCount)
        tickCount = 0
        didLogSevereFrame = false
        // Until the display link provides a real callback interval, use the
        // conservative 60 Hz default. maximumFramesPerSecond is only a display
        // capability and does not describe the cadence this scene receives.
        frameBudgetMS = FrameIntervalStats.defaultFrameBudgetMS
        let kind = scene.kind
        presentationTracker = TransitionPresentationTracker(
            anchor: firstPresentAnchor, anchoredAtRealInput: anchorIsRealInput,
            frameBudgetMS: frameBudgetMS) { [weak self] facts, stats in
                self?.onFlightFacts?(kind, facts)
                if let stats { self?.onFlightStats?(kind, stats) }
            }
        metalLayer.opacity = 1
        phase = .playing
        // 起点可注入：宿主测试要拿"进度恰好 0.5"这种确切刻度断言，不能拿 play() 内部的
        // CACurrentMediaTime() 与测试自己读的那次抢时间——机器一慢，中点就跑到终点之后。
        startTimestamp = startAt ?? CACurrentMediaTime()
        lastTickAt = 0
        renderCount = 0
        if case .panel = scene.content, focusIdentity != nil {
            focusGlow.prepare(scene: scene, environment: glowEnvironment(), budget: duration + 2.6)
            observeGlowPressure()
        }
        render(progress: 0)
        startClock()
        scheduleRearm()
        scheduleSceneDeadline(budget: duration + 2.6)
        VistileLog.ui.log("[过渡] 播放 \(scene.kind.displayName, privacy: .public)：\(scene.cards.count) 张卡片，\(scene.durationMS)ms")
    }

    /// 画面源在飞行中更新：只换纹理与比例，不改时间轴。仅 `.captured` 诊断回退用得到。
    func updateSource(_ identity: WindowIdentity, frame: MetalFrame, aspect: CGFloat) {
        guard var state = states[identity] else { return }
        state.frame = frame
        state.aspect = aspect
        states[identity] = state
        guard phase == .playing || phase == .holding || phase == .fading else { return }
        render(progress: lastProgress)
    }

    // MARK: - 交接与结束

    /// 短淡化交接：真实窗口已验证（或已提交）后整层淡出（方案 §10.1）。
    func beginFade(durationMS: Int = TransitionCarrierView.handoffFadeMS, startAt: CFTimeInterval? = nil) {
        guard phase == .playing || phase == .holding else { return }
        stopTimers()
        hideHoldIndicator()
        stopObservingGlowPressure()
        focusGlow.beginFade()
        fadeFrom = CGFloat(metalLayer.opacity)
        fadeStartTimestamp = startAt ?? CACurrentMediaTime()
        fadeDuration = max(0.016, TimeInterval(durationMS) / 1000)
        phase = .fading
        startClock()
        scheduleSceneDeadline(budget: fadeDuration + 1.0)
    }

    /// 立即结束：不交接也没有过渡（隐藏、屏移除）。屏幕上的事实不再存在。
    func finalizePresentationFacts() {
        presentationTracker?.close(ticks: tickCount)
    }

    func stopNow() {
        presentationTracker?.close(ticks: tickCount)
        presentationTracker = nil
        stopClock()
        stopTimers()
        hideHoldIndicator()
        stopGlow()
        phase = .idle
        metalLayer.opacity = 1
        presentedRects.removeAll()
        presentedAlphas.removeAll()
        presentedPanelRects.removeAll()
        presentedFlow = nil
        states.removeAll()
        scene = nil
        focusIdentity = nil
        playingToken = nil
    }

    private func finishNow() {
        stopClock()
        stopTimers()
        hideHoldIndicator()
        stopGlow()
        phase = .idle
        metalLayer.opacity = 1
        // 只报本段场景自己的令牌：这一刻协调器可能已经在放下一段（方案 §16.2）。
        let token = playingToken
        playingToken = nil
        if let token { onFinished?(token) }
    }

    // MARK: - 时钟

    fileprivate func handleTick(_ link: CADisplayLink) {
        // Use the actual callback budget; ProMotion may run below the display's maximum rate.
        let actualBudget = (link.targetTimestamp - link.timestamp) * 1000
        if actualBudget.isFinite, actualBudget > 0 {
            frameBudgetMS = actualBudget
            presentationTracker?.updateFrameBudget(milliseconds: actualBudget)
        }
        advance(to: link.targetTimestamp)
    }

    /// 时间轴推进：真实播放由 CADisplayLink 调，测试用给定时间戳驱动同一段代码。
    func advance(to timestamp: CFTimeInterval) {
        let previousTick = lastTickAt
        lastTickAt = timestamp
        let now = timestamp
        switch phase {
        case .playing:
            tickCount += 1
            // 第一个 tick 没有参考间隔；其余按真实到帧时间记样本（方案 §20.3）。
            if previousTick > 0 {
                let gapMS = (timestamp - previousTick) * 1000
                frameIntervalsMS.append(gapMS)
                if gapMS > max(100, frameBudgetMS * 6), !didLogSevereFrame, let scene {
                    didLogSevereFrame = true
                    let progressPercent = Int(min(100, max(0, (now - startTimestamp) / max(0.001, duration) * 100)))
                    VistileLog.session.log(level: .info,
                                           "[帧] 慢帧 场景=\(scene.kind.displayName, privacy: .public) 间隔=\(String(format: "%.2f", gapMS), privacy: .public)ms 进度=\(progressPercent)%")
                }
            }
            let raw = duration > 0 ? (now - startTimestamp) / duration : 1
            let progress = CGFloat(min(1, max(0, raw)))
            let renderStarted = CACurrentMediaTime()
            render(progress: progress)
            renderTimesMS.append((CACurrentMediaTime() - renderStarted) * 1000)
            if progress >= 1 {
                phase = .holding
                stopClock()
                rearmTimer?.invalidate()
                rearmTimer = nil
                focusGlow.hold(environment: glowEnvironment())
                // 呈现事实只算这一段：tick 次数与 present 增量并列报告，谁也不替谁（方案 §20.2）。
                if let scene {
                    presentationTracker?.finish(ticks: tickCount)
                    if let stats = FrameIntervalStats.measure(frameIntervalsMS, frameBudgetMS: frameBudgetMS) {
                        onTickStats?(scene.kind, stats)
                    }
                    if let renderStats = FrameIntervalStats.measure(renderTimesMS) {
                        let renderP95 = String(format: "%.2f", renderStats.p95MS)
                        let intervalP95 = String(format: "%.2f", FrameIntervalStats.measure(frameIntervalsMS, frameBudgetMS: frameBudgetMS)?.p95MS ?? 0)
                        let sampleCount = renderStats.count
                        let gaps = FrameIntervalStats.measure(frameIntervalsMS, frameBudgetMS: frameBudgetMS)
                        let slowCount = frameIntervalsMS.filter {
                            $0 > FrameIntervalStats.slowFrameThreshold(frameBudgetMS: frameBudgetMS)
                        }.count
                        let gapP99 = String(format: "%.2f", gaps?.p99MS ?? 0)
                        let maximum = String(format: "%.2f", gaps?.maximumMS ?? 0)
                        VistileLog.session.log(level: .info,
                                               "[帧] 场景=\(scene.kind.displayName, privacy: .public) 绘制p95=\(renderP95, privacy: .public)ms 回调p95=\(intervalP95, privacy: .public)ms p99=\(gapP99, privacy: .public)ms max=\(maximum, privacy: .public)ms slow=\(slowCount) n=\(sampleCount, privacy: .public)")
                    }
                }
                // 到位事件也只属于本段场景：协调器据此判断它是否仍然是当前令牌（方案 §16.2）。
                if let token = playingToken { onReachedEnd?(token) }
                // 宿主可能在这一刻就完成交接（返回总览：总览面板显示后立刻淡出）。
                if phase == .holding { scheduleHoldChecks() }
            }
        case .fading:
            let raw = fadeDuration > 0 ? (now - fadeStartTimestamp) / fadeDuration : 1
            let t = CGFloat(min(1, max(0, raw)))
            metalLayer.opacity = Float(fadeFrom * (1 - t))
            focusGlow.fade(progress: t)
            if t >= 1 { finishNow() }
        case .idle, .holding:
            break
        }
    }

    private func startClock() {
        guard displayLink == nil else { return }
        let link = self.displayLink(target: tickBridge, selector: #selector(TickBridge.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 视图不在任何屏幕上时 displayLink 不会回调：250ms 后还没 tick 就重新取一次显示时钟。
    private func scheduleRearm() {
        rearmTimer?.invalidate()
        let generation = timerGeneration
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self, self.timerGeneration == generation else { return }
            guard self.phase == .playing, self.lastTickAt == 0 else { return }
            self.stopClock()
            self.startClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        rearmTimer = timer
    }

    /// 场景绝对限时：任何回调丢失都不许让承载层无限期留在屏幕上。
    private func scheduleSceneDeadline(budget: TimeInterval) {
        sceneDeadlineTimer?.invalidate()
        let generation = timerGeneration
        let timer = Timer(timeInterval: budget, repeats: false) { [weak self] _ in
            guard let self, self.timerGeneration == generation, self.phase != .idle else { return }
            VistileLog.ui.log("[过渡] 承载层超过限时，按结束处理")
            self.finishNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        sceneDeadlineTimer = timer
    }

    private func scheduleHoldChecks() {
        holdLabelTimer?.invalidate()
        let generation = timerGeneration
        // 大多数等待只有几十毫秒：先安静一会儿，超过 350ms 才显示「正在切换」。
        let label = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.timerGeneration == generation, self.phase == .holding else { return }
            self.showHoldIndicator()
        }
        RunLoop.main.add(label, forMode: .common)
        holdLabelTimer = label

        holdDeadlineTimer?.invalidate()
        let deadline = Timer(timeInterval: TimeInterval(Self.holdDeadlineMS) / 1000, repeats: false) { [weak self] _ in
            guard let self, self.timerGeneration == generation, self.phase == .holding else { return }
            VistileLog.ui.log("[过渡] 真实窗口未在限时内到位，收起承载层")
            self.beginFade(durationMS: 140)
        }
        RunLoop.main.add(deadline, forMode: .common)
        holdDeadlineTimer = deadline
    }

    private func stopTimers() {
        timerGeneration &+= 1
        rearmTimer?.invalidate()
        rearmTimer = nil
        holdLabelTimer?.invalidate()
        holdLabelTimer = nil
        holdDeadlineTimer?.invalidate()
        holdDeadlineTimer = nil
        sceneDeadlineTimer?.invalidate()
        sceneDeadlineTimer = nil
    }

    // MARK: - Focus chrome pressure (notification-driven, no polling)

    private func observeGlowPressure() {
        NotificationCenter.default.addObserver(self, selector: #selector(glowPressureDidChange(_:)),
                                               name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(glowPressureDidChange(_:)),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    private func stopObservingGlowPressure() {
        NotificationCenter.default.removeObserver(self, name: .NSProcessInfoPowerStateDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @objc nonisolated private func glowPressureDidChange(_ notification: Notification) {
        // System notifications need not arrive on the main thread. Re-sample the
        // current scene/environment on main rather than retaining an old scene.
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refreshGlowPressure() }
        } else {
            MainActor.assumeIsolated { refreshGlowPressure() }
        }
    }

    private func refreshGlowPressure() {
        focusGlow.reduceForEnvironment(glowEnvironment())
    }

    private func stopGlow() {
        stopObservingGlowPressure()
        focusGlow.stop()
    }

    // MARK: - 绘制

    private func render(progress: CGFloat) {
        guard let renderer, let scene else { return }
        renderCount += 1
        lastProgress = progress
        let eased = TransitionTimeline.easeOutCubic(progress)

        var cards: [CardDraw] = []
        var placeholders: [(rect: CGRect, tint: SIMD4<Float>)] = []
        var panels: [PanelDraw] = []
        var flows: [FlowDraw] = []
        cards.reserveCapacity(drawOrder.count)
        placeholders.reserveCapacity(drawOrder.count + 1)
        panels.reserveCapacity(drawOrder.count)
        flows.reserveCapacity(1)

        var backdropAlpha: CGFloat = 0
        if let color = TransitionScene.backdropColor(scene.backdrop) {
            backdropAlpha = backdropFrom + (TransitionTimeline.backdropTargetAlpha(scene.backdrop) - backdropFrom) * eased
            if backdropAlpha > 0.001 {
                placeholders.append((CGRect(origin: .zero, size: bounds.size),
                                     SIMD4<Float>(color.x, color.y, color.z, color.w * Float(backdropAlpha))))
            }
        }
        currentBackdropAlpha = backdropAlpha

        var presented: [WindowIdentity: CGRect] = [:]
        var panelRects: [WindowIdentity: CGRect] = [:]
        presented.reserveCapacity(drawOrder.count)
        panelRects.reserveCapacity(drawOrder.count)
        var glowRect: CGRect?
        var glowRadius: CGFloat = 0
        var glowAlpha: CGFloat = 0
        for identity in drawOrder {
            guard let state = states[identity] else { continue }
            let container: CGRect
            let alpha: CGFloat
            if scene.isStationarySwap {
                container = state.end
                alpha = 1
            } else if scene.fadeOnly {
                // 最简模式：不飞行，卡片固定在终点短淡化（方案 §10.5）。
                container = state.end
                let startAlpha = state.startAlpha == state.endAlpha ? 0 : state.startAlpha
                alpha = startAlpha + (state.endAlpha - startAlpha) * eased
            } else {
                container = TransitionTimeline.interpolate(state.start, state.end, progress: eased)
                let alphaT = TransitionTimeline.alphaProgress(eased, fadeFraction: state.fadeFraction)
                alpha = state.startAlpha + (state.endAlpha - state.startAlpha) * alphaT
            }
            // 呈现矩形与透明度照旧按"画面容器"记账：打断续接、轻量对账、宿主自检都读这一对值。
            presented[identity] = cgRect(fromView: container)
            presentedAlphas[identity] = alpha
            guard alpha > 0.01, container.width > 1, container.height > 1 else { continue }
            switch scene.content {
            case let .panel(style):
                // 面板画在卡片外框（含标题条）上，而不是内容区：它代表"那张卡片"本身。
                // 淡化模式下不飞行：面板直接固定在终点，只有透明度在变（方案 §10.5）。
                let panelRect = scene.fadeOnly
                    ? panelEndRect(state)
                    : TransitionTimeline.interpolate(panelStartRect(state),
                                                     panelEndRect(state),
                                                     progress: eased)
                guard panelRect.width > 1, panelRect.height > 1 else { continue }
                panelRects[identity] = cgRect(fromView: panelRect)
                if identity == focusIdentity {
                    glowRect = panelRect
                    glowRadius = style.cornerRadius
                    glowAlpha = alpha
                    // 到达段让 Metal 流光淡出、边缘光晕淡入，避免到位瞬间亮度跳变。
                    if scene.flow != nil {
                        glowAlpha *= 0.5 + 0.5 * TransitionTimeline.flowSettle(eased)
                    }
                    if let spec = scene.flow {
                        // 场景方向是 CG 全局坐标（y 向下）；着色器在视图本地坐标（y 向上）里取轴。
                        flows.append(FlowDraw(rect: panelRect,
                                              axis: SIMD2<Float>(spec.axis.x, -spec.axis.y),
                                              phase: Float(eased),
                                              bandWidth: Float(TransitionTimeline.flowBandWidth(eased)),
                                              trail: Float(TransitionTimeline.flowTrail(eased)),
                                              intensity: Float(alpha * TransitionTimeline.flowIntensity(eased)),
                                              settle: Float(TransitionTimeline.flowSettle(eased)),
                                              colorA: spec.leading,
                                              colorB: spec.trailing,
                                              cornerRadius: style.cornerRadius))
                    }
                }
                panels.append(PanelDraw(rect: panelRect,
                                        fill: style.fill,
                                        stroke: style.stroke,
                                        strokeWidth: style.strokeWidth,
                                        cornerRadius: style.cornerRadius,
                                        opacity: Float(alpha)))
            case .captured:
                // 诊断回退：底板与放大画面照旧各画一份，与 0.1.25 的观感一致。
                if let cellRect = cellRect(state, progress: eased) {
                    let cellAlpha = cellAlpha(state, progress: eased)
                    if cellAlpha > 0.01 {
                        placeholders.append((cellRect, SIMD4<Float>(0.09, 0.09, 0.10, Float(cellAlpha))))
                    }
                }
                let content = TransitionTimeline.aspectFit(aspect: state.aspect, in: container)
                if let frame = state.frame {
                    cards.append(CardDraw(identity: identity, imageRect: content, opacity: Float(alpha), frame: frame))
                } else {
                    // 还没有纹理：画底板色块，运动本身仍然看得见，不假装有画面。
                    placeholders.append((content, SIMD4<Float>(0.09, 0.09, 0.10, Float(alpha))))
                }
            }
        }
        presentedRects = presented
        presentedPanelRects = panelRects
        presentedFlow = flows.first
        focusGlow.update(rect: glowRect, cornerRadius: glowRadius, opacity: glowAlpha,
                         scale: max(1, metalLayer.contentsScale))
        let tracker = phase == .playing ? presentationTracker : nil
        let submission = renderer.draw(layer: metalLayer,
                      cards: cards,
                      placeholders: placeholders,
                      panels: panels,
                      flows: flows,
                      viewBounds: bounds,
                      scale: max(1, metalLayer.contentsScale),
                      onPresented: { event in
                          Task { @MainActor in tracker?.presented(event) }
                      },
                      onGPUCompleted: { milliseconds in
                          Task { @MainActor in tracker?.completedGPU(milliseconds: milliseconds) }
                      })
        if let submission { tracker?.submitted(submission) }
    }

    /// 预取一块 drawable 并固定 drawableSize：把首次呈现前的分配成本挪到启动/总览阶段。
    /// 只分配不下屏，窗口由协调器在 play 时才 orderFront。
    func prewarm() {
        guard metalLayer.drawableSize.width <= 1 || metalLayer.drawableSize.height <= 1 else { return }
        let scale = max(1, metalLayer.contentsScale)
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale),
                                         height: max(1, bounds.height * scale))
        _ = metalLayer.nextDrawable()
    }

    /// 载具视图没有把 bounds 传给图层就没有任何可见像素。
    override func layout() {
        super.layout()
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
    }

    /// 卡片底板（格子底色）在飞行中的矩形：只有 `.captured` 诊断回退还会画它。
    private func cellRect(_ state: CardState, progress: CGFloat) -> CGRect? {
        if let from = state.cellStart {
            let to = state.cellEnd ?? from
            return TransitionTimeline.interpolate(from, to, progress: progress)
        }
        return state.cellEnd
    }

    private func cellAlpha(_ state: CardState, progress: CGFloat) -> CGFloat {
        if state.cellStart != nil {
            return state.cellEnd == nil ? 1 - progress : 1
        }
        return state.cellEnd != nil ? progress : 0
    }

    /// 面板起点：显式端点 → 底板（格子外框）→ 画面矩形。
    private func panelStartRect(_ state: CardState) -> CGRect {
        state.panelFrom ?? state.cellStart ?? state.start
    }

    /// 面板终点：显式端点 → 底板终点 → 画面终点 → 原地不动（不伪造落点）。
    private func panelEndRect(_ state: CardState) -> CGRect {
        // end 是必填的（`Card.end` 为 nil 时已经在 play 时退化成起点），所以这里是收尾项，不是备选链的一环。
        state.panelTo ?? state.cellEnd ?? state.end
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

    /// 此刻这一身份在屏幕上的画面矩形（CG 全局）。播放层只读观察点：宿主自检与测试用。
    func presentedRect(for identity: WindowIdentity) -> CGRect? {
        presentedRects[identity]
    }

    /// 此刻这一身份的面板矩形（CG 全局）。只读观察点：`.panel` 模式下屏幕上真正画出来的就是它。
    func presentedPanelRect(for identity: WindowIdentity) -> CGRect? {
        presentedPanelRects[identity]
    }

    /// 此刻这一身份在屏幕上的透明度。只读观察点：轻量等级的短交叉淡化据此对账（方案 §20.4）。
    func presentedAlpha(for identity: WindowIdentity) -> CGFloat? {
        presentedAlphas[identity]
    }

    // MARK: - 保持提示

    private func setupHoldChrome() {
        guard holdBadge.superlayer == nil else { return }
        holdBadge.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        holdBadge.cornerRadius = 9
        holdBadge.isHidden = true
        holdBadge.zPosition = 2
        layer?.addSublayer(holdBadge)
        holdLabel.string = "正在切换…"
        holdLabel.font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 12, nil)
        holdLabel.fontSize = 12
        holdLabel.alignmentMode = .center
        holdLabel.foregroundColor = NSColor.white.withAlphaComponent(0.92).cgColor
        holdLabel.isHidden = true
        holdLabel.contentsScale = 2
        holdLabel.zPosition = 3
        layer?.addSublayer(holdLabel)
    }

    private func showHoldIndicator() {
        guard phase == .holding else { return }
        let anchor: CGRect
        if let focus = focusIdentity, let state = states[focus] {
            anchor = TransitionTimeline.interpolate(state.start, state.end, progress: 1)
        } else {
            anchor = CGRect(origin: .zero, size: bounds.size)
        }
        let width: CGFloat = 108
        let height: CGFloat = 26
        holdBadge.frame = CGRect(x: anchor.midX - width / 2, y: anchor.midY - height / 2, width: width, height: height)
        holdLabel.frame = CGRect(x: holdBadge.frame.minX, y: holdBadge.frame.minY + height / 2 - 8, width: width, height: 16)
        holdBadge.isHidden = false
        holdLabel.isHidden = false
    }

    private func hideHoldIndicator() {
        holdBadge.isHidden = true
        holdLabel.isHidden = true
    }
}

/// displayLink 的目标桥：避免 CADisplayLink 强引用视图形成环。
private final class TickBridge: NSObject {
    weak var view: TransitionCarrierView?

    @objc func tick(_ link: CADisplayLink) {
        view?.handleTick(link)
    }
}

/// 过渡承载层的生命周期与令牌（方案 §9.2、§10.6）：
/// 会话里同一时刻只有一段过渡；新场景覆盖旧场景时从当前呈现矩形接续，不重放。
@MainActor
final class ModeTransitionCoordinator {
    struct DisplayFacts {
        let cgFrame: CGRect
        let appKitFrame: CGRect
        let scale: CGFloat
    }

    var displayFacts: ((UInt32) -> DisplayFacts?)?
    var textureProvider: ((WindowIdentity) -> MetalFrame?)?
    /// 几何飞行到位的时刻（进入保持态）；返回总览靠它决定何时揭示总览面板。
    var onSceneReachedEnd: ((TransitionToken) -> Void)?
    /// 承载层完全消失（淡出结束/被丢弃）。
    var onSceneFinished: ((TransitionToken) -> Void)?
    /// 取消收尾完成（方案 §13.2、§16.2）：retreat/cancelAll 之后承载层真正下屏的那一刻。
    /// 只有这条回调能把"取消已生效"告诉捕获层与调度器；发起取消不等于取消完成。
    var onSceneCancellationFinished: ((TransitionToken) -> Void)?
    /// 飞行帧事实（方案 §20.3）：P95 帧间隔与掉帧，每次过渡结束报告一次。
    var onSceneStats: ((TransitionScene.Kind, FrameIntervalStats) -> Void)?
    var onSceneTickStats: ((TransitionScene.Kind, FrameIntervalStats) -> Void)?
    /// 呈现事实（方案 §20.2）：首帧延迟 + tick/present 对照，每次飞行到位报告一次。
    var onSceneFacts: ((TransitionScene.Kind, TransitionFlightFacts) -> Void)?

    func finalizePresentationFacts() {
        for carrier in carriers.values { carrier.carrierView.finalizePresentationFacts() }
    }

    private let metal: MetalContext
    private var carriers: [UInt32: TransitionCarrierWindow] = [:]
    private(set) var activeToken: TransitionToken?
    private(set) var activeKind: TransitionScene.Kind?
    private var activeDisplayID: UInt32?
    private var confirmed = false
    /// 已请求取消但承载层还没真正下屏：这段窗口期内任何"延后"都必须立刻失效（方案 §13.2）。
    private var cancellationRequested = false

    init(metal: MetalContext) {
        self.metal = metal
    }

    var isPresenting: Bool { activeToken != nil }

    /// 预建承载窗口并把首次 drawable 分配移出点击路径：首帧延迟里原本包含创建窗口、
    /// 建 CAMetalLayer、取第一块 drawable 的冷启动成本（实测冷启动帧样本更差）。
    func prewarm(displayID: UInt32) {
        guard let facts = displayFacts?(displayID) else { return }
        guard let window = carrier(for: displayID, facts: facts) else { return }
        window.carrierView.configure(cgOrigin: facts.cgFrame.origin, scale: facts.scale)
        window.carrierView.prewarm()
    }

    /// 模式过渡这一路的活动事实（方案 §13.2）：合并进捕获层的统一 TransitionActivity。
    /// 取消已请求时 `blocksGeometryReconfiguration` 自然为 false——延后不再拖住释放。
    var activity: TransitionActivity {
        TransitionActivity(modeTransition: activeToken != nil, cancellationRequested: cancellationRequested)
    }

    /// 当前实际呈现的矩形/透明度（CG 全局，方案 §16.2）：新场景与代理收尾都必须从它接续。
    func presentedRect(for identity: WindowIdentity) -> CGRect? { activeCarrierView?.presentedRect(for: identity) }
    func presentedPanelRect(for identity: WindowIdentity) -> CGRect? { activeCarrierView?.presentedPanelRect(for: identity) }
    func presentedAlpha(for identity: WindowIdentity) -> CGFloat? { activeCarrierView?.presentedAlpha(for: identity) }

    /// 承载层是否已经彻底不在屏幕上：隐藏/退出的收敛判据之一。
    var isIdle: Bool { activeToken == nil && carriers.values.allSatisfy { $0.carrierView.isIdle } }

    /// 返回总览的飞行（或保持）是否还占着屏幕：宿主据此推迟总览面板与两栏的交替。
    var isReturnPresenting: Bool { activeToken != nil && activeKind == .returning }
    /// 当前场景要求栏里藏起来的卡片：静止副本与动画副本不许同时出现。
    var hiddenRailIdentities: Set<WindowIdentity> {
        guard let activeDisplayID, let view = carriers[activeDisplayID]?.carrierView else { return [] }
        return view.scene?.hiddenRailIdentities ?? []
    }

    /// 只读观察点：当前为哪些屏留着承载窗口（方案 §18.2 H18：层数只跟屏数走，不跟卡片数走）。
    var carrierDisplayIDs: Set<UInt32> { Set(carriers.keys) }

    /// 只读观察点：某一屏的承载窗口实例（测试据此断言同一屏的连续播放复用同一个窗口）。
    func carrierWindow(for displayID: UInt32) -> TransitionCarrierWindow? { carriers[displayID] }

    /// - Parameter anchorAt: 真实输入时刻（单调时钟），只用于首帧延迟打点（方案 §20.2）。
    func play(_ scene: TransitionScene, anchorAt: CFTimeInterval? = nil) {
        guard let facts = displayFacts?(scene.displayID) else { return }
        if let old = activeDisplayID, old != scene.displayID {
            stopCarrier(old, emittingFinished: true)
        }
        guard let window = carrier(for: scene.displayID, facts: facts) else { return }
        var sources: [WindowIdentity: MetalFrame] = [:]
        for card in scene.cards {
            if let frame = textureProvider?(card.identity) { sources[card.identity] = frame }
        }
        window.carrierView.configure(cgOrigin: facts.cgFrame.origin, scale: facts.scale)
        window.level = .floating
        window.orderFrontRegardless()
        activeToken = scene.token
        activeKind = scene.kind
        activeDisplayID = scene.displayID
        confirmed = false
        // 新场景已经开始播放：上一轮的"取消中"标记到此结束（方案 §13.2）。
        cancellationRequested = false
        window.carrierView.play(scene, sources: sources, anchorAt: anchorAt)
    }

    /// 飞行中到位的画面源。生产路径画面板，不再有"飞行中补一帧"的调用方；
    /// 保留这条通道只为 `.captured` 诊断回退与宿主测试。
    func updateSource(_ identity: WindowIdentity, frame: MetalFrame, aspect: CGFloat) {
        guard let view = activeCarrierView else { return }
        view.updateSource(identity, frame: frame, aspect: aspect)
    }

    /// 原地交换不等动画时长；几何飞行仍在到位后交接。
    func confirm(_ token: TransitionToken) {
        guard activeToken == token else { return }
        confirmed = true
        guard let view = activeCarrierView,
              view.isHolding || view.scene?.isStationarySwap == true else { return }
        view.beginFade()
    }

    /// 失败/取消：尽快收掉承载层，真实窗口的补偿由执行器负责（方案 §10.4）。
    func retreat(_ token: TransitionToken) {
        guard activeToken == token else { return }
        cancellationRequested = true
        activeCarrierView?.beginFade(durationMS: 90)
    }

    func retreatActive() {
        cancellationRequested = true
        activeCarrierView?.beginFade(durationMS: 90)
    }

    /// 宿主已经完成揭示（总览面板已显示）：开始交接淡化。
    func startHandoff(_ token: TransitionToken) {
        guard activeToken == token else { return }
        activeCarrierView?.beginFade()
    }

    /// 整段会话消失（隐藏、权限丢失、退出）：立即收掉，不留透明命中层。
    /// 取消是"发起"，下屏才是"完成"：两者之间仍算忙，退出/隐藏的排空判据要用完成回调（方案 §5.4、§13.2）。
    func cancelAll() {
        let cancelledToken = activeToken
        cancellationRequested = activeToken != nil
        for id in Array(carriers.keys) {
            carriers[id]?.carrierView.stopNow()
            carriers[id]?.level = .normal
            carriers[id]?.orderOut(nil)
        }
        carriers.removeAll()
        activeToken = nil
        activeKind = nil
        activeDisplayID = nil
        confirmed = false
        // 承载层已确定下屏：把取消完成告知宿主，让捕获重配与过渡占位一起失效。
        if let cancelledToken {
            cancellationRequested = false
            onSceneCancellationFinished?(cancelledToken)
        }
    }

    /// 屏幕集合变化：被拔掉的屏不再保留承载层。
    func retireDisplays(keeping ids: Set<UInt32>) {
        for id in Array(carriers.keys) where !ids.contains(id) {
            stopCarrier(id, emittingFinished: true)
            carriers.removeValue(forKey: id)
        }
    }

    // MARK: - 承载窗口

    private var activeCarrierView: TransitionCarrierView? {
        guard let activeDisplayID else { return nil }
        return carriers[activeDisplayID]?.carrierView
    }

    private func carrier(for displayID: UInt32, facts: DisplayFacts) -> TransitionCarrierWindow? {
        if let existing = carriers[displayID] {
            if existing.frame != facts.appKitFrame {
                existing.setFrame(facts.appKitFrame, display: false)
            }
            return existing
        }
        let created = TransitionCarrierWindow(screenFrame: facts.appKitFrame, metal: metal)
        // 回调令牌由场景自己带来（不是回调时刻的 activeToken）：
        // 只有仍然是当前场景的回调才允许提交状态，过期场景的完成一律丢弃（方案 §16.2）。
        created.carrierView.onReachedEnd = { [weak self] token in
            guard let self, self.activeToken == token else { return }
            // 进入/交换：真实窗口已验证，到点即可交接（返回总览由宿主揭示流程驱动）。
            if self.confirmed, self.activeKind != .returning {
                self.activeCarrierView?.beginFade()
            }
            self.onSceneReachedEnd?(token)
        }
        created.carrierView.onFinished = { [weak self] token in
            guard let self, self.activeToken == token, self.activeDisplayID == displayID else { return }
            if let window = self.carriers[displayID] {
                window.level = .normal
                window.orderOut(nil)
            }
            self.activeToken = nil
            self.activeKind = nil
            self.activeDisplayID = nil
            self.confirmed = false
            let wasCancelling = self.cancellationRequested
            self.cancellationRequested = false
            if wasCancelling { self.onSceneCancellationFinished?(token) } else { self.onSceneFinished?(token) }
        }
        created.carrierView.onTickStats = { [weak self] kind, stats in
            self?.onSceneTickStats?(kind, stats)
        }
        created.carrierView.onFlightStats = { [weak self] kind, stats in
            self?.onSceneStats?(kind, stats)
        }
        created.carrierView.onFlightFacts = { [weak self] kind, facts in
            self?.onSceneFacts?(kind, facts)
        }
        carriers[displayID] = created
        return created
    }

    private func stopCarrier(_ displayID: UInt32, emittingFinished: Bool) {
        guard let window = carriers[displayID] else { return }
        window.carrierView.stopNow()
        window.level = .normal
        window.orderOut(nil)
        guard activeDisplayID == displayID else { return }
        let token = activeToken
        activeToken = nil
        activeKind = nil
        activeDisplayID = nil
        confirmed = false
        if emittingFinished, let token {
            let wasCancelling = cancellationRequested
            cancellationRequested = false
            if wasCancelling { onSceneCancellationFinished?(token) } else { onSceneFinished?(token) }
        }
    }
}
