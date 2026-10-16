# Vistile 兼容矩阵

方案 §15：**没有测试的格子写"未测"，不要填"支持"。**
2026-10-16 第一次在**授权态**跑通了探针（权限记在正式版包上，见 §1 的环境 A），拿到第一批客观事实：
「关联」在 12 个真实应用上有结论了，同时暴露出两个真实失败（P0-1 同进程 AX 索引不唯一、P0-3 提升目标时连带兄弟窗口）。
同一天把 0.1.3（含 R01–R11 与探针退出修复）覆盖装进 `/Applications` 复跑，得到第二轮数据：**P0-3 转为通过、授权无需重新授予，P0-1 仍然失败**。
第三轮（0.1.4+5，改正判据后）：**P0-1 转为通过**——那条红两个版本的原因确认是探针自己的判据错（AX 索引只在同进程内有意义）；
P0-3 第一次逐应用复测，**Code 判通过、Chrome 判失败**，而 Chrome 那条红的基准取在上一轮提升还没落定的窗口列表上，
因此它还不能当 Chrome 的定论（见 §2 的对照表）。
第四轮（**0.1.5+6，16:37，`restoreOverview()` 生效**）：自动 13 项 **11 通过 / 2 失败**。**P0-4 转为通过**
（放大 ChatGPT 后总览面板不持有键盘、归属=targetApplication，0.1.1 之后第二次拿到这条读数）；
P0-3 三个多窗口应用全跑：Code 连续第二轮通过，Chrome 与访达各一条红、且**两轮红的原因不同**；
P0-7 第一次回「缺布局 2」，查明是测量时机（网格在会话隐藏时被清空）。**这一轮没有任何一格转为通过**。
其余格子仍未测；`~/Desktop/Vistile Diagnostics/capability-report.md` 里的同名表格是权威来源，本文只是待填清单与口径说明。
**但这条权威只对"当前还在的那份"成立**：0.1.4 的原始报告文件已经不在了——它被一轮宿主测试就地覆盖
（`CompatibilityRecorder.init(fileName:)` 的参数当时没生效，落盘名硬编码，见 [Acceptance.md](Acceptance.md) §6）。
所以本文的 0.1.4 那几列是**转录**，无法再拿原始文件核对；0.1.5 起报告在探针启动时会先把上一轮归档进
`_archive/<版本-时间>/`，桌面那份永远是最近一轮，事故已经堵住并由 `T16DiagnosticsOutputTests` 4 条用例守着。

## 1. 测试环境

| 项 | 环境 A：正式版（已授权，唯一有真实数据的一组） | 环境 B：仓库 Debug 产物（未授权） |
| --- | --- | --- |
| 包 | `/Applications/Vistile.app`，Developer ID 签名 + 公证票据有效。四轮：0.1.1+2（15:13）、覆盖安装后的 0.1.3+4（15:26，含 R01–R11 与探针退出修复）、覆盖安装后的 0.1.4+5（15:56，改正 P0 判据）、覆盖安装后的 **0.1.5+6（16:37，`restoreOverview()` 与探针进场清场）** | `build/Build/Products/Debug/Vistile.app`，0.1.0+1 / 0.1.2+3，Apple Development 签名 |
| 系统版本 | macOS 27.0.1 | macOS 27.0.1 |
| 硬件 | Apple M5（Mac17,2），arm64，10 核（4 Performance + 6 Efficiency），24GB | 同左 |
| 显示器 | 2 块；0.1.3、0.1.4 与 0.1.5 三轮探针都读到 **负坐标 0 块、缩放 1 种**（与更早记录的"1 块负坐标、2 种缩放"不一致，说明这项随当天接线变化，不能当成固定环境） | 2 块（含 1 块负坐标、2 种缩放） |
| 权限 | 屏幕录制 已授予 / 辅助功能 已授予（授予对象是 Developer ID 那个包，覆盖安装 0.1.3、0.1.4 与 0.1.5 后都没有再弹窗） | 屏幕录制 未授予 / 辅助功能 未授予 |
| 结果 | 0.1.1+2：目录 17 个窗口，自动 9 项 **7 通过 / 2 失败**。0.1.3+4：自动 13 项 **12 通过 / 1 失败**（失败的是 P0-1）。0.1.4+5：目录 17 个窗口、多窗口进程 2 个，自动 13 项 **12 通过 / 1 失败**（失败的是 P0-3 · Chrome），未结束事务 0 条；命令带 `-W` 能返回、报告也写全了，说明进程确实自行退出（这一轮没单独计时，0.1.5 那轮补）。0.1.5+6：目录 17 个窗口、**多窗口进程 3 个**，自动 13 项 **11 通过 / 2 失败**（P0-3 · Chrome 与访达、P0-7 缺布局），另有 1 条「过渡超时」记为失败，未结束事务 0 条；这一轮同样是 `open -W` 返回、报告写全，因此也自行退出了（没单独计时） | 目录为空，探针写出报告，未结束事务 0 条 |

**授权记在签名身份上，不记在 bundle id 上就够了**：环境 A 的授权不会给环境 B 用，Debug 产物跑探针会再弹一次窗。
用户只给正式安装的包授权，因此**正式验收一律跑 `/Applications/Vistile.app`**（命令见 [Acceptance.md](Acceptance.md) §4）。

| 事实 | 证据 |
| --- | --- |
| 同签名升级保留授权 | **通过（已实测三次）**：0.1.1→0.1.3、0.1.3→0.1.4、0.1.4→0.1.5 的 Developer ID 包覆盖装进 `/Applications` 后直接跑探针，都没有重新授权，P0-0 三轮回「屏幕录制=true，辅助功能=true」并取到 17 个窗口的真实目录。所以升级不需要用户再点一次权限 | 本机 2026-10-16 15:26、15:56 与 16:37 三轮报告 |
| 探针跑的就是发布字节 | 0.1.4 那轮：`/Applications/Vistile.app/Contents/MacOS/Vistile` 的 `sha256 c1c64804df2e7f5e385ada9651044ad9ce587c9af224793b40139b9dde7a47d5`，与挂载 `Vistile_v0.1.4_macos_arm64.dmg` 后镜像里同一个文件的哈希一字不差；`Info.plist` 两边都是 `0.1.4 / 5`，`Identifier=com.misswell.Vistile`、`Authority=Developer ID Application: Guofeng Liu (U8U443D7ZL)` → Apple Root CA、`flags=0x10000(runtime)`、`lipo -archs` 只有 `arm64`，`codesign --verify --deep --strict -vvvv` 回 `valid on disk` + `satisfies its Designated Requirement`。0.1.3 那轮同法核对过（二进制 `sha256 5d91c359ef435aab…16a26141`）。**0.1.5 那轮同法逐项核对**：包内二进制
`sha256 5ec8ca4e4b4858e75005d463e2ed328e003880707e25402bef7a4c0de3483672`，与 16:37 跑探针的那个
`/Applications/Vistile.app` 一字不差；`Info.plist` 两边都是 `0.1.5 / 6`；`Identifier=com.misswell.Vistile`、
`flags=0x10000(runtime)`、证书链走到 `Developer ID Application: Guofeng Liu (U8U443D7ZL)`；dmg 与镜像内 app
的 `stapler validate` 都回 `The validate action worked!`；`codesign --verify --deep --strict` 回
`valid on disk` + `satisfies its Designated Requirement`；`lipo -archs` 只有 `arm64` | 本机 `shasum` / `codesign` / `lipo` / `PlistBuddy` / `hdiutil` 实测（2026-10-16，0.1.5 那次在 17:15 从 Release 页重新下载核对） |
| 探针退出（未授权态） | 环境 B 的 0.1.2 探针写完报告后**不退出**，连续两次复现（挂住 5 分钟、90 秒）：主线程停在 `P0Probe.run()`（`App/P0Probe.swift:75`）→ `-[NSApplication terminate:]` → `_shouldTerminate` → `nextEventMatchingMask:`。`NSApp.terminate` 就地等待 `applicationShouldTerminate` 的 reply，而 reply 只能靠主队列排空送达，此时主线程正被 drain 占着。改法：退出请求从 run loop 观察点发出。修后同一条命令 40 秒跑完并自行退出 | 本机 `sample` 输出 + 修复前后各两次运行计时 |
| 探针退出（授权态） | 环境 A 的 0.1.1 探针**正常自行退出**（`open -W` 返回 0），同一调用点没挂。也就是说挂死需要"未授权 + 空目录"这一组条件配合，哪一项是必要条件还没分离出来；修复让两条路径都不再依赖主队列排空。0.1.3+4 在授权态 `open -W` 返回 0、14 秒自行退出；0.1.4+5 同一条命令也能返回且报告写全（即同样自行退出） | 同上 |
| 用户实际退出路径 | 对普通模式实例发 Apple 事件 `quit`（同一个 `applicationShouldTerminate`）3 秒退出；菜单栏点击那条路径未单独测 | 本机实测 |

### 1.1 发布产物的构建环境（CI，不是运行环境）

| 项 | 值 | 来源 |
| --- | --- | --- |
| Runner 镜像 | `macos-14`（镜像标签 `macos-14-arm64`，20260831.0302），系统 macOS 14.8.9 | run [`38773723973`](https://github.com/misswell/Vistile/actions/runs/38773723973) 日志；0.1.2 那次 run [`38863514387`](https://github.com/misswell/Vistile/actions/runs/38863514387)、0.1.3 那次 run [`38866800228`](https://github.com/misswell/Vistile/actions/runs/38866800228) 同镜像同系统（日志里 `Image: macos-14-arm64` / `14.8.9` / `Target: arm64-apple-macosx14.0`） |
| 构建用 Xcode | 16.2（Build 16C5032a，`/Applications/Xcode_16.2.0.app`；取镜像里装得最高的那个，默认 `xcodebuild` 是 15.4） | 同上，脚本内 `==> 工具链：` 一行 |
| macOS SDK | **15.2** | `xcrun --sdk macosx --show-sdk-version`，与产物 `otool -l` 的 `LC_BUILD_VERSION sdk 15.2` 一致 |
| 部署目标 | `minos 14.0`（`arm64-apple-macosx14.0`，Swift 6.0.3） | 同上：解出的二进制 `otool -l` |
| 产物架构 | `arm64` 单架构，从上传的 dmg 里解出 app 实测 `lipo -archs` | 同上 |
| bundle id | `com.misswell.Vistile`（解包读 `Info.plist` 实测） | 同上 |
| 干跑产物的签名实况 | `flags=0x20002(adhoc,linker-signed)`、无票据、`stapler validate` 报 "does not have a ticket" | 下载 run 38773467420 的 dmg 实测 |
| 已证明 | 未签名干跑通过：76 项测试在 Swift 6.0.3 下全绿（**那是 0.1.0 的测试面**，当前是核心 131 + 宿主 80，见"已证明（当前测试面）"一行）、App 用 SDK 15.2 编过、dmg 能挂载、镜像里的 app 是 arm64 单架构 | 同上 |
| 已证明（负向） | 零凭据时 `probeCredentials` 红在第一步并报出缺的键名（`缺少 APPLE_DEVELOPER_ID_P12_BASE64`），不静默通过、不发布 | run [`38774694133`](https://github.com/misswell/Vistile/actions/runs/38774694133) |
| 已证明（签名与公证） | Developer ID 身份导入并试签通过；`.app` 与 `.dmg` 各自公证后 `stapler` 都回 "The staple and validate action worked!"；挂载后镜像里的 `Vistile.app` 票据仍有效；`flags=0x10000(runtime)`；`lipo -archs` 仍是 `arm64` | run [`38827757461`](https://github.com/misswell/Vistile/actions/runs/38827757461) |
| 已证明（Gatekeeper） | **runner 上 `spctl --status` 是 `assessments enabled`**，`spctl -a -t exec` 对构建产物和挂载出来的 app 都回 `accepted` / `source=Notarized Developer ID`——这是一台评估开启的干净 arm64 机器给出的放行结论。**但 `accepted` 本身不证明票据在镜像里**：联网时在线查询会替无票据的包补上上下文，分得开的只有挂载后对包内 app 跑 `stapler validate`（下一行） | 同上，以及发布那次 run [`38828073929`](https://github.com/misswell/Vistile/actions/runs/38828073929) |
| 已证明（发布字节） | 从 Release 页重新下载的 `Vistile_v0.1.1_macos_arm64.dmg`（1164713 字节，`sha256 01646765…97760`）挂载后：dmg 与镜像内 app 的票据都 `The staple and validate action worked!`，`Authority=Developer ID Application`，`flags=0x10000(runtime)`，`arm64` 单架构 | 本机对下载文件实测 |
| 已证明（0.1.2 发布字节） | `Vistile_v0.1.2_macos_arm64.dmg`：**1380316 字节**，`sha256 f9d1d9786dc7cb0d…537a0c201`，与 `GET /repos/misswell/Vistile/releases/tags/v0.1.2` 里该资产的 `digest` 逐字节相同（先下载再比对，不是只信 CI 日志）。挂载后：`Identifier=com.misswell.Vistile`、`flags=0x10000(runtime)`、`Authority=Developer ID Application: Guofeng Liu (U8U443D7ZL)` → `Developer ID Certification Authority` → `Apple Root CA`，dmg 与镜像内 `Vistile.app` 都回 `The staple and validate action worked!`，`lipo -archs` 只有 `arm64`，`Info.plist` 是 `0.1.2 / 3`，包内二进制 `sha256 83884fdc3cffefbd…3b5f5c19`。Apple 侧公证成对：`Vistile_v0.1.2_notarization.zip` 06:52:45Z → `Vistile_v0.1.2_macos_arm64.dmg` 06:53:11Z，两条 `Accepted` | run [`38863514387`](https://github.com/misswell/Vistile/actions/runs/38863514387) 与本机对 Release 页下载文件实测（2026-10-16） |
| 已证明（0.1.3 发布字节） | `Vistile_v0.1.3_macos_arm64.dmg`：**1380791 字节**，`sha256 0bfb9a52712e2fa954700402606468ae19bef9b6cb7cf5ca556900a1fea760de`，与 `GET /repos/misswell/Vistile/releases/tags/v0.1.3` 里该资产的 `digest` 逐字节相同（先 `gh release download` 再比对）。挂载后：`Identifier=com.misswell.Vistile`、`flags=0x10000(runtime)`、证书链 `Developer ID Application: Guofeng Liu (U8U443D7ZL)` → `Developer ID Certification Authority` → `Apple Root CA`，dmg 与镜像内 `Vistile.app` 都回 `The staple and validate action worked!`，`codesign --verify --deep --strict` 回 `valid on disk` + `satisfies its Designated Requirement`，`lipo -archs` 只有 `arm64`，`Info.plist` 是 `0.1.3 / 4`，包内二进制 `sha256 5d91c359ef435aab…16a26141`（与 `/Applications/Vistile.app` 里那个相同，见 §1） | run [`38866800228`](https://github.com/misswell/Vistile/actions/runs/38866800228) 与本机对 Release 页下载文件实测（2026-10-16 15:31） |
| 已证明（0.1.4 发布字节） | `Vistile_v0.1.4_macos_arm64.dmg`：**1400515 字节**，`sha256 196b617a24b088673cdccead54203f6fd75b91b6f675a160d7a80cc6a182a1a9`，与 `GET /repos/misswell/Vistile/releases/tags/v0.1.4` 里该资产的 `digest` 逐字节相同。挂载后：dmg 与镜像内 `Vistile.app` 都回 `The staple and validate action worked!`，`Info.plist` 是 `0.1.4 / 5`，包内二进制 `sha256 c1c64804df2e7f5e…de7a47d5`（与 `/Applications/Vistile.app` 里那个一字不差，见 §1）。runner 侧公证成对：`.app` 07:54:42 `Accepted` → `staple worked` 07:54:44，`.dmg` 07:55:18 `Accepted` → `staple worked` 07:55:19；`spctl --status` = `assessments enabled`，构建产物与挂载出来的 app 两处都回 `accepted` / `source=Notarized Developer ID`；`codesign --verify` 对 app 与 dmg 都回 `valid on disk` + `satisfies its Designated Requirement` | run [`38869893108`](https://github.com/misswell/Vistile/actions/runs/38869893108) 日志 + 本机对 `/tmp/v014/Vistile_v0.1.4_macos_arm64.dmg` 与 `/Applications/Vistile.app` 实测（2026-10-16 16:10） |
| 已证明（0.1.5 发布字节） | `Vistile_v0.1.5_macos_arm64.dmg`：**1399736 字节**，`sha256 e8d15fa976231f8f7d6f0f20352a36e0b6782ad5f1115d3a2225c7fca44a8417`，与 `GET /repos/misswell/Vistile/releases/tags/v0.1.5` 里该资产的 `digest` 逐字节相同（先 `gh release download v0.1.5 -R misswell/Vistile` 再比对）。挂载后的全部复核见上面"探针跑的就是发布字节"那一行。runner 侧公证成对：`.app` 08:35:35 `Accepted` → `staple worked` 08:35:36，`.dmg` 08:35:59 `Accepted` → `staple worked` 08:35:59；`codesign --verify` 对 app 与 dmg 都回 `valid on disk` + `satisfies its Designated Requirement`；`spctl -a -t exec` 对构建产物与挂载出来的 app 都回 `accepted` | run [`38874504769`](https://github.com/misswell/Vistile/actions/runs/38874504769) 日志 + 本机对 `/tmp/v015/Vistile_v0.1.5_macos_arm64.dmg` 实测（2026-10-16 17:15） |
| Apple 侧公证记录 | 按名字过滤共 **6 条，三对**（截至 0.1.2），每对都是一条 `.notarization.zip`（`.app` 本体）早于一条 `.dmg`：0.1.1 的 00:09:58→00:10:21（干跑）与 00:13:56→00:14:26（发布那次），0.1.2 的 06:52:45→06:53:11（发布），六条全 `Accepted`。只剩 dmg 就等于 `.app` 从没提交给 Apple，所以「成对且 zip 在前」这一条要看，不能只看 dmg。**0.1.3、0.1.4 与 0.1.5 那三对只从 run 日志核对**：0.1.3 是 zip 07:24:15 提交、07:24:32 `Accepted`，dmg 07:24:39 提交、07:25:02 `Accepted`；0.1.4 是 `.app` 07:54:42 `Accepted`、`.dmg` 07:55:18 `Accepted`；0.1.5 是 `.app` 08:35:35 `Accepted`、`.dmg` 08:35:59 `Accepted`。本机重跑 `notarytool history` 需要 issuer id（那是 CI secret），至今没取到，因此 Apple 侧列表里只有前三对 | 前三对：`xcrun notarytool history` 本机按名字过滤实测（2026-10-16）；0.1.3/0.1.4/0.1.5：run [`38866800228`](https://github.com/misswell/Vistile/actions/runs/38866800228)、[`38869893108`](https://github.com/misswell/Vistile/actions/runs/38869893108)、[`38874504769`](https://github.com/misswell/Vistile/actions/runs/38874504769) 的 `build-macos` 日志 |
| 修的那处真进了发出去的包 | **0.1.5：标签 `v0.1.5` → `c6653ed`，`v0.1.4..v0.1.5` = 3 个提交**（`d029fce` 每项从干净阶段与稳定窗口列表开始取证 = `restoreOverview()` + 稳定读数；`5751a05` P0-9 不再代填「层级」；`c6653ed` 版本号 0.1.5/6），发布任务 checkout 的是 `ref: v0.1.5`，16:37 那轮探针跑的二进制与镜像里那个哈希一字不差（上一行），所以 0.1.5 那轮报告里的"进场已清场"确实是发出去的代码在做。0.1.4：标签 `v0.1.4` → `7c4503b`（`fix(P0 探针): 三条口径错误改正，版本 0.1.4`，含核心包新增的 `CatalogIdentityAudit` 与 5 条单测），`v0.1.3..v0.1.4` = 2 个提交，发布任务 checkout 的就是 `ref: v0.1.4`；15:56 那轮探针跑的那个 `/Applications/Vistile.app` 二进制与镜像里那个哈希一字不差（§1），所以判据改正确实进了发出去的包。**同样的限制仍然成立**：写回这四轮实测证据的文档提交在标签之后，文档比包新。0.1.3：标签 → `35044b6`，`v0.1.2..v0.1.3` = 3 个提交（含探针退出修复 `fe4b83c`），发布任务 checkout 参数是 `ref: v0.1.3` / `SOURCE_REF: v0.1.3`。0.1.2：标签 → `477e132`，R01–R11 的全部修复提交（`27f8c90`、`901b4a9`、`3b690f4`、`4f49ae3`、`675227f`、`daf35c0`、`23cece2`）连同 CI 与文档提交都在标签里（`git rev-list --count v0.1.1..v0.1.2` = 14）。0.1.1 那次同法核对：标签 → `804e24f`，`.p8` 落盘顺序修复 `64c6635` 是其祖先 | 本机 git 查询 + run [`38874504769`](https://github.com/misswell/Vistile/actions/runs/38874504769)、[`38869893108`](https://github.com/misswell/Vistile/actions/runs/38869893108)、[`38866800228`](https://github.com/misswell/Vistile/actions/runs/38866800228)、[`38863514387`](https://github.com/misswell/Vistile/actions/runs/38863514387)、[`38828073929`](https://github.com/misswell/Vistile/actions/runs/38828073929) 的 env 行 |
| 反面教材（已防呆） | 干跑那次手动触发了真实标签 `v0.1.1`，产出的 `Vistile_v0.1.1_macos_arm64.dmg` 与线上发布的同名文件**字节完全不同**（干跑 `1410db98…0a3f3a` / 发布 `01646765…97760`）。workflow 的 `workflow_dispatch.tag` 现在要求填测试标签，`verify` 任务在标签等于 `Info.plist` 版本时打 `::warning::` 并写进 job summary——不硬拦，因为「重发同一版」是合法兜底路线 | 两次 run 的 artifact 各自 `shasum -a 256` |
| 已证明（当前测试面） | 核心包 137 项纯逻辑测试（14 个 suite，0.1.6 起新增 `TargetRaiseAuditTests` 6 条）+ 宿主层 84 项测试（真实控制器/内容视图/CAMetalLayer，目录与写入走注入替身，0.1.6 起新增 `T16DiagnosticsOutputTests` 4 条）在本机通过；宿主里「面板实际成为 key 窗口」一条依赖系统前台，取不到时显式 skip（本机几种结果都出现过：同一份代码 16:02 那轮 0 跳过、16:25 与 17:02 那两轮各 1 跳过，所以跳过条不能算异常）。CI 在 `pull_request` 与 `push main` 上跑同样两条（`.github/workflows/ci.yml`，不需要任何签名凭据），runner 侧数字：0.1.5 代码面 run [`38874498650`](https://github.com/misswell/Vistile/actions/runs/38874498650) 核心 `Test run with 131 tests passed`、宿主 `Executed 80 tests, with 1 test skipped and 0 failures`；更早的 0.1.4 代码面 run [`38869704821`](https://github.com/misswell/Vistile/actions/runs/38869704821) 同样是 131 / 80；0.1.3 代码面 run [`38866564471`](https://github.com/misswell/Vistile/actions/runs/38866564471) 核心是 126 项（那轮还没有 `CatalogIdentityAudit`）。**137 / 84 这对数字目前只有本机证据**，要等 `v0.1.6` 的 CI 跑完才能写"runner 侧也已追上" | 本机 Xcode 27 / SDK 27.0，2026-10-16，命令见 [Acceptance.md](Acceptance.md) §4；runner 侧 run [`38874498650`](https://github.com/misswell/Vistile/actions/runs/38874498650)、[`38869704821`](https://github.com/misswell/Vistile/actions/runs/38869704821)、[`38866564471`](https://github.com/misswell/Vistile/actions/runs/38866564471) 日志 |
| 未证明 | 用户自己的 Mac 上双击安装的实际体验（权限授予流程、是否被拦）、Intel 机器、以及 P0 的功能行为 | — |

同一套脚本在本机用 `Apple Development` 身份跑过 `SKIP_NOTARIZE=1`：镜像里的 app 确实是
`flags=0x10000(runtime)`、证书链走到 Apple Root CA，但 `Authority` 不是 Developer ID Application，
所以这条路不会有票据也不会发布——脚本现在会把这一点直接说出来。

**`spctl` 在这台开发机上不构成证据**：`spctl --status` 是 `assessments disabled`，
连上面那个 adhoc 的干跑产物都会被回 `accepted / override=security disabled`。
CI 复核因此先把评估状态打进日志，硬把关放在两处与机器设置无关的地方——
`codesign -dvvv` 里必须有 `Authority=Developer ID Application`，`stapler validate` 必须有票据
（包括挂载后对镜像里那个 `Vistile.app` 再验一次）。评估开着时 `spctl` 才作为附加证据。

真公证那一次（run 38827757461 / 发布那次 38828073929）里 runner 的评估状态是 `assessments enabled`，
两条 `spctl -a -t exec` 都回 `accepted` 且 `source=Notarized Developer ID`——所以这条不是「没测」，
而是一台评估开启的干净 arm64 机器给出的放行结论；仍然没测的是用户自己那台机器的首次安装体验。

开发机的 Xcode 27 / SDK 27.0 与 runner 的 Xcode 16.2 / SDK 15.2 差别是真实的：`_TestSupport.swift` 里一条把整型除法、
`CGFloat` 乘法和 `CGRect(origin:size:)` 嵌进同一次调用的表达式，在本机正常、在 16.2 上直接
类型推断超时（第一次干跑抓到，提交 `329c78d` 拆掉）。所以「本机编得过」不能当成「发出去的包编得过」。

## 2. 矩阵

列含义：**捕获**=能否取到实时画面并显示正确状态；**关联**=SC/CG/AX 三路身份唯一对应；**移动/resize**=AX 读写后读回一致；**层级**=展开时目标在总览前且不带动兄弟窗口；**Sheet**=另存为/工作表与弹层不丢焦点、不被总览遮挡；**恢复**=收回与退出后几何回到原状。

"关联=通过"只表示探针取到的身份事实（探针按 SC/CG/AX 三路对得上、窗口编号不重复），**不等于画面没串、也不等于肉眼验收过**。
四轮数据来自同一个 `/Applications/Vistile.app`：0.1.1+2（不含 R09–R11）、0.1.3+4（含）、0.1.4+5（改正判据）、0.1.5+6（进场清场 + 稳定读数）。
「层级」这一列在 0.1.3 及以前只有"探针当时选到目标的那一个应用"有结论（每次只挑一个可放大窗口），
所以 0.1.1 的 Code 失败格子在 0.1.3 没被复测；0.1.4 起 P0-3 对**每个**"同应用 ≥2 窗口"的进程都跑一遍，
那一轮 Code 判通过、Chrome 判失败；0.1.5 把三个多窗口应用全跑（Code、Chrome、访达），Code 连续第二轮通过、另两格各一条红。

**这一列的写入方在四轮里改过两次，必须说清，否则读者会把"在前台"当成"不带动兄弟"**：
0.1.4 及以前，除了 P0-3，`P0-9`（只有一个放大目标、没有兄弟窗口）和 `bringToFront` 的前台读回也会顺手写它；
`5751a05`（在 v0.1.5 标签里）去掉了 P0-9 那处代填，`b763712`（0.1.6，未发布）去掉了前台读回那处。
所以 0.1.5 报告里 ChatGPT 的「层级=通过」来源是前台读回而不是 P0-3，**它没有兄弟场景，不能当这一列的结论**；
访达与 Chrome 的「层级=失败」才是 P0-3 写的。0.1.6 起这一列**只有 P0-3 能写**，其余应用的该格回到未测。

| 应用 | 版本 | 捕获 | 关联 | 移动 | resize | 层级 | Sheet | 恢复 | 已知限制 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Finder（桌面 + 浏览器窗，报告里写 `访达`） | 未记录 | 未测 | 通过 | 未测 | 未测 | **失败（0.1.5，未定性）** | 未测 | 未测 | 0.1.5+6：2 个窗口，目标 #23→#7、兄弟 #21→#20 ⇒ 旧判据按绝对下标判"兄弟一起被提升"。兄弟只动了 1 格，很可能是两次读数之间无关窗口开关的余波（绝对下标不是同一个参照系），也可能是真提升——**两者现在分不开，等 0.1.6 的两两比较判据复跑才能定性**。除此之外访达其余格子仍无结论 |
| Safari | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Terminal（终端） | 未记录 | 未测 | 通过 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 文本编辑 TextEdit | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 备忘录 Notes | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 预览 Preview | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Mail | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 系统设置 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Google Chrome | 未记录 | 未测 | 通过 | 未测 | 未测 | **三轮三种红/绿** | 未测 | 未测 | 0.1.3+4：目标 #11→#8、兄弟 #12→#12 ⇒ 通过。0.1.4+5：目标 #14→#9、兄弟 #17→#13 ⇒ 失败，但 before 取在上一轮（Code）提升的余波还没落定的窗口列表上 ⇒ 那条红不可信。0.1.5+6（进场已清场、前后取稳定读数）：目标 #7→#7、兄弟 #8→#8 ⇒ 失败，两个下标一动没动，最像"Raise 根本没发出去"（`raiseOnly` 拿不到身份或句柄时静默 return）。0.1.6 起 `RaiseOutcome` 能把"没发出"和"发了没生效"分开记，**这一格仍未定性** |
| Google Chrome Beta | 未记录 | 未测 | 通过 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Visual Studio Code（报告里写 `Code`） | 未记录 | 未测 | 通过 | 未测 | 未测 | **通过（0.1.4 与 0.1.5 两轮）** | 未测 | 通过（0.1.1） | 0.1.1+2：目标 #8→#9、兄弟 #13→#15，两个索引都变大（离前台更远）⇒ 判失败，当时的失败原因是「目标没被提升」而不是兄弟被带动（下标越小越靠前）。**0.1.4+5 与 0.1.5+6 连续两轮复测这一格通过**：3 个窗口，目标 #17→#9、兄弟 #18→#18；以及目标 #12→#8、兄弟 #10→#12。注意 0.1.5 这轮 Code 的兄弟 #10→#12 是**变差**（离前台更远），旧判据的"兄弟是否未上移"只看下标有没有变小，这一格在新判据（兄弟不得把任何仍在场且原本在它前面的窗口甩到后面）下同样通过——这一条由 `TargetRaiseAuditTests.closedWindowsAboveSiblingAreNotARaise` 与 `siblingGenuinelyRaised` 两头钉住。恢复=通过来自 0.1.1 那轮真实写过的几何事务（表内「几何写入 17.9ms、读回偏差 0.0pt」+ 未结束事务 0 条）；0.1.4 与 0.1.5 那两轮没有事务可恢复，报告该格是未测 |
| IntelliJ IDEA | 未记录 | 未测 | 通过 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Qoder / Qoder CN | 未记录 | 未测 | 通过 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| UGit | 未记录 | 未测 | 通过 | 未测 | 未测 | 未测 | 未测 | 未测 | 0.1.3+4 那轮的 P0-9 真实链路放大的就是它：视图动作 1 次、阶段到达=true、真实背景点击后回到总览=true。**「层级」这一格 0.1.4 起回到未测**：0.1.3 的报告曾把它写成通过，那是 P0-9 顺手代填的，而 P0-9 只有一个放大目标、没有兄弟窗口可对照，证明不了该列定义的"不带动兄弟"；`5751a05`（v0.1.5 标签内）去掉了这处代填。P0-9 的链路事实仍完整记在自动结论表里 |
| ChatGPT | 未记录 | 未测 | 通过 | 未测 | 未测 | **未测（0.1.6 起）** | 未测 | 未测 | 0.1.4+5 与 0.1.5+6 两轮 P0-9 放大的都是它：视图动作 1 次、阶段到达=true、真实背景点击 1 次后回到总览=true、最小化 0→0。**0.1.5 的报告仍把它的「层级」写成通过，来源不是 P0-9 而是 `bringToFront` 的前台读回**——那证明的是"目标在前台"，不是"没带动兄弟"，判据不同不能顶替；`b763712`（0.1.6，未发布）去掉了这处代填，所以 0.1.6 起这一格应当回到未测，**这是 0.1.6 复跑要确认的一条**：单窗口应用（ChatGPT、UGit、终端等）的「层级」格一个都不该再有结论 |
| ZCode / OrbStack / MacPilot / IdeaLightRun | 未记录 | 未测 | 通过 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Xcode | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Electron 类（Slack/微信/钉钉） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 视频播放（IINA/VLC/AVPlayer） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 受保护内容（Apple Music、DRM 视频） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 全屏 Space 中的窗口 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Stage Manager 窗口组 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Catalyst / iOS-on-Mac 应用 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 无 AX 支持的进程 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| UITestHarness（脚手架，可控场景） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |

同一次探针里与这些格子直接相关的自动结论（四轮都是同一个 `/Applications/Vistile.app`、同一台机器、同一批窗口）：

| 判据 | 0.1.1+2（15:13，未含 R09–R11） | 0.1.3+4（15:26，含 R01–R11 与探针退出修复） | 0.1.4+5（15:56，改正 P0 判据与逐应用复测） || 0.1.5+6（16:37，进场清场 + 稳定读数） |
| --- | --- | --- | --- || --- |
| P0-1 目录与身份 | **失败**：17 窗口、多窗口进程 2 个，窗口编号无重复=true，**同进程 AX 索引无重复=false** | **仍然失败**，同一判据：17 窗口、多窗口进程 2、AX 唯一对应 17、窗口编号无重复=true，同进程 AX 索引无重复=false | **通过**：判据改成"同进程两个窗口不得解析到同一索引"后，17 窗口、多窗口进程 2、AX 唯一对应 17、`窗口编号无重复=true；同进程 AX 索引无重复=true`。前两轮那条红确认是探针判错（索引按 pid 分桶），不是产品缺陷 || **通过（判据改正后连续第二轮）**：17 窗口、多窗口进程 3、AX 唯一对应 17、`窗口编号无重复=true；同进程 AX 索引无重复=true` |
| P0-2 遮挡时仍实时 | 通过：16 个被遮挡窗口里 9 个 1.5s 内收到新帧；帧增量 62（≈40.9 帧/秒） | 通过：16 个里 **12 个**收到新帧；帧增量 49（≈32.6 帧/秒） | 通过：被遮挡 **17 个**里 9 个收到新帧；全目录帧增量 23（≈15.3 帧/秒）。三轮的"收到新帧比例"分别是 9/16、12/16、9/17，波动大，取决于当时哪些窗口真在更新 || 通过：被遮挡 **16 个**里 **12 个**收到新帧；全目录帧增量 46（≈30.7 帧/秒）。四轮的"收到新帧比例"是 9/16、12/16、9/17、12/16，波动大，取决于当时哪些窗口真在更新 |
| P0-3 只提升被点窗口 | **失败**：Code 目标 #8→#9、兄弟 #13→#15（都没上移） | 通过：Chrome 目标 #11→#8、兄弟 #12→#12。**但这轮只选到一个应用，Code 没被复测** | 逐应用跑：Code（3 窗口）**通过** #17→#9、兄弟 #18→#18；Chrome（2 窗口）**失败** #14→#9、兄弟 #17→#13。整体判 1 失败。**Chrome 那条红不可信**：before 取在上一轮 Code 提升的余波还没落定的窗口列表上，0.1.5 起前后都取"连续两次读数一致"的稳定值再复测 || 逐应用跑全 3 个多窗口应用：Code **通过** #12→#8、兄弟 #10→#12；Chrome **失败** #7→#7、兄弟 #8→#8（两个下标一动没动，最像 Raise 根本没发出去）；访达 **失败** #23→#7、兄弟 #21→#20（兄弟只动 1 格，疑似参照系问题）。整体 2 失败。进场清场与稳定读数都已生效，所以这两条红不是上一轮的余波，但两种成因现在分不开，要 0.1.6 的新判据复跑 |
| P0-4 键盘不被总览占用 | 通过：总览面板不持有键盘，键盘归属=targetApplication | **未测**：真实点击已派发，但协调器没有恰好收到一次卡片动作 | **仍未测**，detail 是「动作次数=0（点击前阶段=…，阶段到达=false）」——根因是上一项留下的受控目标让 `showOverview()`（只在 hidden 时 toggle）打不开总览，点位命中不到格子。0.1.5 的 `restoreOverview()` 就是修这个 || **通过**：放大 ChatGPT 后总览面板持有键盘=false、键盘归属=targetApplication。`restoreOverview()`（`d029fce`，在 v0.1.5 标签里）确实把这条路打通了，0.1.1 之后第一次重新拿到这条读数 |
| P0-5 背景点击 100 次 | 通过（有保留）：4730.0ms；结束时阶段=`collapsing`；最小化 0→0；2/2 块屏自留事件 | 通过（有保留）：3874.7ms；结束时阶段=`preparing`；最小化 0→0；2/2 块屏自留事件 | 通过（有保留）：**1181.2ms**；结束时阶段=`preparing`；最小化 0→0；2/2 块屏自留事件。三轮耗时 4730 / 3875 / 1181ms，差 4 倍，说明这个数当前主要测的是机器负载，不是状态机成本 || 通过：819.7ms；结束时阶段=**`overview`**（四轮里第一次落在干净阶段）；最小化 0→0；2/2 块屏自留事件。四轮耗时 4730 / 3875 / 1181 / 820ms |
| P0-6 身份与格子复用 | 通过：沿用 17 个、格子变动 0、跨进程启动标识冲突 0 | 通过：同样 17 / 0 / 0 | 通过：沿用 17、格子变动 0、共用启动标识的重复窗口编号 0 || 通过：同样 17 / 0 / 0 |
| P0-7 多显示器覆盖 | 通过：2 块屏（负坐标 0、缩放 1 种），有窗口的屏幕 2、承载 2、缺布局 0 | 通过：同 | 通过：2 块屏（负坐标 0、不同缩放 1 种），有窗口的屏幕 1、承载窗口 2、缺布局 0 || **失败**：2 块屏（负坐标 0、缩放 1 种），有窗口的屏幕 2、承载窗口 2、**缺布局 2**。查明是测量时机而不是产品回归：网格在会话隐藏时被 `resetForHiddenSession` 清空，而 `layouts` 正是从它重建的，且这一项前面刚记过一次过渡超时（状态机降级）。0.1.6 先恢复总览、等布局确实算出来一轮再取数，并把当时的阶段写进报告；**"有窗口的屏幕必须都有布局"这条判据没有放松** |
| P0-9 事件转接到真实上屏 | 未测（那轮还没这条） | 通过：真实点击 → 放大 UGit，视图动作 1 次、阶段到达=true；真实背景点击 1 次 → 回到总览=true；同期 present +13、捕获帧 +17（9 路流）、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0 | 通过：真实点击 → 放大 **ChatGPT**，视图动作 1 次、阶段到达=true；真实背景点击 1 次 → 回到总览=true；同期 present +14、捕获帧 +22（8 路流）、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0。**这一项从 0.1.5 起不再代填矩阵里的「层级」格**（它没有兄弟窗口可对照） || 通过：真实点击 → 放大 **ChatGPT**，视图动作 1 次、阶段到达=true；真实背景点击 1 次 → 回到总览=true；最小化 0→0；同期 **present +2、捕获帧 +1（1 路流）**、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0。present 增量的绝对值跟着活跃流数走（9/8/1 路流 → +13/+14/+2），所以这条判的是"> 0 且 GPU 错误与提交失败为 0"，不能拿增量互比 |
| P0-10 层级不随回调重排 | 未测 | 通过：12 路直播流、2s 内 163 帧回调期间层级改写 **0 次** | 通过：12 路直播流、2s 内 **149** 帧回调期间层级改写 **0 次** || 通过：**1 路**直播流、2s 内 **17** 帧回调期间层级改写 **0 次**。观察窗里的流数比前两轮少一个量级，这轮证据更弱，但判据（增量必须为 0）本身没变 |
| P0-11 背景点击不留令牌 | 未测 | 通过：空转背景点击后令牌残留=false，随后模拟外部激活（com.tencent.ugit）正常退出总览 | 通过：令牌残留=false，随后外部激活（com.apple.finder）正常退出总览 || 通过：令牌残留=false，随后外部激活（**com.alibaba.DingTalkMac**）正常退出总览。四轮用了四个不同的外部激活对象，说明这条不依赖特定应用 |
| 退出恢复 | 通过：未结束事务 0 条；几何写入 17.9ms，读回偏差 0.0pt | 通过：未结束事务 0 条 | 通过：未结束事务 0 条 || 通过：未结束事务 0 条；几何写入 117.9ms、读回一致（p95 117.9，n=1）。**单次样本，且比 0.1.1 的 17.9ms 慢一个量级**，既不能当回归也不能当"没问题" |
| 捕获预算 | 触发降级：17 路流 > `streamSoftLimit = 12`，备注连续记录"降级影响 13→17 个目标"（热状态 nominal） | 触发降级：影响 17 个目标（流上限 12，热状态 nominal） | 触发降级：影响 **17** 个目标（流上限 12，热状态 nominal）。三轮都是 17 个目标被降档、活跃流恰好顶到 12——阈值该不该是 12，要用这三组数据校准 || 触发降级：备注连续记了"影响 17 个"与"影响 18 个"两条（流上限 12，热状态 nominal）。目录只有 17 个窗口、却出现"降级影响 18 个目标"，这个不自洽还没查清，先原样记在这里 |
| 性能采样 | 帧 322 张/3.0s（所有流合计，不是屏幕帧率）、CPU 0.2 | 12 路流 / 5 个低频：帧 165 张/3.0s，表内"总览帧率"54.9，CPU 0.3（100%=一个逻辑核满载） | 12 路流 / 5 个低频：帧 139 张/3.1s，表内"总览帧率"45.3，CPU 0.3。CPU 三轮 0.2 / 0.3 / 0.3 明显低于十几路流的合理量级，这个数不能当结论，要用 Activity Monitor 对照 | 12 路流 / 6 个低频：帧 136 张/3.0s，表内"总览帧率"45.1，CPU 0.3。四轮 CPU 0.2 / 0.3 / 0.3 / 0.3，明显低于十几路流的合理量级，这个数不能当结论，要用 Activity Monitor 对照 |
| 过渡超时 | 未记 | 未记 | 未记 | **失败 1 条**：令牌 `49395:1792027413359615:1072`，「过渡在限定时间内未确认，已按状态机降级」。当时的证据只有这一句，分不清"预算太短"还是"几何根本没写成功"；0.1.6 起这条会写方向、预算、实际等待毫秒、目标应用与最后一次几何写入 |

还没分离出来的矛盾，记在这里而不是藏起来：

- **P0-3 的 Chrome 三轮三种结果**（0.1.3 通过、0.1.4 失败"兄弟被带动"、0.1.5 失败"目标一动没动"）。
  0.1.4 那条已定位为取证时机：`raiseOnly` 之后整张 `CGWindowList` 顺序表是异步改动的，before 读在了
  Code 那一轮的余波里。0.1.5 进场清场 + 前后稳定读数之后仍然红，而且红法换了，所以**这一格到现在
  既不能算通过也不能算失败**；0.1.6 的 `RaiseOutcome` 才能把"Raise 没发出去"与"发了没生效"分开。
- **P0-4 与 P0-9 曾在同一次运行里结论相反**（0.1.3、0.1.4 两轮）：P0-9 说真实点击确实转接到了视图，
  P0-4 却记"没收到一次卡片动作"。0.1.4 查明原因是阶段脏（总览没打开、点不到格子）而不是键盘归属变坏；
  **0.1.5 两条同向（都通过），这条矛盾已经消掉**——但它消掉的方式是"探针自己先把进场清干净"，
  不是产品改了，所以它证明的是取证，不是层级链路。
- **P0-5 结束时阶段四轮各不相同**（`collapsing` / `preparing` / `preparing` / `overview`）：soak 只保证
  "不累积副作用、最小化数不变"，阶段落在哪一步取决于采样时刻，不能拿来当状态机正确性判据。
- **矩阵里「层级=通过」有过两个不同的代填者**：0.1.3 的 UGit 是 P0-9 写的（`5751a05`，v0.1.5 标签内去掉），
  0.1.5 的 ChatGPT 是 `bringToFront` 的前台读回写的（`b763712`，0.1.6 去掉，未发布）。两者证明的都是
  "目标在前台"，不是该列定义的"不带动兄弟"。**0.1.6 复跑时要专门确认：单窗口应用的「层级」格应全部回到未测，
  只有 P0-3 跑过的 Code/Chrome/访达 三格允许有结论。**
- **0.1.5 报告里矩阵「已知限制」的句子与 P0-3 详情不一致**：Chrome 的详情是"目标没被提升"，
  矩阵那句却无条件写"同应用兄弟窗口被一起提升"。那句是硬编码的，把三种红糊成一句话；0.1.6 起
  该格写 `TargetRaiseAudit` 给出的真实 cause 与 `siblingGainedOver` 名单。**这属于证据表述错误，
  不影响 P0-3 的通过/失败判定，但会影响读报告的人的判断，所以列在这里。**
- **"降级影响 18 个目标"与"目录 17 个窗口"不自洽**（0.1.5 备注里 17 与 18 两条连着出现）。
  还没查清是计数口径不同（目标含不可捕获窗口？）还是重复计入，先按原样记录，不当成已知事实。


## 3. 代码里已经存在的结构性预期

这些不是"支持"结论，只是当前实现遇到该情况时会走哪条路，需要在真机确认表现是否符合预期：

- **受保护内容 / `kCGWindowSharingState = none`**：不进可捕获集合，卡片标注"应用禁止该窗口被捕获"，保留最后一帧，不冒充实时。
- **SC 未列出但 CG 存在的窗口**：仍进目录并明确标记不可捕获（`WindowCatalog`），只作为格子存在。
- **最小化窗口**：不保留空转流，保留最后一帧，状态写"已最小化"。点卡片时先写 `kAXMinimized = false` 并读回确认，
  再按身份重取 AX 句柄（解除最小化会让目录换代，旧索引不得复用），确认非最小化后才写几何并展开；
  解除失败或读不到句柄时直接报失败，不发 `expandCompleted`、不伪造近全屏。**收回与退出恢复都不会把它重新塞回 Dock。**
- **层级策略持久化值未实现**（`.splitBackgroundTiles`）：启动时迁移到 `.normalLevelActivateAndRaise` 并写回，
  `migratedOrderingStrategy` 记一次诊断事实；设置界面不再列出该选项。
- **前景化判定**：`activate`/`AXRaise` 的返回值只算"请求已发出"。判定只读回：目标是不是该应用当前的
  focused window、目标进程是不是真的前台。两项都读到相反证据才判失败并回总览；读不到记"不可确认"，不判成功。
- **背景点击的受信令牌**：只有真的引发收起或切换的那一次点击才会留下令牌；
  总览态下的空转背景点击不留令牌，后续 ⌘Tab/外部应用激活照常隐藏总览。
- **无屏幕录制权限**：`SCShareableContent` 无窗口可返回，卡片明确写缺少权限、无画面；不会用旧帧或截图冒充。
- **无辅助功能权限**：只做预览，受控聚焦/移动/resize 明确禁用并提示。
- **AX 不支持的进程**：`AXObserverHub.axUnsupportedPIDs` 记录，卡片保留预览、禁用受控聚焦。
- **同标题多窗口**：匹配输入不含标题，靠几何与结构事实打分；无法唯一确定时 `allowsAXWrite = false`，提示"同名窗口无法唯一对应"。
- **PID 复用**：身份含进程启动标识（`proc_pidinfo(PROC_PIDTBSDINFO)`），旧窗口身份不会撞新进程。
- **撤销权限**：系统无法由程序撤销，需要重启应用才能恢复捕获（这是系统限制，界面会说明）。
- **Vistile 自己的窗口**：`registerOwnWindow` 统一排除，阻止无限镜像/自捕获（P0-2 要验证这一点）。

## 4. 怎么把格子填成事实

1. 授权两项权限并重启应用，用 `UITestHarness` 或真实应用把场景摆出来。
2. 跑 `open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app`（权限记在 Developer ID 包上，Debug 产物是另一个身份，正式验收不跑 Debug；构建命令与宿主测试见 [Acceptance.md](Acceptance.md) §4）。
3. 每个格子要有对应证据：
   - 捕获 / 恢复 → mailbox `publishedCount` 增长、事务清零记录；
   - 关联 → `P0-1` 的身份唯一性与"画面没有串"录屏；
   - 移动 / resize → AX 读回一致（`geometryVerified`），不是"调用返回 0"；
   - 层级 → **只有 `P0-3` 能填**：`CGWindowListCopyWindowInfo` 顺序（下标即层级）在"两次读数都仍在场的窗口"上做两两比较，
     外加 `raiseOnly` 的 `RaiseOutcome`（没发出与发了没生效都判红），再加录屏。focused window / 前台进程读回
     是「前景化」这一条独立样本，证明的是"在前台"，**不得代填本列**；
   - 上屏 → `P0-9` 的 `RendererDiagnostics.presents` 增量与 GPU 错误计数；
   - Sheet → 另存为面板可见可点、取消后回总览不丢窗口。
4. 把 `capability-report.md` 与录屏一起归档；失败格子写清应用版本、系统版本与复现步骤。
5. 只有拿到证据的格子才允许从"未测"改成"通过/失败"。**代码可编译不代表跨应用交互已验证。**
