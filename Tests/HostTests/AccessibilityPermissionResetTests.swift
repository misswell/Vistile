import Foundation
import XCTest
@testable import Vistile

@MainActor
final class AccessibilityPermissionResetTests: XCTestCase {
    func testResetIsScopedToVistileAccessibilityOnly() async throws {
        var calls = 0
        let reset = AccessibilityPermissionReset(bundleIdentifier: "com.misswell.Vistile") { executable, arguments in
            calls += 1
            XCTAssertEqual(executable.path, "/usr/bin/tccutil")
            XCTAssertEqual(arguments, ["reset", "Accessibility", "com.misswell.Vistile"])
            return 0
        }
        try await reset.reset()
        XCTAssertEqual(calls, 1)
    }

    func testUnknownApplicationCannotTriggerReset() async {
        var calls = 0
        for identifier: String? in [nil, "", "com.example.OtherApp"] {
            let reset = AccessibilityPermissionReset(bundleIdentifier: identifier) { _, _ in
                calls += 1
                return 0
            }
            do {
                try await reset.reset()
                XCTFail("An unknown application must fail closed")
            } catch { }
        }
        XCTAssertEqual(calls, 0)
    }

    func testCommandFailureIsReported() async {
        let reset = AccessibilityPermissionReset(bundleIdentifier: "com.misswell.Vistile") { _, _ in 1 }
        do {
            try await reset.reset()
            XCTFail("A failed reset must not be reported as successful")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("1"))
        }
    }

    func testLaunchFailureIsReported() async {
        let reset = AccessibilityPermissionReset(bundleIdentifier: "com.misswell.Vistile") { _, _ in
            throw NSError(domain: "ResetLaunchTest", code: 42)
        }
        do {
            try await reset.reset()
            XCTFail("A failed process launch must propagate")
        } catch {
            XCTAssertEqual((error as NSError).domain, "ResetLaunchTest")
        }
    }

    func testRepairRequestsOnlyAfterResetAndOpensSettings() async {
        let permissions = RepairPermissions()
        let repair = AccessibilityPermissionRepair(permissions: permissions) {
            permissions.events.append("settings")
        }
        await repair.repair()
        XCTAssertEqual(permissions.events, ["reset", "request", "settings"])
        XCTAssertTrue(permissions.status.screenRecording)
        XCTAssertFalse(permissions.status.accessibility, "Resetting does not grant authorization")
        XCTAssertFalse(repair.isResetting)
        XCTAssertTrue(repair.message?.contains("已清除") == true)
    }

    func testFailedRepairDoesNotRequestOrOpenSettings() async {
        let permissions = RepairPermissions()
        permissions.resetAction = { throw NSError(domain: "ResetTest", code: 1) }
        let repair = AccessibilityPermissionRepair(permissions: permissions) {
            XCTFail("A failed reset must not open settings as if it succeeded")
        }
        await repair.repair()
        XCTAssertEqual(permissions.events, ["reset"])
        XCTAssertFalse(repair.isResetting)
        XCTAssertTrue(repair.message?.contains("清除失败") == true)
    }

    func testRepeatedClickDoesNotStartAnotherReset() async {
        let permissions = RepairPermissions()
        var pending: CheckedContinuation<Void, Never>?
        permissions.resetAction = {
            await withCheckedContinuation { pending = $0 }
        }
        let repair = AccessibilityPermissionRepair(permissions: permissions, openSettings: {})
        let first = Task { await repair.repair() }
        while pending == nil { await Task.yield() }
        XCTAssertTrue(repair.isResetting)
        await repair.repair()
        XCTAssertEqual(permissions.events, ["reset"])
        pending?.resume()
        await first.value
        XCTAssertEqual(permissions.events, ["reset", "request"])
        XCTAssertFalse(repair.isResetting)
    }
}

private final class RepairPermissions: PermissionGuiding {
    var status = PermissionStatus(screenRecording: true, accessibility: false)
    var events: [String] = []
    var resetAction: () async throws -> Void = {}

    func refresh() -> PermissionStatus { status }
    func requestScreenRecording() -> Bool { status.screenRecording }
    func requestAccessibility(prompt: Bool) -> Bool {
        XCTAssertTrue(prompt)
        events.append("request")
        return status.accessibility
    }
    func resetAccessibility() async throws {
        events.append("reset")
        try await resetAction()
    }
}
