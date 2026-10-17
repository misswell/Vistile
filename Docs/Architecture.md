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

`AXObserverHub` 用公开观察器订阅窗口移动/缩放/最小化，事件在 `AXExecutor` 上串行执行，单次调用 0.35s 超时；不支持 AX 的进程记入 `axUnsupportedPIDs`，其卡片只保留预览并明确标注。几何写入全部走 `AXWindowResolver.apply(frame:)` 的**写后读回**判定：读回在容差内即 `exact`——**错误码不许覆盖读回证据**（实机有 Chrome 位置写入报 -25204、读回已在目标位的反例）；写回值与写前不同判 `constrained`；读不到先做有界重试（3 次、间隔 70ms，应用刚被改几何时 AX 会短暂忙），重试仍读不到才判 `unreadable`；`rejected` 只在窗口明确拒绝且读回可证时成立。非 `exact` 的恢复写入一律保留事务、绝不假装成功。

## 5. 捕获与预算

`CaptureCoordinator`（`@MainActor`）维护 `identity → session` 与 `identity → mailbox` 两张表：一个窗口最多一路流。启动并发上限 2，软上限 12（未校准前是保守起点，见 Performance.md）。帧在 `sampleQueue` 上转成 `MetalFrame` 后写入 `FrameMailbox`。

### 5.1 捕获需求按可见性分级

`CaptureDemand` 不再只有"要不要流"，而是五级用途：`transition / visible / prefetch / offscreen / paused`（[CaptureModes.swift:26](../Packages/VistileCore/Sources/VistileCore/Capture/CaptureModes.swift#L26)）。排序规则是**先按可见性等级，再在等级内按用户固定优先级**：飞行交接所需 → 当前可见卡片 → 相邻一屏内的预取 → 离屏卡片；不可捕获/最小化/无权限这类硬限制仍然压过一切（等级只是排队意向，不是许可）。

升降档各带一条滞后线（[CaptureModes.swift:102](../Packages/VistileCore/Sources/VistileCore/Capture/CaptureModes.swift#L102)）：可见/过渡目标要回到实时档，必须等**总需求整体回落到软上限减滞后量以下**（[:128](../Packages/VistileCore/Sources/VistileCore/Capture/CaptureModes.swift#L128)）。这条是修出来的缺陷：原先 `mayRestore` 数的是全体候选，离屏卡片一多就永远卡在"目标太多"，可见流被离屏数量饿住、恢复不了直播。现在离屏可以晚降级、可见必须早恢复。

尺寸重配的抑制条件统一成 `TransitionActivity`（focus 代理、模式过渡、主副交换、布局落定、取消收尾都往同一结构里写），不再各自读 `focus.isAnimating`。抑制的只有"可延后的重配"：取消/停止请求立刻生效，不排队（A36）。滚动按显示周期合并成最新意图，一个周期内多次 delta 只留最后一份，可见项每个周期都拿到调度机会（A35）。

`FrameMailbox` 容量 1：只保留最新帧，写入即替换，`publishedCount/replacedCount/staleCount` 是 P0-2「遮挡时仍实时」的客观依据。纹理与其 `CVMetalTexture` 引用一起存活，command buffer 完成前不释放。slot 移动不等于 identity 消失：资源按 identity 存续，滚出视口不立刻删最后一帧的纹理，窗口关闭或会话结束才按 owner 释放；代理动画引用纹理时先解除引用再释放缓存，避免来源切换那一帧拿到空纹理。

`StreamConfig.build(cellWidth:backingScale:sourceSize:tier:...)` 由格子尺寸反推输出像素宽度，不会按源窗口全尺寸取流。层级：`balanced` 8fps、`powerSaving` 3fps、`refreshPriority` 15fps（都是上限，不是承诺）。

预算阶梯 `BudgetAction`：`keep → lowerFPS → lowerOutputWidth → poll(intervalMilliseconds)`，加/降都带滞后时间与"动画期间不逐帧改配置"的规则；`poll` 卡片由 `SCScreenshotManager` 单次取图，`displayedPhase` 明确是 `.lowFrequency`，界面上显示真实间隔，**不标成实时**。最小化、不可捕获、无权限同样保留最后一帧并各自标注状态。

## 6. 渲染

单设备、单命令队列、单 `CVMetalTextureCache`（`MetalContext`）被所有卡片共享。`OverviewRenderer` 每帧一个 command buffer，逐卡片设置 `MTLViewport` 后绘制；内容矩形由 `aspectFit` 计算，UV 子矩形由 `TexturePool.uvRect(contentRect:pixelSize:)` 得出——**等比适配，不裁切、非均匀拉伸在几何上不可能发生**，这一点由单元测试锁死。

着色器是内联 MSL，用 `makeLibrary(source:)` 运行时编译（不给预览管线引入 shader target）。顶点常量数组必须放在函数外：MSL 不允许函数体内的自动变量带 `constant` 地址空间。

坐标只有一个翻转点：`CoordinateMapper` 以 CG 全局坐标（左上原点）为领域表示，视图侧 `isFlipped = false`，`OverviewContentView` 用 `originInCG` 做一次性换算。往返误差为零由测试保证；负坐标屏与上下排列屏不需要特例。

卡片装饰（标题条、边框、状态文字）走 CALayer，画面走 CAMetalLayer，`zPosition` 排序。无障碍由 `CardAccessibilityBuilder` 从视图当前的描述符生成 `NSAccessibilityElement` 子元素，动作以公开 `NSAccessibilityCustomAction("展开窗口")` 暴露——**没有私有 API，也没有自造状态**。

## 7. 模式过渡与几何事务

两种模式：`.overview`（每屏全屏总览：全部窗口的固定格子实时缩略图，`activeMain == nil`）与 `.workbench`（主窗口＋L 型预览栏）。每次启动都从总览开始，只有点击卡片才进入工作台；进入与返回都由 `WorkbenchReducer` 的单一状态机驱动（阶段 `.overview → .expanding → .focused → .collapsing`），过渡令牌化、可打断——新令牌作废旧过渡，锁屏/退屏/退出由系统级恢复接管（方案 §4、§10.4）。

**进入（`enteringWorkbench`）**：先冻结总览快照、写事务日志（被点窗口的原 frame），再把**被点窗口**带进主区（`FocusGeometry.dockedRect`，比例来自设置；自身不可调整尺寸的窗口按其当前尺寸对中）；其余窗口的真实几何**一个都不动**，作为背景留在原地。L 型栏由两个 `WorkbenchWindowController` 面板绘制（顶栏＋侧栏），栏内预览卡片从各自总览格子动画到确定的 slot rect（`railHandoffs`）——这是视图层的空间变化，不是真实窗口的移动。成功后撤下全屏总览面板；失败把已写入的几何补偿回原 frame、状态机退回总览，并把补偿结果同步回报给状态机（`geometryRestoreSettled`），绝不留下半套 L 型或空白主区。

**L 型内 A/B 交换（`mainSwitch`）**：只有两个窗口的真实几何会动——被点卡片进主区、原主回到自己进入工作台前的 frame；其余窗口与两条栏的滚动偏移、占用都不变（方案 §6.1 硬不变量）。写入同样日志先行、逐窗读回；失败整体回滚。

**返回（`returningOverview`）**：主窗口写回进入前的 frame（从哪来回哪去），状态机清 `activeMain`，总览面板按保存的快照重现（格子、搜索词、滚动位置不变）。

**窗口被手动改过尺寸**：`WindowTransaction` 记 (identity, originalFrame, provisionalFrame, displayID, sessionID, 时间)。用户在主区自己 resize 过的窗口按"保留本次尺寸"处理，恢复时按其意愿跳过。`RecoveryCoordinator.restoreOnQuit()` 在正常退出时逐条恢复并读回校验；未确认恢复的事务保留到下次启动，由 `restoreOnLaunch(recorder:)` 先于新会话处理，两条路径不同时写几何。

### 7.1 一条调度通道：所有权、取消与补偿时序、状态与日志边界

上面每一段说的"写入"现在都只有一条路：[`GeometryOperationScheduler`](../Presentation/GeometryOperationScheduler.swift)（`Presentation/GeometryOperationScheduler.swift`）。它把**准入 → 排队 → 执行 → 结算**收进一条按 identity 串行的通道，取代原先各处自己起 `Task`/`tail` 链的写法——旧写法里"取消"只能翻转一个布尔标志，已经排进 AX 队列的命令照样执行。

- **身份**：每个操作带 `GeometryOperationContext`（sessionID + epoch + token + 操作类型）。代次只由状态机推进、经 `adopt(sessionID:epoch:)`（[:139](../Presentation/GeometryOperationScheduler.swift#L139)）下发给调度器，调度器自己**不**加代次；两处各加一次会让真实写入永远失配。`Skip`（`cancelled / sessionChanged / budgetExpired`，[:22](../Presentation/GeometryOperationScheduler.swift#L22)）是"没开始"的凭据，调用方据此保留日志事实，不能当作"什么都没发生"。
- **出队复查**：入队时有效不代表执行时仍有效，闭包真正跑之前再查一次许可（[:360](../Presentation/GeometryOperationScheduler.swift#L360)）。这是迟到回调那条缺陷的正解，不是靠把队列清空。
- **取消时序**：取消屏障只撤销**普通操作**许可并丢弃未开始的普通计划（[:246](../Presentation/GeometryOperationScheduler.swift#L246)）；已经在写的操作只被阻止继续写下一个属性，"写过哪些属性"的事实保留给补偿。补偿与会话恢复走**独立授权**，撤销之后仍能准入——否则取消就等于把窗口留在中间尺寸。从"决定补偿"到"补偿排队成功"之间由 `reserveCompensation` 占位（[:263](../Presentation/GeometryOperationScheduler.swift#L263)），这段时间也算忙。
- **两种恢复落点不混用**：交换/进入失败回的是**操作前 before**（`operationBeforeFrame`，回到这次操作开始前的位置），退出与会话隐藏才用**会话 original**（进入工作台前的 frame）。补偿回报必须带各身份处置与"谁被激活"，事实不全时 reducer 只转 `recoveryRequired`、绝不声称 `.focused(A)`（[WorkbenchReducer.swift:917](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift#L917)）。
- **退出预算**：一个单调截止点（`deadline(after:)`，[:178](../Presentation/GeometryOperationScheduler.swift#L178)，总预算 2s）由所有阶段共享，后续阶段不重新获得完整两秒。顺序是：标记 terminating → 停热键/观察器/目录定时器/捕获/动画 → `fence(identities:)`（[:314](../Presentation/GeometryOperationScheduler.swift#L314)）排空已开始写入 → `drain(until:)`（[:324](../Presentation/GeometryOperationScheduler.swift#L324)）→ 逐项恢复，**每项开始前先问 `canStartNewWrite(deadline:)`**（[:189](../Presentation/GeometryOperationScheduler.swift#L189)），预算归零就不再落笔 → 到期停止等待、保留未确认日志、只回报一次。`TaskGroup.cancelAll` 撑不起硬超时（不可取消的恢复任务会让 `withTaskGroup` 一直等子任务），所以等待由调度器持有任务与完成 continuation、独立计时到点先答，进程终止或实际回调负责收敛。恢复所有权唯一：状态机发出的 `.restoreAll` 在终止期间被链接住并并入同一条链（[AppCoordinator.swift:671](../App/AppCoordinator.swift#L671)），A39 断言的就是"原 frame 只被写一次、终止回调只回一次"。
- **状态与日志边界**：journal 只在真实写入**之前**原子 prepare（一次批量要么全成要么全废，`revision` 单调递增、过期序号被拒并给出原因，[WindowJournalStore.swift:32](../Recovery/WindowJournalStore.swift#L32)、[:241](../Recovery/WindowJournalStore.swift#L241)）；prepare 失败＝零几何写入。写后那步落盘失败按"已经写过"处理：停止后续步骤并补偿（`journalUpdateFailed`，[Events.swift:87](../Packages/VistileCore/Sources/VistileCore/Domain/Events.swift#L87)），不按"未写入"抹掉义务。只有读回确认恢复成功的事务才从日志删除，未确认的留给下次启动复核。
- **时间基**：调度器的 `Stamp` 是纳秒单调戳，生产值来自 `ContinuousClock`、测试注入可控时钟（[:17](../Presentation/GeometryOperationScheduler.swift#L17)、[:94](../Presentation/GeometryOperationScheduler.swift#L94)）。同一口径也铺到其余计时点：过渡代理动画进度、`metrics.measure` 分段耗时、目录复核预算、捕获重配节流、探针的点击→落定与帧预算样本都用单调时钟（`CACurrentMediaTime()` / `ContinuousClock`），墙钟只用于报告里的日期与日志时间戳（方案 §20.2）。

## 8. 前台与键盘

总览面板从不抢走目标窗口的键盘：放大完成后 `setKeyboardFocus(.targetApplication)`，探针用"面板是否仍是 key 窗口 + 状态机键盘归属"作为客观证据（P0-4）。中文输入、右键、菜单栏、保存面板、滚动、快捷键都落在真实窗口里，因为放大的是真实窗口本身，而不是它的录像。

全局快捷键只用 Carbon `RegisterEventHotKey`；注册失败时如实报告并给菜单入口（`GlobalHotKey.failureHint`）。

## 9. 隐私与安全边界

- 像素只在 GPU/内存，永不落盘，也不写进诊断。
- 事务与报告只含会话 id、进程身份、窗口 id、bundle id、原始/临时 frame、显示器 id、时间与结论文字；**不含窗口标题**（有单元测试专门验证日志内容不含标题正文）。
- 只用公开 API。禁止清单（代码里不会出现）：SkyLight/CGS 私有接口、`_AXUIElementGetWindow`、注入、逐帧全屏截图、H.264 本地预览、Electron/WebView 冒充预览。
- 连续抢焦点、逐帧 Raise、全局鼠标转发都被结构性排除：Raise 只在展开时一次；焦点变化只作事件输入。

## 10. 尚未证明的部分

本文写的是设计意图，不等于验收结论。**P0 至今未通过。** 探针在已授权的正式包
（`/Applications/Vistile.app`，Developer ID + 公证）上累计跑了十几轮，失败位置每轮都在换，
多数原因仍是**探针自己的取证口径或桌面状态**（基准取在上一轮余波上、进场阶段脏、布局被
会话隐藏清空后取数、锁定桌面下 AX 全空）——判据与口径逐条改正并有单测守着
（`CatalogIdentityAudit` 5 条、`TargetRaiseAudit` 6 条、诊断落盘 4 条、`FocusVerificationLadder`）。

**0.1.10 工作台改版把验证面换到了新交互上**：探针新增 P0-12…P0-18（工作台入口、主副交换、
返回一致、总览先行、固定交换 100 次、往返 100 次＋非参与窗口对照、§20.2 帧预算与样本量），
在授权包上连跑八轮（0.1.10+16…+23，报告原件在 [Docs/Evidence](Evidence/README.md)）：

- `P0-12/13/14` 从 +16 起通过（真实点击、读回偏差 ≤0.5pt）；`P0-15` 总览先行：零写入、零面板；
- `P0-16`（固定交换 100 次）在 +20/+22/+23 三轮 **100/100**（点击→落定 p95 = 384 / 552 / 554 ms）；
- `P0-17`（往返 100 次）最好一轮 **61/100**（+23），停在第 62 轮一次"写后读回读不到"上——
  +24 的写后读回有界重试（3×70ms）就是为这条修的，**能否走满要看 0.1.10+24 的解锁复跑**；
- `P0-18` 的帧样本一直不到 §20.2 要求的每路径 100（+21 是 n=13/18/12，+23 长一些也只有 36/61/53），
  **每路径结论未测**；
- +22/+23 的运行中段在锁定桌面（这些段按未测记，不作产品结论），`P0-3`/`P0-4`/`P0-9` 在解锁桌面
  的复跑同样是 +24 要补的；人工与录屏项（报告里 `人工验收` 各行）一律未测。

还有一类事故不属于判据、属于证据保全：**0.1.4 的原始报告文件已经不存在了**，它被一轮宿主测试就地覆盖
（`CompatibilityRecorder` 的 `fileName` 参数当时没生效）。所以文档里的 0.1.4 数字只剩转录，无法再核对原件；
现在测试进程写临时目录、探针启动即归档上一轮，规则由 `T16DiagnosticsOutputTests` 钉住（见 [Acceptance.md](Acceptance.md) §6）。

兼容矩阵只有「关联」（12 个真实应用通过）与「层级」有数据：Code 0.1.4/0.1.5 连续两轮通过、
访达 0.1.6 通过（两两比较判据）、Chrome 三轮三种红/绿且**始终未定性**（0.1.6 起没有再遇到 ≥2 窗口场景）；
0.1.10 的八轮里 `P0-3` 在 UITestHarness 脚手架（6 窗口）上连续六轮通过（+16…+21），+22/+23 未测。
其余格子基本未测：捕获与移动与 resize 与 Sheet 四列**一格结论都没有**，「恢复」只有 Code 在 0.1.1 那轮
拿过一次通过（真实写过的几何事务 + 读回偏差 0.0pt + 未结束事务 0 条）。
0.1.5/0.1.6 报告里 ChatGPT 与 UGit 的「层级=通过」是两处代填，都已在标签内收回，0.1.6 起该列只由 P0-3 写。
TransitionProxy 的稳定遮挡、全屏 Space 与 Stage Manager 行为、30 窗口下的性能曲线都属于未验证能力。
数字与原始读数见 [Compatibility.md](Compatibility.md) §1–§2 与 [Performance.md](Performance.md) §4。
