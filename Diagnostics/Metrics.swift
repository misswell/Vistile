import AppKit
import CoreGraphics
import Foundation
import os
import VistileCore

/// 采样那一刻的性能环境（方案 §20.2 的三个分组维度里需要读系统的那两个）。
///
/// 刷新率走 `CGGetOnlineDisplayList`：显示休眠时 `CGGetActiveDisplayList` 返回 0 个（2026-10-17 实测），
/// 而 online 列表仍能读到面板真实 Hz；取不到就记 0，让分组键落在"刷新率未知"，不假装是 60Hz。
enum PerformanceEnvironment {
    static func current(coldStart: Bool) -> PerformanceGroup {
        PerformanceGroup(refreshHz: mainRefreshHz(),
                         reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                         coldStart: coldStart)
    }

    static func mainRefreshHz() -> Double {
        if let rate = displayRefreshHz(CGMainDisplayID()) { return rate }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        for id in ids.prefix(Int(count)) {
            if let rate = displayRefreshHz(id) { return rate }
        }
        return 0
    }

    private static func displayRefreshHz(_ id: CGDirectDisplayID) -> Double? {
        guard id != 0, let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return mode.refreshRate > 0 ? mode.refreshRate : nil
    }
}

/// os_signpost 区间与轻量计数。正常用户界面不显示这些技术参数（方案 §13）。
final class Metrics {
    static let shared = Metrics()
    static let maximumSamplesPerMetric = 1024

    private let log = OSLog(subsystem: "com.misswell.Vistile", category: "session")
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private struct TimingHistory {
        var samples: [Double] = []
        var nextIndex = 0
        var totalCount = 0

        mutating func append(_ value: Double) {
            totalCount &+= 1
            if samples.count < Metrics.maximumSamplesPerMetric {
                samples.append(value)
            } else {
                samples[nextIndex] = value
                nextIndex = (nextIndex + 1) % Metrics.maximumSamplesPerMetric
            }
        }
    }
    private var timings: [String: TimingHistory] = [:]
    private var signpostIDs: [String: OSSignpostID] = [:]

    var retainedSampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return timings.values.reduce(0) { $0 + $1.samples.count }
    }

    var onSample: ((PerformanceSample) -> Void)?

    /// os_signpost 的 name 必须是编译期字符串；动态标签放进消息里，Instruments 仍能区分。
    private static let intervalName: StaticString = "Vistile区间"
    private static let eventName: StaticString = "Vistile事件"

    func increment(_ name: String, by value: Int = 1) {
        lock.lock()
        counters[name, default: 0] += value
        lock.unlock()
    }

    func counter(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counters[name] ?? 0
    }

    func begin(_ name: String) {
        let id = OSSignpostID(log: log)
        lock.lock()
        signpostIDs[name] = id
        lock.unlock()
        os_signpost(.begin, log: log, name: Self.intervalName, signpostID: id,
                    "begin %{public}@", name as NSString)
    }

    func end(_ name: String, context: String = "") {
        lock.lock()
        let id = signpostIDs.removeValue(forKey: name)
        lock.unlock()
        guard let id else { return }
        os_signpost(.end, log: log, name: Self.intervalName, signpostID: id,
                    "end %{public}@ %{public}@", name as NSString, context as NSString)
    }

    /// 记录一次耗时；同时写 signpost 与内存中的样本，供报告导出。
    func measure(_ name: String, milliseconds: Double, context: String = "") {
        lock.lock()
        timings[name, default: TimingHistory()].append(milliseconds)
        lock.unlock()
        os_signpost(.event, log: log, name: Self.eventName, signpostID: OSSignpostID(log: log),
                    "measure %{public}@ %.1fms %{public}@",
                    name as NSString, milliseconds, context as NSString)
        onSample?(PerformanceSample(name: name, valueMS: milliseconds, context: context))
    }

    func summary() -> [PerformanceSample] {
        lock.lock()
        defer { lock.unlock() }
        return timings.map { name, history in
            let values = history.samples
            let sorted = values.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
            return PerformanceSample(name: "\(name) p95",
                                     valueMS: p95,
                                     context: "n=\(values.count), total=\(history.totalCount), median=\(String(format: "%.1f", sorted[sorted.count / 2]))")
        }.sorted { $0.name < $1.name }
    }

    func snapshotCounters() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }
}
