import AppKit
import Foundation
import VistileCore

/// 把实测事实写成可交付的报告文件；未测项保持"未测"（方案 §15.2、§16）。
final class CompatibilityRecorder {
    private(set) var report: CapabilityReport
    let outputDirectory: URL
    private let queue = DispatchQueue(label: "com.misswell.Vistile.recorder", qos: .utility)

    init(fileName: String = "capability-report") {
        let base = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        outputDirectory = base.appendingPathComponent("Vistile Diagnostics", isDirectory: true)
        report = CapabilityReport(systemVersion: Self.systemVersion,
                                  hardware: Self.hardwareDescription,
                                  appVersion: Self.appVersion)
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
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        report.generatedAt = Date()
        let json = outputDirectory.appendingPathComponent("\(reportName()).json")
        let markdown = outputDirectory.appendingPathComponent("\(reportName()).md")
        guard let data = try? report.encoded() else { return nil }
        try? data.write(to: json, options: .atomic)
        try? report.markdown().write(to: markdown, atomically: true, encoding: .utf8)
        return markdown
    }

    private func reportName() -> String { "capability-report" }

    var markdownText: String {
        queue.sync { report.markdown() }
    }
}
