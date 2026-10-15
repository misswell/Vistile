import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 应用侧唯一的事件入口与 effect 执行者（方案 §7）。
/// 视图、捕获回调、AX 回调都不自己判断"现在算什么状态"：一律转成事件交给同一份 reducer，
/// 再由这里按顺序执行 reducer 给出的效果。
@MainActor
final class AppCoordinator {
    // MARK: - 依赖

    let settings: SettingsModel
    let permissions: PermissionManager
    let metrics: Metrics
    let recorder: CompatibilityRecorder
    let journal: WindowJournalStore
    let catalog: WindowCatalog
    let capture: CaptureCoordinator
    let focus: FocusCoordinator
    let recovery: RecoveryCoordinator
    let observerHub = AXObserverHub()
    let hotKey = GlobalHotKey()

    private let resolver = AXWindowResolver()
    private let renderer: OverviewRenderer

    // MARK: - 状态

    private(set) var state = SessionState()
    private(set) var controllers: [UInt32: OverviewWindowController] = [:]
    private(set) var layouts: [UInt32: GridLayout] = [:]
    private(set) var cardRects: [WindowIdentity: CGRect] = [:]
    var onStatus: ((String) -> Void)?

    /// 供 P0 记录的事实计数（方案 §4：不能仅凭"返回无错误"通过）。
    private(set) var backgroundClickCount = 0
    private(set) var cardClickCount = 0

    private var eventQueue: [SessionEvent] = []
    private var isDraining = false
    private var isSyncing = false
    private var needsSync = false
    private var reconcileTimer: Timer?
    private var redrawTimer: Timer?
    private var hintTimer: Timer?
    private var pendingHint: String?
    private var structuralRefreshWork: DispatchWorkItem?
    private var hasWarnedTinyThumbnails = false
    private var quitRestoreSettled = true
    private var observers: [NSObjectProtocol] = []

    /// 渲染设备与着色器由调用方先建好：启动被阻塞时要分得清是"没有 Metal 设备"还是"着色器没编译过"。
    init(settings: SettingsModel,
         permissions: PermissionManager,
         metrics: Metrics,
         recorder: CompatibilityRecorder,
         metal: MetalContext,
         renderer: OverviewRenderer) {
        let journal = WindowJournalStore()
        let resolver = AXWindowResolver()
        let catalog = WindowCatalog(permissions: permissions, resolver: resolver)

        self.settings = settings
        self.permissions = permissions
        self.metrics = metrics
        self.recorder = recorder
        self.renderer = renderer
        self.journal = journal
        self.catalog = catalog
        self.capture = CaptureCoordinator(metal: metal, catalog: catalog)
        self.focus = FocusCoordinator(catalog: catalog,
                                      metal: metal,
                                      resolver: resolver,
                                      store: journal,
                                      settings: settings,
                                      metrics: metrics,
                                      recorder: recorder)
        self.recovery = RecoveryCoordinator(store: journal,
                                            resolver: resolver,
                                            catalog: catalog,
                                            settings: settings)
    }

    // MARK: - 启动

    func start() {
        catalog.isExcludedBundle = { [weak self] bundleID in self?.settings.isExcluded(bundleID) ?? false }
        catalog.onRecords = { [weak self] records, generation, reason in
            self?.dispatch(.catalogUpdated(records: records, generation: generation, reason: reason))
        }
        catalog.onStatus = { [weak self] text in self?.log("discover", text) }

        capture.onFact = { [weak self] fact in self?.handle(fact) }
        focus.onEvent = { [weak self] event in self?.dispatch(event) }
        focus.onStatus = { [weak self] text in self?.log("focus", text) }
        focus.cardRectProvider = { [weak self] identity in self?.cardRects[identity] }
        focus.textureProvider = { [weak self] identity in self?.renderer.texture(for: identity) }

        observerHub.onWindowEvent = { [weak self] event in self?.handle(event) }
        observerHub.onSupportChanged = { [weak self] pid, supported in
            guard let self, !supported else { return }
            // 不支持 AX 的进程只保留预览，受控聚焦明确禁用。
            self.log("ax", "pid \(pid) 不支持辅助功能，改用低频补偿查询")
        }
        observerHub.onCoalescedEvents = { [weak self] count in
            self?.metrics.increment("ax.events", by: count)
        }

        metrics.onSample = { [weak self] sample in self?.recorder.recordPerformance(sample) }
        hotKey.onFire = { [weak self] in self?.toggleOverview() }

        registerSystemObservers()
        dispatch(.policyChanged(settings.sessionPolicy()))
        dispatch(.settingsChanged(density: settings.density))

        if hotKey.register(settings.hotKey) {
            recorder.record("全局快捷键", subject: settings.hotKey.displayString, result: .unverified,
                            detail: "已注册；实机触发需录屏验证")
        } else {
            recorder.record("全局快捷键", subject: settings.hotKey.displayString, result: .failed,
                            detail: "RegisterEventHotKey 未成功，请从菜单栏进入或在设置里更换组合键")
        }
        recorder.record("Metal 渲染", subject: "总览画面合成", result: .unverified,
                        detail: "设备与纹理缓存已建立；帧率、内存与 WindowServer 增量待实测")
        log("app", "协调层就绪：层级策略 \(settings.orderingStrategy.displayName)，密度 \(settings.density.rawValue)")
    }

    // MARK: - 对外动作

    /// 快捷键与菜单共用：hidden 打开、focused 回总览、overview 退出（方案 §11）。
    func toggleOverview() {
        if state.phase == .hidden { prepareSlotMemory() }
        dispatch(.globalShortcut)
    }

    func returnToOverview() { dispatch(.returnShortcut) }

    func closeOverview() { dispatch(.escapePressed) }

    func organizeNow() { dispatch(.organizeRequested) }

    func refreshNow() { catalog.refresh(reason: .shortcut) }

    func permissionsMayHaveChanged() {
        let before = permissions.status
        let after = permissions.refresh()
        guard after != before else { return }
        handlePermissionChange(after)
    }

    /// 初次进入按跨会话记忆的顺序；容量随后按目录数量确定，不预设上限。
    private func prepareSlotMemory() {
        state.slots = SlotRegistry(capacity: 0, orderPreference: settings.slotOrderPreference)
        hasWarnedTinyThumbnails = false
    }

    private func handlePermissionChange(_ status: PermissionStatus) {
        if !status.screenRecording {
            dispatch(.permissionLost(.screenRecording))
        } else if !status.accessibility {
            dispatch(.permissionLost(.accessibility))
        } else if state.phase.isVisible {
            catalog.refresh(reason: .permissionRestored)
        }
    }

    // MARK: - 事件管线

    /// 事件排队处理：effect 内再次派发的同类事件排到后面，避免递归展开。
    func dispatch(_ event: SessionEvent) {
        eventQueue.append(event)
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        var processed = 0
        while let next = eventQueue.first {
            eventQueue.removeFirst()
            processed += 1
            if processed > 512 {
                eventQueue.removeAll()
                log("app", "事件队列超过 512 条，已丢弃剩余事件以保护主线程")
                break
            }
            handleEvent(next)
        }
        syncIfRequired()
    }

    private func syncIfRequired() {
        guard needsSync else { return }
        needsSync = false
        performSync()
        // performSync 内部可能再触发事件（例如缩略图过小提示），再收敛一次就停，避免成环。
        if needsSync {
            needsSync = false
            performSync()
        }
    }

    private func handleEvent(_ event: SessionEvent) {
        if case let .catalogUpdated(records, _, _) = event {
            // 方案 §2.6：所有符合条件窗口都要有格子。容量随目录增长，绝不静默只留"最近 N 个"。
            state.slots.capacity = max(state.slots.capacity, records.count)
        }
        metrics.increment("event")
        let effects = SessionReducer.reduce(&state, event)
        for effect in effects { run(effect) }
        needsSync = true
    }

    private func run(_ effect: SessionEffect) {
        switch effect {
        case let .discover(_, reason):
            catalog.refresh(reason: reason)

        case let .startCapture(identities, generation):
            // 真正的启动交给统一的目标集同步；这里只登记状态，避免部分目标误停其它流。
            for identity in identities { dispatch(.captureStarted(identity, generation: generation)) }

        case .stopCapture:
            needsSync = true

        case .stopAllCapture:
            let hidden = !state.phase.isVisible
            capture.stopAll(releasingMailboxes: hidden)
            if hidden { renderer.releaseAll() }

        case let .showOverview(displayID):
            showOverview(preferredDisplay: displayID)

        case .hideOverview:
            hideOverview()

        case let .writeJournal(transaction):
            journal.apply(transaction)

        case let .clearJournal(sessionID):
            journal.clear(sessionID: sessionID)

        case let .dropJournal(identity):
            journal.drop(identity)

        case let .expand(identity, token, animationMS):
            focus.expand(identity, token: token, animationMS: animationMS)

        case let .collapse(identity, token, animationMS):
            focus.collapse(identity, token: token, animationMS: animationMS)

        case let .restoreGeometry(identity, token):
            focus.restoreGeometry(identity, token: token)

        case let .restoreAll(token):
            let identities = state.transactions.filter { $0.value.state.requiresRestore }.map(\.key)
            focus.restoreAll(identities, token: token)

        case let .raiseTarget(identity):
            focus.raiseOnly(identity)

        case let .setKeyboardFocus(focus):
            applyKeyboardFocus(focus)

        case let .scheduleReconcile(interval):
            scheduleReconcile(interval)

        case .cancelReconcile:
            reconcileTimer?.invalidate()
            reconcileTimer = nil

        case let .presentHint(hint):
            present(hint)

        case .none:
            break
        }
    }

    // MARK: - 展示同步

    private func performSync() {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        rebuildLayouts()
        guard state.phase.isVisible else { return }

        capture.sync(targets: captureTargets(), tier: state.policy.tier, isAnimating: focus.isAnimating)
        applyOrdering()
        updateObservers()

        let total = state.records.count
        for (displayID, controller) in controllers {
            guard let layout = layouts[displayID] else { continue }
            let records = records(on: displayID)
            controller.updateLayout(layout,
                                    records: records,
                                    renderer: renderer,
                                    mailboxProvider: { [weak self] identity in self?.capture.mailbox(for: identity) },
                                    style: state.style,
                                    showsTitles: settings.showsTitles)
            controller.setToolbar(total: total,
                                  shown: records.values.filter { matchesSearch($0) }.count,
                                  query: state.searchQuery,
                                  hint: pendingHint)
        }
    }

    /// 每屏一份布局；全局 slot 编号不因分屏而改变含义（方案 §8、§12）。
    private func rebuildLayouts() {
        layouts.removeAll()
        cardRects.removeAll()
        for display in catalog.mapper.displays {
            let sources = state.recordsInSlotOrder.compactMap { record -> GridSource? in
                guard record.displayID == display.id, let slot = record.slot else { return nil }
                return GridSource(slot: slot, size: record.frame.size)
            }
            guard !sources.isEmpty else { continue }
            let layout = GridLayoutEngine.layout(sources: sources,
                                                 availableRect: display.visibleFrame,
                                                 style: state.style)
            layouts[display.id] = layout
            for card in layout.cards {
                guard let identity = state.slots.identity(at: card.slot) else { continue }
                cardRects[identity] = card.cellRect
            }
            if !layout.isReadable, !hasWarnedTinyThumbnails, state.phase.isVisible {
                hasWarnedTinyThumbnails = true
                present(.thumbnailTooSmall)
            }
        }
    }

    private func records(on displayID: UInt32) -> [WindowIdentity: WindowRecord] {
        state.records.filter { $0.value.displayID == displayID }
    }

    private func matchesSearch(_ record: WindowRecord) -> Bool {
        state.searchQuery.isEmpty
            || record.title.localizedCaseInsensitiveContains(state.searchQuery)
            || record.applicationName.localizedCaseInsensitiveContains(state.searchQuery)
    }

    private func captureTargets() -> [CaptureTarget] {
        state.records.values.compactMap { record in
            guard let display = catalog.mapper.display(id: record.displayID),
                  let slot = record.slot,
                  let card = layouts[display.id]?.card(at: slot) else { return nil }
            return CaptureTarget(record: record,
                                 cellWidth: card.cellRect.width,
                                 backingScale: display.backingScale,
                                 isPriority: settings.isPriority(record.memoryKey))
        }
    }

    private func applyOrdering() {
        let relative = orderingRelativeTo
        for controller in controllers.values {
            controller.applyOrdering(strategy: settings.orderingStrategy, relativeToWindowID: relative)
        }
    }

    private var orderingRelativeTo: UInt32? {
        guard settings.orderingStrategy == .orderedBelowTarget,
              let target = state.phase.controlledTarget else { return nil }
        return target.windowID
    }

    private func updateObservers() {
        let pids = Set(state.records.keys.map(\.processID))
        for pid in observerHub.observedPIDs where !pids.contains(pid) {
            observerHub.stopObserving(pid: pid)
        }
        for pid in pids { observerHub.observe(application: pid) }
        observerHub.update(windowElements: catalog.axEntries.mapValues { $0.map(\.element) })
    }

    private func showOverview(preferredDisplay: UInt32?) {
        ensureControllers()
        applyOrdering()
        for controller in controllers.values {
            controller.show()
            catalog.registerOwnWindow(id: controller.windowNumber)
        }
        startRedrawLoop()
        if let preferredDisplay, let controller = controllers[preferredDisplay] {
            controller.setKeyboardFocus(true)
        }
    }

    private func hideOverview() {
        focus.cancelAnimation()
        for controller in controllers.values {
            controller.setKeyboardFocus(false)
            controller.hide()
        }
        redrawTimer?.invalidate()
        redrawTimer = nil
        hintTimer?.invalidate()
        hintTimer = nil
        pendingHint = nil
        observerHub.stopAll()
        // 关闭后不留纹理与流，空闲 CPU 才能回基线（方案 §14）。
        capture.stopAll(releasingMailboxes: true)
        renderer.releaseAll()
        settings.apply(state.slots)
    }

    private func ensureControllers() {
        let displays = catalog.mapper.displays
        let ids = Set(displays.map(\.id))
        for (displayID, controller) in controllers where !ids.contains(displayID) {
            controller.hide()
            catalog.forgetOwnWindow(id: controller.windowNumber)
            controllers.removeValue(forKey: displayID)
        }
        for display in displays where controllers[display.id] == nil {
            let controller = OverviewWindowController(display: display, metalLayerScale: display.backingScale)
            controller.onAction = { [weak self] action in self?.handle(action) }
            controller.onFirstClick = { [weak self] in
                // 只统计"第一下就落在总览上"的事实，不在这里改状态。
                self?.backgroundClickCount += 1
            }
            controllers[display.id] = controller
        }
    }

    private func startRedrawLoop() {
        guard redrawTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    /// 有新鲜帧才提交绘制；没有变化的格子不重复上传（方案 §9.6）。
    private func redraw() {
        guard state.phase.isVisible else { return }
        for (displayID, controller) in controllers where controller.isVisible {
            guard layouts[displayID] != nil else { continue }
            controller.contentView.redraw(using: renderer,
                                          records: state.records,
                                          frameByID: { [weak self] in self?.state.records[$0]?.frame },
                                          mailboxes: { [weak self] identity in self?.capture.mailbox(for: identity) },
                                          force: false)
        }
    }

    // MARK: - 键盘焦点

    private func applyKeyboardFocus(_ focus: KeyboardFocus) {
        switch focus {
        case .overview:
            for controller in controllers.values { controller.setKeyboardFocus(false) }
            keyboardHost()?.setKeyboardFocus(true)
        case .targetApplication, .none:
            // 聚焦真实窗口时必须让出键盘，否则输入法与快捷键会被面板吃掉。
            for controller in controllers.values { controller.setKeyboardFocus(false) }
        }
    }

    private func keyboardHost() -> OverviewWindowController? {
        if let identity = state.phase.controlledTarget ?? state.pendingTarget,
           let displayID = state.displayID(of: identity),
           let controller = controllers[displayID] {
            return controller
        }
        if let key = controllers.values.first(where: { $0.isKey }) { return key }
        if let primary = catalog.mapper.primaryDisplay, let controller = controllers[primary.id] { return controller }
        return controllers.values.first
    }

    // MARK: - 视图动作

    private func handle(_ action: OverviewContentView.Action) {
        switch action {
        case let .cardClicked(identity):
            cardClickCount += 1
            dispatch(.cardClicked(identity))
        case .backgroundClicked:
            // 面板自留事件：不穿透到后面的应用，也不激活卡片内的任何控件。
            dispatch(.backgroundClicked(interaction: InteractionToken()))
        case let .cardDragged(from, to):
            dispatch(.cardDragged(from: from, to: to))
        case .keyboardSelected:
            needsSync = true
        case .organize:
            dispatch(.organizeRequested)
        case .exit:
            dispatch(.escapePressed)
        case let .search(query):
            dispatch(.searchChanged(query))
        }
    }

    // MARK: - 捕获与 AX 事实

    private func handle(_ fact: CaptureFact) {
        switch fact {
        case .started:
            metrics.increment("capture.started")
        case let .firstFrame(identity, date):
            dispatch(.captureFirstFrame(identity, date))
        case let .failed(identity, message):
            dispatch(.captureStreamFailed(identity, message))
        case let .downgraded(identity, interval):
            dispatch(.captureDowngraded(identity, intervalMilliseconds: interval))
        case let .budgetApplied(count):
            log("capture", "预算降级影响 \(count) 个目标")
            recorder.note("捕获预算降级影响 \(count) 个目标（流上限 \(capture.streamSoftLimit)，热状态 \(capture.thermalState.rawValue)）")
        }
    }

    private func handle(_ event: AXWindowEvent) {
        metrics.increment("ax.notification")
        guard let record = catalog.record(forAXElement: event.element, processID: event.processID) else {
            // 元素对不上身份时不猜是哪个窗口，直接要一次目录。
            scheduleStructuralRefresh()
            return
        }
        switch event.name {
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            let element = event.element
            Task { [weak self] in
                guard let self, let frame = await self.resolver.currentFrame(of: element) else { return }
                self.dispatch(.windowGeometryChangedExternally(record.identity, frame,
                                                               isUserAction: !self.focus.isWritingGeometry.contains(record.identity)))
            }
        default:
            scheduleStructuralRefresh()
        }
    }

    /// 结构性变化合并成一次目录刷新；一次查询未结束时目录自己会排队（方案 §6.7）。
    private func scheduleStructuralRefresh() {
        structuralRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.catalog.refresh(reason: .windowEvent)
        }
        structuralRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - 计时器与系统事件

    private func scheduleReconcile(_ interval: TimeInterval) {
        reconcileTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.5, interval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.reconcileTick) }
        }
        RunLoop.main.add(timer, forMode: .common)
        reconcileTimer = timer
    }

    private func registerSystemObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] notification in
            guard let self, self.state.phase.isVisible else { return }
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            // 唤起受控目标应用是本次会话自己的动作，不是用户离开。
            if let target = self.state.phase.controlledTarget, target.processID == app?.processIdentifier { return }
            self.dispatch(.focusLost(origin: .otherApplication(bundleID: app?.bundleIdentifier)))
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] _ in
            self?.dispatch(.spaceChanged)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] _ in
            self?.dispatch(.screenLocked)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] _ in
            guard let self else { return }
            self.catalog.rebuildDisplayMapping()
            if self.state.phase.isVisible { self.catalog.refresh(reason: .reconcile) }
        }
        observe(NotificationCenter.default, Notification.Name("NSApplicationDidChangeScreenParameters")) { [weak self] _ in
            guard let self else { return }
            self.catalog.rebuildDisplayMapping()
            self.dispatch(.displaysChanged)
        }
        observe(NotificationCenter.default, .vistilePermissionsChanged) { [weak self] notification in
            guard let status = notification.object as? PermissionStatus else { return }
            self?.handlePermissionChange(status)
        }
        observe(DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked")) { [weak self] _ in
            self?.dispatch(.screenLocked)
        }
    }

    private func observe(_ center: NotificationCenter,
                         _ name: Notification.Name,
                         handler: @escaping (Notification) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { handler($0) })
    }

    private func observe(_ center: DistributedNotificationCenter,
                         _ name: NSNotification.Name,
                         handler: @escaping (Notification) -> Void) {
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { handler($0) })
    }

    /// 供 P0 探针确认每屏都算出了布局，不允许有窗口的屏幕没有格子。
    func layoutDisplayIDs() -> [UInt32] { Array(layouts.keys) }

    // MARK: - 设置

    private func applySettings() {
        if state.policy != settings.sessionPolicy() { dispatch(.policyChanged(settings.sessionPolicy())) }
        if state.style != settings.style { dispatch(.settingsChanged(density: settings.density)) }
        if state.phase.isVisible { scheduleReconcile(state.policy.reconcileInterval) }
        if hotKey.currentBinding != settings.hotKey { _ = hotKey.register(settings.hotKey) }
    }

    /// 菜单或设置页改完选项后调用；状态变更仍走事件管线。
    func settingsChanged() { applySettings() }

    // MARK: - 提示

    private func present(_ hint: HintKind) {
        let text: String
        switch hint {
        case let .newWindowsAvailable(count):
            text = "有 \(count) 个窗口没排进格子，按 ⌥Space 整理"
        case .cannotLocateWindow:
            text = "找不到那个窗口，它可能已经关闭"
        case .thumbnailTooSmall:
            text = "窗口较多，缩略图已经很小；可以直接输入名称筛选"
        case let .permissionMissing(kind):
            text = kind == .screenRecording
                ? "需要屏幕录制权限才能生成实时画面"
                : "需要辅助功能权限才能聚焦与调整窗口"
        case let .transitionTimedOut(name):
            text = "\(name) 没有在规定时间内完成，已安全回到总览"
        case let .restrictedWindow(reason):
            text = reason
        case let .restoreFailed(name):
            text = "\(name) 的窗口尺寸未能恢复，请手动确认"
        case .ambiguousWindow:
            text = "同名窗口无法唯一对应，已禁用受控聚焦"
        }
        metrics.increment("hint")
        pendingHint = text
        onStatus?(text)
        hintTimer?.invalidate()
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pendingHint = nil
                self?.needsSync = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hintTimer = timer
        needsSync = true
    }

    private func log(_ category: String, _ text: String) {
        VistileLog.session.log(level: .debug, "[\(category, privacy: .public)] \(text, privacy: .public)")
        onStatus?(text)
    }

    // MARK: - 退出

    /// 正常退出：先恢复本次临时修改的几何，再落盘诊断。恢复未确认时保留事务给下次启动。
    func prepareForTermination() {
        hotKey.unregister()
        observerHub.stopAll()
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        if state.phase.isVisible { dispatch(.quitRequested) }

        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline, !isTerminationSettled {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }
        // 状态机路径没走完时（例如过渡仍在跑），用目录句柄再做一次有界兜底恢复。
        if !journal.unfinished.isEmpty {
            quitRestoreSettled = false
            let fallback = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.recovery.restoreOnQuit()
                self.quitRestoreSettled = true
            }
            let secondDeadline = Date().addingTimeInterval(0.8)
            while !quitRestoreSettled, Date() < secondDeadline {
                _ = RunLoop.main.run(mode: .default, before: min(secondDeadline, Date().addingTimeInterval(0.05)))
            }
            // 超过兜底时限就放弃等待：未完成事务仍留在日志里，下次启动继续恢复。
            fallback.cancel()
        }
        let unfinished = journal.unfinished.count
        if unfinished == 0 {
            journal.clear(sessionID: state.sessionID)
        } else {
            recorder.note("退出时仍有 \(unfinished) 条事务未确认恢复，已交给下次启动的保守恢复")
        }
        settings.apply(state.slots)
        for sample in metrics.summary() { recorder.recordPerformance(sample) }
        recorder.record("退出恢复",
                        subject: "会话事务",
                        result: unfinished == 0 ? .passed : .failed,
                        detail: "未结束事务 \(unfinished) 条")
        _ = recorder.flush()
    }

    private var isTerminationSettled: Bool {
        state.phase == .hidden && journal.unfinished.isEmpty
    }
}
