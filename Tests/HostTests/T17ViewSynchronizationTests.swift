import AppKit
import Carbon.HIToolbox
import VistileCore
import XCTest
@testable import Vistile

/// T17 视图同步（方案 §13.3）。
///
/// 这一组只问一件事：状态与外观是不是**当场**对得上。测试全部读真实的 CALayer 属性，
/// 不读视图内部的变量，因为用户看到的只有图层。面板摆在主屏之外，测试期间不落进用户桌面。
final class T17ViewSynchronizationTests: XCTestCase {
    private var controller: OverviewWindowController!
    private var renderer: OverviewRenderer!
    private var recorder: ActionRecorder!
    private var layout: GridLayout!
    private var records: [WindowIdentity: WindowRecord]!
    private var metal: MetalContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        metal = try HostFixtures.metalContext()
        renderer = try HostFixtures.renderer(metal: metal)
        controller = OverviewWindowController(display: HostFixtures.display, mapper: HostFixtures.mapper, metal: metal)
        recorder = ActionRecorder()
        controller.onAction = { [weak recorder] action in recorder?.record(action) }
        let built = HostFixtures.layout()
        layout = built.layout
        records = built.records
        sync(query: "", showsTitles: true)
    }

    override func tearDown() {
        controller?.setKeyboardFocus(false)
        controller?.hide()
        controller = nil
        renderer = nil
        recorder = nil
        layout = nil
        records = nil
        metal = nil
        super.tearDown()
    }

    private var view: OverviewContentView { controller.contentView }
    private var origin: CGPoint { HostFixtures.offscreenOrigin }

    private func sync(query: String, showsTitles: Bool = true, layout forced: GridLayout? = nil) {
        controller.updateLayout(forced ?? layout,
                                records: records,
                                renderer: renderer,
                                mailboxProvider: { _ in nil },
                                style: .standard,
                                showsTitles: showsTitles,
                                searchQuery: query)
    }

    private func center(of index: Int, in grid: GridLayout? = nil) -> CGPoint {
        HostFixtures.viewPoint(of: (grid ?? layout).cards[index].cellRect, in: view, cgOrigin: origin)
    }

    private func send(_ type: NSEvent.EventType, to point: CGPoint) {
        let event = HostEvents.mouse(type, in: view.window, point: point)
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .mouseMoved: view.mouseMoved(with: event)
        default: XCTFail("测试未覆盖的鼠标事件类型")
        }
    }

    /// 边框颜色就是 hover/选中的可见区别：读图层而不是读视图内部状态。
    private func borderColor(_ slot: SlotID) -> CGColor? {
        guard let chrome = view.chrome(for: slot) else {
            XCTFail("格子 \(slot.index) 没有装饰层"); return nil
        }
        return chrome.border.borderColor
    }

    /// 比较分量而不是 CGColor 本身：同一进程里由 `NSColor.cgColor` 产出的颜色空间一致，
    /// 但 CGColor 不是 Equatable，直接 XCTAssertEqual 会走 isEqual 并把"分量相同"判成假。
    private func assertBorder(_ slot: SlotID, _ color: NSColor, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = borderColor(slot) else { return }
        XCTAssertEqual(Array(actual.components ?? []),
                       Array(color.cgColor.components ?? []),
                       message, file: file, line: line)
    }

    // MARK: - hover / 键盘外观当场跟上

    func testHoverChangesBorderWithoutWaitingForReconcile() {
        let slot = layout.cards[1].slot
        assertBorder(slot, NSColor.white.withAlphaComponent(0.14), "未 hover 时边框必须是默认色，否则下面的断言毫无意义")

        recorder.reset()
        send(.mouseMoved, to: center(of: 1))
        assertBorder(slot, NSColor.white.withAlphaComponent(0.32),
                     "hover 只改外观，且要当场改：不能等 updateLayout 或 2s reconcile")
        XCTAssertTrue(recorder.actions.isEmpty, "hover 不该产生任何动作事件")

        send(.mouseMoved, to: center(of: 2))
        assertBorder(slot, NSColor.white.withAlphaComponent(0.14), "移开后旧格子要回到默认外观，不能一直亮着")
    }

    func testKeyboardSelectionDrawsAccentBorderImmediately() {
        let first = layout.cards[1].slot
        let next = layout.cards[3].slot
        view.keyDown(with: HostEvents.key(kVK_RightArrow))
        XCTAssertEqual(view.chrome(for: first)?.border.borderWidth, 2, "键盘选中必须落到边框宽度")
        assertBorder(first, NSColor.controlAccentColor, "选中框要用强调色")

        view.keyDown(with: HostEvents.key(kVK_DownArrow))
        XCTAssertEqual(view.chrome(for: next)?.border.borderWidth, 2, "选中要跟着移到下一格")
        assertBorder(next, NSColor.controlAccentColor, "新选中格要用强调色")
        XCTAssertEqual(view.chrome(for: first)?.border.borderWidth, 1, "旧选中格必须当场退回默认")

        view.setSelected(nil)
        XCTAssertEqual(view.chrome(for: next)?.border.borderWidth, 1, "取消选中后边框要回到默认")
    }

    // MARK: - 标题隐藏时的状态事实

    func testStatusSurvivesHiddenTitles() {
        let identity = HostFixtures.identity(0)
        records[identity]?.capture = .pausedMinimized
        sync(query: "", showsTitles: false)
        let chrome = view.chrome(for: layout.cards[0].slot)
        XCTAssertEqual(chrome?.titleText.isHidden, true, "用户关了标题，标题就该藏起来")
        XCTAssertEqual(chrome?.statusText.isHidden, false, "已最小化是功能事实，不能跟着标题一起消失")
        XCTAssertEqual(chrome?.statusText.string as? String, "已最小化")
        if let bar = chrome?.titleBar.frame.height {
            XCTAssertGreaterThan(bar, 0, "只留状态也得有高度，否则文字被压成 0 高")
        }
    }

    func testMissingPermissionIsStatedOnCard() {
        let identity = HostFixtures.identity(1)
        records[identity]?.capture = .permissionMissing
        sync(query: "", showsTitles: true)
        let chrome = view.chrome(for: layout.cards[1].slot)
        XCTAssertEqual(chrome?.statusText.isHidden, false)
        XCTAssertEqual(chrome?.statusText.string as? String, "无录屏权限")
    }

    // MARK: - 筛选与重排

    /// 筛完再清空必须回到原来的格子：筛选只改展示，不改 slot（方案 §8.3、§13.3）。
    func testFilteringThenClearingRestoresSameCells() {
        let before = slotByIndex()
        sync(query: "窗口 2")
        sync(query: "")
        XCTAssertEqual(slotByIndex(), before, "清空筛选后格子与窗口的对应关系必须原样回来")
    }

    /// 布局真的变了（密度/整理）时，按下的那一格已经不代表原来的画面：抬起不能展开。
    func testGestureIsCancelledWhenCellGeometryChanges() {
        let point = center(of: 0)
        send(.leftMouseDown, to: point)
        let compact = GridLayoutEngine.layout(
            sources: (0..<4).map { GridSource(slot: SlotID(index: $0), size: records[HostFixtures.identity($0)]!.frame.size) },
            availableRect: HostFixtures.visibleFrame,
            style: OverviewStyle.style(.compact))
        sync(query: "", layout: compact)
        recorder.reset()
        send(.leftMouseUp, to: point)
        XCTAssertTrue(recorder.actions.isEmpty, "格子矩形变了还照旧发点击，等于点开另一个窗口")
    }

    /// 每个格子里现在放的是哪个窗口：矩形取冻结布局，命中结果取视图实际状态。
    private func slotByIndex() -> [Int: UInt32] {
        var map: [Int: UInt32] = [:]
        for card in layout.cards {
            let rect = HostFixtures.viewRect(card.cellRect, in: view, cgOrigin: origin)
            if let identity = view.identityInCell(at: CGPoint(x: rect.midX, y: rect.midY)) {
                map[card.slot.index] = identity.windowID
            }
        }
        return map
    }
}
