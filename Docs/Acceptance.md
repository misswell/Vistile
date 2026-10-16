# Vistile 验收说明（P0 门禁）

判据来自方案 §4：**必须用屏幕录制与窗口顺序诊断确认，不能仅凭"返回无错误"通过。**
本文件记录：每一项要看到什么、探针能自动取到什么证据、人工要做什么、以及本机当前结论。

## 1. 结论

**P0 未通过。** 2026-10-16 第一次在授权态跑通探针（权限给的是 `/Applications/Vistile.app`，0.1.1+2，
屏幕录制=true、辅助功能=true），9 个自动项里 **7 通过、2 失败**，两条失败都是真缺陷而不是环境不够：

| 失败项 | 实测事实 | 意味着什么 |
| --- | --- | --- |
| P0-1 目录与身份 | 17 个窗口、多窗口进程 2 个，窗口编号无重复=true，但**同进程 AX 索引无重复=false** | 同一应用里两个窗口解析到同一个 AX 索引，"画面与窗口一一对应"还没有客观保证 |
| P0-3 只提升被点窗口 | Code：目标窗口顺序 #8→#9，同应用另一窗口 #13→#15 | 提升目标时把兄弟窗口一起提了上来，正是方案 §12 要防的那件事 |

这组数据来自 **0.1.1，不含 R09–R11**，所以 P0-3 的失败还不能归因：R10 改的是"前景化只按读回事实判定"，
它可能把这种情况判成失败而不是顺带修好它。下一轮必须在装好新版的正式版上重跑同一场景，
才知道是修好了、还是只是换了个判法。

已得到的正面事实（这些不等于 P0 通过）：

| 事实 | 证据 |
| --- | --- |
| 授权态探针跑完并写出报告 | `capability-report.md`（0.1.1+2，2026-10-16 15:13），无崩溃 |
| 探针退出挂死已修复 | 未授权 + 空目录时 0.1.2 写完报告后不退出（两次复现，主线程停在 `NSApp.terminate` 等 reply）；退出请求改从 run loop 观察点发出后 40 秒自行退出。授权态的 0.1.1 当时能自行退出；修后两条路径都不依赖主队列排空 |
| 遮挡窗口继续收帧（"实时"的客观判据） | P0-2 · 被遮挡的 16 个窗口里 9 个在 1.5s 内收到新帧；全目录帧增量 62 ≈ 40.9 帧/秒 |
| 放大后键盘归目标应用 | P0-4 · 总览面板持有键盘=false，键盘归属=targetApplication（中文输入、Sheet 仍属人工项） |
| 背景点击状态机 soak 不累积副作用 | P0-5 · 真实面板 100 次耗时 4730.0ms，最小化 0→0，2/2 块屏自留事件；结束时阶段=`collapsing` |
| 身份与格子沿用 | P0-6 · 17 个身份沿用、格子变动 0、跨进程启动标识冲突 0 |
| 多显示器覆盖 | P0-7 · 2 块屏，有窗口的屏幕都有承载窗口，缺布局 0 |
| 退出事务恢复 | 「退出恢复 · 会话事务 · 通过 · 未结束事务 0 条」；几何写入 17.9ms，读回偏差 0.0pt |
| 全局快捷键注册 | 「全局快捷键 · ⌃⌥空格 · 已注册」（触发仍需录屏） |
| 纯逻辑层 126 项单元测试通过 | `cd Packages/VistileCore && swift test` |
| 宿主层 80 项测试通过（真实控制器/视图/纹理/AX 替身） | §4 的 `xcodebuild test -scheme VistileHostTests` |
| 每次 PR 与 main 推送都跑上述两层 | `.github/workflows/ci.yml`（无签名凭据） |

**这些都不等于 P0 通过。** 宿主测试全部运行在注入的替身与主屏之外的面板上，
`T01` 里"面板实际成为 key 窗口"这一条依赖系统前台：宿主取不到前台激活时显式 `XCTSkip`
（同一条在本机两种结果都出现过：跳过、通过），因此键盘归属的最终结论仍属 P0 实机项。

## 2. 逐项：判据 / 自动证据 / 人工步骤

| 编号 | 必须观察到的结果 | 探针自动取证 | 人工（肉眼/录屏） |
| --- | --- | --- | --- |
| P0-1 | Safari 两窗 + Finder 两窗 + Terminal + 编辑器，至少 6 个独立完整缩略画面；同应用不串窗 | 目录记录数、`windowID` 唯一性、同进程 AX 索引单射、多窗口应用个数、可读回身份数 | 逐个点卡片，比对卡片画面与放大后的真实窗口是否同一扇 |
| P0-2 | 总览遮住全部源窗口、终端持续输出计数时，卡片计数继续更新；无递归捕获 | 被遮挡窗口 mailbox `publishedCount` 在 1.5s 内的增量、全目录帧速率 | 看卡片是否跟着变；确认 Vistile 自己的窗口没有出现在总览里（自捕获） |
| P0-3 | 点 Safari 指定窗口后，目标原生窗口在总览前，另一个 Safari 窗口不露出 | `CGWindowListCopyWindowInfo` 顺序下标：目标是否上移、同应用兄弟窗口是否未上移、目标是否确实排在兄弟之前 | 录屏确认菜单/浮动面板没被总览压住，也没有别的应用窗口被顺带提升 |
| P0-4 | 中文输入、右键、菜单、另存为 Sheet 都正常，无输入转发 | 通过 `NSWindow.sendEvent` 打真实按下/抬起放大窗口（转接断掉本项直接记未测），再读总览面板是否为 key 窗口、状态机 `keyboardFocus` 归属 | 打「测试」看候选窗跟随真实窗口；右键、拖文本、⌘S 出保存面板、滚动与 ⌘C/⌘V/⌘T |
| P0-5 | 点击背景重复 100 次：回到总览、不最小化源窗口、不点击穿透 | 100 次 `backgroundClicked` 后阶段仍可见、最小化计数不变、每块屏的面板是否自留事件、耗时 | 录屏确认背景按钮没被触发、没有窗口缩进 Dock |
| P0-6 | 开关窗口、同名窗口、应用退出重启：不控制错误窗口、不复用失效 ID | 刷新前后身份沿用数、槽位变动数、跨进程 `windowID` 与启动标识冲突检查 | 两个同名窗口（harness 里有「无标题副本」）逐个操作；退出再启动看格子与尺寸恢复 |
| P0-7 | 两屏、不同缩放与负坐标：位置准确，不把窗口送到屏幕之外 | 显示器数、负坐标屏数、不同缩放种数、有窗口的屏幕是否都有承载面板与布局 | 在副屏放大/收回，确认前景比例按副屏可用区、跨屏拖动后格子不跳 |
| P0-8 | 最小化、权限撤销、应用无响应：显示真实状态、可退出、无无限重试 | 最小化/不可捕获/低频卡片的标注是否与真实更新方式一致；AX 不支持进程名单 | 把窗口丢 Dock 看标注并点卡片（会解除最小化，收回不再塞回 Dock）；系统设置里关掉屏幕录制后重启看提示；卡死一个应用看主线程 |
| P0-9 | 真实鼠标事件就能完成放大与收回，画面上确实有 present 出去 | 视图动作计数恰好 +1（`cardClickCount`/`viewBackgroundClickCount`）、阶段到达受控目标再回总览、同期 `RendererDiagnostics.presents` 增量 > 0、GPU 错误与提交失败增量为 0、最小化计数不变 | 录屏确认放大时屏幕上的窗口就是刚点的那张卡片，收回后回到原格子 |
| P0-10 | 设置里看不到未实现的层级策略；直播流回调期间总览不反复改写窗口层级 | 生效策略必须是已实现的且与持久化值一致（`migratedOrderingStrategy` 记迁移来源）；2s 观察窗内 `orderingApplyCount` 增量为 0（无活跃流时记未测） | 打开设置窗口确认下拉里没有「背景分块避让」；旧持久化值迁移后重启一次，确认不重复迁移 |
| P0-11 | 总览态下点空白不会吞掉后来的 ⌘Tab / 外部应用激活 | 空转背景点击后 `trustedInteraction` 必须为 nil；随后注入外部激活事件，阶段必须转 hidden | 放大窗口后按 ⌘Tab 切走，确认总览自动隐藏、快捷键还能重新打开；打开 Sheet 后点背景，确认对话框不被强关 |

## 3. 层级策略

可选并写入设置的只有两条（`OrderingStrategy.userSelectableCases`）：

| 策略 | 行为 | 实测状态 |
| --- | --- | --- |
| `.normalLevelActivateAndRaise`（默认） | 背景总览保持普通 level，激活目标应用 + 一次 `AXRaise` + 设为 focused window | 未实机验证 |
| `.orderedBelowTarget` | 额外用 `order(.below, relativeTo: 目标窗口编号)` 把总览排到目标之下 | 未实机验证；该调用接受窗口编号不等于承诺跨应用稳定排序 |

`.splitBackgroundTiles`（背景分块避让）**没有实现**：代码里不存在分块窗口、裁剪与命中测试。
它已从用户可见选项中移除，遇到旧持久化值时迁移到 `.normalLevelActivateAndRaise` 并写回，
`migratedOrderingStrategy` 作为诊断事实记进报告（P0-10 验证这条）。
要恢复这个选项，必须先真正实现分块、裁剪、命中测试并过同一兼容矩阵，不能用整屏 normal 面板冒充。

前景化的判定只看读回事实（`FrontOrderingReport`）：AX Raise 返回、`activate` 返回、
目标是否真的是该应用的 focused window、目标进程是否真的前台。**"调用没报错"不算已在前台**；
只有读到相反证据才判定失败并走安全回总览分支，读不到时记"不可确认"。

禁止用来"修补"层级的手段：持续抢焦点、每帧 AX Raise、全局鼠标转发。
若公开接口确实做不到稳定的「背景持续总览 + 前景真实窗口」，要提交系统版本、应用版本、
具体失败路径与复现录屏，**不得把"点击后关闭总览"冒充需求完成**，
也不得用签名、公证或纯逻辑测试通过来给 P0 打勾。

## 4. 怎么跑

```bash
# 1. 生成工程并构建（产物：build/Build/Products/Debug/Vistile.app）
xcodegen generate
xcodebuild -project Vistile.xcodeproj -scheme Vistile \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build build

# 2. 纯逻辑测试（核心包，不依赖 AppKit）
cd Packages/VistileCore && swift test && cd ../..

# 3. 宿主测试：真实控制器/内容视图/CAMetalLayer + 注入的目录与写入替身
xcodebuild -project Vistile.xcodeproj -scheme VistileHostTests \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test

# 4. 造可控窗口（同名副本 + 计数器 + 中文输入框 + 保存面板）
xcodebuild -project Vistile.xcodeproj -target UITestHarness -derivedDataPath build -configuration Debug build
open build/Build/Products/Debug/UITestHarness.app

# 5. 跑探针：只能跑在已经授权的那个包上。屏幕录制与辅助功能记在签名身份上，
#    /Applications/Vistile.app（Developer ID）与仓库里的 Debug 产物（Apple Development）
#    在 TCC 看来是两个不同的 App，跑 Debug 会再弹一次授权。
open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app
```

第 3 步与第 5 步分属两层：宿主测试跑在替身与主屏之外的面板上，探针跑的是真实系统权限、
真实窗口与真实上屏。两者结论不可互相顶替。
Xcode 里也可以直接用共享 scheme **P0Probe**（它已注入 `VISTILE_P0_MODE=1`），但那跑的是 Debug 产物，
需要给 Debug 单独授权；正式验收不要用这条路。

产物：`~/Desktop/Vistile Diagnostics/P0-acceptance-checklist.md`（逐项结论）与 `capability-report.md/.json`（事实、兼容矩阵、计时）。

未授权就跑探针是安全的：权限事实会写进 `P0-0`，依赖权限的项目写成未测，不会伪造通过。
但**授权态才是能出结论的那一组**，未授权产物只能证明代码路径能跑。

## 5. 勾验收时的顺序建议

1. 先授权两项权限，重启应用，跑一次探针 → 看 `P0-1`、`P0-7` 是否从"未测"变成有数据。
2. `P0-9` 必须在有权限的机器上先出结论：它是"事件转接 + 真实上屏"的唯一天然证据，
   `presents` 增量为 0 时后面所有关于画面的结论都没有意义。
3. 再摆遮挡场景（把 Terminal 压在其他窗口下面并持续输出）→ `P0-2` 的 `publishedCount` 必须继续增长，这是"实时"的唯一客观判据。
4. 然后开两个 Safari 窗口 → `P0-3` 看顺序下标 + 录屏；`P0-10` 的 2s 观察窗要在此期间保持总览打开且有直播流。
5. 过 `P0-4` 的四项人工输入、`P0-5` 的 100 次连点录屏、`P0-11` 的 ⌘Tab 与 Sheet 两项人工确认。
6. `P0-8` 的最小化项会真的把那张窗口解除最小化（收回后不再塞回 Dock），跑之前先确认可以接受。
7. 每一项失败请连同 `capability-report.md`、系统版本、复现录屏一起反馈；**"未测"不等于"已修复"**。
