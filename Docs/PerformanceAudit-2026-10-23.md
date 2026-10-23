# Performance and native interaction audit / 性能与原生交互审查

## Baseline / 基线

中文：基线为 `77e43ee`（main，v0.1.34），不是最早材料中的 v0.1.32。此次沿窗口发现、状态机同步、截图生命周期、Metal提交/呈现及恢复链核实问题，保留既有事务日志与几何恢复，不重写窗口管理架构。下面的结果不代表264个条目均逐行审阅，也不把旧版本性能数字当成当前实测。

English: The source baseline is `77e43ee` (main, v0.1.34), rather than the preliminary v0.1.32 reference. The audit follows discovery, state synchronization, capture lifetimes, Metal submission/presentation, and recovery. Existing journal and recovery guarantees remain in place. This does not claim line-by-line review of every repository entry or reuse historical measurements as current evidence.

## Confirmed findings and changes / 已确认问题与修复

| Area / 范围 | Before / 修复前证据 | Change / 修复 |
| --- | --- | --- |
| Scroll synchronization / 滚动同步 | 20次连续滚动触发20次完整同步；fullSync计数7→27 / Twenty scroll events caused twenty full syncs | State remains immediate; one-shot display-link scheduling merges rail visuals and visible capture targets. Overview layout, observers, wallpaper and ordering are skipped on the rail-only path. Structural/safety events force immediate synchronization / 状态立即更新；轨道视觉与可见捕获需求按显示周期合并，结构和安全事件仍立即同步 |
| Wallpaper / 壁纸 | 同一图片两次apply解码2次；后台请求实际在主线程；旧token被接受 / Repeated decode, main-thread work, accepted stale token | Background ImageIO decoding, display+URL+mtime keys, shared in-flight requests, eight-image LRU, idempotent real CALayer updates and display/session tokens / 后台解码、有界缓存、请求去重、真实图层幂等及代次校验 |
| Window ordering / 层级 | Backdrop sync unconditionally ordered windows and raised rails / 每次同步都调整窗口层级 | A signature of display, main window, session and ordering strategy gates WindowServer changes / 按屏幕、主窗口、会话和策略变化重排 |
| Poll capture / 低频截图 | 五项新生命周期测试失败，覆盖跨窗并发、同轮改间隔、关闭重开与映射线程 / Five lifecycle regressions reproduced | Two physical screenshot slots, visible-first pending queue, request generations, stale-result rejection; physical completion releases budget / 两路物理并发、可见优先队列、请求代次与真实完成后释放预算 |
| Stream startup / 流启动 | stopAll/reopen could reset counters before old starts returned / 旧启动未完成却释放预算 | Outstanding starts remain counted across session changes; late runs stop before releasing capacity / 跨会话保留实际在途计数 |
| Image mapping / 图像转换 | Poll callback performed CVPixelBuffer/CGContext mapping on MainActor / 转换发生在主线程 | Mapping runs in detached background work; only current results publish on MainActor / 后台转换，仅提交有效结果 |
| AX queue / AX队列 | Queue probe waited0.60084s during retry sleeps, exceeding0.15s regression budget / 共享串行队列被重试睡眠阻塞 | Each read resubmits after async sleep; discovery is window-sized low-priority work; interactive work has priority without preempting active writes / 异步重试、窗口级发现、交互优先，正在执行的写入不被打断 |
| AX types / AX类型 | Forced CF attribute casts trusted third-party types / 直接强转跨进程属性 | Check CF type IDs and AXValue kinds before unpacking, return nil for unexpected values / 校验类型后解包，异常值返回nil |
| Presentation facts / 呈现事实 | noteSubmission incremented presents before GPU commit; regression actual1 expected0 / 提交被当成上屏 | submissions, GPU completions and drawable presentations have separate counters; positive presentedTime callbacks alone confirm presentation / 分开计数，仅实际呈现回调确认像素上屏 |
| Scene telemetry / 场景指标 | First-frame latency and intervals were derived from submission/tick facts / 首帧与间隔由提交和回调代替 | Input-to-submit, GPU execution, actual first presentation, actual presentation intervals, and display-link intervals are separate. Per-scene bounded observation cannot delay geometry handoff / 指标分离，场景独立采样不阻塞几何交接 |
| Refresh budget / 刷新率预算 | Normal60Hz intervals exceeded a fixed12ms logging threshold;12ms intervals wrongly passed120Hz / 固定阈值误判 | Actual display-link target period supplies the budget;60Hz≈16.67ms,120Hz≈8.33ms,0.05ms timestamp tolerance. Only one severe frame log per scene; normal data is summarized / 原生周期预算、每场景有限异常日志 |
| Diagnostic memory / 诊断内存 |2048 recorded values retained2048, exceeding the1024 budget / 样本无限追加 | Constant-size circular history per metric, with retained/total counts in summaries / 每项1024条循环记录，保留累计计数 |

Metal timing source: [Apple — presentedTime](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime). A zero timestamp means no confirmed presentation, including dropped frames / 零时间戳不能证明呈现成功。

## Regression evidence / 回归证据

- Capture:42 passed,0 failed; original T15, lifecycle, minimize and native-input coverage included / 截图相关42项通过，0失败。
- Backdrop:4 original red failures reproduced;7 final tests passed, including background decode, stale tokens, coalescing and LRU / 壁纸先复现4项失败，修复后7项通过。
- Presentation: submission, metric-capacity and refresh-budget red tests reproduced;70 host tests passed after fixes / 先复现提交/内存/预算问题，呈现相关70项通过。
- AX:0.60084s queue-blocking regression reproduced;15 AX/geometry host tests passed / 先复现阻塞，AX与几何15项通过。
- Core and integrated host totals are recorded with final build validation below / 最终核心与集成宿主总数见后续验收记录。

All host execution above used the AgentUse background desktop and isolated source snapshots. Existing human-session processes were preserved / 宿主测试均在AgentUse后台桌面及独立快照执行，未处理用户既有进程。

## Real-machine acceptance gate / 实机验收闸门

中文：离屏HostTests能验证队列上限、代次、几何状态、实际Metal提交以及呈现回调的处理；不能证明离屏图像已显示，也不能证明真实应用切换达到原生流畅度。`Docs/Acceptance.md` 的P0结论必须继续由真实授权、屏幕呈现和长时间资源证据决定，不能因上述测试通过而改成通过。

English: Offscreen HostTests validate budgets, generations, geometry, real Metal submissions, and presentation callback handling. They cannot establish visible screen pixels or native smoothness while switching real applications. The P0 verdict in `Docs/Acceptance.md` still requires real permission, screen presentation, and long-running resource evidence.

The runtime matrix is / 运行时矩阵为：

- 12/30 real windows, continuous scrolling, repeated switching and hide/reopen cycles /12与30个真实窗口、连续滚动、切换及隐藏重开。
- 60Hz and120Hz only when the display is actually operating at that rate / 仅在真实运行对应刷新率时判定60/120Hz。
- 30-minute idle/stability sampling with attributable CPU/RSS, texture and task counts, plus WindowServer context /30分钟CPU/RSS、纹理与任务计数，并附WindowServer环境。
- Input feedback P95≤50ms and geometry/focus readback measured separately / 点击反馈P95≤50ms，几何与焦点读回单独统计。
- No idle redraw of unchanged content, and no hidden-session polling or uncapped capture bursts / 静止不空转、隐藏无残留轮询、不突发启动无界截图。

Environment limits, actual runtime results and formal artifact identity must be appended as facts; unavailable or insufficient samples remain unjudged / 环境限制、运行结果与正式包身份须按事实补录，缺失或不足样本保持未判。

## Scope decisions / 范围判断

中文：发现请求的单进程退避、改用真实移动所有窗口的工作台，以及全面拆分更多视觉脏标记，属于进一步设计建议；本轮未把尚未复现的问题当作缺陷实施。当前保留公开API、串行几何写入、事务恢复与覆盖工作台。实际运行验收不足时，不能将这些架构建议或自动化通过包装成流畅度结论。

English: Per-process discovery backoff, a workbench that physically moves all windows, and a broader visual dirty-state split remain design recommendations rather than reproduced defects in this pass. Public APIs, serial geometry writes, transaction recovery and the overlay workbench remain. Neither architectural suggestions nor passing automation establish native smoothness without runtime evidence.

## Integrated validation / 集成验证

中文：当前0.1.35 (49)隔离快照运行核心XCTest135项、Swift Testing159项，共294项，0失败；AgentUse后台桌面运行完整宿主328项，327通过、1项因真实前台键盘焦点限制跳过、0失败。构建来源含本轮AppCoordinator、显示周期同步、场景收尾和P0预算集成，不仅是各模块定向测试。日志：`/tmp/Vistile-v035-integrated-core.log`；Host的xcresult与正式产物信息由最终验证记录补充。

English: The isolated0.1.35 (49) snapshot passed135 XCTest and159 Swift Testing core tests (294 total), with zero failures. Full host execution on the AgentUse background desktop ran328 tests:327 passed, one skipped because real foreground keyboard focus was unavailable, zero failed. This includes the AppCoordinator, display-cycle synchronization, scene-finalization and P0-budget integration, beyond individual module tests.

## Runtime preflight / 运行预检

中文：AgentUse后台账户可用，桌面为1920×1080pt、2×；环境报告75Hz主虚拟屏和120Hz副虚拟屏，不能确认为物理屏幕60/120Hz证据。账户级权限可用不等于候选Vistile包自身已授权。集成测试Debug包为临时ad-hoc构建且严格签名检查失败，未启动它做P0，避免将无效签名包的权限/呈现结果误记为正式验收。P0继续以签名正式包为前提；未修改TCC或替换已安装的旧版本。

English: The AgentUse desktop is available at1920×1080pt and2×. Its reported75Hz primary and120Hz secondary displays are virtual, so they do not establish physical60/120Hz evidence. Account-level permissions do not prove authorization for the candidate bundle. The temporary ad-hoc Debug test bundle failed strict signature verification and was not launched for P0. P0 requires the signed release bundle; no TCC changes or replacement of the installed older version were performed.

## Window fixture validation / 窗口工具验证

中文：修复测试工具从第25个窗口起尺寸为负的问题；大窗口数使用可见区域网格，小窗口数保留级联，实际frame夹紧至可见屏幕边界。DEBUG回归覆盖12/30窗口与两种屏幕坐标。AgentUse实际枚举12个窗口通过；全新构建目录的30窗口运行确认30/30可见、windowID唯一、尺寸为正、完整在1920×1080屏幕内且0对重叠。stderr为空，启动的两个Harness进程均正常退出，无残留窗口。这只验证fixture，未当作Vistile捕获性能或原生流畅度结果。

English: The fixture previously generated negative sizes from window25 onward. Larger runs now use a visible-screen grid, small runs retain a cascade, and actual frames are clamped to visible bounds. DEBUG guards cover12/30 windows and two screen coordinate configurations. Runtime enumeration passed for12 windows; a fresh build with30 windows confirmed30 visible unique window IDs, positive sizes, all within1920×1080 bounds, with no overlapping pairs. stderr was empty, both task-created Harness processes quit normally and no windows remain. This validates the fixture only, not capture performance or native smoothness.
