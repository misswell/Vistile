import Testing
import Foundation
import CoreGraphics
@testable import VistileCore

@Suite("GridLayoutEngine")
struct GridLayoutEngineTests {
    @Test(arguments: [1, 2, 3, 5, 7, 10, 16, 24, 40, 80])
    func everyCountFitsStaysInsideAndIsDeterministic(_ count: Int) throws {
        let sizes = Fixtures.sizes(count)
        let available = try #require(Fixtures.displays.first?.visibleFrame)
        let first = GridLayoutEngine.layout(sourceSizes: sizes, availableRect: available)
        let second = GridLayoutEngine.layout(sourceSizes: sizes, availableRect: available)

        #expect(first.cards.count == count)
        #expect(second.cards.count == count)
        // 相同输入必须得到相同行列结构。
        #expect(first.columns == second.columns)
        #expect(first.rows == second.rows)
        #expect(first.cellSize == second.cellSize)

        for card in first.cards {
            #expect(card.cellRect.width > 0)
            #expect(card.cellRect.height > 0)
            #expect(available.insetBy(dx: -1, dy: -1).contains(card.cellRect.origin))
            #expect(available.insetBy(dx: -1, dy: -1).contains(CGPoint(x: card.cellRect.maxX, y: card.cellRect.maxY)))
            #expect(card.imageRect.width <= card.contentRect.width + 0.5)
            #expect(card.imageRect.height <= card.contentRect.height + 0.5)
            #expect(card.contentRect.maxY <= card.cellRect.maxY + 0.5)
        }

        for outer in first.cards {
            for inner in first.cards where outer.slot != inner.slot {
                #expect(!outer.cellRect.insetBy(dx: 0.5, dy: 0.5).intersects(inner.cellRect.insetBy(dx: 0.5, dy: 0.5)))
            }
        }
    }

    @Test("多屏子集布局仍携带全局 slot")
    func layoutKeepsGlobalSlotIDs() {
        // 第二屏只放全局编号 3、7、11 三个窗口，格子顺序仍按传入数组。
        let subset: [GridSource] = [
            GridSource(slot: SlotID(index: 3), size: CGSize(width: 1_280, height: 800)),
            GridSource(slot: SlotID(index: 7), size: CGSize(width: 1_000, height: 1_000)),
            GridSource(slot: SlotID(index: 11), size: CGSize(width: 1_920, height: 1_080))
        ]
        let layout = GridLayoutEngine.layout(sources: subset, availableRect: Fixtures.screen)
        #expect(layout.cards.map(\.slot) == [SlotID(index: 3), SlotID(index: 7), SlotID(index: 11)])
        // 位置只由数组顺序决定，不会因为 slot 编号跳号而留空洞。
        let origin = layout.cards[0].cellRect.origin
        #expect(layout.cards[1].cellRect.minX > origin.x || layout.cards[1].cellRect.minY > origin.y)
    }

    @Test("严格等比例：卡片画面不裁切不拉伸")
    func imageRectKeepsSourceAspect() throws {
        let mixed: [CGSize] = [
            CGSize(width: 1_920, height: 1_080),
            CGSize(width: 800, height: 1_400),
            CGSize(width: 2_560, height: 600),
            CGSize(width: 640, height: 480),
            CGSize(width: 1_000, height: 1_000)
        ]
        let layout = GridLayoutEngine.layout(sourceSizes: mixed, availableRect: Fixtures.screen)
        for (card, size) in zip(layout.cards, mixed) {
            let sourceRatio = Double(size.width / size.height)
            let imageRatio = Double(card.imageRect.width / card.imageRect.height)
            #expect(abs(imageRatio - sourceRatio) / sourceRatio < 0.02, "slot \(card.slot.index) 比例失真")
            #expect(card.scale > 0)
            #expect(card.imageRect.width <= card.contentRect.width + 0.5)
            #expect(card.imageRect.height <= card.contentRect.height + 0.5)
        }
    }

    @Test("极窄屏不越界")
    func extremeNarrowScreen() {
        let narrow = CGRect(x: -1_600, y: 0, width: 260, height: 1_200)
        let layout = GridLayoutEngine.layout(sourceSizes: Fixtures.sizes(8), availableRect: narrow)
        #expect(layout.cards.count == 8)
        for card in layout.cards {
            #expect(narrow.insetBy(dx: -1, dy: -1).contains(card.cellRect))
        }
    }

    @Test("负坐标副屏一样可用")
    func negativeOriginDisplay() {
        let secondary = CGRect(x: -1_920, y: -200, width: 1_920, height: 1_080)
        let layout = GridLayoutEngine.layout(sourceSizes: Fixtures.sizes(6), availableRect: secondary)
        #expect(layout.cards.count == 6)
        #expect(layout.cards.allSatisfy { secondary.contains($0.cellRect.insetBy(dx: -1, dy: -1)) })
    }

    @Test("窗口数超过可读尺寸时给出提示标记")
    func readabilityFlag() {
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        #expect(!GridLayoutEngine.layout(sourceSizes: Fixtures.sizes(80), availableRect: small).isReadable)
        #expect(GridLayoutEngine.layout(sourceSizes: Fixtures.sizes(4), availableRect: small).isReadable)
    }

    @Test("相同分数按较少空格、较少列决胜")
    func tieBreakIsStable() {
        let square = Fixtures.sizes(4, aspect: 1.0)
        let layout = GridLayoutEngine.layout(sourceSizes: square, availableRect: CGRect(x: 0, y: 0, width: 900, height: 900))
        // 4 个窗口在正方可用区内应得到 2x2，而不是产生空格的 4x1 / 3x2。
        #expect(layout.columns == 2)
        #expect(layout.rows == 2)
        #expect(layout.emptyCells == 0)
    }

    @Test("紧凑模式格子更密")
    func compactDensityUsesSmallerMargins() {
        let sizes = Fixtures.sizes(6)
        let standard = GridLayoutEngine.layout(sourceSizes: sizes, availableRect: Fixtures.screen, style: .standard)
        let compact = GridLayoutEngine.layout(sourceSizes: sizes, availableRect: Fixtures.screen, style: .compact)
        #expect(compact.cellSize.width >= standard.cellSize.width)
    }
}

@Suite("SlotRegistry")
struct SlotRegistryTests {
    @Test("聚焦与返回不改变格子")
    func focusDoesNotMoveSlots() {
        let list = Fixtures.records(6)
        var registry = SlotRegistry(capacity: 12)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        let snapshot = registry.slots
        // 反复进出不会重排。
        for _ in 0..<3 {
            _ = registry.slot(for: list[2].identity)
            registry.release(list[2].identity)
            registry.assign(list[2].identity, memoryKey: list[2].memoryKey)
        }
        #expect(registry.slots == snapshot)
    }

    @Test("窗口关闭留占位，不依次前移")
    func closedWindowLeavesPlaceholder() {
        let list = Fixtures.records(5)
        var registry = SlotRegistry(capacity: 10)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        registry.release(list[1].identity)
        #expect(registry.slots[1].identity == nil)
        #expect(registry.identity(at: SlotID(index: 2)) == list[2].identity)
        #expect(registry.identity(at: SlotID(index: 4)) == list[4].identity)
    }

    @Test("新窗口填空 slot")
    func newWindowFillsFirstVacancy() {
        let list = Fixtures.records(4)
        var registry = SlotRegistry(capacity: 8)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        registry.release(list[0].identity)
        let newcomer = Fixtures.record(999, 5_555)
        let slot = registry.assign(newcomer.identity, memoryKey: newcomer.memoryKey)
        #expect(slot == SlotID(index: 0))
    }

    @Test("容量不足时排队而不是偷偷隐藏窗口")
    func overCapacityQueuesInsteadOfHiding() {
        let list = Fixtures.records(6)
        var registry = SlotRegistry(capacity: 4)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        #expect(registry.slots.count == 4)
        #expect(registry.pending.count == 2)
        registry.organize()
        #expect(registry.slots.count == 6)
        #expect(registry.pending.isEmpty)
    }

    @Test("搜索过滤只改变展示")
    func searchFilterDoesNotMutate() {
        let list = Fixtures.records(5)
        var registry = SlotRegistry(capacity: 10)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        let before = registry.slots
        let shown = registry.displayedSlots { $0 == list[3].identity }
        #expect(shown == [SlotID(index: 3)])
        #expect(registry.slots == before)
    }

    @Test("拖动交换 slot 并持久化顺序偏好")
    func dragSwapsAndPersistsOrder() {
        // 记忆键是应用级（方案 §16）：用三个不同应用，跨会话顺序记忆的语义才完整。
        let list = [
            Fixtures.record(400, 1_000, app: "A", bundle: "com.a"),
            Fixtures.record(400, 1_001, app: "B", bundle: "com.b"),
            Fixtures.record(400, 1_002, app: "C", bundle: "com.c"),
        ]
        var registry = SlotRegistry(capacity: 6)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        registry.swap(SlotID(index: 0), SlotID(index: 2))
        #expect(registry.identity(at: SlotID(index: 0)) == list[2].identity)
        #expect(registry.orderPreference[list[2].memoryKey] == 0)
        #expect(registry.orderPreference[list[0].memoryKey] == 2)
    }

    @Test("同一应用多个窗口共享一个记忆键：不落标题，恢复用会话内稳定顺序")
    func sameAppWindowsShareOneMemoryKey() {
        let list = Fixtures.records(2)
        #expect(list[0].memoryKey == list[1].memoryKey, "同一 bundle 的兄弟窗口键相同")
        var registry = SlotRegistry(capacity: 4)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        registry.swap(SlotID(index: 0), SlotID(index: 1))
        #expect(Set(registry.orderPreference.keys) == [list[0].memoryKey])
        #expect(registry.orderPreference.values.count == 1)
    }

    @Test("重新进入按记忆顺序")
    func rebuildUsesRememberedOrder() {
        let list = [
            Fixtures.record(400, 1_000, app: "A", bundle: "com.a"),
            Fixtures.record(400, 1_001, app: "B", bundle: "com.b"),
            Fixtures.record(400, 1_002, app: "C", bundle: "com.c"),
        ]
        var registry = SlotRegistry(capacity: 6)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        registry.swap(SlotID(index: 0), SlotID(index: 1))
        var rebuilt = SlotRegistry(capacity: 6, orderPreference: registry.orderPreference)
        rebuilt.rebuild(from: [list[2], list[0], list[1]])
        #expect(rebuilt.identity(at: SlotID(index: 0)) == list[1].identity)
        #expect(rebuilt.identity(at: SlotID(index: 1)) == list[0].identity)
    }

    @Test("整理才压缩占位")
    func onlyOrganizeCompacts() {
        let list = Fixtures.records(4)
        var registry = SlotRegistry(capacity: 8)
        for item in list { registry.assign(item.identity, memoryKey: item.memoryKey) }
        registry.release(list[1].identity)
        #expect(registry.slots.count == 4)
        registry.compactVacancies()
        #expect(registry.slots.count == 3)
        #expect(registry.identity(at: SlotID(index: 1)) == list[2].identity)
    }
}
