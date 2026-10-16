import Foundation
import CoreGraphics

/// 单一 reducer：所有输入进入这里，状态与 effect 一起决定（方案 §7）。
/// View、捕获回调、AX 回调都不得自行维护布尔状态。
public enum SessionReducer {
    public static func reduce(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect] {
        if let priority = reducePriority(&state, event) { return priority }
        return reduceNormal(&state, event)
    }

    // MARK: - 优先级高于动画的事件

    private static func reducePriority(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect]? {
        switch event {
        case .quitRequested:
            guard state.phase.isVisible else { return [] }
            return exitToHidden(&state)

        case let .permissionLost(kind):
            guard state.phase != .hidden else { return [] }
            let token = state.nextTransitionToken()
            state.isExitPending = true
            state.pendingTarget = nil
            state.phase = .suspended(reason: .permissionLost)
            var effects: [SessionEffect] = [.cancelReconcile, .stopAllCapture, .hideOverview]
            if state.hasPendingGeometryRestore { effects.append(.restoreAll(token: token)) }
            effects.append(.presentHint(.permissionMissing(kind)))
            return effects

        case .screenLocked:
            guard state.phase.isVisible else { return [] }
            return suspendAndRestore(&state, reason: .screenLocked)

        case .spaceChanged:
            // Space 切换时暂停并退出当前会话，重新打开时重新发现（方案 §12）。
            guard state.phase.isVisible else { return [] }
            return suspendAndRestore(&state, reason: .spaceChanged)

        case let .windowClosed(identity):
            var effects: [SessionEffect] = [.stopCapture([identity])]
            state.records.removeValue(forKey: identity)
            state.slots.release(identity)
            if let target = state.phase.controlledTarget, target == identity {
                // 目标已销毁：没有可恢复的 frame，只清理事务与捕获。
                state.transactions.removeValue(forKey: identity)
                effects.append(.dropJournal(identity))
                state.pendingTarget = nil
                state.phase = .overview
                state.keyboardFocus = .overview
                effects.append(.setKeyboardFocus(.overview))
            } else if state.pendingTarget == identity {
                state.pendingTarget = nil
            }
            return effects

        case .displaysChanged:
            guard state.phase.isVisible else { return [] }
            state.isDiscoveryInFlight = true
            if state.phase.controlledTarget != nil || state.hasPendingGeometryRestore {
                let token = state.nextTransitionToken()
                state.isExitPending = true
                state.pendingTarget = nil
                state.phase = .recovering(token: token)
                return [.cancelReconcile, .restoreAll(token: token), .hideOverview]
            }
            return [.discover(generation: state.catalogGeneration, reason: .displaysChanged)]

        default:
            return nil
        }
    }

    private static func suspendAndRestore(_ state: inout SessionState, reason: SuspendReason) -> [SessionEffect] {
        let token = state.nextTransitionToken()
        state.isExitPending = true
        state.pendingTarget = nil
        state.phase = .suspended(reason: reason)
        var effects: [SessionEffect] = [.cancelReconcile, .stopAllCapture, .hideOverview]
        if state.hasPendingGeometryRestore { effects.append(.restoreAll(token: token)) }
        return effects
    }

    // MARK: - 常规事件

    private static func reduceNormal(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect] {
        switch event {
        case .globalShortcut:
            return handleShortcut(&state)

        case .returnShortcut:
            switch state.phase {
            case let .focused(target): return beginCollapse(&state, target)
            case let .switching(_, target, _): return beginCollapse(&state, target)
            default: return []
            }

        case .escapePressed:
            // 聚焦真实应用时 Esc 原样交给应用。
            if state.keyboardFocus == .targetApplication { return [] }
            switch state.phase {
            case .overview, .preparing: return exitToHidden(&state)
            case let .focused(target): return beginCollapse(&state, target)
            case let .expanding(target, _), let .collapsing(target, _): return beginCollapse(&state, target)
            case let .switching(_, target, _): return beginCollapse(&state, target)
            default: return []
            }

        case let .cardClicked(identity), let .expandRequested(identity):
            return handleTargetRequest(&state, identity)

        case let .backgroundClicked(interaction):
            state.trustedInteraction = interaction
            switch state.phase {
            case let .focused(target): return beginCollapse(&state, target)
            case let .expanding(target, _): return beginCollapse(&state, target)
            case let .switching(_, target, _): return beginCollapse(&state, target)
            default: return []
            }

        case let .focusLost(origin):
            // 自己点击背景引起的应用切换不是外部离开；令牌只允许被消费一次。
            if case let .internalInteraction(token) = origin, state.trustedInteraction == token {
                state.trustedInteraction = nil
                return []
            }
            return handleFocusLost(&state, origin)

        case .expandCompleted(let token):
            var effects: [SessionEffect] = [.setKeyboardFocus(.targetApplication)]
            switch state.phase {
            case let .expanding(target, current) where current == token:
                state.phase = .focused(target: target)
            case let .switching(_, target, current) where current == token:
                state.phase = .focused(target: target)
            default:
                return []
            }
            state.keyboardFocus = .targetApplication
            state.trustedInteraction = nil
            // 键盘必须真的交给前台应用：域状态改了但不发 effect，NSWindow 会照常吃掉输入。
            let target = state.phase.controlledTarget
            if let pending = state.pendingTarget, pending != target {
                state.pendingTarget = nil
                return effects + beginSwitch(&state, from: target ?? pending, to: pending)
            }
            return effects

        case .collapseCompleted(let token):
            guard case let .collapsing(target, current) = state.phase, current == token else { return [] }
            _ = target
            state.phase = .overview
            state.keyboardFocus = .overview
            state.trustedInteraction = nil
            var effects: [SessionEffect] = [.setKeyboardFocus(.overview)]
            if state.isExitPending {
                state.isExitPending = false
                return effects + exitToHidden(&state)
            }
            if let pending = state.pendingTarget {
                state.pendingTarget = nil
                effects += beginExpand(&state, pending)
            }
            return effects

        case .restoreCompleted(let token):
            guard case let .recovering(current) = state.phase, current == token else { return [] }
            state.phase = .hidden
            state.isExitPending = false
            state.pendingTarget = nil
            state.transactions.removeAll()
            state.slots = SlotRegistry(capacity: state.slots.capacity, orderPreference: state.slots.orderPreference)
            return [.stopAllCapture, .hideOverview, .clearJournal(sessionID: state.sessionID), .cancelReconcile]

        case let .transitionTimedOut(token):
            switch state.phase {
            case let .expanding(target, current) where current == token:
                let appName = state.records[target]?.applicationName ?? "目标应用"
                let effects = beginCollapse(&state, target)
                return effects + [.presentHint(.transitionTimedOut(appName))]
            case let .collapsing(target, current) where current == token:
                // 恢复未确认：保留可重试记录并通知，不弹阻断操作的循环对话框。
                state.phase = .overview
                state.keyboardFocus = .overview
                state.trustedInteraction = nil
                let name = state.records[target]?.applicationName ?? "目标应用"
                return [.setKeyboardFocus(.overview), .presentHint(.restoreFailed(name))]
            case let .switching(_, target, current) where current == token:
                let name = state.records[target]?.applicationName ?? "目标应用"
                return beginCollapse(&state, target) + [.presentHint(.transitionTimedOut(name))]
            case let .recovering(current) where current == token:
                state.phase = .hidden
                state.isExitPending = false
                return [.stopAllCapture, .hideOverview, .cancelReconcile, .presentHint(.restoreFailed("会话恢复"))]
            default:
                return []
            }

        case let .catalogUpdated(records, generation, reason):
            return mergeCatalog(&state, records: records, generation: generation, reason: reason)

        case let .captureStarted(identity, generation):
            guard var record = state.records[identity], generation == record.sessionGeneration else { return [] }
            record.capture = .starting(generation: generation)
            state.records[identity] = record
            return []

        case let .captureFirstFrame(identity, date):
            guard var record = state.records[identity] else { return [] }
            record.capture = record.isMinimized ? .pausedMinimized : .live
            record.lastValidFrameDate = date
            state.records[identity] = record
            return []

        case let .captureStreamFailed(identity, reason):
            guard var record = state.records[identity] else { return [] }
            record.capture = .notCapturable(reason)
            state.records[identity] = record
            return []

        case let .captureDowngraded(identity, intervalMilliseconds):
            guard var record = state.records[identity] else { return [] }
            record.capture = .lowFrequency(intervalMilliseconds: intervalMilliseconds)
            state.records[identity] = record
            return []

        case let .windowMinimized(identity, minimized):
            guard var record = state.records[identity] else { return [] }
            record.isMinimized = minimized
            record.capture = minimized ? .pausedMinimized : (record.capture == .pausedMinimized ? .idle : record.capture)
            state.records[identity] = record
            return []

        case let .windowGeometryChangedExternally(identity, frame, isUserAction):
            guard var record = state.records[identity] else { return [] }
            record.frame = frame
            state.records[identity] = record
            // 程序引起的 AX 通知不能当成用户修改；只有真正的用户操作才记录 override。
            if isUserAction, var transaction = state.transactions[identity], transaction.state.requiresRestore {
                transaction = transaction.withUserOverride(frame)
                state.transactions[identity] = transaction
            }
            return []

        case let .geometryWritten(identity, provisionalFrame, displayID):
            guard var transaction = state.transactions[identity] else { return [] }
            transaction = transaction.markingWritten(provisionalFrame: provisionalFrame, displayID: displayID)
            state.transactions[identity] = transaction
            return [.writeJournal(transaction)]

        case let .geometryVerified(identity, readBack):
            guard var transaction = state.transactions[identity] else { return [] }
            transaction = transaction.markingVerified(readBack: readBack,
                                                      provisionalFrame: transaction.lastProvisionalFrame ?? readBack,
                                                      tolerance: 2)
            state.transactions[identity] = transaction
            return [.writeJournal(transaction)]

        case let .geometryRestored(identity):
            guard var transaction = state.transactions[identity] else { return [] }
            transaction = transaction.markingRestored()
            state.transactions[identity] = transaction
            return [.dropJournal(identity)]

        case .reconcileTick:
            guard state.phase.isVisible, !state.isDiscoveryInFlight else { return [] }
            state.isDiscoveryInFlight = true
            return [.discover(generation: state.catalogGeneration, reason: .reconcile)]

        case .organizeRequested:
            state.slots.organize()
            let remaining = state.slots.pending.count
            return remaining > 0 ? [.presentHint(.newWindowsAvailable(remaining))] : []

        case let .searchChanged(query):
            state.searchQuery = query
            return []

        case let .cardDragged(from, to):
            state.slots.swap(from, to)
            return []

        case let .policyChanged(policy):
            state.policy = policy
            return []

        case let .settingsChanged(density):
            state.style = OverviewStyle.style(density)
            return []

        case .permissionRestored:
            // 回到引导态由宿主决定，状态机只保持 hidden 等待用户重新进入。
            return []

        case .restoreFailed(let token, let identity, let reason):
            guard case .recovering = state.phase, state.phase.token == token else { return [] }
            state.transactions[identity] = state.transactions[identity]?.markingFailed(reason)
            return [.presentHint(.restoreFailed(state.records[identity]?.applicationName ?? reason))]

        default:
            return []
        }
    }

    // MARK: - 具体转移

    private static func handleShortcut(_ state: inout SessionState) -> [SessionEffect] {
        switch state.phase {
        case .hidden:
            return openSession(&state)
        case .preparing:
            return exitToHidden(&state)
        case .overview:
            return exitToHidden(&state)
        case let .focused(target):
            return beginCollapse(&state, target)
        case let .expanding(target, _), let .collapsing(target, _):
            return beginCollapse(&state, target)
        case let .switching(_, target, _):
            return beginCollapse(&state, target)
        case .suspended:
            return [.presentHint(.permissionMissing(.screenRecording))]
        case .recovering:
            return []
        }
    }

    private static func openSession(_ state: inout SessionState) -> [SessionEffect] {
        state.sessionID = UUID()
        state.catalogGeneration += 1
        state.phase = .preparing
        state.keyboardFocus = .overview
        state.isDiscoveryInFlight = true
        state.isExitPending = false
        state.pendingTarget = nil
        state.transactions.removeAll()
        return [.discover(generation: state.catalogGeneration, reason: .shortcut),
                .scheduleReconcile(state.policy.reconcileInterval),
                .setKeyboardFocus(.overview)]
    }

    private static func handleTargetRequest(_ state: inout SessionState, _ identity: WindowIdentity) -> [SessionEffect] {
        switch state.phase {
        case .overview, .preparing:
            return beginExpand(&state, identity)
        case let .focused(current):
            if current == identity { return beginCollapse(&state, current) }
            // 默认：聚焦时点击背景卡片只回总览；开启直接切换才换窗口。
            if state.policy.backgroundClickSwitches { return beginSwitch(&state, from: current, to: identity) }
            return beginCollapse(&state, current)
        case let .expanding(current, _):
            guard identity != current else { return [] }
            state.pendingTarget = identity
            return []
        case let .switching(_, current, _):
            guard identity != current else { return [] }
            state.pendingTarget = identity
            return []
        case .collapsing:
            state.pendingTarget = identity
            return []
        case .hidden, .suspended, .recovering:
            return []
        }
    }

    private static func handleFocusLost(_ state: inout SessionState, _ origin: FocusLossOrigin) -> [SessionEffect] {
        switch origin {
        case let .internalInteraction(token):
            if state.trustedInteraction == token { state.trustedInteraction = nil }
            return []
        case let .otherApplication(bundleID):
            // 主动唤起受控目标应用不算外部离开。
            if let target = state.phase.controlledTarget,
               state.records[target]?.bundleID != nil,
               state.records[target]?.bundleID == bundleID {
                return []
            }
            // 内部点击背景也会切换前台应用，这属于正常返回总览，不能当成外部离开。
            guard state.trustedInteraction == nil else { return [] }
            guard state.phase.isVisible else { return [] }
            return exitToHidden(&state)
        case .commandTab, .dock, .unknown:
            guard state.phase.isVisible else { return [] }
            return exitToHidden(&state)
        }
    }

    private static func beginExpand(_ state: inout SessionState, _ target: WindowIdentity) -> [SessionEffect] {
        guard let record = state.records[target] else { return [.presentHint(.cannotLocateWindow)] }
        // 未确定唯一身份不得写 AX（方案 §7 不变量）。
        guard record.allowsAutoFocus else {
            return [.presentHint(record.confidence.isAmbiguous ? .ambiguousWindow : .cannotLocateWindow)]
        }
        let token = state.nextTransitionToken()
        var effects: [SessionEffect] = []
        if let transaction = ensureTransaction(&state, target: target) {
            effects.append(.writeJournal(transaction))
        }
        effects.append(.expand(target, token: token,
                               animationMS: state.policy.animationMS(isExpand: true, style: state.style)))
        state.phase = .expanding(target: target, token: token)
        state.keyboardFocus = .targetApplication
        state.trustedInteraction = nil
        // 展开开始就让出键盘：动画期间用户已经在往这个窗口里打字。
        effects.append(.setKeyboardFocus(.targetApplication))
        return effects
    }

    private static func beginCollapse(_ state: inout SessionState, _ target: WindowIdentity) -> [SessionEffect] {
        let token = state.nextTransitionToken()
        var effects: [SessionEffect] = []
        if state.transactions[target]?.state.requiresRestore == true {
            effects.append(.restoreGeometry(target, token: token))
        }
        effects.append(.collapse(target, token: token,
                                 animationMS: state.policy.animationMS(isExpand: false, style: state.style)))
        state.phase = .collapsing(target: target, token: token)
        return effects
    }

    private static func beginSwitch(_ state: inout SessionState, from: WindowIdentity, to: WindowIdentity) -> [SessionEffect] {
        guard state.records[to] != nil, state.records[to]?.allowsAutoFocus == true else {
            return beginCollapse(&state, from)
        }
        let token = state.nextTransitionToken()
        var effects: [SessionEffect] = []
        if state.transactions[from]?.state.requiresRestore == true {
            effects.append(.restoreGeometry(from, token: token))
        }
        if let transaction = ensureTransaction(&state, target: to) {
            effects.append(.writeJournal(transaction))
        }
        effects.append(.expand(to, token: token,
                               animationMS: state.policy.animationMS(isExpand: true, style: state.style)))
        state.phase = .switching(from: from, to: to, token: token)
        state.keyboardFocus = .targetApplication
        effects.append(.setKeyboardFocus(.targetApplication))
        return effects
    }

    /// 同一事务不能反复覆盖原 frame：已存在的未完成事务直接复用。
    private static func ensureTransaction(_ state: inout SessionState, target: WindowIdentity) -> WindowTransaction? {
        if let existing = state.transactions[target], existing.state.requiresRestore { return existing }
        guard let record = state.records[target] else { return nil }
        let transaction = WindowTransaction(sessionID: state.sessionID,
                                            identity: target,
                                            bundleID: record.bundleID,
                                            originalFrame: record.frame,
                                            originalDisplayID: record.displayID)
        state.transactions[target] = transaction
        return transaction
    }

    private static func exitToHidden(_ state: inout SessionState) -> [SessionEffect] {
        state.pendingTarget = nil
        state.trustedInteraction = nil
        if state.hasPendingGeometryRestore {
            let token = state.nextTransitionToken()
            state.isExitPending = true
            state.phase = .recovering(token: token)
            return [.cancelReconcile, .restoreAll(token: token)]
        }
        state.phase = .hidden
        state.isExitPending = false
        state.keyboardFocus = .none
        state.slots = SlotRegistry(capacity: state.slots.capacity, orderPreference: state.slots.orderPreference)
        state.transactions.removeAll()
        return [.cancelReconcile, .stopAllCapture, .hideOverview,
                .clearJournal(sessionID: state.sessionID), .setKeyboardFocus(.none)]
    }

    // MARK: - 目录合并

    private static func mergeCatalog(_ state: inout SessionState,
                                     records: [WindowRecord],
                                     generation: UInt64,
                                     reason: DiscoveryReason) -> [SessionEffect] {
        // 旧代际的发现结果不能复活已经过期的状态。
        guard generation >= state.catalogGeneration else { return [] }
        switch state.phase {
        case .hidden, .suspended, .recovering:
            return []
        default:
            break
        }
        state.isDiscoveryInFlight = false
        // 记录代次以目录为准：捕获启动/首帧回调要靠它判断是否仍然有效。
        state.catalogGeneration = max(state.catalogGeneration, generation)

        let incoming = Set(records.map { $0.identity })
        var newlyCapturable: [WindowIdentity] = []

        for record in records {
            if state.records[record.identity] == nil {
                state.slots.assign(record.identity, memoryKey: record.memoryKey)
            }
            // slot 不因标题更新或源窗口调整尺寸而改变。
            var merged = record
            merged.slot = state.slots.slot(for: record.identity)
            if let previous = state.records[record.identity] {
                merged.capture = merged.capture == .idle ? previous.capture : merged.capture
                merged.slot = previous.slot ?? merged.slot
            }
            state.records[record.identity] = merged
            if merged.slot != nil, merged.capture == .idle || merged.capture == .closed {
                newlyCapturable.append(record.identity)
            }
        }

        for identity in Array(state.records.keys) where !incoming.contains(identity) {
            // 关闭的窗口原 slot 成为占位，后面的窗口不依次前移。
            state.slots.release(identity)
            state.records.removeValue(forKey: identity)
        }

        var effects: [SessionEffect] = []
        switch state.phase {
        case .preparing:
            // 初次进入按已有记忆顺序，否则按应用分组 + 稳定发现顺序。
            state.slots.rebuild(from: records)
            let ordered = state.recordsInSlotOrder
            effects.append(.showOverview(displayID: ordered.first?.displayID))
            effects.append(.startCapture(ordered.map { $0.identity }, generation: generation))
            effects.append(.setKeyboardFocus(.overview))
            state.phase = .overview
            state.keyboardFocus = .overview
        case .overview, .focused, .expanding, .collapsing, .switching:
            // 总览显示期间行列结构冻结，只补充新发现的空 slot。
            if !newlyCapturable.isEmpty {
                effects.append(.startCapture(newlyCapturable, generation: generation))
            }
            let queued = state.slots.pending.count
            if queued > 0 { effects.append(.presentHint(.newWindowsAvailable(queued))) }
        default:
            break
        }
        if reason == .reconcile { state.isDiscoveryInFlight = false }
        return effects
    }
}
