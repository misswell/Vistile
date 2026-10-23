import XCTest
import VistileCore
import Darwin
@testable import Vistile

@MainActor
final class UpdatePresentationTests: XCTestCase {
    func testTerminationRequestIsDeferredPastTheCurrentMainActorTurn() {
        var ranInline = true
        let requested = expectation(description: "termination requested")
        ApplicationTermination.request {
            ranInline = false
            requested.fulfill()
        }
        XCTAssertTrue(ranInline, "terminate must not run inside the main-actor turn that starts the handoff")
        wait(for: [requested], timeout: 2)
        XCTAssertFalse(ranInline)
    }

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
    func testCanonicalTemporaryDirectoryUsesPOSIXResolvedPathWithoutSymlinks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let resolvedPath = temporaryDirectory.path.withCString { Darwin.realpath($0, nil) }
        guard let resolvedPath else {
            XCTFail("The system temporary directory must resolve to an existing path")
            return
        }
        defer { Darwin.free(resolvedPath) }

        let canonical = try UpdateInstaller.canonicalTemporaryDirectory()
        XCTAssertEqual(canonical.path, String(cString: resolvedPath))
        XCTAssertNoThrow(try UpdateInstaller.requireNoSymlinkAncestors(canonical))
    }

    func testSymlinkedAncestorIsStillRejectedAfterPathNormalization() throws {
        let root = try UpdateInstaller.canonicalTemporaryDirectory()
            .appendingPathComponent("Vistile-UpdatePathValidation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real", isDirectory: true)
        let realChild = real.appendingPathComponent("child", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realChild, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        XCTAssertNoThrow(try UpdateInstaller.requireNoSymlinkAncestors(realChild))
        XCTAssertThrowsError(try UpdateInstaller.requireNoSymlinkAncestors(alias.appendingPathComponent("child", isDirectory: true)))
    }

    func testSHA256NormalizationAndComparison() {
        let digest = String(repeating: "ab", count: 32)
        XCTAssertEqual(UpdateInstallerValidation.normalizedSHA256("sha256:\(digest.uppercased())"), digest)
        XCTAssertEqual(UpdateInstallerValidation.normalizedSHA256("SHA256:\(digest)"), digest)
        XCTAssertTrue(UpdateInstallerValidation.matchesSHA256(expected: "SHA256:\(digest)", actual: digest.uppercased()))
        XCTAssertNil(UpdateInstallerValidation.normalizedSHA256("sha256:1234"))
        XCTAssertNil(UpdateInstallerValidation.normalizedSHA256(String(repeating: "a", count: 63)), "63 位不是 SHA-256")
        XCTAssertNil(UpdateInstallerValidation.normalizedSHA256(String(repeating: "a", count: 65)), "65 位不是 SHA-256")
        XCTAssertNil(UpdateInstallerValidation.normalizedSHA256(String(repeating: "z", count: 64)), "非十六进制必须拒绝")
        XCTAssertNil(UpdateInstallerValidation.normalizedSHA256(" \(digest)"))
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
        XCTAssertTrue(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "https://GITHUB.com/misswell/Vistile/releases/download/v1.2.3/Vistile.dmg")!))
        XCTAssertFalse(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "http://github.com/misswell/Vistile/releases/download/v1.2.3/Vistile.dmg")!))
        XCTAssertFalse(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "https://example.com/Vistile.dmg")!))
        XCTAssertFalse(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "https://github.com.evil.com/Vistile.dmg")!),
                       "外观相似的域名不是 GitHub")
        XCTAssertFalse(UpdateInstallerValidation.isTrustedDownloadURL(URL(string: "https://evil.com/github.com/Vistile.dmg")!))

        XCTAssertTrue(UpdateInstallerValidation.isSupportedInstallLocation("/Applications/Vistile.app", homeDirectory: "/Users/test"))
        XCTAssertTrue(UpdateInstallerValidation.isSupportedInstallLocation("/Applications/./Vistile.app", homeDirectory: "/Users/test"))
        XCTAssertTrue(UpdateInstallerValidation.isSupportedInstallLocation("/Users/test/Applications/Vistile.app", homeDirectory: "/Users/test"))
        XCTAssertTrue(UpdateInstallerValidation.isSupportedInstallLocation("/Users/test/Applications/Vistile.app", homeDirectory: "/Users/test/"))
        XCTAssertFalse(UpdateInstallerValidation.isSupportedInstallLocation("/Applications/Vistile.app.backup", homeDirectory: "/Users/test"))
        XCTAssertFalse(UpdateInstallerValidation.isSupportedInstallLocation("/Applications/Vistile.app.evil/Vistile.app", homeDirectory: "/Users/test"))
        XCTAssertFalse(UpdateInstallerValidation.isSupportedInstallLocation("/tmp/Vistile.app", homeDirectory: "/Users/test"))
    }
}
