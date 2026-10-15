import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VistileCore

/// 目录来源：SCShareableContent 决定"能不能真的捕获"，CGWindowList 补 alpha/layer/sharing，
/// AX 提供可控性与几何事实。三者缺一不可，任一读不到都按能力分级降级。
struct CatalogInputs {
    let captureSnapshots: [CaptureWindowSnapshot]
    let capturableIDs: Set<UInt32>
    let windowsByID: [UInt32: SCWindow]
}

/// 窗口目录：发现、身份、一对一关联、显示归属与保守的 Space 判定（方案 §6）。
/// 记录与句柄表只在主 Actor 上成组发布，捕获层与几何层读到的永远是同一代次。
@MainActor
final class WindowCatalog {
    var onRecords: (([WindowRecord], UInt64, DiscoveryReason) -> Void)?
    var onStatus: ((String) -> Void)?
    var isExcludedBundle: (String?) -> Bool = { _ in false }

    private let permissions: PermissionManager
    private let resolver: AXWindowResolver
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier
    /// 自己的总览/动画窗口统一排除，阻止无限镜像（方案 §6.9）。
    private var ownWindowIDs: Set<UInt32> = []
    private(set) var records: [WindowIdentity: WindowRecord] = [:]
    /// 显示器事实与捕获权限无关，启动就有值：不能因为一次查询失败就连屏幕都"看不见"。
    private(set) var mapper = CoordinateMapper(displays: DisplayReader.displayInfos())

    private var isInFlight = false
    private var pendingReason: DiscoveryReason?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var generation: UInt64 = 0
    /// 捕获层与几何层需要的句柄表，只在同一次代次内有效。
    private(set) var scWindows: [UInt32: SCWindow] = [:]
    private(set) var axEntries: [pid_t: [AXWindowEntry]] = [:]

    func scWindow(for identity: WindowIdentity) -> SCWindow? { scWindows[identity.windowID] }

    func axEntry(for record: WindowRecord) -> AXWindowEntry? {
        guard let index = record.confidence.resolvedAXIndex else { return nil }
        return axEntries[record.identity.processID]?.first { $0.snapshot.index == index }
    }

    /// AX 通知只给元素，不给窗口编号：用同一代次的句柄表反查身份。
    func record(forAXElement element: AXUIElement, processID pid: pid_t) -> WindowRecord? {
        guard let entries = axEntries[pid] else { return nil }
        for entry in entries where CFEqual(entry.element, element) {
            if let record = records.values.first(where: {
                $0.identity.processID == pid && $0.confidence.resolvedAXIndex == entry.snapshot.index
            }) {
                return record
            }
        }
        return nil
    }

    init(permissions: PermissionManager, resolver: AXWindowResolver = AXWindowResolver()) {
        self.permissions = permissions
        self.resolver = resolver
    }

    func registerOwnWindow(id: UInt32) { ownWindowIDs.insert(id) }
    func forgetOwnWindow(id: UInt32) { ownWindowIDs.remove(id) }

    var currentRecords: [WindowRecord] {
        records.values.sorted {
            (($0.slot?.index ?? .max), $0.identity.windowID) < (($1.slot?.index ?? .max), $1.identity.windowID)
        }
    }

    func record(for identity: WindowIdentity) -> WindowRecord? { records[identity] }

    // MARK: - 刷新

    /// 一次查询仍在进行时不再叠加；结束后把排队原因合并成一次（方案 §6.7）。
    func refresh(reason: DiscoveryReason) {
        if isInFlight {
            pendingReason = reason
            onStatus?("discover queued: \(reason.rawValue)")
            return
        }
        isInFlight = true
        Task { [weak self] in
            await self?.run(reason: reason)
        }
    }

    /// 恢复流程必须基于最新记录做判定，因此它要等这一次查询真正结束。
    func refreshAndWait(reason: DiscoveryReason) async {
        if isInFlight {
            await withCheckedContinuation { waiters.append($0) }
        }
        isInFlight = true
        await run(reason: reason)
    }

    private func run(reason: DiscoveryReason) async {
        let output = await build(reason: reason)
        if let output { publish(output) } else {
            onStatus?("discover unavailable: \(reason.rawValue)")
        }
        isInFlight = false
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
        drainQueuedRefresh()
    }

    private func drainQueuedRefresh() {
        guard let reason = pendingReason else { return }
        pendingReason = nil
        refresh(reason: reason)
    }

    private func publish(_ output: CatalogOutput) {
        mapper = CoordinateMapper(displays: DisplayReader.displayInfos())
        generation = max(generation, output.generation)
        scWindows = output.scWindows
        axEntries = output.axEntries
        // 上一轮已确认关闭的身份不再累积。
        records = records.filter { $0.value.capture != .closed }
        for record in output.records { records[record.identity] = record }
        onRecords?(output.records, output.generation, output.reason)
    }

    /// 显示器配置变化后重建映射（方案 §12）。
    func rebuildDisplayMapping() {
        mapper = CoordinateMapper(displays: DisplayReader.displayInfos())
    }

    struct CatalogOutput {
        let records: [WindowRecord]
        let generation: UInt64
        let reason: DiscoveryReason
        /// 句柄表与记录同代次发布，消费方不会拿到跨代次的窗口对象。
        let scWindows: [UInt32: SCWindow]
        let axEntries: [pid_t: [AXWindowEntry]]
    }

    private func build(reason: DiscoveryReason) async -> CatalogOutput? {
        let nextGeneration = generation &+ 1
        guard permissions.isGranted(.screenRecording) else {
            onStatus?("screen recording permission missing")
            return permissionMissingOutput(generation: nextGeneration, reason: reason)
        }
        guard let content = await shareableContent() else { return nil }

        let cg = cgWindowInformation()
        let inputs = snapshots(content: content, cg: cg)
        let mapper = CoordinateMapper(displays: DisplayReader.displayInfos())
        self.mapper = mapper
        var freshAX: [pid_t: [AXWindowEntry]] = [:]

        var output: [WindowRecord] = []
        var seen: Set<WindowIdentity> = []
        let byProcess = Dictionary(grouping: inputs.captureSnapshots, by: { $0.identity.processID })

        // 只对确实有候选窗口的进程读 AX，跨进程调用有超时上限。
        for (pid, snapshots) in byProcess.sorted(by: { $0.key < $1.key }) {
            let eligible = snapshots.filter { isIncluded($0) }
            guard !eligible.isEmpty else { continue }
            let entries = await resolver.windows(pid: pid)
            freshAX[pid] = entries
            let axSnapshots = entries.map(\.snapshot).filter { !$0.isSheetLike }
            let confidence = WindowMatcher.match(capture: eligible, ax: axSnapshots)

            for snapshot in eligible {
                let matched = confidence[snapshot.identity] ?? .unmatched
                let entry = matched.resolvedAXIndex.flatMap { index in entries.first { $0.snapshot.index == index } }
                output.append(makeRecord(snapshot: snapshot,
                                         ax: entry,
                                         confidence: matched,
                                         capturable: inputs.capturableIDs.contains(snapshot.identity.windowID),
                                         mapper: mapper,
                                         generation: nextGeneration))
                seen.insert(snapshot.identity)
            }
        }

        // 本轮未再出现的旧身份：只有"AX 也读不到且捕获列表也没有"才判为关闭。
        for (identity, stale) in records where !seen.contains(identity) && stale.capture != .closed {
            let stillTracked = inputs.captureSnapshots.contains { $0.identity == identity }
            if !stillTracked, stale.capture != .permissionMissing {
                var closed = stale
                closed.capture = .closed
                closed.sessionGeneration = nextGeneration
                output.append(closed)
            } else {
                // 读不到不等于消失：保留原记录，只更新代次，卡片继续显示最后一帧。
                var kept = stale
                kept.sessionGeneration = nextGeneration
                output.append(kept)
            }
        }

        return CatalogOutput(records: output,
                             generation: nextGeneration,
                             reason: reason,
                             scWindows: inputs.windowsByID,
                             axEntries: freshAX)
    }

    private func permissionMissingOutput(generation: UInt64,
                                         reason: DiscoveryReason) -> CatalogOutput? {
        var updated: [WindowRecord] = []
        for (_, record) in records where record.capture != .closed {
            var copy = record
            copy.capture = .permissionMissing
            copy.sessionGeneration = generation
            updated.append(copy)
        }
        return updated.isEmpty ? nil : CatalogOutput(records: updated,
                                                     generation: generation,
                                                     reason: reason,
                                                     scWindows: [:],
                                                     axEntries: [:])
    }

    private func isIncluded(_ snapshot: CaptureWindowSnapshot) -> Bool {
        let eligibility = WindowEligibilityRules.evaluate(snapshot,
                                                          ownProcessIDs: [ownProcessID],
                                                          ownWindowIDs: ownWindowIDs)
        guard eligibility.isIncluded else { return false }
        return !isExcludedBundle(snapshot.bundleID)
    }

    // MARK: - 来源读取

    private func shareableContent() async -> SCShareableContent? {
        await withCheckedContinuation { continuation in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let error {
                    let message = (error as Error).localizedDescription
                    // 回调不在主线程：状态文字要回主线程，不能直接碰 @MainActor 的属性。
                    Task { @MainActor in self.onStatus?("SCShareableContent failed: \(message)") }
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: content)
                }
            }
        }
    }

    private func cgWindowInformation() -> [UInt32: [String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [UInt32: [String: Any]] = [:]
        result.reserveCapacity(list.count)
        for info in list {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            result[number.uint32Value] = info
        }
        return result
    }

    private func snapshots(content: SCShareableContent, cg: [UInt32: [String: Any]]) -> CatalogInputs {
        var captureSnapshots: [CaptureWindowSnapshot] = []
        var capturable: Set<UInt32> = []
        var windowsByID: [UInt32: SCWindow] = [:]
        captureSnapshots.reserveCapacity(content.windows.count)

        for window in content.windows {
            // 本 SDK 的 SCWindow 不提供 windowType：只用 CG 的 layer 过滤桌面元素（§6.2 三重来源）。
            let id = UInt32(window.windowID)
            capturable.insert(id)
            windowsByID[id] = window
            let pid = window.owningApplication?.processID ?? 0
            let info = cg[id]
            captureSnapshots.append(CaptureWindowSnapshot(
                identity: identity(pid: pid, windowID: id),
                frame: window.frame,
                title: window.title ?? "",
                ownerName: window.owningApplication?.applicationName ?? "",
                bundleID: window.owningApplication?.bundleIdentifier,
                layer: Int(window.windowLayer),
                alpha: (info?[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: window.isOnScreen,
                sharingState: (info?[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? 1
            ))
        }

        // CG 列出但 SC 未列出的窗口仍然入目录：只允许预览并明确标记不可捕获。
        for (id, info) in cg where !capturable.contains(id) {
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            captureSnapshots.append(CaptureWindowSnapshot(
                identity: identity(pid: pid, windowID: id),
                frame: Self.rect(from: info[kCGWindowBounds as String] as? [String: Any]) ?? .zero,
                title: info[kCGWindowName as String] as? String ?? "",
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                bundleID: nil,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                sharingState: (info[kCGWindowSharingState as String] as? NSNumber)?.intValue ?? 1
            ))
        }
        return CatalogInputs(captureSnapshots: captureSnapshots,
                             capturableIDs: capturable,
                             windowsByID: windowsByID)
    }

    private func identity(pid: pid_t, windowID: UInt32) -> WindowIdentity {
        WindowIdentity(processID: pid,
                       processStartIdentity: ProcessIdentityReader.startIdentity(for: pid),
                       windowID: windowID)
    }

    // MARK: - 记录组装

    private func makeRecord(snapshot: CaptureWindowSnapshot,
                            ax entry: AXWindowEntry?,
                            confidence: MatchConfidence,
                            capturable: Bool,
                            mapper: CoordinateMapper,
                            generation: UInt64) -> WindowRecord {
        let axSnapshot = entry?.snapshot
        let frame = axSnapshot?.frame ?? snapshot.frame
        let owner = mapper.ownerDisplay(of: frame) ?? mapper.primaryDisplay
        let previous = records[snapshot.identity]

        let restriction: WindowRestriction?
        if snapshot.sharingState == 0 {
            restriction = .protectedContent
        } else if looksLikeNativeFullscreen(frame: frame, owner: owner, ax: axSnapshot) {
            restriction = .nativeFullscreen
        } else if axSnapshot?.isMinimized == true {
            restriction = nil
        } else if !snapshot.isOnScreen {
            restriction = .otherSpace
        } else if axSnapshot == nil {
            // 没有 AX 事实时无法确认它属于当前 Space：保守标注，卡片仍保持实时。
            restriction = .spaceUnverified
        } else {
            restriction = nil
        }

        let capture: CapturePhase
        switch restriction {
        case .protectedContent: capture = .notCapturable("应用禁止该窗口被捕获")
        case .some: capture = .idle
        case nil:
            if axSnapshot?.isMinimized == true {
                capture = .pausedMinimized
            } else {
                capture = capturable ? .idle : .notCapturable("ScreenCaptureKit 未列出该窗口")
            }
        }

        let record = WindowRecord(identity: snapshot.identity,
                                  bundleID: snapshot.bundleID,
                                  applicationName: snapshot.ownerName,
                                  title: axSnapshot?.title ?? snapshot.title,
                                  axSnapshot: axSnapshot,
                                  confidence: confidence,
                                  frame: frame,
                                  displayID: owner?.id ?? 0,
                                  isMinimized: axSnapshot?.isMinimized ?? false,
                                  isMovable: axSnapshot?.isMovable ?? false,
                                  isResizable: axSnapshot?.isResizable ?? false,
                                  capture: capture,
                                  slot: previous?.slot,
                                  lastValidFrameDate: previous?.lastValidFrameDate,
                                  sessionGeneration: generation,
                                  prefersHighRefresh: previous?.prefersHighRefresh ?? false,
                                  restriction: restriction)
        return merged(previous, with: record)
    }

    /// 标题变化、源尺寸变化都不应重置 slot、最后画面时间与优先级；reconcile 也不能把 live 降级。
    private func merged(_ previous: WindowRecord?, with next: WindowRecord) -> WindowRecord {
        guard let previous else { return next }
        var result = next
        result.slot = next.slot ?? previous.slot
        result.lastValidFrameDate = next.lastValidFrameDate ?? previous.lastValidFrameDate
        result.prefersHighRefresh = next.prefersHighRefresh || previous.prefersHighRefresh
        switch previous.capture {
        case .live, .lowFrequency, .starting:
            if result.capture == .idle { result.capture = previous.capture }
        default:
            break
        }
        return result
    }

    private func looksLikeNativeFullscreen(frame: CGRect, owner: DisplayInfo?, ax: AXWindowSnapshot?) -> Bool {
        guard let owner, let ax else { return false }
        guard ax.isMovable == false, ax.isResizable == false else { return false }
        return abs(frame.minX - owner.frame.minX) <= 2
            && abs(frame.minY - owner.frame.minY) <= 2
            && abs(frame.width - owner.frame.width) <= 2
            && abs(frame.height - owner.frame.height) <= 2
    }

    static func rect(from dictionary: Any?) -> CGRect? {
        guard let dictionary = dictionary as? [String: Any],
              let x = dictionary["X"] as? NSNumber,
              let y = dictionary["Y"] as? NSNumber,
              let width = dictionary["Width"] as? NSNumber,
              let height = dictionary["Height"] as? NSNumber else { return nil }
        return CGRect(x: x.doubleValue, y: y.doubleValue, width: width.doubleValue, height: height.doubleValue)
    }
}

/// 屏幕事实读取：负坐标、上下排列与不同 Retina scale 都保留原始 frame。
enum DisplayReader {
    static func displayInfos() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(id: number.uint32Value,
                               frame: cgFrame(of: screen.frame, primary: primary),
                               visibleFrame: cgFrame(of: screen.visibleFrame, primary: primary),
                               backingScale: screen.backingScaleFactor,
                               isPrimary: screen === primary)
        }
    }

    /// NSScreen 是 AppKit 左下原点；领域层统一使用 CG 全局坐标（以主屏高度翻转一次）。
    private static func cgFrame(of rect: CGRect, primary: NSScreen) -> CGRect {
        CGRect(x: rect.minX, y: primary.frame.height - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    static func visibleFrameCG(displayID: UInt32) -> CGRect? {
        displayInfos().first { $0.id == displayID }?.visibleFrame
    }
}
