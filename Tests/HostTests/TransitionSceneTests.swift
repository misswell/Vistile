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
        coordinator.onSceneFinished = { finished.append($0) }

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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: mainCell,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: handoffs,
                                    animationMS: 240,
                                    presentation: fixture.presentation)))
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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: mainCell,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: handoffs,
                                    animationMS: 240,
                                    presentation: fixture.presentation)))
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
        XCTAssertEqual(finished, [secondToken])
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
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 61),
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
                                       presentation: fixture.presentation)

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
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: mainCell,
                                           animationTo: fixture.layout.mainRect,
                                           railHandoffs: handoffs,
                                           animationMS: 240,
                                           presentation: fixture.presentation)

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
                                               identity: main,
                                               displayID: displayID,
                                               snapshot: fixture.snapshot,
                                               targetFrame: fixture.layout.mainRect,
                                               animationFrom: cell,
                                               animationTo: fixture.layout.mainRect,
                                               railHandoffs: [],
                                               animationMS: 240,
                                               presentation: fixture.presentation)

        var factory = baseFactory(imageRects: [main: cell])
        factory.motionLevel = { .fade }
        let enterScene = try XCTUnwrap(factory.entering(entering))
        XCTAssertEqual(enterScene.level, .fade)
        XCTAssertTrue(enterScene.fadeOnly, "淡化等级不飞行")
        XCTAssertEqual(enterScene.durationMS, fixture.layout.style.entryAnimationMS(reduceMotion: true))
        XCTAssertEqual(enterScene.durationMS, 100)
        XCTAssertLessThan(enterScene.durationMS, 240, "比计划里的完整时长更短")

        let slot = try XCTUnwrap(fixture.placement.slot(of: HostFixtures.identity(1)))
        let intent = WorkbenchSwitchIntent(token: TransitionToken(generation: 64),
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
                                       presentation: fixture.presentation)
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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation)))

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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation)))

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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: fixture.layout.mainRect,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [],
                                    animationMS: 80,
                                    presentation: fixture.presentation)))

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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: target,
                                    animationFrom: mainCell,
                                    animationTo: target,
                                    railHandoffs: [],
                                    animationMS: 240,
                                    presentation: fixture.presentation)))

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
                                    identity: main,
                                    displayID: displayID,
                                    snapshot: fixture.snapshot,
                                    targetFrame: fixture.layout.mainRect,
                                    animationFrom: mainCell,
                                    animationTo: fixture.layout.mainRect,
                                    railHandoffs: [handoff],
                                    animationMS: 240,
                                    presentation: fixture.presentation)))

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

    // MARK: - 组装

    private func distance(_ rect: CGRect, to other: CGRect) -> CGFloat {
        hypot(rect.midX - other.midX, rect.midY - other.midY)
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
