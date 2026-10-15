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
    case splitBackgroundTiles

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
        orderingStrategy = OrderingStrategy(rawValue: defaults.string(for: .orderingStrategy) ?? "") ?? .normalLevelActivateAndRaise
        didCompleteGuidedSetup = defaults.bool(for: .didCompleteGuidedSetup)
        verboseLogging = defaults.bool(for: .systemLogging)
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
