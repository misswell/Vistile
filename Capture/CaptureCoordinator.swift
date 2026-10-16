import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VistileCore

/// 捕获层向上汇报的事实事件；由状态机决定卡片显示什么，捕获层自己不改状态。
enum CaptureFact: Hashable, Sendable {
    case started(WindowIdentity, CaptureRunID)
    case firstFrame(WindowIdentity, Date)
    case failed(WindowIdentity, String)
    case downgraded(WindowIdentity, intervalMilliseconds: Int)
    case budgetApplied(Int)
}

/// 一个待捕获目标：卡片几何与源窗口尺寸决定输出像素，不常驻原生全分辨率。
struct CaptureTarget: Hashable {
    let identity: WindowIdentity
    let cellWidth: CGFloat
    let backingScale: CGFloat
    let sourceSize: CGSize
    let isPriority: Bool
    let isMinimized: Bool
    let isCapturable: Bool

    init(record: WindowRecord, cellWidth: CGFloat, backingScale: CGFloat, isPriority: Bool) {
        identity = record.identity
        self.cellWidth = cellWidth
        self.backingScale = backingScale
        sourceSize = CGSize(width: record.frame.width, height: record.frame.height)
        self.isPriority = isPriority
        isMinimized = record.isMinimized || record.capture == .pausedMinimized
        switch record.capture {
        case .notCapturable, .permissionMissing: isCapturable = false
        default: isCapturable = record.restriction != .protectedContent
        }
    }
}

/// 一次运行的创建请求（方案 §15.1）。
/// 生产用真实 ScreenCaptureKit 会话，宿主测试注入假驱动，
/// 才能确定复现"start 还挂着时 stop 到达""旧回调晚到"这类交错，而不是靠随机 sleep。
struct CaptureRunRequest {
    let identity: WindowIdentity
    let runID: CaptureRunID
    let generation: UInt64
    let config: StreamConfig
    let sourceSizeInPoints: CGSize?
    let mailbox: FrameMailbox<MetalFrame>
    /// 目录里当前的可共享窗口；nil 表示这一轮不该启动。
    let window: SCWindow?
}

/// 捕获流生命周期与并发控制（方案 §7、§9）。
///
/// 长期并发流上限、降级阈值都必须由实测记录校准，这里只是保守起点。
/// 会话表、轮询表、信箱表只在主 Actor 上增删；帧回调在 sampleQueue 上落进信箱后不回读目录。
@MainActor
final class CaptureCoordinator {
    var onFact: ((CaptureFact) -> Void)?

    /// 至多 2 个启动操作同时进行，避免几十个流同一时间申请资源。
    let maxConcurrentStarts = 2
    /// 实测前的保守软上限；Performance 文档会用真实数据替换。
    var streamSoftLimit: Int = 12

    private let metal: MetalContext
    private let catalog: WindowCatalog
    private let makeRun: (CaptureRunRequest) -> CaptureRunning

    /// 一次运行的登记项。收敛前不会从管理表里消失（方案 §7.2 第四条）。
    private final class Entry {
        let identity: WindowIdentity
        let runID: CaptureRunID
        let round: CaptureRoundToken
        let run: CaptureRunning
        var startTask: Task<Bool, Never>?
        var stopTask: Task<Void, Never>?

        init(identity: WindowIdentity, runID: CaptureRunID, round: CaptureRoundToken, run: CaptureRunning) {
            self.identity = identity
            self.runID = runID
            self.round = round
            self.run = run
        }

        /// 先让在途的启动收敛，再由这一条路径执行停止（方案 §7.2 第四条）。
        func stopAfterStart() async {
            if let startTask { _ = await startTask.value }
            await run.stop()
        }

        /// 等待这一轮彻底结束。stopTask 自己调用它会造成死锁，所以只等已有的那条。
        func awaitConvergence() async {
            if let stopTask { await stopTask.value; return }
            await stopAfterStart()
        }
    }

    private struct PendingStart {
        let identity: WindowIdentity
        let runID: CaptureRunID
        let round: CaptureRoundToken
    }
    private var runs: [WindowIdentity: Entry] = [:]
    private var reaping: [CaptureRunID: Entry] = [:]
    /// 每个身份最近登记的一轮。判据用它而不是 `runs`：启动失败时条目先被清掉，
    /// 若按"还在表里"过滤，真正的失败会被当成晚到回调一起吞掉（方案 §7.2 第五条）。
    private var latestRun: [WindowIdentity: CaptureRunID] = [:]
    private var mailboxes: [WindowIdentity: FrameMailbox<MetalFrame>] = [:]
    private var inFlightStarts: Set<CaptureRunID> = []
    private var pendingStarts: [PendingStart] = []
    private var polledIntervals: [WindowIdentity: Int] = [:]
    private var pollTimers: [WindowIdentity: Timer] = [:]
    private var pollTasks: [WindowIdentity: Task<Void, Never>] = [:]
    private var pollInFlight: Set<WindowIdentity> = []
    private var appliedAction: [WindowIdentity: BudgetAction] = [:]
    private var lastConfigurationChange: [WindowIdentity: Date] = [:]
    private var desiredTargets: [WindowIdentity: CaptureTarget] = [:]
    private var currentTier: CaptureTier = .balanced
    /// 本轮代次：stopAll 立刻推进，旧 run 的一切回调从此不被消费（方案 §7.3）。
    private var round = CaptureRoundToken(0)
    private let sampleQueue: DispatchQueue
    private let singleFrame: @MainActor (WindowIdentity, StreamConfig) async -> SingleFrameOutcome

    var thermalState: ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        default: return .critical
        }
    }

    convenience init(metal: MetalContext, catalog: WindowCatalog) {
        let queue = DispatchQueue(label: "com.misswell.Vistile.capture.frames.shared",
                                  qos: .userInitiated,
                                  autoreleaseFrequency: .workItem)
        self.init(metal: metal,
                  catalog: catalog,
                  sampleQueue: queue,
                  runFactory: { request in
                      guard let window = request.window else { return FailedCaptureRun(request: request) }
                      return WindowCaptureSession(identity: request.identity,
                                                  runID: request.runID,
                                                  generation: request.generation,
                                                  window: window,
                                                  sourceSizeInPoints: request.sourceSizeInPoints,
                                                  config: request.config,
                                                  mailbox: request.mailbox,
                                                  metal: metal,
                                                  sampleQueue: queue)
                  }, singleFrame: { identity, config in
                      guard let window = catalog.scWindow(for: identity) else { return .unavailable }
                      let streamConfig = SCStreamConfiguration()
                      streamConfig.apply(config)
                      let filter = SCContentFilter(desktopIndependentWindow: window)
                      guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                                    configuration: streamConfig) else {
                          return .failed
                      }
                      return .image(image)
                  })
    }

    /// 宿主测试注入点：假驱动 + 假信箱，交错完全由测试控制。
    init(metal: MetalContext,
         catalog: WindowCatalog,
         sampleQueue: DispatchQueue,
         runFactory: @escaping (CaptureRunRequest) -> CaptureRunning,
         singleFrame: @escaping (WindowIdentity, StreamConfig) async -> SingleFrameOutcome) {
        self.metal = metal
        self.catalog = catalog
        self.sampleQueue = sampleQueue
        self.makeRun = runFactory
        self.singleFrame = singleFrame
    }

    // MARK: - 对外事实

    /// "已经有运行/启动中的一轮"：并发上限按它算，不能按已经 running 的算。
    var activeStreamCount: Int { runs.count }
    var queuedStartCount: Int { pendingStarts.count }
    var polledCount: Int { pollTimers.count }
    /// 逻辑已失效：不再有待启动、没有存活的一轮。
    var isLogicallyIdle: Bool { runs.isEmpty && pendingStarts.isEmpty && reaping.isEmpty }
    var liveCount: Int { runs.values.filter { $0.run.phase == .running || $0.run.phase == .starting }.count }

    func mailbox(for identity: WindowIdentity) -> FrameMailbox<MetalFrame> {
        if let existing = mailboxes[identity] { return existing }
        let created = FrameMailbox<MetalFrame>()
        mailboxes[identity] = created
        return created
    }

    func allMailboxes() -> [(identity: WindowIdentity, mailbox: FrameMailbox<MetalFrame>)] {
        mailboxes.map { ($0.key, $0.value) }
    }

    func mode(for identity: WindowIdentity) -> DesiredCaptureMode {
        if let interval = polledIntervals[identity] { return .poll(intervalMilliseconds: interval) }
        if runs[identity] != nil { return .live }
        return desiredTargets[identity] == nil ? .paused
            : (desiredTargets[identity]!.isCapturable && !desiredTargets[identity]!.isMinimized ? .live : .paused)
    }

    func frameCounts(for identity: WindowIdentity) -> CaptureFrameCounts {
        if let entry = runs[identity] { return entry.run.frameCounts }
        if let entry = reaping.values.first(where: { $0.identity == identity }) { return entry.run.frameCounts }
        return CaptureFrameCounts()
    }

    /// 等待所有在途启动/停止收敛。只给测试与退出路径用，主线程不阻塞等待。
    ///
    /// 这里给出两个事实：调用返回即"逻辑已失效"（代次作废、旧回调不再被消费），
    /// `waitForQuiet()` 完成才是"底层已停止"（方案 §7.3）。
    func waitForQuiet() async {
        while !reaping.isEmpty || !inFlightStarts.isEmpty {
            let entries = Array(reaping.values)
            if entries.isEmpty {
                await Task.yield()
                continue
            }
            await withTaskGroup(of: Void.self) { group in
                for entry in entries { group.addTask { await entry.awaitConvergence() } }
            }
        }
    }

    // MARK: - 同步目标集合

    /// 先决定模式，再执行启动/重配置/停止（方案 §7.5）。
    func sync(targets: [CaptureTarget], tier: CaptureTier, isAnimating: Bool) {
        currentTier = tier
        desiredTargets = Dictionary(targets.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let roundToken = round

        // 已彻底消失的窗口：释放信箱与纹理；最小化只是暂停，保留最后一帧。
        for identity in Array(mailboxes.keys) where desiredTargets[identity] == nil && runs[identity] == nil {
            releaseWindow(identity)
        }

        let liveStreams = Set(runs.keys)
        let demands = targets.map { target in
            CaptureDemand(identity: target.identity,
                          isCapturable: target.isCapturable,
                          isMinimized: target.isMinimized,
                          isPriority: target.isPriority,
                          currentFPS: runs[target.identity]?.run.config.fps ?? tier.targetFPS,
                          currentPixelWidth: runs[target.identity]?.run.config.pixelWidth ?? tier.maxPixelWidth)
        }
        let plan = CaptureModePlanner.plan(demands: demands,
                                           liveStreams: liveStreams,
                                           polledIntervals: polledIntervals,
                                           streamSoftLimit: streamSoftLimit,
                                           thermal: thermalState)

        // 1. 停：不再需要直播流的一律收敛，先让出并发额度。
        for identity in plan.streamsToStop where runs[identity] != nil {
            terminate(identity: identity)
        }
        // 2. 留：模式没变的存量只做配置对齐，不重建流。
        for target in targets where plan.mode(for: target.identity) == .live && runs[target.identity] != nil {
            appliedAction[target.identity] = plan.actions[target.identity] ?? .keep
            reconfigureIfNeeded(target, tier: tier, isAnimating: isAnimating)
        }
        // 3. 轮询：只在计划要求的间隔上刷新，绝不再顺手启动直播流。
        reconcilePolling(plan: plan, round: roundToken)
        // 4. 起：按并发上限排队，过期项直接跳过。
        pendingStarts = plan.streamsToStart.map {
            PendingStart(identity: $0, runID: CaptureRunID(), round: roundToken)
        }
        drainPendingStarts()
        if plan.overBudget {
            let degraded = plan.actions.values.filter { if case .keep = $0 { return false }; return true }.count
            if degraded > 0 { onFact?(.budgetApplied(degraded)) }
        }
    }

    private func reconfigureIfNeeded(_ target: CaptureTarget, tier: CaptureTier, isAnimating: Bool) {
        guard let entry = runs[target.identity] else { return }
        let candidate = config(for: target, tier: tier)
        let elapsed = Date().timeIntervalSince(lastConfigurationChange[target.identity] ?? .distantPast)
        guard candidate != entry.run.config, !isAnimating, elapsed >= 0.25 else { return }
        lastConfigurationChange[target.identity] = Date()
        let run = entry.run
        let identity = target.identity
        Task { [weak self] in
            let ok = await run.update(configuration: candidate)
            guard let self, !ok, let message = run.lastError else { return }
            self.deliver(identity: identity, runID: entry.runID) { self.onFact?(.failed(identity, message)) }
        }
    }

    private func config(for target: CaptureTarget, tier: CaptureTier) -> StreamConfig {
        let base = StreamConfig.build(cellWidth: target.cellWidth,
                                      backingScale: target.backingScale,
                                      sourceSize: target.sourceSize,
                                      tier: tier)
        guard let action = appliedAction[target.identity] else { return base }
        switch action {
        case .keep, .poll:
            return base
        case let .lowerFPS(fps):
            return StreamConfig(pixelWidth: base.pixelWidth,
                                pixelHeight: base.pixelHeight,
                                fps: fps,
                                queueDepth: base.queueDepth,
                                capturesAudio: false,
                                showsCursor: false)
        case let .lowerOutputWidth(width):
            return StreamConfig.build(cellWidth: target.cellWidth,
                                      backingScale: target.backingScale,
                                      sourceSize: target.sourceSize,
                                      tier: tier,
                                      fpsOverride: base.fps,
                                      widthCapOverride: width)
        }
    }

    // MARK: - 启动 / 收敛

    /// 循环排空队列：跳过已失效、已启动、被移除的条目，直到达到并发上限或队列为空（方案 §7.3）。
    private func drainPendingStarts() {
        while inFlightStarts.count < maxConcurrentStarts, !pendingStarts.isEmpty {
            let next = pendingStarts.removeFirst()
            guard next.round == round else { continue }
            guard runs[next.identity] == nil, inFlightStarts.insert(next.runID).inserted else { continue }
            guard let target = desiredTargets[next.identity], target.isCapturable, !target.isMinimized else {
                inFlightStarts.remove(next.runID)
                continue
            }
            launch(next, target: target)
        }
    }

    private func launch(_ pending: PendingStart, target: CaptureTarget) {
        let mailbox = self.mailbox(for: target.identity)
        // 代次由管理者在切换运行时同步分配；旧 session 无权推进（方案 §7.4）。
        let generation = mailbox.beginRun()
        let request = CaptureRunRequest(identity: target.identity,
                                       runID: pending.runID,
                                       generation: generation,
                                       config: config(for: target, tier: currentTier),
                                       sourceSizeInPoints: target.sourceSize,
                                       mailbox: mailbox,
                                       window: catalog.scWindow(for: target.identity))
        let run = makeRun(request)
        let entry = Entry(identity: target.identity, runID: pending.runID, round: pending.round, run: run)
        runs[target.identity] = entry
        // 新的一轮登记后，旧回调立刻失去对外发事实的资格（方案 §7.2 第五条）。
        latestRun[target.identity] = pending.runID
        lastConfigurationChange[target.identity] = Date()
        wireCallbacks(of: run, entry: entry)
        onFact?(.started(target.identity, pending.runID))
        entry.startTask = Task { [weak self] in
            let ok = await run.start()
            guard let self else { return ok }
            self.inFlightStarts.remove(pending.runID)
            // 失败事实由 onFailure 回调给，这里不再补发一次，避免同一轮报两条（方案 §7.2 最后一条）。
            if !ok { self.retire(entry) }
            self.drainPendingStarts()
            return ok
        }
    }

    /// 回调只认自己那一轮：旧失败、旧首帧、旧停止一律不影响新 run（方案 §7.2 第五条）。
    /// 会话在 sampleQueue 上触发它们，回到主 Actor 后才能碰管理表。
    private func wireCallbacks(of run: CaptureRunning, entry: Entry) {
        let identity = entry.identity
        let roundToken = entry.round
        run.onFirstFrame = { [weak self] runID, date in
            guard runID == entry.runID else { return }
            DispatchQueue.main.async {
                guard let self, self.round == roundToken else { return }
                self.deliver(identity: identity, runID: runID) { self.onFact?(.firstFrame(identity, date)) }
            }
        }
        run.onFailure = { [weak self] runID, message in
            guard runID == entry.runID else { return }
            DispatchQueue.main.async {
                guard let self, self.round == roundToken else { return }
                self.deliver(identity: identity, runID: runID) {
                    self.terminate(identity: identity)
                    self.onFact?(.failed(identity, message))
                    self.drainPendingStarts()
                }
            }
        }
        run.onFramePublished = { [weak self] runID, _ in
            guard runID == entry.runID else { return }
            DispatchQueue.main.async {
                guard let self, self.round == roundToken else { return }
                self.onFrame?(identity)
            }
        }
    }

    /// 只有该身份"最近登记的那一轮"才能对外发事实。
    /// 判据不能是"还在 runs 表里"：启动失败时退役先于回调到达，那样真正的失败会被吞掉。
    private func deliver(identity: WindowIdentity, runID: CaptureRunID, _ emit: () -> Void) {
        guard latestRun[identity] == runID else { return }
        emit()
    }

    /// 启动失败或提前结束：从管理表移除但保留收敛权。
    private func retire(_ entry: Entry) {
        if runs[entry.identity]?.runID == entry.runID { runs.removeValue(forKey: entry.identity) }
        appliedAction.removeValue(forKey: entry.identity)
        lastConfigurationChange.removeValue(forKey: entry.identity)
        drainPendingStarts()
    }

    /// 从集合移除之前先标为 stopping，并把这一轮放进收敛表（方案 §7.2 第四条）。
    private func terminate(identity: WindowIdentity) {
        guard let entry = runs.removeValue(forKey: identity) else { return }
        reaping[entry.runID] = entry
        stopPolling(identity)
        polledIntervals.removeValue(forKey: identity)
        appliedAction.removeValue(forKey: identity)
        lastConfigurationChange.removeValue(forKey: identity)
        entry.stopTask = Task { [weak self] in
            await entry.stopAfterStart()
            guard let self else { return }
            self.reaping.removeValue(forKey: entry.runID)
            self.inFlightStarts.remove(entry.runID)
            self.drainPendingStarts()
        }
    }

    /// hidden、锁屏、睡眠、切换用户后停流；releasing 时连信箱与纹理一起释放（方案 §9.7）。
    /// 调用返回即"逻辑已失效"，底层是否停止由 `waitForQuiet()` 给结论。
    func stopAll(releasingMailboxes: Bool = false) {
        round = round.next()
        desiredTargets.removeAll()
        pendingStarts.removeAll()
        inFlightStarts.removeAll()
        for identity in Array(runs.keys) { terminate(identity: identity) }
        for identity in Array(pollTimers.keys) { stopPolling(identity) }
        if releasingMailboxes {
            for identity in Array(mailboxes.keys) { mailboxes[identity]?.release() }
            mailboxes.removeAll()
            metal.purgeTextureCache()
        }
    }

    /// 确认销毁的窗口：释放信箱并通知渲染层丢弃纹理。
    private func releaseWindow(_ identity: WindowIdentity) {
        terminate(identity: identity)
        stopPolling(identity)
        polledIntervals.removeValue(forKey: identity)
        appliedAction.removeValue(forKey: identity)
        lastConfigurationChange.removeValue(forKey: identity)
        mailboxes.removeValue(forKey: identity)?.release()
        latestRun.removeValue(forKey: identity)
        onWindowReleased?(identity)
    }

    var onFrame: ((WindowIdentity) -> Void)?
    /// 已销毁窗口的纹理回收钩子：renderer.forget 必须接上，不能只清信箱（方案 §7.5）。
    var onWindowReleased: ((WindowIdentity) -> Void)?

    // MARK: - 轮询

    /// 计划里要求轮询的目标才有定时器；升降级滞后由 planner 决定，sync 不会把它又变成直播流。
    private func reconcilePolling(plan: CaptureModePlan, round: CaptureRoundToken) {
        for identity in Array(pollTimers.keys) {
            if case .poll = plan.modes[identity] ?? .paused { continue }
            stopPolling(identity)
            if plan.modes[identity] == nil { polledIntervals.removeValue(forKey: identity) }
        }
        for (identity, mode) in plan.modes.sorted(by: { $0.key.journalKey < $1.key.journalKey }) {
            guard case let .poll(interval) = mode, let target = desiredTargets[identity] else { continue }
            if polledIntervals[identity] == interval, pollTimers[identity] != nil { continue }
            startPolling(target, intervalMilliseconds: interval, round: round)
        }
    }

    private func startPolling(_ target: CaptureTarget, intervalMilliseconds: Int, round: CaptureRoundToken) {
        let identity = target.identity
        if runs[identity] != nil {
            // 轮询卡片不保留活跃流。
            terminate(identity: identity)
        }
        polledIntervals[identity] = intervalMilliseconds
        appliedAction[identity] = .poll(intervalMilliseconds: intervalMilliseconds)
        onFact?(.downgraded(identity, intervalMilliseconds: intervalMilliseconds))
        captureSingleFrame(target, intervalMilliseconds: intervalMilliseconds, round: round)
        guard pollTimers[identity] == nil else { return }
        let timer = Timer(timeInterval: max(0.5, Double(intervalMilliseconds) / 1000), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.round == round else { return }
                guard let current = self.desiredTargets[identity] else { return }
                self.captureSingleFrame(current, intervalMilliseconds: intervalMilliseconds, round: round)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimers[identity] = timer
    }

    private func stopPolling(_ identity: WindowIdentity) {
        pollTimers.removeValue(forKey: identity)?.invalidate()
        pollTasks.removeValue(forKey: identity)?.cancel()
        pollInFlight.remove(identity)
    }

    /// 一次性单窗口捕获（公开 SCScreenshotManager，由 `singleFrame` 注入）。
    /// 同一窗口最多一个请求在途：上一次还没回来就跳过本轮，不叠加并发截图（方案 §7.5）。
    private func captureSingleFrame(_ target: CaptureTarget, intervalMilliseconds: Int, round: CaptureRoundToken) {
        let identity = target.identity
        guard pollInFlight.insert(identity).inserted else { return }
        let base = StreamConfig.build(cellWidth: target.cellWidth,
                                      backingScale: target.backingScale,
                                      sourceSize: target.sourceSize,
                                      tier: .powerSaving)
        let mailbox = self.mailbox(for: identity)
        let generation = mailbox.currentGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.singleFrame(identity, base)
            let payload: MetalFrame?
            if case .image(let captured) = outcome { payload = self.mappedFrame(captured, base: base, target: target) }
            else { payload = nil }
            self.pollInFlight.remove(identity)
            // 轮询已被停掉或整轮作废：这一张不再对外发事实。
            guard self.round == round, self.pollTimers[identity] != nil else { return }
            switch outcome {
            case .unavailable:
                return
            case .failed:
                self.onFact?(.failed(identity, "低频更新捕获失败"))
            case .image:
                guard let payload,
                      mailbox.publish(payload, generation: generation, at: payload.publishedAt) else { return }
                self.onFact?(.downgraded(identity, intervalMilliseconds: intervalMilliseconds))
                self.onFrame?(identity)
            }
        }
        pollTasks[identity] = task
    }

    /// 低频帧与流帧走同一条纹理路径：格式一致，渲染层不必知道它是降级来的。
    private func mappedFrame(_ captured: CGImage, base: StreamConfig, target: CaptureTarget) -> MetalFrame? {
        guard let mapped = metal.texture(from: captured) else { return nil }
        return MetalFrame(texture: mapped.texture,
                          storage: mapped.storage,
                          meta: CapturedFrameMeta(pixelWidth: base.pixelWidth,
                                                  pixelHeight: base.pixelHeight,
                                                  contentRectInPoints: nil,
                                                  pointPixelScale: target.backingScale,
                                                  contentScale: target.backingScale,
                                                  sourceSizeInPoints: target.sourceSize,
                                                  status: .complete,
                                                  isValid: true,
                                                  presentTime: Date().timeIntervalSince1970),
                          publishedAt: Date())
    }
}

/// 单窗口一次捕获的结果。区分"目标已经不在了"与"捕获报错"，否则关窗口会被误报成流失败。
enum SingleFrameOutcome {
    case image(CGImage)
    case unavailable
    case failed
}

/// 目录里已经找不到可共享窗口时的一轮：明确失败，不留下半个 stream（方案 §7.2）。
private final class FailedCaptureRun: CaptureRunning {
    let identity: WindowIdentity
    let runID: CaptureRunID
    var onFirstFrame: ((CaptureRunID, Date) -> Void)?
    var onFailure: ((CaptureRunID, String) -> Void)?
    var onFramePublished: ((CaptureRunID, MetalFrame) -> Void)?
    private let configStore: StreamConfig

    init(request: CaptureRunRequest) {
        identity = request.identity
        runID = request.runID
        configStore = request.config
    }

    var phase: CaptureRunPhase { .stopped }
    var config: StreamConfig { configStore }
    var lastError: String? { "捕获目标已不在当前共享内容列表中" }
    var frameCounts: CaptureFrameCounts { CaptureFrameCounts() }

    @discardableResult
    func start() async -> Bool {
        onFailure?(runID, lastError!)
        return false
    }

    func stop() async {}
    @discardableResult func update(configuration: StreamConfig) async -> Bool { false }
}
