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

    /// 管理者在切换运行时同步分配新代次（方案 §7.4）。
    /// 旧 session 只持有自己的令牌，无权在 stop 返回后推进共享代次。
    /// 默认保留最后一帧：最小化或关闭重开期间画面不该凭空变黑。
    @discardableResult
    public func beginRun(clearingFrame: Bool = false) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generationCounter += 1
        if clearingFrame { latest = nil }
        return generationCounter
    }

    /// 已销毁窗口的彻底清理：代次推进 + 丢弃最后画面。
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        generationCounter += 1
        latest = nil
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

/// SCStream 的帧状态。rawValue 顺序与 SDK 头文件里的 SCFrameStatus 一致（方案 §10.1）：
/// complete=0、idle=1、blank=2、suspended=3、started=4、stopped=5。
public enum CapturedFrameStatus: Int, Hashable, Sendable, CaseIterable {
    case complete = 0
    case idle = 1
    case blank = 2
    case suspended = 3
    case started = 4
    case stopped = 5
}

/// 捕获帧的元数据。字段名一律带单位，坐标换算不许在调用点猜（方案 §10.2）。
public struct CapturedFrameMeta: Hashable, Sendable {
    /// 纹理像素尺寸。
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 内容区，单位是点（SCStreamFrameInfo.contentRect 定义为 "in points in surface"）。
    /// 缺元数据时为 nil：零矩形不等于整幅，不能拿它算 UV。
    public var contentRectInPoints: CGRect?
    /// 像素/点倍率，来自 SCStreamFrameInfo.scaleFactor。
    public var pointPixelScale: CGFloat
    /// 原内容到 surface 的倍率，来自 contentScale。它是倍率，不是尺寸（方案 §10.1）。
    public var contentScale: CGFloat?
    /// 源窗口点尺寸：由目录里的真实 frame 给出，绝不从 contentScale 反推。
    public var sourceSizeInPoints: CGSize?
    /// 缺 status 时由调用方标 .started/.complete 之外的值没有意义：这里只允许明确状态。
    public var status: CapturedFrameStatus
    public var isValid: Bool
    public var presentTime: TimeInterval

    public init(pixelWidth: Int,
                pixelHeight: Int,
                contentRectInPoints: CGRect?,
                pointPixelScale: CGFloat,
                contentScale: CGFloat?,
                sourceSizeInPoints: CGSize?,
                status: CapturedFrameStatus,
                isValid: Bool,
                presentTime: TimeInterval) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentRectInPoints = contentRectInPoints
        self.pointPixelScale = pointPixelScale
        self.contentScale = contentScale
        self.sourceSizeInPoints = sourceSizeInPoints
        self.status = status
        self.isValid = isValid
        self.presentTime = presentTime
    }

    /// 只有 complete 才允许刷新纹理（方案 §10.1）。
    public var shouldUpdateTexture: Bool { isValid && status == .complete }

    /// idle/blank/suspended：保留最后一帧，既不算新画面也不算失败。
    public var keepsLastFrame: Bool { status == .idle || status == .blank || status == .suspended }

    /// 点 → 像素：contentRect 与 pixelBuffer 不同单位，必须乘 scaleFactor（方案 §10.2）。
    public var contentRectInPixels: CGRect? {
        guard let rect = contentRectInPoints, rect.width > 0, rect.height > 0,
              pointPixelScale > 0 else { return nil }
        return CGRect(x: rect.minX * pointPixelScale,
                      y: rect.minY * pointPixelScale,
                      width: rect.width * pointPixelScale,
                      height: rect.height * pointPixelScale)
    }

    /// 归一化内容区（0...1）；元数据不完整或与纹理对不上时返回 nil，调用方退回整幅而不是猜。
    public var normalizedContentRect: CGRect? {
        guard let rect = contentRectInPixels, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let texture = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        guard rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= texture.width * 1.02, rect.maxY <= texture.height * 1.02 else { return nil }
        return CGRect(x: rect.minX / texture.width,
                      y: rect.minY / texture.height,
                      width: rect.width / texture.width,
                      height: rect.height / texture.height)
    }
}
