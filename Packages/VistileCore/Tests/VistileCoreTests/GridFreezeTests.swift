import Testing
import Foundation
import CoreGraphics
@testable import VistileCore

/// 方案 §8.4、§9：格子矩形只在"初次打开 / 整理 / 密度变化 / 显示器配置变化"后改变。
/// 断言全部落在布局层（cellRect 与所在格子），不是只比较 SlotID——SlotID 不变但格子跑了同样是缺陷。
@Suite("固定网格")
struct GridFreezeTests {
    // MARK: - 夹具

    private func dualDisplays() -> [DisplayInfo] {
        [DisplayInfo(id: 1,
                     frame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                     visibleFrame: CGRect(x: 0, y: 64, width: 1_440, height: 836),
                     backingScale: 2,
                     isPrimary: true),
         DisplayInfo(id: 2,
                     frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080),
                     visibleFrame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_026),
                     backingScale: 1,
                     isPrimary: false)]
    }

    private func open(_ displays: [DisplayInfo], _ list: [WindowRecord]) -> (SessionState, DiscoveryRequest) {
        var state = SessionState()
        state.displays = displays
        _ = Fixtures.dispatch(&state, .globalShortcut)
        let effects = Fixtures.dispatch(&state, .openConditionsChanged(conditions: Fixtures.granted, reopenIfReady: true))
        guard let request = Fixtures.discoverRequest(effects) else {
            Issue.record("打开流程没有产生发现请求")
            return (state, DiscoveryRequest(sessionID: state.sessionID, requestID: 0, generation: 0, reason: .shortcut))
        }
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request, records: list))
        #expect(state.phase == .overview)
        return (state, request)
    }

    /// 走一次真实的"重查目录 → 目录返回"，与宿主 reconcile 定时器同一条路径。
    private func refresh(_ state: inout SessionState, _ list: [WindowRecord]) {
        let effects = Fixtures.dispatch(&state, .reconcileTick)
        guard let request = Fixtures.discoverRequest(effects) else {
            Issue.record("重查没有产生发现请求")
            return
        }
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request, records: list))
    }

    private func cellRects(_ state: SessionState) -> [WindowIdentity: CGRect] {
        var result: [WindowIdentity: CGRect] = [:]
        for identity in state.records.keys {
            guard let rect = state.cellRect(for: identity) else {
                Issue.record("\(identity.windowID) 没有格子矩形")
                continue
            }
            result[identity] = rect
        }
        return result
    }

    private func extraRecords(_ count: Int, startingAt tag: Int, displayID: UInt32 = 1) -> [WindowRecord] {
        (0..<count).map { index in
            let record = Fixtures.record(900, UInt32(7_000 + tag * 100 + index),
                                         frame: CGRect(x: 100, y: 100, width: 1_200, height: 750),
                                         title: "新增 \(tag)-\(index)",
                                         app: "Added\(tag)")
            var mutable = record
            mutable.displayID = displayID
            return mutable
        }
    }

    private func collapseToken(_ effects: [SessionEffect]) -> TransitionToken? {
        for effect in effects {
            if case let .collapse(_, token, _) = effect { return token }
        }
        return nil
    }

    // MARK: - §8.4 主用例：现存窗口格子矩形完全一致

    @Test("展开收回、resize、改标题、关闭、新增、筛选都不移动已有格子")
    func gridIsFrozenAcrossEveryOtherEvent() {
        var (state, _) = open(Fixtures.displays, Fixtures.records(5))
        let baseline = cellRects(state)
        let baselineRevision = state.layoutRevision
        #expect(baseline.count == 5)
        let all = state.recordsInSlotOrder
        let a = all[0].identity
        let resizeTarget = all[1].identity
        let closing = all[2].identity

        // A 展开/收回 100 次。
        for _ in 0..<100 {
            let effects = Fixtures.dispatch(&state, .cardClicked(a))
            _ = Fixtures.dispatch(&state, .expandCompleted(Fixtures.expandToken(effects) ?? TransitionToken(generation: 0)))
            let collapse = Fixtures.dispatch(&state, .backgroundClicked(interaction: InteractionToken()))
            _ = Fixtures.dispatch(&state, .collapseCompleted(collapseToken(collapse) ?? TransitionToken(generation: 0)))
        }
        #expect(state.phase == .overview)
        #expect(cellRects(state) == baseline)
        #expect(state.layoutRevision == baselineRevision)

        // A resize（外部几何变化）。
        _ = Fixtures.dispatch(&state, .windowGeometryChangedExternally(resizeTarget,
                                                                      CGRect(x: 60, y: 40, width: 700, height: 480),
                                                                      source: .user))
        #expect(cellRects(state) == baseline)

        // 标题更新：同一批身份，只换标题。
        var renamed = state.records.values.map { record -> WindowRecord in
            var item = record
            item.title = "改名 " + record.title
            return item
        }
        renamed.sort { $0.identity.windowID < $1.identity.windowID }
        refresh(&state, renamed)
        #expect(cellRects(state) == baseline)
        #expect(state.records[resizeTarget]?.title.hasPrefix("改名") == true)

        // 关闭中间一个：原格变空，其余格子不动。
        _ = Fixtures.dispatch(&state, .windowClosed(closing))
        let afterClose = cellRects(state)
        for identity in afterClose.keys where identity != closing {
            #expect(afterClose[identity] == baseline[identity])
        }
        #expect(state.records[closing] == nil)

        // 添加新窗口：它只能进空格，不能将任何已有格子挤走。
        let added = extraRecords(1, startingAt: 0)
        var withAdded = Array(state.records.values)
        withAdded.append(added[0])
        refresh(&state, withAdded)
        let afterAdd = cellRects(state)
        for identity in baseline.keys where afterAdd[identity] != nil {
            #expect(afterAdd[identity] == baseline[identity])
        }
        #expect(state.grids.values.allSatisfy { $0.layoutRevision == baselineRevision })

        // 筛选后清空：展示集合变化，占用与矩形完全还原。
        let slotsBeforeFilter = state.slots.slots
        _ = Fixtures.dispatch(&state, .searchChanged("新增"))
        #expect(state.slots.slots == slotsBeforeFilter)
        _ = Fixtures.dispatch(&state, .searchChanged(""))
        #expect(state.slots.slots == slotsBeforeFilter)
        #expect(cellRects(state) == afterAdd)
        #expect(state.layoutRevision == baselineRevision)
    }

    // MARK: - §8.4 单屏与双屏稀疏全局 slot

    @Test("单屏 slot 连续且每屏本地序号从 0 开始")
    func singleDisplaySlotsAreContiguous() {
        let (state, _) = open(Fixtures.displays, Fixtures.records(4))
        let grid = state.grids[1]
        #expect(grid != nil)
        let used = grid?.occupiedIdentities.count ?? 0
        let indices = (grid?.occupiedIdentities ?? []).compactMap { grid?.slot(for: $0)?.index }
        #expect(indices.sorted() == Array(0..<used))
        #expect(state.slots.capacity == state.gridCapacity)
        for identity in grid?.occupiedIdentities ?? [] {
            let slot = grid?.slot(for: identity)
            let local = slot.flatMap { grid?.localCellIndex(of: $0) }
            #expect(grid?.rect(of: identity) == local.flatMap { grid?.cellRect(at: $0) })
        }
    }

    @Test("双屏使用稀疏全局 slot：行列为每屏本地序号且矩形落在自己屏内")
    func dualDisplaySlotsAreSparse() {
        let displays = dualDisplays()
        var list = Fixtures.records(2)
        list += extraRecords(3, startingAt: 1, displayID: 2)
        let (state, _) = open(displays, list)
        #expect(state.grids.keys.count == 2)

        let primary = state.grids[1]
        let secondary = state.grids[2]
        #expect(primary != nil)
        #expect(secondary != nil)

        let primarySlots = (primary?.occupiedIdentities ?? []).compactMap { primary?.slot(for: $0)?.index }
        let secondarySlots = (secondary?.occupiedIdentities ?? []).compactMap { secondary?.slot(for: $0)?.index }
        #expect(Set(primarySlots).isDisjoint(with: secondarySlots))
        #expect(primarySlots.count + secondarySlots.count == list.count)

        // 全局 slot 稀疏：副屏的 slot 序号不等于它的本地格子序号。
        for identity in secondary?.occupiedIdentities ?? [] {
            guard let slot = secondary?.slot(for: identity),
                  let local = secondary?.localCellIndex(of: slot) else {
                Issue.record("副屏窗口缺少 slot 或本地序号")
                continue
            }
            #expect(local < (secondary?.capacity ?? 0))
            #expect(secondary?.rect(of: identity) == secondary?.cellRect(at: local))
            let visible = displays[1].visibleFrame
            let rect = secondary?.rect(of: identity)
            #expect(rect.map { visible.contains($0.origin) } == true)
            // 用全局 slot 反推行列会把卡片放到另一屏的格子上。
            #expect(secondary?.cellRect(at: slot.index) != secondary?.cellRect(at: local) || slot.index == local)
        }
        #expect(secondarySlots.min() ?? 0 >= (primarySlots.count))
    }

    // MARK: - T16：目标关闭后空格保留

    @Test("最前面与中间关闭都保留空格，后面的窗口不前移")
    func vacancyIsKeptForFirstAndMiddle() {
        var (state, _) = open(Fixtures.displays, Fixtures.records(4))
        let baseline = cellRects(state)
        let all = state.recordsInSlotOrder
        let first = all[0].identity
        let middle = all[2].identity
        _ = Fixtures.dispatch(&state, .windowClosed(first))
        _ = Fixtures.dispatch(&state, .windowClosed(middle))

        #expect(state.slots.slots[0].identity == nil)
        #expect(state.slots.slots[2].identity == nil)
        #expect(state.slots.slots.count == 4)
        for identity in state.records.keys {
            #expect(state.cellRect(for: identity) == baseline[identity])
        }
        // 仍存活的窗口保持它原来的 slot，不依次前移。
        #expect(state.slots.slot(for: all[1].identity) == SlotID(index: 1))
        #expect(state.slots.slot(for: all[3].identity) == SlotID(index: 3))
        let vacantCells = state.grids.values.flatMap { $0.cells }.filter(\.isEmpty).count
        #expect(vacantCells >= 2)
    }

    // MARK: - 整理：pending 入格 + 三处一致

    @Test("格子放满后新窗口进入待整理；整理把待整理全部入格且三处占用一致")
    func organizePlacesEveryPendingWindow() {
        var (state, _) = open(Fixtures.displays, Fixtures.records(3))
        var tag = 0
        // 先把空格填满：新窗口只允许进空格，所以这里不会移动任何已有格子。
        while state.grids.values.reduce(0, { partial, grid in partial + grid.vacancyCount }) > 0 {
            let filled = Array(state.records.values) + extraRecords(1, startingAt: tag)
            refresh(&state, filled)
            tag += 1
        }
        #expect(state.grids.values.allSatisfy { $0.vacancyCount == 0 })

        // 再添加：没有空格就必须进待整理，绝不允许扩容让全部窗口移动。
        let revisionBefore = state.layoutRevision
        let rectsBefore = cellRects(state)
        let overflow = extraRecords(2, startingAt: tag)
        refresh(&state, Array(state.records.values) + overflow)
        #expect(state.layoutRevision == revisionBefore)
        for identity in rectsBefore.keys {
            #expect(state.cellRect(for: identity) == rectsBefore[identity])
        }
        #expect(state.slots.pending.count == 2)
        let waiting = Set(overflow.map(\.identity))
        #expect(Set(state.slots.pending.map(\.identity)) == waiting)

        // 整理是唯一会重排的用户动作。
        _ = Fixtures.dispatch(&state, .organizeRequested)
        #expect(state.slots.pending.isEmpty)
        #expect(state.layoutRevision == revisionBefore + 1)
        assertThreeWayConsistency(state)
    }

    private func assertThreeWayConsistency(_ state: SessionState) {
        for (identity, record) in state.records {
            guard let slot = record.slot else {
                Issue.record("整理后 \(identity.windowID) 仍没有 slot")
                continue
            }
            #expect(state.slots.identity(at: slot) == identity)
            let cell = state.gridCell(for: identity)?.cell
            #expect(cell?.identity == identity)
            #expect(cell?.slot == slot)
        }
        // registry 与 grid 的占用集合必须一模一样。
        let fromRegistry = Set(state.slots.slots.compactMap(\.identity))
        let fromGrids = Set(state.grids.values.flatMap(\.occupiedIdentities))
        #expect(fromRegistry == fromGrids)
        #expect(state.slots.capacity == state.gridCapacity)
    }

    @Test("密度变化允许重排，且重排后仍然三处一致")
    func densityChangeRebuilds() {
        var (state, _) = open(Fixtures.displays, Fixtures.records(4))
        let revision = state.layoutRevision
        _ = Fixtures.dispatch(&state, .settingsChanged(density: .compact))
        #expect(state.layoutRevision == revision + 1)
        assertThreeWayConsistency(state)
    }

    // MARK: - 拖动交换

    @Test("拖动交换只交换占用：矩形留在原地")
    func dragSwapsOccupancyNotGeometry() {
        var (state, _) = open(Fixtures.displays, Fixtures.records(4))
        let all = state.recordsInSlotOrder
        let lhs = all[0]
        let rhs = all[2]
        let lhsRect = state.cellRect(for: lhs.identity)
        let rhsRect = state.cellRect(for: rhs.identity)

        _ = Fixtures.dispatch(&state, .cardDragged(from: lhs.slot ?? SlotID(index: 0),
                                                  to: rhs.slot ?? SlotID(index: 2)))

        // 两个窗口现在各自站在对方的格子里。
        #expect(state.cellRect(for: lhs.identity) == rhsRect)
        #expect(state.cellRect(for: rhs.identity) == lhsRect)
        #expect(state.slots.identity(at: lhs.slot ?? SlotID(index: 0)) == rhs.identity)
        #expect(state.slots.identity(at: rhs.slot ?? SlotID(index: 2)) == lhs.identity)
        #expect(state.records[lhs.identity]?.slot == state.slots.slot(for: lhs.identity))
        #expect(state.records[rhs.identity]?.slot == state.slots.slot(for: rhs.identity))
        // 其余窗口不受影响，格子本身没有重建。
        for record in all where record.identity != lhs.identity && record.identity != rhs.identity {
            #expect(state.cellRect(for: record.identity) != nil)
        }
        #expect(state.layoutRevision == 1)
        assertThreeWayConsistency(state)
    }

    // MARK: - T18：显示器断开

    @Test("显示器断开后按存活屏幕重建网格并注销消失屏")
    func disconnectedDisplayRebuilds() {
        let displays = dualDisplays()
        var list = Fixtures.records(2)
        list += extraRecords(2, startingAt: 3, displayID: 2)
        var (state, _) = open(displays, list)
        let before = state.layoutRevision
        #expect(state.grids.keys.count == 2)

        let effects = Fixtures.dispatch(&state, .displaysChanged)
        guard let request = Fixtures.discoverRequest(effects) else {
            Issue.record("显示器变化后没有重查目录")
            return
        }
        #expect(state.gridsAreStale)
        #expect(state.phase == .overview)

        // 宿主把存活屏幕写进状态：副屏已拔掉，上面的窗口被窗口服务器搬到主屏。
        state.displays = [displays[0]]
        var survivors = Array(state.records.values)
        for index in survivors.indices { survivors[index].displayID = 1 }
        _ = Fixtures.dispatch(&state, .catalogUpdated(request: request, records: survivors))
        #expect(survivors.count == list.count)
        #expect(Array(state.grids.keys) == [1])
        #expect(state.layoutRevision == before + 1)
        assertThreeWayConsistency(state)
        let visible = displays[0].visibleFrame
        for identity in state.records.keys {
            guard let rect = state.cellRect(for: identity) else {
                Issue.record("重建后 \(identity.windowID) 没有格子")
                continue
            }
            #expect(visible.intersects(rect))
        }
    }

    @Test("有待恢复事务时显示器变化先安全恢复再重建")
    func displaysChangedDuringPendingRestoreRecoversFirst() {
        var (state, _) = open(Fixtures.displays, Fixtures.records(3))
        let all = state.recordsInSlotOrder
        let effects = Fixtures.dispatch(&state, .cardClicked(all[0].identity))
        let token = Fixtures.expandToken(effects)!
        _ = Fixtures.dispatch(&state, Fixtures.writeResult(all[0].identity, token: token,
                                                          outcome: .exact(readBack: CGRect(x: 20, y: 20, width: 1_000, height: 640))))
        _ = Fixtures.dispatch(&state, .expandCompleted(token))
        #expect(state.hasPendingGeometryRestore)

        let exitEffects = Fixtures.dispatch(&state, .displaysChanged)
        #expect(state.phase.recoveryDestination == .hidden)
        #expect(containsRestoreAll(exitEffects))
    }

    private func containsRestoreAll(_ effects: [SessionEffect]) -> Bool {
        effects.contains { if case .restoreAll = $0 { return true }; return false }
    }
}
