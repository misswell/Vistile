import CoreGraphics
import Foundation

/// 一次行列优化的冻结结果（方案 §8.1）。
/// 格子矩形全部由这里算出：一旦确定，后续只换格子里的窗口，不换位置。
public struct GridGeometry: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public let cellSize: CGSize
    /// 去掉边距与工具条后的可用区，格子矩形相对它计算。
    public let usable: CGRect
    public let availableRect: CGRect
    public let style: OverviewStyle
    /// 含空格在内的格子总数。
    public let cellCount: Int
    public let emptyCells: Int
    public let score: Double
    public let areaEfficiency: Double
    public let isReadable: Bool

    /// localCellIndex 从每屏自己的 0 开始逐行排列。
    /// 全局 SlotID 稀疏（副屏可能是 slot 7~13），绝不能用 slot.index 反推行列。
    public func cellRect(at index: Int) -> CGRect? {
        guard columns > 0, index >= 0, index < cellCount else { return nil }
        let row = index / columns
        let column = index % columns
        return CGRect(x: usable.minX + CGFloat(column) * (cellSize.width + style.gap),
                      y: usable.minY + CGFloat(row) * (cellSize.height + style.gap),
                      width: cellSize.width,
                      height: cellSize.height)
    }

    public func contentRect(at index: Int) -> CGRect? {
        guard let cell = cellRect(at: index) else { return nil }
        return CGRect(x: cell.minX,
                      y: cell.minY + style.titleHeight,
                      width: cell.width,
                      height: max(0, cell.height - style.titleHeight))
    }
}

/// 一个格子的占用关系：位置与全局 slot 固定，只有窗口内容会变。
/// slot 是"这一格"的编号，不是窗口的编号：空格也必须带着自己的 slot，
/// 否则多屏时"注册表的第一个空位"和"网格的第一个空格"会各指一处。
public struct GridCell: Hashable, Sendable {
    public let localIndex: Int
    public let slot: SlotID?
    public var identity: WindowIdentity?

    public var isEmpty: Bool { identity == nil }
}

/// 放进网格的一个窗口：全局 slot + 身份 + 源尺寸。
public struct GridPlacement: Hashable, Sendable {
    public let localIndex: Int
    public let slot: SlotID
    public let identity: WindowIdentity?
    public let size: CGSize
}

/// 一屏的冻结网格（方案 §8.1、§8.2）。
/// 只有初次打开、用户整理、密度变化、显示器配置变化才会重建；
/// 聚焦/收回/resize/标题/捕获状态/关闭/新窗口都不移动任何格子。
public struct DisplayGridSnapshot: Hashable, Sendable {
    public let displayID: UInt32
    public let layoutRevision: Int
    public let visibleFrame: CGRect
    public let style: OverviewStyle
    public let geometry: GridGeometry
    /// 这一屏第一个格子对应的全局 slot：副屏的本地 0 号格可能是全局 7 号。
    public let startingSlot: Int
    public private(set) var cells: [GridCell]

    public var columns: Int { geometry.columns }
    public var rows: Int { geometry.rows }
    public var isReadable: Bool { geometry.isReadable }
    /// 格子总数就是这一屏能展示的窗口数。
    public var capacity: Int { cells.count }
    public var vacancyCount: Int { cells.filter(\.isEmpty).count }
    public var occupiedCount: Int { cells.count - vacancyCount }
    /// 新窗口只能进这一屏自己的第一个空格。
    public var firstVacantSlot: SlotID? { cells.first(where: \.isEmpty)?.slot }

    /// 按 placements 顺序入格，并用原算法决定行列（只在重建布局时调用）。
    public init(displayID: UInt32,
                layoutRevision: Int,
                visibleFrame: CGRect,
                style: OverviewStyle,
                placements: [GridPlacement],
                startingSlot: Int = 0,
                weights: LayoutWeights = LayoutWeights()) {
        let geometry = GridLayoutEngine.geometry(sourceSizes: placements.map(\.size),
                                                 availableRect: visibleFrame,
                                                 style: style,
                                                 weights: weights)
        self.displayID = displayID
        self.layoutRevision = layoutRevision
        self.visibleFrame = visibleFrame
        self.style = style
        self.geometry = geometry
        self.startingSlot = startingSlot
        // 每个位置都有全局 slot：容量 = 格子数，registry 与网格从此一一对应。
        var cells = (0..<geometry.cellCount).map {
            GridCell(localIndex: $0, slot: SlotID(index: startingSlot + $0))
        }
        for placement in placements where placement.localIndex >= 0 && placement.localIndex < cells.count {
            cells[placement.localIndex] = GridCell(localIndex: placement.localIndex,
                                                   slot: SlotID(index: startingSlot + placement.localIndex),
                                                   identity: placement.identity)
        }
        self.cells = cells
    }


    // MARK: - 查询

    public func cellRect(at localIndex: Int) -> CGRect? { geometry.cellRect(at: localIndex) }
    public func contentRect(at localIndex: Int) -> CGRect? { geometry.contentRect(at: localIndex) }

    public func cell(for identity: WindowIdentity) -> GridCell? {
        cells.first { $0.identity == identity }
    }

    public func localCellIndex(of slot: SlotID) -> Int? {
        cells.first { $0.slot == slot }?.localIndex
    }

    public func identity(atLocalIndex localIndex: Int) -> WindowIdentity? {
        guard localIndex >= 0, localIndex < cells.count else { return nil }
        return cells[localIndex].identity
    }

    public func slot(for identity: WindowIdentity) -> SlotID? { cell(for: identity)?.slot }

    public func rect(of identity: WindowIdentity) -> CGRect? {
        cell(for: identity).flatMap { geometry.cellRect(at: $0.localIndex) }
    }

    public var occupiedIdentities: [WindowIdentity] {
        cells.compactMap(\.identity)
    }

    // MARK: - 变更（都不移动任何格子）

    /// 窗口进入指定格子：只有该格确实为空才成功（方案 §8.2）。
    /// slot 由调用方从 `firstVacantSlot` 取得，保证与登记表指向同一位置。
    @discardableResult
    public mutating func bind(slot: SlotID, identity: WindowIdentity) -> Bool {
        guard let index = cells.firstIndex(where: { $0.isEmpty && $0.slot == slot }) else { return false }
        cells[index] = GridCell(localIndex: index, slot: slot, identity: identity)
        return true
    }

    /// 窗口关闭：原格变空但保留自己的 slot，其余格子一律不动。
    @discardableResult
    public mutating func unbind(_ identity: WindowIdentity) -> Bool {
        guard let index = cells.firstIndex(where: { $0.identity == identity }) else { return false }
        cells[index] = GridCell(localIndex: index, slot: cells[index].slot)
        return true
    }

    /// 拖动交换：交换的是格子里的窗口，位置、矩形和每格自己的 slot 都留在原地。
    public mutating func swapCells(_ lhs: Int, _ rhs: Int) {
        guard lhs >= 0, rhs >= 0, lhs < cells.count, rhs < cells.count, lhs != rhs else { return }
        let leftIdentity = cells[lhs].identity
        cells[lhs] = GridCell(localIndex: lhs, slot: cells[lhs].slot, identity: cells[rhs].identity)
        cells[rhs] = GridCell(localIndex: rhs, slot: cells[rhs].slot, identity: leftIdentity)
    }

    // MARK: - 渲染

    /// 生成渲染层用的布局：cellRect 全部来自冻结几何，只有 imageRect 随源尺寸重算。
    public func layout(for sizes: [WindowIdentity: CGSize]) -> GridLayout {
        let placements: [GridPlacement] = cells.compactMap { cell in
            guard let slot = cell.slot, let identity = cell.identity else { return nil }
            let size = sizes[identity] ?? contentRect(at: cell.localIndex)?.size ?? .zero
            return GridPlacement(localIndex: cell.localIndex, slot: slot, identity: identity, size: size)
        }
        return GridLayoutEngine.layout(geometry: geometry, placements: placements)
    }
}
