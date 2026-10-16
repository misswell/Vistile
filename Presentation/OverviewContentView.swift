import AppKit
import Carbon.HIToolbox
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

    /// 领域状态是筛选词的唯一事实来源：同步时不回发 search 事件，否则与 reducer 成环。
    func setSearchQuery(_ text: String) {
        guard text != searchQuery else { return }
        searchQuery = text
    }

    /// 画面图层。设备必须来自启动时创建并共享的 MetalContext（R02）：
    /// 未绑定 device 的 CAMetalLayer 不会有任何 drawable，界面看起来"什么都画不出来"。
    let metalLayer = CAMetalLayer()
    private var chromeLayers: [SlotID: CardChrome] = [:]
    /// 一张卡片在视图本地坐标里的几何。可比较，是因为"几何有没有变"决定要不要重绘。
    private struct SlotGeometry: Equatable {
        let slot: SlotID
        let identity: WindowIdentity
        let cellRect: CGRect
        let imageRect: CGRect
    }
    private var slotRects: [SlotGeometry] = []
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

    /// 装饰层事实：宿主测试用它确认 hover/选中/状态真的落到图层外观，而不是只改了变量。
    func chrome(for slot: SlotID) -> CardChrome? { chromeLayers[slot] }
    /// 这一此刻命中的窗口：筛选或重排后用来验证"格子放的是哪个窗口"。
    func identityInCell(at point: CGPoint) -> WindowIdentity? { slot(at: point)?.identity }
    /// 某窗口当前所在格子的中心（视图坐标）：P0 探针用它造真实鼠标事件。
    /// 返回 nil 表示这个窗口此刻不在画面上，探针不许改用别的坐标蒙混。
    func cellCenter(for identity: WindowIdentity) -> CGPoint? {
        slotRects.first { $0.identity == identity }.map { CGPoint(x: $0.cellRect.midX, y: $0.cellRect.midY) }
    }
    /// 一个确定不落在任何格子里的视图坐标（P0 探针制造真实背景点击用）。
    func unoccupiedViewPoint() -> CGPoint? {
        guard bounds.width > 4, bounds.height > 4 else { return nil }
        let columns = 24, rows = 16
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: bounds.minX + (CGFloat(column) + 0.5) * bounds.width / CGFloat(columns),
                                    y: bounds.minY + (CGFloat(row) + 0.5) * bounds.height / CGFloat(rows))
                if slot(at: point) == nil, bounds.contains(point) { return point }
            }
        }
        return nil
    }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { false }
    /// 面板可以成为 key，但键盘事件只有落到 content view 才有方向键/Esc/搜索。
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    /// 共享设备由启动方注入；视图不得自建 device 或 commandQueue。
    init(frame frameRect: NSRect, metal: MetalContext) {
        super.init(frame: frameRect)
        commonInit()
        attach(device: metal.device)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// 绑定与纹理、管线同一台设备；显示器变化后仍复用这一条提交路径。
    func attach(device: MTLDevice) {
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
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
        syncLayerGeometry()
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
        let oldGeometry = slotRects
        lastRecords = records
        slotRects = layout.cards.compactMap { card in
            guard let identity = identityAt(card.slot, records: records) else { return nil }
            return SlotGeometry(slot: card.slot,
                                identity: identity,
                                cellRect: viewRect(card.cellRect),
                                imageRect: viewRect(card.imageRect))
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
            applyChrome(chrome, entry: entry, record: record)
        }
        for (slot, chrome) in chromeLayers where !keep.contains(slot) {
            chrome.container.removeFromSuperlayer()
            chromeLayers.removeValue(forKey: slot)
        }

        // 同一格子里画面矩形改变（源窗口 resize、标题条开关）也必须重绘，
        // 只比较 cellRect 会让比例已经变样的画面继续留在旧视口上。
        let geometryChanged = slotRects != oldGeometry
        redraw(using: renderer, mailboxes: mailboxes, force: geometryChanged)
    }

    private func identityAt(_ slot: SlotID, records: [WindowIdentity: WindowRecord]) -> WindowIdentity? {
        records.values.first { $0.slot == slot && matchesSearch($0) }?.identity
    }

    private func matchesSearch(_ record: WindowRecord) -> Bool {
        searchQuery.isEmpty
            || record.title.localizedCaseInsensitiveContains(searchQuery)
            || record.applicationName.localizedCaseInsensitiveContains(searchQuery)
    }

    private func applyChrome(_ chrome: CardChrome, entry: SlotGeometry, record: WindowRecord?) {
        let status = statusText(record?.capture)
        chrome.layout(in: entry.cellRect, style: style, showsTitle: showsTitles, showsStatus: status != nil)
        chrome.apply(title: "\(record?.applicationName ?? "") — \(record?.title ?? "")",
                     status: status,
                     isSelected: selectedSlot == entry.slot,
                     isHovered: hoveredSlot == entry.slot,
                     accent: accentColor,
                     style: style,
                     showsTitle: showsTitles,
                     scale: backingScaleFactor)
    }

    /// Hover / 键盘选择变化要立刻改到装饰层外观，不能只置 needsDisplay 或等 reconcile（方案 §13.3）。
    private func refreshChrome() {
        for (slot, chrome) in chromeLayers {
            guard let entry = slotRects.first(where: { $0.slot == slot }) else { continue }
            applyChrome(chrome, entry: entry, record: lastRecords[entry.identity])
        }
    }

    private func statusText(_ capture: CapturePhase?) -> String? {
        switch capture {
        case .lowFrequency(let interval): return "低频 \(interval)ms"
        case .pausedMinimized: return "已最小化"
        case .permissionMissing: return "无录屏权限"
        case let .notCapturable(reason): return reason.isEmpty ? "不可捕获" : reason
        case .live: return nil
        case .starting: return "启动中"
        case .idle, .none: return nil
        }
    }

    // MARK: - 绘制

    func redraw(using renderer: OverviewRenderer,
               mailboxes: (WindowIdentity) -> FrameMailbox<MetalFrame>?,
               force: Bool = false) {
        let sources = slotRects.map { ($0.identity, mailboxes($0.identity)) }.compactMap { identity, mailbox in
            mailbox.map { (identity, $0) }
        }
        let changed = renderer.absorbFrames(from: sources)
        guard changed || force else { return }

        syncLayerGeometry(renderer: renderer)

        var cards: [CardDraw] = []
        var placeholders: [(rect: CGRect, tint: SIMD4<Float>)] = []
        for entry in slotRects {
            // 等比例画面：格子均匀但比例不同时留白由底色填补，绝不裁切。
            placeholders.append((rect: entry.cellRect, tint: SIMD4<Float>(0.09, 0.09, 0.10, 1)))
            cards.append(CardDraw(identity: entry.identity,
                                  imageRect: entry.imageRect,
                                  opacity: 1,
                                  frame: nil))
        }
        renderer.draw(layer: metalLayer,
                      cards: cards,
                      placeholders: placeholders,
                      viewBounds: bounds,
                      scale: backingScaleFactor)
    }

    /// 尺寸、倍率与 drawableSize 必须一起改：只动 drawableSize 会让画面按旧 scale 解释，
    /// 拖到不同倍率屏幕上直接表现为模糊或错位（方案 §4.3）。
    func syncLayerGeometry(renderer: OverviewRenderer? = nil) {
        metalLayer.frame = CGRect(origin: .zero, size: bounds.size)
        metalLayer.contentsScale = backingScaleFactor
        if let renderer { renderer.bind(metalLayer) }
        let pixels = CGSize(width: (bounds.width * backingScaleFactor).rounded(),
                            height: (bounds.height * backingScaleFactor).rounded())
        if pixels.width > 1, pixels.height > 1, metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
        for label in [titleLabel, queryLabel, hintLabel] { label.contentsScale = backingScaleFactor }
        layoutToolbar()
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

    /// 一次鼠标手势的事实：起点、按下时命中的格子及其画面快照。
    /// mouseDown 不展开（R11）：按下即聚焦会让拖动永远变成展开。
    private struct PendingGesture {
        let start: CGPoint
        /// nil 表示按在背景上。
        let slot: SlotID?
        let identity: WindowIdentity?
        let cellRect: CGRect?
    }

    private enum DragDirection { case left, right, up, down }
    /// 超过该位移才算拖动，不算点击（方案 §13.1）。
    private static let dragThreshold: CGFloat = 10

    private var gesture: PendingGesture?
    private var didDrag = false

    /// 会话关闭、布局改变、窗口销毁、权限丢失都要取消进行中的手势。
    func cancelMouseGesture() {
        gesture = nil
        didDrag = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        didDrag = false
        let hit = slot(at: point)
        gesture = PendingGesture(start: point,
                                 slot: hit?.slot,
                                 identity: hit?.identity,
                                 cellRect: hit.flatMap { entry in slotRects.first { $0.slot == entry.slot }?.cellRect })
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
        if didDrag {
            // 交换目标由抬起位置决定，不由拖动过程中经过的格子决定；拖动不额外展开（方案 §13.1）。
            let release = convert(event.locationInWindow, from: nil)
            guard let target = slot(at: release)?.slot, target != start.slot else { return }
            onAction?(.cardDragged(from: start.slot!, to: target))
            return
        }
        guard let origin = start.slot, let identity = start.identity else {
            // down/up 完整序列落在背景：消费本次交互，不穿透到后面的应用。
            onAction?(.backgroundClicked(slotClicked: nil))
            return
        }
        // 起点必须仍在同一格子里，否则这次按下落在已被重排的画面之上。
        guard slotRects.first(where: { $0.slot == origin })?.cellRect == start.cellRect else { return }
        onAction?(.cardClicked(identity))
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
        let next = slot(at: point)?.slot
        guard next != hoveredSlot else { return }
        hoveredSlot = next
        // 装饰层外观要当场跟上，不能等下一次目录 reconcile（方案 §13.3）。
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

    // MARK: - 键盘

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            // 有筛选词时 Esc 先清除筛选，其次才退出总览（方案 §11：Esc 只在总览持有键盘焦点时生效）。
            if searchQuery.isEmpty { onAction?(.exit) } else { setQuery("") }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            selectCurrent()
        case kVK_LeftArrow: moveSelection(.left)
        case kVK_RightArrow: moveSelection(.right)
        case kVK_UpArrow: moveSelection(.up)
        case kVK_DownArrow: moveSelection(.down)
        case kVK_Space where event.modifierFlags.contains(.option):
            onAction?(.organize)
        case kVK_ANSI_F where event.modifierFlags.contains(.command):
            onAction?(.search(searchQuery))
        default:
            // 其余按键交给输入法解释：中文候选（marked text）经 insertText 提交，
            // 不能用 event.characters 拼接假装支持输入法。
            super.keyDown(with: event)
        }
    }

    /// 输入法/普通按键最终落到这里的文本才是筛选词。
    /// AppKit 的 `insertText:` 参数是 Any：字符串与带属性字符串都可能出现（IME 提交走后者）。
    override func insertText(_ insertString: Any) {
        let text: String
        if let attributed = insertString as? NSAttributedString {
            text = attributed.string
        } else {
            text = (insertString as? String) ?? ""
        }
        guard !text.isEmpty else { return }
        setQuery(searchQuery + text)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !searchQuery.isEmpty else { return }
        setQuery(String(searchQuery.dropLast()))
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
        refreshChrome()
    }

    /// 方向键按冻结网格里的实际邻接关系走，不按全局 SlotID 序号（方案 §13.2）：
    /// 稀疏编号与副屏格子不会因为序号跳跃而选错。空位与被筛掉的项本来就不在 slotRects 里。
    private func moveSelection(_ direction: DragDirection) {
        guard !slotRects.isEmpty else { return }
        let from = selectedSlot.flatMap { slot in slotRects.first { $0.slot == slot } } ?? topLeadingEntry()
        guard let fromEntry = from else { return }
        let unit: CGVector
        switch direction {
        case .left: unit = CGVector(dx: -1, dy: 0)
        case .right: unit = CGVector(dx: 1, dy: 0)
        case .up: unit = CGVector(dx: 0, dy: 1)   // 视图未翻转：向上是 y 增大
        case .down: unit = CGVector(dx: 0, dy: -1)
        }
        let fromCenter = CGPoint(x: fromEntry.cellRect.midX, y: fromEntry.cellRect.midY)
        // 同一行/列容差：偏移超过一格宽度（或高度）不算邻近，避免跨整屏乱跳。
        let laneLimit = unit.dx == 0 ? fromEntry.cellRect.width * 1.5 : fromEntry.cellRect.height * 1.5
        var best: (slot: SlotID, along: CGFloat, across: CGFloat)?
        for entry in slotRects where entry.slot != fromEntry.slot {
            let dx = entry.cellRect.midX - fromCenter.x
            let dy = entry.cellRect.midY - fromCenter.y
            let along = dx * unit.dx + dy * unit.dy
            guard along > 1 else { continue }
            let across = abs(dx * unit.dy - dy * unit.dx)
            guard across <= laneLimit else { continue }
            if let current = best {
                if along < current.along - 1 || (abs(along - current.along) <= 1 && across < current.across) {
                    best = (entry.slot, along, across)
                }
            } else {
                best = (entry.slot, along, across)
            }
        }
        // 边界上没有候选时保持当前选择，不做未声明的循环跳转。
        guard let target = best else { return }
        setSelected(target.slot)
        onAction?(.keyboardSelected(target.slot))
    }

    /// 未选中任何卡片时的起点：视觉左上角。
    private func topLeadingEntry() -> SlotGeometry? {
        slotRects.min { a, b in
            a.cellRect.maxY != b.cellRect.maxY ? a.cellRect.maxY > b.cellRect.maxY : a.cellRect.minX < b.cellRect.minX
        }
    }

    override func layout() {
        super.layout()
        syncLayerGeometry()
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
        case .idle, .none: return "尚未取得画面"
        }
    }
}
