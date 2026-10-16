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
    case windowGeometryChangedExternally(WindowIdentity, CGRect, source: GeometryChangeSource)
    /// AX 写入与读回结果必须回报给状态机，函数返回成功不等于到位（方案 §6 末）。
    case geometryWriteFinished(GeometryWriteResult)
    /// 日志没能落盘：不得继续写 AX（方案 §6.2）。
    case journalWriteFailed(WindowIdentity, String)

    case captureStarted(WindowIdentity, generation: UInt64)
    case captureFirstFrame(WindowIdentity, Date)
    case captureStreamFailed(WindowIdentity, String)
    case captureDowngraded(WindowIdentity, intervalMilliseconds: Int)

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
    case writeJournal(WindowTransaction)
    /// 只清理指定会话中已经结束的条目，其他会话的未完成记录必须留下（方案 §6.4）。
    case clearJournal(sessionID: UUID, settledIdentities: [WindowIdentity])
    case dropJournal(WindowIdentity)
    /// 展开目标由 reducer 算好并先写进日志，宿主只负责写它给的那个 frame（方案 §6.2）。
    case expand(WindowIdentity, targetFrame: CGRect, token: TransitionToken, animationMS: Int)
    case collapse(WindowIdentity, token: TransitionToken, animationMS: Int)
    case restoreGeometry(WindowIdentity, token: TransitionToken)
    case restoreAll(token: TransitionToken, identities: [WindowIdentity])
    case raiseTarget(WindowIdentity)
    /// 立刻结束进行中的代理动画：目标被销毁时不能让画面继续飞向一个不存在的窗口（方案 §12.2）。
    case cancelTransition
    case setKeyboardFocus(KeyboardFocus)
    case scheduleReconcile(TimeInterval)
    case cancelReconcile
    case presentHint(HintKind)
    case none
}
