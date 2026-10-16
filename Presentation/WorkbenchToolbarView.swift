import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 工作台角落工具区（方案 §5.1、§9.3）：位于顶栏面板内部、主区之外。
/// 只承载五个动作（全部窗口、侧栏方向、整理、搜索、文字事实），不复制会话状态。
final class WorkbenchToolbarView: NSView, NSSearchFieldDelegate {
    enum Action {
        case returnToOverview
        case toggleSide
        /// 「更多」菜单里的「整理预览栏」：唯一会重排轨道的动作（方案 §4.4、§6.2）。
        case organize
        case searchFocus(Bool)
        case search(String)
    }

    var onAction: ((Action) -> Void)?

    private let countLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let allWindowsButton = NSButton()
    private let sideButton = NSButton()
    private let moreButton = NSButton()
    private let searchField = NSSearchField()
    /// 「更多」菜单在 build 里搭好、点击时弹出：探针/宿主测试直接取菜单项触发动作，不真弹（弹窗会起嵌套事件循环）。
    let moreMenu = NSMenu()
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

        moreButton.title = "更多"
        moreButton.bezelStyle = .rounded
        moreButton.controlSize = .small
        moreButton.target = self
        moreButton.action = #selector(showMoreMenu)
        moreButton.toolTip = "整理预览栏等轨道操作"
        addSubview(moreButton)

        let organizeItem = NSMenuItem(title: "整理预览栏",
                                      action: #selector(organizeRequested),
                                      keyEquivalent: "")
        organizeItem.target = self
        organizeItem.toolTip = "把卡片收拢排序：固定的应用优先占顶栏，其余按总览顺序"
        moreMenu.autoenablesItems = false
        moreMenu.addItem(organizeItem)

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
        // 紧凑档里提示会被截断，完整文字必须还能读到。
        hintLabel.toolTip = hint
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
    var moreButtonFrame: NSRect { moreButton.frame }

    // MARK: - 动作

    @objc private func returnToOverview() { onAction?(.returnToOverview) }
    @objc private func toggleSide() { onAction?(.toggleSide) }
    @objc private func showMoreMenu() {
        moreMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: moreButton)
    }
    @objc private func organizeRequested() { onAction?(.organize) }

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

    /// 角落高度随窗口收缩，最小只有约 96pt（方案 §11.2 的 clamp 下界），
    /// 固定竖排需要 118pt，所以按实测高度分两档收紧：
    /// <118pt 把提示并进计数行（需 99pt），<99pt 再收内边距与行距（需 94pt）——任何合法高度都不溢出。
    override func layout() {
        super.layout()
        let compact = bounds.height < 118
        let tight = bounds.height < 99
        let inset: CGFloat = tight ? 4 : 6
        let spacing: CGFloat = tight ? 3 : 4
        let width = max(60, bounds.width - 2 * inset)
        var y = bounds.height - inset
        func place(_ height: CGFloat) -> NSRect {
            y -= height
            return NSRect(x: inset, y: y, width: width, height: height)
        }
        let countRow = place(15)
        if compact {
            // 提示右对齐截断，完整文字留在 tooltip：压排版不压事实。
            hintLabel.alignment = .right
            let countWidth = min(countRow.width, ceil(countLabel.intrinsicContentSize.width) + 2)
            countLabel.frame = NSRect(x: countRow.minX, y: countRow.minY,
                                      width: countWidth, height: countRow.height)
            hintLabel.frame = NSRect(x: countRow.minX + countWidth + 6, y: countRow.minY,
                                     width: max(0, countRow.width - countWidth - 6),
                                     height: countRow.height)
        } else {
            countLabel.frame = countRow
            hintLabel.alignment = .left
        }
        y -= spacing
        // 「全部窗口」与「更多」并排一行：工具区高度已经紧，按钮不加行。
        let buttonsRow = place(22)
        let half = max(28, (buttonsRow.width - 4) / 2)
        allWindowsButton.frame = NSRect(x: buttonsRow.minX,
                                        y: buttonsRow.minY,
                                        width: half,
                                        height: buttonsRow.height)
        moreButton.frame = NSRect(x: buttonsRow.minX + half + 4,
                                  y: buttonsRow.minY,
                                  width: half,
                                  height: buttonsRow.height)
        y -= spacing
        sideButton.frame = place(22)
        y -= spacing
        searchField.frame = place(22)
        if !compact {
            y -= spacing
            hintLabel.frame = place(15)
        }
    }
}
