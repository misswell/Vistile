import Foundation
import CoreGraphics

public struct DisplayInfo: Hashable, Sendable {
    public let id: UInt32
    /// CG 全局坐标（左上原点，主显示器左上角为 0,0）。
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let backingScale: CGFloat
    public let isPrimary: Bool

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect, backingScale: CGFloat, isPrimary: Bool) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScale = backingScale
        self.isPrimary = isPrimary
    }
}

/// 坐标统一约定：领域层使用 CG 全局坐标，其它坐标系显式经过这里转换（方案 §12）。
/// CG→AppKit 翻转只以主显示器高度为基准，不对每个屏幕单独翻转。
public struct CoordinateMapper: Sendable {
    public let displays: [DisplayInfo]
    public let primaryHeight: CGFloat

    public init(displays: [DisplayInfo]) {
        self.displays = displays
        let primary = displays.first { $0.isPrimary } ?? displays.first
        self.primaryHeight = primary?.frame.height ?? 0
    }

    public func display(id: UInt32) -> DisplayInfo? {
        displays.first { $0.id == id }
    }

    public var primaryDisplay: DisplayInfo? {
        displays.first { $0.isPrimary } ?? displays.first
    }

    public func cgToAppKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    public func appKitToCg(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    /// AX 坐标本身就是全局左上原点，转换是恒等，但保留显式入口以免调用点误以为已翻转。
    public func axToCg(_ rect: CGRect) -> CGRect { rect }

    /// 窗口归属与其 frame 交集面积最大的屏幕；跨屏窗口不重复展示。
    public func ownerDisplay(of rect: CGRect) -> DisplayInfo? {
        displays
            .map { ($0, intersectionArea($0.frame, rect)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    public func visibleFrame(for rect: CGRect) -> CGRect {
        (ownerDisplay(of: rect) ?? primaryDisplay)?.visibleFrame ?? .zero
    }

    /// 把矩形夹进目标屏幕可用区：优先保持尺寸，放不下时才移动；尺寸大于可用区时只保证左上角可见。
    public func clamp(_ rect: CGRect, to displayID: UInt32?, minimumVisibleEdge: CGFloat = 24) -> CGRect {
        guard let target = displayID.flatMap({ display(id: $0) }) ?? primaryDisplay else { return rect }
        let visible = target.visibleFrame
        guard visible.width > 0, visible.height > 0 else { return rect }

        var origin = rect.origin
        let size = CGSize(width: min(rect.width, visible.width), height: min(rect.height, visible.height))
        let maxX = visible.maxX - size.width
        let maxY = visible.maxY - size.height
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, maxX))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, maxY))

        // 副屏被拔掉后原 frame 完全落在存活屏幕之外：居中到目标屏可用区。
        if intersectionArea(visible, CGRect(origin: origin, size: size)) > 0 {
            return CGRect(origin: origin, size: size)
        }
        return CGRect(x: visible.minX + (visible.width - size.width) / 2,
                      y: visible.minY + (visible.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// SC 流输出像素尺寸与源点尺寸的换算，禁止把点当像素（方案 §9）。
    public func pixelSize(for rect: CGRect, backingScale: CGFloat) -> CGSize {
        CGSize(width: (rect.width * backingScale).rounded(), height: (rect.height * backingScale).rounded())
    }

    public func rect(from contentRect: CGRect, scaleFactor: CGFloat, in container: CGRect) -> CGRect {
        guard scaleFactor > 0 else { return container }
        return CGRect(x: container.minX + contentRect.minX / scaleFactor,
                      y: container.minY + contentRect.minY / scaleFactor,
                      width: contentRect.width / scaleFactor,
                      height: contentRect.height / scaleFactor)
    }

    private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        return inter.isNull || inter.isEmpty ? 0 : inter.width * inter.height
    }
}
