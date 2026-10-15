import Foundation
import os
import VistileCore

/// os_signpost 区间与轻量计数。正常用户界面不显示这些技术参数（方案 §13）。
final class Metrics {
    static let shared = Metrics()

    private let log = OSLog(subsystem: "com.misswell.Vistile", category: "session")
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var timings: [String: [Double]] = [:]
    private var signpostIDs: [String: OSSignpostID] = [:]

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
        timings[name, default: []].append(milliseconds)
        lock.unlock()
        os_signpost(.event, log: log, name: Self.eventName, signpostID: OSSignpostID(log: log),
                    "measure %{public}@ %.1fms %{public}@",
                    name as NSString, milliseconds, context as NSString)
        onSample?(PerformanceSample(name: name, valueMS: milliseconds, context: context))
    }

    func summary() -> [PerformanceSample] {
        lock.lock()
        defer { lock.unlock() }
        return timings.map { name, values in
            let sorted = values.sorted()
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
            return PerformanceSample(name: "\(name) p95",
                                     valueMS: p95,
                                     context: "n=\(values.count), median=\(String(format: "%.1f", sorted[sorted.count / 2]))")
        }.sorted { $0.name < $1.name }
    }

    func snapshotCounters() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }
}
