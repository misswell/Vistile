import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import VistileCore

/// 一条轨道（顶栏 / 侧栏）的承载视图（方案 §9.4、§15.1）。
/// 与总览共用 OverviewRenderer 与 CardChrome，只按冻结投影画这一条栏：
/// 命中测试用卡片外框，滚动只改显示偏移，不改任何逻辑 slot；视图 frame 就是 viewport，
/// 越出视口的卡片由 bounds 裁掉，不画进面板内边距。
final class WorkbenchRailView: NSView {
    enum Action {
        case cardClicked(slot: RailSlotID, identity: WindowIdentity)
        /// 拖动在屏幕上松开：目标 slot 由控制器在两栏之间判定（跨栏拖动必须落在同一次事务里）。
        case cardDragged(from: RailSlotID, screenPoint: CGPoint)
        /// 提出新的滚动偏移；夹取与状态提交由 reducer 负责，视图不自己改快照。
        case scrolled(rail: RailKind, to: CGFloat)
    }

    let rail: RailKind
    var onAction: ((Action) -> Void)?

    /// 与总览同一台设备：未绑定 device 的 CAMetalLayer 不会有 drawable。
    let metalLayer = CAMetalLayer()

    private struct SlotGeometry: Equatable {
        let slot: RailSlotID
        let identity: WindowIdentity?
        let cellRect: CGRect
        let contentRect: CGRect
    }

    private var slotRects: [SlotGeometry] = []
    private var chromeLayers: [RailSlotID: CardChrome] = [:]
    private var emptyLayers: [RailSlotID: EmptySlotChrome] = [:]
    private(set) var lastCards: [RailSlotID: WorkbenchCard] = [:]
    /// 过渡承载层正在画这些身份：栏里对应的卡片（含底板与标题）先藏起来，避免出现两份。
    private var hiddenIdentities: Set<WindowIdentity> = []
    private var hiddenDirty = false
    /// 最近一次投影里的滚动偏移：scrollWheel 在它基础上提出新值。
    private(set) var scrollOffset: CGFloat = 0
    private var hoveredSlot: RailSlotID?
    private var accentColor = NSColor.controlAccentColor
    private var showsTitles = true
    private var chromeStyle = OverviewStyle.standard
    /// CG 全局坐标原点到视图左下的换算基准（视图左上角在 CG 里的坐标）。
    private var originInCG = CGPoint.zero
    private var backingScaleFactor: CGFloat = 2

    init(rail: RailKind, frame frameRect: NSRect, metal: MetalContext) {
        self.rail = rail
        super.init(frame: frameRect)
        commonInit(device: metal.device)
    }

    required init?(coder: NSCoder) {
        rail = .top
        super.init(coder: coder)
        commonInit(device: MTLCreateSystemDefaultDevice())
    }

    private func commonInit(device: MTLDevice?) {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer = CALayer()
        layer?.masksToBounds = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        metalLayer.contentsScale = 2
        metalLayer.zPosition = 0
        layer?.addSublayer(metalLayer)
        let chrome = CALayer()
        chrome.name = "chrome"
        chrome.zPosition = 1
        layer?.addSublayer(chrome)
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var chromeHost: CALayer? {
        layer?.sublayers?.first { $0.name == "chrome" }
    }

    // MARK: - 配置

    func configure(cgOrigin: CGPoint,
                   scale: CGFloat,
                   chromeStyle: OverviewStyle,
                   showsTitles: Bool,
                   accent: NSColor) {
        self.chromeStyle = chromeStyle
        self.showsTitles = showsTitles
        accentColor = accent
        originInCG = cgOrigin
        backingScaleFactor = scale
        metalLayer.contentsScale = scale
        for chrome in chromeLayers.values { chrome.container.contentsScale = scale }
        syncLayerGeometry()
    }

    // MARK: - 同步与绘制

    /// 过渡承载层接管这些卡片：两栏按新集合重绘一次（返回是否有变化）。
    @discardableResult
    func setHiddenRailIdentities(_ identities: Set<WindowIdentity>) -> Bool {
        guard identities != hiddenIdentities else { return false }
        hiddenIdentities = identities
        hiddenDirty = true
        return true
    }

    /// 按冻结投影重建这一条栏的几何与装饰层；画面重绘由新帧或几何变化驱动。
    func update(snapshot: WorkbenchLayoutSnapshot,
                cards: [WorkbenchCard],
                emptySlots: [RailSlotID],
                renderer: OverviewRenderer,
                mailboxes: (WindowIdentity) -> FrameMailbox<MetalFrame>?) {
        let oldGeometry = slotRects
        scrollOffset = snapshot.scrollOffset(rail: rail)
        let bySlot = Dictionary(uniqueKeysWithValues: cards.map { ($0.slot, $0) })
        lastCards = bySlot
        let layout = snapshot.layout
        slotRects = layout.slotOrder
            .filter { $0.rail == rail }
            .compactMap { slot in
                guard let cell = snapshot.rect(for: slot), let content = snapshot.contentRect(for: slot) else { return nil }
                return SlotGeometry(slot: slot,
                                    identity: bySlot[slot]?.identity,
                                    cellRect: viewRect(cell),
                                    contentRect: viewRect(content))
            }

        // 装饰层只保留此刻可能被看见的 slot：滚动轨道可以很长，不为屏幕外的卡片建层。
        let emptySet = Set(emptySlots)
        var keep: Set<RailSlotID> = []
        for entry in slotRects where entry.cellRect.intersects(bounds) {
            keep.insert(entry.slot)
            if let identity = entry.identity, hiddenIdentities.contains(identity) {
                // 这张卡片此刻由过渡承载层绘制：栏里的副本（画面、底板、标题）一起藏起来。
                chromeLayers[entry.slot]?.container.isHidden = true
                emptyLayers[entry.slot]?.container.isHidden = true
                continue
            }
            let record = bySlot[entry.slot]?.record
            if entry.identity == nil, emptySet.contains(entry.slot) {
                let chrome = emptyLayers[entry.slot] ?? {
                    let created = EmptySlotChrome()
                    chromeHost?.addSublayer(created.container)
                    emptyLayers[entry.slot] = created
                    return created
                }()
                chrome.container.isHidden = false
                chrome.layout(in: entry.cellRect, style: chromeStyle, scale: backingScaleFactor)
                continue
            }
            let chrome = chromeLayers[entry.slot] ?? {
                let created = CardChrome()
                chromeHost?.addSublayer(created.container)
                chromeLayers[entry.slot] = created
                return created
            }()
            chrome.container.isHidden = false
            applyChrome(chrome, entry: entry, record: record)
        }
        for (slot, chrome) in chromeLayers where !keep.contains(slot) {
            chrome.container.removeFromSuperlayer()
            chromeLayers.removeValue(forKey: slot)
        }
        for (slot, chrome) in emptyLayers where !keep.contains(slot) {
            chrome.container.removeFromSuperlayer()
            emptyLayers.removeValue(forKey: slot)
        }

        let geometryChanged = slotRects != oldGeometry
        let forced = geometryChanged || hiddenDirty
        hiddenDirty = false
        redraw(using: renderer, mailboxes: mailboxes, force: forced)
    }

    private func applyChrome(_ chrome: CardChrome, entry: SlotGeometry, record: WindowRecord?) {
        let title = record.map { "\($0.applicationName) — \($0.title)" } ?? ""
        chrome.layout(in: entry.cellRect, style: chromeStyle, showsTitle: showsTitles, showsStatus: false)
        chrome.apply(title: title,
                     status: nil,
                     isSelected: false,
                     isHovered: hoveredSlot == entry.slot,
                     accent: accentColor,
                     style: chromeStyle,
                     showsTitle: showsTitles,
                     scale: backingScaleFactor)
    }

    private func refreshChrome() {
        for (slot, chrome) in chromeLayers {
            guard let entry = slotRects.first(where: { $0.slot == slot }) else { continue }
            applyChrome(chrome, entry: entry, record: lastCards[slot]?.record)
        }
    }

    /// 有新鲜帧或几何变化才提交绘制；屏幕外的卡片不进入 draw 列表。
    func redraw(using renderer: OverviewRenderer,
                mailboxes: (WindowIdentity) -> FrameMailbox<MetalFrame>?,
                force: Bool = false) {
        let visible = slotRects.filter { $0.cellRect.intersects(bounds) }
        let sources = visible.compactMap { entry -> (identity: WindowIdentity, mailbox: FrameMailbox<MetalFrame>)? in
            guard let identity = entry.identity, let mailbox = mailboxes(identity) else { return nil }
            return (identity, mailbox)
        }
        let changed = renderer.absorbFrames(from: sources)
        guard changed || force else { return }

        syncLayerGeometry()
        var cards: [CardDraw] = []
        var placeholders: [(rect: CGRect, tint: SIMD4<Float>)] = []
        for entry in visible {
            // 由过渡承载层绘制的身份：栏里连底板带画面都不画，交给承载层画一份。
            if let identity = entry.identity, hiddenIdentities.contains(identity) { continue }
            placeholders.append((rect: entry.cellRect, tint: SIMD4<Float>(0.09, 0.09, 0.10, 1)))
            guard let identity = entry.identity else { continue }
            cards.append(CardDraw(identity: identity, imageRect: entry.contentRect, opacity: 1, frame: nil))
        }
        renderer.draw(layer: metalLayer,
                      cards: cards,
                      placeholders: placeholders,
                      viewBounds: bounds,
                      scale: backingScaleFactor)
    }

    func syncLayerGeometry() {
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.contentsScale = backingScaleFactor
        let pixels = CGSize(width: (bounds.width * backingScaleFactor).rounded(),
                            height: (bounds.height * backingScaleFactor).rounded())
        if pixels.width > 1, pixels.height > 1, metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
    }

    /// CG 全局（左上原点）到视图本地（左下原点）的换算。视图 frame 就是 viewport。
    private func viewRect(_ cgRect: CGRect) -> CGRect {
        CGRect(x: cgRect.minX - originInCG.x,
               y: (bounds.height + originInCG.y) - cgRect.maxY,
               width: cgRect.width,
               height: cgRect.height)
    }

    // MARK: - 命中的事实（供交互与探针共用）

    /// 命中的占用卡片：点击与拖动起点都用它。
    func hitTestCard(at point: CGPoint) -> (slot: RailSlotID, identity: WindowIdentity)? {
        guard let entry = slotRects.first(where: { $0.cellRect.contains(point) }), let identity = entry.identity else {
            return nil
        }
        return (entry.slot, identity)
    }

    /// 命中的逻辑 slot：拖动落点允许是空位（拖到空位就是移过去）。
    func hitTestSlot(at point: CGPoint) -> RailSlotID? {
        slotRects.first { $0.cellRect.contains(point) }?.slot
    }

    /// 某个 slot 的视图本地中心：P0 探针用它造真实鼠标事件。返回 nil 表示此刻不在画面上。
    func cellCenter(for slot: RailSlotID) -> CGPoint? {
        guard let entry = slotRects.first(where: { $0.slot == slot }) else { return nil }
        guard entry.cellRect.intersects(bounds) else { return nil }
        return CGPoint(x: entry.cellRect.midX, y: entry.cellRect.midY)
    }

    /// 可见的卡片格数：宿主测试与诊断用，证明"可见 n"不是编的。
    var visibleCardCount: Int {
        slotRects.filter { $0.identity != nil && $0.cellRect.intersects(bounds) }.count
    }

    // MARK: - 输入

    private struct PendingGesture {
        let start: CGPoint
        let slot: RailSlotID?
        let identity: WindowIdentity?
        let cellRect: CGRect?
    }

    private var gesture: PendingGesture?
    private var didDrag = false
    private static let dragThreshold: CGFloat = 10

    func cancelMouseGesture() {
        gesture = nil
        didDrag = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        let hit = hitTestCard(at: point)
        gesture = PendingGesture(start: point,
                                 slot: hit?.slot,
                                 identity: hit?.identity,
                                 cellRect: hit.flatMap { card in slotRects.first { $0.slot == card.slot }?.cellRect })
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = gesture, start.slot != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.start.x, point.y - start.start.y) > Self.dragThreshold else { return }
        didDrag = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { cancelMouseGesture() }
        guard let start = gesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        if didDrag {
            let screen = window?.convertPoint(toScreen: event.locationInWindow) ?? point
            guard let from = start.slot else { return }
            onAction?(.cardDragged(from: from, screenPoint: screen))
            return
        }
        guard let slot = start.slot, let identity = start.identity else { return }
        // 起点必须仍在同一个格子里，否则这次按下落在已被重排的画面之上。
        guard slotRects.first(where: { $0.slot == slot })?.cellRect == start.cellRect else { return }
        guard hitTestCard(at: point)?.slot == slot else { return }
        onAction?(.cardClicked(slot: slot, identity: identity))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredSlot != nil else { return }
        hoveredSlot = nil
        refreshChrome()
    }

    private func updateHover(_ point: CGPoint) {
        let next = hitTestCard(at: point)?.slot
        guard next != hoveredSlot else { return }
        hoveredSlot = next
        refreshChrome()
    }

    private var trackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    /// 滚动只提出新偏移；夹取与快照提交都在 reducer 里做（方案 §6、§11.2）。
    override func scrollWheel(with event: NSEvent) {
        let delta: CGFloat
        switch rail {
        case .top:
            delta = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
        case .side:
            delta = event.scrollingDeltaY
        }
        guard delta != 0 else { return }
        // 非翻转视图里 offset 增大 = 内容上移；AppKit 的 deltaY 为正表示"向上滚"。
        onAction?(.scrolled(rail: rail, to: scrollOffset - delta))
    }

    override func layout() {
        super.layout()
        syncLayerGeometry()
    }
}

/// 空位的轻量外观：只留一圈淡边与"空位"字样，不残留已关闭窗口的标题（方案 §6.2）。
final class EmptySlotChrome {
    let container = CALayer()
    private let border = CALayer()
    private let label = CATextLayer()

    init() {
        container.masksToBounds = true
        container.contentsScale = 2
        border.borderWidth = 1
        border.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        container.addSublayer(border)
        label.alignmentMode = .center
        label.truncationMode = .end
        label.isWrapped = false
        label.fontSize = 10
        label.font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 10, nil)
        label.foregroundColor = NSColor.tertiaryLabelColor.cgColor
        label.contentsScale = 2
        label.string = "空位"
        container.addSublayer(label)
    }

    func layout(in rect: CGRect, style: OverviewStyle, scale: CGFloat) {
        container.frame = rect
        border.frame = CGRect(origin: .zero, size: rect.size)
        container.cornerRadius = style.cornerRadius
        border.cornerRadius = style.cornerRadius
        label.contentsScale = scale
        label.frame = CGRect(x: 0, y: rect.height / 2 - 6, width: rect.width, height: 12)
    }
}
