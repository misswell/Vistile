import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 一个活动屏幕的工作台承载（方案 §15）：顶栏与侧栏各一个非激活面板。
/// 面板矩形直接来自冻结投影的 topRailRect/sideRailRect，因此结构上不可能覆盖 mainRect；
/// 坐标换算只发生在这里（CG 全局 ↔ AppKit ↔ 面板本地）。
final class WorkbenchWindowController {
    enum Action {
        case railCardClicked(slot: RailSlotID, identity: WindowIdentity)
        case railCardDragged(from: RailSlotID, to: RailSlotID)
        case railScrolled(rail: RailKind, offset: CGFloat)
        /// 分隔线拖动开始：宿主在这里重置写入节流窗口（方案 §11.2）。
        case railDividerDragBegan(rail: RailKind)
        /// 拖动中的尺寸（已 clamp 到 token 范围）：宿主每个事件只推本机预览；外部写入由宿主节流。
        case railDividerDragged(rail: RailKind, value: CGFloat)
        /// 松手：宿主做最终结算与写盘。
        case railDividerDragEnded(rail: RailKind, value: CGFloat)
        /// 右键菜单的「固定在顶部/取消固定」：只写偏好，卡片此刻不动（方案 §6.2）。
        case railPinToggled(identity: WindowIdentity)
        /// 「更多」菜单的「整理预览栏」：重排轨道的唯一入口（方案 §4.4）。
        case organize
        case returnToOverview
        case toggleSide
        case searchFocus(Bool)
        case search(String)
    }

    let displayID: UInt32
    var onAction: ((Action) -> Void)?

    private let topPanel = WorkbenchRailPanel(contentRect: .zero)
    private let sidePanel = WorkbenchRailPanel(contentRect: .zero)
    private let topRailView: WorkbenchRailView
    private let sideRailView: WorkbenchRailView
    private let topDividerView = WorkbenchDividerView(rail: .top, frame: .zero)
    private let sideDividerView = WorkbenchDividerView(rail: .side, frame: .zero)
    private let toolbar = WorkbenchToolbarView(frame: .zero)
    /// 面板整块内容：栏视图只占其中的 viewport，角落工具区与分隔线命中区是它的兄弟。
    /// 若把栏视图直接当 contentView，工具区会落在它的 frame 之外，点击在 hitTest 一级就被丢掉。
    private let topContent = NSView(frame: .zero)
    private let sideContent = NSView(frame: .zero)

    private var display: DisplayInfo
    private var mapper: CoordinateMapper
    /// 最近一次投影：命中判定与探针都用它，不重新推导。
    private var lastPresentation: WorkbenchPresentation?
    /// 分隔线拖动的抓取锚点：以按下点与当时的栏尺寸为基准算增量，面板随预览移动也不漂。
    private var dividerDrag: (rail: RailKind, startPoint: CGPoint, startValue: CGFloat)?

    init(display: DisplayInfo, mapper: CoordinateMapper, metal: MetalContext) {
        self.display = display
        self.mapper = mapper
        displayID = display.id
        topRailView = WorkbenchRailView(rail: .top, frame: .zero, metal: metal)
        sideRailView = WorkbenchRailView(rail: .side, frame: .zero, metal: metal)

        topPanel.contentView = topContent
        sidePanel.contentView = sideContent
        topContent.addSubview(topRailView)
        topContent.addSubview(toolbar)
        topContent.addSubview(topDividerView)
        sideContent.addSubview(sideRailView)
        sideContent.addSubview(sideDividerView)

        topRailView.onAction = { [weak self] action in self?.handle(action, from: .top) }
        sideRailView.onAction = { [weak self] action in self?.handle(action, from: .side) }
        toolbar.onAction = { [weak self] action in self?.handle(toolbarAction: action) }
        topDividerView.onDragBegan = { [weak self] point in self?.beginDividerDrag(rail: .top, screenPoint: point) }
        topDividerView.onDragged = { [weak self] point in self?.updateDividerDrag(rail: .top, screenPoint: point) }
        topDividerView.onDragEnded = { [weak self] point in self?.endDividerDrag(rail: .top, screenPoint: point) }
        sideDividerView.onDragBegan = { [weak self] point in self?.beginDividerDrag(rail: .side, screenPoint: point) }
        sideDividerView.onDragged = { [weak self] point in self?.updateDividerDrag(rail: .side, screenPoint: point) }
        sideDividerView.onDragEnded = { [weak self] point in self?.endDividerDrag(rail: .side, screenPoint: point) }
    }

    var isVisible: Bool { topPanel.isVisible || sidePanel.isVisible }
    var windowNumbers: [UInt32] {
        [UInt32(max(0, topPanel.windowNumber)), UInt32(max(0, sidePanel.windowNumber))]
    }
    var cachedPresentation: WorkbenchPresentation? { lastPresentation }
    var topPanelFrame: CGRect { topPanel.frame }
    var sidePanelFrame: CGRect { sidePanel.frame }
    var topRail: WorkbenchRailView { topRailView }
    var sideRail: WorkbenchRailView { sideRailView }
    var toolbarView: WorkbenchToolbarView { toolbar }
    var topDivider: WorkbenchDividerView { topDividerView }
    var sideDivider: WorkbenchDividerView { sideDividerView }
    var isSearchFocused: Bool { topPanel.isKeyWindow && toolbar.searchHasKeyboard }

    // MARK: - 展示同步

    func update(presentation: WorkbenchPresentation,
                renderer: OverviewRenderer,
                mailboxProvider: (WindowIdentity) -> FrameMailbox<MetalFrame>?,
                showsTitles: Bool,
                searchQuery: String,
                hint: String?) {
        lastPresentation = presentation
        let layout = presentation.snapshot.layout
        guard !layout.isDegenerate else {
            // 连一条栏都放不下：退化为"只有主区"，不产生零尺寸面板。
            hide()
            return
        }

        // 投影坐标先取整再设 frame：AppKit 会对面板 frame 舍入（原点下取整、尺寸上取整），
        // 主动对齐让命中判定与投影用同一个矩形，也避免面板边缘亚像素发糊。
        // 面板窗口覆盖栏与它到主区的整条空带（方案 §11.2）：分隔线命中区必须落在某个窗口里才收得到鼠标。
        let topFrame = mapper.cgToAppKit(layout.topPanelWindowRect).integral
        let sideFrame = mapper.cgToAppKit(layout.sidePanelWindowRect).integral
        if topPanel.frame != topFrame { topPanel.setFrame(topFrame, display: isVisible) }
        if sidePanel.frame != sideFrame { sidePanel.setFrame(sideFrame, display: isVisible) }

        // 视图 frame 就是各自的 viewport：越出视口的卡片由视图 bounds 裁掉，不画进内边距。
        let topViewport = topPanel.convertFromScreen(mapper.cgToAppKit(layout.topViewport))
        let sideViewport = sidePanel.convertFromScreen(mapper.cgToAppKit(layout.sideViewport))
        if topRailView.frame != topViewport { topRailView.frame = topViewport }
        if sideRailView.frame != sideViewport { sideRailView.frame = sideViewport }

        let toolbarRect = topPanel.convertFromScreen(mapper.cgToAppKit(layout.cornerToolRect))
        if toolbar.frame != toolbarRect { toolbar.frame = toolbarRect }

        // 分隔线命中区来自冻结投影：正常态只显示细分隔，拖动时不改这里的几何。
        let topDivider = topPanel.convertFromScreen(mapper.cgToAppKit(layout.topDividerRect))
        let sideDivider = sidePanel.convertFromScreen(mapper.cgToAppKit(layout.sideDividerRect))
        if topDividerView.frame != topDivider { topDividerView.frame = topDivider }
        if sideDividerView.frame != sideDivider { sideDividerView.frame = sideDivider }

        let chromeStyle = OverviewStyle(margin: layout.style.margin,
                                        gap: layout.style.cardGap,
                                        titleHeight: layout.style.titleHeight,
                                        cornerRadius: layout.style.cornerRadius)
        // 顶栏在 CG 里从左上角开始排：视图的换算基准取 viewport 的左上角。
        topRailView.configure(cgOrigin: layout.topViewport.origin,
                              scale: display.backingScale,
                              chromeStyle: chromeStyle,
                              showsTitles: showsTitles,
                              accent: .controlAccentColor)
        sideRailView.configure(cgOrigin: layout.sideViewport.origin,
                               scale: display.backingScale,
                               chromeStyle: chromeStyle,
                               showsTitles: showsTitles,
                               accent: .controlAccentColor)

        topRailView.update(snapshot: presentation.snapshot,
                           cards: presentation.topCards,
                           emptySlots: presentation.emptySlots,
                           searchQuery: searchQuery,
                           renderer: renderer,
                           mailboxes: mailboxProvider)
        sideRailView.update(snapshot: presentation.snapshot,
                            cards: presentation.sideCards,
                            emptySlots: presentation.emptySlots,
                            searchQuery: searchQuery,
                            renderer: renderer,
                            mailboxes: mailboxProvider)

        // 「可见 n」必须如实反映此刻屏幕上的卡片：筛选掉的整格已经不在栏里（方案 §5.5.5）。
        // 主区是真实窗口，不会因为筛选消失，仍然计入。
        let railVisible = presentation.cards.filter { card in
            card.isVisible && card.record.matches(searchQuery: searchQuery)
        }.count
        toolbar.update(side: presentation.side,
                       visibleCount: railVisible + (presentation.mainRecord != nil ? 1 : 0),
                       totalCount: presentation.totalCount,
                       query: searchQuery,
                       hint: hint)
        if let hint { topRailView.toolTip = hint }
    }

    /// 壁纸底铺好后调用：两栏必须重新压回壁纸底之上（底图会为了压住主窗口而下调层级）。
    func raisePanels() {
        for panel in [topPanel, sidePanel] { panel.orderFrontRegardless() }
    }

    /// 同一块屏的倍率/可用区变化：只更新坐标基准，几何重投影由下一次 update(presentation:) 完成。
    /// 屏幕集合变化（增删/分辨率）在工作台里走安全退出路径，不在这里悄悄改坐标。
    func updateDisplay(_ display: DisplayInfo, mapper: CoordinateMapper) {
        guard display.id == displayID else { return }
        self.display = display
        self.mapper = mapper
    }

    // MARK: - 生命周期

    func show() {
        for panel in [topPanel, sidePanel] {
            panel.isReleasedWhenClosed = false
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for view in [topRailView, sideRailView] {
            view.cancelMouseGesture()
            view.setHiddenRailIdentities([])
        }
        topDividerView.cancelMouseGesture()
        sideDividerView.cancelMouseGesture()
        dividerDrag = nil
        toolbar.endSearchEditing()
        setSearchKeyboard(false)
        for panel in [topPanel, sidePanel] { panel.orderOut(nil) }
    }

    /// 过渡承载层接管这些身份：两栏里对应的卡片先不画，避免同屏出现两份（方案 §10.6）。
    /// 返回 true 表示集合变了、调用方需要推一次新投影让隐藏生效。
    @discardableResult
    func setHiddenRailIdentities(_ identities: Set<WindowIdentity>) -> Bool {
        let topChanged = topRailView.setHiddenRailIdentities(identities)
        let sideChanged = sideRailView.setHiddenRailIdentities(identities)
        return topChanged || sideChanged
    }

    /// 搜索期间的 key 策略：只有搜索框在编辑时面板才接受键盘（方案 §9.3）。
    func setSearchKeyboard(_ enabled: Bool) {
        topPanel.acceptsKeyboard = enabled
        if enabled {
            topPanel.makeKeyAndOrderFront(nil)
            topPanel.makeFirstResponder(toolbar)
            toolbar.focusSearch()
        } else if topPanel.isKeyWindow {
            topPanel.makeFirstResponder(nil)
            if NSApp.isActive { NSApp.deactivate() }
        }
    }

    func applyOrdering(strategy: OrderingStrategy, relativeToWindowID: CGWindowID?) {
        switch strategy {
        case .normalLevelActivateAndRaise, .splitBackgroundTiles:
            for panel in [topPanel, sidePanel] { panel.level = .normal }
        case .orderedBelowTarget:
            for panel in [topPanel, sidePanel] { panel.level = .normal }
            if let windowID = relativeToWindowID {
                for panel in [topPanel, sidePanel] { panel.order(.below, relativeTo: Int(windowID)) }
            }
        }
    }

    // MARK: - 输入转接

    private func handle(_ action: WorkbenchRailView.Action, from rail: RailKind) {
        switch action {
        case let .cardClicked(slot, identity):
            onAction?(.railCardClicked(slot: slot, identity: identity))
        case let .cardDragged(from, screenPoint):
            guard let target = hitTestSlot(atScreenPoint: screenPoint), target != from else { return }
            onAction?(.railCardDragged(from: from, to: target))
        case let .scrolled(rail, offset):
            onAction?(.railScrolled(rail: rail, offset: offset))
        case let .cardPinToggled(_, identity):
            onAction?(.railPinToggled(identity: identity))
        }
    }

    private func handle(toolbarAction action: WorkbenchToolbarView.Action) {
        switch action {
        case .returnToOverview: onAction?(.returnToOverview)
        case .toggleSide: onAction?(.toggleSide)
        case .organize: onAction?(.organize)
        case let .searchFocus(focused): onAction?(.searchFocus(focused))
        case let .search(query): onAction?(.search(query))
        }
    }

    // MARK: - 分隔线拖动（方案 §11.2）

    private func beginDividerDrag(rail: RailKind, screenPoint: CGPoint) {
        guard let layout = lastPresentation?.snapshot.layout else { return }
        let startValue = rail == .top ? layout.topRailRect.height : layout.sideRailRect.width
        dividerDrag = (rail, screenPoint, startValue)
        onAction?(.railDividerDragBegan(rail: rail))
    }

    private func updateDividerDrag(rail: RailKind, screenPoint: CGPoint) {
        guard let value = dividerValue(rail: rail, screenPoint: screenPoint) else { return }
        onAction?(.railDividerDragged(rail: rail, value: value))
    }

    private func endDividerDrag(rail: RailKind, screenPoint: CGPoint) {
        defer { dividerDrag = nil }
        guard let value = dividerValue(rail: rail, screenPoint: screenPoint) else { return }
        onAction?(.railDividerDragEnded(rail: rail, value: value))
    }

    /// 抓取锚点 + 屏幕增量 → 新尺寸，clamp 到 token 范围；nil 表示没有进行中的拖动或投影。
    /// 增量从按下点算起（不是逐事件累加）：面板自己会随预览移动，逐事件增量会漂。
    private func dividerValue(rail: RailKind, screenPoint: CGPoint) -> CGFloat? {
        guard let drag = dividerDrag, drag.rail == rail,
              let layout = lastPresentation?.snapshot.layout else { return nil }
        let start = mapper.appKitToCg(CGRect(origin: drag.startPoint, size: .zero)).origin
        let current = mapper.appKitToCg(CGRect(origin: screenPoint, size: .zero)).origin
        let delta: CGFloat
        switch rail {
        case .top:
            // AppKit 向上为正，CG 向下为正：向下拖 = CG y 增大 = 栏更高。
            delta = current.y - start.y
        case .side:
            // 右栏向左拖、左栏向右拖都是"加宽"。
            delta = layout.side == .right ? start.x - current.x : current.x - start.x
        }
        let range = rail == .top ? layout.style.topHeightRange : layout.style.sideWidthRange
        return min(max(drag.startValue + delta, range.lowerBound), range.upperBound)
    }

    /// 跨栏拖动的落点判定：屏幕点先转回各自视图本地坐标，再按卡片外框命中。
    private func hitTestSlot(atScreenPoint point: CGPoint) -> RailSlotID? {
        for view in [topRailView, sideRailView] {
            guard let window = view.window else { continue }
            let windowPoint = window.convertPoint(fromScreen: point)
            let local = view.convert(windowPoint, from: nil)
            if let slot = view.hitTestSlot(at: local) { return slot }
        }
        return nil
    }
}
