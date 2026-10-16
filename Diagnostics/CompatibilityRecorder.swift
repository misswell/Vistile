import AppKit
import Foundation
import VistileCore

/// 把实测事实写成可交付的报告文件；未测项保持"未测"（方案 §15.2、§16）。
final class CompatibilityRecorder {
    private(set) var report: CapabilityReport
    let outputDirectory: URL
    private let queue = DispatchQueue(label: "com.misswell.Vistile.recorder", qos: .utility)

    init(fileName: String = "capability-report") {
        self.fileName = fileName
        outputDirectory = Self.resolvedOutputDirectory()
        report = CapabilityReport(systemVersion: Self.systemVersion,
                                  hardware: Self.hardwareDescription,
                                  appVersion: Self.appVersion)
    }

    private let fileName: String
    /// 只在 `queue` 上读写：本进程有没有已经保过上一轮。
    private var previousRunPreserved = false

    /// 诊断输出的落点。
    /// 两个都要防的事故：
    /// 1. `init(fileName:)` 以前没被使用，落盘名硬编码成 "capability-report"——宿主测试传进来的
    ///    `host-test-<uuid>` 因此也写进了桌面上那份正式报告。2026-10-16 16:25 一轮测试把 0.1.4 的
    ///    原始报告覆盖成了只含合成窗口（App9000）的样例，14:46 那次同样如此；文档里的 0.1.4 数字只剩转录。
    /// 2. 测试进程不该往用户桌面写任何东西。
    /// 规则：显式 `VISTILE_DIAGNOSTICS_DIR` 优先；测试承载写临时目录；其余才是桌面。
    private static func resolvedOutputDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["VISTILE_DIAGNOSTICS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let isTestProcess = env["VISTILE_TEST_HOST"] == "1"
            || env["VISTILE_DIAGNOSTICS_TEMP"] == "1"
            || NSClassFromString("XCTestCase") != nil
        if isTestProcess {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Vistile Diagnostics", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Vistile Diagnostics", isDirectory: true)
    }

    /// 探针启动前把上一轮的报告与清单挪进 `_archive/<版本-时间>/`，避免新一轮就地覆盖证据。
    /// 返回归档目录；没有旧文件时返回 nil。
    /// 正常路径不需要调用它：本进程第一次落盘前 `persistLocked()` 会自动挪走。
    @discardableResult
    func archivePreviousRun(fileName: String = "P0-acceptance-checklist.md") -> URL? {
        queue.sync { archivePreviousRunLocked(fileName: fileName) }
    }

    @discardableResult
    private func archivePreviousRunLocked(fileName: String = "P0-acceptance-checklist.md") -> URL? {
        // 显式调用也算"保过了"：否则调用方之后第一次写盘会再挪一次，把本轮刚写的文件搬走。
        previousRunPreserved = true
        let manager = FileManager.default
        let names = ["\(self.fileName).md", "\(self.fileName).json", fileName]
        let existing = names.map { outputDirectory.appendingPathComponent($0) }
            .filter { manager.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        let destination = outputDirectory
            .appendingPathComponent("_archive", isDirectory: true)
            .appendingPathComponent(archiveName(), isDirectory: true)
        do {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            for url in existing {
                let target = destination.appendingPathComponent(url.lastPathComponent)
                try? manager.removeItem(at: target)
                try manager.moveItem(at: url, to: target)
            }
            return destination
        } catch {
            note("上一轮报告归档失败（\(error.localizedDescription)），本轮将就地覆盖 \(fileName)")
            return nil
        }
    }

    /// 归档必须挂在"本进程第一次写盘"这件事上，不能靠调用方在启动序列里记得先调一次。
    /// 0.1.6 那轮实测：协调层启动时先记了两行事实（全局快捷键 / Metal 渲染）就地写盘，
    /// 把 0.1.5 的原始报告覆盖掉了，之后探针才归档——归档到的只是自己刚写的那两行。
    private func preservePreviousRunLocked() {
        guard !previousRunPreserved else { return }
        previousRunPreserved = true
        guard let archived = archivePreviousRunLocked() else { return }
        report.notes.append("上一轮报告已归档：\(archived.path)")
    }

    /// 归档目录名带上"那一份报告自己是哪个构建、什么时候生成的"，
    /// 而不是当前这个构建——否则三轮之后的归档根本分不出先后。
    private func archiveName() -> String {
        let json = outputDirectory.appendingPathComponent("\(fileName).json")
        var label = "unknown-build"
        let attributes = try? FileManager.default.attributesOfItem(atPath: json.path)
        var date = (attributes?[.modificationDate] as? Date) ?? Date()
        if let data = try? Data(contentsOf: json),
           let old = try? CapabilityReport.decode(data) {
            label = old.appVersion.replacingOccurrences(of: " ", with: "-")
            date = old.generatedAt
        }
        return "\(label)-\(Self.archiveStamp(date))"
    }

    private static func archiveStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    static let systemVersion: String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }()

    static var hardwareDescription: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let model = machine.isEmpty ? "unknown" : machine
        let cores = ProcessInfo.processInfo.processorCount
        let memory = ProcessInfo.processInfo.physicalMemory
        let arch = mach_kernel_architecture
        return "\(arch)/\(model), \(cores) cores, \(memory / (1024 * 1024 * 1024))GB"
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Vistile \(version)+\(build)"
    }

    private static var mach_kernel_architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    // MARK: - 记录

    func record(_ check: String, subject: String, result: VerificationResult, detail: String) {
        let sample = CapabilitySample(check: check,
                                      subject: subject,
                                      result: result,
                                      detail: detail,
                                      systemVersion: Self.systemVersion,
                                      hardware: Self.hardwareDescription)
        queue.async {
            self.report.samples.removeAll { $0.check == check && $0.subject == subject }
            self.report.samples.append(sample)
            self.persistLocked()
        }
    }

    /// 兼容矩阵按"应用 + 版本"聚合；单项未测不影响其它项，格子缺失写未测。
    func updateRow(application: String,
                   version: String,
                   capture: VerificationResult? = nil,
                   association: VerificationResult? = nil,
                   move: VerificationResult? = nil,
                   resize: VerificationResult? = nil,
                   ordering: VerificationResult? = nil,
                   sheet: VerificationResult? = nil,
                   restore: VerificationResult? = nil,
                   knownLimitation: String? = nil) {
        queue.async {
            let key = "\(application)|\(version)"
            var row = self.report.rows.first(where: { "\($0.application)|\($0.applicationVersion)" == key })
                ?? { () -> CompatibilityRow in
                    var row = CompatibilityRow.unverified
                    row.application = application
                    row.applicationVersion = version
                    return row
                }()
            if let capture { row.capture = capture }
            if let association { row.association = association }
            if let move { row.move = move }
            if let resize { row.resize = resize }
            if let ordering { row.ordering = ordering }
            if let sheet { row.sheet = sheet }
            if let restore { row.restore = restore }
            if let knownLimitation { row.knownLimitation = knownLimitation }
            self.report.rows.removeAll { "\($0.application)|\($0.applicationVersion)" == key }
            self.report.rows.append(row)
            self.persistLocked()
        }
    }

    func recordPerformance(_ sample: PerformanceSample) {
        queue.async {
            self.report.performance.removeAll { $0.name == sample.name }
            self.report.performance.append(sample)
            self.persistLocked()
        }
    }

    func note(_ text: String) {
        queue.async {
            guard !self.report.notes.contains(text) else { return }
            self.report.notes.append(text)
            self.persistLocked()
        }
    }

    /// 导出前刷新时间戳，供 P0 与验收阶段落盘。
    @discardableResult
    func flush() -> URL? {
        queue.sync {
            report.generatedAt = Date()
            return persistLocked()
        }
    }

    @discardableResult
    private func persistLocked() -> URL? {
        preservePreviousRunLocked()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        report.generatedAt = Date()
        let json = outputDirectory.appendingPathComponent("\(fileName).json")
        let markdown = outputDirectory.appendingPathComponent("\(fileName).md")
        guard let data = try? report.encoded() else { return nil }
        try? data.write(to: json, options: .atomic)
        try? report.markdown().write(to: markdown, atomically: true, encoding: .utf8)
        return markdown
    }

    var markdownText: String {
        queue.sync { report.markdown() }
    }
}
