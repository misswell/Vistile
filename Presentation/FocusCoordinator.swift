import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 展开、收回与恢复的有序执行器（方案 §10.2、§10.3）。
/// 顺序不变量：事务先落盘 → 写 AX → 读回 → 动画 → 汇报事件。
/// 任何一步失败都必须回报事实，不能把"函数返回"当成"窗口到位"。
@MainActor
final class FocusCoordinator {
    var onEvent: ((SessionEvent) -> Void)?
    var onStatus: ((String) -> Void)?

    /// 卡片画面矩形（CG 全局）由总览布局提供，代理不能自己猜起点。
    var cardRectProvider: ((WindowIdentity) -> CGRect?)?
    /// 动画起点用的画面纹理。
    var textureProvider: ((WindowIdentity) -> MetalFrame?)?

    private let catalog: WindowCatalog
    private let resolver: AXWindowResolver
    private let store: WindowJournalStore
    private let settings: SettingsModel
    private let metrics: Metrics
    private let recorder: CompatibilityRecorder
    private let metal: MetalContext

    private var proxy: TransitionProxyWindow?
    private var activeToken: TransitionToken?
    private var activeIdentity: WindowIdentity?
    private var activeDirection: Direction = .expand
    private var timeoutTimer: Timer?
    private var pendingRestore: [WindowIdentity: Task<Void, Never>] = [:]
    /// 程序写入几何期间，AX 的 moved/resized 通知不能当成用户手动调整（方案 §10.4）。
    private(set) var isWritingGeometry: Set<WindowIdentity> = []

    private enum Direction { case expand, collapse }

    init(catalog: WindowCatalog,
         metal: MetalContext,
         resolver: AXWindowResolver = AXWindowResolver(),
         store: WindowJournalStore,
         settings: SettingsModel,
         metrics: Metrics,
         recorder: CompatibilityRecorder) {
        self.catalog = catalog
        self.metal = metal
        self.resolver = resolver
        self.store = store
        self.settings = settings
        self.metrics = metrics
        self.recorder = recorder
    }

    var isAnimating: Bool { activeToken != nil }

    // MARK: - 展开

    func expand(_ identity: WindowIdentity, token: TransitionToken, animationMS: Int) {
        guard let record = catalog.record(for: identity) else {
            report(token: token, reason: "找不到目标窗口")
            return
        }
        guard let display = catalog.mapper.display(id: record.displayID) ?? catalog.mapper.primaryDisplay else {
            report(token: token, reason: "目标所在显示器已不可用")
            return
        }
        beginAnimation(token, identity: identity)
        metrics.begin("过渡:展开")
        let policy = settings.sessionPolicy()
        // 事务必须在任何 AX 写入之前落盘；reducer 已按顺序发出 effect，这里再确认一次。
        ensureJournaled(record)

        Task { [weak self] in
            guard let self else { return }
            let ax = self.catalog.axEntry(for: record)
            let target = FocusGeometry.targetRect(visibleFrame: display.visibleFrame,
                                                  policy: policy,
                                                  currentSize: record.frame.size,
                                                  isResizable: record.allowsGeometryControl)
            var applied = target
            if let ax, record.allowsGeometryControl {
                let verification = await self.write(frame: target, element: ax.element, identity: identity)
                applied = verification.readBack ?? target
                self.onEvent?(.geometryWritten(identity, provisionalFrame: verification.requested, displayID: display.id))
                if let readBack = verification.readBack {
                    self.onEvent?(.geometryVerified(identity, readBack: readBack))
                }
                if verification.isPartial {
                    self.noteDeviation(record, verification)
                }
            } else {
                // 无法或未授权改尺寸：只做前景与 Raise，卡片继续可点，明确降级。
                self.recorder.updateRow(application: record.applicationName,
                                        version: "",
                                        resize: .blocked,
                                        knownLimitation: record.allowsAutoFocus
                                            ? "AX 报告该窗口不可调整尺寸"
                                            : "身份未唯一确定，禁止几何写入")
                self.onStatus?("跳过尺寸调整：\(record.applicationName) 不允许几何写入")
            }
            await self.bringToFront(record: record, element: ax?.element)
            guard self.activeToken == token else { return }
            self.animate(identity: identity,
                         token: token,
                         from: self.cardRectProvider?(identity) ?? applied,
                         to: applied,
                         animationMS: animationMS,
                         reverse: false)
        }
    }

    // MARK: - 收回

    func collapse(_ identity: WindowIdentity, token: TransitionToken, animationMS: Int) {
        beginAnimation(token, identity: identity)
        metrics.begin("过渡:收回")
        Task { [weak self] in
            guard let self else { return }
            // 读回当前真实 frame 走 AX 队列，主线程不等跨进程调用。
            let from = await self.currentFrame(of: identity)
            // 先恢复原 frame，再播放反向动画（方案 §10.3）。
            await self.pendingRestore[identity]?.value
            self.pendingRestore.removeValue(forKey: identity)
            guard self.activeToken == token else { return }
            let card = self.cardRectProvider?(identity)
                ?? self.catalog.mapper.visibleFrame(for: from ?? .zero)
            self.animate(identity: identity,
                         token: token,
                         from: from ?? card,
                         to: card,
                         animationMS: animationMS,
                         reverse: true)
        }
    }

    /// 恢复只写回事务里记录的原 frame；同一 token 的动画由 collapse 驱动。
    func restoreGeometry(_ identity: WindowIdentity, token: TransitionToken) {
        guard pendingRestore[identity] == nil else { return }
        pendingRestore[identity] = Task { [weak self] in
            guard let self else { return }
            await self.performRestore(identity, token: token)
        }
    }

    /// 退出、锁屏、Space 切换：恢复所有仍未结束的事务后再隐藏总览。
    func restoreAll(_ identities: [WindowIdentity], token: TransitionToken) {
        for identity in identities { restoreGeometry(identity, token: token) }
        let jobs = Array(pendingRestore.values)
        pendingRestore.removeAll()
        Task { [weak self] in
            guard let self else { return }
            for job in jobs { _ = await job.value }
            // 退出路径不留浮层：任何仍在跑的代理立即结束。
            self.stopAnimation()
            self.onEvent?(.restoreCompleted(token))
        }
    }

    func raiseOnly(_ identity: WindowIdentity) {
        guard let record = catalog.record(for: identity) else { return }
        let element = catalog.axEntry(for: record)?.element
        Task { await self.bringToFront(record: record, element: element) }
    }

    /// 外部中断（挂起、退出）时立刻结束代理，避免残留浮层。
    func cancelAnimation() {
        stopAnimation()
    }

    // MARK: - 步骤实现

    private func performRestore(_ identity: WindowIdentity, token: TransitionToken) async {
        guard let entry = store.entry(for: identity), entry.state.requiresRestore else {
            onEvent?(.geometryRestored(identity))
            return
        }
        guard let record = catalog.record(for: identity), let ax = catalog.axEntry(for: record) else {
            // 窗口或句柄已消失：没有可恢复的 frame，清掉事务并记录，不谎报成功。
            store.drop(identity)
            onEvent?(.restoreFailed(token, identity, "窗口已不存在，无法恢复"))
            onStatus?("恢复跳过：窗口已不存在")
            return
        }
        let target = entry.restoreTargetFrame(preserveUserGeometry: settings.preserveUserGeometry)
        let verification = await write(frame: target, element: ax.element, identity: identity)
        if verification.isExact || verification.isPartial {
            onEvent?(.geometryRestored(identity))
            store.markRestored(identity)
            store.drop(identity)
            recorder.updateRow(application: record.applicationName, version: "", restore: verification.isExact ? .passed : .failed,
                               knownLimitation: verification.isExact ? nil : "恢复读回偏差 \(String(format: "%.1f", verification.deviation))pt")
        } else {
            onEvent?(.restoreFailed(token, identity, "恢复读回与目标不一致"))
            recorder.updateRow(application: record.applicationName, version: "", restore: .failed,
                               knownLimitation: "AX 写入后读回不一致")
        }
    }

    /// AX 几何写入：标记为程序引起，读回后回报偏差。
    private func write(frame target: CGRect, element: AXUIElement, identity: WindowIdentity) async -> GeometryVerification {
        isWritingGeometry.insert(identity)
        defer { isWritingGeometry.remove(identity) }
        let started = Date()
        let verification = await resolver.apply(frame: target, element: element)
        metrics.measure("几何写入", milliseconds: Date().timeIntervalSince(started) * 1000,
                        context: "读回偏差 \(String(format: "%.1f", verification.deviation))pt")
        return verification
    }

    /// 前景化：公开激活 API + AX Raise + 设为 focused window，不使用私有层级调用。
    private func bringToFront(record: WindowRecord, element: AXUIElement?) async {
        let identity = record.identity
        if let element {
            _ = await resolver.raise(element: element)
            _ = await resolver.focus(element: element)
        }
        guard let application = NSRunningApplication(processIdentifier: identity.processID) else {
            onStatus?("激活失败：进程已退出")
            return
        }
        // 目标应用激活是"原生前台输入"的前提；失败时只记录，不伪装成功。
        // macOS 14 起 .activateIgnoringOtherApps 已失效，只能接受系统的前台限制策略。
        let activated = application.activate(options: [])
        recorder.updateRow(application: record.applicationName,
                           version: "",
                           ordering: activated ? .unverified : .failed,
                           knownLimitation: activated ? nil : "NSRunningApplication.activate 返回 false")
        if !activated { onStatus?("激活 \(record.applicationName) 失败") }
    }

    private func currentFrame(of identity: WindowIdentity) async -> CGRect? {
        guard let record = catalog.record(for: identity) else { return nil }
        guard let element = catalog.axEntry(for: record)?.element else { return record.frame }
        return await resolver.currentFrame(of: element) ?? record.frame
    }

    private func ensureJournaled(_ record: WindowRecord) {
        guard store.entry(for: record.identity) == nil else { return }
        let transaction = WindowTransaction(sessionID: store.currentSessionID,
                                            identity: record.identity,
                                            bundleID: record.bundleID,
                                            originalFrame: record.frame,
                                            originalDisplayID: record.displayID)
        store.apply(transaction)
        onStatus?("事务缺失，已补记原 frame")
    }

    private func noteDeviation(_ record: WindowRecord, _ verification: GeometryVerification) {
        recorder.updateRow(application: record.applicationName,
                           version: "",
                           resize: .failed,
                           knownLimitation: "写入后读回偏差 \(String(format: "%.1f", verification.deviation))pt（应用自身尺寸约束）")
        onStatus?("\(record.applicationName) 未完全接受目标尺寸")
    }

    // MARK: - 代理动画

    private func beginAnimation(_ token: TransitionToken, identity: WindowIdentity) {
        activeToken = token
        activeIdentity = identity
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    private func animate(identity: WindowIdentity,
                         token: TransitionToken,
                         from source: CGRect,
                         to destination: CGRect,
                         animationMS: Int,
                         reverse: Bool) {
        activeDirection = reverse ? .collapse : .expand
        guard source.width > 1, source.height > 1, destination.width > 1, destination.height > 1 else {
            finish(token)
            return
        }
        let display = catalog.record(for: identity).flatMap { catalog.mapper.display(id: $0.displayID) }
            ?? catalog.mapper.primaryDisplay
        guard let display, let window = ensureProxy(on: display) else {
            finish(token)
            return
        }
        let view = window.proxyView
        view.configure(cgOrigin: display.frame.origin, scale: display.backingScale)
        view.setSource(textureProvider?(identity), sourceAspect: max(0.2, source.width / max(1, source.height)))
        view.onComplete = { [weak self] in self?.finish(token) }
        window.orderFrontRegardless()
        view.animate(fromCG: source, toCG: destination, durationMS: animationMS, reverse: reverse)
        scheduleTimeout(token, animationMS: animationMS)
    }

    private func ensureProxy(on display: DisplayInfo) -> TransitionProxyWindow? {
        let appKitFrame = catalog.mapper.cgToAppKit(display.frame)
        if let proxy {
            // 跨屏动画时移动承载窗口，避免把另一层屏幕的画面混进来。
            if proxy.frame != appKitFrame { proxy.setFrame(appKitFrame, display: false) }
            return proxy
        }
        let created = TransitionProxyWindow(screenFrame: appKitFrame, metal: metal)
        proxy = created
        return created
    }

    private func finish(_ token: TransitionToken) {
        guard activeToken == token else { return }
        let direction = activeDirection
        stopAnimation()
        switch direction {
        case .expand:
            metrics.end("过渡:展开")
            onEvent?(.expandCompleted(token))
        case .collapse:
            metrics.end("过渡:收回")
            onEvent?(.collapseCompleted(token))
        }
    }

    private func stopAnimation() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        proxy?.proxyView.stop()
        proxy?.orderOut(nil)
        activeToken = nil
        activeIdentity = nil
    }

    private func scheduleTimeout(_ token: TransitionToken, animationMS: Int) {
        timeoutTimer?.invalidate()
        // 上限 = 动画 + AX 超时余量；超时后由状态机降级，不能无限期停在过渡态。
        let limit = TimeInterval(animationMS) / 1000 + 1.2
        let timer = Timer(timeInterval: limit, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimeout(token) }
        }
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer
    }

    private func handleTimeout(_ token: TransitionToken) {
        guard activeToken == token else { return }
        stopAnimation()
        recorder.record("过渡超时",
                        subject: activeIdentity?.journalKey ?? "unknown",
                        result: .failed,
                        detail: "过渡在限定时间内未确认，已按状态机降级")
        onStatus?("过渡超时，已降级处理")
        onEvent?(.transitionTimedOut(token))
    }

    private func report(token: TransitionToken, reason: String) {
        onStatus?("展开被拒绝：\(reason)")
        recorder.record("展开前置条件", subject: reason, result: .blocked, detail: reason)
        onEvent?(.transitionTimedOut(token))
    }
}
