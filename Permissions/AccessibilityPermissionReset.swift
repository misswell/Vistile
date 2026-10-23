import Foundation

/// Only reset this product's Accessibility decision; never use a global reset.
struct AccessibilityPermissionReset {
    typealias Runner = (URL, [String]) async throws -> Int32
    private let bundleIdentifier: String?
    private let run: Runner

    init(bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         run: @escaping Runner = AccessibilityPermissionReset.runCommand) {
        self.bundleIdentifier = bundleIdentifier
        self.run = run
    }

    func reset() async throws {
        guard bundleIdentifier == "com.misswell.Vistile" else {
            throw ResetError.invalidApplication
        }
        let code = try await run(URL(fileURLWithPath: "/usr/bin/tccutil"),
                                 ["reset", "Accessibility", "com.misswell.Vistile"])
        guard code == 0 else { throw ResetError.commandFailed(code) }
    }

    private static func runCommand(_ executable: URL, arguments: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do { try process.run() }
            catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    enum ResetError: LocalizedError {
        case invalidApplication
        case commandFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidApplication:
                return "无法确认当前应用身份，未清除授权。请从应用程序文件夹打开 Vistile 后重试。"
            case .commandFailed(let code):
                return "系统未能清除辅助功能授权（退出码 \(code)）。请在系统设置中删除 Vistile 条目后重新添加。"
            }
        }
    }
}
