import Foundation
import CoreGraphics

/// 主区放置决策（方案 §9.1）。把"能不能进主区、以什么方式进"收敛成一次纯计算，
/// 宿主只执行算出来的那条路径，不再自行判断尺寸。
public enum MainPlacementDecision: Hashable, Sendable {
    /// 可调尺寸：精确占据主区。
    case resizeAndMove(target: CGRect)
    /// 固定尺寸但可移动：保持**真实原尺寸**，在主区内居中，只走 position 写入路径。
    case moveOnly(origin: CGPoint, originalSize: CGSize)
    /// 不可移动、或原尺寸放不进主区：不宣布进入主区（方案 §9.1）。
    case unavailable(reason: String)

    /// 计划要写入的目标矩形；不可容纳时为 nil。
    public var targetFrame: CGRect? {
        switch self {
        case let .resizeAndMove(target): return target
        case let .moveOnly(origin, size): return CGRect(origin: origin, size: size)
        case .unavailable: return nil
        }
    }

    /// 仅移动路径不得写 size：宿主据此选择 position-only 通道（方案 §9.1、§24）。
    public var writesSize: Bool {
        if case .resizeAndMove = self { return true }
        return false
    }
}

/// 读回包含性判定（方案 §9.2）：受限不等于合格。
public enum PlacementVerification: Hashable, Sendable {
    /// 四边都在主区内、且与栏的相交不超容差：可以提交 placement。
    case accepted(frame: CGRect)
    /// 只是越界、尺寸本身仍放得进主区：允许一次有界的 position 修正。
    case correctPosition(to: CGRect)
    /// 修正后仍越界或覆盖栏：补偿，不提交。
    case rejected(reason: String)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// 纯逻辑几何判定：可调整尺寸、仅移动、受限读回、主区包含性与不可容纳（方案 §4、§9）。
public enum MainPlacementPolicy {
    /// 点坐标容差：主区包含性按边判定，不按面积（方案 §9.2）。
    public static let containmentTolerance: CGFloat = 2

    /// `currentFrame` 为 nil 表示写前实读失败：此时不得盲目写入（方案 §6.2）。
    /// `isMovable`/`isResizable` 必须是 AX 实读结果，不能用"目录里看着像"代替。
    public static func decide(mainRect: CGRect,
                              currentFrame: CGRect?,
                              isMovable: Bool,
                              isResizable: Bool) -> MainPlacementDecision {
        guard mainRect.width > containmentTolerance, mainRect.height > containmentTolerance else {
            return .unavailable(reason: "主区可用空间不足，无法放下窗口")
        }
        guard let frame = currentFrame, frame.width > 0, frame.height > 0 else {
            return .unavailable(reason: "读不到窗口当前位置，暂不调整尺寸")
        }
        guard isMovable else {
            return .unavailable(reason: "这个窗口不允许移动，无法放进主区")
        }
        if isResizable {
            // 尊重真实尺寸（方案 §9.1 修订）：原尺寸放得下主区就只写位置、不动尺寸；
            // 只有超出主区的窗口才按原宽高比等比收缩贴边。不再强制放大铺满主区。
            if let centered = FocusGeometry.centeredOriginalRect(in: mainRect, size: frame.size) {
                return .moveOnly(origin: centered.origin, originalSize: centered.size)
            }
            return .resizeAndMove(target: FocusGeometry.scaledDownRect(in: mainRect, currentSize: frame.size))
        }
        // 固定尺寸：只有真实尺寸本身能放进主区才进；裁小尺寸再宣称"保留原尺寸"是假的（方案 §9.1）。
        guard frame.width <= mainRect.width + containmentTolerance,
              frame.height <= mainRect.height + containmentTolerance else {
            return .unavailable(reason: "窗口尺寸 \(Int(frame.width))×\(Int(frame.height)) 大于主区 \(Int(mainRect.width))×\(Int(mainRect.height))，无法在不裁切的前提下放入主区")
        }
        guard let centered = FocusGeometry.centeredOriginalRect(in: mainRect, size: frame.size) else {
            return .unavailable(reason: "窗口尺寸超出主区范围，无法在主区内居中")
        }
        return .moveOnly(origin: centered.origin, originalSize: centered.size)
    }

    /// 读回包含性：尺寸有效、四边在主区内、与两条栏的相交不超容差。
    public static func verify(readBack: CGRect,
                              mainRect: CGRect,
                              topRailRect: CGRect,
                              sideRailRect: CGRect) -> PlacementVerification {
        guard readBack.width > 0, readBack.height > 0 else {
            return .rejected(reason: "读回尺寸无效：\(RecoveryText.frame(readBack))")
        }
        if isContained(readBack, in: mainRect), !overlapsRails(readBack, top: topRailRect, side: sideRailRect) {
            return .accepted(frame: readBack)
        }
        // 尺寸本身放得进主区：越界只是位置问题，允许一次有界修正。
        guard readBack.width <= mainRect.width + containmentTolerance,
              readBack.height <= mainRect.height + containmentTolerance else {
            return .rejected(reason: "读回 \(RecoveryText.frame(readBack)) 超出主区 \(RecoveryText.frame(mainRect)) 的尺寸范围")
        }
        let corrected = clampedOrigin(of: readBack, into: mainRect)
        guard isContained(corrected, in: mainRect), !overlapsRails(corrected, top: topRailRect, side: sideRailRect) else {
            return .rejected(reason: "修正到 \(RecoveryText.frame(corrected)) 后仍越界或覆盖预览栏")
        }
        return .correctPosition(to: corrected)
    }

    /// 主窗口读回是否已脱离主区（越界或盖住栏）：用户拖动后需要带回。
    /// 与 `verify` 的接受判据互补：verify 判"写入是否合格"，这里判"要不要发起一次带回"。
    public static func needsRedock(readBack: CGRect,
                                   mainRect: CGRect,
                                   topRailRect: CGRect,
                                   sideRailRect: CGRect) -> Bool {
        guard readBack.width > 0, readBack.height > 0 else { return false }
        return !isContained(readBack, in: mainRect)
            || overlapsRails(readBack, top: topRailRect, side: sideRailRect)
    }

    // MARK: - 判定细节

    private static func isContained(_ frame: CGRect, in mainRect: CGRect) -> Bool {
        let t = containmentTolerance
        return frame.minX >= mainRect.minX - t
            && frame.minY >= mainRect.minY - t
            && frame.maxX <= mainRect.maxX + t
            && frame.maxY <= mainRect.maxY + t
    }

    /// 与栏的相交只在"垂直于栏长边方向的侵入深度"上判容差：
    /// 顶栏看纵向、侧栏看横向；贴着边 2pt 以内的数值误差不算覆盖。
    private static func overlapsRails(_ frame: CGRect, top: CGRect, side: CGRect) -> Bool {
        guard !top.isNull, top.width > 0, top.height > 0 else { return false }
        let t = containmentTolerance
        let topOverlap = frame.intersection(top)
        if !topOverlap.isNull, topOverlap.width > t, topOverlap.height > t { return true }
        guard !side.isNull, side.width > 0, side.height > 0 else { return false }
        let sideOverlap = frame.intersection(side)
        return !sideOverlap.isNull && sideOverlap.width > t && sideOverlap.height > t
    }

    /// 保持尺寸、只改 origin，把矩形挪进主区。
    private static func clampedOrigin(of frame: CGRect, into mainRect: CGRect) -> CGRect {
        let x = min(max(frame.minX, mainRect.minX), max(mainRect.minX, mainRect.maxX - frame.width))
        let y = min(max(frame.minY, mainRect.minY), max(mainRect.minY, mainRect.maxY - frame.height))
        return CGRect(x: x, y: y, width: frame.width, height: frame.height)
    }
}
