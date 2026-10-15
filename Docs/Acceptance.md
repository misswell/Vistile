# Vistile 验收说明（P0 门禁）

判据来自方案 §4：**必须用屏幕录制与窗口顺序诊断确认，不能仅凭"返回无错误"通过。**
本文件记录：每一项要看到什么、探针能自动取到什么证据、人工要做什么、以及本机当前结论。

## 1. 结论

**P0 未通过。** 本机两次探针运行时系统权限均未授予（`屏幕录制=false，辅助功能=false`），
所有依赖真实窗口的项目被记为 **未测** 或 **阻塞**，没有任何一项被声明为通过。

已得到的正面事实（这些不等于 P0 通过）：

| 事实 | 证据 |
| --- | --- |
| 进程能启动、探针能跑完并自动退出 | `capability-report.md` 时间线，无崩溃 |
| 退出路径走完事务恢复 | 「退出恢复 · 会话事务 · 通过 · 未结束事务 0 条」 |
| 全局快捷键注册成功 | 「全局快捷键 · ⌃⌥空格 · 已注册」（触发仍需录屏） |
| Metal 设备与纹理缓存建立 | 「Metal 渲染 · 设备与纹理缓存已建立」 |
| 显示器事实与捕获权限无关 | 「P0-7 · 显示器 2 块（负坐标 1 块，不同缩放 2 种）」 |
| 背景点击状态机 soak 不累积副作用 | 100 次 2.0ms（授权后需连真实面板重跑） |
| 纯逻辑层 76 项单元测试通过 | `swift test` |

## 2. 逐项：判据 / 自动证据 / 人工步骤

| 编号 | 必须观察到的结果 | 探针自动取证 | 人工（肉眼/录屏） |
| --- | --- | --- | --- |
| P0-1 | Safari 两窗 + Finder 两窗 + Terminal + 编辑器，至少 6 个独立完整缩略画面；同应用不串窗 | 目录记录数、`windowID` 唯一性、同进程 AX 索引单射、多窗口应用个数、可读回身份数 | 逐个点卡片，比对卡片画面与放大后的真实窗口是否同一扇 |
| P0-2 | 总览遮住全部源窗口、终端持续输出计数时，卡片计数继续更新；无递归捕获 | 被遮挡窗口 mailbox `publishedCount` 在 1.5s 内的增量、全目录帧速率 | 看卡片是否跟着变；确认 Vistile 自己的窗口没有出现在总览里（自捕获） |
| P0-3 | 点 Safari 指定窗口后，目标原生窗口在总览前，另一个 Safari 窗口不露出 | `CGWindowListCopyWindowInfo` 顺序下标：目标是否上移、同应用兄弟窗口是否未上移、目标是否确实排在兄弟之前 | 录屏确认菜单/浮动面板没被总览压住，也没有别的应用窗口被顺带提升 |
| P0-4 | 中文输入、右键、菜单、另存为 Sheet 都正常，无输入转发 | 放大后总览面板是否为 key 窗口、状态机 `keyboardFocus` 归属 | 打「测试」看候选窗跟随真实窗口；右键、拖文本、⌘S 出保存面板、滚动与 ⌘C/⌘V/⌘T |
| P0-5 | 点击背景重复 100 次：回到总览、不最小化源窗口、不点击穿透 | 100 次 `backgroundClicked` 后阶段仍可见、最小化计数不变、每块屏的面板是否自留事件、耗时 | 录屏确认背景按钮没被触发、没有窗口缩进 Dock |
| P0-6 | 开关窗口、同名窗口、应用退出重启：不控制错误窗口、不复用失效 ID | 刷新前后身份沿用数、槽位变动数、跨进程 `windowID` 与启动标识冲突检查 | 两个同名窗口（harness 里有「无标题副本」）逐个操作；退出再启动看格子与尺寸恢复 |
| P0-7 | 两屏、不同缩放与负坐标：位置准确，不把窗口送到屏幕之外 | 显示器数、负坐标屏数、不同缩放种数、有窗口的屏幕是否都有承载面板与布局 | 在副屏放大/收回，确认前景比例按副屏可用区、跨屏拖动后格子不跳 |
| P0-8 | 最小化、权限撤销、应用无响应：显示真实状态、可退出、无无限重试 | 最小化/不可捕获/低频卡片的标注是否与真实更新方式一致；AX 不支持进程名单 | 把窗口丢 Dock 看标注；系统设置里关掉屏幕录制后重启看提示；卡死一个应用看主线程 |

## 3. 层级策略

默认：**普通 level 的背景总览 + 激活目标应用 + 一次 `AXRaise`**（`SettingsModel.orderingStrategy = .normalLevelActivateAndRaise`）。
备选（同一测试矩阵下验证，不当作默认后门）：**分割成围绕目标矩形的多块背景承载窗口**（`.splitBackgroundTiles`），使背景不覆盖目标区域；提升 level 可能遮挡菜单、拖拽与辅助窗口，因此仍需录屏确认。
`order(.below, relativeTo:)` 接受窗口编号不等于承诺跨应用稳定排序，需按目标系统版本实测。

禁止用来"修补"层级的手段：持续抢焦点、每帧 AX Raise、全局鼠标转发。若两种公开方案都做不到核心交互，要提交具体应用/系统版本/复现视频与阻塞原因，**不得把"点击后关闭总览"冒充需求完成**。

## 4. 怎么跑

```bash
# 1. 生成工程并构建（产物：build/Build/Products/Debug/Vistile.app）
xcodegen generate
xcodebuild -project Vistile.xcodeproj -scheme Vistile \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build build

# 2. 单元测试
cd Packages/VistileCore && swift test

# 3. 造可控窗口（同名副本 + 计数器 + 中文输入框 + 保存面板）
xcodebuild -project Vistile.xcodeproj -target UITestHarness -derivedDataPath build -configuration Debug build
open build/Build/Products/Debug/UITestHarness.app

# 4. 先授予权限（系统设置 → 隐私与安全性 → 屏幕录制 / 辅助功能），再跑探针
VISTILE_P0_MODE=1 open -n -g -W --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app
```

产物：`~/Desktop/Vistile Diagnostics/P0-acceptance-checklist.md`（逐项结论）与 `capability-report.md/.json`（事实、兼容矩阵、计时）。

未授权就跑探针是安全的：权限事实会写进 `P0-0`，依赖权限的项目写成未测，不会伪造通过。

## 5. 勾验收时的顺序建议

1. 先授权两项权限，重启应用，跑一次探针 → 看 `P0-1`、`P0-7` 是否从"未测"变成有数据。
2. 再摆遮挡场景（把 Terminal 压在其他窗口下面并持续输出）→ `P0-2` 的 `publishedCount` 必须继续增长，这是"实时"的唯一客观判据。
3. 然后开两个 Safari 窗口 → `P0-3` 看顺序下标 + 录屏。
4. 最后过 `P0-4` 的四项人工输入与 `P0-5` 的 100 次连点录屏。
5. 每一项失败请连同 `capability-report.md`、系统版本、复现录屏一起反馈；**"未测"不等于"已修复"**。
