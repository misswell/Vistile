# Vistile 架构

本文只描述**已实现的结构**与其不变量。凡是需要真机才能确认的能力，本文一律指向 [Acceptance.md](Acceptance.md)，不在这里当作事实。

## 1. 分层

```
Packages/VistileCore      纯逻辑，无 AppKit / 无框架依赖，可 swift test
  Domain       SessionState / SessionReducer / Events / WindowIdentity / WindowRecord / FocusGeometry
  Layout       GridLayoutEngine / SlotRegistry / CoordinateMapper
  Discovery    WindowSnapshot / WindowMatcher
  Capture      StreamConfig / FrameMailbox
  Recovery     WindowTransaction / SessionJournal
  Diagnostics  CapabilityReport
App layer               只做"把框架事实翻译成核心事件"和"把核心决定翻译成框架调用"
  App          AppMain / AppCoordinator / MenuBarController / GlobalHotKey / P0Probe
  Discovery    WindowCatalog（SC + CG + AX 三路）/ AXObserverHub / AXWindowResolver / ProcessIdentityReader
  Capture      CaptureCoordinator / WindowCaptureSession / MetalContext
  Rendering    OverviewRenderer / ShaderSource / TexturePool / CardAccessibility
  Presentation OverviewWindowController / OverviewPanel / OverviewContentView / FocusCoordinator /
               TransitionProxyWindow / SettingsWindowController / OnboardingWindowController
  Recovery     RecoveryCoordinator / WindowJournalStore
  Diagnostics  CompatibilityRecorder / Metrics / Logger
```

核心层不 import AppKit，因此布局、状态机、身份匹配、事务、信箱都能在单元测试里确定性地跑。宿主层不发明状态：所有跨模块决定都经过 `AppCoordinator` 的事件管线。

## 2. 事件管线

`AppCoordinator.dispatch(_:)` 把 `SessionEvent` 入队，由 `SessionReducer.reduce(&state, event) -> [SessionEffect]` 处理，再按顺序执行 effect。队列保证 effect 里再次派发的同类事件排到后面，不会递归展开。

阶段（`SessionPhase`）：`hidden → preparing → overview ⇄ expanding → focused → collapsing`，另有 `switching`、`suspended(reason)`、`recovering`。

关键事件：`globalShortcut`、`cardClicked`、`backgroundClicked(interaction:)`、`cardDragged`、`organizeRequested`、`searchChanged`、`catalogUpdated(records:generation:reason:)`、`windowClosed`、`windowMinimized`、`windowGeometryChangedExternally(_,_,isUserAction:)`、`geometryWritten`、`geometryVerified`、`geometryRestored`、`captureStarted`、`captureFirstFrame`、`captureStreamFailed`、`captureDowngraded`、`expandRequested`、`expandCompleted(token)`、`collapseCompleted(token)`、`transitionTimedOut(token)`、`focusLost(origin:)`、`permissionLost`、`policyChanged`、`reconcileTick`。

Effect：`discover`、`startCapture`、`stopCapture`、`stopAllCapture`、`showOverview`、`hideOverview`、`writeJournal`、`clearJournal`、`dropJournal`、`expand`、`collapse`、`restoreGeometry`、`restoreAll`、`raiseTarget`、`setKeyboardFocus`、`scheduleReconcile`、`cancelReconcile`、`presentHint`。

三条由 effect 顺序保证的硬规则：

1. **先记日志再动窗口**：`writeJournal` 永远排在 `expand`/`restoreGeometry` 之前，崩溃时事务不丢。
2. **过渡令牌最新者胜**：`TransitionToken` 单调递增，晚到的 `expandCompleted`/`collapseCompleted` 因令牌不符被丢弃，不会出现两段动画抢同一个窗口。
3. **内部点击与外部失焦可区分**：`InteractionToken` 标记总览自己吞掉的背景点击，`focusLost(origin: .otherApplication(...))` 才是用户离开，两者走不同转移。

## 3. 窗口身份与匹配

`WindowIdentity = (processID, processStartIdentity, windowID)`。`processStartIdentity` 由 `proc_pidinfo(PROC_PIDTBSDINFO)` 的进程启动时间提供，因此 PID 被复用后旧窗口身份不会撞上新进程。

`WindowMatcher` 只比较几何与结构事实（尺寸、位置、层次、AX 子角色、同进程候选数），按 `MatchWeights`/`MatchThresholds` 打分；唯一得分够高才写 `resolvedAXIndex`。同名多窗口不靠标题区分：**标题从不进入匹配输入**。歧义时 `confidence.allowsAXWrite = false`，受控聚焦被明确禁用并提示"同名窗口无法唯一对应"，只保留预览。

目录把记录、SC 句柄表、AX 句柄表作为**同一个 generation** 一起发布（`WindowCatalog.publish`），消费方不会拿到跨代次的窗口对象；晚到的捕获回调靠 mailbox generation 判定并丢弃。

## 4. 发现：三路公开 API

| 来源 | 提供 | 用途 |
| --- | --- | --- |
| `SCShareableContent` | 可捕获窗口、所属应用 | 建立捕获目标；本 SDK 的 `SCWindow` 不提供 `windowType`，不用于过滤桌面元素 |
| `CGWindowListCopyWindowInfo` | layer、alpha、`kCGWindowSharingState`、窗口顺序 | 过滤桌面元素与 Dock 层；补齐 SC 未列出但存在的窗口（标记为不可捕获）；P0 的窗口顺序证据 |
| Accessibility（`AXUIElementCopyAttributeValue` 等公开属性/动作） | 位置、尺寸、最小化、`AXRaise`、焦点窗口 | 唯一确认后读写真实窗口几何 |

`AXObserverHub` 用公开观察器订阅窗口移动/缩放/最小化，事件在 `AXExecutor` 上串行执行，单次调用 0.35s 超时；不支持 AX 的进程记入 `axUnsupportedPIDs`，其卡片只保留预览并明确标注。读写之后一律**读回校验**（`AXWindowResolver.apply(frame:)` 比较读回值），不一致标记 `partial`/`failed` 并保留可重试，绝不假装成功。

## 5. 捕获与预算

`CaptureCoordinator`（`@MainActor`）维护 `identity → session` 与 `identity → mailbox` 两张表：一个窗口最多一路流。启动并发上限 2，软上限 12（未校准前是保守起点，见 Performance.md）。帧在 `sampleQueue` 上转成 `MetalFrame` 后写入 `FrameMailbox`。

`FrameMailbox` 容量 1：只保留最新帧，写入即替换，`publishedCount/replacedCount/staleCount` 是 P0-2「遮挡时仍实时」的客观依据。纹理与其 `CVMetalTexture` 引用一起存活，command buffer 完成前不释放。

`StreamConfig.build(cellWidth:backingScale:sourceSize:tier:...)` 由格子尺寸反推输出像素宽度，不会按源窗口全尺寸取流。层级：`balanced` 8fps、`powerSaving` 3fps、`refreshPriority` 15fps（都是上限，不是承诺）。

预算阶梯 `BudgetAction`：`keep → lowerFPS → lowerOutputWidth → poll(intervalMilliseconds)`，加/降都带滞后时间与"动画期间不逐帧改配置"的规则；`poll` 卡片由 `SCScreenshotManager` 单次取图，`displayedPhase` 明确是 `.lowFrequency`，界面上显示真实间隔，**不标成实时**。最小化、不可捕获、无权限同样保留最后一帧并各自标注状态。

## 6. 渲染

单设备、单命令队列、单 `CVMetalTextureCache`（`MetalContext`）被所有卡片共享。`OverviewRenderer` 每帧一个 command buffer，逐卡片设置 `MTLViewport` 后绘制；内容矩形由 `aspectFit` 计算，UV 子矩形由 `TexturePool.uvRect(contentRect:pixelSize:)` 得出——**等比适配，不裁切、非均匀拉伸在几何上不可能发生**，这一点由单元测试锁死。

着色器是内联 MSL，用 `makeLibrary(source:)` 运行时编译（不给预览管线引入 shader target）。顶点常量数组必须放在函数外：MSL 不允许函数体内的自动变量带 `constant` 地址空间。

坐标只有一个翻转点：`CoordinateMapper` 以 CG 全局坐标（左上原点）为领域表示，视图侧 `isFlipped = false`，`OverviewContentView` 用 `originInCG` 做一次性换算。往返误差为零由测试保证；负坐标屏与上下排列屏不需要特例。

卡片装饰（标题条、边框、状态文字）走 CALayer，画面走 CAMetalLayer，`zPosition` 排序。无障碍由 `CardAccessibilityBuilder` 从视图当前的描述符生成 `NSAccessibilityElement` 子元素，动作以公开 `NSAccessibilityCustomAction("展开窗口")` 暴露——**没有私有 API，也没有自造状态**。

## 7. 放大、收回与几何事务

点卡片 → `expandRequested`：先 `writeJournal` 记录原 frame，再由 `FocusCoordinator` 通过 AX 写临时 frame（近全屏，比例来自设置，默认 0.86×0.88）+ `raiseTarget` + 激活目标应用，同时 `TransitionProxyWindow` 用 Metal 把卡片画面从格子矩形插值到目标矩形，与真实窗口到位做短交叉淡化。代理窗口 `ignoresMouseEvents = true`、`canBecomeKey = false`，不接管输入。

插值容器 + 等比内容 + 短交叉淡化三者共同保证动画过程中也不变形。到位判据是 AX 读回一致，不是"调用返回成功"。

点击背景空白由总览面板自留（`OverviewPanel` 覆写命中测试，卡片内控件不会被第二下触发），状态机走 `backgroundClicked` → 回总览；**不最小化、不穿透、不切换应用**。"点背景卡片切换"默认关闭。

`WindowTransaction` 记 (identity, originalFrame, provisionalFrame, displayID, sessionID, 时间)。`RecoveryCoordinator.restoreOnQuit()` 在正常退出时逐条恢复并读回校验；未确认恢复的事务保留到下次启动，由 `restoreOnLaunch(recorder:)` 先于新会话处理，两条路径不同时写几何。用户选择"保留本次尺寸"时按其意愿跳过恢复。

## 8. 前台与键盘

总览面板从不抢走目标窗口的键盘：放大完成后 `setKeyboardFocus(.targetApplication)`，探针用"面板是否仍是 key 窗口 + 状态机键盘归属"作为客观证据（P0-4）。中文输入、右键、菜单栏、保存面板、滚动、快捷键都落在真实窗口里，因为放大的是真实窗口本身，而不是它的录像。

全局快捷键只用 Carbon `RegisterEventHotKey`；注册失败时如实报告并给菜单入口（`GlobalHotKey.failureHint`）。

## 9. 隐私与安全边界

- 像素只在 GPU/内存，永不落盘，也不写进诊断。
- 事务与报告只含会话 id、进程身份、窗口 id、bundle id、原始/临时 frame、显示器 id、时间与结论文字；**不含窗口标题**（有单元测试专门验证日志内容不含标题正文）。
- 只用公开 API。禁止清单（代码里不会出现）：SkyLight/CGS 私有接口、`_AXUIElementGetWindow`、注入、逐帧全屏截图、H.264 本地预览、Electron/WebView 冒充预览。
- 连续抢焦点、逐帧 Raise、全局鼠标转发都被结构性排除：Raise 只在展开时一次；焦点变化只作事件输入。

## 10. 尚未证明的部分

P0-1…P0-8 需要真机录屏与肉眼确认；本机两次探针运行因为系统权限未授予（`屏幕录制=false，辅助功能=false`）而把大部分自动项记为未测或阻塞。兼容矩阵除"进程能起、探针能跑完、退出恢复事务清零"之外全部是未测。TransitionProxy 的稳定遮挡、全屏 Space 与 Stage Manager 行为、30 窗口下的性能曲线都属于未验证能力。
