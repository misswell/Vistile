import CoreGraphics
import Foundation
import VistileCore

/// 一次过渡动画的纯描述（方案 §10.6：统一预计算源/目标 rect、alpha、参与窗口与 token）。
/// 这里不含窗口、计时器与截图：播放由 ModeTransitionCoordinator 负责，
/// 端点与时长可以在宿主测试里直接断言。全部矩形都是 CG 全局坐标，视图层只在绘制时翻转一次。
struct TransitionScene {
    enum Kind {
        case entering
        case returning
        case swapping

        var displayName: String {
            switch self {
            case .entering: return "总览→L 型"
            case .returning: return "L 型→总览"
            case .swapping: return "L 型内交换"
            }
        }
    }

    struct Card {
        let identity: WindowIdentity
        /// 画面容器起点：内容按 aspect 等比适配进这个矩形。
        var start: CGRect
        /// 画面容器终点；nil 表示没有可信落点：原地淡出，不伪造位置（方案 §4.2.5）。
        let end: CGRect?
        /// 卡片底板（格子底色）的起止；nil 表示这一端不画底板。end 为 nil 时底板随飞行淡出。
        var cellStart: CGRect?
        let cellEnd: CGRect?
        var startAlpha: CGFloat
        let endAlpha: CGFloat
        /// 内容等比适配用的宽高比：取有效捕获内容/真实窗口，不用含标题条的格子比例（方案 §4.3）。
        let aspect: CGFloat
        /// 动画期间把对应栏里的真实卡片藏起来，避免静止副本与动画副本叠影。
        let hidesRailCard: Bool
        /// 主区里的那一张：保持提示语与"正在切换"落在它附近，也最后绘制。
        let isFocus: Bool
        /// 透明度在这个进度的分数处就走到终点（1 = 与整段动画同长）。
        /// 轻量等级用它把"其余卡片"的淡化压进 100–160ms（方案 §20.4）。
        var fadeFraction: CGFloat = 1
    }

    enum Backdrop {
        /// 进入工作台：第一帧起就完全不透明，把总览与尚未到位的真实窗口一起盖住（方案 §10.1）。
        case opaque(SIMD4<Float>)
        /// 返回总览：底色在飞行期间从透明升到不透明，把落定前的真实窗口运动盖住（方案 §10.2）。
        case rising(SIMD4<Float>)
        /// 栏内交换：不画底色，两栏与分隔线纹丝不动（方案 §10.3）。
        case transparent
    }

    let kind: Kind
    let token: TransitionToken
    let displayID: UInt32
    let backdrop: Backdrop
    let cards: [Card]
    let durationMS: Int
    /// 减少动态效果：不做几何飞行，卡片固定在终点短淡化（方案 §10.5）。
    let fadeOnly: Bool
    /// 播放这段场景时生效的动效等级（方案 §20.4），供诊断与测试对账。
    let level: MotionLevel

    var hiddenRailIdentities: Set<WindowIdentity> {
        Set(cards.filter(\.hidesRailCard).map(\.identity))
    }

    var focusCard: Card? {
        cards.first(where: \.isFocus)
    }

    static func backdropColor(_ backdrop: Backdrop) -> SIMD4<Float>? {
        switch backdrop {
        case let .opaque(color), let .rising(color): return color
        case .transparent: return nil
        }
    }
}

/// 时间轴上的纯函数：缓动、矩形插值、等比适配、底色透明度。
/// 视图与宿主测试共用同一份实现，测试断言的公式就是屏幕上跑的那一条。
enum TransitionTimeline {
    /// 短促缓出（方案 §10.1：不叠加过冲弹簧、旋转与连续 bounce）。
    static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let clamped = min(1, max(0, t))
        return 1 - pow(1 - clamped, 3)
    }

    static func interpolate(_ from: CGRect, _ to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * progress,
               y: from.minY + (to.minY - from.minY) * progress,
               width: from.width + (to.width - from.width) * progress,
               height: from.height + (to.height - from.height) * progress)
    }

    /// 容器矩形插值 + 内容等比适配：宽高比变化留白，禁止非均匀拉伸（方案 §10.2.5）。
    static func aspectFit(aspect: CGFloat, in container: CGRect) -> CGRect {
        let ratio = max(0.2, aspect)
        let containerAspect = container.width / max(1, container.height)
        if ratio >= containerAspect {
            let height = container.width / max(0.0001, ratio)
            return CGRect(x: container.minX, y: container.midY - height / 2, width: container.width, height: height)
        }
        let width = container.height * ratio
        return CGRect(x: container.midX - width / 2, y: container.minY, width: width, height: container.height)
    }

    /// 卡片透明度按各自的淡化窗口推进（方案 §20.4：轻量等级把"其余卡片"的 100–160ms
    /// 对照整段时长折算成分数；fadeFraction = 1 时就是整段匀速）。
    static func alphaProgress(_ progress: CGFloat, fadeFraction: CGFloat) -> CGFloat {
        guard fadeFraction > 0 else { return 1 }
        return min(1, max(0, progress) / fadeFraction)
    }

    /// 底色在整段飞行里的透明度。opaque 从头就不透明；rising 在前 62% 升满，遮住真实窗口的落定过程。
    static func backdropAlpha(_ backdrop: TransitionScene.Backdrop, progress: CGFloat) -> CGFloat {
        switch backdrop {
        case .opaque: return 1
        case .transparent: return 0
        case .rising: return min(1, max(0, progress) * 1.6)
        }
    }

    /// 底色的目标透明度：opaque/rising 终态为 1，transparent 为 0。
    static func backdropTargetAlpha(_ backdrop: TransitionScene.Backdrop) -> CGFloat {
        backdropAlpha(backdrop, progress: 1)
    }
}

/// 把 reducer 的计划翻译成一段可播放的场景（方案 §10.6：播放期间不重新发现窗口、不重新优化网格）。
/// 所有外部事实（总览画面矩形、真实窗口矩形、屏幕矩形、宽高比）都从闭包读一次，
/// 端点算完就固定；中断续接由播放层用当前呈现矩形替换起点，不改这里的计划值。
struct TransitionSceneFactory {
    var background: SIMD4<Float> = SIMD4<Float>(0.078, 0.082, 0.094, 1)
    var reduceMotion: () -> Bool = { false }
    /// 当前动效等级（方案 §20.4）。降级只改变"怎么画"，不改变计划里的端点与最终画面。
    var motionLevel: () -> MotionLevel = { .full }
    /// 轻量等级下"其余卡片"的交叉淡化时长（方案 §20.4：100–160ms）。
    static let lightCrossfadeMS: CGFloat = 140
    /// 总览里这张卡片画面实际占的矩形（就是总览画的那个 imageRect）。
    var overviewImageRect: (WindowIdentity) -> CGRect? = { _ in nil }
    /// 真实窗口此刻的 frame（交换动画的起点用事实而不是推算）。
    var recordFrame: (WindowIdentity) -> CGRect? = { _ in nil }
    /// 屏幕在 CG 全局坐标里的矩形：卡片的起点/终点必须落在承载屏内才参与这一屏的合成。
    var displayFrame: (UInt32) -> CGRect? = { _ in nil }
    /// 内容宽高比。
    var aspect: (WindowIdentity, CGRect) -> CGFloat = { _, rect in
        max(0.2, rect.width / max(1, rect.height))
    }

    private var level: MotionLevel { motionLevel() }

    static func aspect(frame: MetalFrame?, recordFrame: CGRect?, fallback: CGRect?) -> CGFloat {
        if let meta = frame?.meta {
            if let size = meta.sourceSizeInPoints, size.width > 1, size.height > 1 {
                return max(0.2, size.width / size.height)
            }
            if meta.pixelWidth > 1, meta.pixelHeight > 1 {
                return max(0.2, CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight))
            }
        }
        if let recordFrame, recordFrame.width > 1, recordFrame.height > 1 {
            return max(0.2, recordFrame.width / recordFrame.height)
        }
        if let fallback, fallback.width > 1, fallback.height > 1 {
            return max(0.2, fallback.width / fallback.height)
        }
        return 1.6
    }

    // MARK: - 三种过渡

    /// 总览 → L 型：选中卡片展开到主区，其余可见卡片落进两栏（方案 §10.1）。
    func entering(_ plan: WorkbenchTransitionPlan) -> TransitionScene? {
        guard let screen = usableDisplayFrame(plan.displayID) else { return nil }
        let snapshot = plan.snapshot
        var cards: [TransitionScene.Card] = []

        let mainCell = plan.animationFrom
        let mainStart = mainCell.flatMap { _ in overviewImageRect(plan.identity) } ?? mainCell
        if let mainStart, mainStart.width > 1, mainStart.height > 1 {
            cards.append(TransitionScene.Card(identity: plan.identity,
                                              start: mainStart,
                                              end: plan.animationTo ?? plan.targetFrame,
                                              cellStart: mainCell,
                                              cellEnd: nil,
                                              startAlpha: 1,
                                              endAlpha: 1,
                                              aspect: aspect(plan.identity, mainStart),
                                              hidesRailCard: false,
                                              isFocus: true))
        }
        for handoff in plan.railHandoffs where handoff.from.intersects(screen) {
            guard let card = makeCard(identity: handoff.identity,
                                      contentStart: overviewImageRect(handoff.identity) ?? handoff.from,
                                      contentEnd: handoff.to == nil ? nil : railContent(handoff, in: snapshot),
                                      cellStart: handoff.from,
                                      cellEnd: nil,
                                      hidesRail: false) else { continue }
            cards.append(card)
        }
        // 淡化等级即使系统没有开"减少动态效果"，也改用 80–120ms 的短淡化时长（方案 §20.4）。
        let durationMS = level == .fade
            ? plan.snapshot.layout.style.entryAnimationMS(reduceMotion: true)
            : plan.animationMS
        return TransitionScene(kind: .entering,
                               token: plan.token,
                               displayID: plan.displayID,
                               backdrop: .opaque(background),
                               cards: degradeToLight(cards, durationMS: durationMS),
                               durationMS: durationMS,
                               fadeOnly: level == .fade || reduceMotion(),
                               level: level)
    }

    /// L 型 → 总览：主窗口缩回自己的总览位置，其余卡片回各自位置（方案 §10.2）。
    func returning(_ plan: WorkbenchTransitionPlan) -> TransitionScene? {
        guard let screen = usableDisplayFrame(plan.displayID) else { return nil }
        let snapshot = plan.snapshot
        var cards: [TransitionScene.Card] = []

        let mainStart = plan.animationFrom ?? snapshot.layout.mainRect
        if mainStart.width > 1, mainStart.height > 1 {
            let mainEnd = overviewImageRect(plan.identity) ?? plan.animationTo
            cards.append(TransitionScene.Card(identity: plan.identity,
                                              start: mainStart,
                                              end: mainEnd,
                                              cellStart: nil,
                                              cellEnd: plan.animationTo,
                                              startAlpha: 1,
                                              endAlpha: mainEnd == nil ? 0 : 1,
                                              aspect: aspect(plan.identity, mainStart),
                                              hidesRailCard: true,
                                              isFocus: true))
        }
        for handoff in plan.railHandoffs where handoff.from.intersects(screen) || handoff.to?.intersects(screen) == true {
            guard let card = makeCard(identity: handoff.identity,
                                      contentStart: snapshot.contentRect(for: handoff.slot) ?? handoff.from,
                                      contentEnd: overviewImageRect(handoff.identity) ?? handoff.to,
                                      cellStart: snapshot.rect(for: handoff.slot),
                                      cellEnd: handoff.to,
                                      hidesRail: true) else { continue }
            cards.append(card)
        }
        let durationMS = level == .fade
            ? plan.snapshot.layout.style.returnAnimationMS(reduceMotion: true)
            : plan.animationMS
        return TransitionScene(kind: .returning,
                               token: plan.token,
                               displayID: plan.displayID,
                               backdrop: .rising(background),
                               cards: degradeToLight(cards, durationMS: durationMS),
                               durationMS: durationMS,
                               fadeOnly: level == .fade || reduceMotion(),
                               level: level)
    }

    /// L 型内交换：B 向主区展开，A 向 B 原 slot 收回，其它一律不动（方案 §10.3）。
    func swapping(_ plan: WorkbenchSwitchPlan) -> TransitionScene? {
        guard let screen = usableDisplayFrame(plan.displayID) else { return nil }
        let snapshot = plan.snapshot
        let intent = plan.intent
        var cards: [TransitionScene.Card] = []

        if let slot = intent.railSlot {
            let cell = snapshot.rect(for: slot)
            let start = snapshot.contentRect(for: slot) ?? cell
            if let start, start.width > 1, start.height > 1, start.intersects(screen) {
                cards.append(TransitionScene.Card(identity: intent.to,
                                                  start: start,
                                                  end: plan.mainTargetFrame,
                                                  cellStart: cell,
                                                  cellEnd: nil,
                                                  startAlpha: 1,
                                                  endAlpha: 1,
                                                  aspect: aspect(intent.to, start),
                                                  hidesRailCard: true,
                                                  isFocus: true))
            }
        }
        if let from = intent.from {
            let start = recordFrame(from) ?? snapshot.layout.mainRect
            let end = plan.restingSlot.flatMap { snapshot.contentRect(for: $0) }
                ?? plan.restingTargetFrame
                ?? plan.mainTargetFrame
            cards.append(TransitionScene.Card(identity: from,
                                              start: start,
                                              end: end,
                                              cellStart: nil,
                                              cellEnd: nil,
                                              startAlpha: 1,
                                              endAlpha: 1,
                                              aspect: aspect(from, start),
                                              hidesRailCard: true,
                                              isFocus: false))
        }
        let fadeOnly = level == .fade || reduceMotion()
        let durationMS = snapshot.layout.style.switchAnimationMS(reduceMotion: fadeOnly)
        return TransitionScene(kind: .swapping,
                               token: intent.token,
                               displayID: plan.displayID,
                               backdrop: .transparent,
                               cards: degradeToLight(cards, durationMS: durationMS),
                               durationMS: durationMS,
                               fadeOnly: fadeOnly,
                               level: level)
    }

    // MARK: - 组装

    /// 轻量等级（方案 §20.4）：只让选中卡片做几何缩放，其余卡片不做任何位移，
    /// 直接落在终点并用 100–160ms 完成淡化——每帧要插值的运动卡片数减到一张。
    private func degradeToLight(_ cards: [TransitionScene.Card], durationMS: Int) -> [TransitionScene.Card] {
        guard level == .light, durationMS > 0 else { return cards }
        let fadeFraction = min(1, Self.lightCrossfadeMS / CGFloat(durationMS))
        return cards.map { card in
            guard !card.isFocus else { return card }
            var light = card
            if let end = card.end {
                light.start = end
                light.startAlpha = 0
            }
            light.cellStart = nil
            light.fadeFraction = fadeFraction
            return light
        }
    }

    private func makeCard(identity: WindowIdentity,
                          contentStart: CGRect,
                          contentEnd: CGRect?,
                          cellStart: CGRect?,
                          cellEnd: CGRect?,
                          hidesRail: Bool) -> TransitionScene.Card? {
        guard contentStart.width > 1, contentStart.height > 1 else { return nil }
        return TransitionScene.Card(identity: identity,
                                    start: contentStart,
                                    end: contentEnd,
                                    cellStart: cellStart,
                                    cellEnd: cellEnd,
                                    startAlpha: 1,
                                    endAlpha: contentEnd == nil ? 0 : 1,
                                    aspect: aspect(identity, contentStart),
                                    hidesRailCard: hidesRail,
                                    isFocus: false)
    }

    private func usableDisplayFrame(_ displayID: UInt32) -> CGRect? {
        guard let frame = displayFrame(displayID), frame.width > 1, frame.height > 1 else { return nil }
        return frame
    }

    /// 轨道卡片画面矩形：优先内容区（标题条以下），退化时才用整格。
    private func railContent(_ handoff: RailHandoff, in snapshot: WorkbenchLayoutSnapshot) -> CGRect? {
        guard snapshot.isVisible(handoff.slot) else { return nil }
        return snapshot.contentRect(for: handoff.slot) ?? handoff.to
    }
}
