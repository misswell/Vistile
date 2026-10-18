import AppKit
import Carbon.HIToolbox
import VistileCore
import XCTest
@testable import Vistile

/// T01 控制器事件转接：视图动作到达 controller 恰好一次，键盘焦点真的落到内容视图。
///
/// 全部通过真实入口驱动：真实 NSEvent + 真实 NSView 事件方法 + 真实 first responder 调用。
/// 面板摆在主屏之外的负坐标，测试期间用户桌面上不会出现总览窗口。
final class T01ActionRoutingTests: XCTestCase {
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
        sync(query: "")
    }

    override func tearDown() {
        controller?.setKeyboardFocus(false)
        controller?.hide()
        // 测试临时拿到的前台激活必须还给系统，不能让测试宿主留在用户前面。
        NSApp.deactivate()
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

    private func sync(query: String) {
        controller.updateLayout(layout,
                                records: records,
                                renderer: renderer,
                                mailboxProvider: { _ in nil },
                                style: .standard,
                                showsTitles: true,
                                searchQuery: query)
    }

    private func viewCell(_ index: Int) -> CGRect {
        HostFixtures.viewRect(layout.cards[index].cellRect, in: view, cgOrigin: origin)
    }

    private func center(of index: Int) -> CGPoint {
        HostFixtures.viewPoint(of: layout.cards[index].cellRect, in: view, cgOrigin: origin)
    }

    private func send(_ type: NSEvent.EventType, to point: CGPoint) {
        let event = HostEvents.mouse(type, in: view.window, point: point)
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: XCTFail("测试未覆盖的鼠标事件类型")
        }
    }

    private func click(_ point: CGPoint) {
        send(.leftMouseDown, to: point)
        send(.leftMouseUp, to: point)
    }

    // MARK: - 鼠标

    /// 按下不能展开：展开只发生在抬起之后，且恰好一次（方案 §13.1 / R11）。
    func testCardClickFiresExactlyOnceOnMouseUp() {
        let point = center(of: 0)
        send(.leftMouseDown, to: point)
        XCTAssertEqual(recorder.actions.count, 0, "mouseDown 就展开会让拖动永远变成聚焦")

        send(.leftMouseUp, to: point)
        XCTAssertEqual(recorder.count { if case .cardClicked(let id) = $0 { return id == HostFixtures.identity(0) } else { return false } }, 1)
        XCTAssertEqual(recorder.count { if case .cardClicked = $0 { return true } else { return false } }, 1, "一次手势只能产生一次点击")
    }

    /// 命中测试必须真的由窗口把点交给内容视图：面板不能设置 ignoresMouseEvents。
    func testPanelHitTestReachesContentView() {
        guard let window = view.window else { return XCTFail("控制器未把内容视图装进窗口") }
        let inWindow = view.convert(center(of: 0), to: nil)
        XCTAssertEqual(window.contentView?.hitTest(inWindow), view)
        XCTAssertTrue(controller.consumesBackgroundClicks(), "背景点击必须被总览消费，不能穿透到后面的应用")
    }

    func testBackgroundClickIsConsumed() {
        let cell = viewCell(0)
        let background = CGPoint(x: cell.minX - 6, y: cell.midY)
        XCTAssertTrue(view.bounds.contains(background))
        XCTAssertNil(layout.cards.first { HostFixtures.viewRect($0.cellRect, in: view, cgOrigin: origin).contains(background) },
                     "取样点必须真的落在背景上")
        click(background)
        XCTAssertEqual(recorder.count { if case .backgroundClicked(let slot) = $0 { return slot == nil } else { return false } }, 1)
        XCTAssertEqual(recorder.actions.count, 1)
    }

    func testDragSwapsOnceAndNeverExpands() {
        let from = center(of: 0)
        let to = center(of: 1)
        send(.leftMouseDown, to: from)
        send(.leftMouseDragged, to: CGPoint(x: from.x + 20, y: from.y))
        send(.leftMouseDragged, to: to)
        send(.leftMouseUp, to: to)

        XCTAssertEqual(recorder.count { if case .cardDragged(let a, let b) = $0 { return a == SlotID(index: 0) && b == SlotID(index: 1) } else { return false } }, 1)
        XCTAssertEqual(recorder.count { if case .cardClicked = $0 { return true } else { return false } }, 0, "拖动不得同时展开窗口")
        XCTAssertEqual(recorder.actions.count, 1, "一次拖动只提交一次交换")
    }

    /// 位移没超过阈值仍算点击；超过阈值后回到原格子既不算点击也不算交换。
    func testTinyMovementIsStillAClickAndLongDragBackIsNot() {
        let point = center(of: 0)
        send(.leftMouseDown, to: point)
        send(.leftMouseDragged, to: CGPoint(x: point.x + 4, y: point.y))
        send(.leftMouseUp, to: point)
        XCTAssertEqual(recorder.count { if case .cardClicked = $0 { return true } else { return false } }, 1)

        recorder.reset()
        send(.leftMouseDown, to: center(of: 0))
        send(.leftMouseDragged, to: center(of: 2))
        send(.leftMouseUp, to: center(of: 0))
        XCTAssertEqual(recorder.actions.count, 0, "拖回原格子既不交换也不展开")
    }

    func testGestureIsCancelledWhenSessionCloses() {
        send(.leftMouseDown, to: center(of: 0))
        view.cancelMouseGesture()
        send(.leftMouseUp, to: center(of: 0))
        XCTAssertTrue(recorder.actions.isEmpty, "隐藏/布局变化后残留手势不能在下一次抬起时展开窗口")
    }

    /// 交互路径的收起必须走 alpha（orderOut 单次 460–496ms，会挤掉 displayLink 帧）：
    /// 收起后对外 isVisible=false，但窗口仍 ordered，等隐藏/退出时才真正下屏。
    func testCheapHideKeepsWindowOrderedForCheapHandoff() {
        controller.show()
        XCTAssertTrue(controller.isVisible)
        controller.hideCheaply()
        XCTAssertFalse(controller.isVisible, "对状态机/测试而言已经收起")
        XCTAssertTrue(controller.isOrderedButHidden, "窗口仍 ordered，避免 460ms 的下屏成本")
        XCTAssertEqual(controller.panelAlpha, 0)
        XCTAssertTrue(controller.ignoresMouseEvents, "收起的窗口不能接鼠标")
        controller.hide()
        XCTAssertFalse(controller.isOrderedButHidden)
    }

    // MARK: - 键盘

    /// 方向键按冻结网格的实际邻接走：右到头保持选择，不循环跳到下一行开头。
    func testArrowKeysFollowGridAdjacency() {
        view.keyDown(with: HostEvents.key(kVK_RightArrow))
        XCTAssertEqual(recorder.count { if case .keyboardSelected(let slot) = $0 { return slot == SlotID(index: 1) } else { return false } }, 1)

        view.keyDown(with: HostEvents.key(kVK_RightArrow))
        XCTAssertEqual(recorder.count { if case .keyboardSelected = $0 { return true } else { return false } }, 1,
                       "已到右边界时保持当前选择，不做未声明的循环跳转")

        view.keyDown(with: HostEvents.key(kVK_DownArrow))
        XCTAssertEqual(recorder.count { if case .keyboardSelected(let slot) = $0 { return slot == SlotID(index: 3) } else { return false } }, 1,
                       "下一行同列才是候选，不是 SlotID 序号 +1")
    }

    func testEscapeExitsOnlyWhenNoFilter() {
        view.keyDown(with: HostEvents.key(kVK_Escape))
        XCTAssertEqual(recorder.count { if case .exit = $0 { return true } else { return false } }, 1)

        view.insertText(NSAttributedString(string: "窗口"))
        recorder.reset()
        view.keyDown(with: HostEvents.key(kVK_Escape))
        XCTAssertEqual(recorder.count { if case .search(let query) = $0 { return query.isEmpty } else { return false } }, 1,
                       "有筛选词时 Esc 先清除筛选")
        XCTAssertEqual(recorder.count { if case .exit = $0 { return true } else { return false } }, 0)
    }

    func testOptionSpaceOrganizesAndCommandFResubmitsFilter() {
        view.keyDown(with: HostEvents.key(kVK_Space, flags: HostEvents.option))
        XCTAssertEqual(recorder.count { if case .organize = $0 { return true } else { return false } }, 1)

        view.insertText(NSAttributedString(string: "ma"))
        recorder.reset()
        view.keyDown(with: HostEvents.key(kVK_ANSI_F, characters: "f", flags: HostEvents.command))
        XCTAssertEqual(recorder.count { if case .search(let query) = $0 { return query == "ma" } else { return false } }, 1)
    }

    func testReturnExpandsCurrentSelection() {
        view.keyDown(with: HostEvents.key(kVK_RightArrow))
        recorder.reset()
        view.keyDown(with: HostEvents.key(kVK_Return))
        XCTAssertEqual(recorder.count { if case .cardClicked(let id) = $0 { return id == HostFixtures.identity(1) } else { return false } }, 1)
    }

    /// 输入法路径：文本经 insertText 提交，删除经 deleteBackward；普通按键不能被当成 Esc/整理。
    func testImeTextAndDeletionDriveSearch() {
        view.insertText(NSAttributedString(string: "中文"))
        XCTAssertEqual(recorder.lastSearch, "中文")
        view.insertText(NSAttributedString(string: "候选"))
        XCTAssertEqual(recorder.lastSearch, "中文候选")
        view.deleteBackward(nil)
        XCTAssertEqual(recorder.lastSearch, "中文候")

        recorder.reset()
        view.keyDown(with: HostEvents.key(kVK_ANSI_A, characters: "a"))
        XCTAssertTrue(recorder.actions.allSatisfy { if case .search = $0 { return true } else { return false } },
                      "普通按键只能进筛选词，不能被当成 Esc/整理")
    }

    /// 领域状态是筛选词的唯一来源：同步进来时不得回发 search 事件（否则与 reducer 成环）。
    func testExternalQuerySyncDoesNotEchoBack() {
        recorder.reset()
        sync(query: "外部")
        XCTAssertTrue(recorder.actions.isEmpty)
        XCTAssertEqual(view.searchQuery, "外部")
    }

    /// 筛选改变可见卡片时，视图必须重新取 identity，不能让旧 slotRects 指向已筛掉的窗口。
    func testFilterNarrowsCardsWithoutNewLayout() {
        sync(query: "窗口 2")
        recorder.reset()
        click(center(of: 2))
        XCTAssertEqual(recorder.count { if case .cardClicked(let id) = $0 { return id == HostFixtures.identity(2) } else { return false } }, 1)
        recorder.reset()
        // 其余格子被筛掉后不再是命中目标：点它们只能得到一次背景点击。
        click(center(of: 0))
        XCTAssertEqual(recorder.count { if case .backgroundClicked = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(recorder.count { if case .cardClicked = $0 { return true } else { return false } }, 0)
    }

    // MARK: - 焦点

    /// 键盘门控的两层含义必须分开验证，否则测试会随本机前台应用变化而飘：
    /// - 代码控制层：面板是否"愿意"成为 key（acceptsKeyboard），first responder 是否真的落到内容视图。
    /// - 系统控制层：面板是否"实际"成为 key（要求应用处于前台，宿主测试无法保证）。
    /// 代码控制层永远断言；系统控制层在能取得前台时断言，取不到时显式 skip，绝不静默降级。
    func testKeyboardFocusReallyLandsOnContentView() throws {
        controller.setKeyboardFocus(true)
        XCTAssertTrue(controller.canBecomeKey, "接受键盘时面板必须愿意成为 key")
        XCTAssertTrue(controller.keyboardAccepted, "makeFirstResponder 必须真的把键盘交给内容视图")
        XCTAssertEqual(view.window?.firstResponder as? OverviewContentView, view)

        controller.setKeyboardFocus(false)
        XCTAssertFalse(controller.canBecomeKey, "让出键盘后面板不能再成为 key")
        XCTAssertFalse(controller.keyboardAccepted)
        XCTAssertNil(view.window?.firstResponder as? OverviewContentView)

        // 实际 key 只在宿主能取得前台激活时才断言；取不到就显式 skip 交给实机验证。
        activateHostApp()
        controller.setKeyboardFocus(true)
        guard NSApp.isActive else {
            throw XCTSkip("宿主未取得前台激活：面板实际 isKey 依赖系统前台，需在实机/P0 验证")
        }
        XCTAssertTrue(controller.isKey, "面板已愿意成为 key 且应用已激活，却没真的成为 key")
    }

    /// 让出键盘只做"交出键盘"这一件事：面板仍在原处，不 orderOut、不重新前置背景。
    func testReleasingFocusKeepsOverviewOnScreen() {
        controller.show()
        XCTAssertTrue(controller.isVisible)
        controller.setKeyboardFocus(true)
        controller.setKeyboardFocus(false)
        XCTAssertTrue(controller.isVisible, "让出键盘不能把总览隐藏掉")
        XCTAssertFalse(controller.canBecomeKey, "让出键盘后面板必须拒绝成为 key")
        XCTAssertNil(view.window?.firstResponder as? OverviewContentView)
        controller.hide()
        XCTAssertFalse(controller.isVisible)
    }

    /// 隐藏时进行中的手势必须作废，否则下一次打开会凭空收到一次点击。
    func testHideCancelsPendingGesture() {
        controller.show()
        send(.leftMouseDown, to: center(of: 0))
        controller.hide()
        recorder.reset()
        send(.leftMouseUp, to: center(of: 0))
        XCTAssertTrue(recorder.actions.isEmpty)
    }
}

extension ActionRecorder {
    var lastSearch: String? {
        for action in actions.reversed() {
            if case .search(let query) = action { return query }
        }
        return nil
    }
}
