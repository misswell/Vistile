import Foundation
import CoreGraphics

/// 一次冻结的工作台布局投影（方案 §15）：几何 + 两条栏各自的滚动偏移。
/// 滚动只改变 viewport 显示偏移，不改变任何逻辑 slot；命中与捕获需求都按这份投影算。
public struct WorkbenchLayoutSnapshot: Hashable, Sendable {
    public let displayID: UInt32
    public let layout: WorkbenchLayout
    public let topScrollOffset: CGFloat
    public let sideScrollOffset: CGFloat
    public let revision: Int

    public init(displayID: UInt32,
                layout: WorkbenchLayout,
                topScrollOffset: CGFloat,
                sideScrollOffset: CGFloat,
                revision: Int) {
        self.displayID = displayID
        self.layout = layout
        self.topScrollOffset = layout.clampedScroll(rail: .top, offset: topScrollOffset)
        self.sideScrollOffset = layout.clampedScroll(rail: .side, offset: sideScrollOffset)
        self.revision = revision
    }

    public var side: RailSide { layout.side }
    public var mainRect: CGRect { layout.mainRect }
    public var isDegenerate: Bool { layout.isDegenerate }
    public var isMainAreaConstrained: Bool { layout.isMainAreaConstrained }

    public func scrollOffset(rail: RailKind) -> CGFloat {
        rail == .top ? topScrollOffset : sideScrollOffset
    }

    public func clampedScroll(rail: RailKind, offset: CGFloat) -> CGFloat {
        layout.clampedScroll(rail: rail, offset: offset)
    }

    public func rect(for slot: RailSlotID) -> CGRect? {
        layout.rect(for: slot, scrollOffset: scrollOffset(rail: slot.rail))
    }

    public func contentRect(for slot: RailSlotID) -> CGRect? {
        layout.contentRect(for: slot, scrollOffset: scrollOffset(rail: slot.rail))
    }

    public func isVisible(_ slot: RailSlotID) -> Bool {
        layout.isVisible(slot, scrollOffset: scrollOffset(rail: slot.rail))
    }

    public var visibleSlots: [RailSlotID] {
        layout.visibleSlots(topScroll: topScrollOffset, sideScroll: sideScrollOffset)
    }

    /// 只改滚动偏移的新投影：revision 不变，几何是同一份。
    public func scrolling(rail: RailKind, to offset: CGFloat) -> WorkbenchLayoutSnapshot {
        WorkbenchLayoutSnapshot(displayID: displayID,
                                layout: layout,
                                topScrollOffset: rail == .top ? offset : topScrollOffset,
                                sideScrollOffset: rail == .side ? offset : sideScrollOffset,
                                revision: revision)
    }

    /// 重新计算几何后的新投影（侧栏切换、分隔线收敛、显示器变化都用它）。
    public func replacing(layout newLayout: WorkbenchLayout, revision newRevision: Int) -> WorkbenchLayoutSnapshot {
        WorkbenchLayoutSnapshot(displayID: newLayout.displayID,
                                layout: newLayout.extending(topSlots: max(layout.topSlotCount, newLayout.topSlotCount),
                                                            sideSlots: max(layout.sideSlotCount, newLayout.sideSlotCount)),
                                topScrollOffset: topScrollOffset,
                                sideScrollOffset: sideScrollOffset,
                                revision: newRevision)
    }
}
