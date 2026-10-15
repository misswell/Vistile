import Foundation
import CoreGraphics

public struct SlotID: Hashable, Sendable, Comparable, Codable {
    public let index: Int
    public init(index: Int) { self.index = index }
    public static func < (lhs: SlotID, rhs: SlotID) -> Bool { lhs.index < rhs.index }
}

public enum LayoutDensity: String, Sendable, CaseIterable {
    case standard
    case compact
}

/// 总览样式参数（方案 §8.1，单位 pt）。
public struct OverviewStyle: Hashable, Sendable {
    public var margin: CGFloat
    public var gap: CGFloat
    public var titleHeight: CGFloat
    public var toolbarHeight: CGFloat
    public var cornerRadius: CGFloat
    public var expandAnimationMS: Int
    public var collapseAnimationMS: Int

    public init(margin: CGFloat,
                gap: CGFloat,
                titleHeight: CGFloat = 24,
                toolbarHeight: CGFloat = 32,
                cornerRadius: CGFloat = 10,
                expandAnimationMS: Int = 240,
                collapseAnimationMS: Int = 220) {
        self.margin = margin
        self.gap = gap
        self.titleHeight = titleHeight
        self.toolbarHeight = toolbarHeight
        self.cornerRadius = cornerRadius
        self.expandAnimationMS = expandAnimationMS
        self.collapseAnimationMS = collapseAnimationMS
    }

    public static let standard = OverviewStyle(margin: 20, gap: 14)
    public static let compact = OverviewStyle(margin: 12, gap: 10)

    public static func style(_ density: LayoutDensity) -> OverviewStyle {
        switch density {
        case .standard: return .standard
        case .compact: return .compact
        }
    }

    /// 展开动画允许 160–300ms。
    public var clampedExpandMS: Int { min(300, max(160, expandAnimationMS)) }
    public var clampedCollapseMS: Int { min(300, max(160, collapseAnimationMS)) }
}

/// 归一化后的评分权重，集中定义并用固定样例校准（方案 §8.2）。
public struct LayoutWeights: Hashable, Sendable {
    public var previewArea: Double
    public var emptyCellPenalty: Double
    public var extremeAspectPenalty: Double
    public var minSidePenalty: Double
    /// 短边低于该值认为缩略图过小，需要提示。
    public var minReadableShortSide: CGFloat
    public var targetCellAspect: Double

    public init(previewArea: Double = 1.0,
                emptyCellPenalty: Double = 0.35,
                extremeAspectPenalty: Double = 0.20,
                minSidePenalty: Double = 0.60,
                minReadableShortSide: CGFloat = 90,
                targetCellAspect: Double = 1.6) {
        self.previewArea = previewArea
        self.emptyCellPenalty = emptyCellPenalty
        self.extremeAspectPenalty = extremeAspectPenalty
        self.minSidePenalty = minSidePenalty
        self.minReadableShortSide = minReadableShortSide
        self.targetCellAspect = targetCellAspect
    }
}

public struct GridCard: Hashable, Sendable {
    public let slot: SlotID
    /// 卡片外框（含标题条），CG 全局坐标。
    public let cellRect: CGRect
    /// 去掉标题条后的预览区。
    public let contentRect: CGRect
    /// aspectFit 后的画面矩形：等比例、不裁切、不拉伸。
    public let imageRect: CGRect
    public let scale: Double
}

public struct GridLayout: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cellSize: CGSize
    public let availableRect: CGRect
    public let cards: [GridCard]
    public let emptyCells: Int
    public let score: Double
    public let isReadable: Bool
    /// 预览总面积 / 可用总面积。
    public let areaEfficiency: Double

    public func card(at slot: SlotID) -> GridCard? {
        cards.first { $0.slot == slot }
    }
}

/// 一个待排布的窗口：全局 slot 与源尺寸。
/// 多屏时每屏只传自己那部分窗口，但卡片仍携带全局 slot，
/// 这样键盘选择与拖动交换不会因为分屏而改变编号含义。
public struct GridSource: Hashable, Sendable {
    public let slot: SlotID
    public let size: CGSize

    public init(slot: SlotID, size: CGSize) {
        self.slot = slot
        self.size = size
    }
}

/// 均匀密集格子 + 严格 aspectFit 的布局计算。
public enum GridLayoutEngine {
    public static func layout(sourceSizes: [CGSize],
                              availableRect: CGRect,
                              style: OverviewStyle = .standard,
                              weights: LayoutWeights = LayoutWeights()) -> GridLayout {
        layout(sources: sourceSizes.enumerated().map { GridSource(slot: SlotID(index: $0.offset), size: $0.element) },
               availableRect: availableRect,
               style: style,
               weights: weights)
    }

    public static func layout(sources: [GridSource],
                              availableRect: CGRect,
                              style: OverviewStyle = .standard,
                              weights: LayoutWeights = LayoutWeights()) -> GridLayout {
        let count = sources.count
        let usable = usableArea(in: availableRect, style: style)
        guard count > 0, usable.width > 1, usable.height > 1 else {
            return GridLayout(columns: 0, rows: 0, cellSize: .zero, availableRect: availableRect,
                              cards: [], emptyCells: 0, score: 0, isReadable: true, areaEfficiency: 0)
        }

        var best: Candidate?
        for columns in 1...count {
            guard let candidate = evaluate(columns: columns,
                                           sources: sources,
                                           usable: usable,
                                           style: style,
                                           weights: weights) else { continue }
            if let current = best {
                if isBetter(candidate, than: current, weights: weights) { best = candidate }
            } else {
                best = candidate
            }
        }

        guard let winner = best else {
            // 极端狭长屏（连 1 列都放不下标题条）时退化为单列可缩放布局，保证不越界。
            return fallbackLayout(sources: sources, usable: usable, style: style, availableRect: availableRect)
        }
        return winner.layout(sources: sources, usable: usable, style: style, availableRect: availableRect)
    }

    /// 判定给定窗口数在当前屏上是否仍达到可读尺寸。
    public static func isReadable(count: Int,
                                  availableRect: CGRect,
                                  sourceSizes: [CGSize],
                                  style: OverviewStyle = .standard,
                                  weights: LayoutWeights = LayoutWeights()) -> Bool {
        guard count > 0 else { return true }
        return layout(sourceSizes: Array(sourceSizes.prefix(count)),
                      availableRect: availableRect,
                      style: style,
                      weights: weights).isReadable
    }

    private struct Candidate {
        let columns: Int
        let rows: Int
        let cellSize: CGSize
        let score: Double
        let emptyCells: Int
        let areaEfficiency: Double
        let isReadable: Bool

        func layout(sources: [GridSource], usable: CGRect, style: OverviewStyle, availableRect: CGRect) -> GridLayout {
            var cards: [GridCard] = []
            cards.reserveCapacity(sources.count)
            for (i, source) in sources.enumerated() {
                let row = i / columns
                let column = i % columns
                let cellRect = CGRect(x: usable.minX + CGFloat(column) * (cellSize.width + style.gap),
                                      y: usable.minY + CGFloat(row) * (cellSize.height + style.gap),
                                      width: cellSize.width,
                                      height: cellSize.height)
                let contentHeight = max(0, cellRect.height - style.titleHeight)
                let contentRect = CGRect(x: cellRect.minX, y: cellRect.minY + style.titleHeight,
                                         width: cellRect.width, height: contentHeight)
                let image = aspectFitRect(sourceSize: source.size, in: contentRect)
                cards.append(GridCard(slot: source.slot, cellRect: cellRect, contentRect: contentRect,
                                      imageRect: image.rect, scale: image.scale))
            }
            return GridLayout(columns: columns,
                              rows: rows,
                              cellSize: cellSize,
                              availableRect: availableRect,
                              cards: cards,
                              emptyCells: emptyCells,
                              score: score,
                              isReadable: isReadable,
                              areaEfficiency: areaEfficiency)
        }
    }

    private static func evaluate(columns: Int,
                                 sources: [GridSource],
                                 usable: CGRect,
                                 style: OverviewStyle,
                                 weights: LayoutWeights) -> Candidate? {
        let count = sources.count
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let cellWidth = (usable.width - CGFloat(columns - 1) * style.gap) / CGFloat(columns)
        let cellHeight = (usable.height - CGFloat(rows - 1) * style.gap) / CGFloat(rows)
        guard cellWidth > 1, cellHeight - style.titleHeight > 1 else { return nil }

        let cellSize = CGSize(width: cellWidth, height: cellHeight)
        let contentHeight = cellHeight - style.titleHeight
        var previewArea: CGFloat = 0
        for source in sources {
            let scale = min(cellWidth / max(source.size.width, 1), contentHeight / max(source.size.height, 1))
            previewArea += (source.size.width * scale) * (source.size.height * scale)
        }
        let availableArea = usable.width * usable.height
        guard availableArea > 0 else { return nil }
        let areaEfficiency = Double(previewArea / availableArea)

        let emptyCells = rows * columns - count
        let emptyRatio = rows * columns > 0 ? Double(emptyCells) / Double(rows * columns) : 0

        let cellAspect = Double(cellWidth / max(contentHeight, 1))
        let aspectDeviation = abs(log(cellAspect / max(weights.targetCellAspect, 0.0001)))
        let aspectPenalty = min(1, aspectDeviation / 1.6)

        let shortSide = min(cellWidth, contentHeight)
        let shortfall = shortSide < weights.minReadableShortSide
            ? Double((weights.minReadableShortSide - shortSide) / weights.minReadableShortSide)
            : 0

        // 四项都是 0...1 的归一量，权重可相加。
        let score = weights.previewArea * min(1, areaEfficiency)
            - weights.emptyCellPenalty * emptyRatio
            - weights.extremeAspectPenalty * aspectPenalty
            - weights.minSidePenalty * min(1, shortfall)

        return Candidate(columns: columns, rows: rows, cellSize: cellSize, score: score,
                         emptyCells: emptyCells, areaEfficiency: areaEfficiency,
                         isReadable: shortSide >= weights.minReadableShortSide)
    }

    /// 分数相同按"较少空格、较少列"决胜，保证结果可重复。
    private static func isBetter(_ lhs: Candidate, than rhs: Candidate, weights: LayoutWeights) -> Bool {
        if abs(lhs.score - rhs.score) > 0.0000001 { return lhs.score > rhs.score }
        if lhs.emptyCells != rhs.emptyCells { return lhs.emptyCells < rhs.emptyCells }
        return lhs.columns < rhs.columns
    }

    private static func fallbackLayout(sources: [GridSource], usable: CGRect, style: OverviewStyle, availableRect: CGRect) -> GridLayout {
        let rows = sources.count
        let cellHeight = max(1, (usable.height - CGFloat(max(0, rows - 1)) * style.gap) / CGFloat(max(rows, 1)))
        var cards: [GridCard] = []
        for (i, source) in sources.enumerated() {
            let cellRect = CGRect(x: usable.minX, y: usable.minY + CGFloat(i) * (cellHeight + style.gap),
                                  width: usable.width, height: cellHeight)
            let contentRect = CGRect(x: cellRect.minX, y: cellRect.minY + min(style.titleHeight, cellRect.height),
                                     width: cellRect.width, height: max(0, cellRect.height - style.titleHeight))
            let image = aspectFitRect(sourceSize: source.size, in: contentRect)
            cards.append(GridCard(slot: source.slot, cellRect: cellRect, contentRect: contentRect,
                                  imageRect: image.rect, scale: image.scale))
        }
        return GridLayout(columns: 1, rows: rows, cellSize: CGSize(width: usable.width, height: cellHeight),
                          availableRect: availableRect, cards: cards, emptyCells: 0, score: 0,
                          isReadable: false, areaEfficiency: 0)
    }

    private static func usableArea(in rect: CGRect, style: OverviewStyle) -> CGRect {
        CGRect(x: rect.minX + style.margin,
               y: rect.minY + style.margin + style.toolbarHeight,
               width: max(0, rect.width - 2 * style.margin),
               height: max(0, rect.height - 2 * style.margin - style.toolbarHeight))
    }

    /// 严格等比例，宽高比不同一定留白，底色填补，绝不裁切内容。
    public static func aspectFitRect(sourceSize: CGSize, in container: CGRect) -> (rect: CGRect, scale: Double) {
        guard sourceSize.width > 0, sourceSize.height > 0, container.width > 0, container.height > 0 else {
            return (CGRectZero, 0)
        }
        let scale = min(Double(container.width / sourceSize.width), Double(container.height / sourceSize.height))
        let width = CGFloat(sourceSize.width * scale)
        let height = CGFloat(sourceSize.height * scale)
        let rect = CGRect(x: container.minX + (container.width - width) / 2,
                          y: container.minY + (container.height - height) / 2,
                          width: width, height: height)
        return (rect, scale)
    }
}
