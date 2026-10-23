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

/// 工作台屏幕候选：编号是目录里的显示器 id，名字来自系统（方案 §13）。
struct DisplayChoice: Identifiable, Hashable {
    let id: UInt32
    let name: String
}

/// 设置窗口（方案 §13）。这里只写 SettingsModel，行为变化一律回到协调层走事件管线，
/// 视图不自己保存"当前是不是总览显示中"这类布尔。
@MainActor
final class SettingsWindowController {
    private let coordinator: AppCoordinator
    private let settings: SettingsModel
    private let permissions: PermissionManager
    private let accessibilityRepair: AccessibilityPermissionRepair
    private var window: NSWindow?
    private var host: NSHostingController<SettingsRootView>?
    private var permissionObserver: NSObjectProtocol?

    private var notice: String = ""

    init(coordinator: AppCoordinator, settings: SettingsModel, permissions: PermissionManager) {
        self.coordinator = coordinator
        self.settings = settings
        self.permissions = permissions
        accessibilityRepair = AccessibilityPermissionRepair(permissions: permissions)
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
                         accessibilityRepair: accessibilityRepair,
                         launchStatus: Self.launchAtLoginStatus,
                         launchNote: notice,
                         windowChoices: currentWindowChoices(),
                         runningBundleIDs: runningBundleIDs(),
                         displayChoices: displayChoices(),
                         onApply: applyCallback(),
                         onRefresh: { [weak self] in self?.rerender() },
                         onRequestPermission: { [weak self] kind in self?.request(kind) },
                         onOpenSystemSettings: { pane in SettingsWindowController.openSettings(pane) },
                         onSetLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
                         onRecordHotKey: { [weak self] in self?.recordHotKey() },
                         onWorkbenchSide: { [weak self] side in self?.coordinator.setWorkbenchSide(side) },
                         onWorkbenchDisplay: { [weak self] id in self?.coordinator.setPreferredWorkbenchDisplay(id) },
                         onResetRailSizes: { [weak self] in self?.resetRailSizePreference() },
                         onExportDiagnostics: { [weak self] in self?.exportDiagnostics() })
    }

    /// 显示器名字来自 NSScreen，编号来自目录的显示器事实：两者对不上时如实显示编号（方案 §13）。
    private func displayChoices() -> [DisplayChoice] {
        let screens = NSScreen.screens
        return coordinator.catalog.mapper.displays.map { display in
            let number = screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
            }
            let name = number.map { $0.localizedName } ?? "显示器 \(display.id)"
            return DisplayChoice(id: display.id, name: display.isPrimary ? "\(name)（主屏）" : name)
        }
    }

    private func resetRailSizePreference() {
        settings.workbenchTopHeight = nil
        settings.workbenchSideWidth = nil
        notice = "栏尺寸偏好已清空；下次进入工作台按布局默认值展开"
        rerender()
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

    /// 优先刷新按应用聚合：键是应用级 memoryKey（方案 §16，不含窗口标题），同一应用的多个窗口合并为一项。
    private func currentWindowChoices() -> [WindowChoice] {
        var order: [String] = []
        var groups: [String: (label: String, count: Int)] = [:]
        for record in coordinator.catalog.currentRecords.sorted(by: { $0.applicationName < $1.applicationName }) {
            let key = record.memoryKey
            if let existing = groups[key] {
                groups[key] = (existing.label, existing.count + 1)
            } else {
                groups[key] = (record.applicationName, 1)
                order.append(key)
            }
        }
        return order.prefix(60).compactMap { key in
            guard let group = groups[key] else { return nil }
            return WindowChoice(key: key,
                                label: group.count > 1 ? "\(group.label)（\(group.count) 个窗口）" : group.label)
        }
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
    let accessibilityRepair: AccessibilityPermissionRepair
    let launchStatus: String
    let launchNote: String
    let windowChoices: [WindowChoice]
    let runningBundleIDs: [String]
    let displayChoices: [DisplayChoice]
    let onApply: () -> Void
    let onRefresh: () -> Void
    let onRequestPermission: (PermissionKind) -> Void
    let onOpenSystemSettings: (String) -> Void
    let onSetLaunchAtLogin: (Bool) -> Void
    let onRecordHotKey: () -> Void
    let onWorkbenchSide: (RailSide) -> Void
    let onWorkbenchDisplay: (UInt32?) -> Void
    let onResetRailSizes: () -> Void
    let onExportDiagnostics: () -> Void

    var body: some View {
        Form {
            general
            overview
            workbench
            recovery
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
                ForEach(OrderingStrategy.userSelectableCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Text("层级是否真的稳定压过其他应用，必须以实测记录为准；未验证前不要当成保证。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var workbench: some View {
        Section("工作台（L 型）") {
            Picker("侧栏方向", selection: Binding(get: { settings.workbenchSide },
                                              set: { onWorkbenchSide($0) })) {
                Text("左栏").tag(RailSide.left)
                Text("右栏").tag(RailSide.right)
            }
            Picker("工作台屏幕", selection: Binding(get: { settings.preferredWorkbenchDisplayID },
                                                set: { onWorkbenchDisplay($0) })) {
                Text("跟随点击的窗口").tag(UInt32?.none)
                ForEach(displayChoices) { choice in
                    Text(choice.name).tag(UInt32?.some(choice.id))
                }
            }
            Text("默认跟随点击：点哪块屏上的卡片，工作台就开在哪块屏。指定屏幕后固定在该屏；屏幕被拔掉会自动退回跟随点击。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("栏尺寸")
                Spacer()
                Button("恢复默认栏尺寸", action: onResetRailSizes)
            }
            Text("主区几何由布局决定，不再叠加旧版的前景宽高比例；点击卡片始终把该窗口换进主区，点空白处保持不动。")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var recovery: some View {
        Section("窗口恢复") {
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
            if !permission.accessibility {
                AccessibilityPermissionRepairView(repair: accessibilityRepair)
            }
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
