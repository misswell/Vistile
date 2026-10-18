// 每秒一份"屏幕上前到后的窗口顺序 + 会话 journal 原文"，供 §20/§22 的原始证据留档。
// 与探针内 P0-17 的统查不同：这个进程在应用之外，不参与任何写入，也不改任何窗口。
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
let interval = arguments.count > 1 ? (Double(arguments[1]) ?? 1.0) : 1.0
let limit = arguments.count > 2 ? (Double(arguments[2]) ?? .infinity) : .infinity
let journalURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Vistile/session-journal.json")

var running = true
let stop: (Int32) -> Void = { _ in running = false }
signal(SIGINT, stop)
signal(SIGTERM, stop)

let start = Date()
print("===BEGIN snapshot_loop interval=\(interval)s journal=\(journalURL.path)")
fflush(stdout)
while running {
    let elapsed = Date().timeIntervalSince(start)
    if elapsed > limit { break }
    let front = NSWorkspace.shared.frontmostApplication
    print("===T+\(String(format: "%.1f", elapsed)) \(Int(Date().timeIntervalSince1970)) "
        + "front=\(front?.localizedName ?? "?")[\(front?.processIdentifier ?? -1)]")
    // optionOnScreenOnly 的数组顺序就是窗口服务器当前的前到后顺序，探针与报告里的对照都以它为准。
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]]) ?? []
    for (index, window) in windows.enumerated() {
        let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
        // 标题取自 kCGWindowName。这个进程没有屏幕录制授权时非本进程窗口会回空字符串——
        // 那是取证环境的缺口，必须照实留着，不能填占位文字。
        let title = window[kCGWindowName as String] as? String ?? ""
        let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let x = Int((bounds["X"] as? NSNumber)?.doubleValue ?? 0)
        let y = Int((bounds["Y"] as? NSNumber)?.doubleValue ?? 0)
        let width = Int((bounds["Width"] as? NSNumber)?.doubleValue ?? 0)
        let height = Int((bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
        print("  #\(index) \(owner) [\(title)] @\(x),\(y) \(width)x\(height)")
    }
    let journal = (try? String(contentsOf: journalURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "MISSING"
    print("  JOURNAL \(journal)")
    fflush(stdout)
    Thread.sleep(forTimeInterval: interval)
}
print("===END snapshot_loop")
fflush(stdout)
