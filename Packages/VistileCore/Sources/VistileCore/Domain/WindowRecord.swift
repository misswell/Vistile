import Foundation

/// AX 匹配结果分级。未唯一确定的窗口禁止写 AX（方案 §7 不变量）。
public enum MatchConfidence: Hashable, Sendable {
    case unique(score: Double, axIndex: Int)
    case ambiguous(alternatives: [Int])
    case unmatched

    public var resolvedAXIndex: Int? {
        if case let .unique(_, index) = self { return index }
        return nil
    }

    /// 唯一对应是允许自动聚焦与尺寸控制的前提。
    public var allowsAXWrite: Bool {
        if case .unique = self { return true }
        return false
    }

    public var isAmbiguous: Bool {
        if case .ambiguous = self { return true }
        return false
    }
}

/// 卡片显示的捕获状态，必须与实际能力一致，禁止把轮询或最后一帧标成实时。
public enum CapturePhase: Hashable, Sendable {
    case idle
    case starting(generation: UInt64)
    case live
    case lowFrequency(intervalMilliseconds: Int)
    case pausedMinimized
    case permissionMissing
    case notCapturable(String)
}

/// 受限类型分级（方案 §3.3）。
public enum ControlGrade: String, Sendable {
    case full
    case previewOnly
    case restricted
}

public struct WindowRecord: Hashable, Sendable {
    public let identity: WindowIdentity
    public var bundleID: String?
    public var applicationName: String
    public var title: String
    public var axSnapshot: AXWindowSnapshot?
    public var confidence: MatchConfidence
    /// CG 全局坐标（左上原点）。
    public var frame: CGRect
    public var displayID: UInt32
    public var isMinimized: Bool
    public var isMovable: Bool
    public var isResizable: Bool
    public var capture: CapturePhase
    public var slot: SlotID?
    public var lastValidFrameDate: Date?
    public var sessionGeneration: UInt64
    /// 用户将该窗口设为优先刷新。
    public var prefersHighRefresh: Bool
    /// 跨 Space / 原生全屏 / 受保护内容等无法确认时的保守标记。
    public var restriction: WindowRestriction?

    public init(identity: WindowIdentity,
                bundleID: String?,
                applicationName: String,
                title: String,
                axSnapshot: AXWindowSnapshot? = nil,
                confidence: MatchConfidence = .unmatched,
                frame: CGRect,
                displayID: UInt32,
                isMinimized: Bool = false,
                isMovable: Bool = false,
                isResizable: Bool = false,
                capture: CapturePhase = .idle,
                slot: SlotID? = nil,
                lastValidFrameDate: Date? = nil,
                sessionGeneration: UInt64,
                prefersHighRefresh: Bool = false,
                restriction: WindowRestriction? = nil) {
        self.identity = identity
        self.bundleID = bundleID
        self.applicationName = applicationName
        self.title = title
        self.axSnapshot = axSnapshot
        self.confidence = confidence
        self.frame = frame
        self.displayID = displayID
        self.isMinimized = isMinimized
        self.isMovable = isMovable
        self.isResizable = isResizable
        self.capture = capture
        self.slot = slot
        self.lastValidFrameDate = lastValidFrameDate
        self.sessionGeneration = sessionGeneration
        self.prefersHighRefresh = prefersHighRefresh
        self.restriction = restriction
    }

    public var allowsAutoFocus: Bool {
        confidence.allowsAXWrite && restriction?.blocksFocus != true
    }

    public var allowsGeometryControl: Bool {
        allowsAutoFocus && isResizable && restriction?.blocksGeometry != true
    }

    public var grade: ControlGrade {
        if let restriction, restriction.isHardLimit { return .restricted }
        return allowsGeometryControl ? .full : .previewOnly
    }

    /// 宽高比用于卡片 aspectFit，缺尺寸时按 16:10 兜底而不是除零。
    public var aspectRatio: Double {
        guard frame.height > 0, frame.width > 0 else { return 1.6 }
        return Double(frame.width) / Double(frame.height)
    }

    /// 搜索过滤的唯一规则：总览与工作台两栏共用，标题或应用名包含查询词即算命中（方案 §5.5.5）。
    public func matches(searchQuery: String) -> Bool {
        searchQuery.isEmpty
            || title.localizedCaseInsensitiveContains(searchQuery)
            || applicationName.localizedCaseInsensitiveContains(searchQuery)
    }

    /// 跨会话顺序记忆用的稳定键；标题改动不应该重排格子，但需要能记住"曾经的位置"。
    public var memoryKey: String {
        let normalizedTitle = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\((bundleID ?? applicationName).lowercased())|\(normalizedTitle)"
    }

    /// 工作台跨会话偏好键（轨道顺序、固定在顶部）：只用应用标识，不含窗口标题（方案 §16）。
    /// 同一应用的多个窗口共享一个键，它们之间的先后由会话内稳定顺序决定，不落盘标题。
    public var preferenceKey: String {
        (bundleID ?? "name:\(applicationName)").lowercased()
    }
}

public enum WindowRestriction: Hashable, Sendable {
    case otherSpace
    case nativeFullscreen
    case protectedContent
    case unsupportedAX
    /// 被本应用总览覆盖不等于离开当前 Space，因此单独区分"无法确认"。
    case spaceUnverified

    public var blocksFocus: Bool {
        switch self {
        case .otherSpace, .nativeFullscreen, .unsupportedAX, .spaceUnverified: return true
        case .protectedContent: return false
        }
    }

    public var blocksGeometry: Bool {
        switch self {
        case .otherSpace, .nativeFullscreen, .unsupportedAX, .spaceUnverified: return true
        case .protectedContent: return true
        }
    }

    public var isHardLimit: Bool {
        switch self {
        case .protectedContent, .nativeFullscreen, .otherSpace: return true
        case .unsupportedAX, .spaceUnverified: return false
        }
    }
}
