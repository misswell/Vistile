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
            // 已在恢复中就不再叠加第二条恢复路径。
            guard state.phase != .hidden, state.recoveryDestination == nil else { return [] }
            return exitToHidden(&state)

        case let .permissionLost(kind):
            guard state.phase != .hidden, state.recoveryDestination == nil else { return [] }
            return recoverToHidden(&state, destination: .hiddenAfterPermissionLost(kind),
                                   hints: [.presentHint(.permissionMissing(kind))])

        case .screenLocked, .spaceChanged:
            // Space 切换与锁屏：停预览、隐藏总览、结束过渡、执行恢复，结束后落到 hidden（方案 §5.1、§12）。
            guard state.phase != .hidden, state.recoveryDestination == nil else { return [] }
            return recoverToHidden(&state, destination: .hidden)

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
            guard state.phase.isVisible, state.recoveryDestination == nil else { return [] }
            if state.hasPendingGeometryRestore { return recoverToHidden(&state, destination: .hidden) }
            return [startDiscoveryEffect(&state, reason: .displaysChanged)]

        default:
            return nil
        }
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

        case .openConditionsChanged(let conditions, let reopenIfReady):
            state.openConditions = conditions
            guard case .preparing = state.phase else { return [] }
            guard reopenIfReady else {
                // 条件回报说"不要自动打开"：留在隐藏态等用户再次调用。
                return closePreparingWithoutOpen(&state)
            }
            guard conditions.canOpen else {
                var effects = closePreparingWithoutOpen(&state)
                if let hint = conditions.blockingHint { effects.append(.presentHint(hint)) }
                return effects
            }
            return [startDiscoveryEffect(&state, reason: .shortcut),
                    .scheduleReconcile(state.policy.reconcileInterval)]

        case .catalogDiscoveryFailed(let request, let failure):
            guard state.isCurrentDiscovery(request) else { return [] }
            state.pendingDiscovery = nil
            state.consecutiveDiscoveryFailures += 1
            switch state.phase {
            case .preparing:
                // 无权限且目录为空不得无限留在 preparing（方案 §5.2）。
                var effects = closePreparingWithoutOpen(&state)
                effects.append(.presentHint(failure.hint))
                return effects
            default:
                guard state.consecutiveDiscoveryFailures >= SessionState.discoveryRetryLimit else { return [] }
                // 有界退避到期：保留卡片与最后一帧，把真实原因说出来。
                return [.presentHint(failure.hint)]
            }

        case .expandCompleted(let token):
            let effects: [SessionEffect] = [.setKeyboardFocus(.targetApplication)]
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

        case .geometryRestoreSettled(let token, let items):
            guard state.phase.token == token else { return [] }
            var effects: [SessionEffect] = []
            for item in items {
                guard var transaction = state.transactions[item.identity] else { continue }
                if item.outcome.isSettled {
                    transaction = transaction.markingSettled(item.outcome)
                    state.transactions[item.identity] = transaction
                    effects.append(.dropJournal(item.identity))
                } else {
                    transaction = transaction.markingFailed(item.outcome.message)
                    state.transactions[item.identity] = transaction
                    effects.append(.writeJournal(transaction))
                }
                if item.outcome.isFailure {
                    effects.append(.presentHint(.restoreFailed(item.applicationName)))
                }
            }
            return effects

        case .restoreCompleted(let token):
            guard case let .recovering(destination, current) = state.phase, current == token else { return [] }
            var effects = landHidden(&state, destination: destination)
            // 未成功的窗口必须继续留在 state 与 journal 里（方案 §6.4）。
            let unresolved = state.transactions.values.filter { $0.state.requiresRestore }
            let settled = state.transactions.values.filter { !$0.state.requiresRestore }.map(\.identity)
            for identity in settled { state.transactions.removeValue(forKey: identity) }
            effects.append(.clearJournal(sessionID: state.sessionID, settledIdentities: settled))
            if !unresolved.isEmpty { effects.append(.presentHint(.restoreIncomplete(unresolved.count))) }
            return effects

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
            case let .recovering(destination, current) where current == token:
                var effects = landHidden(&state, destination: destination)
                effects.append(.presentHint(.restoreFailed("会话恢复")))
                return effects
            default:
                return []
            }

        case let .catalogUpdated(request, records):
            return mergeCatalog(&state, request: request, records: records)

        case let .geometryWriteFinished(result):
            return applyWriteResult(&state, result)

        case let .journalWriteFailed(identity, reason):
            guard state.phase.controlledTarget == identity, state.phase.token != nil else { return [] }
            // 还没有任何 AX 写入：直接退回总览，事务原样保留给退出兜底核对。
            state.phase = .overview
            state.keyboardFocus = .overview
            state.pendingTarget = nil
            return [.setKeyboardFocus(.overview), .presentHint(.journalWriteFailed(reason))]

        case let .windowGeometryChangedExternally(identity, frame, source):
            guard var record = state.records[identity] else { return [] }
            record.frame = frame
            state.records[identity] = record
            // 只有确认是用户操作才记录 override；程序写入与"不确定"都不能当成用户改过。
            guard source.recordsUserOverride,
                  var transaction = state.transactions[identity],
                  transaction.state.requiresRestore else { return [] }
            transaction = transaction.withUserOverride(frame)
            state.transactions[identity] = transaction
            // state 改了但 journal 没同步，恢复执行器就读不到用户尺寸（方案 §6.5）。
            return [.writeJournal(transaction)]

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

        case .reconcileTick:
            guard state.phase.isVisible, !state.isDiscoveryInFlight, !state.isDiscoveryBudgetExhausted else { return [] }
            return [startDiscoveryEffect(&state, reason: .reconcile)]

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
            // 恢复权限本身不抢焦点：隐藏态只重新记录条件，用户再次调用才打开（方案 §5.1）。
            guard state.phase.isVisible else { return [.evaluateOpenConditions(reopenIfReady: false)] }
            return [startDiscoveryEffect(&state, reason: .permissionRestored)]

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
        case .recovering:
            return []
        }
    }

    /// 打开前先重新检查条件：录屏已授予才进入发现（方案 §5.1）。
    private static func openSession(_ state: inout SessionState) -> [SessionEffect] {
        state.sessionID = UUID()
        state.phase = .preparing
        state.keyboardFocus = .overview
        state.pendingTarget = nil
        state.isExitPending = false
        state.pendingDiscovery = nil
        state.consecutiveDiscoveryFailures = 0
        state.transactions.removeAll()
        return [.evaluateOpenConditions(reopenIfReady: true), .setKeyboardFocus(.overview)]
    }

    private static func closePreparingWithoutOpen(_ state: inout SessionState) -> [SessionEffect] {
        state.phase = .hidden
        state.keyboardFocus = .none
        state.isExitPending = false
        state.pendingTarget = nil
        state.pendingDiscovery = nil
        state.slots = SlotRegistry(capacity: state.slots.capacity, orderPreference: state.slots.orderPreference)
        return [.cancelReconcile, .hideOverview, .stopAllCapture, .setKeyboardFocus(.none)]
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
        case .hidden, .recovering:
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
        guard let display = targetDisplay(for: record, state: state) else {
            return [.presentHint(.displayUnavailable(record.applicationName))]
        }
        guard let planned = plannedFrame(for: record, display: display, state: state) else { return [] }
        let token = state.nextTransitionToken()
        var effects: [SessionEffect] = []
        // 修改意图先落盘，宿主确认写盘成功后才允许动 AX（方案 §6.2）。
        if let transaction = ensureTransaction(&state, target: target, planned: planned, displayID: display.id) {
            effects.append(.writeJournal(transaction))
        }
        effects.append(.expand(target, targetFrame: planned, token: token,
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
        guard let record = state.records[to],
              let display = targetDisplay(for: record, state: state),
              let planned = plannedFrame(for: record, display: display, state: state) else {
            return beginCollapse(&state, from)
        }
        let token = state.nextTransitionToken()
        var effects: [SessionEffect] = []
        if state.transactions[from]?.state.requiresRestore == true {
            effects.append(.restoreGeometry(from, token: token))
        }
        if let transaction = ensureTransaction(&state, target: to, planned: planned, displayID: display.id) {
            effects.append(.writeJournal(transaction))
        }
        effects.append(.expand(to, targetFrame: planned, token: token,
                               animationMS: state.policy.animationMS(isExpand: true, style: state.style)))
        state.phase = .switching(from: from, to: to, token: token)
        state.keyboardFocus = .targetApplication
        effects.append(.setKeyboardFocus(.targetApplication))
        return effects
    }

    /// 同一事务不能反复覆盖原 frame：已存在的未完成事务只更新计划目标。
    private static func ensureTransaction(_ state: inout SessionState,
                                          target: WindowIdentity,
                                          planned: CGRect,
                                          displayID: UInt32) -> WindowTransaction? {
        if let existing = state.transactions[target], existing.state.requiresRestore {
            let updated = existing.markingPlanned(frame: planned, displayID: displayID)
            state.transactions[target] = updated
            return updated
        }
        guard let record = state.records[target] else { return nil }
        let transaction = WindowTransaction(sessionID: state.sessionID,
                                            identity: target,
                                            bundleID: record.bundleID,
                                            originalFrame: record.frame,
                                            originalDisplayID: record.displayID)
            .markingPlanned(frame: planned, displayID: displayID)
        state.transactions[target] = transaction
        return transaction
    }

    private static func targetDisplay(for record: WindowRecord, state: SessionState) -> DisplayInfo? {
        state.displays.first { $0.id == record.displayID } ?? state.displays.first { $0.isPrimary } ?? state.displays.first
    }

    /// 目标 frame 在核心层算一次：日志里的计划与实际写入的必须是同一个值。
    private static func plannedFrame(for record: WindowRecord, display: DisplayInfo, state: SessionState) -> CGRect? {
        guard display.visibleFrame.width > 0, display.visibleFrame.height > 0 else { return nil }
        return FocusGeometry.targetRect(visibleFrame: display.visibleFrame,
                                       policy: state.policy,
                                       currentSize: record.frame.size,
                                       isResizable: record.allowsGeometryControl)
    }

    /// 恢复/退出/中断的唯一收口：有待恢复事务就走 recovering，没有就直接落 hidden（方案 §5.1）。
    private static func recoverToHidden(_ state: inout SessionState,
                                       destination: RecoveryDestination,
                                       hints: [SessionEffect] = []) -> [SessionEffect] {
        state.pendingTarget = nil
        state.trustedInteraction = nil
        state.pendingDiscovery = nil
        let identities = state.transactions.values.filter { $0.state.requiresRestore }
            .sorted { $0.created < $1.created }.map(\.identity)
        var effects: [SessionEffect] = [.cancelReconcile, .hideOverview, .stopAllCapture]
        guard !identities.isEmpty else {
            state.phase = .hidden
            state.isExitPending = false
            state.keyboardFocus = .none
            state.slots = SlotRegistry(capacity: state.slots.capacity, orderPreference: state.slots.orderPreference)
            let settled = state.transactions.values.filter { !$0.state.requiresRestore }.map(\.identity)
            for identity in settled { state.transactions.removeValue(forKey: identity) }
            effects.append(.clearJournal(sessionID: state.sessionID, settledIdentities: settled))
            effects.append(.setKeyboardFocus(.none))
            return effects + hints
        }
        let token = state.nextTransitionToken()
        state.isExitPending = true
        state.keyboardFocus = .none
        state.phase = .recovering(destination: destination, token: token)
        effects.append(.setKeyboardFocus(.none))
        effects.append(.restoreAll(token: token, identities: identities))
        return effects + hints
    }

    private static func exitToHidden(_ state: inout SessionState) -> [SessionEffect] {
        recoverToHidden(&state, destination: .hidden)
    }

    /// 恢复批次结束（成功或超时）后落到隐藏态。
    private static func landHidden(_ state: inout SessionState, destination: RecoveryDestination) -> [SessionEffect] {
        state.phase = .hidden
        state.isExitPending = false
        state.pendingTarget = nil
        state.pendingDiscovery = nil
        state.keyboardFocus = .none
        state.slots = SlotRegistry(capacity: state.slots.capacity, orderPreference: state.slots.orderPreference)
        var effects: [SessionEffect] = [.cancelReconcile, .stopAllCapture, .hideOverview, .setKeyboardFocus(.none)]
        if case let .hiddenAfterPermissionLost(kind) = destination {
            effects.append(.presentHint(.permissionMissing(kind)))
        }
        return effects
    }

    // MARK: - 写入结果

    private static func applyWriteResult(_ state: inout SessionState,
                                         _ result: GeometryWriteResult) -> [SessionEffect] {
        guard var transaction = state.transactions[result.identity] else { return [] }
        guard state.phase.token == result.token else {
            // 过期结果不改状态：宿主必须已经做了补偿恢复。
            return []
        }
        switch result.outcome {
        case let .exact(readBack):
            transaction = transaction.markingVerified(readBack: readBack, displayID: result.displayID)
        case let .constrained(readBack):
            transaction = transaction.markingWritten(readBack: readBack, displayID: result.displayID,
                                                     note: result.outcome.message)
        case .rejected, .unreadable:
            transaction = transaction.markingWriteFailed(result.outcome.message)
        case .targetGone:
            state.transactions.removeValue(forKey: result.identity)
            return [.dropJournal(result.identity), .presentHint(.cannotLocateWindow)]
        }
        state.transactions[result.identity] = transaction
        return [.writeJournal(transaction)]
    }

    // MARK: - 目录合并

    private static func startDiscoveryEffect(_ state: inout SessionState,
                                             reason: DiscoveryReason) -> SessionEffect {
        .discover(request: state.nextDiscoveryRequest(reason: reason))
    }

    private static func mergeCatalog(_ state: inout SessionState,
                                     request: DiscoveryRequest,
                                     records: [WindowRecord]) -> [SessionEffect] {
        // 旧会话或旧请求的结果一律丢弃：只看可增长的 generation 不足以判定异步有效性（方案 §5.2）。
        guard state.isCurrentDiscovery(request) else { return [] }
        switch state.phase {
        case .hidden, .recovering:
            state.pendingDiscovery = nil
            return []
        default:
            break
        }
        state.pendingDiscovery = nil
        state.consecutiveDiscoveryFailures = 0
        state.catalogGeneration = max(state.catalogGeneration, request.generation)

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
            effects.append(.startCapture(ordered.map { $0.identity }, generation: request.generation))
            effects.append(.setKeyboardFocus(.overview))
            state.phase = .overview
            state.keyboardFocus = .overview
        case .overview, .focused, .expanding, .collapsing, .switching:
            // 总览显示期间行列结构冻结，只补充新发现的空 slot。
            if !newlyCapturable.isEmpty {
                effects.append(.startCapture(newlyCapturable, generation: request.generation))
            }
            let queued = state.slots.pending.count
            if queued > 0 { effects.append(.presentHint(.newWindowsAvailable(queued))) }
        default:
            break
        }
        return effects
    }
}
