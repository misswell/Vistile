import AppKit
import CoreGraphics
import Foundation
import Metal
import QuartzCore
import VistileCore

/// 总览内容视图：CAMetalLayer 合成画面，CALayer 画标题与边框。
/// 视图坐标系用 isFlipped = false（AppKit 左下原点），布局传入 CG 全局坐标后由这里显式换算。
final class OverviewContentView: NSView {
    enum Action: Hashable {
        case cardClicked(WindowIdentity)
        case backgroundClicked(slotClicked: WindowIdentity?)
        case cardDragged(from: SlotID, to: SlotID)
        case keyboardSelected(SlotID)
        case organize
        case exit
        case search(String)
    }

    var onAction: ((Action) -> Void)?
    var searchQuery: String = ""

    private let metalLayer = CAMetalLayer()
    private var chromeLayers: [SlotID: CardChrome] = [:]
    private var slotRects: [(slot: SlotID, identity: WindowIdentity, cellRect: CGRect, imageRect: CGRect)] = []
    private(set) var lastRecords: [WindowIdentity: WindowRecord] = [:]
    private var selectedSlot: SlotID?
    private var hoveredSlot: SlotID?
    private var accentColor = NSColor.controlAccentColor
    private var showsTitles = true
    private var style: OverviewStyle = .standard
    /// CG 全局坐标原点到视图左下的换算基准。
    private var originInCG = CGPoint.zero
    private var backingScaleFactor: CGFloat = 2
    private let titleLabel = CATextLayer()
    private let queryLabel = CATextLayer()
    private let hintLabel = CATextLayer()

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer = CALayer()
        layer?.masksToBounds = true
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = true
        metalLayer.contentsScale = 2
        metalLayer.zPosition = 0
        layer?.addSublayer(metalLayer)
        // chrome/toolbar 用 zPosition 排序：画面在最下，装饰在中，工具条在上。
        let chrome = CALayer()
        chrome.name = "chrome"
        chrome.zPosition = 1
        layer?.addSublayer(chrome)
        let toolbarHost = CALayer()
        toolbarHost.name = "toolbar"
        toolbarHost.zPosition = 2
        layer?.addSublayer(toolbarHost)
        for label in [titleLabel, queryLabel, hintLabel] {
            label.alignmentMode = .left
            label.truncationMode = .end
            label.isWrapped = false
            label.fontSize = 12
            label.font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 12, nil)
            label.contentsScale = backingScaleFactor
            label.isHidden = true
            toolbarHost.addSublayer(label)
        }
        hintLabel.alignmentMode = .center
        queryLabel.alignmentMode = .right
    }

    private var chromeHost: CALayer? {
        layer?.sublayers?.first { $0.name == "chrome" }
    }

    private var toolbarHost: CALayer? {
        layer?.sublayers?.first { $0.name == "toolbar" }
    }

    // MARK: - 配置

    func configure(style: OverviewStyle, showsTitles: Bool, accent: NSColor, cgOrigin: CGPoint, scale: CGFloat) {
        self.style = style
        self.showsTitles = showsTitles
        accentColor = accent
        originInCG = cgOrigin
        backingScaleFactor = scale
        metalLayer.contentsScale = scale
        for label in [titleLabel, queryLabel, hintLabel] {
            label.contentsScale = scale
            label.foregroundColor = NSColor.secondaryLabelColor.cgColor
        }
        titleLabel.foregroundColor = NSColor.labelColor.cgColor
        layoutToolbar()
    }

    /// 工具条只承载三个事实：数量、当前搜索词、一次性提示。
    func updateToolbar(total: Int, shown: Int, query: String, hint: String?) {
        titleLabel.string = "窗口总览 \(shown)/\(total)"
        queryLabel.string = query.isEmpty ? "" : "筛选：\(query)（⌫ 删除，Esc 清除）"
        hintLabel.string = hint ?? ""
        queryLabel.isHidden = query.isEmpty
        hintLabel.isHidden = hint?.isEmpty ?? true
        titleLabel.isHidden = false
        layoutToolbar()
    }

    private func layoutToolbar() {
        guard bounds.width > 2 * style.margin else { return }
        // CG 坐标里可用区顶部让出的那条带，翻回视图坐标后仍在顶部。
        let band = CGRect(x: originInCG.x + style.margin,
                          y: originInCG.y + style.margin,
                          width: bounds.width - 2 * style.margin,
                          height: style.toolbarHeight)
        let rect = viewRect(band)
        let textHeight: CGFloat = 15
        let originY = rect.midY - textHeight / 2
        titleLabel.frame = CGRect(x: rect.minX, y: originY, width: 180, height: textHeight)
        hintLabel.frame = CGRect(x: rect.minX + 190, y: originY, width: max(0, rect.width - 560), height: textHeight)
        queryLabel.frame = CGRect(x: rect.maxX - 360, y: originY, width: 360, height: textHeight)
    }

    /// 布局与画面一起更新；行列结构在总览期间冻结，只有整理才重排。
    func update(layout: GridLayout,
                records: [WindowIdentity: WindowRecord],
                frameByID: (WindowIdentity) -> CGRect?,
                renderer: OverviewRenderer,
                mailboxes: (WindowIdentity) -> FrameMailbox<MetalFrame>?) {
        let oldRects = Dictionary(uniqueKeysWithValues: slotRects.map { ($0.slot, $0.cellRect) })
        lastRecords = records
        slotRects = layout.cards.compactMap { card in
            guard let identity = identityAt(card.slot, records: records) else { return nil }
            return (card.slot, identity, viewRect(card.cellRect), viewRect(card.imageRect))
        }
        selectedSlot = selectedSlot.flatMap { layout.card(at: $0) != nil ? $0 : nil }

        // 同步装饰层，避免每帧重画文字。
        let host = chromeHost
        var keep: Set<SlotID> = []
        for card in layout.cards {
            guard let entry = slotRects.first(where: { $0.slot == card.slot }) else { continue }
            keep.insert(card.slot)
            let chrome = chromeLayers[card.slot] ?? {
                let created = CardChrome()
                host?.addSublayer(created.container)
                chromeLayers[card.slot] = created
                return created
            }()
            let record = records[entry.identity]
            chrome.layout(in: entry.cellRect, style: style, showsTitle: showsTitles)
            chrome.apply(title: "\(record?.applicationName ?? "") — \(record?.title ?? "")",
                         status: statusText(record?.capture),
                         isSelected: selectedSlot == card.slot,
                         isHovered: hoveredSlot == card.slot,
                         accent: accentColor,
                         style: style,
                         showsTitle: showsTitles,
                         scale: backingScaleFactor)
        }
        for (slot, chrome) in chromeLayers where !keep.contains(slot) {
            chrome.container.removeFromSuperlayer()
            chromeLayers.removeValue(forKey: slot)
        }

        // 画面矩形未变且行列未变时，只重绘有变化的纹理。
        let layoutChanged = Dictionary(uniqueKeysWithValues: slotRects.map { ($0.slot, $0.cellRect) }) != oldRects
        redraw(using: renderer, records: records, frameByID: frameByID, mailboxes: mailboxes, force: layoutChanged)
    }

    private func identityAt(_ slot: SlotID, records: [WindowIdentity: WindowRecord]) -> WindowIdentity? {
        records.values.first { $0.slot == slot && $0.capture != .closed && matchesSearch($0) }?.identity
    }

    private func matchesSearch(_ record: WindowRecord) -> Bool {
        searchQuery.isEmpty
            || record.title.localizedCaseInsensitiveContains(searchQuery)
            || record.applicationName.localizedCaseInsensitiveContains(searchQuery)
    }

    private func statusText(_ capture: CapturePhase?) -> String? {
        switch capture {
        case .lowFrequency(let interval): return "低频 \(interval)ms"
        case .pausedMinimized: return "已最小化"
        case .permissionMissing: return "无录屏权限"
        case let .notCapturable(reason): return reason.isEmpty ? "不可捕获" : reason
        case .closed: return "已关闭"
        case .live: return nil
        case .starting: return "启动中"
        case .idle, .none: return nil
        }
    }

    // MARK: - 绘制

    func redraw(using renderer: OverviewRenderer,
               records: [WindowIdentity: WindowRecord],
               frameByID: (WindowIdentity) -> CGRect?,
               mailboxes: (WindowIdentity) -> FrameMailbox<MetalFrame>?,
               force: Bool = false) {
        let sources = slotRects.map { ($0.identity, mailboxes($0.identity)) }.compactMap { identity, mailbox in
            mailbox.map { (identity, $0) }
        }
        let changed = renderer.absorbFrames(from: sources)
        guard changed || force else { return }

        let drawableSize = CGSize(width: (bounds.width * backingScaleFactor).rounded(),
                                  height: (bounds.height * backingScaleFactor).rounded())
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.drawableSize = drawableSize

        var cards: [CardDraw] = []
        var placeholders: [(rect: CGRect, tint: SIMD4<Float>)] = []
        for entry in slotRects {
            let record = records[entry.identity]
            // 等比例画面：格子均匀但比例不同时留白由底色填补，绝不裁切。
            let tint = record?.capture == .closed
                ? SIMD4<Float>(0.11, 0.11, 0.12, 1)
                : SIMD4<Float>(0.09, 0.09, 0.10, 1)
            placeholders.append((rect: entry.cellRect, tint: tint))
            cards.append(CardDraw(identity: entry.identity,
                                  imageRect: entry.imageRect,
                                  opacity: record?.capture == .closed ? 0 : 1,
                                  frame: nil))
        }
        renderer.draw(layer: metalLayer,
                      cards: cards,
                      placeholders: placeholders,
                      viewBounds: bounds,
                      scale: backingScaleFactor)
    }

    /// 视图本地坐标：CG 全局（左上原点）平移到视图左下原点。
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

    // MARK: - 输入

    private func slot(at point: CGPoint) -> (slot: SlotID, identity: WindowIdentity)? {
        // 命中测试用卡片外框，保证标题条也能点。
        slotRects.first { $0.cellRect.contains(point) }.map { ($0.slot, $0.identity) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = slot(at: point) else {
            onAction?(.backgroundClicked(slotClicked: nil))
            return
        }
        onAction?(.cardClicked(hit.identity))
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
        needsDisplay = true
    }

    private func updateHover(_ point: CGPoint) {
        let next = slot(at: point)?.slot
        guard next != hoveredSlot else { return }
        hoveredSlot = next
        needsDisplay = true
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

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            // 有筛选词时 Esc 先清除筛选，其次才退出总览（方案 §11：Esc 只在总览持有键盘焦点时生效）。
            if searchQuery.isEmpty { onAction?(.exit) } else { setQuery("") }
        case 51:
            if !searchQuery.isEmpty { setQuery(String(searchQuery.dropLast())) }
        case 36, 76: selectCurrent()              // Return
        case 123: moveSelection(column: -1)
        case 121: moveSelection(row: 1)
        case 122: moveSelection(row: -1)
        case 124: moveSelection(column: 1)
        case 49 where event.modifierFlags.contains(.option): onAction?(.organize)
        case 3 where event.modifierFlags.contains(.command): onAction?(.search(searchQuery))
        default:
            if event.characters?.count == 1, let character = event.characters?.first,
               !event.modifierFlags.contains(.command) {
                setQuery(searchQuery + String(character))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func setQuery(_ text: String) {
        searchQuery = text
        onAction?(.search(text))
    }

    private func selectCurrent() {
        guard let slot = selectedSlot, let entry = slotRects.first(where: { $0.slot == slot }) else { return }
        onAction?(.cardClicked(entry.identity))
    }

    func setSelected(_ slot: SlotID?) {
        guard slot != selectedSlot else { return }
        selectedSlot = slot
        needsDisplay = true
    }

    /// 方向键选择邻近 slot：按行列坐标而不是数组顺序（方案 §11）。
    private func moveSelection(column: Int = 0, row: Int = 0) {
        let slots = slotRects.map(\.slot).sorted()
        guard !slots.isEmpty else { return }
        guard let current = selectedSlot, let index = slots.firstIndex(of: current) else {
            setSelected(slots.first)
            onAction?(slots.first.map { .keyboardSelected($0) } ?? .keyboardSelected(slots[0]))
            return
        }
        let columns = max(1, nearestColumnCount())
        let flat = index + row * columns + column
        let clamped = min(max(flat, 0), slots.count - 1)
        setSelected(slots[clamped])
        onAction?(.keyboardSelected(slots[clamped]))
    }

    private func nearestColumnCount() -> Int {
        guard let first = slotRects.first else { return 1 }
        let sameRow = slotRects.filter { abs($0.cellRect.minY - first.cellRect.minY) < 2 }
        return max(1, sameRow.count)
    }

    /// 拖动卡片调整顺序是明确的编辑动作，交换 slot 并持久化。
    private var dragStart: (point: CGPoint, slot: SlotID)?
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if dragStart == nil, let hit = slot(at: point) {
            dragStart = (point, hit.slot)
            return
        }
        guard let start = dragStart, hypot(point.x - start.point.x, point.y - start.point.y) > 12,
              let target = slot(at: point), target.slot != start.slot else { return }
        onAction?(.cardDragged(from: start.slot, to: target.slot))
        dragStart = nil
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func layout() {
        super.layout()
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        layoutToolbar()
    }

    // MARK: - 无障碍

    /// VoiceOver 需要读到的卡片事实：位置取屏幕全局坐标，状态取目录里的真实捕获阶段。
    var accessibilityCardDescriptors: [CardAccessibilityDescriptor] {
        slotRects.map { entry in
            let record = lastRecords[entry.identity]
            let screenRect = window?.convertToScreen(entry.cellRect) ?? entry.cellRect
            return CardAccessibilityDescriptor(
                screenRect: screenRect,
                applicationName: record?.applicationName ?? "未知应用",
                title: record?.title ?? "",
                statusText: Self.accessibilityStatus(record?.capture),
                slotIndex: entry.slot.index,
                activate: { [weak self] in self?.onAction?(.cardClicked(entry.identity)) }
            )
        }
    }

    /// 状态描述必须与实际能力一致：轮询、最小化、无权限都不能说成实时。
    private static func accessibilityStatus(_ capture: CapturePhase?) -> String {
        switch capture {
        case .live: return "实时画面"
        case .starting: return "正在启动实时画面"
        case let .lowFrequency(interval): return "低频更新，间隔 \(interval) 毫秒"
        case .pausedMinimized: return "已最小化，画面暂停"
        case .permissionMissing: return "缺少屏幕录制权限，无画面"
        case .notCapturable: return "该窗口不允许捕获"
        case .closed: return "窗口已关闭"
        case .idle, .none: return "尚未取得画面"
        }
    }
}
