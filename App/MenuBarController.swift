import AppKit
import VistileCore

/// 菜单栏常驻入口（方案 §11：第一版通过快捷键与菜单栏进入）。
/// 这里只提供动作与事实状态，不复制会话状态机。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let settings: SettingsModel
    private let permissions: PermissionManager

    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?

    private let statusLine = NSMenuItem(title: "准备中", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem()
    private let permissionsItem = NSMenuItem(title: "权限与诊断…", action: nil, keyEquivalent: "")

    init(coordinator: AppCoordinator, settings: SettingsModel, permissions: PermissionManager) {
        self.coordinator = coordinator
        self.settings = settings
        self.permissions = permissions
        super.init()
        build()
    }

    private func build() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "Vistile 窗口总览"
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleItem.title = "打开总览"
        toggleItem.target = self
        toggleItem.action = #selector(toggleOverview)
        toggleItem.keyEquivalent = ""
        menu.addItem(toggleItem)

        let back = NSMenuItem(title: "返回总览", action: #selector(returnToOverview), keyEquivalent: "")
        back.target = self
        menu.addItem(back)

        let organize = NSMenuItem(title: "整理格子", action: #selector(organize), keyEquivalent: "")
        organize.target = self
        menu.addItem(organize)

        let refresh = NSMenuItem(title: "重新扫描窗口", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        permissionsItem.action = #selector(showOnboarding)
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Vistile", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        permissions.refresh()
        toggleItem.title = coordinator.state.phase.isVisible ? "关闭总览" : "打开总览"
        permissionsItem.title = permissions.status.isComplete
            ? "权限已就绪 · 打开诊断记录"
            : "需要授权：\(missingPermissionNames())"
    }

    private func missingPermissionNames() -> String {
        var names: [String] = []
        if !permissions.status.screenRecording { names.append("屏幕录制") }
        if !permissions.status.accessibility { names.append("辅助功能") }
        return names.isEmpty ? "无" : names.joined(separator: "、")
    }

    // MARK: - 动作

    @objc private func toggleOverview() { coordinator.toggleOverview() }
    @objc private func returnToOverview() { coordinator.returnToOverview() }
    @objc private func organize() { coordinator.organizeNow() }
    @objc private func refresh() { coordinator.refreshNow() }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(coordinator: coordinator,
                                                      settings: settings,
                                                      permissions: permissions)
        }
        settingsWindow?.showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(settings: settings, permissions: permissions)
            onboarding?.onFinished = { [weak self] in self?.coordinator.settingsChanged() }
        }
        onboarding?.showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 图标方向：2×2 格子，其中一格向外扩成窗口轮廓；单色描边，无 3D 与厚渐变（方案 §13）。
    static func menuBarIcon(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let stroke = NSColor.labelColor
        stroke.setStroke()
        let cell = size * 0.38
        let gap = size * 0.10
        // 三个小格 + 一个扩出的窗口轮廓。
        let positions = [
            CGPoint(x: 0, y: size - cell),
            CGPoint(x: size - cell, y: size - cell),
            CGPoint(x: 0, y: 0),
        ]
        for origin in positions {
            let rect = CGRect(x: origin.x, y: origin.y, width: cell, height: cell)
            let path = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
            path.lineWidth = 1.2
            path.stroke()
        }
        let expanded = CGRect(x: size - cell - gap * 0.4, y: 0, width: cell + gap * 0.4, height: cell + gap * 0.4)
        let outline = NSBezierPath(roundedRect: expanded, xRadius: 2, yRadius: 2)
        outline.lineWidth = 1.6
        outline.stroke()
        let bar = NSBezierPath(rect: CGRect(x: expanded.minX, y: expanded.maxY - 3.2,
                                            width: expanded.width, height: 3.2))
        bar.fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
