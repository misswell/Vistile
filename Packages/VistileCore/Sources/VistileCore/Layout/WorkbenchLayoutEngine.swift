import Foundation
import CoreGraphics

/// 工作台的视觉与尺寸 token（方案 §5.2）。全部集中在这里，不散落到视图里。
public struct WorkbenchStyle: Hashable, Sendable {
    /// 外边距 12pt；紧凑时 8pt。
    public var margin: CGFloat
    public var compactMargin: CGFloat
    /// 区域间距 10pt（8–16 可调）。
    public var gap: CGFloat
    /// 预览卡片间距 8pt：固定，不因切换改变。
    public var cardGap: CGFloat
    /// 面板内边距：轨道内容与面板边缘之间。
    public var railPadding: CGFloat
    public var topHeightRatio: CGFloat
    public var topHeightRange: ClosedRange<CGFloat>
    public var sideWidthRatio: CGFloat
    public var sideWidthRange: ClosedRange<CGFloat>
    /// 卡片标题条 20pt。
    public var titleHeight: CGFloat
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat
    /// 统一展示比 16:10：卡片按这个比例算尺寸，内容一律 aspectFit。
    public var displayAspect: CGFloat
    public var topCardWidthRange: ClosedRange<CGFloat>
    public var sideCardHeightRange: ClosedRange<CGFloat>
    /// 分隔线命中区 6–8pt：取 8pt，居中落在区域间距里（方案 §5.2）。
    public var dividerHitWidth: CGFloat
    /// 动画 200ms。
    public var animationMS: Int
    /// 主区最低目标 800×500pt：低于它属于"主区空间不足"，要明确受限。
    public var minimumMainSize: CGSize

    public init(margin: CGFloat = 12,
                compactMargin: CGFloat = 8,
                gap: CGFloat = 10,
                cardGap: CGFloat = 8,
                railPadding: CGFloat = 6,
                topHeightRatio: CGFloat = 0.11,
                topHeightRange: ClosedRange<CGFloat> = 96...320,
                sideWidthRatio: CGFloat = 0.12,
                sideWidthRange: ClosedRange<CGFloat> = 168...480,
                titleHeight: CGFloat = 20,
                cornerRadius: CGFloat = 12,
                borderWidth: CGFloat = 1,
                displayAspect: CGFloat = 1.6,
                topCardWidthRange: ClosedRange<CGFloat> = 140...240,
                sideCardHeightRange: ClosedRange<CGFloat> = 110...180,
                dividerHitWidth: CGFloat = 8,
                animationMS: Int = 200,
                minimumMainSize: CGSize = CGSize(width: 800, height: 500)) {
        self.margin = margin
        self.compactMargin = compactMargin
        self.gap = gap
        self.cardGap = cardGap
        self.railPadding = railPadding
        self.topHeightRatio = topHeightRatio
        self.topHeightRange = topHeightRange
        self.sideWidthRatio = sideWidthRatio
        self.sideWidthRange = sideWidthRange
        self.titleHeight = titleHeight
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.displayAspect = displayAspect
        self.topCardWidthRange = topCardWidthRange
        self.sideCardHeightRange = sideCardHeightRange
        self.dividerHitWidth = dividerHitWidth
        self.animationMS = animationMS
        self.minimumMainSize = minimumMainSize
    }

    /// 减少动态效果时改用短淡化（方案 §5.2、§10.5）。
    public func animationMS(reduceMotion: Bool) -> Int {
        reduceMotion ? min(120, animationMS) : animationMS
    }

    /// 模式过渡的分级时长（方案 §10.1–§10.3）：减少动态效果统一用短淡化。
    public func entryAnimationMS(reduceMotion: Bool) -> Int { reduceMotion ? 100 : 240 }
    public func returnAnimationMS(reduceMotion: Bool) -> Int { reduceMotion ? 100 : 200 }
    public func switchAnimationMS(reduceMotion: Bool) -> Int { reduceMotion ? 80 : 180 }
    /// 分隔线/侧栏切换后的主窗口微调：不播大动画。
    public func settleAnimationMS(reduceMotion: Bool) -> Int { reduceMotion ? 0 : 160 }
}

/// 一次算清的工作台布局（方案 §5.1、§5.3）。
/// 三个矩形互不重叠；topRailRect 是独立全宽面板，sideRailRect 只覆盖它下方。
public struct WorkbenchLayout: Hashable, Sendable {
    public let displayID: UInt32
    public let visibleFrame: CGRect
    public let side: RailSide
    public let style: WorkbenchStyle
    public let margin: CGFloat
    public let mainRect: CGRect
    public let topRailRect: CGRect
    public let sideRailRect: CGRect
    /// 交汇工具区位于顶栏面板内部；不新增覆盖主区的透明窗口。
    public let cornerToolRect: CGRect
    public let topViewport: CGRect
    public let sideViewport: CGRect
    public let topCardSize: CGSize
    public let sideCardSize: CGSize
    public let topCapacity: Int
    public let sideCapacity: Int
    public let topSlotCount: Int
    /// 侧栏内容覆盖的逻辑 slot 数（≥ sideCapacity）：超出可见容量的卡片留在侧栏滚动轨道（方案 §6.2、§5.4）。
    public let sideSlotCount: Int
    public let effectiveTopHeightRange: ClosedRange<CGFloat>
    public let effectiveSideWidthRange: ClosedRange<CGFloat>
    /// 可用区连一条栏都放不下：布局退化为"只有主区"，不产生负尺寸。
    public let isDegenerate: Bool

    public var capacity: Int { topCapacity + sideCapacity }

    /// 主区面积 / 屏幕可用区面积：设置里要显示的是这个实际值，不是宽高百分比（方案 §5.3）。
    public var mainAreaRatio: Double {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return 0 }
        return Double(mainRect.width * mainRect.height / (visibleFrame.width * visibleFrame.height))
    }

    /// 主区低于 800×500 基线：属于"主区空间不足"，卡片要显示受限而不是硬塞（方案 §5.5、§11）。
    public var isMainAreaConstrained: Bool {
        mainRect.width < style.minimumMainSize.width || mainRect.height < style.minimumMainSize.height
    }

    /// 顶栏在前、侧栏在后：逻辑 slot 顺序与轨道显示顺序一致。
    public var slotOrder: [RailSlotID] {
        let top = (0..<topSlotCount).map { RailSlotID(displayID: displayID, rail: .top, ordinal: $0) }
        let side = (0..<sideSlotCount).map { RailSlotID(displayID: displayID, rail: .side, ordinal: $0) }
        return top + side
    }

    /// 内容总长度（含卡片之间的间距，末尾不留 gap）。
    public var topContentLength: CGFloat {
        guard topSlotCount > 0, !isDegenerate else { return 0 }
        return CGFloat(topSlotCount) * topCardSize.width + CGFloat(topSlotCount - 1) * style.cardGap
    }

    public var sideContentLength: CGFloat {
        guard sideSlotCount > 0, !isDegenerate else { return 0 }
        return CGFloat(sideSlotCount) * sideCardSize.height + CGFloat(sideSlotCount - 1) * style.cardGap
    }

    public var maxTopScroll: CGFloat { max(0, topContentLength - topViewport.width) }
    public var maxSideScroll: CGFloat { max(0, sideContentLength - sideViewport.height) }

    public func clampedScroll(rail: RailKind, offset: CGFloat) -> CGFloat {
        let maxOffset = rail == .top ? maxTopScroll : maxSideScroll
        return min(max(0, offset), maxOffset)
    }

    /// slot 在屏幕上的矩形（CG 全局坐标），含用户滚动偏移。
    public func rect(for slot: RailSlotID, scrollOffset: CGFloat) -> CGRect? {
        guard slot.displayID == displayID, !isDegenerate else { return nil }
        switch slot.rail {
        case .top:
            guard slot.ordinal >= 0, slot.ordinal < topSlotCount else { return nil }
            let offset = clampedScroll(rail: .top, offset: scrollOffset)
            let x = topViewport.minX + CGFloat(slot.ordinal) * (topCardSize.width + style.cardGap) - offset
            return CGRect(x: x, y: topViewport.midY - topCardSize.height / 2,
                          width: topCardSize.width, height: topCardSize.height)
        case .side:
            guard slot.ordinal >= 0, slot.ordinal < sideSlotCount else { return nil }
            let offset = clampedScroll(rail: .side, offset: scrollOffset)
            let y = sideViewport.minY + CGFloat(slot.ordinal) * (sideCardSize.height + style.cardGap) - offset
            return CGRect(x: sideViewport.midX - sideCardSize.width / 2, y: y,
                          width: sideCardSize.width, height: sideCardSize.height)
        }
    }

    /// 只有内容矩形（去掉标题条）：画面按这个区域 aspectFit。
    public func contentRect(for slot: RailSlotID, scrollOffset: CGFloat) -> CGRect? {
        guard let rect = rect(for: slot, scrollOffset: scrollOffset) else { return nil }
        let container = CGRect(x: rect.minX,
                               y: rect.minY + style.titleHeight,
                               width: rect.width,
                               height: max(0, rect.height - style.titleHeight))
        return GridLayoutEngine.aspectFitRect(sourceSize: CGSize(width: style.displayAspect, height: 1),
                                              in: container).rect
    }

    /// 该 slot 此刻是否落在 viewport 里（部分可见也算）：捕获需求按它决定优先级。
    public func isVisible(_ slot: RailSlotID, scrollOffset: CGFloat) -> Bool {
        guard let rect = rect(for: slot, scrollOffset: scrollOffset) else { return false }
        let viewport = slot.rail == .top ? topViewport : sideViewport
        let intersection = rect.intersection(viewport)
        return !intersection.isNull && intersection.width > 1 && intersection.height > 1
    }

    public func visibleSlots(topScroll: CGFloat, sideScroll: CGFloat) -> [RailSlotID] {
        slotOrder.filter { slot in
            isVisible(slot, scrollOffset: slot.rail == .top ? topScroll : sideScroll)
        }
    }

    /// 承载面板窗口的 frame（方案 §11.2）：栏本身 ∪ 它与主区之间的整条空带。
    /// 分隔线画在空带中央；窗口伸进空带但不越过 mainRect 边缘，结构上仍不可能覆盖主区。
    public var topPanelWindowRect: CGRect {
        guard !isDegenerate else { return .zero }
        let bottom = max(topRailRect.maxY, mainRect.minY)
        return CGRect(x: topRailRect.minX,
                      y: topRailRect.minY,
                      width: topRailRect.width,
                      height: bottom - topRailRect.minY)
    }

    /// 侧栏面板窗口：右栏向左、左栏向右各伸进自己的空带。
    public var sidePanelWindowRect: CGRect {
        guard !isDegenerate else { return .zero }
        switch side {
        case .right:
            let minX = min(sideRailRect.minX, mainRect.maxX)
            return CGRect(x: minX,
                          y: sideRailRect.minY,
                          width: sideRailRect.maxX - minX,
                          height: sideRailRect.height)
        case .left:
            let maxX = max(sideRailRect.maxX, mainRect.minX)
            return CGRect(x: sideRailRect.minX,
                          y: sideRailRect.minY,
                          width: maxX - sideRailRect.minX,
                          height: sideRailRect.height)
        }
    }

    /// 顶部分隔线命中带（方案 §5.2）：顶栏与主区之间的空带中央，拖动改顶栏高度。
    /// 退化布局没有可拖的带，返回 .zero。
    public var topDividerRect: CGRect {
        let band = CGRect(x: topRailRect.minX,
                          y: topRailRect.maxY,
                          width: topRailRect.width,
                          height: mainRect.minY - topRailRect.maxY)
        return dividerHitRect(in: band, horizontal: true)
    }

    /// 侧栏分隔线命中带：主区与侧栏之间的空带中央，拖动改侧栏宽度。左右栏各自镜像。
    public var sideDividerRect: CGRect {
        let band: CGRect
        switch side {
        case .right:
            band = CGRect(x: mainRect.maxX,
                          y: sideRailRect.minY,
                          width: sideRailRect.minX - mainRect.maxX,
                          height: sideRailRect.height)
        case .left:
            band = CGRect(x: sideRailRect.maxX,
                          y: sideRailRect.minY,
                          width: mainRect.minX - sideRailRect.maxX,
                          height: sideRailRect.height)
        }
        return dividerHitRect(in: band, horizontal: false)
    }

    /// 命中带取空带中央的 min(空带, dividerHitWidth)：够不到 1pt 的空带不产生命中区。
    private func dividerHitRect(in band: CGRect, horizontal: Bool) -> CGRect {
        guard !isDegenerate, band.width > 1, band.height > 1 else { return .zero }
        let thickness = min(horizontal ? band.height : band.width, style.dividerHitWidth)
        guard thickness > 1 else { return .zero }
        if horizontal {
            return CGRect(x: band.minX, y: band.midY - thickness / 2, width: band.width, height: thickness)
        }
        return CGRect(x: band.midX - thickness / 2, y: band.minY, width: thickness, height: band.height)
    }

    public func extending(sideSlots: Int) -> WorkbenchLayout {
        extending(topSlots: topSlotCount, sideSlots: sideSlots)
    }

    public func extending(topSlots: Int, sideSlots: Int) -> WorkbenchLayout {
        let topCount = max(topCapacity, topSlots)
        let sideCount = max(sideCapacity, sideSlots)
        guard topCount != topSlotCount || sideCount != sideSlotCount else { return self }
        return WorkbenchLayout(displayID: displayID,
                               visibleFrame: visibleFrame,
                               side: side,
                               style: style,
                               margin: margin,
                               mainRect: mainRect,
                               topRailRect: topRailRect,
                               sideRailRect: sideRailRect,
                               cornerToolRect: cornerToolRect,
                               topViewport: topViewport,
                               sideViewport: sideViewport,
                               topCardSize: topCardSize,
                               sideCardSize: sideCardSize,
                               topCapacity: topCapacity,
                               sideCapacity: sideCapacity,
                               topSlotCount: topCount,
                               sideSlotCount: sideCount,
                               effectiveTopHeightRange: effectiveTopHeightRange,
                               effectiveSideWidthRange: effectiveSideWidthRange,
                               isDegenerate: isDegenerate)
    }
}

/// 确定性布局计算（方案 §5.3）。设 V=visibleFrame，I=V.insetBy(dx:m,dy:m)。
public enum WorkbenchLayoutEngine {
    public static func layout(displayID: UInt32,
                              visibleFrame: CGRect,
                              side: RailSide,
                              style: WorkbenchStyle = WorkbenchStyle(),
                              compact: Bool = false,
                              topHeightOverride: CGFloat? = nil,
                              sideWidthOverride: CGFloat? = nil,
                              minimumMainSize: CGSize? = nil) -> WorkbenchLayout {
        let margin = compact ? style.compactMargin : style.margin
        let gap = max(0, style.gap)
        let inner = visibleFrame.insetBy(dx: margin, dy: margin)
        guard inner.width > gap + 1, inner.height > gap + 1 else {
            return degenerate(displayID: displayID, visibleFrame: visibleFrame, side: side,
                              style: style, margin: margin)
        }

        let minimum = minimumMainSize ?? style.minimumMainSize
        let topRange = effectiveRange(style.topHeightRange, available: inner.height - gap,
                                      minimumMainLength: minimum.height)
        let sideRange = effectiveRange(style.sideWidthRange, available: inner.width - gap,
                                       minimumMainLength: minimum.width)
        let topHeight = clamp(topHeightOverride ?? inner.height * style.topHeightRatio, topRange)
        let sideWidth = clamp(sideWidthOverride ?? inner.width * style.sideWidthRatio, sideRange)
        let bodyHeight = inner.height - topHeight - gap
        let mainWidth = inner.width - sideWidth - gap

        let topRailRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: topHeight)
        let bodyMinY = inner.minY + topHeight + gap

        let mainRect: CGRect
        let sideRailRect: CGRect
        let cornerToolRect: CGRect
        switch side {
        case .right:
            mainRect = CGRect(x: inner.minX, y: bodyMinY, width: mainWidth, height: bodyHeight)
            sideRailRect = CGRect(x: inner.maxX - sideWidth, y: bodyMinY, width: sideWidth, height: bodyHeight)
            cornerToolRect = CGRect(x: inner.maxX - sideWidth, y: inner.minY, width: sideWidth, height: topHeight)
        case .left:
            mainRect = CGRect(x: inner.minX + sideWidth + gap, y: bodyMinY, width: mainWidth, height: bodyHeight)
            sideRailRect = CGRect(x: inner.minX, y: bodyMinY, width: sideWidth, height: bodyHeight)
            cornerToolRect = CGRect(x: inner.minX, y: inner.minY, width: sideWidth, height: topHeight)
        }

        let padding = style.railPadding
        // 顶栏的卡片视口要扣掉角落工具区与内部 padding：卡片不钻到工具按钮底下。
        let topViewport: CGRect
        switch side {
        case .right:
            topViewport = CGRect(x: topRailRect.minX + padding,
                                 y: topRailRect.minY + padding,
                                 width: max(0, topRailRect.width - sideWidth - 2 * padding),
                                 height: max(0, topRailRect.height - 2 * padding))
        case .left:
            topViewport = CGRect(x: topRailRect.minX + sideWidth + padding,
                                 y: topRailRect.minY + padding,
                                 width: max(0, topRailRect.width - sideWidth - 2 * padding),
                                 height: max(0, topRailRect.height - 2 * padding))
        }
        let sideViewport = sideRailRect.insetBy(dx: padding, dy: padding)
        guard topViewport.width > 1, topViewport.height > style.titleHeight + 1,
              sideViewport.width > 1, sideViewport.height > style.titleHeight + 1,
              style.displayAspect > 0 else {
            return degenerate(displayID: displayID, visibleFrame: visibleFrame, side: side,
                              style: style, margin: margin)
        }

        let rawTopWidth = (topViewport.height - style.titleHeight) * style.displayAspect
        let topCardWidth = min(clamp(rawTopWidth, style.topCardWidthRange), topViewport.width)
        let topCardSize = CGSize(width: topCardWidth,
                                 height: min(topViewport.height, topCardWidth / style.displayAspect + style.titleHeight))

        let rawSideHeight = sideViewport.width / style.displayAspect + style.titleHeight
        let sideCardHeight = min(clamp(rawSideHeight, style.sideCardHeightRange), sideViewport.height)
        let sideCardSize = CGSize(width: sideViewport.width, height: sideCardHeight)

        let topCapacity = capacity(viewportLength: topViewport.width,
                                   cardLength: topCardSize.width,
                                   gap: style.cardGap)
        let sideCapacity = capacity(viewportLength: sideViewport.height,
                                    cardLength: sideCardSize.height,
                                    gap: style.cardGap)

        return WorkbenchLayout(displayID: displayID,
                               visibleFrame: visibleFrame,
                               side: side,
                               style: style,
                               margin: margin,
                               mainRect: mainRect,
                               topRailRect: topRailRect,
                               sideRailRect: sideRailRect,
                               cornerToolRect: cornerToolRect,
                               topViewport: topViewport,
                               sideViewport: sideViewport,
                               topCardSize: topCardSize,
                               sideCardSize: sideCardSize,
                               topCapacity: topCapacity,
                               sideCapacity: sideCapacity,
                               topSlotCount: topCapacity,
                               sideSlotCount: sideCapacity,
                               effectiveTopHeightRange: topRange,
                               effectiveSideWidthRange: sideRange,
                               isDegenerate: false)
    }

    /// 容量取 floor：最后一张卡片的可点击区域绝不越界（方案 §5.4）。
    static func capacity(viewportLength: CGFloat, cardLength: CGFloat, gap: CGFloat) -> Int {
        guard cardLength > 1, viewportLength > 1 else { return 0 }
        let count = Int(floor((viewportLength + gap) / (cardLength + gap)))
        return max(0, count)
    }

    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }

    private static func effectiveRange(_ range: ClosedRange<CGFloat>, available: CGFloat,
                                       minimumMainLength: CGFloat) -> ClosedRange<CGFloat> {
        let reserved = min(max(1, minimumMainLength), max(1, available - range.lowerBound))
        let upper = max(0, min(range.upperBound, available - reserved))
        return min(range.lowerBound, upper)...upper
    }

    private static func degenerate(displayID: UInt32,
                                   visibleFrame: CGRect,
                                   side: RailSide,
                                   style: WorkbenchStyle,
                                   margin: CGFloat) -> WorkbenchLayout {
        WorkbenchLayout(displayID: displayID,
                        visibleFrame: visibleFrame,
                        side: side,
                        style: style,
                        margin: margin,
                        mainRect: visibleFrame,
                        topRailRect: .zero,
                        sideRailRect: .zero,
                        cornerToolRect: .zero,
                        topViewport: .zero,
                        sideViewport: .zero,
                        topCardSize: .zero,
                        sideCardSize: .zero,
                        topCapacity: 0,
                        sideCapacity: 0,
                        topSlotCount: 0,
                        sideSlotCount: 0,
                        effectiveTopHeightRange: 0...0,
                        effectiveSideWidthRange: 0...0,
                        isDegenerate: true)
    }
}
