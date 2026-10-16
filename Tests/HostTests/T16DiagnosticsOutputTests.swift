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
