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

    /// 飞行期间往卡片矩形里画什么。
    ///
    /// 捕获输出有硬上限（`CaptureTier.maxPixelWidth`：powerSaving 640 / balanced 960 / refreshPriority 1280），
    /// 而主区在 2x 下约 3000px 宽：把捕获图放大到主区必然是模糊的，而且抓得越勤越占用点击路径。
    /// 所以飞行期间不画任何位图，只画一块与卡片同形（圆角、底色、描边）的面板；
    /// 落定后由承载层短淡化交接给真实窗口。这样"模糊的放大过程"根本不存在。
    enum Content: Hashable {
        case panel(PanelStyle)
        /// 旧行为：放大捕获画面（仅供诊断回退，生产路径不再使用）。
        case captured
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

        /// 面板（卡片外框）的显式端点。nil 表示按底板/画面矩形推导。
        ///
        /// 面板代表"那张卡片"本身，必须用外框（含标题条），不能用内容区：
        /// 内容区比外框矮一个标题条，拿它当端点会看出面板从卡片中间"长出来"，
        /// 交接时还会再跳一下（面板比真实卡片小一截）。
        /// 进入工作台时轨道卡片的落点是栏里那一格，而画面容器落点是内容区，
        /// 两者不同，所以这里必须能显式给出，不能只靠推导。
        var panelFrom: CGRect? = nil
        var panelTo: CGRect? = nil

        /// 面板起点：显式端点 → 底板 → 画面矩形。
        var panelStart: CGRect { panelFrom ?? cellStart ?? start }
        /// 面板终点：显式端点 → 底板终点 → 画面终点 → 原地不动（不伪造落点）。
        var panelEnd: CGRect { panelTo ?? cellEnd ?? end ?? panelFrom ?? cellStart ?? start }
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
    /// 飞行期间画什么。生产恒为 `.panel`：不放大任何捕获位图，从根上不存在"模糊的过程"。
    var content: Content = .panel(.standard)
    /// 焦点卡上的切换流光；nil 表示这段场景没有流光（淡化等级、无轨道起点的交换）。
    var flow: FlowSpec? = nil

    var hiddenRailIdentities: Set<WindowIdentity> {
        Set(cards.filter(\.hidesRailCard).map(\.identity))
    }

    var focusCard: Card? {
        cards.first(where: \.isFocus)
    }

    var isStationarySwap: Bool {
        guard kind == .swapping, case .panel = content, cards.count == 1,
              let card = focusCard else { return false }
        return card.start == card.end && card.panelStart == card.panelEnd
            && card.startAlpha == 1 && card.endAlpha == 1
    }

    static func backdropColor(_ backdrop: Backdrop) -> SIMD4<Float>? {
        switch backdrop {
        case let .opaque(color), let .rising(color): return color
        case .transparent: return nil
        }
    }
}

/// 切换流光的纯描述：只带方向与光色，亮度/宽度/推进全部由 `TransitionTimeline`
/// 的包络随进度求值——端点算完就固定，播放层不改这里的值（与卡片端点同一约束）。
struct FlowSpec: Hashable {
    /// 飞行方向（CG 全局坐标、起点中心指向终点中心、未归一化也允许）。
    /// 渲染层负责归一化与 y 轴翻转，这里保持"计划事实"的原始形态。
    var axis: SIMD2<Float>
    /// 前缘色（运动方向一头）：调色板里的青。
    var leading: SIMD4<Float> = SIMD4<Float>(0.33, 0.86, 0.96, 1)
    /// 尾端色（能量拖尾）：调色板里的蓝。
    var trailing: SIMD4<Float> = SIMD4<Float>(0.40, 0.54, 1.0, 1)

    static let standard = FlowSpec(axis: SIMD2<Float>(1, 0))
}

/// 飞行面板的外观：颜色与圆角都跟栏内卡片保持一致，看起来就是"那张卡片在飞"。
/// 全部数值集中在这里，视图层与测试共用同一份，不各写一套。
struct PanelStyle: Hashable {    /// 填充色（预乘前的直色）。与总览/两栏卡片底板同一族的稍亮版本：
    /// 飞行时它是屏幕上唯一在动的东西，比静止底板亮一点才看得出来。
    var fill: SIMD4<Float>
    /// 描边色，与卡片边框同一条白 10%。
    var stroke: SIMD4<Float>
    /// 描边宽度（点）。
    var strokeWidth: CGFloat
    /// 圆角半径（点），取 `WorkbenchStyle.cornerRadius`。
    var cornerRadius: CGFloat

    /// 与总览/两栏卡片同一套 token：底板 RGB(0.09,0.09,0.10)、白 7% 边框、12pt 圆角。
    /// 面板取比底板略亮的填充，否则在深色桌面上"飞"起来几乎看不见。
    static let standard = PanelStyle(fill: SIMD4<Float>(0.145, 0.153, 0.173, 1),
                                     stroke: SIMD4<Float>(1, 1, 1, 0.10),
                                     strokeWidth: 1,
                                     cornerRadius: 12)
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

    // MARK: - 切换流光的包络（纯函数：测试断言的就是屏幕上跑的那一条）

    /// 飞行的瞬时速度（相对值 0…1）：easeOutCubic 的导数。起步最快、接近终点归于零。
    /// 光带的宽度与拖尾长度随它调制——快时窄而亮、拖得长，减速后展开变柔。
    static func flightSpeed(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        return (1 - t) * (1 - t)
    }

    /// 流光总强度的首尾呼吸：起步从 0 二次缓入（光从格子里"抽出"而不是突然点亮），
    /// 0.78 之后向 0.35 收拢——落定后的持续呼吸交给边缘光晕，Metal 流光只负责飞行段。
    static func flowIntensity(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        let head = min(1, t / 0.14)
        let headEased = head * head
        let tail = 1 - 0.65 * min(1, max(0, (t - 0.78) / 0.22))
        return headEased * tail
    }

    /// 到达段的展开混合：0.72 之前是纯扫掠光带，之后 smoothstep 升到 1，
    /// 光带展开成以面板中心为核的径向柔光——"水滴落进水面"的收尾。
    static func flowSettle(_ progress: CGFloat) -> CGFloat {
        let t = min(1, max(0, progress))
        let s = min(1, max(0, (t - 0.72) / 0.28))
        return s * s * (3 - 2 * s)
    }

    /// 光带垂直半宽（归一化 0.10…0.32）：随速度反比展开。
    static func flowBandWidth(_ progress: CGFloat) -> CGFloat {
        0.10 + 0.22 * (1 - flightSpeed(progress))
    }

    /// 沿轴拖尾长度（归一化 0.32…0.52）：速度越快拖得越长，减速时收拢。
    static func flowTrail(_ progress: CGFloat) -> CGFloat {
        0.32 + 0.20 * flightSpeed(progress)
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
    /// 飞行期间画面板还是放大捕获图。生产恒为 false（面板）；
    /// 置 true 只在诊断里复现旧行为，任何用户可见路径都不该打开它。
    var drawsCapturedContent: Bool = false

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
                                              isFocus: true,
                                              panelFrom: mainCell,
                                              panelTo: plan.animationTo ?? plan.targetFrame))
        }
        for handoff in plan.railHandoffs where handoff.from.intersects(screen) {
            guard var card = makeCard(identity: handoff.identity,
                                      contentStart: overviewImageRect(handoff.identity) ?? handoff.from,
                                      contentEnd: handoff.to == nil ? nil : railContent(handoff, in: snapshot),
                                      cellStart: handoff.from,
                                      cellEnd: nil,
                                      hidesRail: false) else { continue }
            // 面板落点是栏里那一格（含标题条），不是内容区：否则面板比真实卡片矮一截，交接时会跳。
            card.panelTo = snapshot.isVisible(handoff.slot) ? snapshot.rect(for: handoff.slot) : nil
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
                               level: level,
                               content: content(for: snapshot))
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
                                              isFocus: true,
                                              panelFrom: mainStart,
                                              panelTo: plan.animationTo))
        }
        for handoff in plan.railHandoffs where handoff.from.intersects(screen) || handoff.to?.intersects(screen) == true {
            guard var card = makeCard(identity: handoff.identity,
                                      contentStart: snapshot.contentRect(for: handoff.slot) ?? handoff.from,
                                      contentEnd: overviewImageRect(handoff.identity) ?? handoff.to,
                                      cellStart: snapshot.rect(for: handoff.slot),
                                      cellEnd: handoff.to,
                                      hidesRail: true) else { continue }
            // 起点是栏里那一格（含标题条）；终点是总览那一格，与真实卡片外框完全重合。
            card.panelFrom = snapshot.rect(for: handoff.slot)
            card.panelTo = handoff.to
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
                               level: level,
                               content: content(for: snapshot))
    }

    /// 栏内交换（方案 §10.3）。full 级别：B（新主）从被点选的格子飞进主区、
    /// A（旧主）同时退回自己的格子，两块面板对飞完成空间衔接，并叠加一道
    /// 由速度包络驱动的定向流光；真实窗口交换仍由承载层盖住后照常执行，
    /// 动画时长不影响几何时序（"流光不延后几何执行"）。
    /// light 级别：面板原地不动，流光仍从格子方向扫过主区再扩散（方向感不丢）。
    /// fade/减少动态效果：保持单帧遮罩与短淡化，无流光。
    func swapping(_ plan: WorkbenchSwitchPlan) -> TransitionScene? {
        guard usableDisplayFrame(plan.displayID) != nil else { return nil }
        let snapshot = plan.snapshot
        let intent = plan.intent

        if intent.followsExternalFocus {
            let card = TransitionScene.Card(identity: intent.to,
                                            start: plan.mainTargetFrame,
                                            end: plan.mainTargetFrame,
                                            cellStart: nil,
                                            cellEnd: nil,
                                            startAlpha: 0,
                                            endAlpha: 0.35,
                                            aspect: aspect(intent.to, plan.mainTargetFrame),
                                            hidesRailCard: false,
                                            isFocus: true,
                                            panelFrom: plan.mainTargetFrame,
                                            panelTo: plan.mainTargetFrame)
            return TransitionScene(kind: .swapping, token: intent.token, displayID: plan.displayID,
                                   backdrop: .transparent, cards: [card],
                                   durationMS: reduceMotion() ? 80 : 120, fadeOnly: true,
                                   level: level, content: content(for: snapshot))
        }

        let mainPanelRect = snapshot.layout.mainRect
        // B 被点选的格子就是飞行的起点；滚出视口的格子没有可信起点，退回原地遮盖。
        let sourceSlot = intent.railSlot.flatMap { slot -> CGRect? in
            guard snapshot.isVisible(slot), let rect = snapshot.rect(for: slot) else { return nil }
            return rect
        }
        let reduced = reduceMotion()

        if level == .full, !reduced, let cell = sourceSlot {
            var cards: [TransitionScene.Card] = []
            // B：面板代表"那张卡片"，起点是整格（含标题条），画面容器从内容区起飞。
            let contentStart = intent.railSlot.flatMap { snapshot.contentRect(for: $0) } ?? cell
            cards.append(TransitionScene.Card(identity: intent.to,
                                              start: contentStart,
                                              end: plan.mainTargetFrame,
                                              cellStart: nil,
                                              cellEnd: nil,
                                              startAlpha: 1,
                                              endAlpha: 1,
                                              aspect: aspect(intent.to, contentStart),
                                              hidesRailCard: true,
                                              isFocus: true,
                                              panelFrom: cell,
                                              // 面板终点是实际停靠矩形（原尺寸居中或等比收缩），
                                              // 不是整个主区：否则小窗口落定时面板与真身会跳一下。
                                              panelTo: plan.mainTargetFrame))
            // A：旧主退回自己的格子；没有可信落点（首次选择）时原地淡出，不伪造位置（方案 §4.2.5）。
            // 起点取它此刻的真实矩形：尊重原尺寸后旧主的停靠矩形未必是整个主区。
            if let previous = intent.from {
                let previousFrame = recordFrame(previous) ?? plan.mainTargetFrame
                let restingCell = plan.restingSlot.flatMap { snapshot.rect(for: $0) }
                let restingContent = plan.restingSlot.flatMap { snapshot.contentRect(for: $0) } ?? restingCell
                cards.append(TransitionScene.Card(identity: previous,
                                                  start: previousFrame,
                                                  end: restingContent,
                                                  cellStart: nil,
                                                  cellEnd: restingCell,
                                                  startAlpha: 1,
                                                  endAlpha: restingContent == nil ? 0 : 1,
                                                  aspect: aspect(previous, previousFrame),
                                                  hidesRailCard: restingCell != nil,
                                                  isFocus: false,
                                                  panelFrom: previousFrame,
                                                  panelTo: restingCell))
            }
            var flow = FlowSpec.standard
            flow.axis = SIMD2<Float>(Float(plan.mainTargetFrame.midX - cell.midX),
                                     Float(plan.mainTargetFrame.midY - cell.midY))
            return TransitionScene(kind: .swapping,
                                   token: intent.token,
                                   displayID: plan.displayID,
                                   backdrop: .transparent,
                                   cards: cards,
                                   durationMS: 240,
                                   fadeOnly: false,
                                   level: level,
                                   content: content(for: snapshot),
                                   flow: flow)
        }

        // 原地遮盖：A/B 的真实交换仍被主区面板盖住；light 级别让流光独自扫过再扩散。
        let card = TransitionScene.Card(identity: intent.to,
                                        start: plan.mainTargetFrame,
                                        end: plan.mainTargetFrame,
                                        cellStart: nil,
                                        cellEnd: nil,
                                        startAlpha: 1,
                                        endAlpha: 1,
                                        aspect: aspect(intent.to, plan.mainTargetFrame),
                                        hidesRailCard: false,
                                        isFocus: true,
                                        panelFrom: snapshot.layout.mainRect,
                                        panelTo: snapshot.layout.mainRect)
        var flow: FlowSpec? = nil
        if level == .light, !reduced, let cell = sourceSlot {
            var spec = FlowSpec.standard
            spec.axis = SIMD2<Float>(Float(mainPanelRect.midX - cell.midX),
                                     Float(mainPanelRect.midY - cell.midY))
            flow = spec
        }
        return TransitionScene(kind: .swapping,
                               token: intent.token,
                               displayID: plan.displayID,
                               backdrop: .transparent,
                               cards: [card],
                               durationMS: flow != nil ? 180 : 16,
                               fadeOnly: level == .fade || reduced,
                               level: level,
                               content: content(for: snapshot),
                               flow: flow)
    }

    // MARK: - 组装

    /// 飞行画面：生产恒为圆角面板；`drawsCapturedContent` 只在诊断里回退到旧行为。
    private func content(for snapshot: WorkbenchLayoutSnapshot) -> TransitionScene.Content {
        guard !drawsCapturedContent else { return .captured }
        var style = PanelStyle.standard
        // 圆角跟栏内卡片同一套 token：面板看起来才是"那张卡片"，而不是一个别的方块。
        style.cornerRadius = snapshot.layout.style.cornerRadius
        return .panel(style)
    }

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
            // 面板端点也是"位移"，同样必须就地收掉：只清 start/cellStart 的话，
            // 显式给出的 panelFrom/panelTo 会让面板照样飞出去，轻量等级就不成立了。
            let resting = light.panelTo ?? light.start
            light.panelFrom = resting
            light.panelTo = resting
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
