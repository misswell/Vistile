import XCTest
@testable import VistileCore

/// GitHub Releases 更新通道的纯逻辑回归（方案 §21）。
/// 全部离线：版本比较、release 选择、资产挑选都只吃构造出来的 DTO，不碰网络。
final class UpdateChannelTests: XCTestCase {

    // MARK: - 版本比较

    func testVersionComparisonHandlesPrefixesAndSegmentCounts() throws {
        XCTAssertEqual(try XCTUnwrap(AppVersion("v0.1.13")), AppVersion("0.1.13"))
        XCTAssertTrue(try XCTUnwrap(AppVersion("0.1.9")) < XCTUnwrap(AppVersion("0.1.10")),
                      "逐段数值比较：字符串比较会把 0.1.10 排到 0.1.9 前面")
        XCTAssertTrue(try XCTUnwrap(AppVersion("0.9.9")) < XCTUnwrap(AppVersion("1.0.0")))
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"), "缺位按 0，尾部 0 不参与")
        XCTAssertEqual(AppVersion("0.2.0-beta"), AppVersion("0.2.0"), "预发布后缀不参与排序")
        XCTAssertNil(AppVersion("nightly"))
        XCTAssertNil(AppVersion("v1.x.0"))
    }

    func testAssetDecodesDigestAndAcceptsOlderReleasesWithoutIt() throws {
        let json = #"{"name":"Vistile.dmg","browser_download_url":"https://github.com/misswell/Vistile/releases/download/v1/Vistile.dmg","size":12,"digest":"sha256:abcd"}"#
        let asset = try JSONDecoder().decode(GitHubReleaseAsset.self, from: Data(json.utf8))
        XCTAssertEqual(asset.digest, "sha256:abcd")
        let legacy = json.replacingOccurrences(of: #","digest":"sha256:abcd""#, with: "")
        XCTAssertNil(try JSONDecoder().decode(GitHubReleaseAsset.self, from: Data(legacy.utf8)).digest)
    }

    // MARK: - release 选择

    private func release(_ tag: String,
                         draft: Bool = false,
                         prerelease: Bool = true,
                         assets: [(String, String, Int)] = []) -> GitHubRelease {
        GitHubRelease(tagName: tag,
                      name: "Vistile \(tag)",
                      body: "release \(tag)",
                      htmlURL: URL(string: "https://github.com/misswell/Vistile/releases/tag/\(tag)")!,
                      isDraft: draft,
                      isPrerelease: prerelease,
                      assets: assets.map {
                          GitHubReleaseAsset(name: $0.0,
                                             browserDownloadURL: URL(string: $0.1)!,
                                             size: $0.2)
                      })
    }

    func testLatestSkipsDraftAndOlderAndPicksHighest() throws {
        let current = try XCTUnwrap(AppVersion("0.1.13"))
        let list = [release("v0.1.14", assets: [("Vistile_v0.1.14_macos_arm64.dmg", "https://example.com/a.dmg", 10)]),
                    release("v0.2.0", draft: true),
                    release("v0.1.12"),
                    release("v0.1.15")]
        let latest = try XCTUnwrap(UpdateChannelPolicy.latest(from: list, current: current))
        XCTAssertEqual(latest.version, AppVersion("0.1.15"))
        XCTAssertNil(latest.asset, "没有 dmg 时如实为 nil，界面退回打开发布页")
        XCTAssertEqual(latest.downloadURL.absoluteString,
                       "https://github.com/misswell/Vistile/releases/tag/v0.1.15")
    }

    func testLatestReturnsNilWhenNothingIsNewer() throws {
        let current = try XCTUnwrap(AppVersion("0.1.13"))
        XCTAssertNil(UpdateChannelPolicy.latest(from: [release("v0.1.13"), release("v0.1.12")],
                                                current: current))
        XCTAssertNil(UpdateChannelPolicy.latest(from: [], current: current))
    }

    func testPrereleaseIsPartOfTheChannelByDefault() throws {
        let current = try XCTUnwrap(AppVersion("0.1.13"))
        let list = [release("v0.1.14", prerelease: true)]
        XCTAssertNotNil(UpdateChannelPolicy.latest(from: list, current: current),
                        "本仓库发布包一律标 prerelease，默认必须算进正式通道")
        XCTAssertNil(UpdateChannelPolicy.latest(from: list, current: current, includePrereleases: false))
    }

    func testAssetPreferencePrefersArm64DmgThenAnyDmgThenZip() {
        let multi = release("v0.1.14", assets: [
            ("Vistile_v0.1.14_macos_arm64.zip", "https://example.com/a.zip", 1),
            ("Vistile_v0.1.14_macos_x86_64.dmg", "https://example.com/b.dmg", 2),
            ("Vistile_v0.1.14_macos_arm64.dmg", "https://example.com/c.dmg", 3),
        ])
        XCTAssertEqual(UpdateChannelPolicy.preferredAsset(in: multi)?.name,
                       "Vistile_v0.1.14_macos_arm64.dmg")

        let onlyDmg = release("v0.1.14", assets: [("Vistile.dmg", "https://example.com/d.dmg", 1)])
        XCTAssertEqual(UpdateChannelPolicy.preferredAsset(in: onlyDmg)?.name, "Vistile.dmg")

        let onlyZip = release("v0.1.14", assets: [("Vistile.zip", "https://example.com/e.zip", 1)])
        XCTAssertEqual(UpdateChannelPolicy.preferredAsset(in: onlyZip)?.name, "Vistile.zip")
    }

    // MARK: - GitHub 下载地址

    func testPackageUsesGitHubReleaseAssetDirectly() throws {
        let current = try XCTUnwrap(AppVersion("0.1.13"))
        let list = [release("v0.1.14", assets: [
            ("Vistile_v0.1.14_macos_arm64.dmg", "https://github.com/misswell/Vistile/releases/download/v0.1.14/Vistile_v0.1.14_macos_arm64.dmg", 2_420_239)
        ])]
        let package = try XCTUnwrap(UpdateChannelPolicy.latest(from: list, current: current))
        XCTAssertEqual(package.downloadURL.absoluteString,
                       "https://github.com/misswell/Vistile/releases/download/v0.1.14/Vistile_v0.1.14_macos_arm64.dmg",
                       "有资产时直接打开 GitHub Release 下载链接")
    }

    func testPackageWithoutAssetOpensGitHubReleasePage() throws {
        let current = try XCTUnwrap(AppVersion("0.1.13"))
        let list = [release("v0.1.14")]
        let package = try XCTUnwrap(UpdateChannelPolicy.latest(from: list, current: current))
        XCTAssertEqual(package.downloadURL.absoluteString,
                       "https://github.com/misswell/Vistile/releases/tag/v0.1.14")
    }

    // MARK: - GitHub JSON 解码

    func testDecodesGitHubReleasesPayload() throws {
        let json = """
        [{
          "tag_name": "v0.1.14",
          "name": "Vistile 0.1.14",
          "body": "修复…",
          "html_url": "https://github.com/misswell/Vistile/releases/tag/v0.1.14",
          "draft": false,
          "prerelease": true,
          "assets": [{
            "name": "Vistile_v0.1.14_macos_arm64.dmg",
            "browser_download_url": "https://github.com/misswell/Vistile/releases/download/v0.1.14/Vistile_v0.1.14_macos_arm64.dmg",
            "size": 2375689
          }]
        }]
        """
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: Data(json.utf8))
        let first = try XCTUnwrap(releases.first)
        XCTAssertEqual(first.tagName, "v0.1.14")
        XCTAssertTrue(first.isPrerelease)
        XCTAssertEqual(first.assets.first?.size, 2_375_689)
        let current = try XCTUnwrap(AppVersion("0.1.13"))
        let package = try XCTUnwrap(UpdateChannelPolicy.latest(from: releases, current: current))
        XCTAssertEqual(package.version, AppVersion("0.1.14"))
        XCTAssertNotNil(package.asset)
    }

    func testReleasesEndpointTargetsTheRepository() {
        let url = UpdateChannelPolicy.releasesEndpoint()
        XCTAssertEqual(url.absoluteString,
                       "https://api.github.com/repos/misswell/Vistile/releases?per_page=20")
    }
}
