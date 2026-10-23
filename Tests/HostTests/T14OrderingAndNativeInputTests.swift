import AppKit
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// T14 层级策略与原生输入（方案 §12）。
///
/// 两条底线：没有实现的可选项不能出现在设置里，遗留值必须迁移并留下事实；
/// 前景化只看读回——"没报错"不等于"目标已经在前面"，被证伪时必须停止假装展开成功。
@MainActor
final class T14OrderingAndNativeInputTests: XCTestCase {
    private let sessionID = UUID()
    private var permissions: FakePermissions!
    private var catalogSource: FakeCatalogSource!
    private var processIdentity: FakeProcessIdentity!
    private var writer: FakeGeometryWriter!
    private lazy var scheduler = HostScheduler.make(sessionID: sessionID)
    private var catalog: WindowCatalog!
    private var settings: SettingsModel!
    private var journalDirectory: URL!
    private var scratchDirectories: [URL] = []
    private var testDefaultsSuites: [String] = []

    private var displayID: UInt32 { HostFixtures.display.id }
    private var expandedFrame: CGRect {
        CGRect(x: HostFixtures.offscreenOrigin.x + 40, y: 40, width: 1_200, height: 760)
    }

    override func setUpWithError() throws {
        permissions = FakePermissions()
        catalogSource = FakeCatalogSource()
        processIdentity = FakeProcessIdentity()
        writer = FakeGeometryWriter()
        journalDirectory = try makeScratchDirectory()
    }

    override func tearDown() {
        catalog = nil
        settings = nil
        for directory in scratchDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        scratchDirectories = []
        for suite in testDefaultsSuites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        testDefaultsSuites = []
        super.tearDown()
    }

    // MARK: - §12.1 虚假可选项

    /// 持久化键与 `SettingsModel.Key.orderingStrategy.rawValue` 同一个字符串。
    private let strategyKey = "orderingStrategy"

    func testUnimplementedStrategyIsNotSelectable() {
        XCTAssertFalse(OrderingStrategy.userSelectableCases.contains(.splitBackgroundTiles))
        XCTAssertEqual(OrderingStrategy.userSelectableCases.count, OrderingStrategy.allCases.count - 1)
    }

    func testLegacySplitTilesValueIsMigratedAndRemembered() {
        let suite = transientDefaults()
        suite.set(OrderingStrategy.splitBackgroundTiles.rawValue, forKey: strategyKey)
        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.orderingStrategy, .normalLevelActivateAndRaise,
                       "没有实现的策略不能继续「生效」：它一个分块窗口都不会创建")
        XCTAssertEqual(settings.migratedOrderingStrategy, .splitBackgroundTiles,
                       "迁移必须留下事实，不能悄悄改掉用户的设置")
        // 写回：否则每次启动都重演一次迁移。
        XCTAssertEqual(suite.string(forKey: strategyKey),
                       OrderingStrategy.normalLevelActivateAndRaise.rawValue)
    }

    func testNormalStrategyIsLeftAlone() {
        let suite = transientDefaults()
        suite.set(OrderingStrategy.orderedBelowTarget.rawValue, forKey: strategyKey)
        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.orderingStrategy, .orderedBelowTarget)
        XCTAssertNil(settings.migratedOrderingStrategy)
    }

    // MARK: - 热键持久化边界

    /// 盘上修饰键被清空（旧版本或手改 plist）时，不能把空格这类普通按键注册成全局热键。
    func testModifierlessPersistedHotKeyFallsBackToDefault() {
        let suite = transientDefaults()
        suite.set(Int(HotKeyBinding.default.keyCode), forKey: "hotKeyCode")
        suite.set(0, forKey: "hotKeyModifiers")

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.hotKey, .default, "无修饰键的绑定会全局劫持普通按键")
        XCTAssertTrue(settings.hotKey.hasModifier)
        XCTAssertEqual(suite.integer(forKey: "hotKeyModifiers"),
                       Int(HotKeyBinding.default.carbonModifiers),
                       "坏值必须写回，否则每次启动都要重新兜底")
    }

    func testNegativePersistedModifiersFallBackToDefault() {
        let suite = transientDefaults()
        suite.set(Int(HotKeyBinding.default.keyCode), forKey: "hotKeyCode")
        suite.set(-1, forKey: "hotKeyModifiers")

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.hotKey, .default)
    }

    /// `UInt32(Int)` 对超范围值会直接崩溃，持久化层必须先挡掉。
    func testOutOfRangePersistedKeyCodeFallsBackWithoutTrap() {
        let suite = transientDefaults()
        suite.set(Int(UInt32.max) + 1, forKey: "hotKeyCode")
        suite.set(Int(HotKeyBinding.default.carbonModifiers), forKey: "hotKeyModifiers")

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.hotKey, .default)
        XCTAssertEqual(suite.integer(forKey: "hotKeyCode"), Int(HotKeyBinding.default.keyCode),
                       "坏键码必须写回默认值")
    }

    func testValidPersistedHotKeyIsPreserved() {
        let suite = transientDefaults()
        let custom = HotKeyBinding(keyCode: HotKeyBinding.default.keyCode + 1,
                                   carbonModifiers: HotKeyBinding.default.carbonModifiers)
        suite.set(Int(custom.keyCode), forKey: "hotKeyCode")
        suite.set(Int(custom.carbonModifiers), forKey: "hotKeyModifiers")

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.hotKey, custom, "兜底只处理坏值，不能覆盖用户的有效组合")
    }

    /// 设置层已兜底；注册层再挡一次，避免任何调用方把普通按键注册成全局热键。
    func testGlobalHotKeyRefusesModifierlessBinding() {
        let hub = GlobalHotKey()
        XCTAssertFalse(hub.register(HotKeyBinding(keyCode: HotKeyBinding.default.keyCode,
                                                  carbonModifiers: 0)))
        XCTAssertFalse(hub.isActive)
    }

    // MARK: - 工作台尺寸持久化边界（方案 §5.2、§16）

    /// 盘上的 NaN/负值都会让主区算出坏几何：读入时按"没有偏好"处理并写回。
    func testCorruptGlobalRailPreferencesAreDiscardedAndRewritten() {
        let suite = transientDefaults()
        suite.set(Double.nan, forKey: "workbenchTopHeight")
        suite.set(-12.0, forKey: "workbenchSideWidth")

        settings = SettingsModel(defaults: suite)
        XCTAssertNil(settings.workbenchTopHeight)
        XCTAssertNil(settings.workbenchSideWidth)
        XCTAssertNil(suite.object(forKey: "workbenchTopHeight"), "坏值必须从盘上清掉，不能每次启动重演")
        XCTAssertNil(suite.object(forKey: "workbenchSideWidth"))
    }

    /// 同一显示器的两个尺寸分开读：一个字段是字符串/NaN 时，另一个有效字段不能跟着作废。
    func testRailSizeDictionaryKeepsValidFieldWhenSiblingIsCorrupt() {
        let suite = transientDefaults()
        settings = SettingsModel(defaults: suite)
        settings.workbenchTopHeight = 125
        settings.workbenchSideWidth = 210
        suite.set([
            "display-a": ["topHeight": 240.0, "sideWidth": 350.0],
            "display-b": ["topHeight": "not-a-size", "sideWidth": 270.0],
            "display-c": "not-a-dictionary",
            "display-d": ["topHeight": Double.nan, "sideWidth": -10.0],
        ], forKey: "workbenchRailSizesByDisplay")

        XCTAssertEqual(settings.workbenchRailSizes(for: "display-a").topHeight, 240)
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-a").sideWidth, 350)
        XCTAssertNil(settings.workbenchRailSizes(for: "display-b").topHeight, "坏字段按无偏好处理")
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-b").sideWidth, 270,
                       "同组另一个字段有效时不能被连坐丢弃")
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-c").topHeight, 125,
                       "整条记录类型错误时回退全局偏好")
        XCTAssertEqual(settings.workbenchRailSizes(for: "display-c").sideWidth, 210)
        XCTAssertNil(settings.workbenchRailSizes(for: "display-d").topHeight)
        XCTAssertNil(settings.workbenchRailSizes(for: "display-d").sideWidth)
    }

    /// 未知枚举值不能让启动失败，也不能把无意义的显示器编号带进会话。
    func testCorruptWorkbenchEnumsFallBackToDefaults() {
        let suite = transientDefaults()
        suite.set("diagonal", forKey: "workbenchSide")
        suite.set("explode", forKey: "workbenchOverflow")
        suite.set(-7, forKey: "workbenchDisplay")

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.workbenchSide, .right)
        XCTAssertEqual(settings.workbenchOverflow, .scroll)
        XCTAssertNil(settings.preferredWorkbenchDisplayID)
    }

    // MARK: - 轨道跨会话记忆（方案 §6.2/§16）

    /// 持久化键与 `SettingsModel.Key.workbenchRailOrder` / `.workbenchPins` 的 rawValue 同一个字符串。
    private let railOrderKey = "workbenchRailOrder"
    private let pinsKey = "workbenchPins"

    func testWorkbenchRailMemorySurvivesRelaunchAfterSanitizingStrayKeys() {
        let suite = transientDefaults()
        // 脏值：空键（旧版本或手改过的 plist）不得进入会话，也不许留在盘上每次启动重洗。
        suite.set(["com.example.notes": 3, "": 0], forKey: railOrderKey)
        suite.set(["", "com.example.mail"], forKey: pinsKey)

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.workbenchRailOrder, ["com.example.notes": 3], "空键必须被清洗掉")
        XCTAssertEqual(settings.workbenchPins, ["com.example.mail"])
        XCTAssertEqual(suite.dictionary(forKey: railOrderKey) as? [String: Int],
                       ["com.example.notes": 3], "清洗结果必须写回，否则每次启动都要再洗一遍")
        XCTAssertEqual(suite.stringArray(forKey: pinsKey), ["com.example.mail"])

        // 整理/固定后的写盘 → 新实例读回：跨会话记忆的完整往返，键全是应用级 preferenceKey。
        settings.workbenchRailOrder = ["com.example.notes": 0, "name:Notes": 1]
        settings.workbenchPins = ["name:Notes", "com.example.notes"]
        let relaunched = SettingsModel(defaults: suite)
        XCTAssertEqual(relaunched.workbenchRailOrder, ["com.example.notes": 0, "name:Notes": 1],
                       "整理写下的 rank 必须原样读回")
        XCTAssertEqual(relaunched.workbenchPins, ["com.example.notes", "name:Notes"],
                       "pin 交给消费者前按排序归一：同一份内容不因落盘次序产生不同投影")
    }

    // MARK: - §12.2 前景化按读回判定

    /// 方案 §16：旧版的 slotOrder / priorityKeys 里带过「应用标识|小写标题」，0.1.10 启动时清洗并写回。
    func testLegacyTitleDerivedPreferenceKeysAreCleanedOnLaunch() {
        let suite = transientDefaults()
        suite.set(["com.apple.Safari|文章 A": 5, "com.apple.Safari|文章 B": 2, "": 0,
                   "com.apple.notes|待办": 7], forKey: "slotOrder")
        suite.set(["com.apple.Safari|文章 A", "com.apple.Safari|文章 B", ""], forKey: "priorityKeys")

        settings = SettingsModel(defaults: suite)
        XCTAssertEqual(settings.slotOrderPreference,
                       ["com.apple.safari": 2, "com.apple.notes": 7],
                       "同一应用合并取最靠前序号；空键丢弃")
        XCTAssertEqual(settings.priorityWindowKeys, ["com.apple.safari"], "去标题、去重")
        XCTAssertEqual(suite.dictionary(forKey: "slotOrder") as? [String: Int],
                       ["com.apple.safari": 2, "com.apple.notes": 7],
                       "清洗结果必须写回，盘上不得继续留标题派生键")
        XCTAssertEqual(suite.stringArray(forKey: "priorityKeys"), ["com.apple.safari"])
        XCTAssertTrue(settings.workbenchMigrationNotes.contains { $0.contains("标题派生键") },
                      "迁移必须留下事实说明，不能静默改写用户设置")

        // 重启不再重演：盘上已洗过，第二次启动没有可清洗的旧值。
        let relaunched = SettingsModel(defaults: suite)
        XCTAssertEqual(relaunched.slotOrderPreference, settings.slotOrderPreference)
        XCTAssertFalse(relaunched.workbenchMigrationNotes.contains { $0.contains("标题派生键") })
    }

    func testExpandContinuesOnlyWhenTargetIsReadBackAsFocused() async throws {
        let (focus, identity) = try await startHarness()
        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        var events: [SessionEvent] = []
        focus.onEvent = { events.append($0) }

        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        // 等到"读回 focused window"这一步真的发生，再判定有没有报失败：
        // 只等几何写入会在断言之后才产生事件，得到偶发绿。
        await pendingUntil { writer.focusedWindowReadCount > 0 }
        await pump()
        focus.cancelAnimation()

        XCTAssertTrue(writer.recordedActions.contains("写"), "没走到几何写入")
        XCTAssertFalse(events.contains { if case .transitionTimedOut = $0 { return true }; return false },
                       "读回确认目标就是 focused window，却报失败")
        // 读回走的是 focused window 属性，不是"写入没报错"。
        let focused = await writer.focusedWindow(pid: identity.processID)
        XCTAssertNotNil(focused)
    }

    func testSiblingHoldingFocusStopsTheExpand() async throws {
        let (focus, identity) = try await startHarness()
        // 写焦点"成功"，但应用认为前面是同应用的另一个窗口。
        writer.siblingKeepsFocus = true
        let token = TransitionToken(generation: 1)
        focus.isTokenCurrent = { $0 == token }
        var events: [SessionEvent] = []
        var statuses: [String] = []
        focus.onEvent = { events.append($0) }
        focus.onStatus = { statuses.append($0) }

        focus.expand(identity, targetFrame: expandedFrame, token: token, animationMS: 60)
        await pendingUntil { events.contains { if case .transitionTimedOut = $0 { return true }; return false } }
        focus.cancelAnimation()

        XCTAssertFalse(events.contains { if case .expandCompleted = $0 { return true }; return false },
                       "兄弟窗口还占着焦点时不能把这次算成展开成功")
        XCTAssertTrue(events.contains { if case .transitionTimedOut = $0 { return true }; return false },
                      "必须走安全回总览与恢复分支：\(events)")
        XCTAssertTrue(statuses.contains { $0.contains("前台") }, "拒绝原因要说清是前景化：\(statuses)")
    }

    // MARK: - 组装

    /// 让主队列把已排队的任务跑完：判定链都在 MainActor 的 Task 上，靠 await 交接而不是 sleep。
    private func pump(_ times: Int = 4) async {
        for _ in 0..<times {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    private func startHarness() async throws -> (FocusCoordinator, WindowIdentity) {
        catalogSource.addWindows([0])
        catalog = WindowCatalog(permissions: permissions,
                               axSource: catalogSource,
                               contentSource: catalogSource,
                               displaySource: FakeDisplaySource(displays: [HostFixtures.display]))
        let identity = HostFixtures.identity(0)
        await catalog.refreshAndWait(reason: .reconcile)
        XCTAssertEqual(catalog.record(for: identity)?.allowsGeometryControl, true,
                       "窗口必须被判为可控，否则走不到前景化这一步")
        return (try await startFocus(identity: identity), identity)
    }

    private func startFocus(identity: WindowIdentity) async throws -> FocusCoordinator {
        let store = WindowJournalStore(fileName: "session-journal.json",
                                       sessionID: sessionID,
                                       baseDirectory: journalDirectory)
        settings = SettingsModel(defaults: transientDefaults())
        let recovery = RecoveryCoordinator(store: store,
                                          writer: writer,
                                          catalog: catalog,
                                          settings: settings,
                                          permissions: permissions,
                                          processIdentity: processIdentity,
                                          scheduler: scheduler)
        if let element = catalogSource.element(for: identity) {
            writer.setInitialFrame(FakeCatalogSource.frame(for: 0), for: element)
        }
        await store.apply(WindowTransaction(sessionID: sessionID,
                                           identity: identity,
                                           bundleID: "com.test.app\(identity.windowID)",
                                           originalFrame: FakeCatalogSource.frame(for: 0),
                                           originalDisplayID: displayID)
            .markingPlanned(frame: expandedFrame, displayID: displayID))
        let metal = try HostFixtures.metalContext()
        return FocusCoordinator(catalog: catalog,
                                metal: metal,
                                writer: writer,
                                store: store,
                                settings: settings,
                                metrics: .shared,
                                recorder: CompatibilityRecorder(fileName: "host-test-\(UUID().uuidString)"),
                                recovery: recovery,
                                permissions: permissions,
                                scheduler: scheduler)
    }

    private func pendingUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("等待条件超时（\(timeout)s）")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VistileHostTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchDirectories.append(url)
        return url
    }

    private func transientDefaults() -> UserDefaults {
        let suite = "VistileHostTests.\(UUID().uuidString)"
        testDefaultsSuites.append(suite)
        return UserDefaults(suiteName: suite)!
    }
}
