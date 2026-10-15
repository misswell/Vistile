# Vistile

把系统中所有符合条件的窗口，按固定格子渲染成实时缩略图总览；点击卡片时，**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景任意空白处回到总览。收回过程绝不最小化窗口，临时改过的窗口几何会在退出时恢复。

> **当前状态：功能实现完成、可构建、可运行；P0 能力门禁尚未通过。**
> P0 需要真机录屏与肉眼验收，而验收人是你。任何"未测"格子都不表示可用。
> 详见 [Docs/Acceptance.md](Docs/Acceptance.md) 与 [Docs/Compatibility.md](Docs/Compatibility.md)。

仓库：<https://github.com/misswell/Vistile>

```bash
git clone https://github.com/misswell/Vistile.git
```

Release 页附带本机可用的 `Vistile-0.1.0-arm64-devsigned.zip`。它只有 Apple Development 签名、未做 Developer ID 与公证，换一台机器会被 Gatekeeper 拦下；其它机器请按下面的命令自行构建。

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

签名：Manual + `Apple Development`（团队 `U8U443D7ZL`），未做 Developer ID 与公证，产物只能在本机运行。

## 测试

```bash
cd Packages/VistileCore && swift test      # 76 项单元测试，9 个 suite
```

覆盖：状态机全部转移与不变量、格子容量与确定性排序、固定槽位不被挤动、坐标翻转往返误差为零、严格等比适配（不裁切不拉伸）、身份匹配（同标题多窗口、PID 复用）、帧信箱只留最新、日志与事务里不含窗口标题与像素。

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
VISTILE_P0_MODE=1 open -n -g -W --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app
```

探针跑完自动退出，产物写在 `~/Desktop/Vistile Diagnostics/`：

- `P0-acceptance-checklist.md` — P0-1…P0-8 结论表（通过 / 失败 / 未测），人工项附复现步骤
- `capability-report.md` / `.json` — 能力验证条目、兼容矩阵、计时、备注
- 会话事务：`~/Library/Application Support/Vistile/session-journal.json`

客观证据只来自进程内事实：mailbox 发布计数、`CGWindowListCopyWindowInfo` 的窗口顺序下标、身份与槽位沿用、键盘焦点归属、状态机不变量。"函数返回没报错"从不作为通过条件。

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

- 未做 Developer ID 签名与公证：换机器需要重新构建，且 Gatekeeper 会拦。
- 过渡动画层（代理窗口能否稳定盖住真实窗口）属于 P0 待验证项，验证前不得视为已完成。
- 全屏 Space、Stage Manager、窗口组、受保护内容（DRM）、不提供 AX 的进程：结构上允许降级为"标注清楚的低频/静态卡片"，但兼容性一律**未测**。
- 撤销权限后必须重启应用才能恢复捕获：这是系统限制，界面上会明说。
- 性能数值只有本机一组，且未覆盖 30 窗口压力场景，不能当作结论。

## 隐私

- 捕获像素只在 GPU/内存里，永不落盘；截图接口只用于已明确标注的低频卡片。
- 事务日志只记录会话 id、进程身份、窗口 id、bundle id、原始/临时 frame、显示器 id 与时间，**不含窗口标题与画面**。
- 只用公开 API：ScreenCaptureKit、ApplicationServices 辅助功能、`CGWindowListCopyWindowInfo`、Carbon `RegisterEventHotKey`。不使用 SkyLight/CGS 私有接口、`_AXUIElementGetWindow`、注入、逐帧全屏截图、H.264 本地预览。
