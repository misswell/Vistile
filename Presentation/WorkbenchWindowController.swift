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
    private let toolbar = WorkbenchToolbarView(frame: .zero)
    /// 面板整块内容：栏视图只占其中的 viewport，角落工具区是它的兄弟。
    /// 若把栏视图直接当 contentView，工具区会落在它的 frame 之外，点击在 hitTest 一级就被丢掉。
    private let topContent = NSView(frame: .zero)
    private let sideContent = NSView(frame: .zero)

    private var display: DisplayInfo
    private var mapper: CoordinateMapper
    /// 最近一次投影：命中判定与探针都用它，不重新推导。
    private var lastPresentation: WorkbenchPresentation?

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
        sideContent.addSubview(sideRailView)

        topRailView.onAction = { [weak self] action in self?.handle(action, from: .top) }
        sideRailView.onAction = { [weak self] action in self?.handle(action, from: .side) }
        toolbar.onAction = { [weak self] action in self?.handle(toolbarAction: action) }
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
        let topFrame = mapper.cgToAppKit(layout.topRailRect).integral
        let sideFrame = mapper.cgToAppKit(layout.sideRailRect).integral
        if topPanel.frame != topFrame { topPanel.setFrame(topFrame, display: isVisible) }
        if sidePanel.frame != sideFrame { sidePanel.setFrame(sideFrame, display: isVisible) }

        // 视图 frame 就是各自的 viewport：越出视口的卡片由视图 bounds 裁掉，不画进内边距。
        let topViewport = topPanel.convertFromScreen(mapper.cgToAppKit(layout.topViewport))
        let sideViewport = sidePanel.convertFromScreen(mapper.cgToAppKit(layout.sideViewport))
        if topRailView.frame != topViewport { topRailView.frame = topViewport }
        if sideRailView.frame != sideViewport { sideRailView.frame = sideViewport }

        let toolbarRect = topPanel.convertFromScreen(mapper.cgToAppKit(layout.cornerToolRect))
        if toolbar.frame != toolbarRect { toolbar.frame = toolbarRect }

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
                           renderer: renderer,
                           mailboxes: mailboxProvider)
        sideRailView.update(snapshot: presentation.snapshot,
                            cards: presentation.sideCards,
                            emptySlots: presentation.emptySlots,
                            renderer: renderer,
                            mailboxes: mailboxProvider)

        toolbar.update(side: presentation.side,
                       visibleCount: presentation.visibleCount,
                       totalCount: presentation.totalCount,
                       query: searchQuery,
                       hint: hint)
        if let hint { topRailView.toolTip = hint }
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
        for view in [topRailView, sideRailView] { view.cancelMouseGesture() }
        toolbar.endSearchEditing()
        setSearchKeyboard(false)
        for panel in [topPanel, sidePanel] { panel.orderOut(nil) }
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
        }
    }

    private func handle(toolbarAction action: WorkbenchToolbarView.Action) {
        switch action {
        case .returnToOverview: onAction?(.returnToOverview)
        case .toggleSide: onAction?(.toggleSide)
        case let .searchFocus(focused): onAction?(.searchFocus(focused))
        case let .search(query): onAction?(.search(query))
        }
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
