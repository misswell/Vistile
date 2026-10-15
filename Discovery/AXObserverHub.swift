import AppKit
import ApplicationServices
import Foundation

/// 一次 AX 通知事实。元素本身用于把"哪个窗口变了"对回目录里的身份。
struct AXWindowEvent {
    let processID: pid_t
    let name: String
    let element: AXUIElement
}

/// 订阅应用与窗口的 AX 通知，只做"出变了"的信号，事件本体仍由一次目录刷新取得（方案 §6.6）。
/// 订阅失败或应用不支持 AX 时，靠 reconcile 低频补偿查询，不做任何猜测式轮询。
final class AXObserverHub {
    /// 应用级通知：结构变化。
    private static let applicationNotifications = [
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXApplicationActivatedNotification,
        kAXApplicationDeactivatedNotification,
        kAXApplicationHiddenNotification,
        kAXApplicationShownNotification,
        kAXSheetCreatedNotification
    ]

    /// 窗口级通知：几何与存活变化。
    private static let windowNotifications = [
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification
    ]

    var onWindowEvent: ((AXWindowEvent) -> Void)?
    var onSupportChanged: ((pid_t, Bool) -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var windowElementsByPID: [pid_t: [AXUIElement]] = [:]
    private var pendingEvents: [String] = []
    private var coalesceWork: DispatchWorkItem?
    private let coalesceInterval: TimeInterval = 0.12
    /// 明确不支持 AX 的进程：不再重复创建 observer，交给低频补偿。
    private var unsupported: Set<pid_t> = []

    deinit {
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
    }

    // MARK: - 订阅

    func observe(application pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        guard observers[pid] == nil, !unsupported.contains(pid) else { return }
        var observer: AXObserver?
        let error = AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let hub = Unmanaged<AXObserverHub>.fromOpaque(context).takeUnretainedValue()
            hub.receive(element: element, notification: notification)
        }, &observer)
        guard error == .success, let observer else {
            unsupported.insert(pid)
            onSupportChanged?(pid, false)
            return
        }
        observers[pid] = observer
        let app = AXUIElementCreateApplication(pid)
        for name in Self.applicationNotifications {
            AXObserverAddNotification(observer, app, name as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        onSupportChanged?(pid, true)
    }

    /// 每轮目录刷新后同步窗口级订阅集合；只注册仍存活的窗口，销毁的窗口显式取消订阅。
    func update(windowElements: [pid_t: [AXUIElement]]) {
        for pid in Set(observers.keys).union(windowElements.keys) {
            guard let observer = observers[pid] else { continue }
            let context = Unmanaged.passUnretained(self).toOpaque()
            let next = windowElements[pid] ?? []
            let previous = windowElementsByPID[pid] ?? []
            let nextIDs = Set(next.map { ObjectIdentifier($0 as Any as AnyObject) })

            for stale in previous where !nextIDs.contains(ObjectIdentifier(stale as Any as AnyObject)) {
                for name in Self.windowNotifications {
                    AXObserverRemoveNotification(observer, stale, name as CFString)
                }
            }
            for element in next {
                for name in Self.windowNotifications {
                    AXObserverAddNotification(observer, element, name as CFString, context)
                }
            }
            windowElementsByPID[pid] = next
        }
    }

    func stopObserving(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        windowElementsByPID.removeValue(forKey: pid)
    }

    func stopAll() {
        for pid in observers.keys { stopObserving(pid: pid) }
        unsupported.removeAll()
    }

    var observedPIDs: Set<pid_t> { Set(observers.keys) }
    var axUnsupportedPIDs: Set<pid_t> { unsupported }

    // MARK: - 事件合并

    private func receive(element: AXUIElement, notification: CFString) {
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        pendingEvents.append(notification as String)
        coalesce()
        onWindowEvent?(AXWindowEvent(processID: processID, name: notification as String, element: element))
    }

    /// 连续事件合并成一次刷新请求，避免拖动窗口时目录被打爆。
    private func coalesce() {
        coalesceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = self.pendingEvents.count
            self.pendingEvents.removeAll()
            self.onCoalescedEvents?(count)
        }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: work)
    }

    var onCoalescedEvents: ((Int) -> Void)?
}
