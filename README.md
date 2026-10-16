# Vistile

把系统中所有符合条件的窗口，按固定格子渲染成实时缩略图总览；点击卡片时，**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景任意空白处回到总览。收回过程绝不最小化窗口，临时改过的窗口几何会在退出时恢复。

> **当前状态：功能实现完成、可构建、可运行；P0 能力门禁尚未通过。**
> P0 需要真机录屏与肉眼验收，而验收人是你。任何"未测"格子都不表示可用。
> 详见 [Docs/Acceptance.md](Docs/Acceptance.md) 与 [Docs/Compatibility.md](Docs/Compatibility.md)。

仓库：<https://github.com/misswell/Vistile>

```bash
git clone https://github.com/misswell/Vistile.git
```

Release 页当前版本 `v0.1.3` 附带 GitHub Actions 产出的 **Developer ID 签名 + Apple 公证 + 已装订** `.dmg`（`Vistile_v0.1.3_macos_arm64.dmg`，arm64，1380791 字节，`sha256 0bfb9a52712e2fa954700402606468ae19bef9b6cb7cf5ca556900a1fea760de`，与 GitHub 资产接口回报的 digest 逐字节相同）。从 Release 页重新下载的字节已实测：挂载后 dmg 与镜像里的 `Vistile.app` 都回 `The staple and validate action worked!`，`codesign --verify --deep --strict` 回 `valid on disk` + `satisfies its Designated Requirement`，`Identifier=com.misswell.Vistile`、`Authority=Developer ID Application: Guofeng Liu (U8U443D7ZL)` 一路走到 Apple Root CA，`flags=0x10000(runtime)`，`lipo -archs` 只有 `arm64`，`Info.plist` 是 `0.1.3 / 4`；发布那次的 runner 上 Gatekeeper 评估是开启的，`spctl` 两处都回 `accepted / source=Notarized Developer ID`。公证成对：`.notarization.zip` 07:24:32 `Accepted` 在前、`.dmg` 07:25:02 `Accepted` 在后（这一对取自 run 日志，Apple 侧 `notarytool history` 需要 issuer id，本机没取到）。`/Applications/Vistile.app` 里的二进制与镜像里那个 `sha256` 相同（`5d91c359ef435aab…16a26141`），所以 P0 探针跑的就是发布字节。上一版 `v0.1.2`（1380316 字节，`sha256 f9d1d978…c201`）同样签名并公证过、仍挂在 Release 页；`v0.1.1` 也一样；`v0.1.0` 那条只有 Apple Development 签名、未公证，只在本机可用。

> 公证解决的是「别人能不能装」。P0 功能验收、跨应用兼容矩阵仍然没通过、仍然未测——见下面两句，别把票据当成质量证明。

## 环境

- macOS 14 及以上（开发与实测机器为 macOS 27，Apple Silicon）
- Xcode 26/27 命令行工具
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46：工程文件由 `project.yml` 生成，`Vistile.xcodeproj` 不是手写的

## 构建

```bash
brew install xcodegen            # 仅首次
xcodegen generate
xcodebuild -project Vistile.xcodeproj -scheme Vistile \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build build
```

产物在 `build/Build/Products/Debug/Vistile.app`（`build/` 已在 `.gitignore` 里）。

纯逻辑层是本地 SwiftPM 包 `Packages/VistileCore`。**必须用 `-scheme` 构建**：用 `-target` 会因为 SPM 解析顺序报 `Unable to resolve module dependency: 'VistileCore'`。首次可先执行
`xcodebuild -project Vistile.xcodeproj -scheme Vistile -resolvePackageDependencies`。`UITestHarness` 不依赖核心包，用 `-target` 构建即可。

签名：本机 Debug 产物是 Manual + `Apple Development`（团队 `U8U443D7ZL`），没有 Developer ID 与公证，只能在本机运行。Developer ID 签名与 Apple 公证由 GitHub Actions 完成，见下面「签名与公证」。

## 签名与公证

这台开发机上**没有** Developer ID Application 证书（钥匙串里只有 Apple Development 与 Apple Distribution），也没有公证凭据，所以公证只能在 CI 上做：推一个 `v*` 标签，Actions 会构建 arm64 的 Release 包、签名、公证、装订票据、出 `.dmg` 并复核后发布。

发版顺序（**只推单个标签**——推标签即发布且没有确认环节，`git push --tags` 会连着发出多个 Release）：

```bash
# 1) 改版本号。CI 的一致性守卫读的是 Support/Info.plist，标签对不上它就直接红；
#    测试壳要一起改，否则两处说的不是一件事。NSHumanReadableCopyright 里那句
#    "Vistile <版本号> — …" 是纯文本，别忘了顺手改（旧值曾写着"未签名公证"）。
#    线上已发布到 0.1.3 / CFBundleVersion 4，下一版从这里往上加。
VERSION=0.1.4 BUILD=5
for f in Support/Info.plist Support/UITestHarness-Info.plist; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$f"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$f"
done
# 2) 更新 RELEASE_NOTES.md（Release 正文与更新说明的唯一来源），提交
# 3) 打标签并只推这一个
git tag "v$VERSION" && git push origin "v$VERSION"
```

流水线在 [.github/workflows/release.yml](.github/workflows/release.yml)，需要仓库 secrets（缺哪项，verify 任务点名报哪项；构建仍会跑一次未签名自检，发布任务则必须凭据齐才执行，不会悄悄发一个没签名的包）：

| 用途 | secrets |
| --- | --- |
| Developer ID 签名 | `APPLE_DEVELOPER_ID_P12_BASE64`、`APPLE_DEVELOPER_ID_P12_PASSWORD` |
| 公证（二选一） | `APPLE_API_KEY_BASE64` + `APPLE_API_KEY_ID` + `APPLE_API_ISSUER`，或 `APPLE_ID` + `APPLE_TEAM_ID` + `APPLE_APP_SPECIFIC_PASSWORD` |

填在这里：<https://github.com/misswell/Vistile/settings/secrets/actions>。值只经标准输入写进去，别放进命令参数、日志或聊天记录：

```bash
base64 -i developer-id.p12 | gh secret set APPLE_DEVELOPER_ID_P12_BASE64 -R misswell/Vistile
gh secret set APPLE_DEVELOPER_ID_P12_PASSWORD -R misswell/Vistile        # 从标准输入读
```

p12 必须用 **legacy 算法**导出，否则 runner 上 `security import` 会报
`MAC verification failed during PKCS12 import (wrong password?)`——这句骗人，跟口令无关，
是 OpenSSL 3 默认的 AES-256 + SHA256 MAC macOS 钥匙串读不进去：

```bash
openssl pkcs12 -export -legacy \
  -inkey DeveloperID.key -in DeveloperID.cer -certfile DeveloperIDCA.pem \
  -name "Developer ID Application: <你的名字> (<TEAMID>)" \
  -passout file:./pw -out developer-id.p12
```

换 p12 时 `APPLE_DEVELOPER_ID_P12_BASE64` 与 `APPLE_DEVELOPER_ID_P12_PASSWORD` 必须成对更新。
本地验一对密钥与证书是不是配套的（不动登录钥匙串）：`openssl pkey -pubout` 与
`openssl x509 -pubkey` 的指纹一致，再往一个临时钥匙串里 `security import` 试一次。

先花十几秒验证凭据能不能在 runner 上用通，再花几十分钟构建：

```bash
gh workflow run release.yml -R misswell/Vistile -f tag=v9.9.9-dryrun -f probeCredentials=true
```

secrets 还没填时这条会**红**，红在第一步并点名缺哪个键（`缺少 APPLE_DEVELOPER_ID_P12_BASE64`）——那是预期结果，不是流水线坏了；实测见 run [`38774694133`](https://github.com/misswell/Vistile/actions/runs/38774694133)。它不会静默通过，也不会发布任何东西。

发布相关的脚本：`.github/scripts/import_signing_identity.sh`（一次性钥匙串 + 真试签）、`.github/scripts/build_sign_notarize.sh`（构建→签名→公证→装订→出镜像→挂载复核）、`Tools/make_dmg.sh`。

日常改代码不看凭据也能有 CI：`.github/workflows/ci.yml` 在每个 PR 与 `push main` 上跑两条——
核心包 `swift test`、`Vistile` 无签名构建 + `VistileHostTests` 全量宿主测试。它不碰签名与公证 secrets，
也不产安装包；需要屏幕录制或辅助功能才能判定的断言在代码里显式 `XCTSkip`，不在无权限 runner 上假通过。

本机可以先自检除公证之外的每一步（不需要任何凭据）：

```bash
SIGNING_IDENTITY="Apple Development: <你的身份>" RELEASE_TAG=v9.9.9-selfcheck SKIP_NOTARIZE=1 \
  bash .github/scripts/build_sign_notarize.sh
```

`RELEASE_TAG` 别照抄线上已有的版本号：它直接决定 `release/` 里那个 dmg 的文件名，用 `v0.1.3`（当前线上最新）自检会产出一个和线上发布包同名、字节却不同的文件，隔几天回头看会误当「这版已经发过了」。这条我自己踩过（干跑那次的 `v0.1.1` 与真实发布字节完全不同），现在 `verify` 任务在手动触发却用真实版本时会打警告。

它明确跳过 `notarytool` 与依赖公证票据的复核，**跑通不等于公证过**；本机用的 `Apple Development` 身份也不会被算作签名链证据——脚本会在日志里直说「签名链不是 Developer ID Application」。

`spctl` 在这台开发机上不算验证：`spctl --status` 是 `assessments disabled`，连未签名的产物都会被回 `accepted / override=security disabled`。CI 因此先把评估状态打进日志，硬把关只放在与机器设置无关的两处——证书链里的 `Authority=Developer ID Application` 与挂载后对镜像内 `Vistile.app` 的 `stapler validate`。

跑在 `macos-14` runner（系统 macOS 14.8.9）上，自动选用镜像里版本号最高的 Xcode，实测 **Xcode 16.2 / macOS SDK 15.2 / Swift 6.0.3**（默认 `xcodebuild` 是 15.4，不够新）。这比开发机的 Xcode 27 / SDK 27.0 旧，差别是真实的：`Fixtures.records` 里一条嵌着整型除法与 `CGFloat` 乘法的表达式，在 Xcode 27 上编译正常，在 16.2 / Swift 6.0 上直接报「unable to type-check this expression in reasonable time」——第一次未签名自检就抓到了它。

发布说明的唯一来源是仓库根的 `RELEASE_NOTES.md`，CI 直接拿它当 Release 正文；不要在 workflow 里另写一套模板，否则两条路线的话术会分叉。

## 测试

```bash
# 纯逻辑：状态机、格子、坐标、捕获模式、事务与预算
cd Packages/VistileCore && swift test      # 131 项，13 个 suite

# 宿主层：真实控制器 / 内容视图 / CAMetalLayer，目录与几何写入走注入替身
xcodegen generate
xcodebuild -project Vistile.xcodeproj -scheme VistileHostTests \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test   # 80 项
```

覆盖：状态机全部转移与不变量、格子容量与确定性排序、固定槽位不被挤动、坐标翻转往返误差为零、严格等比适配（不裁切不拉伸）、身份匹配（同标题多窗口、PID 复用）、帧信箱只留最新、日志与事务里不含窗口标题与像素；宿主层再加事件转接恰好一次、真实 first responder、present 与 GPU 错误观测、样本附件解析、展开/收回/恢复交错、最小化先解除再写几何、层级与前台只按读回判定。

宿主测试的面板全部摆在主屏之外（`x = -20000`），运行期间用户桌面上不会多出总览窗口；
其中「面板实际成为 key 窗口」依赖系统前台激活，取不到时该用例显式跳过，交给 P0 实机项。

## 运行

```bash
open build/Build/Products/Debug/Vistile.app   # 或 Xcode 里直接运行 Vistile scheme
```

Vistile 是菜单栏常驻应用（`LSUIElement`），没有 Dock 图标。首次启动会进入引导：授予**屏幕录制**（生成实时卡片）与**辅助功能**（放大、移动、恢复真实窗口）。两项缺任一处，卡片会明确标注无画面或不能聚焦，不会用旧帧冒充实时。

默认全局快捷键 **⌃⌥空格**（设置里可换；注册失败时菜单里仍有"打开总览"入口）。

| 操作 | 结果 |
| --- | --- |
| ⌃⌥空格 / 菜单"打开总览" | 每块显示器各出一张总览 |
| 单击卡片 | 该真实窗口放大到近全屏，背景仍是总览 |
| 点击背景空白 | 事件被总览自留，回到总览；不穿透、不触发卡片内控件、不最小化 |
| Esc | 仅在总览持有键盘焦点时生效；有筛选词时先清筛选 |
| 输入字母 | 按窗口名筛选；⌫ 退格 |
| ⌥空格 | 把没排进格子的窗口整理进空位 |

## P0 探针与诊断产物

```bash
open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app
```

**探针要跑在你已经授权过的那个包上。** 屏幕录制与辅助功能记在签名身份上：`/Applications/Vistile.app`（Developer ID + 公证）和仓库里 `build/Build/Products/Debug/Vistile.app`（Apple Development）在 TCC 看来是两个不同的 App，跑后者会再弹一次授权。所以正式验收只用上面这条命令；Debug 产物只在愿意重新授权的机器上用。

同 Developer ID 的覆盖安装**不需要重新授权**（0.1.1→0.1.3 实测：装完直接跑探针，P0-0 仍回「屏幕录制=true，辅助功能=true」），所以升级版本不会逼用户再点一次权限。

探针跑完自动退出（0.1.3 起；0.1.2 及更早的包会写完报告后挂住不退出，见 [Docs/Compatibility.md](Docs/Compatibility.md) §1），产物写在 `~/Desktop/Vistile Diagnostics/`：

- `P0-acceptance-checklist.md` — P0-1…P0-11 结论表（通过 / 失败 / 未测），人工项附复现步骤
- `capability-report.md` / `.json` — 能力验证条目、兼容矩阵、计时、备注
- 会话事务：`~/Library/Application Support/Vistile/session-journal.json`

客观证据只来自进程内事实：mailbox 发布计数、`CGWindowListCopyWindowInfo` 的窗口顺序下标、身份与槽位沿用、键盘焦点归属、状态机不变量、`RendererDiagnostics` 的 present/GPU 错误计数、层级改写次数与真实视图动作计数。"函数返回没报错"从不作为通过条件。

## 测试脚手架

`UITestHarness` 生成可控的原生窗口（含两个同名窗口、一个每 0.2s 变化的计数器窗口、中文输入框、保存面板按钮），用来把"同标题窗口不串、遮挡时仍实时、Sheet 不丢焦点"这类场景变成可重复的输入。

```bash
xcodebuild -project Vistile.xcodeproj -target UITestHarness -derivedDataPath build -configuration Debug build
open build/Build/Products/Debug/UITestHarness.app   # 可用 HARNESS_WINDOWS=12 调整窗口数
```

## 目录

| 路径 | 职责 |
| --- | --- |
| `Packages/VistileCore` | 纯逻辑：状态机、布局、槽位、身份匹配、事务/日志、帧信箱、坐标映射、能力报告模型 |
| `App` | 组装与事件管线、菜单栏、全局快捷键、P0 探针 |
| `Discovery` | `SCShareableContent` + `CGWindowList` + AX 三路目录、AX 观察器、进程启动身份 |
| `Capture` | 每窗口 `SCStream`、Metal 上下文与纹理缓存、预算阶梯与降级 |
| `Rendering` | Metal 合成卡片、纹理池、无障碍元素 |
| `Presentation` | 总览面板/视图、聚焦与过渡代理、设置与引导窗口 |
| `Recovery` | 几何事务存储、启动/退出恢复 |
| `Diagnostics` | 兼容记录器、`os_signpost` 与计数、日志 |
| `Docs` | 架构、兼容矩阵、性能口径、验收说明 |

## 已知限制

- `v0.1.0` 那条资产只有 Apple Development 签名、未公证，换机器装不上；`v0.1.1` 起才是 Developer ID + 公证 + 装订的 `.dmg`。
- 公证包只在一台 Gatekeeper 评估开启的干净 runner 上验过放行，**用户自己的 Mac 与 Intel 机器仍未实测**。
- 过渡动画层（代理窗口能否稳定盖住真实窗口）属于 P0 待验证项，验证前不得视为已完成。
- 全屏 Space、Stage Manager、窗口组、受保护内容（DRM）、不提供 AX 的进程：结构上允许降级为"标注清楚的低频/静态卡片"，但兼容性一律**未测**。
- 撤销权限后必须重启应用才能恢复捕获：这是系统限制，界面上会明说。
- 性能数值只有本机一组，且未覆盖 30 窗口压力场景，不能当作结论。

## 隐私

- 捕获像素只在 GPU/内存里，永不落盘；截图接口只用于已明确标注的低频卡片。
- 事务日志只记录会话 id、进程身份、窗口 id、bundle id、原始/临时 frame、显示器 id 与时间，**不含窗口标题与画面**。
- 只用公开 API：ScreenCaptureKit、ApplicationServices 辅助功能、`CGWindowListCopyWindowInfo`、Carbon `RegisterEventHotKey`。不使用 SkyLight/CGS 私有接口、`_AXUIElementGetWindow`、注入、逐帧全屏截图、H.264 本地预览。
