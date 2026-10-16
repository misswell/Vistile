import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VistileCore

/// 一次几何写入的完整事实：写前 frame、两侧写入的错误码、写后读回、结论。
/// "函数返回成功"不等于窗口到位，偏差也不能自证成部分成功（方案 §6.1）。
struct GeometryWriteReport: Equatable {
    let target: CGRect
    let frameBeforeWrite: CGRect?
    let sizeWriteError: Int
    let positionWriteError: Int
    let readBack: CGRect?
    let outcome: GeometryOutcome

    var readBackFrame: CGRect? { outcome.readBackFrame }
    var didChangeGeometry: Bool { outcome.didChangeGeometry }
}

/// 几何写入通道抽象：宿主测试用替身驱动交错与故障注入，真机走 AXWindowResolver（方案 §15.1）。
protocol GeometryWriting: AnyObject {
    func currentFrame(of element: AXUIElement) async -> CGRect?
    func apply(frame target: CGRect, element: AXUIElement) async -> GeometryWriteReport
    func raise(element: AXUIElement) async -> Bool
    func focus(element: AXUIElement) async -> Bool
    func setMinimized(_ minimized: Bool, element: AXUIElement) async -> Bool
    func focusedWindow(pid: pid_t) async -> AXWindowEntry?
    /// 写前直接问窗口一次"位置/尺寸能不能写"：目录快照里的 isMovable/isResizable
    /// 会把读取失败折叠成 false，一次读不到不能当成"窗口不可调整"的事实（方案 §6.1）。
    func geometryWriteability(element: AXUIElement) async -> GeometryWriteability
}

/// 写前事实读取的三种结论。读不到（超时/无响应）不是事实：既不能宣称"可写"，
/// 也不能宣称"不可写"——写入自身的读回才是最终判据。
enum GeometryWriteability: Equatable {
    case writeable
    case sizeNotSettable
    case positionNotSettable
    case unreadable
}

extension AXWindowResolver: GeometryWriting {}

extension GeometryWriteReport {
    /// 展开阶段可以用实际读回值继续展示；恢复阶段只有 exact 才算结束事务。
    var displayFrame: CGRect { readBackFrame ?? target }
}

/// AX 调用专用串行执行器：所有跨进程属性读写都走这里，主线程不阻塞。
final class AXExecutor: @unchecked Sendable {
    static let shared = AXExecutor()

    private let queue = DispatchQueue(label: "com.misswell.Vistile.ax", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    /// 有限消息超时：目标应用无响应时快速失败，不无限等待。
    var messagingTimeout: TimeInterval = 0.35

    func submit<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    func fire(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}

/// 一个 AX 窗口句柄 + 读取时的快照。句柄只在同一次解析内使用。
struct AXWindowEntry {
    let snapshot: AXWindowSnapshot
    let element: AXUIElement
}

/// 公开辅助功能接口封装。不使用任何私有 API，也不假设可以拿到 CGWindowID。
final class AXWindowResolver: @unchecked Sendable {
    private let executor: AXExecutor
    private let geometryTolerance: CGFloat

    init(executor: AXExecutor = .shared, geometryTolerance: CGFloat = 2) {
        self.executor = executor
        self.geometryTolerance = geometryTolerance
    }

    // MARK: - 只读

    func applicationElement(pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Float(executor.messagingTimeout))
        return element
    }

    /// 读取某进程的全部窗口。不支持 AX 的应用返回空数组，调用方据此降级为 previewOnly。
    func windows(pid: pid_t) async -> [AXWindowEntry] {
        await executor.submit {
            let app = self.applicationElement(pid: pid)
            guard let raw = self.copy(app, kAXWindowsAttribute),
                  let array = raw as? [AXUIElement] else { return [] }
            return array.enumerated().map { index, element in
                AXUIElementSetMessagingTimeout(element, Float(self.executor.messagingTimeout))
                return AXWindowEntry(snapshot: self.snapshot(of: element, index: index), element: element)
            }
        }
    }

    func focusedWindow(pid: pid_t) async -> AXWindowEntry? {
        await executor.submit {
            let app = self.applicationElement(pid: pid)
            guard let raw = self.copy(app, kAXFocusedWindowAttribute) else { return nil }
            let element = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(element, Float(self.executor.messagingTimeout))
            return AXWindowEntry(snapshot: self.snapshot(of: element, index: -1), element: element)
        }
    }

    /// 该窗口是否挂着需要用户处理的 Sheet（方案 §8.2.4）：只读公开属性，不做任何关闭动作。
    /// 公开 SDK 里没有 "AXSheets" 这个属性（实测 AppKit 窗口的属性表里不存在）；
    /// 真实的公开事实是：附着的 sheet 会作为窗口的一个 child 出现、role 为 AXSheet。
    /// 读不到一律按"没有"回答：不能因为读不到就替产品宣称阻塞，也不能拿它当拒绝的理由。
    func hasAttachedSheet(element: AXUIElement) async -> Bool {
        await executor.submit {
            guard let children = self.copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return false }
            for child in children where self.string(child, kAXRoleAttribute) == NSAccessibility.Role.sheet.rawValue {
                return true
            }
            return false
        }
    }

    private func snapshot(of element: AXUIElement, index: Int) -> AXWindowSnapshot {
        AXWindowSnapshot(index: index,
                         frame: frame(of: element),
                         title: string(element, kAXTitleAttribute) ?? "",
                         role: string(element, kAXRoleAttribute) ?? "AXWindow",
                         subrole: string(element, kAXSubroleAttribute),
                         isMinimized: boolean(element, kAXMinimizedAttribute) ?? false,
                         isMain: boolean(element, kAXMainAttribute) ?? false,
                         isFocused: boolean(element, kAXFocusedAttribute) ?? false,
                         isMovable: settable(element, kAXPositionAttribute),
                         isResizable: settable(element, kAXSizeAttribute))
    }

    /// AX frame：左上原点的全局坐标，与 CG 全局坐标系一致。
    /// 同步版本只允许在 AX 执行队列或启动恢复路径上使用；主线程请用 currentFrame。
    func frame(of element: AXUIElement) -> CGRect? {
        guard let position = copy(element, kAXPositionAttribute),
              let size = copy(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimension = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimension) else { return nil }
        return CGRect(origin: point, size: dimension)
    }

    /// 主线程安全的读取：跨进程调用放到 AX 队列，避免通知密集时卡住 UI。
    func currentFrame(of element: AXUIElement) async -> CGRect? {
        await executor.submit { self.frame(of: element) }
    }

    // MARK: - 写入（每一步都读回）

    /// 设置几何：先尺寸后位置；跨显示器偏差时最多再做一次 size→position 补偿。
    /// 写前读不到 frame 就不写：没有基准就无法判断这次写入到底改了什么。
    func apply(frame target: CGRect, element: AXUIElement) async -> GeometryWriteReport {
        await executor.submit {
            let clamped = target.standardized
            guard let before = self.frame(of: element) else {
                return GeometryWriteReport(target: clamped, frameBeforeWrite: nil,
                                           sizeWriteError: Int(AXError.cannotComplete.rawValue),
                                           positionWriteError: Int(AXError.cannotComplete.rawValue),
                                           readBack: nil, outcome: .unreadable)
            }
            let first = self.writeOnce(clamped, element: element, before: before)
            guard self.needsCompensation(first, before: before) else { return first }
            // 跨不同 scaling 的显示器常见"位置被接受但尺寸被应用重算"：补偿一次，最多一次。
            return self.writeOnce(clamped, element: element, before: before)
        }
    }

    func applyPosition(_ origin: CGPoint, element: AXUIElement) async -> GeometryWriteReport {
        await executor.submit {
            guard let before = self.frame(of: element) else {
                return GeometryWriteReport(target: CGRect(origin: origin, size: .zero), frameBeforeWrite: nil,
                                           sizeWriteError: Int(AXError.cannotComplete.rawValue),
                                           positionWriteError: Int(AXError.cannotComplete.rawValue),
                                           readBack: nil, outcome: .unreadable)
            }
            let target = CGRect(origin: origin, size: before.size)
            let positionError = self.writePosition(origin, element: element)
            let readBack = self.readBackFrame(element)
            return Self.classify(target: target, before: before, sizeError: 0, positionError: positionError,
                                 readBack: readBack, tolerance: self.geometryTolerance)
        }
    }

    private func writeOnce(_ target: CGRect, element: AXUIElement, before: CGRect) -> GeometryWriteReport {
        let sizeError = writeSize(target.size, element: element)
        let positionError = writePosition(target.origin, element: element)
        let readBack = readBackFrame(element)
        return Self.classify(target: target, before: before, sizeError: sizeError, positionError: positionError,
                             readBack: readBack, tolerance: geometryTolerance)
    }

    /// 写后读回给一个有界重试窗口：写入双侧回报成功（错误码 0）时，单次读失败不能当成终审。
    /// run11 P0-17 第 62 轮：Chrome 写入错误码全 0、单次读回=nil 被按"不能宣称到位"拒绝并补偿回滚，
    /// 而 32ms 后的恢复路径读到了 66,184——应用刚被改几何时 AX 会短暂忙。
    /// 重试仍读不到才按 .unreadable 拒绝：读到才算数（方案 §6.1）。
    private func readBackFrame(_ element: AXUIElement, attempts: Int = 3,
                               gap: TimeInterval = 0.07) -> CGRect? {
        for attempt in 0..<attempts {
            if let frame = self.frame(of: element) { return frame }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: gap) }
        }
        return nil
    }

    /// 写前事实：分别读 kAXSize / kAXPosition 的可写性。任一读不到就整体按"读不到"回报，
    /// 因为把半次读取拼成结论同样是把读失败当事实（方案 §6.1）。
    func geometryWriteability(element: AXUIElement) async -> GeometryWriteability {
        await executor.submit {
            guard let size = self.settable(element, kAXSizeAttribute),
                  let position = self.settable(element, kAXPositionAttribute) else { return .unreadable }
            if !size { return .sizeNotSettable }
            if !position { return .positionNotSettable }
            return .writeable
        }
    }

    /// 只有"确实发生了变化但没到位"才值得再补偿一次；完全没变化说明被拒绝，重试只会白等。
    private func needsCompensation(_ report: GeometryWriteReport, before: CGRect) -> Bool {
        guard case .constrained = report.outcome else { return false }
        return report.readBackFrame != nil
    }

    /// 结论判定：exact 只在容差内；被拒绝或读不回都不能宣称成功（方案 §6.1）。
    /// 读回优先于错误码：-25204 这类"无法完成"的报错在实机上窗口可能已经到位
    /// （run10：Chrome 位置写入报 -25204，读回 66,184 ≈ 目标 66,183）。此时宣布失败
    /// 会把一个已经在目标位的窗口拉回去——错误码不许覆盖读回证据。
    static func classify(target: CGRect,
                         before: CGRect,
                         sizeError: Int,
                         positionError: Int,
                         readBack: CGRect?,
                         tolerance: CGFloat) -> GeometryWriteReport {
        let outcome: GeometryOutcome
        let sizeFailed = sizeError != Int(AXError.success.rawValue)
        let positionFailed = positionError != Int(AXError.success.rawValue)
        if let readBack, Self.deviation(target, readBack) <= tolerance {
            // 读回是事实：只要落点在容差内就是 exact，哪怕这次写入报了错。
            outcome = .exact(readBack: readBack)
        } else if sizeFailed || positionFailed {
            outcome = .rejected(sizeFailed ? .sizeWrite(code: sizeError) : .positionWrite(code: positionError))
        } else if let readBack {
            if readBack != before {
                // 有明确证据说明应用接受了部分写入（多为自身尺寸约束）：不等于回到目标，也不等于失败。
                outcome = .constrained(readBack: readBack)
            } else {
                outcome = .rejected(.unchangedByWrite(previous: before))
            }
        } else {
            outcome = .unreadable
        }
        return GeometryWriteReport(target: target, frameBeforeWrite: before,
                                   sizeWriteError: sizeError, positionWriteError: positionError,
                                   readBack: readBack, outcome: outcome)
    }

    static func deviation(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.origin.x - b.origin.x), abs(a.origin.y - b.origin.y),
            abs(a.width - b.width), abs(a.height - b.height))
    }

    /// 解除最小化。写后读回确认，不返回未验证的成功。
    func setMinimized(_ minimized: Bool, element: AXUIElement) async -> Bool {
        await executor.submit {
            let error = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
            guard error == .success else { return false }
            return self.boolean(element, kAXMinimizedAttribute) == minimized
        }
    }

    private func writeSize(_ size: CGSize, element: AXUIElement) -> Int {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return Int(AXError.invalidUIElement.rawValue) }
        return Int(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue).rawValue)
    }

    private func writePosition(_ origin: CGPoint, element: AXUIElement) -> Int {
        var value = origin
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return Int(AXError.invalidUIElement.rawValue) }
        return Int(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue).rawValue)
    }

    /// 公开 Raise action；是否足以稳定压过其他应用窗口需要 P0 实测。
    func raise(element: AXUIElement) async -> Bool {
        await executor.submit {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        }
    }

    func focus(element: AXUIElement) async -> Bool {
        await executor.submit {
            let app = self.applicationElement(pid: self.pid(of: element))
            let error = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, element)
            guard error == .success else { return false }
            if let focused = self.copy(app, kAXFocusedWindowAttribute) {
                return CFEqual(focused, element)
            }
            return false
        }
    }

    // MARK: - 属性原语

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    private func boolean(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = copy(element, attribute) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func settable(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var flag: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, attribute as CFString, &flag) == .success else { return nil }
        return flag.boolValue
    }

    private func pid(of element: AXUIElement) -> pid_t {
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        return processID
    }
}

extension AXWindowSnapshot {
    /// 只有属性可读且位置/尺寸可写时，才允许几何事务。
    var supportsGeometryWrite: Bool {
        isMovable == true && isResizable == true
    }
}
