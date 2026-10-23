import AppKit
import SwiftUI
import VistileCore
import XCTest
@testable import Vistile

@MainActor
final class OnboardingPermissionTests: XCTestCase {
    private var suite: String!
    private var settings: SettingsModel!
    private var permissions: OnboardingPermissions!
    private var controller: OnboardingWindowController!

    override func setUp() {
        super.setUp()
        suite = "Vistile.OnboardingTests.\(UUID().uuidString)"
        settings = SettingsModel(defaults: UserDefaults(suiteName: suite)!)
        permissions = OnboardingPermissions()
        controller = OnboardingWindowController(settings: settings, permissions: permissions)
        // Build the real hosting view without presenting or activating a window.
        controller.loadWindow()
    }

    override func tearDown() {
        controller.window?.close()
        controller = nil
        settings = nil
        permissions = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var view: OnboardingView {
        (controller.window!.contentViewController as! NSHostingController<OnboardingView>).rootView
    }

    private func goToAccessibility() {
        permissions.systemStatus.screenRecording = true
        view.onNext()
        view.onNext()
        XCTAssertEqual(view.step, 2)
    }

    func testRecheckReadsNewGrantAndUpdatesVisibleStatus() {
        goToAccessibility()
        XCTAssertFalse(view.permission.accessibility)
        permissions.systemStatus.accessibility = true
        view.onNext()
        XCTAssertTrue(view.permission.accessibility)
        XCTAssertEqual(view.step, 3)
    }

    func testDeniedPermissionCannotAdvanceToReady() {
        goToAccessibility()
        view.onNext()
        XCTAssertEqual(view.step, 2)
        XCTAssertFalse(view.permission.accessibility)
        XCTAssertFalse(settings.didCompleteGuidedSetup)
    }

    func testMissingScreenPermissionKeepsRecordingStep() {
        view.onNext()
        view.onNext()
        XCTAssertEqual(view.step, 1)
    }

    func testReturnFromSettingsUpdatesHostingView() async {
        goToAccessibility()
        permissions.systemStatus.accessibility = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(view.permission.accessibility)
        XCTAssertEqual(view.step, 2)
    }

    func testPermissionNotificationUpdatesHostingView() async {
        goToAccessibility()
        permissions.systemStatus.accessibility = true
        _ = permissions.refresh()
        NotificationCenter.default.post(name: .vistilePermissionsChanged, object: permissions.status)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(view.permission.accessibility)
    }

    func testRevocationBeforeFinishDoesNotCompleteSetup() {
        goToAccessibility()
        permissions.systemStatus.accessibility = true
        view.onNext()
        XCTAssertEqual(view.step, 3)
        var finished = false
        controller.onFinished = { finished = true }
        permissions.systemStatus.accessibility = false
        view.onFinish()
        XCTAssertFalse(finished)
        XCTAssertFalse(settings.didCompleteGuidedSetup)
        XCTAssertEqual(view.step, 2)
    }

    func testFinishWithBothGrantsCompletesSetup() {
        goToAccessibility()
        permissions.systemStatus.accessibility = true
        view.onNext()
        var finished = false
        controller.onFinished = { finished = true }
        view.onFinish()
        XCTAssertTrue(finished)
        XCTAssertTrue(settings.didCompleteGuidedSetup)
    }

    func testFinishClosesWindowAndNotifiesOnce() {
        goToAccessibility()
        permissions.systemStatus.accessibility = true
        view.onNext()
        var finishCount = 0
        controller.onFinished = { finishCount += 1 }
        expectation(forNotification: NSWindow.willCloseNotification, object: controller.window)
        view.onFinish()
        waitForExpectations(timeout: 1)
        XCTAssertFalse(controller.window!.isVisible)
        XCTAssertEqual(finishCount, 1)
    }
}

private final class OnboardingPermissions: PermissionGuiding {
    var status = PermissionStatus(screenRecording: false, accessibility: false)
    var systemStatus = PermissionStatus(screenRecording: false, accessibility: false)

    func refresh() -> PermissionStatus {
        status = systemStatus
        return status
    }

    func requestScreenRecording() -> Bool { refresh().screenRecording }
    func requestAccessibility(prompt: Bool) -> Bool { refresh().accessibility }
    func resetAccessibility() async throws {
        systemStatus.accessibility = false
        _ = refresh()
    }
}
