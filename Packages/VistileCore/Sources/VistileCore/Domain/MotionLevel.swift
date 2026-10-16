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

/// 一段飞行的帧间隔统计（方案 §20.3）：以 16.67ms 为基准的 P95、超过 33.3ms 的占比与最长连续掉帧。
public struct FrameIntervalStats: Hashable, Sendable {
    /// 33.33ms：两倍基准帧间隔，超过就算一次明显掉帧。
    public static let longFrameMS = 2000.0 / 60.0
    public static let maxP95MS = 20.0
    public static let maxLongFrameRatio = 0.01
    /// 连续 3 帧明显卡顿就不合格：「无连续 3 帧明显卡顿」是 §20.3 的原文。
    public static let maxStutterRun = 3

    public let count: Int
    public let p95MS: Double
    public let longFrameRatio: Double
    public let longestStutterRun: Int

    public var meetsTarget: Bool {
        p95MS <= Self.maxP95MS
            && longFrameRatio <= Self.maxLongFrameRatio
            && longestStutterRun < Self.maxStutterRun
    }

    /// 少于 3 个间隔不足以判断：刚起步就结束的过渡不该被拿来下结论。
    public static func measure(_ intervalsMS: [Double]) -> FrameIntervalStats? {
        let ordered = intervalsMS.filter { $0.isFinite && $0 > 0 }
        guard ordered.count >= 3 else { return nil }
        let sorted = ordered.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let long = sorted.filter { $0 > Self.longFrameMS }.count
        var run = 0
        var longest = 0
        for value in ordered {
            if value > Self.longFrameMS {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return FrameIntervalStats(count: ordered.count,
                                  p95MS: p95,
                                  longFrameRatio: Double(long) / Double(ordered.count),
                                  longestStutterRun: longest)
    }
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
