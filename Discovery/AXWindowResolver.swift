import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import VistileCore

/// 单次 AX 读回校验结果。函数返回成功不等于窗口真的到位（方案 §6 末段）。
struct GeometryVerification: Equatable {
    let requested: CGRect
    let readBack: CGRect?
    let tolerance: CGFloat

    var deviation: CGFloat {
        guard let readBack else { return .infinity }
        return max(abs(readBack.origin.x - requested.origin.x),
                   abs(readBack.origin.y - requested.origin.y),
                   abs(readBack.width - requested.width),
                   abs(readBack.height - requested.height))
    }

    var isExact: Bool { deviation <= tolerance }
    /// 应用自身限制最小尺寸时按实际返回值接受，但必须记录偏差。
    var isPartial: Bool { readBack != nil && !isExact && deviation.isFinite }
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

    /// 解除最小化。写后读回确认，不返回未验证的成功。
    func setMinimized(_ minimized: Bool, element: AXUIElement) async -> Bool {
        await executor.submit {
            let error = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                                     minimized ? kCFBooleanTrue : kCFBooleanFalse)
            guard error == .success else { return false }
            return self.boolean(element, kAXMinimizedAttribute) == minimized
        }
    }

    /// 设置几何：先尺寸后位置；跨显示器偏差时最多再做一次 size→position 补偿。
    func apply(frame target: CGRect, element: AXUIElement) async -> GeometryVerification {
        await executor.submit {
            let clamped = target.standardized
            self.writeSize(clamped.size, element: element)
            self.writePosition(clamped.origin, element: element)
            var verification = GeometryVerification(requested: clamped,
                                                   readBack: self.frame(of: element),
                                                   tolerance: self.geometryTolerance)
            if !verification.isExact, verification.isPartial {
                // 跨不同 scaling 的显示器时常见"位置被接受但尺寸被应用重算"：补偿一次，最多一次。
                self.writePosition(clamped.origin, element: element)
                self.writeSize(clamped.size, element: element)
                verification = GeometryVerification(requested: clamped,
                                                   readBack: self.frame(of: element),
                                                   tolerance: self.geometryTolerance)
            }
            return verification
        }
    }

    func applyPosition(_ origin: CGPoint, element: AXUIElement) async -> GeometryVerification {
        await executor.submit {
            self.writePosition(origin, element: element)
            let readBack = self.frame(of: element)
            let requested = CGRect(origin: origin, size: readBack?.size ?? .zero)
            return GeometryVerification(requested: requested, readBack: readBack, tolerance: self.geometryTolerance)
        }
    }

    private func writeSize(_ size: CGSize, element: AXUIElement) {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    private func writePosition(_ origin: CGPoint, element: AXUIElement) {
        var value = origin
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
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
