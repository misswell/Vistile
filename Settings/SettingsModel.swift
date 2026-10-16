import Foundation
import AppKit
import Combine
import Carbon.HIToolbox
import VistileCore

/// 窗口层级策略。默认使用公开能力最保守的组合，P0 实测后才允许切换。
enum OrderingStrategy: String, CaseIterable, Codable {
    /// 背景总览保持普通 level，激活目标应用并执行 AX Raise。
    case normalLevelActivateAndRaise
    /// 显式把总览排到目标窗口编号之下。
    case orderedBelowTarget
    /// 用围绕目标矩形的多个背景承载窗口避开目标区域。
    ///
    /// 未实现：代码里没有任何分块窗口、裁剪或命中测试，旧的"由 FocusCoordinator 承载"注释不成立。
    /// 保留枚举值只为识别遗留持久化值，不对用户开放（方案 §12.1）。
    case splitBackgroundTiles

    /// 只有真实实现并通过同一兼容矩阵验证的策略才对用户开放。
    static var userSelectableCases: [OrderingStrategy] { allCases.filter { !$0.isUnimplemented } }

    var isUnimplemented: Bool { self == .splitBackgroundTiles }

    var displayName: String {
        switch self {
        case .normalLevelActivateAndRaise: return "普通层级 + 激活 + AX Raise"
        case .orderedBelowTarget: return "排序到目标窗口之下"
        case .splitBackgroundTiles: return "背景分块避让"
        }
    }
}

enum OverviewSortMode: String, CaseIterable, Codable {
    case remembered
    case appGrouped
    case discoveryOrder

    var displayName: String {
        switch self {
        case .remembered: return "按记忆顺序"
        case .appGrouped: return "按应用分组"
        case .discoveryOrder: return "按发现顺序"
        }
    }
}

struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// 默认 Control+Option+Space。
    static let `default` = HotKeyBinding(keyCode: UInt32(kVK_Space),
                                        carbonModifiers: UInt32(controlKey | optionKey))

    /// 名称必须由 keyCode 推出，不能写死"空格"，否则用户改完键看到的还是旧标签。
    var displayString: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        parts.append(keyName)
        return parts.joined()
    }

    var keyName: String {
        if let named = Self.keyNames[Int(truncatingIfNeeded: keyCode)] { return named }
        return "键码 \(keyCode)"
    }

    /// 只覆盖会用到与常见的键；未知键如实显示键码，不猜字符。
    private static let keyNames: [Int: String] = [
        kVK_Space: "空格", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9",
        kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    /// 录制到的 NSEvent 转成绑定；修饰键必须原样保留，否则注册的是另一个组合键。
    static func binding(from event: NSEvent) -> HotKeyBinding {
        HotKeyBinding(keyCode: UInt32(truncatingIfNeeded: event.keyCode),
                      carbonModifiers: HotKeyBinding.carbonModifiers(of: event.modifierFlags))
    }

    var hasModifier: Bool {
        carbonModifiers & UInt32(controlKey | optionKey | cmdKey | shiftKey) != 0
    }

    /// NSEvent 修饰位映射到 Carbon 位；必须用 mask 比较，equal 判断会漏掉其它位。
    static func carbonModifiers(of flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

/// 设置项集中在此，UI 只显示有意义的选项，不暴露 buffer 参数。
final class SettingsModel: ObservableObject {
    fileprivate enum Key: String {
        case launchAtLogin, hotKeyCode, hotKeyModifiers, density, showsTitles, sortMode
        case foregroundWidth, foregroundHeight, backgroundClickSwitches, preserveUserGeometry
        case tier, priorityKeys, excludedBundles, orderingStrategy, didCompleteGuidedSetup
        case slotOrder, compactMode, systemLogging
        case workbenchSide, workbenchTopHeight, workbenchSideWidth, workbenchDisplay
        case workbenchOverflow, workbenchSchema
    }

    private let defaults: UserDefaults

    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, for: .launchAtLogin) } }
    @Published var hotKey: HotKeyBinding {
        didSet {
            defaults.set(Int(truncatingIfNeeded: hotKey.keyCode), for: .hotKeyCode)
            defaults.set(Int(truncatingIfNeeded: hotKey.carbonModifiers), for: .hotKeyModifiers)
        }
    }
    @Published var density: LayoutDensity { didSet { defaults.set(density.rawValue, for: .density) } }
    @Published var showsTitles: Bool { didSet { defaults.set(showsTitles, for: .showsTitles) } }
    @Published var sortMode: OverviewSortMode { didSet { defaults.set(sortMode.rawValue, for: .sortMode) } }
    @Published var foregroundWidthRatio: Double { didSet { defaults.set(foregroundWidthRatio, for: .foregroundWidth) } }
    @Published var foregroundHeightRatio: Double { didSet { defaults.set(foregroundHeightRatio, for: .foregroundHeight) } }
    @Published var backgroundClickSwitches: Bool { didSet { defaults.set(backgroundClickSwitches, for: .backgroundClickSwitches) } }
    @Published var preserveUserGeometry: Bool { didSet { defaults.set(preserveUserGeometry, for: .preserveUserGeometry) } }
    @Published var tier: CaptureTier { didSet { defaults.set(tier.rawValue, for: .tier) } }
    @Published var priorityWindowKeys: [String] { didSet { defaults.set(priorityWindowKeys, for: .priorityKeys) } }
    @Published var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, for: .excludedBundles) } }
    @Published var orderingStrategy: OrderingStrategy { didSet { defaults.set(orderingStrategy.rawValue, for: .orderingStrategy) } }
    @Published var didCompleteGuidedSetup: Bool { didSet { defaults.set(didCompleteGuidedSetup, for: .didCompleteGuidedSetup) } }
    @Published var verboseLogging: Bool { didSet { defaults.set(verboseLogging, for: .systemLogging) } }
    /// 侧栏方向与分隔线偏好：清洗规则在核心 `WorkbenchPreferences`，宿主只负责键值往返（方案 §16）。
    @Published var workbenchSide: RailSide { didSet { defaults.set(workbenchSide.rawValue, for: .workbenchSide) } }
    /// nil 表示用布局默认；拖动结束才写盘（方案 §11.2）。
    @Published var workbenchTopHeight: CGFloat? {
        didSet { defaults.set(workbenchTopHeight.map { Double($0) }, for: .workbenchTopHeight) }
    }
    @Published var workbenchSideWidth: CGFloat? {
        didSet { defaults.set(workbenchSideWidth.map { Double($0) }, for: .workbenchSideWidth) }
    }
    /// 工作台优先显示器；nil = 跟随点击的窗口所在屏幕（方案 §13）。
    @Published var preferredWorkbenchDisplayID: UInt32? {
        didSet { defaults.set(preferredWorkbenchDisplayID.map { Int($0) }, for: .workbenchDisplay) }
    }
    @Published var workbenchOverflow: OverflowBehavior {
        didSet { defaults.set(workbenchOverflow.rawValue, for: .workbenchOverflow) }
    }
    /// 旧版本持久化值的一次性迁移说明；空数组表示这次启动没有可迁移的旧值。
    private(set) var workbenchMigrationNotes: [String] = []
    /// 本次启动从持久化值里迁移掉的未实现策略；nil 表示没有发生过迁移。
    private(set) var migratedOrderingStrategy: OrderingStrategy?
    /// 持久化里现在到底存着哪个策略：P0 探针用它确认迁移已写回，不会每次启动重演（方案 §12.1）。
    var persistedOrderingStrategy: OrderingStrategy? {
        OrderingStrategy(rawValue: defaults.string(for: .orderingStrategy) ?? "")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.launchAtLogin.rawValue: false,
            Key.hotKeyCode.rawValue: Int(truncatingIfNeeded: HotKeyBinding.default.keyCode),
            Key.hotKeyModifiers.rawValue: Int(truncatingIfNeeded: HotKeyBinding.default.carbonModifiers),
            Key.density.rawValue: LayoutDensity.standard.rawValue,
            Key.showsTitles.rawValue: true,
            Key.sortMode.rawValue: OverviewSortMode.remembered.rawValue,
            Key.foregroundWidth.rawValue: 0.86,
            Key.foregroundHeight.rawValue: 0.88,
            Key.backgroundClickSwitches.rawValue: false,
            Key.preserveUserGeometry.rawValue: false,
            Key.tier.rawValue: CaptureTier.balanced.rawValue,
            Key.orderingStrategy.rawValue: OrderingStrategy.normalLevelActivateAndRaise.rawValue,
            Key.didCompleteGuidedSetup.rawValue: false,
            Key.systemLogging.rawValue: false
        ])

        launchAtLogin = defaults.bool(for: .launchAtLogin)
        hotKey = HotKeyBinding(keyCode: UInt32(max(0, defaults.integer(for: .hotKeyCode))),
                               carbonModifiers: UInt32(max(0, defaults.integer(for: .hotKeyModifiers))))
        density = LayoutDensity(rawValue: defaults.string(for: .density) ?? "") ?? .standard
        showsTitles = defaults.bool(for: .showsTitles)
        sortMode = OverviewSortMode(rawValue: defaults.string(for: .sortMode) ?? "") ?? .remembered
        foregroundWidthRatio = defaults.double(for: .foregroundWidth)
        foregroundHeightRatio = defaults.double(for: .foregroundHeight)
        backgroundClickSwitches = defaults.bool(for: .backgroundClickSwitches)
        preserveUserGeometry = defaults.bool(for: .preserveUserGeometry)
        tier = CaptureTier(rawValue: defaults.string(for: .tier) ?? "") ?? .balanced
        priorityWindowKeys = defaults.stringArray(for: .priorityKeys) ?? []
        excludedBundleIDs = defaults.stringArray(for: .excludedBundles) ?? []
        let storedStrategy = OrderingStrategy(rawValue: defaults.string(for: .orderingStrategy) ?? "")
            ?? .normalLevelActivateAndRaise
        // 未实现的策略不能继续「看起来开着」：迁移到普通层级，并留下一次诊断事实（方案 §12.1）。
        let needsMigration = storedStrategy.isUnimplemented
        let resolvedStrategy = needsMigration ? OrderingStrategy.normalLevelActivateAndRaise : storedStrategy
        migratedOrderingStrategy = needsMigration ? storedStrategy : nil
        orderingStrategy = resolvedStrategy
        // init 里 didSet 不触发，迁移结果必须显式写回：否则每次启动都重演一遍迁移。
        if needsMigration { defaults.set(resolvedStrategy.rawValue, for: .orderingStrategy) }
        didCompleteGuidedSetup = defaults.bool(for: .didCompleteGuidedSetup)
        verboseLogging = defaults.bool(for: .systemLogging)

        // 0.1.3–0.1.5 遗留值：只识别，不让它们改变入口或再次缩放主区（方案 §16）。
        // 旧键不在 register 域里，且必须读"真的写过的"持久化域，否则默认值会被当成用户设置；
        // standard 的持久化域是应用 id，注入的测试套件没有持久化域，一律视为"没设置过旧值"。
        let persisted: [String: Any]
        if defaults === UserDefaults.standard, let bundleID = Bundle.main.bundleIdentifier {
            persisted = defaults.persistentDomain(forName: bundleID) ?? [:]
        } else {
            persisted = [:]
        }
        let legacy = LegacyWorkbenchValues(
            defaultPresentationMode: persisted["defaultPresentationMode"] as? String,
            lastPresentationMode: persisted["lastPresentationMode"] as? String,
            foregroundWidthRatio: persisted[Key.foregroundWidth.rawValue] as? Double,
            foregroundHeightRatio: persisted[Key.foregroundHeight.rawValue] as? Double,
            backgroundClickSwitches: persisted[Key.backgroundClickSwitches.rawValue] as? Bool)
        let migrated = WorkbenchPreferences.migrating(from: legacy)
        workbenchMigrationNotes = migrated.notes
        // 迁移结果不是"新的默认设置"：用户已存的键仍以持久化值为准，只对坏值做清洗。
        let stored = WorkbenchPreferences(
            side: RailSide(rawValue: defaults.string(for: .workbenchSide) ?? "") ?? migrated.preferences.side,
            topHeightPreference: defaults.doubleValue(for: .workbenchTopHeight).map { CGFloat($0) }
                ?? migrated.preferences.topHeightPreference,
            sideWidthPreference: defaults.doubleValue(for: .workbenchSideWidth).map { CGFloat($0) }
                ?? migrated.preferences.sideWidthPreference,
            preferredDisplayID: defaults.integerValue(for: .workbenchDisplay).flatMap { UInt32(exactly: $0) }
                ?? migrated.preferences.preferredDisplayID,
            overflowBehavior: OverflowBehavior(rawValue: defaults.string(for: .workbenchOverflow) ?? "")
                ?? migrated.preferences.overflowBehavior).sanitized()
        workbenchSide = stored.side
        workbenchTopHeight = stored.topHeightPreference
        workbenchSideWidth = stored.sideWidthPreference
        preferredWorkbenchDisplayID = stored.preferredDisplayID
        workbenchOverflow = stored.overflowBehavior
        // 清洗结果与 schema 版本显式写回：坏值（NaN/负值）不能每次启动重演，版本号供后续迁移判断。
        defaults.set(stored.topHeightPreference.map { Double($0) }, for: .workbenchTopHeight)
        defaults.set(stored.sideWidthPreference.map { Double($0) }, for: .workbenchSideWidth)
        defaults.set(WorkbenchPreferences.currentSchemaVersion, for: .workbenchSchema)
    }

    var reduceMotion: Bool {
        (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    var style: OverviewStyle {
        OverviewStyle.style(density)
    }

    func sessionPolicy() -> SessionPolicy {
        SessionPolicy(backgroundClickSwitches: backgroundClickSwitches,
                      preserveUserGeometry: preserveUserGeometry,
                      foregroundWidthRatio: foregroundWidthRatio,
                      foregroundHeightRatio: foregroundHeightRatio,
                      density: density,
                      tier: tier,
                      reduceMotion: reduceMotion)
    }

    func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return excludedBundleIDs.contains(bundleID)
    }

    func isPriority(_ memoryKey: String) -> Bool {
        priorityWindowKeys.contains(memoryKey)
    }

    func togglePriority(_ memoryKey: String) {
        if let index = priorityWindowKeys.firstIndex(of: memoryKey) {
            priorityWindowKeys.remove(at: index)
        } else {
            priorityWindowKeys.append(memoryKey)
        }
    }

    /// 跨会话记住卡片顺序。
    var slotOrderPreference: [String: Int] {
        get { (defaults.dictionaryValue(for: .slotOrder) as? [String: Int]) ?? [:] }
        set { defaults.set(newValue.mapValues { NSNumber(value: $0) }, for: .slotOrder) }
    }

    func apply(_ registry: SlotRegistry) {
        slotOrderPreference = registry.orderPreference
    }
}

fileprivate extension UserDefaults {
    func bool(for key: SettingsModel.Key) -> Bool { object(forKey: key.rawValue) as? Bool ?? false }
    func integer(for key: SettingsModel.Key) -> Int { object(forKey: key.rawValue) as? Int ?? 0 }
    /// nil 与 0 必须区分：显示器编号和栏尺寸偏好里 0 不是合法值。
    func integerValue(for key: SettingsModel.Key) -> Int? { object(forKey: key.rawValue) as? Int }
    func doubleValue(for key: SettingsModel.Key) -> Double? { object(forKey: key.rawValue) as? Double }
    func double(for key: SettingsModel.Key) -> Double { object(forKey: key.rawValue) as? Double ?? 0 }
    func string(for key: SettingsModel.Key) -> String? { object(forKey: key.rawValue) as? String }
    func stringArray(for key: SettingsModel.Key) -> [String]? { stringArray(forKey: key.rawValue) }
    func dictionaryValue(for key: SettingsModel.Key) -> [String: Any]? {
        dictionary(forKey: key.rawValue)
    }

    func set(_ value: Any?, for key: SettingsModel.Key) {
        if let value { set(value, forKey: key.rawValue) } else { removeObject(forKey: key.rawValue) }
    }
}
