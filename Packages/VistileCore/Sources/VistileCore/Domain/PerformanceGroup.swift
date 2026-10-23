import Foundation

/// 性能样本的分组维度（方案 §20.2「60Hz/120Hz、reduceMotion、冷启动/热路径分别分组」）。
///
/// 三个维度都进 key：任何一维不同就不许合并成同一个 P95。混池会把"120Hz 热路径很快"
/// 与"60Hz 冷启动很慢"平均成一个谁都对不上的数字，也正是方案要求分组的原因。
public struct PerformanceGroup: Hashable, Sendable {
    /// 采样那一刻读到的刷新率（Hz）。`<= 0` 表示这一刻取不到（显示休眠时活动显示列表为空），不是 0Hz。
    public let refreshHz: Double
    /// 系统「减弱动态效果」开关（`accessibilityDisplayShouldReduceMotion`）。
    public let reduceMotion: Bool
    /// 冷启动 = 这条路径在本进程里的第一次；之后每一次都是热路径。
    public let coldStart: Bool

    public init(refreshHz: Double, reduceMotion: Bool, coldStart: Bool) {
        self.refreshHz = refreshHz
        self.reduceMotion = reduceMotion
        self.coldStart = coldStart
    }

    /// 60/120 之外的面板照实标出来，不硬塞进两档；取不到写成"未知"，不假装是 60Hz。
    /// 容差 1Hz：ProMotion 的读数（59.94 / 119.88）要能归进对应档位。
    public static func refreshLabel(hz: Double) -> String {
        guard hz.isFinite, hz > 0 else { return "刷新率未知" }
        for known in [60.0, 120.0] where abs(hz - known) < 1.0 { return "\(Int(known))Hz" }
        return "\(String(format: "%.0f", hz))Hz"
    }

    public var refreshLabel: String { Self.refreshLabel(hz: refreshHz) }
    public var reduceMotionLabel: String { reduceMotion ? "reduceMotion=开" : "reduceMotion=关" }
    public var startLabel: String { coldStart ? "冷启动" : "热路径" }

    /// 指标名后缀就是它：`Metrics` 按名字分桶，所以分组后每段各算各的 P95。
    public var key: String { "\(refreshLabel)·\(reduceMotionLabel)·\(startLabel)" }

    /// 不带冷热的环境标签：报告头与跨轮对照用（同一台机器、同一开关下的两轮才可比）。
    public var environmentLabel: String { "\(refreshLabel)·\(reduceMotionLabel)" }

    /// 本机一个帧周期的长度；用于实际呈现预算，未知刷新率不得冒充 60Hz。
    /// The native period is the presentation budget; unknown refresh rates remain unjudged.
    public var nativeFrameIntervalMS: Double { refreshHz > 0 ? 1000.0 / refreshHz : 0 }
}

/// 一条指标在一个分组里的裁决：方案 §20.1 的目标值 × §20.2 的样本闸门。
public struct PerformanceVerdict: Hashable, Sendable {
    public enum Status: String, Sendable {
        /// 样本不足（<100 次操作）。按 §20.2「样本不足标未判」，既不算通过也不算失败。
        case undetermined
        /// 达标：P95 在 §20.1 的目标之内。
        case pass
        /// 未达标：P95 超出目标，照实写超多少。
        case miss

        public var label: String {
            switch self {
            case .undetermined: return "未判"
            case .pass: return "达标"
            case .miss: return "未达标"
            }
        }
    }

    public let groupKey: String
    public let status: Status
    public let count: Int
    public let p95MS: Double
    public let targetMS: Double

    /// 报告里的一行事实。nan（一组都没有样本）不写成数字。
    public var factText: String {
        guard count > 0 else { return "\(groupKey) 无样本（未判）" }
        let p95Text = p95MS.isFinite ? String(format: "%.0fms", p95MS) : "无有效值"
        let targetText = targetMS.isFinite && targetMS.rounded() == targetMS
            ? String(format: "%.0f", targetMS) : String(format: "%.2f", targetMS)
        return "\(groupKey) p95=\(p95Text)（目标 ≤\(targetText)ms，n=\(count)，\(status.label)）"
    }
}

/// 分组后的样本闸门与目标判定（方案 §20.1、§20.2）。纯函数，探针只负责喂样本。
public enum PerformanceGate {
    /// §20.2「每条模式路径至少 100 次操作」：按分组计数，一个组够不够 100 只看它自己。
    public static let minSamples = 100

    /// nearest-rank 分位数，与 `Metrics.summary()` 的取法一致；空集合返回 nan。
    public static func percentile(of values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
    }

    public static func p95(of values: [Double]) -> Double { percentile(of: values, 0.95) }

    /// 原始样本入口（探针自己攒的「点击→落定」）。
    public static func judge(groupKey: String, values: [Double], targetMS: Double,
                             minSamples: Int = minSamples) -> PerformanceVerdict {
        judge(groupKey: groupKey, count: values.count, p95MS: p95(of: values),
              targetMS: targetMS, minSamples: minSamples)
    }

    /// 已聚合入口（`Metrics` 的 p95 行：只给出池化后的 P95 与样本数）。
    public static func judge(groupKey: String, count: Int, p95MS: Double, targetMS: Double,
                             minSamples: Int = minSamples) -> PerformanceVerdict {
        let status: PerformanceVerdict.Status
        if count < minSamples || !p95MS.isFinite { status = .undetermined }
        else { status = p95MS > targetMS ? .miss : .pass }
        return PerformanceVerdict(groupKey: groupKey, status: status, count: count,
                                  p95MS: p95MS, targetMS: targetMS)
    }
}

/// 分组指标的命名：生产侧（协调器写样本）与读取侧（P0 探针取每组的行）共用这一套。
///
/// 名字形状是两侧之间唯一的契约。各写各的会静默失效——读取侧一行都匹配不到，
/// 报告里就变成「没有帧样本」，那是测量坏了，不是产品结论。所以放在核心包里做往返测试。
public enum PerformanceMetricName {
    /// `Metrics.summary()` 拼在指标名末尾的后缀。
    public static let summarySuffix = " p95"

    /// 分组后的全名：`<基名>·<分组键>`。measure 名与计数器名都用它。
    public static func qualified(_ base: String, group: PerformanceGroup) -> String {
        "\(base)·\(group.key)"
    }

    /// 从 `summary()` 的一行里取回分组键；不属于这一族（或键为空）返回 nil。
    public static func groupKey(fromSummaryRow name: String, base: String) -> String? {
        let head = "\(base)·"
        guard name.hasPrefix(head), name.hasSuffix(summarySuffix),
              name.count > head.count + summarySuffix.count else { return nil }
        return String(name.dropFirst(head.count).dropLast(summarySuffix.count))
    }

    /// 从计数器名里取回分组键（计数器名没有「 p95」尾巴）。
    public static func groupKey(fromCounterName name: String, base: String) -> String? {
        let head = "\(base)·"
        guard name.hasPrefix(head), name.count > head.count else { return nil }
        return String(name.dropFirst(head.count))
    }
}
