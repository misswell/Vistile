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

    private let display: DisplayInfo

    init(display: DisplayInfo, metalLayerScale: CGFloat) {
        self.display = display
        displayID = display.id
        // 面板 frame 用 AppKit 坐标；领域层坐标是 CG 全局，两者换算只发生在这里。
        let mapper = CoordinateMapper(displays: [display])
        let appKitVisible = mapper.cgToAppKit(display.visibleFrame)
        panel = OverviewPanel(contentRect: appKitVisible)
        contentView = OverviewContentView(frame: CGRect(origin: .zero, size: appKitVisible.size))
        panel.contentView = contentView
        panel.contentView?.autoresizingMask = [.width, .height]
        contentView.configure(style: .standard,
                              showsTitles: true,
                              accent: .controlAccentColor,
                              cgOrigin: display.visibleFrame.origin,
                              scale: metalLayerScale)
    }

    var isVisible: Bool { panel.isVisible }
    var frameInCG: CGRect { display.visibleFrame }
    /// 自己的窗口编号要交给目录排除，否则总览会镜像总览（方案 §6.9）。
    var windowNumber: UInt32 { UInt32(max(0, panel.windowNumber)) }
    var onFirstClick: (() -> Void)? {
        get { panel.onRequestFirstClick }
        set { panel.onRequestFirstClick = newValue }
    }

    func setKeyboardFocus(_ enabled: Bool) {
        panel.acceptsKeyboard = enabled
        if enabled {
            // 不激活面板需要显式成为 key 才能收到方向键与 Esc。
            panel.makeKeyAndOrderFront(nil)
        } else if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func show() {
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        contentView.needsDisplay = true
    }

    func hide() {
        panel.orderOut(nil)
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
            // 分块避让由 FocusCoordinator 承载多个窗口，这里保持整屏面板隐藏。
            panel.level = .normal
        }
    }

    func updateLayout(_ layout: GridLayout,
                      records: [WindowIdentity: WindowRecord],
                      renderer: OverviewRenderer,
                      mailboxProvider: (WindowIdentity) -> FrameMailbox<MetalFrame>?,
                      style: OverviewStyle,
                      showsTitles: Bool) {
        contentView.configure(style: style,
                              showsTitles: showsTitles,
                              accent: .controlAccentColor,
                              cgOrigin: display.visibleFrame.origin,
                              scale: display.backingScale)
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
    var level: NSWindow.Level { panel.level }
    var ignoresMouseEvents: Bool { panel.ignoresMouseEvents }
}

extension OverviewWindowController {
    /// 背景点击由面板自己的窗口接收：面板不是 ignoresMouseEvents，所以事件不会穿透到后面的应用；
    /// 卡片只是像素合成，不存在"点进卡片里的按钮"。这里只做一次显式确认，方便 P0 记录。
    func consumesBackgroundClicks() -> Bool {
        panel.ignoresMouseEvents == false && panel.contentView is OverviewContentView
    }
}
