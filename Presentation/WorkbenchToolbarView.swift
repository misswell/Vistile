import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 工作台角落工具区（方案 §5.1、§9.3）：位于顶栏面板内部、主区之外。
/// 只承载四个动作（全部窗口、侧栏方向、搜索、文字事实），不复制会话状态。
final class WorkbenchToolbarView: NSView, NSSearchFieldDelegate {
    enum Action {
        case returnToOverview
        case toggleSide
        case searchFocus(Bool)
        case search(String)
    }

    var onAction: ((Action) -> Void)?

    private let countLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let allWindowsButton = NSButton()
    private let sideButton = NSButton()
    private let searchField = NSSearchField()
    /// 搜索框此刻是否持有键盘：只影响面板 key 策略，不改会话状态。
    private(set) var searchHasKeyboard = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    private func build() {
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.isEditable = false
        countLabel.isBordered = false
        countLabel.drawsBackground = false
        addSubview(countLabel)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.isEditable = false
        hintLabel.isBordered = false
        hintLabel.drawsBackground = false
        hintLabel.stringValue = ""
        addSubview(hintLabel)

        allWindowsButton.title = "全部窗口"
        allWindowsButton.bezelStyle = .rounded
        allWindowsButton.controlSize = .small
        allWindowsButton.target = self
        allWindowsButton.action = #selector(returnToOverview)
        allWindowsButton.toolTip = "回到完整总览（保留这次的主区上下文）"
        addSubview(allWindowsButton)

        sideButton.bezelStyle = .rounded
        sideButton.controlSize = .small
        sideButton.target = self
        sideButton.action = #selector(toggleSide)
        addSubview(sideButton)

        searchField.placeholderString = "搜索窗口"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.isContinuous = true
        searchField.sendsSearchStringImmediately = true
        addSubview(searchField)
    }

    // MARK: - 事实同步

    func update(side: RailSide, visibleCount: Int, totalCount: Int, query: String, hint: String?) {
        countLabel.stringValue = "可见 \(visibleCount) / 共 \(totalCount)"
        hintLabel.stringValue = hint ?? ""
        sideButton.title = side == .right ? "侧栏：右 ‹" : "侧栏：左 ›"
        sideButton.toolTip = side == .right ? "把侧栏移到左边" : "把侧栏移到右边"
        if searchField.stringValue != query { searchField.stringValue = query }
    }

    /// 面板交出键盘时要让搜索框退出编辑态，否则下一次打开会继续吃掉按键。
    func endSearchEditing() {
        if searchHasKeyboard {
            searchHasKeyboard = false
            window?.makeFirstResponder(nil)
        }
    }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    var searchFieldFrame: NSRect { searchField.frame }

    /// P0 探针用它把真实鼠标事件落在「全部窗口」按钮上，不靠猜坐标。
    var allWindowsButtonFrame: NSRect { allWindowsButton.frame }

    // MARK: - 动作

    @objc private func returnToOverview() { onAction?(.returnToOverview) }
    @objc private func toggleSide() { onAction?(.toggleSide) }

    func controlTextDidBeginEditing(_ obj: Notification) {
        searchHasKeyboard = true
        onAction?(.searchFocus(true))
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard searchHasKeyboard else { return }
        searchHasKeyboard = false
        onAction?(.searchFocus(false))
    }

    func controlTextDidChange(_ obj: Notification) {
        onAction?(.search(searchField.stringValue))
    }

    /// Esc 在搜索框里先清筛选并交回键盘，不是退出工作台（方案 §4.5、§9.3）。
    override func cancelOperation(_ sender: Any?) {
        if !searchField.stringValue.isEmpty {
            searchField.stringValue = ""
            onAction?(.search(""))
        }
        window?.makeFirstResponder(nil)
        onAction?(.searchFocus(false))
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        let inset: CGFloat = 6
        let width = max(60, bounds.width - 2 * inset)
        var y = bounds.height - inset
        func place(_ height: CGFloat) -> NSRect {
            y -= height
            return NSRect(x: inset, y: y, width: width, height: height)
        }
        countLabel.frame = place(15)
        y -= 4
        allWindowsButton.frame = place(22)
        y -= 4
        sideButton.frame = place(22)
        y -= 4
        searchField.frame = place(22)
        y -= 4
        hintLabel.frame = place(15)
    }
}
