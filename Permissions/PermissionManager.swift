import AppKit
import CoreGraphics
import ApplicationServices
import VistileCore

struct PermissionStatus: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
    var isComplete: Bool { screenRecording && accessibility }
}

/// 宿主协作方只需要"当前权限事实"，不需要申请动作：
/// 抽成协议后，目录/过渡/恢复才能在宿主测试里注入固定权限，而不是依赖本机授权状态（方案 §15.1）。
protocol PermissionChecking {
    var status: PermissionStatus { get }
    /// 重新取得权限事实：真实管理器探测系统，替身没有可探测的新事实（见下方默认实现）。
    func refresh() -> PermissionStatus
}

extension PermissionManager: PermissionChecking {}

extension PermissionChecking {
    /// 替身的固定事实不会在两次读取之间变化：默认原样回报。
    func refresh() -> PermissionStatus { status }
}

/// 只做公开预检与分步申请，不模拟授权结果。
final class PermissionManager {
    private(set) var status = PermissionStatus(screenRecording: false, accessibility: false)
    private var promptSeen: Set<String> = []

    init() {
        refresh()
    }

    @discardableResult
    func refresh() -> PermissionStatus {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        let next = PermissionStatus(screenRecording: screen, accessibility: ax)
        if next != status {
            status = next
            NotificationCenter.default.post(name: .vistilePermissionsChanged, object: status)
        }
        return status
    }

    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .screenRecording: return status.screenRecording
        case .accessibility: return refresh().accessibility
        }
    }

    /// 屏幕录制：用于生成实时卡片。
    @discardableResult
    func requestScreenRecording() -> Bool {
        if status.screenRecording { return true }
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted || status.screenRecording
    }

    /// 辅助功能：用于激活和调整窗口。
    @discardableResult
    func requestAccessibility(prompt: Bool) -> Bool {
        if status.accessibility { return true }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: [String: Bool] = prompt ? [key: true] : [:]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        refresh()
        return trusted || status.accessibility
    }

    /// 同一步只提示一次，避免未授予时持续弹窗。
    func guideStep() -> PermissionKind? {
        refresh()
        if !status.screenRecording { return .screenRecording }
        if !status.accessibility { return .accessibility }
        return nil
    }

    func markPrompted(_ kind: PermissionKind) {
        promptSeen.insert(kind.rawValue)
    }

    func didPrompt(_ kind: PermissionKind) -> Bool {
        promptSeen.contains(kind.rawValue)
    }
}

extension Notification.Name {
    static let vistilePermissionsChanged = Notification.Name("Vistile.PermissionsChanged")
    static let vistileDisplaysChanged = Notification.Name("Vistile.DisplaysChanged")
}
