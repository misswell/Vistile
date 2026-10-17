import AppKit
import VistileCore

/// 菜单栏常驻入口（方案 §11：第一版通过快捷键与菜单栏进入）。
/// 这里只提供动作与事实状态，不复制会话状态机。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let coordinator: AppCoordinator
    private let settings: SettingsModel
    private let permissions: PermissionManager

    private(set) var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    /// GitHub Releases 更新通道（方案 §21）：菜单"检查更新…"与启动后的一次静默检查共用。
    private(set) var updateChecker: UpdateChecker
    let checkUpdatesItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")

    private let statusLine = NSMenuItem(title: "准备中", action: nil, keyEquivalent: "")
    let openItem = NSMenuItem()
    let backItem = NSMenuItem()
    let hideItem = NSMenuItem()
    private let permissionsItem = NSMenuItem(title: "权限与诊断…", action: nil, keyEquivalent: "")
    /// 菜单本体：宿主测试直接读条目与启用态，不必经系统菜单弹层（方案 §18.2）。
    let statusMenu = NSMenu()

    /// 测试宿主传 false：不在用户菜单栏里插图标（方案 §18.2）。
    init(coordinator: AppCoordinator,
         settings: SettingsModel,
         permissions: PermissionManager,
         updateChecker: UpdateChecker? = nil,
         installsStatusItem: Bool = true,
         performsAutomaticUpdateCheck: Bool = true) {
        self.coordinator = coordinator
        self.settings = settings
        self.permissions = permissions
        self.updateChecker = updateChecker ?? UpdateChecker(settings: settings)
        super.init()
        let item = installsStatusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) : nil
        build(into: item)
        // 只装在真实菜单栏时才自动检查：测试宿主/无图标模式不碰网络、也不弹窗。
        if performsAutomaticUpdateCheck && installsStatusItem {
            scheduleAutomaticUpdateCheck(delayed: true)
        }
    }

    private func build(into item: NSStatusItem?) {
        // 只允许缩小，不允许放大：菜单栏变矮时保持与系统图标同样的视觉大小，而不是撑满。
        item?.button?.imageScaling = .scaleProportionallyDown
        item?.button?.image = Self.menuBarIcon()
        item?.button?.toolTip = "Vistile 窗口总览"
        statusItem = item

        let menu = statusMenu
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

        checkUpdatesItem.target = self
        checkUpdatesItem.action = #selector(checkForUpdates)
        menu.addItem(checkUpdatesItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Vistile", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item?.menu = menu
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

    // MARK: 更新通道

    /// 启动后的静默检查：24h 节流、只有发现新版本才弹一次（可在设置里关掉，方案 §21）。
    private func scheduleAutomaticUpdateCheck(delayed: Bool) {
        Task { @MainActor [weak self] in
            if delayed { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            guard let self else { return }
            let outcome = await self.updateChecker.checkIfDue()
            if case let .available(package) = outcome {
                self.offerUpdate(package)
            }
        }
    }

    @objc private func checkForUpdates() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.checkUpdatesItem.isEnabled = false
            defer { self.checkUpdatesItem.isEnabled = true }
            self.presentUpdateOutcome(await self.updateChecker.checkNow())
        }
    }

    private func presentUpdateOutcome(_ outcome: UpdateCheckOutcome) {
        switch outcome {
        case let .upToDate(current):
            let alert = NSAlert()
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前版本 \(current)，更新通道已是最新。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        case let .available(package), let .skipped(package):
            // 手动检查即使在"跳过此版本"之后也要展示，否则用户无从恢复。
            offerUpdate(package)
        case let .failed(reason):
            let alert = NSAlert()
            alert.messageText = "检查更新失败"
            alert.informativeText = reason
            alert.addButton(withTitle: "好")
            alert.runModal()
        case .throttled:
            break
        }
    }

    private func offerUpdate(_ package: UpdatePackage) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(package.version)"
        alert.informativeText = Self.updateNotes(for: package)
        // 顺序：镜像优先（国内直连 GitHub release 资产常超时）→ GitHub 兜底 → 稍后 → 跳过。
        let hasMirror = package.mirrorURL != nil
        if hasMirror { alert.addButton(withTitle: "从镜像下载") }
        alert.addButton(withTitle: hasMirror ? "打开 GitHub 发布页" : "打开发布页")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch index {
        case 0 where hasMirror:
            NSWorkspace.shared.open(package.mirrorURL!)
        case 0, 1:
            NSWorkspace.shared.open(package.release.htmlURL)
        case alert.buttons.count - 1:
            updateChecker.skip(package)
        default:
            break
        }
    }

    private static func updateNotes(for package: UpdatePackage) -> String {
        var lines: [String] = []
        if let asset = package.asset {
            lines.append("安装包：\(asset.name)（\(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))）")
        } else {
            lines.append("发布页：\(package.release.htmlURL.absoluteString)")
        }
        if package.mirrorURL != nil {
            lines.append("镜像：autocrop.liuguofeng.com（自有服务器，国内直连）")
            lines.append("国内网络直连 GitHub release 资产常超时；镜像不可用时再走 GitHub 发布页。")
        }
        if let checksum = package.checksumURL {
            lines.append("校验：\(checksum.absoluteString)")
        }
        if let body = package.release.body, !body.isEmpty {
            let trimmed = body.count > 700 ? String(body.prefix(700)) + "…" : body
            lines.append("")
            lines.append(trimmed)
        }
        lines.append("")
        lines.append("下载后把 Vistile.app 拖进「应用程序」覆盖旧版本；可用 `shasum -a 256 <文件>` 对照 .sha256 校验。")
        return lines.joined(separator: "\n")
    }

    /// 只在隐藏态可用：每次打开都先落在全屏总览，工作台只能由点击卡片进入（方案 §4.1、§16）。
    @objc func openOverview() { coordinator.toggleOverview() }
    @objc func returnToOverview() { coordinator.returnToAllWindows() }
    @objc func hideOverview() { coordinator.hideNow() }
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


// MARK: - GitHub Releases 更新通道（方案 §21）

enum UpdateCheckFailure: Error, Equatable {
    case network(String)
    case decoding(String)
}

/// 拉取 release 列表的接缝：测试注入固定 JSON，生产走 GitHub API。
protocol UpdateReleasesFetching: Sendable {
    func fetchReleases() async throws -> Data
}

struct GitHubReleasesFetcher: UpdateReleasesFetching {
    let repository: String
    let session: URLSession

    init(repository: String = UpdateChannelPolicy.defaultRepository,
         session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    static func userAgent() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "\(UpdateChannelPolicy.userAgentProduct)/\(version) (+https://github.com/\(UpdateChannelPolicy.defaultRepository))"
    }

    func fetchReleases() async throws -> Data {
        var request = URLRequest(url: UpdateChannelPolicy.releasesEndpoint(repository: repository))
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub API 要求 User-Agent；未认证限额 60 次/小时，靠 24h 节流兜住。
        request.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateCheckFailure.network("响应不是 HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw UpdateCheckFailure.network("GitHub API 返回 HTTP \(http.statusCode)"
                    + (http.statusCode == 403 ? "（可能触发了未认证限额 60 次/小时）" : ""))
            }
            return data
        } catch let failure as UpdateCheckFailure {
            throw failure
        } catch {
            throw UpdateCheckFailure.network(error.localizedDescription)
        }
    }
}

enum UpdateCheckOutcome: Equatable {
    case upToDate(current: String)
    case available(UpdatePackage)
    case skipped(UpdatePackage)
    case failed(String)
    /// 自动检查落在 24h 节流窗口里：什么都不用做。
    case throttled
}

/// 更新检查的全部决策：节流、跳过版本、选包。网络与版本比较分别走接缝与核心纯逻辑。
@MainActor
final class UpdateChecker: ObservableObject {
    static let automaticInterval: TimeInterval = 24 * 60 * 60

    private let settings: SettingsModel
    private let fetcher: UpdateReleasesFetching
    private let currentVersion: AppVersion
    private let now: () -> Date

    init(settings: SettingsModel,
         fetcher: UpdateReleasesFetching = GitHubReleasesFetcher(),
         currentVersion: AppVersion? = nil,
         now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.fetcher = fetcher
        self.currentVersion = currentVersion
            ?? AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
            ?? AppVersion("0")!
        self.now = now
    }

    /// 启动/定时用的自动检查：开关关闭或仍在上次检查的 24h 内则直接跳过。
    func checkIfDue() async -> UpdateCheckOutcome {
        guard settings.autoCheckUpdates else { return .throttled }
        if let last = settings.lastUpdateCheckAt, now().timeIntervalSince(last) < Self.automaticInterval {
            return .throttled
        }
        return await performCheck()
    }

    /// 菜单里的手动检查：不受开关与节流限制。
    func checkNow() async -> UpdateCheckOutcome {
        await performCheck()
    }

    func skip(_ package: UpdatePackage) {
        settings.skippedUpdateVersion = package.version.description
    }

    private func performCheck() async -> UpdateCheckOutcome {
        let data: Data
        do {
            data = try await fetcher.fetchReleases()
        } catch let failure as UpdateCheckFailure {
            switch failure {
            case let .network(reason), let .decoding(reason):
                return .failed("检查更新失败：\(reason)")
            }
        } catch {
            return .failed("检查更新失败：\(error.localizedDescription)")
        }
        let releases: [GitHubRelease]
        do {
            releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        } catch {
            return .failed("更新信息无法解析：\(error.localizedDescription)")
        }
        settings.lastUpdateCheckAt = now()
        guard let package = UpdateChannelPolicy.latest(from: releases, current: currentVersion) else {
            return .upToDate(current: currentVersion.description)
        }
        if settings.skippedUpdateVersion == package.version.description {
            return .skipped(package)
        }
        return .available(package)
    }
}
