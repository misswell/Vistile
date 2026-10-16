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

    /// 紧凑路径：第 i 个源进第 i 格，位置随窗口数量变化。
    /// 总览显示期间不走这里，走 DisplayGridSnapshot（方案 §8.1）。
    public static func layout(sources: [GridSource],
                              availableRect: CGRect,
                              style: OverviewStyle = .standard,
                              weights: LayoutWeights = LayoutWeights()) -> GridLayout {
        let geometry = geometry(sourceSizes: sources.map(\.size),
                                availableRect: availableRect,
                                style: style,
                                weights: weights)
        let placements = sources.enumerated().map {
            GridPlacement(localIndex: $0.offset, slot: $0.element.slot, identity: nil, size: $0.element.size)
        }
        return layout(geometry: geometry, placements: placements)
    }

    /// 只跑一次行列优化，给出可以冻结下来的几何，空格矩形一并给出。
    public static func geometry(sourceSizes: [CGSize],
                                availableRect: CGRect,
                                style: OverviewStyle = .standard,
                                weights: LayoutWeights = LayoutWeights()) -> GridGeometry {
        let count = sourceSizes.count
        let usable = usableArea(in: availableRect, style: style)
        guard count > 0, usable.width > 1, usable.height > 1 else {
            return GridGeometry(columns: 0,
                                rows: 0,
                                cellSize: .zero,
                                usable: usable,
                                availableRect: availableRect,
                                style: style,
                                cellCount: 0,
                                emptyCells: 0,
                                score: 0,
                                areaEfficiency: 0,
                                isReadable: true)
        }

        var best: Candidate?
        for columns in 1...count {
            guard let candidate = evaluate(columns: columns,
                                           sourceSizes: sourceSizes,
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
            // 极端狭长屏（连 1 列都放不下标题条）时退化为单列，保证不越界。
            return fallbackGeometry(count: count, usable: usable, style: style, availableRect: availableRect)
        }
        return winner.geometry(usable: usable, style: style, availableRect: availableRect, count: count)
    }

    /// 由冻结几何 + 每格内容生成渲染布局：格子位置由调用方决定，这里只算矩形。
    public static func layout(geometry: GridGeometry, placements: [GridPlacement]) -> GridLayout {
        let cards: [GridCard] = placements.compactMap { placement in
            guard let cellRect = geometry.cellRect(at: placement.localIndex),
                  let contentRect = geometry.contentRect(at: placement.localIndex) else { return nil }
            let image = aspectFitRect(sourceSize: placement.size, in: contentRect)
            return GridCard(slot: placement.slot,
                            cellRect: cellRect,
                            contentRect: contentRect,
                            imageRect: image.rect,
                            scale: image.scale)
        }
        return GridLayout(columns: geometry.columns,
                          rows: geometry.rows,
                          cellSize: geometry.cellSize,
                          availableRect: geometry.availableRect,
                          cards: cards,
                          emptyCells: geometry.emptyCells,
                          score: geometry.score,
                          isReadable: geometry.isReadable,
                          areaEfficiency: geometry.areaEfficiency)
    }

    /// 判定给定窗口数在当前屏上是否仍达到可读尺寸。
    public static func isReadable(count: Int,
                                  availableRect: CGRect,
                                  sourceSizes: [CGSize],
                                  style: OverviewStyle = .standard,
                                  weights: LayoutWeights = LayoutWeights()) -> Bool {
        guard count > 0 else { return true }
        return geometry(sourceSizes: Array(sourceSizes.prefix(count)),
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

        func geometry(usable: CGRect, style: OverviewStyle, availableRect: CGRect, count: Int) -> GridGeometry {
            GridGeometry(columns: columns,
                         rows: rows,
                         cellSize: cellSize,
                         usable: usable,
                         availableRect: availableRect,
                         style: style,
                         cellCount: rows * columns,
                         emptyCells: rows * columns - count,
                         score: score,
                         areaEfficiency: areaEfficiency,
                         isReadable: isReadable)
        }
    }

    private static func evaluate(columns: Int,
                                 sourceSizes: [CGSize],
                                 usable: CGRect,
                                 style: OverviewStyle,
                                 weights: LayoutWeights) -> Candidate? {
        let count = sourceSizes.count
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let cellWidth = (usable.width - CGFloat(columns - 1) * style.gap) / CGFloat(columns)
        let cellHeight = (usable.height - CGFloat(rows - 1) * style.gap) / CGFloat(rows)
        guard cellWidth > 1, cellHeight - style.titleHeight > 1 else { return nil }

        let cellSize = CGSize(width: cellWidth, height: cellHeight)
        let contentHeight = cellHeight - style.titleHeight
        var previewArea: CGFloat = 0
        for size in sourceSizes {
            let scale = min(cellWidth / max(size.width, 1), contentHeight / max(size.height, 1))
            previewArea += (size.width * scale) * (size.height * scale)
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

    private static func fallbackGeometry(count: Int,
                                         usable: CGRect,
                                         style: OverviewStyle,
                                         availableRect: CGRect) -> GridGeometry {
        let rows = count
        let cellHeight = max(1, (usable.height - CGFloat(max(0, rows - 1)) * style.gap) / CGFloat(max(rows, 1)))
        return GridGeometry(columns: 1,
                            rows: rows,
                            cellSize: CGSize(width: usable.width, height: cellHeight),
                            usable: usable,
                            availableRect: availableRect,
                            style: style,
                            cellCount: rows,
                            emptyCells: 0,
                            score: 0,
                            areaEfficiency: 0,
                            isReadable: false)
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
