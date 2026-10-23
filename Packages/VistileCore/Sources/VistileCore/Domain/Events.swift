import Foundation
import CoreGraphics

public enum DiscoveryReason: String, Hashable, Sendable {
    case shortcut
    case reconcile
    case windowEvent
    case displaysChanged
    case permissionRestored
    case spaceChanged
    case harnessProbe
}

public enum PermissionKind: String, Hashable, Sendable {
    case screenRecording
    case accessibility
}

public enum HintKind: Hashable, Sendable {
    case newWindowsAvailable(Int)
    case cannotLocateWindow
    case thumbnailTooSmall
    case permissionMissing(PermissionKind)
    case transitionTimedOut(String)
    case restrictedWindow(String)
    case restoreFailed(String)
    case ambiguousWindow
    /// 发现失败与打开被拒都要说清真原因，不能一律提示缺少录屏权限（方案 §5.1）。
    case discoveryFailed(String)
    case journalWriteFailed(String)
    /// 批次处理完毕但仍有窗口几何未恢复：数量必须说出来。
    case restoreIncomplete(Int)
    case displayUnavailable(String)
    /// 工作台过渡失败（进入/返回）：失败必须说清楚，不能停在半套界面（方案 §4.2、§10.5）。
    case workbenchTransitionFailed(String)
    /// A/B 交换失败并已回滚：主窗口仍是原窗口，事实不能含糊（方案 §8.3）。
    case workbenchSwitchFailed(String)
    /// 主窗口未能按布局调整（侧栏切换、分隔线收敛）：位置保持可用，不假装已到位。
    case workbenchMainFrameFailed(String)
}

/// 一次目录查询的身份：会话 ID + 请求代次。旧会话的结果不得生成当前会话的卡片（方案 §5.2）。
public struct DiscoveryRequest: Hashable, Sendable {
    public let sessionID: UUID
    public let requestID: UInt64
    public let generation: UInt64
    public let reason: DiscoveryReason

    public init(sessionID: UUID, requestID: UInt64, generation: UInt64, reason: DiscoveryReason) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.generation = generation
        self.reason = reason
    }
}

/// 全部输入统一转成事件，交给单一 reducer（方案 §7）。
public enum SessionEvent: Hashable, Sendable {
    case globalShortcut
    /// 中文：以已可靠识别的当前窗口开启工作台，不要求总览卡片点击。
    /// English: Enter Workbench using a verified current window without an overview click.
    case currentWindowWorkbenchRequested(WindowIdentity)
    case returnShortcut
    case escapePressed
    case cardClicked(WindowIdentity)
    case backgroundClicked(interaction: InteractionToken)
    case cardDragged(from: SlotID, to: SlotID)
    case organizeRequested
    case searchChanged(String)

    case catalogUpdated(request: DiscoveryRequest, records: [WindowRecord])
    /// 查询失败同样是"这一次请求有结果"：必须清除对应的 in-flight，不得只靠成功路径解锁。
    case catalogDiscoveryFailed(request: DiscoveryRequest, failure: DiscoveryFailure)
    case openConditionsChanged(conditions: OpenConditions, reopenIfReady: Bool)
    case windowClosed(WindowIdentity)
    case windowMinimized(WindowIdentity, Bool)
    /// 中文：系统最终激活的具体窗口，不按应用身份推断。
    /// English: The concrete window finally focused by the system, not an application-level guess.
    case externalWindowFocused(WindowIdentity)
    case workbenchFocusUnavailable(reason: String)
    /// 中文：宿主读取关闭后的系统焦点；closed 必须匹配当前待替补身份。
    /// English: Host-observed focus after closure; closed must match the pending replacement.
    case workbenchReplacementResolved(closed: WindowIdentity, candidate: WindowIdentity?)
    case windowGeometryChangedExternally(WindowIdentity, CGRect, source: GeometryChangeSource)
    /// 中文：用户把主窗口拖出主区（或盖住栏）且拖动已静默；宿主判定越界并去抖后发出。
    /// English: The user dragged the main window out of the main area (or over a rail)
    /// and the drag has gone quiet; the host checks containment and debounces first.
    case mainWindowDisplaced
    /// AX 写入与读回结果必须回报给状态机，函数返回成功不等于到位（方案 §6 末）。
    case geometryWriteFinished(GeometryWriteResult)
    // MARK: 操作级日志（方案 §7.1）
    // 日志状态必须按操作上下文对账：只看 `phase.controlledTarget == failedIdentity`
    // 会把"A 的日志失败"当成"B 的日志失败"，从而留下半套交换。
    /// 该操作的日志已原子落盘：只有这个事件才允许启动几何写入。
    case journalPrepared(context: GeometryOperationContext)
    /// prepare 失败：一次 AX 都没写，按操作类型落回原状态（方案 §7.2）。
    case journalPreparationFailed(context: GeometryOperationContext,
                                  identities: [WindowIdentity],
                                  reason: String)
    /// 真实写入之后的日志更新失败：不能按"未写入"处理，必须停止后续步骤并补偿（方案 §7.2）。
    case journalUpdateFailed(context: GeometryOperationContext,
                             identity: WindowIdentity,
                             reason: String)

    case captureStarted(WindowIdentity, generation: UInt64)
    case captureFirstFrame(WindowIdentity, Date)
    case captureStreamFailed(WindowIdentity, String)
    case captureDowngraded(WindowIdentity, intervalMilliseconds: Int)

    // MARK: 工作台（方案 §7.1）

    /// 总览卡片被选中：每次打开都必须从这里进入工作台，不自动选主（方案 §4.1、§4.2）。
    case overviewCardSelected(identity: WindowIdentity, slot: SlotID, revision: Int)
    /// 中文：选择主窗口，所有轨道卡片保留各自 slot。
    /// English: Select the main window without changing any rail occupant.
    case railCardSelected(slot: RailSlotID, identity: WindowIdentity)
    /// 轨道卡片被"固定在顶部"：只写跨会话 rail 偏好，立即不动任何卡片（方案 §6.2）。
    case railPinToggled(identity: WindowIdentity)
    case railCardDragged(from: RailSlotID, to: RailSlotID)
    case railScrolled(rail: RailKind, offset: CGFloat)
    case railSideChanged(RailSide)
    /// 「全部窗口」按钮：回到完整总览，L 型上下文保存下来（方案 §4.4）。
    case returnToOverviewRequested
    /// 模式过渡结束（进入工作台或返回总览）：失败时停在原模式，不留半套界面。
    case workbenchTransitionFinished(token: TransitionToken, kind: WorkbenchTransitionKind, result: WorkbenchStepOutcome)
    /// A/B 交换的每一步单独回报；placement 只在 commit 时提交（方案 §8.2）。
    case mainSwitchStepFinished(WorkbenchSwitchStepResult)
    case mainSwitchCommitted(token: TransitionToken)
    /// 交换失败并已补偿：补偿事实必须完整（各身份处置 + 谁被激活），
    /// 缺事实或补偿不全时 reducer 只能转入 recoveryRequired，不能假装 `.focused(A)`（方案 §6.4）。
    case mainSwitchFailed(token: TransitionToken, reason: String, compensation: WorkbenchCompensationResult?)
    /// 自动替补的事实回报（方案 §10）：几何与激活都成立才提交 B 为主，否则 B 留在原 slot、主区继续空。
    case promotionFinished(context: GeometryOperationContext,
                           identity: WindowIdentity,
                           geometry: WorkbenchStepOutcome,
                           activated: Bool)
    /// 拖动分隔线中的实时预览：只改本机布局投影，不写任何外部窗口（方案 §11.2）。
    case workbenchRailSizePreview(topHeight: CGFloat?, sideWidth: CGFloat?)
    /// 用户拖动分隔线后的两条栏尺寸偏好；写盘只在拖动结束（方案 §11.2）。
    case workbenchRailSizeChanged(topHeight: CGFloat?, sideWidth: CGFloat?)
    /// 搜索框获得/失去键盘：only 搜索期间 Vistile 持有键盘（方案 §4.5、§9.3）。
    case workbenchSearchFocusChanged(Bool)

    case expandRequested(WindowIdentity)
    case expandCompleted(TransitionToken)
    case collapseCompleted(TransitionToken)
    case transitionTimedOut(TransitionToken)
    /// 每个窗口的恢复结果单独回报；"批次处理完毕"和"全部成功"分开。
    case geometryRestoreSettled(token: TransitionToken, items: [RestoreItemResult])
    case restoreCompleted(TransitionToken)

    case focusLost(origin: FocusLossOrigin)
    case spaceChanged
    case screenLocked
    case displaysChanged
    case permissionLost(PermissionKind)
    case permissionRestored(PermissionKind)
    case quitRequested
    case reconcileTick
    case policyChanged(SessionPolicy)
    case settingsChanged(density: LayoutDensity)
}

public enum FocusLossOrigin: Hashable, Sendable {
    /// 由本应用消费背景点击引起的焦点变化，属于内部正常切换。
    case internalInteraction(InteractionToken)
    case commandTab
    case dock
    /// 激活到哪个应用必须带上，否则我们自己唤起目标窗口引起的失焦会被误判为外部退出。
    case otherApplication(bundleID: String?)
    case unknown
}

public enum SessionEffect: Hashable, Sendable {
    /// 发现请求携带 session + request + generation，宿主必须原样回传（方案 §5.2）。
    case discover(request: DiscoveryRequest)
    /// 打开前重新检查权限；宿主把结果作为 openConditionsChanged 事件回报。
    case evaluateOpenConditions(reopenIfReady: Bool)
    case startCapture([WindowIdentity], generation: UInt64)
    case stopCapture([WindowIdentity])
    case stopAllCapture
    case showOverview(displayID: UInt32?)
    case hideOverview
    // MARK: 日志（方案 §7.1、§7.4）
    // 两条持久化通道各自只做一件事：prepare 是"写 AX 之前的批量准入"，
    // update 是"已发生事实的追加"。旧的逐条同步写盘入口不再存在，主线程不得等磁盘。
    /// 原子批量落盘：整个批次要么都持久化、要么都不持久化；成功回执才允许启动几何写入。
    case prepareJournal(JournalPrepareRequest)
    /// 追加一条日志事实（写后读回、纠正 original、结算清理）。
    case updateJournal(JournalUpdateRequest)
    /// 只清理指定会话中已经结束的条目，其他会话的未完成记录必须留下（方案 §6.4）。
    case clearJournal(sessionID: UUID, settledIdentities: [WindowIdentity])
    /// 排空某次操作的在途几何：隐藏/退出入口必须发出，普通操作许可随之撤销（方案 §5.2）。
    case drainGeometry(GeometryOperationContext)
    /// 展开目标由 reducer 算好并先写进日志，宿主只负责写它给的那个 frame（方案 §6.2）。
    case expand(WindowIdentity, targetFrame: CGRect, token: TransitionToken, animationMS: Int)
    case collapse(WindowIdentity, token: TransitionToken, animationMS: Int)
    case restoreGeometry(WindowIdentity, token: TransitionToken)
    case restoreAll(token: TransitionToken, identities: [WindowIdentity])
    case raiseTarget(WindowIdentity)
    /// 立刻结束进行中的代理动画：目标被销毁时不能让画面继续飞向一个不存在的窗口（方案 §12.2）。
    case cancelTransition
    /// 进入工作台：把主窗口搬到 mainRect，其余窗口按 L 型排布（方案 §4.2、§10.1）。
    case enterWorkbench(WorkbenchTransitionPlan)
    /// 返回完整总览（方案 §4.4）。
    case returnToOverview(WorkbenchTransitionPlan)
    /// 开始一次 A/B 交换：按步骤串行执行，撤销时按逆序回滚（方案 §8.1、§8.3）。
    case beginMainSwitch(WorkbenchSwitchPlan)
    /// 中文：读取关闭/最小化主窗口后系统选择的窗口，不主动激活任何候选。
    /// English: Resolve system focus after main closure/minimization without activating a candidate.
    case resolveWorkbenchReplacement(closed: WindowIdentity)
    /// 撤销进行中的模式过渡：目标已消失或超时，不留半套界面（方案 §10.5）。
    case cancelWorkbenchTransition
    /// 撤下工作台面板（返回总览、回滚、隐藏）：不留下透明的全屏命中层（方案 §9.1）。
    case hideWorkbench
    /// 布局/占用/偏移变化后的重投影：宿主据此重排卡片、命中与帧路由。
    case updateWorkbenchLayout(WorkbenchPresentation)
    /// 主窗口几何微调（侧栏切换、分隔线收敛）：节流写入并读回，不改变 placement（方案 §11.2）。
    /// 带操作上下文：布局调整同样先落盘再写 AX，隐藏时必须排空（方案 §7.1、§7.2）。
    case settleMainFrame(WindowIdentity, targetFrame: CGRect, context: GeometryOperationContext, animationMS: Int)
    case setKeyboardFocus(KeyboardFocus)
    /// 用户显式整理或 pin 后的跨会话轨道记忆：只含应用级键，不含窗口标题（方案 §16）。
    case persistWorkbenchRailMemory(orderPreference: [String: Int], pinnedKeys: Set<String>)
    case scheduleReconcile(TimeInterval)
    case cancelReconcile
    case presentHint(HintKind)
    case none
}
