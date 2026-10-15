import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VistileCore

/// 捕获层向上汇报的事实事件；由状态机决定卡片显示什么，捕获层自己不改状态。
enum CaptureFact: Hashable, Sendable {
    case started(WindowIdentity, UInt64)
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
        case .notCapturable, .closed, .permissionMissing: isCapturable = false
        default: isCapturable = record.restriction != .protectedContent
        }
    }
}

/// 捕获流生命周期与并发控制（方案 §9）。
/// 长期并发流上限、降级阈值都必须由实测记录校准，这里只是保守起点。
/// 会话表与信箱表只在主 Actor 上增删；帧回调在 sampleQueue 上落进信箱后不回读目录。
@MainActor
final class CaptureCoordinator {
    var onFact: ((CaptureFact) -> Void)?

    /// 至多 2 个启动操作同时进行，避免几十个流同一时间申请资源。
    let maxConcurrentStarts = 2
    /// 实测前的保守软上限；Performance 文档会用真实数据替换。
    var streamSoftLimit: Int = 12

    private let metal: MetalContext
    private let catalog: WindowCatalog
    private var sessions: [WindowIdentity: WindowCaptureSession] = [:]
    private var mailboxes: [WindowIdentity: FrameMailbox<MetalFrame>] = [:]
    private var pendingStarts: [CaptureTarget] = []
    private var activeStarts = 0
    private var lastConfigurationChange: [WindowIdentity: Date] = [:]
    private var appliedAction: [WindowIdentity: BudgetAction] = [:]
    private var pollTimers: [WindowIdentity: Timer] = [:]
    private var currentTier: CaptureTier = .balanced
    private let sampleQueue = DispatchQueue(label: "com.misswell.Vistile.capture.frames",
                                           qos: .userInitiated,
                                           autoreleaseFrequency: .workItem)

    var thermalState: ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        default: return .critical
        }
    }

    init(metal: MetalContext, catalog: WindowCatalog) {
        self.metal = metal
        self.catalog = catalog
    }

    var activeStreamCount: Int { sessions.count }
    var queuedStartCount: Int { pendingStarts.count }
    var polledCount: Int { pollTimers.count }

    func mailbox(for identity: WindowIdentity) -> FrameMailbox<MetalFrame> {
        if let existing = mailboxes[identity] { return existing }
        let created = FrameMailbox<MetalFrame>()
        mailboxes[identity] = created
        return created
    }

    func allMailboxes() -> [(identity: WindowIdentity, mailbox: FrameMailbox<MetalFrame>)] {
        mailboxes.map { ($0.key, $0.value) }
    }

    // MARK: - 同步目标集合

    /// generation 用于丢弃晚到回调；isAnimating 期间不逐帧改配置。
    func sync(targets: [CaptureTarget], tier: CaptureTier, isAnimating: Bool) {
        currentTier = tier
        let desired = Set(targets.filter(\.isCapturable).filter { !$0.isMinimized }.map(\.identity))

        for (identity, session) in sessions where !desired.contains(identity) {
            terminate(session: session, identity: identity)
        }
        for target in targets where !target.isCapturable || target.isMinimized {
            // 最小化与不可捕获：不保留空转流，但保留最后一帧。
            stopPolling(target.identity)
        }

        var startNow: [CaptureTarget] = []
        var queued: [CaptureTarget] = []
        for target in targets where target.isCapturable && !target.isMinimized {
            if sessions[target.identity] != nil {
                reconfigureIfNeeded(target, tier: tier, isAnimating: isAnimating)
            } else if activeStarts + startNow.count < maxConcurrentStarts {
                startNow.append(target)
            } else {
                queued.append(target)
            }
        }
        pendingStarts = queued
        applyBudget(targets)
        for target in startNow { start(target, tier: tier) }
    }

    private func reconfigureIfNeeded(_ target: CaptureTarget, tier: CaptureTier, isAnimating: Bool) {
        guard let session = sessions[target.identity] else { return }
        let candidate = config(for: target, tier: tier)
        let elapsed = Date().timeIntervalSince(lastConfigurationChange[target.identity] ?? .distantPast)
        guard session.config.needsReconfiguration(to: candidate,
                                                 elapsedSinceLastChange: elapsed,
                                                 isAnimating: isAnimating) else { return }
        lastConfigurationChange[target.identity] = Date()
        Task { [weak self] in
            guard let self else { return }
            let ok = await session.update(configuration: candidate)
            if !ok, let message = session.lastError {
                await MainActor.run { self.onFact?(.failed(target.identity, message)) }
            }
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

    // MARK: - 启动 / 终止

    private func start(_ target: CaptureTarget, tier: CaptureTier) {
        guard sessions[target.identity] == nil else { return }
        guard let window = catalog.scWindow(for: target.identity) else {
            onFact?(.failed(target.identity, "捕获目标已不在当前共享内容列表中"))
            return
        }
        activeStarts += 1
        let mailbox = self.mailbox(for: target.identity)
        let generation = mailbox.advanceGeneration()
        let session = WindowCaptureSession(identity: target.identity,
                                          generation: generation,
                                          window: window,
                                          config: config(for: target, tier: tier),
                                          mailbox: mailbox,
                                          metal: metal,
                                          sampleQueue: sampleQueue)
        let identity = target.identity
        session.onFirstFrame = { [weak self] date in
            DispatchQueue.main.async { self?.onFact?(.firstFrame(identity, date)) }
        }
        session.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                // 失败不再自动重试：由状态机决定降级或移除卡片。
                if let existing = self.sessions[identity] {
                    self.terminate(session: existing, identity: identity)
                }
                self.onFact?(.failed(identity, message))
                self.drainPendingStarts()
            }
        }
        sessions[identity] = session
        onFact?(.started(identity, generation))
        Task { [weak self] in
            guard let self else { return }
            let ok = await session.start()
            await MainActor.run {
                self.activeStarts -= 1
                if !ok {
                    if let existing = self.sessions[identity] { self.terminate(session: existing, identity: identity) }
                    self.onFact?(.failed(identity, session.lastError ?? "startCapture 失败"))
                }
                self.drainPendingStarts()
            }
        }
    }

    private func drainPendingStarts() {
        guard activeStarts < maxConcurrentStarts, let next = pendingStarts.first else { return }
        pendingStarts.removeFirst()
        guard sessions[next.identity] == nil, next.isCapturable, !next.isMinimized else { return }
        start(next, tier: currentTier)
    }

    private func terminate(session: WindowCaptureSession, identity: WindowIdentity) {
        sessions.removeValue(forKey: identity)
        lastConfigurationChange.removeValue(forKey: identity)
        appliedAction.removeValue(forKey: identity)
        stopPolling(identity)
        Task { _ = await session.stop() }
    }

    /// hidden、锁屏、睡眠、切换用户后停流；releasing 时连 mailbox 一起释放（方案 §9.7）。
    func stopAll(releasingMailboxes: Bool = false) {
        for (identity, session) in sessions { terminate(session: session, identity: identity) }
        pendingStarts.removeAll()
        activeStarts = 0
        for identity in Array(pollTimers.keys) { stopPolling(identity) }
        if releasingMailboxes {
            mailboxes.removeAll()
            metal.purgeTextureCache()
        }
    }

    // MARK: - 预算降级

    /// 固定顺序：降帧率 → 降输出分辨率 → 低优先级轮询；优先刷新窗口最后降级。
    private func applyBudget(_ targets: [CaptureTarget]) {
        let streams = sessions.count
        let thermal = thermalState
        let byIdentity = Dictionary(targets.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })

        for identity in Array(appliedAction.keys) where byIdentity[identity] == nil {
            appliedAction.removeValue(forKey: identity)
            stopPolling(identity)
        }
        guard streams > streamSoftLimit || thermal == .serious || thermal == .critical else {
            if !appliedAction.isEmpty {
                appliedAction.removeAll()
                for identity in Array(pollTimers.keys) { stopPolling(identity) }
            }
            return
        }

        var applied = 0
        let ordered = targets.sorted { a, b in
                a.isPriority != b.isPriority ? a.isPriority : a.identity.windowID < b.identity.windowID
            }
        for target in ordered {
            guard let session = sessions[target.identity] else { continue }
            let action = CaptureBudget.nextAction(currentFPS: session.config.fps,
                                                 currentWidth: session.config.pixelWidth,
                                                 streams: streams,
                                                 streamSoftLimit: streamSoftLimit,
                                                 thermal: thermal,
                                                 isPriority: target.isPriority)
            appliedAction[target.identity] = action
            applied += 1
            switch action {
            case .keep:
                stopPolling(target.identity)
            case .lowerFPS, .lowerOutputWidth:
                stopPolling(target.identity)
                reconfigureImmediately(target)
            case let .poll(intervalMilliseconds):
                startPolling(target, intervalMilliseconds: intervalMilliseconds)
            }
        }
        if applied > 0 { onFact?(.budgetApplied(applied)) }
    }

    /// 预算降级要立刻生效，不再等 250ms 合并窗口。
    private func reconfigureImmediately(_ target: CaptureTarget) {
        guard let session = sessions[target.identity] else { return }
        lastConfigurationChange[target.identity] = Date()
        let candidate = config(for: target, tier: currentTier)
        Task { _ = await session.update(configuration: candidate) }
    }

    /// 轮询更新：明确显示真实间隔，绝不标成实时（方案 §9）。
    private func startPolling(_ target: CaptureTarget, intervalMilliseconds: Int) {
        let identity = target.identity
        if let session = sessions[identity] {
            // 轮询卡片不保留活跃流。
            terminate(session: session, identity: identity)
            appliedAction[identity] = .poll(intervalMilliseconds: intervalMilliseconds)
        }
        onFact?(.downgraded(identity, intervalMilliseconds: intervalMilliseconds))
        captureSingleFrame(target, intervalMilliseconds: intervalMilliseconds)
        guard pollTimers[identity] == nil else { return }
        let timer = Timer(timeInterval: max(0.5, Double(intervalMilliseconds) / 1000), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureSingleFrame(target, intervalMilliseconds: intervalMilliseconds)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimers[identity] = timer
    }

    private func stopPolling(_ identity: WindowIdentity) {
        pollTimers.removeValue(forKey: identity)?.invalidate()
    }

    /// 一次性单窗口捕获（公开 SCScreenshotManager），只用于已明确标注的低频更新。
    private func captureSingleFrame(_ target: CaptureTarget, intervalMilliseconds: Int) {
        let identity = target.identity
        guard let window = catalog.scWindow(for: identity) else { return }
        let configuration = SCStreamConfiguration()
        let base = StreamConfig.build(cellWidth: target.cellWidth,
                                      backingScale: target.backingScale,
                                      sourceSize: target.sourceSize,
                                      tier: .powerSaving)
        configuration.apply(base)
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let mailbox = self.mailbox(for: identity)
        let generation = mailbox.currentGeneration
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                guard let mapped = self.metal.texture(from: image) else { return }
                let payload = MetalFrame(texture: mapped.texture,
                                         storage: mapped.storage,
                                         meta: CapturedFrameMeta(pixelWidth: base.pixelWidth,
                                                                 pixelHeight: base.pixelHeight,
                                                                 contentRect: .zero,
                                                                 scaleFactor: target.backingScale,
                                                                 sourceSize: target.sourceSize,
                                                                 isValid: true,
                                                                 isIdle: false,
                                                                 presentTime: Date().timeIntervalSince1970),
                                         publishedAt: Date())
                let accepted = mailbox.publish(payload, generation: generation, at: payload.publishedAt)
                await MainActor.run {
                    if accepted {
                        self.onFact?(.downgraded(identity, intervalMilliseconds: intervalMilliseconds))
                    }
                }
            } catch {
                await MainActor.run {
                    self.onFact?(.failed(identity, "低频更新捕获失败: \(error.localizedDescription)"))
                }
            }
        }
    }
}
