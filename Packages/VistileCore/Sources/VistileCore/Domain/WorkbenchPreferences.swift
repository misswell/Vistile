import Foundation
import CoreGraphics

/// 溢出卡片的到达方式（方案 §16）：当前只实现"滚动轨道"，保留枚举以便未来扩展时不用改存储格式。
public enum OverflowBehavior: String, Hashable, Sendable, Codable, CaseIterable {
    case scroll

    public var displayName: String {
        switch self {
        case .scroll: return "留在滚动轨道"
        }
    }
}

/// 0.1.3–0.1.5 遗留的持久化值。只用于识别与迁移，不参与任何行为（方案 §16）。
public struct LegacyWorkbenchValues: Hashable, Sendable {
    public var defaultPresentationMode: String?
    public var lastPresentationMode: String?
    public var foregroundWidthRatio: Double?
    public var foregroundHeightRatio: Double?
    public var backgroundClickSwitches: Bool?

    public init(defaultPresentationMode: String? = nil,
                lastPresentationMode: String? = nil,
                foregroundWidthRatio: Double? = nil,
                foregroundHeightRatio: Double? = nil,
                backgroundClickSwitches: Bool? = nil) {
        self.defaultPresentationMode = defaultPresentationMode
        self.lastPresentationMode = lastPresentationMode
        self.foregroundWidthRatio = foregroundWidthRatio
        self.foregroundHeightRatio = foregroundHeightRatio
        self.backgroundClickSwitches = backgroundClickSwitches
    }
}

/// 工作台设置的纯逻辑（方案 §16）：默认值、清洗规则与旧值迁移都集中在这里，
/// 宿主只负责读写键值，不自己判断"这个值该不该信"。
public struct WorkbenchPreferences: Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public private(set) var schemaVersion: Int
    public var side: RailSide
    /// 分隔线拖动的偏好值；nil 表示用默认比例。写入前必须过 `sanitized`。
    public var topHeightPreference: CGFloat?
    public var sideWidthPreference: CGFloat?
    /// 活动工作台显示器偏好；进程重启后显示器可能已不存在，宿主必须有 fallback。
    public var preferredDisplayID: UInt32?
    public var overflowBehavior: OverflowBehavior
    /// 跨会话的顺序偏好与 pin（只存 memoryKey，不存窗口标题）。
    public var railOrderPreference: [String: Int]
    public var pinnedKeys: Set<String>

    /// 入口永远从总览开始：旧的 default/last presentationMode 不得改变它（方案 §16）。
    public static let alwaysStartsAtOverview = true

    public init(side: RailSide = .right,
                topHeightPreference: CGFloat? = nil,
                sideWidthPreference: CGFloat? = nil,
                preferredDisplayID: UInt32? = nil,
                overflowBehavior: OverflowBehavior = .scroll,
                railOrderPreference: [String: Int] = [:],
                pinnedKeys: Set<String> = []) {
        schemaVersion = Self.currentSchemaVersion
        self.side = side
        self.topHeightPreference = topHeightPreference
        self.sideWidthPreference = sideWidthPreference
        self.preferredDisplayID = preferredDisplayID
        self.overflowBehavior = overflowBehavior
        self.railOrderPreference = railOrderPreference
        self.pinnedKeys = pinnedKeys
    }

    /// 读盘与拖动结束都要过这一关：非有限值、负值、退化的 0 一律当作"没有偏好"，
    /// 不然一个坏值会让主区算出负尺寸或 0 高。
    public func sanitized() -> WorkbenchPreferences {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.topHeightPreference = Self.sanitize(preference: topHeightPreference)
        copy.sideWidthPreference = Self.sanitize(preference: sideWidthPreference)
        copy.railOrderPreference = railOrderPreference.filter { !$0.key.isEmpty }
        copy.pinnedKeys = pinnedKeys.filter { !$0.isEmpty }
        return copy
    }

    private static func sanitize(preference: CGFloat?) -> CGFloat? {
        guard let preference, preference.isFinite, preference > 1 else { return nil }
        return preference
    }

    /// 旧版本持久化值 → 当前偏好。两条硬规则（方案 §16）：
    /// 1. 旧模式键只作识别，不允许让任何一次打开绕过总览入口；
    /// 2. 旧 foreground 比例是"旧聚焦路径的缩放系数"，不迁移进新主区几何，避免二次缩放。
    public static func migrating(from legacy: LegacyWorkbenchValues) -> (preferences: WorkbenchPreferences, notes: [String]) {
        var notes: [String] = []
        if legacy.defaultPresentationMode != nil || legacy.lastPresentationMode != nil {
            notes.append("旧展示模式键不再控制入口：每次打开固定从总览开始")
        }
        if legacy.foregroundWidthRatio != nil || legacy.foregroundHeightRatio != nil {
            notes.append("旧前景比例不再作为主区缩放系数：主区几何由工作台布局决定")
        }
        if legacy.backgroundClickSwitches != nil {
            notes.append("旧背景点击开关不影响工作台：卡片点击始终交换主窗口")
        }
        return (WorkbenchPreferences().sanitized(), notes)
    }
}
