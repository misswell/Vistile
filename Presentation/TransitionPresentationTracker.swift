import Foundation
import VistileCore

/// Per-scene presentation facts. Completion never delays geometry or animation handoff.
@MainActor
final class TransitionPresentationTracker {
    private let anchor: TimeInterval
    private let anchoredAtRealInput: Bool
    private var frameBudgetMS: Double
    private var observedBudgetMS: Double?
    private let report: (TransitionFlightFacts, FrameIntervalStats?) -> Void
    private var submissions: [UInt64: RendererSubmission] = [:]
    private var presentations: [UInt64: TimeInterval] = [:]
    private var gpuTimesMS: [Double] = []
    private var ticks = 0
    private var ended = false
    private var reported = false
    private var deadline: Task<Void, Never>?

    init(anchor: TimeInterval, anchoredAtRealInput: Bool, frameBudgetMS: Double,
         report: @escaping (TransitionFlightFacts, FrameIntervalStats?) -> Void) {
        self.anchor = anchor
        self.anchoredAtRealInput = anchoredAtRealInput
        self.frameBudgetMS = FrameIntervalStats.normalizedBudget(frameBudgetMS)
        self.report = report
    }

    func submitted(_ submission: RendererSubmission) {
        guard !ended, !reported else { return }
        submissions[submission.identifier] = submission
    }

    func updateFrameBudget(milliseconds: Double) {
        guard !reported, milliseconds.isFinite, milliseconds > 0 else { return }
        observedBudgetMS = max(observedBudgetMS ?? milliseconds, milliseconds)
        frameBudgetMS = observedBudgetMS ?? frameBudgetMS
    }

    func presented(_ event: RendererPresentation) {
        guard !reported, submissions[event.submission.identifier] != nil,
              presentations[event.submission.identifier] == nil,
              event.presentedAt.isFinite, event.presentedAt > 0 else { return }
        presentations[event.submission.identifier] = event.presentedAt
        reportIfComplete()
    }

    func completedGPU(milliseconds: Double) {
        guard !reported, milliseconds.isFinite, milliseconds > 0 else { return }
        gpuTimesMS.append(milliseconds)
    }

    func finish(ticks: Int) {
        guard !ended else { return }
        ended = true
        self.ticks = ticks
        if presentations.count == submissions.count {
            reportNow()
        } else {
            // A dropped drawable may never report presentation. Bound only telemetry waiting.
            deadline = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                self?.reportNow()
            }
        }
    }

    /// Finalize the exact facts available on interruption; never borrow the next scene's frames.
    func close(ticks: Int) {
        self.ticks = ticks
        ended = true
        reportNow()
    }

    private func reportIfComplete() {
        if ended, presentations.count == submissions.count { reportNow() }
    }

    private func reportNow() {
        guard !reported else { return }
        reported = true
        deadline?.cancel()
        deadline = nil
        let times = presentations.values.sorted()
        let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
        let firstSubmission = submissions.values.map(\.submittedAt).min()
        let firstPresentation = times.first
        let orderedGPU = gpuTimesMS.sorted()
        let gpuP95 = orderedGPU.isEmpty ? nil : orderedGPU[Int(Double(orderedGPU.count - 1) * 0.95)]
        let facts = TransitionFlightFacts(
            firstPresentDelayMS: firstPresentation.map { max(0, ($0 - anchor) * 1000) },
            ticks: ticks, presentedFrames: presentations.count, anchoredAtRealInput: anchoredAtRealInput,
            firstSubmissionDelayMS: firstSubmission.map { max(0, ($0 - anchor) * 1000) },
            submittedFrames: submissions.count, gpuExecutionP95MS: gpuP95,
            presentationComplete: presentations.count == submissions.count, frameBudgetMS: frameBudgetMS)
        report(facts, FrameIntervalStats.measure(intervals, frameBudgetMS: frameBudgetMS))
    }

    deinit { deadline?.cancel() }
}
