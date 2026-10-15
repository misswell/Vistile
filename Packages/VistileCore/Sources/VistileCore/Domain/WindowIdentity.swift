import Foundation

/// 会话内窗口身份。标题只是展示信息，绝不作为主键。
/// 进程重启后 CGWindowID 会被复用，因此身份必须绑定进程启动标识（P0-6）。
public struct WindowIdentity: Hashable, Sendable, CustomStringConvertible, Codable {
    public let processID: Int32
    public let processStartIdentity: UInt64
    public let windowID: UInt32

    public init(processID: Int32, processStartIdentity: UInt64, windowID: UInt32) {
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        self.windowID = windowID
    }

    public func sameProcess(_ other: WindowIdentity) -> Bool {
        processID == other.processID && processStartIdentity == other.processStartIdentity
    }

    public func sameProcess(_ other: ProcessIdentity) -> Bool {
        processID == other.processID && processStartIdentity == other.processStartIdentity
    }

    public var description: String {
        "pid \(processID)/puid \(processStartIdentity)/win \(windowID)"
    }

    /// 日志与事务表使用的稳定键。
    public var journalKey: String {
        "\(processID):\(processStartIdentity):\(windowID)"
    }
}

/// 进程身份：PID 会被回收复用，必须配合启动标识。
public struct ProcessIdentity: Hashable, Sendable, Codable {
    public let processID: Int32
    public let processStartIdentity: UInt64
    public let bundleID: String?
    public let displayName: String

    public init(processID: Int32, processStartIdentity: UInt64, bundleID: String?, displayName: String) {
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        self.bundleID = bundleID
        self.displayName = displayName
    }

    public func isSameProcess(_ other: ProcessIdentity) -> Bool {
        processID == other.processID && processStartIdentity == other.processStartIdentity
    }
}
