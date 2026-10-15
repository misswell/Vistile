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

    case catalogUpdated(records: [WindowRecord], generation: UInt64, reason: DiscoveryReason)
    case windowClosed(WindowIdentity)
    case windowMinimized(WindowIdentity, Bool)
    case windowGeometryChangedExternally(WindowIdentity, CGRect, isUserAction: Bool)
    /// AX 写入与读回结果必须回报给状态机，函数返回成功不等于到位（方案 §6 末）。
    case geometryWritten(WindowIdentity, provisionalFrame: CGRect, displayID: UInt32)
    case geometryVerified(WindowIdentity, readBack: CGRect)
    case geometryRestored(WindowIdentity)

    case captureStarted(WindowIdentity, generation: UInt64)
    case captureFirstFrame(WindowIdentity, Date)
    case captureStreamFailed(WindowIdentity, String)
    case captureDowngraded(WindowIdentity, intervalMilliseconds: Int)

    case expandRequested(WindowIdentity)
    case expandCompleted(TransitionToken)
    case collapseCompleted(TransitionToken)
    case transitionTimedOut(TransitionToken)
    case restoreCompleted(TransitionToken)
    case restoreFailed(TransitionToken, WindowIdentity, String)

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
    case discover(generation: UInt64, reason: DiscoveryReason)
    case startCapture([WindowIdentity], generation: UInt64)
    case stopCapture([WindowIdentity])
    case stopAllCapture
    case showOverview(displayID: UInt32?)
    case hideOverview
    case writeJournal(WindowTransaction)
    case clearJournal(sessionID: UUID)
    case dropJournal(WindowIdentity)
    /// 展开必须携带 journal 中的身份；effect 顺序保证"保存先于写入"。
    case expand(WindowIdentity, token: TransitionToken, animationMS: Int)
    case collapse(WindowIdentity, token: TransitionToken, animationMS: Int)
    case restoreGeometry(WindowIdentity, token: TransitionToken)
    case restoreAll(token: TransitionToken)
    case raiseTarget(WindowIdentity)
    case setKeyboardFocus(KeyboardFocus)
    case scheduleReconcile(TimeInterval)
    case cancelReconcile
    case presentHint(HintKind)
    case none
}
