import AppKit
import CoreGraphics
import Darwin
import Foundation
import QuartzCore
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
    /// soak 开始前的真实 frame 基准（P0-16 进入工作台之前取）：收尾用它核对窗口有没有被写漂移。
    private var soakFrameBaseline: [WindowIdentity: CGRect] = [:]
    /// 三条路径的「点击→落定」延迟样本（毫秒，单调时钟）：enter / swap / return。
    /// 按方案 §20.2 分组攒着：`路径 → 分组键（60/120Hz·reduceMotion·冷热）→ 样本`，
    /// P0-18 逐组判定，不同环境的数字不合并成同一个 P95。
    private var soakLatencyMS: [String: [String: [Double]]] = [:]
    /// 每条路径的派发次数与落定次数（方案 §20.2「同时记录成功率和超时率」；超时数 = 差值）。
    private var clickTally: [String: (attempts: Int, settled: Int)] = [:]
    /// 几何事务对照行（方案 §22）：工作台在途时按 journal 事实逐窗口采样，收尾再与真实 frame 对一次。
    private var ledgerRows: [LedgerRow] = []
    /// 曾出现过真实写入读回的窗口：`journalKey → 该窗口的全部几何事实`。
    /// 收尾判定「退出恢复后确实回到 original」要靠这份名单，不能靠收尾时 journal 里还剩什么
    /// ——落定的事务会被正常删除，那时已经没有行可对。
    /// 事实要整份留着：恢复后的对照行同样得给出 before/target/displayID，只留两个 frame 就成不了表。
    private struct LedgerWrittenFact {
        let original: CGRect
        let operationBefore: String
        let target: String
        let readBack: CGRect
        let displayIDs: String
    }
    private var ledgerWrittenFacts: [String: LedgerWrittenFact] = [:]

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
        // 上一轮报告的归档挂在记录器"本进程第一次写盘"之前（见 CompatibilityRecorder.preservePreviousRunLocked）：
        // 放在这里已经太晚——启动事实先写盘就会把上一轮就地覆盖掉（0.1.6 实测覆盖掉了 0.1.5 的原始报告）。
        recorder.note("P0 探针运行中：自动项记录客观证据，人工项保持未测")
        // 权限是解释后续结论的前提，必须作为事实写进报告，否则"窗口 0 个"会被误读成程序坏了。
        let granted = coordinator.permissions.refresh()
        recorder.record("P0-0 系统权限",
                        subject: "屏幕录制 / 辅助功能",
                        result: granted.isComplete ? .passed : .blocked,
                        detail: "屏幕录制=\(granted.screenRecording)，辅助功能=\(granted.accessibility)；"
                             + "缺任一项时后续自动项只能记为未测或失败")
        await showOverview()
        // 长跑序列：样本闸门（§19.13 每条路径 ≥100 次）与 §19.11 的 30 分钟资源曲线都走这一轮。
        if let minutes = P0Probe.longRunMinutes() {
            await longRun(minutes: minutes)
            await p0_19_transactionLedger()
            await p0_18_frameBudget()
            await performanceSample()
            await finishReport()
            return
        }
        // 首开事实要趁热取：P0-4 起就会真的点卡片进工作台，之后再也拿不到"未点击前"的现场。
        await p0_15_overviewFirst()
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
        await p0_12_workbenchEntry()
        await p0_13_mainSwitch()
        await p0_14_returnToOverview()
        await p0_16_swapSoak()
        await p0_17_roundTrips()
        await p0_19_transactionLedger()
        await p0_18_frameBudget()
        await performanceSample()
        await finishReport()
    }

    /// 报告的收尾。自检必须在"可见态"取样：隐藏态下信箱已被停流释放，累计帧永远读 0——
    /// 0.1.10+18 那轮把"探针恰好在隐藏态采样"误判成了"全程 0 帧"的环境结论。
    private func finishReport() async {
        if coordinator.state.phase == .hidden { await showOverview() }
        let environment = await environmentSelfCheck()
        recorder.record("P0 汇总", subject: "自动 \(autoCount) 项 / 人工 \(checklist.filter(\.isManual).count) 项",
                        result: autoFailures == 0 ? .unverified : .failed,
                        detail: (autoFailures == 0
                            ? "自动项未发现失败；跨应用交互仍需按验收清单肉眼与录屏确认"
                            : "有 \(autoFailures) 个自动项失败，见对应条目") + "；" + environment)
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
        guard coordinator.state.phase == .hidden else { return }
        var retries = 0
        while true {
            coordinator.toggleOverview()
            // "打开总览"不等于"阶段可见"：`.preparing` 也算可见，而上一轮的 records 还在，
            // 只等 isVisible + records 非空会在发现落地前就返回——那时网格刚被复位、视图还是旧格子，
            // 点卡片会被"没有格子位置"静默丢掉（0.1.9+11/+12 两轮 P0-4 的红就是这个形状）。
            // 判据同 P0-7：必须等总览真的落地（阶段到 overview 意味着这一轮网格已经重建完）。
            _ = await waitUntil { self.coordinator.state.phase == .overview && !self.coordinator.state.records.isEmpty }
            // 发现的某一轮整轮全灭（实机形态：捕捉 TCC 成串短暂被拒）时 reducer 会按方案 §5.2
            // 退回收起态——那是环境事实，不是"总览打不开"。有界重试只允许在已经回到 .hidden 时进行：
            // `.preparing` 在途时再调 toggle 反而会把这次打开取消掉。
            guard coordinator.state.phase == .hidden, retries < 3 else { return }
            retries += 1
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    // MARK: - P0-1 目录与身份

    private func p0_1_catalogAndIdentity() async {
        let records = Array(coordinator.state.records.values)
        let apps = Dictionary(grouping: records, by: { $0.identity.processID })
        let multiWindowApps = apps.filter { $0.value.count >= 2 }
        let uniqueWindowIDs = CatalogIdentityAudit.hasUniqueWindowIDs(records)
        // 判据本身在核心包里（CatalogIdentityAudit），这样"跨进程复用索引不算冲突"
        // 这条口径能被单元测试钉住，不会哪天又被改回全局比数量。
        let clashes = CatalogIdentityAudit.axIndexClashes(in: records)
        let readable = records.filter { $0.confidence.allowsAXWrite }.count

        var detail = "窗口 \(records.count) 个；多窗口进程 \(multiWindowApps.count) 个；"
            + "AX 唯一对应 \(readable) 个；窗口编号无重复=\(uniqueWindowIDs)；"
            + "同进程 AX 索引无重复=\(clashes.isEmpty)"
        if !clashes.isEmpty {
            detail += "；冲突：" + clashes.map {
                let names = apps[$0.processID].map { Set($0.map(\.applicationName)).sorted().joined(separator: "/") } ?? "-"
                return "\(names) pid=\($0.processID) 索引 #\($0.axIndex) ← 窗口 \($0.windowIDs.map { "\($0)" }.joined(separator: ","))"
            }.joined(separator: "；")
        }
        let passed = records.count >= 6 && uniqueWindowIDs && clashes.isEmpty
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
        let started = monotonicNow()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let grew = occluded.filter { item in
            self.coordinator.capture.mailbox(for: item.identity).publishedCount > (before[item.identity] ?? 0)
        }
        let wall = max(0.001, monotonicNow() - started)
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

    /// 会话当前是否锁定。`CGSessionCopyCurrentDictionary` 是 CoreGraphics 的公开接口，
    /// 键名取它返回字典里的 `CGSSessionScreenIsLocked`（SDK 里没有导出对应的常量符号）。
    private func sessionLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Int) == 1
    }

    /// 「没有可放大的窗口」这类未测必须说清是谁不给读。锁屏时任何应用的 AX 窗口列表都是空的，
    /// 那是环境；没锁屏却一个都解析不出来，才是要当产品问题查的形状。
    private func environmentSuffix() -> String {
        if sessionLocked() {
            return "（会话锁定=是：此时读不到任何应用的 AX 窗口列表，与权限预检无关）"
        }
        if !coordinator.state.records.values.contains(where: { $0.confidence.allowsAXWrite }) {
            return "（会话未锁定，却没有一个窗口解析得出 AX 索引：这条要当产品问题查）"
        }
        return ""
    }

    // MARK: - P0-3 只提升被点窗口

    private func p0_3_raiseOnlyTarget() async {
        guard settings.orderingStrategy != .splitBackgroundTiles else {
            record("P0-3", "只提升被点窗口", passed: nil,
                   detail: "当前层级策略是背景分块，本探针不覆盖",
                   check: "P0-3 只提升被点窗口")
            manual("P0-3", "只提升被点窗口", "打开两个 Safari 窗口，点其中一个卡片，录屏确认另一个窗口没有被提到前面。")
            return
        }

        // 前置条件：辅助功能已授予，且目录里至少有一个窗口能解析出 AX 索引。
        // 会话锁定时预检仍然回 true，但整个会话的 AX 窗口列表是空的——0.1.8 实测：锁屏状态下
        // 用 osascript 问 Code / Finder / Qoder 的 `count of windows` 一律回 0，而本机
        // `CGSessionCopyCurrentDictionary` 回 `CGSSessionScreenIsLocked = 1`。
        // 那种轮次里 Raise 根本发不出去，记「失败」会把环境写成产品结论，所以记未测并写清缺什么。
        // 判据本体一个字没改：仍是两两比较，"没发出去"与"发了没生效"都算红。
        if let blocked = permissionNote(.accessibility) {
            record("P0-3", "只提升被点窗口", passed: nil, detail: blocked,
                   check: "P0-3 只提升被点窗口")
            return
        }
        let recordsNow = Array(coordinator.state.records.values)
        guard recordsNow.contains(where: { $0.confidence.allowsAXWrite }) else {
            record("P0-3", "只提升被点窗口", passed: nil,
                   detail: "\(recordsNow.count) 个窗口里没有一个能解析出 AX 索引"
                        + "（辅助功能预检=true，会话锁定=\(sessionLocked() ? "是" : "否")）："
                        + "这是本轮的取证环境而不是产品结论，请在解锁、唤醒的桌面上重跑同一条命令",
                   check: "P0-3 只提升被点窗口")
            return
        }

        // 每个"同应用 ≥2 窗口"的进程都跑一遍，并按应用名固定排序。
        // 以前这里取 Dictionary 的第一个：0.1.1 抽到 Code 判失败，0.1.3 抽到 Chrome 判通过，
        // Code 那一格因此一直没被复测。VISTILE_P0_TARGET 可以指定只测某个应用（名字或 bundle id 片段）。
        let grouped = Dictionary(grouping: Array(coordinator.state.records.values), by: { $0.identity.processID })
        var groups = grouped.values.filter { $0.count >= 2 }.sorted { lhs, rhs in
            let l = lhs.first, r = rhs.first
            return (l?.applicationName ?? "", l?.identity.processID ?? 0) < (r?.applicationName ?? "", r?.identity.processID ?? 0)
        }
        let allApps = grouped.values.filter { $0.count >= 2 }.map { $0.first?.applicationName ?? "-" }.sorted()
        let requested = P0Probe.targetFilter()
        if !requested.isEmpty {
            groups = groups.filter { group in
                group.contains { $0.applicationName.localizedCaseInsensitiveContains(requested)
                    || ($0.bundleID ?? "").localizedCaseInsensitiveContains(requested) }
            }
            guard !groups.isEmpty else {
                record("P0-3", "只提升被点窗口", passed: nil,
                       detail: "指定目标「\(requested)」在本机没有 ≥2 个窗口；当前多窗口应用：\(allApps.joined(separator: "/"))",
                       check: "P0-3 只提升被点窗口")
                manual("P0-3", "只提升被点窗口", "打开两个 \(requested) 窗口后再跑同一条命令。")
                return
            }
        }
        guard !groups.isEmpty else {
            record("P0-3", "只提升被点窗口", passed: nil,
                   detail: "本机没有同一应用两个以上窗口，无法制造兄弟场景",
                   check: "P0-3 只提升被点窗口")
            manual("P0-3", "只提升被点窗口", "打开两个 Safari 窗口，点其中一个卡片，录屏确认另一个窗口没有被提到前面。")
            return
        }

        var lines: [String] = []
        var failures: [String] = []
        for group in groups {
            let pair = group.sorted { $0.identity.windowID < $1.identity.windowID }
            guard let target = pair.first, let sibling = pair.last, target.identity != sibling.identity else { continue }
            let targetID = target.identity.windowID
            let siblingID = sibling.identity.windowID
            // 每一轮都先回到总览、并等窗口列表连续两次读数一致，再取基准。
            // 上一次提升会异步改动整张全局顺序表：不等它就取 before，余波会被算成本次的效果
            // （0.1.4 那轮 Chrome 报"兄弟 #17→#13 一起被提升"就发生在这种脏基准上，还不能算结论）。
            await restoreOverview()
            let before = await waitUntilWindowListStable()
            let raise = coordinator.focus.raiseOnly(target.identity)
            // 给异步的 Raise 一次落地的机会：等到列表真的变了为止，超时再取稳定读数。
            _ = await waitUntil(timeout: 2.0) { self.windowOrder() != before }
            let after = await waitUntilWindowListStable()
            // 判据本体在核心包里（TargetRaiseAudit），由单测钉住"余波不算提升、真提升必须红"两侧。
            let audit = TargetRaiseAudit.evaluate(target: targetID, sibling: siblingID, before: before, after: after)
            let passed = raise.wasIssued && audit.passed
            let line = "\(target.applicationName)（\(pair.count) 窗口）目标顺序 "
                + "\(describe(before[targetID]))→\(describe(after[targetID]))，"
                + "同应用另一窗口 \(describe(before[siblingID]))→\(describe(after[siblingID]))，"
                + "共同参照窗口 \(audit.sharedCount) 个（前 \(audit.beforeCount)／后 \(audit.afterCount)）"
            if passed {
                lines.append(line)
                // 「层级」列的定义就是这一项判的东西（展开时目标在总览前且不带动兄弟），
                // 所以通过也必须写这一格。0.1.6 收回两处代填时只在失败分支写，
                // 结果这一列从此只能出「失败」、永远变不成「通过」——17:46 那轮就是这样。
                recorder.updateRow(application: target.applicationName, version: "", ordering: .passed)
            } else {
                let cause = raise.wasIssued ? audit.failureCause : "Raise 没有发出（\(raise.detail)）"
                failures.append(target.applicationName)
                lines.append("\(line) ⇒ 失败（\(cause)）")
                recorder.updateRow(application: target.applicationName, version: "",
                                   ordering: .failed,
                                   knownLimitation: "只提升被点窗口未成立：\(cause)。"
                        + "兄弟对仍在场的窗口占了便宜的有 \(audit.siblingGainedOver.count) 个"
                        + "（窗口编号 \(audit.siblingGainedOver.map(String.init).joined(separator: ","))），"
                        + "绝对下标为 \(describe(before[siblingID]))→\(describe(after[siblingID]))")
            }
            if passed, audit.beforeCount != audit.afterCount {
                recorder.note("P0-3：\(target.applicationName) 这轮窗口列表在两次读数间变动了 "
                              + "\(max(audit.beforeCount, audit.afterCount) - audit.sharedCount) 个窗口，"
                              + "判据只比共同在场的 \(audit.sharedCount) 个")
            }
        }
        record("P0-3", "只提升被点窗口", passed: failures.isEmpty,
               detail: "\(groups.count) 个多窗口应用：" + lines.joined(separator: "；"),
               check: "P0-3 只提升被点窗口")
        manual("P0-3", "背景总览仍可见", "同上场景，录屏确认放大后背景总览没有被隐藏、其他应用窗口没有被误提到前面。")
    }

    /// nil 表示窗口已不在屏幕上；不能把"读不到"当成"排名变好"。
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

    /// 回到总览状态。上一项可能把某个窗口提升成了受控目标，带着脏阶段进下一项就会误判。
    private func restoreOverview() async {
        if coordinator.state.phase != .overview {
            coordinator.dispatch(.returnShortcut)
            _ = await waitUntil(timeout: 2.0) {
                self.coordinator.state.phase == .overview || self.coordinator.state.phase == .hidden
            }
        }
        if coordinator.state.phase != .overview { await showOverview() }
    }

    /// 连续两次 CGWindowList 读数一致才算稳定；到点仍不稳定就返回最后一次读数。
    private func waitUntilWindowListStable(timeout: TimeInterval = 1.5) async -> [UInt32: Int] {
        var previous = windowOrder()
        let deadline = monotonicNow() + timeout
        while monotonicNow() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let current = windowOrder()
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    // MARK: - P0-4 原生前台输入

    private func p0_4_nativeForegroundInput() async {
        guard coordinator.permissions.status.accessibility else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: "未授予辅助功能，无法放大真实窗口，本项只能人工验收", check: "P0-4 原生前台输入")
            manual("P0-4", "中文输入", "授权后点卡片放大窗口，切换到中文输入法打「测试」，确认候选框出现在真实窗口里。")
            return
        }
        // 上一项（P0-3）可能刚把某个窗口提升成受控目标。那种状态下格子不在总览布局里，
        // 点位命中不到卡片；0.1.4 那轮 P0-4 记的"动作次数=0、阶段到达=false"就是脏阶段的读数。
        await restoreOverview()
        // 总览没真正落地时不能点：`.preparing` 下登记表还没重建，点击会被入口守卫静默丢掉，
        // 那测的是取证时机而不是产品。判据与 P0-11/P0-12 一致：打不开就记未测并说清原因。
        guard coordinator.state.phase == .overview else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: "总览没能打开（阶段=\(phaseDebug(coordinator.state.phase))），无法在总览态造真实点击",
                   check: "P0-4 原生前台输入")
            return
        }
        guard let candidate = expandCandidate() else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: (P0Probe.targetFilter().isEmpty
                        ? "没有可聚焦的窗口（身份未唯一确定或受限制）"
                        : "指定目标「\(P0Probe.targetFilter())」没有可放大的窗口") + environmentSuffix(),
                   check: "P0-4 原生前台输入")
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
        let phaseBefore = coordinator.state.phase
        let dispatched = sendRealMouseDownUp(target)
        // 手势动作要等主队列回到 run loop 才落地：派发后立刻读计数必然还是旧值。
        // 先等到阶段真的到达目标，再回来核对"恰好一次"。
        let reached = await waitUntil(timeout: 3.0) { self.coordinator.state.phase.controlledTarget == candidate.identity }
        let clicks = coordinator.cardClickCount - clicksBefore
        guard dispatched, clicks == 1 else {
            record("P0-4", "原生前台输入", passed: nil,
                   detail: dispatched
                        ? "真实点击已派发但动作次数=\(clicks)（点击前阶段=\(phaseBefore)，阶段到达=\(reached)；转接断见 P0-9）"
                        : "真实点击无法派发到总览内容视图（面板不存在或该点命中的不是它）",
                   check: "P0-4 原生前台输入")
            return
        }
        // 点卡片现在走"进入工作台"：过渡由一步 AX 写入 + 前景激活组成（0.1.9+11 实机样本 120ms 与 704ms），
        // 键盘按方案 §10.1 在模式落定后才移交——定长 400ms 会在途中读到"总览仍持有键盘"这个设计动作，
        // 把过渡读成失败。这里改成等过渡自己落定；判据不变：落定后任何 Vistile 面板都不许持有键盘。
        let settled = await waitUntil(timeout: 5.0) {
            let state = self.coordinator.state
            return state.mode == .workbench && !state.workbench.modeTransition.isTransitioning
        }
        let overviewHoldsKey = coordinator.controllers.values.contains { $0.isKey }
        let railHoldsKey = coordinator.workbenchControllers.values.contains { $0.isSearchFocused }
        let focusState = coordinator.state.keyboardFocus
        coordinator.dispatch(.returnShortcut)
        _ = await waitUntil(timeout: 5.0) { self.coordinator.state.phase == .overview || self.coordinator.state.phase == .hidden }
        var issues: [String] = []
        if !settled {
            // 阶段到达=点击是否真的走到"进入"（.expanding 的受控目标就是候选）：
            // false = 点击在入口前就被丢掉；true = 过渡开始了但没落定。两种成因必须分开写。
            let mode = coordinator.state.mode == .workbench ? "workbench" : "overview"
            let transition = coordinator.state.workbench.modeTransition.isTransitioning ? "在途" : "idle"
            issues.append("5s 内进入工作台没有落定（阶段=\(phaseDebug(coordinator.state.phase))，"
                        + "阶段到达=\(reached)，模式=\(mode)，过渡=\(transition)）")
        }
        if overviewHoldsKey { issues.append("总览面板持有键盘") }
        if railHoldsKey { issues.append("工作台面板的搜索框持有键盘") }
        if focusState != .targetApplication { issues.append("键盘归属=\(focusState.rawValue)") }
        record("P0-4", "原生前台输入", passed: issues.isEmpty,
               detail: issues.isEmpty
                    ? "进入工作台（主区=\(candidate.applicationName)）落定后：没有任何 Vistile 面板持有键盘，键盘归属=\(focusState.rawValue)"
                    : "问题：" + issues.joined(separator: "；"),
               check: "P0-4 键盘不被总览占用")
        manual("P0-4", "中文输入", "放大 Terminal 或备忘录，用中文输入法打「测试」，录屏确认候选窗跟随真实窗口。")
        manual("P0-4", "右键与菜单", "在放大窗口上右键、打开菜单栏、拖动文本，确认全部落在真实窗口内。")
        manual("P0-4", "保存面板", "在 Safari 里 ⌘S 打开保存面板，确认面板可见可点、取消后回到总览不丢窗口。")
        manual("P0-4", "滚动与快捷键", "放大后滚动页面并试用 ⌘C/⌘V/⌘T，确认没有按键被总览截走。")
    }

    // MARK: - P0-5 背景点击

    private func p0_5_backgroundClickSoak() async {
        await restoreOverview()
        // 总览没落地时不能记"失败"：隐藏态 soak 测的不是产品（run9 的 阶段=hidden 就是这么来的），
        // 判据与 P0-4/P0-11/P0-12 一致：打不开就记未测并说清原因。
        guard coordinator.state.phase == .overview else {
            record("P0-5", "背景点击 100 次", passed: nil,
                   detail: "总览没能打开（阶段=\(phaseDebug(coordinator.state.phase))），无法在总览态做背景点击 soak",
                   check: "P0-5 背景点击状态机 soak")
            manual("P0-5", "点击不穿透", "总览打开时，在背景空白处连点 100 次，录屏确认后面的按钮没被触发、没有窗口被最小化。")
            manual("P0-5", "点背景回到总览", "放大某个窗口后点背景空白，确认只回到总览，不发生应用切换或窗口最小化。")
            return
        }
        let minimizedBefore = coordinator.state.records.values.filter(\.isMinimized).count
        let consumed = coordinator.controllers.values.filter { $0.consumesBackgroundClicks() }.count
        let started = monotonicNow()
        for _ in 0..<100 {
            coordinator.dispatch(.backgroundClicked(interaction: InteractionToken()))
        }
        let ms = (monotonicNow() - started) * 1000
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
        case .recoveryRequired: return "recoveryRequired"
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
        // 网格在会话隐藏时会被清空（resetForHiddenSession），刚重开总览时布局可能还没算出来。
        // 不在"总览确实可见、布局确实算过一轮"的前置条件下读 layouts，就会把取证时机读成产品缺陷：
        // 0.1.5 那轮的"承载窗口 2、缺布局 2"发生在前一项过渡超时把状态机降级之后，阶段已经不是 overview。
        await restoreOverview()
        // 布局是从冻结网格重建的，而网格只在 `.catalogUpdated` 里产出：0.1.6 可用那轮（17:46）
        // 这一项先于目录落地取数，于是读成「承载窗口 2 块、已算出布局 0 块」。
        // 用户打开总览走的就是同一条 reconcile 路径，所以探针先把这一轮驱动一次再等。
        // 判据没变：有窗口的屏幕仍然必须都有承载窗口与布局。
        coordinator.refreshNow()
        _ = await waitUntil(timeout: 2.0) {
            !self.coordinator.layoutDisplayIDs().isEmpty && !self.coordinator.state.grids.isEmpty
        }
        let covered = Set(coordinator.state.records.values.map(\.displayID))
        let controllers = Set(coordinator.controllers.keys)
        let missingControllers = covered.subtracting(controllers)
        let layoutsMissing = covered.subtracting(layoutDisplayIDs())
        let passed = !controllers.isEmpty && missingControllers.isEmpty && layoutsMissing.isEmpty
        let blocked = permissionNote(.screenRecording)
        record("P0-7", "多显示器", passed: blocked == nil ? passed : nil,
               detail: blocked ?? "显示器 \(displays.count) 块（负坐标 \(negative.count) 块，不同缩放 \(scales.count) 种）；"
                    + "有窗口的屏幕 \(covered.count)，承载窗口 \(controllers.count)，缺布局 \(layoutsMissing.count)；"
                    + "测量时阶段=\(phaseDebug(coordinator.state.phase))，已算出布局的屏幕 \(layoutDisplayIDs().count) 块，"
                    + "网格 \(coordinator.state.grids.count) 屏（陈旧标记=\(coordinator.state.gridsAreStale)），"
                    + "活跃流 \(coordinator.capture.activeStreamCount) 路",
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
        await restoreOverview()
        // 放大与收回会把捕获流停掉再重起。在"0 路流"的瞬间取增量快照，present 与帧数必然读到 0，
        // 那是取证时机而不是链路断了（0.1.6 实测：同一轮 P0-2 有 38 帧，P0-9 却记成 0 路流、present +0）。
        // 0.1.8 又看到另一半形状：10 路活跃流却全程 0 帧。所以前置条件等的是"目录真的又来了一帧"，
        // 不是"有流"。判据本身（present > 0）一个字没动。
        let readyFrames = totalPublished()
        let streamsReady = await waitUntil(timeout: 6.0) { self.totalPublished() > readyFrames }
        guard streamsReady else {
            let stalled = coordinator.capture.activeStreamCount
            record("P0-9", "真实视图链路", passed: nil,
                   detail: "总览已可见，但 6s 内全目录没有一帧新回调（活跃流 \(stalled) 路）——"
                        + (stalled > 0 ? "有流没帧，画面根本没在更新，" : "连流都没有，")
                        + "此刻的 present/帧增量必然为 0，无法判定真实上屏链路：需在目录真的产帧时重跑",
                   check: "P0-9 真实视图链路")
            return
        }
        guard let candidate = expandCandidate(),
              let target = panelPoint(for: candidate.identity) else {
            record("P0-9", "真实视图链路", passed: nil,
                   detail: (P0Probe.targetFilter().isEmpty
                        ? "找不到既可放大、又真的落在某块总览面板格子里的窗口，无法造出真实点击坐标"
                        : "指定目标「\(P0Probe.targetFilter())」没有既可放大又落在面板格子里的窗口")
                        + environmentSuffix(),
                   check: "P0-9 真实视图链路")
            return
        }
        let diagnosticsBefore = coordinator.rendererDiagnostics
        let framesBefore = totalPublished()
        let clicksBefore = coordinator.cardClickCount
        let minimizedBefore = coordinator.state.records.values.filter(\.isMinimized).count

        let down = sendRealMouseDownUp(target)
        let reachedFocus = await waitUntil(timeout: 5.0) { self.coordinator.state.phase.controlledTarget == candidate.identity }
        // 进入工作台的过渡要在 AX 写入与前景激活之后才落定：点卡片在途就算数，但"回到总览"必须从落定态出发。
        let settledEntry = await waitUntil(timeout: 5.0) {
            let state = self.coordinator.state
            return state.mode == .workbench && !state.workbench.modeTransition.isTransitioning
        }
        let expanded = down
            && coordinator.cardClickCount == clicksBefore + 1
            && reachedFocus && settledEntry

        // 回到总览同样走真实事件：新模型里总览背景不再是常驻画面，返回入口是工具区的「全部窗口」按钮，
        // 事件必须真的落在那个按钮上（坐标与命中的校验都在 allWindowsButtonPoint 里，不猜位置）。
        let returnPoint = allWindowsButtonPoint()
        let buttonSent = expanded && returnPoint != nil
            && sendRealMouseDownUp((returnPoint!.window, returnPoint!.point), hitView: returnPoint!.view)
        let returned = await waitUntil(timeout: 8.0) {
            let state = self.coordinator.state
            return state.mode == .overview && !state.workbench.modeTransition.isTransitioning && state.phase == .overview
        }
        let minimizedAfter = coordinator.state.records.values.filter(\.isMinimized).count
        // 回到总览后要给重起流与首次合成留出时间，否则"之后"的增量取的是收回瞬间的空档。
        // 等的同样是"真的又来了一帧"，不是"流计数回到非 0"。
        let resumedFrames = totalPublished()
        _ = await waitUntil(timeout: 6.0) { self.totalPublished() > resumedFrames }
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let diagnosticsAfter = coordinator.rendererDiagnostics
        let frames = totalPublished() - framesBefore
        let presented = diagnosticsAfter.presents - diagnosticsBefore.presents
        let gpuErrors = diagnosticsAfter.gpuErrors - diagnosticsBefore.gpuErrors
        let submissionFailures = diagnosticsAfter.submissionFailures - diagnosticsBefore.submissionFailures
        let streams = coordinator.capture.activeStreamCount
        let rendered = presented > 0
        let detail = "真实点击 → 进入工作台（主区=\(candidate.applicationName)）：视图动作 \(coordinator.cardClickCount - clicksBefore) 次，阶段到达=\(reachedFocus)，进入落定=\(settledEntry)；"
            + "真实点击「全部窗口」=\(buttonSent)，回到总览=\(returned)；"
            + "最小化数量 \(minimizedBefore)→\(minimizedAfter)；"
            + "同期 present +\(presented)、捕获帧 +\(frames)（\(streams) 路流），"
            + "GPU 错误 +\(gpuErrors)、提交失败 +\(submissionFailures)，缺 drawable 累计 \(diagnosticsAfter.missingDrawables)"
        let passed = expanded && buttonSent && returned && rendered
            && minimizedAfter == minimizedBefore
            && gpuErrors == 0 && submissionFailures == 0
        record("P0-9", "真实视图链路", passed: passed, detail: detail, check: "P0-9 事件转接到真实上屏")
        // 这一项证明的是"真实事件能打通放大与上屏"，它没有兄弟窗口可对照（目标是随机选到的单个窗口），
        // 所以不能顺手把矩阵里「层级=展开时不带动兄弟」那一格判成通过——那是 P0-3 的判据。
        // 0.1.1/0.1.3/0.1.4 三轮的报告里 UGit 与 ChatGPT 曾因此被写成"层级通过"，属于过度断言。
        manual("P0-9", "画面确实是这张卡", "录屏确认放大时屏幕上的窗口与刚点的卡片画面一致，不是别的应用的窗口。")
    }

    // MARK: - P0-10 层级策略与改写频率

    private func p0_10_orderingFacts() async {
        await restoreOverview()
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
        // 取数之前得先看到目录真的在产帧。0.1.6/0.1.7 两轮都在 0 路流的瞬间睡 2s，只能记"无回调可对照"；
        // 0.1.8 又实测到反过来的形状——10 路流但全程 0 帧，按旧判据就把"改写 0 次"记成了通过，
        // 可那是**没有任何回调**，不是**有回调而没改写**。现在两头都要等：等到至少来一帧为止。
        // 判据因此是收紧而不是放宽：仍要求"有回调的那 2s 内层级改写 0 次"。
        let launchFrames = totalPublished()
        if permissionNote(.screenRecording) == nil {
            _ = await waitUntil(timeout: 6.0) { self.totalPublished() > launchFrames }
        }
        let appliedBefore = coordinator.orderingApplyCount
        let framesBefore = totalPublished()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let applied = coordinator.orderingApplyCount - appliedBefore
        let frames = totalPublished() - framesBefore
        let streams = coordinator.capture.activeStreamCount
        let blocked = permissionNote(.screenRecording)
        let passed: Bool? = blocked != nil ? nil : (frames > 0 ? applied == 0 : nil)
        record("P0-10", "层级不随回调重排", passed: passed,
               detail: blocked ?? (frames > 0
                    ? "\(streams) 路直播流、2s 内 \(frames) 帧回调期间层级改写 \(applied) 次（期望 0 次）"
                    : (streams > 0
                        ? "有 \(streams) 路流，但等 6s + 观察 2s 期间全目录 0 帧：没有回调可对照，"
                          + "这 2s 内层级改写 \(applied) 次不算被证明"
                        : "等 6s 没等到任何新帧、也没有活跃流：这 2s 内层级改写 \(applied) 次不算被证明")),
               check: "P0-10 层级不每次回调重排")
        if passed == false {
            recorder.updateRow(application: "总览承载窗口", version: "", ordering: .failed,
                               knownLimitation: "捕获回调期间反复改写窗口层级（\(applied) 次/2s）")
        }
    }

    // MARK: - P0-11 背景点击令牌不吞后续激活

    private func p0_11_trustedToken() async {
        await restoreOverview()
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

    // MARK: - P0-12 工作台入口（方案 §4.1、§4.2）

    /// P0-12 进入工作台前主窗口的真实 frame：P0-13 用它核对"原主回到了原位置"。
    private var entryMainFrame: CGRect?

    private func p0_12_workbenchEntry() async {
        await restoreOverview()
        guard coordinator.state.phase == .overview else {
            record("P0-12", "工作台入口", passed: nil,
                   detail: "总览没能打开，无法从总览进入工作台", check: "P0-12 工作台入口")
            return
        }
        guard let candidate = expandCandidate() else {
            record("P0-12", "工作台入口", passed: nil,
                   detail: (P0Probe.targetFilter().isEmpty
                        ? "没有可聚焦的窗口" : "指定目标「\(P0Probe.targetFilter())」没有可聚焦窗口") + environmentSuffix(),
                   check: "P0-12 工作台入口")
            return
        }
        entryMainFrame = coordinator.state.records[candidate.identity]?.frame
        guard let target = panelPoint(for: candidate.identity) else {
            record("P0-12", "工作台入口", passed: nil,
                   detail: "\(candidate.applicationName) 的格子不在任何总览面板上，无法通过真实视图进入",
                   check: "P0-12 工作台入口")
            return
        }
        let clicksBefore = coordinator.cardClickCount
        guard sendRealMouseDownUp(target) else {
            record("P0-12", "工作台入口", passed: nil,
                   detail: "真实点击无法派发到总览内容视图（面板不存在或该点命中的不是它）",
                   check: "P0-12 工作台入口")
            return
        }
        let entered = await waitUntil(timeout: 8.0) {
            let state = self.coordinator.state
            return state.mode == .workbench
                && !state.workbench.modeTransition.isTransitioning
                && !state.workbench.mainSwitch.isBusy
        }
        // 进入会写真实窗口几何，读回要等目录刷新一轮：不刷新就读到的是写之前的 frame。
        try? await Task.sleep(nanoseconds: 300_000_000)
        let generation = coordinator.state.catalogGeneration
        coordinator.refreshNow()
        _ = await waitUntil(timeout: 2.0) { self.coordinator.state.catalogGeneration > generation }

        let state = coordinator.state
        var issues: [String] = []
        var facts: [String] = []
        let clicks = coordinator.cardClickCount - clicksBefore
        if clicks != 1 { issues.append("点击动作次数=\(clicks)") }
        if state.mode != .workbench { issues.append("进入后模式不是工作台（阶段=\(phaseDebug(state.phase))）") }
        if state.workbench.modeTransition.isTransitioning { issues.append("模式过渡仍在途") }
        if state.workbench.placement.main != candidate.identity {
            issues.append("主区=\(state.workbench.placement.main.map(\.journalKey) ?? "空")，期望 \(candidate.identity.journalKey)")
        }
        let overviewVisible = coordinator.controllers.values.filter(\.isVisible).count
        if overviewVisible != 0 { issues.append("总览面板仍可见 \(overviewVisible) 块") }
        if let snapshot = state.workbench.snapshot,
           let presentation = coordinator.workbenchPresentation,
           let controller = coordinator.workbenchControllers[presentation.displayID],
           let record = state.records[candidate.identity] {
            if !controller.isVisible { issues.append("工作台面板未显示") }
            let mapper = coordinator.catalog.mapper
            // 产品把面板窗口铺到 topPanelWindowRect/sidePanelWindowRect（顶栏含与主区之间的空隙带，§11.2），
            // 拿可见栏矩形来比会永远差一条空隙带；宿主的对应断言也是拿 PanelWindowRect 比。
            let topDeviation = P0Probe.rectDeviation(controller.topPanelFrame,
                                                     mapper.cgToAppKit(snapshot.layout.topPanelWindowRect).integral)
            let sideDeviation = P0Probe.rectDeviation(controller.sidePanelFrame,
                                                      mapper.cgToAppKit(snapshot.layout.sidePanelWindowRect).integral)
            if topDeviation > 1 || sideDeviation > 1 {
                issues.append("面板矩形偏离投影（顶 \(P0Probe.pt(topDeviation))pt / 侧 \(P0Probe.pt(sideDeviation))pt）")
            }
            if snapshot.layout.topRailRect.intersects(snapshot.layout.mainRect)
                || snapshot.layout.sideRailRect.intersects(snapshot.layout.mainRect) {
                issues.append("投影里栏与主区相交")
            }
            if snapshot.layout.isDegenerate { facts.append("该屏布局退化，只留主区") }
            if let entryFrame = entryMainFrame {
                let expected = FocusGeometry.dockedRect(in: snapshot.layout.mainRect,
                                                        currentSize: entryFrame.size,
                                                        isResizable: record.allowsGeometryControl)
                let physical = await waitForPhysicalFrame(candidate.identity, expected: expected) ?? record.frame
                let deviation = P0Probe.rectDeviation(physical, expected)
                if deviation > 4 {
                    // §10.1 要求可调整窗口精确占 mainRect；偏差就是偏差，不替应用解释。
                    issues.append("主窗口读回与主区目标偏差 \(P0Probe.pt(deviation))pt"
                                + "（读回 \(P0Probe.rectText(physical))，目标 \(P0Probe.rectText(expected))，"
                                + "可调整=\(record.allowsGeometryControl)）")
                } else {
                    facts.append("主窗口读回偏差 \(P0Probe.pt(deviation))pt（可调整=\(record.allowsGeometryControl)）")
                }
            } else {
                issues.append("进入前读不到主窗口原始 frame")
            }
            facts.append("面板=投影（顶 \(P0Probe.pt(topDeviation))pt / 侧 \(P0Probe.pt(sideDeviation))pt）")
        } else {
            issues.append("进入后没有投影/承载/记录，无法核对几何")
        }
        let blocked = permissionNote(.accessibility)
        record("P0-12", "工作台入口", passed: blocked == nil ? entered && issues.isEmpty : nil,
               detail: blocked ?? (issues.isEmpty
                    ? "真实点击卡片 \(candidate.identity.journalKey) 进入工作台：" + facts.joined(separator: "；")
                    : "问题：" + issues.joined(separator: "；")),
               check: "P0-12 工作台入口")
        manual("P0-12", "L 型与真实窗口", "点卡片后：主区必须是真实窗口（在其中打中文、右键、⌘W 都由真实应用响应），"
               + "两栏不得盖住主区，角落工具区的按钮可点。")
    }

    // MARK: - P0-13 主副交换（方案 §4.3、§6.1、§8）

    private func p0_13_mainSwitch() async {
        let state = coordinator.state
        guard state.mode == .workbench, !state.workbench.modeTransition.isTransitioning else {
            record("P0-13", "主副交换", passed: nil,
                   detail: "上一项没有进入工作台，无法验证交换", check: "P0-13 主副交换")
            return
        }
        guard let presentation = coordinator.workbenchPresentation,
              let main = state.workbench.placement.main else {
            record("P0-13", "主副交换", passed: nil,
                   detail: "工作台里没有投影或没有主窗口，无法验证交换", check: "P0-13 主副交换")
            return
        }
        let railCards = (presentation.topCards + presentation.sideCards).filter { $0.isVisible && $0.identity != main }
        guard let cardB = railCards.first else {
            record("P0-13", "主副交换", passed: nil,
                   detail: "两栏里没有可见卡片（只有主窗口，或该屏布局退化），本项不适用",
                   check: "P0-13 主副交换")
            manual("P0-13", "交换画面", "两个以上窗口时点顶栏/侧栏的预览：主区换成它，各自的小窗仍在原位，当前窗口显示强调色边框。")
            return
        }
        let beforeTop = state.workbench.scrollOffset(rail: .top)
        let beforeSide = state.workbench.scrollOffset(rail: .side)
        let beforeSeats = state.workbench.placement.occupants
        let beforeOthers = beforeSeats.filter { $0.value != main && $0.value != cardB.identity }
        let beforeFrames = beforeOthers.mapValues { state.records[$0]?.frame }
        let bSize = state.records[cardB.identity]?.frame.size

        // 交换必须由真实鼠标事件触发：直接 dispatch 的话，栏视图的命中与手势链断了也能"通过"。
        guard let railPoint = workbenchRailPoint(for: cardB.slot),
              sendRealMouseDownUp((railPoint.window, railPoint.point), hitView: railPoint.view) else {
            record("P0-13", "主副交换", passed: nil,
                   detail: "轨道卡片 \(cardB.slot.rail == .top ? "顶栏" : "侧栏")#\(cardB.slot.ordinal) 此刻不在画面上，"
                        + "或该点命中的不是轨道视图本身，无法派发真实点击",
                   check: "P0-13 主副交换")
            return
        }
        let switched = await waitUntil(timeout: 8.0) {
            let state = self.coordinator.state
            guard !state.workbench.mainSwitch.isBusy, !state.workbench.modeTransition.isTransitioning else { return false }
            return state.workbench.placement.main == cardB.identity
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let generation = coordinator.state.catalogGeneration
        coordinator.refreshNow()
        _ = await waitUntil(timeout: 2.0) { self.coordinator.state.catalogGeneration > generation }

        let after = coordinator.state
        var issues: [String] = []
        var facts: [String] = []
        if !switched {
            var reason = ""
            if case let .failed(_, note) = after.workbench.mainSwitch { reason = "；状态机给出的原因：\(note)" }
            issues.append("交换没有收敛到目标主区（主区=\(after.workbench.placement.main.map(\.journalKey) ?? "空")"
                        + "，阶段=\(phaseDebug(after.phase))\(reason)）")
        }
        if after.workbench.placement.occupant(at: cardB.slot) != cardB.identity {
            issues.append("被点窗口没有保留自己的轨道卡片")
        }
        if after.workbench.placement.occupants != beforeSeats {
            issues.append("切换改变了轨道卡片占位")
        }
        if after.workbench.scrollOffset(rail: .top) != beforeTop || after.workbench.scrollOffset(rail: .side) != beforeSide {
            issues.append("滚动偏移被改变（顶 \(beforeTop)→\(after.workbench.scrollOffset(rail: .top))，"
                        + "侧 \(beforeSide)→\(after.workbench.scrollOffset(rail: .side))）")
        }
        var moved: [String] = []
        for (slot, identity) in beforeOthers {
            guard let before = beforeFrames[slot] ?? nil else { continue }
            guard let now = after.records[identity]?.frame else {
                moved.append("\(identity.journalKey) 已不在目录")
                continue
            }
            let deviation = P0Probe.rectDeviation(before, now)
            if deviation > 4 { moved.append("\(identity.journalKey) 移动 \(P0Probe.pt(deviation))pt") }
        }
        if !moved.isEmpty { issues.append("非主窗口几何被动过：" + moved.joined(separator: "、")) }
        if let bSize, let recordB = after.records[cardB.identity], let snapshotNow = after.workbench.snapshot {
            let expected = FocusGeometry.dockedRect(in: snapshotNow.layout.mainRect,
                                                    currentSize: bSize,
                                                    isResizable: recordB.allowsGeometryControl)
            let physicalB = await waitForPhysicalFrame(cardB.identity, expected: expected) ?? recordB.frame
            let deviation = P0Probe.rectDeviation(physicalB, expected)
            if deviation > 4 {
                issues.append("新主窗口读回与主区目标偏差 \(P0Probe.pt(deviation))pt"
                            + "（读回 \(P0Probe.rectText(physicalB))，目标 \(P0Probe.rectText(expected))）")
            } else {
                facts.append("新主读回偏差 \(P0Probe.pt(deviation))pt")
            }
        }
        if let entryFrame = entryMainFrame, let recordA = after.records[main] {
            let physicalA = await waitForPhysicalFrame(main, expected: entryFrame) ?? recordA.frame
            let deviation = P0Probe.rectDeviation(physicalA, entryFrame)
            if deviation > 4 {
                issues.append("原主窗口没有回到进入前的位置（偏差 \(P0Probe.pt(deviation))pt）")
            } else {
                facts.append("原主回到进入前位置（偏差 \(P0Probe.pt(deviation))pt）")
            }
        }
        captureLedger(stage: "工作台在途·P0-13 单次交换后")
        record("P0-13", "主副交换", passed: issues.isEmpty,
               detail: issues.isEmpty
                    ? "真实点击\(cardB.slot.rail == .top ? "顶栏" : "侧栏")卡片 \(cardB.identity.journalKey)：主区切到它、"
                      + "原主 \(main.journalKey) 与被点窗口的小窗各留原位，其余 \(beforeOthers.count) 个占用与滚动偏移未动；"
                      + facts.joined(separator: "；")
                    : "问题：" + issues.joined(separator: "；"),
               check: "P0-13 主副交换")
        manual("P0-13", "交换画面", "点顶栏/侧栏里的一张预览：主区换成它、各自的小窗保留原位、仅当前窗口显示强调色边框；"
               + "先在栏里滚动几格再交换，确认滚动位置不回弹。")
    }

    // MARK: - P0-14 返回总览（方案 §4.4）

    private func p0_14_returnToOverview() async {
        guard coordinator.state.mode == .workbench else {
            record("P0-14", "返回总览", passed: nil,
                   detail: "当前不在工作台，无法验证「全部窗口」返回", check: "P0-14 返回总览")
            return
        }
        guard let buttonPoint = allWindowsButtonPoint() else {
            record("P0-14", "返回总览", passed: nil,
                   detail: "找不到「全部窗口」按钮的真实点位（按钮不在画面上，或该点的命中不是标题为「全部窗口」的按钮）",
                   check: "P0-14 返回总览")
            return
        }
        let dispatched = sendRealMouseDownUp((buttonPoint.window, buttonPoint.point), hitView: buttonPoint.view)
        let returned = await waitUntil(timeout: 8.0) {
            let state = self.coordinator.state
            return state.mode == .overview && !state.workbench.modeTransition.isTransitioning
                && state.phase == .overview
        }
        // 阶段先到 overview，面板要等返回飞行落定才上屏（揭示链 §10.1）：固定睡 300ms 采一次
        // 会把"飞行还没落地"读成"面板没显示"（0.1.10+18 那轮的 P0-14 红就是这个形状）。
        // 格子事实要有观察窗，与其它项一致。
        let panelsShown = await waitUntil(timeout: 3.0) {
            self.coordinator.controllers.values.contains(where: \.isVisible)
        }
        let panels = coordinator.controllers.values.filter(\.isVisible).count
        var issues: [String] = []
        if !dispatched { issues.append("真实点击无法派发到「全部窗口」按钮") }
        if !returned { issues.append("状态机没有回到总览（阶段=\(phaseDebug(coordinator.state.phase))）") }
        if !panelsShown { issues.append("总览面板没有重新显示（3s 观察窗内未见可见面板）") }
        record("P0-14", "返回总览", passed: issues.isEmpty,
               detail: issues.isEmpty
                    ? "真实点击「全部窗口」后回到总览，总览面板 \(panels) 块重新显示"
                    : "问题：" + issues.joined(separator: "；"),
               check: "P0-14 返回总览")
        manual("P0-14", "返回一致", "点「全部窗口」：回到的必须是进入前的那套总览（格子、搜索词、滚动位置都不变），背景不闪。")
    }

    // MARK: - P0-15 总览先行（方案 §19.1）

    /// 首开事实必须在任何点击之前取：本函数紧跟 run() 里首次 showOverview() 调用，
    /// 那时探针还没点过任何卡片（P0-4 起才会点）。「未点击前真实 frame 不变」的进程内
    /// 证据是"没有任何几何事务启动过"：写真实窗口只从事务出发，总览态至今没有任何事务。
    private func p0_15_overviewFirst() async {
        let state = coordinator.state
        let panels = coordinator.controllers.values.filter(\.isVisible).count
        let workbenchVisible = coordinator.workbenchControllers.values.filter(\.isVisible).count
        let eligible = state.records.values.filter(\.allowsAutoFocus)
        let missingCards = eligible.filter { coordinator.cardRects[$0.identity] == nil }
        var issues: [String] = []
        if state.mode != .overview { issues.append("首开模式不是总览") }
        if state.phase != .overview { issues.append("首开阶段=\(phaseDebug(state.phase))") }
        if state.workbench.placement.main != nil { issues.append("首开就有主区窗口") }
        if workbenchVisible != 0 { issues.append("首开就有工作台面板可见 \(workbenchVisible) 块") }
        if !state.transactions.isEmpty { issues.append("首开就有 \(state.transactions.count) 笔在途几何事务") }
        if coordinator.cardClickCount != 0 { issues.append("取证时已有 \(coordinator.cardClickCount) 次卡片点击") }
        if panels == 0 { issues.append("总览面板一块都没显示") }
        if !missingCards.isEmpty {
            issues.append("有 \(missingCards.count) 个可聚焦窗口没有总览格子（"
                        + missingCards.prefix(3).map(\.applicationName).joined(separator: "、") + "）")
        }
        // 方案 §19.1 的「至少 6 窗」是场景前提不是产品判据：窗口不够记未测，不替产品下结论。
        let enoughWindows = state.records.count >= 6
        let facts = "首开：模式=总览，总览面板 \(panels) 块，\(eligible.count) 个可聚焦窗口全部有格子（卡片位 \(coordinator.cardRects.count) 个），"
            + "主区=空，工作台面板=0，在途几何事务 0 笔，卡片点击 0 次"
        record("P0-15", "总览先行", passed: enoughWindows ? issues.isEmpty : nil,
               detail: (enoughWindows ? "" : "本机只有 \(state.records.count) 个窗口，未满足方案 §19.1 的「至少 6 窗」场景，先开够窗口再跑；")
                    + (issues.isEmpty ? facts : "问题：" + issues.joined(separator: "；")),
               check: "P0-15 总览先行")
        manual("P0-15", "首开录屏",
               "用快捷键与菜单栏各打开一次：首次必须是全屏总览；未点击任何卡片前，录屏确认没有窗口移动、没有出现两栏；点 A 之后才出现主区与两栏。")
        manual("P0-15", "退出重开不加记忆", "退出 Vistile 再启动，仍从总览开始，不记忆上次的 L 型。")
    }

    // MARK: - P0-16 固定交换 soak（方案 §19.2、§19.13）

    /// 连续真实点击轨道卡片做固定交换，逐轮核对硬不变量（方案 §6.1）：
    /// 中文：被点卡片进主区，所有轨道卡片保留原 slot，滚动偏移不动。
    /// English: Select the main window while preserving every rail slot and scroll offset.
    /// 中途刷新一次目录核对非参与窗口的真实 frame 没被写过（§19.2「其他卡片坐标不变」）。
    private func p0_16_swapSoak() async {
        let blocked = permissionNote(.accessibility)
        guard blocked == nil else {
            record("P0-16", "固定交换 100 次", passed: nil, detail: blocked!, check: "P0-16 固定交换 soak")
            manual("P0-16", "连续交换", "点开工作台后连续快速点两栏卡片：主区、卡片位置与滚动都不跳，无输入积压。")
            return
        }
        await restoreOverview()
        await refreshCatalog()
        if soakFrameBaseline.isEmpty { soakFrameBaseline = await captureStableFrameBaseline() }
        if coordinator.state.mode != .workbench {
            let entry = await enterWorkbenchViaRealClick()
            guard entry.ok else {
                record("P0-16", "固定交换 100 次", passed: nil,
                       detail: "进入工作台失败：\(entry.reason)\(environmentSuffix())", check: "P0-16 固定交换 soak")
                manual("P0-16", "连续交换", "点开工作台后连续快速点两栏卡片：主区、卡片位置与滚动都不跳，无输入积压。")
                return
            }
        }
        guard let presentation = coordinator.workbenchPresentation,
              let initialMain = coordinator.state.workbench.placement.main else {
            record("P0-16", "固定交换 100 次", passed: nil,
                   detail: "工作台里没有投影或没有主窗口", check: "P0-16 固定交换 soak")
            return
        }
        // 顶栏、侧栏各挑一张可点的卡交替交换：覆盖 §19.2 的「A↔顶部 B、A↔侧栏 C」两种路径。
        let topSlot = firstClickableRailSlot(in: presentation.topCards, excluding: initialMain)
        let sideSlot = firstClickableRailSlot(in: presentation.sideCards, excluding: initialMain)
        guard topSlot != nil || sideSlot != nil else {
            record("P0-16", "固定交换 100 次", passed: nil,
                   detail: "两栏里没有可见且可命中的卡片（只有主窗口，或该屏布局退化），本项不适用",
                   check: "P0-16 固定交换 soak")
            return
        }
        var participants: Set<WindowIdentity> = [initialMain]
        for slot in [topSlot, sideSlot].compactMap({ $0 }) {
            if let occupant = coordinator.state.workbench.placement.occupant(at: slot) { participants.insert(occupant) }
        }
        var failures: [String] = []
        var swaps = 0
        var topClicks = 0
        var sideClicks = 0
        var latencyMS: [Double] = []
        var consecutiveFailures = 0
        for index in 0..<100 {
            let preferTop = index % 2 == 0
            let preferred = preferTop ? (topSlot ?? sideSlot) : (sideSlot ?? topSlot)
            let currentMain = coordinator.state.workbench.placement.main
            let selectedSlot: RailSlotID?
            if let preferred, coordinator.state.workbench.placement.occupant(at: preferred) != currentMain {
                selectedSlot = preferred
            } else if let currentMain, let current = coordinator.workbenchPresentation {
                // Repeatedly clicking the selected card is a no-op. Choose a different
                // visible identity so every sample still measures a real switch.
                selectedSlot = firstClickableRailSlot(in: current.cards, excluding: currentMain)
            } else {
                selectedSlot = nil
            }
            guard let slot = selectedSlot,
                  let identity = coordinator.state.workbench.placement.occupant(at: slot),
                  let point = workbenchRailPoint(for: slot) else {
                failures.append("第 \(index + 1) 次：找不到可点的非当前轨道卡片")
                break
            }
            participants.insert(identity)
            let before = coordinator.state
            // 座位用身份→slot 的反向表：只比「两次都在场的窗口」的轨道位置，
            // 期间有别的窗口开合是环境噪声，不是产品把卡片挪了。
            let beforeSeat = Dictionary(uniqueKeysWithValues: before.workbench.placement.occupants
                .map { ($0.value, $0.key) })
            let beforeTopScroll = before.workbench.scrollOffset(rail: .top)
            let beforeSideScroll = before.workbench.scrollOffset(rail: .side)
            if let oldMain = before.workbench.placement.main { participants.insert(oldMain) }
            let started = monotonicNow()
            guard sendRealMouseDownUp((point.window, point.point), hitView: point.view) else {
                failures.append("第 \(index + 1) 次：真实点击无法派发")
                break
            }
            let converged = await waitUntil(timeout: 8.0) {
                self.isSettled(main: identity) && self.coordinator.workbenchControllers.values.contains(where: \.isVisible)
            }
            let latency = (monotonicNow() - started) * 1000
            latencyMS.append(latency)
            recordClickOutcome(path: "swap", ms: latency, settled: converged)
            if !converged {
                let state = coordinator.state
                var note = "-"
                if case let .failed(_, reason) = state.workbench.mainSwitch { note = reason }
                failures.append("第 \(index + 1) 次没收敛（主区=\(state.workbench.placement.main?.journalKey ?? "空")，"
                              + "阶段=\(phaseDebug(state.phase))，状态机=\(note)）")
                break
            }
            let after = coordinator.state
            var issues: [String] = []
            if after.workbench.placement.occupant(at: slot) != identity {
                issues.append("被点窗口没有保留自己的轨道卡片")
            }
            let afterSeat = Dictionary(uniqueKeysWithValues: after.workbench.placement.occupants.map { ($0.value, $0.key) })
            let movedCards = beforeSeat.compactMap { identity, seat -> String? in
                guard let now = afterSeat[identity], now != seat else { return nil }
                return "\(identity.journalKey) 从 \(Self.slotLabel(seat)) 挪到 \(Self.slotLabel(now))"
            }
            if !movedCards.isEmpty {
                issues.append("其他卡片挪位：" + movedCards.joined(separator: "、"))
            }
            if after.workbench.scrollOffset(rail: .top) != beforeTopScroll || after.workbench.scrollOffset(rail: .side) != beforeSideScroll {
                issues.append("滚动偏移被改变")
            }
            if issues.isEmpty {
                consecutiveFailures = 0
                swaps += 1
            } else {
                failures.append("第 \(index + 1) 次：" + issues.joined(separator: "、"))
                consecutiveFailures += 1
            }
            if slot.rail == .top { topClicks += 1 } else { sideClicks += 1 }
            // 中途取一次真实 frame 事实：非参与窗口不该被动过。
            if index == 49 {
                await refreshCatalog()
                captureLedger(stage: "工作台在途·交换第50次")
                let drift = frameDriftReport(baseline: soakFrameBaseline, excluding: participants)
                if !drift.silent.isEmpty {
                    failures.append("50 次后非参与窗口几何被动过：" + drift.silent.joined(separator: "、"))
                }
            }
            if consecutiveFailures >= 3 { break }
        }
        // 样本已在每次点击时按分组记进 soakLatencyMS（方案 §20.2），这里只算本轮的概览数字。
        let swapTimes = latencyMS
        let p95 = Self.percentile(of: swapTimes, 0.95)
        record("P0-16", "固定交换 100 次",
               passed: failures.isEmpty && swaps == 100,
               detail: failures.isEmpty
                    ? "真实点击交换 \(swaps) 次（顶栏 \(topClicks)、侧栏 \(sideClicks)）全部收敛：每轮被点卡进主区、"
                      + "所有小窗保留各自 slot、滚动偏移不变；点击→落定 p95=\(String(format: "%.0f", p95))ms（目标 ≤500ms）；"
                      + clickOutcomeText("swap", "交换") + "；"
                      + "非参与窗口 frame 对照在 P0-17 收尾统查"
                    : "已完成 \(swaps)/100 次；问题：" + failures.prefix(3).joined(separator: "；"),
               check: "P0-16 固定交换 soak")
        manual("P0-16", "连续交换", "点开工作台后连续快速点两栏卡片：立即反馈、无回跳、无输入积压；栏内滚动位置不乱。")
    }

    // MARK: - P0-17 往返 soak（方案 §19.10、§19.13）

    /// 「全部窗口」→总览→点卡片→工作台，连续 100 轮（≥§19.10 的 30 次往返，也给 §19.13 攒每条路径的样本）：
    /// 每轮核对总览冻结格位、轨道占用（往返目标除外）与滚动偏移不变、被点窗口成为主区；
    /// 收尾回总览刷新目录，统查全部存活窗口的真实 frame 相对基准无漂移（覆盖 §19.2 的坐标不变）。
    private func p0_17_roundTrips() async {
        let blocked = permissionNote(.accessibility)
        guard blocked == nil else {
            record("P0-17", "往返 100 次", passed: nil, detail: blocked!, check: "P0-17 往返 soak")
            manual("P0-17", "往返录屏", "点「全部窗口」回总览、再点同一/不同窗口，往返 30 次：总览位置、轨道位置、滚动都不变。")
            return
        }
        // 上一项可能留下隐藏态（例如 P0-16 撞上会话被外部中断）：先落回总览再进，
        // 不然"进不去"测的是残留现场而不是产品（与 P0-16 的入口约定一致）。
        await restoreOverview()
        if coordinator.state.mode != .workbench {
            let entry = await enterWorkbenchViaRealClick()
            guard entry.ok else {
                record("P0-17", "往返 100 次", passed: nil,
                       detail: "进入工作台失败：\(entry.reason)\(environmentSuffix())", check: "P0-17 往返 soak")
                manual("P0-17", "往返录屏", "点「全部窗口」回总览、再点同一/不同窗口，往返 30 次：总览位置、轨道位置、滚动都不变。")
                return
            }
        }
        guard let firstMain = coordinator.state.workbench.placement.main,
              let presentation = coordinator.workbenchPresentation else {
            record("P0-17", "往返 100 次", passed: nil,
                   detail: "工作台里没有主窗口或投影", check: "P0-17 往返 soak")
            return
        }
        // 目标：当前主 + 两栏第一张可见卡（只有一张时全程用同一窗口往返，覆盖"再点同一窗口"）。
        let second = presentation.cards.first { $0.isVisible && $0.identity != firstMain }?.identity
        let targets = second.map { [firstMain, $0] } ?? [firstMain]
        var failures: [String] = []
        var rounds = 0
        var cellBaseline: [WindowIdentity: CGPoint] = [:]
        var maxCellDeviation: CGFloat = 0
        var seatBaseline: [WindowIdentity: RailSlotID]?
        var baselineTopScroll: CGFloat?
        var baselineSideScroll: CGFloat?
        var consecutiveFailures = 0
        for index in 0..<100 {
            guard let button = allWindowsButtonPoint() else {
                failures.append("第 \(index + 1) 轮找不到「全部窗口」按钮")
                break
            }
            let returnStarted = monotonicNow()
            guard sendRealMouseDownUp((button.window, button.point), hitView: button.view) else {
                failures.append("第 \(index + 1) 轮「全部窗口」点击无法派发")
                break
            }
            let returned = await waitUntil(timeout: 8.0) { self.isSettled(overviewVisible: true) }
            recordClickOutcome(path: "return", ms: (monotonicNow() - returnStarted) * 1000, settled: returned)
            if !returned {
                failures.append("第 \(index + 1) 轮没回到总览（阶段=\(phaseDebug(coordinator.state.phase))）")
                break
            }
            // 总览冻结：同一窗口的格心（面板视图坐标）跨轮次必须一致。
            let identity = targets[index % targets.count]
            if let center = overviewCellLocal(for: identity) {
                if let baseline = cellBaseline[identity] {
                    let deviation = hypot(center.x - baseline.x, center.y - baseline.y)
                    maxCellDeviation = max(maxCellDeviation, deviation)
                    if deviation > 0.5 {
                        failures.append("第 \(index + 1) 轮总览格心漂移 \(String(format: "%.1f", deviation))pt")
                        consecutiveFailures += 1
                    }
                } else {
                    cellBaseline[identity] = center
                }
            } else {
                failures.append("第 \(index + 1) 轮 \(identity.journalKey) 的总览格子不在面板上")
                break
            }
            guard let point = panelPoint(for: identity) else {
                failures.append("第 \(index + 1) 轮 \(identity.journalKey) 格子不在面板上")
                break
            }
            let enterStarted = monotonicNow()
            guard sendRealMouseDownUp(point) else {
                failures.append("第 \(index + 1) 轮卡片点击无法派发")
                break
            }
            let entered = await waitUntil(timeout: 8.0) {
                self.isSettled(main: identity) && self.coordinator.workbenchControllers.values.contains(where: \.isVisible)
            }
            recordClickOutcome(path: "enter", ms: (monotonicNow() - enterStarted) * 1000, settled: entered)
            if !entered {
                let state = coordinator.state
                failures.append("第 \(index + 1) 轮进入没落定到 \(identity.journalKey)"
                              + "（主区=\(state.workbench.placement.main?.journalKey ?? "空")，阶段=\(phaseDebug(state.phase))）")
                break
            }
            // 轨道占用（往返目标除外）与滚动偏移不变。座位按身份比较：只查两轮都在场的窗口，
            // 收尾期间有窗口开合是环境噪声；「新窗口补位不挪动别的卡片」是方案 §4.4 的既有规则。
            let state = coordinator.state
            let seats = Dictionary(uniqueKeysWithValues: state.workbench.placement.occupants
                .filter { !targets.contains($0.value) }
                .map { ($0.value, $0.key) })
            if let baseline = seatBaseline {
                let moved = baseline.compactMap { identity, seat -> String? in
                    guard let now = seats[identity], now != seat else { return nil }
                    return "\(identity.journalKey) 从 \(Self.slotLabel(seat)) 挪到 \(Self.slotLabel(now))"
                }
                if !moved.isEmpty {
                    failures.append("第 \(index + 1) 轮其他窗口挪位：" + moved.joined(separator: "、"))
                    consecutiveFailures += 1
                }
            } else {
                seatBaseline = seats
                baselineTopScroll = state.workbench.scrollOffset(rail: .top)
                baselineSideScroll = state.workbench.scrollOffset(rail: .side)
            }
            if let top = baselineTopScroll, let side = baselineSideScroll,
               state.workbench.scrollOffset(rail: .top) != top || state.workbench.scrollOffset(rail: .side) != side {
                failures.append("第 \(index + 1) 轮滚动偏移被改变")
                consecutiveFailures += 1
            }
            if consecutiveFailures >= 3 { break }
            rounds += 1
        }
        // 收尾：回总览、刷新目录，统查全部存活窗口的真实 frame 漂移（含 P0-16 的交换参与者回落）。
        // 窗口服务器的几何提交滞后 AX 约 0.6s，两种误报都来自这个滞后：
        // 收尾第一次采样可能是旧几何 → 隔一轮再读，连续两次同一结论才判（0.1.10+20 的对策）；
        // 基准本身也可能是写回后立刻采到的旧几何 → 基准改为连续两次实读一致才记（0.1.10+22 的 241pt 误报即此）。
        await restoreOverview()
        if soakFrameBaseline.isEmpty { soakFrameBaseline = await captureStableFrameBaseline() }
        var drift = frameDriftReport(baseline: soakFrameBaseline, excluding: [])
        var driftRetries = 0
        while !(drift.silent.isEmpty && drift.reported.isEmpty), driftRetries < 3 {
            driftRetries += 1
            try? await Task.sleep(nanoseconds: 900_000_000)
            await refreshCatalog()
            let again = frameDriftReport(baseline: soakFrameBaseline, excluding: [])
            if again.silent == drift.silent, again.reported == drift.reported { break }
            drift = again
        }
        let enterTimes = latencyTotal("enter")
        let returnTimes = latencyTotal("return")
        var issues = failures
        if rounds != 100 { issues.append("完成 \(rounds)/100 轮") }
        if !drift.silent.isEmpty { issues.append("真实 frame 静默漂移（产品没有任何记录）：" + drift.silent.prefix(4).joined(separator: "、")) }
        record("P0-17", "往返 100 次", passed: issues.isEmpty,
               detail: issues.isEmpty
                    ? "「全部窗口」↔卡片往返 \(rounds) 轮全部落定；总览格心最大漂移 \(String(format: "%.2f", maxCellDeviation))pt（冻结）；"
                      + "非往返目标的轨道占用与滚动偏移不变；\(soakFrameBaseline.count) 个窗口真实 frame 相对基准"
                      + (drift.reported.isEmpty ? "无漂移"
                                                : "无静默漂移（\(drift.reported.count) 项已由产品回报："
                                                  + drift.reported.prefix(3).joined(separator: "、") + "）") + "；"
                      + "进入 p95=\(String(format: "%.0f", Self.percentile(of: enterTimes, 0.95)))ms（目标 ≤600ms）、"
                      + "返回 p95=\(String(format: "%.0f", Self.percentile(of: returnTimes, 0.95)))ms（目标 ≤500ms）；"
                      + clickOutcomeText("enter", "进入") + "；" + clickOutcomeText("return", "返回")
                    : "已完成 \(rounds)/100 轮；问题：" + issues.prefix(3).joined(separator: "；"),
               check: "P0-17 往返 soak")
        manual("P0-17", "往返录屏", "点「全部窗口」回总览、再点同一/不同窗口，往返 30 次：总览位置、轨道位置、滚动都不变，退出后再开仍从总览开始。")
    }

    // MARK: - P0-19 几何事务对照（方案 §22）

    /// 一行对照：一个被写窗口在某个时刻的全部几何事实。
    /// 交付清单要求「退出/失败恢复前后每个被写窗口的 original/before/target/readBack/displayID 对照」，
    /// 只给一句"恢复通过"不算交付——偏离多少、有没有读回，必须能从表里读出来。
    private struct LedgerRow {
        let stage: String
        let key: String
        let original: String
        let operationBefore: String
        let target: String
        let readBack: String
        let displayID: String
        let state: String
        let live: String
        let deviation: CGFloat

        var markdownLine: String {
            let dev = deviation < 0 ? "—" : String(format: "%.1f", deviation)
            return "| \(stage) | \(key) | \(original) | \(operationBefore) | \(target) | \(readBack) | \(displayID) | \(state) | \(live) | \(dev) |"
        }
    }

    /// 从 journal 的已提交事实采样一行行对照。工作台在途时调用，才有 target/readBack 可记。
    private func captureLedger(stage: String) {
        let records = coordinator.state.records
        for entry in coordinator.journal.snapshot.entries.values.sorted(by: { $0.identity.journalKey < $1.identity.journalKey }) {
            let key = entry.identity.journalKey
            let live = records[entry.identity]?.frame
            let dev = live.map { Self.rectDeviation($0, entry.originalFrame) } ?? -1
            let displayIDs = "原\(entry.originalDisplayID)/目标\(entry.plannedDisplayID.map(String.init) ?? "—")/读回\(entry.provisionalDisplayID.map(String.init) ?? "—")"
            ledgerRows.append(LedgerRow(stage: stage,
                                        key: key,
                                        original: Self.rectText(entry.originalFrame),
                                        operationBefore: entry.operationBeforeFrame.map(Self.rectText) ?? "—",
                                        target: entry.plannedFrame.map(Self.rectText) ?? "—",
                                        readBack: entry.lastProvisionalFrame.map(Self.rectText) ?? "—",
                                        displayID: displayIDs,
                                        state: String(describing: entry.state),
                                        live: live.map(Self.rectText) ?? "窗口已不在目录",
                                        deviation: dev))
            // 有读回=这次真的动过窗口。这份名单是收尾判定的依据：事务落定后会被正常删除。
            if let readBack = entry.lastProvisionalFrame {
                ledgerWrittenFacts[key] = LedgerWrittenFact(original: entry.originalFrame,
                                                            operationBefore: entry.operationBeforeFrame.map(Self.rectText) ?? "—",
                                                            target: entry.plannedFrame.map(Self.rectText) ?? "—",
                                                            readBack: readBack,
                                                            displayIDs: displayIDs)
            }
        }
    }

    /// 「恢复后」一侧也要逐窗口成行：只给未回位名单，读的人看不到每个被写窗口各自的最终事实，
    /// 就不满足方案 §22 的「退出/失败恢复前后」对照。落定的事务此时已从 journal 删除，
    /// 所以这些行只能由在途时留下的 `ledgerWrittenFacts` + 当前真实读数拼出来。
    private func appendRecoveredRows() {
        let records = coordinator.state.records
        let entries = coordinator.journal.snapshot.entries
        for (key, fact) in ledgerWrittenFacts.sorted(by: { $0.key < $1.key }) {
            let live = records.values.first { $0.identity.journalKey == key }?.frame
            let dev = live.map { Self.rectDeviation($0, fact.original) } ?? -1
            let state = entries[key].map { String(describing: $0.state) } ?? "已落定并删除"
            ledgerRows.append(LedgerRow(stage: "退出恢复后",
                                        key: key,
                                        original: Self.rectText(fact.original),
                                        operationBefore: fact.operationBefore,
                                        target: fact.target,
                                        readBack: Self.rectText(fact.readBack),
                                        displayID: fact.displayIDs,
                                        state: state,
                                        live: live.map(Self.rectText) ?? "窗口已不在目录",
                                        deviation: dev))
        }
    }

    /// 收尾对照：每个曾有真实写入读回的窗口，此刻必须回到会话 original。
    /// 窗口服务器几何提交滞后 AX（P0-17 同一实测结论），所以未回位的读数要连续两次一致才判。
    private func p0_19_transactionLedger() async {
        await refreshCatalog()
        var unrestored: [String] = []
        var attempts = 0
        while true {
            unrestored = ledgerUnrestoredReport()
            if unrestored.isEmpty || attempts >= 3 { break }
            attempts += 1
            try? await Task.sleep(nanoseconds: 900_000_000)
            await refreshCatalog()
        }
        // 前一次 refreshCatalog 就是最后一批真实读数：恢复后的行必须用它，不能再猜。
        appendRecoveredRows()
        let rows = ledgerRows.map(\.markdownLine).joined(separator: "\n")
        recorder.note("""
        ## P0-19 几何事务对照（方案 §22）
        | 时刻 | 窗口 | original | 操作前(before) | 目标(target) | 读回(readBack) | displayID 原/目标/读回 | 状态 | 当前真实 frame | 与 original 偏离pt |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        \(rows.isEmpty ? "| — | 本轮没采到在途事务 | | | | | | | | |" : rows)
        """)
        guard !ledgerWrittenFacts.isEmpty else {
            record("P0-19", "几何事务对照", passed: nil,
                   detail: "本轮没有任何「写入后读回」的窗口事实可对照（soak 未跑成或被环境挡住），"
                         + "对照表 \(ledgerRows.count) 行全是未写入事务；不能据此判定恢复正确",
                   check: "P0-19 几何事务对照")
            return
        }
        let lingering = coordinator.journal.snapshot.entries.values
            .filter { !$0.state.requiresRestore }
            .map { "\($0.identity.journalKey)（state=\($0.state)）" }
            .sorted()
        var issues: [String] = []
        if !unrestored.isEmpty {
            issues.append("曾有真实写入读回的窗口里 \(unrestored.count)/\(ledgerWrittenFacts.count) 个没回到 original："
                          + unrestored.prefix(4).joined(separator: "、"))
        }
        if !lingering.isEmpty {
            issues.append("收尾仍留存 \(lingering.count) 笔不要求恢复的事务（方案 §7.2 的未解释恢复义务）："
                          + lingering.prefix(4).joined(separator: "、"))
        }
        record("P0-19", "几何事务对照", passed: issues.isEmpty,
               detail: issues.isEmpty
                    ? "采到 \(ledgerRows.count) 行对照（覆盖 \(ledgerWrittenFacts.count) 个曾有写入读回的窗口）；"
                      + "退出恢复后每个被写窗口的真实 frame 与会话 original 偏离 ≤4pt；"
                      + "收尾无「不要求恢复却仍留存」的事务；逐行见报告对照表"
                    : issues.joined(separator: "；") + "；逐行见报告对照表",
               check: "P0-19 几何事务对照")
    }

    /// 曾有写入读回的窗口 → 现在还在 original 上吗。读不到当前 frame 的窗口（已关闭）不算未回位。
    private func ledgerUnrestoredReport() -> [String] {
        let records = coordinator.state.records
        return ledgerWrittenFacts.compactMap { key, fact in
            guard let now = records.values.first(where: { $0.identity.journalKey == key })?.frame else { return nil }
            let dev = Self.rectDeviation(now, fact.original)
            guard dev > 4 else { return nil }
            return "\(key) 现偏 original \(Self.pt(dev))pt（读回曾为 \(Self.rectText(fact.readBack))）"
        }.sorted()
    }

    // MARK: - P0-18 样本与帧预算（方案 §19.13、§20.2）

    private func p0_18_frameBudget() async {
        let summary = coordinator.metrics.summary()
        let counters = coordinator.metrics.snapshotCounters()
        var facts: [String] = []
        var shortfalls: [String] = []
        var misses: [String] = []
        let env = PerformanceEnvironment.current(coldStart: false)
        facts.append("分组环境：\(env.environmentLabel)，本机帧间隔 \(String(format: "%.2f", env.nativeFrameIntervalMS))ms"
            + "（§20.2 要求 60Hz/120Hz、reduceMotion、冷启动/热路径分别分组，下面的判定逐组给）")
        // Actual presented intervals use the group's native frame budget; unknown refresh rates stay unjudged.
        for kind in ["总览→L 型", "L 型内交换", "L 型→总览"] {
            let rows = groupedRows(in: summary, base: "过渡帧间隔p95·\(kind)")
            guard !rows.isEmpty else {
                shortfalls.append("\(kind) 没有帧样本（一个分组都没有）")
                continue
            }
            // 逐组累计有效间隔条数：§20.2 的 1,000 个间隔闸门按分组判；出现同名重复也直接相加，不崩。
            var intervals: [String: Int] = [:]
            for entry in groupedCounters(counters, base: "过渡有效帧间隔·\(kind)") {
                intervals[entry.groupKey, default: 0] += entry.value
            }
            for row in rows {
                let segments = Self.sampleCount(from: row.sample.context)
                let refreshLabel = row.groupKey.components(separatedBy: "·").first ?? ""
                guard refreshLabel.hasSuffix("Hz"), let refreshHz = Double(refreshLabel.dropLast(2)),
                      refreshHz.isFinite, refreshHz > 0 else {
                    shortfalls.append("\(kind)「\(row.groupKey)」缺少真实刷新率，帧预算未判")
                    continue
                }
                let frameTargetMS = 1000 / refreshHz + FrameIntervalStats.timestampToleranceMS
                let verdict = PerformanceGate.judge(groupKey: row.groupKey, count: segments,
                                                   p95MS: row.sample.valueMS, targetMS: frameTargetMS)
                let iv = intervals[row.groupKey] ?? 0
                facts.append("\(kind)「\(row.groupKey)」\(verdict.factText)，有效间隔 \(iv)")
                if segments < PerformanceGate.minSamples {
                    shortfalls.append("\(kind)「\(row.groupKey)」操作样本 \(segments) < \(PerformanceGate.minSamples)（§20.2 记未判）")
                } else if iv < Self.minIntervalsPerPath {
                    shortfalls.append("\(kind)「\(row.groupKey)」有效间隔 \(iv) < \(Self.minIntervalsPerPath)（§20.2 记未判）")
                } else if verdict.status == .miss {
                    misses.append("\(kind)「\(row.groupKey)」实际呈现间隔 p95 超本机帧预算 \(String(format: "%.2f", frameTargetMS))ms")
                }
            }
        }
        // ② 段级帧预算（掉帧占比 ≤1%、无连续 3 帧）按分组给，池化会看不出是哪一组在掉帧。
        let within = groupedCounters(counters, base: "过渡帧预算内")
        let over = groupedCounters(counters, base: "过渡超帧预算")
        let budgetGroups = Set(within.map { $0.groupKey }).union(over.map { $0.groupKey })
        for groupKey in budgetGroups.sorted() {
            let w = within.first { $0.groupKey == groupKey }?.value ?? 0
            let o = over.first { $0.groupKey == groupKey }?.value ?? 0
            facts.append("分组「\(groupKey)」帧预算：\(w) 段在内、\(o) 段超预算")
            if o > 0 { misses.append("分组「\(groupKey)」有 \(o) 段超出 §20.2 帧预算") }
        }
        if budgetGroups.isEmpty {
            facts.append("帧预算：没有任何分组计数（本轮没有过渡飞行完成）")
        }
        // 点击→第一帧单独判（方案 §20.2「把每段动画的首帧延迟单独记录」+ §20.1 点击反馈 P95 ≤50ms）。
        // 帧间隔统计只覆盖动画内部，看不见"点了很久没出第一帧"，所以两段各算各的。
        for kind in ["总览→L 型", "L 型内交换", "L 型→总览"] {
            let rows = groupedRows(in: summary, base: "过渡首帧延迟·\(kind)")
            guard !rows.isEmpty else {
                shortfalls.append("\(kind) 没有锚在真实点击上的首帧样本")
                continue
            }
            for row in rows {
                let n = Self.sampleCount(from: row.sample.context)
                let verdict = PerformanceGate.judge(groupKey: row.groupKey, count: n,
                                                   p95MS: row.sample.valueMS, targetMS: 50)
                facts.append("\(kind) 点击→首帧「\(row.groupKey)」\(verdict.factText)")
                if n < PerformanceGate.minSamples {
                    shortfalls.append("\(kind)「\(row.groupKey)」首帧样本 \(n) < \(PerformanceGate.minSamples)（§20.2 记未判）")
                } else if verdict.status == .miss {
                    misses.append("\(kind)「\(row.groupKey)」点击→首帧 p95 超 50ms 目标")
                }
            }
            // 无锚点的段（自动替补、探针直接 dispatch）单列，不参与"点击反馈"判定。
            for row in groupedRows(in: summary, base: "过渡首帧延迟(无点击锚点)·\(kind)") {
                facts.append("\(kind) 无点击锚点段「\(row.groupKey)」p95=\(String(format: "%.1f", row.sample.valueMS))ms"
                    + "（\(Self.sampleCount(from: row.sample.context)) 段，不计入点击反馈）")
            }
        }
        // 回调次数不能代替呈现（方案 §20.2）：present=0 的段没有画面证据，回调多于 present 的差额是真实丢帧。
        let zeroPresent = counters["过渡零呈现段"] ?? 0
        let callbackOnly = counters["过渡回调多于呈现"] ?? 0
        facts.append("呈现核对：\(zeroPresent) 段一次 present 都没有、回调多于呈现合计 \(callbackOnly) 帧")
        if zeroPresent > 0 { misses.append("有 \(zeroPresent) 段过渡没有任何画面证据") }
        if callbackOnly > 0 { misses.append("有 \(callbackOnly) 个显示链接回调没换成帧") }
        // 点击→落定延迟（单调时钟差值，方案 §20.2）。目标来自 §20.1（慢应用按方案允许超时回滚，数字就是数字，照实写）。
        let paths: [(key: String, kind: String, targetMS: Double)] = [
            ("enter", "总览→L 型", 600), ("swap", "L 型内交换", 500), ("return", "L 型→总览", 500)]
        for path in paths {
            let groups = soakLatencyMS[path.key] ?? [:]
            guard !groups.isEmpty else {
                shortfalls.append("\(path.kind) 没有「点击→落定」样本（\(clickOutcomeText(path.key, path.kind))）")
                continue
            }
            facts.append("\(path.kind) 落定核对：\(clickOutcomeText(path.key, path.kind))")
            let total = latencyTotal(path.key)
            recorder.recordPerformance(PerformanceSample(name: "点击→落定p95·\(path.kind)（\(groups.count) 个分组合池）",
                                                         valueMS: Self.percentile(of: total, 0.95),
                                                         context: "n=\(total.count)，成功率\(String(format: "%.1f%%", successRate(path.key)))，"
                                                            + "目标 ≤\(Int(path.targetMS))ms；合池只作概览，判定见逐组行"))
            for groupKey in groups.keys.sorted() {
                let values = groups[groupKey] ?? []
                let verdict = PerformanceGate.judge(groupKey: groupKey, values: values, targetMS: path.targetMS)
                let p95 = verdict.p95MS.isFinite ? String(format: "%.0fms", verdict.p95MS) : "无有效值"
                facts.append("\(path.kind) 点击→落定「\(groupKey)」p95=\(p95)（目标 ≤\(Int(path.targetMS))ms，n=\(values.count)，\(verdict.status.label)）")
                recorder.recordPerformance(PerformanceSample(name: "点击→落定p95·\(path.kind)·\(groupKey)",
                                                             valueMS: values.isEmpty ? 0 : verdict.p95MS,
                                                             context: "n=\(values.count)，目标 ≤\(Int(path.targetMS))ms，\(verdict.status.label)"))
                switch verdict.status {
                case .undetermined: shortfalls.append("\(path.kind)「\(groupKey)」延迟样本 \(values.count) < \(PerformanceGate.minSamples)（§20.2 记未判）")
                case .miss: misses.append("\(path.kind)「\(groupKey)」点击→落定 p95 超 \(Int(path.targetMS))ms 目标")
                case .pass: break
                }
            }
        }
        record("P0-18", "样本与帧预算", passed: shortfalls.isEmpty ? misses.isEmpty : nil,
               detail: (shortfalls.isEmpty ? "" : "样本不足（不能判）：\(shortfalls.joined(separator: "；"))；")
                    + (misses.isEmpty ? "" : "超目标：\(misses.joined(separator: "；"))；")
                    + facts.joined(separator: "；"),
               check: "P0-18 样本与帧预算")
        manual("P0-18", "录屏对照", "用 QuickTime 录总览→L型、交换、返回各一段，对照报告里的 p95 与录屏观感（无回跳、无输入积压）。")
    }

    /// §20.2「短场景累计至少 1,000 个有效间隔」：一条路径在一个分组里的帧间隔样本总数下限。
    private static let minIntervalsPerPath = 1_000

    /// `Metrics` 的指标名在分组后长这样：`<基名>·<分组键>`，summary 再拼「 p95」。
    /// 名字形状由 `PerformanceMetricName` 单点定义（生产侧与这里共用），解析不自己拼字符串——
    /// 两侧一改就走偏，报告会变成"一行样本都没有"，那是测量失效。
    private func groupedRows(in summary: [PerformanceSample], base: String) -> [(groupKey: String, sample: PerformanceSample)] {
        summary.compactMap { sample -> (String, PerformanceSample)? in
            guard let key = PerformanceMetricName.groupKey(fromSummaryRow: sample.name, base: base) else { return nil }
            return (key, sample)
        }.sorted { $0.groupKey < $1.groupKey }
    }

    /// 分组计数器的同一种形状：`<基名>·<分组键>` → 值。
    private func groupedCounters(_ counters: [String: Int], base: String) -> [(groupKey: String, value: Int)] {
        counters.compactMap { name, value in
            PerformanceMetricName.groupKey(fromCounterName: name, base: base).map { ($0, value) }
        }.sorted { $0.groupKey < $1.groupKey }
    }

    // MARK: - 长时运行（方案 §19.11、§20.3 P8；样本闸门 §19.13 也走这一轮）

    /// 反复走三条真实点击路径（返回总览 → 点卡片进工作台 → 点轨道卡交换），
    /// 周期采样本进程 RSS；结束时隐藏并核对活跃流最终为零。
    /// 点击→落定延迟与帧样本累计进 soakLatencyMS / Metrics，P0-18 在同一轮里按 n≥100 判定。
    private func longRun(minutes: Int) async {
        await restoreOverview()
        await refreshCatalog()
        if soakFrameBaseline.isEmpty { soakFrameBaseline = await captureStableFrameBaseline() }
        let started = monotonicNow()
        let deadline = started + Double(minutes) * 60
        let cpuStart = P0Probe.processCPUSeconds()
        var failures: [String] = []
        var rounds = 0
        var consecutiveFailures = 0
        var rssSamples: [(offset: TimeInterval, mb: Double)] = []
        // 单调时钟没有"纪元"可言，用"15 秒前"表达第一轮立即采一次（原来的 Date.distantPast 同一意图）。
        var lastSampleAt = monotonicNow() - 15
        while monotonicNow() < deadline {
            // 1) 返回总览：真实点击「全部窗口」；已经不在工作台就先补一次进入。
            if coordinator.state.mode == .workbench {
                guard let button = allWindowsButtonPoint() else {
                    failures.append("第 \(rounds + 1) 轮找不到「全部窗口」按钮")
                    break
                }
                let returnStarted = monotonicNow()
                guard sendRealMouseDownUp((button.window, button.point), hitView: button.view) else {
                    failures.append("第 \(rounds + 1) 轮「全部窗口」点击无法派发")
                    break
                }
                let returned = await waitUntil(timeout: 8.0) { self.isSettled(overviewVisible: true) }
                recordClickOutcome(path: "return", ms: (monotonicNow() - returnStarted) * 1000, settled: returned)
                guard returned else {
                    failures.append("第 \(rounds + 1) 轮没回到总览（阶段=\(phaseDebug(coordinator.state.phase))）")
                    break
                }
            } else if coordinator.state.phase != .overview {
                await restoreOverview()
            }
            // 2) 点卡片进工作台（同 P0-17 的判定：落定 + 工作台可见）。
            guard let candidate = expandCandidate(), let point = panelPoint(for: candidate.identity) else {
                failures.append("第 \(rounds + 1) 轮没有可点的总览卡片")
                break
            }
            let enterStarted = monotonicNow()
            guard sendRealMouseDownUp(point) else {
                failures.append("第 \(rounds + 1) 轮卡片点击无法派发")
                break
            }
            // 点击可能命中"身份瞬时未唯一"的复核重试：等待窗覆盖复核本身（实测约 0.5s）。
            let entered = await waitUntil(timeout: 10.0) {
                self.isSettled(main: candidate.identity) && self.coordinator.workbenchControllers.values.contains(where: \.isVisible)
            }
            recordClickOutcome(path: "enter", ms: (monotonicNow() - enterStarted) * 1000, settled: entered)
            guard entered else {
                failures.append("第 \(rounds + 1) 轮进入没落定到 \(candidate.identity.journalKey)"
                              + "（阶段=\(phaseDebug(coordinator.state.phase))）")
                break
            }
            // 3) 轨道交换：点一张不是主窗口的可见轨道卡。
            if let presentation = coordinator.workbenchPresentation,
               let slot = firstClickableRailSlot(in: presentation.cards, excluding: candidate.identity),
               let identity = presentation.cards.first(where: { $0.slot == slot })?.identity,
               let railPoint = workbenchRailPoint(for: slot) {
                let swapStarted = monotonicNow()
                guard sendRealMouseDownUp((railPoint.window, railPoint.point), hitView: railPoint.view) else {
                    failures.append("第 \(rounds + 1) 轮轨道点击无法派发")
                    break
                }
                let swapped = await waitUntil(timeout: 8.0) { self.isSettled(main: identity) }
                recordClickOutcome(path: "swap", ms: (monotonicNow() - swapStarted) * 1000, settled: swapped)
                if !swapped {
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 {
                        failures.append("第 \(rounds + 1) 轮起连续 \(consecutiveFailures) 轮交换没收敛，提前收尾")
                        break
                    }
                } else {
                    consecutiveFailures = 0
                    if ledgerRows.isEmpty { captureLedger(stage: "工作台在途·长跑首轮交换后") }
                }
            }
            rounds += 1
            if monotonicNow() - lastSampleAt >= 15 {
                lastSampleAt = monotonicNow()
                if let mb = P0Probe.residentFootprintMB() {
                    rssSamples.append((monotonicNow() - started, mb))
                }
            }
        }
        // 收尾：回总览 → 隐藏 → 活跃流最终为零（方案 §19.11）。
        await restoreOverview()
        coordinator.toggleOverview()
        _ = await waitUntil(timeout: 5.0) { self.coordinator.state.phase == .hidden }
        var streamsNow = coordinator.capture.activeStreamCount
        let streamDeadline = monotonicNow() + 10
        while streamsNow > 0, monotonicNow() < streamDeadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            streamsNow = coordinator.capture.activeStreamCount
        }
        let duration = monotonicNow() - started
        let cpuUsed = P0Probe.processCPUSeconds().flatMap { end in cpuStart.map { end - $0 } }
        let cpuAverage = cpuUsed.map { $0 / duration * 100 }
        let mb = { (value: Double) in String(format: "%.0f", value) }
        let rssFirst = rssSamples.prefix(3).map(\.mb)
        let rssLast = rssSamples.suffix(3).map(\.mb)
        let firstAvg = rssFirst.isEmpty ? nil : rssFirst.reduce(0, +) / Double(rssFirst.count)
        let lastAvg = rssLast.isEmpty ? nil : rssLast.reduce(0, +) / Double(rssLast.count)
        let rssMax = rssSamples.map(\.mb).max()
        // "无持续单调增长"的可核对判据：末三段均值不超过首三段均值 +50MB。
        let grew = firstAvg.flatMap { first in lastAvg.map { $0 > first + 50 } } ?? false
        var issues = failures
        if rounds == 0 { issues.append("一轮完整往返都没跑成") }
        if grew { issues.append("RSS 末段均值 \(mb(lastAvg ?? 0))MB 高于首段 \(mb(firstAvg ?? 0))MB 超 50MB") }
        if streamsNow != 0 { issues.append("隐藏后 10s 内活跃流未归零（现 \(streamsNow) 路）") }
        let walls = [("enter", "进入"), ("swap", "交换"), ("return", "返回")].map { key, label -> String in
            let values = latencyTotal(key)
            // 分组数写出来：长跑跨了 ProMotion 升降档或冷热两种路径时，这里先露出"数字来自几个组"，
            // 逐组的 P95 与判定在 P0-18（§20.2）。
            let groups = soakLatencyMS[key]?.count ?? 0
            return "\(label) n=\(values.count) p95=\(String(format: "%.0f", Self.percentile(of: values, 0.95)))ms"
                + (groups > 1 ? "（\(groups) 个分组）" : "")
        }
        let outcomes = [("enter", "进入"), ("swap", "交换"), ("return", "返回")]
            .map { key, label in clickOutcomeText(key, label) }
        record("P0-长跑", "\(minutes) 分钟长时运行", passed: issues.isEmpty,
               detail: (issues.isEmpty ? "" : "问题：" + issues.prefix(3).joined(separator: "；") + "；")
                    + "\(rounds) 轮完整往返、\(walls.joined(separator: "、"))；"
                    + "成功率与超时数：\(outcomes.joined(separator: "；"))；"
                    + "RSS 首段均值 \(firstAvg.map(mb) ?? "-")MB → 末段 \(lastAvg.map(mb) ?? "-")MB，峰值 \(rssMax.map(mb) ?? "-")MB；"
                    + "平均 CPU \(cpuAverage.map { String(format: "%.1f", $0) } ?? "-")%（100% = 一个逻辑核满载）；"
                    + "隐藏后活跃流 \(streamsNow) 路；窗口 \(coordinator.state.records.count) 个",
               check: "P0-长跑 30 分钟")
        manual("P0-长跑", "资源曲线对照", "对照活动监视器：30 分钟内 CPU/GPU/内存无持续单调增长，隐藏后窗口服务器活动回落；录屏抽查最后 1 分钟无卡顿。")
    }

    // MARK: - soak 辅助

    /// 等一次目录刷新落地：写回几何之后要看真实 frame，都必须先经过它。
    private func refreshCatalog() async {
        let generation = coordinator.state.catalogGeneration
        coordinator.refreshNow()
        _ = await waitUntil(timeout: 3.0) { self.coordinator.state.catalogGeneration > generation }
    }

    /// 进入/交换/返回的统一落定判据：模式、过渡、交换队列都落定；给了 main 还要主区身份对上。
    private func isSettled(main: WindowIdentity? = nil, overviewVisible: Bool = false) -> Bool {
        let state = coordinator.state
        guard !state.workbench.modeTransition.isTransitioning, !state.workbench.mainSwitch.isBusy else { return false }
        if overviewVisible {
            return state.mode == .overview && state.phase == .overview
                && coordinator.controllers.values.contains(where: \.isVisible)
        }
        guard state.mode == .workbench else { return false }
        if let main { return state.workbench.placement.main == main }
        return true
    }

    /// soak 前的进入：真实点击总览里排序第一张可点的卡片，等进入落定。
    private func enterWorkbenchViaRealClick() async -> (ok: Bool, reason: String) {
        guard coordinator.state.phase == .overview else {
            return (false, "总览没能打开（阶段=\(phaseDebug(coordinator.state.phase))）")
        }
        guard let candidate = expandCandidate(), let target = panelPoint(for: candidate.identity) else {
            return (false, "没有既可聚焦、又落在总览面板格子里的窗口")
        }
        guard sendRealMouseDownUp(target) else {
            return (false, "真实点击无法派发到总览内容视图")
        }
        let settled = await waitUntil(timeout: 8.0) {
            self.isSettled() && self.coordinator.workbenchControllers.values.contains(where: \.isVisible)
        }
        guard settled else {
            let state = coordinator.state
            return (false, "8s 内进入工作台没有落定（主区=\(state.workbench.placement.main?.journalKey ?? "空")，"
                    + "阶段=\(phaseDebug(state.phase))）")
        }
        return (true, "")
    }

    /// 可点的轨道卡：投影里可见、身份不是当前主、且那一格中心真的命中栏视图本身（点位不猜）。
    private func firstClickableRailSlot(in cards: [WorkbenchCard], excluding identity: WindowIdentity?) -> RailSlotID? {
        cards.first { $0.isVisible && $0.identity != identity && workbenchRailPoint(for: $0.slot) != nil }?.slot
    }

    /// 总览里某窗口格心在面板内容视图坐标里的位置：跨轮次比较"总览冻结"（视图坐标不受窗口移动影响）。
    private func overviewCellLocal(for identity: WindowIdentity) -> CGPoint? {
        guard let record = coordinator.state.records[identity],
              let controller = coordinator.controllers[record.displayID] else { return nil }
        return controller.contentView.cellCenter(for: identity)
    }

    /// 相对基准的真实 frame 偏差（pt）；已不在目录里的窗口跳过（关闭不算漂移）。
    /// 分为两类：产品在 state / 日志里记着未完成事务或失败原因的算「已回报」——
    /// 这一项查的是"不许静默挪窗口"，不是"产品不许失败"（0.1.10+22 的 ZCode 自身动画 44pt 误报即此）；
    /// 没有任何产品记录的偏差才是探针要抓的静默漂移（run9 的几何冻结即此类）。
    private func frameDriftReport(baseline: [WindowIdentity: CGRect],
                                  excluding: Set<WindowIdentity>) -> (silent: [String], reported: [String]) {
        let state = coordinator.state
        let unfinished = Set(coordinator.journal.unfinished.map(\.identity))
        var silent: [String] = []
        var reported: [String] = []
        for (identity, frame) in baseline where !excluding.contains(identity) {
            guard let now = state.records[identity]?.frame else { continue }
            let deviation = Self.rectDeviation(frame, now)
            guard deviation > 4 else { continue }
            let line = "\(identity.journalKey) 偏 \(Self.pt(deviation))pt"
            let acknowledged = state.transactions[identity]?.state.requiresRestore == true || unfinished.contains(identity)
            if acknowledged {
                let note = (state.transactions[identity]?.failureReason
                    ?? coordinator.journal.entry(for: identity)?.failureReason).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "有未完成几何事务"
                reported.append("\(line)（已回报：\(note)）")
            } else {
                silent.append(line)
            }
        }
        return (silent.sorted(), reported.sorted())
    }

    /// 基线必须在几何安静之后才记：窗口服务器的提交滞后 AX 约 0.6s，
    /// 写回后立刻采样会把旧主区几何记成"原位置"，收尾统查时倒打一耙（0.1.10+22 的 241pt 误报）。
    /// 连续两次读到同一组 frame 才认基线；目录每次重新实读。
    private func captureStableFrameBaseline() async -> [WindowIdentity: CGRect] {
        var previous = coordinator.state.records.mapValues(\.frame)
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 900_000_000)
            await refreshCatalog()
            let current = coordinator.state.records.mapValues(\.frame)
            let stable = Set(current.keys) == Set(previous.keys)
                && current.allSatisfy { identity, frame in
                    guard let before = previous[identity] else { return false }
                    return WindowTransaction.framesClose(before, frame, tolerance: 2)
                }
            if stable { return current }
            previous = current
        }
        return previous
    }

    private static func percentile(of values: [Double], _ q: Double) -> Double {
        PerformanceGate.percentile(of: values, q)
    }

    /// 记一次真实点击的样本与结果（方案 §20.2）：按分组攒延迟，同时累计该路径的派发/落定次数。
    /// 冷热在这里按"该路径本进程是否还没有过样本"判——第一次是冷启动，之后每一次都是热路径。
    private func recordClickOutcome(path: String, ms: Double, settled: Bool) {
        let seen = soakLatencyMS[path]?.values.reduce(0) { $0 + $1.count } ?? 0
        let group = PerformanceEnvironment.current(coldStart: seen == 0)
        soakLatencyMS[path, default: [:]][group.key, default: []].append(ms)
        var tally = clickTally[path] ?? (attempts: 0, settled: 0)
        tally.attempts += 1
        if settled { tally.settled += 1 }
        clickTally[path] = tally
    }

    /// 某条路径跨分组的样本合计：只用于 P0-16/P0-17 各自那行的概览数字，判定一律走分组（P0-18）。
    private func latencyTotal(_ path: String) -> [Double] {
        guard let groups = soakLatencyMS[path] else { return [] }
        return groups.values.flatMap { $0 }
    }

    /// §20.2 的成功率与超时数：派发过几次、落定几次、超时几次，按路径给。
    private func clickOutcomeText(_ path: String, _ kind: String) -> String {
        guard let tally = clickTally[path] else { return "\(kind) 没有派发过点击" }
        return "\(kind) 成功率\(String(format: "%.1f%%", successRate(path)))（\(tally.settled)/\(tally.attempts)）、超时\(tally.attempts - tally.settled)"
    }

    private func successRate(_ path: String) -> Double {
        guard let tally = clickTally[path], tally.attempts > 0 else { return 0 }
        return Double(tally.settled) / Double(tally.attempts) * 100
    }

    private static func slotLabel(_ slot: RailSlotID) -> String {
        "\(slot.rail.displayName)#\(slot.ordinal)"
    }

    /// Metrics 的 p95 行把样本数写在 context「n=123, median=…」里。
    private static func sampleCount(from context: String) -> Int {
        guard let range = context.range(of: "n=") else { return 0 }
        return Int(context[range.upperBound...].prefix { $0.isNumber }) ?? 0
    }

    // MARK: - 本轮取证环境自检

    /// 依赖帧的自动项（P0-2 / P0-9 / P0-10 / 性能采样）只有在"这一轮目录真的产过帧"时才谈得上成立；
    /// 依赖 AX 的项（P0-3 / P0-4 / P0-9）只有在"至少有一个窗口解析得出 AX 索引"时才谈得上成立。
    /// 0.1.6 实测过一整轮 0 帧；0.1.8 又实测过一整轮"画面有更新但 AX 全空"——那台机器当时锁着屏，
    /// 权限预检照样回 true，而任何应用的 AX 窗口列表都是空的。两种都会把环境产物记成产品结论，
    /// 所以这一项把"本轮到底能不能判"写成事实，不改任何一项的判据。
    private func environmentSelfCheck() async -> String {
        // 帧事实要有观察窗：锁屏/显示休眠与"刚重新打开、流还在起步"是两种形状。
        // 0.1.10+18 那轮在隐藏态采了一次样（信箱已释放）就写「全程 0 帧」，
        // 与同一份报告里 P0-2 的 96 帧自相矛盾——单一瞬时读数不能当环境结论。
        let deadline = monotonicNow() + 2.5
        var frames = totalPublished()
        while frames == 0 && monotonicNow() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            frames = totalPublished()
        }
        let records = Array(coordinator.state.records.values)
        let readable = records.filter { $0.confidence.allowsAXWrite }.count
        let streams = coordinator.capture.activeStreamCount
        let presented = coordinator.rendererDiagnostics.presents
        let locked = sessionLocked()
        let line = "窗口 \(records.count) 个（AX 可解析 \(readable) 个），活跃流 \(streams) 路，"
            + "本次启动累计捕获帧 \(frames)、累计 present \(presented)，会话锁定=\(locked ? "是" : "否")，"
            + "性能分组环境 \(PerformanceEnvironment.current(coldStart: false).environmentLabel)"
        var voids: [String] = []
        if records.isEmpty || frames == 0 {
            voids.append("可见态 2.5s 观察窗内 0 帧 → 依赖帧的 P0-2/P0-9/P0-10/性能采样 不能当产品结论")
        }
        if readable == 0 {
            voids.append("没有一个窗口解析得出 AX 索引 → 依赖 AX 的 P0-3/P0-4/P0-9 不能当产品结论")
        }
        record("环境自检", "本轮是否可判",
               passed: voids.isEmpty ? true : nil,
               detail: voids.isEmpty
                    ? "\(line)：画面在更新、AX 也解析得到，依赖帧与依赖 AX 的结论都可用"
                    : "\(line)：\(voids.joined(separator: "；"))。"
                      + "锁屏或显示休眠就是这个形状（此时权限预检仍回 true），请在解锁、唤醒的桌面上重跑同一条命令",
               check: "运行环境自检")
        return voids.isEmpty ? "本轮可判（\(line)）"
                             : "本轮不可全判：\(voids.joined(separator: "；"))（\(line)）"
    }

    // MARK: - 真实事件派发

    /// 探针的放大目标：按应用名 + 窗口编号固定排序，两次跑选到的是同一个窗口。
    /// 以前用的是 `records.values.first(where:)`，Dictionary 顺序不保证，所以 0.1.1 与 0.1.3
    /// 两轮测的根本不是同一个应用。`VISTILE_P0_TARGET` 指定时只在该应用里选（复测具体场景）。
    private func expandCandidate() -> WindowRecord? {
        let all = coordinator.state.records.values.filter(\.allowsAutoFocus)
            .sorted { ($0.applicationName, $0.identity.windowID) < ($1.applicationName, $1.identity.windowID) }
        let requested = P0Probe.targetFilter()
        guard !requested.isEmpty else { return all.first }
        return all.first { $0.applicationName.localizedCaseInsensitiveContains(requested)
            || ($0.bundleID ?? "").localizedCaseInsensitiveContains(requested) }
    }

    static func targetFilter() -> String {
        ProcessInfo.processInfo.environment["VISTILE_P0_TARGET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// 承载某窗口的面板 + 该格子中心在窗口坐标里的位置。拿不到就返回 nil，探针不许改用猜测坐标。
    private func panelPoint(for identity: WindowIdentity) -> (window: NSWindow, point: CGPoint)? {
        guard let record = coordinator.state.records[identity],
              let controller = coordinator.controllers[record.displayID] else { return nil }
        let view = controller.contentView
        guard let window = view.window, let local = view.cellCenter(for: identity) else { return nil }
        return (window, view.convert(local, to: nil))
    }

    /// 一整次左键按下 + 抬起，交给 NSWindow 做真实派发（hitTest → 视图手势 → 动作转接）。
    /// `hitView` 用于工作台的两栏与工具栏：调用方给出事件必须落到的视图，命中测试对不上就不发。
    private func sendRealMouseDownUp(_ target: (window: NSWindow, point: CGPoint), hitView: NSView? = nil) -> Bool {
        guard let content = target.window.contentView,
              let hit = content.hitTest(target.point),
              let down = Self.mouseEvent(.leftMouseDown, window: target.window, point: target.point),
              let up = Self.mouseEvent(.leftMouseUp, window: target.window, point: target.point) else { return false }
        if let hitView {
            guard hit === hitView || hit.isDescendant(of: hitView) else { return false }
        } else {
            guard content is OverviewContentView else { return false }
        }
        target.window.sendEvent(down)
        target.window.sendEvent(up)
        return true
    }

    /// 工作台某条栏上某张卡片的真实事件点。命中测试必须落回栏视图本身：
    /// 落在工具栏或按钮上的点会被它们吃掉，那种点不能当"点了卡片"用。
    private func workbenchRailPoint(for slot: RailSlotID) -> (window: NSWindow, point: CGPoint, view: NSView)? {
        guard let controller = coordinator.workbenchControllers[slot.displayID] else { return nil }
        let rail = slot.rail == .top ? controller.topRail : controller.sideRail
        guard let window = rail.window, let local = rail.cellCenter(for: slot) else { return nil }
        let point = rail.convert(local, to: nil)
        guard rail.hitTest(point) === rail else { return nil }
        return (window, point, rail)
    }

    /// 「全部窗口」按钮中心的真实事件点；标题对不上就不给坐标（不许猜位置）。
    private func allWindowsButtonPoint() -> (window: NSWindow, point: CGPoint, view: NSView)? {
        guard let controller = coordinator.workbenchControllers.values.first(where: { $0.isVisible }) else { return nil }
        let toolbar = controller.toolbarView
        guard let window = toolbar.window else { return nil }
        let frame = toolbar.allWindowsButtonFrame
        let point = toolbar.convert(CGPoint(x: frame.midX, y: frame.midY), to: nil)
        guard let button = window.contentView?.hitTest(point) as? NSButton, button.title == "全部窗口" else { return nil }
        return (window, point, toolbar)
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

    /// 两个矩形四条边的最大偏差（pt）。位置与尺寸一起比，避免"位置对了但尺寸没写进去"漏判。
    static func rectDeviation(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX),
            max(abs(a.minY - b.minY),
                max(abs(a.width - b.width), abs(a.height - b.height))))
    }

    static func pt(_ value: CGFloat) -> String { String(format: "%.1f", value) }

    static func rectText(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f %.0fx%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    // MARK: - 性能记录

    private func performanceSample() async {
        let framesBefore = totalPublished()
        let cpuBefore = P0Probe.processCPUSeconds()
        let started = monotonicNow()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let wall = max(0.001, monotonicNow() - started)
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

    /// 本进程已消耗的 CPU 时间（用户 + 系统），单位秒。100% 记法由调用方按采样时长（单调时钟）换算。
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

    /// 本进程物理内存占用（MB）：长跑看的就是这条曲线（方案 §19.11、§20.5）。
    static func residentFootprintMB() -> Double? {
        var info = rusage_info_current()
        let result: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) { raw in
                proc_pid_rusage(getpid(), Int32(truncatingIfNeeded: RUSAGE_INFO_CURRENT), raw)
            }
        }
        guard result == 0 else { return nil }
        return Double(info.ri_phys_footprint) / 1_048_576
    }

    /// VISTILE_P0_LONG_MINUTES 设置了分钟数才走长跑序列（0 或未设置 = 标准序列）。
    static func longRunMinutes() -> Int? {
        guard let raw = ProcessInfo.processInfo.environment["VISTILE_P0_LONG_MINUTES"] else { return nil }
        let minutes = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return minutes > 0 ? minutes : nil
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
        let status = coordinator.permissions.refresh()
        let granted = kind == .screenRecording ? status.screenRecording : status.accessibility
        guard granted else {
            return kind == .screenRecording
                ? "未授予屏幕录制：目录与帧数据不存在，本项无法判定（见 P0-0）"
                : "未授予辅助功能：不能操作真实窗口，本项无法判定（见 P0-0）"
        }
        return nil
    }

    /// 采样用的单调时钟（方案 §20.2「时间使用单调时钟；wall-clock 时间只用于报告日期」）。
    /// `Date()` 会被 NTP 步进、手动改表和时区调整挪动，用它做差能凭空造出 ±几十秒的"点击耗时"；
    /// `CACurrentMediaTime()` 走 mach_absolute_time，和过渡帧间隔样本（ModeTransitionCoordinator）同一时间域，
    /// 两边读数可以直接对齐。报告里的日期时间戳仍然用墙钟。
    private func monotonicNow() -> TimeInterval { CACurrentMediaTime() }

    private func waitUntil(timeout: TimeInterval = 6.0, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = monotonicNow() + timeout
        while monotonicNow() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return predicate()
    }

    /// 物理窗口的几何提交可能晚于状态机落定（实测 Chrome 重负载下晚约 0.7s：AX 写已接受、
    /// 窗口服务器到位在后）。判定"主区换成它"前按有界期限轮询目录，等物理 frame 真正到位；
    /// 到期仍不到位就返回最后一次读数，由调用方按事实判失败（方案 §6.1：读回为准，不替应用解释）。
    private func waitForPhysicalFrame(_ identity: WindowIdentity,
                                      expected: CGRect,
                                      tolerance: CGFloat = 4,
                                      timeout: TimeInterval = 2.0) async -> CGRect? {
        let deadline = monotonicNow() + timeout
        var latest = coordinator.state.records[identity]?.frame
        while monotonicNow() < deadline {
            if let latest, P0Probe.rectDeviation(latest, expected) <= tolerance { return latest }
            let generation = coordinator.state.catalogGeneration
            coordinator.refreshNow()
            _ = await waitUntil(timeout: 1.5) { self.coordinator.state.catalogGeneration > generation }
            latest = coordinator.state.records[identity]?.frame
            if let latest, P0Probe.rectDeviation(latest, expected) <= tolerance { return latest }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return latest
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
