import XCTest
import CoreGraphics
@testable import VistileCore

/// 确定性边界扫描（方案 §5、§8.3）：固定种子的随机输入 + 极端值，断言结构不变量。
/// 不依赖系统屏幕，也不碰任何真实窗口。
final class WorkbenchBoundaryInvariantTests: XCTestCase {

    /// 固定种子的线性同余发生器：同一个种子在任何机器上产生同一串输入。
    private struct SeededRandom {
        private var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func double(_ lower: Double, _ upper: Double) -> Double {
            let unit = Double(next() >> 11) / Double(UInt64(1) << 53)
            return lower + (upper - lower) * unit
        }

        mutating func int(_ lower: Int, _ upper: Int) -> Int {
            lower + Int(next() % UInt64(upper - lower + 1))
        }

        mutating func pick<T>(_ values: [T]) -> T { values[int(0, values.count - 1)] }
    }

    private func assertFinite(_ value: CGFloat, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value.isFinite, "\(label) 必须是有限值，实际 \(value)", file: file, line: line)
    }

    private func assertFiniteNonNegative(_ rect: CGRect, _ label: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        assertFinite(rect.minX, "\(label).minX", file: file, line: line)
        assertFinite(rect.minY, "\(label).minY", file: file, line: line)
        assertFinite(rect.width, "\(label).width", file: file, line: line)
        assertFinite(rect.height, "\(label).height", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.width, 0, "\(label) 宽度不得为负", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.height, 0, "\(label) 高度不得为负", file: file, line: line)
    }

    private func assertContained(_ rect: CGRect, in container: CGRect, _ label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let eps: CGFloat = 0.001
        XCTAssertGreaterThanOrEqual(rect.minX, container.minX - eps, "\(label) 左边越界", file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, container.minY - eps, "\(label) 下边越界", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, container.maxX + eps, "\(label) 右边越界", file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, container.maxY + eps, "\(label) 上边越界", file: file, line: line)
    }

    private func overlaps(_ lhs: CGRect, _ rhs: CGRect, _ threshold: CGFloat = 0.001) -> Bool {
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > threshold && intersection.height > threshold
    }

    private func assertDisjoint(_ lhs: CGRect, _ rhs: CGRect, _ label: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(overlaps(lhs, rhs), "\(label) 不得有正面积重叠", file: file, line: line)
    }

    // MARK: - 工作台布局

    func testWorkbenchLayoutInvariantsAcrossRandomAndExtremeFrames() {
        var random = SeededRandom(seed: 0x5EED_2026_1023)
        let sides: [RailSide] = [.left, .right]
        let overridePool: [CGFloat?] = [nil, -10_000, 0, 1, 50, 96, 168, 320, 480, 10_000, .nan, .infinity, -.infinity]
        let minimumPool: [CGSize?] = [nil, CGSize(width: 0, height: 0), CGSize(width: 1, height: 1),
                                      CGSize(width: 800, height: 500), CGSize(width: 2_000, height: 2_000),
                                      CGSize(width: 100_000, height: 100_000)]
        var nonDegenerateCount = 0

        for iteration in 0..<400 {
            let tinyWidth = random.int(0, 3) == 0
            let tinyHeight = random.int(0, 3) == 0
            let width = tinyWidth ? random.double(0, 80) : random.double(80, 4_000)
            let height = tinyHeight ? random.double(0, 80) : random.double(80, 3_000)
            let visible = CGRect(x: random.double(-12_000, 12_000),
                                 y: random.double(-12_000, 12_000),
                                 width: width,
                                 height: height)
            let side = random.pick(sides)
            let compact = random.int(0, 1) == 1
            let topOverride = random.int(0, 2) == 0
                ? random.pick(overridePool)
                : (random.int(0, 1) == 0 ? nil : CGFloat(random.double(-500, 2_000)))
            let sideOverride = random.int(0, 2) == 0
                ? random.pick(overridePool)
                : (random.int(0, 1) == 0 ? nil : CGFloat(random.double(-500, 2_000)))
            let minimum = random.pick(minimumPool)

            let layout = WorkbenchLayoutEngine.layout(displayID: 7,
                                                      visibleFrame: visible,
                                                      side: side,
                                                      compact: compact,
                                                      topHeightOverride: topOverride,
                                                      sideWidthOverride: sideOverride,
                                                      minimumMainSize: minimum)
            let repeated = WorkbenchLayoutEngine.layout(displayID: 7,
                                                        visibleFrame: visible,
                                                        side: side,
                                                        compact: compact,
                                                        topHeightOverride: topOverride,
                                                        sideWidthOverride: sideOverride,
                                                        minimumMainSize: minimum)
            XCTAssertEqual(layout, repeated, "同一输入必须得到同一布局（第 \(iteration) 轮）")

            let rects: [(CGRect, String)] = [
                (layout.mainRect, "mainRect"),
                (layout.topRailRect, "topRailRect"),
                (layout.sideRailRect, "sideRailRect"),
                (layout.cornerToolRect, "cornerToolRect"),
                (layout.topViewport, "topViewport"),
                (layout.sideViewport, "sideViewport"),
                (layout.topPanelWindowRect, "topPanelWindowRect"),
                (layout.sidePanelWindowRect, "sidePanelWindowRect"),
                (layout.topDividerRect, "topDividerRect"),
                (layout.sideDividerRect, "sideDividerRect"),
            ]
            for (rect, label) in rects {
                assertFiniteNonNegative(rect, "第 \(iteration) 轮 \(label)")
            }
            assertFinite(layout.topCardSize.width, "第 \(iteration) 轮 topCardSize.width")
            assertFinite(layout.topCardSize.height, "第 \(iteration) 轮 topCardSize.height")
            assertFinite(layout.sideCardSize.width, "第 \(iteration) 轮 sideCardSize.width")
            assertFinite(layout.sideCardSize.height, "第 \(iteration) 轮 sideCardSize.height")
            assertFinite(layout.topContentLength, "第 \(iteration) 轮 topContentLength")
            assertFinite(layout.sideContentLength, "第 \(iteration) 轮 sideContentLength")
            assertFinite(layout.maxTopScroll, "第 \(iteration) 轮 maxTopScroll")
            assertFinite(layout.maxSideScroll, "第 \(iteration) 轮 maxSideScroll")
            XCTAssertGreaterThanOrEqual(layout.topCapacity, 0)
            XCTAssertGreaterThanOrEqual(layout.sideCapacity, 0)

            guard !layout.isDegenerate else {
                XCTAssertEqual(layout.topCapacity, 0)
                XCTAssertEqual(layout.sideCapacity, 0)
                XCTAssertEqual(layout.topContentLength, 0)
                XCTAssertEqual(layout.sideContentLength, 0)
                XCTAssertEqual(layout.topDividerRect, .zero)
                XCTAssertEqual(layout.sideDividerRect, .zero)
                continue
            }
            nonDegenerateCount += 1

            for (rect, label) in rects.prefix(6) {
                assertContained(rect, in: visible, "第 \(iteration) 轮 \(label)")
            }
            assertContained(layout.cornerToolRect, in: layout.topRailRect, "第 \(iteration) 轮 cornerToolRect")
            assertContained(layout.topViewport, in: layout.topRailRect, "第 \(iteration) 轮 topViewport")
            assertContained(layout.sideViewport, in: layout.sideRailRect, "第 \(iteration) 轮 sideViewport")

            assertDisjoint(layout.mainRect, layout.topRailRect, "第 \(iteration) 轮主区/顶栏")
            assertDisjoint(layout.mainRect, layout.sideRailRect, "第 \(iteration) 轮主区/侧栏")
            assertDisjoint(layout.topRailRect, layout.sideRailRect, "第 \(iteration) 轮顶栏/侧栏")
            assertDisjoint(layout.topViewport, layout.cornerToolRect, "第 \(iteration) 轮卡片视口/角落工具区")
            assertDisjoint(layout.cornerToolRect, layout.sideRailRect, "第 \(iteration) 轮角落工具区/侧栏")

            XCTAssertGreaterThan(layout.mainRect.width, 0, "第 \(iteration) 轮主区宽度")
            XCTAssertGreaterThan(layout.mainRect.height, 0, "第 \(iteration) 轮主区高度")
            XCTAssertGreaterThan(layout.topCardSize.width, 0, "第 \(iteration) 轮顶栏卡片宽度")
            XCTAssertGreaterThan(layout.topCardSize.height, 0, "第 \(iteration) 轮顶栏卡片高度")
            XCTAssertGreaterThan(layout.sideCardSize.width, 0, "第 \(iteration) 轮侧栏卡片宽度")
            XCTAssertGreaterThan(layout.sideCardSize.height, 0, "第 \(iteration) 轮侧栏卡片高度")

            // 容量按 floor 取整：最后一张完整卡片不越出视口（方案 §5.4）。
            XCTAssertLessThanOrEqual(layout.topContentLength, layout.topViewport.width + 0.001,
                                     "第 \(iteration) 轮顶栏内容越界")
            XCTAssertLessThanOrEqual(layout.sideContentLength, layout.sideViewport.height + 0.001,
                                     "第 \(iteration) 轮侧栏内容越界")
            if layout.topCapacity > 0 {
                XCTAssertLessThanOrEqual(layout.topContentLength, layout.topViewport.width + 0.001)
            }
            if layout.sideCapacity > 0 {
                XCTAssertLessThanOrEqual(layout.sideContentLength, layout.sideViewport.height + 0.001)
            }

            // 有效区间必须是合法的闭区间：下界不能高于上界，也不能为负。
            let topRange = layout.effectiveTopHeightRange
            let sideRange = layout.effectiveSideWidthRange
            XCTAssertTrue(topRange.lowerBound.isFinite && topRange.upperBound.isFinite)
            XCTAssertTrue(sideRange.lowerBound.isFinite && sideRange.upperBound.isFinite)
            XCTAssertGreaterThanOrEqual(topRange.lowerBound, 0)
            XCTAssertGreaterThanOrEqual(sideRange.lowerBound, 0)
            XCTAssertLessThanOrEqual(topRange.lowerBound, topRange.upperBound)
            XCTAssertLessThanOrEqual(sideRange.lowerBound, sideRange.upperBound)

            // 面板窗口伸进空带但不覆盖主区（方案 §11.2）。
            assertDisjoint(layout.topPanelWindowRect, layout.mainRect, "第 \(iteration) 轮顶栏面板窗口/主区")
            assertDisjoint(layout.sidePanelWindowRect, layout.mainRect, "第 \(iteration) 轮侧栏面板窗口/主区")

            // 分隔线命中带：要么为零，要么完全落在空带里且不侵入两侧。
            if layout.topDividerRect != .zero {
                assertFiniteNonNegative(layout.topDividerRect, "第 \(iteration) 轮 topDividerRect")
                XCTAssertGreaterThanOrEqual(layout.topDividerRect.minY, layout.topRailRect.maxY - 0.001)
                XCTAssertLessThanOrEqual(layout.topDividerRect.maxY, layout.mainRect.minY + 0.001)
                XCTAssertLessThanOrEqual(layout.topDividerRect.height, layout.style.dividerHitWidth + 0.001)
                assertDisjoint(layout.topDividerRect, layout.topRailRect, "第 \(iteration) 轮顶部分隔线/顶栏")
                assertDisjoint(layout.topDividerRect, layout.mainRect, "第 \(iteration) 轮顶部分隔线/主区")
            }
            if layout.sideDividerRect != .zero {
                assertFiniteNonNegative(layout.sideDividerRect, "第 \(iteration) 轮 sideDividerRect")
                XCTAssertLessThanOrEqual(layout.sideDividerRect.width, layout.style.dividerHitWidth + 0.001)
                assertDisjoint(layout.sideDividerRect, layout.mainRect, "第 \(iteration) 轮侧部分隔线/主区")
                assertDisjoint(layout.sideDividerRect, layout.sideRailRect, "第 \(iteration) 轮侧部分隔线/侧栏")
            }
        }

        XCTAssertGreaterThan(nonDegenerateCount, 100, "样本必须同时覆盖退化和正常布局")
    }

    func testWorkbenchSlotRectsStayFiniteAndInsideViewportForHostileScroll() {
        var random = SeededRandom(seed: 0xA11_CE_5)
        let sides: [RailSide] = [.left, .right]
        let offsets: [CGFloat] = [-1_000_000, -1, 0, 0.5, 17, 1_000_000, .nan, .infinity, -.infinity]
        var checkedLayouts = 0

        for _ in 0..<120 {
            let frame = CGRect(x: random.double(-800, 800),
                               y: random.double(-800, 800),
                               width: random.double(500, 3_000),
                               height: random.double(400, 2_000))
            let topOverride: CGFloat? = random.int(0, 2) == 0 ? random.pick([nil, 96, 200, 10_000, .nan]) : nil
            let sideOverride: CGFloat? = random.int(0, 2) == 0 ? random.pick([nil, 168, 300, 10_000, .nan]) : nil
            let layout = WorkbenchLayoutEngine.layout(displayID: 1,
                                                      visibleFrame: frame,
                                                      side: random.pick(sides),
                                                      topHeightOverride: topOverride,
                                                      sideWidthOverride: sideOverride)
            guard !layout.isDegenerate else { continue }
            checkedLayouts += 1

            let topExtended = layout.extending(topSlots: layout.topCapacity + random.int(0, 12),
                                               sideSlots: layout.sideCapacity + random.int(0, 12))
            XCTAssertEqual(topExtended.slotOrder.count,
                           topExtended.topSlotCount + topExtended.sideSlotCount)
            XCTAssertEqual(topExtended.slotOrder,
                           Array(0..<topExtended.topSlotCount).map {
                               RailSlotID(displayID: 1, rail: .top, ordinal: $0)
                           } + Array(0..<topExtended.sideSlotCount).map {
                               RailSlotID(displayID: 1, rail: .side, ordinal: $0)
                           })

            for slot in topExtended.slotOrder {
                for offset in offsets {
                    let rail = slot.rail == .top ? RailKind.top : RailKind.side
                    let clamped = topExtended.clampedScroll(rail: rail, offset: offset)
                    assertFinite(clamped, "clampedScroll(\(rail), \(offset))")
                    let maximum = rail == .top ? topExtended.maxTopScroll : topExtended.maxSideScroll
                    XCTAssertGreaterThanOrEqual(clamped, 0)
                    XCTAssertLessThanOrEqual(clamped, maximum + 0.001)

                    guard let rect = topExtended.rect(for: slot, scrollOffset: offset) else {
                        XCTFail("非退化布局里每个 slot 都必须有矩形")
                        continue
                    }
                    assertFiniteNonNegative(rect, "slot \(slot.ordinal) rect")
                    XCTAssertGreaterThan(rect.width, 0)
                    XCTAssertGreaterThan(rect.height, 0)

                    guard let content = topExtended.contentRect(for: slot, scrollOffset: offset) else {
                        XCTFail("非退化布局里每个 slot 都必须有内容矩形")
                        continue
                    }
                    assertFiniteNonNegative(content, "slot \(slot.ordinal) contentRect")
                    assertContained(content, in: rect, "slot \(slot.ordinal) 内容区")
                    if slot.rail == .top {
                        XCTAssertEqual(rect.midY, topExtended.topViewport.midY, accuracy: 0.001)
                    } else {
                        XCTAssertEqual(rect.midX, topExtended.sideViewport.midX, accuracy: 0.001)
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedLayouts, 40, "样本必须覆盖足够多的非退化布局")
    }

    func testWorkbenchExtendingNeverShrinksBelowCapacityAndStaysDeterministic() {
        let frame = CGRect(x: 0, y: 64, width: 1_512, height: 918)
        let layout = WorkbenchLayoutEngine.layout(displayID: 3, visibleFrame: frame, side: .right)
        XCTAssertFalse(layout.isDegenerate)

        for requested in -5...60 {
            let extended = layout.extending(topSlots: requested, sideSlots: requested)
            XCTAssertGreaterThanOrEqual(extended.topSlotCount, layout.topCapacity)
            XCTAssertGreaterThanOrEqual(extended.sideSlotCount, layout.sideCapacity)
            XCTAssertGreaterThanOrEqual(extended.topSlotCount, requested)
            XCTAssertGreaterThanOrEqual(extended.sideSlotCount, requested)
            XCTAssertEqual(extended.topSlotCount, extended.extending(topSlots: requested, sideSlots: requested).topSlotCount)
            XCTAssertEqual(extended.sideSlotCount, extended.extending(topSlots: requested, sideSlots: requested).sideSlotCount)
        }
    }

    // MARK: - 槽位登记表

    private func makeIdentity(_ index: Int) -> WindowIdentity {
        Fixtures.identity(900, UInt32(10_000 + index))
    }

    private func assertRegistryInvariants(_ registry: SlotRegistry, _ context: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(registry.capacity, 0, "\(context): 容量不得为负", file: file, line: line)
        XCTAssertLessThanOrEqual(registry.slots.count, registry.capacity,
                                 "\(context): 表长度不得超过容量", file: file, line: line)

        var occupied: [WindowIdentity: Int] = [:]
        for (index, content) in registry.slots.enumerated() {
            if let identity = content.identity {
                XCTAssertNil(occupied[identity], "\(context): 同一窗口占了多个 slot", file: file, line: line)
                occupied[identity] = index
                XCTAssertEqual(registry.slot(for: identity)?.index, index,
                               "\(context): slot(for:) 必须指向实际位置", file: file, line: line)
                XCTAssertEqual(registry.identity(at: SlotID(index: index)), identity,
                               "\(context): identity(at:) 必须回读同一身份", file: file, line: line)
            }
        }

        var pendingIdentities = Set<WindowIdentity>()
        for item in registry.pending {
            XCTAssertTrue(pendingIdentities.insert(item.identity).inserted,
                          "\(context): 待整理队列出现重复窗口", file: file, line: line)
            XCTAssertNil(occupied[item.identity],
                         "\(context): 已落位的窗口不得同时留在待整理队列", file: file, line: line)
        }

        XCTAssertNil(registry.identity(at: SlotID(index: -1)), "\(context): 负下标必须返回 nil", file: file, line: line)
        XCTAssertNil(registry.identity(at: SlotID(index: registry.slots.count)),
                     "\(context): 越界下标必须返回 nil", file: file, line: line)
        XCTAssertEqual(registry.liveSlots.count, occupied.count, "\(context): liveSlots 数量必须等于占位数", file: file, line: line)
    }

    func testSlotRegistryOperationSequencesKeepInvariants() {
        var random = SeededRandom(seed: 0x5107_2026)
        var registry = SlotRegistry(capacity: random.int(0, 8))
        let identities = (0..<16).map(makeIdentity)
        let memoryKey: (Int) -> String = { "com.example.app\($0)" }

        func randomPending(excluding occupied: Set<WindowIdentity>) -> [SlotRegistry.PendingWindow] {
            let count = random.int(0, 4)
            var used = occupied
            var items: [SlotRegistry.PendingWindow] = []
            for _ in 0..<count {
                let index = random.int(0, identities.count - 1)
                let identity = identities[index]
                guard used.insert(identity).inserted else { continue }
                items.append(.init(identity: identity,
                                   memoryKey: memoryKey(index),
                                   applicationName: "App",
                                   title: "窗口"))
            }
            return items
        }

        for step in 0..<1_500 {
            let identityIndex = random.int(0, identities.count - 1)
            let identity = identities[identityIndex]
            let operation = random.int(0, 9)
            switch operation {
            case 0, 1:
                registry.assign(identity, memoryKey: memoryKey(identityIndex))
            case 2:
                registry.occupy(identity, memoryKey: memoryKey(identityIndex),
                                at: SlotID(index: random.int(-3, 14)))
            case 3:
                registry.release(identity)
            case 4:
                registry.compactVacancies()
            case 5:
                registry.organize()
            case 6:
                registry.swap(SlotID(index: random.int(-2, 14)),
                              SlotID(index: random.int(-2, 14)))
            case 7:
                var usedSlots = Set<Int>()
                var entries: [(slot: SlotID, identity: WindowIdentity, memoryKey: String)] = []
                var usedIdentities = Set<WindowIdentity>()
                for _ in 0..<random.int(0, 6) {
                    let slot = random.int(-2, 14)
                    let index = random.int(0, identities.count - 1)
                    guard usedSlots.insert(slot).inserted,
                          usedIdentities.insert(identities[index]).inserted else { continue }
                    entries.append((SlotID(index: slot), identities[index], memoryKey(index)))
                }
                registry.adopt(capacity: random.int(0, 12), occupied: entries,
                               pending: randomPending(excluding: usedIdentities))
            case 8:
                let occupied = Set(registry.slots.compactMap(\.identity))
                registry.replacePending(randomPending(excluding: occupied))
            default:
                guard registry.slot(for: identity) == nil else { break }
                registry.enqueuePending(Fixtures.record(900, UInt32(10_000 + identityIndex),
                                                        title: "窗口", bundle: "com.example.app\(identityIndex)"))
            }
            assertRegistryInvariants(registry, "第 \(step) 步 op=\(operation)")
        }
    }

    /// 容量满 → 排队；空位出现后 `assign` 落位，待整理队列必须同步移除该窗口。
    func testAssignClearsPendingWhenVacancyReopens() {
        var registry = SlotRegistry(capacity: 2)
        let a = makeIdentity(0)
        let b = makeIdentity(1)
        let c = makeIdentity(2)

        XCTAssertNotNil(registry.assign(a, memoryKey: "a"))
        XCTAssertNotNil(registry.assign(b, memoryKey: "b"))
        XCTAssertNil(registry.assign(c, memoryKey: "c"))
        XCTAssertEqual(registry.pending.map(\.identity), [c])

        registry.release(a)
        XCTAssertNotNil(registry.assign(c, memoryKey: "c"))
        XCTAssertFalse(registry.pending.contains { $0.identity == c },
                       "落位后仍留在待整理队列会虚报溢出数量")
        assertRegistryInvariants(registry, "assign 落位后")
    }

    // MARK: - 总览网格

    func testGridGeometryInvariantsAcrossRandomInputs() {
        var random = SeededRandom(seed: 0x6_21D_2026)
        var checked = 0

        for iteration in 0..<180 {
            let count = random.int(1, 220)
            let sizes = (0..<count).map { _ in
                CGSize(width: random.double(0, 3_000), height: random.double(0, 2_000))
            }
            let available = CGRect(x: random.double(-1_000, 1_000),
                                   y: random.double(-1_000, 1_000),
                                   width: random.double(60, 3_500),
                                   height: random.double(40, 2_400))
            let style: OverviewStyle = random.int(0, 1) == 0 ? .standard : .compact
            let geometry = GridLayoutEngine.geometry(sourceSizes: sizes,
                                                     availableRect: available,
                                                     style: style)
            let layout = GridLayoutEngine.layout(sourceSizes: sizes,
                                                 availableRect: available,
                                                 style: style)

            assertFinite(geometry.cellSize.width, "第 \(iteration) 轮 cellSize.width")
            assertFinite(geometry.cellSize.height, "第 \(iteration) 轮 cellSize.height")
            assertFiniteNonNegative(geometry.usable, "第 \(iteration) 轮 usable")
            XCTAssertGreaterThanOrEqual(geometry.cellCount, 0)
            XCTAssertGreaterThanOrEqual(geometry.emptyCells, 0)
            XCTAssertEqual(layout.cards.count, geometry.cellCount == 0 ? 0 : count,
                           "第 \(iteration) 轮每张卡都必须有几何")

            guard geometry.cellCount > 0 else { continue }
            checked += 1
            XCTAssertGreaterThanOrEqual(geometry.cellCount, count)
            XCTAssertEqual(geometry.cellCount, geometry.columns * geometry.rows)
            XCTAssertEqual(geometry.emptyCells, geometry.cellCount - count)
            XCTAssertGreaterThan(geometry.columns, 0)
            XCTAssertGreaterThan(geometry.rows, 0)
            XCTAssertGreaterThan(geometry.cellSize.width, 0)
            XCTAssertGreaterThan(geometry.cellSize.height, 0)

            var rects: [CGRect] = []
            for index in 0..<geometry.cellCount {
                guard let rect = geometry.cellRect(at: index),
                      let content = geometry.contentRect(at: index) else {
                    XCTFail("第 \(iteration) 轮格 \(index) 缺少矩形")
                    continue
                }
                assertFiniteNonNegative(rect, "第 \(iteration) 轮格 \(index)")
                assertFiniteNonNegative(content, "第 \(iteration) 轮内容 \(index)")
                assertContained(rect, in: geometry.usable, "第 \(iteration) 轮格 \(index)")
                assertContained(content, in: rect, "第 \(iteration) 轮内容 \(index)")
                rects.append(rect)
            }
            for index in rects.indices {
                for other in rects.index(after: index)..<rects.endIndex {
                    assertDisjoint(rects[index], rects[other],
                                   "第 \(iteration) 轮格 \(index)/\(other) 重叠")
                }
            }

            for card in layout.cards {
                assertFiniteNonNegative(card.cellRect, "第 \(iteration) 轮卡片")
                assertFiniteNonNegative(card.contentRect, "第 \(iteration) 轮卡片内容")
                assertFiniteNonNegative(card.imageRect, "第 \(iteration) 轮画面")
                assertFinite(CGFloat(card.scale), "第 \(iteration) 轮 scale")
                XCTAssertGreaterThanOrEqual(card.scale, 0)
                // 零尺寸源窗口没有可画内容：按约定返回 .zero，不参与包含关系。
                if card.imageRect != .zero {
                    assertContained(card.imageRect, in: card.contentRect, "第 \(iteration) 轮画面")
                } else {
                    XCTAssertEqual(card.scale, 0)
                }
            }
        }
        XCTAssertGreaterThan(checked, 80, "样本必须覆盖足够多的有效几何")
    }
}
