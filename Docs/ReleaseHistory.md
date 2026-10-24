# Vistile

## 0.1.44 (58) — 2026-10-24

- 修复 v0.1.43 的过渡完成依赖：代理动画不再只依赖显示时钟回调，按自身时长到点收尾；前景化用例改用确定性激活替身，不再受 runner 的 PID 环境抽签影响。
  Fixes the v0.1.43 transition-completion dependency: the proxy animation no longer relies solely on display-link callbacks and closes on its own deadline; the foreground test now uses a deterministic activation double instead of depending on the runner's PID namespace.

自动验证 / Automated validation: 核心 143 + 159，0 失败；宿主 357 项，356 通过、1 跳过 / 357 host tests, 356 passed, 1 skipped, 0 failed.

## 0.1.43 (57) — 2026-10-24

- 动效与性能：承载层改由显示时钟驱动、透明度只应用一次、落定后停止重绘；切换流光与飞行面板贴合真实停靠窗口，落定时收束为边缘光晕。控制流程：激活/置前/读回/目录/带回/前台复核绑定会话代次与写许可，跨会话晚到回调不再改动窗口；新选择作废在途焦点跟随；退出与启动恢复串行化。
  Motion & performance: the carrier layer is driven by the display clock, opacity is applied once, and redraws stop once settled; the switch flow and flying panels now match the real docking target and settle into the edge glow. Control flow: activation, raising, read-back, catalog, drag-back and foreground checks are bound to the session epoch and write permit, so late cross-session callbacks no longer touch windows; new selections cancel in-flight focus following; termination and launch restore are serialized.

自动验证 / Automated validation: 核心 143 + 159，0 失败；宿主 356 项，355 通过、1 跳过 / 356 host tests, 355 passed, 1 skipped, 0 failed.

## 0.1.42 (56) — 2026-10-24

- 修复切换无效回归：可调窗口不再因 isMovable 采样折叠被拒（读回兜底才是判据）；主区停靠两种模式（尊重原尺寸/充满主区）可在设置中选择，即时生效。
  Fixes the switch-no-op regression: resizable windows are no longer rejected by movable-sampling collapse (read-back remains the criterion); main-area docking mode (respect original size / fill) is now selectable in Settings and applies immediately.

自动验证 / Automated validation: 核心 143 + 159，0 失败；宿主 332 项，331 通过、1 跳过 / 332 host tests, 331 passed, 1 skipped, 0 failed.

## 0.1.41 (55) — 2026-10-24

- 主区停靠尊重真实尺寸：放得下原样居中只写位置，超屏按原宽高比等比收缩；主窗口被拖出主区静默后带回；最小化即时进状态机；快速用户切换安全收口。
  Docking respects the real window size: original size centered when it fits (position-only writes), proportional scale-down only when oversized; a dragged-out main window is brought back after the drag goes quiet; minimize notifications reach the state machine immediately; fast user switching now exits safely like lock.

自动验证 / Automated validation: 核心 141 + 159，0 失败；宿主全量 332 项，331 通过、1 跳过 / 332 host tests, 331 passed, 1 skipped, 0 failed.

## 0.1.40 (54) — 2026-10-24

- CI 宿主测试失败时把日志文件里的断言明细带进 console，间歇失败可定位。
  Failing host-test assertions from the runner-side log are now surfaced in the console, making intermittent failures diagnosable.

## 0.1.39 (53) — 2026-10-24

- 前景化失败用例的等待预算放宽到 6 秒，消除 CI 慢 runner 的间歇超时；等待条件不变。
  The activation-failure case's wait budget widens to 6 s, removing intermittent timeouts on slow CI runners; the awaited facts are unchanged.

## 0.1.38 (52) — 2026-10-24

- 手动选择/返回/收起时作废在途的自动焦点跟随查询：晚到的旧结果不再把用户刚选下的主窗口切走；用例覆盖"选择落定后旧查询晚到"的时序。
  Manual selections, returns and dismissals now cancel in-flight automatic focus-follow queries, so a late result from an older query can no longer steal the freshly selected main window; the case covers the post-selection late-arrival ordering.

自动验证 / Automated validation: 核心 135 + 159，0 失败；宿主全量 332 项，331 通过、1 跳过 / 332 host tests, 331 passed, 1 skipped, 0 failed.

## 0.1.37 (51) — 2026-10-24

- 切换主窗口改为空间流动过渡：新主面板从被点选的轨道格飞进主区、旧主面板同时退回格子，Metal 定向流光由速度包络驱动——起步抽出、减速展开、到达扩散为径向柔光；AX 几何时序不变。
  Main-window switching becomes a spatial flow: the promoted panel flies from its rail cell into the main area while the previous one retreats, with a Metal directional light band driven by a speed envelope — drawn out at launch, broadening on deceleration, and diffusing into a radial glow on arrival; AX geometry timing is unchanged.
- 流光三级降级：light 面板原地而光仍扫过（方向感不丢），fade/Reduce Motion 保持单帧遮罩；形态参数全部为纯函数并有宿主测试断言。
  The flow degrades in three tiers: light keeps panels stationary while light still sweeps; fade and Reduce Motion keep the one-frame mask. All envelope shapes are pure functions asserted by host tests.

自动验证 / Automated validation: 核心 XCTest 135 + Swift Testing 159，0 失败 / 0 failures；AgentUse 宿主全量 332 项，331 通过、1 项真实前台键盘焦点限制跳过 / 332 host tests, 331 passed, 1 skipped, 0 failed。流光像素观感待 P0 实机录屏验收 / Flow pixel quality awaits real-machine P0 acceptance.

## 0.1.36 (50) — 2026-10-24

- AX 观察者差分注册、轮询例行帧停止触发全量同步、搜索键击合并到显示周期：总览打开期间的全量同步从"每事件一次"收敛到结构性变化才发生，重复的 43–101ms 观察者重注册停顿随差分消失。
  AX observer registration now diffs on both sides, routine poll frames stop triggering full synchronization, and search keystrokes coalesce per display cycle: full syncs during an open overview drop from once-per-event to structural changes only, removing repeated 43–101ms observer re-registration stalls.
- Esc/背景收起当帧视觉消失，实测 460–496ms 的 orderOut 延后执行，重开自动取消；工作台主区真实窗口停止捕获流，避免系统"共享窗口"标识，轨道副本保留最后一帧。
  Esc and background dismissal hide visually within the frame, deferring the measured 460–496ms orderOut and cancelling it on reopen; the workbench main window stops its capture stream to avoid the system sharing badge, with the rail copy keeping its last frame.

自动验证 / Automated validation: 核心 XCTest 135 + Swift Testing 159，0 失败 / 0 failures；AgentUse 宿主全量 330 项，329 通过、1 项真实前台键盘焦点限制跳过 / 330 host tests, 329 passed, 1 skipped for real foreground keyboard focus, 0 failed。P0 实机验收（授权正式包、真实刷新率、30 分钟资源曲线）仍按 [Acceptance.md](Acceptance.md) 单独记录。

## 0.1.35 (49) — 2026-10-23

- 滚动与栏尺寸预览按显示周期合并视觉同步；壁纸后台解码、有界缓存，窗口层级按签名变化调整。状态、安全事件与几何事务继续即时处理。
  Scroll and rail-size previews coalesce visual synchronization per display cycle. Wallpaper decoding runs in the background with bounded caching, and window ordering changes only with its signature. State, safety events and geometry transactions remain immediate.
- 低频截图最多两路物理并发，请求代次阻止过期结果；取消和重开不提前释放真实在途预算，图像映射移出主线程。
  Poll capture has two physical slots and generation checks. Cancellation and reopening preserve outstanding resource accounting, and image mapping leaves the main thread.
- AX读回异步重试，窗口发现分块、交互优先；保留串行写入并校验跨进程属性类型。
  AX readback retries asynchronously, discovery is window-sized and interactive jobs have priority. Writes remain serial and cross-process attribute types are validated.
- 区分Metal提交、GPU完成和实际呈现；实际呈现时间决定首帧及帧间隔，预算随显示回调周期变化，诊断样本每项限制1024条。
  Metal submission, GPU completion and presentation are separate. Actual presentation timestamps drive first-frame and interval metrics, display-link periods set budgets, and each metric retains at most1,024 samples.

自动验证 / Automated validation: Core XCTest135 + Swift Testing159，0失败；AgentUse宿主328项，327通过、1项真实前台键盘焦点限制跳过、0失败。P0仍需授权正式包及真实显示环境验收；完整证据与限制见 [PerformanceAudit-2026-10-23.md](PerformanceAudit-2026-10-23.md)。

## 0.1.34 (48) — 2026-10-23

- 槽位与网格一致性：窗口从待整理队列落入空位时同步移出队列，溢出数量不再重复计数；登记表恢复丢弃负 slot，容量按实际条目计算，不再越界崩溃；极小屏单列兜底的内容区按格高收缩，不再跑出格子。
  Slot and grid consistency: a queued window that lands in a vacancy leaves the pending queue, so overflow counts are no longer duplicated; restoring slots drops negative indices and derives capacity from real entries instead of trapping; fallback-card content is clamped inside cells shorter than the title bar.
- 极端布局与设置：兜底网格先压缩间距再分配行高，不再产出负或零格高；按显示器读取栏尺寸时两个字段分别校验，单个坏值不再拖垮另一项有效偏好，NaN/负值读入即清洗写回。
  Extreme layout and settings: the fallback grid compresses gaps before row height, so no negative or zero cell heights; per-display rail sizes validate each field independently, so one corrupt value no longer discards a valid sibling, and NaN/negative values are cleaned and written back on read.
- 输入与热键：搜索词忽略首尾空白，只剩空格等同没有查询；越界或缺少修饰键的持久化热键回退默认，注册层拒绝无修饰键绑定，避免劫持普通按键。
  Input and hotkeys: search ignores leading/trailing whitespace, so a whitespace-only query behaves as no query; persisted hotkeys with out-of-range codes or missing modifiers fall back to the default, and registration refuses modifier-less bindings to avoid hijacking plain keys.
- 更新通道：版本标签拒绝空段与非 ASCII 数字，坏 tag 不再参与版本比较；自动检查把未来时间戳视为到期，系统时间回拨或坏值不会永久压住检查。
  Update channel: version tags reject empty and non-ASCII numeric segments so malformed tags never enter comparisons; automatic checks treat future timestamps as due, so clock rollback or corrupt values cannot throttle checks forever.
- 新增确定性边界扫描：400 组极端工作台帧与子像素/NaN 覆盖、120 组敌意滚动偏移、1500 步槽位操作序列、180 组随机网格几何，全部离线运行且不触碰真实窗口。
  Added deterministic boundary scans: 400 extreme workbench frames with sub-pixel/NaN overrides, 120 hostile scroll offsets, 1,500-step slot operation sequences and 180 random grid geometries, all offline and without touching real windows.

自动验证：干净构建目录下核心 XCTest **133** + Swift Testing **159**，0 失败；宿主全量 **307** 项，306 通过、1 项因后台账户无法取得真实前台键盘焦点跳过、0 失败。Release（arm64、未签名）构建通过。GitHub Actions 在 tag 上完成签名、公证、装订与发布，App 与 DMG 两份公证均为 `Accepted`。下载产物复核：`Vistile_v0.1.34_macos_arm64.dmg`，SHA-256 `d727c5d69df0903cdee1198ba28836baf0d205e8c20ae73d8b9df5b708f8a28f`，版本 0.1.34 (48)，TeamIdentifier `U8U443D7ZL`，Gatekeeper 判为 Notarized Developer ID，`stapler validate` 通过，`lipo` 仅含 arm64。

## 0.1.33 (47) — 2026-10-23

- 修复应用内更新在“正在恢复窗口并重新启动”阶段卡住的问题：退出请求原先在更新任务占用主队列时直接调用 `NSApplication.terminate`，`.terminateLater` 的回复与兜底计时都无法送达。现在把退出请求交回主运行循环的下一轮，替换 helper 能按时接管并完成重启。
  Fixes the in-app update hang at "restoring windows and relaunching". The exit request used to call `NSApplication.terminate` while the update task held the main queue, so the `.terminateLater` reply and the ceiling fallback could never be delivered. Termination is now handed back to the next main-run-loop turn, letting the replacement helper take over and relaunch.
- 交接超时失败仍保留当前版本，并由 helper 写入诊断结果；下次启动提示“上次更新未完成”。
  A handoff timeout still keeps the current version, and the helper writes a diagnostic result that is surfaced on the next launch.

自动验证：干净构建目录下核心 XCTest **126** + Swift Testing **155**，0 失败；宿主全量 **298** 项，297 通过、1 项因后台账户无法取得真实前台键盘焦点跳过、0 失败；新增回归断言退出请求不得在当前 MainActor 轮次内同步执行。Release（arm64、未签名）构建通过。GitHub Actions 在 tag 上完成签名、公证、装订与发布。下载产物复核：`Vistile_v0.1.33_macos_arm64.dmg`，SHA-256 `74cf42f62653573d18c74ceb8c0fb3012435b4f3392bec2016bfb655e92e4434`，版本 0.1.33 (47)，TeamIdentifier `U8U443D7ZL`，Gatekeeper 判为 Notarized Developer ID，`stapler validate` 通过，`lipo` 仅含 arm64。

升级说明：0.1.31 与 0.1.32 的应用内更新都会卡在同一处，运行中的旧版本无法用自身代码完成修复；这两版需手动下载 DMG 安装一次，0.1.33 起应用内更新恢复。

## 0.1.32 (46) — 2026-10-23

- 修复引导页“完成”按钮只记录完成状态、不关闭窗口的问题：点击“完成”现在会关闭引导窗口，完成回调只触发一次；用窗口关闭按钮结束引导时行为不变。
  Finishing onboarding now closes its window instead of only recording the completion flag. The completion callback fires exactly once whether 完成 is clicked or the window is closed via its button.

自动验证：干净构建目录下核心 XCTest **126** + Swift Testing **155**，0 失败；宿主全量 **297** 项，296 通过、1 项因后台账户无法取得真实前台键盘焦点跳过、0 失败；新增回归断言关窗通知与单次回调。Release（arm64、未签名）构建通过。GitHub Actions 在 tag 上完成签名、公证、装订与发布。下载产物复核：`Vistile_v0.1.32_macos_arm64.dmg`，SHA-256 `8ffccfee8f81105bc8f0651d7ffe1c0bb28c89dc1a3b904a1e7ad54242e8106f`，版本 0.1.32 (46)，TeamIdentifier `U8U443D7ZL`，Gatekeeper 判为 Notarized Developer ID，`stapler validate` 通过，`lipo` 仅含 arm64。

## 0.1.31 (45) — 2026-10-23

- 重新设计菜单栏图标：以简洁的主窗口与上方预览栏表达工作台，单色图标自动适配系统明暗外观。
  The menu bar icon now depicts the Workbench as a main window beneath a preview rail, and its monochrome artwork adapts to the system appearance.
- 检查更新新增“下载并安装”：显示下载进度，支持取消；安装包校验与应用签名验证通过后，恢复窗口并自动替换、重新启动。
  Check for Updates now offers Download and Install with progress and cancellation. After the package and app signature verify, windows are restored and the app replaces itself and relaunches.
- 更新准备失败保留当前版本，替换失败自动回滚；只读安装位置会提示先将应用移入可写目录。
  A failed update preparation keeps the current version, a failed replacement rolls back, and read-only install locations tell the user to move the app to a writable folder.
- 更新说明改为固定高度的可滚动区域，去掉 Markdown 标记和重复的手动安装说明。
  Release notes render in a fixed-height scroll area without Markdown markers or duplicated manual installation instructions.
- 手动切换主窗口不再固定等待 180ms：主区先盖上原地遮罩，真实窗口交换随即执行；宿主链路从点击到首笔几何写入的中位数由 267.55ms 降到约 79–95ms。
  Manual main-window swaps no longer wait a fixed 180ms: an in-place mask covers the main area first and the real AX exchange follows immediately. On the host harness chain, the median time from click to first geometry write fell from 267.55ms to roughly 79–95ms.
- 顶栏与左右侧栏改为 18pt 连续外壳、12pt 卡片圆角、细描边与透明圆角，并修正圆角层未真正裁剪越界内容的缺陷。
  The top and side rails use an 18pt continuous shell, 12pt card radius, hairline stroke and transparent rounded corners; the defect where the rounded layer did not actually clip overflowing content is fixed.
- 切换等待期间显示新版 Siri 风格彩边流光（细锐边 + 外侧柔光）；等待本身不额外触发重绘，低电量、热压力或“减少动态效果”时只保留静态彩边，完成或取消立即收起。
  A Siri-style edge glow (sharp rim plus a soft outer halo) plays during switch waits. Waiting adds no redraws; low power, thermal pressure or Reduce Motion keep only the static rim, and completion or cancellation dismisses it immediately.

自动验证：干净构建目录下核心 XCTest **126** + Swift Testing **155**，0 失败；宿主全量 **296** 项，295 通过、1 项因后台账户无法取得真实前台键盘焦点跳过、0 失败；Release（arm64、未签名）构建通过。GitHub Actions 在 tag 上完成签名、公证、装订与发布。下载产物复核：`Vistile_v0.1.31_macos_arm64.dmg`，SHA-256 `4d8f65129d5f7e1199fbe700c6c84cfc01c9c06f7c17f6be96d3d65d03d65f8f`，版本 0.1.31 (45)，TeamIdentifier `U8U443D7ZL`，Gatekeeper 判为 Notarized Developer ID，`stapler validate` 通过，`lipo` 仅含 arm64。

显式未测：真实鼠标拖拽分隔线、真实跨应用 AX 交换，以及真实 Dock、多 Space、全屏场景的端到端验收仍未完成；79–95ms 来自宿主替身链路，不代表真实跨应用端到端延迟。

## 0.1.29 (43) — 2026-10-23

- 顶栏高度与侧栏宽度可直接拖动边框调整：悬停高亮、拖动显示当前尺寸、双击重置单维、Esc 取消；尺寸按显示器保存，并按屏幕与主窗口可容纳范围取有效值。
  The top rail height and side rail width are now draggable at their inner borders, with hover highlight, a live size label, double-click reset per dimension, and Esc to cancel. Sizes persist per display and are clamped to what the screen and main window can accommodate.
- 轨道保留稳定的逻辑卡位：调整栏尺寸只改变可见容量，缩略图仍按源窗口比例绘制；容量不足时滚动，不重排已有卡片。
  Rails keep stable logical slots: resizing changes visible capacity only, thumbnails retain the source aspect ratio, overflow scrolls, and existing cards are never reshuffled.
- 新窗口进入、Dock 与其他应用切换统一跟随最终获得焦点的具体窗口；连续切换按最新意图收敛，已过期的目标不再被重新激活。
  New windows, Dock launches, and app switches follow the concrete window that ultimately receives focus. Rapid switches converge on the latest intent, and superseded targets are not re-activated.
- 关闭主窗口后按“系统随后聚焦的合法同屏窗口 → 同屏最近使用 → 原卡位”补位；没有候选时保留空主区。后台新增窗口只补卡片，不抢焦点、不自动滚动。
  After the main window closes, the next focus target is the system's subsequent legal same-display window, then same-display MRU, then the original slot; with no candidate the main area stays empty. Background additions only fill cards and never steal focus or auto-scroll.
- 外部切换使用更短的原地淡化，开启“减少动态效果”时缩短到 80ms；补偿路径不再把焦点拉回过期的旧主窗口。
  External switches use a shorter in-place fade (80ms under Reduce Motion), and compensation no longer pulls focus back to a superseded main window.

自动验证：核心 XCTest **124** + Swift Testing **155**，0 失败（删除 `Packages/VistileCore/.build` 后重跑）；宿主全量 **266** 项，265 通过、1 项环境跳过、0 失败，其中工作台相关 **147** 项。跳过项仍是后台账户无法取得真实前台键盘焦点的检查。

显式未测：自动化环境的鼠标拖动未能把事件送达目标进程（AppKit 窗口派发路径改由 `NSWindow.sendEvent` 回归覆盖，含顶栏、左右侧栏、面板移动后的锚点保持与双击重置）；真实 Dock、跨 Space、全屏切换未做端到端验收。无法可靠识别具体窗口时保留原生焦点并提示，不循环抢焦点。

## 0.1.28 (42) — 2026-10-23

- 辅助功能权限缺失时，引导和设置页提供“清除授权并重新授权”：只重置 Vistile 的辅助功能记录，成功后重新申请并打开系统设置，由用户开启权限；失败时显示错误。
  When Accessibility access is missing, onboarding and settings offer a repair button that resets only Vistile's Accessibility decision, requests access again, and opens System Settings for the user to grant it. Reset failures are reported.
- 引导页在返回应用和点击重新检查时刷新权限；未获授权不能完成引导。
  Onboarding refreshes permissions when returning to the app and when rechecking; missing grants prevent setup completion.
- 更新检查、说明与安装包下载统一使用 GitHub Releases，移除自建镜像，不向自有服务器上传。下方旧版本中的镜像说明仅为历史记录。
  Update checks, release notes, and package downloads use GitHub Releases exclusively. Self-hosted mirrors are removed, and no release is uploaded to a personal server. Mirror references in older entries below are historical.

把 macOS 全部符合条件的窗口渲染成固定格子的实时缩略图总览；点击卡片时**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景空白处回到总览；收回绝不最小化窗口，临时改过的窗口几何在退出时还原。

只用公开接口：ScreenCaptureKit 多路捕获 + Metal 合成，ApplicationServices AX 读写几何，CGWindowList 提供层级与窗口顺序证据。没有私有 SkyLight/CGS 调用、没有事件注入、没有逐帧全屏截屏、不靠窗口标题控制窗口。日志与事务只存会话 id、进程身份、窗口 id、bundle id、原始/临时几何、显示器 id 与时间，**不含窗口标题与像素**；捕获画面只存在于内存纹理，不落盘。

## 必须先知道的三件事

1. **P0 能力门禁（P0-1…P0-11）没有通过。** 同一个正式版包上已经跑了五轮可用数据：0.1.1+2 有两条失败（P0-1 同进程 AX 索引不唯一、P0-3 提升被点窗口时把同应用兄弟一起提上来）；0.1.3+4 把自动项从 9 条扩到 13 条，结果 12 通过 / 1 失败；0.1.4+5 用改正后的口径复跑，13 条 1 失败，**P0-1 换了正确判据之后实机通过**（17 个窗口、同进程 AX 索引无重复=true），所以那条红了两个版本的问题不是产品缺陷，是探针测错了东西；0.1.5+6 是 11 通过 / 2 失败，**P0-4 转为通过**（放大 ChatGPT 后总览面板不持有键盘、归属=targetApplication）；**0.1.6+7 可用那轮（17:46）11 通过 / 2 失败，剩下两格是 P0-7 与 P0-9，而 P0-3 这一轮两个多窗口应用都判通过**（Code 目标 #15→#8、兄弟 #13→#13；访达目标 #29→#7、兄弟绝对下标动了但对仍在场的窗口一个便宜都没占）。0.1.6 还有一轮（17:37）整轮作废——全程 0 帧、AX 只解析出 5/15，那轮的"P0-2 收不到新帧""P0-3 Raise 没发出"是屏幕状态的环境产物。**这五轮里失败的位置每轮都在换，而绝大多数原因是探针自己的取证口径**（基准取在上一轮余波上、阶段没清场、布局被会话隐藏清空后取数、在 0 路流的瞬间取增量）。**0.1.7 没跑过实机轮次**（发布后读代码才发现「层级」列的通过分支根本不写格子，于是改动直接进 0.1.8）；**0.1.8 跑了四轮**，前三轮全程 0 帧、AX 一个窗口都解析不出来，第四轮 13 通过 / 1 失败——而那台机器当时**锁着屏**：锁屏时权限预检仍回 true，`osascript` 问任何应用 `count of windows` 却一律回 0，所以那一轮里 P0-3 的「Raise 没有发出（拿不到 AX 句柄）」是环境，不是产品结论（0.1.9 起这种轮次记未测）。**这六轮里失败的位置每轮都在换，而绝大多数原因是探针自己的取证口径或桌面状态**（基准取在上一轮余波上、阶段没清场、布局被会话隐藏清空后取数、在 0 路流的瞬间取增量、锁屏时替产品下结论）。人工与录屏项一律还是「未测」，见 [Docs/Acceptance.md](Docs/Acceptance.md)。
2. **兼容矩阵只有「关联」与「层级」两列有了部分数据。** [Docs/Compatibility.md](Docs/Compatibility.md) 里 12 个真实应用的关联=通过；层级由 P0-3 写的格子现在有了 Code（0.1.4/0.1.5/0.1.6 连续三轮通过）与访达（0.1.6 用共同参照系判通过）；Chrome 在 0.1.4/0.1.5 各有一条红、0.1.6 那轮它没有 ≥2 个窗口所以没复测，仍未定性。此外 0.1.5 报告里 ChatGPT 那格「通过」是前台读回代填的、0.1.3 报告里 UGit 那格是 P0-9 代填的，两处都已收回（0.1.6 起这一列只由 P0-3 写）。**这两格的口径要看清：它们是把报告正文里 P0-3 那一行的判据抄进文档的，报告自己那份机器生成的矩阵里，0.1.7 及以前「层级」列在 P0-3 通过时是空的——通过分支根本不调 `updateRow`，这一列只能出「失败」，直到 0.1.8 才补上。**其余列（捕获、移动、resize、Sheet）一格结论都没有，「恢复」只有 Code 在 0.1.1 那轮真实写过几何、读回偏差 0.0pt，算过一次通过——包括 Safari、Finder、Office 与全屏应用在内仍然全是「未测」。未测不等于可用。0.1.11 按修复方案 §19 又补了「激活」「输入」两列，**这两列整列为未测**——能填它们的是真机矩阵 M07（逐应用设为主并核对前台）与 M11（肉眼输入体验），都还没在发布字节上跑过。
3. **性能数字只有本机几条样本，且其中 CPU 那一条明显不可信。** [Docs/Performance.md](Docs/Performance.md) 里的预算是设计值；授权态可用五轮记录 CPU 0.2 / 0.3 / 0.3 / 0.3 / 0.3（十几路流），这个数当不了结论，必须用 Activity Monitor / Instruments 对照。帧数那条也要看口径：报告里的"帧 184 张/3.0s"是所有流合计，不是屏幕帧率（0.1.6 那轮的"总览帧率 61.0"就是它除以墙钟时间）。作废那轮读到的是 0 帧 / 0.1 CPU——0 帧不是"很快"，是没有画面可捕。几何写入五轮只有两个样本（17.9ms 与 117.9ms，后者 n=1），慢了一个量级却说不出原因——0.1.6 起「过渡超时」会带上预算与实际等待毫秒，这项才有可分辨的数据。**0.1.12 起每条 P95 都按「档位·reduceMotion·冷启动/热路径」分组**，此前的读数全是合池的：两套数字口径不同，不能互相代替，也不能拿旧的合池数字给分组后的判据交差。

## 本版（0.1.27）相对 0.1.26 的变化

- 卡片标题回收未显示图标和状态栏占用的宽度，左右各留 8pt；只有确实显示状态时才为状态文字留位。悬停轨道卡片可查看完整应用名和窗口标题。
- 工作台内每个窗口始终保留自己的小窗与逻辑 slot。切换主窗口只更新选中身份，不再把原主窗口塞进被点卡片的位置；当前窗口用系统强调色边框标记，VoiceOver 同时读出“当前窗口”。
- 主窗口的小窗也纳入原有捕获预算，继续显示预览；切换动画期间保留双方的小窗，返回动画端点使用各自的原 slot。
- 可见数与总窗口数按唯一身份计算，避免主区与自己的小窗重复计数；窗口关闭仍只清理自己的 slot，其他卡片不前移。手动拖动和整理仍可调整位置。
- 中文：轨道位置与主窗口选择独立，只有明确的拖动、整理或窗口增删改变占位。
- English: Rail positions are independent of main-window selection. Only explicit drag/reorganize actions or window membership changes alter occupancy.

自动验证：核心 XCTest **83** + Swift Testing **155**，0 失败。宿主 **229** 项回归，最终分组汇总 **228 通过、1 项环境跳过、0 失败**；完整宿主轮次中两处旧隐藏判据修正后，单独重跑过渡场景 **39/39** 通过。跳过项仍是后台账户未取得前台激活的真实键盘焦点检查。实际真机帧率和点击延迟未据此重新测量。

## 本版（0.1.26）相对 0.1.25 的变化

修**进入工作台那段飞行一直是糊的**，并把点击路径上的跨进程抓帧整条删掉。

### 根因：一张 640px 的纹理被放大 4.7 倍

`CaptureCoordinator.refreshSingleFrame` 建 `StreamConfig` 时用的是 `tier: .powerSaving`，
而 `CaptureTier.powerSaving.maxPixelWidth == 640`。`AppCoordinator.flightPrefetchWidth()`（本版已删除）
想要的是主区宽度（约 1500pt，2x 下约 3000px），请求在捕获层就被这条 640px 上限截断；
承载层（`Presentation/ModeTransitionCoordinator.swift`）再把这张 640px 纹理画进约 3000px 宽的主区矩形，
放大倍数约 **4.7×**。所以整段飞行（进入 240ms / 返回 200ms / 交换 180ms）必然是糊的——**预取再多次也没用，问题不在预取时机，在输出尺寸**。

同时，每次点击/hover 都会在点击路径上发起一次 `SCScreenshotManager` 全窗口抓帧（`prefetchFlightFrame`），
每段过渡还会再发起 1–2 次（`refreshFlightTexture`）。这些抓帧与 AX 写入、displayLink 抢主线程。

### 改法：飞行只画圆角面板，不缩放任何位图

- 飞行期间不再绘制任何截图，改画一块圆角面板：填充 RGB(0.145, 0.153, 0.173)、1pt 白 10% 描边、8pt 圆角，
  从卡片格子矩形飞到落点。**全程没有任何位图缩放**，所以"模糊的过程"根本不存在。
  圆角取 `WorkbenchStyle.cornerRadius` 这一套 token，面板看起来才是"那张卡片"。
- 落定后承载层 **110ms 淡出**，把画面交给真实窗口（`TransitionCarrierView.handoffFadeMS`）；
  交接期既看不到糊图，也没有硬切。
- 面板端点用**卡片外框（含标题条）**，不是内容区：端点由场景显式给出（`Card.panelFrom` / `Card.panelTo`），
  没给才按 `cellStart ?? start` → `cellEnd ?? end` 推导。用内容区会比外框矮一个标题条，
  既看出"从卡片中间长出来"，交接时还会再跳一下。

### 删除：点击路径上不再有跨进程抓帧

`prefetchFlightFrame`、`refreshFlightTexture`、`prefetchedFlightFrames`、`lastPrefetchAt`、`prefetchTasks`、
`prefetchRequestCount`、`prefetchedFrameCount`、`prefetchedFlightFrame(for:)`、
`CaptureCoordinator.refreshSingleFrame`、`refreshInFlight`，以及两个视图的 `onHoverIdentity` 回调全部移除。
点击路径上不再有任何 `SCScreenshotManager` 调用（降级到轮询的卡片仍按原预算单帧取图，那条路径不属于点击）。

### 结构

- `Rendering/TransitionScene.swift` 新增 `TransitionScene.Content`（`.panel(PanelStyle)` / `.captured`）与 `PanelStyle`；
  工厂默认 `.panel`（`TransitionScene.content` 的默认值），`TransitionSceneFactory.drawsCapturedContent = true`
  可回退到放大捕获图的旧行为——**仅供诊断**，任何用户可见路径都不该打开它。
- `Rendering/ShaderSource.swift` 的纯色管线支持圆角（矩形距离场 + 1px 抗锯齿）；
  `cornerRadius = 0` 时直接返回，老调用点零额外成本。

### 顺带修掉：⌃⌥空格 全局快捷键必崩

实机验收时发现的既有缺陷（0.1.25 及以前都有，与本次动效改动无关）：

`GlobalHotKey.installHandlerIfNeeded` 把 `&context` 传给了 `InstallEventHandler` 的 `inUserData`。
那个参数是**按值保存的 `void *`**，传局部变量地址等于把一块马上失效的栈内存交出去；
方法返回后，每次按下快捷键 `fromOpaque(userData)` 读到的都是垃圾指针，进程直接 SIGSEGV
（`EXC_BAD_ACCESS`，崩溃栈落在 `GlobalHotKey.swift` 的回调里）。改成直接传 `toOpaque()` 的结果。

**对照证据**：把本次全部改动 stash 掉、用 HEAD（0.1.25）构建同一份调试产物，在同一个会话里按同一个组合键，
同样崩溃（崩溃点一致）。修复后连按 3 次均存活，无新崩溃报告。

### 操作跟手与过渡连续性

- 卡片标题、边框、空位和 Metal 承载层关闭隐式属性动画：滚动位置、hover 与 display-link 淡出直接采用本轮值，避免图层再叠一段默认动画而落后于画面。
- 顶栏触控板滚动按一次手势的初始主方向锁轴，系统惯性阶段沿用同一轴；新手势重新判断。精确滚动保留系统点数与惯性，普通滚轮按每行 10pt 换算。
- 过渡按 `CADisplayLink.targetTimestamp` 计算即将呈现的位置；面板被打断时从当前可见矩形续接，不跳回新计划的起点。
- drawable 尺寸仅在实际变化时更新。静止界面仍按需重绘，不添加空转刷新循环。
- 新增滚动锁轴/惯性、普通滚轮、装饰层与淡出无隐式动画回归；补强面板打断续接断言。以上是实现与自动检查范围，尚未据此宣称真机帧率或延迟提升。

### 实测与回归

- 本版**没有新的真机性能读数**：飞行不再放大位图，但"点击→首帧 p95""点击→落定 p95"要在授权正式版上复测；
  旧读数（进入 549ms / 交换 421ms）含这些抓帧成本，不能直接与新版对比（见 [Docs/Performance.md](Docs/Performance.md) §4 第 6 项）。
- 自动回归：核心 XCTest **81** + Swift Testing **155**，0 失败；AgentSpace 后台桌面宿主 **227 项（1 项既有环境跳过），0 失败**。宿主使用已核对一致的临时源码副本，避免改动用户目录权限。

## 本版（0.1.25）相对 0.1.24 的变化

修复**总览里打开新 App 会把整个总览关掉**。0.1.22 只处理了工作台里的失焦；总览仍然走旧逻辑：
外部应用一激活就 `focusLost → 退出会话`，总览瞬间消失，新应用的窗口没有机会变成卡片。

现在总览也有同样的"新窗口"判定，但按会话基线取事实：

- 打开总览那一刻已有的窗口记为基线；之后才出现、3 秒内第一次见到的窗口才算"新打开的应用"。
- 新窗口已经进目录：立即保持总览，把新应用作为新卡片放进空格，并重新激活、置前总览。
- 新窗口比前台变更晚一轮目录：先主动核对目录，在 600+600ms 宽限内等它；出现就留下，没出现才按正常离开退出。
- 切到总览里已有的应用（Cmd+Tab、点 Dock 等）仍然立即退出，不会被宽限拖住。
- 延迟结算直接入队、不再经过分流：修掉了宽限结束后重新开始等待、永远退不出去的隐患
  （工作台 0.1.22 的旧路径也有同一问题）。
- 新系统上 `NSApp.activate` 不一定真把 App 带回前台，重新置前时补一次运行中应用句柄的激活。

实机依据（0.1.24 日志 19:44:16–19:44:22）：总览打开时 4 个窗口里没有 `ai.opencode.desktop`（pid 1449），
5.5 秒后它激活，旧逻辑在 300ms 确认后直接 `overview→hidden`。这条路径现在会保持总览并把它的窗口纳入卡片。

自动回归：核心 XCTest **81** + Swift Testing **155**；宿主 **216 项（1 项既有环境跳过）0 失败**。
新增 4 条宿主用例：目录已到的新窗口、目录晚到的新窗口、切到已有应用立即退出、未知 bundle 无新窗口在宽限后退出。

## 本版（0.1.24）相对 0.1.23 的变化

补全上一版的**切换失败卡死**修复：0.1.23 只处理了总览里的卡片点击，工作台轨道上的点击与
"返回总览"走的是另一条状态机路径，仍然只弹提示、状态不动。实机日志里可以清楚看到：
进入 `recoveryRequired` 后连续点顶栏卡片，每条 `[点击] 轨道卡片` 后面都只有同一句失败提示，
阶段不再变化；外部应用激活触发的"退出会话"也被同一条闸门吞掉。

现在把工作台侧的恢复闸门统一成「**说明原因 + 按日志收口退出**」：轨道卡片点击、返回总览、
侧栏/尺寸调整等入口在几何不可信时都会先给提示，再走 `recovering → hidden` 安全退出；
落地时清掉 `recoveryRequired`，下一次打开就是干净会话。有欠恢复事务时仍按日志逐条恢复，
不会把窗口丢在临时几何上。

自动回归：核心 XCTest **81** + Swift Testing **155**；宿主 **212 项（1 项既有环境跳过）0 失败**。
新增 `testRailClickInRecoveryRequiredExitsAndReopensClean`，覆盖"提示 → 恢复批次 → 落地清标记 →
重新打开可再次进入工作台换主"的完整链路。

## 本版（0.1.23）相对 0.1.22 的变化

修复**切换失败后卡死**：换主时如果目标窗口拒绝几何修改（例如 Qoder 窗口 1747×1129 无法缩进
主区 1507×973），补偿不完整会进入 `recoveryRequired`；此前这个状态下点击任何卡片只弹一次提示、
状态不动，用户感觉"点过的窗口再点没反应"。

现在：`recoveryRequired` 下点击任何卡片会**按日志收口并退出恢复**（提示 + 收工作台），
下一次打开就是干净会话，不再把用户关死。

自动回归：核心 155+80；宿主 **212 项（1 项既有环境跳过）0 失败**；核心新增断言覆盖
"点击从 recoveryRequired 安全退出"。

另：屏幕读取的系统隐私指示（菜单栏/窗口上的"正在观察"标识）由系统绘制，公开 API 无法隐藏；
可以减少持续抓屏时间（例如改成按需单帧抓取），代价是预览不再实时。需要的话我再单独做。
## 本版（0.1.22）相对 0.1.21 的变化

两件事：**主窗口切换动画不再中途"跳"**，以及**打开新软件不再让整场布局消失**。

### 主窗口切换

真实 AX 交换原来在动画中段就执行，旧主缩回、新主放大还没播完，真实窗口就先动了，看起来像"覆盖"。
现在真实 AX 交换延后到切换动画完整播完再执行（旧主缩回、新主放大→承载层保持/淡出时落到真实窗口），
屏幕上看到的就是完整的"上一层退出、下一层放大"。

### 打开新软件

之前工作台里切到刚打开的应用会触发 `focusLost` → 整场恢复/隐藏，用户看到所有窗口都不见了。
现在：工作台里失焦时，如果最近 3 秒内有新窗口出现，就**回到冻结总览**把这个新窗口纳入卡片布局，
而不是整场退出；只有切到已有应用（没有新窗口）才按原逻辑退出。

### 回归与实测

- 自动回归：核心 155+80；宿主 **212 项（1 项既有环境跳过）0 失败**；
  新增用例 `testNewWindowFocusLossReturnsToOverviewInsteadOfHiding`（新窗口出现→回总览并入布局）。
- 真机探针（`VISTILE_P0_TARGET=Chrome`，当时共 6 个窗口）：P0-16/P0-17 均 100/100、格心 0.00pt、
  真实 frame 无漂移；帧间隔与落定受 6 窗口负载影响，未与 4 窗口基线直接比较。
- 同轮还遇到一个环境问题：某个目标窗口按自身最小尺寸约束拒绝缩小（1686×1089 > 主区 1507×973），
  探针按判据记未测；这是应用约束，不是回归。
## 本版（0.1.21）相对 0.1.20 的变化

这一版给工作台加了一层**壁纸底**：进入 L 型后，背景看起来只剩"一个真实窗口在最前"，
不再露出其他应用的窗口和桌面杂乱。

### 做法

- 工作台进入时铺一块全屏窗口（`WorkbenchBackdropWindow`），显示当前桌面壁纸并轻度暗化；
- 把它**排在真实主窗口的下一层**（`order(.below, relativeTo: 主窗口 CGWindowID)`），
  其余应用窗口都被这层盖住；主窗口是别人的真实窗口，保持在最上层；
- 两栏面板铺完后重新提到壁纸底之上；窗口编号登记为自有窗口，不会被目录当成一张卡片；
- 返回总览/退出时撤掉壁纸底并注销窗口编号。

### 验证

- 自动回归：核心 155+80；宿主 **211 项（1 项既有环境跳过）0 失败**（新增壁纸底生命周期用例：
  压在真实主窗口下一层、自有窗口登记、返回后撤掉并注销）。
- 真机（探针运行中读 CGWindowList 层级）：壁纸底为 layer 0 全屏窗口，索引在主窗口之后（在其下层）、
  在其他应用窗口之前（盖住它们），两栏面板在壁纸底之上。截图权限被系统挡，改用窗口列表核对。
## 本版（0.1.20）相对 0.1.19 的变化

这一版把**进入 / 交换 / 返回三条动画全部拉满 120Hz**（真机帧间隔 p95 全部 **8.3ms**），
Mission Control 级的帧率目标达成。

### 改法

0.1.19 只把交换的真实 AX 执行后移；进入/返回仍是"动画与几何同时跑"，个别帧会掉到 16–19ms。
本版把三种过渡统一：**动画立即起飞，真实 AX 几何延后 110ms 开始**，执行前核对过渡令牌
（取消/过期整笔丢弃），常量 `AppCoordinator.transitionExecutionDelayNS`。

### 真机实测（120Hz，完整 100 轮，caffeinate 防锁屏）

| 指标 | 0.1.19 | 0.1.20 |
| --- | --- | --- |
| 进入动画帧间隔 p95 | 未单列 | **8.3ms（n=37，median 8.3）** |
| 交换动画帧间隔 p95 | 8.3ms | **8.3ms（n=100，median 8.3）** |
| 返回动画帧间隔 p95 | 8.3ms | **8.3ms（n=101，median 8.3）** |
| 进入 / 交换 / 返回 首帧 p95 | 5 / 3 / 10ms | **3 / 4 / 9ms** |
| 进入 / 交换 / 返回 落定 p95 | 128 / 253 / 256ms | **249 / 252 / 256ms**（目标 600/500/500） |
| P0-16 / P0-17 | 100/100 | **100/100，格心 0.00pt，真实 frame 无漂移** |

进入/返回的落定 deliberately 后移了约 120ms（换满帧），仍在目标内。

**如实说明**：P0-18 的正式判定还差"进入路径 120Hz 样本 ≥100"这一项——ProMotion 刷新率
随内容在 48/60/120Hz 间切换，样本被分到不同分组，本轮进入只归到 37 条；这不影响
"三条动画帧间隔 p95 已到 8.3ms"的实测结论，但正式判定仍需固定刷新率补样本。
第一轮复测曾出现交换 p95 14.2ms（运行间抖动），第二轮回到 8.3ms；已记录在验收文档。

自动回归：核心 155+80；宿主 **210 项（1 既有环境跳过）0 失败**。
## 本版（0.1.19）相对 0.1.18 的变化

这一版把**交换动画也拉满 120Hz**：真机实测交换帧间隔 p95 = **8.3ms / median 8.3ms（n=100）**，
和系统的 Mission Control 同一帧率档位。

### 根因与改法

0.1.18 已经把交互路径上的 `orderOut`（460–496ms）和飞行期观察者同步（43–101ms）移走，
但交换动画仍稳定每两帧一次（16.7ms）。真机打点显示：交换飞行的 180ms 里，真实 AX 交换步骤
一直在主线程上执行，主线程被占掉约一半，displayLink 只能隔帧回调。

改法：**交换动画先飞，真实 AX 交换延后 110ms 再开始**（动画 180ms 的前 2/3 留给满帧飞行），
用落定预算换丝滑——实测落定仍是 253ms（目标 ≤500ms），没有变慢到用户可感知。

### 真机实测（120Hz，P0 探针，锁屏前完整 100 轮）

| 指标 | 0.1.18 | 0.1.19 |
| --- | --- | --- |
| 交换动画帧间隔 p95 | 16.7–19.5ms | **8.3ms（n=100，median 8.3）** |
| 返回动画帧间隔 p95 | 8.3ms | 8.3ms（n=101） |
| 交换落定 p95 | 252ms | 253ms（目标 ≤500） |
| 进入 / 返回落定 p95 | 128 / 255ms | 128 / 256ms（目标 600 / 500） |
| 交换首帧 p95 | 11ms | **3ms（n=100）** |
| P0-16 / P0-17 | 100/100 | **100/100、格心 0.00pt、真实 frame 无漂移** |

**如实说明**：原始慢帧日志里仍有 120 帧 14–19ms（进入/返回的个别帧），
进入动画的 120Hz 分组样本只有 1 条（P0-18 要求每路径 ≥100，本轮不够，记未判）；
这些不改变"交换动画已满帧"的结论，但离"全程零丢帧"还有距离。

自动回归：核心 155+80；宿主 **210 项（1 既有环境跳过）0 失败**。
## 本版（0.1.18）相对 0.1.17 的变化

这一版按 **Mission Control 级丝滑** 的目标修主线程卡顿，真机探针已跑出接近满帧的数据。

### 根因

- 单帧 Metal 渲染只要 **0.06–0.17ms**，不是 GPU 慢。
- 掉帧来自交互路径上的主线程同步：`syncOverviewPanels` 里的 `orderOut` 单次 **460–496ms**；
  飞行期间 `updateObservers` 单次 43–101ms。两者都会直接挤掉 displayLink 的 tick。

### 改动

- **总览面板交互期不再下屏**：收起改为 `alpha=0 + ignoresMouseEvents`（`hideCheaply`），
  真正的 `orderOut` 只留到隐藏/退出/换屏时做；对外 `isVisible` 语义不变（状态机/测试仍看到"已收起"）。
- **飞行期间推迟 AX 观察者同步**：场景结束统一补一次，不再让 43–101ms 的订阅重排打断动画。
- 保留 `[帧]`（每段动画绘制/间隔 p95）与 `[主线程]`（performSync 分步耗时）诊断日志，方便继续调。
- 新增回归：`testCheapHideKeepsWindowOrderedForCheapHandoff`（收起后仍 ordered、alpha=0、不接鼠标；
  真正 `hide()` 才下屏）。

### 真机实测（120Hz，P0 探针，锁屏前）

| 指标 | 0.1.17 | 0.1.18 |
| --- | --- | --- |
| P0-16 交换落定 p95 | 624–640ms | **252ms**（目标 ≤500，达标） |
| P0-17 进入 / 返回 p95 | 498–750 / 298–323ms | **128ms / 255ms**（目标 600/500，达标） |
| 首帧 p95（热路径） | 345–422ms | **11ms**（目标 ≤50，达标） |
| 返回动画帧间隔 p95 | 24–40ms | **8.3ms**（120Hz 满帧） |
| 交换动画帧间隔 p95 | 21–26ms | 16.7–19.5ms（仍略高于 8.33，下一步） |

第二轮复测在 28/100 轮被系统锁屏中断（`screenLocked`），不是回归；锁屏前 P0-16 100/100。
自动回归：核心 155+80；宿主 **210 项（1 既有环境跳过）0 失败**。
## 本版（0.1.17）相对 0.1.16 的变化

这一版做**性能与动效优化**。先用内置 P0 探针在真机上量了 0.1.16 的基线（100 轮真实点击）：

| 指标 | 0.1.16 实测 | 目标 |
| --- | --- | --- |
| 固定交换 100 轮 | 100/100 收敛，点击→落定 p95 **623ms** | ≤500ms |
| 往返：进入 / 返回 p95 | **750ms** / 323ms | ≤600 / ≤500ms |
| 点击→首帧 p95 | 进入 **549ms**、交换 **421ms**、返回 **110ms** | ≤50ms |
| 过渡帧间隔 p95（热路径） | 进入 **47.8ms**、交换 25.8ms、返回 29.2ms | ≤20ms |
| 帧预算 | 271 段里 163 段超预算 | — |

本轮针对性改动：

- **预建过渡承载层**：打开总览时就为各屏建好承载窗口、图层与首块 drawable，
  把窗口/图层/纹理分配从点击路径挪走（首帧延迟里的冷启动成本）。
- **hover/点击预取主区分辨率画面**：总览卡片或轨道卡片 hover 90ms（或点击）即按主区宽度抓一帧，
  过渡飞行优先用它，不再把轨道/总览尺寸的画面放大成“糊”的画面。预取有 400ms 节流与 5s 新鲜度上限，
  不会因为划过多张卡片而连发抓帧。
- **飞行期间推迟捕获重配**：过渡动画在屏上时，捕获层同步会与 displayLink 抢主线程；改为飞行期间
  暂缓 `capture.sync`（≤240ms），场景结束立刻补一次——这是帧间隔抖动的已知来源之一。
- 新增诊断：`[首帧] 场景=… 距输入=Nms` 与 `起飞→呈现=Nms`，把“点击→场景起飞”和“起飞→首帧呈现”分开记录。

自动回归：核心 swift-testing 155 + XCTest 80；宿主 **209 项（1 项既有环境跳过）0 失败**；
新增用例钉住“总览打开即预建承载层”“hover 触发主区抓帧”。

**未完成（如实说）**：优化后的真机复测在 08:51 被系统锁屏挡住（`CGSSessionScreenIsLocked=1`、`activeDisplays=0`），
探针按判据记未测。上面的基线已成立，但“优化后 p95 是否达标”**还没有数字**，解锁后需要用同一探针复跑，
不能拿自动回归代替性能验收。

## 本版（0.1.16）相对 0.1.15 的变化

这一版修**总览没有置前**，并按实机日志优化**切换窗口的卡顿**。

### 总览置前

从菜单栏/快捷键打开总览时，会先激活 App 再把每屏面板置前。之前只在自己的进程里
`orderFrontRegardless`，App 不是活动应用时，前台应用的同级窗口仍可能盖住总览。

### 切换窗口：砍掉 2 秒级的句柄复核停顿

用统一日志还原了 0.1.15 的真实切换耗时（同一台机器、非代理环境）：

- 正常交换：点击 → 提交约 **250–300ms**（准备 69ms、B 写入 69ms、激活 12ms、A 回轨 96ms、提交 4ms）。
- 异常样本：07:08:42 与 07:09:45 两次都卡约 **2.14s**，最后报「拿不到 AX 句柄（身份未唯一确定）」；
  性能样本里出现过 `工作台:主区交换 = 2180.8ms`。根因是 `WindowCatalog.axEntryAfterReview` 的
  兜底预算是 **2.0s**：目录某轮 AX 读取超时会把整代句柄变成空，复核循环不断整轮刷新（每轮读所有应用），
  几何路径就一直等在"模糊的过渡代理"里。

改动：

- **交互路径的句柄复核预算 2.0s → 1.0s**（恢复/退出仍保留 2.0s：宁可慢也要还原正确）。
- **可调尺寸窗口不再做多余的可写性探测**：放置策略只看"能不能 resize"，每笔少一次跨进程请求
  （实机 5–20ms；读超时可达 0.35s）。固定尺寸/不可移动窗口仍会探测，最终判据仍是写后读回。
- 每一步交换都往统一日志写**耗时**：`[交换] 步骤=… 耗时=Nms 结论=…`，下次再优化有事实依据。

**未做**：没有为了"看起来快"缩短动画时长（交换仍 180ms 动效）；没有改变实体窗口的落位与校验判据。
**仍未测**：0.1.16 的真机复测——升级后点几次切换，看日志里每步耗时与是否还有 ~1s 的复核停顿，
才能确认这次优化在真实应用上的效果。

## 本版（0.1.15）相对 0.1.14 的变化

这一版解决一个实际阻塞：**无代理网络下 GitHub 的 release 直链下载不下来**。
本机实测（不走代理）`github.com/misswell/Vistile/releases/download/…` 25 秒 0 字节超时，
而 `api.github.com` 与带代理的下载都正常——所以问题不在包，在下载通道。

### 下载镜像（自有服务器，国内直连）

安装包现在同时放在自有域名镜像上，位置规则
`https://autocrop.liuguofeng.com/vistile/releases/<tag>/<文件名>`，旁边有同名 `.sha256` 校验文件：

- 本版 dmg：<https://autocrop.liuguofeng.com/vistile/releases/v0.1.15/Vistile_v0.1.15_macos_arm64.dmg>
- 校验文件：<https://autocrop.liuguofeng.com/vistile/releases/v0.1.15/Vistile_v0.1.15_macos_arm64.dmg.sha256>
- GitHub 直链仍然保留（有代理时可用），但**更新弹窗默认给镜像**。
- 已实测：镜像直连 200、2,420,xxx 字节、sha256 与 GitHub 发布资产一致；
  `ghfast.top` 前缀（第三方代理）作为备用也验证过字节一致，但**不默认使用**——安装包只从自有域名取。

### 更新通道改成镜像优先

- 弹窗按钮顺序：**从镜像下载** → 打开 GitHub 发布页 → 稍后 → 跳过此版本；没有安装包资产时退回发布页。
- 弹窗正文写明镜像来源、`.sha256` 校验地址，以及"GitHub 直链可能超时"的提示。
- 核心 `UpdateChannelPolicy` 为每个可用版本同时给出：自建镜像地址、校验文件地址、GitHub 直链。
  旧的 0.1.14 更新弹窗只会打开 GitHub 直链，所以**本版需要手动从上面镜像链接下载安装一次**；
  从 0.1.15 起，后续版本的自动更新提示会直接走镜像。

回归：核心新增 3 条（镜像 URL/校验 URL、无资产时无镜像、文件名编码），宿主更新检查用例补镜像断言；
核心 155 + XCTest 80，宿主 206 项 0 失败。

**仍未测**：镜像下载在 Safari/系统下载器里的手工验收、弹窗四个按钮的真实点击路径；
每发一版仍需把 dmg 与 `.sha256` 手动上传到镜像目录（发布流水线尚未自动同步到自有服务器）。
## 本版（0.1.14）相对 0.1.13 的变化

这一版包含两部分：**修复 0.1.13 的实机卡死缺陷**，以及**新增 GitHub Releases 更新通道**。

### 修复：交换一次之后界面不再响应（0.1.13 实机问题）

现场：进入工作台后点一次 L 型内交换，日志出现
`事实追加失败 原因=日志序号已过期（期望 7，当前 8）：update … 未写入`，随后界面不再响应任何点击，
日志里持续报"过渡/交换在途"。根因是两处叠加：

- **日志追加的守卫用错了维度**：`updateJournal` 拿日志**全局 revision** 当守卫。日志是会话级共享的，
  退出清理、布局结算、同窗口排队结算都会推进它；无关写入一前进，本次交换的第一条事实就被判成"过期"。
  0.1.13 实机「期望 7，当前 8」即此。现在守卫改为"**条目仍存在**"：无关写入不影响；条目已被补偿清理后
  才拒绝迟到写入（不会把结清的事务复活）。
- **失败收口走错分支**：写前事实落盘失败被 reducer 当成"写后失败"，发出 `.drainGeometry`；
  宿主收到排空入口就 `switchCoordinator.cancel()` 交还会话所有权，而这次交换的失败结论
  （`mainSwitchFailed`）正是由那条在途链补偿后回报的——先取消它，回报就被门禁全挡掉，
  状态机永远停在 `rollingBack`，之后点击全被"交换在途"吞掉。现在操作自身的日志失败**不再发排空**
  （排空只属于隐藏/退出入口），由在途链补偿后如实回报，界面立刻恢复可操作。

回归：宿主新增 3 条（无关写入不判死 / 写前失败收口 / 写后失败收口）、核心新增 2 条（交换中日志失败不发排空、
最小化恢复失败进补偿事实后收口），存储层新增 1 条守卫语义用例；全套仍然全绿。

### 新增：GitHub Releases 更新通道

- **菜单「检查更新…」**：手动检查，不受节流与开关限制；发现新版本弹窗给「下载并打开 / 稍后 / 跳过此版本」。
  下载优先 arm64 dmg 直链，没有安装包资产时退回打开发布页。
- **启动后静默检查**：延迟 3 秒、**24 小时节流**（GitHub 未认证 API 限额 60 次/小时），
  只有发现新版本才提示；可在设置里关闭自动检查。选择「跳过此版本」后同一版本不再自动提示，手动检查仍会展示。
- **判定逻辑在核心包**（`UpdateChannel.swift`）：版本比较（逐段数值，`v` 前缀/预发布后缀兼容）、
  release 选择（忽略 draft，按仓库既有约定把 prerelease 算进通道）、资产挑选（arm64 dmg → 任意 dmg → zip）。
- **接缝可测**：网络取数、当前版本、时钟全部注入；8 条宿主用例覆盖新版本、已最新、prerelease、
  跳过版本、24h 节流、关闭自动、坏 JSON、GitHub 限流提示。**没有**引入第三方更新框架，也不做静默自动安装。

**仍未测**：更新弹窗与真实 GitHub 下载在一次真实桌面里的手工验收（本轮只有接缝级自动回归）；
§19 真机矩阵 M01–M14、§20 性能数字、30 分钟长跑、录屏、强退恢复实机全部保留未测，仍然不能宣布整体验收通过。

## 本版（0.1.13）相对 0.1.12 的变化

这一版执行**第二轮代码审查**（基线 `1235207`）的 6 项缺陷修复与 3 项同轮加固，**不改交互模型**：仍是总览先行、
点卡片进 L 型、交换只动两个窗口、返回保留上下文、隐藏恢复原窗。

- **日志批次成为完整串行事务**（C01）：`WindowJournalStore` 原先在锁内先写共享暂存、再异步落盘，失败回滚会把后来批次的
  暂存一起抹掉——最坏情况是"已失败的 A 被后来批次的落盘冒充为已提交"，或"已报成功的 B/C 被下一批静默抹掉"。
  现在"取快照 → 应用 → 编码 → 落盘 → 提交"整段在一个串行事务里，失败批次不提交任何状态，后续批次必然基于最新已提交内容；
  `revision` 改为加锁读取。日志落盘还留了可注入接缝，故障路径可以确定性复现而不是只能靠真磁盘坏掉。
- **最小化解除进入写入许可与补偿链**（C02）：`setMinimized` 现在带 `GeometryWritePermit` 并在 AX 队列内部复查；
  解除成功当场登记可逆副作用，7 条提前返回路径都走恢复授权把它收回去；补偿先回位几何、再恢复最小化。
  许可撤销后队列里那笔命令零执行，不会再出现"Vistile 已隐藏、窗口却被展开着"。
- **新会话清队列不再让等待者悬挂**（C03）：`openSession()` 逐项 `skip(.sessionChanged)`，`skip` 成为队列项唯一终态函数，
  每个已接收任务恰有一个终态。
- **操作前快照以宿主写前实读为准**（C04）：`WorkbenchCompensationResult` 新增 `beforeReads`，reducer 判定"回滚是否成立"
  优先用实读事实——用户在 Vistile 之外移动过窗口后，正确的补偿不再被误判成 `recoveryRequired`；
  目录缓存 frame 只作乐观预检，可移动且主区有效时交给宿主按实读重新决策。
- **`drain(until:)` 的截止真正可到期**（C05）：静默与截止在调度器内部竞速，先到者结算；到期后不再启动新的恢复写入，
  未完成的事务照旧留在日志里等下次启动核对。
- **通道身份取代全局深度**（C06）：`laneDepth` 换成 `@TaskLocal` 通道令牌，独立任务即使在 `await` 期间到达也必须排队；
  补偿/恢复的合法嵌套仍就地执行。
- **同轮加固**（C07–C09）：写前实读的 original 修正与操作前快照**同批落盘**（少一次磁盘往返、没有中间分叉）；
  最小化恢复失败进入补偿事实（`unresolvedMinimizeRestorations` 非空即转 `recoveryRequired`，不再假装回滚完成）；
  settlement backlog 落盘接入同一可注入接缝。

回归面：核心包 swift-testing 155 项（16 suites）＋ XCTest 69 项，宿主 194 项执行、1 项既有环境跳过、0 失败；
受影响三套（Entry / Divider / Switch）重复 5 轮共 265 项 0 失败。新增 17 条确定性用例，全部用可控 gate /
fake clock / 可核对动作序列，没有新增 sleep 赌时序。

**这一版没有做完的部分（照实说）**：§19 真机矩阵 M01–M14、§20 性能数字、30 分钟长跑、录屏、强退恢复实机
**全部保留未测**——本轮没有新增任何真机数字，代码与替身回归不等于真实桌面交互验收。逐项状态与遗留风险见
[Docs/Acceptance.md](Docs/Acceptance.md) §12。

## 本版（0.1.12）相对 0.1.11 的变化

这一版**不改任何交互与几何行为**，改的是"数字怎么被量出来"和"回归是不是在赌机器快"。

- **性能样本按环境分组**（方案 §20.2 要求「60Hz/120Hz、reduceMotion、冷启动/热路径分别分组」）。0.1.11 的读数全部是
  **合池**的：`Metrics` 只按指标名聚合，名字里没有环境维度，于是"120Hz 热路径很快"与"60Hz 冷启动很慢"被平均成一个
  谁都对不上的数字。现在每条时长/帧样本的指标名带分组键 `档位·reduceMotion=开|关·冷启动/热路径`，逐组各算各的 P95；
  档位把 59.94/119.88 归一成 60Hz/120Hz，读不到刷新率时写「刷新率未知」而不是假装 60Hz；冷启动＝该场景在本进程里的
  第一次飞行。每组不足 100 次操作按 §20.2 写**未判**——既不写达标也不写未达标。
- **补上一条写了却没人测的判据**：「短场景累计至少 1,000 个有效间隔」以前没有测量支撑——报告里只有"段数"
  （一次过渡算一段），段内到底有几条有效间隔从未计数，所以这条门既判不了、也不会被如实记成未判。
- **`点击→落定` 另留一行合池概览**，报告里明写"只作概览，判定看逐组行"，不用合池数字顶替分组结论。
- **回归不再赌墙钟**：CI 首跑红、同一提交重跑绿的两条宿主用例（过期令牌补偿、减少动态效果）根因都在时钟上——
  一条在等"1 秒内出现第二笔写入"，一条拿测试自己读的 `CACurrentMediaTime()` 与播放层内部盖的起点抢时间，
  机器一慢"中点"就落到终点之后。**断言判据没变**，只把触发时机换成事件（起点注入、替身报信、调度器栅栏）。
- **仍然未测**：本版没有新增任何真机数字。§19 的 M01–M14、§20 的性能数字（分组后每条都要重取）、30 分钟长跑、
  录屏、强退恢复实机全部保留未测。也正因为口径改了，**0.1.11 那批合池数字不再能当本轮证据**——解锁后要在 0.1.12 上重跑。
  逐项状态见 [Docs/Acceptance.md](Docs/Acceptance.md) §11.10、§11.11、§11.12。

## 本版（0.1.11）相对 0.1.10 的变化

这一版**不改交互模型**（仍是总览先行、点卡片进 L 型、交换只动两个窗口、返回保留上下文、隐藏恢复原窗），改的是这些行为下面的写入时序、失败补偿的真实性、退出期限、日志原子性、捕获调度，以及性能测量的口径。执行的是《Vistile 修复方案（基线 66e8d26）》的 R01–R10，逐项状态见 [Docs/Acceptance.md](Docs/Acceptance.md) §11。

- **真实 AX 写入只有一条通道**（R01）：新建 `GeometryOperationScheduler`，每次操作带会话代次 + 操作身份；取消或隐藏时先撤销普通准入再排空队列，之后只允许"恢复授权"的写入。迟到的回调不再改新会话的状态，也不会出现退出恢复后又被写一笔。
- **交换失败与退出恢复是两套目标**（R02）：失败补偿回到**操作前**（A 仍在主区、B 仍在原位），退出才回会话 original。补偿按逆序执行，且会把"哪些窗口真的动过"如实回报，不再出现"已回到 original 却宣称旧主还在主区"。
- **日志失败不再卡住状态**（R03）：批量 `prepare` 改异步且原子（第二条失败则整套不成立）；写后落盘失败单列并进补偿；老日志缺新字段按"未写入过"读入。
- **跨屏恢复只规划一次**（R04）：不再按当前屏二次夹取；原屏被拔或分辨率变化时给合法回退目标并记原因。
- **固定尺寸窗口改为仅移动**（R05）：真实原尺寸放得下就只写 position，不写 size；放不下明确拒绝而不动其它窗口。`constrained` 读回要先证明确实落在主区内才可提交，否则有界纠正后补偿。
- **关闭主窗口的替补成为完整事务**（R06）：建事务 → 写入 → 激活 → 提交；一次关闭只自动试一个候选，武装期间用户手动选择顶掉自动替补。
- **总览格子满了也能进轨道**（R07）：展示成员与总览位置解耦，超出格子的窗口仍进 L 尾部，其它位置不动。
- **返回再入不再把滚动归零**（R08）：栏内偏移成为唯一事实源，按内容长度与栏尺寸 clamp。
- **捕获按可见性分级**（R09）：`transition/visible/prefetch/offscreen/paused` 五档，离屏窗口不再挤占可见工作集，也不阻塞可见流恢复直播；过渡期间重配合并到下一周期。
- **退出期限不再靠 `TaskGroup.cancelAll` 赛跑**（R10）：单一恢复所有权 + 有界等待 + 到期留痕，期限后不启动新的恢复写入。

测量口径（方案 §20.2）也重做了一遍，端点清单在 [Docs/Performance.md](Docs/Performance.md) §3.8：
所有时长改走单调时钟（墙钟只用于日期）；**点击→首帧延迟单独记录并锚在真实输入上**（探针直接派发、没有点击锚点的段单列，不混进"点击反馈"P95）；
新增 `过渡零呈现段` / `过渡回调多于呈现` 两个计数，把 display-link 回调次数与真实 present 次数分开核对；
journal prepare、journal 事实追加、AX 排队、几何写入、写后读回、激活+Raise、布局结算各自打点。
探针侧 `P0-18` 现在按"每条路径 n≥100 才判、不足标未判"，`P0-19` 输出每个被写窗口的 original/before/target/readBack/displayID 对照表。

回归面：核心包 swift-testing 148 项 + XCTest 64 项，宿主 180 项（1 项因取不到真实前台激活而显式跳过，不计为成功）；
方案 §18 的 A01–A42 每条都有确定性用例（可控 gate / fake clock / 可核对动作序列，不靠 sleep 赌时序）。

**这一版没有做完的部分（照实说）**：§19 真机矩阵 M01–M14 与 §20 的性能数字**还没在 0.1.11 的发布字节上跑过**，
录屏、强退恢复实机、固定尺寸真实应用、中文输入体验、30 分钟长跑全部保留未测；
[Docs/Compatibility.md](Docs/Compatibility.md) 本轮新加的「激活」「输入」两列因此整列为未测。
按方案 §22 的验收通过条件，**本版不能宣布整体验收通过**——代码项与自动回归完成，真机与性能两项还是空的。

## 本版（0.1.10）相对 0.1.9 的变化

0.1.10 是工作台改版（《Vistile 工作台修改方案 2026-10-16》M0–M3）的第一个版本：**打开仍是全屏总览；点一张卡片后，被点的真实窗口进主区，顶部与侧栏出现两条预览轨道（L 型），其余窗口留在原地**。主副交换、返回总览、失败回滚都走既有几何事务链路；预览面板不持有键盘，主区永远是真实窗口。

### 交互模型（相对 0.1.9 的产品变化）

- **先总览，点卡片才进工作台**：进程启动/重开固定进总览，不记忆上次模式；未点击前不写任何窗口几何、不显示两栏（`P0-15`）。
- **主副交换只动两个窗口**：每次交换只把"新主"写进主区、把"原主"写回它原来在总览里的格子位置；其余窗口的真实 frame 一个不动，总览快照（格子、搜索词、滚动位置）冻结不重排（`P0-16`/`P0-17` 的"非参与窗口对照"）。
- **真实输入不与预览争**：主区是真实窗口本身（中文候选、右键、菜单栏、Sheet 都落在真实应用里）；两栏是 Vistile 自己的预览面板；分隔线拖动只做预览、AX 写入按 15–20Hz 节流、松手落定。
- **过渡可打断（latest-wins）**：总览↔L 型、A/B 交换的动画都按"只在前次副作用收敛后处理最终目标"实现；快速连点不回放、不排队。
- **动效分级降级**：完整→轻量→淡化，压力或"减少动态效果"下退化但不改变最终布局；过渡期间采 60Hz 帧间隔样本（`P0-18`）。
- **设置迁移（方案 §16）**：轨道左右侧、紧凑模式、主区尺寸限制、溢出行为（滚动/省略）、pin 与整理顺序；旧键（含标题派生的优先刷新键）启动时清洗为应用级标识并记迁移备注。

### 探针为这套模型新增 7 项自动验收（P0-12…P0-18）

与产品改动同一版进包：`P0-12` 工作台进入与真实读回偏差、`P0-13` 主副交换（只提升被点窗口、其余不动）、`P0-14` 返回一致、`P0-15` 总览先行、`P0-16` 固定交换 100 次（顶栏 50＋侧栏 50，点击→落定 p95）、`P0-17` 往返 100 次＋非参与窗口 frame 对照、`P0-18` §20.2 帧预算与样本量。判据全部是真实点击＋读回证据，不读内部状态自证。

### 实机轮次与修复（0.1.10+16…+24）

在 `/Applications/Vistile.app`（同一 Developer ID）＋授权桌面上连跑八轮（+16…+23；+24 是修复轮，复跑见下），每轮失败都先定位到根因再修，没有一轮是"重跑碰运气"：

| 轮次 | 结果 | 失败形状 → 修复方向 |
| --- | --- | --- |
| +16 | `P0-12/13/14` 转通过；`P0-16`=2/100、`P0-17`=12/100 | 窗口服务器几何提交滞后 AX 约 0.6s，目录采样把刚移动的窗口判成"未唯一"、点击被拒 → 复核后再判（+17） |
| +17 | `P0-16`=6/100、`P0-17`=21/100 | 一次 AX 读超时被目录折叠成"不可调整尺寸"，写前守卫拿坏采样当事实 → 写前直接问窗口一次，读不到≠不可写（+18） |
| +18 | **诊断轮**：`P0-16`=1/100（第 2 次交换后会话静默退出）、`P0-17` 未测 | 焦点核对把一次 AX 读回失败／自己的唤起通知当成失焦证据 → 焦点阶梯（+19）；另两处探针取样时机同时修 |
| +19 | **诊断轮**：`P0-16`=3/100、`P0-17`=9/100 | 被点身份瞬时未唯一时宿主静默丢掉点击 → 点击复核重试约 2s＋提示留痕（+20）；焦点阶梯修复后本轮零静默退出 |
| +20 | `P0-16` 转通过（100/100，p95=384ms）；`P0-17` 红 | 241.0pt"漂移"是探针单次取样撞上提交滞后窗口的误报（独立快照证明窗口已在原位）→ 连续两次读到同一偏差才判（+21）；另抓到两条幻影提示「窗口尺寸未能恢复」→ WorkbenchReducer 同步收口（+21） |
| +21 | **诊断轮**：`P0-16`=19/100、`P0-17`=11/100＋真实漂移 | 句柄路径"一个坏采样就判死" → 句柄取不到先带截止时间复核目录 `axEntryAfterReview`（+22） |
| +22 | **诊断轮**：`P0-16` 转通过（100/100，p95=552ms）；`P0-17`=3/100 | Chrome 位置写入报 -25204、读回其实已在目标位——错误码压过读回 → 分类读回优先；漂移基线采样在滞后窗口内 → 稳定基线；外部应用自播动画 → 漂移分账（+23） |
| +23 | **诊断轮**：`P0-16` 通过（100/100，p95=554ms）；`P0-17`=61/100 | 写入双侧错误码=0、单次读回读不到被当终审（32ms 后恢复路径就读到了）→ 写后读回有界重试 3×70ms（+24）；幻影提示与真实漂移本轮消失 |
| +24 | （复跑中，见下面"要定性"一段） |  |

每轮的原始报告、日志与快照在 [Docs/Evidence](Docs/Evidence/README.md)（+18 起另留 `-live-log.txt`/`-snapshots.txt` 原件）；逐项结论在 [Docs/Acceptance.md](Docs/Acceptance.md) §1。

### +24 复跑要定性的事

- `P0-17` 能否走满 100/100（+23 那轮停在第 62 轮的单次读回失败上）；
- `P0-18` 能否在长跑轮次凑够 ≥100 帧样本并给出 §20.2 的每路径结论；
- `P0-3`/`P0-4`/`P0-9` 在解锁桌面上的复跑（+23 那轮中途锁定段按"未测"记，不作产品结论）。

### 发布与复跑基线（run12 起跑发布字节）

- `v0.1.10` 已发布：Release run [`38947484361`](https://github.com/misswell/Vistile/actions/runs/38947484361) checkout 的是 `v0.1.10` → `ceb7f01`，`verify` 回了「`v0.1.10` 与 `Info.plist` 的 `0.1.10` 一致」。CI 在 macos-14 / Xcode 16.2 上重新构建、签名（Developer ID U8U443D7ZL）、公证：runner 侧公证成对（`.app` 18:31:13 `Accepted`、`.dmg` 18:31:45 `Accepted`，两次 `staple worked`），`spctl --status` = `assessments enabled`，产物回 `accepted / source=Notarized Developer ID`。
- 发布字节已本机复核并覆盖装回 `/Applications/Vistile.app`：dmg **1995501 字节**、`sha256 4ac65158…86af`（与资产接口 `digest` 逐字节相同），包内二进制 `sha256 9f830aa5…a40f`；dmg 与包内 app 的 `stapler validate` 都回 `The validate action worked!`，证书链到 `Developer ID Application: Guofeng Liu (U8U443D7ZL)`（同签名身份，授权保留，不需要重新授权）。**上面那张表里的 +16…+23 跑的是各轮本机 Xcode 27 构建（`5f7e8ae8…` 是 +24 本机构建，从未被任何一轮跑到）；run12 起跑的才是 CI 构建的发布字节**（与标签同源码，含全部 +24 修复）。

### 回归测试

- 核心包（`swift test`）：swift-testing **147 项 / 15 个 suite** ＋ XCTest 46 项，全过（EXIT=0）。
- 宿主测试（`VistileHostTests`）：**157 项执行、1 项跳过、0 失败**（`xcodebuild test`，2026-10-17 02:24，EXIT=0）。跳过项只有 `T01ActionRoutingTests.testKeyboardFocusReallyLandsOnContentView`（"宿主未取得前台激活：面板实际 isKey 依赖系统前台，需在实机/P0 验证"）——按方案 §22 这项**不计为成功**，属实机待验。M0–M3 的 W/H 用例覆盖、每项结果与 skip 原因见 [Docs/Acceptance.md](Docs/Acceptance.md) §7。
- **P0 仍未通过。** 人工与录屏项一律「未测」；"未测"不等于"已修复"。工作台的其余未证部分（稳定遮挡、全屏 Space、Stage Manager、30 窗口性能曲线）同前版，见 [Docs/Architecture.md](Docs/Architecture.md) §10。

## 本版（0.1.9）相对 0.1.8 的变化

0.1.8 发布后在正式版上跑了四轮，前三轮（18:14、18:17、18:27）全程 0 帧、AX 一个窗口都解析不出来，第四轮（18:33）有帧。**这四轮把根因定死了：这台机器当时锁着屏。** 判据不是猜的——锁屏状态下用 `osascript` 问 Code / Finder / Qoder 的 `count of windows` 一律回 **0**（而 `UI elements enabled` 回 true），本机 `CGSessionCopyCurrentDictionary` 回 `CGSSessionScreenIsLocked = 1`，`screencapture` 抓出来就是锁屏界面。也就是说：**权限预检回 true，整个会话却读不到任何应用的 AX 窗口列表**。那种轮次里 P0-3 记的「Raise 没有发出（拿不到 AX 句柄）」、P0-4 与 P0-9 记的「没有可放大的窗口」都是环境产物，不是产品结论——而它们以前被记成**失败**。本版改的就是"环境不许替产品下结论"：

- **环境自检从一条扩成两条**（自动项仍是 14 条，只是这一项自己说全）：除了"本轮有没有帧"，还报"有没有一个窗口解析得出 AX 索引"，并把**会话锁定**读数写进同一行；哪一类结论作废，逐条点名（依赖帧的 P0-2/P0-9/P0-10/性能采样、依赖 AX 的 P0-3/P0-4/P0-9）。
- **P0-3 加前置条件**：辅助功能预检为真、且目录里至少有一个窗口解析得出 AX 索引，才进入判定；不满足记**未测**并写清缺什么。写法和别处不一样的一点是它**不把锁定当挡箭牌**——锁定与未锁定分别给话术，"没锁屏却一个都解析不出来"明确写「这条要当产品问题查」。判据本体一个字没改：仍是共同在场窗口的两两比较，"没发出去"与"发了没生效"都算红。
- **P0-10 的判据从"有流就行"收紧成"这 2s 真的有回调"**。0.1.8 实测到一个以前没见过的形状：10 路活跃流、全程 0 帧，旧判据据此记「通过」——可那是**没有回调**，不是**有回调而没改写**。现在进场先等到目录真的来一帧，等不到就记未测；有帧时仍要求"2s 内层级改写 0 次"。**这是收紧，不是放宽。**
- **P0-9 的两处等待同样改成按帧**：进场前与回到总览后各等一次"目录真的又产帧"，不再信"流计数回到非 0"。判据 `present > 0` 没动。
- **0.1.8 那轮（18:33）已经拿到的结论，本版一并认账**：P0-7 **第一次转通过**（缺布局 0、已算出布局 1 屏、网格 1 屏、活跃流 10 路）——这是 0.1.7 那批取数时机改动第一次在非作废轮次里得到检验；P0-2 通过（10/10 被遮挡窗口在 1.5s 内收到新帧，全目录 90 帧≈58.1 帧/秒）；P0-10 在有回调的 2s 里层级改写 0 次。同一轮 P0-3 仍然红，但红的成因是锁屏读不到 AX，本版之后这种轮次不再记红。
- 回归测试仍是核心包 **137 项 / 14 个 suite**、宿主 **85 项**：本版改的全在探针（App 层），没有新逻辑进核心包；P0-3 前置条件的复现步骤就是上面那两条读数。
- **P0 依然没有通过**。P0-3/P0-4/P0-9 需要在一台**解锁且唤醒**的桌面上重跑才算数；人工与录屏项一律还是「未测」。见 [Docs/Acceptance.md](Docs/Acceptance.md)。

## 本版（0.1.8）相对 0.1.7 的变化

0.1.7 发布并核过产物之后，读代码又发现两处**同一族**的取证洞，本版只补这两处，产品代码路径没动：

- **「层级」这一列以前永远变不成「通过」。** 0.1.6 收回两处代填时，`updateRow` 只留在 P0-3 的**失败分支**里，通过分支一行不写。于是 17:46 那轮 P0-3 两个多窗口应用都判通过，报告的机器生成矩阵里 Code 与访达的「层级」两格仍然是空的——文档里那两格是靠人把正文那一行的判据抄进去的，不是探针写的。现在通过分支同样写 `.passed`；「这一列只由 P0-3 写」这条规则（0.1.6 立的）和判据本身一个字没改。
- **P0-10 也改成先起流再取数。** 0.1.6 与 0.1.7 两轮它都记成「当前没有活跃捕获流，无回调可对照」，而同一轮更晚的性能采样有 12 路流——和 0.1.7 给 P0-9 修掉的是同一族取样时刻问题。现在进场后最多等 4s，直到至少一路流活跃再取 before/after，等不到就在读数里写清"等 4s 没起流"。**判据仍是"有直播流的那 2s 内层级改写必须 0 次"，没有放宽。**
- 回归测试与 0.1.7 相同：核心包 **137 项 / 14 个 suite**、宿主 **85 项**。两处改动都在探针（App 层）里，测试面没变。
- **本版复跑要定性的是三件事**：0.1.7 改过的 P0-7（布局是否真的算出来了）与 P0-9（回到总览后流重起的增量），P0-3 通过时「层级」格能否由探针自己写上，以及 P0-10 能否第一次给出"有流期间改写 0 次"。P0 仍未通过，人工与录屏项一律还是「未测」，见 [Docs/Acceptance.md](Docs/Acceptance.md)。

## 本版（0.1.7）相对 0.1.6 的变化

0.1.6 在已授权正式版上跑了两轮，两轮都是同一个包、同一条命令：

- **17:37 那轮整轮作废。** 全目录帧增量 0、present 0、15 个窗口里只有 5 个能解析出 AX 索引，于是 P0-2「0 个窗口收到新帧」、P0-3「Raise 没有发出（拿不到 AX 句柄）」、P0-9/P0-10/性能采样的 0 全是同一个环境产物。17:46 复跑时这些数字全回来了（15/15 可解析、38 帧、P0-3 两个多窗口应用**都判通过**：Code 目标 #15→#8 而兄弟 #13→#13，访达目标 #29→#7、兄弟 #20→#14 但对仍在场的窗口一个便宜都没占）。**问题不在判据，在那一刻能不能取到证据**——所以本版把"本轮到底有没有帧可判"变成探针自己写出来的事实。
- **修掉第二处会销毁证据的时序。** 上一版把归档加在探针入口，可协调层在启动时就先写了两行事实（全局快捷键 / Metal 渲染），**上一轮的原件在这之前就被就地覆盖了**，探针随后归档到的是自己刚写的那两行——0.1.5 的原始报告就是这样没了（本轮数字是从会话转录里恢复的）。现在保命动作挂在「本进程第一次写盘」之前，谁先写都不再能覆盖上一轮；宿主新增一条用例直接复现这个事故形状（**84 → 85 项**）。每轮跑完还把三份原件拷进 [Docs/Evidence](Docs/Evidence/README.md)，桌面上的报告只有一份，不该是唯一的一份。
- **依赖帧的项不再在"0 路活跃流"的瞬间取增量。** 放大与收回会把捕获流停掉再重起：0.1.6 那轮 P0-9 就取到了 `present +0、捕获帧 +0（0 路流）`，而同一轮更早的 P0-2 有 38 帧、更晚的性能采样有 12 路流 184 帧——那是取样时刻，不是链路断了。P0-9 现在要求"总览可见且至少一路流活跃"才进场（不满足记未测并写清缺什么），回到总览后等流重起、再留 1 秒落定才取 after 快照；P0-7 把当时的活跃流数一并写进读数。**`present > 0` 与"有窗口的屏幕必须都有承载窗口与布局"两条判据一个字没改。**
- **新增自动项「运行环境自检」**（自动项 13 → 14）：窗口数、AX 可解析数、活跃流、本次启动累计捕获帧与累计 present。全程 0 帧时这一项明确写"依赖帧的 P0-2/P0-9/P0-10/性能采样 全部不能当产品结论，请在唤醒状态下重跑"，同一句话拼进 P0 汇总——读者不用再从四个 0 里反推环境。
- 纯逻辑测试仍是 **137 项 / 14 个 suite**（本版没动核心包），宿主 **85 项**。
- **本版复跑要定性的是 P0-7 与 P0-9**：0.1.6 可用那轮（17:46）这两格是仅存的自动失败，而本版改的正是它们的取数时机。P0 仍未通过，人工与录屏项一律还是「未测」，见 [Docs/Acceptance.md](Docs/Acceptance.md)。

## 本版（0.1.6）相对 0.1.5 的变化

0.1.5 的实机复跑把 P0-4 从"未测"变成了通过（进场清场生效），同时留下三条红：P0-3 的 Chrome 与访达、P0-7 的"缺布局 2"，外加一条"过渡超时"。本版做的是**让这三条能被分辨的取证改动 + 一处证据保全缺陷**；判定条件一条没放宽：

- **P0-3 的判据下沉到核心包，改用两两比较。** 旧判据拿 `CGWindowList` 的**绝对下标**前后相减，可两次读数之间只要有无关窗口开合，整张表就平移，"兄弟 #21→#20"这种余波会被判成连带提升（访达那条红疑似就是这个）。新判据 `TargetRaiseAudit` 只在"前后两次都仍在屏上的窗口"里比较：目标必须升到兄弟之前，兄弟不得把任何**仍在场且原本在它前面**的窗口甩到后面。核心包 6 条单测两头钉住——既有直接复现访达那轮形状的用例（无关窗口关闭不算提升），也有"目标与兄弟一起越过第三方窗口必须仍然红"的用例。**按名次比的写法会放过真连带提升，所以特意没用名次。**
- **`raiseOnly` 不再静默 no-op。** 目录查不到身份、或本代次句柄表里没有那个 AX 索引时，它以前直接 return，一个 Raise 都没发却没有任何记录——Chrome 那轮"目标 #7→#7 一动没动"最像这条路径。现在返回 `RaiseOutcome`（已发出 / 记录缺失 / 句柄缺失），探针把"没发出去"和"发了没生效"分开写；**两种都判红**，因为这种窗口点卡片同样静默无效。
- **「层级」列收回第二处代填。** 上一版收回了 P0-9 那处，但 `bringToFront` 的前台读回还在写同一列——0.1.5 报告里 ChatGPT 的「层级=通过」就是这么来的，它证明的是"目标在前台"，不是该列定义的"不带动兄弟"。现在前台读回改记成独立样本「前景化」，这一列**只由 P0-3 写**；`P0-3` 失败时矩阵的「已知限制」写的也是真实原因（目标没被提升 / 兄弟被带动 / 目标仍在兄弟之后 / 读不到），不再无条件套同一句话。
- **P0-7 先确认布局真的算出来了再取数。** 网格在会话隐藏时被 `resetForHiddenSession` 清空，而 `layouts` 正是从它重建的，所以"缺布局 2"测的是进场状态。现在这项先恢复总览、等布局确实产出一次，再把当时的阶段写进报告。**"有窗口的屏幕必须都有承载窗口与布局"这条判据一个字没改。**
- **过渡超时要说话说清楚。** 以前只有一句"未确认，已按状态机降级"，分不清是预算太短还是几何根本没写进去。现在记方向、预算、实际等待毫秒、目标应用、令牌代次与最后一次几何写入。
- **修掉一处会销毁证据的缺陷**：`CompatibilityRecorder` 的 `fileName` 参数从来没生效，落盘名硬编码，于是**宿主测试把自己那份合成数据写进了桌面上那份正式报告，0.1.4 的原始报告因此没了**（文档里那轮数字只剩转录）。现在 `fileName` 决定实际写出的文件、测试进程一律写临时目录、探针启动时先把上一轮的报告与清单归档进 `_archive/<那份报告自己的版本-生成时间>/`。4 条宿主用例（`T16DiagnosticsOutputTests`）钉住这三条规则。
- 回归测试仍是两层，数字涨了：核心包 **131 → 137 项**（13 → 14 个 suite，新增 `TargetRaiseAuditTests` 6 条），宿主 **80 → 84 项**（新增 T16 4 条）。
- **本版没有新的实机结论。** 上面每条都是为了让 0.1.6 的复跑能给出定性；P0 仍未通过，人工与录屏项一律还是「未测」。见 [Docs/Acceptance.md](Docs/Acceptance.md)。

## 本版（0.1.5）相对 0.1.4 的变化

0.1.4 的实机复跑证明判据改正生效了（P0-1 从两轮红变成通过），同时暴露出探针还剩两个**取证时序**错误。本版只改探针取证据的时机，判定条件一条没放宽，产品代码路径没动：

- **每一项进场前先把阶段清干净。** `showOverview()` 只在 `hidden` 时才 toggle，所以带着上一项留下的受控目标进场时总览根本打不开——0.1.4 的 P0-4 就是这样记成"真实点击已派发但动作次数=0（阶段到达=false）"的。新增 `restoreOverview()`：先 `returnShortcut` 退出受控态并等阶段落回 `overview/hidden`，仍不在总览才兜底打开。P0-3/4/5/9/10/11 六项全部改用它。
- **窗口顺序基准改成稳定读数。** P0-3 逐应用复测时，上一轮的 AX Raise 会异步改动整张全局 `CGWindowList` 顺序表；不等它落定就取 before，余波会被算成本轮的效果。0.1.4 那轮 Chrome 报"同应用另一窗口 #17→#13，兄弟一起被提升"就发生在这种脏基准上，**不能当结论**。新增 `waitUntilWindowListStable()`：连续两次读数完全一致才算稳定，before 与 after 都取稳定值（默认 1.5s 上限，超时返回最后一次读数并在同一轮里照常判定）。
- **收回一个过度断言**：`P0-9`（真实事件链路）过去会顺手把兼容矩阵里「层级」那一格写成通过，但它放大的只是按名字排序选到的**单个**窗口，没有兄弟窗口可对照，证明不了该列定义的"不带动兄弟"。0.1.1/0.1.3/0.1.4 三轮报告里 UGit 与 ChatGPT 因此带着一个没被证明过的结论；从本版起那一列只由 `P0-3` 写，`P0-9` 的链路事实仍整条记在自动结论表里。这是把没有的证据收回，不是放宽判据。
- 回归测试仍为两层：核心包 131 项 / 13 个 suite，宿主 80 项。这两条改动在探针（App 层）里，核心与宿主测试面没变；定性要靠 0.1.5 在已授权正式版上的复跑。

## 本版（0.1.4）相对 0.1.3 的变化

改的全是 **P0 探针自己的取证口径**——上一版的三条结论其实被探针的三个错误决定了，产品代码路径没动。三条都带回归测试或明确复现步骤：

- **P0-1 的判据修好了，之前那条"失败"是探针测错了东西。** 旧断言把 17 个窗口的 AX 索引放在一起比数量（全局唯一），可 AX 索引只在**同一个进程**里有意义：`WindowCatalog.axEntries` 按 pid 分桶，几何写回也按 `(pid, index)` 取元素，所以不同应用各自都有 0 号窗口是常态。现在判据是"同进程两个窗口不得解析到同一索引"，冲突时报告直接点名是哪个进程、哪个索引、哪两个窗口编号。逻辑挪进核心包 `CatalogIdentityAudit`，5 条单元测试钉住"跨进程复用不算冲突 / 同进程重复才算 / 未唯一确定的不参与 / 输入顺序无关"（核心测试 126 → 131 项）。
- **P0-3 现在把每个"同应用 ≥2 窗口"的进程都跑一遍，并且按应用名固定排序。** 旧代码取 `Dictionary` 的第一个：0.1.1 抽到 Code 判失败、0.1.3 抽到 Chrome 判通过，于是 Code 那一格一直没被复测。新增 `VISTILE_P0_TARGET=<应用名或 bundle id 片段>` 可指定只测某个应用，指定后找不到目标时明确记"未测"并列出当前多窗口应用，不会偷偷换一个应用冒充同一场景。
- **P0-4 的"未测"是探针读得太快。** 它在 `sendEvent` 之后立刻读卡片动作计数，而手势动作要等主队列回到 run loop 才落地，所以必然读到旧值——同一次运行里更晚的 P0-9 用同样的派发确实拿到了 1 次动作。现在先等阶段到达目标再核对"恰好一次"，条件没有放宽。放大目标也改成按应用名固定排序，不再每轮随机换应用。

## 本版（0.1.3）相对 0.1.2 的变化

只有一条代码改动，但它挡住的是"验收流程本身能不能跑完"：

- **P0 探针跑完会真的退出了。** 0.1.2 及更早的包在未授权态写完报告后进程不退出：主线程停在 `-[NSApplication terminate:]` 里等 `applicationShouldTerminate` 的 reply，而 reply 只能靠主队列排空送达，此时主线程正被那个 drain 占着。退出请求改从 run loop 观察点发出，实测从"挂死"变成 40 秒跑完并自行退出。普通使用路径的退出不受影响（菜单栏退出、Apple 事件 `quit` 都正常）。
- **验收命令改成跑正式安装的包**：`open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app`。屏幕录制与辅助功能记在签名身份上，Developer ID 包和仓库里的 Debug 产物在 TCC 看来是两个不同的 App；文档里所有探针步骤都已经换成前者。
- **覆盖安装确实不需要重新授权（这条是 0.1.3 发布后实测的）**：0.1.1→0.1.3 覆盖装进 `/Applications` 后直接跑探针，没有再弹权限窗，P0-0 仍回「屏幕录制=true，辅助功能=true」。升级不会逼用户重授一次。
- **拿到第二批授权态客观证据**：13 条自动项里 P0-9（真实点击→放大→真实背景点击→回总览，同期 present +13、捕获帧 +17、GPU 错误 +0）、P0-10（12 路流、2s 内 163 帧回调期间层级改写 0 次）、P0-11（背景点击不留令牌，随后外部激活正常退出总览）第一次跑通并记录到进程内事实。

## 0.1.2 相对 0.1.1 的行为变化

来自一次逐文件审查（R01–R11），每条都改的是实际代码路径：

- **点卡片真的会放大窗口**：视图动作原先没接到控制器，现在按 `按下 → 抬起` 走面板 → 内容视图 → 协调器，一次手势只发一次动作；按下不再展开，拖动只交换格子。
- **画面真的上屏**：总览图层、代理图层与渲染管线共用同一 Metal device，每帧显式 `present(drawable)`；GPU 错误、提交失败、缺 drawable 都有计数并进报告。
- **挂起 / 锁屏 / 权限变化后能重新打开**：恢复任务与打开条件分离，不再停在 preparing 死等。
- **写几何前先有事务**：没有可靠原始 frame 记录就不动窗口；令牌过期或权限收回时立刻补偿回原 frame；退出时逐条汇报恢复结果，失败项留在事务里。
- **捕获流生命周期**：每轮独立 runID，start/stop 交错与旧回调隔离，轮询模式单在途，纹理等 command buffer 完成才释放。
- **格子位置冻结**：展开、关掉中间窗口、清空筛选、新窗口补位都不再挪动别的卡片；只有「整理」才重排。
- **多屏**：面板按完整显示器表建立，副屏、负坐标、混合缩放下的入口坐标不再被单屏基准翻错。
- **帧元数据**：改用 sample attachments 读 status 与内容矩形，点与像素两种单位分开，卡片画面不再拉伸或裁错。
- **最小化窗口**：点卡片先解除最小化并读回确认，再按窗口身份重取 AX 句柄写几何；解除失败明确报错，不发"已展开"、不伪造近全屏；收回与退出都不会把它重新塞回 Dock。
- **层级策略**：未实现的「背景分块避让」从设置里移除，旧持久化值迁移到普通层级并写回、留一条诊断记录；前景化只按读回事实判定（目标是否真是 focused window、目标进程是否真在前台），"调用返回没报错"不再算成功；层级不再随每次捕获回调反复改写。
- **背景点击**：只有真的引发收起或切换的那一次点击才留下受信令牌，之后的 ⌘Tab / 外部应用激活照常把总览隐藏掉。

测试面从「只有纯逻辑」扩成两层：核心包 126 项 + macOS 宿主 80 项（真实控制器、内容视图、CAMetalLayer，目录与几何写入走注入替身；面板全程摆在主屏之外，不会落进你的桌面）。CI 新增 `.github/workflows/ci.yml`，每个 PR 与 main 推送都跑这两层与一次无签名构建，不依赖任何签名凭据。

## 安装

下载 `.dmg`，把 Vistile 拖进「应用程序」。首次启动需要在「系统设置 → 隐私与安全性」里手动授予**屏幕录制**与**辅助功能**，然后重启 App。默认呼出热键是 **⌃⌥空格**。

安装包由 GitHub Actions 用 Developer ID 签名（hardened runtime + 时间戳）、经 Apple 公证并装订票据。发布前 CI 会硬验两处：`codesign -dvvv` 的证书链里必须有 `Authority=Developer ID Application`，挂载后镜像里那个 `Vistile.app` 必须 `stapler validate` 通过。架构只有 arm64（Apple Silicon），Intel 包不提供。

下载后可以自己复核（不需要任何额外工具）：

```bash
shasum -a 256 Vistile_v0.1.4_macos_arm64.dmg   # 期望 196b617a24b088673cdccead54203f6fd75b91b6f675a160d7a80cc6a182a1a9（1400515 字节）
hdiutil attach Vistile_v0.1.4_macos_arm64.dmg
xcrun stapler validate "/Volumes/"*/Vistile.app      # 期望 The validate action worked!
codesign -dvvv "/Volumes/"*/Vistile.app 2>&1 | grep -E "Authority=Developer ID|flags=0x"
hdiutil detach "/Volumes/"*
xcrun stapler validate Vistile_v0.1.4_macos_arm64.dmg   # 镜像外的那个 .dmg 自己也要有票据
```

覆盖安装即可升级：屏幕录制与辅助功能记在签名身份上，同一个 Developer ID 换版本不需要重新授权。这一条在 0.1.1→0.1.3 与 0.1.3→0.1.4 两次覆盖安装上都实测过（没再弹权限窗，探针的 P0-0 仍回「屏幕录制=true，辅助功能=true」）。

0.1.4 的产物已按上面的步骤核对过：dmg **1400515 字节**、`sha256 196b617a24b088673cdccead54203f6fd75b91b6f675a160d7a80cc6a182a1a9`，与 GitHub 资产接口回报的 `digest` 逐字节相同；挂载后 dmg 与镜像里的 `Vistile.app` 票据都回 `The staple and validate action worked!`；镜像里 `Contents/MacOS/Vistile` 的 `sha256` 是 `c1c64804df2e7f5e385ada9651044ad9ce587c9af224793b40139b9dde7a47d5`，覆盖装进 `/Applications/Vistile.app` 后同一个文件的 `sha256` 一字不差——所以那一轮 P0 探针跑的就是发布字节。发布那次（run [`38869893108`](https://github.com/misswell/Vistile/actions/runs/38869893108)）的 CI runner 上 `spctl --status` 是 `assessments enabled`，产物回 `accepted / source=Notarized Developer ID`。

上一版（0.1.3，1380791 字节、`sha256 0bfb9a52712e2fa954700402606468ae19bef9b6cb7cf5ca556900a1fea760de`）同法核对过，与资产 `digest` 逐字节相同；`codesign --verify --deep --strict` 回 `valid on disk` + `satisfies its Designated Requirement`，证书链 `Developer ID Application: Guofeng Liu (U8U443D7ZL)` → Apple Root CA，`flags=0x10000(runtime)`，`lipo -archs` 只有 `arm64`；公证在 runner 日志里成对：`.notarization.zip` 07:24:32 `Accepted` 在前、`.dmg` 07:25:02 `Accepted` 在后。再上一版（0.1.2，1380316 字节、`sha256 f9d1d9786dc7cb0d…537a0c201`）Apple 侧 `notarytool history` 里也是成对出现（`.notarization.zip` 在前、`.dmg` 在后，两条 `Accepted`）。**你自己的 Mac 第一次安装体验仍未测**——权限授予流程、是否被系统二次确认，都要真机才知道；开发机这边 `spctl` 评估是关掉的，测不出这一层。

## 构建与测试

```bash
brew install xcodegen
xcodegen generate                        # Vistile.xcodeproj 由 project.yml 生成
xcodebuild -project Vistile.xcodeproj -scheme Vistile -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
cd Packages/VistileCore && swift test    # 137 项纯逻辑，14 个 suite
cd ../..
xcodebuild -project Vistile.xcodeproj -scheme VistileHostTests \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test    # 84 项宿主测试
```

必须用 `-scheme`，用 `-target Vistile` 会报 `Unable to resolve module dependency: 'VistileCore'`。

自动 P0 探针（只产出证据，不等于验收结论）。**正式验收只能跑已授权的那个包**：权限记在签名身份上，
`/Applications/Vistile.app`（Developer ID）与仓库里的 Debug 产物（Apple Development）在 TCC 看来是两个不同的 App，
跑 Debug 会再弹一次授权窗：

```bash
open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app
```

产物写在 `~/Desktop/Vistile Diagnostics/`：本轮报告在原地，上一轮的三份文件被归档进 `_archive/<版本-生成时间>/`。
缺少屏幕录制或辅助功能权限时，相关项记为「未测」并给出原因，不会伪装成通过或失败。
宿主测试的诊断产物不写桌面，一律落 `$TMPDIR/Vistile Diagnostics/host-test-<uuid>.*`。

## 已知限制

- 展开真实窗口后前台 App 的键盘归属、Sheet 与子窗口的跟随、多显示器混合 DPI 下的拖拽，均未经真机确认。
- **P0-1 已经回答：判据改正后连续两轮实机通过（0.1.4 与 0.1.5）。** 旧断言把整个目录的 AX 索引放在一起比数量，而索引只在同进程内有意义（句柄表按 pid 分桶、写回按 `(pid, index)`）。改成"同进程两个窗口不得解析到同一索引"后，正式包里 17 个窗口回 `窗口编号无重复=true；同进程 AX 索引无重复=true`（0.1.5 那轮多窗口进程 3 个、AX 唯一对应 17 个）。口径本身有 5 条单元测试守着（`CatalogIdentityAudit`）。
- **P0-3「只提升被点窗口」现在是一格通过、两格未定性。** 0.1.4 第一次把每个"同应用 ≥2 窗口"的进程都跑一遍：Code（3 窗口）目标 #17→#9、兄弟 #18→#18 ⇒ 通过（这一格在 0.1.1 判红之后一直没被复测过）；Chrome 报失败。**0.1.5 把三个多窗口应用跑全了**：Code 连续第二轮通过（#12→#8、兄弟 #10→#12）；Chrome 仍然红，但换了红法（目标 #7→#7 一动没动，最像 Raise 根本没发出去）；访达报兄弟 #21→#20"被一起提升"，而兄弟只动了 1 格，很可能是两次读数之间无关窗口开合把整张表平移了——**绝对下标在前后两次不是同一个参照系**。0.1.6 的判据因此改成在"两次都仍在场的窗口"里做两两比较，并让 `raiseOnly` 用 `RaiseOutcome` 说清有没有真的发出 Raise；也可以 `VISTILE_P0_TARGET=Chrome` 只测它。**这两条红要到 0.1.6 复跑才定性。**
- **P0-9 / P0-10 / P0-11 已在授过权限的正式版上跑出结论**（0.1.4+5：13 条自动项 1 失败；0.1.5+6：11 通过 / 2 失败）。P0-4 在 0.1.3 记"未测"是探针在事件派发后立刻读计数，0.1.4 加了等待仍记"未测"，查明还有第二层原因：上一项留下的受控目标让总览压根没打开，点击点不到格子。0.1.5 用 `restoreOverview()` 清掉进场阶段后**这一项转为实机通过**（放大 ChatGPT 后总览面板不持有键盘、归属=targetApplication）。但"键盘归属"的肉眼结论（中文输入候选窗跟随、Sheet、⌘Tab）仍属人工项，一律未测。
- **P0-7 的「缺布局」在 0.1.5 第一次变红，查明是测量时机**：网格在会话隐藏时被清空，而布局正是从它重建的。0.1.6 先恢复总览、等布局确实产出一次再取数，并把当时阶段写进报告；判据本身没动，所以这一格也要 0.1.6 复跑才算定性。
- **0.1.4 那轮的原始报告文件已经不存在**：`CompatibilityRecorder` 的 `fileName` 参数当时没生效，一轮宿主测试把自己的合成数据覆盖进了桌面那份正式报告。0.1.6 起 `fileName` 生效、测试进程写临时目录、探针启动先把上一轮归档进 `_archive/<版本-生成时间>/`。所以文档里的 0.1.4 数字只剩转录，无法再核对原件——这条记在这里而不是藏起来。
- 菜单栏图标已按系统图标的视觉大小重绘，但它在真实菜单栏里的观感仍未经截图确认。
- 最小化与隐藏的窗口不参与实时预览；点最小化卡片会真的把它解除最小化，收回后不会自动放回 Dock。
- 无应用内更新、无更新检查、无 App Store 分发；界面文案只有简体中文。
