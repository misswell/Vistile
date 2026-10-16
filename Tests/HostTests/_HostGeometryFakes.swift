import AppKit
import ApplicationServices
import Foundation
import VistileCore
@testable import Vistile

/// 几何事务与交错类回归（T05/T06/T07）用的固定事实。
///
/// 这些回归断言的是"外部写入之前与之后的事实"，不是函数返回值。对着真桌面跑既不确定
/// （取决于本机接线与授权），也会改动用户窗口（禁止），所以屏幕、候选窗口、AX 句柄、
/// 权限、进程身份、几何写入六项全部注入；替身写入器之外不会碰一次真实 AX。

/// 固定权限事实。
final class FakePermissions: PermissionChecking, @unchecked Sendable {
    var status: PermissionStatus
    init(status: PermissionStatus = PermissionStatus(screenRecording: true, accessibility: true)) {
        self.status = status
    }
}

/// 固定显示器：全部落在主屏之外的负坐标；"原显示器是否还活着"由测试决定。
struct FakeDisplaySource: DisplayInfoSource {
    var displays: [DisplayInfo]
    func displayInfos() -> [DisplayInfo] { displays }
}

/// 候选窗口与 AX 句柄来源。句柄是用假 PID 创建的应用元素，系统里并不存在这些进程。
final class FakeCatalogSource: CatalogContentSource, CatalogAXSource, @unchecked Sendable {
    private let lock = NSLock()
    private var windowFrames: [WindowIdentity: CGRect] = [:]
    private var elements: [WindowIdentity: AXUIElement] = [:]
    /// 置为 false 复现"这一代 AX 句柄读不到"。
    var publishesAX = true

    /// offscreen 且互不重叠：保证捕获窗口与 AX 窗口一对一唯一匹配。
    static func frame(for index: Int) -> CGRect {
        CGRect(x: HostFixtures.offscreenOrigin.x + 20 + CGFloat(index) * 40,
               y: HostFixtures.offscreenOrigin.y + 20 + CGFloat(index) * 30,
               width: 800, height: 500)
    }

    func addWindows(_ indices: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        for index in indices {
            let identity = HostFixtures.identity(index)
            windowFrames[identity] = Self.frame(for: index)
            elements[identity] = AXUIElementCreateApplication(identity.processID)
        }
    }

    func frame(of identity: WindowIdentity) -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return windowFrames[identity]
    }

    func element(for identity: WindowIdentity) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return elements[identity]
    }

    func load() async -> CatalogContentResult {
        lock.lock()
        let identities = Array(windowFrames.keys)
        lock.unlock()
        let snapshots = identities.map { identity in
            CaptureWindowSnapshot(identity: identity,
                                  frame: frame(of: identity) ?? .zero,
                                  title: Self.title(for: identity),
                                  ownerName: Self.owner(for: identity),
                                  bundleID: "com.test.app\(identity.windowID)",
                                  layer: 0,
                                  alpha: 1,
                                  isOnScreen: true,
                                  sharingState: 1)
        }
        return .loaded(CatalogContent(snapshots: snapshots,
                                      capturableIDs: Set(identities.map(\.windowID)),
                                      scWindows: [:]))
    }

    func windows(pid: pid_t) async -> [AXWindowEntry] {
        guard publishesAX else { return [] }
        lock.lock()
        let identity = windowFrames.keys.first { $0.processID == pid }
        lock.unlock()
        guard let identity, let element = element(for: identity) else { return [] }
        return [AXWindowEntry(snapshot: AXWindowSnapshot(index: 0,
                                                         frame: frame(of: identity),
                                                         title: Self.title(for: identity),
                                                         subrole: "AXStandardWindow",
                                                         isMovable: true,
                                                         isResizable: true),
                              element: element)]
    }

    private static func title(for identity: WindowIdentity) -> String { "窗口 \(identity.windowID)" }
    private static func owner(for identity: WindowIdentity) -> String { "App\(identity.windowID)" }
}

/// 进程身份替身：默认"还是原来那个进程"，可按 PID 改成"号被复用了"。
final class FakeProcessIdentity: ProcessIdentityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var restarted: Set<pid_t> = []

    func markProcessRestarted(processID: pid_t) {
        lock.lock(); restarted.insert(processID); lock.unlock()
    }

    func isSameInstance(processID: pid_t, startIdentity: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !restarted.contains(processID)
    }
}

/// 几何写入替身：记录每一次写入、脚本化目标应用的行为，
/// 并能把写入卡在"已经发起但还没完成"这一刻，用来确定性地制造交错。
final class FakeGeometryWriter: GeometryWriting, @unchecked Sendable {
    struct Write: Equatable {
        let frame: CGRect
    }

    /// 替身模拟的目标应用行为。
    enum Script {
        /// 接受写入，读回等于目标。
        case accepts
        /// 应用按自身约束改了尺寸：有读回但偏离目标。
        case constrains
        /// AX 写入报错，frame 保持不变。
        case rejects
    }

    private let lock = NSLock()
    private var frames: [Int: CGRect] = [:]
    private var scripts: [Int: Script] = [:]
    private var defaultScript: Script = .accepts
    private var writeLog: [Write] = []
    private var raises = 0
    private var focuses = 0
    private var gateRequested = false
    private var pendingResume: CheckedContinuation<Void, Never>?
    /// 写入发起那一刻的旁路观察：用于断言"日志已落盘，才轮到写 AX"。
    var onWillWrite: ((Write) -> Void)?

    // MARK: 脚本

    func setInitialFrame(_ frame: CGRect, for element: AXUIElement) {
        lock.lock(); frames[Self.key(of: element)] = frame; lock.unlock()
    }

    /// 传 nil 设置全局默认行为。
    func setScript(_ script: Script, for element: AXUIElement?) {
        lock.lock()
        if let element { scripts[Self.key(of: element)] = script } else { defaultScript = script }
        lock.unlock()
    }

    /// true 时下一次 `apply` 停在写入内部，直到 `openGate()`。
    var gatesNextWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return gateRequested }
        set { lock.lock(); gateRequested = newValue; lock.unlock() }
    }

    var isBlockedInWrite: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingResume != nil
    }

    func openGate() {
        lock.lock()
        let resume = pendingResume
        pendingResume = nil
        gateRequested = false
        lock.unlock()
        resume?.resume()
    }

    // MARK: GeometryWriting

    func currentFrame(of element: AXUIElement) async -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        return frames[Self.key(of: element)]
    }

    func apply(frame target: CGRect, element: AXUIElement) async -> GeometryWriteReport {
        let key = Self.key(of: element)
        await waitForGateIfNeeded()
        onWillWrite?(Write(frame: target))

        lock.lock()
        let before = frames[key]
        let script = scripts[key] ?? defaultScript
        writeLog.append(Write(frame: target))
        let success = Int(AXError.success.rawValue)
        let failure = Int(AXError.failure.rawValue)
        var readBack = target
        var outcome = GeometryOutcome.exact(readBack: target)
        var sizeError = success
        var positionError = success
        switch script {
        case .accepts:
            break
        case .constrains:
            readBack = target.offsetBy(dx: 30, dy: 30)
            outcome = .constrained(readBack: readBack)
        case .rejects:
            readBack = before ?? target
            outcome = .rejected(.sizeWrite(code: failure))
            sizeError = failure
            positionError = failure
        }
        if script != .rejects { frames[key] = readBack }
        lock.unlock()

        return GeometryWriteReport(target: target,
                                   frameBeforeWrite: before,
                                   sizeWriteError: sizeError,
                                   positionWriteError: positionError,
                                   readBack: readBack,
                                   outcome: outcome)
    }

    func raise(element: AXUIElement) async -> Bool {
        lock.lock(); raises += 1; lock.unlock()
        return true
    }

    func focus(element: AXUIElement) async -> Bool {
        lock.lock(); focuses += 1; lock.unlock()
        return true
    }

    // MARK: 查询

    var recordedWrites: [Write] {
        lock.lock(); defer { lock.unlock() }
        return writeLog
    }

    var writtenFrames: [CGRect] { recordedWrites.map(\.frame) }
    var totalWrites: Int { recordedWrites.count }
    var raiseCount: Int { lock.lock(); defer { lock.unlock() }; return raises }
    var focusCount: Int { lock.lock(); defer { lock.unlock() }; return focuses }

    private func waitForGateIfNeeded() async {
        lock.lock()
        guard gateRequested else { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            pendingResume = continuation
            lock.unlock()
        }
    }

    private static func key(of element: AXUIElement) -> Int { Int(CFHash(element)) }
}
