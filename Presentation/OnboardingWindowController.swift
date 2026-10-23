import AppKit
import SwiftUI
import VistileCore

/// 首次运行引导（方案 §13：权限分步申请，说明用途与不申请的后果）。
/// 只报告系统真实状态：未授权时明确写"无实时画面/无法聚焦"，不模拟成功。
@MainActor
final class OnboardingWindowController {
    var onFinished: (() -> Void)?

    private let settings: SettingsModel
    private let permissions: PermissionGuiding
    private let accessibilityRepair: AccessibilityPermissionRepair
    private(set) var window: NSWindow?
    private var host: NSHostingController<OnboardingView>?
    private var closeHandler: CloseHandler?
    private var step = 0
    private var observers: [NSObjectProtocol] = []

    init(settings: SettingsModel, permissions: PermissionGuiding) {
        self.settings = settings
        self.permissions = permissions
        accessibilityRepair = AccessibilityPermissionRepair(permissions: permissions)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .vistilePermissionsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.rerender() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissions() }
        })
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func showWindow() {
        loadWindow()
        refreshPermissions()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func loadWindow() {
        guard window == nil else { return }
        let host = NSHostingController(rootView: makeView())
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "欢迎使用 Vistile"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 430))
        let handler = CloseHandler { [weak self] in self?.finishIfReady() }
        closeHandler = handler
        window.delegate = handler
        self.host = host
        self.window = window
    }

    private func makeView() -> OnboardingView {
        OnboardingView(step: step,
                       permission: permissions.status,
                       accessibilityRepair: accessibilityRepair,
                       hotKey: settings.hotKey.displayString,
                       onNext: { [weak self] in self?.advance() },
                       onBack: { [weak self] in self?.move(-1) },
                       onRequest: { [weak self] kind in self?.request(kind) },
                       onOpenSettings: { pane in
                           if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                               NSWorkspace.shared.open(url)
                           }
                       },
                       onFinish: { [weak self] in self?.finish() })
    }

    private func rerender() { host?.rootView = makeView() }

    private func refreshPermissions() {
        _ = permissions.refresh()
        rerender()
    }

    private func advance() {
        refreshPermissions()
        // 未授权时留在对应步骤，不能进入“可以开始了”。
        if step == 1 && !permissions.status.screenRecording { return }
        if step == 2 {
            guard permissions.status.isComplete else {
                if !permissions.status.screenRecording { step = 1; rerender() }
                return
            }
        }
        move(1)
    }

    private func move(_ delta: Int) {
        step = min(3, max(0, step + delta))
        rerender()
    }

    private func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording: _ = permissions.requestScreenRecording()
        case .accessibility: _ = permissions.requestAccessibility(prompt: true)
        }
        // 授权后系统需要几秒才反映到预检结果；这里只刷新，不承诺已授予。
        _ = permissions.refresh()
        rerender()
    }

    private func finish() {
        refreshPermissions()
        guard permissions.status.isComplete else {
            step = permissions.status.screenRecording ? 2 : 1
            rerender()
            return
        }
        settings.didCompleteGuidedSetup = true
        step = 3
        rerender()
        onFinished?()
    }

    /// 关窗也算完成引导的前提是权限已就绪；否则下次启动还会再引导一次。
    private func finishIfReady() {
        refreshPermissions()
        guard permissions.status.isComplete else { return }
        settings.didCompleteGuidedSetup = true
        onFinished?()
    }
}

struct OnboardingView: View {
    let step: Int
    let permission: PermissionStatus
    let accessibilityRepair: AccessibilityPermissionRepair
    let hotKey: String
    let onNext: () -> Void
    let onBack: () -> Void
    let onRequest: (PermissionKind) -> Void
    let onOpenSettings: (String) -> Void
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            Text(stepCaption).font(.body).foregroundStyle(.primary)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(22)
        .frame(width: 520, height: 430)
    }

    private var title: String {
        switch step {
        case 0: return "Vistile 把窗口摊成一屏总览"
        case 1: return "需要屏幕录制权限"
        case 2: return "需要辅助功能权限"
        default: return "可以开始了"
        }
    }

    private var stepCaption: String {
        switch step {
        case 0:
            return "总览里每个格子都是窗口自己的实时画面。点格子会把真实窗口放大到前台，点背景回到总览。"
                + "收回不会最小化窗口，退出时会被临时改过的尺寸会恢复原样。"
        case 1:
            return "屏幕录制只用于生成卡片画面。没有它，格子只能显示占位色块，无法给出实时预览。"
                + "画面像素不会写入磁盘。"
        case 2:
            return "辅助功能只用于把窗口移到指定位置、以及退出时恢复原位置。"
                + "没有它，Vistile 仍可显示总览，但点击卡片只能激活窗口、不能调整尺寸与位置。"
        default:
            return "快捷键默认 \(hotKey)。按一次进入总览，再按一次回到当前窗口。"
                + "任何时候都可以从菜单栏更换组合键或调整密度。"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(granted: permission.screenRecording,
                              missing: "未授予：卡片没有实时画面")
                Button("申请屏幕录制") { onRequest(.screenRecording) }
                    .disabled(permission.screenRecording)
                Button("在系统设置中打开") { onOpenSettings("Privacy_ScreenCapture") }
                Text("系统会要求重新打开应用才能生效；这一步不能由程序替你确认。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(granted: permission.accessibility,
                              missing: "未授予：不能移动或调整窗口")
                Button("申请辅助功能") { onRequest(.accessibility) }
                    .disabled(permission.accessibility)
                Button("在系统设置中打开") { onOpenSettings("Privacy_Accessibility") }
                Text("开启 Vistile 后，回到本窗口点“已处理，重新检查”。系统也可能将此权限称为“设备控制和数据访问”。")
                    .font(.callout).foregroundStyle(.secondary)
                if !permission.accessibility {
                    AccessibilityPermissionRepairView(repair: accessibilityRepair)
                }
            }
        case 3:
            VStack(alignment: .leading, spacing: 10) {
                Label("屏幕录制", systemImage: permission.screenRecording ? "checkmark.circle.fill" : "xmark.circle")
                Label("辅助功能", systemImage: permission.accessibility ? "checkmark.circle.fill" : "xmark.circle")
                Text("按 \(hotKey) 试试。窗口很多时格子会很小，可以直接输入名称筛选。")
                    .font(.callout).foregroundStyle(.secondary)
                Text("跨应用的交互表现需要实测记录，未完成验收前请在诊断记录里保留“未测”。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                Bullet("格子位置固定，不会因为聚焦或返回而跳动")
                Bullet("被遮挡的窗口依然实时更新")
                Bullet("中文输入、右键菜单、滚动、快捷键都交还给真实窗口")
                Bullet("不使用私有接口，也不注入其他进程")
            }
        }
    }

    /// 未授予时不推进到"看起来完成了"的步骤，只提供下一步入口。
    @ViewBuilder private var footer: some View {
        HStack {
            if step > 0 { Button("上一步", action: onBack) }
            Spacer()
            if step < 2 {
                Button(step == 0 ? "开始" : "下一步", action: onNext)
            } else if step == 2 {
                Button("已处理，重新检查", action: onNext)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("完成", action: onFinish)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let missing: String
    var body: some View {
        HStack {
            Circle().fill(granted ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(granted ? "已授予" : missing)
        }
    }
}

private struct Bullet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "circle")
                .font(.system(size: 5))
                .padding(.top, 6)
            Text(text)
        }
    }
}

/// 只有一个回调的窗口代理，避免为一次 close 通知引入常驻对象。
private final class CloseHandler: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
