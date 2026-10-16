import Foundation
import Testing
@testable import VistileCore

/// R05：一次运行的生命周期裁决。
///
/// 这些交错全靠"谁取得停止权"决定，旧实现没有这层裁决：stop 在 start 还挂起时对着 nil 空操作，
/// 于是被取消的那轮 SCStream 留在系统里，活跃流永远减不到零（方案 §7.2）。
@Suite("捕获生命周期裁决")
struct CaptureRunLifecycleTests {
    @Test("start 还挂起时 stop 只交给一条路径执行")
    func stopDuringPendingStartHasOneOwner() {
        var lifecycle = CaptureLifecycle()
        // #expect 会把接收者按不可变捕获，所以每步裁决都先落到局部值。
        let began = lifecycle.beginStart()
        #expect(began)
        // 取消立刻生效，但执行权属于 start 返回后的那条路径。
        #expect(lifecycle.requestStop() == .pendingStart)
        #expect(lifecycle.cancellationRequested)
        #expect(lifecycle.phase == .starting)
        #expect(lifecycle.startReturned() == .mustStop)
        #expect(lifecycle.phase == .stopping)
        // 别的路径不能再停第二次。
        #expect(lifecycle.requestStop() == .nobody)
        lifecycle.markStopped()
        #expect(lifecycle.isSettled)
    }

    @Test("stop 先到时这一轮根本不许启动")
    func stopBeforeStartBlocksLaunch() {
        var lifecycle = CaptureLifecycle()
        #expect(lifecycle.requestStop() == .thisCall)
        let began = lifecycle.beginStart()
        #expect(!began)
        #expect(lifecycle.phase == .stopping)
        // 启动路径对着不存在的底层实例收敛即可，不许进入 running。
        #expect(lifecycle.startReturned() == .alreadyHandled)
    }

    @Test("正常启动后的停止由本次调用负责")
    func stopAfterRunningIsOwnCall() {
        var lifecycle = CaptureLifecycle()
        let began = lifecycle.beginStart()
        #expect(began)
        #expect(lifecycle.startReturned() == .enterRunning)
        #expect(lifecycle.isRunning)
        #expect(lifecycle.requestStop() == .thisCall)
        #expect(lifecycle.requestStop() == .nobody)
        lifecycle.markStopped()
        #expect(lifecycle.phase == .stopped)
    }

    @Test("没收敛的一轮不许从管理表里忘掉")
    func unreapedPhasesStayVisible() {
        var idle = CaptureLifecycle()
        #expect(idle.needsReaping)
        let began = idle.beginStart()
        #expect(began)
        #expect(idle.needsReaping)
        #expect(idle.startReturned() == .enterRunning)
        #expect(!idle.needsReaping)
        #expect(idle.requestStop() == .thisCall)
        #expect(idle.needsReaping)
        idle.markStopped()
        #expect(!idle.needsReaping)
    }

    @Test("重复启动不会开出第二个底层实例")
    func secondStartRejected() {
        var lifecycle = CaptureLifecycle()
        let first = lifecycle.beginStart()
        #expect(first)
        let second = lifecycle.beginStart()
        #expect(!second)
    }

    @Test("runID 与轮次令牌各自独立前进")
    func runAndRoundTokensAreSeparate() {
        let a = CaptureRunID()
        let b = CaptureRunID()
        #expect(a != b)
        #expect(a.journalKey != b.journalKey)
        var round = CaptureRoundToken(0)
        #expect(round.next().value == 1)
        #expect(round.next().next() == CaptureRoundToken(2))
        round = CaptureRoundToken(UInt64.max)
        // 溢出不许 trap：轮次只用于比较相等，回绕后仍能区分新旧。
        #expect(round.next() == CaptureRoundToken(0))
    }
}

/// R05：模式计划。旧实现在 sync 里按"sessions 有没有"决定启动，
/// 于是降级来的轮询卡片下一次同步又被当成缺流的卡片重启直播流（方案 §7.5）。
@Suite("捕获模式计划")
struct CaptureModePlannerTests {
    private let softLimit = 12

    /// 没有流的目标要填档位默认值，协调层就是这么构造 CaptureDemand 的。
    private func fresh(_ count: Int) -> [CaptureDemand] {
        (1...count).map { demand($0, fps: 15, width: 1_280) }
    }

    private func ids(_ indices: [Int]) -> Set<WindowIdentity> {
        Set(indices.map { WindowIdentity.test(700, UInt32($0)) })
    }

    private func window(_ index: Int) -> WindowIdentity { WindowIdentity.test(700, UInt32(index)) }

    @Test("滞后线一定低于软上限，否则阈值边界会全停全启")
    func restoreLimitIsBelowSoftLimit() {
        let restore = CaptureModePlanner.restoreLimit(forSoftLimit: softLimit)
        #expect(restore < softLimit)
        #expect(restore >= 1)
        #expect(CaptureModePlanner.restoreLimit(forSoftLimit: 1) == 1)
        #expect(CaptureModePlanner.restoreLimit(forSoftLimit: 2) == 1)
    }

    @Test("直播名额只由想要直播的目标数决定，与当前已启动的流数无关")
    func liveSlotsComeFromDemandCountNotStreamCount() {
        let demands = fresh(5)
        // 降级后一条流都不剩：名额仍按 5 个目标算，不许因为"现在 0 条流"就全部重启。
        let empty = CaptureModePlanner.plan(demands: demands,
                                            liveStreams: [],
                                            polledIntervals: [:],
                                            streamSoftLimit: 2,
                                            thermal: .nominal)
        let existing = CaptureModePlanner.plan(demands: demands,
                                               liveStreams: ids([1, 2]),
                                               polledIntervals: [:],
                                               streamSoftLimit: 2,
                                               thermal: .nominal)
        #expect(empty.modes == existing.modes)
        #expect(existing.mode(for: window(3)) == .poll(intervalMilliseconds: 1_000))
        #expect(existing.streamsToStart.isEmpty)
        #expect(existing.streamsToStop.isEmpty)
        let liveCount = demands.filter { existing.mode(for: $0.identity) == .live }.count
        #expect(liveCount <= 2)
    }

    @Test("仍在预算内但没回到滞后线时，轮询卡片不许被重启成直播流")
    func polledCardIsNotRestartedWhileAboveRestoreLimit() {
        let polled = window(1)
        // 其余 9 个正直播：10 个目标低于软限 12，但高于滞后线 9。
        let plan = CaptureModePlanner.plan(demands: fresh(10),
                                           liveStreams: ids(Array(2...10)),
                                           polledIntervals: [polled: 1_000],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(!plan.overBudget)
        #expect(plan.mode(for: polled) == .poll(intervalMilliseconds: 1_000))
        #expect(plan.streamsToStart.isEmpty)
        #expect(plan.streamsToStop.isEmpty)
    }

    @Test("回到滞后线以下才恢复实时")
    func pollingRestoresOnlyBelowHysteresis() {
        let polled = window(1)
        // 9 个目标正好等于滞后线：可以恢复。
        let plan = CaptureModePlanner.plan(demands: fresh(9),
                                           liveStreams: ids(Array(2...9)),
                                           polledIntervals: [polled: 1_000],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(plan.mode(for: polled) == .live)
        #expect(plan.actions[polled] == .keep)
        #expect(plan.streamsToStart == [polled])
        #expect(plan.streamsToStop.isEmpty)
    }

    @Test("超预算时已轮询的卡片保持原间隔，不逐轮加深")
    func existingPollingIntervalIsStable() {
        let inside = window(1)
        let outside = window(13)
        let plan = CaptureModePlanner.plan(demands: (1...13).map { demand($0, fps: 3, width: 400) },
                                           liveStreams: [],
                                           polledIntervals: [inside: 4_000, outside: 4_000],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(plan.overBudget)
        // 名额内但仍高于滞后线：保持 4000，不许再乘一级阶梯。
        #expect(plan.mode(for: inside) == .poll(intervalMilliseconds: 4_000))
        #expect(plan.actions[inside] == .poll(intervalMilliseconds: 4_000))
        // 超出名额：同样保持已有间隔。
        #expect(plan.mode(for: outside) == .poll(intervalMilliseconds: 4_000))
    }

    @Test("已经不再需要的直播流必须停掉")
    func streamsWithoutDemandAreStopped() {
        let gone = WindowIdentity.test(700, 9)
        let kept = window(1)
        let plan = CaptureModePlanner.plan(demands: [demand(1)],
                                           liveStreams: [gone],
                                           polledIntervals: [:],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(plan.streamsToStop == [gone])
        #expect(plan.mode(for: kept) == .live)
    }

    @Test("最小化只暂停：不占流也不轮询，但不算失败")
    func minimizedWindowPausesWithoutStream() {
        let identity = window(1)
        let plan = CaptureModePlanner.plan(demands: [demand(1, isMinimized: true)],
                                           liveStreams: [identity],
                                           polledIntervals: [:],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(plan.mode(for: identity) == .paused)
        #expect(plan.mode(for: identity).displayPhase == .idle)
        #expect(plan.streamsToStop == [identity])
        #expect(plan.streamsToStart.isEmpty)
    }

    @Test("最小化目标不占直播名额")
    func minimizedTargetsAreNotCountedAgainstBudget() {
        // 2 个可直播 + 10 个最小化：真正要流的只有 2 个，不该按 12 个算超预算。
        var demands = fresh(2)
        demands += (3...12).map { demand($0, isMinimized: true) }
        let plan = CaptureModePlanner.plan(demands: demands,
                                           liveStreams: [],
                                           polledIntervals: [:],
                                           streamSoftLimit: 2,
                                           thermal: .nominal)
        #expect(!plan.overBudget)
        #expect(plan.streamsToStart == [window(1), window(2)])
    }

    @Test("不可捕获的目标同样不启动")
    func uncapturableTargetPauses() {
        let identity = window(1)
        let plan = CaptureModePlanner.plan(demands: [demand(1, isCapturable: false)],
                                           liveStreams: [],
                                           polledIntervals: [:],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(plan.mode(for: identity) == .paused)
        #expect(plan.streamsToStart.isEmpty)
    }

    @Test("降级顺序稳定：优先窗口最后降级，同一输入两次结果一致")
    func degradationOrderIsStableAndPriorityLast() {
        // 软限 2、4 个目标全部已降到 3fps/400 宽；优先窗口是 3 号。
        let demands = [demand(1, fps: 3, width: 400),
                       demand(2, fps: 3, width: 400),
                       demand(3, isPriority: true, fps: 3, width: 400),
                       demand(4, fps: 3, width: 400)]
        let first = CaptureModePlanner.plan(demands: demands,
                                            liveStreams: [],
                                            polledIntervals: [:],
                                            streamSoftLimit: 2,
                                            thermal: .nominal)
        let second = CaptureModePlanner.plan(demands: Array(demands.reversed()),
                                             liveStreams: [],
                                             polledIntervals: [:],
                                             streamSoftLimit: 2,
                                             thermal: .nominal)
        #expect(first.modes == second.modes)
        #expect(first.streamsToStart == second.streamsToStart)
        // 优先窗口先拿名额并最后降级；其余即使进了名额也只能轮到轮询。
        #expect(first.mode(for: window(3)) == .live)
        #expect(first.actions[window(3)] == .keep)
        #expect(first.mode(for: window(1)) == .poll(intervalMilliseconds: 1_000))
        #expect(first.mode(for: window(2)) == .poll(intervalMilliseconds: 1_000))
        #expect(first.streamsToStart == [window(3)])
    }

    @Test("热状态危急时即使目标很少也进入预算处理")
    func hotThermalAloneTriggersBudget() {
        let identity = window(1)
        let plan = CaptureModePlanner.plan(demands: [demand(1, fps: 3, width: 400)],
                                           liveStreams: [identity],
                                           polledIntervals: [:],
                                           streamSoftLimit: softLimit,
                                           thermal: .critical)
        #expect(plan.overBudget)
        #expect(plan.mode(for: identity) == .poll(intervalMilliseconds: 1_000))
        #expect(plan.streamsToStop == [identity])
    }

    @Test("未超预算时不动已有流")
    func withinBudgetKeepsEverything() {
        let a = window(1)
        let b = window(2)
        let plan = CaptureModePlanner.plan(demands: [demand(1), demand(2)],
                                           liveStreams: [a, b],
                                           polledIntervals: [:],
                                           streamSoftLimit: softLimit,
                                           thermal: .nominal)
        #expect(plan.streamsToStart.isEmpty)
        #expect(plan.streamsToStop.isEmpty)
        #expect(plan.mode(for: a) == .live)
        #expect(plan.actions[a] == .keep)
    }

    @Test("降级动作会改直播流配置，但仍然是直播")
    func lowerActionsStayLive() {
        let kept = window(1)
        let dropped = window(2)
        let plan = CaptureModePlanner.plan(demands: fresh(2),
                                           liveStreams: [kept, dropped],
                                           polledIntervals: [:],
                                           streamSoftLimit: 1,
                                           thermal: .nominal)
        #expect(plan.overBudget)
        #expect(plan.actions[kept] == .lowerFPS(10))
        #expect(plan.mode(for: kept) == .live)
        #expect(plan.mode(for: dropped) == .poll(intervalMilliseconds: 1_000))
        #expect(plan.streamsToStart.isEmpty)
        #expect(plan.streamsToStop == [dropped])
    }

    @Test("兑现一轮计划后下一轮不再改动：直播与轮询都不乒乓")
    func downgradedPlanIsStableAcrossSyncs() {
        let demands = fresh(5)
        let first = CaptureModePlanner.plan(demands: demands,
                                            liveStreams: [],
                                            polledIntervals: [:],
                                            streamSoftLimit: 2,
                                            thermal: .nominal)
        let liveFirst = demands.filter { first.mode(for: $0.identity) == .live }.map(\.identity)
        #expect(liveFirst.count == 2)
        #expect(first.streamsToStart == liveFirst)

        // 协调层兑现这轮：启动这 2 条流，其余记下轮询间隔。
        var intervals: [WindowIdentity: Int] = [:]
        for identity in demands.map(\.identity) where first.mode(for: identity) != .live {
            if case let .poll(ms) = first.mode(for: identity) { intervals[identity] = ms }
        }
        let second = CaptureModePlanner.plan(demands: demands,
                                             liveStreams: Set(liveFirst),
                                             polledIntervals: intervals,
                                             streamSoftLimit: 2,
                                             thermal: .nominal)
        #expect(second.modes == first.modes)
        #expect(second.actions == first.actions)
        #expect(second.streamsToStart.isEmpty)
        #expect(second.streamsToStop.isEmpty)

        // 第三轮仍然一样：旧实现在这里会因为"看见 0 条流"而全停全启。
        let third = CaptureModePlanner.plan(demands: demands,
                                            liveStreams: Set(liveFirst),
                                            polledIntervals: intervals,
                                            streamSoftLimit: 2,
                                            thermal: .nominal)
        #expect(third.modes == first.modes)
        #expect(third.streamsToStart.isEmpty)
        #expect(third.streamsToStop.isEmpty)
    }

    private func demand(_ index: Int,
                        isPriority: Bool = false,
                        isMinimized: Bool = false,
                        isCapturable: Bool = true,
                        fps: Int = 15,
                        width: Int = 320) -> CaptureDemand {
        CaptureDemand(identity: window(index),
                      isCapturable: isCapturable,
                      isMinimized: isMinimized,
                      isPriority: isPriority,
                      currentFPS: fps,
                      currentPixelWidth: width)
    }
}
