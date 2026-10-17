import AppKit
import Foundation
import VistileCore
import XCTest
@testable import Vistile

/// T16 诊断输出落点（方案 §16）。
///
/// 钉住两件事，都是真实事故：
/// 1. `init(fileName:)` 曾经没被使用，落盘名硬编码成 "capability-report"，
///    于是宿主测试把自己那份合成数据（App9000）写进了用户桌面上那份正式报告，0.1.4 的原始报告因此没了。
/// 2. 测试进程不能往用户桌面写任何东西；探针每轮就地覆盖同名文件，所以启动时必须先把上一轮挪进 `_archive/`。
final class T16DiagnosticsOutputTests: XCTestCase {
    private var scratchDirectories: [URL] = []
    private var savedEnvironment: [String: String?] = [:]

    override func tearDown() {
        for url in scratchDirectories { try? FileManager.default.removeItem(at: url) }
        for (key, value) in savedEnvironment {
            switch value {
            case let .some(text): setenv(key, text, 1)
            case .none: unsetenv(key)
            }
        }
        super.tearDown()
    }

    /// 环境变量在 `CompatibilityRecorder.init` 时被读取，所以必须"先设变量、再构造 recorder"。
    private func useDiagnosticsDirectory(_ url: URL, override: Bool) {
        let key = "VISTILE_DIAGNOSTICS_DIR"
        if !savedEnvironment.keys.contains(key) {
            savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
        }
        if override {
            setenv(key, url.path, 1)
        } else {
            unsetenv(key)
        }
    }

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VistileDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchDirectories.append(url)
        return url
    }

    private func report(appVersion: String = "Vistile 0.0.1+1",
                        generatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> CapabilityReport {
        CapabilityReport(generatedAt: generatedAt,
                         systemVersion: "macOS 0.0.0",
                         hardware: "test",
                         appVersion: appVersion,
                         samples: [CapabilitySample(check: "样例",
                                                    subject: "窗口",
                                                    result: .passed,
                                                    detail: "事实",
                                                    systemVersion: "macOS 0.0.0",
                                                    hardware: "test")])
    }

    // MARK: - 落点名

    func testFileNameDecidesTheWrittenFileAndNeverTheSharedOne() throws {
        let directory = try makeScratchDirectory()
        useDiagnosticsDirectory(directory, override: true)
        let recorder = CompatibilityRecorder(fileName: "host-test-42")
        XCTAssertEqual(recorder.outputDirectory.standardizedFileURL.path, directory.standardizedFileURL.path)

        recorder.record("样例", subject: "窗口", result: .passed, detail: "只应出现在 host-test-42 里")
        XCTAssertNotNil(recorder.flush())

        let written = directory.appendingPathComponent("host-test-42.md")
        let shared = directory.appendingPathComponent("capability-report.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path), "fileName 必须真的决定落盘文件名")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path),
                       "自定义 fileName 不得再写进正式报告 capability-report.md")
        let text = try XCTUnwrap(String(contentsOf: written, encoding: .utf8))
        XCTAssertTrue(text.contains("只应出现在 host-test-42 里"))
    }

    func testTestProcessDoesNotWriteToTheUsersDesktop() {
        useDiagnosticsDirectory(URL(fileURLWithPath: "/unused"), override: false)
        let recorder = CompatibilityRecorder()
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? ""
        XCTAssertFalse(recorder.outputDirectory.path.contains(desktop),
                       "测试承载里解析出的落点必须是临时目录，实际是 \(recorder.outputDirectory.path)")
    }

    // MARK: - 归档

    func testArchivePreviousRunMovesEveryArtifactAndKeepsItsOwnVersionInTheName() throws {
        let directory = try makeScratchDirectory()
        useDiagnosticsDirectory(directory, override: true)

        let json = directory.appendingPathComponent("capability-report.json")
        let markdown = directory.appendingPathComponent("capability-report.md")
        let checklist = directory.appendingPathComponent("P0-acceptance-checklist.md")
        let old = report(appVersion: "Vistile 0.9.9+3", generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try old.encoded().write(to: json)
        try "上一轮的报告".write(to: markdown, atomically: true, encoding: .utf8)
        try "上一轮的清单".write(to: checklist, atomically: true, encoding: .utf8)

        let recorder = CompatibilityRecorder()
        let archived = try XCTUnwrap(recorder.archivePreviousRun())

        // 目录名带上"那一份报告自己是哪个构建"：用当前构建命名的话，几轮之后根本分不出先后。
        XCTAssertTrue(archived.lastPathComponent.contains("0.9.9+3"),
                      "归档名应带上旧报告自己的版本，实际 \(archived.lastPathComponent)")
        for name in ["capability-report.md", "capability-report.json", "P0-acceptance-checklist.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent(name).path),
                          "\(name) 应该被归档")
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
                           "\(name) 应已从落点移走，否则本轮会就地覆盖它")
        }
    }

    func testArchiveIsANoOpWhenNothingWasWrittenBefore() throws {
        let directory = try makeScratchDirectory()
        useDiagnosticsDirectory(directory, override: true)
        let recorder = CompatibilityRecorder(fileName: "host-test-empty")
        XCTAssertNil(recorder.archivePreviousRun())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("_archive", isDirectory: true).path))
    }

    /// 复现 0.1.6 那轮的真实事故：协调层在启动时先记两行事实（全局快捷键 / Metal 渲染）就地写盘，
    /// 探针的归档调用排在后面——它归档到的只是自己刚写的那两行，0.1.5 的原始报告在这之前就被覆盖了。
    /// 所以保命动作必须挂在"本进程第一次写盘"上，而不是靠调用方记得先调一次。
    func testFirstWritePreservesThePreviousRunEvenWhenNobodyAsked() throws {
        let directory = try makeScratchDirectory()
        useDiagnosticsDirectory(directory, override: true)

        let json = directory.appendingPathComponent("capability-report.json")
        let markdown = directory.appendingPathComponent("capability-report.md")
        let checklist = directory.appendingPathComponent("P0-acceptance-checklist.md")
        let old = report(appVersion: "Vistile 0.9.8+2")
        try old.encoded().write(to: json)
        try "上一轮的报告".write(to: markdown, atomically: true, encoding: .utf8)
        try "上一轮的清单".write(to: checklist, atomically: true, encoding: .utf8)

        let recorder = CompatibilityRecorder()
        recorder.record("全局快捷键", subject: "⌃⌥空格", result: .unverified, detail: "本轮新写的一行")
        XCTAssertNotNil(recorder.flush())

        let archiveRoot = directory.appendingPathComponent("_archive", isDirectory: true)
        let rounds = try FileManager.default.contentsOfDirectory(atPath: archiveRoot.path)
        let round = try XCTUnwrap(rounds.first { $0.contains("0.9.8+2") },
                                 "第一次写盘就必须把上一轮挪走，且归档名带旧报告自己的版本，实际 \(rounds)")
        let archivedMarkdown = archiveRoot.appendingPathComponent(round, isDirectory: true)
            .appendingPathComponent("capability-report.md")
        XCTAssertEqual(try String(contentsOf: archivedMarkdown, encoding: .utf8), "上一轮的报告")
        for name in ["capability-report.json", "P0-acceptance-checklist.md"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: archiveRoot
                .appendingPathComponent(round, isDirectory: true)
                .appendingPathComponent(name).path), "\(name) 也应一起归档")
        }

        let fresh = try XCTUnwrap(String(contentsOf: directory.appendingPathComponent("capability-report.md"),
                                         encoding: .utf8))
        XCTAssertTrue(fresh.contains("本轮新写的一行"))
        XCTAssertTrue(fresh.contains("上一轮报告已归档"), "新报告里要写清上一轮挪到了哪")
    }
}

// MARK: - GitHub Releases 更新通道（方案 §21）

/// 更新检查的宿主回归：网络与磁盘都注入，不碰真实 GitHub。
/// 决策逻辑（版本比较、选包）在核心包 `UpdateChannelTests` 里已有纯逻辑覆盖，
/// 这里钉的是"接缝 + 节流 + 跳过版本 + 失败口径"。
@MainActor
final class UpdateChannelHostTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        suites = []
        super.tearDown()
    }

    private func makeSettings() -> SettingsModel {
        let name = "com.misswell.Vistile.updatetests.\(UUID().uuidString)"
        suites.append(name)
        return SettingsModel(defaults: UserDefaults(suiteName: name)!)
    }

    private struct FakeFetcher: UpdateReleasesFetching {
        let result: Result<Data, UpdateCheckFailure>
        func fetchReleases() async throws -> Data {
            switch result {
            case let .success(data): return data
            case let .failure(failure): throw failure
            }
        }
    }

    private func payload(_ tag: String,
                         prerelease: Bool = true,
                         assets: [(name: String, url: String, size: Int)] = []) -> Data {
        let files = assets.isEmpty
            ? [(name: "Vistile_\(tag)_macos_arm64.dmg",
                url: "https://github.com/misswell/Vistile/releases/download/\(tag)/Vistile_\(tag)_macos_arm64.dmg",
                size: 2_375_689)]
            : assets
        let list: [[String: Any]] = [[
            "tag_name": tag,
            "name": "Vistile \(tag)",
            "body": "本版说明",
            "html_url": "https://github.com/misswell/Vistile/releases/tag/\(tag)",
            "draft": false,
            "prerelease": prerelease,
            "assets": files.map { ["name": $0.name, "browser_download_url": $0.url, "size": $0.size] }
        ]]
        return try! JSONSerialization.data(withJSONObject: list)
    }

    private func checker(_ data: Data,
                         settings: SettingsModel,
                         current: String = "0.1.13",
                         now: @escaping () -> Date = Date.init) -> UpdateChecker {
        UpdateChecker(settings: settings,
                      fetcher: FakeFetcher(result: .success(data)),
                      currentVersion: AppVersion(current),
                      now: now)
    }

    func testNewerReleaseIsOfferedWithArm64Dmg() async throws {
        let settings = makeSettings()
        let outcome = await checker(payload("v0.1.14"), settings: settings).checkNow()
        guard case let .available(package) = outcome else {
            return XCTFail("应有可用更新，实际 \(outcome)")
        }
        XCTAssertEqual(package.version.description, "0.1.14")
        XCTAssertEqual(package.asset?.name, "Vistile_v0.1.14_macos_arm64.dmg")
        XCTAssertEqual(package.mirrorURL?.absoluteString,
                       "https://autocrop.liuguofeng.com/vistile/releases/v0.1.14/Vistile_v0.1.14_macos_arm64.dmg",
                       "更新必须优先给国内可下载的镜像路径：GitHub 直链在无代理网络下会超时")
        XCTAssertNotNil(package.checksumURL, "镜像旁边要有同名 .sha256 校验文件")
        XCTAssertNotNil(settings.lastUpdateCheckAt, "成功检查后要记时间，自动检查按它节流")
    }

    func testSameVersionIsUpToDate() async throws {
        let settings = makeSettings()
        let outcome = await checker(payload("v0.1.13"), settings: settings).checkNow()
        XCTAssertEqual(outcome, .upToDate(current: "0.1.13"))
    }

    func testPrereleaseIsPartOfTheUpdateChannel() async throws {
        let settings = makeSettings()
        let outcome = await checker(payload("v0.1.14", prerelease: true), settings: settings).checkNow()
        guard case .available = outcome else {
            return XCTFail("本仓库发布包一律标 prerelease，更新通道必须包含它：\(outcome)")
        }
    }

    func testSkippedVersionStopsAutoPromptButManualCheckStillShowsUpgrade() async throws {
        let settings = makeSettings()
        let updateChecker = checker(payload("v0.1.14"), settings: settings)
        guard case let .available(package) = await updateChecker.checkNow() else {
            return XCTFail("第一次检查应发现新版本")
        }
        updateChecker.skip(package)
        XCTAssertEqual(settings.skippedUpdateVersion, "0.1.14")
        let again = await updateChecker.checkNow()
        XCTAssertEqual(again, .skipped(package), "手动检查仍要展示被跳过的版本，否则用户无从恢复")
    }

    func testAutomaticCheckIsThrottledFor24HoursAndMakesNoNetworkCall() async throws {
        let settings = makeSettings()
        settings.lastUpdateCheckAt = Date()
        // 故意给一个会抛错的取数器：被节流时根本不该走到网络。
        let checker = UpdateChecker(settings: settings,
                                    fetcher: FakeFetcher(result: .failure(.network("不该被调用"))),
                                    currentVersion: AppVersion("0.1.13"))
        let outcome = await checker.checkIfDue()
        XCTAssertEqual(outcome, .throttled)
    }

    func testAutomaticCheckRespectsDisabledSetting() async throws {
        let settings = makeSettings()
        settings.autoCheckUpdates = false
        let checker = UpdateChecker(settings: settings,
                                    fetcher: FakeFetcher(result: .failure(.network("不该被调用"))),
                                    currentVersion: AppVersion("0.1.13"))
        let automatic = await checker.checkIfDue()
        XCTAssertEqual(automatic, .throttled)
        // 手动检查仍然可以工作：开关只管自动。
        let manual = UpdateChecker(settings: settings,
                                   fetcher: FakeFetcher(result: .success(payload("v0.1.14"))),
                                   currentVersion: AppVersion("0.1.13"))
        guard case .available = await manual.checkNow() else {
            return XCTFail("关掉自动检查不该影响手动检查")
        }
    }

    func testMalformedPayloadFailsReadably() async throws {
        let settings = makeSettings()
        let outcome = await checker(Data("not json".utf8), settings: settings).checkNow()
        guard case let .failed(reason) = outcome else { return XCTFail("解析失败要如实回报：\(outcome)") }
        XCTAssertTrue(reason.contains("无法解析"), reason)
    }

    func testNetworkFailureSurfacesGitHubRateLimitHint() async throws {
        let settings = makeSettings()
        let checker = UpdateChecker(settings: settings,
                                    fetcher: FakeFetcher(result: .failure(.network("GitHub API 返回 HTTP 403（可能触发了未认证限额 60 次/小时）"))),
                                    currentVersion: AppVersion("0.1.13"))
        guard case let .failed(reason) = await checker.checkNow() else {
            return XCTFail("网络失败要如实回报：不是静默当成最新版")
        }
        XCTAssertTrue(reason.contains("403"), reason)
        XCTAssertTrue(reason.contains("60 次/小时"), reason)
    }
}
