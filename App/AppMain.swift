import AppKit

@main
enum AppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // 菜单栏常驻应用：不抢 Dock 图标，总览由快捷键/菜单进入。
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsModel()
    private let permissions = PermissionManager()
    private let metrics = Metrics.shared
    private let recorder = CompatibilityRecorder()

    private var coordinator: AppCoordinator?
    private var menuBar: MenuBarController?
    private var probe: P0Probe?
    private var startup: Task<Void, Never>?
    private var hasBegunTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        metrics.begin("启动")
        // 任一环节失败都不启动：本方案禁止用静态截图冒充实时预览，也不允许带着坏管线继续跑。
        guard let metal = MetalContext.make() else {
            recorder.record("启动", subject: "Metal 设备", result: .blocked, detail: "系统未提供可用 Metal 设备或纹理缓存")
            _ = recorder.flush()
            presentBlocker("Vistile 无法启动",
                           "本机没有可用的 Metal 渲染设备。总览卡片必须由 GPU 合成实时画面，"
                               + "本方案禁止用静态截图冒充实时预览。")
            return
        }
        guard let renderer = OverviewRenderer(metal: metal) else {
            recorder.record("启动", subject: "绘制管线", result: .blocked, detail: "卡片着色器编译或管线创建失败")
            _ = recorder.flush()
            presentBlocker("Vistile 无法启动",
                           "卡片着色器在本机编译失败，或渲染管线创建失败。"
                               + "诊断已写入桌面「Vistile Diagnostics」，请连同本机系统版本一起反馈。")
            return
        }
        let coordinator = AppCoordinator(settings: settings,
                                         permissions: permissions,
                                         metrics: metrics,
                                         recorder: recorder,
                                         metal: metal,
                                         renderer: renderer)
        self.coordinator = coordinator

        // 崩溃恢复先于新会话：两条路径不能同时写窗口几何（方案 §10.5）。
        startup = Task { @MainActor [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            let restored = await coordinator.recovery.restoreOnLaunch(recorder: self.recorder)
            if !restored.isEmpty {
                VistileLog.session.log(level: .info, "启动恢复处理了 \(restored.count, format: .decimal) 条事务")
            }
            coordinator.start()
            self.menuBar = MenuBarController(coordinator: coordinator,
                                             settings: self.settings,
                                             permissions: self.permissions)
            coordinator.onStatus = { [weak self] text in self?.menuBar?.setStatus(text) }

            if ProcessInfo.processInfo.environment["VISTILE_P0_MODE"] == "1" {
                let probe = P0Probe(coordinator: coordinator, recorder: self.recorder, settings: self.settings)
                self.probe = probe
                // 探针跑完就走正常退出路径：验收清单已落盘，事务恢复与诊断导出同样不能跳过。
                probe.onFinished = { NSApp.terminate(nil) }
                probe.begin()
            } else if !self.permissions.status.isComplete || !self.settings.didCompleteGuidedSetup {
                self.menuBar?.showOnboarding()
            }
            self.metrics.end("启动")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // 从系统设置返回后重新检查授权，不持续弹窗。
        coordinator?.permissionsMayHaveChanged()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 退出路径：先恢复本次临时修改的几何，再让系统真正终止。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator, !hasBegunTermination else { return .terminateNow }
        hasBegunTermination = true
        coordinator.prepareForTermination()
        return .terminateNow
    }

    private func presentBlocker(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        _ = alert.runModal()
        NSApp.terminate(nil)
    }
}
