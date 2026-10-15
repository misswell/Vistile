import Foundation

/// 有界帧信箱：只保留最新一帧，新帧替换旧帧，绝不形成待渲染无限队列（方案 §9.3）。
/// 代际不匹配的晚到回调被忽略，因此 stop 之后到达的帧不会污染新会话。
public final class FrameMailbox<Payload: Sendable>: @unchecked Sendable {
    private struct Slot {
        let payload: Payload
        let generation: UInt64
        let at: Date
        let version: UInt64
    }

    private let lock = NSLock()
    private var latest: Slot?
    private var versionCounter: UInt64 = 0
    private var generationCounter: UInt64 = 0

    public private(set) var publishedCount: Int = 0
    public private(set) var replacedCount: Int = 0
    public private(set) var staleCount: Int = 0
    /// 上界固定为 1，测试用来验证不会有第二帧排队。
    public let capacity = 1

    public init() {}

    public var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generationCounter
    }

    /// 停止或重建流时递增代际，旧回调自然失效。
    @discardableResult
    public func advanceGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generationCounter += 1
        latest = nil
        return generationCounter
    }

    @discardableResult
    public func publish(_ payload: Payload, generation: UInt64, at date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == generationCounter else {
            staleCount += 1
            return false
        }
        if latest != nil { replacedCount += 1 }
        versionCounter += 1
        latest = Slot(payload: payload, generation: generation, at: date, version: versionCounter)
        publishedCount += 1
        return true
    }

    /// 渲染器只在版本变化时取帧，静止后不再重绘。
    public func latestIfChanged(aboveVersion: UInt64) -> (payload: Payload, version: UInt64, at: Date)? {
        lock.lock()
        defer { lock.unlock() }
        guard let slot = latest, slot.version > aboveVersion else { return nil }
        return (slot.payload, slot.version, slot.at)
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return latest == nil ? 0 : 1
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        latest = nil
    }

    public var lastPublishedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return latest?.at
    }
}

/// 捕获帧的元数据，坐标单位换算必须显式处理（方案 §9.2）。
public struct CapturedFrameMeta: Hashable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var contentRect: CGRect
    public var scaleFactor: CGFloat
    public var sourceSize: CGSize
    public var isValid: Bool
    public var isIdle: Bool
    public var presentTime: TimeInterval

    public init(pixelWidth: Int,
                pixelHeight: Int,
                contentRect: CGRect,
                scaleFactor: CGFloat,
                sourceSize: CGSize,
                isValid: Bool,
                isIdle: Bool,
                presentTime: TimeInterval) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentRect = contentRect
        self.scaleFactor = scaleFactor
        self.sourceSize = sourceSize
        self.isValid = isValid
        self.isIdle = isIdle
        self.presentTime = presentTime
    }

    /// 只有有效完整帧才允许更新纹理；idle 帧保留最后画面但不算失败。
    public var shouldUpdateTexture: Bool { isValid && !isIdle }
}
