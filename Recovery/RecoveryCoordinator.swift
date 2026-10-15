import AppKit
import Foundation
import VistileCore

/// 崩溃恢复：下次启动只做保守判定，绝不凭旧 windowID 或同标题盲恢复（方案 §10.5）。
/// 目录与句柄表只在主 Actor 上发布，这里也必须在主 Actor 上读取同一代次。
@MainActor
final class RecoveryCoordinator {
    private let store: WindowJournalStore
    private let resolver: AXWindowResolver
    private let catalog: WindowCatalog
    private let settings: SettingsModel

    /// 恢复失败可重试一次，之后只保留诊断，不弹阻断操作的循环对话框。
    private let maxRestoreAttempts = 1

    init(store: WindowJournalStore = WindowJournalStore(),
         resolver: AXWindowResolver = AXWindowResolver(),
         catalog: WindowCatalog,
         settings: SettingsModel) {
        self.store = store
        self.resolver = resolver
        self.catalog = catalog
        self.settings = settings
    }

    struct RestoredWindow {
        let identity: WindowIdentity
        let decision: RecoveryDecision
        let verified: GeometryVerification?
    }

    /// 启动时处理上次未结束的事务。返回逐条事实供诊断记录。
    @discardableResult
    func restoreOnLaunch(recorder: CompatibilityRecorder? = nil) async -> [RestoredWindow] {
        let pending = store.unfinished
        guard !pending.isEmpty else { return [] }
        recorder?.note("发现 \(pending.count) 条未结束的几何事务，按保守策略处理")

        // 先建立一次目录，才能判断进程是否重启、窗口是否仍存活。
        // 这里等的是"这一轮查询真正结束"，不是固定睡眠：慢机器上 250ms 并不足以拿到 AX 句柄。
        await catalog.refreshAndWait(reason: .shortcut)

        var results: [RestoredWindow] = []
        let mapper = catalog.mapper
        for entry in pending {
            let record = catalog.record(for: entry.identity)
            let isProcessAlive = NSRunningApplication(processIdentifier: entry.identity.processID)
                .map { $0.processIdentifier == entry.identity.processID
                    && ProcessIdentityReader.startIdentity(for: $0.processIdentifier) == entry.identity.processStartIdentity }
                ?? false
            let isWindowAlive = record != nil && record?.capture != .closed
            let isOriginalDisplayLive = mapper.display(id: entry.originalDisplayID) != nil
            let clamped = mapper.display(id: entry.originalDisplayID).map { _ in
                entry.originalFrame
            } ?? mapper.clamp(entry.originalFrame, to: nil)

            let decision = RecoveryPlanner.decide(entry: entry,
                                                  currentFrame: record?.frame,
                                                  isWindowAlive: isWindowAlive,
                                                  isProcessAlive: isProcessAlive,
                                                  isOriginalDisplayLive: isOriginalDisplayLive,
                                                  clampedFrame: clamped,
                                                  preserveUserGeometry: settings.preserveUserGeometry)
            guard decision.shouldWriteAX, let record, let ax = catalog.axEntry(for: record) else {
                results.append(RestoredWindow(identity: entry.identity, decision: decision, verified: nil))
                if case .skipProcessRestarted = decision { recorder?.note("跳过恢复：进程已重启 \(entry.bundleID ?? "")") }
                if case .skipWindowGone = decision { recorder?.note("跳过恢复：窗口已不存在") }
                if case let .skipUserMoved(current) = decision {
                    recorder?.note("跳过恢复：用户已自行移动窗口（当前 \(Self.text(current))）")
                }
                store.drop(entry.identity)
                continue
            }

            let target = decision.frame ?? entry.originalFrame
            let verification = await resolver.apply(frame: target, element: ax.element)
            if verification.isExact || verification.isPartial {
                store.markRestored(entry.identity)
                store.drop(entry.identity)
                if verification.isPartial {
                    recorder?.note("恢复偏差 \(String(format: "%.1f", verification.deviation))pt：应用自身尺寸约束")
                }
            } else if entry.restoreAttempts < maxRestoreAttempts {
                store.apply(entry.markingFailed("crash restore failed"))
                recorder?.note("恢复失败，保留可重试记录：\(entry.identity)")
            } else {
                store.drop(entry.identity)
                recorder?.note("恢复失败已达重试上限，终止重试：\(entry.identity)")
            }
            results.append(RestoredWindow(identity: entry.identity, decision: decision, verified: verification))
        }
        return results
    }

    /// 正常退出：把所有仍未结束的事务恢复原 frame。崩溃不能靠 defer 保证执行。
    func restoreOnQuit() async {
        let pending = store.unfinished
        guard !pending.isEmpty else { return }
        for entry in pending {
            guard let record = catalog.record(for: entry.identity),
                  let ax = catalog.axEntry(for: record) else {
                store.drop(entry.identity)
                continue
            }
            let target = entry.restoreTargetFrame(preserveUserGeometry: settings.preserveUserGeometry)
            let verification = await resolver.apply(frame: target, element: ax.element)
            if verification.isExact || verification.isPartial {
                store.markRestored(entry.identity)
                store.drop(entry.identity)
            } else {
                store.apply(entry.markingFailed("quit restore failed"))
            }
        }
    }

    static func text(_ rect: CGRect) -> String {
        "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))"
    }
}

private extension RecoveryDecision {
    var frame: CGRect? {
        switch self {
        case let .restore(to: to): return to
        case let .clampAndRestore(to: to): return to
        case let .skipPreserveUserGeometry(keep: keep): return keep
        default: return nil
        }
    }
}
