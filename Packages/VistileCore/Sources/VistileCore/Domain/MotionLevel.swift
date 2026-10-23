import Foundation

/// 过渡动效等级（方案 §20.4）：完整 → 轻量 → 最简淡化。
/// 等级只影响动画成本，不改变任何布局、时序语义与最终画面（方案 §20.3 的硬验收不变）。
public enum MotionLevel: String, Hashable, Sendable, CaseIterable, Codable {
    /// 共享 GPU 卡片变换 + 淡化。
    case full
    /// 只对选中卡片做几何缩放，其余卡片不做位移、100–160ms 淡化。
    case light
    /// 全员 80–120ms 短淡化，不飞行。
    case fade

    public var displayName: String {
        switch self {
        case .full: return "完整"
        case .light: return "轻量"
        case .fade: return "淡化"
        }
    }

    public var degraded: MotionLevel {
        switch self {
        case .full: return .light
        case .light, .fade: return .fade
        }
    }

    public var recovered: MotionLevel {
        switch self {
        case .full, .light: return .full
        case .fade: return .light
        }
    }
}

/// Refresh-rate-aware interval statistics. A 0.05ms tolerance only covers timestamp rounding.
public struct FrameIntervalStats: Hashable, Sendable {
    public static let defaultFrameBudgetMS = 1000.0 / 60.0
    public static let timestampToleranceMS = 0.05
    public static let longFrameMS = defaultFrameBudgetMS * 2
    public static let maxP95MS = defaultFrameBudgetMS + timestampToleranceMS
    public static let maxLongFrameRatio = 0.01
    public static let maxStutterRun = 3

    public let count: Int
    public let p95MS: Double
    public let p99MS: Double
    public let maximumMS: Double
    public let frameBudgetMS: Double
    public let longFrameRatio: Double
    public let longestStutterRun: Int

    public var meetsTarget: Bool {
        p95MS <= frameBudgetMS + Self.timestampToleranceMS
            && longFrameRatio <= Self.maxLongFrameRatio
            && longestStutterRun < Self.maxStutterRun
    }

    public static func slowFrameThreshold(frameBudgetMS: Double) -> Double {
        max(12, normalizedBudget(frameBudgetMS) * 1.5)
    }

    public static func normalizedBudget(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : defaultFrameBudgetMS
    }

    public static func measure(_ intervalsMS: [Double], frameBudgetMS: Double = defaultFrameBudgetMS) -> FrameIntervalStats? {
        let ordered = intervalsMS.filter { $0.isFinite && $0 > 0 }
        guard ordered.count >= 3 else { return nil }
        let sorted = ordered.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let budget = normalizedBudget(frameBudgetMS)
        let longThreshold = budget * 2
        let long = sorted.filter { $0 > longThreshold }.count
        var run = 0
        var longest = 0
        for value in ordered {
            if value > longThreshold {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return FrameIntervalStats(count: ordered.count,
                                  p95MS: percentile(0.95),
                                  p99MS: percentile(0.99),
                                  maximumMS: sorted[sorted.count - 1],
                                  frameBudgetMS: budget,
                                  longFrameRatio: Double(long) / Double(ordered.count),
                                  longestStutterRun: longest)
    }
}

/// 一段过渡飞行的呈现事实（方案 §20.2）：首帧延迟单独记录，回调次数与真实呈现次数分开核对。
///
/// displayLink 回调 N 次不代表屏幕换了 N 帧：取不到 drawable、提交失败都只回调不呈现。
/// 只用帧间隔统计会把"点了但很久没出第一帧"和"整段没有像素"都掩盖掉。
public struct TransitionFlightFacts: Hashable, Sendable {
    /// 真实输入 → 第一段画面 present 出去的毫秒数；整段一次都没 present 成功时为 nil。
    public let firstPresentDelayMS: Double?
    public let firstSubmissionDelayMS: Double?
    public let submittedFrames: Int
    public let gpuExecutionP95MS: Double?
    public let presentationComplete: Bool
    public let frameBudgetMS: Double
    /// 飞行期间收到的 tick 次数。
    public let ticks: Int
    /// 飞行期间渲染器实际 present 出去的帧数（含 play() 同步画的第一帧）。
    public let presentedFrames: Int
    /// 首帧延迟是否锚在真实输入上。false 表示没有前置输入（自动替补、探针直接驱动），
    /// 按动画进入时刻算——这种样本不能混进"点击反馈"的 P95。
    public let anchoredAtRealInput: Bool

    public init(firstPresentDelayMS: Double?, ticks: Int, presentedFrames: Int, anchoredAtRealInput: Bool,
                firstSubmissionDelayMS: Double? = nil, submittedFrames: Int? = nil,
                gpuExecutionP95MS: Double? = nil, presentationComplete: Bool = true,
                frameBudgetMS: Double = FrameIntervalStats.defaultFrameBudgetMS) {
        self.firstPresentDelayMS = firstPresentDelayMS
        self.firstSubmissionDelayMS = firstSubmissionDelayMS
        self.submittedFrames = submittedFrames ?? presentedFrames
        self.gpuExecutionP95MS = gpuExecutionP95MS
        self.presentationComplete = presentationComplete
        self.frameBudgetMS = FrameIntervalStats.normalizedBudget(frameBudgetMS)
        self.ticks = ticks
        self.presentedFrames = presentedFrames
        self.anchoredAtRealInput = anchoredAtRealInput
    }

    /// 一次 present 都没有的过渡不能当画面证据：tick 再多也只是回调。
    public var hasPresentedPixels: Bool { presentedFrames > 0 }
    /// 回调多于呈现的差额：>0 说明有 tick 没有换成屏幕上的帧。
    public var missedPresentFrames: Int { max(0, ticks - presentedFrames) }
}

/// 动效等级决策（方案 §20.4）：在后续过渡中降级、记录原因、用滞后避免反复抖动。
///
/// 基准等级来自启动事实（系统减少动态效果、采集档位）；低于基准的等级只由
/// 「连续卡顿观测」驱动。降得快（连续两段超预算降一级）、升得慢（连续八段流畅升一级），
/// 决策只发生在每次过渡结束时，绝不每帧切换。
public struct MotionLevelController: Sendable {
    public static let degradeAfterBadScenes = 2
    public static let recoverAfterCleanScenes = 8

    public private(set) var level: MotionLevel
    /// 最近一次等级变化/基准设置的原因，供诊断与真机验收记录（方案 §20.4「记录降级原因」）。
    public private(set) var reason: String

    private var base: MotionLevel
    private var badStreak = 0
    private var cleanStreak = 0

    public init(reduceMotion: Bool = false, pressureTier: CaptureTier = .balanced) {
        let base = Self.baseLevel(reduceMotion: reduceMotion, pressureTier: pressureTier)
        self.base = base
        level = base
        reason = Self.baseReason(reduceMotion: reduceMotion, pressureTier: pressureTier)
    }

    /// 基准事实变化（系统设置翻转、采集档位切换）：回到新基准并清掉旧观测。
    /// 旧观测得出的等级是针对旧基准的结论，不能带进新基准。
    public mutating func update(reduceMotion: Bool, pressureTier: CaptureTier) {
        let newBase = Self.baseLevel(reduceMotion: reduceMotion, pressureTier: pressureTier)
        guard newBase != base else { return }
        base = newBase
        level = newBase
        badStreak = 0
        cleanStreak = 0
        reason = Self.baseReason(reduceMotion: reduceMotion, pressureTier: pressureTier)
    }

    /// 一段过渡飞行结束后的观测。返回变化后的等级；没变返回 nil。
    @discardableResult
    public mutating func observe(_ stats: FrameIntervalStats) -> MotionLevel? {
        if stats.meetsTarget {
            badStreak = 0
            cleanStreak += 1
        } else {
            cleanStreak = 0
            badStreak += 1
        }
        if badStreak >= Self.degradeAfterBadScenes, level != .fade {
            let previous = level
            level = level.degraded
            badStreak = 0
            reason = "连续\(Self.degradeAfterBadScenes)段过渡超出帧预算"
                + "（p95 \(Self.format(stats.p95MS))ms、掉帧 \(Self.format(stats.longFrameRatio * 100))%）"
                + "：\(previous.displayName)→\(level.displayName)"
            return level
        }
        if cleanStreak >= Self.recoverAfterCleanScenes, level != base {
            let previous = level
            level = level.recovered
            cleanStreak = 0
            reason = "连续\(Self.recoverAfterCleanScenes)段过渡流畅：\(previous.displayName)→\(level.displayName)"
            return level
        }
        return nil
    }

    private static func baseLevel(reduceMotion: Bool, pressureTier: CaptureTier) -> MotionLevel {
        if reduceMotion { return .fade }
        return pressureTier == .powerSaving ? .light : .full
    }

    private static func baseReason(reduceMotion: Bool, pressureTier: CaptureTier) -> String {
        if reduceMotion { return "系统减少动态效果：只用短淡化" }
        return pressureTier == .powerSaving ? "低功耗档位：从轻量开始" : "默认完整动效"
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
