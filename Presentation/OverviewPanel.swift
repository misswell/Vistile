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
        titleBar.isHidden = !showsTitle
        border.borderColor = (isSelected ? accent : NSColor.white.withAlphaComponent(isHovered ? 0.32 : 0.14)).cgColor
        border.borderWidth = isSelected ? 2 : 1
        statusText.isHidden = status == nil
        statusText.string = status ?? ""
        container.cornerRadius = style.cornerRadius
        border.cornerRadius = style.cornerRadius
        iconSlot.isHidden = true
        _ = scale
    }

    func layout(in rect: CGRect, style: OverviewStyle, showsTitle: Bool) {
        container.frame = rect
        border.frame = CGRect(origin: .zero, size: rect.size)
        let barHeight: CGFloat = showsTitle ? style.titleHeight : 0
        // 视图未翻转，标题条要贴在格子上沿。
        titleBar.frame = CGRect(x: 0, y: rect.height - barHeight, width: rect.width, height: barHeight)
        titleText.frame = CGRect(x: 30, y: titleBar.bounds.midY - 7, width: max(0, rect.width - 34 - 56), height: 14)
        statusText.frame = CGRect(x: rect.width - 90, y: titleBar.bounds.midY - 6, width: 86, height: 12)
    }
}
