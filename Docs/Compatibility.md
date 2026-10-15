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
| 未证明 | Developer ID 签名链、公证、票据装订、真机 Gatekeeper 放行——缺 secrets，干跑时这些被显式跳过 | — |

同一套脚本在本机用 `Apple Development` 身份跑过 `SKIP_NOTARIZE=1`：镜像里的 app 确实是
`flags=0x10000(runtime)`、证书链走到 Apple Root CA，但 `Authority` 不是 Developer ID Application，
所以这条路不会有票据也不会发布——脚本现在会把这一点直接说出来。

**`spctl` 在这台开发机上不构成证据**：`spctl --status` 是 `assessments disabled`，
连上面那个 adhoc 的干跑产物都会被回 `accepted / override=security disabled`。
CI 复核因此先把评估状态打进日志，硬把关放在两处与机器设置无关的地方——
`codesign -dvvv` 里必须有 `Authority=Developer ID Application`，`stapler validate` 必须有票据
（包括挂载后对镜像里那个 `Vistile.app` 再验一次）。评估开着时 `spctl` 才作为附加证据。

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
- **最小化窗口**：不保留空转流，保留最后一帧，状态写"已最小化"；点卡片应解除最小化后再放大。
- **无屏幕录制权限**：`SCShareableContent` 无窗口可返回，卡片明确写缺少权限、无画面；不会用旧帧或截图冒充。
- **无辅助功能权限**：只做预览，受控聚焦/移动/resize 明确禁用并提示。
- **AX 不支持的进程**：`AXObserverHub.axUnsupportedPIDs` 记录，卡片保留预览、禁用受控聚焦。
- **同标题多窗口**：匹配输入不含标题，靠几何与结构事实打分；无法唯一确定时 `allowsAXWrite = false`，提示"同名窗口无法唯一对应"。
- **PID 复用**：身份含进程启动标识（`proc_pidinfo(PROC_PIDTBSDINFO)`），旧窗口身份不会撞新进程。
- **撤销权限**：系统无法由程序撤销，需要重启应用才能恢复捕获（这是系统限制，界面会说明）。
- **Vistile 自己的窗口**：`registerOwnWindow` 统一排除，阻止无限镜像/自捕获（P0-2 要验证这一点）。

## 4. 怎么把格子填成事实

1. 授权两项权限并重启应用，用 `UITestHarness` 或真实应用把场景摆出来。
2. 跑 `VISTILE_P0_MODE=1 open -n -g -W --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app`（构建时加 `-derivedDataPath build`，见 [Acceptance.md](Acceptance.md) §4）。
3. 每个格子要有对应证据：
   - 捕获 / 恢复 → mailbox `publishedCount` 增长、事务清零记录；
   - 关联 → `P0-1` 的身份唯一性与"画面没有串"录屏；
   - 移动 / resize → AX 读回一致（`geometryVerified`），不是"调用返回 0"；
   - 层级 → `CGWindowListCopyWindowInfo` 顺序下标 + 录屏；
   - Sheet → 另存为面板可见可点、取消后回总览不丢窗口。
4. 把 `capability-report.md` 与录屏一起归档；失败格子写清应用版本、系统版本与复现步骤。
5. 只有拿到证据的格子才允许从"未测"改成"通过/失败"。**代码可编译不代表跨应用交互已验证。**
