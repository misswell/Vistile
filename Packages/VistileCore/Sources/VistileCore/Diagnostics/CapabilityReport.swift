import Foundation

/// "未测"必须写"未测"，不能填"支持"（方案 §15.2）。
public enum VerificationResult: String, Codable, Hashable, Sendable {
    case passed
    case failed
    case blocked
    case unverified
}

public struct CapabilitySample: Codable, Hashable, Sendable {
    public var check: String
    public var subject: String
    public var result: VerificationResult
    public var detail: String
    public var systemVersion: String
    public var hardware: String
    public var capturedAt: Date

    public init(check: String,
                subject: String,
                result: VerificationResult,
                detail: String,
                systemVersion: String,
                hardware: String,
                capturedAt: Date = Date()) {
        self.check = check
        self.subject = subject
        self.result = result
        self.detail = detail
        self.systemVersion = systemVersion
        self.hardware = hardware
        self.capturedAt = capturedAt
    }
}

/// 兼容矩阵的一行：捕获、关联、移动、resize、层级、Sheet、恢复都要有独立结论。
public struct CompatibilityRow: Codable, Hashable, Sendable {
    public var application: String
    public var applicationVersion: String
    public var capture: VerificationResult
    public var association: VerificationResult
    public var move: VerificationResult
    public var resize: VerificationResult
    public var ordering: VerificationResult
    public var sheet: VerificationResult
    public var restore: VerificationResult
    public var knownLimitation: String

    public static let unverified = CompatibilityRow(application: "", applicationVersion: "",
                                                    capture: .unverified, association: .unverified,
                                                    move: .unverified, resize: .unverified,
                                                    ordering: .unverified, sheet: .unverified,
                                                    restore: .unverified, knownLimitation: "")
}

public struct PerformanceSample: Codable, Hashable, Sendable {
    public var name: String
    public var valueMS: Double
    public var context: String
    public init(name: String, valueMS: Double, context: String) {
        self.name = name
        self.valueMS = valueMS
        self.context = context
    }
}

public struct CapabilityReport: Codable, Sendable {
    public var generatedAt: Date
    public var systemVersion: String
    public var hardware: String
    public var appVersion: String
    public var samples: [CapabilitySample]
    public var rows: [CompatibilityRow]
    public var performance: [PerformanceSample]
    public var notes: [String]

    public init(generatedAt: Date = Date(),
                systemVersion: String,
                hardware: String,
                appVersion: String,
                samples: [CapabilitySample] = [],
                rows: [CompatibilityRow] = [],
                performance: [PerformanceSample] = [],
                notes: [String] = []) {
        self.generatedAt = generatedAt
        self.systemVersion = systemVersion
        self.hardware = hardware
        self.appVersion = appVersion
        self.samples = samples
        self.rows = rows
        self.performance = performance
        self.notes = notes
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CapabilityReport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CapabilityReport.self, from: data)
    }

    public func markdown() -> String {
        var lines: [String] = []
        lines.append("# Vistile 实测记录")
        lines.append("")
        lines.append("- 系统：\(systemVersion)")
        lines.append("- 硬件：\(hardware)")
        lines.append("- 构建：\(appVersion)")
        lines.append("- 生成时间：\(Self.dateFormatter.string(from: generatedAt))")
        lines.append("")
        lines.append("## 能力验证")
        lines.append("")
        lines.append("| 编号 | 对象 | 结论 | 记录 |")
        lines.append("| --- | --- | --- | --- |")
        for sample in samples.sorted(by: { ($0.check, $0.subject) < ($1.check, $1.subject) }) {
            lines.append("| \(sample.check) | \(sample.subject) | \(label(sample.result)) | \(sample.detail) |")
        }
        lines.append("")
        lines.append("## 兼容矩阵")
        lines.append("")
        lines.append("| 应用 | 版本 | 捕获 | 关联 | 移动 | resize | 层级 | Sheet | 恢复 | 已知限制 |")
        lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        for row in rows {
            lines.append("| \(row.application) | \(row.applicationVersion) | \(label(row.capture)) | \(label(row.association)) | \(label(row.move)) | \(label(row.resize)) | \(label(row.ordering)) | \(label(row.sheet)) | \(label(row.restore)) | \(row.knownLimitation) |")
        }
        if !performance.isEmpty {
            lines.append("")
            lines.append("## 计时（CPU 记法：100% = 一个逻辑核满载）")
            lines.append("")
            lines.append("| 指标 | 毫秒 | 说明 |")
            lines.append("| --- | --- | --- |")
            for sample in performance {
                lines.append("| \(sample.name) | \(String(format: "%.1f", sample.valueMS)) | \(sample.context) |")
            }
        }
        if !notes.isEmpty {
            lines.append("")
            lines.append("## 备注")
            lines.append("")
            for note in notes { lines.append("- \(note)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func label(_ result: VerificationResult) -> String {
        switch result {
        case .passed: return "通过"
        case .failed: return "失败"
        case .blocked: return "阻塞"
        case .unverified: return "未测"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
