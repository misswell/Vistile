# Vistile 性能记录

> 本文有**四组旧总览口径的授权态本机自动数据**（0.1.1+2 / 0.1.3+4 / 0.1.4+5 / 0.1.5+6，同一台机器、同一个 `/Applications/Vistile.app`）
> 加两组未授权对照（§3.5），以及**0.1.10 工作台八轮的采样**（§3.7，换了口径：点击→落定墙钟 + 过渡帧间隔）。
> 它们证明的是"测量口径能跑、代码路径可运行、部分趋势可比"，
> **不构成性能结论**：CPU 各轮都低到不可信、几何写入样本刚够但场景混合、帧率列的口径几次在变。
> 任何"预期 CPU/内存/帧率"都必须来自实测，且要先解决 §4 第 2、12 项那两个已知问题。

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

## 3. 本机自动采样

### 3.1 授权态的第一批真实数字（2026-10-16 15:13，macOS 27.0.1，Apple M5 10 核 / 24GB，正式版 0.1.1+2）

运行方式：`open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app`。
权限记在 Developer ID 包上，仓库里的 Debug 产物是另一个身份、要单独授权，所以正式验收只跑这一条命令。

| 指标 | 值 | 怎么读 |
| --- | --- | --- |
| 目录窗口 / 活跃流 / 低频卡片 | 17 / 17 路 / 0 个 | 17 个窗口全部进了捕获集合 |
| 采样窗口内帧数 | 322 张 / 3.0s | 报告的"总览帧率"列因此填了 **107.0**，但那是**所有流合计的帧数/秒**，不是屏幕帧率；按名义 30fps×17 路应该远不止这个数，说明碰顶后大量流被降档 |
| 捕获预算 | 备注连续记录"降级影响 13→17 个目标（流上限 12，热状态 nominal）" | `streamSoftLimit = 12` 在 17 窗口下必然大面积降档，§2 的阈值校准就是要用它 |
| Vistile CPU | 0.2（100% = 一个逻辑核满载） | **这组数不能当结论**：17 路流不可能只用 0.2% 一个核。要么采样口径太窄，要么负载在 WindowServer/GPU 侧，必须用 Activity Monitor 与 Instruments 对照 |
| 几何写入 | 17.9ms，读回偏差 0.0pt；p95 17.9ms（n=2，median 41.8） | 读回一致是硬结论；样本只有 2 次，延迟数字还不够 |
| 状态机 100 次背景点击 | 4730.0ms（≈47ms/次） | 真实面板路径，和纯 reducer 的 2.0ms 不是一个口径，别混着引用 |
| 退出恢复 | 未结束事务 0 条 | 恢复路径在授权态也走完 |

### 3.2 授权态第二轮（2026-10-16 15:26，同一台机器，正式版 0.1.3+4 覆盖安装）

同一条命令，探针 14 秒跑完并自行退出（§3.6 的修复生效）。这一轮是**含 R01–R11 的第一组可比数据**：
自动项从 9 条扩到 13 条，12 通过 / 1 失败（P0-1）。

| 指标 | 值 | 怎么读 |
| --- | --- | --- |
| 目录窗口 / 采样时活跃流 | 17 个 / 12 路 + 5 个低频 | 预算把 17 路压成 12 路直播 + 5 个降档，与 §2 的设计一致 |
| 采样窗口内帧数 | 165 张 / 3.0s | 仍是**所有流合计**；报告"总览帧率"列因此是 54.9，不是屏幕帧率 |
| 遮挡时收帧 | 16 个被遮挡窗口里 12 个在 1.5s 内收到新帧，帧增量 49（≈32.6 帧/秒） | 比上一轮的 9/16 好，但两轮窗口集合不完全相同，别当增益结论 |
| 捕获预算 | 备注"降级影响 17 个目标（流上限 12，热状态 nominal）" | 连续两轮都在 17 窗口上碰顶，`streamSoftLimit = 12` 的校准就用这两组 |
| Vistile CPU | 0.3（100% = 一个逻辑核满载） | 与上一轮的 0.2 同样**不可信**，仍要 Activity Monitor / Instruments 对照 |
| 状态机 100 次背景点击 | 3874.7ms（≈39ms/次），结束时阶段=`preparing` | 真实面板路径；上一轮 4730.0ms、结束时 `collapsing`，两轮结束时落在不同阶段，说明这条只保证"不累积副作用" |
| 层级改写频率 | 12 路流、2s 内 163 帧捕获回调期间 **0 次** | `applyOrdering` 的签名短路在真实负载下确实生效（P0-10） |
| 真实事件链路 | 一次放大 + 一次背景点击：present +13、捕获帧 +17（9 路流）、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0 | present 计数第一次在授权态非零（P0-9） |
| 退出恢复 | 未结束事务 0 条 | 同上一轮 |

### 3.3 授权态第三轮（2026-10-16 15:56，同一台机器，正式版 0.1.4+5 覆盖安装，改正判据后）

同一条命令，`open -W` 能返回、报告写全（即同样自行退出；这一轮没单独计时）。
自动项仍是 13 条、**12 通过 / 1 失败**，但失败的那条换了：P0-1 转通过，P0-3 的 Chrome 转红，
而 Chrome 那条红的基准取在上一轮提升的余波里（见 [Compatibility.md](Compatibility.md) §2），所以本轮的性能数字可比、结论数字要复跑。

| 指标 | 值 | 怎么读 |
| --- | --- | --- |
| 目录窗口 / 采样时活跃流 | 17 个 / 12 路 + 5 个低频 | 与上一轮同一档降额，`streamSoftLimit = 12` 第三次在 17 窗口上碰顶 |
| 采样窗口内帧数 | 139 张 / 3.1s | 所有流合计；报告"总览帧率"列因此填 **45.3**，不是屏幕帧率。三轮 107.0 / 54.9 / 45.3，这个"帧率"列本身口径就不稳，别当指标引用 |
| 遮挡时收帧 | 被遮挡 **17 个**里 9 个在 1.5s 内收到新帧，全目录帧增量 23（≈15.3 帧/秒） | 三轮 9/16、12/16、9/17 —— 分母每轮都在变，只能证明"遮挡窗口确实在继续收帧"，不能证明收帧率 |
| 捕获预算 | 备注"降级影响 17 个目标（流上限 12，热状态 nominal）" | 连续三轮同一结论：17 窗口下阈值 12 必然降档 17 个目标 |
| Vistile CPU | 0.3（100% = 一个逻辑核满载） | 三轮 0.2 / 0.3 / 0.3，与十几路流的负载明显不称，**这条采样口径本身要查**（§4 第 2 项） |
| 状态机 100 次背景点击 | **1181.2ms**（≈12ms/次），结束时阶段=`preparing` | 三轮 4730.0 / 3874.7 / 1181.2ms，同一份代码差 4 倍——说明这条测的是机器当时的负载，不是状态机成本，引用时要连这句一起说 |
| 层级改写频率 | 12 路流、2s 内 **149** 帧回调期间 **0 次** | 与上一轮（163 帧、0 次）同向，`applyOrdering` 的签名短路在真实负载下继续生效（P0-10） |
| 真实事件链路 | 放大 ChatGPT + 一次背景点击：present +14、捕获帧 +22（8 路流）、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0 | P0-9 连续第二轮非零 present；注意采样时活跃流只有 8 路（总览正在被探针反复开合） |
| 退出恢复 | 未结束事务 0 条 | 同前两轮 |

### 3.4 授权态第四轮（2026-10-16 16:37，同一台机器，正式版 0.1.5+6 覆盖安装，探针进场清场后）

同一条命令，`open -W` 能返回、报告写全（同样自行退出，也没单独计时）。自动项 13 条、**11 通过 / 2 失败**：
失败的是 P0-3（Chrome 与访达，两个应用各一条、成因不同）和 P0-7（缺布局 2），另有 1 条「过渡超时」记为失败。
这一轮进场会先把阶段恢复到总览、窗口列表取到"连续两次读数一致"才当基准，所以**顺序类读数是四轮里第一次可比的**；
P0-4 因此从"未测"转为拿到读数。

| 指标 | 值 | 怎么读 |
| --- | --- | --- |
| 目录窗口 / 采样时活跃流 | 17 个 / 12 路 + 6 个低频 | `streamSoftLimit = 12` 第四次在 17 窗口上碰顶；备注连着出现"降级影响 17 个"与"18 个"两条，与目录数不自洽，**这个口径差还没查清** |
| 采样窗口内帧数 | 136 张 / 3.0s | 所有流合计；"总览帧率"列因此填 **45.1**。四轮 107.0 / 54.9 / 45.3 / 45.1，这一列口径本身不稳，别当指标引用 |
| 遮挡时收帧 | 被遮挡 **16 个**里 **12 个**在 1.5s 内收到新帧，全目录帧增量 46（≈30.7 帧/秒） | 四轮比例 9/16、12/16、9/17、12/16。分母每轮都变，只能证明"遮挡窗口确实在继续收帧"，不能证明收帧率 |
| Vistile CPU | 0.3（100% = 一个逻辑核满载） | 四轮 0.2 / 0.3 / 0.3 / 0.3，与十几路流完全不称，**这条采样口径要查**（§4 第 2 项），本轮没有新证据推翻这个判断 |
| 状态机 100 次背景点击 | **819.7ms**（≈8ms/次），结束时阶段=`overview` | 四轮 4730.0 / 3874.7 / 1181.2 / 819.7ms，同一份代码最大相差近 6 倍；这条测的是机器负载，不是状态机成本。结束时阶段第一次落在干净的 `overview`，是进场清场的副作用，不是性能结论 |
| 层级改写频率 | **1 路**流、2s 内 **17** 帧回调期间 **0 次** | 判据（增量必须为 0）没变，但观察窗里的流数比上一轮少一个量级，**这轮证据比 §3.2/§3.3 弱**，不能因为"同样 0 次"就当成同等强度 |
| 真实事件链路 | 放大 ChatGPT + 一次背景点击：present **+2**、捕获帧 **+1**（1 路流）、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0 | P0-9 连续第三轮非零 present。增量绝对值跟着活跃流数走（9/8/1 路 → +13/+14/+2），**只能判"> 0 且错误为 0"，不能跨轮比大小** |
| 几何写入 | **117.9ms**，读回一致（p95 117.9，n=1） | §3.1 那轮是 17.9ms、读回偏差 0.0pt。慢了一个量级，但 **n=1**，既不能算回归也不能算没问题；这是当前最缺重复样本的一项 |
| 过渡超时 | 1 条，令牌 `49395:1792027413359615:1072` | 报告当时只写"未确认，已按状态机降级"，**没有预算、实际等待、方向与最后一次几何写入**，所以这条红的性能含义是空的。0.1.6 起补齐这些字段，才能分清"预算太短"和"根本没写成功" |
| 退出恢复 | 未结束事务 0 条 | 同前三轮 |

### 3.5 未授权的那两组（只证明测量口径与代码路径能跑通）

运行方式同前，但跑的是仓库 Debug 产物（屏幕录制与辅助功能均未授予，目录为空、没有活跃流；0.1.2 那一次写完报告后不退出，是 §3.5 的那个缺陷）。

| 指标 | 值 | 说明 |
| --- | --- | --- |
| 状态机 100 次背景点击 | **2.0ms** | 纯 reducer 路径，不含绘制；证明背景点击处理没有累积副作用 |
| 活跃流 / 低频卡片 | 0 / 0 | 权限缺失，目录为空 |
| 采样窗口内帧数 | 0 张 / 3.1s | 同上，不是性能数据 |
| 总览帧率 | 0.0 帧/秒 | 同上 |
| Vistile CPU | 0.0（100% = 一个逻辑核满载） | 同上，无捕获负载 |
| 启动 → 探针跑完 → 退出恢复 | 全程无崩溃，未结束事务 0 条 | 事务与恢复路径可运行 |

### 3.6 探针自身的退出缺陷（已修，未计入任何性能口径）

未授权 + 空目录时，0.1.2 的探针写完报告后**不退出**（两次复现，主线程停在 `NSApp.terminate` 里等
`applicationShouldTerminate` 的 reply，而 reply 只能靠主队列排空送达）。改成从 run loop 观察点发出退出请求后，
同一条命令 40 秒跑完并自行退出。授权态的 0.1.1 当时能自行退出，所以"哪一项是必要条件"还没分离出来，
但两条路径现在都不再依赖主队列排空——0.1.3+4 在授权态 14 秒自行退出，0.1.4+5 同一条命令也能返回并写全报告。细节见 [Compatibility.md](Compatibility.md) §1。


同一台机器还跑过一次失败样例：着色器编译失败时应用会拒绝启动并写明原因，而不是退回静态截图（已修复，见 `ShaderSource.swift` 的函数外 `constant` 数组）。

### 3.7 工作台时代的数字（0.1.10+16…+23，同一台机器；本机 Xcode 27 构建）

0.1.10 的工作台八轮换了一套采样口径：跑的不再是旧的总览静态采样，而是工作台路径——
`P0-16`（固定交换 100 次）、`P0-17`（往返 100 次 + 非参与窗口 frame 对照）与 `P0-18`（§20.2 帧预算与样本量）。
**口径**：点击→落定是**真实点击到状态收敛的墙钟时间**（含 AX 写入与动画），不是状态机内部耗时；
帧样本是过渡期间按 60Hz 间隔采的帧间隔。八轮里只有 +16/+17/+20 记"可用"，+18/+19/+21/+22/+23 都记"诊断轮"
（静默退出、中途锁定段或失败形状只作对照；其中 `P0-16` 的 100/100 属可引用的单点读数）；
每轮原始报告、`-live-log.txt` 与 `-snapshots.txt` 在 [Docs/Evidence](Evidence/README.md)。

| 指标 | 值 | 怎么读 |
| --- | --- | --- |
| 固定交换 100 次（顶栏 50 + 侧栏 50） | +20/+22/+23 三轮 **100/100** 收敛（判据是"每轮被点卡进主区、原主回原 slot、其余占用与滚动不变"）；同三项读数里的点击→落定 p95 = **384 / 552 / 554ms** | +16/+17 两轮只有 2/100 与 6/100——根因是窗口服务器几何提交滞后 AX 约 0.6s 时目录把"刚移动的窗口"判成身份未唯一、点击被拒；修复（目录带截止时间复核、写前直接问窗口）之后连续三轮走满。**p95 是记录读数、不是这三轮的通过判据**；后两轮的 55xms 已经压在 ≤500ms 目标线上 |
| 点击→落定 p95·三条路径 | +20：总览→L 型 788ms（n=100）/ L 型内交换 384ms（n=100）/ L 型→总览 509ms（n=100）；+23：735ms（n=62）/ 554ms（n=100）/ 256ms（n=62） | 目标分别是 ≤600 / ≤500 / ≤500ms。**L 型→总览在 +23 已经明显低于目标，另两条路径仍超**；+22 那轮总览→L 型只有 n=4，不能比。P0-18 把"内交换 p95 超 500ms"原样记在超目标清单里 |
| 往返 100 次 | +20 走完过 **100/100 轮**（但该项按一条 241pt 漂移读数判红——独立快照证明是探针单次取样误报）；收紧基线后 +23 是 **61/100** | +22 是 3/100、+21 是 11/100、+23 停在**第 62 轮的单次写后读回读不到**（32ms 后恢复路径就读到了）。+24 给 `readBackFrame` 加了有界重试（3×70ms），**61/100 是 +23 的修复前基线，不是当前能力** |
| 过渡帧样本量（P0-18） | +21 三轮 n=**13/18/12**；+23 三轮 n=**36/61/53**，都 < §20.2 要求的每路径 ≥100 | 样本不足不能判。+23 同轮粗读数：**44 段在预算内、106 段超预算**（判据 P95≤20ms 且掉帧占比≤1% 且无连续 3 帧卡顿）；帧间隔 p95：+21 是 47.2/44.3/50.7ms，+23 是 32.6/43.8/39.6ms——离 20ms 预算有明显距离，但样本没到量级之前这一行只算趋势 |
| 几何写入（工作台路径） | +20 n=307 median 49.9 / p95 144.6ms；+22 n=209 median 22.3 / p95 105.2ms；+23 n=267 median 21.6 / p95 95.1ms | **样本量终于够了**（§4 第 12 项缺的就是这个），但注意口径：这是主区交换场景的混合路径（含目录复核、写后读回与重试），跟 0.1.1 的 17.9ms / 0.1.5 的 117.9ms 那两次单写不是同一件事，不能直接互相引用 |
| 幻影提示 / 真实漂移 | +20 抓到两条幻影「窗口尺寸未能恢复」（独立快照证明窗口其实在原位）；+22 抓到 241pt（基线采样在提交滞后窗口内）与 44pt（ZCode 自播动画）"漂移"；+23 两样都是 **0** | WorkbenchReducer 同步收口（+21）+ 稳定基线 + 漂移分账（+23）之后干净了一轮，属"单轮干净"不是定论 |
| Vistile CPU / 总览帧率 | CPU 0.08（+20）/ 0.42（+22）/ 0.04（+23）；总览帧率 8.2 / 95.5 / 0（+23 有锁定段） | **仍在同一个"不可信"区间**：口径没核（§4 第 2 项），且 +23 的 0 帧率来自锁定段。这一列的工作台轮次不作任何结论 |
| 终止状况 | +16…+23 每轮探针都自行退出并写全报告（+18 起另留 live log 与快照） | +18 那轮抓到过一次"第 2 次交换后会话静默退出"（判据：报告缺失），+19 的焦点阶梯修复后未再复现 |

还没到量级的：`P0-17` 的 100/100 与 `P0-18` 的 ≥100 帧样本要靠解锁后的 run12 与 30 分钟长跑（run13）补；
**这两项起跑的是发布字节（CI 构建）**，上表八轮跑的是各轮本机构建（§1 的说明在 [Compatibility.md](Compatibility.md) §1.1）。

### 3.8 §20.2 采样端点清单与时间口径（本轮把"只测内部耗时"改成"逐段可核对"）

方案 §20.2 要求端点打在真实输入、首帧反馈、journal prepare、AX 排队、写入、读回、激活、present、settle 上，
并明令"不能用 reducer 状态推进或 display-link callback 次数代替实际画面呈现"。下表是**代码里真实存在的打点**，
每行给出指标名与文件行号；报告里的数字只能从这些名字读出来，名字对不上就是没测。

| 端点 | 指标名（`Metrics.measure` 的 name） | 打点位置 | §20.1 判据 |
| --- | --- | --- | --- |
| 真实输入 | 不单独成项，是首帧延迟的**锚点**：两处 view-action 入口写 `lastInputStamp` | [App/AppCoordinator.swift:1481](../App/AppCoordinator.swift#L1481)（总览卡片）、[:1533](../App/AppCoordinator.swift#L1533)（工作台轨道） | — |
| 首帧反馈（present 出去的那一刻） | `过渡首帧延迟·<场景>·<分组键>` / `过渡首帧延迟(无点击锚点)·<场景>·<分组键>` | 锚点消费 [App/AppCoordinator.swift:1186](../App/AppCoordinator.swift#L1186)，判据是渲染器 `diagnostics().presents` 增量 [Presentation/ModeTransitionCoordinator.swift:435](../Presentation/ModeTransitionCoordinator.swift#L435)，入表 [App/AppCoordinator.swift:1260](../App/AppCoordinator.swift#L1260) | 点击反馈 P95 ≤50ms（逐组判） |
| 呈现 vs 回调 | 计数 `过渡零呈现段`、`过渡回调多于呈现` | [App/AppCoordinator.swift:1269](../App/AppCoordinator.swift#L1269)、[:1272](../App/AppCoordinator.swift#L1272)，缺口算式 `ticks − presentedFrames`。这两条不按分组拆：它们是"有没有画面证据"的核对，不是 §20.1 带目标值的数字 | 任一非 0 即不能宣布该项达标 |
| 帧间隔（按场景×分组分段） | `过渡帧间隔p95·<场景>·<分组键>` | [App/AppCoordinator.swift:1235](../App/AppCoordinator.swift#L1235)，段内统计由 `FrameIntervalStats.measure` 做 | P95 ≤20ms（逐组判） |
| 段级帧预算（掉帧占比与连续卡顿） | 计数 `过渡帧预算内·<分组键>` / `过渡超帧预算·<分组键>` | [App/AppCoordinator.swift:1242](../App/AppCoordinator.swift#L1242)；`meetsTarget` = P95≤20ms 且 >33.3ms 占比 ≤1% 且无连续 3 帧 [Packages/VistileCore/Sources/VistileCore/Domain/MotionLevel.swift:50](../Packages/VistileCore/Sources/VistileCore/Domain/MotionLevel.swift#L50) | 任一组的「超预算」>0 即该组未达标 |
| 有效间隔总数 | 计数 `过渡有效帧间隔·<场景>·<分组键>` | [App/AppCoordinator.swift:1246](../App/AppCoordinator.swift#L1246)，值取 `FrameIntervalStats.count`（该段里有限且 >0 的间隔条数） | §20.2「累计至少 1,000 个有效间隔」，按组判 |
| journal prepare | `日志:批量 prepare` | [App/AppCoordinator.swift:632](../App/AppCoordinator.swift#L632) | 无独立阈值，用于分离"落盘慢"与"AX 慢" |
| journal 事实追加 | `日志:事实追加` | [App/AppCoordinator.swift:657](../App/AppCoordinator.swift#L657) | 同上 |
| AX 排队（提交→通道认领） | `工作台:AX 排队` | [Presentation/WorkbenchSwitchCoordinator.swift:106](../Presentation/WorkbenchSwitchCoordinator.swift#L106) | 同上；排队时长决定"点了没反应"是不是队列问题 |
| 几何写入（含读回与重试的混合段） | `工作台:几何写入` | [Presentation/WorkbenchSwitchCoordinator.swift:654](../Presentation/WorkbenchSwitchCoordinator.swift#L654) | 历史口径见 §3.7，不与单次写入互引 |
| 写后读回（单独一段） | `工作台:几何读回`、`几何读回` | [Presentation/WorkbenchSwitchCoordinator.swift:115](../Presentation/WorkbenchSwitchCoordinator.swift#L115)、[Presentation/FocusCoordinator.swift:188](../Presentation/FocusCoordinator.swift#L188)，取值 `GeometryWriteReport.readBackMS`（3×70ms 有界重试之和） | 同上 |
| 激活 + Raise | `激活+Raise` | [Presentation/FocusCoordinator.swift:419](../Presentation/FocusCoordinator.swift#L419) | 同上；context 带"激活返回/raise 返回/焦点一致/前景一致" |
| 最终 settle | `工作台:布局结算` | [Presentation/WorkbenchSwitchCoordinator.swift:355](../Presentation/WorkbenchSwitchCoordinator.swift#L355) | 同上 |
| 三条模式路径整体（点击→落定） | 逐组 `点击→落定p95·<路径>·<分组键>`；另有一行不带分组键的**合池概览**（只作概览，判定不看它） | 采样 [App/P0Probe.swift:1912](../App/P0Probe.swift#L1912)（`recordClickOutcome`），逐组判定与入表 [App/P0Probe.swift:1623](../App/P0Probe.swift#L1623) | ≤600 / ≤500 / ≤500ms（逐组判） |
| 成功率与超时数 | 报告正文一行：`<路径> 成功率X%（落定/派发）、超时N` | [App/P0Probe.swift:1928](../App/P0Probe.swift#L1928)（`clickOutcomeText`），长跑侧 [:1794](../App/P0Probe.swift#L1794) | §20.2「同时记录成功率和超时率」 |

**口径约定（本轮统一）**：
- 所有时长、deadline、动画进度一律单调时钟：App 侧 `CACurrentMediaTime()`（`mach_absolute_time`），
  探针侧 `monotonicNow()`（[App/P0Probe.swift:2180](../App/P0Probe.swift#L2180)）。
  墙钟只用于报告日期与日志时间戳。改口径之前跨睡眠/改表的读数不能与本轮互引。
- `Metrics.summary()` 会把每个名字改写成「<name> p95」并把 context 覆盖成「n=…, median=…」，
  所以**每条样本自己的 context 只通过 `onSample` → 报告正文**落盘。消费端（含 P0-18）必须按前缀匹配，
  不能按全名相等；名字形状由 `PerformanceMetricName` 单点定义，生产侧与读取侧共用
  （[App/AppCoordinator.swift:1235](../App/AppCoordinator.swift#L1235) 写、[App/P0Probe.swift:1652](../App/P0Probe.swift#L1652) 读）。
  两侧各自拼字符串会静默失效——读取侧一行都匹配不到，报告只写"没有帧样本"，那是测量坏了。
  这条契约由两组测试钉住：核心包的命名往返
  （[Packages/VistileCore/Tests/VistileCoreTests/PerformanceGroupTests.swift:78](../Packages/VistileCore/Tests/VistileCoreTests/PerformanceGroupTests.swift#L78)）
  与宿主里走真实 `Metrics` 的分组合池检查
  （[Tests/HostTests/TransitionSceneTests.swift:1337](../Tests/HostTests/TransitionSceneTests.swift#L1337)）。
- 首帧延迟的锚点只在"由真实点击触发的那一段"生效，且用完即清：探针直接 `dispatch`、自动替补段走
  「(无点击锚点)」单列，**不允许混进点击反馈的 P95**。
- 样本不足一律标未判：每条模式路径 ≥100 次操作、短场景累计 ≥1,000 个有效间隔；
  锁屏/授权弹窗/系统睡眠记为环境中断，不静默删除。
  **分组已落地**（此前所有 P95 都是跨刷新率、跨 reduceMotion、跨冷热合池的，那不符合 §20.2）：
  分组键 = 「刷新率档位·reduceMotion=开/关·冷启动/热路径」三维，由 `PerformanceGroup` 单点定义
  （[Packages/VistileCore/Sources/VistileCore/Domain/PerformanceGroup.swift:7](../Packages/VistileCore/Sources/VistileCore/Domain/PerformanceGroup.swift#L7)），
  环境读数在每次飞行开始时现取（[Diagnostics/Metrics.swift:12](../Diagnostics/Metrics.swift#L12) 的 `PerformanceEnvironment.current(coldStart:)`，
  刷新率走 [Diagnostics/Metrics.swift:18](../Diagnostics/Metrics.swift#L18)），"冷启动"就是该场景的第一次飞行
  （[App/AppCoordinator.swift:1183](../App/AppCoordinator.swift#L1183)）。判定阈值与未判口径同样单点：
  `PerformanceGate.minSamples = 100` 与 `judge(...)`
  （[Packages/VistileCore/Sources/VistileCore/Domain/PerformanceGroup.swift:80](../Packages/VistileCore/Sources/VistileCore/Domain/PerformanceGroup.swift#L80)），
  「≥1,000 个有效间隔」这一维以前没有测量支撑（只有段数），现在由 `过渡有效帧间隔` 计数按组累加，P0-18 双门都过才判。
  120Hz 组可以按本机帧间隔给更严的预算，但 §20.1 的 20ms 判据对 60Hz/120Hz 一视同仁，保留 60Hz 基准便于与历史比较。
  **本机的档位已有实测依据**：内置面板 `CGDisplayCopyDisplayMode(1).refreshRate` 报 `120.0`（2026-10-17 16:17，锁屏熄屏态下测得；
  注意 `CGGetActiveDisplayList` 在熄屏时回 0 块，必须走 `CGGetOnlineDisplayList` 才拿得到模式与刷新率，脚本见
  [Evidence/README.md](Evidence/README.md)「run14 起跑前」）。ProMotion 会随内容升降，所以分组标签要在动画进行中重读该值，不能沿用一格的静态读数。
- §3.1–§3.7 的自报 CPU（0.2–0.42）与"总览帧率"仍在同一个未核区间，**不作为改善基线**（方案 §20.3）。
  要引用 CPU 必须先与 Activity Monitor / Instruments 对表并写清对表方式。

## 4. 必须补齐的实测项（全部未测）

1. **空闲基线**：总览打开且画面静止时 `presents` 不增长、总览关闭后 CPU 回到接近 0%、GPU 无持续占用（Activity Monitor 对照）。
2. **12 窗口常驻**：balanced 层级下的 CPU、GPU、内存（纹理数 × 输出尺寸）、`windowserver` 增量。授权态四轮自报 CPU 是 0.2 / 0.3 / 0.3 / 0.3（§3.1–§3.4），十几路流不可能这么低，**先要查的是这个数怎么来的**，再谈优化。0.1.10 工作台八轮自报 0.04–0.42（§3.7），仍在同一个"不可信"区间，不改变这条判断。
3. **30 窗口压力**：帧率下降是否渐进、降级发生时卡片标注是否与实际更新方式一致、`replacedCount`/`staleCount` 是否上升。
4. **遮挡窗口**：被完全遮住的窗口其 `publishedCount` 是否继续增长（这是"实时"的判据，不是肉眼判断）。**探针已给出四轮数据**：16 个里 9 个、16 个里 12 个、17 个里 9 个、16 个里 12 个在 1.5s 内收到新帧（§3.1–§3.4）；还缺的是**长时间稳定性**（连续几分钟不掉流）。
5. **热状态路径**：`serious`/`critical` 下降级是否按阶梯发生、优先窗口是否最后被牺牲。
6. **过渡动画**：24 帧内是否稳定、代理层与真实窗口衔接有无闪白。0.1.10 工作台的过渡帧间隔采样已经在跑（§3.7：两轮 n=13/18/12 与 36/61/53，p95 在 32.6–50.7ms），但样本没到 §20.2 的 ≥100、结果也超其 P95≤20ms 预算——这一项从"全未测"变成"有初步样本、离判据还差"。
   **§3.7 那批样本没有分组维度**（当时指标名里没有刷新率/reduceMotion/冷热），按 §20.2 只能作趋势，不能和新分的组并成同一个 P95，也不能拿来判"60Hz 组"或"120Hz 组"。
7. **跨缩放屏**：Retina 与外屏混合时纹理尺寸选择是否仍按格子宽度。
8. **长时间停留**：30 分钟内是否有纹理/事务/观察器泄漏（`inFlightTextureCount`、`retained.count`、`journal.unfinished`）。
9. **呈现健康度**：`RendererDiagnostics` 的 `missingDrawables`、`submissionFailures`、`gpuErrors` 在长时间运行与显示器变更后是否保持为 0（P0-9 每轮记增量）。
10. **层级改写频率**：`orderingApplyCount` 在总览持续打开的 30 分钟内应只有策略/目标变化那几次；持续随帧增长说明在跟 WindowServer 较劲（P0-10 记 2s 窗口）。**§3.4 那轮观察窗里只有 1 路流**，所以这一项目前的三轮强证据来自 §3.2/§3.3（12 路流、163/149 帧），要补的是"总览持续打开 30 分钟"这一档。
11. **软上限校准**：`streamSoftLimit = 12` 目前只是保守起点，要用第 2、3 项的实测数据决定它是收紧还是放宽。四轮 17 窗口都触顶降档；**0.1.5 的备注里"降级影响 17 个"与"18 个"连着出现、和目录的 17 个窗口不自洽**，先把这个计数口径查清再谈阈值。
12. **几何写入耗时**：四轮只有两个样本（§3.1 的 17.9ms/偏差 0.0pt 与 §3.4 的 117.9ms/p95 117.9、n=1），相差一个量级却说不出原因。要同一台机器、同一批窗口连跑 ≥20 次写入取分布，并把 0.1.6 起「过渡超时」新增的"预算 / 实际等待 / 最后一次几何写入"字段一起看——否则超时到底是预算问题还是写入问题，永远分不开。**0.1.10 工作台轮次已经给出大样本分布**（§3.7：n=209–307，median 21.6–49.9ms、p95 95–145ms），但那是主区交换的混合路径（含目录复核、写后读回与重试），与这里的"单次写入"不是同一口径；两套要分开校准。

复现与记录方式：用 `UITestHarness` 造窗口，跑 `open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app`（探针必须跑在已授权的正式版包上），把 `~/Desktop/Vistile Diagnostics/capability-report.md` 的计时表与 `P0-acceptance-checklist.md` 一起存档；Instruments 用 `com.misswell.Vistile` 子系统的 signpost 区间对齐时间轴。
