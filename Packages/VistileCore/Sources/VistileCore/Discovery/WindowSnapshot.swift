import Foundation
import CoreGraphics

/// CGWindowList / SCShareableContent 一侧的候选窗口快照。
public struct CaptureWindowSnapshot: Hashable, Sendable {
    public let identity: WindowIdentity
    public let frame: CGRect
    public let title: String
    public let ownerName: String
    public let bundleID: String?
    /// kCGWindowLayer：0 为普通窗口层。
    public let layer: Int
    public let alpha: Double
    public let isOnScreen: Bool
    /// kCGWindowSharingState：0 = None（受保护内容不可捕获）。
    public let sharingState: Int

    public init(identity: WindowIdentity,
                frame: CGRect,
                title: String,
                ownerName: String,
                bundleID: String?,
                layer: Int,
                alpha: Double,
                isOnScreen: Bool,
                sharingState: Int) {
        self.identity = identity
        self.frame = frame
        self.title = title
        self.ownerName = ownerName
        self.bundleID = bundleID
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.sharingState = sharingState
    }

    public var area: CGFloat { max(0, frame.width) * max(0, frame.height) }
}

/// 应用 AX windows 一侧的候选快照。`index` 是 AXWindows 数组下标，只在同一次读取内有效。
public struct AXWindowSnapshot: Hashable, Sendable {
    public let index: Int
    public let frame: CGRect?
    public let title: String
    public let role: String
    public let subrole: String?
    public let isMinimized: Bool
    public let isMain: Bool
    public let isFocused: Bool
    public let isMovable: Bool?
    public let isResizable: Bool?

    public init(index: Int,
                frame: CGRect?,
                title: String,
                role: String = "AXWindow",
                subrole: String? = nil,
                isMinimized: Bool = false,
                isMain: Bool = false,
                isFocused: Bool = false,
                isMovable: Bool? = nil,
                isResizable: Bool? = nil) {
        self.index = index
        self.frame = frame
        self.title = title
        self.role = role
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.isMain = isMain
        self.isFocused = isFocused
        self.isMovable = isMovable
        self.isResizable = isResizable
    }

    /// Sheet/对话框不是独立文档窗口，不应单独成卡（方案 §12）。
    public var isSheetLike: Bool {
        subrole == "AXDialog" || subrole == "AXSystemFloatingWindow" || role == "AXSheet"
    }
}

public enum ExclusionReason: String, Sendable {
    case ownProcess
    case ownOverlay
    case desktopOrDock
    case menuBarOrPanel
    case offScreen
    case tooSmall
    case nearlyTransparent
    case protectedContent
}

public struct WindowEligibility: Hashable, Sendable {
    public let isIncluded: Bool
    public let reason: ExclusionReason?

    public static let included = WindowEligibility(isIncluded: true, reason: nil)
    public static func excluded(_ reason: ExclusionReason) -> WindowEligibility {
        WindowEligibility(isIncluded: false, reason: reason)
    }
}

/// 产品支持范围（方案 §3.3）。注意：标题为空不是排除理由。
public enum WindowEligibilityRules {
    public static func evaluate(_ snapshot: CaptureWindowSnapshot,
                                ownProcessIDs: Set<Int32>,
                                ownWindowIDs: Set<UInt32>,
                                minimumEdge: CGFloat = 24) -> WindowEligibility {
        if ownWindowIDs.contains(snapshot.identity.windowID) { return .excluded(.ownOverlay) }
        if ownProcessIDs.contains(snapshot.identity.processID) { return .excluded(.ownProcess) }
        if !snapshot.isOnScreen { return .excluded(.offScreen) }
        if snapshot.layer < 0 { return .excluded(.desktopOrDock) }
        // 只有普通窗口层进入格子；Dock、菜单栏、提示气泡、工具浮窗层在更高层。
        if snapshot.layer > 0 { return .excluded(.menuBarOrPanel) }
        if snapshot.alpha < 0.05 { return .excluded(.nearlyTransparent) }
        if snapshot.frame.width < minimumEdge || snapshot.frame.height < minimumEdge { return .excluded(.tooSmall) }
        if snapshot.sharingState == 0 { return .excluded(.protectedContent) }
        return .included
    }
}
