# Vistile 性能记录

> 本文只有**一组本机自动数据**，且这组数据是在系统权限未授予、目录为空的情况下采到的。
> 它证明测量口径与代码路径可运行，**不构成性能结论**。任何"预期 CPU/内存/帧率"都必须来自实测。

## 1. 记法约定

- **CPU 100% = 一个逻辑核满载**（不是整机）。取值方式：`proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT)` 的 `ri_user_time + ri_system_time`（单位纳秒）做前后差，除以墙钟时间。
- 帧率用 mailbox 的 `publishedCount` 增量除以墙钟时间，不靠计时器假设。
- 耗时用 `os_signpost` 区间（`Vistile区间`/`Vistile事件`）+ 进程内样本，`Metrics.summary()` 给 p95 与中位数，写进 `capability-report.md` 的计时表。
- 正常界面不显示这些技术参数（方案 §13）；它们只出现在诊断产物里。

## 2. 结构性预算（代码里的既定约束）

| 项 | 值 | 出处 |
| --- | --- | --- |
| 同时启动的流 | 最多 2 路 | `CaptureCoordinator.maxConcurrentStarts` |
| 活跃流软上限 | 12（未校准的保守起点） | `CaptureCoordinator.streamSoftLimit` |
| 帧信箱容量 | 1，只留最新帧 | `FrameMailbox.capacity` |
| `queueDepth` | 3（系统默认，不超官方上限 8） | `CaptureTier.queueDepth` |
| 目标帧率 | balanced 8 / powerSaving 3 / refreshPriority 15 fps（上限，非承诺） | `CaptureTier.targetFPS` |
| 输出宽度上限 | balanced 960 / powerSaving 640 / refreshPriority 1280 px | `CaptureTier.maxPixelWidth` |
| 输出高度 | 按源宽高比反推，不做非均匀拉伸 | `StreamConfig.build` |
| 配置变更合并 | 250ms 去抖；动画期间不改配置 | `StreamConfig.needsReconfiguration` |
| 降级阶梯 | 帧率 `15,10,8,5,3` → 宽度 `1280,960,720,560,400` → 轮询 `1s,2s,4s` | `CaptureBudget` |
| 降级触发 | 流数超软上限，或热状态 `serious`/`critical` | `CaptureBudget.nextAction` |
| 优先窗口 | 未远超软上限且非危急时最后才被降级 | 同上 |
| 整屏重绘 | 每帧一个 command buffer，全部卡片共用；无新帧不提交 | `OverviewRenderer` |
| 重绘触发 | 由新帧与状态变化调用 `scheduleRedraw`，同一轮次只排一次队；**没有 60Hz 空转定时器** | `OverviewRenderer.scheduleRedraw`、`AppCoordinator.redraw` |
| 层级改写 | 只在策略或目标窗口编号变化时执行一次，签名相同直接返回；`orderingApplyCount` 供 P0-10 取证 | `AppCoordinator.applyOrdering` |
| 纹理生命周期 | 纹理与 `CVMetalTexture` 同存活，command buffer 完成前不释放 | `MetalFrame` / `TexturePool` |

长期并发流上限与降级阈值**必须由实测校准**：`streamSoftLimit = 12` 与上面三档 fps 都是保守起点，实测后要按真实数据替换。

## 3. 本机自动采样（2026-10-16，macOS 27.0.1，Apple M1，8 逻辑核，16GB）

运行方式：`open -n -g -W --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app` 探针完整跑一遍后自动退出。屏幕录制与辅助功能均未授予，因此目录为空、没有活跃流。

这组数据没有捕获负载，只证明测量口径与代码路径能跑通；含 R01–R11 修复的当前代码必须在授权机上重跑才有可比性。

| 指标 | 值 | 说明 |
| --- | --- | --- |
| 状态机 100 次背景点击 | **2.0ms** | 纯 reducer 路径，不含绘制；证明背景点击处理没有累积副作用 |
| 活跃流 / 低频卡片 | 0 / 0 | 权限缺失，目录为空 |
| 采样窗口内帧数 | 0 张 / 3.1s | 同上，不是性能数据 |
| 总览帧率 | 0.0 帧/秒 | 同上 |
| Vistile CPU | 0.0（100% = 一个逻辑核满载） | 同上，无捕获负载 |
| 启动 → 探针跑完 → 退出恢复 | 全程无崩溃，未结束事务 0 条 | 事务与恢复路径可运行 |

同一台机器还跑过一次失败样例：着色器编译失败时应用会拒绝启动并写明原因，而不是退回静态截图（已修复，见 `ShaderSource.swift` 的函数外 `constant` 数组）。

## 4. 必须补齐的实测项（全部未测）

1. **空闲基线**：总览打开且画面静止时 `presents` 不增长、总览关闭后 CPU 回到接近 0%、GPU 无持续占用（Activity Monitor 对照）。
2. **12 窗口常驻**：balanced 层级下的 CPU、GPU、内存（纹理数 × 输出尺寸）、`windowserver` 增量。
3. **30 窗口压力**：帧率下降是否渐进、降级发生时卡片标注是否与实际更新方式一致、`replacedCount`/`staleCount` 是否上升。
4. **遮挡窗口**：被完全遮住的窗口其 `publishedCount` 是否继续增长（这是"实时"的判据，不是肉眼判断）。
5. **热状态路径**：`serious`/`critical` 下降级是否按阶梯发生、优先窗口是否最后被牺牲。
6. **过渡动画**：24 帧内是否稳定、代理层与真实窗口衔接有无闪白。
7. **跨缩放屏**：Retina 与外屏混合时纹理尺寸选择是否仍按格子宽度。
8. **长时间停留**：30 分钟内是否有纹理/事务/观察器泄漏（`inFlightTextureCount`、`retained.count`、`journal.unfinished`）。
9. **呈现健康度**：`RendererDiagnostics` 的 `missingDrawables`、`submissionFailures`、`gpuErrors` 在长时间运行与显示器变更后是否保持为 0（P0-9 每轮记增量）。
10. **层级改写频率**：`orderingApplyCount` 在总览持续打开的 30 分钟内应只有策略/目标变化那几次；持续随帧增长说明在跟 WindowServer 较劲（P0-10 记 2s 窗口）。
11. **软上限校准**：`streamSoftLimit = 12` 目前只是保守起点，要用第 2、3 项的实测数据决定它是收紧还是放宽。

复现与记录方式：用 `UITestHarness` 造窗口，跑 `open -n -g -W --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app`，把 `~/Desktop/Vistile Diagnostics/capability-report.md` 的计时表与 `P0-acceptance-checklist.md` 一起存档；Instruments 用 `com.misswell.Vistile` 子系统的 signpost 区间对齐时间轴。
