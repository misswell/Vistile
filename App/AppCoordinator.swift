import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import VistileCore

/// 应用侧唯一的事件入口与 effect 执行者（方案 §7）。
/// 视图、捕获回调、AX 回调都不自己判断"现在算什么状态"：一律转成事件交给同一份 reducer，
/// 再由这里按顺序执行 reducer 给出的效果。
@MainActor
final class AppCoordinator {
    // MARK: - 依赖

    let settings: SettingsModel
    /// 权限只按"当前事实"读取：宿主测试注入替身，真实管理器随生产构造进来（方案 §15.1）。
    let permissions: PermissionChecking
    let metrics: Metrics
    let recorder: CompatibilityRecorder
    let journal: WindowJournalStore
    let catalog: WindowCatalog
    let capture: CaptureCoordinator
    /// 全应用唯一的几何操作通道（方案 §5.1–§5.5、§14.2）：focus / switch / recovery 共用它，
    /// 因此"取消屏障""排空""恢复授权"只有一处实现，也不存在第二条恢复路径。
    let geometry: GeometryOperationScheduler
    let focus: FocusCoordinator
    let recovery: RecoveryCoordinator
    /// 工作台两窗口动作的串行执行器（方案 §8.2）；探针可读它的事实（是否到过限时）。
    let switchCoordinator: WorkbenchSwitchCoordinator
    let observerHub = AXObserverHub()
    let hotKey = GlobalHotKey()
    /// 测试宿主为 false：真实注册会占用用户系统里的组合键（方案 §18.2）。
    private let registersGlobalHotKey: Bool

    private let resolver = AXWindowResolver()
    private let renderer: OverviewRenderer
    /// 启动时创建的共享设备：总览图层与代理图层都必须绑定它（R02）。
    private let metal: MetalContext
    /// 过渡承载层（方案 §10.6）：总览↔L 型、栏内交换的短时合成层都由它播放。
    private let modes: ModeTransitionCoordinator

    // MARK: - 状态

    private(set) var state = SessionState()
    private(set) var controllers: [UInt32: OverviewWindowController] = [:]
    private(set) var workbenchControllers: [UInt32: WorkbenchWindowController] = [:]
    /// 宿主最近一次收到的冻结投影：只有 reducer 发 updateWorkbenchLayout 或过渡计划时才更新。
    private(set) var workbenchPresentation: WorkbenchPresentation?
    private(set) var layouts: [UInt32: GridLayout] = [:]
    private(set) var cardRects: [WindowIdentity: CGRect] = [:]
    /// 总览里每张卡片画面实际占的矩形：进入动画的起点必须就是它画的那一格（方案 §10.1）。
    private var imageRects: [WindowIdentity: CGRect] = [:]
    var onStatus: ((String) -> Void)?

    /// 供 P0 记录的事实计数（方案 §4：不能仅凭"返回无错误"通过）。
    private(set) var backgroundClickCount = 0
    private(set) var cardClickCount = 0
    /// 只统计"由真实视图动作转接进来"的背景点击：P0 探针用它区分事件链路与直接 dispatch。
    private(set) var viewBackgroundClickCount = 0
    /// 最近一次真实视图动作的时刻（单调时钟）：过渡首帧延迟以它为锚点（方案 §20.2）。
    /// 锚在 `play()` 自己的进入时刻会把"点击后卡在目录复核里几百毫秒才起动画"这段洗掉。
    private(set) var lastInputStamp: CFTimeInterval = 0
    /// 过渡动画起飞后，真实 AX 几何执行的开始延迟（动画 180–240ms，前 110ms 留满帧飞行）。
    static let transitionExecutionDelayNS: UInt64 = 110_000_000

    /// 飞行期间推迟的 AX 观察者同步：场景结束后必须补一次。
    private var observersDeferredWhilePresenting = false
    /// 每个窗口第一次出现在会话里的时刻：用来判断"焦点丢失是不是因为开了新窗口"。
    private var recordFirstSeenAt: [WindowIdentity: CFTimeInterval] = [:]
    private var directEntryTask: Task<Void, Never>?
    private var directEntryRevision: UInt64 = 0
    private var directWorkbenchTarget: WindowIdentity?
    private var directEntrySelectionQueued = false
    var isOpeningCurrentWindowWorkbench: Bool { directEntryTask != nil || directWorkbenchTarget != nil }
    private var focusFollowTask: Task<Void, Never>?
    private var focusFollowRevision: UInt64 = 0
    private let focusReader: GeometryWriting
    var frontmostProcessID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// 打开总览那一刻已经在布局里的身份：之后只有基线之外、最近才出现的窗口才算"用户开了新 App"。
    /// 没有基线就会误伤普通切换——会话开场时所有记录都是"刚出现"，首次出现时刻全等于打开时刻。
    private var overviewBaselineIdentities: Set<WindowIdentity> = []
    private var pendingOverviewFocusLoss: (bundleID: String, event: SessionEvent)?

    /// 工作台"壁纸底"：铺满目标屏、压在真实主窗口下面，让背景看起来只有这一个窗口。
    private var workbenchBackdrops: [UInt32: WorkbenchBackdropWindow] = [:]
    private(set) var backdropIsOrderedBelowMain = false

    /// 测试：当前有几块壁纸底、是否已压到主窗口下一层、它们的窗口编号。
    var backdropWindowCount: Int { workbenchBackdrops.count }
    var backdropWindowNumbers: [UInt32] { workbenchBackdrops.values.map { UInt32(max(0, $0.windowNumber)) } }

    /// 每条场景在本进程的第一次飞行算冷启动，之后都算热路径（方案 §20.2 分组维度）。
    /// 分组在 `playTransition` 那一刻定下来，帧间隔与首帧延迟两条回调共用同一个键，不各读一次系统状态。
    private var flightCountByKind: [TransitionScene.Kind: Int] = [:]
    private var flightGroupByKind: [TransitionScene.Kind: PerformanceGroup] = [:]

    private var eventQueue: [SessionEvent] = []
    private var isDraining = false
    private var isSyncing = false
    private var needsSync = false
    /// 过渡飞行期间推迟的捕获重配：场景结束必须补一次，不能永久跳过。
    private var deferredCaptureSync = false
    private var reconcileTimer: Timer?
    private var hintTimer: Timer?
    /// 上一次真正下发给面板的层级事实；nil 表示还没排过。
    private var appliedOrdering: (strategy: OrderingStrategy, relativeToWindowID: UInt32?)?
    /// P0 探针用它证明"层级不随捕获回调反复改写"（方案 §12.2）。
    private(set) var orderingApplyCount = 0
    private var pendingHint: String?
    private var structuralRefreshWork: DispatchWorkItem?
    private var hasWarnedTinyThumbnails = false
    private var lastOpenConditions: OpenConditions?
    private var observers: [NSObjectProtocol] = []
    /// 分隔线拖动期间的外部写入节流（方案 §11.2）：15–20Hz 且一次在途；每个鼠标事件的预览不受它限制。
    private var railSizeWritePolicy = RailSizeWritePolicy()
    private var railSizeBeforeDrag: (topHeight: CGFloat?, sideWidth: CGFloat?)?
    /// 过渡动效等级决策（方案 §20.4）：基准来自系统减少动态效果与采集档位，连续卡顿观测再降级。
    private var motionController = MotionLevelController()

    /// 返回总览期间被推迟的揭示（方案 §10.1：先让代理画完，再切换总览与两栏，避免一闪）。
    /// 效果按任意顺序到达，三件事齐了且飞行到位才真正落位；任一条件丢失就整组作废。
    private struct PendingReveal {
        let token: TransitionToken
        var hideWorkbench = false
        var showOverview = false
        var preferredDisplay: UInt32?
        var keyboard = false
        var reachedEnd = false
    }
    private var pendingReveal: PendingReveal?

    // MARK: - 会话级几何编排（方案 §5.4、§7.1、§14）

    /// operationID → 操作上下文：`updateJournal` 失败只带 operationID，
    /// 但补偿事件需要完整上下文（会话、代次、令牌、类型），所以在 prepare 时登记（方案 §7.2）。
    private var operationContexts: [UUID: GeometryOperationContext] = [:]

    /// 打开总览时激活 App 的动作（测试可注入）：菜单栏点击时 App 通常不是活动应用，
    /// 不激活就只是在自己的进程内 orderFront，前台应用的同级窗口仍会盖住总览。
    /// 新系统上 `NSApp.activate` 不一定真的把 App 带回前台，再走一次运行中应用句柄。
    var activateApplication: () -> Void = {
        NSApp.activate(ignoringOtherApps: true)
        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    /// 排空完成回调（宿主侧事件）：`drainGeometry` 发出后，只有这里才算"几何任务已终止"。
    /// 核心层目前没有对应的回执事件，宿主先把事实暴露出来，reducer 补上后改成 dispatch（方案 §5.4）。
    var onGeometryDrainFinished: ((GeometryOperationContext, Bool) -> Void)?

    /// 一次统一隐藏入口的进度：撤销准入 → 清理意图 → 拆 UI/停捕获 → 栅栏 → 恢复。
    /// 每个阶段都可能被打断，但同一次会话只允许一条这样的链（方案 §5.4）。
    private enum SessionTeardown {
        case idle
        case revoked(sessionID: UUID)
        case draining(GeometryOperationContext)
        case finished(GeometryOperationContext, settled: Bool)
    }
    private var teardown: SessionTeardown = .idle

    /// 供探针/测试读取的排空事实：最后一次隐藏是在等栅栏、还是已经排空、是否超预算。
    private(set) var isGeometryDrained = true

    /// 渲染设备与着色器由调用方先建好：启动被阻塞时要分得清是"没有 Metal 设备"还是"着色器没编译过"。
    /// 宿主测试注入口（方案 §18.2）：目录、捕获、几何写入、事务日志与进程实例判定都可换替身，省略即生产接线。
    /// 进程实例判定必须可注入，否则退出恢复在宿主里只会得出"进程已不存在"，永远走不到真正写回原 frame 那一步。
    /// 不注册真实全局热键的选项只属于测试宿主：它不该占用用户系统里的组合键。
    init(settings: SettingsModel,
         permissions: PermissionChecking,
         metrics: Metrics,
         recorder: CompatibilityRecorder,
         metal: MetalContext,
         renderer: OverviewRenderer,
         catalog: WindowCatalog? = nil,
         capture: CaptureCoordinator? = nil,
         journal: WindowJournalStore = WindowJournalStore(),
         writer: GeometryWriting? = nil,
         registersGlobalHotKey: Bool = true,
         processIdentity: ProcessIdentityChecking = LiveProcessIdentity.shared,
         geometryClock: (() -> GeometryOperationScheduler.Stamp)? = nil) {
        let resolver = AXWindowResolver()
        let catalog = catalog ?? WindowCatalog(permissions: permissions, resolver: resolver)
        let geometryWriter = writer ?? resolver

        self.focusReader = geometryWriter
        self.settings = settings
        self.permissions = permissions
        self.metrics = metrics
        self.recorder = recorder
        self.metal = metal
        self.renderer = renderer
        self.journal = journal
        self.catalog = catalog
        self.capture = capture ?? CaptureCoordinator(metal: metal, catalog: catalog)
        self.modes = ModeTransitionCoordinator(metal: metal)
        self.registersGlobalHotKey = registersGlobalHotKey
        // 唯一的几何通道：注入时钟时用它（宿主测试用手动时钟证明退出预算，不靠真实 sleep，方案 §14/§18 A38）。
        let geometry = GeometryOperationScheduler(now: geometryClock)
        self.geometry = geometry
        // 恢复执行器先建：过渡执行器的恢复全部委托给它，避免两套恢复规则（方案 §6.5）。
        let recovery = RecoveryCoordinator(store: journal,
                                           writer: geometryWriter,
                                           catalog: catalog,
                                           settings: settings,
                                           permissions: permissions,
                                           processIdentity: processIdentity,
                                           scheduler: geometry)
        self.recovery = recovery
        let focus = FocusCoordinator(catalog: catalog,
                                     metal: metal,
                                     writer: geometryWriter,
                                     store: journal,
                                     settings: settings,
                                     metrics: metrics,
                                     recorder: recorder,
                                     recovery: recovery,
                                     permissions: permissions,
                                     scheduler: geometry)
        self.focus = focus
        self.switchCoordinator = WorkbenchSwitchCoordinator(catalog: catalog,
                                                            writer: geometryWriter,
                                                            store: journal,
                                                            recovery: recovery,
                                                            focus: focus,
                                                            permissions: permissions,
                                                            metrics: metrics,
                                                            recorder: recorder,
                                                            scheduler: geometry)
        self.switchCoordinator.frontmostProcessID = { [weak self] in self?.frontmostProcessID() }
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
        focus.isTokenCurrent = { [weak self] token in
            guard let current = self?.state.phase.token else { return false }
            return current == token
        }
        switchCoordinator.onEvent = { [weak self] event in
            guard let self else { return }
            // 动画交接的开关只跟"真实结果"走：到位/提交才淡化，失败/取消立刻收（方案 §10.1、§10.4）。
            switch event {
            case let .workbenchTransitionFinished(token, kind, result):
                if !result.allowsContinue {
                    self.log("workbench", "\(kind.displayName)未完成：\(result.message)")
                }
                if result.allowsContinue { self.modes.confirm(token) } else { self.modes.retreat(token) }
            case let .mainSwitchCommitted(token):
                self.modes.confirm(token)
            case let .mainSwitchFailed(token, reason, _):
                self.log("workbench", "主区交换未完成：\(reason)")
                self.modes.retreat(token)
            default:
                break
            }
            self.dispatch(event)
        }
        switchCoordinator.onStatus = { [weak self] text in self?.log("workbench", text) }

        // 承载层的屏幕事实与画面源都从同一处读：播放期间不重新发现窗口（方案 §10.6）。
        modes.displayFacts = { [weak self] displayID in
            guard let self, let display = self.catalog.mapper.display(id: displayID) else { return nil }
            return ModeTransitionCoordinator.DisplayFacts(cgFrame: display.frame,
                                                          appKitFrame: self.catalog.mapper.cgToAppKit(display.frame),
                                                          scale: display.backingScale)
        }
        // 飞行默认画面板，不画捕获位图；这条接线只服务 `.captured` 诊断回退（用总览已保留的那一帧）。
        modes.textureProvider = { [weak self] identity in self?.renderer.texture(for: identity) }
        modes.onSceneReachedEnd = { [weak self] token in self?.handleSceneReachedEnd(token) }
        modes.onSceneFinished = { [weak self] token in self?.handleSceneFinished(token) }
        modes.onSceneStats = { [weak self] kind, stats in self?.handleSceneStats(kind: kind, stats: stats) }
        modes.onSceneFacts = { [weak self] kind, facts in self?.handleSceneFacts(kind: kind, facts: facts) }
        // 交换执行器不自己判断状态：每一步都回来问唯一状态机这次交换还算不算数（方案 §8.2）。
        switchCoordinator.shouldPreserveExternalFocus = { [weak self] token in
            guard let self, self.state.workbench.mainSwitch.intent?.token == token else { return false }
            return self.state.workbench.pendingExternalFocus != nil
                || self.state.workbench.pendingRailSelection?.followsExternalFocus == true
        }
        switchCoordinator.directive = { [weak self] token in
            guard let self else { return .aborted }
            switch self.state.workbench.mainSwitch {
            case let .switching(intent, _) where intent.token == token:
                return .proceed
            case let .rollingBack(intent, reason) where intent.token == token:
                return .rollback(reason: reason)
            default:
                return .aborted
            }
        }

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
        hotKey.onFire = { [weak self] in self?.performGlobalShortcut() }

        registerSystemObservers()
        lastOpenConditions = openConditions()
        if let issue = journal.loadIssue {
            // 日志损坏要说明"已归档到哪、这次启动少恢复了什么"，不能静默当作没有事务。
            log("journal", "事务日志不可读，已归档：\(issue)")
            recorder.record("事务日志", subject: "启动读取", result: .failed, detail: issue)
        }
        dispatch(.policyChanged(settings.sessionPolicy()))
        dispatch(.settingsChanged(density: settings.density))

        if registersGlobalHotKey {
            if hotKey.register(settings.hotKey) {
                recorder.record("全局快捷键", subject: settings.hotKey.displayString, result: .unverified,
                                detail: "已注册；实机触发需录屏验证")
            } else {
                recorder.record("全局快捷键", subject: settings.hotKey.displayString, result: .failed,
                                detail: "RegisterEventHotKey 未成功，请从菜单栏进入或在设置里更换组合键")
            }
        }
        recorder.record("Metal 渲染", subject: "总览画面合成", result: .unverified,
                        detail: "设备与纹理缓存已建立；帧率、内存与 WindowServer 增量待实测")
        log("app", "协调层就绪：层级策略 \(settings.orderingStrategy.displayName)，密度 \(settings.density.rawValue)")
        // 虚假可选项必须留下迁移事实，而不是悄悄改掉用户的设置（方案 §12.1）。
        if let migrated = settings.migratedOrderingStrategy {
            recorder.record("层级策略迁移", subject: migrated.displayName, result: .blocked,
                            detail: "该策略没有实现（没有分块窗口、裁剪与命中测试），已改用 \(settings.orderingStrategy.displayName)")
        }
        // 旧版展示模式/比例键只识别一次并说清楚，不让任何一次打开绕过总览入口（方案 §16）。
        for note in settings.workbenchMigrationNotes {
            log("settings", note)
            recorder.record("工作台设置迁移", subject: "旧版本持久化值", result: .blocked, detail: note)
        }
    }

    // MARK: - 对外动作

    /// 快捷键与菜单共用：hidden 打开、focused 回总览、overview 退出（方案 §11）。
    func toggleOverview() {
        cancelDirectEntry()
        if state.phase == .hidden { prepareSlotMemory() }
        dispatch(.globalShortcut)
    }

    func performGlobalShortcut() {
        if isOpeningCurrentWindowWorkbench {
            cancelDirectEntry()
            if state.phase.isVisible { dispatch(.globalShortcut) }
        } else if state.phase == .hidden && settings.opensCurrentWindowWorkbench {
            openCurrentWindowWorkbench()
        } else {
            toggleOverview()
        }
    }

    private func cancelDirectEntry() {
        directEntryRevision &+= 1
        directEntryTask?.cancel()
        directEntryTask = nil
        directWorkbenchTarget = nil
        directEntrySelectionQueued = false
    }

    /// 中文：在打开任何面板前读取具体 AX 焦点窗口，后台核对目录后直接进入工作台。
    /// English: Resolve the concrete AX-focused window before showing panels, then enter Workbench directly.
    func openCurrentWindowWorkbench(processID: pid_t? = nil) {
        guard state.phase == .hidden, !isTerminationBegun, !isOpeningCurrentWindowWorkbench else { return }
        permissionsMayHaveChanged()
        let status = permissions.status
        guard status.isComplete else {
            present(.permissionMissing(status.screenRecording ? .accessibility : .screenRecording))
            return
        }
        guard let pid = processID ?? frontmostProcessID(), pid != ProcessInfo.processInfo.processIdentifier else {
            present(.workbenchTransitionFailed("请先选中要使用的窗口，再开启工作台。"))
            return
        }
        directEntryRevision &+= 1
        let revision = directEntryRevision
        let epoch = state.sessionEpoch
        directEntryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.directEntryRevision == revision { self.directEntryTask = nil } }
            guard let focused = await self.focusReader.focusedWindow(pid: pid), !focused.snapshot.isSheetLike else {
                if !Task.isCancelled, self.directEntryRevision == revision,
                   self.state.sessionEpoch == epoch, !self.isTerminationBegun { self.present(.cannotLocateWindow) }
                return
            }
            guard !Task.isCancelled, self.directEntryRevision == revision,
                  self.state.phase == .hidden, self.state.sessionEpoch == epoch else { return }
            await self.catalog.refreshAndWait(reason: .shortcut)
            let current = await self.focusReader.focusedWindow(pid: pid)
            guard !Task.isCancelled, self.directEntryRevision == revision,
                  self.state.phase == .hidden, self.state.sessionEpoch == epoch,
                  !self.isTerminationBegun else { return }
            let front = self.frontmostProcessID()
            let isMenuActivation = processID != nil && front == ProcessInfo.processInfo.processIdentifier
            guard (front == pid || isMenuActivation), let current,
                  CFEqual(current.element, focused.element),
                  let record = self.catalog.record(forAXElement: focused.element, processID: pid) else {
                self.present(.workbenchTransitionFailed("当前窗口已变化或暂时无法识别，请重新选择窗口后重试。"))
                return
            }
            self.directWorkbenchTarget = record.identity
            self.directEntrySelectionQueued = false
            self.prepareSlotMemory()
            self.dispatch(.globalShortcut)
        }
    }

    func returnToOverview() { dispatch(.returnShortcut) }

    /// 菜单「回到全部窗口」：工作台里回冻结总览；已经停在总览时是空动作（方案 §4.5）。
    func returnToAllWindows() { dispatch(.returnToOverviewRequested) }

    /// 菜单「隐藏」：任何可见形态都收起；隐藏态不发事件，避免反过来打开（方案 §11）。
    func hideNow() {
        guard state.phase.isVisible else { return }
        dispatch(.globalShortcut)
    }

    func closeOverview() { dispatch(.escapePressed) }

    func organizeNow() { dispatch(.organizeRequested) }

    func reportWorkbenchRailSize(topHeight: CGFloat?, sideWidth: CGFloat?) {
        dispatch(.workbenchRailSizeChanged(topHeight: topHeight, sideWidth: sideWidth))
        guard topHeight == nil || state.workbench.topHeightPreference == topHeight,
              sideWidth == nil || state.workbench.sideWidthPreference == sideWidth else { return }
        persistWorkbenchRailSizes()
    }

    private func persistWorkbenchRailSizes() {
        guard state.mode == .workbench, let displayID = state.workbench.snapshot?.displayID else { return }
        settings.saveWorkbenchRailSizes(for: Self.displaySettingsKey(displayID),
                                       topHeight: state.workbench.topHeightPreference,
                                       sideWidth: state.workbench.sideWidthPreference)
    }

    static func displaySettingsKey(_ displayID: UInt32) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return "display-\(displayID)"
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// 拖动中的节流写入（方案 §11.2）：15–20Hz，且同一时刻最多一次在途——不排队堆积 AX 写入。
    /// 最终尺寸由松手路径收口；迟到的旧读回由 reducer 的令牌守卫丢弃。
    private func settleRailSizeIfDue(rail: RailKind, value: CGFloat) {
        let now = CACurrentMediaTime()
        guard railSizeWritePolicy.allowsWrite(now: now,
                                              hasInFlightWrite: state.workbench.mainFrameWrite != nil
                                                || state.workbench.armed != nil) else { return }
        railSizeWritePolicy.recordWrite(at: now)
        dispatch(.workbenchRailSizeChanged(topHeight: rail == .top ? value : nil,
                                           sideWidth: rail == .side ? value : nil))
    }

    /// 设置页切侧栏方向：工作台开着就即时生效，隐藏或空闲时只记设置，下次进入落位（方案 §16）。
    func setWorkbenchSide(_ side: RailSide) {
        settings.workbenchSide = side
        if state.workbench.modeTransition.isTransitioning || state.mode == .workbench {
            dispatch(.railSideChanged(side))
        }
    }

    /// 设置页选工作台屏幕：nil = 跟随点击。当前已经在工作台里时不搬活动屏，下一次进入生效（方案 §13）。
    func setPreferredWorkbenchDisplay(_ displayID: UInt32?) {
        settings.preferredWorkbenchDisplayID = displayID
        state.workbench.preferredDisplayID = displayID
    }

    func refreshNow() { dispatch(.reconcileTick) }

    func permissionsMayHaveChanged() {
        let after = permissions.refresh()
        handlePermissionChange(after)
    }

    /// 初次进入按跨会话记忆的顺序；容量随后按目录数量确定，不预设上限。
    private func prepareSlotMemory() {
        state.slots = SlotRegistry(capacity: 0, orderPreference: settings.slotOrderPreference)
        // 工作台布局偏好是用户设置：每次从隐藏进入时按设置落位，会话里的改动已在动作处写回（方案 §16）。
        state.workbench.side = settings.workbenchSide
        state.workbench.topHeightPreference = settings.workbenchTopHeight
        state.workbench.sideWidthPreference = settings.workbenchSideWidth
        state.workbench.preferredDisplayID = settings.preferredWorkbenchDisplayID
        // 轨道记忆（整理顺序、固定在顶部）跨会话注入：键只含应用标识，不含窗口标题（方案 §16）。
        state.workbench.placement.adoptMemory(orderPreference: settings.workbenchRailOrder,
                                              pinned: Set(settings.workbenchPins))
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
        // 焦点丢失会决定整场会话的去留，先由宿主按"有没有带来新窗口"分流（方案 §6.2、§8.2）。
        if interceptFocusLoss(event) { return }
        enqueue(event)
    }

    private func enqueue(_ event: SessionEvent) {
        let dispatchStarted = CACurrentMediaTime()
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
        let dispatchCostMS = (CACurrentMediaTime() - dispatchStarted) * 1000
        if dispatchCostMS > 20 || (modes.isPresenting && dispatchCostMS > 8) {
            let presenting = modes.isPresenting
            let label = Self.eventLabel(event)
            VistileLog.session.log(level: .info,
                                   "[主线程] dispatch 耗时=\(Int(dispatchCostMS))ms 事件=\(processed) 飞行=\(presenting) 末事件=\(label, privacy: .public)")
        }
        if lastInputStamp > 0 {
            let delta = Int((CACurrentMediaTime() - lastInputStamp) * 1000)
            VistileLog.session.log(level: .info, "[首帧] dispatch 结束 距输入=\(delta)ms 队列事件=\(processed)")
        }
        syncIfRequired()
    }

    private var recentlyAppearedCutoff: CFTimeInterval { CACurrentMediaTime() - 3 }

    /// 工作台/总览里切到别的应用：如果对方带来了此前不在布局里的新窗口，把它纳入卡片，
    /// 而不是整场退出。返回 true 表示这次焦点丢失已被宿主接管。
    private func interceptFocusLoss(_ event: SessionEvent) -> Bool {
        guard case let .focusLost(origin) = event else { return false }
        if state.mode == .workbench || state.workbench.modeTransition.isTransitioning {
            if case .internalInteraction = origin { return false }
            requestWorkbenchFocusFollow()
            return true
        }
        guard case let .otherApplication(bundleID?) = origin,
              state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy,
              case .overview = state.phase else { return false }
        // 宽限期内再来一次焦点丢失（例如用户连续切应用）：仍按第一次的决定收口，
        // 不能在这里抢先退出，否则新窗口还在路上就先把总览关了。
        guard pendingOverviewFocusLoss == nil else { return true }
        return handleOverviewDeparture(bundleID: bundleID, event: event)
    }

    private var canFollowWorkbenchFocus: Bool {
        state.phase.isVisible && (state.mode == .workbench || state.workbench.modeTransition.isTransitioning)
            && !state.workbench.pendingReturnToOverview
    }

    func requestWorkbenchFocusFollow() {
        guard canFollowWorkbenchFocus else { return }
        focusFollowTask?.cancel()
        focusFollowRevision &+= 1
        let revision = focusFollowRevision
        let sessionID = state.sessionID
        let epoch = state.sessionEpoch
        focusFollowTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self else { return }
            defer { if self.focusFollowRevision == revision { self.focusFollowTask = nil } }
            var unresolvedPID: pid_t?
            for attempt in 0..<6 {
                guard !Task.isCancelled, self.focusFollowRevision == revision,
                      self.state.sessionID == sessionID, self.state.sessionEpoch == epoch,
                      self.canFollowWorkbenchFocus else { return }
                if let pid = self.frontmostProcessID(), pid != ProcessInfo.processInfo.processIdentifier {
                    let focused = await self.focusReader.focusedWindow(pid: pid)
                    guard !Task.isCancelled, self.focusFollowRevision == revision,
                          self.state.sessionID == sessionID, self.state.sessionEpoch == epoch,
                          self.canFollowWorkbenchFocus else { return }
                    guard self.frontmostProcessID() == pid else { continue }
                    if focused?.snapshot.isSheetLike == true { return }
                    if let focused,
                       let record = self.catalog.record(forAXElement: focused.element, processID: pid),
                       self.state.records[record.identity] != nil {
                        if let closed = self.state.workbench.pendingReplacement,
                           !self.state.workbench.hasAutoPromotionAttempted {
                            self.dispatch(.workbenchReplacementResolved(closed: closed, candidate: record.identity))
                        } else {
                            self.dispatch(.externalWindowFocused(record.identity))
                        }
                        return
                    }
                    unresolvedPID = pid
                }
                if !self.state.isDiscoveryInFlight { self.dispatch(.reconcileTick) }
                if attempt < 5 { try? await Task.sleep(nanoseconds: 120_000_000) }
            }
            guard !Task.isCancelled, self.focusFollowRevision == revision,
                  self.state.sessionID == sessionID, self.state.sessionEpoch == epoch,
                  self.canFollowWorkbenchFocus else { return }
            if let pid = unresolvedPID, self.frontmostProcessID() == pid,
               self.state.workbench.pendingReplacement?.processID != pid {
                self.dispatch(.workbenchFocusUnavailable(reason: "可能的问题：当前窗口暂时无法可靠识别。处理方法：已保留原生窗口，请稍后从总览重新选择。"))
            } else if let closed = self.state.workbench.pendingReplacement {
                self.dispatch(.workbenchReplacementResolved(closed: closed, candidate: nil))
            }
        }
    }

    /// 总览里的外部激活：只有"打开总览后新出现的窗口"才留下总览，
    /// 切到布局里已有的应用仍是正常离开（否则用别的方式切走就再也关不掉总览）。
    private func handleOverviewDeparture(bundleID: String, event: SessionEvent) -> Bool {
        if let identity = newlyAppearedOverviewWindow() {
            keepOverviewAfterNewWindow(identity)
            return true
        }
        // 目标应用在打开总览时就有窗口：普通切换，立即退出，不额外等待。
        guard !bundleHadBaselineWindows(bundleID) else { return false }
        pendingOverviewFocusLoss = (bundleID, event)
        // 刚启动的应用窗口可能比前台变更晚一轮目录才出现：主动核对并在宽限内等它。
        dispatch(.reconcileTick)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, self.pendingOverviewFocusLoss?.bundleID == bundleID else { return }
            if let identity = self.newlyAppearedOverviewWindow() {
                self.pendingOverviewFocusLoss = nil
                self.keepOverviewAfterNewWindow(identity)
                return
            }
            if !self.state.isDiscoveryInFlight { self.dispatch(.reconcileTick) }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.pendingOverviewFocusLoss?.bundleID == bundleID else { return }
            self.pendingOverviewFocusLoss = nil
            guard case .overview = self.state.phase else { return }
            if let identity = self.newlyAppearedOverviewWindow() {
                self.keepOverviewAfterNewWindow(identity)
            } else {
                // 宽限结束仍没有新窗口：直接入队，不能再被分流接住（否则每次宽限都从头开始）。
                self.enqueue(event)
            }
        }
        return true
    }

    /// 基线之外、最近 3 秒内第一次出现的窗口 = 用户刚打开的新应用。
    private func newlyAppearedOverviewWindow() -> WindowIdentity? {
        let cutoff = recentlyAppearedCutoff
        return state.records.keys.first { identity in
            !overviewBaselineIdentities.contains(identity) && (recordFirstSeenAt[identity] ?? 0) > cutoff
        }
    }

    private func bundleHadBaselineWindows(_ bundleID: String) -> Bool {
        state.records.values.contains {
            $0.bundleID == bundleID && overviewBaselineIdentities.contains($0.identity)
        }
    }

    /// 新窗口已由目录合并落进空格：把总览重新激活并置前，让新卡片真的呈现在用户眼前。
    private func keepOverviewAfterNewWindow(_ identity: WindowIdentity) {
        log("session", "总览里出现新窗口 \(identity.journalKey)：纳入布局并保持总览，不退出会话")
        activateApplication()
        for controller in controllers.values { controller.raisePanel() }
        applyKeyboardFocus(.overview)
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
        let beforePhase = state.phase
        let beforeMode = state.mode
        let beforeTransition = state.workbench.modeTransition
        switch event {
        case .overviewCardSelected, .currentWindowWorkbenchRequested, .railCardSelected, .returnToOverviewRequested:
            focusFollowTask?.cancel()
            focusFollowTask = nil
            focusFollowRevision &+= 1
        default:
            break
        }
        let entryIdentity: WindowIdentity?
        switch event {
        case let .overviewCardSelected(identity, _, _), let .currentWindowWorkbenchRequested(identity): entryIdentity = identity
        default: entryIdentity = nil
        }
        if let identity = entryIdentity {
            let preferred = state.workbench.preferredDisplayID.flatMap { id in state.displays.first { $0.id == id } }
            if let displayID = preferred?.id ?? state.records[identity]?.displayID {
                let sizes = settings.workbenchRailSizes(for: Self.displaySettingsKey(displayID))
                state.workbench.topHeightPreference = sizes.topHeight
                state.workbench.sideWidthPreference = sizes.sideWidth
            }
        }
        var effects = SessionReducer.reduce(&state, event)
        if directEntrySelectionQueued, directWorkbenchTarget != nil,
           case .overview = state.phase, state.workbench.armed == nil,
           state.workbench.modeTransition == .idle {
            // A rejected target or journal preparation falls back to a usable overview.
            cancelDirectEntry()
            effects.append(.showOverview(displayID: nil))
            effects.append(.setKeyboardFocus(.overview))
        }
        if state.phase == .hidden && beforePhase != .hidden { cancelDirectEntry() }
        if !canFollowWorkbenchFocus {
            focusFollowTask?.cancel()
            focusFollowTask = nil
            focusFollowRevision &+= 1
            railSizeBeforeDrag = nil
        }
        let now = CACurrentMediaTime()
        for identity in state.records.keys where recordFirstSeenAt[identity] == nil {
            recordFirstSeenAt[identity] = now
        }
        // 总览基线：进入总览那一刻已有的窗口。之后基线之外、最近才出现的身份才算新打开的应用。
        // 离开总览就作废，下次进入重新取；宽限中的焦点丢失也一并取消。
        if case .overview = state.phase {
            if case .overview = beforePhase {} else {
                overviewBaselineIdentities = Set(state.records.keys)
            }
        } else {
            overviewBaselineIdentities.removeAll()
            pendingOverviewFocusLoss = nil
        }
        // 目录先于宽限期到达：不用等满，立即把总览要回来并展示新卡片。
        if pendingOverviewFocusLoss != nil, case .overview = state.phase,
           let identity = newlyAppearedOverviewWindow() {
            pendingOverviewFocusLoss = nil
            keepOverviewAfterNewWindow(identity)
        }
        // 会话身份只有一个来源：状态机算完就把 sessionID/代次下发给调度器，
        // 否则两边各数一次，真实写入永远拿不到准入（方案 §5.3、§15）。
        geometry.adopt(sessionID: state.sessionID, epoch: state.sessionEpoch)
        // 阶段/模式变化必须留痕：0.1.10+18 那轮的静默整段退出，就是因为隐藏路径一条日志都没有，
        // 只能靠外部进程采样反推。此处的"由什么事实引起"是事后定责的锚点。
        if state.phase != beforePhase || state.mode != beforeMode
            || state.workbench.modeTransition != beforeTransition {
            log("session", "阶段 \(Self.phaseLabel(beforePhase))→\(Self.phaseLabel(state.phase))，"
                + "模式 \(beforeMode)→\(state.mode)，"
                + "过渡 \(Self.transitionLabel(beforeTransition))→\(Self.transitionLabel(state.workbench.modeTransition))，"
                + "由 \(Self.eventLabel(event))")
        }
        for effect in effects {
            // 事务落盘失败时必须停止后续效果：先写 AX 会让窗口变成不可恢复的改动（方案 §6.2）。
            guard run(effect) else { break }
        }
        needsSync = true
    }

    private static func phaseLabel(_ phase: SessionPhase) -> String {
        switch phase {
        case .hidden: return "hidden"
        case .preparing: return "preparing"
        case .overview: return "overview"
        case let .expanding(target, _): return "expanding(\(target.journalKey))"
        case let .focused(target): return "focused(\(target.journalKey))"
        case let .collapsing(target, _): return "collapsing(\(target.journalKey))"
        case let .switching(from, to, _): return "switching(\(from.journalKey)→\(to.journalKey))"
        case .recovering: return "recovering"
        case let .recoveryRequired(target, _): return "recoveryRequired(\(target.journalKey))"
        }
    }

    private static func transitionLabel(_ transition: ModeTransition) -> String {
        switch transition {
        case .idle: return "空闲"
        case let .enteringWorkbench(_, target): return "进入工作台(\(target.journalKey))"
        case .returningOverview: return "返回总览"
        }
    }

    /// 事件名 + 关键身份：catalogUpdated 这类大载荷只报名字，避免日志被记录列表刷爆。
    private static func eventLabel(_ event: SessionEvent) -> String {
        switch event {
        case .globalShortcut: return "globalShortcut"
        case .currentWindowWorkbenchRequested: return "currentWindowWorkbenchRequested"
        case .returnShortcut: return "returnShortcut"
        case .escapePressed: return "escapePressed"
        case let .cardClicked(identity): return "cardClicked(\(identity.journalKey))"
        case .backgroundClicked: return "backgroundClicked"
        case .cardDragged: return "cardDragged"
        case .organizeRequested: return "organizeRequested"
        case .searchChanged: return "searchChanged"
        case .catalogUpdated: return "catalogUpdated"
        case .catalogDiscoveryFailed: return "catalogDiscoveryFailed"
        case .openConditionsChanged: return "openConditionsChanged"
        case let .windowClosed(identity): return "windowClosed(\(identity.journalKey))"
        case let .windowMinimized(identity, minimized): return "windowMinimized(\(identity.journalKey), \(minimized))"
        case let .windowGeometryChangedExternally(identity, _, source): return "geometryChangedExternally(\(identity.journalKey), \(source))"
        case .geometryWriteFinished: return "geometryWriteFinished"
        case let .journalPrepared(context): return "journalPrepared(\(context.kind.rawValue))"
        case let .journalPreparationFailed(context, identities, _):
            return "journalPreparationFailed(\(context.kind.rawValue), \(identities.count))"
        case let .journalUpdateFailed(context, identity, _):
            return "journalUpdateFailed(\(context.kind.rawValue), \(identity.journalKey))"
        case .captureStarted: return "captureStarted"
        case .captureFirstFrame: return "captureFirstFrame"
        case .captureStreamFailed: return "captureStreamFailed"
        case .captureDowngraded: return "captureDowngraded"
        case let .overviewCardSelected(identity, _, _): return "overviewCardSelected(\(identity.journalKey))"
        case let .railCardSelected(slot, identity): return "railCardSelected(\(slot.rail.displayName)#\(slot.ordinal), \(identity.journalKey))"
        case let .externalWindowFocused(identity): return "externalWindowFocused(\(identity.journalKey))"
        case .workbenchFocusUnavailable: return "workbenchFocusUnavailable"
        case let .workbenchReplacementResolved(closed, candidate):
            return "workbenchReplacementResolved(\(closed.journalKey), \(candidate?.journalKey ?? "无"))"
        case .railPinToggled: return "railPinToggled"
        case let .railCardDragged(from, to): return "railCardDragged(\(from.ordinal)→\(to.ordinal))"
        case .railScrolled: return "railScrolled"
        case .railSideChanged: return "railSideChanged"
        case .returnToOverviewRequested: return "returnToOverviewRequested"
        case .workbenchTransitionFinished: return "workbenchTransitionFinished"
        case .mainSwitchStepFinished: return "mainSwitchStepFinished"
        case .mainSwitchCommitted: return "mainSwitchCommitted"
        case let .mainSwitchFailed(_, reason, _): return "mainSwitchFailed(\(reason))"
        case let .promotionFinished(_, identity, _, activated):
            return "promotionFinished(\(identity.journalKey), activated=\(activated))"
        case .workbenchRailSizePreview: return "workbenchRailSizePreview"
        case .workbenchRailSizeChanged: return "workbenchRailSizeChanged"
        case .workbenchSearchFocusChanged: return "workbenchSearchFocusChanged"
        case let .expandRequested(identity): return "expandRequested(\(identity.journalKey))"
        case .expandCompleted: return "expandCompleted"
        case .collapseCompleted: return "collapseCompleted"
        case .transitionTimedOut: return "transitionTimedOut"
        case .geometryRestoreSettled: return "geometryRestoreSettled"
        case .restoreCompleted: return "restoreCompleted"
        case let .focusLost(origin): return "focusLost(\(focusOriginLabel(origin)))"
        case .spaceChanged: return "spaceChanged"
        case .screenLocked: return "screenLocked"
        case .displaysChanged: return "displaysChanged"
        case .permissionLost: return "permissionLost"
        case .permissionRestored: return "permissionRestored"
        case .quitRequested: return "quitRequested"
        case .reconcileTick: return "reconcileTick"
        case .policyChanged: return "policyChanged"
        case .settingsChanged: return "settingsChanged"
        }
    }

    private static func focusOriginLabel(_ origin: FocusLossOrigin) -> String {
        switch origin {
        case .internalInteraction: return "内部交互"
        case .commandTab: return "commandTab"
        case .dock: return "dock"
        case let .otherApplication(bundleID): return "别的应用(\(bundleID ?? "未知"))"
        case .unknown: return "未知（前台核对）"
        }
    }

    /// 返回 false 表示这条 effect 之后不允许继续执行。
    ///
    /// 这里刻意不写 `default:`：核心层新增一个 effect 时宿主必须显式表态，
    /// 不能让它悄悄落进"什么都不做"分支——那正是"状态机以为已处理、界面一动不动"的来源（方案 §5.4）。
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
            if let target = directWorkbenchTarget, !directEntrySelectionQueued {
                directEntrySelectionQueued = true
                if let display = state.workbench.preferredDisplayID ?? state.records[target]?.displayID {
                    modes.prewarm(displayID: display)
                }
                dispatch(.currentWindowWorkbenchRequested(target))
                break
            }
            if var reveal = pendingReveal {
                reveal.showOverview = true
                reveal.preferredDisplay = displayID
                pendingReveal = reveal
                completeRevealIfReady()
            } else {
                showOverview(preferredDisplay: displayID)
            }

        case .hideOverview:
            // 只拆界面：隐藏不等于"几何任务已终止"，排空由 `.drainGeometry` 那条链给结论（方案 §5.4）。
            hideOverview()

        // MARK: 日志：批量准入与事实追加（方案 §7.1、§7.4）

        case let .prepareJournal(request):
            // 写 AX 之前的唯一准入闸：整体落盘成功才回报 journalPrepared，失败一个字节都不写。
            registerContext(request.context)
            Task { [weak self, request] in
                guard let self else { return }
                let anchor = self.lastInputStamp
                if anchor > 0 {
                    VistileLog.session.log(level: .info,
                                           "[首帧] prepare 开始 距输入=\(Int((CACurrentMediaTime() - anchor) * 1000))ms")
                }
                let started = CACurrentMediaTime()
                let written = await self.journal.prepare(request)
                // §20.2 要求 journal prepare 单独打点：写盘等待混在"进入主区"总耗时里就永远分不开。
                self.metrics.measure("日志:批量 prepare",
                                     milliseconds: (CACurrentMediaTime() - started) * 1000,
                                     context: written.isPersisted ? "整体落盘成功"
                                                                  : (written.reason ?? "落盘失败"))
                if written.isPersisted {
                    if anchor > 0 {
                        VistileLog.session.log(level: .info,
                                               "[首帧] prepare 完成 距输入=\(Int((CACurrentMediaTime() - anchor) * 1000))ms 落盘=\(Int((CACurrentMediaTime() - started) * 1000))ms")
                    }
                    self.dispatch(.journalPrepared(context: request.context))
                } else {
                    let reason = written.reason ?? "未知原因"
                    self.log("journal", "批量落盘失败：\(reason)")
                    self.recorder.record("几何事务落盘",
                                         subject: "批量 prepare",
                                         result: .failed,
                                         detail: reason)
                    self.dispatch(.journalPreparationFailed(context: request.context,
                                                            identities: request.affectedIdentities,
                                                            reason: reason))
                }
            }

        case let .updateJournal(request):
            // 追加已发生的事实：失败说明"确实写过"，只能进补偿，不能按未写入处理（方案 §7.2）。
            Task { [weak self, request] in
                guard let self else { return }
                let started = CACurrentMediaTime()
                let written = await self.journal.update(request)
                self.metrics.measure("日志:事实追加",
                                     milliseconds: (CACurrentMediaTime() - started) * 1000,
                                     context: written.isPersisted ? "落盘成功" : (written.reason ?? "落盘失败"))
                guard !written.isPersisted else { return }
                let reason = written.reason ?? "未知原因"
                self.log("journal", "事实追加失败 \(request.identity.journalKey)：\(reason)")
                // operationID 为空是旧展开路径，没有操作级补偿：只记事实，不伪造上下文。
                guard let operationID = request.operationID,
                      let context = self.operationContexts[operationID] else { return }
                self.dispatch(.journalUpdateFailed(context: context, identity: request.identity, reason: reason))
            }

        case let .clearJournal(sessionID, settledIdentities):
            Task { [weak self, sessionID, settledIdentities] in
                guard let self else { return }
                let written = await self.journal.clearSettled(sessionID: sessionID,
                                                              settledIdentities: settledIdentities)
                if let reason = written.reason { self.log("journal", "清理已完成事务失败：\(reason)") }
            }

        case let .drainGeometry(context):
            // 隐藏/退出的排空入口：撤销普通准入 → 拆界面 → 栅栏 → 恢复授权下的收尾。
            drainGeometry(context)

        // MARK: 展开/收回/恢复/唤起

        case let .expand(identity, targetFrame, token, animationMS):
            focus.expand(identity, targetFrame: targetFrame, token: token, animationMS: animationMS)

        case let .collapse(identity, token, animationMS):
            focus.collapse(identity, token: token, animationMS: animationMS)

        case let .restoreGeometry(identity, token):
            guard canStartRestoreOutsideTermination() else { break }
            focus.restoreGeometry(identity, token: token)

        case let .restoreAll(token, identities):
            if canStartRestoreOutsideTermination() {
                focus.restoreAll(identities, token: token, deadline: sharedTerminationDeadline)
            } else {
                // 终止链是唯一的恢复所有者：接住状态机算好的这一批，不开第二条并发恢复路径（方案 §14.2）。
                terminationRestoreRequest = (token, identities)
            }

        case let .raiseTarget(identity):
            // 唤起也是一次跨进程动作：先拿上下文与准入，再进 AX 队列（方案 §5.2）。
            let context = geometry.makeContext(token: TransitionToken(generation: 0), kind: .settleLayout)
            registerContext(context)
            let outcome = focus.raiseOnly(identity, context: context)
            if !outcome.wasIssued { log("focus", "唤起未发出：\(outcome.detail)") }

        case .cancelTransition:
            // 目标没了：立刻收掉代理浮层并清空令牌，旧动画回调此后不再有效。
            focus.cancelAnimation()

        // MARK: 工作台（方案 §4、§8）

        case let .enterWorkbench(plan):
            cancelDirectEntry()
            registerContext(plan.operationContext)
            // 投影立刻生效：总览面板收起、两栏按冻结几何显示，然后才写主窗口（方案 §4.2）。
            workbenchPresentation = plan.presentation
            ensureWorkbenchControllers()
            // 承载层先上屏（同一 tick 内同步画第一帧），真实窗口的 resize/聚焦都发生在遮罩之后（方案 §10.1）。
            // 飞行画的是圆角面板，不需要为它抓任何画面：点击路径上零跨进程抓帧。
            playTransition(sceneFactory.entering(plan))
            // 丝滑优先：动画先飞，真实 AX 几何在后段开始；令牌失效则整笔丢弃。
            let enterToken = plan.token
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: AppCoordinator.transitionExecutionDelayNS)
                guard let self else { return }
                guard case let .expanding(_, current) = self.state.phase, current == enterToken else { return }
                self.switchCoordinator.perform(plan)
            }

        case let .returnToOverview(plan):
            registerContext(plan.operationContext)
            pendingReveal = PendingReveal(token: plan.token)
            playTransition(sceneFactory.returning(plan))
            let returnToken = plan.token
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: AppCoordinator.transitionExecutionDelayNS)
                guard let self else { return }
                guard case let .collapsing(_, current) = self.state.phase, current == returnToken else { return }
                self.switchCoordinator.perform(plan)
            }

        case let .beginMainSwitch(plan):
            registerContext(plan.intent.operationContext)
            playTransition(sceneFactory.swapping(plan))
            // 丝滑优先：交换动画先飞，真实 AX 交换在动画中后段再开始。
            // 实机：AX 步骤在飞行动画期间持续占用主线程，丢帧稳定为 16.7ms（每两帧一次）；
            // 落定预算还有余量（~250ms 对 500ms 目标），把几何执行后移换取满帧。
            let swapToken = plan.intent.token
            // 主窗口切换：真实 AX 交换等动画完整播完（旧主缩回、新主放大）再执行，
            // 落在承载层保持/淡出阶段，避免动画中途真实窗口"跳"一下。
            let swapAnimationMS = state.workbench.snapshot?.layout.style
                .switchAnimationMS(reduceMotion: state.policy.reduceMotion) ?? 180
            let swapDelayNS = UInt64(plan.intent.followsExternalFocus ? 16 : max(80, swapAnimationMS)) * 1_000_000
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: swapDelayNS)
                guard let self else { return }
                guard self.state.workbench.mainSwitch.intent?.token == swapToken,
                      self.state.workbench.activeContext == plan.intent.operationContext else { return }
                self.switchCoordinator.perform(plan)
            }

        case .cancelWorkbenchTransition:
            // 目标消失或超时：停止后续步骤；已写入的窗口由事务日志交回恢复路径（方案 §10.5）。
            pendingReveal = nil
            modes.retreatActive()
            switchCoordinator.cancel()

        case .hideWorkbench:
            if var reveal = pendingReveal {
                reveal.hideWorkbench = true
                pendingReveal = reveal
                completeRevealIfReady()
            } else {
                hideWorkbenchPanels()
            }

        case let .updateWorkbenchLayout(presentation):
            if workbenchPresentation?.snapshot.revision ?? 0 <= presentation.snapshot.revision {
                workbenchPresentation = presentation
            }

        case .resolveWorkbenchReplacement:
            requestWorkbenchFocusFollow()

        case let .settleMainFrame(identity, targetFrame, context, animationMS):
            // 拖动预览可能已领先本次写入，包含性必须按提交时的目标矩形核对。
            registerContext(context)
            guard let rects = settleRects() else {
                log("workbench", "布局投影缺失，布局微调未发起")
                break
            }
            switchCoordinator.settle(identity,
                                     targetFrame: targetFrame,
                                     displayID: rects.displayID,
                                     token: context.transitionToken,
                                     mainRect: targetFrame,
                                     topRailRect: .null,
                                     sideRailRect: .null,
                                     context: context,
                                     animationMS: animationMS)

        case let .setKeyboardFocus(focus):
            if focus == .overview, directWorkbenchTarget != nil { break }
            // 返回总览的键盘移交推迟到揭示那一刻：目标面板还没上屏就不该先接管键盘（方案 §10.1）。
            if case .overview = focus, var reveal = pendingReveal {
                reveal.keyboard = true
                pendingReveal = reveal
                needsSync = true
            } else {
                applyKeyboardFocus(focus)
            }

        case let .persistWorkbenchRailMemory(orderPreference, pinnedKeys):
            // 轨道记忆是用户说过的话，只有整理/固定动作才会到这里：如实写盘（方案 §16）。
            settings.workbenchRailOrder = orderPreference
            settings.workbenchPins = pinnedKeys.sorted()

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

    // MARK: - 操作上下文登记（方案 §7.2）

    /// 记下这次操作的身份：日志更新失败只带 operationID，补偿要能还原完整上下文。
    private func registerContext(_ context: GeometryOperationContext) {
        operationContexts[context.operationID] = context
        // 表只服务于本会话：换会话后旧操作再报事实也不该找到旧上下文。
        if operationContexts.count > 64 {
            for (id, value) in operationContexts where value.sessionID != context.sessionID {
                operationContexts.removeValue(forKey: id)
            }
        }
    }

    /// 布局微调需要的主区/两栏矩形：来自当前冻结投影，绝不现场重算（方案 §11.2）。
    private func settleRects() -> (displayID: UInt32, mainRect: CGRect, topRailRect: CGRect, sideRailRect: CGRect)? {
        guard let presentation = workbenchPresentation else { return nil }
        let layout = presentation.snapshot.layout
        return (presentation.displayID, layout.mainRect, layout.topRailRect, layout.sideRailRect)
    }

    /// 退出期间只有一个恢复所有者（方案 §14.2）：终止链一旦开始，状态机的恢复效果由它接管。
    private func canStartRestoreOutsideTermination() -> Bool {
        guard isTerminationBegun else { return true }
        log("termination", "终止链已是唯一恢复所有者，本次恢复效果并入同一条链")
        return false
    }

    // MARK: - 统一隐藏与排空（方案 §5.4）

    /// 退出链的共享预算截止点；正常会话隐藏不受两秒限制，所以是 nil。
    private var terminationDeadline: GeometryOperationScheduler.Stamp?

    /// 状态机算好、但按 §14.2 移交终止链的恢复批次：终止时只有一条恢复路径能碰窗口。
    private var terminationRestoreRequest: (token: TransitionToken, identities: [WindowIdentity])?

    /// 恢复写入拿到的截止点：只有终止链开始后才有预算（方案 §14）。
    var sharedTerminationDeadline: GeometryOperationScheduler.Stamp? { terminationDeadline }

    /// 隐藏入口统一：撤销普通准入 → 停掉在跑的操作链 → 等已开始写入的栅栏 → 给出排空结论。
    /// 界面拆建仍归 `.hideOverview`/`.hideWorkbench`/`.stopAllCapture`：这里只回答"几何任务终止了没有"（方案 §5.4）。
    /// 快捷键、锁屏、Space、权限丢失、显示器变化、退出都走这条链，不再有第二种隐藏。
    private func drainGeometry(_ context: GeometryOperationContext) {
        if case .draining = teardown {
            // 同一次会话只允许一条排空链：后来的请求并入它，不开第二条恢复路径（方案 §14.2）。
            log("drain", "排空链已在运行，本次请求（\(context.kind.rawValue)）并入同一条链")
            return
        }
        teardown = .revoked(sessionID: context.sessionID)
        isGeometryDrained = false
        // 关闭普通准入：相位之后任何普通操作都拿不到许可，排队计划一律丢弃（方案 §5.1）。
        geometry.advance(to: .closing)
        // 交换链自己也要收手：它内部还有一段尾任务，不叫停就会继续提交写入（方案 §8.3）。
        switchCoordinator.cancel()
        focus.cancelAnimation()
        let deadline = terminationDeadline
        Task { [weak self] in
            guard let self else { return }
            let quiet = await self.geometry.drain(until: deadline)
            self.teardown = .finished(context, settled: quiet)
            self.isGeometryDrained = self.geometry.isIdle
            self.log("drain", quiet
                     ? "几何通道已排空（\(context.kind.rawValue)）"
                     : "排空超出预算：\(self.geometry.busyDescription)，事务与日志原样保留")
            self.onGeometryDrainFinished?(context, quiet)
        }
    }

    // MARK: - 展示同步

    private func performSync() {
        guard !isSyncing else { return }
        let syncStarted = CACurrentMediaTime()
        isSyncing = true
        var marks: [(String, Double)] = []
        var lastMark = syncStarted
        func mark(_ label: String) {
            let now = CACurrentMediaTime()
            marks.append((label, (now - lastMark) * 1000))
            lastMark = now
        }
        defer {
            isSyncing = false
            let cost = (CACurrentMediaTime() - syncStarted) * 1000
            if cost > 40 || (modes.isPresenting && cost > 8) {
                let breakdown = marks
                    .filter { $0.1 > 8 }
                    .map { "\($0.0)=\(Int($0.1))ms" }
                    .joined(separator: " ")
                let phaseName = Self.phaseLabel(state.phase)
                let presenting = modes.isPresenting
                VistileLog.session.log(level: .info,
                                       "[主线程] performSync 总=\(Int(cost))ms 阶段=\(phaseName, privacy: .public) 飞行=\(presenting) \(breakdown, privacy: .public)")
            }
        }
        rebuildLayouts()
        mark("布局")
        // 被拔掉的屏不再保留承载层：过渡画面只属于还在的屏幕（方案 §9.1）。
        modes.retireDisplays(keeping: Set(catalog.mapper.displays.map(\.id)))
        guard state.phase.isVisible else {
            for controller in controllers.values where controller.isOrderedButHidden { controller.hide() }
            return
        }
        mark("退屏")

        // 统一的过渡活动（方案 §13.2）：三路事实合并后交给捕获层。
        // 过渡飞行在屏上时，捕获层的重配会与 displayLink 抢主线程，是帧间隔抖动的来源之一；
        // 飞行期间只推迟 capture.sync（≤240ms），场景结束时立刻补一次——画面先由已有纹理兜住。
        let presentingTransition = modes.isPresenting && transitionActivity.modeTransition
        if presentingTransition || railSizeBeforeDrag != nil {
            deferredCaptureSync = true
        } else {
            deferredCaptureSync = false
            capture.sync(targets: captureTargets(), tier: state.policy.tier, activity: transitionActivity)
        }
        mark("捕获")
        // 诊断：飞行期间这里若耗时数百毫秒，会直接挤掉 displayLink tick（渲染本身约 0.1ms）。
        syncOverviewPanels()
        mark("总览面板")
        syncWorkbenchPanels()
        mark("工作台面板")
        applyOrdering()
        mark("层级")
        // 飞行期间 AX 观察者增删实测 43–101ms/次，会直接挤掉 displayLink 的 tick；
        // 订阅变化不需要在飞行中立即生效，场景结束的 requestSync 会补一次。
        if modes.isPresenting || railSizeBeforeDrag != nil {
            observersDeferredWhilePresenting = true
        } else {
            observersDeferredWhilePresenting = false
            updateObservers()
        }
        mark("观察者")

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
            mark("面板内容")
        }
    }

    /// 总览面板只在总览模式显示：进入 L 型后（含过渡中）全屏覆盖层必须先收起（方案 §4.2）。
    /// 返回总览的飞行还在屏幕上时也不例外：等揭示再显示，避免"一闪关掉再弹新界面"（方案 §10.1）。
    private func syncOverviewPanels() {
        let shouldShow = state.mode == .overview
            && directWorkbenchTarget == nil
            && !state.workbench.modeTransition.isTransitioning
            && pendingReveal == nil
        for controller in controllers.values {
            if shouldShow {
                if !controller.isVisible {
                    controller.show()
                    catalog.registerOwnWindow(id: controller.windowNumber)
                    // 重新显示的面板要重新下发一次层级，隐藏期间目标可能已换（方案 §12.2）。
                    appliedOrdering = nil
                }
            } else if controller.isVisible {
                controller.setKeyboardFocus(false)
                // 过渡/揭示期间用 alpha 收起：orderOut 单次实测 460–496ms，会把 displayLink 直接挤停。
                if modes.isPresenting || state.workbench.modeTransition.isTransitioning || pendingReveal != nil {
                    controller.hideCheaply()
                } else {
                    controller.hide()
                }
            }
        }
    }

    /// 两条栏按冻结投影显示；投影退化或没有投影时不留下零尺寸空面板（方案 §9.1）。
    /// 返回总览的飞行期间两栏必须留在屏幕上（承载层要盖着它们飞），所以揭示前都算"engaged"。
    private func syncWorkbenchPanels() {
        let engaged = state.workbench.modeTransition.isTransitioning
            || state.mode == .workbench
            || pendingReveal != nil
        guard engaged, let presentation = workbenchPresentation else {
            for controller in workbenchControllers.values where controller.isVisible { controller.hide() }
            hideWorkbenchBackdrops()
            return
        }
        ensureWorkbenchControllers()
        for (displayID, controller) in workbenchControllers where displayID != presentation.displayID {
            if controller.isVisible { controller.hide() }
        }
        guard let controller = workbenchControllers[presentation.displayID] else { return }
        if !controller.isVisible {
            controller.show()
            for id in controller.windowNumbers { catalog.registerOwnWindow(id: id) }
            appliedOrdering = nil
        }
        // 承载层正在画的卡片先从栏里藏起来，再推投影：藏在重绘前生效，不会出现两份（方案 §10.6）。
        controller.setHiddenRailIdentities(modes.hiddenRailIdentities)
        controller.update(presentation: presentation,
                          renderer: renderer,
                          mailboxProvider: { [weak self] identity in self?.capture.mailbox(for: identity) },
                          showsTitles: settings.showsTitles,
                          searchQuery: state.searchQuery,
                          hint: pendingHint)
        syncWorkbenchBackdrop(for: presentation, controller: controller)
    }

    /// 壁纸底跟着工作台投影走：屏、frame、壁纸，以及"压在主窗口下一层"的层级。
    private func syncWorkbenchBackdrop(for presentation: WorkbenchPresentation,
                                        controller: WorkbenchWindowController) {
        guard let display = catalog.mapper.display(id: presentation.displayID) else {
            hideWorkbenchBackdrops()
            return
        }
        // 没有真实主窗口时不铺底图：宁可露出桌面，也不能盖住可能在前面的窗口。
        guard let mainRecord = presentation.mainRecord else {
            hideWorkbenchBackdrops()
            return
        }
        let appKitFrame = catalog.mapper.cgToAppKit(display.frame)
        let backdrop: WorkbenchBackdropWindow
        if let existing = workbenchBackdrops[presentation.displayID] {
            backdrop = existing
        } else {
            backdrop = WorkbenchBackdropWindow(screenFrame: appKitFrame)
            catalog.registerOwnWindow(id: UInt32(max(0, backdrop.windowNumber)))
            workbenchBackdrops[presentation.displayID] = backdrop
        }
        backdrop.apply(screenFrame: appKitFrame,
                       wallpaper: WorkbenchBackdropWindow.wallpaperImage(for: presentation.displayID))
        let mainWindowNumber = Int(mainRecord.identity.windowID)
        guard mainWindowNumber > 0 else {
            backdrop.orderOut(nil)
            backdropIsOrderedBelowMain = false
            return
        }
        backdrop.orderFrontRegardless()
        backdrop.orderBelow(windowNumber: mainWindowNumber)
        backdropIsOrderedBelowMain = true
        // 底图为了压住主窗口会被降到主窗口下一层；两栏必须重新提到它上面。
        controller.raisePanels()
        for (displayID, other) in workbenchBackdrops where displayID != presentation.displayID {
            other.orderOut(nil)
            catalog.forgetOwnWindow(id: UInt32(max(0, other.windowNumber)))
            workbenchBackdrops.removeValue(forKey: displayID)
        }
    }

    private func hideWorkbenchBackdrops() {
        backdropIsOrderedBelowMain = false
        for (displayID, backdrop) in workbenchBackdrops {
            backdrop.orderOut(nil)
            catalog.forgetOwnWindow(id: UInt32(max(0, backdrop.windowNumber)))
            workbenchBackdrops.removeValue(forKey: displayID)
        }
    }

    private func hideWorkbenchPanels() {
        hideWorkbenchBackdrops()
        for controller in workbenchControllers.values {
            controller.hide()
            for id in controller.windowNumbers { catalog.forgetOwnWindow(id: id) }
        }
        workbenchPresentation = nil
    }

    /// 每屏一份渲染布局：格子矩形来自冻结网格，只有 imageRect 随源尺寸变化（方案 §8.1）。
    private func rebuildLayouts() {
        layouts.removeAll()
        cardRects.removeAll()
        imageRects.removeAll()
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
                imageRects[identity] = card.imageRect
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
        record.matches(searchQuery: state.searchQuery)
    }

    /// 三路过渡事实合并后的唯一活动判据（方案 §13.2）：
    /// 视图代理、模式承载层、交换/布局执行器任何一路还在跑，尺寸重配都要延后合并；
    /// 任何一路说了"取消已请求"，延后立刻失效，释放不许被动画拖住。
    var transitionActivity: TransitionActivity {
        focus.activity | modes.activity | switchCoordinator.activity
    }

    // MARK: - 捕获需求分级（方案 §13.1）

    /// 可见性分档的中间结果：每档一个身份集合，顺序即优先级（方案 §13.1）。
    private struct CaptureVisibilityPlan {
        var transition: Set<WindowIdentity> = []
        var visible: Set<WindowIdentity> = []
        var prefetch: Set<WindowIdentity> = []
        /// 真实主区窗口：它自己就是画面，不该再占一条缩略捕获流（方案 §13.1）。
        var excluded: Set<WindowIdentity> = []
    }

    /// 一张卡的画面需求来自四个事实，按固定顺序取第一档命中：
    /// 过渡参与者 → 此刻可见 → 相邻一屏内的预取 → 离屏。
    ///
    /// 为什么不能只看"有没有格子"：滚动即将进入视口的卡片要提前有缓存帧，
    /// 而远离视口的卡片还在抢直播名额，可见卡片就永远回不到实时（方案 §13.1 末段）。
    private func captureVisibilityPlan() -> CaptureVisibilityPlan {
        var plan = CaptureVisibilityPlan()
        // 1. 过渡参与者：状态机正在操作的身份 + 执行器在途身份 + 承载层正在飞的身份。
        for identity in transitionParticipants { plan.transition.insert(identity) }
        if let presentation = workbenchPresentation {
            // 2. 可见：投影自己按 viewport 判定，宿主不另算一套。
            for card in presentation.cards where card.isVisible { plan.visible.insert(card.identity) }
            // 3. 邻近预取：每条栏各取"可见序号范围 ± 一屏卡片数"，绝不越界到整条栏（方案 §13.1）。
            for rail in [RailKind.top, .side] {
                let ordinals = presentation.cards.filter { $0.slot.rail == rail }.map { $0.slot.ordinal }
                let visibleOrdinals = presentation.cards.filter { $0.slot.rail == rail && $0.isVisible }
                    .map { $0.slot.ordinal }
                guard let first = visibleOrdinals.min(), let last = visibleOrdinals.max() else { continue }
                // 一屏能放几张按当前可见数量估，至少 1 张；上界即"相邻一屏"。
                let span = max(1, visibleOrdinals.count)
                let lower = first - span, upper = last + span
                for card in presentation.cards
                where card.slot.rail == rail && card.slot.ordinal >= lower && card.slot.ordinal <= upper {
                    plan.prefetch.insert(card.identity)
                }
            }
            // The selected window keeps its live rail thumbnail and uses the same capture budget.
            plan.excluded = []
        } else {
            // 总览：有格子的算可见；没有格子的（overflow/被过滤）算离屏，只保最后一帧。
            for (displayID, layout) in layouts {
                for card in layout.cards {
                    guard let identity = state.slots.identity(at: card.slot) else { continue }
                    plan.visible.insert(identity)
                }
            }
        }
        return plan
    }

    /// 当前正在"飞"的身份：这几张必须拿到最高档，否则交接时是旧图（方案 §10.6、§13.1）。
    private var transitionParticipants: Set<WindowIdentity> {
        var identities: Set<WindowIdentity> = []
        if let target = state.phase.controlledTarget { identities.insert(target) }
        if let pending = state.pendingTarget { identities.insert(pending) }
        if let target = state.workbench.modeTransition.target { identities.insert(target) }
        switch state.workbench.mainSwitch {
        case let .switching(intent, _):
            identities.insert(intent.to)
            if let from = intent.from { identities.insert(from) }
        case let .rollingBack(intent, _):
            identities.insert(intent.to)
            if let from = intent.from { identities.insert(from) }
        default:
            break
        }
        return identities
    }

    private func captureTargets() -> [CaptureTarget] {
        let hidden = !state.phase.isVisible
        let plan = captureVisibilityPlan()
        // 工作台里主区是真实窗口：只有两栏卡片需要实时画面（方案 §4.3、§14 空闲 CPU）。
        if state.workbench.modeTransition.isTransitioning || state.mode == .workbench,
           let presentation = workbenchPresentation {
            let scale = catalog.mapper.display(id: presentation.displayID)?.backingScale ?? 2
            return presentation.cards.compactMap { card in
                let cellWidth = presentation.snapshot.contentRect(for: card.slot)?.width
                    ?? presentation.snapshot.layout.topCardSize.width
                return CaptureTarget(record: card.record,
                                     cellWidth: cellWidth,
                                     backingScale: scale,
                                     isPriority: settings.isPriority(card.record.memoryKey),
                                     visibility: visibility(for: card.identity, in: plan, hidden: hidden))
            }
        }
        return state.records.values.compactMap { record in
            guard let display = catalog.mapper.display(id: record.displayID) else { return nil }
            // 没有格子位置的卡片（overflow/刚新增）也要有目标条目：它按离屏处理只保最后一帧，
            // 不能因为布局里暂时没有它就从目标集里消失（那会让滚回来的瞬间是黑帧）。
            let card = record.slot.flatMap { layouts[display.id]?.card(at: $0) }
            let cellWidth = card?.cellRect.width ?? display.frame.width / 6
            return CaptureTarget(record: record,
                                 cellWidth: max(80, cellWidth),
                                 backingScale: display.backingScale,
                                 isPriority: settings.isPriority(record.memoryKey),
                                 visibility: visibility(for: record.identity, in: plan, hidden: hidden))
        }
    }

    /// 分档：隐藏 > 过渡参与者 > 可见 > 邻近预取 > 离屏（方案 §13.1 的固定顺序）。
    private func visibility(for identity: WindowIdentity,
                            in plan: CaptureVisibilityPlan,
                            hidden: Bool) -> CaptureTargetVisibility {
        if hidden || plan.excluded.contains(identity) { return .paused }
        if plan.transition.contains(identity) { return .transition }
        if plan.visible.contains(identity) { return .visible }
        if plan.prefetch.contains(identity) { return .prefetch }
        // 离屏：包括"这一轮没有格子位置"的新增窗口——它随时会被重新平铺进来，
        // 保留最后一帧比彻底不捕获更省（滚回来时不是黑帧）。
        return .offscreen
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
        for controller in workbenchControllers.values {
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

    // MARK: - 过渡动画（方案 §10）

    /// 预计算源/目标的全套外部事实：播放期间不再回读目录、不重排网格（方案 §10.6）。
    private var sceneFactory: TransitionSceneFactory {
        // 每次起过渡前对齐一次基准事实：系统设置与采集档位可能刚刚变过（方案 §20.4）。
        motionController.update(reduceMotion: state.policy.reduceMotion, pressureTier: state.policy.tier)
        var factory = TransitionSceneFactory()
        factory.reduceMotion = { [weak self] in self?.state.policy.reduceMotion ?? false }
        factory.motionLevel = { [weak self] in self?.motionController.level ?? .full }
        factory.overviewImageRect = { [weak self] identity in self?.imageRects[identity] }
        factory.recordFrame = { [weak self] identity in self?.state.records[identity]?.frame }
        factory.displayFrame = { [weak self] displayID in self?.catalog.mapper.display(id: displayID)?.frame }
        factory.aspect = { [weak self] identity, fallback in
            guard let self else { return max(0.2, fallback.width / max(1, fallback.height)) }
            return TransitionSceneFactory.aspect(frame: self.renderer.texture(for: identity),
                                                 recordFrame: self.state.records[identity]?.frame,
                                                 fallback: self.imageRects[identity] ?? fallback)
        }
        return factory
    }

    private func playTransition(_ scene: TransitionScene?) {
        guard let scene else { return }
        // 冷/热在这一次飞行起飞的这一刻定（方案 §20.2）。中途重定向会让同场景再起飞一次，
        // 分组键以最后一段为准——它只是样本标签，不改变任何判据。
        let flights = (flightCountByKind[scene.kind] ?? 0) + 1
        flightCountByKind[scene.kind] = flights
        flightGroupByKind[scene.kind] = PerformanceEnvironment.current(coldStart: flights == 1)
        // 锚点用完即清：每段过渡只由触发它的那次输入锚定，没有输入（自动替补、探针直接 dispatch）
        // 就按 play() 进入时刻算，并在 context 里如实标出来（方案 §20.2）。
        let anchor = lastInputStamp
        lastInputStamp = 0
        if anchor > 0 {
            // 首帧延迟的拆点：点击→场景起飞（主线程/日志闸门排队时间），和起飞→呈现分开算。
            VistileLog.session.log(level: .info,
                                   "[首帧] 场景=\(scene.kind.displayName, privacy: .public) 距输入=\(Int((CACurrentMediaTime() - anchor) * 1000))ms")
        }
        modes.play(scene, anchorAt: anchor > 0 ? anchor : nil)
        // 场景一上屏，两栏就要按新的隐藏集合重绘一次。
        needsSync = true
    }

    /// 宿主测试：打开总览后哪些屏已经预建了过渡承载层。
    var prewarmedCarrierDisplayIDs: Set<UInt32> { modes.carrierDisplayIDs }

    /// 飞行到位（进入保持态）：返回总览的揭示要等这个时刻才允许落位（方案 §10.1）。
    private func handleSceneReachedEnd(_ token: TransitionToken) {
        guard var reveal = pendingReveal, reveal.token == token else { return }
        reveal.reachedEnd = true
        pendingReveal = reveal
        completeRevealIfReady()
    }

    /// 承载层完全消失：栏里的静止副本恢复绘制；被推迟的揭示在这里兜底完成，不留半套界面。
    private func handleSceneFinished(_ token: TransitionToken) {
        if let reveal = pendingReveal, reveal.token == token {
            pendingReveal = nil
            if state.mode == .overview {
                hideWorkbenchPanels()
                showOverview(preferredDisplay: reveal.preferredDisplay)
                if reveal.keyboard { applyKeyboardFocus(.overview) }
            }
        }
        if deferredCaptureSync {
            deferredCaptureSync = false
        }
        requestSync()
    }

    /// 过渡飞行的帧事实（方案 §20.3/§20.4）：逐场景记 P95 与掉帧，连续超预算的观测驱动降级（带滞后）。
    /// 指标名带 §20.2 的分组键，`Metrics` 按名字分桶 → 不同刷新率/reduceMotion/冷热的样本不混进同一个 P95。
    private func handleSceneStats(kind: TransitionScene.Kind, stats: FrameIntervalStats) {
        let group = flightGroupByKind[kind] ?? PerformanceEnvironment.current(coldStart: false)
        metrics.measure(PerformanceMetricName.qualified("过渡帧间隔p95·\(kind.displayName)", group: group),
                        milliseconds: stats.p95MS,
                        context: "n=\(stats.count)"
                            + " 掉帧占比\(String(format: "%.1f%%", stats.longFrameRatio * 100))"
                            + " 最长连续=\(stats.longestStutterRun)"
                            + " 分组=\(group.key)"
                            + " 本机帧间隔=\(String(format: "%.2f", group.nativeFrameIntervalMS))ms")
        metrics.increment(stats.meetsTarget ? PerformanceMetricName.qualified("过渡帧预算内", group: group)
                                            : PerformanceMetricName.qualified("过渡超帧预算", group: group))
        // §20.2 的第二个闸门是"累计至少 1,000 个有效间隔"，数的是帧间隔条数不是动画段数，
        // 所以要单独攒：只有段数（n≥100）能对上"每条路径 100 次操作"，间隔总数没人记就永远判不了。
        metrics.increment(PerformanceMetricName.qualified("过渡有效帧间隔·\(kind.displayName)", group: group),
                          by: stats.count)
        if let changed = motionController.observe(stats) {
            log("motion", "动效等级变化：\(motionController.reason)")
            metrics.increment("动效等级.\(changed.rawValue)")
        }
    }

    /// 呈现事实（方案 §20.2）：首帧延迟单独一条；动画 present 与 displayLink 回调分开核对。
    /// 只记帧间隔会把"点了之后很久没出第一帧"和"整段一个像素都没呈现"都藏起来。
    private func handleSceneFacts(kind: TransitionScene.Kind, facts: TransitionFlightFacts) {
        let group = flightGroupByKind[kind] ?? PerformanceEnvironment.current(coldStart: false)
        if let delay = facts.firstPresentDelayMS {
            // 没有点击锚点的段（自动替补、探针直接 dispatch）单列，不混进"点击反馈"的 P95。
            metrics.measure(PerformanceMetricName.qualified(
                                facts.anchoredAtRealInput ? "过渡首帧延迟·\(kind.displayName)"
                                                          : "过渡首帧延迟(无点击锚点)·\(kind.displayName)",
                                group: group),
                            milliseconds: delay,
                            context: "锚点=\(facts.anchoredAtRealInput ? "真实点击" : "动画进入")"
                                + " ticks=\(facts.ticks) present=\(facts.presentedFrames)"
                                + " 分组=\(group.key)")
        } else {
            metrics.increment("过渡零呈现段")
        }
        if facts.missedPresentFrames > 0 {
            metrics.increment("过渡回调多于呈现", by: facts.missedPresentFrames)
        }
    }

    /// 三件事齐了（两栏收起、总览上屏、飞行到位）才做一次真正切换；缺一件就继续等（方案 §10.1）。
    private func completeRevealIfReady() {
        guard let reveal = pendingReveal,
              reveal.hideWorkbench, reveal.showOverview, reveal.reachedEnd else { return }
        pendingReveal = nil
        hideWorkbenchPanels()
        showOverview(preferredDisplay: reveal.preferredDisplay)
        if reveal.keyboard { applyKeyboardFocus(.overview) }
        modes.startHandoff(reveal.token)
        needsSync = true
    }

    /// 需要一次收敛但可能不在事件管线内（承载层回调）：不在管线里就立刻同步。
    private func requestSync() {
        needsSync = true
        guard !isDraining, !isSyncing else { return }
        syncIfRequired()
    }

    private func showOverview(preferredDisplay: UInt32?) {
        ensureControllers()
        applyOrdering()
        for controller in controllers.values {
            controller.show()
            catalog.registerOwnWindow(id: controller.windowNumber)
        }
        // 画面由新帧驱动、装饰层由状态变化驱动：这里不再挂 60Hz 空转定时器（方案 §13.3、§14 空闲 CPU）。
        // 预建各屏承载层：把窗口/图层/drawable 的首次分配移出点击路径（首帧延迟的冷启动部分）。
        for display in catalog.mapper.displays { modes.prewarm(displayID: display.id) }
        // 激活本身会把 App 的窗口整体提前；再显式置前一次，避免个别系统版本里
        // "非激活面板 + orderFrontRegardless" 仍压不过前台应用的同级窗口。
        activateApplication()
        for controller in controllers.values { controller.raisePanel() }
        if let preferredDisplay, let controller = controllers[preferredDisplay] {
            controller.setKeyboardFocus(true)
        }
    }

    private func hideOverview() {
        focus.cancelAnimation()
        // 会话隐藏：承载层与推迟的揭示一起作废，不留任何透明层（方案 §10.4）。
        pendingReveal = nil
        modes.cancelAll()
        for controller in controllers.values {
            controller.setKeyboardFocus(false)
            controller.hide()
        }
        // 会话隐藏时工作台同样不存在：两栏面板不留透明命中层（方案 §9.1）。
        hideWorkbenchPanels()
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

    /// 工作台面板与总览一样按屏维护；屏被拔掉时同样要收面板并注销自己的窗口编号。
    private func ensureWorkbenchControllers() {
        let displays = catalog.mapper.displays
        let ids = Set(displays.map(\.id))
        var membershipChanged = false
        for (displayID, controller) in workbenchControllers where !ids.contains(displayID) {
            controller.hide()
            for id in controller.windowNumbers { catalog.forgetOwnWindow(id: id) }
            workbenchControllers.removeValue(forKey: displayID)
            membershipChanged = true
        }
        for display in displays {
            if let controller = workbenchControllers[display.id] {
                controller.updateDisplay(display, mapper: catalog.mapper)
                continue
            }
            let controller = WorkbenchWindowController(display: display, mapper: catalog.mapper, metal: metal)
            controller.onAction = { [weak self] action in self?.handle(action) }

            workbenchControllers[display.id] = controller
            membershipChanged = true
        }
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
        if let presentation = workbenchPresentation,
           let controller = workbenchControllers[presentation.displayID], controller.isVisible {
            for view in [controller.topRail, controller.sideRail] {
                view.redraw(using: renderer,
                            mailboxes: { [weak self] identity in self?.capture.mailbox(for: identity) },
                            force: false)
            }
        }
    }

    // MARK: - 键盘焦点

    private func applyKeyboardFocus(_ focus: KeyboardFocus) {
        switch focus {
        case .overview:
            let host = keyboardHost()
            for controller in controllers.values where controller !== host { controller.setKeyboardFocus(false) }
            for controller in workbenchControllers.values { controller.setSearchKeyboard(false) }
            host?.setKeyboardFocus(true)
            reportKeyboardReality(focus, host: host)
        case .railSearch:
            // 只有搜索框在编辑时工作台面板才接受键盘（方案 §9.3）。
            let host = workbenchController()
            for controller in controllers.values { controller.setKeyboardFocus(false) }
            for controller in workbenchControllers.values where controller !== host {
                controller.setSearchKeyboard(false)
            }
            host?.setSearchKeyboard(true)
            reportKeyboardReality(focus, host: nil)
        case .targetApplication, .none:
            // 聚焦真实窗口时必须让出键盘，否则输入法与快捷键会被面板吃掉。
            for controller in controllers.values { controller.setKeyboardFocus(false) }
            for controller in workbenchControllers.values { controller.setSearchKeyboard(false) }
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
            guard let search = workbenchController() else {
                log("keyboard", "搜索需要键盘，但当前没有工作台面板")
                return
            }
            guard !search.isSearchFocused else { return }
            log("keyboard", "搜索键盘未落位：工作台顶栏面板不是 key 或搜索框不是 first responder")
        case .targetApplication, .none:
            if let still = controllers.values.first(where: { $0.isKey }) {
                log("keyboard", "让出键盘后 display \(still.displayID) 总览面板仍是 key，原生输入可能落进总览")
            }
            if let still = workbenchControllers.values.first(where: { $0.isSearchFocused }) {
                log("keyboard", "让出键盘后 display \(still.displayID) 搜索框仍持有键盘")
            }
        }
    }

    private func workbenchController() -> WorkbenchWindowController? {
        let displayID = state.workbench.activeDisplayID
            ?? workbenchPresentation?.displayID
            ?? state.phase.controlledTarget.flatMap { state.displayID(of: $0) }
        if let displayID, let controller = workbenchControllers[displayID] { return controller }
        return workbenchControllers.values.first
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
        lastInputStamp = CACurrentMediaTime()
        VistileLog.session.log(level: .info, "[首帧] 输入到达 视图=总览")
        switch action {
        case let .cardClicked(identity):
            cardClickCount += 1
            let modeLabel = state.mode == .overview ? "总览" : "工作台"
            VistileLog.session.log(level: .debug,
                                   "[点击] 总览卡片 \(identity.journalKey, privacy: .public) 模式=\(modeLabel, privacy: .public)")
            // 总览里的选择只有一个入口：进入工作台（方案 §4.1）。没有格子位置就不是一次有效选择。
            guard let slot = state.slots.slot(for: identity) else {
                log("overview", "点击的卡片没有格子位置，未发起聚焦")
                return
            }
            // 身份瞬时未唯一（窗口刚被移动、两侧 frame 还没对齐）：复核目录并重试，
            // 不拿一次坏采样下"定位不到"的结论（方案 §6.1）。唯一时零额外延迟。
            if let record = state.records[identity], !record.confidence.allowsAXWrite {
                Task { @MainActor in
                    await reviewRecordUniqueness(identity)
                    guard state.phase.isVisible, state.mode == .overview else { return }
                    guard let fresh = state.slots.slot(for: identity) else {
                        // 复核完仍没有格子位置：窗口多半已经走了，别让这次点击无声消失。
                        log("overview", "点击 \(identity.journalKey) 复核后没有格子位置，未发起聚焦")
                        present(.cannotLocateWindow)
                        return
                    }
                    dispatch(.overviewCardSelected(identity: identity,
                                                   slot: fresh,
                                                   revision: state.workbench.layoutRevision))
                }
                return
            }
            dispatch(.overviewCardSelected(identity: identity,
                                           slot: slot,
                                           revision: state.workbench.layoutRevision))
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

    /// 工作台视图动作同样只转成事件：命中、滚动、搜索都不在视图里改状态（方案 §7.1）。
    private func handle(_ action: WorkbenchWindowController.Action) {
        lastInputStamp = CACurrentMediaTime()
        VistileLog.session.log(level: .info, "[首帧] 输入到达 视图=工作台")
        switch action {
        case let .railCardClicked(slot, identity):
            // 点击进诊断日志：实机验收要能还原"点是否到达宿主、当时状态机什么态度"（方案 §14）。
            let railLabel = slot.rail == .top ? "顶栏" : "侧栏"
            let mainLabel = state.workbench.placement.main?.journalKey ?? "空"
            let switchLabel = state.workbench.mainSwitch.isBusy ? "在途" : "空闲"
            VistileLog.session.log(level: .debug,
                                   "[点击] 轨道卡片 \(railLabel, privacy: .public)#\(slot.ordinal) \(identity.journalKey, privacy: .public) 主区=\(mainLabel, privacy: .public) 交换=\(switchLabel, privacy: .public)")
            // 与总览点击同一条原则：身份瞬时未唯一时复核重试，不把一次坏采样当"不能交换"。
            if state.records[identity]?.confidence.allowsAXWrite != true {
                Task { @MainActor in
                    await reviewRecordUniqueness(identity)
                    guard state.phase.isVisible, state.mode == .workbench else { return }
                    dispatch(.railCardSelected(slot: slot, identity: identity))
                }
                return
            }
            dispatch(.railCardSelected(slot: slot, identity: identity))
        case let .railCardDragged(from, to):
            dispatch(.railCardDragged(from: from, to: to))
        case let .railScrolled(rail, offset):
            dispatch(.railScrolled(rail: rail, offset: offset))
        case .railDividerDragBegan:
            railSizeBeforeDrag = (state.workbench.topHeightPreference, state.workbench.sideWidthPreference)
            railSizeWritePolicy.reset()
        case let .railDividerDragged(rail, value):
            // 每个鼠标事件都推本机预览；外部 AX 写入由节流策略决定（方案 §11.2）。
            dispatch(.workbenchRailSizePreview(topHeight: rail == .top ? value : nil,
                                               sideWidth: rail == .side ? value : nil))
            settleRailSizeIfDue(rail: rail, value: value)
        case let .railDividerDragEnded(rail, value):
            railSizeBeforeDrag = nil
            reportWorkbenchRailSize(topHeight: rail == .top ? value : nil,
                                    sideWidth: rail == .side ? value : nil)
        case .railDividerDragCancelled:
            guard let previous = railSizeBeforeDrag else { break }
            railSizeBeforeDrag = nil
            state.workbench.topHeightPreference = previous.topHeight
            state.workbench.sideWidthPreference = previous.sideWidth
            dispatch(.workbenchRailSizeChanged(topHeight: nil, sideWidth: nil))
        case let .railDividerReset(rail):
            railSizeBeforeDrag = nil
            if rail == .top { state.workbench.topHeightPreference = nil }
            else { state.workbench.sideWidthPreference = nil }
            dispatch(.workbenchRailSizeChanged(topHeight: nil, sideWidth: nil))
            persistWorkbenchRailSizes()
        case let .railPinToggled(identity):
            dispatch(.railPinToggled(identity: identity))
        case .organize:
            dispatch(.organizeRequested)
        case .returnToOverview:
            dispatch(.returnToOverviewRequested)
        case .toggleSide:
            let side = (workbenchPresentation?.side ?? state.workbench.side).toggled
            dispatch(.railSideChanged(side))
            // 被状态机拒绝的请求不能改用户设置：只有状态真的换了方向才写盘（方案 §11.2、§16）。
            if state.workbench.side == side { settings.workbenchSide = side }
        case let .searchFocus(focused):
            dispatch(.workbenchSearchFocusChanged(focused))
        case let .search(query):
            dispatch(.searchChanged(query))
        }
    }

    // MARK: - 捕获与 AX 事实

    /// 点击到达时身份可能瞬时未唯一：窗口刚被我们移动过，窗口服务器的几何提交
    /// 明显晚于 AX 一侧（实测约 0.6s），按几何打分就会掉成"无法唯一确定"（方案 §6.1）。
    /// 复核目录并重试读取，最多约 2s；读回唯一立刻返回，超时也返回——
    /// 之后一律交给状态机按当时的记录判定（唯一则照常动作，仍不唯一则给出提示）。
    /// 身份本来就唯一时一次都不复核，零额外延迟。
    private func reviewRecordUniqueness(_ identity: WindowIdentity) async {
        guard state.records[identity]?.confidence.allowsAXWrite != true else { return }
        VistileLog.session.log(level: .debug,
                               "[点击] \(identity.journalKey, privacy: .public) 身份暂未唯一，复核目录后重试")
        for _ in 0..<8 {
            await catalog.refreshAndWait(reason: .windowEvent)
            if state.records[identity]?.confidence.allowsAXWrite == true { return }
            guard state.phase.isVisible else { return }
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
    }

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
        if event.name == kAXFocusedWindowChangedNotification || event.name == kAXMainWindowChangedNotification
            || event.name == kAXWindowCreatedNotification || event.name == kAXWindowDeminiaturizedNotification {
            if canFollowWorkbenchFocus, frontmostProcessID() == event.processID {
                requestWorkbenchFocusFollow()
            } else if let target = state.phase.controlledTarget, target.processID == event.processID {
                verifyControlledWindowIsFrontmost(target, trigger: "AX \(event.name)")
            }
        }
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

    /// 受控应用在前台时的核对：受控窗口不再是前台窗口时才安全退出工作台
    /// （方案 §14：不得只比较 PID 就当没发生变化）。判定走 FocusVerificationLadder——
    /// 单次读不到或读数摇摆都不是事实，只有连续两次读到同一个别的身份才算确证失焦
    /// （0.1.10+18 实测：交换刚提交后我们自己的前景确认产生焦点通知，赶上一次读回失败，
    /// 被当成用户离开、整段会话静默退出）。交换与模式过渡在途时不插话——
    /// 那时候前台归属由执行器自己的写入读回判定，否则我们自己的唤起会被误读成用户离开。
    private func verifyControlledWindowIsFrontmost(_ target: WindowIdentity, trigger: String) {
        if canFollowWorkbenchFocus {
            requestWorkbenchFocusFollow()
            return
        }
        guard state.workbench.modeTransition == .idle, !state.workbench.mainSwitch.isBusy else {
            log("focus", "核对受控窗口 \(target.journalKey) 跳过（过渡/交换在途）：\(trigger)")
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var reads: [WindowIdentity?] = []
            for attempt in 1...3 {
                if attempt > 1 { try? await Task.sleep(nanoseconds: 220_000_000) }
                // 每次读回前复核：会话、受控目标与"静止"都可能已经变了。
                guard self.state.phase.isVisible, self.state.phase.controlledTarget == target,
                      self.state.workbench.modeTransition == .idle,
                      !self.state.workbench.mainSwitch.isBusy else { return }
                let focused = await self.resolver.focusedWindow(pid: target.processID)
                var read: WindowIdentity?
                if let focused,
                   let record = self.catalog.record(forAXElement: focused.element, processID: target.processID) {
                    read = record.identity
                }
                reads.append(read)
                if read == target { break }
            }
            let readText = reads.map { $0?.journalKey ?? "读不到" }.joined(separator: "、")
            switch FocusVerificationLadder.verdict(target: target, reads: reads) {
            case .present:
                log("focus", "核对受控窗口 \(target.journalKey)（\(trigger)）：读回[\(readText)]，仍在前台")
            case .inconclusive:
                // 读不到不是事实：不退出会话，等后续通知或下一轮核对再看。
                log("focus", "核对受控窗口 \(target.journalKey)（\(trigger)）：读回[\(readText)] 不构成失焦证据，保持会话")
            case let .confirmedLost(lost):
                log("focus", "核对受控窗口 \(target.journalKey)（\(trigger)）：读回[\(readText)] 确证 \(lost.journalKey) 在前台，安全退出会话")
                guard self.state.phase.isVisible, self.state.phase.controlledTarget == target else { return }
                self.dispatch(.focusLost(origin: .unknown))
            }
        }
    }

    /// 外部应用激活的确认：激活通知先于焦点真正落定到达，落点可能是我们自己的唤起、
    /// 用户切回受控应用的瞬态、或真有一个别的应用接管前台。只认 300ms 后重新读回的前台事实：
    /// 读不到不算证据；前台是我们自己或受控进程都保持会话，确证是别的应用才退出
    /// （方案 §14；「读不到 ≠ 不可以」）。过渡/交换在途时交给执行器自己的读回判定。
    private func confirmExternalDeparture(bundleID: String?, processIdentifier: pid_t?) {
        if canFollowWorkbenchFocus {
            requestWorkbenchFocusFollow()
            return
        }
        let controlledPID = state.phase.controlledTarget?.processID
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.state.phase.isVisible else { return }
            guard self.state.workbench.modeTransition == .idle, !self.state.workbench.mainSwitch.isBusy else {
                log("focus", "激活确认 \(bundleID ?? "?")：过渡/交换在途，前台归属交由执行器判定，保持会话")
                return
            }
            guard let front = NSWorkspace.shared.frontmostApplication else {
                log("focus", "激活确认 \(bundleID ?? "?")：300ms 后读不到前台应用，不构成离开证据，保持会话")
                return
            }
            if front.bundleIdentifier == Bundle.main.bundleIdentifier {
                log("focus", "激活确认 \(bundleID ?? "?")：300ms 后前台是我们自己，保持会话")
                return
            }
            if let controlledPID, front.processIdentifier == controlledPID {
                log("focus", "激活确认 \(bundleID ?? "?")：300ms 后前台是受控进程 pid=\(controlledPID)，按内部唤起处理，保持会话")
                return
            }
            log("focus", "激活确认 \(bundleID ?? "?")：300ms 后前台=\(front.bundleIdentifier ?? "?") pid=\(front.processIdentifier)，确证外部应用在前台，退出会话")
            guard self.state.phase.isVisible else { return }
            self.dispatch(.focusLost(origin: .otherApplication(bundleID: front.bundleIdentifier ?? bundleID)))
        }
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
            log("focus", "应用激活 \(app?.bundleIdentifier ?? "?") pid=\(app?.processIdentifier ?? -1)"
                + "（受控目标=\(self.state.phase.controlledTarget.map { "\($0.processID)/\($0.windowID)" } ?? "无")）")
            // 受控应用的激活可能是我们自己的动作，也可能是用户选中了它的兄弟窗口：
            // 必须读回前台窗口的身份再判定，不能只比 PID 就当没发生（方案 §14）。
            if let target = self.state.phase.controlledTarget, target.processID == app?.processIdentifier {
                self.verifyControlledWindowIsFrontmost(target, trigger: "应用激活")
                return
            }
            self.confirmExternalDeparture(bundleID: app?.bundleIdentifier,
                                          processIdentifier: app?.processIdentifier)
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
        // 每个提示都要在日志里留痕：实机验收要看得出"产品对这次操作有没有说话"（方案 §14）。
        VistileLog.session.log(level: .debug, "[hint] \(text, privacy: .public)")
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
        // 阶段/模式/过渡的每一跳都必须留在能查到的等级里：0.1.10+18 那轮静默退出只能靠外部进程采样反推，
        // 就是因为这类轨迹全压在 .debug，控制台与统一日志都取不到（方案 §14、§22）。
        VistileLog.session.log(level: .info, "[\(category, privacy: .public)] \(text, privacy: .public)")
        onStatus?(text)
    }

    // MARK: - 退出

    /// 退出总期限：到期就回报终止，未完成事务留在日志里交给下次启动。
    static let terminationCeiling: TimeInterval = 2.0

    /// 正常退出：先恢复本次临时修改的几何，再落盘诊断。恢复未确认时保留事务给下次启动。
    /// 等待用可续起的 Task 完成，不在主线程嵌套 RunLoop，也不并行开第二条恢复路径（方案 §6.6）。
    /// 终止链只报已经发生的事实：排空、恢复确认条数、按预算推迟条数（方案 §14.5）。
    private struct TerminationOutcome {
        var drained = true
        var restored = 0
        var deferred = 0
        var didExpire = false
    }

    func beginTermination(settled: @escaping @MainActor () -> Void) {
        cancelDirectEntry()
        guard !isTerminationBegun else { return }
        isTerminationBegun = true
        // 1. 先停掉一切会产生新写入的来源：热键、AX 观察、目录定时任务、结构刷新。
        hotKey.unregister()
        observerHub.stopAll()
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        structuralRefreshWork?.cancel()
        // 共享预算从这一刻开始算：后面每个阶段只花剩下的，不再各自重新拿满两秒（方案 §14）。
        let deadline = geometry.deadline(after: .seconds(Self.terminationCeiling))
        terminationDeadline = deadline
        if state.phase.isVisible { dispatch(.quitRequested) }

        // 2. 终止链是唯一的恢复所有者：先按身份栅栏排空在途写入，再在剩余预算内逐条恢复。
        let outcome = OneShot<TerminationOutcome>()
        Task { [weak self] in
            guard let self else { return }
            outcome.send(await self.runTermination(deadline: deadline))
        }
        // 3. 到点用独立计时回调结束等待。`TaskGroup.cancelAll()` 管不住已经在跨进程调用里的恢复，
        //    包住它只是把"等子任务收尾"说成硬截止（方案 §14）；这里的在途调用继续自行收敛，日志原样保留。
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.terminationCeiling) {
            MainActor.assumeIsolated {
                var expired = TerminationOutcome()
                expired.didExpire = true
                expired.drained = false
                outcome.send(expired)
            }
        }
        // 4. 回报恰好一次：链先收敛就用链的结论，否则用到点结论。
        Task { [weak self] in
            let result = await withCheckedContinuation {
                (continuation: CheckedContinuation<TerminationOutcome, Never>) in
                outcome.attach(continuation)
            }
            guard let self else { return }
            await self.finishTermination(result)
            settled()
        }
    }

    private var isTerminationBegun = false

    /// 终止链本体：排空 → 在剩余预算内逐条恢复 → 交出事实。任何一步没有预算就停下保留日志（方案 §14.1–§14.3）。
    private func runTermination(deadline: GeometryOperationScheduler.Stamp) async -> TerminationOutcome {
        var result = TerminationOutcome()
        result.drained = await geometry.drain(until: deadline)
        let pending = journal.unfinished.count
        guard pending > 0 else { return result }
        guard result.drained, geometry.canStartNewWrite(deadline: deadline) else {
            result.deferred = pending
            result.didExpire = true
            recorder.note("退出预算已尽：\(pending) 条事务保留在日志里，交下次启动核对")
            return result
        }
        let token = terminationRestoreRequest?.token ?? TransitionToken(generation: 0)
        let report = await recovery.restoreOnQuit(token: token, deadline: deadline)
        result.restored = report.items.filter { $0.outcome.isSettled }.count
        result.deferred = report.deferredByDeadline.count
        result.didExpire = !report.deferredByDeadline.isEmpty
        return result
    }

    private func finishTermination(_ outcome: TerminationOutcome) async {
        let unfinished = journal.unfinished.count
        if outcome.didExpire {
            // 到期：只记录已确认事实，一条都不清理，未完成事务留给下次启动（方案 §14.5）。
            recorder.note("退出期限结束：恢复确认 \(outcome.restored) 条，推迟 \(outcome.deferred) 条，"
                          + "排空\(outcome.drained ? "完成" : "未完成")")
        } else if unfinished == 0 {
            // 只清已完成条目：其他会话的未完成记录必须留下（方案 §6.4）。
            _ = await journal.clearSettled(sessionID: journal.currentSessionID,
                                           settledIdentities: journal.settledIdentities(sessionID: journal.currentSessionID))
        } else {
            recorder.note("退出时仍有 \(unfinished) 条事务未确认恢复，已交给下次启动的保守恢复")
        }
        settings.apply(state.slots)
        for sample in metrics.summary() { recorder.recordPerformance(sample) }
        recorder.record("退出恢复",
                        subject: "会话事务",
                        result: unfinished == 0 && !outcome.didExpire ? .passed : .failed,
                        detail: "未结束事务 \(unfinished) 条，期限\(outcome.didExpire ? "已过" : "内收敛")")
        _ = recorder.flush()
    }
}
