import Foundation
import CoreGraphics

/// 性能档位（方案 §13）。UI 只显示这几个有意义的名字，不暴露 buffer 参数。
public enum CaptureTier: String, Sendable, Hashable, CaseIterable, Codable {
    case balanced
    case powerSaving
    case refreshPriority

    /// 目标帧率是上限，不是承诺。
    public var targetFPS: Int {
        switch self {
        case .balanced: return 8
        case .powerSaving: return 3
        case .refreshPriority: return 15
        }
    }

    public var hoverFPS: Int {
        switch self {
        case .balanced, .refreshPriority: return 15
        case .powerSaving: return 8
        }
    }

    public var maxPixelWidth: Int {
        switch self {
        case .balanced: return 960
        case .powerSaving: return 640
        case .refreshPriority: return 1280
        }
    }

    /// queueDepth 取系统默认 3，不超过官方上限 8（方案 §9 [S3]）。
    public var queueDepth: Int { 3 }
}

public enum ThermalState: String, Sendable, Hashable, CaseIterable {
    case nominal, fair, serious, critical
}

/// 单窗口流的输出配置。几何变化不重建流，尺寸调整合并延迟 250ms。
public struct StreamConfig: Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    public var queueDepth: Int
    public var capturesAudio: Bool
    public var showsCursor: Bool

    public init(pixelWidth: Int, pixelHeight: Int, fps: Int, queueDepth: Int,
                capturesAudio: Bool = false, showsCursor: Bool = false) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.queueDepth = queueDepth
        self.capturesAudio = capturesAudio
        self.showsCursor = showsCursor
    }

    public static func build(cellWidth: CGFloat,
                             backingScale: CGFloat,
                             sourceSize: CGSize,
                             tier: CaptureTier,
                             qualityFactor: Double = 1.0,
                             fpsOverride: Int? = nil,
                             widthCapOverride: Int? = nil) -> StreamConfig {
        let cap = widthCapOverride ?? tier.maxPixelWidth
        let requested = Int((cellWidth * backingScale * qualityFactor).rounded())
        let width = max(32, min(cap, requested))
        let height: Int
        if sourceSize.width > 0, sourceSize.height > 0 {
            // 保持源宽高比，输出像素不做非均匀拉伸。
            height = max(1, Int((CGFloat(width) * sourceSize.height / sourceSize.width).rounded()))
        } else {
            height = max(1, width * 9 / 16)
        }
        return StreamConfig(pixelWidth: width,
                            pixelHeight: height,
                            fps: fpsOverride ?? tier.targetFPS,
                            queueDepth: min(8, max(1, tier.queueDepth)),
                            capturesAudio: false,
                            showsCursor: false)
    }

    /// 动画中不逐帧改配置；变化必须等待合并窗口结束。
    public func needsReconfiguration(to candidate: StreamConfig,
                                      elapsedSinceLastChange: TimeInterval,
                                      isAnimating: Bool,
                                      debounceInterval: TimeInterval = 0.25) -> Bool {
        guard !isAnimating else { return false }
        guard candidate != self else { return false }
        return elapsedSinceLastChange >= debounceInterval
    }
}

public enum BudgetAction: Hashable, Sendable {
    case keep
    case lowerFPS(Int)
    case lowerOutputWidth(Int)
    case poll(intervalMilliseconds: Int)

    /// UI 必须显示真实刷新间隔，不能把轮询标成实时。
    public var displayedPhase: CapturePhase {
        switch self {
        case .keep: return .live
        case .lowerFPS: return .live
        case .lowerOutputWidth: return .live
        case let .poll(intervalMilliseconds): return .lowFrequency(intervalMilliseconds: intervalMilliseconds)
        }
    }
}

/// 超预算时的固定降级顺序：8→5→3fps；降低输出分辨率；仍超限则轮询（方案 §9）。
public enum CaptureBudget {
    public static let fpsLadder = [15, 10, 8, 5, 3]
    public static let widthLadder = [1280, 960, 720, 560, 400]
    public static let pollLadder = [1_000, 2_000, 4_000]

    public static func nextAction(currentFPS: Int,
                                  currentWidth: Int,
                                  streams: Int,
                                  streamSoftLimit: Int,
                                  thermal: ThermalState,
                                  isPriority: Bool) -> BudgetAction {
        let overLimit = streams > streamSoftLimit
        let hotThermal = thermal == .serious || thermal == .critical
        guard overLimit || hotThermal else { return .keep }
        // 优先刷新窗口最后降级：只有远超软上限或热状态危急时才牺牲它。
        if isPriority, streams <= streamSoftLimit * 2, thermal != .critical { return .keep }

        // 1. 降帧率（每次只降一级）
        if let lower = fpsLadder.filter({ $0 < currentFPS }).max() {
            return .lowerFPS(lower)
        }
        if currentFPS > 3 { return .lowerFPS(3) }
        // 2. 降输出分辨率
        if let narrower = widthLadder.filter({ $0 < currentWidth }).max() {
            return .lowerOutputWidth(narrower)
        }
        // 3. 低优先级卡片轮询更新
        return .poll(intervalMilliseconds: pollLadder[0])
    }

    public static func pollInterval(after intervalMilliseconds: Int) -> Int {
        pollLadder.first { $0 > intervalMilliseconds } ?? pollLadder.last ?? 4_000
    }

    /// 长时间没有新帧不等于失败：只有流错误、最小化或窗口关闭才是状态变化。
    public static func capturePhase(for record: WindowRecord,
                                    now: Date,
                                    stallThreshold: TimeInterval = 5) -> CapturePhase {
        if record.isMinimized, record.capture == .live || record.capture == .idle {
            return .pausedMinimized
        }
        // idle 帧保留最后画面，仍显示为原状态，不改成失败。
        return record.capture
    }
}
