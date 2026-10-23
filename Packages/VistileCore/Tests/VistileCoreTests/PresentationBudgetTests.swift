import XCTest
@testable import VistileCore

final class PresentationBudgetTests: XCTestCase {
    func testOneNormal60HzIntervalIsNotLoggedAsASlowFrame() {
        XCTAssertGreaterThan(FrameIntervalStats.slowFrameThreshold(frameBudgetMS: 1000.0 / 60), 1000.0 / 60)
    }

    func testTheSame12MillisecondIntervalMisses120HzButFits60HzBudget() throws {
        let intervals = Array(repeating: 12.0, count: 20)
        XCTAssertTrue(try XCTUnwrap(FrameIntervalStats.measure(intervals, frameBudgetMS: 1000.0 / 60)).meetsTarget)
        XCTAssertFalse(try XCTUnwrap(FrameIntervalStats.measure(intervals, frameBudgetMS: 1000.0 / 120)).meetsTarget)
    }
}
