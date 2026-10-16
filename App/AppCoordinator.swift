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
    /// 启动时创建的共享设备：总览图层与代理图层都必须绑定它（R02）。
    private let metal: MetalContext

    // MARK: - 状态

    private(set) var state = SessionState()
    private(set) var controllers: [UInt32: OverviewWindowController] = [:]
    private(set) var layouts: [UInt32: GridLayout] = [:]
    private(set) var cardRects: [WindowIdentity: CGRect] = [:]
    var onStatus: ((String) -> Void)?

    /// 供 P0 记录的事实计数（方案 §4：不能仅凭"返回无错误"通过）。
    private(set) var backgroundClickCount = 0
    private(set) var cardClickCount = 0
    /// 只统计"由真实视图动作转接进来"的背景点击：P0 探针用它区分事件链路与直接 dispatch。
    private(set) var viewBackgroundClickCount = 0

    private var eventQueue: [SessionEvent] = []
    private var isDraining = false
    private var isSyncing = false
    private var needsSync = false
    private var reconcileTimer: Timer?
    private var hintTimer: Timer?
    /// 上一次真正下发给面板的层级事实；nil 表示还没排过。
    private var appliedOrdering: (strategy: OrderingStrategy, relativeToWindowID: UInt32?)?
    /// P0 探针用它证明"层级不随捕获回调反复改写"（方案 §12.2）。
    private(set) var orderingApplyCount = 0
    private var pendingHint: String?
    private var structuralRefreshWork: DispatchWorkItem?
    private var hasWarnedTinyThumbnails = false
    private var hasReportedUnwiredWorkbench = false
    private var lastOpenConditions: OpenConditions?
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
        self.metal = metal
        self.renderer = renderer
        self.journal = journal
        self.catalog = catalog
        self.capture = CaptureCoordinator(metal: metal, catalog: catalog)
        // 恢复执行器先建：过渡执行器的恢复全部委托给它，避免两套恢复规则（方案 §6.5）。
        let recovery = RecoveryCoordinator(store: journal,
                                           writer: resolver,
                                           catalog: catalog,
                                           settings: settings,
                                           permissions: permissions)
        self.recovery = recovery
        self.focus = FocusCoordinator(catalog: catalog,
                                      metal: metal,
                                      writer: resolver,
                                      store: journal,
                                      settings: settings,
                                      metrics: metrics,
                                      recorder: recorder,
                                      recovery: recovery,
                                      permissions: permissions)
    }

    // MARK: - 启动

    func start() {
        catalog.isExcludedBundle = { [weak self] bundleID in self?.settings.isExcluded(bundleID) ?? false }
        // 结果必须原样带回它对应的那一次请求：旧会话/旧请求的目录不得进入当前状态机（方案 §5.2）。
        catalog.onRecords = { [weak self] update, request in
            guard let self, let request else { return }
            // 确定销毁先走统一的 .windowClosed，再合并本轮记录：只有一套关闭窗口生命周期（方案 §8.3）。
            for identity in update.removals { self.dispatch(.windowClosed(identity)) }
            self.dispatch(.catalogUpdated(request: request, records: update.upserts))
        }
        // 失败也要解锁 in-flight，否则一次查询失败会把总览永久卡在准备中。
        catalog.onFailure = { [weak self] request, failure in
            guard let self, let request else { return }
            self.dispatch(.catalogDiscoveryFailed(request: request, failure: failure))
        }
        catalog.onStatus = { [weak self] text in self?.log("discover", text) }

        capture.onFact = { [weak self] fact in self?.handle(fact) }
        // 画面更新由新帧驱动并合并到下一个主队列周期：静止时不该再有整屏空转（方案 §7.5）。
        capture.onFrame = { [weak self] _ in
            guard let self, self.state.phase.isVisible else { return }
            self.renderer.scheduleRedraw { [weak self] in self?.redraw() }
        }
        // 纹理回收只接这一条：画面层与捕获层各自持有的一份拷贝必须一起丢，否则缓存越界（方案 §7.5）。
        capture.onWindowReleased = { [weak self] identity in
            self?.renderer.forget(identity)
        }
        focus.onEvent = { [weak self] event in self?.dispatch(event) }
        focus.onStatus = { [weak self] text in self?.log("focus", text) }
        focus.cardRectProvider = { [weak self] identity in self?.cardRects[identity] }
        focus.textureProvider = { [weak self] identity in self?.renderer.texture(for: identity) }
        // 过期的过渡不许再改状态：宿主用状态机自己那一次令牌判定。
        focus.isTokenCurrent = { [weak self] token in self?.state.phase.token == token }

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
        lastOpenConditions = openConditions()
        if let issue = journal.loadIssue {
            // 日志损坏要说明"已归档到哪、这次启动少恢复了什么"，不能静默当作没有事务。
            log("journal", "事务日志不可读，已归档：\(issue)")
            recorder.record("事务日志", subject: "启动读取", result: .failed, detail: issue)
        }
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
        // 虚假可选项必须留下迁移事实，而不是悄悄改掉用户的设置（方案 §12.1）。
        if let migrated = settings.migratedOrderingStrategy {
            recorder.record("层级策略迁移", subject: migrated.displayName, result: .blocked,
                            detail: "该策略没有实现（没有分块窗口、裁剪与命中测试），已改用 \(settings.orderingStrategy.displayName)")
        }
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

    func refreshNow() { dispatch(.reconcileTick) }

    func permissionsMayHaveChanged() {
        let after = permissions.refresh()
        handlePermissionChange(after)
    }

    /// 初次进入按跨会话记忆的顺序；容量随后按目录数量确定，不预设上限。
    private func prepareSlotMemory() {
        state.slots = SlotRegistry(capacity: 0, orderPreference: settings.slotOrderPreference)
        hasWarnedTinyThumbnails = false
    }

    private func handlePermissionChange(_ status: PermissionStatus) {
        let conditions = openConditions()
        // 权限轮询与通知会重复回报同一状态：只有真变化才进事件管线（方案 §5.1）。
        guard conditions != lastOpenConditions else { return }
        lastOpenConditions = conditions
        if !status.screenRecording {
            dispatch(.permissionLost(.screenRecording))
        } else if !status.accessibility {
            dispatch(.permissionLost(.accessibility))
        } else {
            dispatch(.permissionRestored(.screenRecording))
        }
    }

    /// 打开前置条件的唯一口径：权限读缓存，restartRequired 由捕获流事实给出（R05）。
    private func openConditions() -> OpenConditions {
        let status = permissions.status
        return OpenConditions(screenRecording: status.screenRecording,
                              accessibility: status.accessibility,
                              restartRequired: false)
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
        // 显示器事实不属于任何事件：目标屏判定与"这一屏还在不在"都由它决定（方案 §12）。
        let previousDisplays = Set(state.displays.map(\.id))
        state.displays = catalog.mapper.displays
        // 屏幕集合与状态里不一致就直接标脏：显示器通知可能晚于目录结果到达（方案 §9.1）。
        if state.phase.isVisible, previousDisplays != Set(state.displays.map(\.id)) {
            state.gridsAreStale = true
        }
        metrics.increment("event")
        let effects = SessionReducer.reduce(&state, event)
        for effect in effects {
            // 事务落盘失败时必须停止后续效果：先写 AX 会让窗口变成不可恢复的改动（方案 §6.2）。
            guard run(effect) else { break }
        }
        needsSync = true
    }

    /// 返回 false 表示这条 effect 之后不允许继续执行。
    @discardableResult
    private func run(_ effect: SessionEffect) -> Bool {
        switch effect {
        case let .discover(request):
            catalog.refresh(reason: request.reason, request: request)

        case let .evaluateOpenConditions(reopenIfReady):
            let conditions = openConditions()
            lastOpenConditions = conditions
            dispatch(.openConditionsChanged(conditions: conditions, reopenIfReady: reopenIfReady))

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
            let result = journal.apply(transaction)
            guard !result.isPersisted else { return true }
            let reason = result.reason ?? "未知原因"
            log("journal", "事务未落盘：\(reason)")
            recorder.record("几何事务落盘", subject: transaction.identity.journalKey, result: .failed,
                            detail: reason)
            dispatch(.journalWriteFailed(transaction.identity, reason))
            return false

        case let .clearJournal(sessionID, settledIdentities):
            let result = journal.clearSettled(sessionID: sessionID, settledIdentities: settledIdentities)
            if let reason = result.reason { log("journal", "清理已完成事务失败：\(reason)") }

        case let .dropJournal(identity):
            let result = journal.drop(identity)
            if let reason = result.reason { log("journal", "删除事务失败：\(reason)") }

        case let .expand(identity, targetFrame, token, animationMS):
            focus.expand(identity, targetFrame: targetFrame, token: token, animationMS: animationMS)

        case let .collapse(identity, token, animationMS):
            focus.collapse(identity, token: token, animationMS: animationMS)

        case let .restoreGeometry(identity, token):
            focus.restoreGeometry(identity, token: token)

        case let .restoreAll(token, identities):
            focus.restoreAll(identities, token: token)

        case let .raiseTarget(identity):
            focus.raiseOnly(identity)

        case .cancelTransition:
            // 目标没了：立刻收掉代理浮层并清空令牌，旧动画回调此后不再有效。
            focus.cancelAnimation()

        // M1 阶段工作台只到核心层，宿主接线在 M2（方案 §21）。以下 case 如实记录，
        // 不伪造动画或几何；hideWorkbench 是"确保工作台面板不存在"，当前天然成立。
        case let .enterWorkbench(plan):
            reportWorkbenchUnwired("enterWorkbench", identity: plan.identity)

        case let .returnToOverview(plan):
            reportWorkbenchUnwired("returnToOverview", identity: plan.identity)

        case let .beginMainSwitch(plan):
            reportWorkbenchUnwired("beginMainSwitch", identity: plan.intent.to)

        case .cancelWorkbenchTransition:
            reportWorkbenchUnwired("cancelWorkbenchTransition", identity: nil)

        case .hideWorkbench:
            break

        case let .updateWorkbenchLayout(presentation):
            reportWorkbenchUnwired("updateWorkbenchLayout", identity: presentation.mainIdentity)

        case let .settleMainFrame(identity, _, _, _):
            reportWorkbenchUnwired("settleMainFrame", identity: identity)

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
        return true
    }

    /// M1 的工作台 effect 只在核心层可达；宿主接线在 M2。如实记录一次，避免静默吞掉。
    private func reportWorkbenchUnwired(_ effect: String, identity: WindowIdentity?) {
        log("workbench", "\(effect) 尚未接入宿主（M2），本次未执行")
        guard !hasReportedUnwiredWorkbench else { return }
        hasReportedUnwiredWorkbench = true
        recorder.record("工作台宿主接入", subject: identity?.journalKey ?? "-", result: .failed,
                        detail: "M1 只到核心层；\(effect) 未执行")
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
                                    showsTitles: settings.showsTitles,
                                    searchQuery: state.searchQuery)
            controller.setToolbar(total: total,
                                  shown: records.values.filter { matchesSearch($0) }.count,
                                  query: state.searchQuery,
                                  hint: pendingHint)
        }
    }

    /// 每屏一份渲染布局：格子矩形来自冻结网格，只有 imageRect 随源尺寸变化（方案 §8.1）。
    private func rebuildLayouts() {
        layouts.removeAll()
        cardRects.removeAll()
        for (displayID, grid) in state.grids {
            var sizes: [WindowIdentity: CGSize] = [:]
            for identity in grid.occupiedIdentities {
                if let record = state.records[identity] { sizes[identity] = record.frame.size }
            }
            let layout = grid.layout(for: sizes)
            layouts[displayID] = layout
            for card in layout.cards {
                guard let identity = state.slots.identity(at: card.slot) else { continue }
                cardRects[identity] = card.cellRect
            }
            if !grid.isReadable, !hasWarnedTinyThumbnails, state.phase.isVisible {
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
        // 层级只在策略或目标窗口编号改变时重排：捕获帧、轮询事实都会触发同步，
        // 每次回调都 order(.below) 会与 WindowServer 持续较劲（方案 §12.2）。
        if let applied = appliedOrdering, applied.strategy == settings.orderingStrategy,
           applied.relativeToWindowID == relative { return }
        appliedOrdering = (settings.orderingStrategy, relative)
        orderingApplyCount += 1
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
        // 画面由新帧驱动、装饰层由状态变化驱动：这里不再挂 60Hz 空转定时器（方案 §13.3、§14 空闲 CPU）。
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
        hintTimer?.invalidate()
        hintTimer = nil
        pendingHint = nil
        // 下一次打开的面板是同一批对象，但层级要重新下发一次：隐藏期间目标可能已换。
        appliedOrdering = nil
        observerHub.stopAll()
        // 关闭后不留纹理与流，空闲 CPU 才能回基线（方案 §14）。
        capture.stopAll(releasingMailboxes: true)
        renderer.releaseAll()
        focus.pruneIdleChannels()
        settings.apply(state.slots)
    }

    private func ensureControllers() {
        let displays = catalog.mapper.displays
        let ids = Set(displays.map(\.id))
        var membershipChanged = false
        for (displayID, controller) in controllers where !ids.contains(displayID) {
            controller.hide()
            catalog.forgetOwnWindow(id: controller.windowNumber)
            controllers.removeValue(forKey: displayID)
            membershipChanged = true
        }
        for display in displays {
            if let controller = controllers[display.id] {
                // 同一块屏的尺寸/倍率变化要落到面板、内容视图与 drawableSize：
                // 只更新 catalog.mapper 不等于展示已更新（方案 §9.1）。
                controller.updateDisplay(display, mapper: catalog.mapper)
                continue
            }
            let controller = OverviewWindowController(display: display, mapper: catalog.mapper, metal: metal)
            controller.onAction = { [weak self] action in self?.handle(action) }
            controller.onFirstClick = { [weak self] in
                // 只统计"第一下就落在总览上"的事实，不在这里改状态。
                self?.backgroundClickCount += 1
            }
            controllers[display.id] = controller
            membershipChanged = true
        }
        // 新建的面板从没被排过序：签名要作废，否则这一屏永远停在默认层级。
        if membershipChanged { appliedOrdering = nil }
    }

    /// 有新鲜帧才提交绘制；没有变化的格子不重复上传（方案 §9.6）。
    private func redraw() {
        guard state.phase.isVisible else { return }
        for (displayID, controller) in controllers where controller.isVisible {
            guard layouts[displayID] != nil else { continue }
            controller.contentView.redraw(using: renderer,
                                          mailboxes: { [weak self] identity in self?.capture.mailbox(for: identity) },
                                          force: false)
        }
    }

    // MARK: - 键盘焦点

    private func applyKeyboardFocus(_ focus: KeyboardFocus) {
        switch focus {
        case .overview, .railSearch:
            let host = keyboardHost()
            for controller in controllers.values where controller !== host { controller.setKeyboardFocus(false) }
            host?.setKeyboardFocus(true)
            reportKeyboardReality(focus, host: host)
        case .targetApplication, .none:
            // 聚焦真实窗口时必须让出键盘，否则输入法与快捷键会被面板吃掉。
            for controller in controllers.values { controller.setKeyboardFocus(false) }
            reportKeyboardReality(focus, host: nil)
        }
    }

    /// 域状态与 NSWindow 实况必须对得上：脱节时写事实，不能只在状态机里以为已切换。
    private func reportKeyboardReality(_ focus: KeyboardFocus, host: OverviewWindowController?) {
        switch focus {
        case .overview:
            guard let host else {
                log("keyboard", "总览需要键盘，但当前没有可用面板")
                return
            }
            guard !host.keyboardAccepted else { return }
            log("keyboard", "总览键盘未落位：面板不是 key 或 first responder 不是内容视图，方向键/Esc/搜索不保证有效")
        case .railSearch:
            // 工作台搜索框持有键盘（M2 接入）；现在如实记录实况，不假装搜索可用。
            guard let host else {
                log("keyboard", "搜索需要键盘，但当前没有可用面板（工作台未接入，M2）")
                return
            }
            guard !host.keyboardAccepted else { return }
            log("keyboard", "搜索键盘未落位：面板不是 key（工作台未接入，M2）")
        case .targetApplication, .none:
            guard let still = controllers.values.first(where: { $0.isKey }) else { return }
            log("keyboard", "让出键盘后 display \(still.displayID) 面板仍是 key，原生输入可能落进总览")
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
            viewBackgroundClickCount += 1
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
        case let .started(identity, _):
            metrics.increment("capture.started")
            log("capture", "\(identity.processID)/\(identity.windowID) 启动一轮捕获")
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
                // 归因由过渡执行器按"写入中/写后读回"判定，不能用一个瞬时布尔猜测（方案 §6.5）。
                let source = self.focus.changeSource(for: record.identity, observed: frame)
                self.dispatch(.windowGeometryChangedExternally(record.identity, frame, source: source))
            }
        default:
            scheduleStructuralRefresh()
        }
    }

    /// 结构性变化合并成一次目录刷新，并且必须经过状态机：直接调目录会让 in-flight 记账出现两份（方案 §6.7）。
    /// 已有查询在跑时这一次会被 reconcile 的在飞保护吞掉，由下一个周期补上，不会堆积。
    private func scheduleStructuralRefresh() {
        structuralRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.dispatch(.reconcileTick)
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
            // 唤醒后的补查同样只经状态机，保持"发现"有一条记账线。
            self.dispatch(.reconcileTick)
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
    /// 供 P0 探针读取真实呈现计数：present 没发生就等于画面链路断了（方案 §4.4）。
    var rendererDiagnostics: RendererDiagnostics { renderer.diagnostics() }

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
        case let .discoveryFailed(reason):
            text = "窗口列表没查到：\(reason)"
        case let .journalWriteFailed(reason):
            text = "改动没能记入事务日志（\(reason)），已取消这次聚焦"
        case let .restoreIncomplete(count):
            text = "有 \(count) 个窗口的尺寸没恢复成功，下次启动会继续尝试"
        case let .displayUnavailable(name):
            text = "\(name) 所在的显示器已不可用，无法展开"
        case let .workbenchTransitionFailed(reason):
            text = "这次切换没有完成：\(reason)"
        case let .workbenchSwitchFailed(reason):
            text = "主窗口交换未完成：\(reason)"
        case let .workbenchMainFrameFailed(reason):
            text = "主窗口尺寸没能调整到位：\(reason)"
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

    /// 退出总期限：到期就回报终止，未完成事务留在日志里交给下次启动。
    static let terminationCeiling: TimeInterval = 2.0

    /// 正常退出：先恢复本次临时修改的几何，再落盘诊断。恢复未确认时保留事务给下次启动。
    /// 等待用可续起的 Task 完成，不在主线程嵌套 RunLoop，也不并行开第二条恢复路径（方案 §6.6）。
    func beginTermination(settled: @escaping @MainActor () -> Void) {
        guard !isTerminationBegun else { return }
        isTerminationBegun = true
        hotKey.unregister()
        observerHub.stopAll()
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        structuralRefreshWork?.cancel()
        if state.phase.isVisible { dispatch(.quitRequested) }

        Task { [weak self] in
            guard let self else { return }
            let ceiling = Date().addingTimeInterval(Self.terminationCeiling)
            while Date() < ceiling, !self.isTerminationSettled {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // 状态机路径没走完时（例如过渡仍在跑），用日志里的未完成事务做有界兜底恢复。
            if !self.journal.unfinished.isEmpty {
                await self.restoreOnQuitWithin(ceiling)
            }
            self.finishTermination()
            settled()
        }
    }

    private var isTerminationBegun = false

    private var isTerminationSettled: Bool {
        state.phase == .hidden && journal.unfinished.isEmpty && focus.isIdle
    }

    /// 兜底恢复与剩余期限赛跑：到期就放弃等待，事务留在日志里。
    private func restoreOnQuitWithin(_ deadline: Date) async {
        let remaining = max(0, deadline.timeIntervalSinceNow)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.recovery.restoreOnQuit()
            }
            group.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    private func finishTermination() {
        let unfinished = journal.unfinished.count
        if unfinished == 0 {
            // 只清已完成条目：其他会话的未完成记录必须留下（方案 §6.4）。
            _ = journal.clearSettled(sessionID: journal.currentSessionID,
                                     settledIdentities: journal.settledIdentities(sessionID: journal.currentSessionID))
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
}
