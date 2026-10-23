import ApplicationServices
import XCTest
@testable import Vistile

private final class AXExecutorEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@MainActor
final class AXExecutorTests: XCTestCase {
    func testReadBackRetryDoesNotBlockOtherAXWork() async {
        let executor = AXExecutor()
        let firstReadStarted = expectation(description: "first read attempt started")
        firstReadStarted.assertForOverFulfill = false

        let retry = Task {
            await AXReadBackRetry.read(attempts: 3, gap: 0.3) {
                await executor.submit {
                    firstReadStarted.fulfill()
                    return nil as Int?
                }
            }
        }

        await fulfillment(of: [firstReadStarted], timeout: 1)
        let started = CACurrentMediaTime()
        let probe = await executor.submit { true }
        let elapsed = CACurrentMediaTime() - started

        XCTAssertTrue(probe)
        XCTAssertLessThan(elapsed, 0.15,
                          "A delayed read-back retry must yield the shared AX queue")
        _ = await retry.value
    }

    func testInteractiveAXWorkRunsBetweenDiscoveryJobsWithoutPreemptingActiveJob() async {
        let executor = AXExecutor()
        let recorder = AXExecutorEventRecorder()
        let activeStarted = expectation(description: "active discovery job started")
        let releaseActive = DispatchSemaphore(value: 0)

        let active = Task {
            await executor.submit(priority: .discovery) {
                recorder.append("active-start")
                activeStarted.fulfill()
                releaseActive.wait()
                recorder.append("active-end")
            }
        }
        await fulfillment(of: [activeStarted], timeout: 1)

        let discovery = Task {
            await executor.submit(priority: .discovery) { recorder.append("discovery") }
        }
        await waitForQueuedJobs(1, executor: executor)

        let interactive = Task {
            await executor.submit(priority: .interactive) { recorder.append("interactive") }
        }
        await waitForQueuedJobs(2, executor: executor)
        XCTAssertEqual(recorder.snapshot, ["active-start"], "An active AX job must finish atomically")

        releaseActive.signal()
        await active.value
        await interactive.value
        await discovery.value

        XCTAssertEqual(recorder.snapshot,
                       ["active-start", "active-end", "interactive", "discovery"])
    }

    func testUnexpectedAXTypesAreIgnoredInsteadOfTrapping() throws {
        var size = CGSize(width: 320, height: 200)
        let sizeValue = try XCTUnwrap(AXValueCreate(.cgSize, &size))
        XCTAssertNil(AXElementValues.point(from: sizeValue))

        var point = CGPoint(x: 20, y: 30)
        let pointValue = try XCTUnwrap(AXValueCreate(.cgPoint, &point))
        XCTAssertNil(AXElementValues.size(from: pointValue))
        XCTAssertNil(AXElementValues.windowElement(from: NSNumber(value: 42)))
    }

    private func waitForQueuedJobs(_ count: Int, executor: AXExecutor) async {
        for _ in 0..<100 {
            if executor.queuedJobCount >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Expected at least \(count) queued AX jobs")
    }
}
