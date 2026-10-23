import Foundation
import CoreGraphics

/// 一条轨道卡片：slot（逻辑位置）+ 窗口事实。宿主只按它绘制，不自行推断占用关系。
public struct WorkbenchCard: Hashable, Sendable {
    public let slot: RailSlotID
    public let record: WindowRecord
    /// 此刻是否落在 viewport 里（部分可见也算）：决定捕获优先级与"可见 n/共 m"。
    public let isVisible: Bool
    /// 该窗口所属应用是否被用户"固定在顶部"（方案 §6.2）：宿主据此画标记，不改位置。
    public let isPinned: Bool
    public let isCurrent: Bool

    public init(slot: RailSlotID, record: WindowRecord, isVisible: Bool, isPinned: Bool = false, isCurrent: Bool = false) {
        self.slot = slot
        self.record = record
        self.isVisible = isVisible
        self.isPinned = isPinned
        self.isCurrent = isCurrent
    }

    public var identity: WindowIdentity { record.identity }
}

/// 宿主渲染工作台所需的最小事实集合（方案 §15.1）：
/// 两栏卡片、主窗口、空位与真实计数，全部由一次投影生成，宿主不直接读 SessionState。
public struct WorkbenchPresentation: Hashable, Sendable {
    public let displayID: UInt32
    public let snapshot: WorkbenchLayoutSnapshot
    public let side: RailSide
    public let mainIdentity: WindowIdentity?
    public let mainRecord: WindowRecord?
    public let topCards: [WorkbenchCard]
    public let sideCards: [WorkbenchCard]
    /// 可见范围内没有占用的 slot：轻量显示"空位"，不残留已关闭窗口的标题（方案 §6.2）。
    public let emptySlots: [RailSlotID]
    /// "当前可见 n / 共 m"（方案 §5.5.5）。
    public let visibleCount: Int
    public let totalCount: Int
    public let isMainAreaConstrained: Bool

    public init(displayID: UInt32,
                snapshot: WorkbenchLayoutSnapshot,
                side: RailSide,
                mainIdentity: WindowIdentity?,
                mainRecord: WindowRecord?,
                topCards: [WorkbenchCard],
                sideCards: [WorkbenchCard],
                emptySlots: [RailSlotID],
                visibleCount: Int,
                totalCount: Int,
                isMainAreaConstrained: Bool) {
        self.displayID = displayID
        self.snapshot = snapshot
        self.side = side
        self.mainIdentity = mainIdentity
        self.mainRecord = mainRecord
        self.topCards = topCards
        self.sideCards = sideCards
        self.emptySlots = emptySlots
        self.visibleCount = visibleCount
        self.totalCount = totalCount
        self.isMainAreaConstrained = isMainAreaConstrained
    }

    public var cards: [WorkbenchCard] { topCards + sideCards }

    public func card(for identity: WindowIdentity) -> WorkbenchCard? {
        cards.first { $0.identity == identity }
    }
}

public enum WorkbenchPresenter {
    /// 由几何投影 + 占用关系生成宿主用的展示事实。
    public static func make(state: SessionState,
                            snapshot: WorkbenchLayoutSnapshot,
                            placement: WorkbenchPlacement) -> WorkbenchPresentation {
        var top: [WorkbenchCard] = []
        var side: [WorkbenchCard] = []
        for (slot, identity) in placement.occupants.sorted(by: { $0.key < $1.key }) {
            guard let record = state.records[identity] else { continue }
            let card = WorkbenchCard(slot: slot,
                                     record: record,
                                     isVisible: snapshot.isVisible(slot),
                                     isPinned: placement.pinned.contains(record.preferenceKey),
                                     isCurrent: identity == placement.main)
            switch slot.rail {
            case .top: top.append(card)
            case .side: side.append(card)
            }
        }
        let occupied = Set(placement.occupants.keys)
        let empty = snapshot.layout.slotOrder.filter { !occupied.contains($0) }
        let mainIdentity = placement.main
        let mainRecord = mainIdentity.flatMap { state.records[$0] }
        var visible = Set((top + side).filter(\.isVisible).map(\.identity))
        if let mainIdentity, mainRecord != nil { visible.insert(mainIdentity) }
        return WorkbenchPresentation(displayID: snapshot.displayID,
                                     snapshot: snapshot,
                                     side: snapshot.layout.side,
                                     mainIdentity: mainIdentity,
                                     mainRecord: mainRecord,
                                     topCards: top,
                                     sideCards: side,
                                     emptySlots: empty,
                                     visibleCount: visible.count,
                                     totalCount: placement.memberCount,
                                     isMainAreaConstrained: snapshot.layout.isMainAreaConstrained)
    }
}
