import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 每屏一个总览承载窗口（方案 §12）。窗口本身只做承载与坐标换算，
/// 层级策略由 OrderingStrategy 决定，具体是否稳定必须由 P0 实测记录。
final class OverviewWindowController {
    let displayID: UInt32
    private let panel: OverviewPanel
    let contentView: OverviewContentView
    var onAction: ((OverviewContentView.Action) -> Void)?

    private var display: DisplayInfo
    private var mapper: CoordinateMapper
    /// 键盘是否真的落到了内容视图：面板成为 key 不等于方向键/Esc 有人接。
    private(set) var keyboardAccepted = false

    init(display: DisplayInfo, mapper: CoordinateMapper, metal: MetalContext) {
        self.display = display
        self.mapper = mapper
        displayID = display.id
        // 面板 frame 用 AppKit 坐标；领域层坐标是 CG 全局，两者换算只发生在这里。
        let appKitVisible = Self.appKitFrame(for: display, mapper: mapper)
        panel = OverviewPanel(contentRect: appKitVisible)
        contentView = OverviewContentView(frame: CGRect(origin: .zero, size: appKitVisible.size), metal: metal)
        panel.contentView = contentView
        panel.contentView?.autoresizingMask = [.width, .height]
        applyDisplayConfiguration()
        // R01：视图事件只有一条出口——转接到控制器，再由协调层进状态机。
        // 不在每次 updateLayout 重复绑定，也不让视图直接持有协调器。
        contentView.onAction = { [weak self] action in
            self?.onAction?(action)
        }
    }

    /// 控制器最终 frame 的计算入口。传入的 mapper 必须覆盖全部显示器：
    /// CG→AppKit 翻转以主屏高度为基准，单屏 mapper 会把副屏翻成 y=0（方案 §9.1）。
    static func appKitFrame(for display: DisplayInfo, mapper: CoordinateMapper) -> CGRect {
        mapper.cgToAppKit(display.visibleFrame)
    }

    /// 显示器新增/移除由调用方重建控制器；这里只处理同一块屏的几何或倍率变化。
    func updateDisplay(_ display: DisplayInfo, mapper: CoordinateMapper) {
        guard display.id == displayID else { return }
        guard display.visibleFrame != self.display.visibleFrame || display.backingScale != self.display.backingScale else { return }
        self.display = display
        self.mapper = mapper
        let frame = Self.appKitFrame(for: display, mapper: mapper)
        // 面板、内容视图、倍率、drawableSize 必须一起改，否则画面按旧基准解释。
        panel.setFrame(frame, display: isVisible)
        contentView.frame = CGRect(origin: .zero, size: frame.size)
        applyDisplayConfiguration()
    }

    private func applyDisplayConfiguration() {
        contentView.configure(style: .standard,
                              showsTitles: true,
                              accent: .controlAccentColor,
                              cgOrigin: display.visibleFrame.origin,
                              scale: display.backingScale)
    }

    /// 实际"在交互里可见"的事实。交互期间收起用 alpha 隐藏（下屏 orderOut 实测 460–496ms），
    /// 窗口仍 ordered；只有隐藏/退出/换屏才真正 orderOut。
    private var presented = false
    var isVisible: Bool { presented }
    /// ordered 但已视觉收起的窗口：隐藏态收尾时要真正下屏。
    var isOrderedButHidden: Bool { panel.isVisible && !presented }
    var frameInCG: CGRect { display.visibleFrame }
    /// 面板实际落在屏幕上的 AppKit frame：宿主测试用它验证翻转结果，而不是只看 mapper 往返。
    var appKitPanelFrame: CGRect { panel.frame }
    /// 自己的窗口编号要交给目录排除，否则总览会镜像总览（方案 §6.9）。
    var windowNumber: UInt32 { UInt32(max(0, panel.windowNumber)) }
    var onFirstClick: (() -> Void)? {
        get { panel.onRequestFirstClick }
        set { panel.onRequestFirstClick = newValue }
    }

    func setKeyboardFocus(_ enabled: Bool) {
        panel.acceptsKeyboard = enabled
        if enabled {
            // 不激活面板也必须显式成为 key，并且把 first responder 交给内容视图，
            // 否则面板拿到 key 而视图不收键，方向键/Esc/搜索全部落空。
            panel.makeKeyAndOrderFront(nil)
            keyboardAccepted = panel.makeFirstResponder(contentView) && panel.firstResponder === contentView
        } else {
            keyboardAccepted = false
            let wasKey = panel.isKeyWindow
            // 交出键盘只做一件事：不管面板有没有真的成为 key，响应者都要回到窗口，
            // 否则下一个会话会让旧的内容视图继续接键。
            panel.makeFirstResponder(nil)
            // 让出键盘不等于把背景重新前置：交出激活状态即可，面板保持可见、不重新抢 key。
            if wasKey { NSApp.deactivate() }
        }
    }

    func show() {
        panel.isReleasedWhenClosed = false
        presented = true
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        if !panel.isVisible { panel.orderFrontRegardless() }
        contentView.needsDisplay = true
    }

    /// 让 App 激活之后再置前一次：仅凭 show() 的 orderFrontRegardless，前台应用的同级窗口仍可能盖住总览。
    func raisePanel() {
        panel.orderFrontRegardless()
    }

    func hide() {
        // 隐藏时正在进行的手势不能残留到下一次打开（方案 §13.1）。
        contentView.cancelMouseGesture()
        presented = false
        panel.orderOut(nil)
    }

    /// 交互路径的快速收起：只改透明度与命中，不触发 orderOut 的 460–496ms 下屏成本。
    func hideCheaply() {
        guard presented else { return }
        contentView.cancelMouseGesture()
        presented = false
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
    }

    /// Esc/背景点击的用户收起路径：总览必须在这一帧内从视野消失，
    /// 真正的 orderOut（单次实测 460–496ms，多屏还串行）延后到主队列空闲处执行；
    /// 这期间重开（show 恢复 alpha）则下屏自动取消，面板原地复用。
    func hideForUserDismissal() {
        hideCheaply()
        let panel = self.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        }
    }

    func applyOrdering(strategy: OrderingStrategy, relativeToWindowID: CGWindowID?) {
        switch strategy {
        case .normalLevelActivateAndRaise:
            panel.level = .normal
        case .orderedBelowTarget:
            // 接受窗口编号不等于跨应用稳定排序，P0 会以屏幕录制与顺序诊断验证实际表现。
            panel.level = .normal
            if let windowID = relativeToWindowID {
                panel.order(.below, relativeTo: Int(windowID))
            }
        case .splitBackgroundTiles:
            // 分块避让没有实现：这里只能保持整屏普通层级，不会避开目标区域。
            // 该值不再对用户开放，遗留持久化值由 SettingsModel 迁移到普通层级（方案 §12.1）。
            panel.level = .normal
        }
    }

    func updateLayout(_ layout: GridLayout,
                      records: [WindowIdentity: WindowRecord],
                      renderer: OverviewRenderer,
                      mailboxProvider: (WindowIdentity) -> FrameMailbox<MetalFrame>?,
                      style: OverviewStyle,
                      showsTitles: Bool,
                      searchQuery: String) {
        contentView.configure(style: style,
                              showsTitles: showsTitles,
                              accent: .controlAccentColor,
                              cgOrigin: display.visibleFrame.origin,
                              scale: display.backingScale)
        // 筛选词以领域状态为准：每屏面板都要跟上，不能只改工具条文字。
        contentView.setSearchQuery(searchQuery)
        contentView.update(layout: layout,
                           records: records,
                           frameByID: { records[$0]?.frame },
                           renderer: renderer,
                           mailboxes: mailboxProvider)
    }

    func setHoverFeedback(_ hint: String?) {
        panel.contentView?.toolTip = hint
    }

    /// 工具条三件事：数量、当前筛选词、一次性提示。都是文本，不引入可误点的控件。
    func setToolbar(total: Int, shown: Int, query: String, hint: String?) {
        contentView.updateToolbar(total: total, shown: shown, query: query, hint: hint)
    }

    var isKey: Bool { panel.isKeyWindow }
    /// 面板是否"愿意"成为 key：这是本仓库自己的门控（acceptsKeyboard），
    /// 不依赖系统此刻把前台给了谁，因此可以在宿主测试里确定。
    var canBecomeKey: Bool { panel.canBecomeKey }
    var level: NSWindow.Level { panel.level }
    /// 测试：廉价收起后窗口仍 ordered、只是 alpha=0 且不接鼠标。
    var panelAlpha: CGFloat { panel.alphaValue }
    var ignoresMouseEvents: Bool { panel.ignoresMouseEvents }
}

extension OverviewWindowController {
    /// 背景点击由面板自己的窗口接收：面板不是 ignoresMouseEvents，所以事件不会穿透到后面的应用；
    /// 卡片只是像素合成，不存在"点进卡片里的按钮"。这里只做一次显式确认，方便 P0 记录。
    func consumesBackgroundClicks() -> Bool {
        panel.ignoresMouseEvents == false && panel.contentView is OverviewContentView
    }
}
