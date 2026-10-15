import Foundation
import CoreGraphics

/// 稳定的格子位置登记表（方案 §8.3）。
/// 聚焦、返回、切换都不重排；只有用户明确"整理"或重新进入才压缩占位。
public struct SlotRegistry: Hashable, Sendable {
    public enum SlotContent: Hashable, Sendable {
        case occupied(WindowIdentity, memoryKey: String)
        case vacant

        public var identity: WindowIdentity? {
            if case let .occupied(identity, _) = self { return identity }
            return nil
        }
    }

    public private(set) var slots: [SlotContent]
    /// 容量不足时的排队窗口，不自动隐藏任何窗口。
    public private(set) var pending: [PendingWindow]
    public var capacity: Int

    public struct PendingWindow: Hashable, Sendable {
        public let identity: WindowIdentity
        public let memoryKey: String
        public let applicationName: String
        public let title: String
    }

    /// 跨会话记忆的顺序偏好：memoryKey -> 期望序号。
    public var orderPreference: [String: Int]

    public init(capacity: Int, orderPreference: [String: Int] = [:]) {
        self.capacity = max(0, capacity)
        self.slots = []
        self.pending = []
        self.orderPreference = orderPreference
    }

    public var occupiedCount: Int {
        slots.reduce(0) { $0 + ($1.identity == nil ? 0 : 1) }
    }

    public var liveSlots: [SlotID] {
        slots.enumerated().compactMap { offset, content in
            content.identity == nil ? nil : SlotID(index: offset)
        }
    }

    public func identity(at slot: SlotID) -> WindowIdentity? {
        guard slot.index >= 0, slot.index < slots.count else { return nil }
        return slots[slot.index].identity
    }

    public func slot(for identity: WindowIdentity) -> SlotID? {
        guard let index = slots.firstIndex(where: { $0.identity == identity }) else { return nil }
        return SlotID(index: index)
    }

    /// 新窗口填入第一个空 slot；容量不足进入待整理队列。
    @discardableResult
    public mutating func assign(_ identity: WindowIdentity, memoryKey: String) -> SlotID? {
        if let existing = slot(for: identity) { return existing }
        if let vacantIndex = slots.firstIndex(where: { $0.identity == nil }) {
            slots[vacantIndex] = .occupied(identity, memoryKey: memoryKey)
            return SlotID(index: vacantIndex)
        }
        guard slots.count < capacity else {
            if !pending.contains(where: { $0.identity == identity }) {
                pending.append(PendingWindow(identity: identity, memoryKey: memoryKey, applicationName: "", title: ""))
            }
            return nil
        }
        slots.append(.occupied(identity, memoryKey: memoryKey))
        return SlotID(index: slots.count - 1)
    }

    /// 窗口关闭：原位成为占位，后面的窗口不依次前移。
    public mutating func release(_ identity: WindowIdentity) {
        if let index = slots.firstIndex(where: { $0.identity == identity }) {
            slots[index] = .vacant
        }
        pending.removeAll { $0.identity == identity }
    }

    /// 关闭再进入时清理占位，但保留仍存活窗口的相对顺序。
    public mutating func compactVacancies() {
        slots = slots.filter { $0.identity != nil }
    }

    /// 用户按"整理"：清理占位、扩容并放入排队窗口。这是唯一会重排的动作。
    public mutating func organize() {
        compactVacancies()
        capacity = max(capacity, slots.count + pending.count)
        let queued = pending
        pending = []
        for item in queued {
            if assign(item.identity, memoryKey: item.memoryKey) == nil {
                pending.removeAll { $0.identity == item.identity }
                pending.append(item)
            }
        }
        persistOrder()
    }

    /// 用户拖动卡片：交换 slot 并写回顺序偏好。
    public mutating func swap(_ from: SlotID, _ to: SlotID) {
        guard from.index >= 0, to.index >= 0, from.index < slots.count, to.index < slots.count else { return }
        slots.swapAt(from.index, to.index)
        persistOrder()
    }

    public mutating func persistOrder() {
        var map: [String: Int] = [:]
        for (index, content) in slots.enumerated() {
            if case let .occupied(_, memoryKey) = content { map[memoryKey] = index }
        }
        orderPreference = map
    }

    /// 搜索过滤只改变展示，清空后回到原 slot。
    public func displayedSlots(matching isIncluded: (WindowIdentity) -> Bool) -> [SlotID] {
        slots.enumerated().compactMap { offset, content in
            guard let identity = content.identity, isIncluded(identity) else { return nil }
            return SlotID(index: offset)
        }
    }

    /// 初次进入按记忆顺序，否则按应用分组 + 稳定发现顺序。
    public mutating func rebuild(from records: [WindowRecord]) {
        let ordered = records.sorted { lhs, rhs in
            let lRank = orderPreference[lhs.memoryKey] ?? Int.max
            let rRank = orderPreference[rhs.memoryKey] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            if lhs.applicationName != rhs.applicationName { return lhs.applicationName < rhs.applicationName }
            if lhs.identity.processID != rhs.identity.processID { return lhs.identity.processID < rhs.identity.processID }
            return lhs.identity.windowID < rhs.identity.windowID
        }
        slots = []
        pending = []
        for record in ordered.prefix(capacity) {
            slots.append(.occupied(record.identity, memoryKey: record.memoryKey))
        }
        for record in ordered.dropFirst(min(capacity, ordered.count)) {
            pending.append(PendingWindow(identity: record.identity, memoryKey: record.memoryKey,
                                         applicationName: record.applicationName, title: record.title))
        }
        persistOrder()
    }
}
