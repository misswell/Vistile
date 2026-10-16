import AppKit
import CoreGraphics
import Darwin
import Foundation
import VistileCore

/// P0 灰盒探针（方案 §4）。
///
/// 划分原则：能在进程内拿到客观证据的（窗口顺序、帧计数、身份映射、状态机反应）才写通过/失败；
/// 必须由肉眼或录屏确认的（画面是否串、中文输入、保存面板）一律写"未测"并附复现步骤。
/// "函数返回没有报错"不作为任何一项的通过条件。
@MainActor
final class P0Probe {
    private let coordinator: AppCoordinator
    private let recorder: CompatibilityRecorder
    private let settings: SettingsModel

    private var job: Task<Void, Never>?
    private var checklist: [Item] = []

    /// 一轮探针跑完后的收尾动作：命令行运行时用它把应用退出，保证一次调用得到一份产物。
    var onFinished: (() -> Void)?

    struct Item {
        let id: String
        let title: String
        /// 自动项写结论，人工项写"未测"。
        let verdict: String
        let detail: String
        let isManual: Bool
    }

    init(coordinator: AppCoordinator, recorder: CompatibilityRecorder, settings: SettingsModel) {
        self.coordinator = coordinator
        self.recorder = recorder
        self.settings = settings
    }

    func begin() {
        guard job == nil else { return }
        job = Task { [weak self] in await self?.run() }
    }

    // MARK: - 序列

    private func run() async {
        recorder.note("P0 探针运行中：自动项记录客观证据，人工项保持未测")
        // 权限是解释后续结论的前提，必须作为事实写进报告，否则"窗口 0 个"会被误读成程序坏了。
        let granted = coordinator.permissions.refresh()
        recorder.record("P0-0 系统权限",
                        subject: "屏幕录制 / 辅助功能",
                        result: granted.isComplete ? .passed : .blocked,
                        detail: "屏幕录制=\(granted.screenRecording)，辅助功能=\(granted.accessibility)；"
                             + "缺任一项时后续自动项只能记为未测或失败")
        await showOverview()
        await p0_1_catalogAndIdentity()
        await p0_2_liveWhileOccluded()
        await p0_3_raiseOnlyTarget()
        await p0_4_nativeForegroundInput()
        await p0_5_backgroundClickSoak()
        await p0_6_identityReuse()
        await p0_7_multiDisplay()
        await p0_8FailureModes()
        await p0_9_realViewChain()
        await p0_10_orderingFacts()
        await p0_11_trustedToken()
        await performanceSample()
        if coordinator.state.phase == .hidden { await showOverview() }
        recorder.record("P0 汇总", subject: "自动 \(autoCount) 项 / 人工 \(checklist.filter(\.isManual).count) 项",
                        result: autoFailures == 0 ? .unverified : .failed,
                        detail: autoFailures == 0
                            ? "自动项未发现失败；跨应用交互仍需按验收清单肉眼与录屏确认"
                            : "有 \(autoFailures) 个自动项失败，见对应条目")
        writeChecklist()
        // onFinished 走的是 NSApp.terminate：它就地等 applicationShouldTerminate 的 reply，
        // 而 reply 只能靠主队列排空送达。探针跑完时主线程正卡在 main queue 的 drain 里，
        // 就地调用会把 drain 占死、reply 永远排不上（0.1.2 实测两次挂死）。
        // 交给 run loop 的观察点执行：退出请求发出时当前 drain 已经返回。
        let finish = onFinished
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { finish?() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    private var autoCount: Int { checklist.filter { !$0.isManual }.count }
    private var autoFailures: Int { checklist.filter { !$0.isManual && $0.verdict.contains("失败") }.count }

    private func showOverview() async {
        if coordinator.state.phase != .hidden { return }
        coordinator.toggleOverview()
        _ = await waitUntil { self.coordinator.state.phase.isVisible && !self.coordinator.state.records.isEmpty }
    }

    // MARK: - P0-1 目录与身份

    private func p0_1_catalogAndIdentity() async {
        let records = Array(coordinator.state.records.values)
        let apps = Dictionary(grouping: records, by: { $0.identity.processID })
        let multiWindowApps = apps.filter { $0.value.count >= 2 }
        let windowIDs = Set(records.map(\.identity.windowID))
        let axIndexes = records.compactMap { $0.confidence.resolvedAXIndex }
        let injectiveAX = Set(axIndexes).count == axIndexes.count
        let uniqueWindowIDs = windowIDs.count == records.count
        let readable = records.filter { $0.confidence.allowsAXWrite }.count

        let detail = "窗口 \(records.count) 个；多窗口进程 \(multiWindowApps.count) 个；"
            + "AX 唯一对应 \(readable) 个；窗口编号无重复=\(uniqueWindowIDs)；同进程 AX 索引无重复=\(injectiveAX)"
        let passed = records.count >= 6 && uniqueWindowIDs && injectiveAX
        let blocked = permissionNote(.screenRecording)
        record("P0-1", "目录与身份",
               passed: blocked == nil ? passed : nil,
               detail: blocked ?? (records.count < 6 ? "窗口不足 6 个，先打开更多窗口再跑：\(detail)" : detail),
               check: "P0-1 目录与身份")
        manual("P0-1", "画面没有串",
               "打开两个 Safari 与两个 Finder 窗口，逐个点卡片，录屏确认每张卡片内容与放大后的真实窗口一致。")
        for app in Set(records.map(\.applicationName)).sorted().prefix(12) {
            recorder.updateRow(application: app, version: "",
                               capture: .unverified,
                               association: records.contains(where: { $0.applicationName == app && $0.confidence.allowsAXWrite })
                                   ? .passed : .unverified)
        }
    }

    // MARK: - P0-2 遮挡时仍实时

    private func p0_2_liveWhileOccluded() async {
        let records = Array(coordinator.state.records.values)
        let occluded = records.filter { candidate in
            records.contains { other in
                other.identity != candidate.identity
                    && other.frame.contains(CGPoint(x: candidate.frame.midX, y: candidate.frame.midY))
            }
        }
        guard !occluded.isEmpty else {
            record("P0-2", "遮挡时仍实时", passed: nil,
                   detail: "本机当前没有互相遮挡的窗口，无法制造遮挡场景", check: "P0-2 遮挡时仍实时")
            manual("P0-2", "遮挡时仍实时", "把 Terminal 放在其他窗口下方并让它持续打印，确认卡片跟着变。")
            return
        }
        let before = Dictionary(uniqueKeysWithValues: occluded.map { ($0.identity, coordinator.capture.mailbox(for: $0.identity).publishedCount) })
        let framesA = totalPublished()
        let started = Date()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let grew = occluded.filter { item in
            self.coordinator.capture.mailbox(for: item.identity).publishedCount > (before[item.identity] ?? 0)
        }
        let wall = max(0.001, Date().timeIntervalSince(started))
        let delta = totalPublished() - framesA
        let detail = "被遮挡窗口 \(occluded.count) 个，其中 \(grew.count) 个在 \(String(format: "%.1f", wall))s 内收到新帧；"
            + "全目录帧增量 \(delta)（约 \(String(format: "%.1f", Double(delta) / wall)) 帧/秒）"
        record("P0-2", "遮挡时仍实时",
               passed: delta > 0 && !grew.isEmpty,
               detail: grew.isEmpty && delta > 0
                    ? "总览有帧到达但被遮挡的窗口没有新帧（可能是画面本身没变化）：\(detail)" : detail,
               check: "P0-2 遮挡时仍实时")
        manual("P0-2", "静止窗口不谎报", "确认卡片右上角只在低频或暂停时出现状态文字，实时时不显示任何标注。")
    }

    private func totalPublished() -> Int {
        coordinator.capture.allMailboxes().reduce(0) { $0 + $1.mailbox.publishedCount }
    }

    // MARK: - P0-3 只提升被点窗口

    private func p0_3_raiseOnlyTarget() async {
        let grouped = Dictionary(grouping: Array(coordinator.state.records.values), by: { $0.identity.processID })
        guard let pair = grouped.first(where: { $0.value.count >= 2 })?.value.sorted(by: { $0.identity.windowID < $1.identity.windowID }),
              let target = pair.first, let sibling = pair.last,
              settings.orderingStrategy != .splitBackgroundTiles else {
            record("P0-3", "只提升被点窗口", passed: nil,
                   detail: "本机没有同一应用两个以上窗口，或当前层级策略是背景分块（本探针不覆盖）",
                   check: "P0-3 只提升被点窗口")
            manual("P0-3", "只提升被点窗口", "打开两个 Safari 窗口，点其中一个卡片，录屏确认另一个窗口没有被提到前面。")
            return
        }
        let before = windowOrder()
        coordinator.focus.raiseOnly(target.identity)
        _ = await waitUntil(timeout: 2.0) {
            let after = self.windowOrder()
            return (after[target.identity.windowID] ?? .max) < (before[target.identity.windowID] ?? .max)
        }
        let after = windowOrder()
        let targetIndex = after[target.identity.windowID]
        let siblingIndex = after[sibling.identity.windowID]
        let movedUp = lt(targetIndex, before[target.identity.windowID])
        let siblingNotRaised = !(lt(siblingIndex, before[sibling.identity.windowID]))
        let aboveSibling = lt(targetIndex, siblingIndex)
        let passed = movedUp && siblingNotRaised && aboveSibling
        record("P0-3", "只提升被点窗口", passed: passed,
               detail: "\(target.applicationName) 目标窗口顺序 \(describe(before[target.identity.windowID]))→\(describe(targetIndex))，"
                    + "同应用另一窗口 \(describe(before[sibling.identity.windowID]))→\(describe(siblingIndex))",
               check: "P0-3 只提升被点窗口")
        recorder.updateRow(application: target.applicationName, version: "",
                           ordering: passed ? .passed : .failed,
                           knownLimitation: passed ? nil : "AX Raise 后窗口顺序未如预期")
        manual("P0-3", "背景总览仍可见", "同上场景，录屏确认放大后背景总览没有被隐藏、其他应用窗口没有被误提到前面。")
    }

    /// nil 表示窗口已不在屏幕上；不能把"读不到"当成"排名变好"。
    private func lt(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs < rhs
    }

    private func describe(_ index: Int?) -> String { index.map { "#\($0)" } ?? "不在屏" }

    /// 前台到后台的窗口编号序列，用于窗口顺序诊断（CGWindowList 的返回顺序就是层级顺序）。
    private func windowOrder() -> [UInt32: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }
        var result: [UInt32: Int] = [:]
        for (index, info) in list.enumerated() {
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { continue }
            result[number.uint32Value] = index
        }
        return result
    }

    // MARK: - P0-4 原生前台输入

    private func p0_4_nativeForegroundInput() async {
        guard coordinator.permissions.status.accessibility else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: "未授予辅助功能，无法放大真实窗口，本项只能人工验收", check: "P0-4 原生前台输入")
            manual("P0-4", "中文输入", "授权后点卡片放大窗口，切换到中文输入法打「测试」，确认候选框出现在真实窗口里。")
            return
        }
        guard let candidate = coordinator.state.records.values.first(where: { $0.allowsAutoFocus }) else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: "没有可聚焦的窗口（身份未唯一确定或受限制）", check: "P0-4 原生前台输入")
            return
        }
        // 放大必须由真实鼠标事件触发：直接 dispatch 的话，事件转接断了也能"通过"（方案 §14）。
        guard let target = panelPoint(for: candidate.identity) else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: "\(candidate.applicationName) 的格子不在任何总览面板上，无法通过真实视图放大（见 P0-9）",
                   check: "P0-4 原生前台输入")
            return
        }
        let clicksBefore = coordinator.cardClickCount
        let dispatched = sendRealMouseDownUp(target)
        guard dispatched, coordinator.cardClickCount == clicksBefore + 1 else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: dispatched
                        ? "真实点击已派发，但协调器没有恰好收到一次卡片动作（转接断，见 P0-9）"
                        : "真实点击无法派发到总览内容视图（面板不存在或该点命中的不是它）",
                   check: "P0-4 原生前台输入")
            return
        }
        _ = await waitUntil(timeout: 3.0) { self.coordinator.state.phase.controlledTarget == candidate.identity }
        try? await Task.sleep(nanoseconds: 400_000_000)
        let panelHoldsKey = coordinator.controllers.values.contains { $0.isKey }
        let focusState = coordinator.state.keyboardFocus
        coordinator.dispatch(.returnShortcut)
        _ = await waitUntil(timeout: 3.0) { self.coordinator.state.phase == .overview || self.coordinator.state.phase == .hidden }
        record("P0-4", "原生前台输入", passed: !panelHoldsKey && focusState == .targetApplication,
               detail: "放大 \(candidate.applicationName) 后：总览面板持有键盘=\(panelHoldsKey)，键盘归属=\(focusState.rawValue)",
               check: "P0-4 键盘不被总览占用")
        manual("P0-4", "中文输入", "放大 Terminal 或备忘录，用中文输入法打「测试」，录屏确认候选窗跟随真实窗口。")
        manual("P0-4", "右键与菜单", "在放大窗口上右键、打开菜单栏、拖动文本，确认全部落在真实窗口内。")
        manual("P0-4", "保存面板", "在 Safari 里 ⌘S 打开保存面板，确认面板可见可点、取消后回到总览不丢窗口。")
        manual("P0-4", "滚动与快捷键", "放大后滚动页面并试用 ⌘C/⌘V/⌘T，确认没有按键被总览截走。")
    }

    // MARK: - P0-5 背景点击

    private func p0_5_backgroundClickSoak() async {
        if coordinator.state.phase != .overview { await showOverview() }
        let minimizedBefore = coordinator.state.records.values.filter(\.isMinimized).count
        let consumed = coordinator.controllers.values.filter { $0.consumesBackgroundClicks() }.count
        let started = Date()
        for _ in 0..<100 {
            coordinator.dispatch(.backgroundClicked(interaction: InteractionToken()))
        }
        let ms = Date().timeIntervalSince(started) * 1000
        let phase = coordinator.state.phase
        let minimizedAfter = coordinator.state.records.values.filter(\.isMinimized).count
        let passed = consumed == coordinator.controllers.count
            && coordinator.controllers.count > 0
            && minimizedAfter == minimizedBefore
            && phase.isVisible
        let blocked = permissionNote(.screenRecording)
        record("P0-5", "背景点击 100 次", passed: blocked == nil ? passed : nil,
               detail: blocked ?? "状态机 100 次背景点击耗时 \(String(format: "%.1f", ms))ms；阶段=\(phaseDebug(phase))；"
                    + "最小化数量 \(minimizedBefore)→\(minimizedAfter)；\(consumed)/\(coordinator.controllers.count) 块屏确认自留事件",
               check: "P0-5 背景点击状态机 soak")
        manual("P0-5", "点击不穿透", "总览打开时，在背景空白处连点 100 次，录屏确认后面的按钮没被触发、没有窗口被最小化。")
        manual("P0-5", "点背景回到总览", "放大某个窗口后点背景空白，确认只回到总览，不发生应用切换或窗口最小化。")
    }

    private func phaseDebug(_ phase: SessionPhase) -> String {
        switch phase {
        case .hidden: return "hidden"
        case .preparing: return "preparing"
        case .overview: return "overview"
        case .expanding: return "expanding"
        case .focused: return "focused"
        case .collapsing: return "collapsing"
        case let .switching(_, to, _): return "switching(\(to.journalKey))"
        case let .recovering(destination, _): return "recovering(\(destination))"
        }
    }

    // MARK: - P0-6 身份复用

    private func p0_6_identityReuse() async {
        let before = Dictionary(uniqueKeysWithValues: coordinator.state.records.map { ($0.value.identity, $0.value.slot?.index ?? -1) })
        let generation = coordinator.state.catalogGeneration
        coordinator.refreshNow()
        _ = await waitUntil(timeout: 4.0) { self.coordinator.state.catalogGeneration > generation }
        let after = Dictionary(uniqueKeysWithValues: coordinator.state.records.map { ($0.value.identity, $0.value.slot?.index ?? -1) })
        let carried = before.keys.filter { after[$0] != nil }
        let moved = carried.filter { before[$0] != after[$0] }
        // 同窗口编号跨进程身份必须不同：PID 复用时不能共用身份。
        let byWindowID = Dictionary(grouping: Array(coordinator.state.records.values), by: { $0.identity.windowID })
        let collisions = byWindowID.filter { $0.value.count > 1 && Set($0.value.map(\.identity.processStartIdentity)).count == 1 }
        let passed = !carried.isEmpty && moved.isEmpty && collisions.isEmpty
        let blocked = permissionNote(.screenRecording)
        record("P0-6", "身份与格子复用", passed: blocked == nil ? passed : nil,
               detail: blocked ?? "刷新后沿用身份 \(carried.count) 个，格子变动 \(moved.count) 个，"
                    + "共用启动标识的重复窗口编号 \(collisions.count) 个",
               check: "P0-6 同标题窗口身份复用")
        manual("P0-6", "退出再启动", "开两个同名窗口（如两个「无标题」备忘录），退出 Vistile 再启动，录屏确认格子与窗口仍然对得上。")
        manual("P0-6", "重启后尺寸恢复", "改一个窗口尺寸后强退 Vistile（⌥右键图标→退出会走正常恢复；崩溃请结束进程），"
               + "下次启动应自动恢复原位置，确认弹窗说明。")
    }

    // MARK: - P0-7 多显示器

    private func p0_7_multiDisplay() async {
        let displays = coordinator.catalog.mapper.displays
        guard displays.count >= 2 else {
            record("P0-7", "多显示器", passed: nil,
                   detail: "只检测到 \(displays.count) 块显示器，需要接第二块屏（负坐标与不同缩放都要覆盖）",
                   check: "P0-7 多显示器")
            manual("P0-7", "多显示器", "接上第二块屏（含负坐标或上下排列），确认两屏都有总览、跨屏拖动窗口后格子不跳、Retina 与外屏缩放混合时卡片不变形。")
            return
        }
        let negative = displays.filter { $0.frame.minX < 0 || $0.frame.minY < 0 }
        let scales = Set(displays.map(\.backingScale))
        let covered = Set(coordinator.state.records.values.map(\.displayID))
        let controllers = Set(coordinator.controllers.keys)
        let missingControllers = covered.subtracting(controllers)
        let layoutsMissing = covered.subtracting(layoutDisplayIDs())
        let passed = !controllers.isEmpty && missingControllers.isEmpty && layoutsMissing.isEmpty
        let blocked = permissionNote(.screenRecording)
        record("P0-7", "多显示器", passed: blocked == nil ? passed : nil,
               detail: blocked ?? "显示器 \(displays.count) 块（负坐标 \(negative.count) 块，不同缩放 \(scales.count) 种）；"
                    + "有窗口的屏幕 \(covered.count)，承载窗口 \(controllers.count)，缺布局 \(layoutsMissing.count)",
               check: "P0-7 多显示器覆盖")
        manual("P0-7", "跨屏放大", "在副屏放大窗口，确认前景比例按副屏可用区计算、收回后回到副屏原格子。")
    }

    private func layoutDisplayIDs() -> [UInt32] { coordinator.layoutDisplayIDs() }

    // MARK: - P0-8 异常路径

    private func p0_8FailureModes() async {
        let minimized = coordinator.state.records.values.filter(\.isMinimized)
        if minimized.isEmpty {
            record("P0-8", "最小化窗口", passed: nil, detail: "本机没有最小化窗口，无法自动验证", check: "P0-8 最小化窗口")
            manual("P0-8", "最小化窗口", "把窗口丢进 Dock，确认卡片标注「已最小化」而不是显示成实时画面；点卡片应解除最小化并放大。")
        } else {
            let labelled = minimized.filter { item in
                switch item.capture {
                case .pausedMinimized, .lowFrequency, .notCapturable: return true
                default: return false
                }
            }
            record("P0-8", "最小化窗口", passed: labelled.count == minimized.count,
                   detail: "最小化 \(minimized.count) 个，正确标注 \(labelled.count) 个（禁止把暂停画面写成实时）",
                   check: "P0-8 最小化不谎报实时")
        }
        let unsupported = coordinator.observerHub.axUnsupportedPIDs
        if !unsupported.isEmpty {
            record("P0-8", "不支持 AX 的应用", passed: true,
                   detail: "\(unsupported.count) 个进程无法创建 AXObserver，已降级为仅预览",
                   check: "P0-8 不支持 AX 降级")
        }
        record("P0-8", "撤销权限", passed: nil,
               detail: "系统权限无法由程序撤销；请在系统设置里关掉屏幕录制后重启 Vistile", check: "P0-8 撤销权限")
        manual("P0-8", "撤销权限", "在系统设置里取消屏幕录制权限后重开 Vistile，确认卡片明确写「缺少屏幕录制权限，无画面」，不显示旧帧冒充实时。")
        manual("P0-8", "应用无响应", "让某个应用卡死（例如 `sleep` 死循环的 Terminal），确认总览仍能显示其它窗口、"
               + "该卡片标注低频或启动中，Vistile 主线程不卡住。")
        manual("P0-8", "窗口中途关闭", "放大窗口后从别处关掉它，确认回到总览且不残留事务记录。")
    }

    // MARK: - P0-9 真实视图链路与上屏

    /// 方案 §14：探针必须经过真实视图/渲染链路。只调 dispatch 的项证明的是状态机，
    /// 事件转接（R01）与 Metal 上屏（R02）断了也照样"通过"，这里把这两层一起取证。
    private func p0_9_realViewChain() async {
        let blocked = permissionNote(.screenRecording)
        guard blocked == nil else {
            record("P0-9", "真实视图链路", passed: nil, detail: blocked!, check: "P0-9 真实视图链路")
            return
        }
        if coordinator.state.phase != .overview { await showOverview() }
        guard let candidate = coordinator.state.records.values.first(where: { $0.allowsAutoFocus }),
              let target = panelPoint(for: candidate.identity) else {
            record("P0-9", "真实视图链路", passed: nil,
                   detail: "找不到既可放大、又真的落在某块总览面板格子里的窗口，无法造出真实点击坐标",
                   check: "P0-9 真实视图链路")
            return
        }
        let diagnosticsBefore = coordinator.rendererDiagnostics
        let framesBefore = totalPublished()
        let clicksBefore = coordinator.cardClickCount
        let backgroundsBefore = coordinator.viewBackgroundClickCount
        let minimizedBefore = coordinator.state.records.values.filter(\.isMinimized).count

        let down = sendRealMouseDownUp(target)
        let reachedFocus = await waitUntil(timeout: 5.0) { self.coordinator.state.phase.controlledTarget == candidate.identity }
        let expanded = down
            && coordinator.cardClickCount == clicksBefore + 1
            && reachedFocus

        // 回到总览也走真实事件：抬起落在空白格子上，而不是塞给状态机一个假点击。
        let backgroundSent = coordinator.state.phase.controlledTarget == candidate.identity
            && sendRealBackgroundClick(on: candidate.identity)
        let returned = await waitUntil(timeout: 5.0) { self.coordinator.state.phase == .overview }
        let minimizedAfter = coordinator.state.records.values.filter(\.isMinimized).count

        let diagnosticsAfter = coordinator.rendererDiagnostics
        let frames = totalPublished() - framesBefore
        let presented = diagnosticsAfter.presents - diagnosticsBefore.presents
        let gpuErrors = diagnosticsAfter.gpuErrors - diagnosticsBefore.gpuErrors
        let submissionFailures = diagnosticsAfter.submissionFailures - diagnosticsBefore.submissionFailures
        let streams = coordinator.capture.activeStreamCount
        let rendered = presented > 0
        let detail = "真实点击 → 放大 \(candidate.applicationName)：视图动作 \(coordinator.cardClickCount - clicksBefore) 次，阶段到达=\(reachedFocus)；"
            + "真实背景点击 \(coordinator.viewBackgroundClickCount - backgroundsBefore) 次，回到总览=\(returned)；"
            + "最小化数量 \(minimizedBefore)→\(minimizedAfter)；"
            + "同期 present +\(presented)、捕获帧 +\(frames)（\(streams) 路流），"
            + "GPU 错误 +\(gpuErrors)、提交失败 +\(submissionFailures)，缺 drawable 累计 \(diagnosticsAfter.missingDrawables)"
        let passed = expanded && backgroundSent && returned && rendered
            && minimizedAfter == minimizedBefore
            && gpuErrors == 0 && submissionFailures == 0
        record("P0-9", "真实视图链路", passed: passed, detail: detail, check: "P0-9 事件转接到真实上屏")
        recorder.updateRow(application: candidate.applicationName, version: "",
                           ordering: passed ? .passed : .unverified,
                           knownLimitation: passed ? nil : "真实事件链路或 present 未取得闭环证据")
        manual("P0-9", "画面确实是这张卡", "录屏确认放大时屏幕上的窗口与刚点的卡片画面一致，不是别的应用的窗口。")
    }

    // MARK: - P0-10 层级策略与改写频率

    private func p0_10_orderingFacts() async {
        if coordinator.state.phase != .overview { await showOverview() }
        // §12.1：未实现的策略不得继续"看起来开着"，且迁移结果必须已经写回持久化。
        let persisted = settings.persistedOrderingStrategy
        let migrationOK = !settings.orderingStrategy.isUnimplemented && persisted == settings.orderingStrategy
        let migratedNote = settings.migratedOrderingStrategy
            .map { "；本次启动已从 \($0.rawValue) 迁移并写回" } ?? ""
        record("P0-10", "层级策略已实现且写回", passed: migrationOK,
               detail: "生效策略=\(settings.orderingStrategy.rawValue)，持久化=\(persisted.map { $0.rawValue } ?? "读不到")"
                    + migratedNote,
               check: "P0-10 未实现层级策略迁移")
        manual("P0-10", "设置里看不到分块", "打开设置窗口，确认层级策略下拉里已经没有「背景分块避让」。")

        // §12.2：层级只在策略/目标变化时改写；捕获回调反复 order(.below) 是在跟 WindowServer 较劲。
        let appliedBefore = coordinator.orderingApplyCount
        let framesBefore = totalPublished()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let applied = coordinator.orderingApplyCount - appliedBefore
        let frames = totalPublished() - framesBefore
        let streams = coordinator.capture.activeStreamCount
        let blocked = permissionNote(.screenRecording)
        let passed: Bool? = blocked != nil ? nil : (streams > 0 ? applied == 0 : nil)
        record("P0-10", "层级不随回调重排", passed: passed,
               detail: blocked ?? (streams > 0
                    ? "\(streams) 路直播流、2s 内 \(frames) 帧回调期间层级改写 \(applied) 次（期望 0 次）"
                    : "当前没有活跃捕获流，无回调可对照：2s 内层级改写 \(applied) 次，需在有直播流时重跑"),
               check: "P0-10 层级不每次回调重排")
        if passed == false {
            recorder.updateRow(application: "总览承载窗口", version: "", ordering: .failed,
                               knownLimitation: "捕获回调期间反复改写窗口层级（\(applied) 次/2s）")
        }
    }

    // MARK: - P0-11 背景点击令牌不吞后续激活

    private func p0_11_trustedToken() async {
        if coordinator.state.phase != .overview { await showOverview() }
        guard coordinator.state.phase == .overview else {
            record("P0-11", "背景点击不留令牌", passed: nil,
                   detail: "总览没能打开，无法在总览态验证令牌", check: "P0-11 令牌不永久抑制外部激活")
            return
        }
        // 总览态下的背景点击不引发任何收起：这次交互不能被存成后续"受信"令牌（方案 §12.2）。
        let token = InteractionToken()
        coordinator.dispatch(.backgroundClicked(interaction: token))
        let retained = coordinator.state.trustedInteraction == token
        // 用一个确定不是受控目标的 bundleID 模拟外部激活：它必须正常把总览隐藏掉。
        let bundleID = coordinator.state.records.values.first { $0.bundleID != Bundle.main.bundleIdentifier }?.bundleID
            ?? "com.apple.finder"
        coordinator.dispatch(.focusLost(origin: .otherApplication(bundleID: bundleID)))
        let exited = await waitUntil(timeout: 3.0) { self.coordinator.state.phase == .hidden }
        record("P0-11", "背景点击不留令牌", passed: !retained && exited,
               detail: "空转背景点击后令牌残留=\(retained)；随后模拟外部激活（\(bundleID)）"
                    + (exited ? "正常退出总览" : "被吞掉，总览没有隐藏"),
               check: "P0-11 令牌不永久抑制外部激活")
        await showOverview()
        manual("P0-11", "Cmd-Tab 之后", "放大窗口后按 ⌘Tab 切到别的应用，确认总览自动隐藏；再按快捷键能重新打开，不需要重启 Vistile。")
        manual("P0-11", "对话框不被强关", "在放大窗口里打开一个 Sheet（如另存为），点背景，确认对话框不被强行关掉。")
    }

    // MARK: - 真实事件派发

    /// 承载某窗口的面板 + 该格子中心在窗口坐标里的位置。拿不到就返回 nil，探针不许改用猜测坐标。
    private func panelPoint(for identity: WindowIdentity) -> (window: NSWindow, point: CGPoint)? {
        guard let record = coordinator.state.records[identity],
              let controller = coordinator.controllers[record.displayID] else { return nil }
        let view = controller.contentView
        guard let window = view.window, let local = view.cellCenter(for: identity) else { return nil }
        return (window, view.convert(local, to: nil))
    }

    /// 一整次左键按下 + 抬起，交给 NSWindow 做真实派发（hitTest → 视图手势 → 动作转接）。
    private func sendRealMouseDownUp(_ target: (window: NSWindow, point: CGPoint)) -> Bool {
        guard let view = target.window.contentView as? OverviewContentView,
              view.hitTest(target.point) != nil,
              let down = Self.mouseEvent(.leftMouseDown, window: target.window, point: target.point),
              let up = Self.mouseEvent(.leftMouseUp, window: target.window, point: target.point) else { return false }
        target.window.sendEvent(down)
        target.window.sendEvent(up)
        return true
    }

    /// 点在确定不属于任何格子的空白上：命中测试为 nil 才算真的背景，不能靠"随便挑个角"。
    private func sendRealBackgroundClick(on identity: WindowIdentity) -> Bool {
        guard let record = coordinator.state.records[identity],
              let controller = coordinator.controllers[record.displayID] else { return false }
        let view = controller.contentView
        guard let window = view.window, let local = view.unoccupiedViewPoint() else { return false }
        let point = view.convert(local, to: nil)
        guard view.hitTest(point) != nil else { return false }
        return sendRealMouseDownUp((window, point))
    }

    private static func mouseEvent(_ type: NSEvent.EventType, window: NSWindow, point: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type,
                           location: point,
                           modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber,
                           context: nil,
                           eventNumber: 0,
                           clickCount: 1,
                           pressure: 0.5)
    }

    // MARK: - 性能记录

    private func performanceSample() async {
        let framesBefore = totalPublished()
        let cpuBefore = P0Probe.processCPUSeconds()
        let started = Date()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let wall = max(0.001, Date().timeIntervalSince(started))
        let frames = totalPublished() - framesBefore
        let streams = coordinator.capture.activeStreamCount
        let polled = coordinator.capture.polledCount
        recorder.recordPerformance(PerformanceSample(name: "总览帧率",
                                                     valueMS: Double(frames) / wall,
                                                     context: "帧/秒（数值填在毫秒列，便于表格直接排序）"))
        if let cpuBefore, let cpuAfter = P0Probe.processCPUSeconds() {
            // 方案 §14：CPU 用 100% = 一个逻辑核满载的记法。
            recorder.recordPerformance(PerformanceSample(name: "Vistile CPU",
                                                         valueMS: (cpuAfter - cpuBefore) / wall * 100,
                                                         context: "总览打开时占用，100% = 一个逻辑核满载"))
        }
        recorder.record("性能采样", subject: "\(streams) 路流 / \(polled) 个低频",
                        result: .unverified,
                        detail: "帧 \(frames) 张/\(String(format: "%.1f", wall))s；空闲基线与 WindowServer 增量需 Activity Monitor 对照")
        manual("性能", "空闲基线", "关闭总览后在活动监视器确认 CPU 回到接近 0%，GPU 无持续占用。")
        manual("性能", "多窗口压力", "开到 30 个窗口，确认帧率下降是渐进的、卡片标注与实际更新方式一致。")
    }

    /// 本进程已消耗的 CPU 时间（用户 + 系统），单位秒。100% 记法由调用方按墙钟时间换算。
    static func processCPUSeconds() -> Double? {
        var info = rusage_info_current()
        let result: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { raw in
                proc_pid_rusage(getpid(), Int32(truncatingIfNeeded: RUSAGE_INFO_CURRENT), raw)
            }
        }
        guard result == 0 else { return nil }
        // 本 SDK 的字段是 UInt64 纳秒：ri_user_time / ri_system_time。
        return (Double(info.ri_user_time) + Double(info.ri_system_time)) / 1_000_000_000
    }

    // MARK: - 工具

    private func record(_ id: String, _ title: String, passed: Bool?, detail: String, check: String) {
        let verdict: String
        if passed == nil { verdict = "未测" } else { verdict = passed == true ? "通过" : "失败" }
        checklist.append(Item(id: id, title: title, verdict: verdict, detail: detail, isManual: false))
        let result: VerificationResult
        switch passed {
        case .none: result = .unverified
        case .some(true): result = .passed
        case .some(false): result = .failed
        }
        recorder.record(check, subject: title, result: result, detail: detail)
        coordinator.onStatus?("P0 \(id) \(title)：\(verdict)")
    }

    private func manual(_ id: String, _ title: String, _ steps: String) {
        checklist.append(Item(id: id, title: title, verdict: "未测", detail: steps, isManual: true))
        recorder.record("\(id) 人工验收 · \(title)", subject: "录屏/肉眼", result: .unverified, detail: steps)
    }

    /// 系统门禁没开时不许写"失败"：那会把未授权读成程序缺陷。返回 nil 才代表这一项真的可以判定。
    private func permissionNote(_ kind: PermissionKind) -> String? {
        guard coordinator.permissions.isGranted(kind) else {
            return kind == .screenRecording
                ? "未授予屏幕录制：目录与帧数据不存在，本项无法判定（见 P0-0）"
                : "未授予辅助功能：不能操作真实窗口，本项无法判定（见 P0-0）"
        }
        return nil
    }

    private func waitUntil(timeout: TimeInterval = 6.0, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return predicate()
    }

    private func writeChecklist() {
        let url = recorder.outputDirectory.appendingPathComponent("P0-acceptance-checklist.md")
        var lines: [String] = ["# P0 验收清单（\(CompatibilityRecorder.systemVersion)，\(CompatibilityRecorder.hardwareDescription)）", ""]
        lines.append("自动项由探针在本机取证；人工项必须由肉眼与录屏确认，未确认前一律保持「未测」。")
        lines.append("")
        lines.append("| 编号 | 项目 | 结论 | 说明 |")
        lines.append("| --- | --- | --- | --- |")
        for item in checklist.sorted(by: { ($0.id, $0.title) < ($1.id, $1.title) }) {
            lines.append("| \(item.id) | \(item.title) | \(item.verdict) | \(item.detail) |")
        }
        lines.append("")
        lines.append("## 录屏建议")
        lines.append("")
        lines.append("- 用 QuickTime 录制整屏，包含菜单栏里的窗口顺序变化。")
        lines.append("- 每条结论后附「操作 → 期望 → 实际」，实际与期望不符的项不要改结论。")
        lines.append("- 报告文件与清单同目录：\(recorder.outputDirectory.path)")
        let text = lines.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: recorder.outputDirectory, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        recorder.note("P0 验收清单：\(url.path)")
        _ = recorder.flush()
    }
}
