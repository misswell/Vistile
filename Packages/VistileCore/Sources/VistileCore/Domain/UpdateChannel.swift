import Foundation

/// 版本号：只比较数字段，忽略 `v` 前缀与预发布后缀（方案 §21「GitHub Releases 更新通道」）。
/// 段数不同时缺位按 0 处理（0.1.9 < 0.1.10；1.0 == 1.0.0）。
public struct AppVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let segments: [Int]

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        // 预发布标记之后的部分不参与排序（0.2.0-beta 与 0.2.0 视为同一版本）。
        if let cut = trimmed.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            trimmed = String(trimmed[..<cut])
        }
        let parts = trimmed.split(separator: ".")
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        // 去掉尾部 0，让 1.0 与 1.0.0 相等。
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        segments = numbers
    }

    public var description: String { segments.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.segments.count, rhs.segments.count)
        for index in 0..<count {
            let left = index < lhs.segments.count ? lhs.segments[index] : 0
            let right = index < rhs.segments.count ? rhs.segments[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// GitHub Releases 里的一项资产（只保留下载要用的事实）。
public struct GitHubReleaseAsset: Hashable, Sendable, Codable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int

    public init(name: String, browserDownloadURL: URL, size: Int) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

/// GitHub Releases 里的一条 release（字段按 API 的 snake_case 解码）。
public struct GitHubRelease: Hashable, Sendable, Codable {
    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [GitHubReleaseAsset]

    public init(tagName: String,
                name: String?,
                body: String?,
                htmlURL: URL,
                isDraft: Bool,
                isPrerelease: Bool,
                assets: [GitHubReleaseAsset]) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
    }
}

/// 已确认可用的更新：版本、原始 release、首选下载资产与发布页。
public struct UpdatePackage: Hashable, Sendable {
    public let version: AppVersion
    public let release: GitHubRelease
    /// 首选下载资产；nil 表示没有可识别的安装包，只能打开发布页。
    public let asset: GitHubReleaseAsset?

    /// GitHub Release 资产直链；无可识别资产时返回发布页。
    public var downloadURL: URL { asset?.browserDownloadURL ?? release.htmlURL }

    public init(version: AppVersion,
                release: GitHubRelease,
                asset: GitHubReleaseAsset?) {
        self.version = version
        self.release = release
        self.asset = asset
    }
}

/// 更新通道的纯逻辑：仓库地址、release 选择、资产选择（可单测，不碰网络）。
public enum UpdateChannelPolicy {
    /// 更新通道就是本仓库的 GitHub Releases（其他项目通用做法：不打自建服务器）。
    public static let defaultRepository = "misswell/Vistile"
    public static let userAgentProduct = "Vistile"
    public static func releasesEndpoint(repository: String = defaultRepository,
                                        perPage: Int = 20) -> URL {
        var components = URLComponents(string: "https://api.github.com/repos/\(repository)/releases")!
        components.queryItems = [URLQueryItem(name: "per_page", value: String(perPage))]
        return components.url!
    }

    /// 从 release 列表里挑出比 `current` 新的最高版本。
    ///
    /// 本仓库的发布包按既有约定标 `prerelease=true`（`v0.1.12`/`v0.1.13` 都是），
    /// 所以默认**把 prerelease 也算作正式通道**；draft 一律忽略。
    public static func latest(from releases: [GitHubRelease],
                              current: AppVersion,
                              includePrereleases: Bool = true) -> UpdatePackage? {
        var best: (AppVersion, GitHubRelease)?
        for release in releases {
            guard !release.isDraft else { continue }
            guard includePrereleases || !release.isPrerelease else { continue }
            guard let version = AppVersion(release.tagName), version > current else { continue }
            if let existing = best, existing.0 >= version { continue }
            best = (version, release)
        }
        guard let best else { return nil }
        let asset = preferredAsset(in: best.1)
        return UpdatePackage(version: best.0,
                             release: best.1,
                             asset: asset)
    }

    /// 首选资产：arm64 dmg → 任意 dmg → zip；都没有就返回 nil（只打开发布页）。
    public static func preferredAsset(in release: GitHubRelease) -> GitHubReleaseAsset? {
        let assets = release.assets
        func name(_ asset: GitHubReleaseAsset) -> String { asset.name.lowercased() }
        if let dmg = assets.first(where: { name($0).hasSuffix(".dmg") && name($0).contains("arm64") }) {
            return dmg
        }
        if let dmg = assets.first(where: { name($0).hasSuffix(".dmg") }) {
            return dmg
        }
        return assets.first { name($0).hasSuffix(".zip") }
    }
}
