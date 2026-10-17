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

/// 在一层短时透明 Metal 层里合成所有参与画面（方案 §10.6）：
/// 卡片容器按 ease-out 插值、内容等比适配、底板随飞行淡出；真实窗口是否到位不阻塞动画，
/// 到点后保持稳定并显示「正在切换」，等 confirm（真实窗口验证通过/提交）再短淡化交接。
/// 时间轴由 CADisplayLink 驱动，按真实 elapsed time 推进；静止或等待期间不发 tick。
final class TransitionCarrierView: NSView {
    let metalLayer = CAMetalLayer()

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

    private var displayLink: CADisplayLink?
    private let tickBridge = TickBridge()
    private var lastTickAt: CFTimeInterval = 0
    /// 本段场景飞行期间的帧间隔样本（ms）；播放结束按场景给出 P95 与掉帧事实（方案 §20.3）。
    private var frameIntervalsMS: [Double] = []
    /// 首帧延迟的锚点：真实输入的时刻（方案 §20.2）。用 play() 自己的进入时间会把
    /// "点击后卡在目录复核里几百毫秒才起动画"这段洗掉。
    private var firstPresentAnchor: CFTimeInterval = 0
    /// 锚点是否来自真实输入（false = 没有前置点击，按 play() 进入时刻算）。
    private var anchorIsRealInput = false
    /// 本段开始时渲染器的 present 计数，用于算出这一段真正呈现了多少帧。
    private var presentsAtSceneStart = 0
    private var firstPresentDelayMS: Double?
    private var tickCount = 0
    private var rearmTimer: Timer?
    private var holdLabelTimer: Timer?
    private var holdDeadlineTimer: Timer?
    private var sceneDeadlineTimer: Timer?
    private let holdBadge = CALayer()
    private let holdLabel = CATextLayer()

    var onReachedEnd: ((TransitionToken) -> Void)?
    var onFinished: ((TransitionToken) -> Void)?
    /// 一段飞行的帧间隔统计（方案 §20.3）：每次过渡结束后给一次，供诊断与降级决策。
    var onFlightStats: ((TransitionScene.Kind, FrameIntervalStats) -> Void)?
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
        metalLayer.device = metal.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = 2
        metalLayer.zPosition = 0
        layer?.addSublayer(metalLayer)
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
    func play(_ scene: TransitionScene, sources: [WindowIdentity: MetalFrame], anchorAt: CFTimeInterval? = nil) {
        let interrupting = phase != .idle
        self.scene = scene
        // 令牌与场景一起绑定：之后的每个回调都只报这个令牌，绝不在回调时刻回看协调器状态（方案 §16.2）。
        self.playingToken = scene.token
        states.removeAll()
        drawOrder = []
        focusIdentity = nil
        for card in scene.cards {
            var startRect = card.start
            var startAlpha = card.startAlpha
            if let presented = presentedRects[card.identity] {
                startRect = presented
                startAlpha = presentedAlphas[card.identity] ?? startAlpha
            }
            states[card.identity] = CardState(start: viewRect(startRect),
                                              end: viewRect(card.end ?? startRect),
                                              cellStart: card.cellStart.map { viewRect($0) },
                                              cellEnd: card.cellEnd.map { viewRect($0) },
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
        firstPresentAnchor = anchorAt ?? CACurrentMediaTime()
        anchorIsRealInput = anchorAt != nil
        firstPresentDelayMS = nil
        tickCount = 0
        presentsAtSceneStart = renderer?.diagnostics().presents ?? 0
        metalLayer.opacity = 1
        phase = .playing
        startTimestamp = CACurrentMediaTime()
        lastTickAt = 0
        render(progress: 0)
        startClock()
        scheduleRearm()
        scheduleSceneDeadline(budget: duration + 2.6)
        VistileLog.ui.log("[过渡] 播放 \(scene.kind.displayName, privacy: .public)：\(scene.cards.count) 张卡片，\(scene.durationMS)ms")
    }

    /// 画面源在飞行中更新（例如刚拍到的主窗口新帧）：只换纹理与比例，不改时间轴。
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
    func beginFade(durationMS: Int = TransitionCarrierView.handoffFadeMS) {
        guard phase != .idle else { return }
        stopTimers()
        hideHoldIndicator()
        fadeFrom = CGFloat(metalLayer.opacity)
        fadeStartTimestamp = CACurrentMediaTime()
        fadeDuration = max(0.016, TimeInterval(durationMS) / 1000)
        phase = .fading
        startClock()
        scheduleSceneDeadline(budget: fadeDuration + 1.0)
    }

    /// 立即结束：不交接也没有过渡（隐藏、屏移除）。屏幕上的事实不再存在。
    func stopNow() {
        stopClock()
        stopTimers()
        hideHoldIndicator()
        phase = .idle
        metalLayer.opacity = 1
        presentedRects.removeAll()
        presentedAlphas.removeAll()
        states.removeAll()
        scene = nil
        focusIdentity = nil
        playingToken = nil
    }

    private func finishNow() {
        stopClock()
        stopTimers()
        hideHoldIndicator()
        phase = .idle
        metalLayer.opacity = 1
        // 只报本段场景自己的令牌：这一刻协调器可能已经在放下一段（方案 §16.2）。
        let token = playingToken
        playingToken = nil
        if let token { onFinished?(token) }
    }

    // MARK: - 时钟

    fileprivate func handleTick(_ link: CADisplayLink) {
        advance(to: link.timestamp)
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
                frameIntervalsMS.append((timestamp - previousTick) * 1000)
            }
            let raw = duration > 0 ? (now - startTimestamp) / duration : 1
            let progress = CGFloat(min(1, max(0, raw)))
            render(progress: progress)
            if progress >= 1 {
                phase = .holding
                stopClock()
                // 呈现事实只算这一段：tick 次数与 present 增量并列报告，谁也不替谁（方案 §20.2）。
                if let scene {
                    let presented = (renderer?.diagnostics().presents ?? 0) - presentsAtSceneStart
                    onFlightFacts?(scene.kind, TransitionFlightFacts(firstPresentDelayMS: firstPresentDelayMS,
                                                                     ticks: tickCount,
                                                                     presentedFrames: presented,
                                                                     anchoredAtRealInput: anchorIsRealInput))
                    if let stats = FrameIntervalStats.measure(frameIntervalsMS) {
                        onFlightStats?(scene.kind, stats)
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
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.phase != .idle, self.lastTickAt == 0 else { return }
            self.stopClock()
            self.startClock()
        }
        RunLoop.main.add(timer, forMode: .common)
        rearmTimer = timer
    }

    /// 场景绝对限时：任何回调丢失都不许让承载层无限期留在屏幕上。
    private func scheduleSceneDeadline(budget: TimeInterval) {
        sceneDeadlineTimer?.invalidate()
        let timer = Timer(timeInterval: budget, repeats: false) { [weak self] _ in
            guard let self, self.phase != .idle else { return }
            VistileLog.ui.log("[过渡] 承载层超过限时，按结束处理")
            self.finishNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        sceneDeadlineTimer = timer
    }

    private func scheduleHoldChecks() {
        holdLabelTimer?.invalidate()
        // 大多数等待只有几十毫秒：先安静一会儿，超过 350ms 才显示「正在切换」。
        let label = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            guard let self, self.phase == .holding else { return }
            self.showHoldIndicator()
        }
        RunLoop.main.add(label, forMode: .common)
        holdLabelTimer = label

        holdDeadlineTimer?.invalidate()
        let deadline = Timer(timeInterval: TimeInterval(Self.holdDeadlineMS) / 1000, repeats: false) { [weak self] _ in
            guard let self, self.phase == .holding else { return }
            VistileLog.ui.log("[过渡] 真实窗口未在限时内到位，收起承载层")
            self.beginFade(durationMS: 140)
        }
        RunLoop.main.add(deadline, forMode: .common)
        holdDeadlineTimer = deadline
    }

    private func stopTimers() {
        rearmTimer?.invalidate()
        rearmTimer = nil
        holdLabelTimer?.invalidate()
        holdLabelTimer = nil
        holdDeadlineTimer?.invalidate()
        holdDeadlineTimer = nil
        sceneDeadlineTimer?.invalidate()
        sceneDeadlineTimer = nil
    }

    // MARK: - 绘制

    private func render(progress: CGFloat) {
        guard let renderer, let scene else { return }
        lastProgress = progress
        let eased = TransitionTimeline.easeOutCubic(progress)

        var cards: [CardDraw] = []
        var placeholders: [(rect: CGRect, tint: SIMD4<Float>)] = []

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
        for identity in drawOrder {
            guard let state = states[identity] else { continue }
            let cellRect: CGRect?
            let cellAlpha: CGFloat
            if let from = state.cellStart {
                let to = state.cellEnd ?? from
                cellRect = TransitionTimeline.interpolate(from, to, progress: eased)
                cellAlpha = state.cellEnd == nil ? 1 - eased : 1
            } else if let to = state.cellEnd {
                cellRect = to
                cellAlpha = eased
            } else {
                cellRect = nil
                cellAlpha = 0
            }
            if let cellRect, cellAlpha > 0.01 {
                placeholders.append((cellRect, SIMD4<Float>(0.09, 0.09, 0.10, Float(cellAlpha))))
            }

            let container: CGRect
            let alpha: CGFloat
            if scene.fadeOnly {
                // 最简模式：不飞行，卡片固定在终点短淡化（方案 §10.5）。
                container = state.end
                alpha = (state.endAlpha > 0.01 ? eased : 1 - eased) * state.endAlpha
            } else {
                container = TransitionTimeline.interpolate(state.start, state.end, progress: eased)
                let alphaT = TransitionTimeline.alphaProgress(eased, fadeFraction: state.fadeFraction)
                alpha = state.startAlpha + (state.endAlpha - state.startAlpha) * alphaT
            }
            presented[identity] = cgRect(fromView: container)
            presentedAlphas[identity] = alpha
            guard alpha > 0.01, container.width > 1, container.height > 1 else { continue }
            let content = TransitionTimeline.aspectFit(aspect: state.aspect, in: container)
            if let frame = state.frame {
                cards.append(CardDraw(identity: identity, imageRect: content, opacity: Float(alpha), frame: frame))
            } else {
                // 还没有纹理：画底板色块，运动本身仍然看得见，不假装有画面。
                placeholders.append((content, SIMD4<Float>(0.09, 0.09, 0.10, Float(alpha))))
            }
        }
        presentedRects = presented
        renderer.draw(layer: metalLayer,
                      cards: cards,
                      placeholders: placeholders,
                      viewBounds: bounds,
                      scale: max(1, metalLayer.contentsScale))
        // 首帧延迟只在"渲染器真的 present 出去"的那一刻记：draw 调用与 tick 回调都不算反馈（方案 §20.2）。
        if firstPresentDelayMS == nil, renderer.diagnostics().presents > presentsAtSceneStart {
            firstPresentDelayMS = max(0, (CACurrentMediaTime() - firstPresentAnchor) * 1000)
        }
    }

    /// 载具视图没有把 bounds 传给图层就没有任何可见像素。
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

    /// 此刻这一身份在屏幕上的画面矩形（CG 全局）。播放层只读观察点：宿主自检与测试用。
    func presentedRect(for identity: WindowIdentity) -> CGRect? {
        presentedRects[identity]
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
    /// 呈现事实（方案 §20.2）：首帧延迟 + tick/present 对照，每次飞行到位报告一次。
    var onSceneFacts: ((TransitionScene.Kind, TransitionFlightFacts) -> Void)?

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

    /// 模式过渡这一路的活动事实（方案 §13.2）：合并进捕获层的统一 TransitionActivity。
    /// 取消已请求时 `blocksGeometryReconfiguration` 自然为 false——延后不再拖住释放。
    var activity: TransitionActivity {
        TransitionActivity(modeTransition: activeToken != nil, cancellationRequested: cancellationRequested)
    }

    /// 当前实际呈现的矩形/透明度（CG 全局，方案 §16.2）：新场景与代理收尾都必须从它接续。
    func presentedRect(for identity: WindowIdentity) -> CGRect? { activeCarrierView?.presentedRect(for: identity) }
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

    /// 飞行中到位的画面源（例如主窗口的一次性新帧）。
    func updateSource(_ identity: WindowIdentity, frame: MetalFrame, aspect: CGFloat) {
        guard let view = activeCarrierView else { return }
        view.updateSource(identity, frame: frame, aspect: aspect)
    }

    /// 真实窗口已到位/已提交：飞行结束（或已在保持）后开始短淡化交接。
    func confirm(_ token: TransitionToken) {
        guard activeToken == token else { return }
        confirmed = true
        guard let view = activeCarrierView, view.isHolding else { return }
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
            guard let self else { return }
            // 承载层下屏属于物理事实：即使场景已过期也要把窗口收掉，
            // 但状态提交（令牌清空、揭示、取消完成）只认当前场景（方案 §16.2）。
            if let window = self.carriers[displayID] {
                window.level = .normal
                window.orderOut(nil)
            }
            guard self.activeToken == token else { return }
            self.activeToken = nil
            self.activeKind = nil
            self.activeDisplayID = nil
            self.confirmed = false
            let wasCancelling = self.cancellationRequested
            self.cancellationRequested = false
            if wasCancelling { self.onSceneCancellationFinished?(token) } else { self.onSceneFinished?(token) }
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
