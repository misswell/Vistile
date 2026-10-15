import Foundation
import CoreGraphics

/// 前景真实窗口的目标几何（方案 §10.1）。
/// 只保证背景可点击，不保证所有背景卡片都完整可见。
public enum FocusGeometry {
    public static func targetRect(visibleFrame: CGRect,
                                  policy: SessionPolicy,
                                  currentSize: CGSize?,
                                  isResizable: Bool) -> CGRect {
        guard isResizable, visibleFrame.width > 0, visibleFrame.height > 0 else {
            // 尺寸无法调整时按原尺寸居中，不反复强制拉伸。
            return centeredOriginal(in: visibleFrame, size: currentSize)
        }
        let inset = max(policy.foregroundEdgeInset, 0)
        let maxWidth = max(1, visibleFrame.width - 2 * inset)
        let maxHeight = max(1, visibleFrame.height - 2 * inset)
        let width = min(SessionPolicy.clamped(policy.foregroundWidthRatio) * Double(visibleFrame.width), Double(maxWidth))
        let height = min(SessionPolicy.clamped(policy.foregroundHeightRatio) * Double(visibleFrame.height), Double(maxHeight))
        let rect = CGRect(x: visibleFrame.midX - width / 2,
                          y: visibleFrame.midY - height / 2,
                          width: width,
                          height: height)
        // 边界限制在可用屏幕内。
        return CGRect(x: min(max(rect.minX, visibleFrame.minX + inset), visibleFrame.maxX - inset - rect.width),
                      y: min(max(rect.minY, visibleFrame.minY + inset), visibleFrame.maxY - inset - rect.height),
                      width: rect.width,
                      height: rect.height)
    }

    private static func centeredOriginal(in visibleFrame: CGRect, size: CGSize?) -> CGRect {
        guard let size, size.width > 0, size.height > 0 else { return visibleFrame }
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.midY - height / 2,
                      width: width,
                      height: height)
    }

    /// 过渡代理的中间矩形：容器矩形插值 + 内容等比适配，不做非均匀图像拉伸。
    public static func interpolated(from source: CGRect, to destination: CGRect, progress: Double) -> CGRect {
        let t = min(1, max(0, progress))
        return CGRect(x: source.minX + (destination.minX - source.minX) * CGFloat(t),
                      y: source.minY + (destination.minY - source.minY) * CGFloat(t),
                      width: source.width + (destination.width - source.width) * CGFloat(t),
                      height: source.height + (destination.height - source.height) * CGFloat(t))
    }
}
