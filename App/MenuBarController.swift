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
    private var updateInstallation: UpdateInstallationWindowController?
    private var isPresentingUpdateOffer = false
    private var onboarding: OnboardingWindowController?
    /// GitHub Releases 更新通道（方案 §21）：菜单"检查更新…"与启动后的一次静默检查共用。
    private(set) var updateChecker: UpdateChecker
    let checkUpdatesItem = NSMenuItem(title: "检查更新…", action: nil, keyEquivalent: "")

    private let statusLine = NSMenuItem(title: "准备中", action: nil, keyEquivalent: "")
    let openItem = NSMenuItem()
    let currentWindowItem = NSMenuItem()
    private var entryProcessID: pid_t?
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
        if installsStatusItem, let failure = UpdateInstaller.consumePendingFailure() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard self != nil else { return }
                let alert = NSAlert()
                alert.messageText = "上次更新未完成"
                alert.informativeText = failure
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
        // 只装在真实菜单栏时才自动检查：测试宿主/无图标模式不碰网络、也不弹窗。
        if performsAutomaticUpdateCheck && installsStatusItem {
            scheduleAutomaticUpdateCheck(delayed: true)
        }
    }

    private func build(into item: NSStatusItem?) {
        // 只允许缩小，不允许放大：菜单栏变矮时保持与系统图标同样的视觉大小，而不是撑满。
        item?.button?.imageScaling = .scaleProportionallyDown
        item?.button?.image = Self.menuBarIcon()
        item?.button?.toolTip = "Vistile 工作台与窗口总览"
        statusItem = item

        let menu = statusMenu
        menu.delegate = self
        menu.autoenablesItems = false

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        // Explicit overview and current-window Workbench entries stay independent of shortcut preferences.
        openItem.title = "打开窗口总览"
        openItem.target = self
        openItem.action = #selector(openOverview)
        menu.addItem(openItem)

        currentWindowItem.title = "以当前窗口开启工作台"
        currentWindowItem.target = self
        currentWindowItem.action = #selector(openCurrentWindowWorkbench)
        menu.addItem(currentWindowItem)

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
        entryProcessID = coordinator.frontmostProcessID()
        openItem.isEnabled = !visible
        currentWindowItem.isEnabled = coordinator.state.phase == .hidden && !coordinator.isOpeningCurrentWindowWorkbench
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
        if let updateInstallation, updateInstallation.isRunning {
            updateInstallation.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
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
        guard updateInstallation?.isRunning != true, !isPresentingUpdateOffer else { return }
        isPresentingUpdateOffer = true
        defer { isPresentingUpdateOffer = false }
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(package.version)"
        alert.informativeText = package.asset == nil
            ? "可前往 GitHub 查看此版本。"
            : "下载完成后会自动安装并重新启动，工作台中的窗口会先恢复原位。"
        let notes = Self.updateNotes(for: package)
        if !notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 210))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.font = .systemFont(ofSize: 13)
            text.textColor = .labelColor
            text.textContainerInset = NSSize(width: 0, height: 6)
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.autoresizingMask = .width
            text.textContainer?.widthTracksTextView = true
            text.string = notes
            scroll.documentView = text
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: package.asset == nil ? "打开发布页" : "下载并安装")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch index {
        case 0:
            if package.asset != nil {
                if updateInstallation == nil { updateInstallation = UpdateInstallationWindowController() }
                updateInstallation?.install(package)
            } else {
                NSWorkspace.shared.open(package.downloadURL)
            }
        case alert.buttons.count - 1:
            updateChecker.skip(package)
        default:
            break
        }
    }

    static func updateNotes(for package: UpdatePackage) -> String {
        var lines: [String] = []
        if let asset = package.asset {
            lines.append("安装包：\(ByteCountFormatter.string(fromByteCount: Int64(asset.size), countStyle: .file))")
        }
        if let body = package.release.body {
            var sawVersionHeading = false
            for rawLine in body.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                // Release assets and manual installation instructions belong on the release page.
                if line.hasPrefix("## 下载") || line.lowercased().hasPrefix("## download") { break }
                if line == "# Vistile" { continue }
                if line.hasPrefix("## v") {
                    if sawVersionHeading { break }
                    sawVersionHeading = true
                    continue
                }
                var plain = line.replacingOccurrences(of: "`", with: "")
                    .replacingOccurrences(of: "**", with: "")
                while plain.hasPrefix("#") { plain.removeFirst() }
                plain = plain.trimmingCharacters(in: .whitespaces)
                if plain.hasPrefix("- ") { plain = "• " + String(plain.dropFirst(2)) }
                lines.append(plain)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只在隐藏态可用：每次打开都先落在全屏总览，工作台只能由点击卡片进入（方案 §4.1、§16）。
    @objc func openOverview() { coordinator.toggleOverview() }
    @objc func openCurrentWindowWorkbench() { coordinator.openCurrentWindowWorkbench(processID: entryProcessID) }
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

    /// 图标以窗口外框、顶栏和左侧栏表达工作台，保持单色 template 造型。
    static func menuBarIcon(canvas: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: canvas, height: canvas))
        image.lockFocus()
        NSColor.black.setStroke()

        let window = CGRect(x: (canvas - 14.5) / 2,
                            y: (canvas - 12.5) / 2,
                            width: 14.5,
                            height: 12.5)
        let outline = NSBezierPath(roundedRect: window, xRadius: 2.5, yRadius: 2.5)
        outline.lineWidth = 1.5
        outline.stroke()

        // 顶栏一条分隔线，下面只保留短左侧栏线，让右下主窗口保持完整留白。
        let headerY = window.maxY - 3
        let header = NSBezierPath()
        header.lineWidth = 1.5
        header.move(to: CGPoint(x: window.minX + 1.25, y: headerY))
        header.line(to: CGPoint(x: window.maxX - 1.25, y: headerY))
        header.stroke()

        let sidebar = NSBezierPath()
        sidebar.lineWidth = 1.5
        sidebar.move(to: CGPoint(x: window.minX + 4, y: window.minY + 1.5))
        sidebar.line(to: CGPoint(x: window.minX + 4, y: headerY))
        sidebar.stroke()

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
        let current = now()
        // 未来时间戳（系统时间回拨或盘上坏值）不能永久压住自动检查。
        if let last = settings.lastUpdateCheckAt, last <= current,
           current.timeIntervalSince(last) < Self.automaticInterval {
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
