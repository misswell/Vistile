# Vistile 兼容矩阵

方案 §15：**没有测试的格子写"未测"，不要填"支持"。**
本表当前**全部为未测**：本机两次探针运行时屏幕录制与辅助功能都未授予，没有任何跨应用交互被观察过。
逐格填写方式见文末；`~/Desktop/Vistile Diagnostics/capability-report.md` 里的同名表格是权威来源，本文只是待填清单与口径说明。

## 1. 测试环境（唯一有记录的一组）

| 项 | 值 |
| --- | --- |
| 系统版本 | macOS 27.0.1 |
| 硬件 | Apple M1，arm64，8 逻辑核，16GB |
| 应用版本 | Vistile 0.1.0+1（Debug，Apple Development 签名，未公证） |
| 显示器 | 2 块（含 1 块负坐标、2 种缩放） |
| 权限 | 屏幕录制 未授予 / 辅助功能 未授予 |
| 结果 | 目录为空，探针跑完并正常退出，未结束事务 0 条 |

### 1.1 发布产物的构建环境（CI，不是运行环境）

| 项 | 值 | 来源 |
| --- | --- | --- |
| Runner 镜像 | `macos-14`，系统 macOS 14.8.9 | run [`38773723973`](https://github.com/misswell/Vistile/actions/runs/38773723973) 日志 |
| 构建用 Xcode | 16.2（Build 16C5032a，`/Applications/Xcode_16.2.0.app`；取镜像里装得最高的那个，默认 `xcodebuild` 是 15.4） | 同上，脚本内 `==> 工具链：` 一行 |
| macOS SDK | **15.2** | `xcrun --sdk macosx --show-sdk-version`，与产物 `otool -l` 的 `LC_BUILD_VERSION sdk 15.2` 一致 |
| 部署目标 | `minos 14.0`（`arm64-apple-macosx14.0`，Swift 6.0.3） | 同上：解出的二进制 `otool -l` |
| 产物架构 | `arm64` 单架构，从上传的 dmg 里解出 app 实测 `lipo -archs` | 同上 |
| bundle id | `com.misswell.Vistile`（解包读 `Info.plist` 实测） | 同上 |
| 干跑产物的签名实况 | `flags=0x20002(adhoc,linker-signed)`、无票据、`stapler validate` 报 "does not have a ticket" | 下载 run 38773467420 的 dmg 实测 |
| 已证明 | 未签名干跑通过：76 项测试在 Swift 6.0.3 下全绿、App 用 SDK 15.2 编过、dmg 能挂载、镜像里的 app 是 arm64 单架构 | 同上 |
| 已证明（负向） | 零凭据时 `probeCredentials` 红在第一步并报出缺的键名（`缺少 APPLE_DEVELOPER_ID_P12_BASE64`），不静默通过、不发布 | run [`38774694133`](https://github.com/misswell/Vistile/actions/runs/38774694133) |
| 已证明（签名与公证） | Developer ID 身份导入并试签通过；`.app` 与 `.dmg` 各自公证后 `stapler` 都回 "The staple and validate action worked!"；挂载后镜像里的 `Vistile.app` 票据仍有效；`flags=0x10000(runtime)`；`lipo -archs` 仍是 `arm64` | run [`38827757461`](https://github.com/misswell/Vistile/actions/runs/38827757461) |
| 已证明（Gatekeeper） | **runner 上 `spctl --status` 是 `assessments enabled`**，`spctl -a -t exec` 对构建产物和挂载出来的 app 都回 `accepted` / `source=Notarized Developer ID`——这是一台评估开启的干净 arm64 机器给出的放行结论。**但 `accepted` 本身不证明票据在镜像里**：联网时在线查询会替无票据的包补上上下文，分得开的只有挂载后对包内 app 跑 `stapler validate`（下一行） | 同上，以及发布那次 run [`38828073929`](https://github.com/misswell/Vistile/actions/runs/38828073929) |
| 已证明（发布字节） | 从 Release 页重新下载的 `Vistile_v0.1.1_macos_arm64.dmg`（1164713 字节，`sha256 01646765…97760`）挂载后：dmg 与镜像内 app 的票据都 `The staple and validate action worked!`，`Authority=Developer ID Application`，`flags=0x10000(runtime)`，`arm64` 单架构 | 本机对下载文件实测 |
| Apple 侧公证记录 | 按名字过滤后共 **4 条，两对**，每对都是一条 `.notarization.zip`（`.app` 本体）早于一条 `.dmg`：00:09:58→00:10:21（干跑）与 00:13:56→00:14:26（发布那次），四条全 `Accepted`。只剩 dmg 就等于 `.app` 从没提交给 Apple，所以「成对且 zip 在前」这一条要看，不能只看 dmg | `xcrun notarytool history` 本机按名字过滤实测 |
| 修的那处真进了发出去的包 | 标签 `v0.1.1` → `804e24f`，发布任务 `SOURCE_REF: v0.1.1`，而 `.p8` 落盘顺序修复 `64c6635` 是 `804e24f` 的祖先（`git merge-base --is-ancestor` 实测通过）。`main` 只比标签多一个文档提交 `52794fb` | 本机 git 查询 + run [`38828073929`](https://github.com/misswell/Vistile/actions/runs/38828073929) 的 env 行 |
| 反面教材（已防呆） | 干跑那次手动触发了真实标签 `v0.1.1`，产出的 `Vistile_v0.1.1_macos_arm64.dmg` 与线上发布的同名文件**字节完全不同**（干跑 `1410db98…0a3f3a` / 发布 `01646765…97760`）。workflow 的 `workflow_dispatch.tag` 现在要求填测试标签，`verify` 任务在标签等于 `Info.plist` 版本时打 `::warning::` 并写进 job summary——不硬拦，因为「重发同一版」是合法兜底路线 | 两次 run 的 artifact 各自 `shasum -a 256` |
| 已证明（当前测试面） | 核心包 126 项纯逻辑测试 + 宿主层 80 项测试（真实控制器/内容视图/CAMetalLayer，目录与写入走注入替身）在本机通过；宿主里「面板实际成为 key 窗口」一条依赖系统前台，取不到时显式 skip（本机两种结果都出现过：跳过、通过）；CI 已在 `pull_request` 与 `push main` 上跑同样两条（`.github/workflows/ci.yml`，不需要任何签名凭据） | 本机 Xcode 27 / SDK 27.0，2026-10-16，命令见 [Acceptance.md](Acceptance.md) §4 |
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

| 应用 | 版本 | 捕获 | 关联 | 移动 | resize | 层级 | Sheet | 恢复 | 已知限制 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Finder（桌面 + 浏览器窗） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Safari | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Terminal | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 文本编辑 TextEdit | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 备忘录 Notes | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 预览 Preview | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Mail | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 系统设置 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Google Chrome | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Visual Studio Code | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Xcode | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Electron 类（Slack/微信/钉钉） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 视频播放（IINA/VLC/AVPlayer） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 受保护内容（Apple Music、DRM 视频） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 全屏 Space 中的窗口 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Stage Manager 窗口组 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| Catalyst / iOS-on-Mac 应用 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| 无 AX 支持的进程 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |
| UITestHarness（脚手架，可控场景） | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 | 未测 |

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
2. 跑 `open -n -g -W --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app`（构建命令与宿主测试见 [Acceptance.md](Acceptance.md) §4）。
3. 每个格子要有对应证据：
   - 捕获 / 恢复 → mailbox `publishedCount` 增长、事务清零记录；
   - 关联 → `P0-1` 的身份唯一性与"画面没有串"录屏；
   - 移动 / resize → AX 读回一致（`geometryVerified`），不是"调用返回 0"；
   - 层级 → `CGWindowListCopyWindowInfo` 顺序下标（`P0-3`）+ focused window / 前台进程读回（`P0-9` 的展开路径）+ 录屏；
   - 上屏 → `P0-9` 的 `RendererDiagnostics.presents` 增量与 GPU 错误计数；
   - Sheet → 另存为面板可见可点、取消后回总览不丢窗口。
4. 把 `capability-report.md` 与录屏一起归档；失败格子写清应用版本、系统版本与复现步骤。
5. 只有拿到证据的格子才允许从"未测"改成"通过/失败"。**代码可编译不代表跨应用交互已验证。**
