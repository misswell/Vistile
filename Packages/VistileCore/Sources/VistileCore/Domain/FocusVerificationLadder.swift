/// 受控窗口"是否还在前台"的判定阶梯（方案 §14；读取原则见 §12.2「读不到 ≠ 不可以」）。
/// AX 单次读回既可能超时（nil），也可能赶上目标应用自己的激活/抬升瞬态；
/// 只有连续两次读到同一个"非目标"身份才算确证失焦。读不到一律算不确定——
/// 不许据此退出会话（0.1.10+18 实测：交换刚提交后我们自己的前景确认触发的焦点通知，
/// 赶上一次读回失败，被当成用户离开整段会话静默退出）。
public enum FocusVerificationLadder {
    public enum Verdict: Equatable {
        /// 读到过目标：仍在前台（瞬态之后回来了）。
        case present
        /// 确证失焦：连续两次读到同一个别的身份。
        case confirmedLost(WindowIdentity)
        /// 读不到或读数摇摆：不是事实，什么都不做，留给后续通知再核对。
        case inconclusive
    }

    public static func verdict(target: WindowIdentity, reads: [WindowIdentity?]) -> Verdict {
        if reads.contains(where: { $0 == target }) { return .present }
        for index in 1..<reads.count {
            guard let current = reads[index], current != target,
                  let previous = reads[index - 1], previous == current else { continue }
            return .confirmedLost(current)
        }
        return .inconclusive
    }
}
