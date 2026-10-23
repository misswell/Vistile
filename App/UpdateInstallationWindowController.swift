import AppKit
import VistileCore

/// The update stays cancellable until the verified replacement helper takes ownership.
@MainActor
final class UpdateInstallationWindowController: NSWindowController, NSWindowDelegate {
    private let installer = UpdateInstaller()
    private var installationTask: Task<Void, Never>?
    private let status = NSTextField(wrappingLabelWithString: "正在准备下载…")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var isHandingOff = false
    var isRunning: Bool { installationTask != nil || isHandingOff }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "更新 Vistile"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = NSTextField(labelWithString: "正在更新 Vistile")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        cancelButton.target = self
        cancelButton.action = #selector(cancelInstallation)
        cancelButton.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [heading, status, progress, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(_ package: UpdatePackage) {
        if isRunning { showWindow(nil); window?.makeKeyAndOrderFront(nil); return }
        isHandingOff = false
        cancelButton.isEnabled = true
        status.stringValue = "正在下载 Vistile \(package.version)…"
        progress.isIndeterminate = true
        progress.startAnimation(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.installationTask = nil }
            do {
                let prepared = try await self.installer.install(package: package) { [weak self] update in
                    guard let self, self.cancelButton.isEnabled else { return }
                    self.display(update)
                }
                try Task.checkCancellation()
                self.isHandingOff = true
                self.cancelButton.isEnabled = false
                self.status.stringValue = "更新已就绪，正在恢复窗口并重新启动…"
                try prepared.launchAndRelaunch()
                NSApp.terminate(nil)
            } catch is CancellationError {
                self.close()
            } catch {
                if Task.isCancelled { self.close(); return }
                self.isHandingOff = false
                self.cancelButton.isEnabled = true
                self.progress.stopAnimation(nil)
                self.status.stringValue = "更新未完成，当前版本已保留。"
                let alert = NSAlert()
                alert.messageText = "无法安装更新"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.addButton(withTitle: "手动下载")
                if let window = self.window {
                    alert.beginSheetModal(for: window) { response in
                        if response == .alertSecondButtonReturn {
                            NSWorkspace.shared.open(package.downloadURL)
                        }
                    }
                }
            }
        }
    }

    private func display(_ update: UpdateInstallProgress) {
        status.stringValue = update.message
        progress.isIndeterminate = update.fraction == nil
        if let fraction = update.fraction {
            progress.stopAnimation(nil)
            progress.doubleValue = min(1, max(0, fraction))
        } else {
            progress.startAnimation(nil)
        }
    }

    @objc private func cancelInstallation() {
        guard !isHandingOff else { return }
        installationTask?.cancel()
        status.stringValue = "正在取消…"
        cancelButton.isEnabled = false
        if installationTask == nil { close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isHandingOff else { return false }
        if isRunning { cancelInstallation(); return false }
        return true
    }
}
