import Foundation

/// 一次捕获运行的独立身份（方案 §7.1）。
/// WindowIdentity 指外部窗口、目录 generation 指一轮发现、总览 sessionID 指一次会话：
/// 同一个窗口关掉再开时三者都可能不同或相同，只有 runID 专门区分"第几次流"。
public struct CaptureRunID: Hashable, Sendable, CustomStringConvertible {
    public let value: UUID

    public init() { value = UUID() }
    public init(_ value: UUID) { self.value = value }

    public var description: String { String(value.uuidString.prefix(8)) }
    public var journalKey: String { value.uuidString }
}

/// 捕获轮次令牌：stopAll 之后旧 run 的完成回调一律作废（方案 §7.3）。
public struct CaptureRoundToken: Hashable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) { self.value = value }

    public func next() -> CaptureRoundToken { CaptureRoundToken(value &+ 1) }
}

public enum CaptureRunPhase: String, Hashable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case stopped
}

/// 单次运行的生命周期裁决（方案 §7.2）。
///
/// 放在核心包是因为这些交错全靠时序决定，而时序只能靠"谁取得停止权"这类纯裁决来固定：
/// 调用方各自记布尔迟早会漏掉 starting→stopping 这条边。
public struct CaptureLifecycle: Hashable, Sendable {
    /// start  awaited 回来后该怎么走。
    public enum StartReturn: Hashable, Sendable {
        /// 正常进入 running。
        case enterRunning
        /// 等待期间收到停止请求：调用方必须停掉刚建好的底层实例，且不进入 running。
        case mustStop
        /// 停止已由别的路径收敛：本次结果只能丢弃。
        case alreadyHandled
    }

    public enum StopOwner: Hashable, Sendable {
        /// 本次调用负责停止底层实例。
        case thisCall
        /// start 仍挂起：由 start 返回后的路径负责，绝不两边都停或都不停。
        case pendingStart
        /// 已经停过或正在停：什么都不做。
        case nobody
    }

    public private(set) var phase: CaptureRunPhase = .idle
    public private(set) var cancellationRequested = false

    public init() {}

    /// 建好底层实例之后、await 启动之前调用。返回 false 表示已被取消，调用方要立刻停掉它。
    public mutating func beginStart() -> Bool {
        guard phase == .idle else { return false }
        if cancellationRequested { return false }
        phase = .starting
        return true
    }

    /// 启动成功返回后的裁决。失败路径自己走 markStopped，不经过这里。
    public mutating func startReturned() -> StartReturn {
        guard phase == .starting else { return .alreadyHandled }
        guard cancellationRequested else {
            phase = .running
            return .enterRunning
        }
        phase = .stopping
        return .mustStop
    }

    /// 请求停止：即便 start 还在等待也立刻标记取消（方案 §7.2 第三条）。
    public mutating func requestStop() -> StopOwner {
        switch phase {
        case .idle:
            cancellationRequested = true
            phase = .stopping
            return .thisCall
        case .starting:
            cancellationRequested = true
            return .pendingStart
        case .running:
            cancellationRequested = true
            phase = .stopping
            return .thisCall
        case .stopping, .stopped:
            return .nobody
        }
    }

    public mutating func markStopped() {
        phase = .stopped
    }

    public var isRunning: Bool { phase == .running }
    public var isSettled: Bool { phase == .stopped }
    /// 还没收敛完：管理表不能把它忘掉，否则可能启动的流就丢了（方案 §7.2 第四条）。
    public var needsReaping: Bool { phase == .idle || phase == .starting || phase == .stopping }
}
