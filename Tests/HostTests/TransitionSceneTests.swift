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

    func testSwappingSceneFliesBothPanelsWithDirectionalFlow() throws {
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
        XCTAssertEqual(scene.displayID, displayID)
        XCTAssertNil(TransitionScene.backdropColor(scene.backdrop), "栏内交换不画底色，两栏与分隔线纹丝不动")
        XCTAssertEqual(scene.durationMS, 240, "full 级别给足对飞与流光的时间，不再是一帧遮罩")
        XCTAssertEqual(scene.level, .full)
        XCTAssertFalse(scene.fadeOnly)
        XCTAssertEqual(scene.cards.map(\.identity), [to, from], "新主飞进、旧主退回：两张面板对飞完成空间衔接")

        let promoted = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(promoted.identity, to)
        XCTAssertTrue(promoted.isFocus)
        XCTAssertEqual(promoted.start, fixture.snapshot.contentRect(for: slot) ?? fixture.snapshot.rect(for: slot),
                       "画面容器从被点选格子的内容区起飞")
        XCTAssertEqual(promoted.end, mainTarget)
        XCTAssertEqual(promoted.panelFrom, fixture.snapshot.rect(for: slot), "面板代表那张卡片：从整格（含标题条）起飞")
        XCTAssertEqual(promoted.panelTo, mainTarget,
                       "面板终点是实际停靠目标：小窗口不再飞向整个主区")
        XCTAssertEqual(promoted.startAlpha, 1)
        XCTAssertEqual(promoted.endAlpha, 1)
        XCTAssertEqual(promoted.aspect, 1.8, accuracy: 0.0001)
        XCTAssertTrue(promoted.hidesRailCard, "飞行面板是替身：轨道副本必须藏起来避免叠影")

        let demoted = try XCTUnwrap(scene.cards.first { $0.identity == from })
        // 尊重原尺寸：旧主从它此刻的真实矩形起飞（recordFrame 供的帧），不是主区矩形。
        XCTAssertEqual(demoted.start, recordFrames[from] ?? mainTarget, "旧主从真实停靠矩形起飞")
        XCTAssertEqual(demoted.panelFrom, recordFrames[from] ?? fixture.layout.mainRect)
        XCTAssertEqual(demoted.panelTo, fixture.snapshot.rect(for: slot), "旧主退回自己的格子")
        XCTAssertEqual(demoted.endAlpha, 1)
        XCTAssertTrue(demoted.hidesRailCard)
        XCTAssertFalse(demoted.isFocus)

        XCTAssertEqual(scene.hiddenRailIdentities, [to, from])
        let flow = try XCTUnwrap(scene.flow, "full 级别必须携带流光：切换要有能量流动的衔接")
        let cell = try XCTUnwrap(fixture.snapshot.rect(for: slot))
        let expected = SIMD2<Float>(Float(fixture.layout.mainRect.midX - cell.midX),
                                    Float(fixture.layout.mainRect.midY - cell.midY))
        XCTAssertEqual(flow.axis.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(flow.axis.y, expected.y, accuracy: 0.001, "流光方向从被点选格子指向主区")
    }

    /// 流光的时间包络：起步抽出、减速展开、到达扩散——形态全部单调、有界、端点确定。
    func testFlowEnvelopesAreMonotonicAndBounded() {
        XCTAssertEqual(TransitionTimeline.flightSpeed(0), 1, accuracy: 0.0001)
        XCTAssertEqual(TransitionTimeline.flightSpeed(1), 0, accuracy: 0.0001)
        for index in 0..<20 where index > 0 {
            let t = CGFloat(index) / 20
            XCTAssertLessThanOrEqual(TransitionTimeline.flightSpeed(t), TransitionTimeline.flightSpeed(t - 0.05),
                                     "速度必须单调下降：easeOut 的减速感是流光形态的输入")
        }
        XCTAssertEqual(TransitionTimeline.flowIntensity(0), 0, accuracy: 0.0001, "光不能突然点亮：起步从零抽出")
        XCTAssertGreaterThan(TransitionTimeline.flowIntensity(0.14), 0.9, "起步段结束时接近全亮")
        XCTAssertEqual(TransitionTimeline.flowIntensity(1), 0, accuracy: 0.0001,
                       "落定后 Metal 流光归零，持续光效无缝交给边缘光晕")
        for index in 0...20 {
            let t = CGFloat(index) / 20
            XCTAssertGreaterThanOrEqual(TransitionTimeline.flowIntensity(t), 0)
            XCTAssertLessThanOrEqual(TransitionTimeline.flowIntensity(t), 1)
            XCTAssertGreaterThanOrEqual(TransitionTimeline.flowSettle(t), 0)
            XCTAssertLessThanOrEqual(TransitionTimeline.flowSettle(t), 1)
            XCTAssertGreaterThanOrEqual(TransitionTimeline.flowBandWidth(t), 0.10)
            XCTAssertLessThanOrEqual(TransitionTimeline.flowBandWidth(t), 0.32)
            XCTAssertGreaterThanOrEqual(TransitionTimeline.flowTrail(t), 0.32)
            XCTAssertLessThanOrEqual(TransitionTimeline.flowTrail(t), 0.52)
        }
        XCTAssertEqual(TransitionTimeline.flowSettle(0.72), 0, accuracy: 0.0001, "0.72 前是纯扫掠")
        XCTAssertEqual(TransitionTimeline.flowSettle(1), 1, accuracy: 0.0001, "到达段完全展开为径向柔光")
        XCTAssertGreaterThan(TransitionTimeline.flowBandWidth(1), TransitionTimeline.flowBandWidth(0),
                             "减速后光带必须展开：宽而柔，不是等宽扫过")
        XCTAssertGreaterThan(TransitionTimeline.flowTrail(0), TransitionTimeline.flowTrail(1),
                             "速度最快时拖尾最长")
    }

    /// light 级别不飞面板，但流光仍从格子方向扫过主区再扩散：方向感不丢。
    /// fade/Reduce Motion 保持单帧遮罩与短淡化，无流光。
    func testSwappingFlowDegradesByMotionLevel() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 26),
                                           from: HostFixtures.identity(0), to: to,
                                           source: .rail(slot: slot), placementRevision: 1,
                                           targetDisplayID: displayID)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: fixture.layout.mainRect,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))

        var lightFactory = baseFactory(imageRects: [:])
        lightFactory.motionLevel = { .light }
        let light = try XCTUnwrap(lightFactory.swapping(plan))
        XCTAssertEqual(light.durationMS, 180, "light 级别让流光独自扫完再扩散")
        XCTAssertNotNil(light.flow, "light 级别仍要有方向感")
        XCTAssertEqual(light.cards.map(\.identity), [to])
        XCTAssertTrue(light.isStationarySwap, "light 面板原地不动，只有光在动")
        XCTAssertTrue(light.hiddenRailIdentities.isEmpty)

        var fadeFactory = baseFactory(imageRects: [:])
        fadeFactory.motionLevel = { .fade }
        let fade = try XCTUnwrap(fadeFactory.swapping(plan))
        XCTAssertNil(fade.flow, "淡化等级无流光")
        XCTAssertEqual(fade.durationMS, 16)
        XCTAssertTrue(fade.fadeOnly)

        var reducedFactory = baseFactory(imageRects: [:])
        reducedFactory.reduceMotion = { true }
        let reduced = try XCTUnwrap(reducedFactory.swapping(plan))
        XCTAssertNil(reduced.flow, "Reduce Motion 下无流光")
        XCTAssertEqual(reduced.durationMS, 16)
        XCTAssertTrue(reduced.fadeOnly)
    }

    func testSwappingWithoutPreviousMainStillFliesFromTheRail() throws {
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
        XCTAssertEqual(scene.cards.map(\.identity), [to], "没有旧主时只有新主一张在飞")
        let card = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(card.start, fixture.snapshot.contentRect(for: slot) ?? fixture.snapshot.rect(for: slot))
        XCTAssertEqual(card.end, plan.mainTargetFrame)
        XCTAssertEqual(card.panelFrom, fixture.snapshot.rect(for: slot))
        XCTAssertEqual(card.panelTo, fixture.layout.mainRect)
        XCTAssertEqual(card.startAlpha, 1)
        XCTAssertEqual(card.endAlpha, 1)
        XCTAssertEqual(scene.durationMS, 240)
        XCTAssertNotNil(scene.flow)
        XCTAssertEqual(scene.hiddenRailIdentities, [to])
    }

    func testExternalFocusUsesShortStationaryFadeWithoutMovingRailCards() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let base = HostPlanFacts.switchIntent(token: TransitionToken(generation: 25),
                                              from: HostFixtures.identity(0), to: to,
                                              source: .rail(slot: slot), placementRevision: 1,
                                              targetDisplayID: displayID)
        let intent = WorkbenchSwitchIntent(token: base.token, from: base.from, to: to,
                                            source: base.source, placementRevision: base.placementRevision,
                                            targetDisplayID: displayID, operationContext: base.operationContext,
                                            beforeOperation: base.beforeOperation, followsExternalFocus: true)
        let plan = WorkbenchSwitchPlan(intent: intent, displayID: displayID,
                                       mainTargetFrame: fixture.layout.mainRect,
                                       restingTargetFrame: nil, restingSlot: slot,
                                       snapshot: fixture.snapshot, presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        var factory = baseFactory(imageRects: [:])
        let scene = try XCTUnwrap(factory.swapping(plan))
        XCTAssertTrue(scene.fadeOnly)
        XCTAssertEqual(scene.durationMS, 120)
        XCTAssertEqual(scene.cards.count, 1)
        let card = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(card.identity, to)
        XCTAssertEqual(card.start, plan.mainTargetFrame)
        XCTAssertEqual(card.end, plan.mainTargetFrame)
        XCTAssertEqual(card.panelFrom, plan.mainTargetFrame)
        XCTAssertEqual(card.panelTo, plan.mainTargetFrame)
        XCTAssertEqual(card.startAlpha, 0)
        XCTAssertEqual(card.endAlpha, 0.35)
        XCTAssertTrue(scene.hiddenRailIdentities.isEmpty)
        factory.reduceMotion = { true }
        let reduced = try XCTUnwrap(factory.swapping(plan))
        XCTAssertEqual(reduced.durationMS, 80)
        XCTAssertTrue(reduced.fadeOnly)
        XCTAssertEqual(reduced.focusCard?.startAlpha, 0)
        XCTAssertEqual(reduced.focusCard?.endAlpha, 0.35)
    }

    // MARK: - 降级与限额

    /// Manual swapping keeps its one-frame mask budget even under Reduce Motion.
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
        XCTAssertTrue(scene.fadeOnly, "Reduce Motion still selects the non-flight presentation path")
        XCTAssertEqual(scene.level, .full, "System Reduce Motion does not rewrite the requested level")
        XCTAssertEqual(scene.durationMS, 16)
        XCTAssertEqual(scene.cards.map(\.identity), [to])
        XCTAssertEqual(scene.focusCard?.startAlpha, 1)
        XCTAssertEqual(scene.focusCard?.endAlpha, 1)
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
        XCTAssertEqual(coordinator.hiddenRailIdentities, Set([to, HostFixtures.identity(0)]),
                       "飞行面板是替身：两张窗口的轨道副本在过渡期间都藏起来")
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

    /// Light manual swapping keeps a single opaque target at rest; no demoted-card crossfade.
    func testLightLevelSwappingKeepsOnlyTheTargetStationary() throws {
        let fixture = HostWorkbench.fixture(count: 3)
        let from = HostFixtures.identity(0)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        XCTAssertNotEqual(fixture.snapshot.contentRect(for: slot), fixture.layout.mainRect,
                          "The selected rail thumbnail must not become the mask's starting rect")
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
        XCTAssertFalse(scene.fadeOnly, "Stationary geometry does not change the requested motion level")
        XCTAssertEqual(scene.durationMS, 180, "面板原地不动，但流光仍要扫过再扩散：光走完这段的时间")
        XCTAssertNotNil(scene.flow)
        XCTAssertEqual(scene.cards.map(\.identity), [to])

        let promoted = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(promoted.identity, to)
        XCTAssertEqual(promoted.start, plan.mainTargetFrame)
        XCTAssertEqual(promoted.end, plan.mainTargetFrame)
        XCTAssertEqual(promoted.startAlpha, 1)
        XCTAssertEqual(promoted.endAlpha, 1)
        XCTAssertNil(promoted.cellStart)
        XCTAssertNil(promoted.cellEnd)
        XCTAssertEqual(promoted.fadeFraction, 1)
        XCTAssertFalse(promoted.hidesRailCard)
        XCTAssertTrue(scene.hiddenRailIdentities.isEmpty)
    }

    /// Light mode keeps the actual docked window panel stationary, not the whole main area.
    func testLightLevelSwappingKeepsTheDockedPanelStationary() throws {
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
        let dockedTarget = fixture.layout.mainRect.insetBy(dx: 80, dy: 40)
        let plan = WorkbenchSwitchPlan(intent: intent,
                                       displayID: displayID,
                                       mainTargetFrame: dockedTarget,
                                       restingTargetFrame: nil,
                                       restingSlot: slot,
                                       snapshot: fixture.snapshot,
                                       presentation: fixture.presentation,
                                       placement: HostPlanFacts.placement(target: dockedTarget))
        var factory = baseFactory(imageRects: [:])
        factory.motionLevel = { .light }
        let scene = try XCTUnwrap(factory.swapping(plan))

        XCTAssertEqual(scene.cards.map(\.identity), [to])
        let promoted = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(promoted.panelFrom, dockedTarget)
        XCTAssertEqual(promoted.panelTo, dockedTarget)
        XCTAssertEqual(promoted.panelStart, dockedTarget)
        XCTAssertEqual(promoted.panelEnd, dockedTarget)
        XCTAssertNotEqual(promoted.panelEnd, fixture.layout.mainRect,
                          "流光与边缘光晕必须贴合原尺寸停靠窗口，不能铺满主区")
        XCTAssertEqual(promoted.startAlpha, 1)
        XCTAssertEqual(promoted.endAlpha, 1)
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
        XCTAssertEqual(railCard.panelFrom, fixture.snapshot.rect(for: railSlot))
        XCTAssertEqual(railCard.panelTo, fixture.snapshot.rect(for: railSlot))
        XCTAssertNotEqual(focus.panelStart, focus.panelEnd, "Entering still flies the focus panel")
        XCTAssertEqual(railCard.startAlpha, 0)
        XCTAssertNil(railCard.cellStart)
        XCTAssertEqual(railCard.fadeFraction,
                       TransitionSceneFactory.lightCrossfadeMS / CGFloat(scene.durationMS),
                       accuracy: 0.0001)
    }

    func testLightLevelReturningSnapsRailPanelsToOverviewWhileFocusStillFlies() throws {
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let other = HostFixtures.identity(1)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0)))
        let otherCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 1)))
        let slot = try XCTUnwrap(fixture.placement.slot(of: other))
        let railCell = try XCTUnwrap(fixture.snapshot.rect(for: slot))
        let token = TransitionToken(generation: 109)
        let plan = WorkbenchTransitionPlan(kind: .returningOverview,
                                           token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .returnOverview),
                                           identity: main,
                                           displayID: displayID,
                                           snapshot: fixture.snapshot,
                                           targetFrame: fixture.layout.mainRect,
                                           animationFrom: fixture.layout.mainRect,
                                           animationTo: mainCell.cellRect,
                                           railHandoffs: [RailHandoff(identity: other, slot: slot,
                                                                      from: railCell, to: otherCell.cellRect)],
                                           animationMS: 200,
                                           presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: fixture.layout.mainRect))
        var factory = baseFactory(imageRects: [main: mainCell.imageRect, other: otherCell.imageRect])
        factory.motionLevel = { .light }
        let scene = try XCTUnwrap(factory.returning(plan))
        XCTAssertEqual(scene.level, .light)
        XCTAssertFalse(scene.fadeOnly)
        XCTAssertEqual(scene.durationMS, 200)
        let focus = try XCTUnwrap(scene.focusCard)
        XCTAssertEqual(focus.start, fixture.layout.mainRect)
        XCTAssertEqual(focus.end, mainCell.imageRect)
        XCTAssertNotEqual(focus.start, focus.end)
        XCTAssertEqual(focus.panelFrom, fixture.layout.mainRect)
        XCTAssertEqual(focus.panelTo, mainCell.cellRect)
        XCTAssertNotEqual(focus.panelStart, focus.panelEnd)
        XCTAssertEqual(focus.fadeFraction, 1)
        let railCard = try XCTUnwrap(scene.cards.first { $0.identity == other })
        XCTAssertEqual(railCard.start, otherCell.imageRect)
        XCTAssertEqual(railCard.end, otherCell.imageRect)
        XCTAssertEqual(railCard.panelFrom, otherCell.cellRect)
        XCTAssertEqual(railCard.panelTo, otherCell.cellRect)
        XCTAssertNil(railCard.cellStart)
        XCTAssertEqual(railCard.startAlpha, 0)
        XCTAssertEqual(railCard.endAlpha, 1)
        XCTAssertEqual(railCard.fadeFraction, 0.7, accuracy: 0.0001, "140ms crossfade within a 200ms return")
        XCTAssertEqual(scene.hiddenRailIdentities, Set([main, other]))
    }

    /// Fade level shortens entry while manual swapping keeps its 16ms mask budget.
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
        XCTAssertEqual(swapScene.level, .fade)
        XCTAssertEqual(swapScene.durationMS, 16)
        XCTAssertEqual(swapScene.cards.map(\.identity), [intent.to])
        XCTAssertEqual(swapScene.focusCard?.startAlpha, 1)
        XCTAssertEqual(swapScene.focusCard?.endAlpha, 1)
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
        view.onTickStats = { reported.append(($0, $1)) }

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
        view.onTickStats = { _, stats in reported.append(stats) }

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
        view.stopNow() // Finalize only observed facts; offscreen submission is not presentation.
        let flight = try XCTUnwrap(facts.first)
        XCTAssertEqual(facts.count, 1, "一段飞行只报一次呈现事实")
        XCTAssertTrue(flight.anchoredAtRealInput, "给了输入锚点就必须标成真实输入锚定")
        XCTAssertEqual(flight.ticks, 16, "tick 次数按真正驱动到飞行的次数记：首个 tick + 15 个 16.7ms")
        XCTAssertLessThanOrEqual(flight.presentedFrames, flight.ticks + 1,
                                 "present 不可能多于渲染次数（play 的同步第一帧 + 每个 tick 一次）")
        XCTAssertGreaterThan(flight.submittedFrames, 0)
        guard flight.hasPresentedPixels else {
            XCTAssertNil(flight.firstPresentDelayMS, "Offscreen draws cannot fabricate screen presentation")
            return
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
        view.stopNow() // Finalize only observed facts; offscreen submission is not presentation.
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
        view.onTickStats = { _, _ in reported += 1 }

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

        defer { view.stopNow() }
        let grid = HostFixtures.layout(count: 2)
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let other = HostFixtures.identity(1)
        let mainCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 0)))
        let otherCell = try XCTUnwrap(grid.layout.card(at: SlotID(index: 1)))
        let slot = try XCTUnwrap(fixture.placement.slot(of: other))
        let mainTarget = fixture.layout.mainRect.insetBy(dx: 6, dy: 6)
        let token = TransitionToken(generation: 31)

        func build(reduceMotion: Bool) throws -> TransitionScene {
            let plan = WorkbenchTransitionPlan(kind: .enteringWorkbench,
                                               token: token,
                                               operationContext: HostPlanFacts.context(token: token, kind: .enterWorkbench),
                                               identity: main,
                                               displayID: displayID,
                                               snapshot: fixture.snapshot,
                                               targetFrame: mainTarget,
                                               animationFrom: mainCell.cellRect,
                                               animationTo: mainTarget,
                                               railHandoffs: [RailHandoff(identity: other, slot: slot,
                                                                          from: otherCell.cellRect,
                                                                          to: fixture.snapshot.rect(for: slot))],
                                               animationMS: fixture.layout.style.entryAnimationMS(reduceMotion: reduceMotion),
                                               presentation: fixture.presentation,
                                               placement: HostPlanFacts.placement(target: mainTarget))
            var factory = baseFactory(imageRects: [main: mainCell.imageRect, other: otherCell.imageRect])
            factory.reduceMotion = { reduceMotion }
            return try XCTUnwrap(factory.entering(plan))
        }

        let full = try build(reduceMotion: false)
        let reduced = try build(reduceMotion: true)
        XCTAssertEqual(full.kind, .entering, "Manual swapping is stationary even without Reduce Motion")
        XCTAssertEqual(full.cards.count, 2, "前提：两张卡片都要真的飞")
        XCTAssertTrue(full.cards.allSatisfy { $0.start != $0.end })
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
            let panel = try XCTUnwrap(view.presentedPanelRect(for: card.identity))
            let panelEnd = try XCTUnwrap(card.panelEnd)
            XCTAssertEqual(panel.minX, panelEnd.minX, accuracy: 0.001)
            XCTAssertEqual(panel.minY, panelEnd.minY, accuracy: 0.001)
            XCTAssertEqual(panel.width, panelEnd.width, accuracy: 0.001)
            XCTAssertEqual(panel.height, panelEnd.height, accuracy: 0.001)
            let alpha = try XCTUnwrap(view.presentedAlpha(for: card.identity))
            XCTAssertGreaterThan(alpha, 0, "淡化本身要看得见：\(card.identity) alpha=\(alpha)")
            XCTAssertLessThan(alpha, 1, "Entering still fades in under Reduce Motion")
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

    /// 面板圆角必须跟着布局 token 走：栏内卡片是 12pt，面板也必须是 12pt，否则飞行中会看出形状变化。
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

    /// 承载层在 `.panel` 下提交真实 Metal work，并且面板矩形单调逼近落点。
    /// 该 carrier 在离屏测试中运行，因此这里只验证提交与几何；屏幕呈现由 drawable callback 单独验证。
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
        // 面板必须生成真实 Metal submission；离屏层不能作为屏幕像素已呈现的证据。
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
        view.stopNow()
        let reported = try XCTUnwrap(facts.first, "到位后必须报告一次飞行事实")
        XCTAssertGreaterThan(reported.submittedFrames, 0, "The panel must submit real Metal work")
        if reported.presentedFrames == 0 {
            XCTAssertNil(reported.firstPresentDelayMS, "Offscreen submissions cannot count as displayed frames")
        }
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

    // MARK: - Focus glow (real CA layers, deterministic timeline and timer firing)

    @MainActor
    func testFocusGlowTracksOnlyThePanelOutlineWithFiniteColorAnimations() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        let scene = glowScene()
        let focus = try XCTUnwrap(scene.focusCard)
        let glow = view.focusGlow
        view.play(scene, sources: [:], startAt: 100)
        XCTAssertEqual(glow.phase, .playing)
        XCTAssertTrue(glow.isActive)
        XCTAssertTrue(glow.isAnimating)
        XCTAssertEqual(glow.cornerRadius, 12)
        XCTAssertEqual(view.layer?.sublayers?.filter { $0 === glow.container }.count, 1)
        XCTAssertEqual(glow.container.sublayers?.count, 2, "All cards share one focus-only pair of gradients")

        for progress in [0.0, 0.25, 0.5, 1.0] {
            view.advance(to: 100 + progress * 0.24)
            let panel = try XCTUnwrap(view.presentedPanelRect(for: focus.identity))
            let expected = CGRect(x: panel.minX - HostFixtures.offscreenOrigin.x,
                                  y: view.bounds.height + HostFixtures.offscreenOrigin.y - panel.maxY,
                                  width: panel.width, height: panel.height)
            let outline = try XCTUnwrap(glow.bounds)
            for (presented, planned) in [(outline, expected), (glow.container.frame, expected)] {
                XCTAssertEqual(presented.minX, planned.minX, accuracy: 0.001)
                XCTAssertEqual(presented.minY, planned.minY, accuracy: 0.001)
                XCTAssertEqual(presented.width, planned.width, accuracy: 0.001)
                XCTAssertEqual(presented.height, planned.height, accuracy: 0.001)
            }
            XCTAssertNotEqual(panel, view.presentedRect(for: focus.identity), "Use the cell, not its inset content")
        }
        view.advance(to: 101)
        XCTAssertEqual(glow.phase, .holding)
        let gradients = glow.container.sublayers?.compactMap { $0 as? CAGradientLayer } ?? []
        XCTAssertEqual(gradients.count, 2)
        for gradient in gradients {
            let mask = try XCTUnwrap(gradient.mask as? CAShapeLayer)
            XCTAssertEqual(gradient.type, .conic)
            XCTAssertNil(mask.fillColor, "No full-panel rainbow fill")
            XCTAssertTrue(CATransform3DIsIdentity(gradient.transform), "Never rotate a large clipped rectangle")
            XCTAssertEqual(gradient.animationKeys(), ["focus.colors"])
            let animation = try XCTUnwrap(gradient.animation(forKey: "focus.colors") as? CAKeyframeAnimation)
            XCTAssertEqual(animation.keyPath, "colors")
            XCTAssertEqual(animation.values?.count, 6)
            XCTAssertGreaterThan(animation.repeatDuration, 0)
            XCTAssertEqual(animation.repeatDuration, 2.84, accuracy: 0.0001)
            XCTAssertTrue(animation.repeatCount.isFinite)
            XCTAssertNil(mask.animationKeys())
        }
        let halo = try XCTUnwrap(gradients.first, "Broad bloom is added before the rim")
        let rim = try XCTUnwrap(gradients.last)
        let rimMask = try XCTUnwrap(rim.mask as? CAShapeLayer)
        let haloMask = try XCTUnwrap(halo.mask as? CAShapeLayer)
        XCTAssertEqual(rimMask.lineWidth, 1.5, accuracy: 0.0001, "The visible edge stays hairline")
        XCTAssertEqual(haloMask.lineWidth, 10, accuracy: 0.0001, "Bloom is a wide band, not a second edge")
        XCTAssertEqual(rim.opacity, 1, accuracy: 0.0001)
        XCTAssertEqual(halo.opacity, 0.55, accuracy: 0.0001, "A wide band must stay a soft bloom, not a fill")
        XCTAssertEqual(halo.frame, glow.container.bounds.insetBy(dx: -8, dy: -8),
                       "Bloom lives outside the panel so it reads as light leaving the edge")
        XCTAssertEqual(haloMask.path?.boundingBox, halo.bounds.insetBy(dx: 4, dy: 4),
                       "The wide stroke straddles the panel edge instead of covering the interior")
        XCTAssertEqual(rimMask.path?.boundingBox, rim.bounds.insetBy(dx: 0.75, dy: 0.75))
    }

    @MainActor
    func testHoldingGlowFlowsWithoutDisplayLinkOrMoreMetalDraws() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        view.play(glowScene(), sources: [:], startAt: 100)
        view.advance(to: 101)
        let glow = view.focusGlow
        let bounds = glow.bounds
        let draws = view.renderCount
        let presents = view.metalSubmissionCount
        XCTAssertTrue(view.isHolding)
        XCTAssertFalse(view.hasDisplayLink)
        XCTAssertTrue(glow.isAnimating)
        XCTAssertFalse(view.isHoldIndicatorVisible)
        let labelTimer = try XCTUnwrap(view.holdLabelTimer)
        labelTimer.fire()
        XCTAssertTrue(view.isHoldIndicatorVisible)
        for tick in 1...20 { view.advance(to: 101 + Double(tick) * 0.05) }
        XCTAssertEqual(glow.bounds, bounds)
        XCTAssertEqual(glow.phase, .holding)
        XCTAssertTrue(glow.isAnimating)
        XCTAssertEqual(view.renderCount, draws, "Waiting color flow must not call render")
        XCTAssertEqual(view.metalSubmissionCount, presents)
        XCTAssertFalse(view.hasDisplayLink)
    }

    @MainActor
    func testGlowFadeStopsAnimationsAndPreservesThePanelOpacity() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        view.play(glowScene(focusAlpha: 0.6), sources: [:], startAt: 100)
        let draws = view.renderCount
        XCTAssertEqual(view.focusGlow.container.opacity, 0.6, accuracy: 0.0001)
        view.beginFade()
        XCTAssertEqual(view.focusGlow.phase, .fading)
        XCTAssertFalse(view.focusGlow.isAnimating)
        view.focusGlow.fade(progress: 0.5)
        XCTAssertEqual(view.focusGlow.container.opacity, 0.3, accuracy: 0.0001)
        XCTAssertEqual(view.renderCount, draws)
        for layer in [view.focusGlow.container] + (view.focusGlow.container.sublayers ?? []) {
            XCTAssertNil(layer.animationKeys(), "Handoff removes every old CA animation")
        }
    }

    @MainActor
    func testReduceMotionGlowIsAStaticRimAtThePanelEndpoint() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        let scene = glowScene(fadeOnly: true)
        view.play(scene, sources: [:], startAt: 100)
        view.advance(to: 100.12)
        XCTAssertEqual(view.presentedPanelRect(for: HostFixtures.identity(0)), scene.focusCard?.panelTo)
        XCTAssertTrue(view.focusGlow.isActive)
        XCTAssertEqual(view.focusGlow.quality, .staticRim)
        XCTAssertFalse(view.focusGlow.isAnimating)
        let gradients = view.focusGlow.container.sublayers?.compactMap { $0 as? CAGradientLayer } ?? []
        let rim = try XCTUnwrap(gradients.last)
        let colors = NSArray(array: rim.colors ?? [])
        let outline = view.focusGlow.bounds
        XCTAssertTrue(try XCTUnwrap(gradients.first).isHidden, "Reduced Motion does not need the broad halo")
        view.advance(to: 101)
        XCTAssertEqual(view.focusGlow.phase, .holding)
        XCTAssertEqual(view.focusGlow.bounds, outline)
        XCTAssertEqual(NSArray(array: rim.colors ?? []), colors)
        XCTAssertFalse(view.focusGlow.isAnimating)
        for layer in [view.focusGlow.container] + gradients {
            XCTAssertNil(layer.animationKeys(), "No breathing, transforms or color loops under Reduce Motion")
        }
    }

    @MainActor
    func testLightLevelAndPowerOrThermalPressureUseOnlyAStaticRim() throws {
        let cases: [(MotionLevel, TransitionFocusGlow.Environment)] = [
            (.light, .init(lowPower: false, thermalState: .nominal)),
            (.fade, .init(lowPower: false, thermalState: .nominal)),
            (.full, .init(lowPower: true, thermalState: .nominal)),
            (.full, .init(lowPower: false, thermalState: .fair)),
            (.full, .init(lowPower: false, thermalState: .serious)),
            (.full, .init(lowPower: false, thermalState: .critical))
        ]
        let view = try makeGlowView()
        defer { view.stopNow() }
        for (level, environment) in cases {
            view.glowEnvironment = { environment }
            view.play(glowScene(level: level), sources: [:], startAt: 100)
            view.advance(to: 101)
            XCTAssertTrue(view.focusGlow.isActive)
            XCTAssertEqual(view.focusGlow.quality, .staticRim)
            XCTAssertFalse(view.focusGlow.isAnimating)
            XCTAssertEqual(view.focusGlow.container.sublayers?.filter { !$0.isHidden }.count, 1)
            XCTAssertFalse(view.hasDisplayLink)
            view.stopNow()
        }
    }

    @MainActor
    func testPressureChangeWhileHoldingStopsColorFlowWithoutRendering() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        view.play(glowScene(), sources: [:], startAt: 100)
        view.advance(to: 101)
        XCTAssertTrue(view.focusGlow.isAnimating)
        let draws = view.renderCount
        view.glowEnvironment = { .init(lowPower: true, thermalState: .nominal) }
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertEqual(view.focusGlow.quality, .staticRim)
        XCTAssertFalse(view.focusGlow.isAnimating)
        XCTAssertTrue(view.focusGlow.isActive)
        XCTAssertEqual(view.renderCount, draws)
        XCTAssertFalse(view.hasDisplayLink)
    }

    @MainActor
    func testInterruptedGlowDiscardsOldAnimationsLabelsAndTimers() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        for phase in [TransitionFocusGlow.Phase.playing, .holding, .fading] {
            view.play(glowScene(), sources: [:], startAt: 100)
            if phase == .playing {
                view.advance(to: 100.12)
            } else {
                view.advance(to: 101)
                try XCTUnwrap(view.holdLabelTimer).fire()
                XCTAssertTrue(view.isHoldIndicatorVisible)
            }
            let label = view.holdLabelTimer
            let holdDeadline = view.holdDeadlineTimer
            let sceneDeadline = view.sceneDeadlineTimer
            if phase == .fading { view.beginFade() }
            XCTAssertEqual(view.focusGlow.phase, phase)
            let priorOutline = try XCTUnwrap(view.focusGlow.bounds)
            let container = view.focusGlow.container
            let second = glowScene(generation: 402, level: .light)
            view.play(second, sources: [:], startAt: 200)
            XCTAssertTrue(view.focusGlow.container === container, "Reuse the single focus chrome")
            let resumed = try XCTUnwrap(view.focusGlow.bounds)
            for (resumedEdge, priorEdge) in [(resumed.minX, priorOutline.minX),
                                             (resumed.minY, priorOutline.minY),
                                             (resumed.width, priorOutline.width),
                                             (resumed.height, priorOutline.height)] {
                XCTAssertEqual(resumedEdge, priorEdge, accuracy: 0.001,
                               "Resume the displayed panel, not a stale planned start")
            }
            XCTAssertEqual(view.focusGlow.phase, .playing)
            XCTAssertFalse(view.focusGlow.isAnimating, "A new static scene must remove the old flow")
            XCTAssertFalse(view.isHoldIndicatorVisible)
            XCTAssertNil(view.holdLabelTimer)
            XCTAssertNil(view.holdDeadlineTimer)
            XCTAssertFalse(label?.isValid ?? false)
            XCTAssertFalse(holdDeadline?.isValid ?? false)
            XCTAssertFalse(sceneDeadline?.isValid ?? false)
            view.advance(to: 201)
            label?.fire()
            holdDeadline?.fire()
            sceneDeadline?.fire()
            XCTAssertTrue(view.isHolding, "Old deadlines cannot fade or finish a newer held scene")
            XCTAssertEqual(view.playingToken, second.token)
            XCTAssertFalse(view.isHoldIndicatorVisible, "An old label cannot appear during the new scene's grace period")
            view.stopNow()
        }
    }

    @MainActor
    func testGlowAndHoldChromeAreCleanedBySuccessFailureCancellationAndDisplayRemoval() throws {
        enum Ending { case confirm, retreat, cancel, removeDisplay }
        let metal = try HostFixtures.metalContext()
        for ending in [Ending.confirm, .retreat, .cancel, .removeDisplay] {
            let coordinator = ModeTransitionCoordinator(metal: metal)
            defer { coordinator.cancelAll() }
            coordinator.displayFacts = { _ in
                let rect = CGRect(origin: HostFixtures.offscreenOrigin, size: HostFixtures.offscreenSize)
                return .init(cgFrame: rect, appKitFrame: rect, scale: 2)
            }
            let scene = glowScene()
            coordinator.prewarm(displayID: scene.displayID)
            let window = try XCTUnwrap(coordinator.carrierWindow(for: scene.displayID))
            let view = window.carrierView
            view.glowEnvironment = { .init(lowPower: false, thermalState: .nominal) }
            coordinator.play(scene)
            view.advance(to: CACurrentMediaTime() + 1)
            try XCTUnwrap(view.holdLabelTimer).fire()
            XCTAssertTrue(view.focusGlow.isAnimating)
            let labelTimer = view.holdLabelTimer
            switch ending {
            case .confirm: coordinator.confirm(scene.token)
            case .retreat: coordinator.retreat(scene.token)
            case .cancel: coordinator.cancelAll()
            case .removeDisplay: coordinator.retireDisplays(keeping: [])
            }
            XCTAssertFalse(view.focusGlow.isAnimating)
            XCTAssertFalse(view.isHoldIndicatorVisible)
            XCTAssertNil(view.holdLabelTimer)
            XCTAssertNil(view.holdDeadlineTimer)
            XCTAssertFalse(labelTimer?.isValid ?? false)
            if !view.isIdle {
                XCTAssertEqual(view.focusGlow.phase, .fading)
                XCTAssertTrue(view.focusGlow.isActive, "Static edge fades with the panel, not ahead of it")
                view.advance(to: CACurrentMediaTime() + 1)
            }
            XCTAssertEqual(view.focusGlow.phase, .idle)
            XCTAssertNil(view.focusGlow.bounds)
            XCTAssertFalse(view.focusGlow.isActive)
            XCTAssertFalse(view.hasDisplayLink)
            XCTAssertNil(view.sceneDeadlineTimer)
            XCTAssertTrue(coordinator.isIdle)
        }
    }

    @MainActor
    func testGlowCleansUpOnHoldAndAbsoluteDeadlinesWithoutSleeping() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        view.play(glowScene(), sources: [:], startAt: 100)
        view.advance(to: 101)
        try XCTUnwrap(view.holdLabelTimer).fire()
        try XCTUnwrap(view.holdDeadlineTimer).fire()
        XCTAssertEqual(view.focusGlow.phase, .fading)
        XCTAssertFalse(view.focusGlow.isAnimating)
        XCTAssertFalse(view.isHoldIndicatorVisible)
        XCTAssertNil(view.holdLabelTimer)
        view.advance(to: CACurrentMediaTime() + 1)
        XCTAssertEqual(view.focusGlow.phase, .idle)
        XCTAssertFalse(view.focusGlow.isActive)

        for holding in [false, true] {
            view.play(glowScene(), sources: [:], startAt: 200)
            if holding {
                view.advance(to: 201)
                try XCTUnwrap(view.holdLabelTimer).fire()
            }
            try XCTUnwrap(view.sceneDeadlineTimer).fire()
            XCTAssertTrue(view.isIdle)
            XCTAssertEqual(view.focusGlow.phase, .idle)
            XCTAssertFalse(view.focusGlow.isAnimating)
            XCTAssertNil(view.focusGlow.bounds)
            XCTAssertFalse(view.isHoldIndicatorVisible)
            XCTAssertNil(view.holdLabelTimer)
            XCTAssertNil(view.holdDeadlineTimer)
            XCTAssertNil(view.sceneDeadlineTimer)
        }
    }

    @MainActor
    func testMovingToAnotherDisplayStopsTheOldGlowAndHoldTimer() throws {
        let coordinator = ModeTransitionCoordinator(metal: try HostFixtures.metalContext())
        defer { coordinator.cancelAll() }
        coordinator.displayFacts = { _ in
            let rect = CGRect(origin: HostFixtures.offscreenOrigin, size: HostFixtures.offscreenSize)
            return .init(cgFrame: rect, appKitFrame: rect, scale: 2)
        }
        let first = glowScene()
        coordinator.play(first)
        let old = try XCTUnwrap(coordinator.carrierWindow(for: first.displayID)?.carrierView)
        old.advance(to: CACurrentMediaTime() + 1)
        try XCTUnwrap(old.holdLabelTimer).fire()
        let label = old.holdLabelTimer
        let second = glowScene(generation: 403, onDisplay: first.displayID + 1)
        coordinator.play(second)
        XCTAssertTrue(old.isIdle)
        XCTAssertEqual(old.focusGlow.phase, .idle)
        XCTAssertFalse(old.focusGlow.isActive)
        XCTAssertFalse(old.focusGlow.isAnimating)
        XCTAssertFalse(old.isHoldIndicatorVisible)
        XCTAssertFalse(label?.isValid ?? false)
        XCTAssertNil(old.holdDeadlineTimer)
        XCTAssertNil(old.sceneDeadlineTimer)
        XCTAssertFalse(old.hasDisplayLink)
        XCTAssertEqual(coordinator.activeToken, second.token)
    }

    @MainActor
    func testNoFocusOrCapturedContentLeavesNoGlowAndInvisibleFocusDoesNotAnimate() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        for scene in [glowScene(hasFocus: false), glowScene(content: .captured), glowScene(focusAlpha: 0)] {
            view.play(scene, sources: [:], startAt: 100)
            view.advance(to: 101)
            XCTAssertFalse(view.focusGlow.isActive)
            XCTAssertFalse(view.focusGlow.isAnimating)
            XCTAssertNil(view.focusGlow.bounds)
        }
        view.stopNow()
        XCTAssertEqual(view.focusGlow.phase, .idle)
    }

    @MainActor
    func testFallbackSwapPanelFlowAndGlowUseTheDockedTarget() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        let fixture = HostWorkbench.fixture(count: 3)
        let to = HostFixtures.identity(1)
        let slot = try XCTUnwrap(fixture.placement.slot(of: to))
        let missing = RailSlotID(displayID: displayID, rail: .side, ordinal: 999)
        XCTAssertFalse(fixture.snapshot.isVisible(missing))
        let cases: [(MotionLevel, Bool, WorkbenchSelectionSource)] = [
            (.light, false, .rail(slot: slot)),
            (.fade, false, .rail(slot: slot)),
            (.full, true, .rail(slot: slot)),
            (.full, false, .accessibility),
            (.full, false, .rail(slot: missing)),
            (.light, false, .rail(slot: missing))
        ]
        for inset in [CGFloat(80), CGFloat(140)] {
            let target = fixture.layout.mainRect.insetBy(dx: inset, dy: inset / 2).offsetBy(dx: 20, dy: 10)
            XCTAssertNotEqual(target, fixture.layout.mainRect)
            for (level, reduced, source) in cases {
                let intent = HostPlanFacts.switchIntent(token: TransitionToken(generation: 501),
                                                       from: HostFixtures.identity(0), to: to, source: source,
                                                       placementRevision: 1, targetDisplayID: displayID)
                let plan = WorkbenchSwitchPlan(intent: intent, displayID: displayID, mainTargetFrame: target,
                                               restingTargetFrame: nil, restingSlot: slot,
                                               snapshot: fixture.snapshot, presentation: fixture.presentation,
                                               placement: HostPlanFacts.placement(target: target))
                var factory = baseFactory(imageRects: [:])
                factory.motionLevel = { level }
                factory.reduceMotion = { reduced }
                let scene = try XCTUnwrap(factory.swapping(plan))
                let card = try XCTUnwrap(scene.focusCard)
                XCTAssertEqual(card.start, target)
                XCTAssertEqual(card.end, target)
                XCTAssertEqual(card.panelStart, target)
                XCTAssertEqual(card.panelEnd, target)
                XCTAssertTrue(scene.isStationarySwap)
                view.play(scene, sources: [:], startAt: 100)
                let localTarget = CGRect(x: target.minX - HostFixtures.offscreenOrigin.x,
                                         y: view.bounds.height + HostFixtures.offscreenOrigin.y - target.maxY,
                                         width: target.width, height: target.height)
                for progress in [0.0, 0.5, 1.0] {
                    view.advance(to: 100 + progress * Double(scene.durationMS) / 1000)
                    XCTAssertLessThan(distance(try XCTUnwrap(view.presentedPanelRect(for: to)), to: target), 0.001)
                    XCTAssertEqual(view.focusGlow.bounds, localTarget)
                    XCTAssertEqual(view.focusGlow.container.frame, localTarget)
                    if level == .light, source == .rail(slot: slot) {
                        let flow = try XCTUnwrap(view.presentedFlow)
                        let cell = try XCTUnwrap(fixture.snapshot.rect(for: slot))
                        XCTAssertEqual(flow.rect, localTarget)
                        XCTAssertEqual(flow.axis.x, Float(target.midX - cell.midX), accuracy: 0.001)
                        XCTAssertEqual(flow.axis.y, Float(cell.midY - target.midY), accuracy: 0.001)
                    } else {
                        XCTAssertNil(view.presentedFlow)
                    }
                }
                view.stopNow()
            }
        }
    }

    @MainActor
    func testFadeOnlyMissingReturnTargetFadesOutInsteadOfDisappearing() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        let fixture = HostWorkbench.fixture(count: 2)
        let main = HostFixtures.identity(0)
        let token = TransitionToken(generation: 502)
        let start = fixture.layout.mainRect.insetBy(dx: 80, dy: 40)
        let plan = WorkbenchTransitionPlan(kind: .returningOverview, token: token,
                                           operationContext: HostPlanFacts.context(token: token, kind: .returnOverview),
                                           identity: main, displayID: displayID, snapshot: fixture.snapshot,
                                           targetFrame: start, animationFrom: start, animationTo: nil,
                                           railHandoffs: [], animationMS: 200, presentation: fixture.presentation,
                                           placement: HostPlanFacts.placement(target: start))
        var factory = baseFactory(imageRects: [:])
        factory.motionLevel = { .fade }
        let scene = try XCTUnwrap(factory.returning(plan))
        XCTAssertNil(scene.focusCard?.end)
        XCTAssertEqual(scene.focusCard?.endAlpha, 0)
        view.play(scene, sources: [:], startAt: 100)
        XCTAssertEqual(view.presentedAlpha(for: main), 1)
        XCTAssertEqual(view.presentedPanelRect(for: main), start)
        view.advance(to: 100 + Double(scene.durationMS) / 2000)
        XCTAssertEqual(try XCTUnwrap(view.presentedAlpha(for: main)), 0.125, accuracy: 0.0001)
        XCTAssertEqual(view.presentedPanelRect(for: main), start)
        view.advance(to: 101)
        XCTAssertEqual(view.presentedAlpha(for: main), 0)
        XCTAssertNil(view.presentedPanelRect(for: main))
        XCTAssertFalse(view.focusGlow.isActive)
    }

    @MainActor
    func testFadeOnlyPreservesAlphaEndpointsAndStationaryFadeIn() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        let identity = HostFixtures.identity(0)
        let start = CGRect(x: HostFixtures.offscreenOrigin.x + 20, y: 40, width: 200, height: 120)
        let end = start.offsetBy(dx: 300, dy: 180)
        let cases: [(CGFloat, CGFloat, CGFloat)] = [(0, 0.35, 0), (1, 1, 0), (0.8, 0.2, 0.8), (0, 0, 0)]
        for (startAlpha, endAlpha, initialAlpha) in cases {
            let card = TransitionScene.Card(identity: identity, start: start, end: end, cellStart: nil, cellEnd: nil,
                                           startAlpha: startAlpha, endAlpha: endAlpha, aspect: 2,
                                           hidesRailCard: false, isFocus: true)
            let scene = TransitionScene(kind: .entering, token: TransitionToken(generation: 503), displayID: displayID,
                                        backdrop: .transparent, cards: [card], durationMS: 1000, fadeOnly: true, level: .fade)
            view.play(scene, sources: [:], startAt: 100)
            XCTAssertEqual(try XCTUnwrap(view.presentedAlpha(for: identity)), initialAlpha, accuracy: 0.0001)
            view.advance(to: 100.5)
            XCTAssertEqual(try XCTUnwrap(view.presentedAlpha(for: identity)),
                           initialAlpha + (endAlpha - initialAlpha) * 0.875, accuracy: 0.0001)
            XCTAssertEqual(view.presentedRect(for: identity), end)
            view.advance(to: 101)
            XCTAssertEqual(try XCTUnwrap(view.presentedAlpha(for: identity)), endAlpha, accuracy: 0.0001)
            view.stopNow()
        }
    }

    @MainActor
    func testFlowRespectsCardAlphaAndSettlesContinuouslyIntoGlow() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        for alpha in [CGFloat(0), CGFloat(0.25), CGFloat(1)] {
            var scene = glowScene(focusAlpha: alpha)
            scene.flow = .standard
            view.play(scene, sources: [:], startAt: 100)
            for progress in [0.0, 0.25, 0.5, 0.999, 1.0] {
                view.advance(to: 100 + progress * 0.24)
                if alpha == 0 {
                    XCTAssertNil(view.presentedFlow)
                    XCTAssertFalse(view.focusGlow.isActive)
                    continue
                }
                let eased = TransitionTimeline.easeOutCubic(CGFloat(progress))
                let flow = try XCTUnwrap(view.presentedFlow)
                XCTAssertEqual(flow.intensity, Float(alpha * TransitionTimeline.flowIntensity(eased)), accuracy: 0.0001)
                XCTAssertEqual(view.focusGlow.container.opacity,
                               Float(alpha * (0.5 + 0.5 * TransitionTimeline.flowSettle(eased))), accuracy: 0.0001)
                XCTAssertEqual(view.focusGlow.bounds, flow.rect)
            }
            view.advance(to: 101)
            XCTAssertEqual(view.presentedFlow?.intensity ?? 0, 0, accuracy: 0.0001)
            XCTAssertFalse(view.hasDisplayLink)
            view.stopNow()
            XCTAssertNil(view.presentedFlow)
        }
    }

    @MainActor
    func testRepeatedBeginFadeKeepsTheOriginalDeadlineAndOpacityCurve() throws {
        let view = try makeGlowView()
        defer { view.stopNow() }
        let scene = glowScene(focusAlpha: 0.6)
        var finished: [TransitionToken] = []
        view.onFinished = { finished.append($0) }
        view.play(scene, sources: [:], startAt: 100)
        view.advance(to: 101)
        view.beginFade(durationMS: 1000, startAt: 200)
        let deadline = try XCTUnwrap(view.sceneDeadlineTimer)
        view.advance(to: 200.5)
        XCTAssertEqual(view.metalLayer.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(view.focusGlow.container.opacity, 0.3, accuracy: 0.0001)
        view.beginFade(durationMS: 2000, startAt: 200.5)
        XCTAssertTrue(view.sceneDeadlineTimer === deadline)
        XCTAssertTrue(deadline.isValid)
        view.advance(to: 200.75)
        XCTAssertEqual(view.metalLayer.opacity, 0.25, accuracy: 0.0001)
        XCTAssertEqual(view.focusGlow.container.opacity, 0.15, accuracy: 0.0001)
        view.advance(to: 201)
        XCTAssertTrue(view.isIdle)
        XCTAssertFalse(view.hasDisplayLink)
        XCTAssertEqual(finished, [scene.token])
        view.beginFade(startAt: 202)
        view.advance(to: 203)
        XCTAssertEqual(finished, [scene.token])
    }

    @MainActor
    func testStaleCompletionCannotHideAReusedCarrierWindow() throws {
        let coordinator = ModeTransitionCoordinator(metal: try HostFixtures.metalContext())
        defer { coordinator.cancelAll() }
        coordinator.displayFacts = { _ in
            let rect = CGRect(origin: HostFixtures.offscreenOrigin, size: HostFixtures.offscreenSize)
            return .init(cgFrame: rect, appKitFrame: rect, scale: 2)
        }
        var finished: [TransitionToken] = []
        var cancelled: [TransitionToken] = []
        coordinator.onSceneFinished = { finished.append($0) }
        coordinator.onSceneCancellationFinished = { cancelled.append($0) }
        let first = glowScene(generation: 504)
        coordinator.play(first)
        let window = try XCTUnwrap(coordinator.carrierWindow(for: displayID))
        let staleCompletion = try XCTUnwrap(window.carrierView.onFinished)
        let second = glowScene(generation: 505)
        coordinator.play(second)
        staleCompletion(first.token)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.level, .floating)
        XCTAssertEqual(coordinator.activeToken, second.token)
        XCTAssertEqual(window.carrierView.playingToken, second.token)
        XCTAssertTrue(window.carrierView.isPlaying)
        XCTAssertTrue(finished.isEmpty)
        XCTAssertTrue(cancelled.isEmpty)
        window.carrierView.beginFade(durationMS: 1000, startAt: 200)
        window.carrierView.advance(to: 201)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(coordinator.isIdle)
        XCTAssertEqual(finished, [second.token])
        XCTAssertTrue(cancelled.isEmpty)
    }

    @MainActor
    private func makeGlowView() throws -> TransitionCarrierView {
        let view = TransitionCarrierView(frame: CGRect(origin: .zero, size: HostFixtures.offscreenSize),
                                         metal: try HostFixtures.metalContext())
        view.configure(cgOrigin: HostFixtures.offscreenOrigin, scale: 2)
        view.glowEnvironment = { .init(lowPower: false, thermalState: .nominal) }
        view.layout()
        return view
    }

    private func glowScene(generation: UInt64 = 401, fadeOnly: Bool = false, level: MotionLevel = .full,
                           hasFocus: Bool = true, focusAlpha: CGFloat = 1,
                           content: TransitionScene.Content = .panel(.standard), onDisplay: UInt32? = nil) -> TransitionScene {
        let from = CGRect(x: HostFixtures.offscreenOrigin.x + 80, y: 120, width: 240, height: 160)
        let to = CGRect(x: HostFixtures.offscreenOrigin.x + 400, y: 180, width: 820, height: 560)
        let cards = (0..<3).map { index in
            TransitionScene.Card(identity: HostFixtures.identity(index),
                                 start: from.insetBy(dx: 10, dy: 16), end: to.insetBy(dx: 12, dy: 18),
                                 cellStart: from, cellEnd: to,
                                 startAlpha: index == 0 ? focusAlpha : 1, endAlpha: index == 0 ? focusAlpha : 1,
                                 aspect: 1.5, hidesRailCard: false, isFocus: hasFocus && index == 0,
                                 panelFrom: from, panelTo: to)
        }
        return TransitionScene(kind: .swapping, token: TransitionToken(generation: generation),
                               displayID: onDisplay ?? displayID, backdrop: .transparent, cards: cards,
                               durationMS: 240, fadeOnly: fadeOnly, level: level, content: content)
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
