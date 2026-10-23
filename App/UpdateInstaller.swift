import AppKit
import CryptoKit
import Darwin
import Foundation
import VistileCore

struct UpdateInstallProgress: Sendable {
    let message: String
    let fraction: Double?
}

enum UpdateInstallError: LocalizedError {
    case unsupportedAsset
    case invalidDownloadURL
    case missingDigest
    case digestMismatch
    case invalidPackage(String)
    case unsupportedLocation
    case readOnlyVolume
    case installDirectoryNotWritable
    case helper(String)
    case command(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAsset:
            return "此版本没有可识别的 DMG 或 ZIP 安装包。"
        case .invalidDownloadURL:
            return "更新包下载地址无效，请从 Vistile 官方发布页下载。"
        case .missingDigest:
            return "此版本没有提供 SHA-256 校验值，无法安全地直接安装。"
        case .digestMismatch:
            return "更新包 SHA-256 校验失败，当前版本未更改。"
        case let .invalidPackage(message), let .command(message), let .timedOut(message), let .helper(message):
            return message
        case .unsupportedLocation:
            return "应用内更新仅支持安装在“应用程序”文件夹中的 Vistile.app。请先将 Vistile 移入“应用程序”文件夹。"
        case .readOnlyVolume:
            return "当前 Vistile 位于只读磁盘映像或只读卷中，请先将它复制到“应用程序”文件夹。"
        case .installDirectoryNotWritable:
            return "无法写入 Vistile 的安装文件夹。请检查“应用程序”文件夹权限，或手动下载更新。"
        }
    }
}

@MainActor
final class UpdateInstaller: NSObject {
    private(set) var isInstalling = false
    private let fileManager = FileManager.default

    override init() {
        super.init()
        Self.cleanupStaleTemporaryDirectories()
    }

    func install(
        package: UpdatePackage,
        progress: @escaping @MainActor @Sendable (UpdateInstallProgress) -> Void = { _ in }
    ) async throws -> PreparedUpdate {
        guard !isInstalling else { throw CancellationError() }
        isInstalling = true
        defer { isInstalling = false }

        var workspace: URL?
        var stagingContainer: URL?
        var prepared = false
        defer {
            if !prepared {
                if let stagingContainer { try? Self.removeOwnedDirectory(stagingContainer) }
                if let workspace { try? Self.removeOwnedDirectory(workspace) }
            }
        }

        try Task.checkCancellation()
        guard let asset = package.asset,
              asset.name.lowercased().hasSuffix(".dmg") || asset.name.lowercased().hasSuffix(".zip") else {
            throw UpdateInstallError.unsupportedAsset
        }
        guard UpdateInstallerValidation.isTrustedDownloadURL(asset.browserDownloadURL) else {
            throw UpdateInstallError.invalidDownloadURL
        }
        guard let expectedDigest = asset.digest,
              UpdateInstallerValidation.normalizedSHA256(expectedDigest) != nil else {
            throw UpdateInstallError.missingDigest
        }
        guard asset.size > 0, asset.size <= 1_073_741_824 else {
            throw UpdateInstallError.invalidPackage("GitHub 发布记录中的更新包大小无效。")
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard !Self.isSymbolicLink(bundleURL) else {
            throw UpdateInstallError.invalidPackage("当前 Vistile.app 路径是符号链接，无法安全替换。")
        }
        try Self.requireNoSymlinkAncestors(bundleURL)
        let currentApp = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let installParent = try validateInstallLocation(currentApp)
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard Bundle.main.bundleIdentifier == "com.misswell.Vistile",
              let current = AppVersion(currentVersion), package.version > current else {
            throw UpdateInstallError.invalidPackage("更新版本必须高于当前版本，当前安装未更改。")
        }
        guard let releaseVersion = AppVersion(package.release.tagName), releaseVersion == package.version else {
            throw UpdateInstallError.invalidPackage("发布版本与安装包版本不一致。")
        }
        guard let teamIdentifier = try await developerIDTeamIdentifier(for: currentApp) else {
            throw UpdateInstallError.invalidPackage("当前 Vistile 不是有效的 Developer ID 签名版本，无法安全替换。")
        }

        let tempParent = try Self.canonicalTemporaryDirectory()
        let root = tempParent.appendingPathComponent("VistileUpdate-\(UUID().uuidString)", isDirectory: true)
        try Self.createPrivateDirectory(root)
        try Self.requireNoSymlinkAncestors(root)
        workspace = root
        let archiveExtension = asset.name.lowercased().hasSuffix(".dmg") ? "dmg" : "zip"
        let archive = root.appendingPathComponent("package.\(archiveExtension)")
        let request = URLRequest(url: asset.browserDownloadURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        progress(UpdateInstallProgress(message: "正在下载 Vistile \(package.version)…", fraction: 0))
        let downloader = UpdateAssetDownload(destination: archive,
                                             expectedSize: Int64(asset.size),
                                             progress: progress)
        let response = try await withTaskCancellationHandler {
            try await downloader.start(request)
        } onCancel: {
            downloader.cancel()
        }
        try Task.checkCancellation()
        guard let httpResponse = response.0 as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateInstallError.invalidPackage("下载更新失败（HTTP \((response.0 as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        guard let actualSize = try? Self.fileSize(archive), actualSize == Int64(asset.size) else {
            throw UpdateInstallError.invalidPackage("下载文件大小与 GitHub 发布记录不一致。")
        }

        progress(UpdateInstallProgress(message: "正在校验 SHA-256…", fraction: nil))
        let actualDigest = try await Self.sha256(of: archive) { fraction in
            progress(UpdateInstallProgress(message: "正在校验 SHA-256…", fraction: fraction))
        }
        guard UpdateInstallerValidation.matchesSHA256(expected: expectedDigest, actual: actualDigest) else {
            throw UpdateInstallError.digestMismatch
        }
        try Task.checkCancellation()

        let extraction = root.appendingPathComponent("extracted", isDirectory: true)
        try Self.createPrivateDirectory(extraction)
        let extractedApp: URL
        if archiveExtension == "dmg" {
            progress(UpdateInstallProgress(message: "正在只读挂载并检查安装包…", fraction: nil))
            extractedApp = try await extractDMG(archive, into: extraction, workspace: root)
        } else {
            progress(UpdateInstallProgress(message: "正在解压更新…", fraction: nil))
            let result = try await Self.runTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, extraction.path], timeout: 120)
            guard result.status == 0 else { throw UpdateInstallError.command("解压更新失败：\(result.output)") }
            extractedApp = try Self.findVistileApp(in: extraction)
        }
        try Task.checkCancellation()

        progress(UpdateInstallProgress(message: "正在验证版本、签名和公证…", fraction: nil))
        _ = try await validateUpdatedApp(extractedApp, version: package.version, teamIdentifier: teamIdentifier)

        let stageContainer = installParent.appendingPathComponent(".Vistile-Update-\(UUID().uuidString)", isDirectory: true)
        try Self.createPrivateDirectory(stageContainer)
        stagingContainer = stageContainer
        let stagedApp = stageContainer.appendingPathComponent("Vistile.app", isDirectory: true)
        progress(UpdateInstallProgress(message: "正在准备替换文件…", fraction: nil))
        let copied = try await Self.runTool("/usr/bin/ditto", arguments: ["--rsrc", "--extattr", extractedApp.path, stagedApp.path], timeout: 120)
        guard copied.status == 0 else { throw UpdateInstallError.command("无法在安装磁盘上暂存新版本：\(copied.output)") }
        try Self.requireRealDirectory(stagedApp, ownedByCurrentUser: true)
        let stagedVersion = try await validateUpdatedApp(stagedApp, version: package.version, teamIdentifier: teamIdentifier)
        try Task.checkCancellation()

        let supportDirectory = try Self.prepareSupportDirectory()
        let backupApp = installParent.appendingPathComponent(".Vistile.app.backup-\(UUID().uuidString)", isDirectory: true)
        let helper = root.appendingPathComponent("replace-vistile.sh")
        try Self.writeHelper(to: helper)
        let handoff = PreparedUpdate.Handoff(currentApp: currentApp,
                                             stagedApp: stagedApp,
                                             backupApp: backupApp,
                                             stagingContainer: stageContainer,
                                             workspace: root,
                                             temporaryParent: tempParent,
                                             supportDirectory: supportDirectory,
                                             teamIdentifier: teamIdentifier,
                                             version: stagedVersion,
                                             bundleIdentifier: "com.misswell.Vistile",
                                             executableName: Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Vistile")
        prepared = true
        progress(UpdateInstallProgress(message: "更新包已验证并准备就绪。", fraction: 1))
        return PreparedUpdate(handoff: handoff)
    }

    /// 在下次启动时读取并消费 helper 的替换失败说明。
    static func consumePendingFailure() -> String? {
        let url = supportDirectoryURL().appendingPathComponent("update-result.txt")
        guard !Self.isSymbolicLink(url),
              let data = try? Data(contentsOf: url), data.count <= 16_384,
              let text = String(data: data, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard text.hasPrefix("failure\n") else { return nil }
        let detail = text.dropFirst("failure\n".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "更新未完成，已恢复旧版本。" : detail
    }

    /// 清理异常退出留下的私有暂存目录；只清理本应用命名空间内超过一天的目录。
    static func cleanupStaleTemporaryDirectories() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        if let tempParent = try? Self.canonicalTemporaryDirectory() {
            removeStaleDirectories(in: tempParent, prefix: "VistileUpdate-", olderThan: cutoff)
        }
        for parent in supportedInstallParents() {
            removeStaleDirectories(in: parent, prefix: ".Vistile-Update-", olderThan: cutoff)
        }
    }

    private func validateInstallLocation(_ app: URL) throws -> URL {
        guard UpdateInstallerValidation.isSupportedInstallLocation(app.path, homeDirectory: NSHomeDirectory()) else {
            let volume = Self.isReadOnlyVolume(app.deletingLastPathComponent())
            throw volume ? UpdateInstallError.readOnlyVolume : UpdateInstallError.unsupportedLocation
        }
        try Self.requireRealDirectory(app, ownedByCurrentUser: false)
        try Self.requireNoSymlinkAncestors(app.deletingLastPathComponent())
        guard !Self.isReadOnlyVolume(app.deletingLastPathComponent()) else { throw UpdateInstallError.readOnlyVolume }
        let parent = app.deletingLastPathComponent()
        let probe = parent.appendingPathComponent(".Vistile-Write-\(UUID().uuidString)")
        do {
            try Self.createPrivateDirectory(probe)
            try Self.removeOwnedDirectory(probe)
        } catch {
            try? Self.removeOwnedDirectory(probe)
            throw UpdateInstallError.installDirectoryNotWritable
        }
        return parent
    }

    private func extractDMG(_ image: URL, into extraction: URL, workspace: URL) async throws -> URL {
        let mountPoint = workspace.appendingPathComponent("mounted", isDirectory: true)
        try Self.createPrivateDirectory(mountPoint)
        do {
            let attach = try await Self.runTool("/usr/bin/hdiutil",
                                              arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-quiet", "-mountpoint", mountPoint.path, image.path],
                                              timeout: 60)
            guard attach.status == 0 else { throw UpdateInstallError.invalidPackage("无法只读挂载 DMG：\(attach.output)") }
            let sourceApp = try Self.findVistileApp(in: mountPoint, requiresOwnership: false)
            let copiedApp = extraction.appendingPathComponent("Vistile.app", isDirectory: true)
            let copy = try await Self.runTool("/usr/bin/ditto", arguments: ["--rsrc", "--extattr", sourceApp.path, copiedApp.path], timeout: 120)
            guard copy.status == 0 else { throw UpdateInstallError.invalidPackage("无法从 DMG 复制 Vistile.app：\(copy.output)") }
            let detach = try await Self.runTool("/usr/bin/hdiutil", arguments: ["detach", "-quiet", mountPoint.path], timeout: 30)
            guard detach.status == 0 else { throw UpdateInstallError.command("DMG 已复制，但无法安全卸载：\(detach.output)") }
            return copiedApp
        } catch {
            // Cleanup must also run after the caller cancels while hdiutil is attaching/copying.
            let cleanup = Task { @MainActor in
                try await Self.runTool("/usr/bin/hdiutil", arguments: ["detach", "-quiet", mountPoint.path], timeout: 30)
            }
            _ = try? await cleanup.value
            throw error
        }
    }

    private func validateUpdatedApp(_ app: URL, version: AppVersion, teamIdentifier: String) async throws -> String {
        try Self.requireNoSymlinkAncestors(app)
        try Self.requireRealDirectory(app, ownedByCurrentUser: false)
        let temporaryRoot = try Self.canonicalTemporaryDirectory()
        guard Self.isDescendant(app, of: temporaryRoot) ||
                Self.isDescendant(app, of: URL(fileURLWithPath: "/Applications", isDirectory: true)) ||
                Self.isDescendant(app, of: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true)) else {
            throw UpdateInstallError.invalidPackage("更新 App 位于预期暂存目录之外。")
        }
        guard let bundle = Bundle(url: app),
              let actualVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              UpdateInstallerValidation.matchesBundle(bundleIdentifier: bundle.bundleIdentifier,
                                                      version: actualVersion,
                                                      expectedIdentifier: "com.misswell.Vistile",
                                                      expectedVersion: version.description),
              let executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String else {
            throw UpdateInstallError.invalidPackage("更新包中的 Bundle ID 或版本与发布记录不一致。")
        }
        let executable = app.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path), !Self.isSymbolicLink(executable) else {
            throw UpdateInstallError.invalidPackage("更新包中的 Vistile 可执行文件缺失或无效。")
        }
        let signature = try await Self.codeSignature(for: app)
        guard signature.teamIdentifier == teamIdentifier, signature.isDeveloperID else {
            throw UpdateInstallError.invalidPackage("更新 App 的 Developer ID 团队签名与当前版本不一致。")
        }
        let gatekeeper = try await Self.runTool("/usr/sbin/spctl", arguments: ["--assess", "--type", "execute", "--verbose=2", app.path], timeout: 30)
        guard gatekeeper.status == 0 else {
            throw UpdateInstallError.invalidPackage("Gatekeeper 未接受更新 App：\(gatekeeper.output)")
        }
        return actualVersion
    }

    private func developerIDTeamIdentifier(for app: URL) async throws -> String? {
        let signature = try await Self.codeSignature(for: app)
        return signature.isDeveloperID ? signature.teamIdentifier : nil
    }

    private static func codeSignature(for app: URL) async throws -> (teamIdentifier: String, isDeveloperID: Bool) {
        let verification = try await runTool("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path], timeout: 30)
        guard verification.status == 0 else {
            throw UpdateInstallError.invalidPackage("Developer ID 签名验证失败：\(verification.output)")
        }
        let result = try await runTool("/usr/bin/codesign", arguments: ["--display", "--verbose=4", app.path], timeout: 30)
        guard result.status == 0 else { throw UpdateInstallError.invalidPackage("无法读取 App 签名：\(result.output)") }
        let lines = result.output.split(whereSeparator: \.isNewline).map(String.init)
        let team = lines.first(where: { $0.hasPrefix("TeamIdentifier=") })?.dropFirst("TeamIdentifier=".count).description ?? ""
        let developerID = lines.contains(where: { $0.hasPrefix("Authority=Developer ID Application:") })
        guard !team.isEmpty, team != "not set" else { throw UpdateInstallError.invalidPackage("App 未包含有效的签名团队标识。") }
        return (team, developerID)
    }

    private static func sha256(of url: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        let task = Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let total = try fileSize(url)
            var read: Int64 = 0
            var hasher = SHA256()
            while true {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                read += Int64(chunk.count)
                await progress(total > 0 ? min(1, Double(read) / Double(total)) : 0)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw UpdateInstallError.invalidPackage("无法读取下载文件大小。") }
        return size.int64Value
    }

    private static func findVistileApp(in directory: URL, requiresOwnership: Bool = true) throws -> URL {
        try requireRealDirectory(directory, ownedByCurrentUser: requiresOwnership)
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                             includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                             options: [.skipsHiddenFiles]) else {
            throw UpdateInstallError.invalidPackage("无法读取更新包内容。")
        }
        var matches: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent == "Vistile.app" {
                matches.append(item)
                enumerator.skipDescendants()
            } else if item.pathExtension.lowercased() == "app" {
                enumerator.skipDescendants()
            }
        }
        guard matches.count == 1, let app = matches.first,
              isDescendant(app, of: directory), !isSymbolicLink(app) else {
            throw UpdateInstallError.invalidPackage("安装包必须且只能包含一个真实的 Vistile.app。")
        }
        try requireNoSymlinkAncestors(app)
        try requireRealDirectory(app, ownedByCurrentUser: false)
        return app
    }

    private static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try requireRealDirectory(url, ownedByCurrentUser: true)
    }

    nonisolated fileprivate static func requireRealDirectory(_ url: URL, ownedByCurrentUser: Bool) throws {
        guard !isSymbolicLink(url) else { throw UpdateInstallError.invalidPackage("检测到意外的符号链接：\(url.lastPathComponent)") }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw UpdateInstallError.invalidPackage("目录不存在或类型无效：\(url.lastPathComponent)")
        }
        if ownedByCurrentUser, info.st_uid != uid_t(getuid()) {
            throw UpdateInstallError.invalidPackage("暂存目录不属于当前用户。")
        }
    }

    nonisolated static func canonicalTemporaryDirectory() throws -> URL {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL
        let resolvedPath = temporaryDirectory.path.withCString { Darwin.realpath($0, nil) }
        guard let resolvedPath else {
            throw UpdateInstallError.invalidPackage("无法解析系统临时目录。")
        }
        defer { Darwin.free(resolvedPath) }
        let canonical = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        try requireRealDirectory(canonical, ownedByCurrentUser: false)
        try requireNoSymlinkAncestors(canonical)
        return canonical
    }

    nonisolated static func requireNoSymlinkAncestors(_ url: URL) throws {
        let standardizedPath = lexicallyStandardizedPath(url.path)
        var currentPath = ""
        for component in standardizedPath.split(separator: "/") {
            currentPath += "/\(component)"
            let current = URL(fileURLWithPath: currentPath, isDirectory: true)
            guard !isSymbolicLink(current) else { throw UpdateInstallError.invalidPackage("安装路径包含符号链接。") }
        }
    }

    private nonisolated static func lexicallyStandardizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return "/" + components.joined(separator: "/")
    }

    nonisolated fileprivate static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK)
    }

    private static func isReadOnlyVolume(_ url: URL) -> Bool {
        var info = statfs()
        let result = url.path.withCString { statfs($0, &info) }
        return result != 0 || (info.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = lexicallyStandardizedPath(root.path)
        let candidatePath = lexicallyStandardizedPath(candidate.path)
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    nonisolated fileprivate static func removeOwnedDirectory(_ url: URL) throws {
        guard !isSymbolicLink(url) else { throw UpdateInstallError.invalidPackage("拒绝清理符号链接暂存目录。") }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == uid_t(getuid()) else {
            throw UpdateInstallError.invalidPackage("拒绝清理非本用户拥有的暂存目录。")
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func removeStaleDirectories(in parent: URL, prefix: String, olderThan cutoff: Date) {
        guard !isSymbolicLink(parent),
              let children = try? FileManager.default.contentsOfDirectory(at: parent,
                                                                          includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                                          options: []) else { return }
        for child in children where child.lastPathComponent.hasPrefix(prefix) && !isSymbolicLink(child) {
            var info = stat()
            guard lstat(child.path, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  info.st_uid == uid_t(getuid()),
                  let values = try? child.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate, date < cutoff else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private static func prepareSupportDirectory() throws -> URL {
        let directory = supportDirectoryURL()
        try requireNoSymlinkAncestors(directory)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        try requireRealDirectory(directory, ownedByCurrentUser: true)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        for name in ["update-result.txt", "update-installer.log"] {
            guard !isSymbolicLink(directory.appendingPathComponent(name)) else {
                throw UpdateInstallError.helper("更新状态文件包含符号链接。")
            }
        }
        return directory
    }

    private static func supportDirectoryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Vistile", isDirectory: true)
            .standardizedFileURL
    }

    private static func supportedInstallParents() -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications", isDirectory: true)]
    }

    private static func writeHelper(to url: URL) throws {
        try Data(replacementHelper.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private static let replacementHelper = #"""
    #!/bin/sh
    set -u
    umask 077
    if [ "$#" -ne 13 ]; then exit 64; fi
    current_app=$1
    staged_app=$2
    backup_app=$3
    old_pid=$4
    workspace_root=$5
    temporary_parent=$6
    stage_container=$7
    expected_team=$8
    expected_version=$9
    expected_bundle=${10}
    executable_name=${11}
    result_file=${12}
    log_file=${13}
    current_parent=${current_app%/*}
    result_parent=${result_file%/*}
    log_parent=${log_file%/*}
    expected_binary="$current_app/Contents/MacOS/$executable_name"
    result_written=0
    backup_moved=0
    failed_app="$current_parent/.Vistile.failed-$$"
    existing_pids="|"

    log() {
        /bin/echo "[$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')] $*" >> "$log_file" 2>/dev/null || true
    }
    write_failure() {
        [ "$result_parent" = "$log_parent" ] && [ -d "$result_parent" ] && [ ! -L "$result_parent" ] || return 1
        [ ! -L "$result_file" ] && [ ! -L "$log_file" ] || return 1
        temporary_result="$result_file.tmp.$$"
        /usr/bin/printf 'failure\n%s\n诊断日志：%s\n' "$1" "$log_file" > "$temporary_result" 2>/dev/null || return 1
        /bin/chmod 600 "$temporary_result" 2>/dev/null || true
        /bin/mv -f "$temporary_result" "$result_file" 2>/dev/null || return 1
        result_written=1
    }
    cleanup() {
        if [ -d "$stage_container" ] && [ ! -L "$stage_container" ]; then /bin/rm -rf "$stage_container" >> "$log_file" 2>&1 || log "无法清理安装暂存目录：$stage_container"; fi
        if [ -d "$workspace_root" ] && [ ! -L "$workspace_root" ]; then /bin/rm -rf "$workspace_root" >> "$log_file" 2>&1 || log "无法清理更新临时目录：$workspace_root"; fi
    }
    pid_runs_app() {
        candidate_command=$(/bin/ps -p "$1" -o command= 2>/dev/null || true)
        case "$candidate_command" in "$expected_binary"|"$expected_binary "*) return 0 ;; *) return 1 ;; esac
    }
    find_new_pid() {
        for candidate in $(/usr/bin/pgrep -x "$executable_name" 2>/dev/null || true); do
            case "$existing_pids" in *"|$candidate|"*) continue ;; esac
            [ "$candidate" != "$old_pid" ] || continue
            if pid_runs_app "$candidate"; then /bin/echo "$candidate"; return 0; fi
        done
        return 1
    }
    verify_app() {
        candidate=$1
        [ -d "$candidate" ] && [ ! -L "$candidate" ] || return 1
        actual_bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate/Contents/Info.plist" 2>/dev/null || true)
        actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$candidate/Contents/Info.plist" 2>/dev/null || true)
        [ "$actual_bundle" = "$expected_bundle" ] && [ "$actual_version" = "$expected_version" ] || return 1
        /usr/bin/codesign --verify --deep --strict "$candidate" >> "$log_file" 2>&1 || return 1
        signature=$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1 || true)
        actual_team=$(printf '%s\n' "$signature" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)
        authority=$(printf '%s\n' "$signature" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -n 1)
        [ "$actual_team" = "$expected_team" ] || return 1
        case "$authority" in "Developer ID Application:"*) ;; *) return 1 ;; esac
        /usr/sbin/spctl --assess --type execute --verbose=2 "$candidate" >> "$log_file" 2>&1
    }
    rollback() {
        [ -d "$backup_app" ] || return 0
        log "正在恢复旧版本。"
        if [ -e "$current_app" ] || [ -L "$current_app" ]; then
            /bin/mv "$current_app" "$failed_app" || { log "无法移走失败版本；旧版本备份保留在 $backup_app"; return 1; }
        fi
        if /bin/mv "$backup_app" "$current_app"; then
            backup_moved=0
            [ -e "$failed_app" ] && /bin/rm -rf "$failed_app"
            /usr/bin/open -n "$current_app" >> "$log_file" 2>&1 || log "已恢复旧版本，但重新打开命令失败。"
            log "旧版本已恢复。"
            return 0
        fi
        log "恢复失败；旧版本仍保留在 $backup_app。"
        return 1
    }
    fail_update() {
        reason=$1
        log "更新失败：$reason"
        if [ "$backup_moved" -eq 1 ]; then
            rollback || reason="$reason 自动回滚未完成，旧版本保留在 $backup_app。"
        fi
        write_failure "$reason" || log "无法写入失败结果文件：$result_file"
        exit 1
    }
    on_exit() {
        exit_code=$?
        if [ "$exit_code" -ne 0 ] && [ "$result_written" -eq 0 ]; then
            [ "$backup_moved" -eq 1 ] && rollback || true
            write_failure "更新 helper 异常退出（代码 $exit_code）。" || true
        fi
        cleanup
    }
    trap on_exit EXIT

    case "$old_pid" in ''|*[!0-9]*) fail_update "旧 App 进程标识无效。" ;; esac
    case "$workspace_root" in "$temporary_parent"/VistileUpdate-*) ;; *) fail_update "拒绝使用预期目录之外的暂存路径。" ;; esac
    [ "${workspace_root%/*}" = "$temporary_parent" ] || fail_update "更新临时目录层级无效。"
    case "$stage_container" in "$current_parent"/.Vistile-Update-*) ;; *) fail_update "拒绝使用预期目录之外的安装暂存路径。" ;; esac
    [ "${stage_container%/*}" = "$current_parent" ] || fail_update "安装暂存目录层级无效。"
    [ "$staged_app" = "$stage_container/Vistile.app" ] || fail_update "安装暂存 App 路径无效。"
    case "$backup_app" in "$current_parent"/.Vistile.app.backup-*) ;; *) fail_update "备份路径无效。" ;; esac
    [ "$current_app" = "/Applications/Vistile.app" ] || [ "$current_app" = "$HOME/Applications/Vistile.app" ] || fail_update "应用不在受支持的安装位置。"
    [ "$result_parent" = "$log_parent" ] && [ -d "$result_parent" ] && [ ! -L "$result_parent" ] || fail_update "更新诊断目录无效。"
    [ ! -L "$result_file" ] && [ ! -L "$log_file" ] || fail_update "更新诊断文件包含符号链接。"
    [ ! -L "$current_app" ] && [ ! -L "$staged_app" ] && [ ! -L "$stage_container" ] && [ ! -L "$workspace_root" ] || fail_update "检测到符号链接，已停止替换。"
    [ -d "$current_app" ] && [ -d "$staged_app" ] && [ -d "$stage_container" ] && [ -d "$workspace_root" ] || fail_update "安装文件或暂存目录不存在。"
    [ ! -e "$backup_app" ] && [ ! -L "$backup_app" ] || fail_update "备份目录已存在，已停止替换以保护旧版本。"
    /usr/bin/stat -f '%d' "$current_parent" > /dev/null 2>&1 || fail_update "无法检查安装磁盘。"
    verify_app "$staged_app" || fail_update "暂存 App 的版本、签名或 Gatekeeper 检查失败。"
    log "安装包及签名验证通过，等待 Vistile 正常退出。"
    wait_count=0
    while pid_runs_app "$old_pid"; do
        [ "$wait_count" -lt 480 ] || fail_update "Vistile 未能在 120 秒内正常退出。"
        /bin/sleep 0.25
        wait_count=$((wait_count + 1))
    done
    log "旧 App 进程已正常退出或原 PID 已不再属于 Vistile。"
    /bin/mv "$current_app" "$backup_app" || fail_update "无法备份旧版本，安装目录权限不足。"
    backup_moved=1
    /bin/mv "$staged_app" "$current_app" || fail_update "无法将新版本移动到安装位置。"
    log "已原子替换 App，检查最终安装副本。"
    verify_app "$current_app" || fail_update "最终安装副本的签名或 Gatekeeper 检查失败。"
    for candidate in $(/usr/bin/pgrep -x "$executable_name" 2>/dev/null || true); do
        if pid_runs_app "$candidate"; then existing_pids="${existing_pids}${candidate}|"; fi
    done
    log "启动前已记录现存 Vistile 进程：$existing_pids"
    /usr/bin/open -n "$current_app" >> "$log_file" 2>&1 || fail_update "系统未能打开新版本。"
    new_pid=""
    launch_count=0
    while [ "$launch_count" -lt 40 ]; do
        new_pid=$(find_new_pid || true)
        [ -n "$new_pid" ] && break
        /bin/sleep 0.5
        launch_count=$((launch_count + 1))
    done
    [ -n "$new_pid" ] || fail_update "新版本未能在 20 秒内启动。"
    log "新版本进程已启动（PID=$new_pid），继续观察 8 秒。"
    /bin/sleep 8
    pid_runs_app "$new_pid" || fail_update "新版本进程启动后很快退出，已回滚。"
    log "新版本持续运行，删除旧版本备份。"
    /bin/rm -rf "$backup_app" || log "无法删除旧版本备份：$backup_app"
    backup_moved=0
    [ ! -L "$result_file" ] && /bin/rm -f "$result_file"
    log "更新成功。"
    exit 0
    """#

    private static func runTool(_ path: String, arguments: [String], timeout: TimeInterval) async throws -> ToolResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do { try process.run() }
            catch { throw UpdateInstallError.command("无法启动系统工具 \(URL(fileURLWithPath: path).lastPathComponent)：\(error.localizedDescription)") }
            if Task.isCancelled, process.isRunning { process.terminate() }
            let outputReader = Task.detached(priority: .utility) {
                pipe.fileHandleForReading.readDataToEndOfFile()
            }
            let waiter = Task.detached(priority: .utility) {
                process.waitUntilExit()
                return process.terminationStatus
            }
            let watchdog = Task.detached(priority: .utility) { () -> Bool in
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                catch { return false }
                guard process.isRunning else { return false }
                process.terminate()
                return true
            }
            let status = await waiter.value
            watchdog.cancel()
            let timedOut = await watchdog.value
            let data = await outputReader.value
            try Task.checkCancellation()
            if timedOut {
                throw UpdateInstallError.timedOut("系统工具执行超时：\(URL(fileURLWithPath: path).lastPathComponent)。")
            }
            return ToolResult(status: status,
                              output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private struct ToolResult {
        let status: Int32
        let output: String
    }
}

final class PreparedUpdate: @unchecked Sendable {
    fileprivate struct Handoff {
        let currentApp: URL
        let stagedApp: URL
        let backupApp: URL
        let stagingContainer: URL
        let workspace: URL
        let temporaryParent: URL
        let supportDirectory: URL
        let teamIdentifier: String
        let version: String
        let bundleIdentifier: String
        let executableName: String
    }

    private let handoff: Handoff
    private let lock = NSLock()
    private var didLaunchHelper = false
    private var didCleanup = false

    fileprivate init(handoff: Handoff) { self.handoff = handoff }

    func launchAndRelaunch() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didLaunchHelper, !didCleanup else {
            throw UpdateInstallError.helper("此更新包已启动替换，或暂存文件已经清理。")
        }
        let script = handoff.workspace.appendingPathComponent("replace-vistile.sh")
        try UpdateInstaller.requireRealDirectory(handoff.workspace, ownedByCurrentUser: true)
        guard !UpdateInstaller.isSymbolicLink(script), !UpdateInstaller.isSymbolicLink(handoff.stagedApp) else {
            throw UpdateInstallError.helper("更新 helper 或暂存 App 路径包含符号链接。")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/sh", script.path,
                             handoff.currentApp.path, handoff.stagedApp.path, handoff.backupApp.path,
                             String(ProcessInfo.processInfo.processIdentifier), handoff.workspace.path,
                             handoff.temporaryParent.path, handoff.stagingContainer.path,
                             handoff.teamIdentifier, handoff.version, handoff.bundleIdentifier,
                             handoff.executableName,
                             handoff.supportDirectory.appendingPathComponent("update-result.txt").path,
                             handoff.supportDirectory.appendingPathComponent("update-installer.log").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw UpdateInstallError.helper("无法启动本地替换程序：\(error.localizedDescription)") }
        didLaunchHelper = true
    }

    func cleanup() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didLaunchHelper, !didCleanup else { return }
        try UpdateInstaller.removeOwnedDirectory(handoff.stagingContainer)
        try UpdateInstaller.removeOwnedDirectory(handoff.workspace)
        didCleanup = true
    }

    deinit { try? cleanup() }
}

enum UpdateInstallerValidation {
    static func normalizedSHA256(_ digest: String) -> String? {
        let value = digest.lowercased().hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
        let normalized = value.lowercased()
        guard normalized.count == 64, normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        return normalized
    }

    static func matchesSHA256(expected: String, actual: String) -> Bool {
        guard let normalized = normalizedSHA256(expected) else { return false }
        return normalized.caseInsensitiveCompare(actual) == .orderedSame
    }

    static func matchesBundle(bundleIdentifier: String?, version: String?, expectedIdentifier: String, expectedVersion: String) -> Bool {
        guard bundleIdentifier == expectedIdentifier,
              let version,
              let actual = AppVersion(version),
              let expected = AppVersion(expectedVersion) else { return false }
        return actual == expected
    }

    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }

    static func isSupportedInstallLocation(_ path: String, homeDirectory: String) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized == "/Applications/Vistile.app" || standardized == URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent("Applications/Vistile.app").standardizedFileURL.path
    }
}

private final class UpdateAssetDownload: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let destination: URL
    private let expectedSize: Int64
    private let progress: @MainActor @Sendable (UpdateInstallProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URLResponse, URL), Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancellationRequested = false

    init(destination: URL, expectedSize: Int64, progress: @escaping @MainActor @Sendable (UpdateInstallProgress) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func start(_ request: URLRequest) async throws -> (URLResponse, URL) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.downloadTask(with: request)
            self.session = session
            self.task = task
            let cancelled = cancellationRequested
            lock.unlock()
            if cancelled { task.cancel() } else { task.resume() }
        }
    }

    func cancel() {
        lock.lock()
        cancellationRequested = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "") else {
            completionHandler(nil)
            finish(.failure(UpdateInstallError.invalidDownloadURL))
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedSize
        let fraction = total > 0 ? min(1, Double(totalBytesWritten) / Double(total)) : nil
        Task { @MainActor [progress] in
            progress(UpdateInstallProgress(message: "正在下载 Vistile…", fraction: fraction))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response,
              let finalURL = response.url,
              UpdateInstallerValidation.isTrustedDownloadURL(finalURL) ||
                (["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(finalURL.host?.lowercased() ?? "") && finalURL.scheme?.lowercased() == "https") else {
            finish(.failure(UpdateInstallError.invalidDownloadURL))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success((response, destination)))
        } catch {
            finish(.failure(UpdateInstallError.command("无法保存下载的更新包：\(error.localizedDescription)")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
        else { finish(.failure(UpdateInstallError.command("下载更新失败：\(error.localizedDescription)"))) }
    }

    private func finish(_ result: Result<(URLResponse, URL), Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        continuation.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
