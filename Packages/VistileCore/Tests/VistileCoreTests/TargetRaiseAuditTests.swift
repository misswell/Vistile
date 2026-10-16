import Testing
import Foundation
@testable import VistileCore

/// P0-3 判据本身。这些用例里既有"必须仍然红"的真缺陷，也有"绝对下标会误判成红"的列表余波：
/// 两边都钉住，才既不会放过连带提升，也不会因为无关窗口开关就把产品判死。
@Suite("只提升被点窗口的判据")
struct TargetRaiseAuditTests {
    // MARK: - 通过

    @Test("目标升到兄弟之前、兄弟一个便宜都没占")
    func cleanRaise() {
        let before: [UInt32: Int] = [10: 0, 20: 1, 30: 2]   // 10=别的应用，20=兄弟，30=目标
        let after: [UInt32: Int] = [10: 0, 30: 1, 20: 2]
        let result = TargetRaiseAudit.evaluate(target: 30, sibling: 20, before: before, after: after)
        #expect(result.passed)
        #expect(result.failureCause.isEmpty)
    }

    @Test("无关窗口关闭把兄弟的绝对下标挪小一格，不算连带提升")
    func closedWindowsAboveSiblingAreNotARaise() {
        // 复现 2026-10-16 16:37 那轮访达的形状：目标 #23→#7，兄弟 #21→#20。
        // 绝对下标下兄弟"变小了"会被判失败；实际上兄弟只被目标超过，对任何仍在场的窗口都没占便宜。
        let before: [UInt32: Int] = [10: 0, 11: 1, 12: 2, 20: 3, 30: 4]
        let after: [UInt32: Int] = [10: 0, 30: 1, 20: 2]     // 11、12 这两个无关窗口关了
        #expect((after[20] ?? 0) < (before[20] ?? 0), "绝对下标确实变小——旧判据就是在这里误判的")
        let result = TargetRaiseAudit.evaluate(target: 30, sibling: 20, before: before, after: after)
        #expect(result.measurable)
        #expect(result.siblingNotRaised)
        #expect(result.passed)
        #expect(result.sharedCount == 3)
    }

    // MARK: - 必须仍然红

    @Test("兄弟把原本在它前面的在场窗口甩到后面，判失败")
    func siblingGenuinelyRaised() {
        // 目标与兄弟一起越过 11：目标升了，兄弟也升了。
        let before: [UInt32: Int] = [10: 0, 11: 1, 20: 2, 30: 3]
        let after: [UInt32: Int] = [10: 0, 30: 1, 20: 2, 11: 3]
        let result = TargetRaiseAudit.evaluate(target: 30, sibling: 20, before: before, after: after)
        #expect(!result.passed)
        #expect(result.targetMovedUp)
        #expect(!result.siblingNotRaised)
        #expect(result.failureCause == "兄弟一起被提升")
        #expect(result.siblingGainedOver == [11])
    }

    @Test("目标一动没动就是没被提升")
    func targetNotRaised() {
        // 复现同一轮 Chrome：目标 #7→#7、兄弟 #8→#8，两次读数完全一致。
        let before: [UInt32: Int] = [10: 0, 20: 1, 30: 2]
        let after: [UInt32: Int] = [10: 0, 20: 1, 30: 2]
        let result = TargetRaiseAudit.evaluate(target: 30, sibling: 20, before: before, after: after)
        #expect(!result.passed)
        #expect(!result.targetMovedUp)
        #expect(result.failureCause == "目标没被提升")
    }

    @Test("目标升了但没升到兄弟之前")
    func targetStillBehindSibling() {
        let before: [UInt32: Int] = [10: 0, 20: 1, 11: 2, 30: 3]
        let after: [UInt32: Int] = [10: 0, 20: 1, 30: 2, 11: 3]
        let result = TargetRaiseAudit.evaluate(target: 30, sibling: 20, before: before, after: after)
        #expect(!result.passed)
        #expect(result.targetMovedUp)
        #expect(result.siblingNotRaised)
        #expect(result.failureCause == "目标没在兄弟之上")
    }

    @Test("目标或兄弟有一次不在屏上时记为不可判定，不当成通过")
    func unreadableIsNotPass() {
        let before: [UInt32: Int] = [10: 0, 20: 1, 30: 2]
        let after: [UInt32: Int] = [10: 0, 20: 1]
        let result = TargetRaiseAudit.evaluate(target: 30, sibling: 20, before: before, after: after)
        #expect(!result.measurable)
        #expect(!result.passed)
        #expect(result.failureCause == "目标或兄弟有一次不在屏上，无法判定")
    }
}
