import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 总览承载窗口：普通 level 的无边框面板，位于其他普通窗口之上还是之下由
/// OrderingStrategy 与 P0 实测结论决定；这里不预设层级胜出。
final class OverviewPanel: NSPanel {
    var onRequestFirstClick: (() -> Void)?
    /// 只有总览持有键盘焦点时才接受键盘事件（方案 §7 不变量）。
    var acceptsKeyboard = false

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = true
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        title = "Vistile Overview"
        // 不激活面板也必须第一下就能点，不能要求双击。
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        onRequestFirstClick?()
        super.mouseDown(with: event)
    }
}

/// 卡片外观层：标题条、边框、状态标记。GPU 只合成画面，装饰用 CALayer，
/// 避免每帧栅格化文字（方案 §9.4）。
final class CardChrome {
    let container = CALayer()
    let border = CALayer()
    let titleBar = CALayer()
    let titleText = CATextLayer()
    let statusText = CATextLayer()
    let iconSlot = CALayer()
    /// 「已固定」标记：贴在卡片右上角，关掉标题也看得见（方案 §6.2）。
    let pinBadge = CATextLayer()

    init() {
        container.masksToBounds = true
        container.contentsScale = 2
        border.borderWidth = 1
        border.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        container.addSublayer(border)

        titleBar.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        titleText.alignmentMode = .left
        titleText.truncationMode = .end
        titleText.isWrapped = false
        titleText.fontSize = 11
        titleText.font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 11, nil)
        titleText.foregroundColor = NSColor.labelColor.cgColor
        titleText.contentsScale = 2
        titleBar.addSublayer(titleText)
        container.addSublayer(titleBar)

        statusText.fontSize = 10
        statusText.alignmentMode = .right
        statusText.foregroundColor = NSColor.secondaryLabelColor.cgColor
        statusText.contentsScale = 2
        statusText.isHidden = true
        titleBar.addSublayer(statusText)

        pinBadge.string = "已固定"
        pinBadge.fontSize = 9
        pinBadge.alignmentMode = .right
        pinBadge.truncationMode = .end
        pinBadge.isWrapped = false
        pinBadge.font = CTFontCreateWithName(".AppleSystemUIFont" as CFString, 9, nil)
        pinBadge.foregroundColor = NSColor.controlAccentColor.cgColor
        pinBadge.contentsScale = 2
        pinBadge.isHidden = true
        container.addSublayer(pinBadge)
    }

    /// 固定标记由展示事实驱动，与位置无关：pin 只在下次整理时改轨道（方案 §6.2）。
    func applyPinned(_ pinned: Bool) {
        pinBadge.isHidden = !pinned
    }

    /// Hover 只提升边框/底色，不移动格子、不放大挤动（方案 §8.1）。
    func apply(title: String,
               status: String?,
               isSelected: Bool,
               isHovered: Bool,
               accent: NSColor,
               style: OverviewStyle,
               showsTitle: Bool,
               scale: CGFloat) {
        titleText.string = title
        titleText.isHidden = !showsTitle
        // 关掉标题也不能把状态事实一起藏掉：已最小化、无权限必须还能看见（方案 §13.3）。
        titleBar.isHidden = !(showsTitle || status != nil)
        border.borderColor = (isSelected ? accent : NSColor.white.withAlphaComponent(isHovered ? 0.32 : 0.14)).cgColor
        border.borderWidth = isSelected ? 2 : 1
        statusText.isHidden = status == nil
        statusText.string = status ?? ""
        container.cornerRadius = style.cornerRadius
        border.cornerRadius = style.cornerRadius
        iconSlot.isHidden = true
        _ = scale
    }

    func layout(in rect: CGRect, style: OverviewStyle, showsTitle: Bool, showsStatus: Bool) {
        container.frame = rect
        border.frame = CGRect(origin: .zero, size: rect.size)
        // 关标题时若还有状态要说，标题条仍要留出高度，否则状态文字会被压成 0 高。
        let barHeight: CGFloat = (showsTitle || showsStatus) ? style.titleHeight : 0
        // 视图未翻转，标题条要贴在格子上沿。
        titleBar.frame = CGRect(x: 0, y: rect.height - barHeight, width: rect.width, height: barHeight)
        titleText.frame = CGRect(x: 30, y: titleBar.bounds.midY - 7, width: max(0, rect.width - 34 - 56), height: 14)
        statusText.frame = CGRect(x: rect.width - 90, y: titleBar.bounds.midY - 6, width: 86, height: 12)
        // 固定标记贴卡片右上角，不依赖标题条是否存在。
        pinBadge.frame = CGRect(x: max(0, rect.width - 52), y: max(0, rect.height - 15), width: 46, height: 12)
    }
}
