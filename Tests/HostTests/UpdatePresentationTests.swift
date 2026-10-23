import XCTest
import VistileCore
@testable import Vistile

@MainActor
final class UpdatePresentationTests: XCTestCase {
    func testNotesShowChangesWithoutManualInstallInstructionsOrMarkdownHeadings() throws {
        let release = GitHubRelease(tagName: "v1.2.3", name: nil, body: """
        # Vistile
        ## v1.2.3 (45)
        - Supports **in-app updates** and `restart`.
        ## 下载
        | Platform | File |
        Drag Vistile.app into Applications.
        """, htmlURL: URL(string: "https://github.com/misswell/Vistile/releases/tag/v1.2.3")!,
                                    isDraft: false, isPrerelease: false, assets: [])
        let package = UpdatePackage(version: try XCTUnwrap(AppVersion("1.2.3")), release: release, asset: nil)
        let notes = MenuBarController.updateNotes(for: package)
        XCTAssertEqual(notes, "• Supports in-app updates and restart.")
    }
}

final class UpdateInstallerValidationTests: XCTestCase {
    func testSHA256NormalizationAndComparison() {
        let digest = String(repeating: "ab", count: 32)
        XCTAssertEqual(UpdateInstallerValidation.normalizedSHA256("sha256:\(digest.uppercased())"), digest)
        XCTAssertTrue(UpdateInstallerValidation.matchesSHA256(expected: "SHA256:\(digest)", actual: digest.uppercased()))
        XCTAssertNil(UpdateInstallerValidation.normalizedSHA256("sha256:1234"))
        XCTAssertFalse(UpdateInstallerValidation.matchesSHA256(expected: digest, actual: String(repeating: "cd", count: 32)))
    }

    func testBundleIdentityRequiresExactIdentifierAndVersion() {
        XCTAssertTrue(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                              version: "1.2.3",
                                                              expectedIdentifier: "com.misswell.Vistile",
                                                              expectedVersion: "1.2.3"))
        XCTAssertFalse(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.example.Other",
                                                               version: "1.2.3",
                                                               expectedIdentifier: "com.misswell.Vistile",
                                                               expectedVersion: "1.2.3"))
        XCTAssertFalse(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                               version: "1.2.4",
                                                               expectedIdentifier: "com.misswell.Vistile",
                                                               expectedVersion: "1.2.3"))
    }

    func testBundleVersionComparisonAcceptsEquivalentTrailingZeroSegments() {
        XCTAssertTrue(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                               version: "0.2.0",
                                                               expectedIdentifier: "com.misswell.Vistile",
                                                               expectedVersion: "0.2"))
        XCTAssertTrue(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                               version: "0.2",
                                                               expectedIdentifier: "com.misswell.Vistile",
                                                               expectedVersion: "0.2.0"))
        XCTAssertFalse(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                                version: "0.2.1",
                                                                expectedIdentifier: "com.misswell.Vistile",
                                                                expectedVersion: "0.2.0"))
        XCTAssertFalse(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                                version: "0.3.0",
                                                                expectedIdentifier: "com.misswell.Vistile",
                                                                expectedVersion: "0.2"))
        XCTAssertFalse(UpdateInstallerValidation.matchesBundle(bundleIdentifier: "com.misswell.Vistile",
                                                                version: "not-a-version",
                                                                expectedIdentifier: "com.misswell.Vistile",
                                                                expectedVersion: "0.2.0"))
    }

    func testDownloadAndInstallationLocationBoundaries() {
        XCTAssertTrue(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "https://github.com/misswell/Vistile/releases/download/v1.2.3/Vistile.dmg")!))
        XCTAssertFalse(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "http://github.com/misswell/Vistile/releases/download/v1.2.3/Vistile.dmg")!))
        XCTAssertFalse(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "https://example.com/Vistile.dmg")!))

        XCTAssertTrue(UpdateInstallerValidation.isSupportedInstallLocation("/Applications/Vistile.app", homeDirectory: "/Users/test"))
        XCTAssertTrue(UpdateInstallerValidation.isSupportedInstallLocation("/Users/test/Applications/Vistile.app", homeDirectory: "/Users/test"))
        XCTAssertFalse(UpdateInstallerValidation.isSupportedInstallLocation("/Applications/Vistile.app.backup", homeDirectory: "/Users/test"))
        XCTAssertFalse(UpdateInstallerValidation.isSupportedInstallLocation("/tmp/Vistile.app", homeDirectory: "/Users/test"))
    }
}
