import Foundation
import CoreGraphics

/// 恢复目标为什么是这个值（方案 §8）：报告与日志必须说得出降级原因。
public enum RestoreDestinationReason: Hashable, Sendable {
    /// 原屏仍在，原 frame 依旧有效：精确恢复。
    case exactOnOriginalDisplay
    /// 原屏仍在但分辨率/可用区变了：在原屏内夹取。
    case adjustedOnOriginalDisplay
    /// 原屏已消失：夹到备用屏可用区。
    case originalDisplayUnavailable
    /// 用户明确保留的位置：按 override 自己的矩形选屏。
    case overrideOnDisplay
}

/// 唯一的恢复目标规划结果（方案 §8）。写入方拿到 targetFrame 就直接写，
/// 禁止再按 record.displayID 或"窗口此刻所在屏"二次重算。
public struct RestoreDestination: Hashable, Sendable {
    public let targetDisplayID: UInt32?
    public let targetFrame: CGRect
    public let reason: RestoreDestinationReason
    /// 原屏或原位置没能保住：结算与报告都要按降级处理，不能报"精确恢复"。
    public var isDowngraded: Bool {
        reason == .adjustedOnOriginalDisplay || reason == .originalDisplayUnavailable
    }

    public init(targetDisplayID: UInt32?, targetFrame: CGRect, reason: RestoreDestinationReason) {
        self.targetDisplayID = targetDisplayID
        self.targetFrame = targetFrame
        self.reason = reason
    }
}

/// 显示器选择 + 目标 frame 计算的唯一入口（方案 §8）。
/// 只接受显示器可用性事实，不接受"窗口现在在哪块屏"这种会诱发二次夹取的信息。
public enum RestorePlanner {
    /// `originalVisibleFrame`：原始屏当前可用区，原屏消失时传 nil。
    /// `fallbackVisibleFrame`：明确备用屏的可用区；`fallbackDisplayID` 是那块屏的身份。
    public static func plan(entry: WindowTransaction,
                            originalDisplayIsLive: Bool,
                            originalVisibleFrame: CGRect?,
                            fallbackVisibleFrame: CGRect?,
                            fallbackDisplayID: UInt32? = nil) -> RestoreDestination? {
        // 规则 4：用户保留的位置按它自己的矩形决定落点，不盲用目录里最近的 displayID。
        if let override = entry.userOverrideFrame {
            return planOverride(override,
                                entry: entry,
                                originalDisplayIsLive: originalDisplayIsLive,
                                originalVisibleFrame: originalVisibleFrame,
                                fallbackVisibleFrame: fallbackVisibleFrame,
                                fallbackDisplayID: fallbackDisplayID)
        }
        guard originalDisplayIsLive, let originalVisibleFrame, originalVisibleFrame.width > 1,
              originalVisibleFrame.height > 1 else {
            // 规则 3：原屏消失，只能落进有明确身份的备用屏可用区。
            guard let fallback = fallbackVisibleFrame, fallback.width > 1, fallback.height > 1 else { return nil }
            return RestoreDestination(targetDisplayID: fallbackDisplayID,
                                      targetFrame: clamp(entry.originalFrame, into: fallback),
                                      reason: .originalDisplayUnavailable)
        }
        // 规则 1：原 frame 仍在原屏可用范围内有效——精确恢复，不动坐标。
        if contains(originalVisibleFrame, entry.originalFrame) {
            return RestoreDestination(targetDisplayID: entry.originalDisplayID,
                                      targetFrame: entry.originalFrame,
                                      reason: .exactOnOriginalDisplay)
        }
        // 规则 2：原屏仍在但可用范围变了，只在原屏内做必要夹取。
        return RestoreDestination(targetDisplayID: entry.originalDisplayID,
                                  targetFrame: clamp(entry.originalFrame, into: originalVisibleFrame),
                                  reason: .adjustedOnOriginalDisplay)
    }

    private static func planOverride(_ override: CGRect,
                                     entry: WindowTransaction,
                                     originalDisplayIsLive: Bool,
                                     originalVisibleFrame: CGRect?,
                                     fallbackVisibleFrame: CGRect?,
                                     fallbackDisplayID: UInt32?) -> RestoreDestination {
        if originalDisplayIsLive, let visible = originalVisibleFrame, contains(visible, override) {
            return RestoreDestination(targetDisplayID: entry.originalDisplayID,
                                      targetFrame: override,
                                      reason: .overrideOnDisplay)
        }
        if let visible = fallbackVisibleFrame, contains(visible, override) {
            return RestoreDestination(targetDisplayID: fallbackDisplayID,
                                      targetFrame: override,
                                      reason: .overrideOnDisplay)
        }
        // override 不在任何已知屏内：按与矩形相交最多的那块屏夹取。
        if let visible = originalVisibleFrame, originalDisplayIsLive,
           intersectionArea(visible, override) >= intersectionArea(fallbackVisibleFrame ?? .zero, override) {
            return RestoreDestination(targetDisplayID: entry.originalDisplayID,
                                      targetFrame: clamp(override, into: visible),
                                      reason: .overrideOnDisplay)
        }
        if let visible = fallbackVisibleFrame {
            return RestoreDestination(targetDisplayID: fallbackDisplayID,
                                      targetFrame: clamp(override, into: visible),
                                      reason: .overrideOnDisplay)
        }
        return RestoreDestination(targetDisplayID: originalDisplayIsLive ? entry.originalDisplayID : fallbackDisplayID,
                                  targetFrame: override,
                                  reason: .overrideOnDisplay)
    }

    /// 整块包含判定（2pt 容差）：跨屏或贴边被切掉都不算"仍然有效"。
    private static func contains(_ container: CGRect, _ frame: CGRect) -> Bool {
        let t: CGFloat = 2
        return frame.minX >= container.minX - t
            && frame.minY >= container.minY - t
            && frame.maxX <= container.maxX + t
            && frame.maxY <= container.maxY + t
    }

    /// 夹取时保留尺寸：尺寸本身大于可用区时先缩到可用区内，保证结果落在屏内。
    private static func clamp(_ frame: CGRect, into visible: CGRect) -> CGRect {
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - width))
        let y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let box = a.intersection(b)
        return box.isNull ? 0 : box.width * box.height
    }
}
