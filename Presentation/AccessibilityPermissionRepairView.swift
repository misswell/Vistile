import AppKit
import SwiftUI

@MainActor
final class AccessibilityPermissionRepair: ObservableObject {
    @Published private(set) var isResetting = false
    @Published private(set) var message: String?
    private let permissions: PermissionGuiding
    private let openSettings: () -> Void

    init(permissions: PermissionGuiding,
         openSettings: @escaping () -> Void = {
             if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                 NSWorkspace.shared.open(url)
             }
         }) {
        self.permissions = permissions
        self.openSettings = openSettings
    }

    func repair() async {
        guard !isResetting else { return }
        isResetting = true
        message = nil
        defer { isResetting = false }
        do {
            try await permissions.resetAccessibility()
            _ = permissions.requestAccessibility(prompt: true)
            message = "已清除旧授权并重新申请。请在系统设置中开启 Vistile，返回后重新检查；若仍未生效，请退出并重新打开 Vistile。"
            openSettings()
        } catch {
            message = "清除失败：\(error.localizedDescription)"
        }
    }
}

struct AccessibilityPermissionRepairView: View {
    @ObservedObject var repair: AccessibilityPermissionRepair

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统开关已开启却仍显示未授权？可清除 Vistile 的旧辅助功能授权，再重新开启。")
                .font(.callout).foregroundStyle(.secondary)
            Button(repair.isResetting ? "正在清除授权…" : "清除授权并重新授权") {
                Task { await repair.repair() }
            }
            .disabled(repair.isResetting)
            if let message = repair.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
