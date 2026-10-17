import CoreGraphics
import Foundation
import VistileCore
@testable import Vistile

/// 捕获生命周期回归（T08/T09/T15）用的可控制驱动（方案 §15.1 第 2 层）。
///
/// 真实 ScreenCaptureKit 的 startCapture 什么时候返回、停止是否落在同一条流上，
/// 都不是测试能安排的；用随机 sleep 猜时序只会得到偶发绿。这里把"一次运行"换成
/// 带门的替身，并让它按与真实会话相同的核心裁决（`CaptureLifecycle`）走：
/// 于是断言落在协调器真正负责的那几件事上——谁去停、停几次、旧回调能不能影响新的一轮。
/// SCStream 自己那层（addStreamOutput/removeStreamOutput/stopCapture 的实际效果）仍属实机项。

/// 底层实例替身：只回答"这条流被停了几次"。
final class FakeStreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _stops = 0
    var stops: Int { lock.withLock { _stops } }
    func stop() { lock.withLock { _stops += 1 } }
}

/// 一次假运行。`gatesStart` 让 start 卡在 await 里，直到测试 `openStartGate()`。
final class FakeCaptureRun: CaptureRunning, @unchecked Sendable {
    let identity: WindowIdentity
    let runID: CaptureRunID
    /// 本轮拿到的信箱代次：首帧必须发布在它上面，否则 R05 的代次修复没被真正测到。
    let generation: UInt64
    let mailbox: FrameMailbox<MetalFrame>

    var onFirstFrame: ((CaptureRunID, Date) -> Void)?
    var onFailure: ((CaptureRunID, String) -> Void)?
    var onFramePublished: ((CaptureRunID, MetalFrame) -> Void)?

    private let lock = NSLock()
    private var lifecycle = CaptureLifecycle()
    private var storage: StreamConfig
    private var handle: FakeStreamHandle?
    private var created: [FakeStreamHandle] = []
    private var all: [FakeStreamHandle] = []
    private var pendingStartResume: CheckedContinuation<Void, Never>?
    private var _lastError: String?
    private var _counts = CaptureFrameCounts()
    private var configurationUpdates = 0

    /// 置位后 start 停在 await 里，等 `openStartGate()`。
    var gatesStart = false
    /// 置位后 start 报失败：用来验证"失败回调与 start 返回 false 只报一条"。
    var failsStart = false
    /// 首帧发布用的纹理（由测试用真实 Metal 设备造好）。
    var frameForPublish: MetalFrame?

    init(request: CaptureRunRequest) {
        identity = request.identity
        runID = request.runID
        generation = request.generation
        mailbox = request.mailbox
        storage = request.config
    }

    var phase: CaptureRunPhase { lock.withLock { lifecycle.phase } }
    var config: StreamConfig { lock.withLock { storage } }
    var lastError: String? { lock.withLock { _lastError } }
    var frameCounts: CaptureFrameCounts { lock.withLock { _counts } }

    /// 建立过几条底层实例、总共停了几次：活跃流能否归零就看这两个数。
    var createdHandleCount: Int { lock.withLock { created.count } }
    var totalStops: Int { lock.withLock { created.reduce(0) { $0 + $1.stops } } }
    /// 本轮造出的每一个底层实例（含登记失败就被丢弃的那条）都必须被停过。
    var madeHandleCount: Int { lock.withLock { all.count } }
    var unstoppedHandleCount: Int { lock.withLock { all.filter { $0.stops == 0 }.count } }
    var isSuspendedInStart: Bool { lock.withLock { pendingStartResume != nil } }
    var liveHandles: Int { lock.withLock { created.filter { $0.stops == 0 }.count } }

    @discardableResult
    func start() async -> Bool {
        let candidate = FakeStreamHandle()
        lock.withLock { all.append(candidate) }
        let registered = lock.withLock { () -> Bool in
            guard lifecycle.beginStart() else { return false }
            handle = candidate
            created.append(candidate)
            return true
        }
        guard registered else {
            candidate.stop()
            return false
        }
        if lock.withLock({ gatesStart }) { await waitForStartGate() }
        if lock.withLock({ failsStart }) {
            lock.withLock {
                _lastError = "startCapture 失败"
                handle = nil
                lifecycle.markStopped()
            }
            candidate.stop()
            // 真实会话也是先回调再返回 false：两条路径必须只对外报一次。
            onFailure?(runID, "startCapture 失败")
            return false
        }
        switch lock.withLock({ lifecycle.startReturned() }) {
        case .enterRunning:
            return true
        case .mustStop, .alreadyHandled:
            lock.withLock { handle = nil; lifecycle.markStopped() }
            candidate.stop()
            return false
        }
    }

    func stop() async {
        switch lock.withLock({ lifecycle.requestStop() }) {
        case .thisCall:
            let target = lock.withLock { () -> FakeStreamHandle? in
                let existing = handle
                handle = nil
                lifecycle.markStopped()
                return existing
            }
            target?.stop()
        case .pendingStart, .nobody:
            return
        }
    }

    @discardableResult
    func update(configuration: StreamConfig) async -> Bool {
        lock.withLock {
            storage = configuration
            configurationUpdates += 1
        }
        return phase == .running
    }

    /// 这条流被要求换过几次配置：滚动/拖动时的"一个显示周期只兑现一次合并重配"就数这个（方案 §13.2）。
    var configurationUpdateCount: Int { lock.withLock { configurationUpdates } }

    // MARK: - 门与晚到回调

    func openStartGate() {
        lock.withLock { gatesStart = false }
        resumeStartGate()
    }

    /// 晚到首帧：真实场景是停止之后系统才把回调排上来。
    func emitFirstFrame(at date: Date = Date()) { onFirstFrame?(runID, date) }
    func emitFailure(_ message: String) { onFailure?(runID, message) }
    func emitFrame() {
        let pending = lock.withLock { frameForPublish }
        guard let frame = pending else { return }
        guard mailbox.publish(frame, generation: generation, at: Date()) else { return }
        lock.withLock { _counts.published += 1 }
        onFramePublished?(runID, frame)
    }

    private func waitForStartGate() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !gatesStart {
                lock.unlock()
                continuation.resume()
                return
            }
            pendingStartResume = continuation
            lock.unlock()
        }
    }

    private func resumeStartGate() {
        lock.lock()
        let resume = pendingStartResume
        pendingStartResume = nil
        lock.unlock()
        resume?.resume()
    }
}

/// 单窗口低频捕获的替身：能数"同时在途几个请求"，也能把请求卡在门后。
final class FakeSingleFrameCapturer: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [WindowIdentity] = []
    private var _inFlight = 0
    private var _peakInFlight = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var gateAll = false
    var image: CGImage?

    var callCount: Int { lock.withLock { _calls.count } }
    var peakInFlight: Int { lock.withLock { _peakInFlight } }
    func calls(for identity: WindowIdentity) -> Int { lock.withLock { _calls.filter { $0 == identity }.count } }

    /// 置位后每次捕获都卡在门后，直到 `openGate()`：用来制造"sync 连着来两次"。
    var gatesRequests: Bool {
        get { lock.withLock { gateAll } }
        set { lock.withLock { gateAll = newValue } }
    }

    func openGate() {
        lock.lock()
        gateAll = false
        let waiters = pending
        pending = []
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func outcome(for identity: WindowIdentity) async -> SingleFrameOutcome {
        lock.lock()
        _calls.append(identity)
        _inFlight += 1
        _peakInFlight = max(_peakInFlight, _inFlight)
        let shouldGate = gateAll
        if shouldGate {
            lock.unlock()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock(); pending.append(continuation); lock.unlock()
            }
        } else {
            lock.unlock()
        }
        let result: SingleFrameOutcome = image.map { .image($0) } ?? .failed
        lock.lock()
        _inFlight -= 1
        lock.unlock()
        return result
    }
}

/// 捕获测试的组装入口（`WindowCatalog` 是 MainActor 类型，这里同步标注）。
@MainActor
enum HostCapture {
    /// 一个可捕获目标：几何固定，测试只关心生命周期不关心像素。
    static func target(_ index: Int, slot: Int? = nil, isPriority: Bool = false, cellWidth: CGFloat = 320) -> CaptureTarget {
        CaptureTarget(record: HostFixtures.record(index, slot: slot ?? index),
                      cellWidth: cellWidth,
                      backingScale: 2,
                      isPriority: isPriority)
    }

    static func catalog() -> WindowCatalog {
        let source = FakeCatalogSource()
        return WindowCatalog(permissions: FakePermissions(),
                             axSource: source,
                             contentSource: source,
                             displaySource: FakeDisplaySource(displays: [HostFixtures.display]))
    }
}
