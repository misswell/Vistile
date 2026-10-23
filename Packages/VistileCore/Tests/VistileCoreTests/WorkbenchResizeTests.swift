import CoreGraphics
import XCTest
@testable import VistileCore

final class WorkbenchResizeTests: XCTestCase {
    private let visible = CGRect(x: -1_512, y: 64, width: 1_512, height: 918)

    private func layout(top: CGFloat = 96, sideWidth: CGFloat = 168,
                        side: RailSide = .right, frame: CGRect? = nil,
                        minimumMainSize: CGSize? = nil) -> WorkbenchLayout {
        WorkbenchLayoutEngine.layout(displayID: 7, visibleFrame: frame ?? visible, side: side,
                                     topHeightOverride: top, sideWidthOverride: sideWidth,
                                     minimumMainSize: minimumMainSize)
    }

    func testExpandedRangesReserveDefaultMainBaseline() {
        let style = WorkbenchStyle()
        XCTAssertEqual(style.topHeightRange, 96...320)
        XCTAssertEqual(style.sideWidthRange, 168...480)
        let large = layout(top: 9_999, sideWidth: 9_999)
        XCTAssertEqual(large.topRailRect.height, 320)
        XCTAssertEqual(large.sideRailRect.width, 480)
        XCTAssertEqual(large.effectiveTopHeightRange, style.topHeightRange)
        XCTAssertEqual(large.effectiveSideWidthRange, style.sideWidthRange)

        let medium = layout(top: 9_999, sideWidth: 9_999,
                            frame: CGRect(x: 0, y: 0, width: 1_280, height: 800))
        XCTAssertEqual(medium.effectiveTopHeightRange, 96...266)
        XCTAssertEqual(medium.effectiveSideWidthRange, 168...446)
        XCTAssertEqual(medium.mainRect.size, style.minimumMainSize)
        XCTAssertEqual(medium.topRailRect.height, medium.effectiveTopHeightRange.upperBound)
        XCTAssertEqual(medium.sideRailRect.width, medium.effectiveSideWidthRange.upperBound)
    }

    func testOptionalRealMinimumChangesEffectiveRanges() {
        let minimum = CGSize(width: 1_100, height: 650)
        let result = layout(top: 9_999, sideWidth: 9_999, minimumMainSize: minimum)
        XCTAssertEqual(result.effectiveTopHeightRange, 96...234)
        XCTAssertEqual(result.effectiveSideWidthRange, 168...378)
        XCTAssertEqual(result.mainRect.size, minimum)
        XCTAssertEqual(result.style.minimumMainSize, CGSize(width: 800, height: 500))
    }

    func testSmallAndDegenerateScreensNeverProduceNegativeOrOverlappingGeometry() {
        for size in [CGSize(width: 1_000, height: 600), CGSize(width: 400, height: 300),
                     CGSize(width: 180, height: 120), CGSize(width: 40, height: 30), .zero] {
            for side in [RailSide.left, .right] {
                let frame = CGRect(origin: CGPoint(x: -500, y: 100), size: size)
                let result = layout(top: 9_999, sideWidth: 9_999, side: side, frame: frame)
                XCTAssertTrue(result.isMainAreaConstrained)
                for rect in [result.mainRect, result.topRailRect, result.sideRailRect,
                             result.topViewport, result.sideViewport] {
                    XCTAssertGreaterThanOrEqual(rect.width, 0)
                    XCTAssertGreaterThanOrEqual(rect.height, 0)
                    if !rect.isEmpty { XCTAssertTrue(frame.contains(rect)) }
                }
                if !result.isDegenerate {
                    XCTAssertFalse(result.mainRect.intersects(result.topRailRect))
                    XCTAssertFalse(result.mainRect.intersects(result.sideRailRect))
                    XCTAssertFalse(result.topRailRect.intersects(result.sideRailRect))
                    XCTAssertTrue(result.effectiveTopHeightRange.contains(result.topRailRect.height))
                    XCTAssertTrue(result.effectiveSideWidthRange.contains(result.sideRailRect.width))
                }
            }
        }
    }

    func testCardsFitViewportAndPreserveImageAspectAtEveryRailSize() throws {
        for side in [RailSide.left, .right] {
            for top in [CGFloat(96), 160, 240, 320] {
                for width in [CGFloat(168), 248, 360, 480] {
                    let result = layout(top: top, sideWidth: width, side: side)
                    for rail in [RailKind.top, .side] {
                        let size = rail == .top ? result.topCardSize : result.sideCardSize
                        let viewport = rail == .top ? result.topViewport : result.sideViewport
                        XCTAssertLessThanOrEqual(size.width, viewport.width + 0.001)
                        XCTAssertLessThanOrEqual(size.height, viewport.height + 0.001)
                        let capacity = rail == .top ? result.topCapacity : result.sideCapacity
                        for ordinal in 0..<capacity {
                            let slot = RailSlotID(displayID: 7, rail: rail, ordinal: ordinal)
                            let rect = try XCTUnwrap(result.rect(for: slot, scrollOffset: 0))
                            let content = try XCTUnwrap(result.contentRect(for: slot, scrollOffset: 0))
                            XCTAssertTrue(viewport.insetBy(dx: -0.001, dy: -0.001).contains(rect))
                            XCTAssertTrue(rect.insetBy(dx: -0.001, dy: -0.001).contains(content))
                            XCTAssertGreaterThanOrEqual(content.minY, rect.minY + result.style.titleHeight - 0.001)
                            XCTAssertEqual(content.width / content.height, result.style.displayAspect, accuracy: 0.001)
                        }
                    }
                }
            }
        }
    }

    func testResizePreservesBothLogicalRailsAndMakesOldTopSlotsScrollable() throws {
        let original = layout().extending(sideSlots: 12)
        let snapshot = WorkbenchLayoutSnapshot(displayID: 7, layout: original,
                                               topScrollOffset: 0, sideScrollOffset: 240, revision: 1)
        let resized = snapshot.replacing(layout: layout(top: 320, sideWidth: 480), revision: 2)
        XCTAssertLessThan(resized.layout.topCapacity, original.topCapacity)
        XCTAssertEqual(resized.layout.topSlotCount, original.topSlotCount)
        XCTAssertEqual(resized.layout.sideSlotCount, original.sideSlotCount)
        XCTAssertEqual(resized.layout.slotOrder, original.slotOrder)
        XCTAssertEqual(resized.sideScrollOffset, 240)
        XCTAssertGreaterThan(resized.layout.maxTopScroll, 0)
        XCTAssertEqual(resized.revision, 2)

        let lastTop = RailSlotID(displayID: 7, rail: .top, ordinal: original.topSlotCount - 1)
        XCTAssertNotNil(resized.rect(for: lastTop))
        XCTAssertFalse(resized.isVisible(lastTop))
        let scrolled = resized.scrolling(rail: .top, to: .greatestFiniteMagnitude)
        XCTAssertTrue(scrolled.isVisible(lastTop))
        XCTAssertTrue(scrolled.layout.topViewport.contains(try XCTUnwrap(scrolled.rect(for: lastTop))))

        let shrunk = scrolled.replacing(layout: layout(), revision: 3)
        XCTAssertEqual(shrunk.layout.slotOrder, original.slotOrder)
        XCTAssertEqual(shrunk.topScrollOffset, 0)
        XCTAssertEqual(shrunk.sideScrollOffset, 240)
    }

    func testExtendingBothRailsAndLegacyOverloadKeepGeometryAndRanges() throws {
        let original = layout()
        let extended = original.extending(topSlots: 24, sideSlots: 30)
        XCTAssertEqual(extended.topSlotCount, 24)
        XCTAssertEqual(extended.sideSlotCount, 30)
        XCTAssertEqual(extended.capacity, original.capacity)
        XCTAssertEqual(extended.mainRect, original.mainRect)
        XCTAssertEqual(extended.topViewport, original.topViewport)
        XCTAssertEqual(extended.sideViewport, original.sideViewport)
        XCTAssertEqual(extended.effectiveTopHeightRange, original.effectiveTopHeightRange)
        XCTAssertEqual(extended.effectiveSideWidthRange, original.effectiveSideWidthRange)
        XCTAssertEqual(extended.topContentLength, 24 * original.topCardSize.width + 23 * original.style.cardGap)
        XCTAssertEqual(extended.extending(sideSlots: 40).topSlotCount, 24)
        XCTAssertEqual(extended.extending(sideSlots: 40).sideSlotCount, 40)
        XCTAssertNotNil(extended.rect(for: RailSlotID(displayID: 7, rail: .top, ordinal: 23), scrollOffset: 0))
        XCTAssertNil(extended.rect(for: RailSlotID(displayID: 7, rail: .top, ordinal: 24), scrollOffset: 0))
        XCTAssertEqual(original.extending(topSlots: -1, sideSlots: -1), original)
    }

    func testSnapshotReplacementAlsoPreservesNewlyExtendedSlots() {
        let original = layout()
        let snapshot = WorkbenchLayoutSnapshot(displayID: 7, layout: original,
                                               topScrollOffset: 0, sideScrollOffset: 0, revision: 1)
        let expanded = original.extending(topSlots: 24, sideSlots: 30)
        let updated = snapshot.replacing(layout: expanded, revision: 2)
        XCTAssertEqual(updated.layout.topSlotCount, 24)
        XCTAssertEqual(updated.layout.sideSlotCount, 30)
        XCTAssertTrue(updated.layout.slotOrder.allSatisfy { updated.rect(for: $0) != nil })
    }

    func testSnapshotRetainsSlotsThroughDegenerateLayout() {
        let original = layout().extending(topSlots: 24, sideSlots: 30)
        let snapshot = WorkbenchLayoutSnapshot(displayID: 7, layout: original,
                                               topScrollOffset: 120, sideScrollOffset: 240, revision: 1)
        let tiny = snapshot.replacing(layout: layout(frame: CGRect(x: 0, y: 0, width: 30, height: 30)), revision: 2)
        XCTAssertTrue(tiny.isDegenerate)
        XCTAssertEqual(tiny.layout.slotOrder, original.slotOrder)
        XCTAssertEqual(tiny.layout.maxTopScroll, 0)
        XCTAssertEqual(tiny.layout.maxSideScroll, 0)
        let restored = tiny.replacing(layout: layout(top: 320), revision: 3)
        XCTAssertEqual(restored.layout.slotOrder, original.slotOrder)
        XCTAssertTrue(restored.layout.slotOrder.allSatisfy { restored.rect(for: $0) != nil })
    }
}
