import AppKit
import ServiceManagement
import SwiftUI
import VistileCore

/// 可勾选的窗口候选（优先刷新用），由主 Actor 侧快照后传入，视图不跨隔离读目录。
struct WindowChoice: Identifiable, Hashable {
    let key: String
    let label: String
    var id: String { key }
}

/// 设置窗口（方案 §13）。这里只写 SettingsModel，行为变化一律回到协调层走事件管线，
/// 视图不自己保存"当前是不是总览显示中"这类布尔。
@MainActor
final class SettingsWindowController {
    private let coordinator: AppCoordinator
    private let settings: SettingsModel
    private let permissions: PermissionManager
    private var window: NSWindow?
    private var host: NSHostingController<SettingsRootView>?
    private var permissionObserver: NSObjectProtocol?

    private var notice: String = ""

    init(coordinator: AppCoordinator, settings: SettingsModel, permissions: PermissionManager) {
        self.coordinator = coordinator
        self.settings = settings
        self.permissions = permissions
    }

    func showWindow() {
        if window == nil { build() }
        rerender()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let host = NSHostingController(rootView: makeView())
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "Vistile 设置"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 620))
        window.contentMinSize = NSSize(width: 520, height: 420)
        self.host = host
        self.window = window
        permissionObserver = NotificationCenter.default.addObserver(forName: .vistilePermissionsChanged,
                                                                    object: nil,
                                                                    queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rerender() }
        }
    }

    private func makeView() -> SettingsRootView {
        SettingsRootView(settings: settings,
                         permission: permissions.status,
                         launchStatus: Self.launchAtLoginStatus,
                         launchNote: notice,
                         windowChoices: currentWindowChoices(),
                         runningBundleIDs: runningBundleIDs(),
                         onApply: applyCallback(),
                         onRefresh: { [weak self] in self?.rerender() },
                         onRequestPermission: { [weak self] kind in self?.request(kind) },
                         onOpenSystemSettings: { pane in SettingsWindowController.openSettings(pane) },
                         onSetLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
                         onRecordHotKey: { [weak self] in self?.recordHotKey() },
                         onExportDiagnostics: { [weak self] in self?.exportDiagnostics() })
    }

    private func rerender() {
        host?.rootView = makeView()
    }

    /// 写设置后回到协调层：状态机与捕获档位都由事件管线更新，不在这里直接改窗口。
    private func applyCallback() -> () -> Void {
        { [weak coordinator] in
            Task { @MainActor in coordinator?.settingsChanged() }
        }
    }

    private func currentWindowChoices() -> [WindowChoice] {
        coordinator.catalog.currentRecords
            .sorted { $0.applicationName < $1.applicationName }
            .prefix(60)
            .map { WindowChoice(key: $0.memoryKey, label: "\($0.applicationName) · \($0.title.isEmpty ? "无标题" : $0.title)") }
    }

    private func runningBundleIDs() -> [String] {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .filter { $0 != Bundle.main.bundleIdentifier }
            .sorted()
    }

    private func request(_ kind: PermissionKind) {
        switch kind {
        case .screenRecording: _ = permissions.requestScreenRecording()
        case .accessibility: _ = permissions.requestAccessibility(prompt: true)
        }
        rerender()
    }

    /// 开机启动只允许如实报告结果：注册失败时把系统错误原样显示，不假装已开启。
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            settings.launchAtLogin = enabled
            notice = enabled ? "已按系统结果设置开机启动" : "已关闭开机启动"
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            notice = "开机启动未生效：\(error.localizedDescription)"
        }
        rerender()
    }

    private static var launchAtLoginStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "系统记录：已开启"
        case .notRegistered: return "系统记录：未注册"
        case .requiresApproval: return "系统记录：等待用户在「登录项」里批准"
        case .notFound: return "系统记录：系统找不到本应用（未安装到 /Applications）"
        @unknown default: return "系统记录：未知"
        }
    }

    /// 录制只监听本机按键，成功后写绑定；未拿到按键就恢复原值。
    private func recordHotKey() {
        notice = "请按下新的组合键（⌃⌥⌘⇧ 至少一个）…"
        rerender()
        var monitor: Any?
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard let self else { return event }
            let binding = HotKeyBinding.binding(from: event)
            if !binding.hasModifier {
                self.notice = "需要至少一个修饰键，已保留原来的 \(self.settings.hotKey.displayString)"
            } else if !self.coordinator.hotKey.register(binding) {
                self.notice = "注册失败：\(binding.displayString) 可能已被其他应用占用，已保留原组合键"
            } else {
                self.settings.hotKey = binding
                self.notice = "已启用 \(binding.displayString)"
            }
            self.rerender()
            return nil
        }
    }

    private func exportDiagnostics() {
        guard let url = coordinator.recorder.flush() else {
            notice = "诊断记录写入失败，请查看系统日志"
            rerender()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        notice = "诊断记录：\(url.path)"
        rerender()
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - 视图

struct SettingsRootView: View {
    @ObservedObject var settings: SettingsModel
    let permission: PermissionStatus
    let launchStatus: String
    let launchNote: String
    let windowChoices: [WindowChoice]
    let runningBundleIDs: [String]
    let onApply: () -> Void
    let onRefresh: () -> Void
    let onRequestPermission: (PermissionKind) -> Void
    let onOpenSystemSettings: (String) -> Void
    let onSetLaunchAtLogin: (Bool) -> Void
    let onRecordHotKey: () -> Void
    let onExportDiagnostics: () -> Void

    var body: some View {
        Form {
            general
            overview
            focus
            performance
            exclusions
            permissions
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 460)
    }

    private func binding<Value>(_ read: @escaping (SettingsModel) -> Value,
                                _ write: @escaping (SettingsModel, Value) -> Void) -> Binding<Value> {
        Binding(get: { read(self.settings) }, set: { value in
            write(self.settings, value)
            self.onApply()
        })
    }

    @ViewBuilder private var general: some View {
        Section("通用") {
            Toggle("开机启动", isOn: binding({ $0.launchAtLogin }, { $0.launchAtLogin = $1 }))
                .onChange(of: settings.launchAtLogin) { _, enabled in onSetLaunchAtLogin(enabled) }
            Text(launchStatus).font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("全局快捷键")
                Spacer()
                Text(settings.hotKey.displayString).monospaced()
            }
            HStack {
                Button("录制新组合键", action: onRecordHotKey)
                Button("恢复默认") {
                    settings.hotKey = .default
                    onApply()
                }
            }
            if !launchNote.isEmpty {
                Text(launchNote).font(.callout).foregroundStyle(.secondary)
            }
            Toggle("详细系统日志", isOn: binding({ $0.verboseLogging }, { $0.verboseLogging = $1 }))
        }
    }

    @ViewBuilder private var overview: some View {
        Section("总览") {
            Picker("密度", selection: binding({ $0.density }, { $0.density = $1 })) {
                ForEach(LayoutDensity.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Toggle("显示窗口标题", isOn: binding({ $0.showsTitles }, { $0.showsTitles = $1 }))
            Picker("排序", selection: binding({ $0.sortMode }, { $0.sortMode = $1 })) {
                ForEach(OverviewSortMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("层级策略", selection: binding({ $0.orderingStrategy }, { $0.orderingStrategy = $1 })) {
                ForEach(OrderingStrategy.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("层级是否真的稳定压过其他应用，必须以实测记录为准；未验证前不要当成保证。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var focus: some View {
        Section("聚焦") {
            Slider(value: binding({ $0.foregroundWidthRatio }, { $0.foregroundWidthRatio = $1 }),
                   in: 0.75...0.94) {
                Text("前景宽度 \(Int(settings.foregroundWidthRatio * 100))%")
            }
            Slider(value: binding({ $0.foregroundHeightRatio }, { $0.foregroundHeightRatio = $1 }),
                   in: 0.75...0.94) {
                Text("前景高度 \(Int(settings.foregroundHeightRatio * 100))%")
            }
            Toggle("点击背景卡片直接切换", isOn: binding({ $0.backgroundClickSwitches }, { $0.backgroundClickSwitches = $1 }))
            Text("默认关闭：背景只负责回到总览，避免误切窗口。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("保留聚焦期间我手动调整的尺寸", isOn: binding({ $0.preserveUserGeometry }, { $0.preserveUserGeometry = $1 }))
            Text("关闭时，退出会把我临时改过的窗口尺寸恢复原样。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var performance: some View {
        Section("性能") {
            Picker("刷新档位", selection: binding({ $0.tier }, { $0.tier = $1 })) {
                ForEach(CaptureTier.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("目标帧率是上限而非承诺；窗口很多时系统会按预算降级，卡片会写明实际更新方式。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("优先刷新")
                Spacer()
                Button("刷新窗口列表", action: onRefresh)
            }
            if windowChoices.isEmpty {
                Text("打开总览后这里会列出当前窗口。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(windowChoices) { choice in
                Toggle(choice.label, isOn: binding({ $0.isPriority(choice.key) }, { model, value in
                    if value != model.isPriority(choice.key) { model.togglePriority(choice.key) }
                }))
            }
        }
    }

    @ViewBuilder private var exclusions: some View {
        Section("不参与总览的应用") {
            if settings.excludedBundleIDs.isEmpty {
                Text("未排除任何应用。").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                    Spacer()
                    Button("移除") {
                        settings.excludedBundleIDs.removeAll { $0 == bundleID }
                        onApply()
                    }
                }
            }
            Menu("添加要排除的应用") {
                ForEach(runningBundleIDs.filter { !settings.excludedBundleIDs.contains($0) }.prefix(40), id: \.self) { id in
                    Button(id) {
                        settings.excludedBundleIDs.append(id)
                        onApply()
                    }
                }
            }
        }
    }

    @ViewBuilder private var permissions: some View {
        Section("权限与诊断") {
            HStack {
                StatusDot(granted: permission.screenRecording)
                Text("屏幕录制（实时卡片）")
                Spacer()
                if !permission.screenRecording {
                    Button("申请") { onRequestPermission(.screenRecording) }
                    Button("打开设置") { onOpenSystemSettings("Privacy_ScreenCapture") }
                }
            }
            HStack {
                StatusDot(granted: permission.accessibility)
                Text("辅助功能（聚焦与恢复窗口）")
                Spacer()
                if !permission.accessibility {
                    Button("申请") { onRequestPermission(.accessibility) }
                    Button("打开设置") { onOpenSystemSettings("Privacy_Accessibility") }
                }
            }
            Text("两项权限只用于窗口画面与窗口位置，标题不会写入日志或磁盘记录。")
                .font(.callout).foregroundStyle(.secondary)
            Button("导出诊断记录", action: onExportDiagnostics)
        }
    }
}

private struct StatusDot: View {
    let granted: Bool
    var body: some View {
        Circle()
            .fill(granted ? Color.green : Color.orange)
            .frame(width: 8, height: 8)
    }
}

private extension LayoutDensity {
    var displayName: String {
        switch self {
        case .standard: return "标准"
        case .compact: return "紧凑"
        }
    }
}

extension CaptureTier {
    var displayName: String {
        switch self {
        case .balanced: return "均衡（约 \(targetFPS) 帧上限）"
        case .powerSaving: return "省电（约 \(targetFPS) 帧上限）"
        case .refreshPriority: return "优先刷新（约 \(targetFPS) 帧上限）"
        }
    }
}
