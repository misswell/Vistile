import AppKit
import CoreGraphics
import QuartzCore
import VistileCore
import XCTest
@testable import Vistile

/// 过渡动画的纯逻辑（方案 §10.1–§10.6、§18.2 H21）：端点、过滤、淡出、时长与缓动。
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
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: target,
                                           animationFrom: mainCell,
                                           animationTo: target,
                                           railHandoffs: handoffs,
                                           animationMS: 240,
                                           presentation: fixture.presentation)

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
                                           presentation: fixture.presentation)

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
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: cell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [handoff],
                                           animationMS: 240,
                                           presentation: fixture.presentation)

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
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: CGRect(x: 100, y: 100, width: 900, height: 700),
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: mainCell,
                                           railHandoffs: handoffs,
                                           animationMS: 200,
                                           presentation: fixture.presentation)

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
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: cell,
                                           railHandoffs: [],
                                           animationMS: 200,
                                           presentation: fixture.presentation)

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
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 21),
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
                                       presentation: fixture.presentation)

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
        XCTAssertTrue(promoted.hidesRailCard, "栏里那份先藏起来，否则飞行中会出现两个 B")

        let demoted = try XCTUnwrap(scene.cards.first { $0.identity == from })
        XCTAssertFalse(demoted.isFocus)
        XCTAssertEqual(demoted.start, recordFrames[from], "起点用真实窗口帧，不用推算")
        XCTAssertEqual(demoted.end, fixture.snapshot.contentRect(for: slot))
        XCTAssertTrue(demoted.hidesRailCard)
        XCTAssertEqual(scene.hiddenRailIdentities, [from, to])
    }

    func testSwappingWithoutPreviousMainOnlyPromotes() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 22),
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
                                       presentation: fixture.presentation)

        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).swapping(plan))
        XCTAssertEqual(scene.cards.map(\.identity), [to])
        XCTAssertEqual(scene.hiddenRailIdentities, [to])
    }

    // MARK: - 降级与限额

    func testReduceMotionStaysFadeOnly() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 23),
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
                                       presentation: fixture.presentation)

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
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: [],
                                           animationMS: 240,
                                           presentation: fixture.presentation)
        var factory = baseFactory(imageRects: [:])
        factory.displayFrame = { _ in nil }
        XCTAssertNil(factory.entering(plan), "拿不到屏幕事实时不许播动画")
    }

    // MARK: - 打断续接

    /// §10.4：播放中来了新场景，必须从"此刻屏幕上的矩形"接续，不跳回新计划的起点、也不重放。
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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation)))

        let before = CACurrentMediaTime()
        view.play(sceneA, sources: [:])
        view.advance(to: before + 0.06)
        XCTAssertGreaterThan(view.lastProgress, 0, "时间轴必须按真实 elapsed 推进")
        XCTAssertLessThan(view.lastProgress, 1)
        XCTAssertTrue(view.isPlaying)
        let interrupted = try XCTUnwrap(view.presentedRect(for: main), "飞行中每一帧都要留下此刻的呈现矩形")
        XCTAssertNotEqual(interrupted, mainCell)

        // 新计划把同一张卡片声明成另一个起点（屏外）：接续必须用"此刻位置"，而不是新场景的 start。
        let laterStart = mainCell.offsetBy(dx: screen.width * 4, dy: screen.height * 2)
        let sceneB = try XCTUnwrap(baseFactory(imageRects: [main: laterStart]).entering(
            WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                    token: TransitionToken(generation: 52),
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation)))
        view.play(sceneB, sources: [:])
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
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 41),
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
                                       presentation: fixture.presentation)
        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).swapping(swap))

        coordinator.play(scene)
        XCTAssertTrue(coordinator.isPresenting)
        XCTAssertEqual(coordinator.activeKind, .swapping)
        XCTAssertEqual(coordinator.hiddenRailIdentities, [HostFixtures.identity(0), to])
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
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 42),
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
                                       presentation: fixture.presentation)
        let scene = try XCTUnwrap(baseFactory(imageRects: [:]).swapping(plan))
        coordinator.play(scene)

        // 承载屏被拔掉：这一屏的承载层必须收掉，并把"结束了"报给宿主，不留下无人认领的层。
        coordinator.retireDisplays(keeping: [])
        XCTAssertFalse(coordinator.isPresenting)
        XCTAssertEqual(finished, [intent.token])
    }

    // MARK: - 组装

    private func baseFactory(imageRects: [WindowIdentity: CGRect]) -> TransitionSceneFactory {
        var factory = TransitionSceneFactory()
        factory.overviewImageRect = { imageRects[$0] }
        factory.recordFrame = { _ in nil }
        factory.displayFrame = { [displayID, screen] id in id == displayID ? screen : nil }
        factory.aspect = { _, rect in max(0.2, rect.width / max(1, rect.height)) }
        return factory
    }
}
