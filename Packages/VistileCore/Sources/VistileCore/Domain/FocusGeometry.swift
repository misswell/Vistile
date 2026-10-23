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

    /// 尺寸放得下时返回**真实原尺寸**的居中矩形，放不下返回 nil。
    /// 只有这条判据能保证"保留原尺寸"不是把尺寸裁小之后的说辞（方案 §9.1）。
    public static func centeredOriginalRect(in container: CGRect, size: CGSize?) -> CGRect? {
        guard let size, size.width > 0, size.height > 0 else { return nil }
        guard size.width <= container.width, size.height <= container.height else { return nil }
        return CGRect(x: container.midX - size.width / 2,
                      y: container.midY - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    /// 总览聚焦路径的兜底：容器小于窗口时按容器夹取，此时不得宣称"保留原尺寸"。
    private static func centeredOriginal(in visibleFrame: CGRect, size: CGSize?) -> CGRect {
        if let fits = centeredOriginalRect(in: visibleFrame, size: size) { return fits }
        guard let size, size.width > 0, size.height > 0 else { return visibleFrame }
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.midY - height / 2,
                      width: width,
                      height: height)
    }

    /// 工作台主区停靠：模式决定可调窗口的形态——尊重原尺寸时原样居中/超屏等比收缩
    /// （方案 §11 修订），充满主区时精确占满（旧语义）；不可调窗口两种模式下都原样居中，
    /// 放不下按容器夹取兜底。
    public static func dockedRect(in mainRect: CGRect,
                                  currentSize: CGSize?,
                                  isResizable: Bool,
                                  docking: MainAreaDocking = .respectful) -> CGRect {
        guard mainRect.width > 1, mainRect.height > 1 else { return mainRect }
        if isResizable {
            return docking == .fill ? mainRect : scaledDownRect(in: mainRect, currentSize: currentSize)
        }
        return centeredOriginal(in: mainRect, size: currentSize)
    }

    /// 尊重真实尺寸的主区目标：放得下时原样居中（返回的就是原尺寸），放不下时等比收缩贴边。
    /// 这是"保持原尺寸"与"超屏才收缩"两个语义的唯一计算点，放置决策、动画端点与
    /// 验收期望都从它取值，三处永远不会对不上（方案 §9.1 修订）。
    public static func scaledDownRect(in mainRect: CGRect, currentSize: CGSize?) -> CGRect {
        guard let size = currentSize, size.width > 0, size.height > 0,
              mainRect.width > 1, mainRect.height > 1 else { return mainRect }
        if let fits = centeredOriginalRect(in: mainRect, size: size) { return fits }
        let scale = min(mainRect.width / size.width, mainRect.height / size.height)
        let scaled = CGSize(width: (size.width * scale).rounded(),
                            height: (size.height * scale).rounded())
        return CGRect(x: mainRect.midX - scaled.width / 2,
                      y: mainRect.midY - scaled.height / 2,
                      width: scaled.width,
                      height: scaled.height)
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
