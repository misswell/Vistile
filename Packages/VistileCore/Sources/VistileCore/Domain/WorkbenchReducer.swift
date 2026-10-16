import Foundation
import CoreGraphics

/// 工作台状态逻辑（方案 §7）：由唯一 SessionReducer 调用的纯逻辑层，不独立执行 AX。
/// 处理"总览↔工作台"模式过渡、轨道占用、A/B 交换的提交点；
/// 认不出的（或不在工作台情境的）事件返回 nil，交回 SessionReducer 既有逻辑。
public enum WorkbenchReducer {

    // MARK: - 事件入口

    static func reduce(_ state: inout SessionState, _ event: SessionEvent) -> [SessionEffect]? {
        // 会话不可见（隐藏/恢复中）时工作台事件一律不认领：旧完成回调不能复活工作台（方案 §4.5、§10.5）。
        guard state.phase.isVisible else { return nil }
        switch event {
        case let .overviewCardSelected(identity, _, _):
            return beginEnterWorkbench(&state, identity: identity)
        case let .railCardSelected(slot, identity):
            return beginRailSelection(&state, slot: slot, identity: identity)
        case let .railCardDragged(from, to):
            return handleRailDrag(&state, from: from, to: to)
        case let .railScrolled(rail, offset):
            return handleRailScroll(&state, rail: rail, offset: offset)
        case let .railSideChanged(side):
            return handleSideChanged(&state, side: side)
        case .returnToOverviewRequested:
            return beginReturnOverview(&state)
        case let .workbenchTransitionFinished(token, kind, result):
            return finishModeTransition(&state, token: token, kind: kind, result: result)
        case let .mainSwitchStepFinished(result):
            return recordSwitchStep(&state, result)
        case let .mainSwitchCommitted(token):
            return commitMainSwitch(&state, token: token)
        case let .mainSwitchFailed(token, reason):
            return failMainSwitch(&state, token: token, reason: reason)
        case let .workbenchRailSizePreview(topHeight, sideWidth):
            return handleRailSizePreview(&state, topHeight: topHeight, sideWidth: sideWidth)
        case let .workbenchRailSizeChanged(topHeight, sideWidth):
            return handleRailSizeChanged(&state, topHeight: topHeight, sideWidth: sideWidth)
        case let .workbenchSearchFocusChanged(focused):
            return handleSearchFocus(&state, focused: focused)
        case let .geometryWriteFinished(result):
            guard let pending = state.workbench.mainFrameWrite,
                  pending.token == result.token, pending.identity == result.identity else { return nil }
            return applyMainFrameResult(&state, result)
        case let .transitionTimedOut(token):
            guard isWorkbenchToken(state, token) else { return nil }
            return handleTimeout(&state, token: token)
        default:
            break
        }

        guard isEngaged(state) else { return nil }
        switch event {
        case let .backgroundClicked(interaction):
            // 点击栏内空白：保持主窗口与模式，只登记可信交互，不收起、不穿透（方案 §7.2）。
            state.trustedInteraction = interaction
            return []
        case .cardClicked, .expandRequested:
            // 工作台里的卡片选择必须走 railCardSelected；旧展开路径不能在这里复活。
            return []
        case .escapePressed:
            return handleEscape(&state)
        case .globalShortcut, .returnShortcut:
            // 任意可见的工作台形态 → 隐藏并恢复（方案 §4.5）。
            state.pendingTarget = nil
            return SessionReducer.exitToHidden(&state)
        case .organizeRequested:
            return organizeRail(&state)
        default:
            return nil
        }
    }

    /// 工作台事件占据中：模式已完成切换，或正在模式过渡。
    private static func isEngaged(_ state: SessionState) -> Bool {
        state.mode == .workbench || state.workbench.modeTransition.isTransitioning
    }

    /// 令牌只对工作台自己的过渡/交换有效，否则交回既有超时逻辑。
    private static func isWorkbenchToken(_ state: SessionState, _ token: TransitionToken) -> Bool {
        if state.workbench.modeTransition.token == token { return true }
        if state.workbench.mainSwitch.intent?.token == token { return true }
        return state.workbench.mainFrameWrite?.token == token
    }

    // MARK: - 总览 → 工作台（方案 §4.2）

    private static func beginEnterWorkbench(_ state: inout SessionState, identity: WindowIdentity) -> [SessionEffect] {
        // 只在总览落地态、且没有进行中的工作台动作时开始；未点击前绝不改真实窗口（方案 §4.1）。
        guard state.mode == .overview, case .overview = state.phase,
              state.workbench.modeTransition == .idle else { return [] }
        guard let record = state.records[identity] else { return [.presentHint(.cannotLocateWindow)] }
        guard record.allowsAutoFocus else {
            return [.presentHint(record.confidence.isAmbiguous ? .ambiguousWindow : .cannotLocateWindow)]
        }
        guard let display = workbenchDisplay(state, identity: identity, record: record) else {
            return [.presentHint(.displayUnavailable(record.applicationName))]
        }
        guard let baseLayout = workbenchLayout(for: display, state: state) else {
            return [.presentHint(.displayUnavailable(record.applicationName))]
        }
        // 本次进入后的轨道占用：只用于动画端点与展示事实；placement 在过渡成功后才提交。
        var prospective = state.workbench.placement
        let layout = initializeRailOccupants(&prospective, state: state, target: identity, layout: baseLayout)
        let snapshot = WorkbenchLayoutSnapshot(displayID: display.id,
                                               layout: layout,
                                               topScrollOffset: 0,
                                               sideScrollOffset: 0,
                                               revision: state.workbench.layoutRevision + 1)

        let token = state.nextTransitionToken()
        let targetFrame = FocusGeometry.dockedRect(in: layout.mainRect,
                                                   currentSize: record.frame.size,
                                                   isResizable: record.allowsGeometryControl)
        var effects: [SessionEffect] = []
        // 写前事务早于任何 AX 写入（方案 §6.2）。
        if let transaction = SessionReducer.ensureTransaction(&state, target: identity,
                                                              planned: targetFrame, displayID: display.id) {
            effects.append(.writeJournal(transaction))
        }
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           identity: identity,
                                           displayID: display.id,
                                           snapshot: snapshot,
                                           targetFrame: targetFrame,
                                           animationFrom: state.cellRect(for: identity),
                                           animationTo: targetFrame,
                                           railHandoffs: railHandoffs(state, snapshot: snapshot,
                                                                      placement: prospective,
                                                                      excluding: identity, entering: true),
                                           animationMS: layout.style.entryAnimationMS(reduceMotion: state.policy.reduceMotion),
                                           presentation: WorkbenchPresenter.make(state: state,
                                                                                 snapshot: snapshot,
                                                                                 placement: prospective))
        state.workbench.modeTransition = .enteringWorkbench(token: token, target: identity)
        state.workbench.snapshot = snapshot
        state.workbench.layoutRevision = snapshot.revision
        state.phase = .expanding(target: identity, token: token)
        // 键盘在模式落地且真实窗口可用后才移交（方案 §10.1）；期间仍由总览持有。
        effects.append(.enterWorkbench(plan))
        return effects
    }

    private static func finishModeTransition(_ state: inout SessionState,
                                             token: TransitionToken,
                                             kind: WorkbenchTransitionKind,
                                             result: WorkbenchStepOutcome) -> [SessionEffect] {
        switch kind {
        case .enteringWorkbench:
            guard case let .enteringWorkbench(current, target) = state.workbench.modeTransition,
                  current == token else { return [] }
            state.workbench.modeTransition = .idle
            guard result.allowsContinue, state.records[target] != nil,
                  let snapshot = state.workbench.snapshot else {
                // 失败留在原总览：不提交 placement、不留下半套轨道（方案 §4.2.7）。
                state.workbench.snapshot = nil
                state.phase = .overview
                state.keyboardFocus = .overview
                return [.cancelWorkbenchTransition, .hideWorkbench, .setKeyboardFocus(.overview),
                        .presentHint(.workbenchTransitionFailed(result.message))]
            }
            var placement = state.workbench.placement
            let extended = initializeRailOccupants(&placement, state: state, target: target, layout: snapshot.layout)
            state.workbench.placement = placement
            if extended != snapshot.layout {
                let updated = snapshot.replacing(layout: extended, revision: state.workbench.layoutRevision + 1)
                state.workbench.snapshot = updated
                state.workbench.layoutRevision = updated.revision
            }
            state.workbench.activeDisplayID = snapshot.displayID
            state.workbench.lastSelectedMain = target
            state.mode = .workbench
            state.phase = .focused(target: target)
            state.keyboardFocus = .targetApplication
            return [.setKeyboardFocus(.targetApplication),
                    .updateWorkbenchLayout(WorkbenchPresenter.make(state: state,
                                                                   snapshot: state.workbench.snapshot ?? snapshot,
                                                                   placement: state.workbench.placement))]

        case .returningOverview:
            guard case let .returningOverview(current) = state.workbench.modeTransition,
                  current == token else { return [] }
            state.workbench.modeTransition = .idle
            let main = state.workbench.placement.main
            if !result.allowsContinue, let main, state.records[main] != nil {
                // 返回失败：留在工作台，主窗口恢复可操作（方案 §8.3、§10.2）。
                state.phase = .focused(target: main)
                state.keyboardFocus = .targetApplication
                return [.cancelWorkbenchTransition, .setKeyboardFocus(.targetApplication),
                        .presentHint(.workbenchTransitionFailed(result.message))]
            }
            // 成功：L 型上下文保存下来（occupants/side/scroll/偏好），activeMain 归零（方案 §4.4）。
            state.mode = .overview
            state.workbench.placement.setMain(nil)
            state.phase = .overview
            state.keyboardFocus = .overview
            return [.setKeyboardFocus(.overview), .hideWorkbench, .showOverview(displayID: nil)]
        }
    }

    // MARK: - 工作台 → 总览（方案 §4.4）

    private static func beginReturnOverview(_ state: inout SessionState) -> [SessionEffect] {
        guard state.mode == .workbench else { return [] }
        guard state.workbench.modeTransition == .idle else { return [] }
        if state.workbench.mainSwitch.isBusy {
            // 交换进行中：记住意图，等这次收敛后再回总览（方案 §4.5、§7.2）。
            state.workbench.pendingReturnToOverview = true
            state.workbench.pendingRailSelection = nil
            return []
        }
        guard let snapshot = state.workbench.snapshot else { return [] }
        guard let main = state.workbench.placement.main, let record = state.records[main] else {
            // 没有主窗口：没有真实几何要动，直接落回总览。
            state.mode = .overview
            state.workbench.placement.setMain(nil)
            state.phase = .overview
            state.keyboardFocus = .overview
            return [.setKeyboardFocus(.overview), .hideWorkbench, .showOverview(displayID: nil)]
        }
        let token = state.nextTransitionToken()
        let targetFrame = state.transactions[main]?.restoreTargetFrame(preserveUserGeometry: state.policy.preserveUserGeometry)
            ?? record.frame
        var effects: [SessionEffect] = []
        if var transaction = state.transactions[main] {
            transaction = transaction.markingPlanned(frame: targetFrame, displayID: transaction.originalDisplayID)
            state.transactions[main] = transaction
            effects.append(.writeJournal(transaction))
        }
        let plan = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: token,
                                           identity: main,
                                           displayID: snapshot.displayID,
                                           snapshot: snapshot,
                                           targetFrame: targetFrame,
                                           animationFrom: snapshot.layout.mainRect,
                                           animationTo: state.cellRect(for: main),
                                           railHandoffs: railHandoffs(state, snapshot: snapshot,
                                                                      placement: state.workbench.placement,
                                                                      excluding: main, entering: false),
                                           animationMS: snapshot.layout.style.returnAnimationMS(reduceMotion: state.policy.reduceMotion),
                                           presentation: WorkbenchPresenter.make(state: state,
                                                                                  snapshot: snapshot,
                                                                                  placement: state.workbench.placement))
        state.workbench.modeTransition = .returningOverview(token: token)
        state.phase = .collapsing(target: main, token: token)
        effects.append(.returnToOverview(plan))
        return effects
    }

    // MARK: - 轨道选择与 A/B 交换（方案 §4.3、§8）

    private static func beginRailSelection(_ state: inout SessionState,
                                           slot: RailSlotID,
                                           identity: WindowIdentity) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle else { return [] }
        // 事实对不上（占用已变化）就不写几何；以 placement 为准。
        guard state.workbench.placement.occupant(at: slot) == identity else { return [] }
        guard state.workbench.placement.main != identity else { return [] }
        if state.workbench.mainSwitch.isBusy {
            // 交换进行中：只保存最新目标，前一次收敛后再处理（方案 §7.2、§10.4）。后到的点击覆盖先前意图。
            state.workbench.pendingRailSelection = WorkbenchPendingSelection(identity: identity, slot: slot)
            state.workbench.pendingReturnToOverview = false
            return []
        }
        return startSwitch(&state, to: identity, slot: slot)
    }

    private static func startSwitch(_ state: inout SessionState,
                                    to identity: WindowIdentity,
                                    slot: RailSlotID) -> [SessionEffect] {
        guard let record = state.records[identity] else { return [.presentHint(.cannotLocateWindow)] }
        guard record.allowsAutoFocus else {
            return [.presentHint(record.confidence.isAmbiguous ? .ambiguousWindow : .cannotLocateWindow)]
        }
        guard let snapshot = state.workbench.snapshot else { return [] }
        let placement = state.workbench.placement
        let token = state.nextTransitionToken()
        let mainTarget = FocusGeometry.dockedRect(in: snapshot.layout.mainRect,
                                                  currentSize: record.frame.size,
                                                  isResizable: record.allowsGeometryControl)
        // 旧主（若存在）回到它的 resting frame：原始尺寸或用户明确保留的尺寸（方案 §8.1）。
        var restingTarget: CGRect?
        if let from = placement.main, let fromRecord = state.records[from] {
            restingTarget = state.transactions[from]?
                .restoreTargetFrame(preserveUserGeometry: state.policy.preserveUserGeometry)
                ?? fromRecord.frame
        }
        let intent = WorkbenchSwitchIntent(token: token,
                                           from: placement.main,
                                           to: identity,
                                           source: .rail(slot: slot),
                                           placementRevision: placement.revision,
                                           targetDisplayID: snapshot.displayID)
        var effects: [SessionEffect] = []
        // 写前事务：B 的目标是主区；A 的目标是它的回落点。都先落盘再动 AX（方案 §8.2.3）。
        if let transaction = SessionReducer.ensureTransaction(&state, target: identity,
                                                              planned: mainTarget, displayID: snapshot.displayID) {
            effects.append(.writeJournal(transaction))
        }
        if let from = placement.main, let restingTarget, var transaction = state.transactions[from] {
            transaction = transaction.markingPlanned(frame: restingTarget,
                                                     displayID: transaction.originalDisplayID)
            state.transactions[from] = transaction
            effects.append(.writeJournal(transaction))
        }
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: snapshot.displayID,
                                       mainTargetFrame: mainTarget,
                                       restingTargetFrame: restingTarget,
                                       restingSlot: slot,
                                       snapshot: snapshot,
                                       presentation: WorkbenchPresenter.make(state: state,
                                                                              snapshot: snapshot,
                                                                              placement: placement))
        state.workbench.mainSwitch = .switching(intent: intent, step: .prepare)
        if let from = placement.main {
            state.phase = .switching(from: from, to: identity, token: token)
        } else {
            state.phase = .focused(target: identity)
        }
        effects.append(.beginMainSwitch(plan))
        return effects
    }

    private static func recordSwitchStep(_ state: inout SessionState,
                                         _ result: WorkbenchSwitchStepResult) -> [SessionEffect] {
        guard case let .switching(intent, _) = state.workbench.mainSwitch,
              intent.token == result.token else { return [] }
        guard result.outcome.allowsContinue else {
            // 失败：宿主按逆序补偿；补偿完成前不提交 placement（方案 §8.3）。
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: result.outcome.message)
            return []
        }
        state.workbench.mainSwitch = .switching(intent: intent, step: nextStep(after: result.step))
        return []
    }

    private static func commitMainSwitch(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        guard let intent = state.workbench.mainSwitch.intent, intent.token == token else { return [] }
        var placement = state.workbench.placement
        let target = intent.to
        var effects: [SessionEffect] = []
        if let from = intent.from, state.records[from] != nil, placement.main == from,
           let slot = intent.railSlot, placement.occupant(at: slot) == target {
            // 正常提交：只有 main 与 sourceSlot 两处改变（方案 §6.1）。
            placement.swapMain(with: slot)
        } else if intent.from == nil || state.records[intent.from!] == nil {
            // 没有旧主，或旧主已在途中关闭：B 进主区，原 slot 由 setMain 让空（方案 §8.3）。
            placement.setMain(target)
        } else {
            // 事实已变化：不假提交，也不动已写入的窗口（方案 §8.3）。
            let reason = "轨道占用已变化，未提交交换"
            state.workbench.mainSwitch = .failed(intent: intent, reason: reason)
            state.workbench.pendingRailSelection = nil
            if let main = placement.main { state.phase = .focused(target: main) }
            return [.presentHint(.workbenchSwitchFailed(reason))]
        }
        state.workbench.placement = placement
        state.workbench.lastSelectedMain = target
        state.workbench.mainSwitch = .idle
        state.phase = .focused(target: target)
        state.keyboardFocus = .targetApplication
        effects.append(.setKeyboardFocus(.targetApplication))
        effects.append(contentsOf: layoutEffects(state))
        // latest-wins：前一次已经收敛，现在处理等着的最后意图（方案 §10.4）。
        if state.workbench.pendingReturnToOverview {
            state.workbench.pendingReturnToOverview = false
            effects.append(contentsOf: beginReturnOverview(&state))
        } else if let pending = state.workbench.pendingRailSelection {
            state.workbench.pendingRailSelection = nil
            if pending.identity != target {
                effects.append(contentsOf: startSwitch(&state, to: pending.identity, slot: pending.slot))
            }
        }
        return effects
    }

    private static func failMainSwitch(_ state: inout SessionState,
                                       token: TransitionToken,
                                       reason: String) -> [SessionEffect] {
        guard let intent = state.workbench.mainSwitch.intent, intent.token == token else { return [] }
        state.workbench.mainSwitch = .failed(intent: intent, reason: reason)
        state.workbench.pendingRailSelection = nil
        var effects: [SessionEffect] = [.presentHint(.workbenchSwitchFailed(reason))]
        if let main = state.workbench.placement.main, state.records[main] != nil {
            state.phase = .focused(target: main)
            state.keyboardFocus = .targetApplication
            effects.insert(.setKeyboardFocus(.targetApplication), at: 0)
        } else {
            state.phase = .overview
            state.keyboardFocus = .overview
            effects.insert(.setKeyboardFocus(.overview), at: 0)
        }
        effects.append(contentsOf: layoutEffects(state))
        // 失败回滚完成后，等着的「全部窗口」意图仍然有效（方案 §4.5）。
        if state.workbench.pendingReturnToOverview {
            state.workbench.pendingReturnToOverview = false
            effects.append(contentsOf: beginReturnOverview(&state))
        }
        return effects
    }

    private static func nextStep(after step: WorkbenchSwitchStep) -> WorkbenchSwitchStep {
        let all = WorkbenchSwitchStep.allCases
        guard let index = all.firstIndex(of: step), index + 1 < all.count else { return .commit }
        return all[index + 1]
    }

    // MARK: - 轨道交互

    private static func handleRailDrag(_ state: inout SessionState,
                                       from: RailSlotID,
                                       to: RailSlotID) -> [SessionEffect] {
        guard state.mode == .workbench, !state.workbench.mainSwitch.isBusy,
              state.workbench.modeTransition == .idle else { return [] }
        var placement = state.workbench.placement
        guard placement.swapSlots(from, to) else { return [] }
        state.workbench.placement = placement
        return layoutEffects(state)
    }

    private static func handleRailScroll(_ state: inout SessionState,
                                         rail: RailKind,
                                         offset: CGFloat) -> [SessionEffect] {
        guard state.mode == .workbench, let snapshot = state.workbench.snapshot else { return [] }
        let clamped = snapshot.clampedScroll(rail: rail, offset: offset)
        guard clamped != state.workbench.scrollOffset(rail: rail) else { return [] }
        state.workbench.snapshot = snapshot.scrolling(rail: rail, to: clamped)
        state.workbench.scroll(rail: rail, offset: clamped)
        return layoutEffects(state)
    }

    private static func handleSideChanged(_ state: inout SessionState, side: RailSide) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy else { return [] }
        guard state.workbench.side != side, let snapshot = state.workbench.snapshot,
              let display = state.displays.first(where: { $0.id == snapshot.displayID }) else { return [] }
        state.workbench.side = side
        guard let layout = workbenchLayout(for: display, state: state) else { return [] }
        let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
        state.workbench.snapshot = updated
        state.workbench.layoutRevision = updated.revision
        var effects: [SessionEffect] = layoutEffects(state)
        // 主区镜像后主窗口必须跟着走：不改变 placement，但写真实几何并读回（方案 §5.1、§11）。
        effects.append(contentsOf: settleMain(&state, snapshot: updated))
        return effects
    }

    /// 拖动中的实时预览：只改本机投影（方案 §11.2）。节流后的写入与松手后的最终读回
    /// 都走 handleRailSizeChanged——只有那条路径会 settleMain 并留下事务记录。
    private static func handleRailSizePreview(_ state: inout SessionState,
                                              topHeight: CGFloat?,
                                              sideWidth: CGFloat?) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy else { return [] }
        guard applyRailSize(&state, topHeight: topHeight, sideWidth: sideWidth) != nil else { return [] }
        return layoutEffects(state)
    }

    private static func handleRailSizeChanged(_ state: inout SessionState,
                                              topHeight: CGFloat?,
                                              sideWidth: CGFloat?) -> [SessionEffect] {
        guard state.mode == .workbench, state.workbench.modeTransition == .idle,
              !state.workbench.mainSwitch.isBusy else { return [] }
        guard let updated = applyRailSize(&state, topHeight: topHeight, sideWidth: sideWidth) else { return [] }
        var effects: [SessionEffect] = layoutEffects(state)
        // 松手后的最终读回由 settleMain 收口，拖动中的节流写入由宿主做（方案 §11.2）。
        effects.append(contentsOf: settleMain(&state, snapshot: updated))
        return effects
    }

    /// 两条栏尺寸偏好落进状态并重算冻结投影；算不出新布局（没有 snapshot/屏幕已不在）返回 nil。
    /// nil = 这一维没有新偏好：两条分隔线是独立拖动的，不能顺手清掉另一维（方案 §11.2）。
    private static func applyRailSize(_ state: inout SessionState,
                                      topHeight: CGFloat?,
                                      sideWidth: CGFloat?) -> WorkbenchLayoutSnapshot? {
        if let topHeight { state.workbench.topHeightPreference = topHeight }
        if let sideWidth { state.workbench.sideWidthPreference = sideWidth }
        guard let snapshot = state.workbench.snapshot,
              let display = state.displays.first(where: { $0.id == snapshot.displayID }),
              let layout = workbenchLayout(for: display, state: state) else { return nil }
        let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
        state.workbench.snapshot = updated
        state.workbench.layoutRevision = updated.revision
        return updated
    }

    private static func organizeRail(_ state: inout SessionState) -> [SessionEffect] {
        guard state.mode == .workbench, !state.workbench.mainSwitch.isBusy,
              state.workbench.modeTransition == .idle,
              let snapshot = state.workbench.snapshot,
              !state.workbench.placement.occupants.isEmpty else { return [] }
        var placement = state.workbench.placement
        let memoryKeys = Dictionary(uniqueKeysWithValues: state.records.map { ($0.key, $0.value.memoryKey) })
        var layout = snapshot.layout
        placement.reorganize(slotOrder: extendedSlotOrder(layout: layout,
                                                          needed: placement.occupants.count),
                             memoryKeys: memoryKeys)
        state.workbench.placement = placement
        // 整理后可能用到了可见容量之外的 slot：内容轨道必须同步延长，否则那些窗口滚不到。
        layout = layout.extending(sideSlots: maxSideOrdinal(placement) + 1)
        if layout != snapshot.layout {
            let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
            state.workbench.snapshot = updated
            state.workbench.layoutRevision = updated.revision
        }
        return layoutEffects(state)
    }

    private static func handleSearchFocus(_ state: inout SessionState, focused: Bool) -> [SessionEffect] {
        guard state.mode == .workbench else { return [] }
        if focused {
            state.keyboardFocus = .railSearch
            return []
        }
        guard state.keyboardFocus == .railSearch else { return [] }
        state.keyboardFocus = .targetApplication
        return [.setKeyboardFocus(.targetApplication)]
    }

    /// Esc（方案 §4.5）：过渡中 → 安全退出；搜索 → 关搜索还焦点；主应用 → 原样交给应用。
    private static func handleEscape(_ state: inout SessionState) -> [SessionEffect] {
        if state.workbench.modeTransition.isTransitioning || state.workbench.mainSwitch.isBusy {
            state.pendingTarget = nil
            return SessionReducer.exitToHidden(&state)
        }
        switch state.keyboardFocus {
        case .targetApplication:
            return []
        case .railSearch:
            state.searchQuery = ""
            state.keyboardFocus = .targetApplication
            return [.setKeyboardFocus(.targetApplication)]
        case .overview, .none:
            return SessionReducer.exitToHidden(&state)
        }
    }

    // MARK: - 超时（方案 §10.5、§8.3）

    private static func handleTimeout(_ state: inout SessionState, token: TransitionToken) -> [SessionEffect] {
        if state.workbench.modeTransition.token == token {
            let kind = state.workbench.modeTransition
            state.workbench.modeTransition = .idle
            if case .enteringWorkbench = kind {
                state.workbench.snapshot = nil
                state.phase = .overview
                state.keyboardFocus = .overview
                return [.cancelWorkbenchTransition, .hideWorkbench, .setKeyboardFocus(.overview),
                        .presentHint(.workbenchTransitionFailed("进入工作台超时，已留在总览"))]
            }
            if let main = state.workbench.placement.main, state.records[main] != nil {
                state.phase = .focused(target: main)
                state.keyboardFocus = .targetApplication
                return [.cancelWorkbenchTransition, .setKeyboardFocus(.targetApplication),
                        .presentHint(.workbenchTransitionFailed("返回总览超时，仍在工作台"))]
            }
            state.phase = .overview
            return [.cancelWorkbenchTransition, .presentHint(.workbenchTransitionFailed("返回总览超时"))]
        }
        if let intent = state.workbench.mainSwitch.intent, intent.token == token {
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "交换超时")
            // 补偿由宿主串行执行器完成，完成后回报 mainSwitchFailed。
            return []
        }
        if state.workbench.mainFrameWrite?.token == token {
            state.workbench.mainFrameWrite = nil
            return [.presentHint(.workbenchMainFrameFailed("主窗口未在期限内完成调整"))]
        }
        return []
    }

    // MARK: - 主窗口几何微调

    /// 布局变化后把真实主窗口带到新的 mainRect：不改变 placement，只更新事务计划（方案 §11）。
    private static func settleMain(_ state: inout SessionState, snapshot: WorkbenchLayoutSnapshot) -> [SessionEffect] {
        guard let main = state.workbench.placement.main, let record = state.records[main] else { return [] }
        let token = state.nextTransitionToken()
        let target = FocusGeometry.dockedRect(in: snapshot.layout.mainRect,
                                              currentSize: record.frame.size,
                                              isResizable: record.allowsGeometryControl)
        var effects: [SessionEffect] = []
        if var transaction = state.transactions[main] {
            transaction = transaction.markingPlanned(frame: target, displayID: snapshot.displayID)
            state.transactions[main] = transaction
            effects.append(.writeJournal(transaction))
        }
        state.workbench.mainFrameWrite = WorkbenchFrameWrite(token: token, identity: main)
        effects.append(.settleMainFrame(main, targetFrame: target, token: token,
                                        animationMS: snapshot.layout.style.settleAnimationMS(reduceMotion: state.policy.reduceMotion)))
        return effects
    }

    static func applyMainFrameResult(_ state: inout SessionState, _ result: GeometryWriteResult) -> [SessionEffect] {
        state.workbench.mainFrameWrite = nil
        guard var transaction = state.transactions[result.identity] else { return [] }
        var effects: [SessionEffect] = []
        switch result.outcome {
        case let .exact(readBack):
            transaction = transaction.markingVerified(readBack: readBack, displayID: result.displayID)
        case let .constrained(readBack):
            transaction = transaction.markingWritten(readBack: readBack, displayID: result.displayID,
                                                     note: result.outcome.message)
        case .rejected, .unreadable:
            transaction = transaction.markingWriteFailed(result.outcome.message)
            effects.append(.presentHint(.workbenchMainFrameFailed(result.outcome.message)))
        case .targetGone:
            state.transactions.removeValue(forKey: result.identity)
            return [.dropJournal(result.identity)]
        }
        state.transactions[result.identity] = transaction
        effects.insert(.writeJournal(transaction), at: 0)
        return effects
    }

    // MARK: - 目录同步与窗口关闭

    /// 关闭/消失：原 slot 留空不前移；主窗口自动替补最多一次（方案 §6.2）。
    /// 由 SessionReducer 的窗口关闭优先级分支调用。
    static func handleWindowClosed(_ state: inout SessionState, identity: WindowIdentity) -> [SessionEffect] {
        guard isEngaged(state) else { return [] }
        var effects: [SessionEffect] = []
        // 模式过渡目标关闭：取消过渡，留在原模式（方案 §4.2.7）。
        if state.workbench.modeTransition.target == identity {
            state.workbench.modeTransition = .idle
            state.workbench.snapshot = nil
            state.workbench.placement.vacate(identity)
            state.phase = .overview
            state.keyboardFocus = .overview
            return [.cancelWorkbenchTransition, .hideWorkbench, .setKeyboardFocus(.overview),
                    .presentHint(.workbenchTransitionFailed("目标窗口已关闭"))]
        }
        // 交换中的窗口关闭交给宿主补偿后回报 mainSwitchFailed（方案 §8.3）。
        if case let .switching(intent, _) = state.workbench.mainSwitch,
           intent.to == identity || intent.from == identity {
            state.workbench.mainSwitch = .rollingBack(intent: intent, reason: "交换中的窗口已关闭")
        }
        var placement = state.workbench.placement
        guard placement.contains(identity) else { return effects }
        let wasMain = placement.main == identity
        placement.vacate(identity)
        state.workbench.placement = placement
        if wasMain, !state.workbench.mainSwitch.isBusy {
            effects.append(contentsOf: promoteCandidateIfNeeded(&state))
        }
        // 等着的目标已经关闭：直接丢弃，别再发起一次注定失败的交换。
        if state.workbench.pendingRailSelection?.identity == identity {
            state.workbench.pendingRailSelection = nil
        }
        effects.append(contentsOf: layoutEffects(state))
        return effects
    }

    /// 主窗口没了：选轨道顺序第一个唯一可控候选；没有候选则主区空状态（方案 §6.2）。
    private static func promoteCandidateIfNeeded(_ state: inout SessionState) -> [SessionEffect] {
        guard state.workbench.placement.main == nil else { return [] }
        guard let candidate = firstControllableCandidate(placement: state.workbench.placement, state: state) else {
            // 主区空态：轨道还在，键盘仍在 Vistile 一侧以便继续选择。
            state.phase = .overview
            state.keyboardFocus = .overview
            return [.setKeyboardFocus(.overview)]
        }
        state.workbench.placement.setMain(candidate)
        state.workbench.lastSelectedMain = candidate
        state.phase = .focused(target: candidate)
        state.keyboardFocus = .targetApplication
        var effects: [SessionEffect] = [.setKeyboardFocus(.targetApplication)]
        if let snapshot = state.workbench.snapshot {
            effects.append(contentsOf: settleMain(&state, snapshot: snapshot))
        }
        return effects
    }

    /// 目录回来后的轨道同步：关闭的留空，新窗口填空或尾部追加（方案 §6.2、§4.4.7）。
    static func syncCatalog(_ state: inout SessionState, generation _: UInt64) -> [SessionEffect] {
        guard state.mode == .workbench, let snapshot = state.workbench.snapshot else { return [] }
        var placement = state.workbench.placement
        // 主窗口从目录里消失（没有独立关闭事件时）：同样让位，不指向已不存在的身份。
        if let main = placement.main, state.records[main] == nil {
            placement.setMain(nil)
        }
        for identity in placement.occupants.values where state.records[identity] == nil {
            placement.vacate(identity)
        }
        let layout = fillRailOccupants(&placement, state: state, layout: snapshot.layout)
        guard placement != state.workbench.placement || layout != snapshot.layout else { return [] }
        state.workbench.placement = placement
        if layout != snapshot.layout {
            let updated = snapshot.replacing(layout: layout, revision: state.workbench.layoutRevision + 1)
            state.workbench.snapshot = updated
            state.workbench.layoutRevision = updated.revision
        }
        var effects: [SessionEffect] = []
        if placement.main == nil, !state.workbench.mainSwitch.isBusy {
            effects.append(contentsOf: promoteCandidateIfNeeded(&state))
        }
        effects.append(contentsOf: layoutEffects(state))
        return effects
    }

    // MARK: - 轨道初始化与占用

    /// 首次生成或恢复既有上下文（方案 §4.2.3、§4.4.6、§6）：
    /// - 同一主身份：恢复原轨道；
    /// - 选中的是轨道上的窗口：它进主区，原主回它的 slot；
    /// - 其他：选中窗口进主区，其余按稳定顺序补位。
    /// 返回补位后内容轨道延长过的布局。
    @discardableResult
    private static func initializeRailOccupants(_ placement: inout WorkbenchPlacement,
                                                state: SessionState,
                                                target: WindowIdentity,
                                                layout: WorkbenchLayout) -> WorkbenchLayout {
        if placement.isEmpty {
            var fresh = WorkbenchPlacement()
            fresh.setMain(target)
            let extended = fillRailOccupants(&fresh, state: state, layout: layout)
            placement = fresh
            return extended
        }
        if placement.main == target {
            return layout
        }
        if let slot = placement.slot(of: target) {
            let previousMain = placement.main ?? state.workbench.lastSelectedMain
            placement.setMain(target)
            if let previousMain, state.records[previousMain] != nil {
                placement.place(previousMain, at: slot, memoryKey: state.records[previousMain]?.memoryKey)
            }
        } else {
            placement.setMain(target)
        }
        return fillRailOccupants(&placement, state: state, layout: layout)
    }

    /// 把还没有轨道位置的窗口放进空格；没有空格就在侧栏尾部追加逻辑 slot（方案 §6.2）。
    /// 不移动任何已有 occupant，也不抢主。返回内容轨道延长后的布局（溢出卡片靠滚动到达）。
    private static func fillRailOccupants(_ placement: inout WorkbenchPlacement,
                                          state: SessionState,
                                          layout: WorkbenchLayout) -> WorkbenchLayout {
        let missing = stableOrder(state).filter { identity in
            identity != placement.main && !placement.contains(identity)
        }
        guard !missing.isEmpty else { return layout }
        var vacant = vacantSlots(placement: placement, layout: layout)
        // 追加序号必须同时避开既有占用与还没消费的空格，否则 place 会失败而静默丢窗口。
        var nextSide = max(layout.sideSlotCount, maxSideOrdinal(placement) + 1)
        var neededSide = layout.sideSlotCount
        for identity in missing {
            let memoryKey = state.records[identity]?.memoryKey
            if !vacant.isEmpty {
                let slot = vacant.removeFirst()
                if placement.place(identity, at: slot, memoryKey: memoryKey), slot.rail == .side {
                    neededSide = max(neededSide, slot.ordinal + 1)
                }
                continue
            }
            let slot = RailSlotID(displayID: layout.displayID, rail: .side, ordinal: nextSide)
            nextSide += 1
            if placement.place(identity, at: slot, memoryKey: memoryKey) {
                neededSide = max(neededSide, slot.ordinal + 1)
            }
        }
        return layout.extending(sideSlots: neededSide)
    }

    private static func vacantSlots(placement: WorkbenchPlacement, layout: WorkbenchLayout) -> [RailSlotID] {
        layout.slotOrder.filter { placement.occupant(at: $0) == nil }
    }

    private static func maxSideOrdinal(_ placement: WorkbenchPlacement) -> Int {
        placement.occupants.keys
            .filter { $0.rail == .side }
            .map(\.ordinal)
            .max() ?? -1
    }

    /// 整理用的 slot 顺序：可见容量之外按需延长侧栏轨道，绝不在整理时丢窗口（方案 §6.2）。
    private static func extendedSlotOrder(layout: WorkbenchLayout, needed: Int) -> [RailSlotID] {
        var order = layout.slotOrder
        var ordinal = layout.sideSlotCount
        while order.count < needed {
            order.append(RailSlotID(displayID: layout.displayID, rail: .side, ordinal: ordinal))
            ordinal += 1
        }
        return order
    }

    private static func firstControllableCandidate(placement: WorkbenchPlacement,
                                                   state: SessionState) -> WindowIdentity? {
        placement.occupants.sorted { $0.key < $1.key }
            .map(\.value)
            .first { state.records[$0]?.allowsAutoFocus == true }
    }

    /// 总览稳定顺序：冻结网格里的全局 slot 序号，其次应用名 + 稳定身份（方案 §4.2.3）。
    static func stableOrder(_ state: SessionState) -> [WindowIdentity] {
        let displayed = state.records.values.filter { state.gridCell(for: $0.identity) != nil }
        return displayed.sorted { lhs, rhs in
            let l = state.gridCell(for: lhs.identity)?.cell.slot?.index
            let r = state.gridCell(for: rhs.identity)?.cell.slot?.index
            if let l, let r, l != r { return l < r }
            if l != nil, r == nil { return true }
            if l == nil, r != nil { return false }
            if lhs.applicationName != rhs.applicationName { return lhs.applicationName < rhs.applicationName }
            if lhs.identity.processID != rhs.identity.processID { return lhs.identity.processID < rhs.identity.processID }
            return lhs.identity.windowID < rhs.identity.windowID
        }.map(\.identity)
    }

    // MARK: - 呈现与几何辅助

    /// 当前状态的展示事实（无 snapshot 时为空）。
    static func presentation(_ state: SessionState) -> WorkbenchPresentation? {
        guard let snapshot = state.workbench.snapshot else { return nil }
        return WorkbenchPresenter.make(state: state, snapshot: snapshot, placement: state.workbench.placement)
    }

    /// 只有 snapshot 有效时才发出的布局重投影 effect。
    private static func layoutEffects(_ state: SessionState) -> [SessionEffect] {
        presentation(state).map { [.updateWorkbenchLayout($0)] } ?? []
    }

    private static func workbenchDisplay(_ state: SessionState,
                                         identity: WindowIdentity,
                                         record: WindowRecord) -> DisplayInfo? {
        // 用户固定了工作台屏幕时先用它；没设置或该屏已拔掉，才跟随点击的卡片（方案 §13）。
        if let preferred = state.workbench.preferredDisplayID,
           let display = state.displays.first(where: { $0.id == preferred }) {
            return display
        }
        if let displayID = state.gridCell(for: identity)?.displayID,
           let display = state.displays.first(where: { $0.id == displayID }) {
            return display
        }
        return SessionReducer.targetDisplay(for: record, state: state)
    }

    private static func workbenchLayout(for display: DisplayInfo, state: SessionState) -> WorkbenchLayout? {
        guard display.visibleFrame.width > 1, display.visibleFrame.height > 1 else { return nil }
        let style = WorkbenchStyle()
        var layout = WorkbenchLayoutEngine.layout(displayID: display.id,
                                                  visibleFrame: display.visibleFrame,
                                                  side: state.workbench.side,
                                                  style: style,
                                                  topHeightOverride: state.workbench.topHeightPreference,
                                                  sideWidthOverride: state.workbench.sideWidthPreference)
        if layout.isMainAreaConstrained {
            // 小屏自动紧凑，不产生无法辨识的卡片（方案 §5.5）。
            layout = WorkbenchLayoutEngine.layout(displayID: display.id,
                                                  visibleFrame: display.visibleFrame,
                                                  side: state.workbench.side,
                                                  style: style,
                                                  compact: true,
                                                  topHeightOverride: state.workbench.topHeightPreference,
                                                  sideWidthOverride: state.workbench.sideWidthPreference)
        }
        // 侧栏切换、分隔线收敛、显示器变化都重算几何：内容轨道按当前占用续长，已用 slot 不因重算失联。
        return layout.extending(sideSlots: maxSideOrdinal(state.workbench.placement) + 1)
    }

    /// 其余卡片在两个位置空间之间的过渡端点（方案 §4.2.5、§10.2）。
    private static func railHandoffs(_ state: SessionState,
                                     snapshot: WorkbenchLayoutSnapshot,
                                     placement: WorkbenchPlacement,
                                     excluding main: WindowIdentity,
                                     entering: Bool) -> [RailHandoff] {
        placement.occupants.sorted { $0.key < $1.key }.compactMap { slot, identity in
            guard identity != main, state.records[identity] != nil else { return nil }
            let cardRect = snapshot.rect(for: slot)
            if entering {
                guard let from = state.cellRect(for: identity) else { return nil }
                return RailHandoff(identity: identity, slot: slot, from: from, to: cardRect)
            }
            guard let from = cardRect else { return nil }
            return RailHandoff(identity: identity, slot: slot, from: from, to: state.cellRect(for: identity))
        }
    }
}
