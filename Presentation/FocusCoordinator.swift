import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 展开、收回与恢复的有序执行器（方案 §10.2、§10.3）。
/// 顺序不变量：事务先落盘 → 写 AX → 读回 → 动画 → 汇报事件。
/// 三条硬规则：同一窗口的操作串行；每个 await 之后重查令牌；只有读回一致才宣称到位（方案 §6.3）。
@MainActor
final class FocusCoordinator {
    var onEvent: ((SessionEvent) -> Void)?
    var onStatus: ((String) -> Void)?

    /// 卡片画面矩形（CG 全局）由总览布局提供，代理不能自己猜起点。
    var cardRectProvider: ((WindowIdentity) -> CGRect?)?
    /// 动画起点用的画面纹理。
    var textureProvider: ((WindowIdentity) -> MetalFrame?)?
    /// 令牌是否仍然是状态机当前那一次过渡；过期写入只做补偿，不改状态。
    var isTokenCurrent: ((TransitionToken) -> Bool)?

    /// 程序写入与用户拖动不能靠一个瞬时布尔区分：写入结束后仍按读回值判定（方案 §6.5）。
    private static let attributionWindow: TimeInterval = 0.6

    private let catalog: WindowCatalog
    private let writer: GeometryWriting
    private let store: WindowJournalStore
    private let settings: SettingsModel
    private let metrics: Metrics
    private let recorder: CompatibilityRecorder
    private let metal: MetalContext
    private let recovery: RecoveryCoordinator
    private let permissions: PermissionChecking

    private var proxy: TransitionProxyWindow?
    private var activeToken: TransitionToken?
    private var activeIdentity: WindowIdentity?
    private var activeDirection: Direction = .expand
    private var watchdog: Timer?
    /// 每个窗口一条串行通道：展开、收回、恢复、补偿按入队顺序执行，互不重叠（方案 §6.3）。
    private var tails: [WindowIdentity: Task<Void, Never>] = [:]
    private var busy: Set<WindowIdentity> = []
    private var writing: Set<WindowIdentity> = []
    private var lastWritten: [WindowIdentity: (frame: CGRect, at: Date)] = [:]

    private enum Direction { case expand, collapse }

    init(catalog: WindowCatalog,
         metal: MetalContext,
         writer: GeometryWriting = AXWindowResolver(),
         store: WindowJournalStore,
         settings: SettingsModel,
         metrics: Metrics,
         recorder: CompatibilityRecorder,
         recovery: RecoveryCoordinator,
         permissions: PermissionChecking) {
        self.catalog = catalog
        self.metal = metal
        self.writer = writer
        self.store = store
        self.settings = settings
        self.metrics = metrics
        self.recorder = recorder
        self.recovery = recovery
        self.permissions = permissions
    }

    var isAnimating: Bool { activeToken != nil }

    /// 退出前必须等到所有窗口通道排空：不能并行走第二条恢复路径（方案 §6.6）。
    var isIdle: Bool { activeToken == nil && busy.isEmpty }

    // MARK: - 展开

    func expand(_ identity: WindowIdentity,
                targetFrame: CGRect,
                token: TransitionToken,
                animationMS: Int) {
        guard isTokenCurrent?(token) ?? true else { return }
        guard let record = catalog.record(for: identity) else {
            report(token: token, reason: "找不到目标窗口")
            return
        }
        guard let display = catalog.mapper.display(id: record.displayID) ?? catalog.mapper.primaryDisplay else {
            report(token: token, reason: "目标所在显示器已不可用")
            return
        }
        guard permissions.status.isComplete else {
            report(token: token, reason: "权限已收回，未写入窗口几何")
            return
        }
        // 总超时从这一次动作的入口开始算，而不是从动画开始算（方案 §6.3）。
        beginAnimation(token, identity: identity, budgetMS: animationMS + 1_500)
        metrics.begin("过渡:展开")
        Task { [weak self] in
            guard let self else { return }
            await self.onChannel(identity) {
                await self.performExpand(record: record,
                                         display: display,
                                         targetFrame: targetFrame,
                                         token: token,
                                         animationMS: animationMS)
            }
        }
    }

    private func performExpand(record: WindowRecord,
                               display: DisplayInfo,
                               targetFrame: CGRect,
                               token: TransitionToken,
                               animationMS: Int) async {
        let identity = record.identity
        guard isCurrent(token, identity) else { return }
        // 事务必须已经落盘：缺事务就写 AX，窗口会失去可恢复的原 frame（方案 §6.2）。
        guard store.entry(for: identity)?.state.requiresRestore == true else {
            report(token: token, reason: "几何事务未落盘，已拒绝写入")
            return
        }
        // 排队期间目录可能已经换了一代：以最新记录为准，但只写 reducer 给的那个 frame。
        let current = catalog.record(for: identity) ?? record
        let ax = catalog.axEntry(for: current)
        var applied = targetFrame
        if let ax, current.allowsGeometryControl {
            let started = Date()
            writing.insert(identity)
            let write = await writer.apply(frame: targetFrame, element: ax.element)
            writing.remove(identity)
            lastWritten[identity] = (write.displayFrame, Date())
            metrics.measure("几何写入", milliseconds: Date().timeIntervalSince(started) * 1000,
                            context: write.outcome.message)
            guard isCurrent(token, identity) else {
                // 令牌已过期：状态已经不属于这次过渡，但几何可能已被改掉，必须补偿回原 frame。
                if write.didChangeGeometry, let entry = store.entry(for: identity) {
                    recorder.note("过渡令牌已过期，正在补偿恢复：\(identity.journalKey)")
                    _ = await recovery.restore(entry: entry)
                }
                return
            }
            applied = write.displayFrame
            onEvent?(.geometryWriteFinished(GeometryWriteResult(identity: identity,
                                                                token: token,
                                                                operationID: UUID(),
                                                                targetFrame: targetFrame,
                                                                displayID: display.id,
                                                                outcome: write.outcome)))
            if case let .constrained(readBack) = write.outcome {
                recorder.updateRow(application: current.applicationName,
                                   version: "",
                                   resize: .failed,
                                   knownLimitation: "写入后读回 \(RecoveryCoordinator.text(readBack))，未回到目标尺寸")
                onStatus?("\(current.applicationName) 未完全接受目标尺寸")
            }
        } else {
            // 无法或未授权改尺寸：只做前景与 Raise，卡片继续可点，明确降级（方案 §10.1）。
            noteBlocked(current, current.allowsAutoFocus
                ? "AX 报告该窗口不可调整尺寸，或本代次句柄不可用"
                : "身份未唯一确定，禁止几何写入")
        }
        await bringToFront(record: current, element: ax?.element)
        guard isCurrent(token, identity) else { return }
        animate(identity: identity,
                token: token,
                from: cardRectProvider?(identity) ?? applied,
                to: applied,
                animationMS: animationMS,
                reverse: false)
    }

    // MARK: - 收回

    func collapse(_ identity: WindowIdentity, token: TransitionToken, animationMS: Int) {
        guard isTokenCurrent?(token) ?? true else { return }
        beginAnimation(token, identity: identity, budgetMS: animationMS + 200)
        metrics.begin("过渡:收回")
        Task { [weak self] in
            guard let self else { return }
            await self.onChannel(identity) {
                guard self.isCurrent(token, identity) else { return }
                // 同一通道已保证 .restoreGeometry 先跑完（方案 §10.3）：这里只读真实 frame 再反向动画。
                let from = await self.currentFrame(of: identity)
                guard self.isCurrent(token, identity) else { return }
                let card = self.cardRectProvider?(identity) ?? self.catalog.mapper.visibleFrame(for: from ?? .zero)
                self.animate(identity: identity,
                             token: token,
                             from: from ?? card,
                             to: card,
                             animationMS: animationMS,
                             reverse: true)
            }
        }
    }

    /// 恢复只写回事务里记录的原 frame；同一 token 的反向动画由通道排在它后面。
    func restoreGeometry(_ identity: WindowIdentity, token: TransitionToken) {
        Task { [weak self] in
            guard let self else { return }
            let item = await self.onChannel(identity) { await self.restoreOne(identity) }
            self.onEvent?(.geometryRestoreSettled(token: token, items: [item]))
        }
    }

    /// 退出、锁屏、Space 切换：逐条恢复并单独回报结果，最后统一收口（方案 §6.4）。
    func restoreAll(_ identities: [WindowIdentity], token: TransitionToken) {
        Task { [weak self] in
            guard let self else { return }
            for identity in identities {
                let item = await self.onChannel(identity) { await self.restoreOne(identity) }
                self.onEvent?(.geometryRestoreSettled(token: token, items: [item]))
            }
            self.stopAnimation()
            self.onEvent?(.restoreCompleted(token))
        }
    }

    private func restoreOne(_ identity: WindowIdentity) async -> RestoreItemResult {
        guard let entry = store.entry(for: identity) else {
            // 日志里没有：可能属于别的会话，也可能写盘失败。按事实回报，不谎报已恢复。
            return RestoreItemResult(identity: identity,
                                     outcome: .notAttempted("事务日志中没有该窗口的记录"),
                                     applicationName: catalog.record(for: identity)?.applicationName ?? "未知应用")
        }
        guard entry.state.requiresRestore else {
            return RestoreItemResult(identity: identity,
                                     outcome: .alreadyAtOriginal,
                                     applicationName: recovery.applicationName(for: entry))
        }
        return await recovery.restore(entry: entry)
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

    /// 通道字典按窗口累积，空闲时必须回收（方案 §14 内存）。
    func pruneIdleChannels() {
        for identity in Array(tails.keys) where !busy.contains(identity) {
            tails[identity] = nil
            lastWritten[identity] = nil
        }
    }

    /// AX 通知的几何变化归因：写入中 = 程序；写后短窗口内读回对得上 = 程序；对不上 = 不确定。
    func changeSource(for identity: WindowIdentity, observed frame: CGRect) -> GeometryChangeSource {
        if writing.contains(identity) { return .programmatic }
        guard let last = lastWritten[identity] else { return .user }
        guard Date().timeIntervalSince(last.at) < Self.attributionWindow else { return .user }
        return WindowTransaction.framesClose(frame, last.frame, tolerance: 2) ? .programmatic : .uncertain
    }

    // MARK: - 串行通道

    @discardableResult
    private func onChannel<V: Sendable>(_ identity: WindowIdentity,
                                        _ body: @escaping @MainActor () async -> V) async -> V {
        let previous = tails[identity]
        busy.insert(identity)
        return await withCheckedContinuation { (continuation: CheckedContinuation<V, Never>) in
            tails[identity] = Task { @MainActor in
                _ = await previous?.value
                let value = await body()
                continuation.resume(returning: value)
                busy.remove(identity)
            }
        }
    }

    /// 每个 await 之后重新确认：令牌仍是当前过渡，且权限仍在（方案 §6.3）。
    private func isCurrent(_ token: TransitionToken, _ identity: WindowIdentity) -> Bool {
        guard activeToken == token, isTokenCurrent?(token) ?? true else { return false }
        guard permissions.status.isComplete else { return false }
        return catalog.record(for: identity) != nil
    }

    // MARK: - 步骤实现

    private func currentFrame(of identity: WindowIdentity) async -> CGRect? {
        guard let record = catalog.record(for: identity) else { return nil }
        guard let element = catalog.axEntry(for: record)?.element else { return record.frame }
        return await writer.currentFrame(of: element) ?? record.frame
    }

    /// 前景化：公开激活 API + AX Raise + 设为 focused window，不使用私有层级调用。
    private func bringToFront(record: WindowRecord, element: AXUIElement?) async {
        let identity = record.identity
        if let element {
            _ = await writer.raise(element: element)
            _ = await writer.focus(element: element)
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

    private func noteBlocked(_ record: WindowRecord, _ reason: String) {
        recorder.updateRow(application: record.applicationName,
                           version: "",
                           resize: .blocked,
                           knownLimitation: reason)
        onStatus?("跳过尺寸调整：\(record.applicationName)（\(reason)）")
    }

    // MARK: - 代理动画

    private func beginAnimation(_ token: TransitionToken, identity: WindowIdentity, budgetMS: Int) {
        activeToken = token
        activeIdentity = identity
        scheduleWatchdog(token, budgetMS: budgetMS)
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
        let sourceFrame = textureProvider?(identity)
        view.setSource(sourceFrame, sourceAspect: sourceAspect(for: identity, frame: sourceFrame, cellRect: source))
        view.onComplete = { [weak self] in self?.finish(token) }
        // 打断续接：上一段动画仍在跑时必须从画面当前位置继续，而不是从旧起点重放。
        let startRect = view.isAnimating ? view.currentRectInCG : source
        // 减少动态效果时做真正的短淡化（固定在终点矩形），而不是把同一段缩放动画调快。
        let fadeOnly = settings.sessionPolicy().reduceMotion
        window.orderFrontRegardless()
        view.animate(fromCG: startRect,
                     toCG: destination,
                     durationMS: animationMS,
                     reverse: reverse,
                     mode: fadeOnly ? .fade : .scale,
                     startAlpha: fadeOnly ? (reverse ? 1 : 0) : 1,
                     endAlpha: fadeOnly ? (reverse ? 0 : 1) : 1)
    }

    /// 动画画面比例取有效捕获内容或真实源窗口，不能用"含标题条的格子比例"（方案 §4.3）。
    private func sourceAspect(for identity: WindowIdentity, frame: MetalFrame?, cellRect: CGRect) -> CGFloat {
        if let meta = frame?.meta {
            if meta.sourceSize.width > 1, meta.sourceSize.height > 1 {
                return max(0.2, meta.sourceSize.width / meta.sourceSize.height)
            }
            if meta.pixelWidth > 1, meta.pixelHeight > 1 {
                return max(0.2, CGFloat(meta.pixelWidth) / CGFloat(meta.pixelHeight))
            }
        }
        if let record = catalog.record(for: identity), record.frame.width > 1, record.frame.height > 1 {
            return max(0.2, record.frame.width / record.frame.height)
        }
        return max(0.2, cellRect.width / max(1, cellRect.height))
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
        watchdog?.invalidate()
        watchdog = nil
        proxy?.proxyView.stop()
        proxy?.orderOut(nil)
        activeToken = nil
        activeIdentity = nil
    }

    /// 有界总超时：AX 排队、动画回调丢失都不能让状态机无限期停在过渡态。
    private func scheduleWatchdog(_ token: TransitionToken, budgetMS: Int) {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(budgetMS) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimeout(token) }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func handleTimeout(_ token: TransitionToken) {
        guard activeToken == token else { return }
        let identity = activeIdentity
        stopAnimation()
        recorder.record("过渡超时",
                        subject: identity?.journalKey ?? "unknown",
                        result: .failed,
                        detail: "过渡在限定时间内未确认，已按状态机降级")
        onStatus?("过渡超时，已降级处理")
        // 超时不能把窗口留在中间尺寸：已经改过几何就补一次恢复（方案 §6.3）。
        if let identity, let entry = store.entry(for: identity), entry.state.requiresRestore {
            Task { [weak self] in
                guard let self else { return }
                let item = await self.onChannel(identity) { await self.recovery.restore(entry: entry) }
                self.onStatus?("超时补偿恢复：\(item.outcome.message)")
            }
        }
        onEvent?(.transitionTimedOut(token))
    }

    private func report(token: TransitionToken, reason: String) {
        onStatus?("展开被拒绝：\(reason)")
        recorder.record("展开前置条件", subject: reason, result: .blocked, detail: reason)
        // 前置条件失败发生在 beginAnimation 之前：不能停掉别人的动画，但必须让状态机离开过渡态。
        if activeToken == token { stopAnimation() }
        onEvent?(.transitionTimedOut(token))
    }
}
