import Foundation

/// 「只提升被点窗口」的判据（P0-3，方案 §12.1）。
///
/// 判据只能在**两次读数都还在屏上的窗口**这个共同参照系里比。全局 `CGWindowList` 的顺序表
/// 会被无关窗口的开关改动：2026-10-16 16:37 那轮访达报"兄弟 #21→#20 一起被提升"，
/// 而目标自己从 #23 到了 #7——兄弟那一格是别的窗口关掉造成的余波，不是提升。
///
/// 换成共同参照系不等于把验收条件改弱：兄弟只要对任何一个仍在场的窗口占了便宜（原本在它前面的
/// 现在在它后面），仍然判失败。这一点由 `TargetRaiseAuditTests` 钉住。
public enum TargetRaiseAudit {
    public struct Result: Equatable, Sendable {
        /// 参与比较的窗口数（两次读数都在屏上）。
        public let sharedCount: Int
        public let beforeCount: Int
        public let afterCount: Int
        /// 目标是否真的对某个仍在场的窗口超过了它。
        public let targetMovedUp: Bool
        /// 兄弟是否一个便宜都没占。
        public let siblingNotRaised: Bool
        /// 结束时目标是否排在兄弟之前。
        public let targetAboveSibling: Bool
        /// 目标或兄弟有一次不在屏上时无法判定，不能把"读不到"当成通过或失败。
        public let measurable: Bool

        public var passed: Bool { measurable && targetMovedUp && siblingNotRaised && targetAboveSibling }

        /// 失败原因。写进矩阵"已知限制"的那句必须就是这一条：
        /// 以前探针无条件写"AX Raise 后同应用兄弟窗口被一起提升"，
        /// 而 0.1.5 报告里 Chrome 的真实原因是"目标没被提升"，两种缺陷被同一句话糊过去了。
        public var failureCause: String {
            if !measurable { return "目标或兄弟有一次不在屏上，无法判定" }
            if !targetMovedUp { return "目标没被提升" }
            if !siblingNotRaised { return "兄弟一起被提升" }
            if !targetAboveSibling { return "目标没在兄弟之上" }
            return ""
        }

        /// 兄弟实际赢过谁：失败时要把对象写出来，否则报告只有一句"被一起提升"，无从复现。
        public let siblingGainedOver: [UInt32]
    }

    public static func evaluate(target: UInt32,
                                sibling: UInt32,
                                before: [UInt32: Int],
                                after: [UInt32: Int]) -> Result {
        let shared = before.keys.filter { after[$0] != nil }
        let measurable = [target, sibling].allSatisfy { before[$0] != nil && after[$0] != nil }
            && !shared.isEmpty
        guard measurable else {
            return Result(sharedCount: shared.count,
                          beforeCount: before.count,
                          afterCount: after.count,
                          targetMovedUp: false,
                          siblingNotRaised: false,
                          targetAboveSibling: false,
                          measurable: false,
                          siblingGainedOver: [])
        }
        let gainedByTarget = windowsThatFellBehind(target, in: shared, before: before, after: after)
        // 目标被提到兄弟前面正是这一项要发生的事，所以它不算兄弟"占了便宜"。
        let gainedBySibling = windowsThatFellBehind(sibling, in: shared, before: before, after: after)
            .filter { $0 != target }
        return Result(sharedCount: shared.count,
                      beforeCount: before.count,
                      afterCount: after.count,
                      targetMovedUp: !gainedByTarget.isEmpty,
                      siblingNotRaised: gainedBySibling.isEmpty,
                      targetAboveSibling: (after[target] ?? .max) < (after[sibling] ?? .max),
                      measurable: true,
                      siblingGainedOver: gainedBySibling.sorted())
    }

    /// 原本排在 `subject` 前面、现在被它甩到后面的窗口——即 subject 在对谁占便宜。
    private static func windowsThatFellBehind(_ subject: UInt32,
                                              in shared: [UInt32],
                                              before: [UInt32: Int],
                                              after: [UInt32: Int]) -> [UInt32] {
        guard let subjectBefore = before[subject], let subjectAfter = after[subject] else { return [] }
        return shared.compactMap { window in
            guard window != subject,
                  let wasIndex = before[window], wasIndex < subjectBefore,
                  let nowIndex = after[window], nowIndex >= subjectAfter else { return nil }
            return window
        }
    }
}
