import XCTest
import CoreGraphics
@testable import VistileCore

final class WorkbenchFocusTests: XCTestCase {
    private func overview(_ count: Int = 6) -> (SessionState, [WindowRecord]) {
        var state = Fixtures.state(withCount: count)
        let records = Fixtures.records(count)
        Fixtures.openToOverview(&state, records: records)
        return (state, records)
    }

    private func prepareEntry(_ state: inout SessionState, _ identity: WindowIdentity) throws -> JournalPrepareRequest {
        let slot = try XCTUnwrap(state.gridCell(for: identity)?.cell.slot)
        return try request(Fixtures.dispatch(&state, .overviewCardSelected(identity: identity, slot: slot,
                                                                           revision: state.layoutRevision)))
    }

    private func request(_ effects: [SessionEffect]) throws -> JournalPrepareRequest {
        try XCTUnwrap(effects.compactMap { effect in
            if case let .prepareJournal(request) = effect { return request }
            return nil
        }.first)
    }

    private func release(_ state: inout SessionState, _ request: JournalPrepareRequest) -> [SessionEffect] {
        Fixtures.dispatch(&state, .journalPrepared(context: request.context))
    }

    private func finishEntry(_ state: inout SessionState) throws -> [SessionEffect] {
        let token = try XCTUnwrap(state.workbench.modeTransition.token)
        return Fixtures.dispatch(&state, .workbenchTransitionFinished(token: token, kind: .enteringWorkbench,
                                                                      result: .succeeded(readBack: state.workbench.snapshot?.mainRect)))
    }

    private func entered(_ count: Int = 6) throws -> (SessionState, [WindowRecord]) {
        var (state, records) = overview(count)
        let prepared = try prepareEntry(&state, records[0].identity)
        _ = release(&state, prepared)
        _ = try finishEntry(&state)
        return (state, records)
    }

    private func switchPlan(_ state: inout SessionState, _ effects: [SessionEffect]) throws -> WorkbenchSwitchPlan {
        let prepared = try request(effects)
        return try XCTUnwrap(release(&state, prepared).compactMap { effect in
            if case let .beginMainSwitch(plan) = effect { return plan }
            return nil
        }.first)
    }

    @discardableResult
    private func commit(_ state: inout SessionState, _ plan: WorkbenchSwitchPlan) -> [SessionEffect] {
        for step in WorkbenchSwitchStep.allCases {
            let identity = step == .moveToMain ? plan.intent.to : (step == .restorePrevious ? plan.intent.from : nil)
            let frame = step == .moveToMain ? plan.mainTargetFrame : (step == .restorePrevious ? plan.restingTargetFrame : nil)
            _ = Fixtures.dispatch(&state, .mainSwitchStepFinished(.init(token: plan.intent.token, step: step,
                                                                       outcome: .succeeded(readBack: frame), identity: identity)))
        }
        return Fixtures.dispatch(&state, .mainSwitchCommitted(token: plan.intent.token))
    }

    private func select(_ state: inout SessionState, _ identity: WindowIdentity) throws -> WorkbenchSwitchPlan {
        let slot = try XCTUnwrap(state.workbench.slot(of: identity))
        let effects = Fixtures.dispatch(&state, .railCardSelected(slot: slot, identity: identity))
        return try switchPlan(&state, effects)
    }

    private func catalog(_ state: inout SessionState, _ records: [WindowRecord]) throws -> [SessionEffect] {
        let request = try XCTUnwrap(Fixtures.discoverRequest(Fixtures.dispatch(&state, .reconcileTick)))
        return Fixtures.dispatch(&state, .catalogUpdated(request: request, records: records))
    }

    private func assertNoFocusOrWrite(_ effects: [SessionEffect], file: StaticString = #filePath, line: UInt = #line) {
        for effect in effects {
            switch effect {
            case .prepareJournal, .beginMainSwitch, .enterWorkbench, .settleMainFrame, .raiseTarget, .setKeyboardFocus:
                XCTFail("Unexpected focus/write effect: \(effect)", file: file, line: line)
            default: break
            }
        }
    }

    func testBackgroundCatalogAddsAndReordersWithoutStealingMainOrMovingSlots() throws {
        var (state, records) = try entered()
        let homes = state.workbench.placement.occupants
        let extra = Fixtures.record(900, 9000)
        let effects = try catalog(&state, [extra] + records.reversed())
        assertNoFocusOrWrite(effects)
        XCTAssertEqual(state.workbench.placement.main, records[0].identity)
        XCTAssertNotNil(state.workbench.slot(of: extra.identity))
        for (slot, identity) in homes { XCTAssertEqual(state.workbench.placement.occupant(at: slot), identity) }
    }

    func testConcreteSameApplicationWindowFollowsThroughJournalAndKeepsEverySlot() throws {
        var (state, records) = try entered()
        let a = records[0].identity, b = records[1].identity
        XCTAssertEqual(a.processID, b.processID)
        let homes = state.workbench.placement.occupants
        let effects = Fixtures.dispatch(&state, .externalWindowFocused(b))
        XCTAssertEqual(effects.count, 1)
        XCTAssertNil(state.workbench.activeContext)
        XCTAssertEqual(state.workbench.placement.main, a)
        let plan = try switchPlan(&state, effects)
        XCTAssertTrue(plan.intent.followsExternalFocus)
        XCTAssertEqual(plan.intent.beforeOperation.writtenOrder, [b, a])
        XCTAssertEqual(plan.intent.to, b)
        let committed = commit(&state, plan)
        XCTAssertFalse(committed.contains(.setKeyboardFocus(.targetApplication)))
        XCTAssertEqual(state.workbench.placement.occupants, homes)
        XCTAssertEqual(state.workbench.recentMainIdentities, [b, a])
        XCTAssertEqual(state.transactions[b]?.lastProvisionalFrame, plan.mainTargetFrame)
    }

    func testLatestExternalWinsDuringEntryIncludingJournalPreparation() throws {
        for beforeJournal in [true, false] {
            var (state, records) = overview()
            let prepared = try prepareEntry(&state, records[0].identity)
            if !beforeJournal { _ = release(&state, prepared) }
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[0].identity))
            XCTAssertEqual(state.workbench.pendingExternalFocus, records[2].identity)
            XCTAssertNil(state.workbench.pendingRailSelection)
            if beforeJournal { _ = release(&state, prepared) }
            let effects = try finishEntry(&state)
            XCTAssertFalse(effects.contains(.setKeyboardFocus(.targetApplication)))
            let plan = try switchPlan(&state, effects)
            XCTAssertEqual(plan.intent.to, records[2].identity)
            XCTAssertTrue(plan.intent.followsExternalFocus)
            commit(&state, plan)
            XCTAssertEqual(state.workbench.placement.main, records[2].identity)
        }
    }

    func testLatestExternalWinsDuringSwitchAndOwnAcknowledgementDoesNotOverwriteIt() throws {
        var (state, records) = try entered()
        let first = try select(&state, records[1].identity)
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[3].identity))
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
        XCTAssertEqual(state.workbench.pendingExternalFocus, records[3].identity)
        let effects = commit(&state, first)
        let final = try switchPlan(&state, effects)
        XCTAssertEqual(final.intent.to, records[3].identity)
        XCTAssertTrue(final.intent.followsExternalFocus)
        XCTAssertNil(state.workbench.pendingExternalFocus)
    }

    func testExternalCanReturnToOldMainDuringSwitch() throws {
        var (state, records) = try entered()
        let first = try select(&state, records[1].identity)
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[0].identity))
        let effects = commit(&state, first)
        let final = try switchPlan(&state, effects)
        XCTAssertEqual(final.intent.to, records[0].identity)
    }

    func testManualAndExternalPendingNeverCompeteAndLatestSourceWins() throws {
        for manualLast in [true, false] {
            var (state, records) = try entered()
            let first = try select(&state, records[1].identity)
            let manual = SessionEvent.railCardSelected(slot: try XCTUnwrap(state.workbench.slot(of: records[2].identity)),
                                                       identity: records[2].identity)
            let external = SessionEvent.externalWindowFocused(records[3].identity)
            _ = Fixtures.dispatch(&state, manualLast ? external : manual)
            _ = Fixtures.dispatch(&state, manualLast ? manual : external)
            XCTAssertFalse(state.workbench.pendingExternalFocus != nil && state.workbench.pendingRailSelection != nil)
            let effects = commit(&state, first)
            let final = try switchPlan(&state, effects)
            XCTAssertEqual(final.intent.to, records[manualLast ? 2 : 3].identity)
            XCTAssertEqual(final.intent.followsExternalFocus, !manualLast)
        }
    }

    func testSelectingCurrentCardClearsOlderExternalPending() throws {
        var (state, records) = try entered()
        let first = try select(&state, records[1].identity)
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
        _ = Fixtures.dispatch(&state, .railCardSelected(slot: try XCTUnwrap(state.workbench.slot(of: records[1].identity)),
                                                       identity: records[1].identity))
        let effects = commit(&state, first)
        XCTAssertNil(state.workbench.pendingExternalFocus)
        XCTAssertNil(state.workbench.armed)
        XCTAssertFalse(effects.contains { if case .prepareJournal = $0 { return true }; return false })
    }

    func testExternalLatestWaitsForLayoutSettleAndItsJournal() throws {
        for beforeJournal in [true, false] {
            var (state, records) = try entered()
            let effects = Fixtures.dispatch(&state, .railSideChanged(.left))
            let prepared = try request(effects)
            if !beforeJournal { _ = release(&state, prepared) }
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
            XCTAssertEqual(state.workbench.pendingExternalFocus, records[2].identity)
            if beforeJournal { _ = release(&state, prepared) }
            let target = try XCTUnwrap(state.transactions[records[0].identity]?.plannedFrame)
            let settled = Fixtures.dispatch(&state, Fixtures.writeResult(records[0].identity,
                                                                          token: prepared.context.transitionToken,
                                                                          outcome: .exact(readBack: target), target: target))
            let final = try switchPlan(&state, settled)
            XCTAssertEqual(final.intent.to, records[2].identity)
        }
    }

    func testReturnAndHideClearPendingExternalFocus() throws {
        for hide in [false, true] {
            var (state, records) = try entered()
            let first = try select(&state, records[1].identity)
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
            let effects = Fixtures.dispatch(&state, hide ? .globalShortcut : .returnToOverviewRequested)
            XCTAssertNil(state.workbench.pendingExternalFocus)
            if hide {
                XCTAssertTrue(effects.contains(.hideWorkbench))
                XCTAssertTrue(state.workbench.recentMainIdentities.isEmpty)
                XCTAssertTrue(Fixtures.dispatch(&state, .externalWindowFocused(records[3].identity)).isEmpty)
                XCTAssertTrue(Fixtures.dispatch(&state, .mainSwitchCommitted(token: first.intent.token)).isEmpty)
            } else {
                let finished = commit(&state, first)
                XCTAssertEqual(try request(finished).context.kind, .returnOverview)
            }
        }
    }

    func testClosingMainWaitsForSystemCandidateAheadOfMRUAndStableSlotOrder() throws {
        var (state, records) = try entered()
        let selected = try select(&state, records[2].identity)
        commit(&state, selected)
        let homes = state.workbench.placement.occupants
        let closed = Fixtures.dispatch(&state, .windowClosed(records[2].identity))
        XCTAssertTrue(closed.contains(.resolveWorkbenchReplacement(closed: records[2].identity)))
        XCTAssertFalse(closed.contains(.setKeyboardFocus(.overview)))
        XCTAssertNil(state.workbench.armed)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertEqual(state.phase, .overview)
        XCTAssertEqual(state.mode, .workbench)
        XCTAssertEqual(state.workbench.pendingReplacement, records[2].identity)
        let resolved = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[2].identity,
                                                                              candidate: records[4].identity))
        let plan = try switchPlan(&state, resolved)
        XCTAssertTrue(plan.intent.isPromotion)
        XCTAssertTrue(plan.intent.followsExternalFocus)
        XCTAssertEqual(plan.intent.to, records[4].identity)
        XCTAssertNil(plan.intent.from)
        commit(&state, plan)
        for (slot, identity) in homes where identity != records[2].identity {
            XCTAssertEqual(state.workbench.placement.occupant(at: slot), identity)
        }
        XCTAssertFalse(state.workbench.recentMainIdentities.contains(records[2].identity))
    }

    func testMRUFallbackBeatsSlotOrderWhenSystemHasNoCandidate() throws {
        var (state, records) = try entered()
        for index in [3, 2] {
            let plan = try select(&state, records[index].identity)
            commit(&state, plan)
        }
        state.records[records[4].identity]?.displayID = 2
        _ = Fixtures.dispatch(&state, .windowClosed(records[2].identity))
        let resolved = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[2].identity,
                                                                              candidate: nil))
        let plan = try switchPlan(&state, resolved)
        XCTAssertEqual(plan.intent.to, records[3].identity)
        XCTAssertFalse(plan.intent.followsExternalFocus)
    }

    func testClosingMainThenFocusingAnotherDisplayYieldsInsteadOfPromotingMRU() throws {
        var (state, records) = try entered()
        state.records[records[2].identity]?.displayID = 2
        _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        let effects = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                              candidate: records[2].identity))
        XCTAssertFalse(state.phase.isVisible)
        XCTAssertNil(state.workbench.armed)
        XCTAssertTrue(effects.contains(.hideWorkbench))
    }

    func testSlotFallbackSkipsMinimizedSheetRestrictedAndAmbiguousWindows() throws {
        var (state, records) = try entered(8)
        state.records[records[1].identity]?.isMinimized = true
        state.records[records[2].identity]?.axSnapshot = Fixtures.ax(0, frame: records[2].frame, subrole: "AXDialog")
        state.records[records[3].identity]?.restriction = .protectedContent
        state.records[records[4].identity]?.confidence = .ambiguous(alternatives: [0, 1])
        state.records[records[5].identity]?.isMovable = false
        state.records[records[6].identity]?.displayID = 2
        _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        let resolved = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                              candidate: records[1].identity))
        let plan = try switchPlan(&state, resolved)
        XCTAssertEqual(plan.intent.to, records[7].identity)
    }

    func testNoCandidateLeavesLFrameEmptyAndBackgroundAdditionNeverRetries() throws {
        var (state, records) = try entered(1)
        _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        _ = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity, candidate: nil))
        XCTAssertEqual(state.mode, .workbench)
        XCTAssertNotNil(state.workbench.snapshot)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertNil(state.workbench.pendingReplacement)
        let extra = Fixtures.record(901, 9001)
        assertNoFocusOrWrite(try catalog(&state, [extra]))
        XCTAssertNil(state.workbench.armed)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertNotNil(state.workbench.slot(of: extra.identity))
    }

    func testReplacementFailureDoesNotTryAnotherCandidateOrCatalogRetry() throws {
        var (state, records) = try entered()
        _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        let resolved = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                              candidate: records[1].identity))
        let prepared = try request(resolved)
        _ = Fixtures.dispatch(&state, .journalPreparationFailed(context: prepared.context,
                                                                identities: prepared.affectedIdentities, reason: "disk full"))
        XCTAssertNil(state.workbench.armed)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertTrue(state.workbench.hasAutoPromotionAttempted)
        assertNoFocusOrWrite(try catalog(&state, Array(records.dropFirst())))
        XCTAssertTrue(Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                              candidate: records[2].identity)).isEmpty)
    }

    func testStaleReplacementAfterManualSelectionAndHideIsIgnored() throws {
        for hide in [true, false] {
            var (state, records) = try entered()
            _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
            if hide {
                _ = Fixtures.dispatch(&state, .globalShortcut)
            } else {
                let plan = try select(&state, records[2].identity)
                commit(&state, plan)
            }
            let late = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                               candidate: records[1].identity))
            XCTAssertTrue(late.isEmpty)
            XCTAssertNil(state.workbench.pendingReplacement)
        }
    }

    func testWrongClosedIdentityDoesNotConsumePendingReplacement() throws {
        var (state, records) = try entered()
        _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        let effects = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[1].identity,
                                                                              candidate: records[2].identity))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(state.workbench.pendingReplacement, records[0].identity)
    }

    func testMinimizedMainYieldsButKeepsItsCardAndNeverAutomaticallyRestoresIt() throws {
        var (state, records) = try entered()
        let homes = state.workbench.placement.occupants
        let effects = Fixtures.dispatch(&state, .windowMinimized(records[0].identity, true))
        XCTAssertTrue(effects.contains(.resolveWorkbenchReplacement(closed: records[0].identity)))
        XCTAssertFalse(effects.contains(.setKeyboardFocus(.overview)))
        XCTAssertEqual(state.workbench.placement.occupants, homes)
        XCTAssertNil(state.workbench.placement.main)
        XCTAssertNil(state.phase.controlledTarget)
        XCTAssertNotNil(state.transactions[records[0].identity])
        let resolved = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                              candidate: records[0].identity))
        let plan = try switchPlan(&state, resolved)
        XCTAssertEqual(plan.intent.to, records[1].identity)
        XCTAssertNil(plan.restingTargetFrame)
        commit(&state, plan)
        XCTAssertEqual(state.records[records[0].identity]?.isMinimized, true)
        XCTAssertEqual(state.workbench.placement.occupants, homes)
    }

    func testCatalogDisappearanceAndMinimizationRequestResolutionWithoutPromotion() throws {
        for minimized in [false, true] {
            var (state, records) = try entered()
            var incoming = records
            if minimized { incoming[0].isMinimized = true } else { incoming.removeFirst() }
            let effects = try catalog(&state, incoming)
            XCTAssertTrue(effects.contains(.resolveWorkbenchReplacement(closed: records[0].identity)))
            XCTAssertNil(state.workbench.armed)
            XCTAssertNil(state.workbench.placement.main)
            XCTAssertNil(state.phase.controlledTarget)
            XCTAssertEqual(state.workbench.slot(of: records[0].identity) != nil, minimized)
        }
    }

    func testDifferentDisplayOrHardRestrictionSafelyExitsWithActionableHint() throws {
        for restriction in 0..<4 {
            var (state, records) = try entered()
            let target = records[1].identity
            switch restriction {
            case 0: state.records[target]?.displayID = 2
            case 1: state.records[target]?.restriction = .nativeFullscreen
            case 2: state.records[target]?.isMovable = false
            default: state.records[target]?.confidence = .unmatched
            }
            let effects = Fixtures.dispatch(&state, .externalWindowFocused(target))
            XCTAssertFalse(state.phase.isVisible)
            XCTAssertTrue(effects.contains(.hideWorkbench))
            XCTAssertNil(state.workbench.armed)
            XCTAssertTrue(effects.contains { effect in
                if case let .presentHint(.restrictedWindow(message)) = effect { return message.contains("请") }
                return false
            })
        }
    }

    func testSheetFocusIgnoredWithoutExitingOrOverwritingLatestIntent() throws {
        var (state, records) = try entered()
        state.records[records[4].identity]?.axSnapshot = AXWindowSnapshot(index: 0, frame: records[4].frame,
                                                                                         title: "Sheet", role: "AXSheet")
        let first = try select(&state, records[1].identity)
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
        XCTAssertTrue(Fixtures.dispatch(&state, .externalWindowFocused(records[4].identity)).isEmpty)
        XCTAssertEqual(state.workbench.pendingExternalFocus, records[2].identity)
        XCTAssertTrue(state.phase.isVisible)
        let effects = commit(&state, first)
        XCTAssertEqual(try switchPlan(&state, effects).intent.to, records[2].identity)
    }

    func testUnresolvableExternalFocusSafelyExitsAndRejectsLateIntent() throws {
        var (state, records) = try entered()
        let effects = Fixtures.dispatch(&state, .workbenchFocusUnavailable(reason: "请从总览重新选择"))
        XCTAssertFalse(state.phase.isVisible)
        XCTAssertTrue(effects.contains(.hideWorkbench))
        XCTAssertTrue(effects.contains(.presentHint(.restrictedWindow("请从总览重新选择"))))
        XCTAssertTrue(Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity)).isEmpty)
    }

    func testSupersededManualSwitchKeepsOldGeometryForLatestExternalPlanWithoutFocusWrites() throws {
        var (state, records) = try entered()
        let homes = state.workbench.placement.occupants
        let first = try select(&state, records[1].identity)
        _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
        let failed = Fixtures.dispatch(&state, .mainSwitchFailed(token: first.intent.token, reason: "superseded",
            compensation: .init(items: [
                .init(identity: records[0].identity, action: .notWritten, displayID: 1),
                .init(identity: records[1].identity, action: .notWritten, displayID: 1)
            ], activatedMain: nil)))
        XCTAssertFalse(failed.contains(.setKeyboardFocus(.targetApplication)))
        XCTAssertNil(state.workbench.recoveryRequired)
        let latest = try switchPlan(&state, failed)
        XCTAssertEqual(latest.intent.from, records[0].identity)
        XCTAssertEqual(latest.intent.to, records[2].identity)
        XCTAssertTrue(latest.intent.followsExternalFocus)
        commit(&state, latest)
        XCTAssertEqual(state.workbench.placement.occupants, homes)
        XCTAssertEqual(state.workbench.placement.main, records[2].identity)
    }

    func testExternalSwitchWithoutNewerIntentExitsAfterVerifiedCompensation() throws {
        var (state, records) = try entered()
        let effects = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
        let plan = try switchPlan(&state, effects)
        let failed = Fixtures.dispatch(&state, .mainSwitchFailed(token: plan.intent.token, reason: "focus changed",
            compensation: .init(items: [
                .init(identity: records[0].identity, action: .notWritten, displayID: 1),
                .init(identity: records[1].identity, action: .notWritten, displayID: 1)
            ], activatedMain: nil)))
        XCTAssertNil(state.workbench.recoveryRequired)
        XCTAssertFalse(state.phase.isVisible)
        XCTAssertFalse(failed.contains(.setKeyboardFocus(.targetApplication)))
    }

    func testApplicationLevelFocusLossWaitsForConcreteIdentity() throws {
        var (state, records) = try entered()
        for origin in [FocusLossOrigin.commandTab, .dock, .unknown, .otherApplication(bundleID: "another.app")] {
            XCTAssertTrue(Fixtures.dispatch(&state, .focusLost(origin: origin)).isEmpty)
            XCTAssertEqual(state.workbench.placement.main, records[0].identity)
            XCTAssertEqual(state.mode, .workbench)
        }
    }

    func testBackgroundAdditionDuringPreparedExternalSwitchDoesNotCancelIt() throws {
        var (state, records) = try entered()
        let effects = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
        let prepared = try request(effects)
        let extra = Fixtures.record(902, 9002)
        assertNoFocusOrWrite(try catalog(&state, records + [extra]))
        let released = release(&state, prepared)
        XCTAssertTrue(released.contains { if case .beginMainSwitch = $0 { return true }; return false })
        XCTAssertEqual(state.workbench.mainSwitch.intent?.to, records[1].identity)
    }

    func testPreparedExternalTargetBecomingMinimizedIsNeverAdmitted() throws {
        var (state, records) = try entered()
        let effects = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
        let prepared = try request(effects)
        _ = Fixtures.dispatch(&state, .windowMinimized(records[1].identity, true))
        XCTAssertTrue(release(&state, prepared).isEmpty)
        XCTAssertEqual(state.workbench.placement.main, records[0].identity)
        XCTAssertNil(state.workbench.armed)
    }

    func testClosedMainDuringSwitchDefersReplacementUntilCompleteCompensation() throws {
        var (state, records) = try entered()
        let first = try select(&state, records[1].identity)
        _ = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        let resolved = Fixtures.dispatch(&state, .workbenchReplacementResolved(closed: records[0].identity,
                                                                              candidate: records[2].identity))
        XCTAssertTrue(resolved.isEmpty)
        XCTAssertNil(state.workbench.armed)
        XCTAssertEqual(state.workbench.activeContext, first.intent.operationContext)
        let failed = Fixtures.dispatch(&state, .mainSwitchFailed(token: first.intent.token, reason: "old main closed",
                                                                 compensation: .init(items: [.init(identity: records[1].identity,
                                                                                                  action: .notWritten, displayID: 1)],
                                                                                     activatedMain: nil)))
        let replacement = try switchPlan(&state, failed)
        XCTAssertEqual(replacement.intent.to, records[2].identity)
        XCTAssertTrue(replacement.intent.isPromotion)
        XCTAssertTrue(replacement.intent.followsExternalFocus)
        XCTAssertNil(state.workbench.recoveryRequired)
    }

    func testLatestExternalSurvivesPrepareFailureAndSafeRollback() throws {
        for beforeJournal in [true, false] {
            var (state, records) = try entered()
            let effects = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
            let prepared = try request(effects)
            if !beforeJournal { _ = release(&state, prepared) }
            _ = Fixtures.dispatch(&state, .externalWindowFocused(records[2].identity))
            let failed: [SessionEffect]
            if beforeJournal {
                failed = Fixtures.dispatch(&state, .journalPreparationFailed(context: prepared.context,
                                                                               identities: prepared.affectedIdentities,
                                                                               reason: "prepare failed"))
            } else {
                failed = Fixtures.dispatch(&state, .mainSwitchFailed(token: prepared.context.transitionToken, reason: "write rejected",
                                                                      compensation: .init(items: [
                                                                        .init(identity: records[1].identity, action: .notWritten, displayID: 1),
                                                                        .init(identity: records[0].identity, action: .notWritten, displayID: 1)
                                                                      ], activatedMain: nil)))
            }
            XCTAssertEqual(try switchPlan(&state, failed).intent.to, records[2].identity)
        }
    }

    func testClosingMainDuringReturnPreparationDoesNotActivateOverview() throws {
        var (state, records) = try entered()
        let prepared = try request(Fixtures.dispatch(&state, .returnToOverviewRequested))
        let effects = Fixtures.dispatch(&state, .windowClosed(records[0].identity))
        XCTAssertFalse(effects.contains(.setKeyboardFocus(.overview)))
        XCTAssertTrue(effects.contains(.resolveWorkbenchReplacement(closed: records[0].identity)))
        XCTAssertNil(state.phase.controlledTarget)
        XCTAssertEqual(state.mode, .workbench)
        XCTAssertTrue(release(&state, prepared).isEmpty)
    }

    func testExternalTargetMovingToAnotherDisplayBeforeCommitCannotFakeSuccess() throws {
        var (state, records) = try entered()
        let effects = Fixtures.dispatch(&state, .externalWindowFocused(records[1].identity))
        let plan = try switchPlan(&state, effects)
        state.records[records[1].identity]?.displayID = 2
        commit(&state, plan)
        XCTAssertEqual(state.workbench.placement.main, records[0].identity)
        XCTAssertTrue(state.workbench.mainSwitch.isRollingBack)
        XCTAssertEqual(state.workbench.activeContext, plan.intent.operationContext)
        XCTAssertNotNil(state.workbench.runningOperation)
        XCTAssertEqual(state.workbench.recentMainIdentities, [records[0].identity])
    }

    func testResizeDuringJournalAndWriteKeepsOneOperationAndConvergesToFinalSize() throws {
        var (state, _) = try entered()
        let first = try request(Fixtures.dispatch(&state, .workbenchRailSizeChanged(topHeight: 140, sideWidth: nil)))
        for height in [CGFloat(160), 180, 200] {
            let effects = Fixtures.dispatch(&state, .workbenchRailSizePreview(topHeight: height, sideWidth: nil))
            XCTAssertEqual(state.workbench.armed?.context, first.context)
            XCTAssertFalse(effects.contains { if case .prepareJournal = $0 { return true }; return false })
        }
        let initial = try XCTUnwrap(release(&state, first).compactMap { effect -> (WindowIdentity, CGRect, GeometryOperationContext)? in
            if case let .settleMainFrame(identity, frame, context, _) = effect { return (identity, frame, context) }
            return nil
        }.first)
        XCTAssertEqual(state.workbench.snapshot?.layout.topRailRect.height, 200)
        let whileWriting = Fixtures.dispatch(&state, .workbenchRailSizeChanged(topHeight: 220, sideWidth: 300))
        XCTAssertNil(state.workbench.armed)
        XCTAssertFalse(whileWriting.contains { if case .prepareJournal = $0 { return true }; return false })
        let completed = Fixtures.dispatch(&state, .geometryWriteFinished(.init(identity: initial.0,
            token: initial.2.transitionToken, operationID: initial.2.operationID, targetFrame: initial.1,
            displayID: 1, outcome: .exact(readBack: initial.1), context: initial.2)))
        let final = try request(completed)
        XCTAssertNotEqual(final.context, first.context)
        let last = try XCTUnwrap(release(&state, final).compactMap { effect -> (WindowIdentity, CGRect, GeometryOperationContext)? in
            if case let .settleMainFrame(identity, frame, context, _) = effect { return (identity, frame, context) }
            return nil
        }.first)
        XCTAssertEqual(last.1, state.workbench.snapshot?.mainRect)
        XCTAssertEqual(state.workbench.snapshot?.layout.topRailRect.height, 220)
        XCTAssertEqual(state.workbench.snapshot?.layout.sideRailRect.width, 300)
        _ = Fixtures.dispatch(&state, .geometryWriteFinished(.init(identity: last.0,
            token: last.2.transitionToken, operationID: last.2.operationID, targetFrame: last.1,
            displayID: 1, outcome: .exact(readBack: last.1), context: last.2)))
        XCTAssertNil(state.workbench.armed)
        XCTAssertNil(state.workbench.mainFrameWrite)
        XCTAssertFalse(state.workbench.railSizeRecomputePending)
    }

    func testObservedMinimumConstrainsSubsequentDividerSizes() throws {
        var (state, records) = try entered()
        let prepared = try request(Fixtures.dispatch(&state, .workbenchRailSizeChanged(topHeight: 320, sideWidth: 480)))
        let initial = try XCTUnwrap(release(&state, prepared).compactMap { effect -> CGRect? in
            if case let .settleMainFrame(_, frame, _, _) = effect { return frame }; return nil
        }.first)
        var constrained = initial
        constrained.size.width += 90
        constrained.size.height += 70
        let completed = Fixtures.dispatch(&state, .geometryWriteFinished(.init(identity: records[0].identity,
            token: prepared.context.transitionToken, operationID: prepared.context.operationID,
            targetFrame: initial, displayID: 1, outcome: .constrained(readBack: constrained), context: prepared.context)))
        XCTAssertNotNil(try request(completed))
        let layout = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertGreaterThanOrEqual(layout.mainRect.width, constrained.width)
        XCTAssertGreaterThanOrEqual(layout.mainRect.height, constrained.height)
        XCTAssertLessThan(layout.topRailRect.height, 320)
        XCTAssertLessThan(layout.sideRailRect.width, 480)
    }

    func testRecomputedLayoutExtendsBothRailsThroughStableOccupiedOrdinals() throws {
        var (state, records) = try entered(24)
        let homes = state.workbench.placement.occupants
        let oldTop = try XCTUnwrap(homes.keys.filter { $0.rail == .top }.map(\.ordinal).max())
        state.workbench.topHeightPreference = 160
        state.workbench.sideWidthPreference = 248
        let prepared = try request(Fixtures.dispatch(&state, .railSideChanged(.left)))
        _ = release(&state, prepared)
        let layout = try XCTUnwrap(state.workbench.snapshot?.layout)
        XCTAssertGreaterThan(layout.topSlotCount, oldTop)
        XCTAssertEqual(state.workbench.placement.occupants, homes)
        for slot in homes.keys { XCTAssertNotNil(layout.rect(for: slot, scrollOffset: 0)) }
        XCTAssertEqual(state.workbench.placement.main, records[0].identity)
    }
}
