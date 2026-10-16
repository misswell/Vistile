import Testing
import Foundation
import CoreGraphics
@testable import VistileCore

@Suite("WindowTransaction")
struct WindowTransactionTests {
    private let original = CGRect(x: 120, y: 90, width: 900, height: 600)
    private let provisional = CGRect(x: 60, y: 50, width: 1_300, height: 860)

    private func transaction(state make: (WindowTransaction) -> WindowTransaction = { $0 }) -> WindowTransaction {
        make(WindowTransaction(sessionID: UUID(), identity: WindowIdentity.test(700, 42), bundleID: nil,
                               originalFrame: original, originalDisplayID: 1))
    }

    @Test("同一事务不会反复覆盖原 frame")
    func originalFrameIsImmutable() {
        let identity = WindowIdentity.test(700, 42)
        var journal = SessionJournal(sessionID: UUID())
        let created = WindowTransaction(sessionID: journal.sessionID, identity: identity, bundleID: "com.test.app",
                                        originalFrame: original, originalDisplayID: 1)
        journal.apply(created)
        journal.apply(created.markingPlanned(frame: provisional, displayID: 1)
            .markingWritten(readBack: provisional, displayID: 1))
        journal.apply(WindowTransaction(sessionID: journal.sessionID, identity: identity, bundleID: "com.test.app",
                                        originalFrame: CGRect(x: 999, y: 999, width: 1, height: 1),
                                        originalDisplayID: 2))
        let entry = journal.entries[identity.journalKey]
        #expect(entry?.originalFrame == original)
        #expect(entry?.originalDisplayID == 1)
        #expect(entry?.plannedFrame == provisional)
        #expect(entry?.lastProvisionalFrame == provisional)
    }

    @Test("修改意图在写入之前就必须算作待恢复")
    func plannedMutationRequiresRestore() {
        let planned = transaction { $0.markingPlanned(frame: provisional, displayID: 1) }
        #expect(planned.state == .mutationPlanned)
        #expect(planned.state.requiresRestore)
        #expect(planned.state.needsConservativeCheck)
        var journal = SessionJournal(sessionID: planned.sessionID)
        journal.apply(planned)
        #expect(journal.unfinished.map(\.identity) == [planned.identity])
        // 崩溃发生在"计划已落盘、写入未确认"之间：计划的 frame 也是判据。
        #expect(planned.writtenFrameCandidates == [provisional])
    }

    @Test("只有读回一致才记为已验证")
    func verifiedOnlyOnExactReadBack() {
        let written = transaction { $0.markingPlanned(frame: provisional, displayID: 1)
            .markingWritten(readBack: provisional, displayID: 1) }
        #expect(written.state == .written)
        #expect(written.state.requiresRestore)
        let verified = written.markingVerified(readBack: provisional, displayID: 1)
        #expect(verified.state == .verified)
        let rejected = written.markingWriteFailed("尺寸写入返回错误码 -25205")
        #expect(rejected.state == .failed)
        #expect(rejected.state.requiresRestore)
        #expect(rejected.restoreAttempts == 0)
        #expect(rejected.failureReason?.contains("-25205") == true)
    }

    @Test("日志内容不含标题正文")
    func journalStoresNoTitlesOrScreenshots() throws {
        let base = WindowTransaction(sessionID: UUID(), identity: WindowIdentity.test(700, 42),
                                     bundleID: "com.test.app", originalFrame: original, originalDisplayID: 1)
        let transaction = base.markingPlanned(frame: provisional, displayID: 1)
        var journal = SessionJournal(sessionID: transaction.sessionID)
        journal.apply(transaction)
        let data = try journal.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("机密标题"))
        #expect(text.contains("com.test.app"))
        let decoded = try SessionJournal.decode(data)
        #expect(decoded.entries[transaction.journalKey]?.originalFrame == original)
        #expect(decoded.entries[transaction.journalKey]?.plannedFrame == provisional)
    }

    /// 旧版本日志的样子：用真实编码器产出结构，再剥掉只有新版本才有的字段。
    /// 不手写 CGRect 的 JSON 形状，避免把测试绑死成系统类型的私有编码格式。
    private func legacyJournalData(state rawState: String) throws -> Data {
        let session = UUID(uuidString: "7A1B4A7A-2E1D-4E1F-9A44-1B1B1B1B1B1B") ?? UUID()
        var journal = SessionJournal(sessionID: session)
        let base = WindowTransaction(sessionID: session, identity: WindowIdentity.test(700, 42),
                                     bundleID: "com.test.app", originalFrame: original, originalDisplayID: 1)
        journal.apply(base.markingPlanned(frame: provisional, displayID: 1)
            .markingWritten(readBack: provisional, displayID: 1))
        var json = try #require(JSONSerialization.jsonObject(with: try journal.encoded()) as? [String: Any])
        let entries = try #require(json["entries"] as? [String: [String: Any]])
        var entry = try #require(entries["700:1:42"])
        entry["state"] = rawState
        entry.removeValue(forKey: "plannedFrame")
        entry.removeValue(forKey: "plannedDisplayID")
        var legacyEntries = entries
        legacyEntries["700:1:42"] = entry
        json["entries"] = legacyEntries
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test("旧日志缺少新字段照常解码")
    func legacyJournalWithoutNewFieldsDecodes() throws {
        let journal = try SessionJournal.decode(legacyJournalData(state: "written"))
        let entry = try #require(journal.entries["700:1:42"])
        #expect(entry.state == .written)
        #expect(entry.plannedFrame == nil)
        #expect(entry.state.requiresRestore)
        #expect(entry.originalFrame == original)
    }

    @Test("无法识别的旧状态按需要恢复处理，不当成空日志")
    func unknownStateIsConservative() throws {
        let journal = try SessionJournal.decode(legacyJournalData(state: "someFutureState"))
        let entry = try #require(journal.entries["700:1:42"])
        #expect(entry.state == .failed)
        #expect(entry.state.requiresRestore)
        #expect(entry.failureReason != nil)
        #expect(journal.unfinished.count == 1)
    }

    @Test("prune 只清指定会话中已结束的条目")
    func pruneKeepsOtherSessionsAndUnfinished() {
        let sessionA = UUID()
        let sessionB = UUID()
        var journal = SessionJournal(sessionID: sessionA)
        let settledA = WindowTransaction(sessionID: sessionA, identity: WindowIdentity.test(700, 1), bundleID: nil,
                                         originalFrame: original, originalDisplayID: 1).markingRestored()
        let pendingA = WindowTransaction(sessionID: sessionA, identity: WindowIdentity.test(700, 2), bundleID: nil,
                                         originalFrame: original, originalDisplayID: 1)
            .markingWritten(readBack: provisional, displayID: 1)
        let settledB = WindowTransaction(sessionID: sessionB, identity: WindowIdentity.test(700, 3), bundleID: nil,
                                         originalFrame: original, originalDisplayID: 1).markingRestored()
        for item in [settledA, pendingA, settledB] { journal.apply(item) }
        journal.prune(sessionID: sessionA, settledIdentities: [settledA.identity, pendingA.identity, settledB.identity])
        #expect(journal.entries[settledA.identity.journalKey] == nil)
        // 同一会话里仍未恢复的必须留下，其他会话的一条都不许动。
        #expect(journal.entries[pendingA.identity.journalKey] != nil)
        #expect(journal.entries[settledB.identity.journalKey] != nil)
    }

    @Test("未完成事务按创建顺序列出")
    func unfinishedOrdering() {
        var journal = SessionJournal(sessionID: UUID())
        let first = WindowTransaction(sessionID: journal.sessionID, identity: WindowIdentity.test(700, 1), bundleID: nil,
                                      originalFrame: original, originalDisplayID: 1, created: Date(timeIntervalSince1970: 100))
        let second = WindowTransaction(sessionID: journal.sessionID, identity: WindowIdentity.test(700, 2), bundleID: nil,
                                       originalFrame: original, originalDisplayID: 1, created: Date(timeIntervalSince1970: 50))
        journal.apply(first.markingWritten(readBack: provisional, displayID: 1))
        journal.apply(second)
        #expect(journal.unfinished.count == 1)
        #expect(journal.unfinished.first?.identity.windowID == 1)
    }

    @Test("进程重启或用户已自行改动时跳过自动恢复")
    func conservativeRecovery() {
        let entry = transaction { $0.markingWritten(readBack: provisional, displayID: 1) }

        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: provisional, liveness: .processExited,
                                       isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false) == .skipProcessRestarted)
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: CGRect(x: 20, y: 20, width: 500, height: 400),
                                       liveness: .alive, isOriginalDisplayLive: true,
                                       clampedFrame: nil, preserveUserGeometry: false)
                == .skipUserMoved(current: CGRect(x: 20, y: 20, width: 500, height: 400)))
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: original, liveness: .alive,
                                       isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false) == .skipAlreadyRestored)
        // 确认关闭才允许判 gone。
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: nil, liveness: .closedWindow,
                                       isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false) == .skipWindowGone)
        // 权限丢失 / 句柄暂不可读不是"窗口消失"：不写也不删。
        let deferred = RecoveryPlanner.decide(entry: entry, currentFrame: nil, liveness: .unknown(reason: "缺少辅助功能权限"),
                                              isOriginalDisplayLive: true, clampedFrame: nil, preserveUserGeometry: false)
        #expect(deferred == .deferRestore(reason: "缺少辅助功能权限"))
        #expect(!deferred.shouldWriteAX)
        #expect(deferred.settledOutcome?.isSettled == false)
        let decided = RecoveryPlanner.decide(entry: entry, currentFrame: provisional.offsetBy(dx: 1, dy: 1),
                                             liveness: .alive, isOriginalDisplayLive: true,
                                             clampedFrame: nil, preserveUserGeometry: false)
        #expect(decided == .restore(to: original))
        #expect(decided.shouldWriteAX)
        #expect(decided.frame == original)
    }

    @Test("计划已落盘但未确认写入时同样保守判定")
    func plannedStateIsCheckedAgainstPlannedFrame() {
        let entry = transaction { $0.markingPlanned(frame: provisional, displayID: 1) }
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: original, liveness: .alive,
                                       isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false) == .skipAlreadyRestored)
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: provisional, liveness: .alive,
                                       isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false) == .restore(to: original))
        // 既不是原 frame 也不是计划 frame：不擅自覆盖。
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: CGRect(x: 10, y: 10, width: 100, height: 100),
                                       liveness: .alive, isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false)
                == .skipUserMoved(current: CGRect(x: 10, y: 10, width: 100, height: 100)))
    }

    @Test("自动恢复重试有上限：达到后停止擅自写入，但记录与恢复信息保留")
    func boundedRestoreRetries() {
        let exhausted = transaction { $0.markingWritten(readBack: provisional, displayID: 1) }
            .markingFailed("AX 拒绝写入")
            .markingFailed("AX 拒绝写入")
            .markingFailed("AX 拒绝写入")
        #expect(exhausted.restoreAttempts == RecoveryPlanner.autoRestoreAttemptLimit)
        let decided = RecoveryPlanner.decide(entry: exhausted, currentFrame: provisional, liveness: .alive,
                                             isOriginalDisplayLive: true, clampedFrame: nil,
                                             preserveUserGeometry: false)
        #expect(!decided.shouldWriteAX)
        #expect(decided.settledOutcome?.isSettled == false)
        #expect(decided.settledOutcome?.message.contains("人工") == true)
    }

    @Test("从未写入的事务不需要恢复")
    func preparedTransactionSkips() {
        let entry = transaction()
        #expect(RecoveryPlanner.decide(entry: entry, currentFrame: original, liveness: .alive,
                                       isOriginalDisplayLive: true, clampedFrame: nil,
                                       preserveUserGeometry: false) == .skipNeverWritten)
    }

    @Test("显示器断开后夹取到存活屏幕")
    func displayDisconnectClamps() {
        let entry = WindowTransaction(sessionID: UUID(), identity: WindowIdentity.test(700, 42), bundleID: nil,
                                      originalFrame: CGRect(x: 1_600, y: 0, width: 900, height: 600),
                                      originalDisplayID: 2)
            .markingWritten(readBack: CGRect(x: 1_600, y: 0, width: 1_400, height: 860), displayID: 2)
        let clamped = CGRect(x: 300, y: 40, width: 900, height: 600)
        let decided = RecoveryPlanner.decide(entry: entry,
                                             currentFrame: CGRect(x: 1_600, y: 0, width: 1_400, height: 860),
                                             liveness: .alive, isOriginalDisplayLive: false,
                                             clampedFrame: clamped, preserveUserGeometry: false)
        #expect(decided == .clampAndRestore(to: clamped))
        #expect(decided.frame == clamped)
    }

    @Test("保留手动尺寸时不回到进入前大小")
    func userOverridePreservedWhenRequested() {
        let override = CGRect(x: 300, y: 300, width: 1_000, height: 700)
        let entry = transaction { $0.markingWritten(readBack: provisional, displayID: 1).withUserOverride(override) }
        #expect(entry.restoreTargetFrame(preserveUserGeometry: true) == override)
        #expect(entry.restoreTargetFrame(preserveUserGeometry: false) == original)
        let decision = RecoveryPlanner.decide(entry: entry, currentFrame: override, liveness: .alive,
                                              isOriginalDisplayLive: true, clampedFrame: nil,
                                              preserveUserGeometry: true)
        #expect(decision == .skipPreserveUserGeometry(keep: override))
        #expect(decision.settledOutcome == .keptUserGeometry)
    }

    @Test("逐条恢复结果区分'可结束'与'必须保留'")
    func restoreOutcomeSettling() {
        #expect(RestoreOutcome.restored.isSettled)
        #expect(RestoreOutcome.alreadyAtOriginal.isSettled)
        #expect(RestoreOutcome.windowGone.isSettled)
        #expect(RestoreOutcome.userMoved(current: original).isSettled)
        #expect(!RestoreOutcome.constrained(deviation: 12).isSettled)
        #expect(!RestoreOutcome.rejected("错误码 -25205").isSettled)
        #expect(!RestoreOutcome.unreadable.isSettled)
        #expect(!RestoreOutcome.notAttempted("缺少辅助功能权限").isSettled)
        let batch = RestoreBatchResult(token: TransitionToken(generation: 1), items: [
            RestoreItemResult(identity: WindowIdentity.test(700, 1), outcome: .restored, applicationName: "A"),
            RestoreItemResult(identity: WindowIdentity.test(700, 2), outcome: .unreadable, applicationName: "B"),
        ])
        #expect(batch.settledIdentities == [WindowIdentity.test(700, 1)])
        #expect(batch.unresolvedIdentities == [WindowIdentity.test(700, 2)])
        #expect(batch.hasUnresolved)
    }
}

@Suite("CaptureLifecycle")
struct CaptureLifecycleTests {
    @Test("信箱只保留最新一帧")
    func mailboxKeepsLatestOnly() {
        let mailbox = FrameMailbox<Int>()
        let generation = mailbox.currentGeneration
        for frame in 1...12 { mailbox.publish(frame, generation: generation, at: Date()) }
        #expect(mailbox.pendingCount == 1)
        var last = mailbox.latestIfChanged(aboveVersion: 0)
        var versions: [UInt64] = []
        while let value = last {
            versions.append(value.version)
            #expect(value.payload == 12)
            last = mailbox.latestIfChanged(aboveVersion: value.version)
        }
        #expect(versions.count == 1)
        #expect(mailbox.replacedCount == 11)
    }

    @Test("停止后晚到的帧因代际不匹配被忽略")
    func lateFramesIgnoredAfterStop() {
        let mailbox = FrameMailbox<Int>()
        let old = mailbox.currentGeneration
        mailbox.publish(1, generation: old, at: Date())
        let new = mailbox.beginRun(clearingFrame: true)
        #expect(!mailbox.publish(2, generation: old, at: Date()))
        #expect(mailbox.pendingCount == 0)
        #expect(mailbox.staleCount == 1)
        #expect(mailbox.publish(3, generation: new, at: Date()))
        #expect(mailbox.latestIfChanged(aboveVersion: 0)?.payload == 3)
    }

    @Test("重开运行保留最后一帧，销毁窗口才丢弃")
    func reopenedRunKeepsLastFrameButReleaseDropsIt() {
        let mailbox = FrameMailbox<Int>()
        let first = mailbox.currentGeneration
        mailbox.publish(11, generation: first, at: Date())
        // 最小化/关闭再打开：新代次旧帧失效，但画面要接着显示，不能凭空变黑。
        let second = mailbox.beginRun()
        #expect(mailbox.pendingCount == 1)
        #expect(!mailbox.publish(12, generation: first, at: Date()))
        #expect(mailbox.latestIfChanged(aboveVersion: 0)?.payload == 11)
        #expect(mailbox.publish(13, generation: second, at: Date()))
        #expect(mailbox.latestIfChanged(aboveVersion: 0)?.payload == 13)
        // 窗口真销毁：代次推进 + 清空。
        mailbox.release()
        #expect(mailbox.pendingCount == 0)
        #expect(!mailbox.publish(14, generation: second, at: Date()))
    }

    @Test("并发写入不会形成队列")
    func concurrentPublishStaysBounded() async {
        let mailbox = FrameMailbox<Int>()
        let generation = mailbox.currentGeneration
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<500 {
                group.addTask { mailbox.publish(index, generation: generation, at: Date()) }
            }
        }
        #expect(mailbox.pendingCount == 1)
        #expect(mailbox.publishedCount == 500)
    }

    @Test("重复移除与清理是幂等的")
    func repeatedClearIsIdempotent() {
        let mailbox = FrameMailbox<Int>()
        mailbox.publish(1, generation: mailbox.currentGeneration, at: Date())
        mailbox.clear()
        mailbox.clear()
        #expect(mailbox.pendingCount == 0)
        #expect(mailbox.latestIfChanged(aboveVersion: 0) == nil)
    }

    @Test("降级顺序先帧率、再分辨率、最后轮询")
    func degradationLadder() {
        #expect(CaptureBudget.nextAction(currentFPS: 8, currentWidth: 960, streams: 20, streamSoftLimit: 12,
                                         thermal: .nominal, isPriority: false) == .lowerFPS(5))
        #expect(CaptureBudget.nextAction(currentFPS: 3, currentWidth: 960, streams: 20, streamSoftLimit: 12,
                                         thermal: .nominal, isPriority: false) == .lowerOutputWidth(720))
        #expect(CaptureBudget.nextAction(currentFPS: 3, currentWidth: 400, streams: 20, streamSoftLimit: 12,
                                         thermal: .serious, isPriority: false) == .poll(intervalMilliseconds: 1_000))
        let polled: CapturePhase = BudgetAction.poll(intervalMilliseconds: 2_000).displayedPhase
        if case let .lowFrequency(interval) = polled {
            #expect(interval == 2_000)
        } else {
            Issue.record("轮询必须显示为低频更新，不能标成实时")
        }
    }

    @Test("优先刷新窗口在降级时保留")
    func priorityWindowKeepsRefresh() {
        #expect(CaptureBudget.nextAction(currentFPS: 8, currentWidth: 960, streams: 20, streamSoftLimit: 12,
                                         thermal: .nominal, isPriority: true) == .keep)
    }

    @Test("几秒没有新帧不算捕获失败")
    func idleFrameIsNotFailure() {
        var record = Fixtures.record(700, 3)
        record.capture = .live
        record.lastValidFrameDate = Date(timeIntervalSinceNow: -30)
        #expect(CaptureBudget.capturePhase(for: record, now: Date()) == .live)
        record.isMinimized = true
        #expect(CaptureBudget.capturePhase(for: record, now: Date()) == .pausedMinimized)
        record.capture = .notCapturable("protected")
        #expect(CaptureBudget.capturePhase(for: record, now: Date()) == .notCapturable("protected"))
    }

    @Test("输出宽度受质量上限约束并保持源宽高比")
    func streamConfigSizing() {
        let config = StreamConfig.build(cellWidth: 800, backingScale: 2, sourceSize: CGSize(width: 1_920, height: 1_080),
                                        tier: .balanced)
        #expect(config.pixelWidth == 960)
        #expect(abs(Double(config.pixelWidth) / Double(config.pixelHeight) - 1_920.0 / 1_080.0) < 0.02)
        #expect(config.capturesAudio == false)
        #expect(config.showsCursor == false)
        #expect(config.queueDepth == 3)
        let small = StreamConfig.build(cellWidth: 120, backingScale: 2, sourceSize: CGSize(width: 800, height: 600),
                                       tier: .balanced)
        #expect(small.pixelWidth == 240)
    }

    @Test("动画中不重建流，尺寸调整合并 250ms")
    func reconfigurationDebounced() {
        let current = StreamConfig.build(cellWidth: 400, backingScale: 2, sourceSize: CGSize(width: 1_280, height: 800), tier: .balanced)
        let candidate = StreamConfig.build(cellWidth: 600, backingScale: 2, sourceSize: CGSize(width: 1_280, height: 800), tier: .balanced)
        #expect(!current.needsReconfiguration(to: candidate, elapsedSinceLastChange: 1.0, isAnimating: true))
        #expect(!current.needsReconfiguration(to: candidate, elapsedSinceLastChange: 0.1, isAnimating: false))
        #expect(current.needsReconfiguration(to: candidate, elapsedSinceLastChange: 0.3, isAnimating: false))
        #expect(!current.needsReconfiguration(to: current, elapsedSinceLastChange: 5, isAnimating: false))
    }
}

@Suite("CoordinateMapper")
struct CoordinateMapperTests {
    private var mapper: CoordinateMapper { Fixtures.mapper() }

    @Test("CG 与 AppKit 往返误差为零")
    func roundTrip() throws {
        let display = try #require(mapper.primaryDisplay)
        let rect = CGRect(x: 140, y: 220, width: 900, height: 600)
        let flipped = mapper.cgToAppKit(rect)
        #expect(mapper.appKitToCg(flipped) == rect)
        #expect(abs(flipped.maxY - display.frame.height + rect.minY) < 0.001)
    }

    @Test("负坐标与上下排列屏幕使用同一翻转基准")
    func secondaryDisplaysShareFlipBasis() {
        let mapper = CoordinateMapper(displays: [
            DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                        visibleFrame: CGRect(x: 0, y: 64, width: 1_512, height: 918), backingScale: 2, isPrimary: true),
            DisplayInfo(id: 2, frame: CGRect(x: -1_920, y: -300, width: 1_920, height: 1_080),
                        visibleFrame: CGRect(x: -1_920, y: -300, width: 1_920, height: 1_040), backingScale: 1, isPrimary: false)
        ])
        let rect = CGRect(x: -1_800, y: -200, width: 800, height: 500)
        let flipped = mapper.cgToAppKit(rect)
        #expect(mapper.appKitToCg(flipped) == rect)
        #expect(flipped.origin.y > 0)
    }

    @Test("跨屏窗口归属交集面积最大的屏幕且不重复")
    func ownerDisplayByMaxIntersection() {
        let mapper = CoordinateMapper(displays: [
            DisplayInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                        visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000), backingScale: 2, isPrimary: true),
            DisplayInfo(id: 2, frame: CGRect(x: 1_000, y: 0, width: 1_000, height: 1_000),
                        visibleFrame: CGRect(x: 1_000, y: 0, width: 1_000, height: 1_000), backingScale: 1, isPrimary: false)
        ])
        let leftHeavy = CGRect(x: 600, y: 100, width: 500, height: 400)
        #expect(mapper.ownerDisplay(of: leftHeavy)?.id == 1)
        let rightHeavy = CGRect(x: 1_100, y: 100, width: 500, height: 400)
        #expect(mapper.ownerDisplay(of: rightHeavy)?.id == 2)
    }

    @Test("原屏幕不可达时夹取到存活屏幕可用区")
    func clampToLiveDisplay() {
        let visible = CGRect(x: 0, y: 0, width: 1_512, height: 982)
        let clamped = mapper.clamp(CGRect(x: 4_000, y: 3_000, width: 900, height: 600), to: 1)
        #expect(visible.contains(clamped))
        #expect(clamped.size == CGSize(width: 900, height: 600))
        let shifted = mapper.clamp(CGRect(x: -400, y: 700, width: 900, height: 600), to: 1)
        #expect(visible.contains(shifted))
    }

    @Test("点与像素不允许混用")
    func pixelConversion() {
        #expect(mapper.pixelSize(for: CGRect(x: 0, y: 0, width: 480, height: 300), backingScale: 2) == CGSize(width: 960, height: 600))
        let scaled = mapper.rect(from: CGRect(x: 20, y: 40, width: 1_920, height: 1_080), scaleFactor: 2,
                                 in: CGRect(x: 0, y: 0, width: 960, height: 540))
        #expect(scaled == CGRect(x: 10, y: 20, width: 960, height: 540))
    }
}

@Suite("FocusGeometry")
struct FocusGeometryTests {
    private let visible = CGRect(x: 0, y: 64, width: 1_512, height: 918)

    @Test("默认 86% x 88% 并居中")
    func defaultRatios() {
        let rect = FocusGeometry.targetRect(visibleFrame: visible, policy: SessionPolicy(),
                                            currentSize: CGSize(width: 800, height: 600), isResizable: true)
        #expect(abs(rect.width / visible.width - 0.86) < 0.01)
        #expect(abs(rect.height / visible.height - 0.88) < 0.01)
        #expect(abs(rect.midX - visible.midX) < 0.5)
        #expect(abs(rect.midY - visible.midY) < 0.5)
    }

    @Test("四周至少保留 32pt")
    func edgeInsetRespected() {
        var policy = SessionPolicy()
        policy.foregroundWidthRatio = 0.94
        policy.foregroundHeightRatio = 0.94
        let rect = FocusGeometry.targetRect(visibleFrame: visible, policy: policy,
                                            currentSize: CGSize(width: 800, height: 600), isResizable: true)
        #expect(rect.minX - visible.minX >= 31.9)
        #expect(visible.maxX - rect.maxX >= 31.9)
        #expect(rect.minY - visible.minY >= 31.9)
        #expect(visible.maxY - rect.maxY >= 31.9)
    }

    @Test("比例限制在 75%–94%")
    func ratiosClamped() {
        var policy = SessionPolicy()
        policy.foregroundWidthRatio = 1.4
        policy.foregroundHeightRatio = 0.2
        #expect(SessionPolicy.clamped(policy.foregroundWidthRatio) == 0.94)
        #expect(SessionPolicy.clamped(policy.foregroundHeightRatio) == 0.75)
    }

    @Test("不可调整尺寸的窗口按原尺寸居中")
    func fixedSizeWindow() {
        let rect = FocusGeometry.targetRect(visibleFrame: visible, policy: SessionPolicy(),
                                            currentSize: CGSize(width: 600, height: 400), isResizable: false)
        #expect(rect.size == CGSize(width: 600, height: 400))
        #expect(abs(rect.midX - visible.midX) < 0.5)
    }

    @Test("减少动态效果时改用短淡化，自定义时长夹到 160–300ms")
    func reduceMotionShortensAnimation() {
        var policy = SessionPolicy()
        policy.reduceMotion = true
        #expect(policy.animationMS(isExpand: true, style: .standard) <= 120)
        #expect(policy.animationMS(isExpand: false, style: .standard) <= 120)
        let loose = OverviewStyle(margin: 20, gap: 14, expandAnimationMS: 400, collapseAnimationMS: 20)
        #expect(SessionPolicy().animationMS(isExpand: true, style: loose) == 300)
        #expect(SessionPolicy().animationMS(isExpand: false, style: loose) == 160)
    }
}
