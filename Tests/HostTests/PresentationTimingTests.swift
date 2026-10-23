import XCTest
import Metal
import VistileCore
@testable import Vistile

final class PresentationTimingTests: XCTestCase {
    func testLongRunningMetricHistoryHasABoundedMemoryFootprint() {
        let metrics = Metrics()
        for value in 0..<(Metrics.maximumSamplesPerMetric * 2) {
            metrics.measure("repeated-transition", milliseconds: Double(value))
        }
        XCTAssertEqual(metrics.retainedSampleCount, Metrics.maximumSamplesPerMetric)
    }

    func testSubmittingAFrameDoesNotClaimItWasPresented() throws {
        let metal = try HostFixtures.metalContext()
        let renderer = try XCTUnwrap(OverviewRenderer(metal: metal))
        renderer.noteSubmission()
        XCTAssertEqual(renderer.diagnostics().presents, 0,
                       "Committing work is not evidence that pixels reached the screen")
    }

    func testOnlyTheDrawablePresentationCallbackCanConfirmPixels() throws {
        let renderer = try XCTUnwrap(OverviewRenderer(metal: HostFixtures.metalContext()))
        let drawable = ControlledPresentationDrawable()
        let submission = RendererSubmission(identifier: 1, submittedAt: 10)
        renderer.observePresentation(of: drawable, submission: submission)
        renderer.noteSubmission()
        XCTAssertEqual(renderer.diagnostics().submissions, 1)
        XCTAssertEqual(renderer.diagnostics().presents, 0)
        drawable.complete(at: 0)
        XCTAssertEqual(renderer.diagnostics().presents, 0, "Dropped frames have no presented timestamp")
        drawable.complete(at: 10.016)
        XCTAssertEqual(renderer.diagnostics().presents, 1)
    }

    @MainActor
    func testPresentationFactsWaitForActualFramesAndMeasureTheirTimestamps() throws {
        var facts: TransitionFlightFacts?
        var stats: FrameIntervalStats?
        let tracker = TransitionPresentationTracker(anchor: 10, anchoredAtRealInput: true,
                                                    frameBudgetMS: 1000.0 / 60) {
            facts = $0
            stats = $1
        }
        let submissions = (1...4).map { RendererSubmission(identifier: UInt64($0), submittedAt: 10.001) }
        for submission in submissions { tracker.submitted(submission) }
        tracker.completedGPU(milliseconds: 0.75)
        tracker.finish(ticks: 4)
        XCTAssertNil(facts, "Submitting frames must not invent screen presentation")
        for index in [2, 0, 1, 3] {
            tracker.presented(RendererPresentation(submission: submissions[index],
                                                   presentedAt: 10 + Double(index + 1) / 60))
        }
        let report = try XCTUnwrap(facts)
        XCTAssertEqual(report.submittedFrames, 4)
        XCTAssertEqual(report.presentedFrames, 4)
        XCTAssertEqual(try XCTUnwrap(report.firstSubmissionDelayMS), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.firstPresentDelayMS), 1000.0 / 60, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(report.gpuExecutionP95MS), 0.75)
        XCTAssertTrue(report.presentationComplete)
        XCTAssertEqual(try XCTUnwrap(stats).p95MS, 1000.0 / 60, accuracy: 0.001)
    }

    @MainActor
    func testInterruptedSceneDoesNotBorrowTheNextScenesPresentation() throws {
        var facts: [TransitionFlightFacts] = []
        let tracker = TransitionPresentationTracker(anchor: 10, anchoredAtRealInput: true,
                                                    frameBudgetMS: 1000.0 / 120) { report, _ in facts.append(report) }
        tracker.submitted(RendererSubmission(identifier: 7, submittedAt: 10.002))
        tracker.close(ticks: 1)
        tracker.presented(RendererPresentation(submission: RendererSubmission(identifier: 8, submittedAt: 10.003),
                                               presentedAt: 10.01))
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts[0].presentedFrames, 0)
        XCTAssertFalse(facts[0].presentationComplete)
        XCTAssertNil(facts[0].firstPresentDelayMS)
    }
}

private final class ControlledPresentationDrawable: NSObject, MTLDrawable {
    private var handlers: [MTLDrawablePresentedHandler] = []
    var presentedTime: CFTimeInterval = 0
    var drawableID: Int { 1 }
    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) { handlers.append(block) }
    func complete(at timestamp: CFTimeInterval) {
        presentedTime = timestamp
        for handler in handlers { handler(self) }
    }
}
