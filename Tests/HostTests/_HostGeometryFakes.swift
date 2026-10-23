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
    private var publishedResizable: [WindowIdentity: Bool] = [:]
    /// 置为 false 复现"这一代 AX 句柄读不到"。
    var publishesAX = true
    /// 接下来 N 轮查询整轮读不到 AX（复现实机捕捉权限成串短暂被拒），之后自动恢复。
    /// 以 `load()` 为轮起点：目录一轮查询固定先读内容再读各进程 AX，整轮一起坏才贴近真实形态。
    var axUnavailableRounds = 0
    private var axBlockedThisRound = false
    /// AX 侧的最小化事实由写入器持有（应用是唯一真相），目录只是读它。
    var minimizedReader: ((WindowIdentity) -> Bool)?
    private var pendingSwap: [WindowIdentity: AXUIElement] = [:]
    /// 目录查询停在"捕获/AX 已发起、还没回来"这一刻：制造无响应目录下的取消（方案 §18 A01）。
    private var armedLoadGate = false
    private var pendingLoadResume: CheckedContinuation<Void, Never>?

    /// 下一次 `load()` 停在轮询起点，直到 `openCatalogLoadGate()`。
    var gatesNextCatalogLoad: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armedLoadGate }
        set {
            lock.lock(); armedLoadGate = newValue; lock.unlock()
        }
    }

    var isBlockedInCatalogLoad: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingLoadResume != nil
    }

    func openCatalogLoadGate() {
        lock.lock()
        let resume = pendingLoadResume
        pendingLoadResume = nil
        armedLoadGate = false
        lock.unlock()
        resume?.resume()
    }

    private func waitForCatalogLoad() async {
        lock.lock()
        guard armedLoadGate else { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            armedLoadGate = false
            pendingLoadResume = continuation
            lock.unlock()
        }
    }

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

    /// 让目录把某窗口发布在另一个位置（复现"目录快照落后一整轮"）：
    /// 只影响目录/`windows(pid:)` 发布的快照事实，窗口真实位置仍由写入替身持有。
    func setPublishedFrame(_ frame: CGRect, for identity: WindowIdentity) {
        lock.lock(); windowFrames[identity] = frame; lock.unlock()
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

    /// 目录快照里把该窗口标成不可调整尺寸：复现"采样时一次 AX 读超时被折叠成 false"的坏代次。
    /// 它只影响目录里发布的快照事实；窗口本身是否可写由写入替身的实测决定。
    func setPublishedResizable(_ value: Bool, for identity: WindowIdentity) {
        lock.lock(); publishedResizable[identity] = value; lock.unlock()
    }

    func hasAttachedSheet(element: AXUIElement) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let identity = elements.first(where: { CFEqual($0.value, element) })?.key else { return false }
        return sheets.contains(identity)
    }

    func load() async -> CatalogContentResult {
        await waitForCatalogLoad()
        lock.lock()
        axBlockedThisRound = axUnavailableRounds > 0
        if axBlockedThisRound { axUnavailableRounds -= 1 }
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
        let blocked = axBlockedThisRound
        let identity = windowFrames.keys.first { $0.processID == pid }
        lock.unlock()
        guard !blocked else { return [] }
        guard let identity else { return [] }
        // 换代时把句柄换成另一个对象：用来复现"旧索引指向别的窗口"。
        lock.lock()
        if let next = pendingSwap.removeValue(forKey: identity) { elements[identity] = next }
        lock.unlock()
        guard let element = element(for: identity) else { return [] }
        lock.lock()
        let resizable = publishedResizable[identity] ?? true
        lock.unlock()
        return [AXWindowEntry(snapshot: AXWindowSnapshot(index: 0,
                                                         frame: frame(of: identity),
                                                         title: Self.title(for: identity),
                                                         subrole: "AXStandardWindow",
                                                         isMinimized: minimizedReader?(identity) ?? false,
                                                         isMovable: true,
                                                         isResizable: resizable),
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
        /// 应用按自身约束改了尺寸，读回**仍在请求矩形内**：方案 §9.2 的"受限但合格"。
        case constrainsInside
        /// 应用按自身约束改了尺寸并把窗口顶出主区：方案 §9.2 的"受限且越界"。
        case constrains
        /// AX 写入报错，frame 保持不变。
        case rejects
    }

    /// 写入里的两个停止点：门的位置决定了取消能拦住哪一半。
    enum Gate {
        /// 命令已排到队列头、AX 调用还没开始：这一半取消后必须**零写入**。
        case entry
        /// 尺寸已经落笔、位置还没写：这一半取消后必须回报**部分事实**。
        case position
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
    private var armedGates: Set<Gate> = []
    private var pendingGate: Gate?
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

    /// true 时下一次写入停在"AX 调用还没开始"这一刻，直到 `openGate()`。
    var gatesNextWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armedGates.contains(.entry) }
        set { arm(.entry, newValue) }
    }

    /// true 时下一次 `apply` 停在"尺寸已写、位置还没写"这一刻：制造真实的部分写入。
    var gatesPositionWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armedGates.contains(.position) }
        set { arm(.position, newValue) }
    }

    /// 现在卡在哪一扇门上；没卡住时为 nil。
    var blockedGate: Gate? { lock.lock(); defer { lock.unlock() }; return pendingGate }

    var isBlockedInWrite: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingResume != nil
    }

    func openGate() {
        lock.lock()
        let resume = pendingResume
        pendingResume = nil
        pendingGate = nil
        armedGates.removeAll()
        lock.unlock()
        resume?.resume()
    }

    private func arm(_ gate: Gate, _ value: Bool) {
        lock.lock()
        if value { armedGates.insert(gate) } else { armedGates.remove(gate) }
        lock.unlock()
    }

    // MARK: 写前事实读取的挂起点

    /// 写前两趟实读也可以无响应：取消必须拦得住"读还没回来"这一刻（方案 §18 A02/A03）。
    enum ReadGate: Hashable {
        /// 写前实读 frame 已发起、还没回来
        case currentFrame
        /// 可移动/可尺寸能力查询已发起、还没回来
        case writeability
    }

    private var armedReadGates: Set<ReadGate> = []
    private var pendingReadGate: ReadGate?
    private var pendingReadResume: CheckedContinuation<Void, Never>?

    /// true 时下一次写前实读停在"AX 读取已发起、还没回来"这一刻，直到 `openReadGate()`。
    var gatesNextFrameRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armedReadGates.contains(.currentFrame) }
        set { arm(.currentFrame, newValue) }
    }

    /// true 时下一次能力查询停在"AX 读取已发起、还没回来"这一刻。
    var gatesNextWriteabilityRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armedReadGates.contains(.writeability) }
        set { arm(.writeability, newValue) }
    }

    /// 现在卡在哪一趟读上；没卡住时为 nil。
    var blockedReadGate: ReadGate? { lock.lock(); defer { lock.unlock() }; return pendingReadGate }

    var isBlockedInRead: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingReadResume != nil
    }

    func openReadGate() {
        lock.lock()
        let resume = pendingReadResume
        pendingReadResume = nil
        pendingReadGate = nil
        armedReadGates.removeAll()
        lock.unlock()
        resume?.resume()
    }

    private func arm(_ gate: ReadGate, _ value: Bool) {
        lock.lock()
        if value { armedReadGates.insert(gate) } else { armedReadGates.remove(gate) }
        lock.unlock()
    }

    private func waitForReadGate(_ gate: ReadGate) async {
        lock.lock()
        guard armedReadGates.contains(gate) else { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            armedReadGates.remove(gate)
            pendingReadGate = gate
            pendingReadResume = continuation
            lock.unlock()
        }
    }

    // MARK: GeometryWriting

    func currentFrame(of element: AXUIElement) async -> CGRect? {
        await waitForReadGate(.currentFrame)
        lock.lock(); defer { lock.unlock() }
        return frames[Self.key(of: element)]
    }

    /// 写前事实读取的替身结论：可以脚本化成"可写 / 读到不可写 / 读不到"。
    /// 全局值只作默认：按元素设置才造得出"B 不接受尺寸、A 照常可写"这种真实混合形态。
    var writeability: GeometryWriteability = .writeable
    private var writeabilityByElement: [Int: GeometryWriteability] = [:]

    func setWriteability(_ value: GeometryWriteability, for element: AXUIElement?) {
        lock.lock()
        if let element { writeabilityByElement[Self.key(of: element)] = value } else { writeability = value }
        lock.unlock()
    }

    /// 诊断/测试：真机每笔跨进程探测约 5–20ms（读超时 0.35s），用例据此确认不必要的探测没有被发出。
    private var writeabilityProbes = 0
    var writeabilityProbeCount: Int { lock.lock(); defer { lock.unlock() }; return writeabilityProbes }

    func geometryWriteability(element: AXUIElement) async -> GeometryWriteability {
        await waitForReadGate(.writeability)
        lock.lock()
        writeabilityProbes += 1
        defer { lock.unlock() }
        return writeabilityByElement[Self.key(of: element)] ?? writeability
    }

    func apply(frame target: CGRect, element: AXUIElement, permit: GeometryWritePermit) async -> GeometryWriteReport {
        let key = Self.key(of: element)
        let clamped = target.standardized
        // 落笔前查许可：入队之后才被撤销的命令，一次 AX 写入都不许发生（方案 §5.2）。
        guard permit.isGranted else {
            return Self.cancelledReport(target: clamped, before: nil, wroteSize: false, wrotePosition: false)
        }
        await waitForGate(.entry)
        guard permit.isGranted else {
            return Self.cancelledReport(target: clamped, before: nil, wroteSize: false, wrotePosition: false)
        }

        // 尺寸：这一次调用真的发起了跨进程写入。
        lock.lock()
        let before = frames[key]
        let script = scripts[key] ?? defaultScript
        writeLog.append(Write(frame: clamped))
        actions.append("写")
        if script != .rejects { frames[key] = CGRect(origin: (before ?? clamped).origin, size: clamped.size) }
        lock.unlock()
        onWillWrite?(Write(frame: clamped))

        await waitForGate(.position)
        guard permit.isGranted else {
            // 尺寸已经改掉、位置还没写：按真实部分事实回报，让补偿照着它回位。
            lock.lock(); let partial = frames[key]; lock.unlock()
            return Self.cancelledReport(target: clamped, before: before,
                                        wroteSize: true, wrotePosition: false, readBack: partial)
        }

        let success = Int(AXError.success.rawValue)
        let failure = Int(AXError.failure.rawValue)
        var readBack = clamped
        var outcome = GeometryOutcome.exact(readBack: clamped)
        var sizeError = success
        var positionError = success
        lock.lock()
        switch script {
        case .accepts:
            frames[key] = clamped
        case .constrainsInside:
            // 位置照写，尺寸按应用自己的上限收 60pt：读回小于目标但完全落在主区内。
            readBack = CGRect(x: clamped.minX, y: clamped.minY,
                              width: max(1, clamped.width - 60), height: max(1, clamped.height - 60))
            outcome = .constrained(readBack: readBack)
            frames[key] = readBack
        case .constrains:
            readBack = clamped.offsetBy(dx: 30, dy: 30)
            outcome = .constrained(readBack: readBack)
            frames[key] = readBack
        case .rejects:
            readBack = before ?? clamped
            outcome = .rejected(.sizeWrite(code: failure))
            sizeError = failure
            positionError = failure
        }
        lock.unlock()

        return GeometryWriteReport(target: clamped,
                                   frameBeforeWrite: before,
                                   sizeWriteError: sizeError,
                                   positionWriteError: positionError,
                                   readBack: readBack,
                                   outcome: outcome,
                                   didWriteSize: true,
                                   didWritePosition: true)
    }

    /// 仅移动路径：只写位置，尺寸用写前实读值（方案 §9.1）。
    func applyPosition(_ origin: CGPoint,
                       element: AXUIElement,
                       permit: GeometryWritePermit) async -> GeometryWriteReport {
        let key = Self.key(of: element)
        guard permit.isGranted else {
            return Self.cancelledReport(target: CGRect(origin: origin, size: .zero), before: nil,
                                        wroteSize: false, wrotePosition: false)
        }
        await waitForGate(.entry)
        guard permit.isGranted else {
            return Self.cancelledReport(target: CGRect(origin: origin, size: .zero), before: nil,
                                        wroteSize: false, wrotePosition: false)
        }

        let success = Int(AXError.success.rawValue)
        let failure = Int(AXError.failure.rawValue)
        var size = CGSize.zero
        var before: CGRect?
        var readBack: CGRect?
        var outcome = GeometryOutcome.unreadable
        var positionError = success
        lock.lock()
        if let current = frames[key] {
            before = current
            size = current.size
            let moved = CGRect(origin: origin, size: current.size)
            switch scripts[key] ?? defaultScript {
            case .accepts, .constrainsInside:
                // 仅移动路径没有尺寸可约束：两种脚本在这里都是"位置照写、读回一致"。
                frames[key] = moved
                readBack = moved
                outcome = .exact(readBack: moved)
            case .constrains:
                let constrained = moved.offsetBy(dx: 30, dy: 30)
                frames[key] = constrained
                readBack = constrained
                outcome = .constrained(readBack: constrained)
            case .rejects:
                readBack = current
                outcome = .rejected(.positionWrite(code: failure))
                positionError = failure
            }
        }
        writeLog.append(Write(frame: CGRect(origin: origin, size: size)))
        actions.append("移")
        lock.unlock()
        let written = Write(frame: CGRect(origin: origin, size: size))
        onWillWrite?(written)

        return GeometryWriteReport(target: CGRect(origin: origin, size: size),
                                   frameBeforeWrite: before,
                                   sizeWriteError: success,
                                   positionWriteError: positionError,
                                   readBack: readBack,
                                   outcome: outcome,
                                   didWriteSize: false,
                                   didWritePosition: true)
    }

    /// 取消后的回报：没写的那一侧错误码记"未执行"，写过的一侧与读回事实原样保留。
    private static func cancelledReport(target: CGRect,
                                        before: CGRect?,
                                        wroteSize: Bool,
                                        wrotePosition: Bool,
                                        readBack: CGRect? = nil) -> GeometryWriteReport {
        GeometryWriteReport(target: target, frameBeforeWrite: before,
                            sizeWriteError: wroteSize ? Int(AXError.success.rawValue) : Int(AXError.cannotComplete.rawValue),
                            positionWriteError: wrotePosition ? Int(AXError.success.rawValue) : Int(AXError.cannotComplete.rawValue),
                            readBack: readBack,
                            outcome: .cancelled(wroteSize: wroteSize, wrotePosition: wrotePosition, readBack: readBack),
                            didWriteSize: wroteSize, didWritePosition: wrotePosition)
    }

    private func waitForGate(_ gate: Gate) async {
        lock.lock()
        guard armedGates.contains(gate) else { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            armedGates.remove(gate)
            pendingGate = gate
            pendingResume = continuation
            lock.unlock()
        }
    }

    func raise(element: AXUIElement) async -> Bool {
        lock.lock(); raises += 1; lock.unlock()
        return true
    }

    func focus(element: AXUIElement) async -> Bool {
        lock.lock()
        focuses += 1
        // 读回的是"应用当前认为的 focused window"：可以是被兄弟窗口占着。
        let key = Self.key(of: element)
        let call = (focusCalls[key] ?? 0) + 1
        focusCalls[key] = call
        let held = siblingKeepsFocus
            || siblingHoldsFocusFor.contains(key)
            || (siblingHoldsFocusFromCall[key].map { call >= $0 } ?? false)
        focusedByPID[Int(Self.pid(of: element))] = held ? Self.sibling : element
        lock.unlock()
        return true
    }

    /// 置位后：写焦点成功，但读回永远是另一个元素（同应用兄弟窗口仍在前面的情形）。
    var siblingKeepsFocus = false
    /// 前景化失败要能只落在某一个窗口上：方案 §18 A08 是"目标窗口自己前景化失败"，
    /// 而补偿阶段还要把原主重新提到前面——全局置位会把这两次混成一次，判据就不成立了。
    private var siblingHoldsFocusFor: Set<Int> = []
    /// 同一窗口的第 n 次前景化起才失败：A09 要的就是"首次前景确认通过、写回原主后复核失败"。
    private var siblingHoldsFocusFromCall: [Int: Int] = [:]
    private var focusCalls: [Int: Int] = [:]

    /// 只让这个句柄的前景读回被兄弟窗口占住（`fromCall` 表示从第几次前景化开始）。
    func setSiblingHoldingFocus(_ value: Bool, for element: AXUIElement, fromCall: Int? = nil) {
        lock.lock()
        let key = Self.key(of: element)
        if value {
            if let fromCall { siblingHoldsFocusFromCall[key] = fromCall } else { siblingHoldsFocusFor.insert(key) }
        } else {
            siblingHoldsFocusFor.remove(key)
            siblingHoldsFocusFromCall.removeValue(forKey: key)
        }
        lock.unlock()
    }

    /// 该句柄到现在为止被前景化过几次：测试用它确认失败真的落在预期的那一次上。
    func focusCallCount(for element: AXUIElement) -> Int {
        lock.lock(); defer { lock.unlock() }
        return focusCalls[Self.key(of: element)] ?? 0
    }

    func setExternalFocus(_ element: AXUIElement, pid: pid_t) {
        lock.lock(); focusedByPID[Int(pid)] = element; lock.unlock()
    }

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
    /// true 时"重新最小化"写入成功但读回不变：补偿想把窗口收回去却收不回来。
    var refusesMinimize = false

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

    func setMinimized(_ minimized: Bool, element: AXUIElement, permit: GeometryWritePermit) async -> MinimizeWriteOutcome {
        await waitForMinimizeGate()
        lock.lock()
        // 与真实 AX 队列同一条规则：命令已经排到队列头，真正执行前再查一次许可。
        // 撤销后这里必须"零执行"，而不是先改状态再报告失败（方案 §5.2）。
        guard permit.isGranted else {
            lock.unlock()
            return .refused(reason: "写入许可已撤销")
        }
        unminimizeCount += 1
        actions.append(minimized ? "最小化" : "解除最小化")
        let key = Self.key(of: element)
        // 拒绝的脚本模拟真实失败：属性写入本身不报错，但读回还是原来的值。
        let refused = (minimized ? refusesMinimize : refusesUnminimize)
        if !refused { self.minimized[key] = minimized }
        let readBack = self.minimized[key] ?? false
        lock.unlock()
        return readBack == minimized ? .changed : .notApplied(reason: "写后读回仍是最小化=\(readBack)")
    }

    // MARK: 最小化写入的挂起点

    /// 与几何写入的 `.entry` 门同一个位置：AX 调用还没开始那一刻。
    /// 取消必须拦得住这一半——放行后不得发生迟到的解除最小化（方案 §5.2、§18）。
    private var armedMinimizeGate = false
    private var pendingMinimizeResume: CheckedContinuation<Void, Never>?

    /// true 时下一次最小化写入停在"AX 调用还没开始"这一刻，直到 `openMinimizeGate()`。
    var gatesNextMinimize: Bool {
        get { lock.lock(); defer { lock.unlock() }; return armedMinimizeGate }
        set {
            lock.lock(); armedMinimizeGate = newValue; lock.unlock()
        }
    }

    var isBlockedInMinimize: Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingMinimizeResume != nil
    }

    func openMinimizeGate() {
        lock.lock()
        let resume = pendingMinimizeResume
        pendingMinimizeResume = nil
        armedMinimizeGate = false
        lock.unlock()
        resume?.resume()
    }

    private func waitForMinimizeGate() async {
        lock.lock()
        guard armedMinimizeGate else { lock.unlock(); return }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            armedMinimizeGate = false
            pendingMinimizeResume = continuation
            lock.unlock()
        }
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

    private static func key(of element: AXUIElement) -> Int { Int(CFHash(element)) }
}
