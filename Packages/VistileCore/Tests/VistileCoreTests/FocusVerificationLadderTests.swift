import Testing
@testable import VistileCore

/// 判定阶梯的行为约定（方案 §14、§12.2）：读不到与摇摆不是事实，只有连续两次
/// 读到同一个"非目标"身份才确证失焦。0.1.10+18 的静默退出就死在"单次读不到＝离开"上。
@Suite("焦点核对阶梯")
struct FocusVerificationLadderTests {
    private let target = WindowIdentity.test(100, 1)
    private let sibling = WindowIdentity.test(100, 2)
    private let other = WindowIdentity.test(200, 3)

    @Test("一次都没读到：不确定，不退出")
    func allUnreadable() {
        #expect(FocusVerificationLadder.verdict(target: target, reads: [nil, nil, nil]) == .inconclusive)
        #expect(FocusVerificationLadder.verdict(target: target, reads: [nil]) == .inconclusive)
    }

    @Test("只读到一次别的身份：还不足以确证（这就是 +18 那轮的形状）")
    func singleOtherReadIsNotEnough() {
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling]) == .inconclusive)
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling, nil]) == .inconclusive)
        #expect(FocusVerificationLadder.verdict(target: target, reads: [nil, other]) == .inconclusive)
    }

    @Test("连续两次读到同一个别的身份：确证失焦")
    func stableOtherReadIsConfirmed() {
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling, sibling]) == .confirmedLost(sibling))
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling, sibling, nil]) == .confirmedLost(sibling))
        #expect(FocusVerificationLadder.verdict(target: target, reads: [nil, other, other]) == .confirmedLost(other))
    }

    @Test("读数摇摆或换了两个不同的身份：不确定")
    func flickeringReadsAreInconclusive() {
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling, nil, sibling]) == .inconclusive)
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling, other, nil]) == .inconclusive)
    }

    @Test("读到过目标：按在场处理（瞬态之后回来了）")
    func targetSeenMeansPresent() {
        #expect(FocusVerificationLadder.verdict(target: target, reads: [sibling, target]) == .present)
        #expect(FocusVerificationLadder.verdict(target: target, reads: [target]) == .present)
    }
}
