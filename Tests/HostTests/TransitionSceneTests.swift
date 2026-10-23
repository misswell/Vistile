import AppKit
import CoreGraphics
import QuartzCore
import VistileCore
import XCTest
@testable import Vistile

/// 过渡动画的纯逻辑（方案 §10.1–§10.6、§18.2 H21、§20.3–§20.4）：端点、过滤、淡出、时长、缓动、动效等级与帧采样。
///
/// 这里只断言"屏幕上要跑的那一份计划"：工厂读到的每个外部事实都由测试自己给出，
/// 端点算错、把窗口画到不存在的 slot 上、或把失败当成功，都会在这里先失败。
final class TransitionSceneTests: XCTestCase {
    private let displayID = HostFixtures.display.id
    private let screen = HostFixtures.visibleFrame

    // MARK: - 时间轴

    func testEaseOutCubicEndpointsAndShape() throws {
        XCTAssertEqual(TransitionTimeline.easeOutCubic(0), 0, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.easeOutCubic(1), 1, accuracy: 0.0001)
        // 短促缓出：中点已经走完大半，尾段减速（无过冲）。
        XCTAssertEqual(TransitionTimeline.easeOutCubic(0.5), 0.875, accuracy: 0.0001)
        XCTAssertGreaterThan(TransitionTimeline.easeOutCubic(0.25), 0.25)
        // 越界输入必须夹取：时间轴外推会让卡片飞出屏幕。
        XCTAssertEqual(TransitionTimeline.easeOutCubic(-3), 0, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.easeOutCubic(9), 1, accuracy: 0.0001)
    }

    func testInterpolateReachesBothEnds() throws {
        let from = CGRect(x: 0, y: 0, width: 100, height: 50)
        let to = CGRect(x: 200, y: 400, width: 500, height: 300)
        XCTAssertEqual(TransitionTimeline.interpolate(from, to, progress: 0), from)
        XCTAssertEqual(TransitionTimeline.interpolate(from, to, progress: 1), to)
        let mid = TransitionTimeline.interpolate(from, to, progress: 0.5)
        XCTAssertEqual(mid.minX, 100, accuracy: 0.0001)
        XCTAssertEqual(mid.minY, 200, accuracy: 0.0001)
        XCTAssertEqual(mid.width, 300, accuracy: 0.0001)
        XCTAssertEqual(mid.height, 175, accuracy: 0.0001)
        XCTAssertEqual(mid.midX, 250, accuracy: 0.0001)
        XCTAssertEqual(mid.midY, 287.5, accuracy: 0.0001)
    }

    func testAspectFitKeepsRatioAndStaysInside() throws {
        let container = CGRect(x: 10, y: 20, width: 100, height: 100)
        let wide = TransitionTimeline.aspectFit(aspect: 2, in: container)
        XCTAssertEqual(wide.width, 100, accuracy: 0.0001)
        XCTAssertEqual(wide.height, 50, accuracy: 0.0001)
        XCTAssertEqual(wide.midY, container.midY, accuracy: 0.0001)
        let tall = TransitionTimeline.aspectFit(aspect: 0.5, in: container)
        XCTAssertEqual(tall.width, 50, accuracy: 0.0001)
        XCTAssertEqual(tall.height, 100, accuracy: 0.0001)
        XCTAssertEqual(tall.midX, container.midX, accuracy: 0.0001)
        // 退化比例必须夹到 0.2，否则会算出零宽/无限高。
        let degenerate = TransitionTimeline.aspectFit(aspect: 0, in: container)
        XCTAssertGreaterThan(degenerate.width, 0)
        XCTAssertGreaterThan(degenerate.height, 0)
    }

    func testBackdropAlphaSemantics() throws {
        XCTAssertEqual(TransitionTimeline.backdropAlpha(.opaque(SIMD4<Float>(0, 0, 0, 1)), progress: 0), 1)
        XCTAssertEqual(TransitionTimeline.backdropAlpha(.transparent, progress: 0.5), 0)
        let rising = TransitionScene.Backdrop.rising(SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(TransitionTimeline.backdropAlpha(rising, progress: 0), 0)
        XCTAssertEqual(TransitionTimeline.backdropAlpha(rising, progress: 0.5), 0.8, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.backdropAlpha(rising, progress: 0.63), 1, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.backdropTargetAlpha(rising), 1)
    }

    func testAspectPrefersFrameMetaThenRecordThenFallback() throws {
        let metal = try HostFixtures.metalContext()
        // 真纹理：宽高比必须从捕获元数据读出来，而不是测试自己塞一个数字。
        let base = try HostFixtures.metalFrame(metal: metal, width: 500, height: 200)
        let sourceMeta = CapturedFrameMeta(pixelWidth: 800,
                                           pixelHeight: 400,
                                           contentRectInPoints: nil,
                                           pointPixelScale: 2,
                                           contentScale: 2,
                                           sourceSizeInPoints: CGSize(width: 1200, height: 300),
                                           status: .complete,
                                           isValid: true,
                                           presentTime: 0)
        let framed = MetalFrame(texture: base.texture,
                                storage: base.storage,
                                meta: sourceMeta,
                                publishedAt: base.publishedAt)
        XCTAssertEqual(TransitionSceneFactory.aspect(frame: framed,
                                                     recordFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
                                                     fallback: CGRect(x: 0, y: 0, width: 900, height: 300)),
                       4, accuracy: 0.0001, "源尺寸存在时优先于像素尺寸与窗口帧")
        XCTAssertEqual(TransitionSceneFactory.aspect(frame: base,
                                                     recordFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
                                                     fallback: nil),
                       2.5, accuracy: 0.0001, "没有源尺寸时用像素尺寸（500×200）")
        XCTAssertEqual(TransitionSceneFactory.aspect(frame: nil,
                                                     recordFrame: CGRect(x: 0, y: 0, width: 500, height: 250),
                                                     fallback: CGRect(x: 0, y: 0, width: 900, height: 300)),
                       2, accuracy: 0.0001)
        XCTAssertEqual(TransitionSceneFactory.aspect(frame: nil,
                                                     recordFrame: nil,
                                                     fallback: CGRect(x: 0, y: 0, width: 900, height: 300)),
                       3, accuracy: 0.0001)
        XCTAssertEqual(TransitionSceneFactory.aspect(frame: nil, recordFrame: nil, fallback: nil),
                       1.6, accuracy: 0.0001)
        // 零尺寸输入不许算出 0 或无穷：比例一律夹到 ≥ 0.2。
        XCTAssertEqual(TransitionSceneFactory.aspect(frame: nil,
                                                     recordFrame: CGRect(x: 0, y: 0, width: 0, height: 0),
                                                     fallback: CGRect(x: 0, y: 0, width: 0, height: 0)),
                       1.6, accuracy: 0.0001)
    }

    // MARK: - 总览 → L 型

    func testEnteringSceneUsesOverviewImageRectAndRailContent() throws {
        let grid = HostFixtures.layout(count: 4)
        let fixture = HostWorkbench.fixture(count: 4)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))).cellRect
        let imageRects = Dictionary(uniqueKeysWithValues: grid.layout.cards.map {
            (HostFixtures.identity($0.slot.index), $0.imageRect)
        })
        let target = CGRect(x: fixture.layout.mainRect.minX + 4,
                            y: fixture.layout.mainRect.minY + 4,
                            width: fixture.layout.mainRect.width - 8,
                            height: fixture.layout.mainRect.height - 8)
        let handoffs = try (1...3).map { index -> RailHandoff in
            let identity = HostFixtures.identity(index)
            let slot = try XCTUnwrap(fixture.placement.slot(of: identity))
            let cell = try XCTUnwrap(grid.layout.card(at: SlotID(index: index))?.cellRect)
            return RailHandoff(identity: identity,
                               slot: slot,
                               from: cell,
                               to: fixture.snapshot.rect(for: slot))
        }
        let token = TransitionToken(generation: 7)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: target,
                                           animationFrom: mainCell,
                                           animationTo: target,
                                           railHandoffs: handoffs,
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: target))

        var factory = baseFactory(imageRects: imageRects)
        factory.aspect = { identity, _ in identity.windowID == 9_001 ? 3.5 : 1.25 }
        let scene = try XCTUnwrap(factory.entering(plan))

        XCTAssertEqual(scene.kind, .entering)
        XCTAssertEqual(scene.token, token)
        XCTAssertEqual(scene.displayID, displayID)
        XCTAssertEqual(scene.durationMS, 240)
        XCTAssertFalse(scene.fadeOnly)
        XCTAssertEqual(TransitionScene.backdropColor(scene.backdrop)?.w, 1, "进入的第一帧就必须盖住总览")
        XCTAssertEqual(scene.cards.count, 4, "一张主卡片 + 三张轨道卡片")

        let mainCard = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(mainCard.identity, main)
        XCTAssertEqual(mainCard.start, imageRects[main], "起点必须是总览画出来的那一格，而不是含标题条的外框")
        XCTAssertEqual(mainCard.end, target)
        XCTAssertEqual(mainCard.cellStart, mainCell, "底板跟着总览格子一起飞")
        XCTAssertNil(mainCard.cellEnd)
        XCTAssertEqual(mainCard.endAlpha, 1)
        XCTAssertFalse(mainCard.hidesRailCard)
        XCTAssertEqual(mainCard.aspect, 1.25, accuracy: 0.0001)

        let railCard = try XCTUnwrap(scene.cards.first { $0.identity == HostFixtures.identity(1) })
        let railCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 1))?.cellRect)
        let railSlot = try XCTUnwrap(fixture.placement.slot(of: HostFixtures.identity(1)))
        XCTAssertEqual(railCard.start, imageRects[HostFixtures.identity(1)])
        XCTAssertEqual(railCard.end, fixture.snapshot.contentRect(for: railSlot), "终点是栏里的内容区，不是整格")
        XCTAssertEqual(railCard.cellStart, railCell, "底板从 reducer 给出的总览格子起飞")
        XCTAssertEqual(railCard.aspect, 3.5, accuracy: 0.0001, "宽高比必须走注入的那一份")
        XCTAssertTrue(scene.hiddenRailIdentities.isEmpty, "进入时两栏刚上屏，没有需要藏起来的副本")
    }

    func testEnteringSkipsCardsOutsideTheDisplay() throws {
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let cell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))).cellRect
        let faraway = CGRect(x: screen.maxX + 5_000, y: screen.maxY + 5_000, width: 200, height: 120)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: TransitionToken(generation: 3),
                                           operationContext: HostPlanFacts.context(token: TransitionToken(generation: 3), kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: cell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [RailHandoff(identity: HostFixtures.identity(1),
                                                                      slot: try XCTUnwrap(fixture.placement.slot(of: HostFixtures.identity(1))),
                                                                      from: faraway,
                                                                      to: nil)],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).entering(plan))
        XCTAssertEqual(scene.cards.map(\.identity), [main], "不在这一屏上的卡片不参与合成")
    }

    func testEnteringOverflowCardFadesInsteadOfFakingPosition() throws {
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2, sideSlots: 12)
        let main = HostFixtures.identity(0)
        let cell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))).cellRect
        let farSlot = RailSlotID(displayID: displayID, rail: .side, ordinal: 11)
        let handoff = RailHandoff(identity: HostFixtures.identity(1),
                                  slot: farSlot,
                                  from: grid.layout.cards[1].imageRect,
                                  to: fixture.snapshot.rect(for: farSlot))
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: TransitionToken(generation: 4),
                                           operationContext: HostPlanFacts.context(token: TransitionToken(generation: 4), kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: cell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [handoff],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        let scene = try XCTUnwrap(baseFactory(imageRects: [HostFixtures.identity(1): grid.layout.cards[1].imageRect]).entering(plan))
        let card = try XCTUnwrap(scene.cards.first { $0.identity == HostFixtures.identity(1) })
        XCTAssertFalse(fixture.snapshot.isVisible(farSlot), "前提：第 12 格在侧栏可视区之外")
        let expectedEnd = fixture.snapshot.isVisible(farSlot) ? fixture.snapshot.contentRect(for: farSlot) : nil
        XCTAssertEqual(card.end, expectedEnd, "可视区之外的 slot 没有可信落点：原地淡出，不伪造位置")
        XCTAssertEqual(card.endAlpha, expectedEnd == nil ? 0 : 1)
        XCTAssertNotNil(card.cellStart, "飞行过程本身照画：只有落点与终点透明度退化")
    }

    // MARK: - L 型 → 总览

    func testReturningSceneFliesBackToOverviewCells() throws {
        let grid = HostFixtures.layout(count: 4)
        let fixture = HostWorkbench.fixture(count: 4)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))).cellRect
        let imageRects = Dictionary(uniqueKeysWithValues: grid.layout.cards.map {
            (HostFixtures.identity($0.slot.index), $0.imageRect)
        })
        let handoffs = (1...3).map { index -> RailHandoff in
            let identity = HostFixtures.identity(index)
            let slot = fixture.placement.slot(of: identity)!
            return RailHandoff(identity: identity,
                               slot: slot,
                               from: fixture.snapshot.rect(for: slot) ?? mainCell,
                               to: grid.layout.card(at: SlotID(index: index))?.cellRect)
        }
        let token = TransitionToken(generation: 11)
        let plan = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .returnOverview),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: CGRect(x: 100, y: 100, width: 900, height: 700),
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: mainCell,
                                           railHandoffs: handoffs,
                                           animationMS: 200,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: CGRect(x: 100, y: 100, width: 900, height: 700)))

        let scene = try XCTUnwrap(baseFactory(imageRects: imageRects).returning(plan))
        XCTAssertEqual(scene.kind, .returning)
        XCTAssertEqual(scene.durationMS, 200)
        XCTAssertEqual(scene.token, token)
        XCTAssertEqual(TransitionScene.backdropColor(scene.backdrop)?.w, 1, "返回时底色升到不透明")
        XCTAssertEqual(TransitionTimeline.backdropAlpha(scene.backdrop, progress: 0), 0, "起步时真实窗口还看得见")

        let mainCard = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(mainCard.start, fixture.layout.mainRect)
        XCTAssertEqual(mainCard.end, imageRects[main])
        XCTAssertNil(mainCard.cellStart)
        XCTAssertEqual(mainCard.cellEnd, mainCell, "主窗口缩回自己的总览格子")
        XCTAssertTrue(mainCard.hidesRailCard)

        let railCard = try XCTUnwrap(scene.cards.first { $0.identity == HostFixtures.identity(2) })
        let slot = fixture.placement.slot(of: HostFixtures.identity(2))!
        XCTAssertEqual(railCard.start, fixture.snapshot.contentRect(for: slot))
        XCTAssertEqual(railCard.cellStart, fixture.snapshot.rect(for: slot))
        XCTAssertEqual(railCard.end, imageRects[HostFixtures.identity(2)])
        XCTAssertEqual(railCard.cellEnd, grid.layout.card(at: SlotID(index: 2))?.cellRect)
        XCTAssertTrue(railCard.hidesRailCard)
        XCTAssertEqual(scene.hiddenRailIdentities.count, 4, "返回时栏里的副本全部交给承载层")
    }

    func testReturningWithoutOverviewRectFallsBackToPlanTarget() throws {
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let cell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))).cellRect
        let plan = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: TransitionToken(generation: 12),
                                           operationContext: HostPlanFacts.context(token: TransitionToken(generation: 12), kind: .returnOverview),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: cell,
                                           railHandoffs: [],
                                           animationMS: 200,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).returning(plan))
        let mainCard = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(mainCard.end, cell, "没有总览画面矩形时退回计划里的格子矩形，不是 nil")
        XCTAssertEqual(mainCard.endAlpha, 1)
    }

    // MARK: - L 型内交换

    func testSwappingSceneOnlyMovesTwoCards() throws {
        let fixture = HostWorkbench.fixture(count: 4)
        let from = HostFixtures.identity(0)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let recordFrames = [from: CGRect(x: 40, y: 60, width: 1_100, height: 720),
                            to: CGRect(x: 90, y: 120, width: 800, height: 500)]
        let mainTarget = fixture.layout.mainRect.insetBy(dx: 6, dy: 6)
        let resting = fixture.snapshot.contentRect(for: slot).map { $0.insetBy(dx: 3, dy: 3) } ?? mainTarget
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 21),
                                           from: from,
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 3,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: mainTarget,
                                       restingTargetFrame: resting,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: mainTarget))

        var factory = baseFactory(imageRects: [:])
        factory.recordFrame = { identity in recordFrames[identity] }
        factory.aspect = { identity, _ in identity == to ? 1.8 : 1.2 }
        let scene = try XCTUnwrap(factory.swapping(plan))

        XCTAssertEqual(scene.kind, .swapping)
        XCTAssertEqual(scene.token, intent.token)
        XCTAssertNil(TransitionScene.backdropColor(scene.backdrop), "栏内交换不画底色，两栏与分隔线纹丝不动")
        XCTAssertEqual(scene.durationMS, fixture.layout.style.switchAnimationMS(reduceMotion: false))
        XCTAssertEqual(scene.cards.count, 2, "只允许两张卡片移动")

        let promoted = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(promoted.identity, to)
        XCTAssertEqual(promoted.start, fixture.snapshot.contentRect(for: slot))
        XCTAssertEqual(promoted.cellStart, fixture.snapshot.rect(for: slot))
        XCTAssertEqual(promoted.end, mainTarget)
        XCTAssertNil(promoted.cellEnd)
        XCTAssertEqual(promoted.aspect, 1.8, accuracy: 0.0001)
        XCTAssertFalse(promoted.hidesRailCard, "The selected thumbnail remains visible during switching")

        let demoted = try XCTUnwrap(scene.cards.first { $0.identity == from })
        XCTAssertFalse(demoted.isFocus)
        XCTAssertEqual(demoted.start, recordFrames[from], "起点用真实窗口帧，不用推算")
        XCTAssertEqual(demoted.end, fixture.snapshot.contentRect(for: slot))
        XCTAssertFalse(demoted.hidesRailCard)
        XCTAssertTrue(scene.hiddenRailIdentities.isEmpty)
    }

    func testSwappingWithoutPreviousMainOnlyPromotes() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 22),
                                           from: nil,
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 1,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: nil,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).swapping(plan))
        XCTAssertEqual(scene.cards.map(\.identity), [to])
        XCTAssertTrue(scene.hiddenRailIdentities.isEmpty, "Switching keeps the selected thumbnail visible")
    }

    // MARK: - 降级与限额

    /// A41（方案 §18 A41）：系统"减少动态效果"下只做短淡化，时长取降级值且严格短于完整动效。
    /// 呈现层是否真的不位移见 `testReduceMotionPresentsTheSameEndpointsWithoutAnyFlight`。
    func testReduceMotionStaysFadeOnly() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 23),
                                           from: HostFixtures.identity(0),
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 1,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: fixture.layout.mainRect,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        var factory = baseFactory(imageRects: [:])
        factory.reduceMotion = { true }
        let scene = try XCTUnwrap(factory.swapping(plan))
        XCTAssertTrue(scene.fadeOnly, "减少动态效果时只做短淡化")
        XCTAssertEqual(scene.durationMS, fixture.layout.style.switchAnimationMS(reduceMotion: true))
        XCTAssertLessThan(scene.durationMS, fixture.layout.style.switchAnimationMS(reduceMotion: false))
    }

    func testNoDisplayFrameMeansNoScene() throws {
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: TransitionToken(generation: 31),
                                           operationContext: HostPlanFacts.context(token: TransitionToken(generation: 31), kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        var factory = baseFactory(imageRects: [:])
        factory.displayFrame = { _ in nil }
        XCTAssertNil(factory.entering(plan), "拿不到屏幕事实时不许播动画")
    }

    // MARK: - 打断续接

    /// §10.4 / A40（方案 §18 A40）：播放中来了新场景，必须从"此刻屏幕上的矩形"接续，
    /// 不跳回新计划的起点、也不重放。"旧完成不得提交新状态"那一半由核心侧
    /// `WorkbenchTests` 的过渡收口用例守着（见 W 系列）。
    @MainActor
    func testInterruptContinuesFromPresentedRect() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let target = fixture.layout.mainRect
        XCTAssertNotEqual(mainCell, target, "前提：总览格与主区矩形不同，飞行才可观察")

        let sceneA = try XCTUnwrap(baseFactory(imageRects: [main: mainCell]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 51),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 51), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: target))))

        let before = CACurrentMediaTime()
        view.play(sceneA, sources: [:])
        view.advance(to: before + 0.06)
        XCTAssertGreaterThan(view.lastProgress, 0, "时间轴必须按真实 elapsed 推进")
        XCTAssertLessThan(view.lastProgress, 1)
        XCTAssertTrue(view.isPlaying)
        let interrupted = try XCTUnwrap(view.presentedRect(for: main), "飞行中每一帧都要留下此刻的呈现矩形")
        XCTAssertNotEqual(interrupted, mainCell)
        let interruptedPanel = try XCTUnwrap(view.presentedPanelRect(for: main))

        // 新计划把同一张卡片声明成另一个起点（屏外）：接续必须用"此刻位置"，而不是新场景的 start。
        let laterStart = mainCell.offsetBy(dx: screen.width * 4, dy: screen.height * 2)
        let sceneB = try XCTUnwrap(baseFactory(imageRects: [main: laterStart]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 52),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 52), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: target))))
        view.play(sceneB, sources: [:])
        let continuedPanel = try XCTUnwrap(view.presentedPanelRect(for: main))
        XCTAssertEqual(continuedPanel, interruptedPanel, "The visible panel must resume from its displayed position")
        let continued = try XCTUnwrap(view.presentedRect(for: main))
        XCTAssertEqual(continued.minX, interrupted.minX, accuracy: 0.001, "打断续接：不许跳回新计划的起点")
        XCTAssertEqual(continued.minY, interrupted.minY, accuracy: 0.001)
        XCTAssertEqual(continued.width, interrupted.width, accuracy: 0.001)
        XCTAssertEqual(continued.height, interrupted.height, accuracy: 0.001)
        XCTAssertGreaterThan(abs(continued.minX - laterStart.minX) + abs(continued.minY - laterStart.minY),
                             100, "新计划的声明起点在屏外，两者必须明显不同，否则这条断言没有意义")
        view.stopNow()
        XCTAssertTrue(view.isIdle)
    }

    // MARK: - 承载层生命周期

    @MainActor
    func testCoordinatorTracksSceneKindAndHiddenIdentities() throws {
        let metal = try HostFixtures.metalContext()
        let coordinator = ModeTransitionCoordinator(metal: metal)
        coordinator.displayFacts = { [displayID] id in
            guard id == displayID else { return nil }
            return ModeTransitionCoordinator.DisplayFacts(cgFrame: HostFixtures.visibleFrame,
                                                          appKitFrame: HostFixtures.visibleFrame,
                                                          scale: 2)
        }

        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 41),
                                           from: HostFixtures.identity(0),
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 1,
                                           targetDisplayID: displayID)
        let swap = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: fixture.layout.mainRect,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).swapping(swap))

        coordinator.play(scene)
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertEqual(coordinator.activeKind, .swapping)
        XCTAssertTrue(coordinator.hiddenRailIdentities.isEmpty, "Both windows retain visible rail thumbnails")
        XCTAssertFalse(coordinator.isReturnPresenting)

        coordinator.cancelAll()
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertTrue(coordinator.hiddenRailIdentities.isEmpty)
    }

    @MainActor
    func testRetireDisplaysFinishesTheActiveScene() throws {
        let metal = try HostFixtures.metalContext()
        let coordinator = ModeTransitionCoordinator(metal: metal)
        coordinator.displayFacts = { [displayID] id in
            guard id == displayID else { return nil }
            return ModeTransitionCoordinator.DisplayFacts(cgFrame: HostFixtures.visibleFrame,
                                                          appKitFrame: HostFixtures.visibleFrame,
                                                          scale: 2)
        }
        var finished: [TransitionToken] = []
        coordinator.onSceneFinished = { finished.append($0) }

        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 42),
                                           from: HostFixtures.identity(0),
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 1,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: fixture.layout.mainRect,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).swapping(plan))
        coordinator.play(scene)

        // 承载屏被拔掉：这一屏的承载层必须收掉，并把"结束了"报给宿主，不留下无人认领的层。
        coordinator.retireDisplays(keeping: [])
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertEqual(finished, [intent.token])
    }

    /// §18.2 H18：整屏过渡只有一层承载窗口——卡片再多也不按卡片数建窗；
    /// 同一屏连续播放复用同一个实例；结束（淡出完成）后这一层不再上屏、不再占着令牌。
    @MainActor
    func testSingleCarrierLayerServesManyCardsAndIsReleasedAtEnd() throws {
        let metal = try HostFixtures.metalContext()
        let coordinator = ModeTransitionCoordinator(metal: metal)
        coordinator.displayFacts = { [displayID] id in
            guard id == displayID else { return nil }
            return ModeTransitionCoordinator.DisplayFacts(cgFrame: HostFixtures.visibleFrame,
                                                          appKitFrame: HostFixtures.visibleFrame,
                                                          scale: 2)
        }
        var finished: [TransitionToken] = []
        var cancelled: [TransitionToken] = []
        coordinator.onSceneFinished = { finished.append($0) }
        coordinator.onSceneCancellationFinished = { cancelled.append($0) }

        let grid = HostFixtures.layout(count: 6)
        let fixture = HostWorkbench.fixture(count: 6)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let imageRects = Dictionary(uniqueKeysWithValues: grid.layout.cards.map {
            (HostFixtures.identity($0.slot.index), $0.imageRect)
        })
        let handoffs = (1..<6).compactMap { index -> RailHandoff? in
            guard let slot = fixture.placement.slot(of: HostFixtures.identity(index)) else { return nil }
            return RailHandoff(identity: HostFixtures.identity(index),
                               slot: slot,
                               from: grid.layout.cards[index].imageRect,
                               to: fixture.snapshot.rect(for: slot))
        }
        XCTAssertGreaterThanOrEqual(handoffs.count, 4, "前提：这一屏至少要容纳四张轨道卡片，'不按卡片数建窗'才有意义")

        let token = TransitionToken(generation: 81)
        let scene = try XCTUnwrap(baseFactory(imageRects: imageRects).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: token,
                                    operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: mainCell,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: handoffs,
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))
        XCTAssertEqual(scene.cards.count, 1 + handoffs.count, "前提：这一段过渡真的有多张卡片参与合成")

        coordinator.play(scene)
        XCTAssertEqual(coordinator.carrierDisplayIDs, [displayID],
                       "\(scene.cards.count) 张卡片共用一整屏一层承载窗口")
        let window = try XCTUnwrap(coordinator.carrierWindow(for: displayID))
        XCTAssertTrue(window.isVisible, "播放期间承载层必须真的上屏")
        XCTAssertEqual(window.carrierView.scene?.cards.count, scene.cards.count, "所有卡片都从这一层的合成器里画出来")

        // 同一屏连着播第二段：不新建窗口，复用同一个实例，场景换成新的一段。
        let secondToken = TransitionToken(generation: 82)
        let second = try XCTUnwrap(baseFactory(imageRects: imageRects).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: secondToken,
                                    operationContext: HostPlanFacts.context(token: secondToken, kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: mainCell,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: handoffs,
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))
        coordinator.play(second)
        XCTAssertEqual(coordinator.carrierDisplayIDs.count, 1, "第二次播放不新增承载窗口")
        let reused = try XCTUnwrap(coordinator.carrierWindow(for: displayID))
        XCTAssertTrue(reused === window, "同一屏的承载窗口是复用的同一个实例，不是每段过渡建一个")
        XCTAssertEqual(reused.carrierView.scene?.token, secondToken)

        // 结束：淡出跑完，这一层离开屏幕、令牌归零；实例留着给下一次同屏播放复用。
        coordinator.retreat(secondToken)
        reused.carrierView.advance(to: CACurrentMediaTime() + 0.2)
        XCTAssertFalse(coordinator.isPresenting, "结束后不许再占着过渡令牌")
        XCTAssertFalse(reused.isVisible, "结束后承载层必须离开屏幕")
        XCTAssertTrue(coordinator.hiddenRailIdentities.isEmpty)
        // retreat 是"取消"不是"落位完成"：终止回调必须正好一个，而且走取消那一路（方案 §13.2、A39）。
        XCTAssertEqual(cancelled, [secondToken], "retreat 收场必须回报一次取消完成")
        XCTAssertTrue(finished.isEmpty, "被 retreat 收掉的过渡不许再发一次正常完成，否则状态机收两遍（A39）")
    }

    // MARK: - 动效等级与帧采样（方案 §20.3–§20.4）

    func testAlphaProgressScalesFadeIntoFraction() throws {
        XCTAssertEqual(TransitionTimeline.alphaProgress(0.25, fadeFraction: 1), 0.25, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.alphaProgress(0.25, fadeFraction: 0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.alphaProgress(0.75, fadeFraction: 0.5), 1, accuracy: 0.0001, "淡化窗口走完就满透明度，不超调")
        XCTAssertEqual(TransitionTimeline.alphaProgress(1, fadeFraction: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.alphaProgress(0, fadeFraction: 0.5), 0, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.alphaProgress(-2, fadeFraction: 0.5), 0, accuracy: 0.0001, "越界输入夹取")
        XCTAssertEqual(TransitionTimeline.alphaProgress(0.5, fadeFraction: 0), 1, accuracy: 0.0001, "0 分数退化时不做除法")
    }

    /// 轻量等级（方案 §20.4）：只让选中卡片飞，被换下的那张直接落在终点、用 140ms 完成淡化。
    func testLightLevelFlightsOnlyFocusAndSnapsOthersInSwapping() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let from = HostFixtures.identity(0)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        XCTAssertNotEqual(fixture.snapshot.contentRect(for: slot), fixture.layout.mainRect,
                          "前提：真实窗口帧（起点）与栏内容区（终点）不同，替换才可观察")
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 61),
                                           from: from,
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 1,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: nil,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        var factory = baseFactory(imageRects: [:])
        factory.motionLevel = { .light }
        let scene = try XCTUnwrap(factory.swapping(plan))

        XCTAssertEqual(scene.level, .light)
        XCTAssertFalse(scene.fadeOnly, "轻量仍然飞行，不是淡化模式")
        XCTAssertEqual(scene.durationMS, fixture.layout.style.switchAnimationMS(reduceMotion: false),
                       "等级只改怎么画，不改计划给的总时长")

        let promoted = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(promoted.identity, to)
        XCTAssertEqual(promoted.start, fixture.snapshot.contentRect(for: slot), "选中的那张必须真的从栏里飞出去")
        XCTAssertNotEqual(promoted.start, promoted.end)
        XCTAssertEqual(promoted.cellStart, fixture.snapshot.rect(for: slot))
        XCTAssertEqual(promoted.fadeFraction, 1, "主卡片按整段推进，不压缩")

        let demoted = try XCTUnwrap(scene.cards.first { $0.identity == from })
        let resting = try XCTUnwrap(demoted.end)
        XCTAssertEqual(resting, promoted.start, "A 去 B 原来待的地方")
        XCTAssertEqual(demoted.start, resting, "轻量等级不做位移：起点直接换成终点")
        XCTAssertEqual(demoted.startAlpha, 0, "从透明开始，在终点原地淡入")
        XCTAssertNil(demoted.cellStart, "没有位移就不画底板飞行")
        XCTAssertEqual(demoted.fadeFraction,
                       TransitionSceneFactory.lightCrossfadeMS / CGFloat(scene.durationMS),
                       accuracy: 0.0001)
        XCTAssertLessThan(TransitionSceneFactory.lightCrossfadeMS, CGFloat(scene.durationMS),
                          "前提：140ms 比整段更短，压缩淡化窗口才有意义")
    }

    /// 轻量等级：面板端点也必须收掉。只清 cellStart 而留着显式 panelFrom/panelTo，
    /// 面板照样会飞出去——那样"只让选中卡片动"的降级就名不副实了。
    func testLightLevelSnapsPanelEndpointsToo() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let from = HostFixtures.identity(0)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 108),
                                                from: from,
                                                to: to,
                                                source: .rail(slot: slot),
                                                placementRevision: 1,
                                                targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: nil,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        var factory = baseFactory(imageRects: [:])
        factory.motionLevel = { .light }
        let scene = try XCTUnwrap(factory.swapping(plan))

        let promoted = try XCTUnwrap(scene.focusCard)
        XCTAssertNotEqual(promoted.panelStart, promoted.panelEnd, "选中的那张照常飞")

        let demoted = try XCTUnwrap(scene.cards.first { $0.identity == from })
        XCTAssertEqual(demoted.panelFrom, demoted.panelTo,
                       "轻量等级的面板端点必须就地收掉，不许还在飞")
        XCTAssertEqual(demoted.panelTo, demoted.panelEnd, "收掉之后的落点仍是计划落点")
        XCTAssertEqual(demoted.startAlpha, 0, "仍然是原地淡入")
    }

    /// 轻量等级进入：轨道卡片不飞、直接落在栏里并短淡化；主卡片照常从总览那一格展开。
    func testLightLevelEnteringSnapsRailCardsToTheirSlots() throws {
        let grid = HostFixtures.layout(count: 3)
        let fixture = HostWorkbench.fixture(count: 3)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let imageRects = Dictionary(uniqueKeysWithValues: grid.layout.cards.map {
            (HostFixtures.identity($0.slot.index), $0.imageRect)
        })
        let handoffs = try (1...2).map { index -> RailHandoff in
            let identity = HostFixtures.identity(index)
            let slot = try XCTUnwrap(fixture.placement.slot(of: identity))
            let cell = try XCTUnwrap(grid.layout.card(at: SlotID(index: index))?.cellRect)
            return RailHandoff(identity: identity, slot: slot, from: cell, to: fixture.snapshot.rect(for: slot))
        }
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: TransitionToken(generation: 62),
                                           operationContext: HostPlanFacts.context(token: TransitionToken(generation: 62), kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: mainCell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: handoffs,
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        var factory = baseFactory(imageRects: imageRects)
        factory.motionLevel = { .light }
        let scene = try XCTUnwrap(factory.entering(plan))

        XCTAssertFalse(scene.fadeOnly)
        XCTAssertEqual(scene.durationMS, 240, "轻量不改计划给的总时长")
        let focus = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(focus.start, imageRects[main], "主卡片仍从总览画出来的那一格起飞")
        XCTAssertNotEqual(focus.start, focus.end)
        XCTAssertEqual(focus.cellStart, mainCell, "主卡片的底板照飞")
        XCTAssertEqual(focus.fadeFraction, 1)

        let railCard = try XCTUnwrap(scene.cards.first { $0.identity == HostFixtures.identity(1) })
        let railSlot = try XCTUnwrap(fixture.placement.slot(of: HostFixtures.identity(1)))
        XCTAssertEqual(railCard.end, fixture.snapshot.contentRect(for: railSlot))
        XCTAssertEqual(railCard.start, railCard.end, "轻量等级不做位移：起点即终点")
        XCTAssertEqual(railCard.startAlpha, 0)
        XCTAssertNil(railCard.cellStart)
        XCTAssertEqual(railCard.fadeFraction,
                       TransitionSceneFactory.lightCrossfadeMS / CGFloat(scene.durationMS),
                       accuracy: 0.0001)
    }

    /// 淡化等级：即使系统没开「减少动态效果」，也用 80–120ms 短淡化（方案 §20.4）。
    func testFadeLevelShortensDurationsWithoutSystemReduceMotion() throws {
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let cell = CGRect(x: 100, y: 100, width: 300, height: 200)
        let entering = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                               token: TransitionToken(generation: 63),
                                               operationContext: HostPlanFacts.context(token: TransitionToken(generation: 63), kind: .enterWorkbench),
                                               identity: main,
                                               displayID: displayID,
                                               snapshot: fixture.snapshot,
                                               targetFrame: fixture.layout.mainRect,
                                               animationFrom: cell,
                                               animationTo: fixture.layout.mainRect,
                                               railHandoffs: [],
                                               animationMS: 240,
                                               presentation: fixture.presentation,
                                               placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        var factory = baseFactory(imageRects: [main: cell])
        factory.motionLevel = { .fade }
        let enterScene = try XCTUnwrap(factory.entering(entering))
        XCTAssertEqual(enterScene.level, .fade)
        XCTAssertTrue(enterScene.fadeOnly, "淡化等级不飞行")
        XCTAssertEqual(enterScene.durationMS, fixture.layout.style.entryAnimationMS(reduceMotion: true))
        XCTAssertEqual(enterScene.durationMS, 100)
        XCTAssertLessThan(enterScene.durationMS, 240, "比计划里的完整时长更短")

        let slot = try XCTUnwrap(fixture.placement.slot(of: HostFixtures.identity(1)))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 64),
                                           from: main,
                                           to: HostFixtures.identity(1),
                                           source: .rail(slot: slot),
                                           placementRevision: 1,
                                           targetDisplayID: displayID)
        let swap = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: nil,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let swapScene = try XCTUnwrap(factory.swapping(swap))
        XCTAssertTrue(swapScene.fadeOnly)
        XCTAssertEqual(swapScene.durationMS, fixture.layout.style.switchAnimationMS(reduceMotion: true))
        XCTAssertEqual(swapScene.durationMS, 80)
        XCTAssertEqual(swapScene.cards.count, 2, "淡化不改变参与卡片，只改变怎么画")
    }

    /// 帧采样（方案 §20.3）：飞行结束把这一段的帧间隔统计报给宿主，40ms 的三连必须被抓到。
    @MainActor
    func testCarrierReportsStutterRunAtFlightEnd() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: fixture.layout.mainRect]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 71),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 71), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))

        var reported: [(TransitionScene.Kind, FrameIntervalStats)] = []
        view.onFlightStats = { reported.append(($0, $1)) }

        let base = CACurrentMediaTime()
        view.play(scene, sources: [:])
        view.advance(to: base)
        var now = base
        let deltasMS: [Double] = [16.7, 16.7, 16.7, 16.7, 16.7, 16.7, 40, 40, 40, 16.7, 16.7, 16.7]
        for delta in deltasMS {
            now += delta / 1000
            view.advance(to: now)
        }
        XCTAssertTrue(view.isHolding, "前提：这段合成时间轴必须跑完")
        XCTAssertEqual(reported.count, 1, "一段飞行只报一次")
        let (kind, stats) = try XCTUnwrap(reported.first)
        XCTAssertEqual(kind, .entering)
        XCTAssertEqual(stats.count, 11, "240ms 在第六个 16.7 与三个 40ms 之后的第 11 个间隔上跑完：tick 1…11 各留一个样本")
        XCTAssertEqual(stats.longestStutterRun, 3, "40ms 的三连必须被抓到")
        XCTAssertEqual(stats.p95MS, 40, accuracy: 0.001)
        XCTAssertGreaterThan(stats.longFrameRatio, FrameIntervalStats.maxLongFrameRatio)
        XCTAssertFalse(stats.meetsTarget, "连续 3 帧明显卡顿不合格")
        XCTAssertGreaterThan(stats.p95MS, FrameIntervalStats.maxP95MS)
        view.stopNow()
    }

    /// 帧采样：全 16.7ms 的一段必须判为预算内（方案 §20.3：P95 ≤ 20ms、掉帧占比 ≤ 1%、无 3 连卡顿）。
    @MainActor
    func testCarrierReportsCleanRunAsWithinBudget() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: fixture.layout.mainRect]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 72),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 72), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))

        var reported: [FrameIntervalStats] = []
        view.onFlightStats = { _, stats in reported.append(stats) }

        let base = CACurrentMediaTime()
        view.play(scene, sources: [:])
        view.advance(to: base)
        var now = base
        for _ in 0..<15 {
            now += 16.7 / 1000
            view.advance(to: now)
        }
        XCTAssertTrue(view.isHolding)
        let stats = try XCTUnwrap(reported.first)
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(stats.count, 15)
        XCTAssertEqual(stats.p95MS, 16.7, accuracy: 0.001)
        XCTAssertEqual(stats.longFrameRatio, 0, accuracy: 0.0001)
        XCTAssertEqual(stats.longestStutterRun, 0)
        XCTAssertTrue(stats.meetsTarget, "全 16.7ms 的一段必须在预算内，不必等到 8 段才敢下结论")
        view.stopNow()
    }

    /// 呈现事实（方案 §20.2）：首帧延迟以真实输入为锚，单独一条；tick 次数与 present 次数分开记，
    /// 不许拿回调次数当"画面动了"。
    @MainActor
    func testCarrierReportsFirstFrameAnchoredAtInputAndSeparatesPresentsFromTicks() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: fixture.layout.mainRect]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 74),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 74), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))

        var facts: [TransitionFlightFacts] = []
        view.onFlightFacts = { _, value in facts.append(value) }

        // 假装"200ms 前就点了"：锚点在前，首帧延迟就必须把这 200ms 算进去。
        let anchor = CACurrentMediaTime() - 0.2
        let base = CACurrentMediaTime()
        view.play(scene, sources: [:], anchorAt: anchor)
        view.advance(to: base)
        var now = base
        for _ in 0..<15 {
            now += 16.7 / 1000
            view.advance(to: now)
        }
        XCTAssertTrue(view.isHolding)
        let flight = try XCTUnwrap(facts.first)
        XCTAssertEqual(facts.count, 1, "一段飞行只报一次呈现事实")
        XCTAssertTrue(flight.anchoredAtRealInput, "给了输入锚点就必须标成真实输入锚定")
        XCTAssertEqual(flight.ticks, 16, "tick 次数按真正驱动到飞行的次数记：首个 tick + 15 个 16.7ms")
        XCTAssertLessThanOrEqual(flight.presentedFrames, flight.ticks + 1,
                                 "present 不可能多于渲染次数（play 的同步第一帧 + 每个 tick 一次）")
        guard flight.hasPresentedPixels else {
            return XCTFail("承载层一次都没 present：这一段没有画面证据，先查 drawable 是否拿得到")
        }
        let delay = try XCTUnwrap(flight.firstPresentDelayMS)
        XCTAssertGreaterThanOrEqual(delay, 195, "首帧延迟必须包含点击之后那 200ms")
        XCTAssertLessThan(delay, 400, "锚点之外只允许几十毫秒的合成开销")
        view.stopNow()
    }

    /// 没有前置输入的过渡（自动替补、探针直接 dispatch）不许冒充"点击反馈"：
    /// 锚点缺失要标出来，延迟按动画进入时刻算，所以一定是小数字。
    @MainActor
    func testFlightFactsWithoutInputAnchorAreMarkedNotAnchored() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: fixture.layout.mainRect]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 75),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 75), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))

        var facts: [TransitionFlightFacts] = []
        view.onFlightFacts = { _, value in facts.append(value) }
        let startBase = CACurrentMediaTime()
        view.play(scene, sources: [:])
        view.advance(to: startBase)
        var now = startBase
        for _ in 0..<15 {
            now += 16.7 / 1000
            view.advance(to: now)
        }
        XCTAssertTrue(view.isHolding, "前提：这段必须跑到飞行结束才会计一次呈现事实")
        let flight = try XCTUnwrap(facts.first)
        XCTAssertFalse(flight.anchoredAtRealInput, "没给锚点就不能标成真实输入")
        if flight.hasPresentedPixels {
            // 锚点是 play() 自己：首帧在同一 tick 内画完，不该读出几百毫秒。
            XCTAssertLessThan(flight.firstPresentDelayMS ?? 999, 100)
        }
        view.stopNow()
    }

    /// 样本不足不下结论：只有两个间隔时宁可不报，也不拿两帧做降级决策（方案 §20.4）。
    @MainActor
    func testCarrierSkipsStatsWhenTooFewSamples() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: fixture.layout.mainRect]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 73),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 73), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 80,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))

        var reported = 0
        view.onFlightStats = { _, _ in reported += 1 }

        let base = CACurrentMediaTime()
        view.play(scene, sources: [:])
        view.advance(to: base)
        view.advance(to: base + 0.05)
        view.advance(to: base + 0.10)
        XCTAssertTrue(view.isHolding)
        XCTAssertEqual(reported, 0, "少于 3 个间隔不产生统计")
        view.stopNow()
    }

    /// §18.2 H21：位移动画由时间轴驱动，与预览帧率解耦——源纹理只有第一帧（低 fps 的极端：
    /// 飞行期间零新帧），60Hz 的每一拍照样是新位置、且单调逼近终点；中途补一帧新纹理只换画面，
    /// 不动时间轴；到点必须到位，不许因为"没有新帧"而停住或拖长。
    @MainActor
    func testMotionIsDrivenByTimelineNotBySourceFrames() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.imageRect)
        let target = fixture.layout.mainRect
        XCTAssertNotEqual(mainCell, target, "前提：端点不同，位移才可观察")

        let firstFrame = try HostFixtures.metalFrame(metal: metal, width: 640, height: 400)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: mainCell]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 91),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 91), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: target))))

        let base = CACurrentMediaTime()
        view.play(scene, sources: [main: firstFrame])
        let start = try XCTUnwrap(view.presentedRect(for: main))
        XCTAssertEqual(start, mainCell)
        var previous = start
        var lastDistance = distance(previous, to: target)

        // 60Hz 八拍：飞行的前半段里源纹理一帧都不更新。
        for step in 1...8 {
            view.advance(to: base + Double(step) * 0.0167)
            let current = try XCTUnwrap(view.presentedRect(for: main))
            XCTAssertNotEqual(current, previous, "第 \(step) 拍没有新位置：动画在等新帧，帧率没有解耦")
            let currentDistance = distance(current, to: target)
            XCTAssertLessThan(currentDistance, lastDistance, "第 \(step) 拍没有更接近终点")
            previous = current
            lastDistance = currentDistance
        }
        XCTAssertTrue(view.isPlaying)

        // 中途到一帧新纹理：只换画面，时间轴不许回退、不许跳变。
        let progressBefore = view.lastProgress
        let secondFrame = try HostFixtures.metalFrame(metal: metal, width: 800, height: 400)
        view.updateSource(main, frame: secondFrame, aspect: 2)
        XCTAssertEqual(view.lastProgress, progressBefore, "换纹理不许动时间轴")
        XCTAssertEqual(try XCTUnwrap(view.presentedRect(for: main)), previous, "换纹理不许改当前呈现矩形")

        // 继续走到时长：后半段依然零新帧，但必须原地按计划到位。
        for step in 9...15 {
            view.advance(to: base + Double(step) * 0.0167)
        }
        XCTAssertTrue(view.isHolding, "240ms 内必须跑完：没有新帧不代表动画可以拖长")
        // 视图↔CG 换算有浮点残差（0.0000000001 量级），逐分量按 0.01pt 对账。
        let landed = try XCTUnwrap(view.presentedRect(for: main))
        XCTAssertEqual(landed.midX, target.midX, accuracy: 0.01, "到点必须落在主区矩形上")
        XCTAssertEqual(landed.midY, target.midY, accuracy: 0.01)
        XCTAssertEqual(landed.width, target.width, accuracy: 0.01)
        XCTAssertEqual(landed.height, target.height, accuracy: 0.01)
        view.stopNow()
    }

    /// 轻量等级的播放（方案 §20.4）：其余卡片从第一帧就落在终点，140ms 内淡到不透明；主卡片照常连续飞行。
    @MainActor
    func testLightPlaybackSnapsOthersAndFadesThemInEarly() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let other = HostFixtures.identity(1)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.imageRect)
        let otherCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 1))?.cellRect)
        XCTAssertNotEqual(mainCell, fixture.layout.mainRect, "前提：总览格与主区矩形不同，飞行才可观察")
        let otherSlot = try XCTUnwrap(fixture.placement.slot(of: other))
        let handoff = RailHandoff(identity: other,
                                  slot: otherSlot,
                                  from: otherCell,
                                  to: fixture.snapshot.rect(for: otherSlot))

        var factory = baseFactory(imageRects: [main: mainCell, other: grid.layout.cards[1].imageRect])
        factory.motionLevel = { .light }
        let scene = try XCTUnwrap(factory.entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 74),
                                    operationContext: HostPlanFacts.context(token: TransitionToken(generation: 74), kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: mainCell,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [handoff],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: fixture.layout.mainRect))))

        let focus = try XCTUnwrap(scene.focusCard)
        let railCard = try XCTUnwrap(scene.cards.first { $0.identity == other })
        XCTAssertNotEqual(focus.start, focus.end, "前提：主卡片真的要飞")
        XCTAssertEqual(railCard.start, railCard.end, "前提：轻量级的其余卡片声明为原地")

        let base = CACurrentMediaTime()
        view.play(scene, sources: [:])
        // 30ms：主卡片在途中，其余卡片已在终点、还在淡入。
        view.advance(to: base + 0.03)
        let flying = try XCTUnwrap(view.presentedRect(for: main))
        XCTAssertNotEqual(flying, focus.start)
        XCTAssertNotEqual(flying, focus.end)
        let snapped = try XCTUnwrap(view.presentedRect(for: other))
        let snappedEnd = try XCTUnwrap(railCard.end)
        XCTAssertEqual(snapped.minX, snappedEnd.minX, accuracy: 0.001, "其余卡片不做位移")
        XCTAssertEqual(snapped.minY, snappedEnd.minY, accuracy: 0.001)
        XCTAssertEqual(snapped.width, snappedEnd.width, accuracy: 0.001)
        XCTAssertEqual(snapped.height, snappedEnd.height, accuracy: 0.001)
        let midAlpha = try XCTUnwrap(view.presentedAlpha(for: other))
        XCTAssertGreaterThan(midAlpha, 0)
        XCTAssertLessThan(midAlpha, 1, "前半段还在淡入")

        // 150ms（≥ 140ms 的淡化窗口）：其余卡片已经完全不透明，主卡片仍在飞。
        view.advance(to: base + 0.15)
        XCTAssertEqual(try XCTUnwrap(view.presentedAlpha(for: other)), 1, accuracy: 0.0001,
                       "140ms 的交叉淡化必须在这之前走完")
        XCTAssertTrue(view.isPlaying)
        view.stopNow()
    }

    /// A41（方案 §18 A41、§10.5）：减少动态效果必须得到**同样的几何与焦点结果**，只是不做位移。
    /// 判据取自真实呈现层的 `presentedRect`——fadeOnly 只在 carrier 的呈现分支里生效，
    /// 只断言场景标志等于"没飞行"，屏幕上的矩形仍可能照旧飞。
    @MainActor
    func testReduceMotionPresentsTheSameEndpointsWithoutAnyFlight() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let fixture = HostWorkbench.fixture(count: 4)
        let from = HostFixtures.identity(0)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let recordFrames = [from: CGRect(x: 40, y: 60, width: 1_100, height: 720),
                            to: CGRect(x: 90, y: 120, width: 800, height: 500)]
        let mainTarget = fixture.layout.mainRect.insetBy(dx: 6, dy: 6)
        let resting = fixture.snapshot.contentRect(for: slot) ?? mainTarget
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 31),
                                           from: from,
                                           to: to,
                                           source: .rail(slot: slot),
                                           placementRevision: 3,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: mainTarget,
                                       restingTargetFrame: resting,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: mainTarget))

        func build(reduceMotion: Bool) throws -> TransitionScene {
            var factory = baseFactory(imageRects: [:])
            factory.recordFrame = { identity in recordFrames[identity] }
            factory.reduceMotion = { reduceMotion }
            return try XCTUnwrap(factory.swapping(plan))
        }

        let full = try build(reduceMotion: false)
        let reduced = try build(reduceMotion: true)
        XCTAssertEqual(full.cards.count, 2, "前提：两张卡片都要真的飞")
        XCTAssertEqual(reduced.cards.count, 2)

        // 同样的几何与焦点结果：端点、参与窗口、哪张是主区卡片都必须一模一样。
        XCTAssertEqual(reduced.cards.map(\.identity), full.cards.map(\.identity), "减少动效不许改变参与窗口集合")
        XCTAssertEqual(reduced.cards.map(\.end), full.cards.map(\.end), "终点几何必须与完整动效一致")
        XCTAssertEqual(reduced.cards.map(\.isFocus), full.cards.map(\.isFocus), "焦点卡片必须是同一张")
        XCTAssertTrue(reduced.fadeOnly)
        XCTAssertFalse(full.fadeOnly)
        XCTAssertLessThan(reduced.durationMS, full.durationMS, "时长要缩短")

        let reducedBase = CACurrentMediaTime()
        view.play(reduced, sources: [:], startAt: reducedBase)
        // 走到这一段的中点：还在淡入途中，但矩形已经停在终点——一个像素都不许位移。
        // 起点由测试给定（`startAt`），进度恰好 0.5；换成 play() 自己读时钟的话，
        // 机器一慢中点就漂到终点之后，这条会变成赌机器快。
        view.advance(to: reducedBase + Double(reduced.durationMS) / 2_000.0)
        for card in reduced.cards {
            let end = try XCTUnwrap(card.end)
            let presented = try XCTUnwrap(view.presentedRect(for: card.identity))
            XCTAssertEqual(presented.minX, end.minX, accuracy: 0.001, "\(card.identity) 减少动效时仍有位移")
            XCTAssertEqual(presented.minY, end.minY, accuracy: 0.001)
            XCTAssertEqual(presented.width, end.width, accuracy: 0.001)
            XCTAssertEqual(presented.height, end.height, accuracy: 0.001)
            let alpha = try XCTUnwrap(view.presentedAlpha(for: card.identity))
            XCTAssertGreaterThan(alpha, 0, "淡化本身要看得见：\(card.identity) alpha=\(alpha)")
        }
        view.stopNow()

        // 对照组：同一份计划不降级时，同一时刻必须还在途中——
        // 没有这条，上面的"已经在终点"可能只是因为根本没画出来。
        let fullBase = CACurrentMediaTime()
        view.play(full, sources: [:], startAt: fullBase)
        view.advance(to: fullBase + Double(full.durationMS) / 2_000.0)
        let focus = try XCTUnwrap(full.focusCard)
        let flying = try XCTUnwrap(view.presentedRect(for: focus.identity))
        let focusEnd = try XCTUnwrap(focus.end)
        XCTAssertNotEqual(flying.minX, focusEnd.minX, accuracy: 0.001,
                          "完整动效在中点应当还在飞：\(flying)")
        view.stopNow()
    }

    // MARK: - 分组样本链路（方案 §20.2）

    /// 分组指标名是生产侧（协调器写样本）与读取侧（P0 探针取每组的行）之间唯一的契约。
    /// 这里用真的 `Metrics` 走一遍：写进两个分组、读回来必须是两行、每行的 n 只数自己那份，
    /// 且名字能被读取侧解析回同一个分组键。解析不出来的形状必须还给 nil，不许猜。
    func testGroupedSamplesStaySeparateThroughRealMetrics() throws {
        let metrics = Metrics()
        let base = "过渡帧间隔p95·总览→L 型"
        let hot = PerformanceGroup(refreshHz: 119.88, reduceMotion: false, coldStart: false)
        let cold = PerformanceGroup(refreshHz: 119.88, reduceMotion: false, coldStart: true)
        for _ in 0..<3 { metrics.measure(PerformanceMetricName.qualified(base, group: hot), milliseconds: 8, context: "n=9") }
        metrics.measure(PerformanceMetricName.qualified(base, group: cold), milliseconds: 40, context: "n=1")

        let summary = metrics.summary()
        let rows = summary.compactMap { sample -> (String, PerformanceSample)? in
            guard let key = PerformanceMetricName.groupKey(fromSummaryRow: sample.name, base: base) else { return nil }
            return (key, sample)
        }
        XCTAssertEqual(Set(rows.map { $0.0 }), Set([hot.key, cold.key]), "两个分组要各自成行，不能合池")
        let hotRow = try XCTUnwrap(rows.first { $0.0 == hot.key }?.1)
        let coldRow = try XCTUnwrap(rows.first { $0.0 == cold.key }?.1)
        // `Metrics.summary()` 的 context 形状是「n=<样本数>, median=…」；探针按这个形状取 n，
        // 形状变了这条要先红，而不是让 P0-18 静默读成 0 个样本。
        XCTAssertTrue(hotRow.context.starts(with: "n=3,"), "热路径那行的 n 只数自己这 3 段：\(hotRow.context)")
        XCTAssertTrue(coldRow.context.starts(with: "n=1,"), "冷启动那行只有自己 1 段：\(coldRow.context)")
        XCTAssertEqual(hotRow.valueMS, 8, accuracy: 0.001, "合池会把冷启动那段 40ms 混进热路径的 P95")
        XCTAssertEqual(coldRow.valueMS, 40, accuracy: 0.001)

        // 计数器同形：写进去、按基名读回分组键。
        metrics.increment(PerformanceMetricName.qualified("过渡有效帧间隔·总览→L 型", group: hot), by: 30)
        let counters = metrics.snapshotCounters()
        XCTAssertEqual(counters[PerformanceMetricName.qualified("过渡有效帧间隔·总览→L 型", group: hot)], 30)
        XCTAssertEqual(counters.compactMap { PerformanceMetricName.groupKey(fromCounterName: $0.key, base: "过渡有效帧间隔·总览→L 型") }, [hot.key])

        // 解析失败一律是 nil：漏尾巴、别的族、空分组键，都不能被读成"这一组没样本"之外的东西。
        XCTAssertNil(PerformanceMetricName.groupKey(fromSummaryRow: base + "·" + hot.key, base: base))
        XCTAssertNil(PerformanceMetricName.groupKey(fromSummaryRow: "过渡首帧延迟·总览→L 型·\(hot.key) p95", base: base))
        XCTAssertNil(PerformanceMetricName.groupKey(fromSummaryRow: "\(base)· p95", base: base))
        XCTAssertNil(PerformanceMetricName.groupKey(fromCounterName: "过渡零呈现段", base: "过渡帧预算内"))
        XCTAssertNil(PerformanceMetricName.groupKey(fromCounterName: "\(base)·", base: base))
    }

    /// 采样那一刻的环境读数本身也要能被解析回分组键：真实 Hz 是 59.94/119.88 这类小数，
    /// reduceMotion 是系统开关，两者都进键。读不到刷新率时必须落在"刷新率未知"而不是假装 60Hz。
    func testEnvironmentGroupKeyRoundTrips() throws {
        let group = PerformanceEnvironment.current(coldStart: true)
        let rate = PerformanceGroup.refreshLabel(hz: group.refreshHz)
        XCTAssertTrue(rate.hasSuffix("Hz") || rate == "刷新率未知", "刷新率档位要落在可比较的形状上：\(rate)")
        XCTAssertTrue(group.key.hasPrefix(rate), "键的第一段就是刚读到的档位：\(group.key)")
        XCTAssertTrue(group.key.contains(group.reduceMotion ? "reduceMotion=开" : "reduceMotion=关"))
        XCTAssertTrue(group.key.hasSuffix("冷启动"))
        XCTAssertEqual(PerformanceMetricName.groupKey(fromSummaryRow: PerformanceMetricName.qualified("过渡帧间隔p95·L 型内交换", group: group) + " p95",
                                                      base: "过渡帧间隔p95·L 型内交换"),
                       group.key)
    }

    // MARK: - 组装

    private func distance(_ rect: CGRect, to other: CGRect) -> CGFloat {
        hypot(rect.midX - other.midX, rect.midY - other.midY)
    }

    // MARK: - 飞行画面：圆角面板（0.1.26 起不再放大捕获图）

    /// 三种过渡的场景都必须声明"画面板"，而不是放大捕获图。
    /// 这是"没有模糊过程"的结构保证：只要场景是 `.panel`，承载层就不会画任何位图。
    func testAllScenesDefaultToPanelContentNotCapturedPixels() throws {
        let grid = HostFixtures.layout(count: 3)
        let fixture = HostWorkbench.fixture(count: 3)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let imageRects = Dictionary(uniqueKeysWithValues: grid.layout.cards.map {
            (HostFixtures.identity($0.slot.index), $0.imageRect)
        })
        let handoffs = try (1...2).map { index -> RailHandoff in
            let identity = HostFixtures.identity(index)
            let slot = try XCTUnwrap(fixture.placement.slot(of: identity))
            return RailHandoff(identity: identity,
                               slot: slot,
                               from: try XCTUnwrap(grid.layout.card(at: SlotID(index: index))?.cellRect),
                               to: fixture.snapshot.rect(for: slot))
        }
        let enterToken = TransitionToken(generation: 101)
        let enterPlan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                                token: enterToken,
                                                operationContext: HostPlanFacts.context(token: enterToken, kind: .enterWorkbench),
                                                identity: main,
                                                displayID: displayID,
                                                snapshot: fixture.snapshot,
                                                targetFrame: fixture.layout.mainRect,
                                                animationFrom: mainCell,
                                                animationTo: fixture.layout.mainRect,
                                                railHandoffs: handoffs,
                                                animationMS: 240,
                                                presentation: fixture.presentation,
                                                placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let factory = baseFactory(imageRects: imageRects)
        for (name, scene) in [("进入", try XCTUnwrap(factory.entering(enterPlan))),
                              ("返回", try XCTUnwrap(factory.returning(enterPlan)))] {
            guard case .panel = scene.content else {
                return XCTFail("\(name)过渡必须画面板，不能放大捕获图：content=\(scene.content)")
            }
        }
        let slot = try XCTUnwrap(fixture.placement.slot(of: HostFixtures.identity(1)))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 102),
                                                from: main,
                                                to: HostFixtures.identity(1),
                                                source: .rail(slot: slot),
                                                placementRevision: 1,
                                                targetDisplayID: displayID)
        let swapPlan = WorkbenchSwitchPlan(intent: intent,
                                           displayID: displayID,
                                           mainTargetFrame: fixture.layout.mainRect,
                                           restingTargetFrame: nil,
                                           restingSlot: slot,
                                           snapshot: fixture.snapshot,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let swapScene = try XCTUnwrap(factory.swapping(swapPlan))
        guard case .panel = swapScene.content else {
            return XCTFail("交换过渡必须画面板，不能放大捕获图：content=\(swapScene.content)")
        }
    }

    /// 面板圆角必须跟着布局 token 走：栏内卡片是 8pt，面板也必须是 8pt，否则飞行中会看出形状变化。
    func testPanelStyleFollowsLayoutCornerRadius() throws {
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let cell = CGRect(x: 100, y: 100, width: 300, height: 200)
        let token = TransitionToken(generation: 103)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: cell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: cell]).entering(plan))
        guard case let .panel(style) = scene.content else {
            return XCTFail("进入过渡必须画面板")
        }
        XCTAssertEqual(style.cornerRadius, fixture.layout.style.cornerRadius,
                       "面板圆角必须取布局 token，不能自己写死一个数")
        XCTAssertEqual(style.cornerRadius, PanelStyle.standard.cornerRadius, accuracy: 0.0001)
        XCTAssertEqual(style.strokeWidth, PanelStyle.standard.strokeWidth, accuracy: 0.0001)
        XCTAssertGreaterThan(style.fill.w, 0.99, "填充必须不透明：面板要挡住底下的真实窗口")
        XCTAssertGreaterThan(style.stroke.w, 0, "描边要有可辨识的 alpha")
    }

    /// 面板端点用卡片外框（含标题条），而不是内容区：
    /// 内容区比外框矮一截，拿它当端点会看出面板从卡片中间"长出来"。
    func testPanelEndpointsUseCardCellNotContentRect() throws {
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let mainImage = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.imageRect)
        XCTAssertNotEqual(mainCell, mainImage, "前提：外框与内容区不同，端点选择才可观察")
        let token = TransitionToken(generation: 104)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: mainCell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: mainImage]).entering(plan))
        let card = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(card.panelStart, mainCell, "面板起点是卡片外框，不是内容区")
        XCTAssertEqual(card.start, mainImage, "画面容器起点照旧是内容区（.captured 回退仍然用它）")
        XCTAssertEqual(card.panelEnd, card.cellEnd ?? card.end ?? card.start)
    }

    /// 面板端点必须落在"卡片外框"上，不能落在内容区：
    /// 内容区比外框矮一个标题条，用它当端点会让面板比真实卡片小一截，交接时再跳一下。
    /// 这条钉住进入工作台时轨道卡片的面板落点 = 栏里那一格。
    func testRailPanelEndpointsUseRailCellNotContentRect() throws {
        let grid = HostFixtures.layout(count: 3)
        let fixture = HostWorkbench.fixture(count: 3)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let imageRects = Dictionary(uniqueKeysWithValues: grid.layout.cards.map {
            (HostFixtures.identity($0.slot.index), $0.imageRect)
        })
        let handoffs = try (1...2).map { index -> RailHandoff in
            let identity = HostFixtures.identity(index)
            let slot = try XCTUnwrap(fixture.placement.slot(of: identity))
            return RailHandoff(identity: identity,
                               slot: slot,
                               from: try XCTUnwrap(grid.layout.card(at: SlotID(index: index))?.cellRect),
                               to: fixture.snapshot.rect(for: slot))
        }
        let token = TransitionToken(generation: 107)
        let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                           token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: mainCell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: handoffs,
                                           animationMS: 240,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        let scene = try XCTUnwrap(baseFactory(imageRects: imageRects).entering(plan))

        for handoff in handoffs {
            let card = try XCTUnwrap(scene.cards.first { $0.identity == handoff.identity })
            let slot = handoff.slot
            let cell = try XCTUnwrap(fixture.snapshot.rect(for: slot))
            let content = try XCTUnwrap(fixture.snapshot.contentRect(for: slot))
            XCTAssertNotEqual(cell, content, "前提：栏里外框与内容区不同，端点选择才可观察")
            XCTAssertEqual(card.panelTo, cell, "面板必须落在栏里那一格（含标题条），不是内容区")
            XCTAssertEqual(card.end, content, "画面容器终点照旧是内容区（.captured 回退仍然用它）")
            XCTAssertNotEqual(card.panelTo, content, "面板落点不许退回内容区")
        }

        // 主卡片：面板起点是总览那一格，落点是主区目标帧。
        let focus = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(focus.panelFrom, mainCell)
        XCTAssertEqual(focus.panelTo, fixture.layout.mainRect)
    }

    /// 承载层在 `.panel` 下确实把面板画到屏幕上，并且面板矩形单调逼近落点。
    /// 这条同时钉住"presentedRect 仍然按画面容器记账"——打断续接与轻量对账都读它。
    @MainActor
    func testCarrierDrawsPanelsThatTravelToTheTarget() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()

        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let mainImage = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.imageRect)
        let target = fixture.layout.mainRect
        let token = TransitionToken(generation: 105)
        let scene = try XCTUnwrap(baseFactory(imageRects: [main: mainImage]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: token,
                                    operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: target))))
        // 面板必须真的被 present 出去：着色器编译失败或编码器建不起来时，
        // 观察点照样有值，但屏幕上一个像素都没有——那是"看起来没糊其实什么都没画"。
        var facts: [TransitionFlightFacts] = []
        view.onFlightFacts = { _, reported in facts.append(reported) }
        let base = CACurrentMediaTime()
        view.play(scene, sources: [:])
        let startPanel = try XCTUnwrap(view.presentedPanelRect(for: main))
        XCTAssertEqual(startPanel, mainCell, "第一帧的面板就在卡片外框上")
        var previousDistance = distance(startPanel, to: target)
        for step in 1...10 {
            view.advance(to: base + Double(step) * 0.0167)
            let panel = try XCTUnwrap(view.presentedPanelRect(for: main))
            let currentDistance = distance(panel, to: target)
            XCTAssertLessThan(currentDistance, previousDistance, "第 \(step) 拍面板没有更接近落点")
            previousDistance = currentDistance
        }
        // 到位后面板与真实窗口的落点重合：交接时用户看不到位置跳变。
        view.advance(to: base + 0.30)
        let landed = try XCTUnwrap(view.presentedPanelRect(for: main))
        XCTAssertEqual(landed.midX, target.midX, accuracy: 0.01)
        XCTAssertEqual(landed.midY, target.midY, accuracy: 0.01)
        XCTAssertEqual(landed.width, target.width, accuracy: 0.01)
        XCTAssertEqual(landed.height, target.height, accuracy: 0.01)
        let reported = try XCTUnwrap(facts.first, "到位后必须报告一次飞行事实")
        XCTAssertGreaterThan(reported.presentedFrames, 0,
                             "圆角面板必须真的 present 上屏，不能只是记账：present=\(reported.presentedFrames)")
        XCTAssertTrue(reported.hasPresentedPixels)
        view.stopNow()
        XCTAssertNil(view.presentedPanelRect(for: main), "收场后面板观察点必须清空，不留幽灵")
    }

    /// `.captured` 诊断回退仍然画底板与放大画面：回退开关不能变成"什么都不画"。
    @MainActor
    func testCapturedFallbackStillDrawsPlateAndTexture() throws {
        let metal = try HostFixtures.metalContext()
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: metal)
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.layout()
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0))?.cellRect)
        let target = fixture.layout.mainRect
        let token = TransitionToken(generation: 106)
        var factory = baseFactory(imageRects: [main: mainCell])
        factory.drawsCapturedContent = true
        let scene = try XCTUnwrap(factory.entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: token,
                                    operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation,
                                    placement: HostPlanFacts.placement(target: target))))
        guard case .captured = scene.content else {
            return XCTFail("drawsCapturedContent = true 时必须回到 .captured")
        }
        let frame = try HostFixtures.metalFrame(metal: metal, width: 640, height: 400)
        let base = CACurrentMediaTime()
        view.play(scene, sources: [main: frame])
        view.advance(to: base + 0.10)
        XCTAssertNil(view.presentedPanelRect(for: main), "回退模式下不画面板")
        XCTAssertNotNil(view.presentedRect(for: main), "回退模式照旧按画面容器记账")
        view.stopNow()
    }

    private func baseFactory(imageRects: [WindowIdentity: CGRect]) -> TransitionSceneFactory {
        var factory = TransitionSceneFactory()
        factory.overviewImageRect = { imageRects[$0] }
        factory.recordFrame = { _ in nil }
        factory.displayFrame = { [displayID, screen] id in id == displayID ? screen : nil }
        factory.aspect = { _, rect in max(0.2, rect.width / max(1, rect.height)) }
        return factory
    }
}
