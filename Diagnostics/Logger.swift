import Foundation
import os

/// 诊断日志只写事实，不写标题正文之外的用户内容（方案 §14 隐私边界）。
enum VistileLog {
    static let session = Logger(subsystem: "com.misswell.Vistile", category: "session")
    static let capture = Logger(subsystem: "com.misswell.Vistile", category: "capture")
    static let geometry = Logger(subsystem: "com.misswell.Vistile", category: "geometry")
    static let ui = Logger(subsystem: "com.misswell.Vistile", category: "ui")
}
