import AppKit
import Foundation
import Darwin

/// 进程启动标识：用于识别 PID 复用（P0-6）。
///
/// `proc_bsdinfo` 公开字段中只有启动时间，没有 puid，因此使用
/// `pbi_start_tvsec * 1e6 + pbi_start_tvusec` 作为微秒级启动标识；
/// 读取失败时退到 `NSRunningApplication.launchDate`。
enum ProcessIdentityReader {
    private static let cacheLock = NSLock()
    private static var cache: [Int32: UInt64] = [:]

    static func startIdentity(for pid: Int32) -> UInt64 {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[pid] { return cached }
        let value = read(pid)
        cache[pid] = value
        return value
    }

    /// 进程退出或身份变化后必须丢弃缓存，否则复用的 PID 会带着旧启动标识。
    static func invalidate(_ pid: Int32) {
        cacheLock.lock()
        cache.removeValue(forKey: pid)
        cacheLock.unlock()
    }

    static func invalidateAll() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    private static func read(_ pid: Int32) -> UInt64 {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 1, pointer, size)
        }
        if read == size, info.pbi_pid == UInt32(pid) {
            let microseconds = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
            if microseconds > 0 { return microseconds }
        }
        if let application = NSRunningApplication(processIdentifier: pid),
           let launchDate = application.launchDate {
            let microseconds = UInt64(max(0, launchDate.timeIntervalSince1970) * 1_000_000)
            if microseconds > 0 { return microseconds }
        }
        // 完全读不到时返回 0：身份仍然唯一到 PID 粒度，但会保守限制几何控制。
        return 0
    }
}
