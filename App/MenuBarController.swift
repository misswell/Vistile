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
    private let openItem = NSMenuItem()
    private let backItem = NSMenuItem()
    private let hideItem = NSMenuItem()
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
        // 只允许缩小，不允许放大：菜单栏变矮时保持与系统图标同样的视觉大小，而不是撑满。
        item.button?.imageScaling = .scaleProportionallyDown
        item.button?.image = Self.menuBarIcon()
        item.button?.toolTip = "Vistile 窗口总览"
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // 三个入口分开写：打开永远先全屏总览，回来才是回到全部窗口，隐藏是明确动作（方案 §11、§16）。
        openItem.title = "打开窗口总览"
        openItem.target = self
        openItem.action = #selector(openOverview)
        menu.addItem(openItem)

        backItem.title = "回到全部窗口"
        backItem.target = self
        backItem.action = #selector(returnToOverview)
        menu.addItem(backItem)

        hideItem.title = "隐藏"
        hideItem.target = self
        hideItem.action = #selector(hideOverview)
        menu.addItem(hideItem)

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
        let visible = coordinator.state.phase.isVisible
        let inWorkbench = coordinator.state.mode == .workbench
        // 已开着时「打开」没有意义，反之亦然；工作台外「回到全部窗口」也是空动作。
        openItem.isEnabled = !visible
        backItem.isEnabled = inWorkbench
        hideItem.isEnabled = visible
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

    /// 只在隐藏态可用：每次打开都先落在全屏总览，工作台只能由点击卡片进入（方案 §4.1、§16）。
    @objc private func openOverview() { coordinator.toggleOverview() }
    @objc private func returnToOverview() { coordinator.returnToAllWindows() }
    @objc private func hideOverview() { coordinator.hideNow() }
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
    /// 视觉大小必须与相邻系统图标一致：18pt 画布里只占 15pt 墨迹（14pt 字形 + 1pt 描边）并居中。
    /// 边线全部落在 0.5pt 网格上，2x 屏下描边边界正好是整像素，避免发虚。
    static func menuBarIcon(canvas: CGFloat = 18) -> NSImage {
        let box: CGFloat = 14
        let cell: CGFloat = 5
        let expanded: CGFloat = 7
        let inset = (canvas - box) / 2
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        NSColor.black.setStroke()

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: inset + x, y: inset + y)
        }

        // 三个小格：左上、右上、左下。
        for origin in [point(0, box - cell), point(box - cell, box - cell), point(0, 0)] {
            let path = NSBezierPath(roundedRect: CGRect(origin: origin, size: CGSize(width: cell, height: cell)),
                                    xRadius: 1.2, yRadius: 1.2)
            path.lineWidth = 1
            path.stroke()
        }

        // 右下：向外扩成的窗口轮廓，比小格高出一档，顶部一条细线表示标题栏。
        let window = CGRect(x: inset + box - expanded, y: inset, width: expanded, height: expanded)
        let outline = NSBezierPath(roundedRect: window, xRadius: 1.5, yRadius: 1.5)
        outline.lineWidth = 1
        outline.stroke()
        let titleBar = NSBezierPath()
        titleBar.lineWidth = 1
        titleBar.move(to: CGPoint(x: window.minX + 1.5, y: window.maxY - 2))
        titleBar.line(to: CGPoint(x: window.maxX - 1.5, y: window.maxY - 2))
        titleBar.stroke()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
