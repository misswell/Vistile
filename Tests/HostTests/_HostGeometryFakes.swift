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
final class FakeCatalogSource: CatalogContentSource, CatalogAXSource, CatalogSheetSource, @unchecked Sendable {
    private let lock = NSLock()
    private var windowFrames: [WindowIdentity: CGRect] = [:]
    private var elements: [WindowIdentity: AXUIElement] = [:]
    private var sheets: Set<WindowIdentity> = []
    /// 置为 false 复现"这一代 AX 句柄读不到"。
    var publishesAX = true
    /// AX 侧的最小化事实由写入器持有（应用是唯一真相），目录只是读它。
    var minimizedReader: ((WindowIdentity) -> Bool)?
    private var pendingSwap: [WindowIdentity: AXUIElement] = [:]

    /// 下一次 AX 读取时把该身份的句柄换成 `element`。
    func swapElementOnNextRead(_ identity: WindowIdentity, to element: AXUIElement) {
        lock.lock(); pendingSwap[identity] = element; lock.unlock()
    }

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

    /// 让某个窗口"挂着需要用户处理的 Sheet"（方案 §8.2.4）。
    func setSheet(_ hasSheet: Bool, for identity: WindowIdentity) {
        lock.lock()
        if hasSheet { sheets.insert(identity) } else { sheets.remove(identity) }
        lock.unlock()
    }

    func hasAttachedSheet(element: AXUIElement) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let identity = elements.first(where: { CFEqual($0.value, element) })?.key else { return false }
        return sheets.contains(identity)
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
        guard let identity else { return [] }
        // 换代时把句柄换成另一个对象：用来复现"旧索引指向别的窗口"。
        lock.lock()
        if let next = pendingSwap.removeValue(forKey: identity) { elements[identity] = next }
        lock.unlock()
        guard let element = element(for: identity) else { return [] }
        return [AXWindowEntry(snapshot: AXWindowSnapshot(index: 0,
                                                         frame: frame(of: identity),
                                                         title: Self.title(for: identity),
                                                         subrole: "AXStandardWindow",
                                                         isMinimized: minimizedReader?(identity) ?? false,
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
    private var minimized: [Int: Bool] = [:]
    private var unminimizeCount = 0
    /// 动作序列：断言"先解除最小化，再写几何"这类顺序，而不是只看最终状态。
    private var actions: [String] = []
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
        actions.append("写")
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
        lock.lock()
        focuses += 1
        // 读回的是"应用当前认为的 focused window"：可以是被兄弟窗口占着。
        focusedByPID[Int(Self.pid(of: element))] = siblingKeepsFocus ? Self.sibling : element
        lock.unlock()
        return true
    }

    /// 置位后：写焦点成功，但读回永远是另一个元素（同应用兄弟窗口仍在前面的情形）。
    var siblingKeepsFocus = false
    private var focusedByPID: [Int: AXUIElement] = [:]
    /// 前景化判定读过几次 focused window：测试用它等"读回这一步真的发生了"。
    private var focusedReads = 0

    var focusedWindowReadCount: Int {
        lock.lock(); defer { lock.unlock() }
        return focusedReads
    }

    func focusedWindow(pid: pid_t) async -> AXWindowEntry? {
        lock.lock(); let element = focusedByPID[Int(pid)]; focusedReads += 1; lock.unlock()
        guard let element else { return nil }
        return AXWindowEntry(snapshot: AXWindowSnapshot(index: -1,
                                                        frame: nil,
                                                        title: "",
                                                        subrole: "AXStandardWindow",
                                                        isMovable: true,
                                                        isResizable: true),
                             element: element)
    }

    /// 一个不属于任何目标窗口的 AX 对象。
    private static let sibling = AXUIElementCreateApplication(999_999)

    private static func pid(of element: AXUIElement) -> pid_t {
        var value: pid_t = 0
        AXUIElementGetPid(element, &value)
        return value
    }

    // MARK: 最小化（方案 §11）

    /// true 时解除最小化"写入成功但读回不变"：应用自己不肯把窗口放回来。
    var refusesUnminimize = false

    /// 替身里的应用侧事实。
    func setMinimizedState(_ value: Bool, for element: AXUIElement) {
        lock.lock(); minimized[Self.key(of: element)] = value; lock.unlock()
    }

    func isMinimized(for element: AXUIElement) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return minimized[Self.key(of: element)] ?? false
    }

    var unminimizeAttempts: Int {
        lock.lock(); defer { lock.unlock() }
        return unminimizeCount
    }

    func setMinimized(_ minimized: Bool, element: AXUIElement) async -> Bool {
        lock.lock()
        unminimizeCount += 1
        actions.append(minimized ? "最小化" : "解除最小化")
        let key = Self.key(of: element)
        // 拒绝的脚本模拟真实失败：属性写入本身不报错，但读回还是原来的值。
        if !(refusesUnminimize && !minimized) { self.minimized[key] = minimized }
        let readBack = self.minimized[key] ?? false
        lock.unlock()
        return readBack == minimized
    }

    /// 替身看到的动作顺序（写 = 几何写入，其余是最小化/解除最小化）。
    var recordedActions: [String] {
        lock.lock(); defer { lock.unlock() }
        return actions
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
