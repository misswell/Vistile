import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import VistileCore

/// 一次来源读取拿到的原始事实：候选窗口 + 可捕获编号 + 捕获用的 SCWindow 句柄。
/// 捕获来源决定"能不能真的捕获"，CG 补 alpha/layer/sharing，AX 提供可控性与几何事实；
/// 三者缺一不可，任一读不到都按能力分级降级。
struct CatalogContent {
    let snapshots: [CaptureWindowSnapshot]
    let capturableIDs: Set<UInt32>
    let scWindows: [UInt32: SCWindow]
}

/// 来源读取的结果：失败必须带上可显示的原因，不能与"没有窗口"混成同一种回报（方案 §5.2）。
enum CatalogContentResult {
    case loaded(CatalogContent)
    case failed(DiscoveryFailure)
}

/// 窗口来源协议：生产用 ScreenCaptureKit + CGWindowList，宿主测试注入固定事实（方案 §15.1）。
/// 没有这层协议，宿主测试只能对着真桌面跑，交错类回归（T06/T07）就无法确定性地复现。
protocol CatalogContentSource {
    func load() async -> CatalogContentResult
}

/// AX 句柄来源协议：生产用真实跨进程读取，测试注入固定句柄表。
protocol CatalogAXSource {
    func windows(pid: pid_t) async -> [AXWindowEntry]
}

extension AXWindowResolver: CatalogAXSource {}

/// 模态 Sheet 检查协议：生产按"窗口 child 里有没有 role=AXSheet"读公开属性，宿主测试注入固定事实（方案 §8.2.4）。
protocol CatalogSheetSource {
    func hasAttachedSheet(element: AXUIElement) async -> Bool
}

extension AXWindowResolver: CatalogSheetSource {}

/// 屏幕事实来源：生产读 NSScreen，宿主测试注入固定显示器（方案 §15.1）。
/// 恢复判定要看"原显示器是否还活着"，让它依赖真实桌面就没法做确定性回归。
protocol DisplayInfoSource {
    func displayInfos() -> [DisplayInfo]
}

struct ScreenDisplaySource: DisplayInfoSource {
    func displayInfos() -> [DisplayInfo] { DisplayReader.displayInfos() }
}

/// 一次目录发布的完整事实（方案 §8.3）：新增/更新、确定销毁、暂时读不到分开表达，
/// 避免"以 .closed 记录伪装删除"和"从 records 里悄悄消失"两套生命周期并存。
struct CatalogUpdate {
    let upserts: [WindowRecord]
    /// 本轮确认不存在的窗口：调用方必须走统一的 .windowClosed 路径。
    let removals: [WindowIdentity]
    /// 仍在但读不到 AX 句柄的窗口：卡片保留，不能当成关闭。
    let transientUnavailable: [WindowIdentity]
}

/// 窗口目录：发现、身份、一对一关联、显示归属与保守的 Space 判定（方案 §6）。
/// 记录与句柄表只在主 Actor 上成组发布，捕获层与几何层读到的永远是同一代次。
@MainActor
final class WindowCatalog {
    /// 发布必须携带本次查询对应的请求：旧会话/旧请求的结果不得进入当前状态机（方案 §5.2）。
    /// request 为 nil 表示这次发布不属于任何会话请求（例如启动恢复前的目录建立）。
    var onRecords: ((CatalogUpdate, DiscoveryRequest?) -> Void)?
    /// 失败同样是"这一次请求有结果"：必须让 in-flight 解锁，不能只靠成功路径（方案 §5.2）。
    var onFailure: ((DiscoveryRequest?, DiscoveryFailure) -> Void)?
    var onStatus: ((String) -> Void)?
    var isExcludedBundle: (String?) -> Bool = { _ in false }

    private let permissions: PermissionChecking
    private let axSource: CatalogAXSource
    private let contentSource: CatalogContentSource
    private let displaySource: DisplayInfoSource
    private let sheetSource: CatalogSheetSource
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier
    /// 自己的总览/动画窗口统一排除，阻止无限镜像（方案 §6.9）。
    private var ownWindowIDs: Set<UInt32> = []
    private(set) var records: [WindowIdentity: WindowRecord] = [:]
    /// 确认销毁过的身份：恢复执行器据此把事务结算为"窗口已消失"，而不是无限重试。
    private(set) var confirmedGone: Set<WindowIdentity> = []
    /// 显示器事实与捕获权限无关，启动就有值：不能因为一次查询失败就连屏幕都"看不见"。
    private(set) var mapper: CoordinateMapper

    private var isInFlight = false
    private var pendingReason: DiscoveryReason?
    /// 合并排队期间仍要记住"哪些请求在等结果"：一次查询可能同时答复多个请求。
    private var outstanding: [DiscoveryRequest] = []
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

    /// 句柄表是"上一次发布"的快照：窗口正在移动时，两侧 frame 可能还没对齐，
    /// 一次坏采样会把窗口判成未唯一；实机还观察到捕捉权限查询会成串短暂被拒（0.5–1s），
    /// 期间每一轮目录都答"未唯一"——单次复核会把环境抖动当成窗口事实。
    /// 写入方拿不到句柄时在截止时间内反复复核（不消耗点击路径的 8 轮预算，因为它有独立时限）；
    /// 预算用尽仍拿不到才返回 nil，由调用方按事实拒绝（方案 §6.1、§6.2）。
    static let axConfirmBudget: TimeInterval = 2.0

    func axEntryAfterReview(for record: WindowRecord, reason: DiscoveryReason = .windowEvent) async -> AXWindowEntry? {
        if let entry = axEntry(for: record) { return entry }
        let deadline = Date().addingTimeInterval(Self.axConfirmBudget)
        while Date() < deadline {
            await refreshAndWait(reason: reason)
            if let fresh = self.record(for: record.identity), let entry = axEntry(for: fresh) {
                return entry
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
        return nil
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

    init(permissions: PermissionChecking,
         resolver: AXWindowResolver = AXWindowResolver(),
         axSource: CatalogAXSource? = nil,
         contentSource: CatalogContentSource = ScreenCaptureContentSource(),
         displaySource: DisplayInfoSource = ScreenDisplaySource(),
         sheetSource: CatalogSheetSource? = nil) {
        self.permissions = permissions
        self.axSource = axSource ?? resolver
        self.contentSource = contentSource
        self.displaySource = displaySource
        self.sheetSource = sheetSource ?? resolver
        self.mapper = CoordinateMapper(displays: displaySource.displayInfos())
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
    /// 合并期间登记的请求全部算"这次查询的答复"，否则先到的请求会被永久卡住。
    func refresh(reason: DiscoveryReason, request: DiscoveryRequest? = nil) {
        if let request { outstanding.append(request) }
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
    /// 循环等待：合并排队的下一轮查询开始时不能插队并发跑。
    func refreshAndWait(reason: DiscoveryReason, request: DiscoveryRequest? = nil) async {
        if let request { outstanding.append(request) }
        while isInFlight {
            await withCheckedContinuation { waiters.append($0) }
        }
        isInFlight = true
        await run(reason: reason)
    }

    private enum CatalogResult {
        case published(CatalogOutput)
        /// 记录仍然发布（例如权限被收回要标记降级），但这次请求要按失败回报，不能假装成功。
        case degraded(CatalogOutput, DiscoveryFailure)
        case failure(DiscoveryFailure)
    }

    private func run(reason: DiscoveryReason) async {
        let requests = outstanding
        outstanding.removeAll()
        let result = await build(reason: reason)
        switch result {
        case .published(let output):
            publish(output)
            if requests.isEmpty { onRecords?(output.update, nil) }
            for request in requests { onRecords?(output.update, request) }
        case .degraded(let output, let failure):
            publish(output)
            report(failure: failure, requests: requests)
        case .failure(let failure):
            report(failure: failure, requests: requests)
        }
        isInFlight = false
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
        drainQueuedRefresh()
    }

    private func report(failure: DiscoveryFailure, requests: [DiscoveryRequest]) {
        onStatus?("discover failed: \(failure.message)")
        guard !requests.isEmpty else { onFailure?(nil, failure); return }
        for request in requests { onFailure?(request, failure) }
    }

    private func drainQueuedRefresh() {
        guard let reason = pendingReason else { return }
        pendingReason = nil
        refresh(reason: reason)
    }

    private func publish(_ output: CatalogOutput) {
        mapper = CoordinateMapper(displays: displaySource.displayInfos())
        generation = max(generation, output.generation)
        scWindows = output.scWindows
        axEntries = output.axEntries
        // 确定销毁的身份从目录消失并被记住；再次出现即撤销该结论。
        for identity in output.update.removals {
            records.removeValue(forKey: identity)
            confirmedGone.insert(identity)
        }
        for record in output.update.upserts {
            records[record.identity] = record
            confirmedGone.remove(record.identity)
        }
    }

    /// 只有目录明确回报"这一轮捕获列表里也没有"才算确认销毁（方案 §8.3）。
    func isConfirmedGone(_ identity: WindowIdentity) -> Bool { confirmedGone.contains(identity) }

    /// 该窗口此刻是否挂着需要用户处理的 Sheet（方案 §8.2.4）。
    /// 句柄或事实读不到时按"没有"回答：拒绝写入必须基于确凿事实，不能靠猜。
    func hasBlockingSheet(identity: WindowIdentity) async -> Bool {
        guard let record = records[identity], let ax = axEntry(for: record) else { return false }
        return await sheetSource.hasAttachedSheet(element: ax.element)
    }

    /// 显示器配置变化后重建映射（方案 §12）。
    func rebuildDisplayMapping() {
        mapper = CoordinateMapper(displays: displaySource.displayInfos())
    }

    struct CatalogOutput {
        let update: CatalogUpdate
        let generation: UInt64
        let reason: DiscoveryReason
        /// 句柄表与记录同代次发布，消费方不会拿到跨代次的窗口对象。
        let scWindows: [UInt32: SCWindow]
        let axEntries: [pid_t: [AXWindowEntry]]
    }

    private func build(reason: DiscoveryReason) async -> CatalogResult {
        let nextGeneration = generation &+ 1
        guard permissions.status.screenRecording else {
            onStatus?("screen recording permission missing")
            let degraded = permissionMissingOutput(generation: nextGeneration, reason: reason)
            let failure = DiscoveryFailure.permissionMissing(.screenRecording)
            if let degraded { return .degraded(degraded, failure) }
            return .failure(failure)
        }
        let inputs: CatalogContent
        switch await contentSource.load() {
        case .loaded(let loaded): inputs = loaded
        case .failed(let failure): return .failure(failure)
        }
        let mapper = CoordinateMapper(displays: displaySource.displayInfos())
        self.mapper = mapper
        var freshAX: [pid_t: [AXWindowEntry]] = [:]

        var output: [WindowRecord] = []
        var seen: Set<WindowIdentity> = []
        let byProcess = Dictionary(grouping: inputs.snapshots, by: { $0.identity.processID })

        // 只对确实有候选窗口的进程读 AX，跨进程调用有超时上限。
        for (pid, snapshots) in byProcess.sorted(by: { $0.key < $1.key }) {
            let eligible = snapshots.filter { isIncluded($0) }
            guard !eligible.isEmpty else { continue }
            let entries = await axSource.windows(pid: pid)
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

        // 本轮未再出现的旧身份：只有"捕获列表也没有"才判为确定销毁。
        var removals: [WindowIdentity] = []
        var transientUnavailable: [WindowIdentity] = []
        for (identity, stale) in records where !seen.contains(identity) {
            let stillTracked = inputs.snapshots.contains { $0.identity == identity }
            if !stillTracked, stale.capture != .permissionMissing {
                removals.append(identity)
            } else {
                // 读不到不等于消失：保留原记录，只更新代次，卡片继续显示最后一帧。
                var kept = stale
                kept.sessionGeneration = nextGeneration
                output.append(kept)
                transientUnavailable.append(identity)
            }
        }

        let catalogOutput = CatalogOutput(update: CatalogUpdate(upserts: output,
                                                                removals: removals,
                                                                transientUnavailable: transientUnavailable),
                                          generation: nextGeneration,
                                          reason: reason,
                                          scWindows: inputs.scWindows,
                                          axEntries: freshAX)

        // 没有任何一个候选窗口通过筛选：要说"没有可用的窗口"，不能显示空白面板当作成功（方案 §5.2）。
        if seen.isEmpty, reason == .shortcut {
            return .degraded(catalogOutput, .emptyCatalog)
        }
        return .published(catalogOutput)
    }

    private func permissionMissingOutput(generation: UInt64,
                                         reason: DiscoveryReason) -> CatalogOutput? {
        var updated: [WindowRecord] = []
        for (_, record) in records {
            var copy = record
            copy.capture = .permissionMissing
            copy.sessionGeneration = generation
            updated.append(copy)
        }
        return updated.isEmpty ? nil : CatalogOutput(update: CatalogUpdate(upserts: updated,
                                                                           removals: [],
                                                                           transientUnavailable: []),
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
}

/// 生产用的窗口来源：SCShareableContent 给出"能被真正捕获"的集合，
/// CGWindowList 补 alpha/layer/sharing，AX 的可控性事实由目录另行读取。
/// 查询失败必须带原因上抛：把"读不到"和"没有窗口"混成空数组会谎报成功（方案 §5.2）。
struct ScreenCaptureContentSource: CatalogContentSource {
    func load() async -> CatalogContentResult {
        switch await shareableContent() {
        case .failed(let failure): return .failed(failure)
        case .loaded(let content):
            let cg = cgWindowInformation()
            return .loaded(snapshots(content: content, cg: cg))
        }
    }

    private enum Content {
        case loaded(SCShareableContent)
        case failed(DiscoveryFailure)
    }

    private func shareableContent() async -> Content {
        await withCheckedContinuation { continuation in
            SCShareableContent.getWithCompletionHandler { content, error in
                if let error {
                    continuation.resume(returning: .failed(.contentUnavailable((error as Error).localizedDescription)))
                } else if let content {
                    continuation.resume(returning: .loaded(content))
                } else {
                    continuation.resume(returning: .failed(.contentUnavailable("接口返回空内容且没有错误")))
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

    private func snapshots(content: SCShareableContent, cg: [UInt32: [String: Any]]) -> CatalogContent {
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
        return CatalogContent(snapshots: captureSnapshots,
                              capturableIDs: capturable,
                              scWindows: windowsByID)
    }

    private func identity(pid: pid_t, windowID: UInt32) -> WindowIdentity {
        WindowIdentity(processID: pid,
                       processStartIdentity: ProcessIdentityReader.startIdentity(for: pid),
                       windowID: windowID)
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
