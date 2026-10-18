# Vistile 验收说明（P0 门禁）

判据来自方案 §4：**必须用屏幕录制与窗口顺序诊断确认，不能仅凭"返回无错误"通过。**
本文件记录：每一项要看到什么、探针能自动取到什么证据、人工要做什么、以及本机当前结论。

## 1. 结论

**P0 未通过。** 探针跑的是已授权的正式包（`/Applications/Vistile.app`，Developer ID + 公证），
不是仓库里的 Debug 编译。授权态到现在有下面这些轮次，**每一轮的原件都在
[Docs/Evidence](Evidence/README.md)**，本表只是转录：

| 轮次 | 跑的包 | 这一轮能不能用 | 自动项 | 红的是什么 |
| --- | --- | --- | --- | --- |
| 10-16 15:13 | 0.1.1+2（不含 R01–R11） | 可用 | 9 项：7 通过 / 2 失败 | `P0-1` 同进程 AX 索引不唯一；`P0-3` 放大 Code 目标时兄弟窗口 #13→#15 一起被提升 |
| 10-16 15:26 | 0.1.3+4 | 可用 | 13 项：12 通过 / 1 失败 | `P0-1` 同进程 AX 索引不唯一（查明是探针判错） |
| 10-16 15:56 | 0.1.4+5（判据改正后） | 可用 | 13 项：12 通过 / 1 失败 | `P0-3` Chrome：目标 #14→#9 但兄弟 #17→#13（查明基准取在上一轮提升还没落定的窗口列表上） |
| 10-16 16:37 | 0.1.5+6（restoreOverview 生效） | 可用 | 13 项：11 通过 / 2 失败 | `P0-3`：Chrome 目标 #7→#7 没被提升、访达 兄弟 #21→#20；`P0-7`：有窗口的屏幕 2 块但缺布局 2（另有 1 条「过渡超时」） |
| 10-16 17:37 | 0.1.6+7 | **作废** | — | 全程 0 帧、AX 只解析出 5/15：桌面当时锁着屏（判据见 [Evidence/README](Evidence/README.md)） |
| 10-16 17:46 | 0.1.6+7 | 可用 | 13 项：11 通过 / 2 失败 | `P0-7` 缺布局 1；`P0-9` present +0（0 路流瞬间取样）。**`P0-3` 这一轮两个多窗口应用都判通过** |
| 10-16 18:14 / 18:17 / 18:27 | 0.1.8+9 | **作废 ×3** | — | 同样全程 0 帧、AX 可解析 0/10；18:27 那轮距覆盖安装已 14 分钟，**"等一会儿就好"是错的，锁屏才是根因** |
| 10-16 18:33 | 0.1.8+9 | 有帧可判，但**整轮在锁定态** | 14 项：13 通过 / 1 失败 | 唯一红是 `P0-3`「Raise 没有发出（拿不到 AX 句柄）」——锁定态下任何应用的 AX 窗口列表都是空的，0.1.9 起这种轮次记**未测** |
| 10-16 20:25 | 0.1.9+11 | **诊断轮** | 17 项：16 通过 / 1 失败 | `P0-4`「总览面板持有键盘=true，键盘归属=overview」——红在取证时机不在产品（修复前的对照） |
| 10-16 20:29 | 0.1.9+12 | **诊断轮** | 17 项：16 通过 / 1 失败 | `P0-4`「5s 内没落定＋总览面板持有键盘」，形状同 +11 |
| 10-16 20:38 | 0.1.9+13 | 可用 | 17 项：无失败 | `P0-4` 转通过（进入主区 n=3）；`P0-7` 未测（本轮只接 1 块屏） |
| 10-17 00:02 | 0.1.10+16 | 可用 | 21 项：19 通过 / 2 失败 | `P0-16`=2/100、`P0-17`=12/100——拒绝来自同一根因：窗口服务器几何提交滞后 AX 约 0.6s，目录采样把刚移动的窗口判成"未唯一"；`P0-12/13/14` 转通过 |
| 10-17 00:15 | 0.1.10+17 | 可用 | 21 项：19 通过 / 2 失败 | `P0-16`=6/100、`P0-17`=21/100；新失败形状＝目录快照把一次 AX 读超时折叠成"不可调整尺寸"，写前守卫拿坏采样当事实 |
| 10-17 00:22 | 0.1.10+18 | **诊断轮**（不可全判） | 21 项：19 通过 / 2 失败 | `P0-16`=1/100（第 2 次交换后会话静默退出）、`P0-17` 未测、`P0-14` 红＝探针取样早于返回动画落地；全程 0 帧，依赖帧的项不能当产品结论 |
| 10-17 00:43 | 0.1.10+19 | **诊断轮** | 21 项：19 通过 / 2 失败 | `P0-16`=3/100、`P0-17`=9/100——被点身份瞬时未唯一时宿主把点击丢掉（有日志留痕）；+19 焦点阶梯修复本轮零静默退出 |
| 10-17 00:50 | 0.1.10+20 | 可用 | 21 项：20 通过 / 1 失败 | `P0-16` 转通过（100/100，p95=384ms）；`P0-17` 红＝241.0pt 漂移，独立快照证明是探针单次取样误报；另抓到两条幻影提示「窗口尺寸未能恢复」（+21 修） |
| 10-17 01:09 | 0.1.10+21 | **诊断轮** | 21 项：18 通过 / 3 失败 | `P0-16`=19/100（「拿不到 AX 句柄（身份未唯一确定）」）、`P0-17`=11/100＋真实漂移 144/234pt；两处句柄路径一个坏采样就判死（+22 修：带截止时间复核目录） |
| 10-17 01:37 | 0.1.10+22 | **诊断轮** | 21 项：20 通过 / 1 失败 | `P0-16` 转通过（100/100，p95=552ms）；`P0-17`=3/100（第 4 轮 Chrome 写入报 -25204、读回其实已在目标位）＋漂移 241pt（基线采样在几何提交滞后窗口内）与 44pt（ZCode 自播动画） |
| 10-17 01:58 | 0.1.10+23 | **诊断轮** | 21 项：20 通过 / 1 失败 | `P0-16`=通过（100/100）；`P0-17`=61/100——第 62 轮写入双侧错误码=0、单次读回读不到被判「不能宣称到位」，但 32ms 后恢复路径读到了 66,184；幻影提示与真实漂移本轮消失。本轮中途有锁定段与授权弹窗，只作诊断 |

### 锁定态会伪造结论，这是本轮新学到的

`P0-0` 的权限预检在锁屏时**照样回「屏幕录制=true，辅助功能=true」**，但：

- 捕获侧：0.1.8 的 18:14/18:17/18:27 三轮累计捕获帧 **0**、present 1；
- AX 侧：锁定态下 `osascript` 问 Code / Finder / Qoder 的 `count of windows` 一律回 **0**
  （`UI elements enabled` 仍回 true），于是目录里 10 个窗口**一个都解析不出 AX 索引**。

后果是三项同时失真：`P0-3` 记「Raise 没有发出」、`P0-4`/`P0-9` 记「没有可放大/可聚焦的窗口」。
**这些都是环境，不是产品结论。** 0.1.9 的处理是：`P0-3` 进场前要求"预检为真且至少一个窗口解析得出
AX 索引"，不满足记未测；环境自检同时报「帧 / AX / 会话锁定」三条读数，并点名哪些结论作废。
复核命令（三条公开接口）写在 [Docs/Evidence/README.md](Evidence/README.md#一轮能不能用怎么当场判)。

### 到目前为止真正立得住的轮次结论

- `P0-4` 从 0.1.5 起判**通过**：放大 ChatGPT 后总览面板持有键盘=false、键盘归属=targetApplication。
  上一轮那条"未测"的根因（上一项结束时阶段是脏的、总览压根没打开）由 `restoreOverview()` 解决。
- `P0-7` 从 0.1.8 那轮（18:33）起判**通过**：2 块屏、有窗口的屏幕 1 块、承载窗口 2、**缺布局 0**、
  已算出布局 1 屏、网格 1 屏（陈旧标记=false）、活跃流 10 路。这是 0.1.7 那批取数时机改动
  第一次在非作废轮次里拿到证据。
- `P0-10` 在有回调的 2s 里层级改写 **0 次**（0.1.8 那轮：10 路流、2s 内 170 帧）。
  以前这项在"0 路流"的瞬间睡 2s 只能记未测，而 0.1.8 又暴露出反过来的形状（10 路流却 0 帧，
  旧判据据此记通过）——0.1.9 把判据收紧成"这 2s 真的有回调"。
- `P0-3` 在 0.1.6 那轮（17:46）两个多窗口应用**都判通过**：Code 目标 #15→#8、兄弟 #13→#13；
  访达目标 #29→#7、兄弟 #20→#14 但对仍在场的窗口一个便宜都没占。
  **但这一轮的「层级」矩阵格是空的**：0.1.6 收回两处代填时把 `updateRow` 只留在失败分支，
  通过分支一行不写，所以那一列在 0.1.8 及以前**永远变不成「通过」**（0.1.8 补上，见 §3）。
- **0.1.10 工作台语义下的六条**（+16…+21 轮，解锁桌面；+22 起中段锁定，这些项按未测记）：
  `P0-12` 工作台入口通过（真实点击、主窗口读回偏差 ≤0.5pt）；`P0-13` 主副交换通过（只动主区与
  原主 slot、其余 13 个占用与滚动偏移未动、原主回位偏差 0.0pt）；`P0-14` 返回总览通过；
  `P0-15` 总览先行通过（首开模式=总览、面板 1 块、15 个格子、主区空、在途事务 0、点击 0 次）；
  `P0-4` 通过（进入工作台（主区=Code）落定后没有任何 Vistile 面板持有键盘）；
  `P0-3` 在 **UITestHarness 脚手架（6 窗口）** 上连续六轮通过（目标顺序 #12→#4、#18→#4、#15→#5 等）。
  **脚手架上的通过不改真实应用的矩阵格**——那 12 个真实应用的「层级」仍按 §2 各自的状态。
- `P0-16`（固定交换 100 次）：+20/+22/+23 三轮 **100/100**（点击→落定 p95 = 384 / 552 / 554 ms）。
  更早几轮的红（2/100、6/100、1/100、3/100、19/100）逐轮定位到宿主点击复核、写前实读、
  焦点阶梯、句柄复核四处根因，修后连续三轮走满（见轮次表与 [RELEASE_NOTES](../RELEASE_NOTES.md) 0.1.10 段）。

`P0-3` 那三条历史红的成因，到这里已经全部能分辨：

- **Chrome「目标没被提升」（0.1.5 #7→#7）**：`raiseOnly` 以前查不到身份就静默 return，
  一个 Raise 都没发也不记录。0.1.6 起它返回 `RaiseOutcome`，探针把"没发出去"和"发了没生效"分开写，
  **两种都判红**。0.1.6/0.1.8 两轮里 Chrome 都没有 ≥2 个窗口，这一格因此仍未复测。
- **访达「兄弟一起被提升」（0.1.5 #21→#20）**：旧判据拿绝对下标相减，两次读数不是同一个参照系。
  新判据下沉到核心包 `TargetRaiseAudit`，只在"两次读数都仍在屏上的窗口"里做两两比较；
  0.1.6 那轮同一场景判**通过**（兄弟 #20→#14 但没占任何仍在场窗口的便宜）。
  **这不是放宽**：按名次比的写法会放过"目标与兄弟一起越过第三方窗口"，所以用的是两两比较
  （`TargetRaiseAuditTests` 6 条钉住两侧）。
- **`P0-7` 的「缺布局」**：网格在会话隐藏时被 `resetForHiddenSession` 清空，而 `layouts` 正是从它重建的。
  0.1.7 起这一项先恢复总览、等布局确实产出一次再取数，并把当时的阶段/网格屏数/活跃流写进读数；
  0.1.8 那轮**缺布局 0**，判据本身一个字没改。
- **「过渡超时」**：0.1.6 起会写方向、预算、实际等待毫秒、目标应用、令牌代次与最后一次几何写入，
  之前只有一个"未确认"，分不清"预算太短"还是"根本没写成功"。

**`P0-1` 已经在实机上回答：通过（判据改正后连续多轮）**。0.1.5 那轮 17 个窗口回 `窗口编号无重复=true；
同进程 AX 索引无重复=true`，多窗口进程 3 个、AX 唯一对应 17 个；0.1.6（15 窗口）与 0.1.8（10 窗口）同样不红。
判据改正前那两轮（0.1.1、0.1.3）的红来自探针自己的错误判据（把全局 AX 索引放在一起比数量，而索引只在同进程内有意义），判据改正后不再红——
这不是放宽验收，新判据反而更严格：冲突时要点名进程、索引和冲突的窗口编号
（`CatalogIdentityAudit`，核心包单测守着）。

已得到的正面事实（这些不等于 P0 通过）：

| 事实 | 证据 |
| --- | --- |
| 同 Developer ID 覆盖安装不需要重新授权 | 0.1.1→0.1.3、0.1.3→0.1.4、0.1.4→0.1.5 三轮覆盖安装后直接跑探针，`P0-0` 均回「屏幕录制=true，辅助功能=true」，全程没有弹授权 |
| 目录身份判据（窗口编号唯一 + 同进程 AX 索引单射） | `P0-1`（0.1.5）· 窗口 17 个、多窗口进程 3 个、AX 唯一对应 17 个、`窗口编号无重复=true；同进程 AX 索引无重复=true`（0.1.4 与 0.1.5 连续两轮；0.1.3 及更早那条红是探针判错） |
| 真实点击驱动整条链路并真的上屏 | `P0-9`（0.1.5）· 真实点击 → 放大 ChatGPT：视图动作 1 次、阶段到达=true；真实背景点击 1 次 → 回到总览=true；最小化 0→0；同期 `present` +2、捕获帧 +1（1 路流）、GPU 错误 +0、提交失败 +0、缺 drawable 累计 0 |
| 层级不随捕获回调反复改写 | `P0-10`（0.1.5）· 1 路直播流、2s 内 17 帧回调期间层级改写 **0 次**；`P0-10`（0.1.4）· 12 路流、2s 内 149 帧期间同样 0 次 |
| 未实现层级策略已迁移并写回 | `P0-10` · 生效策略=normalLevelActivateAndRaise，持久化同值 |
| 背景点击不留受信令牌 | `P0-11`（0.1.5）· 空转背景点击后令牌残留=false，随后外部激活（com.alibaba.DingTalkMac）正常退出总览 |
| 遮挡窗口继续收帧（"实时"的客观判据） | `P0-2`（0.1.5）· 被遮挡 16 个里 12 个在 1.5s 内收到新帧；全目录帧增量 46 ≈ 30.7 帧/秒 |
| 只提升被点窗口（Code 场景，3 窗口） | `P0-3`（0.1.5）· 目标 #12→#8，同应用另一窗口 #10→#12；0.1.4 那轮同场景是 #17→#9 与 #18→#18 —— 连续两轮通过 |
| 放大后键盘归目标应用 | `P0-4`（0.1.5）· 放大 ChatGPT 后总览面板持有键盘=false、归属=targetApplication。0.1.1 也拿到过同一条，0.1.3/0.1.4 因探针进场状态判"未测"，0.1.5 起 `restoreOverview()` 后稳定可取 |
| 背景点击 100 次不累积副作用 | `P0-5`（0.1.5）· 819.7ms、结束阶段=`overview`、最小化 0→0、2/2 块屏自留事件 |
| 身份与格子沿用 | `P0-6`（0.1.5）· 17 个身份沿用、格子变动 0、共用启动标识的重复窗口编号 0 |
| 多显示器承载 | `P0-7`（0.1.8）· 2 块屏、有窗口的屏幕 1 块、承载窗口 2、**缺布局 0**、已算出布局 1 屏、活跃流 10 路 ⇒ 通过。0.1.5 那轮「缺布局 2」已定性为测量时机（网格被会话隐藏清空后取数），0.1.7 起先等布局产出再取数 |
| 捕获预算按上限降档 | 备注「降级影响 17 个目标（流上限 12，热状态 nominal）」，采样时 12 路流 + 6 个低频 |
| 退出事务恢复 | 0.1.5「未结束事务 0 条」，探针跑完自行退出 |
| 探针跑的就是发布字节 | **0.1.10**：GitHub Release 的 `Vistile_v0.1.10_macos_arm64.dmg`（CI 构建，1995501 字节，`sha256 4ac65158…86af`，与资产接口 `digest` 逐字节相同）挂载后 dmg 与包内 app 票据都有效、`Authority` 链到 Developer ID (U8U443D7ZL)、`Info.plist 0.1.10/24`、包内二进制 `sha256 9f830aa5…a40f`；**该载荷已覆盖装回 `/Applications/Vistile.app`**（部署后二进制同哈希）⇒ **run12 起探针跑的就是发布字节**。此前 +16…+23 八轮跑的是各轮本机 Xcode 27 构建（与标签 `v0.1.10`→`ceb7f01` 同源码；+24 的本机构建 `5f7e8ae8…` 从未被任何一轮跑到，发布字节本身就是 +24 代码的 CI 构建）。0.1.5 那轮同法核对过（二进制 `sha256 5ec8ca4e…`） |
| 纯逻辑层 148 项/15 suite ＋ XCTest 63 项 / 宿主层 178 项（1 skip） | `swift test`、`xcodebuild test -scheme VistileHostTests`，2026-10-17 15:07 最终一轮全过（数字与逐项映射见 §7、§9） |

仍要澄清、现在既不算通过也不算失败的：

- `P0-3` 的 Chrome 一格（0.1.5「目标 #7→#7 没被提升」）：既可能是 `raiseOnly` 没发出去，也可能是
  发了但 Chrome 不吃 AX Raise。0.1.6 起 `RaiseOutcome` 已能把两种成因分开记，但 0.1.6 及以后各轮
  Chrome 都没再出现 ≥2 窗口场景，**这一格到 0.1.10 仍未复测**。
- `P0-17`（往返 100 次）：+20 那轮**走完了 100/100，但按一条 241pt 漂移读数判红**——独立快照证明那是探针单次取样误报；此后 +21/+22/+23 分别只走到 11、3、61/100，+23 停在第 62 轮的单次写后读回读不到（写入双侧错误码=0，32ms 后恢复路径就读到了）。+24 给 `readBackFrame` 加了有界重试（3×70ms），**走不走得满由 0.1.10+24 的解锁复跑定性**。
- `P0-18` 的每路径帧样本一直不够：+21 那轮 n=13/18/12，+23 那轮长一些也只有 36/61/53——都 < 100，
  样本不足不能判（+23 同轮还记了「44 段在预算内、106 段超预算」的粗读数）。
  §20.2 的"每路径结论"要等长跑轮次。
- 人工项（画面是否串、中文输入、Sheet、⌘Tab、跨屏拖拽、最小化标注，以及 0.1.10 新增的
  「L 型主区是真实窗口」「交换画面不跳位」「返回不闪」等录屏项）一律**未测**，需要录屏。
- `P0-8` 的两条本机无场景项仍**未测**：撤销权限（程序不能替用户撤销）、最小化窗口（本机当时没有最小化窗口）。

（0.1.5 那轮的访达一格与「缺布局 2」曾挂在这里"等 0.1.6 复跑"，两个都已经有结论：访达在
0.1.6 用两两比较判据通过、`P0-7` 在 0.1.8 通过；条目已移走，成因见上面「三条历史红的成因」。）

**这些都不等于 P0 通过。** 宿主测试全部运行在注入的替身与主屏之外的面板上，
`T01` 里"面板实际成为 key 窗口"这一条依赖系统前台：宿主取不到前台激活时显式 `XCTSkip`
（同一条在本机两种结果都出现过：跳过、通过），因此键盘归属的最终结论仍属 P0 实机项。

## 2. 逐项：判据 / 自动证据 / 人工步骤

| 编号 | 必须观察到的结果 | 探针自动取证 | 人工（肉眼/录屏） |
| --- | --- | --- | --- |
| P0-1 | Safari 两窗 + Finder 两窗 + Terminal + 编辑器，至少 6 个独立完整缩略画面；同应用不串窗 | 目录记录数、`windowID` 唯一性、同进程 AX 索引单射、多窗口应用个数、可读回身份数 | 逐个点卡片，比对卡片画面与放大后的真实窗口是否同一扇 |
| P0-2 | 总览遮住全部源窗口、终端持续输出计数时，卡片计数继续更新；无递归捕获 | 被遮挡窗口 mailbox `publishedCount` 在 1.5s 内的增量、全目录帧速率 | 看卡片是否跟着变；确认 Vistile 自己的窗口没有出现在总览里（自捕获） |
| P0-3 | 点 Safari 指定窗口后，目标原生窗口在总览前，另一个 Safari 窗口不露出 | `CGWindowListCopyWindowInfo` 顺序（下标即层级）：`TargetRaiseAudit` 只在"前后两次读数都仍在屏上的窗口"里做两两比较——目标是否升到兄弟之前、兄弟是否把任何仍在场且原本在它前面的窗口甩到后面；`raiseOnly` 返回 `RaiseOutcome`，"没发出 Raise"与"发了没生效"分开记，两种都判红。前后各取"连续两次读数一致"的稳定值 | 录屏确认菜单/浮动面板没被总览压住，也没有别的应用窗口被顺带提升 |
| P0-4 | 中文输入、右键、菜单、另存为 Sheet 都正常，无输入转发 | 通过 `NSWindow.sendEvent` 打真实按下/抬起放大窗口（转接断掉本项直接记未测），再读总览面板是否为 key 窗口、状态机 `keyboardFocus` 归属 | 打「测试」看候选窗跟随真实窗口；右键、拖文本、⌘S 出保存面板、滚动与 ⌘C/⌘V/⌘T |
| P0-5 | 点击背景重复 100 次：回到总览、不最小化源窗口、不点击穿透 | 100 次 `backgroundClicked` 后阶段仍可见、最小化计数不变、每块屏的面板是否自留事件、耗时 | 录屏确认背景按钮没被触发、没有窗口缩进 Dock |
| P0-6 | 开关窗口、同名窗口、应用退出重启：不控制错误窗口、不复用失效 ID | 刷新前后身份沿用数、槽位变动数、跨进程 `windowID` 与启动标识冲突检查 | 两个同名窗口（harness 里有「无标题副本」）逐个操作；退出再启动看格子与尺寸恢复 |
| P0-7 | 两屏、不同缩放与负坐标：位置准确，不把窗口送到屏幕之外 | 取数前先恢复总览并等布局确实算出来一轮（网格在会话隐藏时会被 `resetForHiddenSession` 清空，直接读会看到空布局）；再记显示器数、负坐标屏数、不同缩放种数、有窗口的屏幕是否都有承载面板与布局，并把当时阶段与布局屏幕数写进报告 | 在副屏放大/收回，确认前景比例按副屏可用区、跨屏拖动后格子不跳 |
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

兼容矩阵的「层级」格现在**只由 `P0-3` 写**：它是唯一有"同应用 ≥2 窗口"场景、能分辨"只提升被点窗口"
的一项。`bringToFront` 的读回结果改记成独立样本「前景化」，不再代填矩阵——0.1.5 及之前那几份报告里
UGit/ChatGPT 等单窗口应用的「层级」格就是被这条代填补出来的，读回的是"是否在前台"，
不是方案 §11 要的"不带动兄弟窗口"，判据不同，不能顶替。0.1.6 起这些格子回到「未测」。

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
#    新版 xcodebuild 不再接受「-target 直连 + -derivedDataPath」同时出现（报 exit 64：
#    "requires a scheme"）；改走 scheme，UITestHarness 已挂在 Vistile scheme 的 build 目标里
#    （见 project.yml），产物路径不变。
xcodebuild -project Vistile.xcodeproj -scheme Vistile \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build build
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
探针启动时会先把上一轮的这三个文件归档进 `_archive/<上一份报告自己写的版本-生成时间>/`，
所以桌面那份永远是本轮的，历史轮次不会被覆盖（见 §6）。

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

## 6. 交付证据本身也要被守住

报告是本文件的判据来源，所以它的落盘规则等同于验收规则。这里记一次真实事故和它修成了什么：

**事故**：`CompatibilityRecorder.init(fileName:)` 的参数从来没被用上，落盘名硬编码成
`capability-report`。宿主测试传进来的 `host-test-<uuid>` 因此也写进了桌面那份正式报告——
2026-10-16 16:25 一轮测试把 **0.1.4 的原始报告覆盖成了只含合成窗口（App9000）的样例**，
14:46 那次归档的 `pre-0.1.2` 同样如此。结果就是：文档里那些 0.1.4 读数只剩转录，
再也拿不出原始文件去核对。**这属于"测试销毁交付证据"，比测试失败更严重。**

修成了三件事，都由 `T16DiagnosticsOutputTests` 钉住（4 条用例）：

| 规则 | 代码位置 | 怎么验 |
| --- | --- | --- |
| `fileName` 决定实际写出的文件名，共享名不再被顺带覆盖 | `CompatibilityRecorder.persist` 用 `"\(fileName).md/.json"` | `testFileNameDecidesTheWrittenFileAndNeverTheSharedOne` |
| 测试进程不往用户桌面写 | `resolvedOutputDirectory()`：`VISTILE_DIAGNOSTICS_DIR` > 测试承载（临时目录）> 桌面 | `testTestProcessDoesNotWriteToTheUsersDesktop` |
| 新一轮探针先归档旧报告，归档名带**那份报告自己**的版本与生成时间 | `archivePreviousRun()` + `archiveName()` 读旧 JSON 的 `appVersion/generatedAt` | `testArchivePreviousRunMovesEveryArtifactAndKeepsItsOwnVersionInTheName` |

实机复核（跑完宿主测试后，桌面那份必须是最近一次探针的，而不是测试产物）：

```bash
xcodebuild -project Vistile.xcodeproj -scheme VistileHostTests \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test

head -6 "$HOME/Desktop/Vistile Diagnostics/capability-report.md"   # 仍是上一轮探针的版本与生成时间
ls "$HOME/Desktop/Vistile Diagnostics/" | grep -c '^host-test-'    # 期望 0：测试产物不在桌面
ls "$TMPDIR/Vistile Diagnostics/" | grep -c '^host-test-'          # 期望 > 0：它们落在临时目录
```

2026-10-17 02:24 宿主测试后的实测复核：桌面报告仍是 0.1.10+23 探针（01:58:30 生成）未被覆盖、桌面 `host-test-*` = 0 条、临时目录 808 条——三条读数都符合预期。

## 7. 工作台 W/H 用例覆盖与 0.1.10 实际结果

0.1.10+24 最终回归（提交前最后一轮，2026-10-17 02:23–02:24）：

- 核心包 `swift test`：swift-testing **147 项 / 15 个 suite** ＋ XCTest **46 项**（即 `WorkbenchTests` 全部，W01–W29 的核心纯逻辑），0 失败，EXIT=0。
- 宿主 `VistileHostTests`：**157 项执行、1 项跳过、0 失败**，EXIT=0（xcresult：`build/Logs/Test/Test-VistileHostTests-2026.10.17_02-23-31-+0800.xcresult`）。

跳过的 1 项（按方案 §22 不计为成功，属实机待验项，不属于 W/H 任一项）：

- `T01ActionRoutingTests.testKeyboardFocusReallyLandsOnContentView` —— 跳过原因原文："宿主未取得前台激活：面板实际 isKey 依赖系统前台，需在实机/P0 验证"。

### W（方案 §18.1；全部在 `Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift`）

| 编号 | 用例 | 覆盖测试 | 结果 |
| --- | --- | --- | --- |
| W01 | 左/右栏几何 | `testW01RailGeometryStaysInsideAndNeverOverlaps` | 通过 |
| W02 | 面积与约束 | `testW02AreaRatioIsRealAreaAndSmallScreensAreExplicitlyConstrained` | 通过 |
| W03 | 交换 A/B | `testW03SwapOnlyTouchesMainAndSourceSlot` | 通过 |
| W04 | 连续 A/B/C | `testW04ConsecutiveSwapsConserveWindowsAndKeepScroll` | 通过 |
| W05 | 中间卡片关闭 | `testW05ClosingAMiddleCardOnlyLeavesItsSlotEmpty` | 通过 |
| W06 | 新窗口与追加 | `testW06NewWindowFillsVacancyThenAppendsWithoutStealingMain` | 通过 |
| W07 | 查询/过滤 | `testW07SearchNeverChangesFrozenPositions` | 通过 |
| W08 | 模式往返 | `testW08ModeRoundTripKeepsPlacementAndMainIdentity` | 通过 |
| W09 | 过渡 latest-wins | `testW09LatestSelectionWinsAfterPreviousConverges` | 通过 |
| W10 | 退出优先级 | `testW10ExitEventsWinAndStaleCompletionsCannotReviveWorkbench`＋`testW10SpaceChangeAndQuitAlsoTakePriority` | 通过 |
| W11 | 多屏目标 | `testW11TargetDisplayAndSourceDisplayStaySeparate`＋`testW11FixedPreferredDisplayWinsAndFallsBackWhenUnplugged` | 通过 |
| W12 | 持久化迁移 | `testW12LegacySettingsNeverBypassOverviewEntryOrDoubleScaleMainArea`＋`testW12SanitizeDropsDegenerateRailPreferences`＋`testW12LegacyTitleDerivedKeysAreCleanedToAppLevel`＋`testW12MemoryKeyNeverCarriesWindowTitle` | 通过 |
| W13 | 每次打开 | `testW13EveryOpenStartsAtOverviewAndNeverAutoEnters` | 通过 |
| W14 | 未选择不改窗口 | `testW14NothingTouchesRealWindowsBeforeSelection` | 通过 |
| W15 | 首次选中 | `testW15FirstSelectionCreatesOneMainPlusPreviews` | 通过 |
| W16 | 首次选中失败 | `testW16FailedFirstSelectionStaysInOverview` | 通过 |
| W17 | 返回全部窗口 | `testW17ReturnRestoresFrozenOverviewAndConservesWindows` | 通过 |
| W18 | 上下文重新选择 | `testW18ContextReselectionRestoresOrSwapsCorrectly` | 通过 |
| W19 | Esc/全局退出 | `testW19EscapeFollowsKeyboardOwnership` | 通过 |
| W20 | 模式过渡打断 | `testW20InterruptedTransitionNeverCommitsStaleTokens` | 通过 |
| W21 | 1窗/0窗/关闭目标 | `testW21SingleWindowZeroWindowsAndClosedTarget` | 通过 |
| W22 | 动效等级 | `testW22ReducedMotionAndPressureOnlyChangeTiming`＋`testW22FrameStatsMeasureP95RatioAndConsecutiveStutterRuns`＋`testW22MotionLevelDegradesOnBadStreakAndRecoversSlowlyWithHysteresis`＋`testW22ReduceMotionAndPressureSetTheBaseLevelAndResetObservations` | 通过 |
| W23（M3b 加项） | 分隔线调整 | `testW23DividerHitBandsSitInsideGapsAndClampToStyle`＋`testW23DividerPreviewOnlyMovesLocalProjectionAndNeverSettles`＋`testW23DividerCommitSettlesOnceAndStaleReadBackCannotOverwriteFinal` | 通过 |
| W24（M3d 加项） | 整理与置顶 | `testW24OrganizeCompactsGapsAndPutsPinnedAppsFirst`＋`testW24PinToggleIsAppScopedAndReversibleWithoutMovingCards`＋`testW24AdoptedPinsApplyAtFirstOrganizeAfterRelaunch`＋`testW24OrganizeAndPinRefuseWhileSwitchIsBusy`＋`testW24PreferenceKeyNeverCarriesWindowTitle` | 通过 |
| W25（M3f 加项） | 写入读回记入事务 | `testW25EnteringRecordsDockReadBackSoRecoveryRestoresOriginal`＋`testW25SwapStepsRecordReadBacksSoRollbackAndQuitCanRestore` | 通过 |
| W26–W29（+21 追加：幻影与事务收口） | 返回收口 / 进入失败补偿 / 进入超时 / 交换回滚收口 | `testW26SettledReturnLeavesNoPhantomForInterruptedHide`、`testW27EnteringFailureCompensationSettlesBeforeTransitionEnd`、`testW28EnteringTimeoutLeavesNoPhantomTransaction`、`testW29SwitchRollbackSettlementAcceptedWithoutSwitchingPhase` | 通过 |

### H（方案 §18.2；全部在 `Tests/HostTests/`）

| 编号 | 用例 | 覆盖（文件・场景标记） | 结果 |
| --- | --- | --- | --- |
| H01 | 两栏点击链路 | WorkbenchRailViewTests・点击链路，及拖动路径 | 通过 |
| H02 | 非激活焦点 | WorkbenchRailViewTests・键盘策略、「全部窗口」按钮（H02/H17 同一路径） | 通过 |
| H03 | Metal 设备/呈现 | WorkbenchRailViewTests・Metal 设备与呈现几何 | 通过 |
| H04 | B 几何失败 | WorkbenchSwitchTests・目标写入被拒：不提交、补偿、不假成功 | 通过 |
| H05 | A 恢复失败 | WorkbenchSwitchTests・原主写回失败：留痕、不假成功 | 通过 |
| H06 | 异步交错 | WorkbenchSwitchTests・在途卡住与取消（H06/H19）：迟到回调不改变任何东西 | 通过 |
| H07 | 最小化/关闭 | WorkbenchSwitchTests・先解除再写几何、途中句柄丢失零写入、H07b 预算内复核 | 通过 |
| H08 | 分隔线拖动 | WorkbenchDividerTests・设备级事实：串行执行，最终尺寸不被旧写入覆盖 | 通过 |
| H09 | 滚动/拖动 | WorkbenchRailViewTests・滚动与视口裁剪、边缘自动滚动 | 通过 |
| H10 | 主区最小尺寸 | WorkbenchSwitchTests・应用约束返回：记事实、继续、不覆盖预览栏 | 通过 |
| H11 | 屏幕变化 | WorkbenchRailViewTests・坐标与屏幕 | 通过 |
| H12 | 捕获需求 | WorkbenchRailViewTests・捕获需求的投影事实 | 通过 |
| H13 | 模态与失焦 | WorkbenchRailViewTests・无障碍（朗读与激活）；WorkbenchSwitchTests・对话框阻塞（挂 Sheet 不许写） | 通过 |
| H14 | 日志失败 | WorkbenchSwitchTests・意图没落盘：写前拒绝、零写入 | 通过 |
| H15 | 全部入口 | WorkbenchEntryTests・先显示总览、不写 AX | 通过 |
| H16 | 初选真实事件 | WorkbenchEntryTests・点击之后才建两栏并交接真实窗口 | 通过 |
| H17 | 返回真实面板 | WorkbenchRailViewTests・「全部窗口」按钮 | 通过 |
| H18 | 全屏过渡资源 | TransitionSceneTests・整屏过渡只有一层承载窗口 | 通过 |
| H19 | 慢 AX/首帧 | WorkbenchSwitchTests・超时：到点先报，再按逆序补偿一次 | 通过 |
| H20 | 快速点击退出 | WorkbenchSwitchTests・连点：只有最新意图提交，队列有界 | 通过 |
| H21 | 帧率与预览解耦 | TransitionSceneTests・位移动画由时间轴驱动 | 通过 |
| H22 | 焦点交接 | WorkbenchSwitchTests・先到位、再确认前台、最后才提交 | 通过 |
| H23 | （加项）目录快照滞后 | WorkbenchSwitchTests・写前实读纠回原位置，返回真的写回 | 通过 |

两条口径说明：**「通过」只代表宿主侧用注入替身能验到的那部分**（方案 §18.2 每行"必须断言"的范围），真实系统权限、真实窗口与视觉结果仍靠 §19 实机路径与 P0 探针，两者不可互替；**无任何 W/H 项被 skip**，唯一 skip 的 `T01ActionRoutingTests` 那条见本节开头。

## 8. 方案 §19 真机验收路径逐项状态（0.1.10）

这是方案 §22 交付清单里「第 19 节逐项状态」一项。构建：代码面 `a6df44b`（标签 `v0.1.10`，Release run [38947484361](https://github.com/misswell/Vistile/actions/runs/38947484361)，之后仅文档面追平到 `6902bd7`）；系统 macOS 27.0.1、Apple M5 10 核 / 24GB；应用版本 0.1.10+24，本机探针轮次 +16…+23（报告在 [Docs/Evidence](Evidence/README.md)），run12 起换发布字节。**「自动」只写探针判据立得住的部分；人工/录屏项一律未测，未测不等于已修复。**

| §19 | 路径 | 自动判据 | 人工/录屏 | 证据 |
| --- | --- | --- | --- | --- |
| 1 | 总览先行 | **通过**：`P0-15`（+16…+21）首开模式=总览、面板 1 块、格子齐、主区空、在途事务 0、点击 0 次；`P0-12` 入口真实点击、主窗口读回偏差 0.5pt | 「未点击前真实 frame 不变 + L 型出现时机」录屏**未测**；方案点名的 6 窗组合（Safari/Finder/Terminal/VS Code/Xcode）没在真实应用里凑齐——0.1.10 八轮里 `P0-3` 跑在 UITestHarness 脚手架上（六轮通过、+22/+23 锁定记未测） | +21/+23 清单 `P0-15`、`P0-12` 行 |
| 2 | 固定交换 | **通过**：`P0-16` 三轮 100/100（+20/+22/+23，顶栏 50 + 侧栏 50），判据含「其余占用与滚动偏移不变」 | 「连续快速交换无回跳、栏内滚动不乱」录屏**未测** | +20/+22/+23 清单 `P0-16` 行 |
| 3 | 进度监看 | **通过**：`P0-2` 多轮通过；+23 轮被遮挡 12/12 在 1.6s 内收到新帧、全目录帧增量 112（≈70.8 帧/秒） | 「卡片画面确实跟着终端计数变」肉眼确认**未测**——判据本身也说明 mailbox 增长不等于可见更新 | +23 清单 `P0-2` 行、Compatibility §2 |
| 4 | 原生输入 | **部分**：`P0-4` 自动通过（0.1.5、0.1.10+16：落定后没有 Vistile 面板持有键盘、归属=targetApplication），但中文候选/右键/菜单栏/Sheet/拖放/预览不透点全部只列了人工步骤 | **未测**（需要录屏） | Acceptance §1、+23 清单 `P0-4`/`P0-11` 行 |
| 5 | 宽高比 | 无探针项；结构性做法是按源宽高比反推输出高度（[Performance.md](Performance.md) §2），`P0-12/13` 的 ≤0.5pt 只证明几何、不证明预览完整呈图 | **未测** | — |
| 6 | 窗口过多 | 未测。既有读数只有 17 窗口触顶降档（捕获预算），24/40 窗口行为没有测过（Performance §4 第 3 项） | **未测** | — |
| 7 | 跨屏 | **自动承载通过**：`P0-7`（0.1.8）2 块屏、有窗口的屏幕都有布局、缺布局 0。+23 轮只检测到 1 块屏，该轮 `P0-7` 记未测 | 「从副屏选 B、切走后恢复原屏、原屏断开仍可用」**未测** | Compatibility §2、+23 清单 `P0-7` 行 |
| 8 | 系统中断 | **部分**：外部激活/⌘Tab 方向由 `P0-11` 自动通过（四轮四个不同对象）；锁屏由 0.1.8 四轮证明探针能跑完退出（锁定态只作环境记录、不替产品下结论）；退出恢复「未结束事务 0 条」多轮通过 | 「Space、睡眠、权限变化后可正常退出恢复并重新打开」**未测** | Compatibility §2、Acceptance §1「锁定态会伪造结论」一节 |
| 9 | 异常交换 | **宿主替身通过**：H04/H05/H06/H07/H14/H19/H20/H22、W10/W16/W25/W29 覆盖写入被拒补偿、原主写回失败留痕、日志失败零写入、慢 AX 超时逆序补偿、迟到回调不作数 | 实机异常（应用无响应、目标关闭、AX 拒绝、磁盘写失败、强退后再启动）**未测**（`P0-8` 相应人工行未测） | Acceptance §7 H 表、+23 清单 `P0-8` 行 |
| 10 | 模式切换 | **进行中**：`P0-14` 返回总览通过；`P0-17` 往返 +20 走完过 100/100（因一条后证为探针误报的漂移读数判红），+23 按收紧后的基线走 61/100、停在第 62 轮写后读回读不到——+24 的读回有界重试就是为这条修的，**run12 复跑定性**；「退出后再开仍从总览」人工行未测（纯逻辑侧由 `testW13EveryOpenStartsAtOverviewAndNeverAutoEnters` 守着） | 「往返 30 次录屏」**未测** | +20/+23 清单 `P0-14`/`P0-17` 行、Acceptance §7 W13 |
| 11 | 长时运行 | 未测（30 分钟长跑 run13 是为它排的；Performance §4 第 8 项同口径） | **未测** | — |
| 12 | 左右/尺寸设置 | **宿主替身通过**：W23（分隔线命中带、预览不落盘、提交一次旧读回不能覆盖）、W01 栏几何、H08/H10（设备级串行、应用约束记事实继续） | 「侧栏左右切换、紧凑模式后点击区域与画面一致、不截断主应用工具栏」**未测** | Acceptance §7 W/H 表 |
| 13 | 快速操作与流畅 | **样本不足未判**：`P0-18` 帧样本 +21 是 n=13/18/12、+23 是 n=36/61/53，均 < 每路径 100；已记超目标读数（帧间隔 p95 32.6–50.7ms 对 20ms 预算；+23 粗读数 44 段在内/106 段超预算；点击→落定 +23 = 735/554/256ms，总览→L 超 600ms、内交换超 500ms） | 「QuickTime 录屏对照」**未测**；run13 凑样本 | Performance §3.7、+23 清单 `P0-18` 行 |
| 14 | 低功耗与重负载 | 未测（低电量/发热、40 窗口、慢应用各一轮都没跑；动效分级降级有 W22 纯逻辑与实现，实机低电量表现未验） | **未测** | — |

重点应用覆盖（方案 §19 末段）：同应用多文档窗口已有 Code（0.1.4/0.1.5/0.1.6 三轮通过）与访达（0.1.6 通过）、Chrome（至 0.1.10 未定性）；**Electron 应用（Slack/微信/钉钉）、Java/IDEA、固定尺寸原生应用一律未测**——按方案要求，"应用类型相似"不批量填通过。

## 9. 方案 §18 A01–A42 逐项状态（本轮 0.1.11 起、0.1.12 收尾）

本轮最终回归（下面两行是 2026-10-17 15:46–15:48 那一轮，`v0.1.11` 提交前的最后一轮；发布之后又跑了两轮——18:42–18:43 的确定性复跑与 19:18–19:19 清空构建目录后的重跑，逐条命令与退出码记在 §11.3；同一天 15:06 那轮的 63/178 是加「首帧呈现事实」三条用例之前）：

- 核心包 `swift test`：swift-testing **148 项 / 15 个 suite** ＋ XCTest **64 项**，0 失败，`CORE_EXIT=0`（日志 `/tmp/core_test.log`）。
- 宿主 `VistileHostTests`：**180 项执行、1 项跳过、0 失败**，`HOST_EXIT=0`（日志 `/tmp/host_test.log`，15:48:11 那轮）。
- **上面两行是 0.1.11 发布字节那一轮的读数，不与发布后的数字合并。** §20.2 样本分组改动落在发布之后，现已随 `v0.1.12` 发版（见 §11.10）：
  核心包 **155 项 / 16 个 suite** ＋ XCTest **64 项**、`CORE_EXIT=0`（日志 `/tmp/core_group2.log`，17:17:17）；
  宿主 **182 项执行、1 项跳过、0 失败**、`HOST_EXIT=0`（日志 `/tmp/host_group2.log`，17:18:17，`** TEST SUCCEEDED **`）。
  涨出来的 9 项是 `PerformanceGroupTests` 的 7 条纯逻辑用例（[Packages/VistileCore/Tests/VistileCoreTests/PerformanceGroupTests.swift](../Packages/VistileCore/Tests/VistileCoreTests/PerformanceGroupTests.swift)）
  与宿主 `TransitionSceneTests` 的 2 条走真实 `Metrics` 的分组合池检查（[Tests/HostTests/TransitionSceneTests.swift:1337](../Tests/HostTests/TransitionSceneTests.swift#L1337)）。
  真机数字仍然一个都没有——这 9 条测的是**测量本身**，不是产品性能。
- 新增的三条就是这轮涨出来的：`TransitionSceneTests.testCarrierReportsFirstFrameAnchoredAtInputAndSeparatesPresentsFromTicks`、
  `testFlightFactsWithoutInputAnchorAreMarkedNotAnchored`（方案 §20.2 首帧锚点与"回调≠呈现"）、
  `WorkbenchTests.testTransitionFlightFactsSeparatePresentsFromTicks`（缺口算式 `ticks − presentedFrames`）。
- 跳过的仍是同一条 `T01ActionRoutingTests.testKeyboardFocusReallyLandsOnContentView`（宿主取不到前台激活，按方案 §22 不计为成功）。
- **本轮核对时改正了 14 处行号漂移**：`WorkbenchTests.swift` 里 A15/A19/A20/A21/A26/A27/A28/A29/A30/A31/A32/A33/A36/A42 那 14 行的锚点比实际早了 18–20 行
  （本轮在同文件前部追加了首帧事实用例，行号整体后移）。测试本身一直都在、名字也没变，是文档的锚点旧了。
  那 14 行当时只改了 `#L` 链接、链接**文字**里的行号还是旧的（点开跳到新行，读起来却指向上一个用例）；本轮把 16 处 label 与 `#L` 对齐（14 处遗留＋本轮新漂移 2 处），核对脚本改为同时比对两者。
  可复跑的核对（19:04 全仓 188 条行锚链接、46 条带符号名的全部命中，0 处失配；§20.2 分组改动后 `P0Probe.swift` 行号又后移过一次，§11.11 去时钟依赖那轮改了三个文件的前部行数，
  由此漂移的 6 处锚点（`ModeTransitionCoordinator.swift:432→435`、`TransitionSceneTests.swift:1335→1337`/`1374→1376`、`T05T07GeometryTransactionTests.swift:399→422`/`460→483`/`523→546`）已按新行号核对。
  **`v0.1.12` 字节回填之后再原样重跑一次（20:04:51）：`links=188 named=46 problems=0`，计数与上一轮一字不差**）：

  ```bash
  cd "$(git rev-parse --show-toplevel)"
  python3 - <<'PY'
  import re, os, glob
  bad=[]; tot=0; named=0; cache={}
  for f in glob.glob('Docs/**/*.md', recursive=True)+['README.md']:
      d=os.path.dirname(f) or '.'
      for i,L in enumerate(open(f).read().splitlines(),1):
          for m in re.finditer(r'\[([^\]]*)\]\((\.\./[^)#]+)#L(\d+)\)', L):
              label, ln = m.group(1), int(m.group(3))
              real=os.path.normpath(os.path.join(d,m.group(2))); tot+=1
              if not os.path.isfile(real): bad.append((f,i,real,'missing')); continue
              ls=cache.setdefault(real, open(real).read().splitlines())
              if ln>len(ls): bad.append((f,i,real,f'L{ln}>{len(ls)}')); continue
              nums=re.findall(r':(\d+)', label)
              if nums and int(nums[-1])!=ln: bad.append((f,i,real,f'label :{nums[-1]} != #L{ln}'))
              nm=re.match(r'\s*`([A-Za-z_][A-Za-z0-9_]{6,})`', L[m.end():])
              if nm:
                  named+=1
                  if nm.group(1) not in '\n'.join(ls[max(0,ln-6):ln+5]): bad.append((f,i,real,nm.group(1)))
  print(f'links={tot} named={named} problems={len(bad)}')
  [print('  ',b) for b in bad[:20]]
  PY
  ```

写法约定（方案 §18 原文要求）：测试名可调整；用可控 gate、fake clock 与可核对动作序列，不加真实 sleep 赌时序；每条断言外部结果或稳定不变量，不只镜像内部实现。下表「覆盖测试」给的是断言真正落点，多对一的行把共用例都列出。

「A01–A42 每条都有用例」这一句怎么自己复核（16:22 与 20:04:51 各跑一次，42 条全部命中，无 `MISS`）：

```bash
cd "$(git rev-parse --show-toplevel)"
for i in $(seq -w 1 42); do
  grep -rqIo "\bA$i\b" Packages/VistileCore/Tests Tests || echo "MISS A$i"
done
```

命中的是测试源码里对该编号的引用注释；每条引用旁边就是它自己的断言，所以这条只能证明"编号没漏"，
不能证明"断言充分"——充分性要看下表第三列给的具体测试名与行号。

| 编号 | 注入/操作 → 必须断言 | 覆盖测试 | 结果 |
| --- | --- | --- | --- |
| A01 | 目录复核期间取消 → 放行后零普通 AX 写入、恢复可完成 | [WorkbenchSwitchTests.swift:1191](../Tests/HostTests/WorkbenchSwitchTests.swift#L1191) `testCancelDuringCatalogRecheckWritesNothingAndSessionRecovers` | 通过 |
| A02 | 能力读取期间取消 → 同上，不绕过令牌 | [WorkbenchSwitchTests.swift:1238](../Tests/HostTests/WorkbenchSwitchTests.swift#L1238) `testCancelDuringWriteabilityReadNeverWritesWithRevokedPermit` | 通过 |
| A03 | 写前 frame 读取期间取消 → 不提交迟到 apply | [WorkbenchSwitchTests.swift:1269](../Tests/HostTests/WorkbenchSwitchTests.swift#L1269) `testCancelDuringPreWriteFrameReadNeverCommitsLateApply` | 通过 |
| A04 | AX 队列已有未执行命令时取消 → 底层准入拒绝旧命令 | [WorkbenchSwitchTests.swift:1139](../Tests/HostTests/WorkbenchSwitchTests.swift#L1139) `testCancelDuringGatedWriteStopsTheSwitchAndLateCallbacksChangeNothing` | 通过 |
| A05 | 写入执行中隐藏 → 恢复排在在途写入之后，最终 original | [T05T07GeometryTransactionTests.swift:422](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L422) `testQuitQueuesBehindInFlightExpandAndKeepsUnfinishedIntent` | 通过 |
| A06 | 旧队列积压后开启新会话 → 旧命令不复活、不改新状态 | [WorkbenchDividerTests.swift:321](../Tests/HostTests/WorkbenchDividerTests.swift#L321) `testSessionAdoptionWhileBacklogIsQueuedDiscardsOldCommands` | 通过 |
| A07 | 连续分隔线调整再隐藏 → 至多一项最新 pending，隐藏后无迟到微调 | [WorkbenchDividerTests.swift:264](../Tests/HostTests/WorkbenchDividerTests.swift#L264) `testRapidSettlesKeepOnlyTheNewestPendingAndHideLeavesNoLateNudge`＋:223 `testSettleSerializesWritesAndFinalFrameWins` | 通过 |
| A08 | B 进主区后激活失败 → B 回 beforeB、A 保持主区 | [WorkbenchSwitchTests.swift:466](../Tests/HostTests/WorkbenchSwitchTests.swift#L466) `testActivationFailureAfterMovingToMainRestoresTargetAndKeepsPreviousMain` | 通过 |
| A09 | A 已离主区后 B 前景复核失败 → A 回 beforeA 主区、B 回 beforeB、激活 A | [WorkbenchSwitchTests.swift:497](../Tests/HostTests/WorkbenchSwitchTests.swift#L497) `testForegroundRecheckFailureAfterPreviousMainLeftsRollsBothBackAndReactivatesMain` | 通过 |
| A10 | A 部分写入后失败 → 部分写入被识别并补偿 | [WorkbenchSwitchTests.swift:1301](../Tests/HostTests/WorkbenchSwitchTests.swift#L1301) `testStalledWriteTimesOutAndRollsBackExactlyOnce`（`gatesPositionWrite` 制造"尺寸已写、位置未写"） | 通过 |
| A11 | A/B 补偿任一失败 → journal 保留、进 recoveryRequired、不假 focused | [WorkbenchSwitchTests.swift:526](../Tests/HostTests/WorkbenchSwitchTests.swift#L526) `testCompensationFailureKeepsJournalAndNeverCommits` | 通过 |
| A12 | 回滚成功留在工作台 → A 会话事务仍待最终恢复，不能被 drop | [WorkbenchSwitchTests.swift:430](../Tests/HostTests/WorkbenchSwitchTests.swift#L430) `testPreviousMainRestoreFailureIsReportedAndKeepsJournal`；同一条不变量另在 :749/:836/:888/:1104 四个用例里各自断言 | 通过 |
| A13 | 首次 journal prepare 失败再重试 → 无 AX、busy 清理、第二次能进入 | [WorkbenchSwitchTests.swift:590](../Tests/HostTests/WorkbenchSwitchTests.swift#L590) `testJournalPrepareFailureBlocksWritesAndRetryProceeds`＋[WorkbenchTests.swift:1818](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L1818) | 通过 |
| A14 | A/B 批量第二条失败 → 原子失败、无 AX、无半套交换 | [WorkbenchSwitchTests.swift:630](../Tests/HostTests/WorkbenchSwitchTests.swift#L630) `testBatchPrepareIsAtomicWhenSecondMutationFails`＋[WorkbenchTests.swift:1845](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L1845) | 通过 |
| A15 | 返回日志失败 → 原主与轨道不变、无飞行/恢复 | [WorkbenchTests.swift:1893](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L1893) `testReturnPrepareFailureKeepsMainRailAndStartsNoFlight` | 通过 |
| A16 | 原位置纠正落盘失败 → 后续零几何写入 | [WorkbenchSwitchTests.swift:656](../Tests/HostTests/WorkbenchSwitchTests.swift#L656) `testOriginalCorrectionFailureRefusesEveryGeometryWrite` | 通过 |
| A17 | observed 落盘失败 → 停后续步骤，真实写入有补偿义务 | [WorkbenchSwitchTests.swift:680](../Tests/HostTests/WorkbenchSwitchTests.swift#L680) `testObservedFactPersistFailureRollsBackAndStopsBeforeCommit`＋[WorkbenchTests.swift:1907](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L1907) | 通过 |
| A18 | 异步 prepare 完成时会话已取消 → 不启动旧操作 | [WorkbenchSwitchTests.swift:713](../Tests/HostTests/WorkbenchSwitchTests.swift#L713) `testStaleOperationContextStartsNoWrite`＋[WorkbenchTests.swift:1949](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L1949) | 通过 |
| A19 | 跨屏移动后原屏仍在 → 恢复 originalDisplay 而非当前屏 | [WorkbenchTests.swift:1991](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L1991) `testCrossDisplayMoveRestoresOriginalDisplayNotCurrentOne` | 通过 |
| A20 | 原屏拔除/分辨率变化 → 合法回退目标、原因、结算一致 | [WorkbenchTests.swift:2016](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2016) `testOriginalDisplayResizeAndUnplugGiveLegalDowngradeWithMatchingSettlement` | 通过 |
| A21 | 用户 override 跨屏 → 选 override 对应屏，不夹错屏 | [WorkbenchTests.swift:2060](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2060) `testUserOverridePicksTheDisplayThatActuallyContainsIt` | 通过 |
| A22 | constrained 但完全位于主区 → 可提交，保留实际读回 | [WorkbenchSwitchTests.swift:891](../Tests/HostTests/WorkbenchSwitchTests.swift#L891) `testConstrainedReadBackInsideMainIsRecordedAndSubmitted` | 通过 |
| A23 | constrained 覆盖栏 → 有界纠正或补偿，不提交 | [WorkbenchSwitchTests.swift:923](../Tests/HostTests/WorkbenchSwitchTests.swift#L923) `testConstrainedReadBackOutsideMainIsCorrectedOnceAndThenCompensated` | 通过 |
| A24 | 固定尺寸可移动、能容纳 → 只写 position，不写 size | [WorkbenchSwitchTests.swift:355](../Tests/HostTests/WorkbenchSwitchTests.swift#L355) `testFixedSizedWindowToFitIsMovedWithoutAnySizeWrite` | 通过 |
| A25 | 固定尺寸太大/位置不可写 → 明确拒绝，原主与轨道不变 | [WorkbenchSwitchTests.swift:380](../Tests/HostTests/WorkbenchSwitchTests.swift#L380) `testConfirmedUnsizableWindowIsRefusedWithoutWrites` | 通过 |
| A26 | 关闭 A、B 无历史事务 → prepare→写入→激活→提交顺序完整 | [WorkbenchTests.swift:2097](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2097) `testAutoPromotionAfterClosingMainRunsPrepareWriteActivateCommitInOrder` | 通过 |
| A27 | 替补 journal/AX/激活分别失败 → B 留 slot、主区空、可手动选 C | [WorkbenchTests.swift:2128](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2128) `testFailedPromotionLeavesCandidateInSlotAndKeepsMainSelectable` | 通过 |
| A28 | 自动替补同时用户选择 C → 最新手动意图生效，无无限排队 | [WorkbenchTests.swift:2411](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2411) `testManualSelectionDuringPromotionArmingWins` | 通过 |
| A29 | 总览网格已满后新增 B → 无 gridCell 仍入 L 尾部，其他位置不动 | [WorkbenchTests.swift:2456](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2456) `testWindowBeyondGridCapacityStillEntersRailTail` | 通过 |
| A30 | 标题更新/目录顺序改变 → 已有 occupant 不动 | [WorkbenchTests.swift:2490](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2490) `testTitleUpdateAndCatalogReorderNeverMoveOccupants` | 通过 |
| A31 | 返回总览后再选原 A → 两栏非零偏移保留 | [WorkbenchTests.swift:2514](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2514) `testScrollOffsetsSurviveReturnAndReentry` | 通过 |
| A32 | 返回后选轨道 B → A/B 正确交换、偏移保留 | [WorkbenchTests.swift:2543](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2543) `testRailSelectionAfterReturnSwapsAndKeepsOffsets` | 通过 |
| A33 | 关闭内容或改变栏尺寸 → 只按合法范围 clamp | [WorkbenchTests.swift:2563](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2563) `testRailSizeAndContentShrinkClampToLegalRange` | 通过 |
| A34 | 可见/离屏混合超过预算 → 可见优先，离屏不阻止可见恢复直播 | [CaptureRunTests.swift:352](../Packages/VistileCore/Tests/VistileCoreTests/CaptureRunTests.swift#L352) `offscreenTargetsNeitherTakeSlotsNorBlockRestore` | 通过 |
| A35 | 连续滚动 → 启停次数受控、最后可见集合调度正确 | [T08T09CaptureLifecycleTests.swift:284](../Tests/HostTests/T08T09CaptureLifecycleTests.swift#L284) `testScrollingSettlesOnTheLastVisibleSetWithoutRestartingCards`＋:257 `testRapidSizeDeltasCoalesceIntoLatestIntent`（滚动用例先钉住分母：滑过的每张卡片都起过一条流） | 通过 |
| A36 | 工作台过渡中尺寸更新 → 延后重配，取消/停止仍立即有效 | [WorkbenchTests.swift:2595](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2595) `testSizeUpdateDuringTransitionDefersReconfigurationAndCancelIsImmediate` | 通过 |
| A37 | 旧捕获 run 回调迟到 → 不污染新 mailbox、资源计数不增 | [T08T09CaptureLifecycleTests.swift:175](../Tests/HostTests/T08T09CaptureLifecycleTests.swift#L175) `testLateCallbacksAfterStopAllCannotTouchTheNewRun` | 通过 |
| A38 | 无响应 AX 到退出期限 → 等待有界、日志保留、无新恢复写入 | [T05T07GeometryTransactionTests.swift:483](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L483) `testDeadlineDuringUnresponsiveRestoreKeepsJournalAndStartsNoFurtherWrite`（fake clock，`HostClock` 推进到期限）＋:523 `testTerminationWaitResolvesOnceWithWhicheverArrivesFirst` | 通过；**应用级 2s 真实上限属实机项（§19 M14），本轮未测** |
| A39 | 两种退出入口重复触发 → 仅一恢复所有者、一次终止回调 | [WorkbenchEntryTests.swift:305](../Tests/HostTests/WorkbenchEntryTests.swift#L305) `testTwoQuitEntriesLeaveOneRecoveryOwnerAndOneTerminationCallback`（真 `AppCoordinator`：两个链入口＋状态机 `.restoreAll` 抢同一窗口，断言原 frame 只写一次、窗口回原位、日志清空、收尾一次）＋[T05T07GeometryTransactionTests.swift:546](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L546)＋[TransitionSceneTests.swift:692](../Tests/HostTests/TransitionSceneTests.swift#L692)（retreat 走取消那一路，终止回调正好一个） | 通过 |
| A40 | 动画中连点/退出 → 从当前呈现值接续，旧完成不提交 | [TransitionSceneTests.swift:459](../Tests/HostTests/TransitionSceneTests.swift#L459) `testInterruptContinuesFromPresentedRect` | 通过 |
| A41 | reduceMotion → 同样几何与焦点结果，缩短/减少位移 | [TransitionSceneTests.swift:405](../Tests/HostTests/TransitionSceneTests.swift#L405) `testReduceMotionStaysFadeOnly`＋:1148 `testReduceMotionPresentsTheSameEndpointsWithoutAnyFlight`（承载层实测：中点已完整落位，终点/参与集合/焦点与完整动效逐项相同） | 通过；肉眼降级观感仍需录屏（§19 M13） |
| A42 | 成功交换与往返组合循环 → placement 唯一、无漏窗、无 busy 悬挂、无未解释恢复义务 | [WorkbenchTests.swift:2643](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift#L2643) `testRandomOperationSequencePreservesInvariants`（固定种子，失败打印种子与动作序列） | 通过；实机长跑由 §19 M03/M12 承担，本轮未测 |

42 条都有自动用例且全部通过；A38/A41/A42 的实机那一半按方案要求单列未测，不合并成"全通过"。

## 10. 本轮方案 §17 逐文件落实状态

这里说的方案是本轮执行的 `Vistile_Repair_Plan_66e8d26_2026-10-17.md`（R01–R10 那份），与本文 §7/§8 引用的工作台方案不是同一份文档；两份都用 §17/§18/§19 编号，读的时候按"本轮方案/工作台方案"区分。

「落点」给的是改完之后能一眼看出该条真的被执行的地方（类/函数/字段），不是文件名。**「基线已满足」这两行要说清证据**：方案 §17 把它们列为待改，核对下来基线 `66e8d26` 已经具备要求的行为，本轮没有为了"逐文件都动过"而改代码。

| §17 文件 | 要求 | 落点 / 状态 |
| --- | --- | --- |
| `App/AppCoordinator.swift` | 异步 journal prepare、统一 scheduler、隐藏取消屏障、可见性 captureTargets、统一 TransitionActivity、退出生命周期、删除分散写入入口 | 调度器是成员 [`geometry`](../App/AppCoordinator.swift#L24)，构造时建一次（[AppCoordinator.swift:156](../App/AppCoordinator.swift#L156)）；退出时 `.restoreAll` 效果被链接住的那道门在 [AppCoordinator.swift:694](../App/AppCoordinator.swift#L694) `canStartRestoreOutsideTermination()`；捕获需求按屏可见集合投影后交给 `capture.sync(targets:tier:activity:)`。分散写入入口已收口：宿主测试现在能通过 `catalog/capture/writer/journal/processIdentity` 五个注入口装配整个协调器（[WorkbenchEntryTests.swift:266](../Tests/HostTests/WorkbenchEntryTests.swift#L266) 的 A39 用例就是走这条装配） |
| `Presentation/WorkbenchSwitchCoordinator.swift` | 去无代次 tail、operation context、写前准入、操作 before 快照、真实补偿结果、统一调度 | 唯一写入路径是 `scheduler.perform(GeometryOperationScheduler.Operation…)`（[WorkbenchSwitchCoordinator.swift:129](../Presentation/WorkbenchSwitchCoordinator.swift#L129)），文件头写明"所有真实写入只有一条路"（[:8](../Presentation/WorkbenchSwitchCoordinator.swift#L8)）；进主区方式由 `MainPlacementPolicy` 决定（[:11](../Presentation/WorkbenchSwitchCoordinator.swift#L11)）；补偿结果以 `WorkbenchCompensationResult` 全量回报（见下面 Events 行） |
| `Presentation/FocusCoordinator.swift` | 旧路径写入与 restoreAll 接入同一 scheduler，保留视图代理职责，不再另立几何所有权 | scheduler 是注入的同一个实例（[FocusCoordinator.swift:34](../Presentation/FocusCoordinator.swift#L34)），展开/收回写入也走 `scheduler.perform`（[:105](../Presentation/FocusCoordinator.swift#L105)）；代理动画活动并入 `TransitionActivity`（[:74](../Presentation/FocusCoordinator.swift#L74)），捕获层不再读零散的 `isAnimating` |
| `Presentation/ModeTransitionCoordinator.swift` | 暴露真实过渡状态与取消完成、当前呈现值重定向、旧场景完成不提交新状态 | 过渡活动事实 [`activity`](../Presentation/ModeTransitionCoordinator.swift#L562)；"从当前呈现值接续"由 [TransitionSceneTests.swift:459](../Tests/HostTests/TransitionSceneTests.swift#L459) `testInterruptContinuesFromPresentedRect` 钉住（A40） |
| `Discovery/AXWindowResolver.swift` | AX 执行时许可校验、实际写入事实、position-only 路径、能力读取与当前 frame 异步 | `apply(frame:element:permit:)` / `applyPosition(_:element:permit:)` 都要求带 permit（[AXWindowResolver.swift:39](../Discovery/AXWindowResolver.swift#L39)）；写前直接问窗口"位置/尺寸能不能写"（[:41](../Discovery/AXWindowResolver.swift#L41)），读不到按"事实不足"而不是"可写"处理（[:47](../Discovery/AXWindowResolver.swift#L47)）；一次写入的完整事实（写前 frame、两个属性各自的错误码、写后读回、结论）见同文件顶部的 `GeometryWriteReport` |
| `Recovery/WindowJournalStore.swift` | async 批量 prepare、原子副本提交、revision、original 修正失败返回、不可变读快照、检查所有结算持久化 | revision 单调递增（[WindowJournalStore.swift:60](../Recovery/WindowJournalStore.swift#L60)），过期序号的写入被拒并给出原因（[:297](../Recovery/WindowJournalStore.swift#L297)）；A13/A14/A15/A16/A17 五条回归就是打这条缝的（§9） |
| `Recovery/RecoveryCoordinator.swift` | 单次规划 RestoreDestination、不按当前屏二次夹、支持截止时间与 scheduler、最终结算按事实 | 目标只规划一次（[RecoveryCoordinator.swift:152](../Recovery/RecoveryCoordinator.swift#L152) `planDestination`），逐项恢复接受同一份预算截止点（[:76](../Recovery/RecoveryCoordinator.swift#L76) `deadline:`），写入同样过 scheduler（[:45](../Recovery/RecoveryCoordinator.swift#L45)）；进程实例判定注入见下 §17 未列的一行 |
| 新建 `Core/Domain/GeometryOperationContext.swift` | 会话代次 + 操作身份 + 操作类型 | `OperationKind` 含 `promoteCandidate`（[GeometryOperationContext.swift:19](../Packages/VistileCore/Sources/VistileCore/Domain/GeometryOperationContext.swift#L19)），迟到回执按整体代次判定 |
| 新建 `Core/MainPlacementPolicy.swift` | 可测试的放置与 readBack 包含性判定 | A22/A23/A24/A25 四条的判据都在这里，不在宿主代码里 |
| 新建 `Core/Recovery/RestoreDestination.swift`（§17 未列，§8 需要） | 跨屏恢复目标一次性规划 + 回退原因 | A19/A20/A21 的事实载体 |
| 新建 `Presentation/GeometryOperationScheduler.swift`（§17 只列了同名文件） | 会话准入、按 identity 串行、fence、排空、恢复授权、截止时间 | `isAdmissible` / `drain(until:)` / `remaining(until:)` / `canStartNewWrite(deadline:)`（[GeometryOperationScheduler.swift:397](../Presentation/GeometryOperationScheduler.swift#L397) 起）；时间基是单调 Stamp（[:31](../Presentation/GeometryOperationScheduler.swift#L31)） |
| `Core/Domain/Events.swift` | 操作级 journal 与补偿事件、替补事件、隐藏/排空事件 | `journalPrepared` / `journalPreparationFailed`（[Events.swift:81](../Packages/VistileCore/Sources/VistileCore/Domain/Events.swift#L81)）、写后落盘失败单列（[:87](../Packages/VistileCore/Sources/VistileCore/Domain/Events.swift#L87)）、`mainSwitchFailed(…compensation:)`（[:116](../Packages/VistileCore/Sources/VistileCore/Domain/Events.swift#L116)）、`promotionFinished`（[:118](../Packages/VistileCore/Sources/VistileCore/Domain/Events.swift#L118)）、`prepareJournal`（[:173](../Packages/VistileCore/Sources/VistileCore/Domain/Events.swift#L173)） |
| `Core/Domain/SessionState.swift` | 会话代次与明确恢复状态，phase 与 workbench busy 不互相矛盾 | 会话代次（[SessionState.swift:7](../Packages/VistileCore/Sources/VistileCore/Domain/SessionState.swift#L7)）＋"普通操作与补偿都必须带它"的操作上下文（[:231](../Packages/VistileCore/Sources/VistileCore/Domain/SessionState.swift#L231)） |
| `Core/Domain/SessionReducer.swift` | 隐藏入口统一、日志失败按 token 收口、恢复事实不因 UI 过期丢失、新增窗口入口可达 | A05/A15/A18/A39 的 reducer 侧；`.restoreAll` 效果仍由状态机发出（所有权在宿主链上收口） |
| `Core/Domain/WorkbenchState.swift` | 操作上下文 / 待处理意图 / 保存 RailContext，scroll 唯一事实源 | `activeContext`、`armed` 待处理意图与偏移唯一来源；A31/A32/A33 覆盖偏移那条 |
| `Core/Domain/WorkbenchReducer.swift` | prepare 成功后启动、失败不假 focused、替补成功后提交、stableOrder 去 gridCell 资格过滤、重入保留偏移 | 替补建模为完整操作 `promoteCandidate`（[WorkbenchReducer.swift:1557](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift#L1557)），一次关闭只自动尝试一个候选（[:502](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift#L502)），手动选择在武装期顶掉未写入的自动替补（[:659](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift#L659)）；补偿事实不全时只转 `recoveryRequired`（[:944](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift#L944)） |
| `Core/Domain/WorkbenchSwitchIntent.swift` | 操作 before 信息或引用、完整补偿结果、constrained 不等于主区合格 | 身份与类型（[WorkbenchSwitchIntent.swift:120](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchSwitchIntent.swift#L120)、[:145](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchSwitchIntent.swift#L145) `isPromotion`） |
| `Core/Domain/FocusGeometry.swift` | 固定尺寸保持原尺寸、主区策略与仅移动决策、不可容纳返回明确结果 | [`centeredOriginalRect`](../Packages/VistileCore/Sources/VistileCore/Domain/FocusGeometry.swift#L31) 只在**真实原尺寸**放得下时返回矩形，放不下返回 nil；原来的夹取版本改名为主区路径的兜底并明确"此时不得宣称保留原尺寸"（A24/A25） |
| `Core/Recovery/WindowTransaction.swift` | 操作/写入事实字段、兼容老日志、original 与 before 分离、降级恢复结算 | `operationBeforeFrame` / `operationBeforeDisplayID`（[WindowTransaction.swift:45](../Packages/VistileCore/Sources/VistileCore/Recovery/WindowTransaction.swift#L45)）与会话 `originalFrame` 分开；老日志缺这两个字段时按"未写入过"读入，不影响恢复 |
| `Core/Capture/CaptureModes.swift` | 可见性优先级、可见工作集恢复直播、离屏降频、稳定排序与滞后 | 需求分级 `transition/visible/prefetch/offscreen/paused`（[CaptureModes.swift:26](../Packages/VistileCore/Sources/VistileCore/Capture/CaptureModes.swift#L26) 起）＋升降级滞后线（[:102](../Packages/VistileCore/Sources/VistileCore/Capture/CaptureModes.swift#L102)、[:128](../Packages/VistileCore/Sources/VistileCore/Capture/CaptureModes.swift#L128)：可见/过渡目标回到实时要整体落到滞后线以下，离屏数量不再阻止可见流恢复） |
| `Capture/CaptureCoordinator.swift` | CaptureTarget 可见性、重配合并、统一动画状态、保留 runID 隔离与资源清理 | `sync(targets:tier:activity:)` 收统一 `TransitionActivity`（[CaptureCoordinator.swift:297](../Capture/CaptureCoordinator.swift#L297)），重配合并留到下一周期（[:354](../Capture/CaptureCoordinator.swift#L354)），run 代次隔离（[:465](../Capture/CaptureCoordinator.swift#L465)） |
| `Core/Domain/WorkbenchPresentation.swift` | 使用真实可见性；空主区/处理中/受限状态与命中事实一致 | **基线已满足，本轮未改**。可见性来自几何投影的实测：`isVisible: snapshot.isVisible(slot)`（[WorkbenchPresentation.swift:82](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchPresentation.swift#L82)）；空主区由 `mainIdentity`/`mainRecord` 可空表达（[:91](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchPresentation.swift#L91)）；受限状态直取布局事实 `isMainAreaConstrained`（[:104](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchPresentation.swift#L104)）；替补期间候选仍留在 `placement.occupants`（§10「不提前消失」，A27 断言的就是这份投影）。方案写的"最多附加处理中状态"是允许项、不是必需项，因此没有为它新增字段 |
| `Presentation/WorkbenchWindowController.swift` | 仅把动作转事件；替补空态、失败可重试；不承担几何提交 | **基线已满足，本轮未改**。视图侧只有一个出口 `onAction`（[WorkbenchWindowController.swift:31](../Presentation/WorkbenchWindowController.swift#L31)），卡片点击/拖动/滚动/pin/分隔线/工具区全部转成动作事件（[:242](../Presentation/WorkbenchWindowController.swift#L242)–[:280](../Presentation/WorkbenchWindowController.swift#L280)）；文件里唯一的"apply"是自己两块面板的层级 `applyOrdering`（[:225](../Presentation/WorkbenchWindowController.swift#L225)），不写任何真实窗口的几何 |
| `Tests/HostTests/_HostGeometryFakes.swift` | 可控 gate、部分成功、永不返回、激活失败、队列开始前拦截、动作日志 | 本轮扩了写入门（尺寸/位置分别可拦）、读回门、`FakeProcessIdentity`、动作日志；A01–A05/A10/A38/A39 靠这些门构造时序 |
| `Tests/HostTests/WorkbenchSwitchTests.swift` | 后段失败补偿、取消前后真实 frame、日志失败、主区包含性、修正错误断言 | 见 §9 A01–A04、A08–A12、A16–A18、A22–A25 各行 |
| `Tests/HostTests/WorkbenchEntryTests.swift` | prepare 重试、快速退出、替补事务与焦点的宿主组合 | 见 §9 A39；本文件也是唯一把真 `AppCoordinator` ＋五个替身装配起来的用例 |
| `Core/Tests/WorkbenchTests.swift` | busy 收口、候选关闭、满网格新增、往返偏移、placement 不变量 | 见 §9 A13–A15、A17–A21、A26–A33、A36、A42 |
| `Tests/HostTests/T05T07GeometryTransactionTests.swift` | 跨屏恢复、原位置修正失败、日志结算失败、退出期限 | 见 §9 A05、A38、A39（终止等待只解析一次那条） |
| `Tests/HostTests/T08T09CaptureLifecycleTests.swift` | 可见性升降档、隐藏取消、旧 runID 回调隔离 | 见 §9 A35、A37 |
| `Tests/HostTests/T14OrderingAndNativeInputTests.swift` | 替补/回滚后实际激活调用；真实输入另留人工 | 激活调用次数由替身计数；**中文输入/右键/Sheet 仍属 §19 M11 人工项，未测** |
| `Tests/HostTests/TransitionSceneTests.swift` | 中途重定向、失败回退、reduceMotion、旧完成隔离 | 见 §9 A40、A41、A39 |
| `Docs/Acceptance.md` | 逐项状态，CI/替身/真实应用/视觉证据分开 | §7（工作台方案 W/H）、§8（工作台方案实机项）、§9（本轮 §18 A01–A42）、本节（本轮 §17）、§11（本轮 §19 M01–M14 与 §22 交付清单） |
| `Docs/Performance.md` | 统一测量端点、样本与环境；不沿用不可信 CPU 数字 | 见 Performance §3.8（本轮口径：单调时钟、端点清单、样本量闸门） |
| `Docs/Compatibility.md` | 真实应用按捕获/移动/resize/激活/输入/恢复分别记录 | 矩阵列已补「激活」「输入」两列（原表只有捕获/关联/移动/resize/层级/Sheet/恢复），新列一律未测，等 §19 M07/M11 的实机读数填 |
| `Docs/Architecture.md` | 新调度所有权、取消与补偿时序、状态与日志边界 | 见 Architecture §5.1（可见性分级）与新增的 §7.1（一条调度通道、取消与补偿时序、状态与日志边界） |

方案 §17 的 33 行里，31 行落在本轮改动内；`WorkbenchPresentation.swift` 与 `WorkbenchWindowController.swift` 两行核对后判定基线已满足、未改代码，证据如上。另外新建了 §17 清单没列但方案正文要求的三个文件（`GeometryOperationContext.swift`、`RestoreDestination.swift`、`GeometryOperationScheduler` 的会话代次部分），以及 `AppCoordinator` 的 `processIdentity` 注入口——没有它，宿主里的退出恢复只会读成"进程已不存在"，A39 走不到写回原 frame 那一步（[AppCoordinator.swift:138](../App/AppCoordinator.swift#L138)）。



## 11. 本轮（0.1.11 起、0.1.12 发出，方案 §22）交付报告

方案 §22 的每一项在下面单列。**这一节里"未测"很多，这是如实记录而不是笔误**：方案 §19 要求发布包与探针运行包必须对应、
不能用不同源码轮次拼成一个"全通过"，而本轮的真机项还没在发布字节上跑过——该字节现在是 `v0.1.12`（`dbf2204`，构建 26，已装进 `/Applications/Vistile.app`），§34 待办。
凡引用 0.1.10 及更早轮次的读数，都标明它属于**哪一个源码轮次**，不与本轮互证。

### 11.1 基线、最终 SHA、构建号、实际运行包 hash

| 项 | 值 | 怎么核对 |
| --- | --- | --- |
| 修复前基线 SHA | `66e8d267676c15938271d94ed694f30e02340992`（方案 §23 指定） | `git log -1 66e8d26` |
| 本轮代码 SHA | `889a923a32e5900406b3e223cd8bc3890f5bc819`，标签 `v0.1.11`（标签对象 `3bfdf7201f6be5b86968843b32fc404590b6813a`）；`git ls-remote origin main refs/tags/v0.1.11` 显示 `main` 也在这条提交上 | 本文档的提交在标签之后，**文档比包新**——这条限制每轮都存在，照实写 |
| 构建号 | `0.1.11 / 25`（`Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`）。已从发布包与安装后两份 `Info.plist` 各读一次，两者一致 | `plutil -extract CFBundleShortVersionString raw -o - /Applications/Vistile.app/Contents/Info.plist` |
| 发布包 hash | dmg `Vistile_v0.1.11_macos_arm64.dmg`：`5facbd52fb12963bce4559c25df1e78db1a71a29efb6aad585caaa7d090d0061`，`2328935` 字节。与 GitHub 资产的 `digest` 一字不差；**先用 `gh api …releases/tags/v0.1.11` 对字节数再哈希**，本机 `gh release download` 有把文件截断、导致哈希与 digest 假性不符的前科 | `shasum -a 256` 对照 `gh release view v0.1.11 --json assets` |
| dmg 内包体 hash | `Vistile.app/Contents/MacOS/Vistile` = `0ddf55e60a4de0e628f80254380443e5bd84c64f2a3274e48fff5c94c348e0a6`（`lipo -archs` = `arm64`；`Identifier=com.misswell.Vistile`、`Authority=Developer ID Application: Guofeng Liu (U8U443D7ZL)`、`TeamIdentifier=U8U443D7ZL`、`flags=0x10000(runtime)`；`codesign --verify --deep --strict` 通过；`xcrun stapler validate` 通过；`spctl --assess --type execute` = accepted，source=Notarized Developer ID） | 挂载后对 dmg 内 bundle 逐条跑上面的命令 |
| 实际运行包 hash | `0ddf55e60a4de0e628f80254380443e5bd84c64f2a3274e48fff5c94c348e0a6`——`ditto` 从 dmg 装进 `/Applications/Vistile.app` 后实测，与 dmg 内那份**完全相同**；签名/装订/gatekeeper 在安装位置重跑同样全通过。替换下来的 0.1.10+24 旧包（`9f830aa5aa43499034d149d7197a06418fdf5b8d3901f070a29f2370ae30a40f`）移到了 `/tmp/Vistile_0110_backup`，没有删除。bundle id 与签名团队未变，所以已有的屏幕录制/辅助功能授权继续生效 | `shasum -a 256 /Applications/Vistile.app/Contents/MacOS/Vistile` |
| 真机项是否已在这份字节上跑过 | **没有**。2026-10-17 16:06、16:09、16:17 三次读 `CGSessionCopyCurrentDictionary` 都是 `CGSSessionScreenIsLocked=1`（桌面锁定，`onDisplay=1`），方案 §19 与既有约束都不允许在锁屏上取证，故 §11.4–§11.8 仍全部为未测 | `xcrun swift /tmp/lockcheck.swift`（脚本在 [Evidence/README.md](Evidence/README.md)「run14 起跑前」） |

**发布后的两轮改动（§11.10 分组、§11.11 去时钟依赖）已随 `v0.1.12` 发出，上面的表描述的是 `v0.1.11` 那批字节。**
0.1.11 的表保留原样，因为那一轮的真机项确实没跑；下面这行才是现在该装、该跑的那一份：

| 项 | 值 | 怎么核对 |
| --- | --- | --- |
| 0.1.12 代码 SHA / 标签 | `dbf22046f4de4ab949e465b7fa6cad346b1deaff`，标签 `v0.1.12`（指向同一提交）；`git ls-remote origin refs/tags/v0.1.12 refs/heads/main` 两者相同 | 提交链：`889a923`（0.1.11）→ `dcbd7f4`（§11.10）→ `84071c0`（§11.11）→ `dbf2204`（版本号） |
| 构建号 | `0.1.12 / 26`；dmg 内与 `/Applications/Vistile.app` 内两份 `Info.plist` 各读一次，一致 | `defaults read /Applications/Vistile.app/Contents/Info CFBundleShortVersionString` |
| 发布包 hash | dmg `Vistile_v0.1.12_macos_arm64.dmg`：`d342dbd49d60c123878c9a71103c1d033a583ce690370294264f2245fd29761b`，`2349001` 字节，与 GitHub 资产 `digest` 一字不差。**第一次下载截断成 `515333` 字节**（哈希自然对不上），删掉重下才一致——截断这一步必须先看字节数 | `ls -l` ＋ `shasum -a 256` 对照 `gh release view v0.1.12 --json assets` |
| dmg 内包体 hash | `Vistile.app/Contents/MacOS/Vistile` = `dd07d34a8d9fd4fa1d6a8e27fea3b3deada140945c5cd49ba9ade2e04b55d9e9`；`Identifier=com.misswell.Vistile`、`Authority=Developer ID Application: Guofeng Liu (U8U443D7ZL)`、`TeamIdentifier=U8U443D7ZL`；`codesign --verify --deep --strict` 通过、`xcrun stapler validate` 通过、`spctl -a -t install` = source=Notarized Developer ID | 挂载后逐条跑上面的命令 |
| 实际运行包 hash | `dd07d34a…5d9e9`——`ditto` 装进 `/Applications/Vistile.app` 后实测，与 dmg 内那份**完全相同**；签名/装订/gatekeeper 在安装位置重跑同样全通过。替换下来的 0.1.11 旧包（`0ddf55e6…4e0a6`）移到 `/tmp/Vistile-0.1.11-backup.app`，没有删除。bundle id 与签名团队未变，**屏幕录制/辅助功能授权继续生效，不需要重新授权** | `shasum -a 256 /Applications/Vistile.app/Contents/MacOS/Vistile` |
| 流水线 | CI 与 Release 两条都在 `dbf2204` 上 success：<https://github.com/misswell/Vistile/actions/runs/39028389804>（CI）与 <https://github.com/misswell/Vistile/actions/runs/39028401485>（Release：`verify` ✓ → `probe-credentials` 跳过 → `build-macos` ✓ → `release` ✓，`publishedAt` 19:25:52 +0800）。§11.11 那条修复自身的 CI 是 <https://github.com/misswell/Vistile/actions/runs/39027671256>，**attempt 1 就绿**（同一条流水线在 `31d40ca` 上是首跑红、重跑绿） | `gh run view <id> --json conclusion,attempt,jobs` |
| 真机项是否已在这份字节上跑过 | **还没有**。16:06 / 16:09 / 16:17 / 17:49 / 19:23:39 / 19:44:01 / 19:53:19 七次读数全是 `CGSSessionScreenIsLocked=1`（`onDisplay=1`，`online=1 active=0`）。包已就位（19:54 重读运行包 hash 仍是 `dd07d34a…5d9e9`、版本仍是 `0.1.12 / 26`），缺的只是能看见桌面的那一刻 | 同上，`swift /tmp/lockcheck.swift` |
| 事后复核（20:32:46–47） | dmg 仍在 `/tmp`（`2349001` 字节 / `d342dbd49d60c123878c9a71…`），重新挂载后包内二进制仍是 `dd07d34a8d9fd4fa1d6a8e27…`，`spctl -a -t install` 仍回 `source=Notarized Developer ID` ＋ `origin=Developer ID Application: Guofeng Liu (U8U443D7ZL)`——上面每一行都能原地重放，不是只跑过一次的历史 | `shasum -a 256 /tmp/Vistile_v0.1.12_macos_arm64.dmg`；挂载见下一列 |
| 挂载命令的口径变化 | `hdiutil attach -nobrowse -readonly -mountpoint` 现在会打 deprecated 警告（仍能工作）。复核这轮改用 `diskutil image attach --mountOptions nobrowse --readOnly --mountPoint /tmp/v0112_rc2 <dmg>` ＋ `diskutil eject` | 两种都跑过：安装前那次用 `hdiutil`（dmg 落盘时间 19:41，见文件 `mtime`），20:32 这次用 `diskutil` |


### 11.2 R01–R10 逐项：根因 / 修改文件 / 关键行为 / 回归用例 / 状态

「状态」一列只写代码与自动回归两件事，**真机那一半统一在 §11.4 的 M 表**，不在这里混成"完成"。

| R | 根因（方案原话的缩写） | 关键落点 | 新增/改正的行为 | 回归用例 | 状态 |
| --- | --- | --- | --- | --- | --- |
| R01 | 取消、隐藏与恢复未统一排空写入 | `Presentation/GeometryOperationScheduler.swift`（新建）＋ [WorkbenchSwitchCoordinator.swift:129](../Presentation/WorkbenchSwitchCoordinator.swift#L129)、[FocusCoordinator.swift:106](../Presentation/FocusCoordinator.swift#L106) | 真实 AX 写入只有一条通道；会话代次准入；隐藏/退出先撤普通准入再排空，之后只允许恢复授权写入；同一窗口按 identity 串行 | A01–A07、A18、A39 | 代码完成；替身回归通过；实机未测 |
| R02 | 交换失败回到 original，却宣称旧主仍在主区 | `Core/Domain/WorkbenchSwitchIntent.swift`、`WorkbenchReducer.swift`、[WorkbenchSwitchCoordinator.swift](../Presentation/WorkbenchSwitchCoordinator.swift) | 操作 before 快照与补偿结果全量回报；逆序补偿；补偿后做真实焦点/前景复核；**交换失败回 before，退出恢复才用会话 original** | A08–A12 | 代码完成；替身回归通过；实机未测 |
| R03 | 日志失败使进入/交换状态卡住 | `Recovery/WindowJournalStore.swift`、`Core/Domain/Events.swift`、[AppCoordinator.swift:625](../App/AppCoordinator.swift#L625) | 异步原子批量 prepare；操作级 journal 事件；写后落盘失败单列并进补偿；老日志缺新字段按"未写入过"读入 | A13–A17 | 代码完成；替身回归通过；**强退实机恢复未测**（§11.8） |
| R04 | 恢复目标被 clamp 到当前屏 | `Core/Recovery/RestoreDestination.swift`（新建）、[RecoveryCoordinator.swift:152](../Recovery/RecoveryCoordinator.swift#L152) | 跨屏恢复目标只规划一次；原始屏优先、备用屏回退并记原因；分辨率变化/拔屏给合法降级 | A19–A21 | 代码完成；替身回归通过；实机跨屏未测 |
| R05 | constrained 直接提交、固定尺寸窗口被整体拒绝 | `Core/MainPlacementPolicy.swift`（新建）、`Core/Domain/FocusGeometry.swift`、[AXWindowResolver.swift:39](../Discovery/AXWindowResolver.swift#L39) | 按真实 readBack 的包含性判定；固定尺寸只写 position 不写 size；不可容纳时明确拒绝且不动原主与轨道 | A22–A25 | 代码完成；替身回归通过；固定尺寸真实应用未测 |
| R06 | 关闭主窗口直接提交替补，未建事务、未激活 | [WorkbenchReducer.swift:1557](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift#L1557) | 替补建模为完整提升事务（journal→写入→激活→提交），一次关闭只试一个候选；武装期手动选择顶掉自动替补 | A26–A28 | 代码完成；替身回归通过；实机替补未测 |
| R07 | 总览网格满时新增窗口不进轨道 | `Core/Domain/WorkbenchState.swift`、`stableOrder`（去 `gridCell` 资格过滤） | 展示成员与总览位置解耦：超出格子仍入 L 尾部，其它位置不动 | A29–A30 | 代码完成；替身回归通过 |
| R08 | 返回后再次进入把滚动归零 | `Core/Domain/WorkbenchState.swift`（保存 `RailContext` 偏移） | 偏移唯一事实源、返回再入保留、按内容长度与栏尺寸 clamp 到合法范围 | A31–A33 | 代码完成；替身回归通过；肉眼滚动未测 |
| R09 | 捕获不看可见性、新动画未参与重配抑制 | `Core/Capture/CaptureModes.swift`、[CaptureCoordinator.swift:297](../Capture/CaptureCoordinator.swift#L297) | 需求分级 `transition/visible/prefetch/offscreen/paused`；可见优先、离屏不占位不阻塞；升降级滞后；重配合并到下一周期；runID 隔离与资源清理 | A34–A37 | 代码完成；替身回归通过；30 分钟流量稳定性未测 |
| R10 | TaskGroup 赛跑不能实现退出硬期限 | [GeometryOperationScheduler.swift:397](../Presentation/GeometryOperationScheduler.swift#L397) 起（`drain(until:)`/`canStartNewWrite(deadline:)`）、[AppCoordinator.swift:694](../App/AppCoordinator.swift#L694) | 单一恢复所有权；有界等待 + 到期留痕；不再仅依赖 `TaskGroup.cancelAll`；期限后不启动新的恢复写入 | A38–A40 | 代码完成；替身回归通过；**应用级 2s 真实上限属实机项，未测** |

方案 §21 的提交边界（阶段 1–6）全部落在本轮，没有只提交计划或第一阶段。

### 11.3 自动测试输出与跳过项

- 命令与结果见 §9 顶部本轮数字（`CORE_EXIT=0`、`HOST_EXIT=0`，148/64/180，1 skip）。
- **发布后两轮改动（§11.10 分组、§11.11 去时钟依赖）之后的最新一轮**（18:42–18:43）：
  核心 `swift test` `CORE_EXIT=0`＝swift-testing 155 项/16 suite ＋ XCTest 64 项（日志 `/tmp/core_det.log`）；
  宿主 `VistileHostTests` `HOST_EXIT=0`＝**182 项执行、1 跳过、0 失败**（日志 `/tmp/host_full_det.log`）；
  §11.11 那两条另按 `-test-iterations 10` 单独连跑：`Executed 20 tests, with 0 failures`（日志 `/tmp/host_repeat10.log`）。
  三项计数与 §9 的发布后读数一致，本轮没有新增用例、也没有删断言。
- **清空构建目录后重跑一次**（`rm -rf build .build Packages/VistileCore/.build`），因为增量编译会掩盖 CI 才撞得上的错误：
  `CLEAN_CORE_EXIT=0`（148 swift-testing ＋ 64 XCTest）、
  `CLEAN_RELEASE_BUILD_EXIT=0` 且 Release 配置下 `error:` 计数为 0（`xcodebuild -scheme Vistile -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=NO`，不签名）、
  `CLEAN_HOST_EXIT=0`（180 项、1 skip、0 失败）。日志：`/tmp/clean_core.log`、`/tmp/clean_release.log`、`/tmp/clean_host.log`。
- **`v0.1.12` 之前再清一次构建目录**（同一套命令，`rm -rf build .build Packages/VistileCore/.build`）：19:18–19:19 那轮
  `CLEAN_CORE_EXIT=0`（155 swift-testing ＋ 64 XCTest）、`CLEAN_RELEASE_BUILD_EXIT=0` 且 `error:` 计数 0、
  `CLEAN_HOST_EXIT=0`（**182 项、1 skip、0 失败**，18.13s）。日志：`/tmp/clean_core.log`、`/tmp/clean_release.log`、`/tmp/clean_host.log`。
  发版提交 `dbf2204` 上 CI 与 Release 两条 run 均 success（§11.1 表内有链接），也就是"花一个版本号"之前本机与 runner 两边都干净。
- **`v0.1.12` 那一轮的 runner 侧数字**（run <https://github.com/misswell/Vistile/actions/runs/39028389804>，两条 job 都 success）：
  **核心** `Test run with 155 tests passed` ＋ `Executed 64 tests, with 0 failures`；**宿主** `Executed 182 tests, with 1 test skipped and 0 failures`
  ＋ `** TEST SUCCEEDED **`。与本机 18:42–18:43、19:18–19:19 两轮计数一字不差。取法：
  `gh run view 39028389804 --log | grep -E "Test run with|Executed [0-9]+ tests|TEST SUCCEEDED"`
- 只动 `Docs/` 的那次回填（`5a8fb74`）也照样过 CI：<https://github.com/misswell/Vistile/actions/runs/39033164047>
  （`gh run list --workflow=ci.yml --limit 1 --json headSha,conclusion` 回 `success`，20:38 确认）。
  文档提交不改任何计数，跑它只为证明"写回证据的这一笔也没把仓库弄红"。
- CI（推送后 `main` = `889a923`，两条都在同一提交上，结论均为 success）：
  测试任务 <https://github.com/misswell/Vistile/actions/runs/39015752380>（`.github/workflows/ci.yml`，不需要签名凭据）。
  runner 侧数字与本机同一份：**核心** `Test run with 148 tests passed` ＋ `Executed 64 tests, with 0 failures`；
  **宿主** `Executed 180 tests, with 1 test skipped and 0 failures` ＋ `** TEST SUCCEEDED **`（日志步 `核心包 swift test` 与 `宿主构建与测试（无签名）`）。
  发布任务 <https://github.com/misswell/Vistile/actions/runs/39015752372>（`verify` 49s ✓ → `probe-credentials` 未执行（凭据齐备时跳过）→
  `build-macos` 2m59s ✓（构建/签名/公证/装订/复核）→ `release` 7s ✓）。`gh run view --json conclusion` 双双 `success`。
- Release 正文来源核对：`gh release view v0.1.11 --json body` 与 `RELEASE_NOTES.md` 逐行 `diff`，**唯一差别是工作流在末尾追加的
  「## 下载」表格**（9 行），正文其余部分一字不差——即发布说明确实来自仓库文件，不是手工拼的。
  **因此 `RELEASE_NOTES.md` 本轮之后不再改**：这一节的回填只动 `Docs/`，改它会让仓库文件与已发布正文不再对应（中途误动过一次空行，已 `git restore` 还原）。
- 同一核对对 `v0.1.12` 再做一次，并且换了更硬的做法——不再逐行 diff，直接证明"正文是文件的前缀"：
  `gh release view v0.1.12 --json body -q .body > /tmp/body12.md`、`git show v0.1.12:RELEASE_NOTES.md > /tmp/notes12.md`，
  比 `body.startswith(notes)` → **True**，`notes_len=23210`、`body_len=23324`，多出来的 111 个字符正是工作流末尾追加的
  「`\n## 下载\n\n| 平台 | 文件 |\n|------|------|\n| Apple Silicon | \`Vistile_v0.1.12_macos_arm64.dmg\` |\n\nIntel 未提供安装包，也未做真机验证。\n\n`」
  （`.github/workflows/release.yml:253-268` 那段 `cat RELEASE_NOTES.md` ＋ 表格）。也就是说 0.1.12 的发布说明与 `dbf2204` 里那份文件**逐字节相同**，没有手工成分。
- 跳过项只有 1 条，原因与处置：`testKeyboardFocusReallyLandsOnContentView` 需要真实前台激活，宿主环境取不到时显式 `XCTSkip`；
  按方案 §22 它不计为成功，对应真机项是 M04/M11（未测）。

### 11.4 §19 真机矩阵 M01–M14 逐项（本轮 0.1.12）

三类证据分列：**真实应用**（只有解锁桌面上跑发布字节才算）、**脚手架**（UITestHarness 的可控异常时序，只证明时序形状）、
**纯逻辑**（W/H 替身）。方案 §19 明令脚手架不能代替真实应用兼容性，也不能按应用类型批量填通过。

方案 §19 还要求"记录实际 macOS/Xcode/设备、显示器布局、刷新率、窗口数、应用版本、SHA、二进制 hash"。
这些字段里除"窗口数"以外都不需要解锁桌面，先在锁屏态下把可取的部分记下来（2026-10-17 16:11–16:12 实测），
run14 直接用同一份环境，只在解锁后补窗口数与真机读数：

| 环境项 | 实测值 | 取法 |
| --- | --- | --- |
| macOS | `27.0.1`（build `26A434`） | `sw_vers` |
| 本机 Xcode / SDK | **这台机器上装了两套**：`/Applications/Xcode.app` = Xcode `26.6`（Build `17F113`，macOS SDK `26.5`，Swift 6.3.3）——`xcode-select -p` 当前指向它；`/Applications/Xcode beta.app` = Xcode `27.0`（Build `27A5209h`，SDK `27.0`，Swift 6.4）。**本轮 15:46–15:48 的回归与清空构建目录后的重跑跑在 26.6 上**（`/tmp/clean_release.log:1` 的调用行就是 `/Applications/Xcode.app/.../xcodebuild`，`:262` 的 `-sdk …MacOSX26.5.sdk`），而历史轮次写的"本机 Xcode 27 构建"指的是那套 beta，两者都对，只是不是同一套工具链。发布字节由 runner 构建，与本机两套都不同 | `xcode-select -p`、`xcodebuild -version`、`DEVELOPER_DIR=/Applications/Xcode beta.app/Contents/Developer xcodebuild -version` |
| 构建 runner | `macos-14` arm64 runner，工具链 Xcode `16.2`（Build `16C5032a`）/ macOS SDK `15.2`（run 39015752372 的 `build-macos` 日志行 08:01:51）——发布字节由 runner 工具链产出，与本机版本不同，这是事实而非偏差 | `gh api …/runs/39015752372/logs` |
| 设备 | `Mac17,2`，`arm64`，Apple M5（10 核 GPU，Metal 4） | `sysctl -n hw.model`、`system_profiler SPDisplaysDataType` |
| 显示器布局 | **只有一块内置屏，单屏无副屏**：`CGGetOnlineDisplayList` 回 `online=1 ids=[1]`、`CGMainDisplayID()=1`、`CGDisplayBounds = (0,0,1800,1169)`（点），面板为 Built-in Liquid Retina XDR、`3024 x 1964 Retina`、`Main Display: Yes`、`Mirror: Off`。锁屏熄屏期间 `CGGetActiveDisplayList` 回 `total=0`、`system_profiler` 回 `Display Asleep: Yes`——**这两条只说明"当前没有活动模式"，不代表屏幕消失**，刷新率要走 online 列表才取到 | `system_profiler SPDisplaysDataType`、online/active 两个列表的 swift 片段（[Evidence/README.md](Evidence/README.md)「run14 起跑前」） |
| 刷新率 | 内置面板在线模式报 **`Hz=120.0`**（`CGDisplayCopyDisplayMode(1).refreshRate`，16:17 实测，与 `asleep=true` 同时成立）。§20.2 的 60Hz/120Hz 分组因此有明确落点：这台机器只有这一档面板，ProMotion 会在静止内容与动画之间升降，**run14 必须在动画进行中重读 `refreshRate`**，不能拿一个静态读数给整轮分组 | 同上 |
| 应用版本 / SHA / 二进制 hash | `0.1.12 / 26`，源码 `dbf2204`，运行包 `dd07d34a8d9fd4fa1d6a8e27fea3b3deada140945c5cd49ba9ade2e04b55d9e9`（见 §11.1，19:54 重读仍是这一份） | §11.1 的核对命令 |
| 桌面锁与窗口数 | `CGSSessionScreenIsLocked=1`（16:06、16:09、16:17、17:49、19:23:39、19:44:01、19:53:19 七次一致）且 `onDisplay=1`——会话在但屏幕锁着。**阻塞的是"锁"本身，不是屏幕消失**：锁屏态下 AX 窗口列表读不到、捕获拿不到真实画面，历史三轮（0.1.6 17:37、0.1.8 18:14/18:17）就是这么废掉的。窗口数在锁屏态下无意义，故整表仍为未测 | `xcrun swift /tmp/lockcheck.swift`（脚本见 [Evidence/README.md](Evidence/README.md)） |

按 §20.2 的口径，"锁屏、授权弹窗、系统睡眠"这一类只能记成**环境中断**，既不能静默删除，也不能反填通过。

| M | 路径 | 真实应用 | 脚手架 | 纯逻辑 | 本轮状态 |
| --- | --- | --- | --- | --- | --- |
| M01 | 总览先行 + 6 窗组合（Safari/访达/终端/VS Code/Xcode） | 未测 | — | — | **未测**：0.1.10 的 `P0-15`/`P0-12` 读数属于 +16…+23 与 run12 那批字节，不能给 0.1.12 用 |
| M02 | 固定交换（顶栏 50 + 侧栏 50） | 未测 | — | W23/W01 通过 | **未测**：`P0-16` 100/100 是 +20/+22/+23 的读数，源码轮次不同 |
| M03 | 进度监看（被遮挡仍实时、终端计数肉眼可见） | 未测 | — | A34/A35 通过 | **未测** |
| M04 | 原生输入（中文候选/右键/菜单栏/Sheet/拖放/预览不透点） | 未测 | — | `T14` 只数了激活调用次数 | **未测**（Compatibility「输入」列整列为空） |
| M05 | 宽高比（预览不裁切不拉伸） | 未测 | — | `严格等比例` 用例通过 | **未测** |
| M06 | 窗口过多（24/40 窗口） | 未测 | — | — | **未测**：历史读数最大 17 窗口触顶降档 |
| M07 | 跨屏（副屏选 B、切走回原屏、原屏断开仍可用） | 未测 | — | A19–A21 通过 | **未测**（Compatibility「激活」列等它） |
| M08 | 系统中断（Space/睡眠/权限变化后能退出恢复并重开） | 未测 | — | — | **未测**：锁定段一律记环境中断，不静默删除也不反填通过 |
| M09 | 异常交换（应用无响应、目标关闭、AX 拒绝、磁盘写失败、强退后重启） | 未测 | H04/H05/H06/H07/H14/H19/H20/H22 通过 | W10/W16/W25/W29 通过 | **未测**：脚手架只证明可控时序，不能代替真实应用 |
| M10 | 模式切换（往返 30 次、退出后再开仍从总览） | 未测 | — | `testW13…` 通过 | **未测** |
| M11 | 长时运行 30 分钟 | 未测 | — | — | **未测**：run14 排 `VISTILE_P0_LONG_MINUTES=30` |
| M12 | 左右/尺寸设置（紧凑模式后点击区域与画面一致、不截断主应用工具栏） | 未测 | — | W23/H15/H16/H18/H21 通过 | **未测** |
| M13 | 快速操作与流畅（§20.1 目标 + 录屏对照） | 未测 | — | W22 帧判据通过 | **未测**：本轮新增的首帧延迟与"回调 vs 呈现"读数还没有真机样本 |
| M14 | 低功耗与重负载（低电量/发热、40 窗口、慢应用、2s 退出上限） | 未测 | — | — | **未测** |

### 11.5 三条交互路径：成功率、P50/P95、超时数、帧间隔与有效样本数

**本轮未测**。测量面已就绪（端点清单与口径见 [Performance.md](Performance.md) §3.8，判定与不足样本的措辞在 `P0-18`，
[App/P0Probe.swift:1526](../App/P0Probe.swift#L1526)）：每条路径的点击→落定**逐组**按 n≥100 判、P95 对 §20.1 目标；
首帧延迟单独一条（锚在真实点击上，无锚点段单列）；帧间隔按场景×分组分段算 P95
（[App/P0Probe.swift:1538](../App/P0Probe.swift#L1538)），段级再看 >33.3ms 占比与连续 3 帧停顿
（[App/P0Probe.swift:1564](../App/P0Probe.swift#L1564) 起的逐组帧预算）；「累计 ≥1,000 个有效间隔」按 `过渡有效帧间隔` 计数逐组累加，
样本门与间隔门都过才判；`过渡零呈现段`、`过渡回调多于呈现` 两个计数非 0 即不能宣布达标。
成功率与超时数已有专门一行：`<路径> 落定核对：成功率X%（落定/派发）、超时N`
（[App/P0Probe.swift:1929](../App/P0Probe.swift#L1929) `clickOutcomeText`，长跑侧 [:1794](../App/P0Probe.swift#L1794)），
未落定的样本照样进派发数，不会被只报成功样本的 P95 洗掉。

### 11.6 录屏

**未测**。要求：至少一段连续不剪辑的清晰录屏，覆盖 总览→选 A→选 B→滚动→返回→再入→关闭主窗口→隐藏，
且录屏里的跳变不能靠剪辑掩盖；录制环境需与 §11.1 的运行包 hash 对应。

### 11.7 每个被写窗口的 original / before / target / readBack / displayID 对照

探针侧已实现：`P0-19` 在工作台在途与退出恢复后两个阶段逐窗口采样并输出对照表
（[App/P0Probe.swift:1413](../App/P0Probe.swift#L1413) `captureLedger(stage:)`、[:1479](../App/P0Probe.swift#L1479) 输出 markdown 表、
[:1516](../App/P0Probe.swift#L1516) `ledgerUnrestoredReport()` 用"曾有写入读回的窗口"名单收尾，收尾时 journal 里还剩什么都不能当依据）。
判据是退出恢复后每个被写窗口的真实 frame 与会话 original 偏离 ≤4pt；全是未写入事务时明确写"不能据此判定恢复正确"。
**真实应用上的输出未测**（等 run14）。

### 11.8 30 分钟资源曲线与隐藏后清理

**未测**。`longRun(minutes:)` 会周期采 RSS、进程 CPU 秒、活跃流数，结束时隐藏并核对活跃流最终为零
（[App/P0Probe.swift:1671](../App/P0Probe.swift#L1671)）。CPU/RSS 数字必须能与 Activity Monitor / Instruments 对表才能引用（Performance §3.8 末条）。

### 11.9 日志 schema 兼容性、强退恢复、新旧安装包行为

- **schema**：`WindowTransaction` 新增 `operationBeforeFrame` / `operationBeforeDisplayID`，老日志缺字段按"未写入过"读入，
  不影响恢复（[WindowTransaction.swift:45](../Packages/VistileCore/Sources/VistileCore/Recovery/WindowTransaction.swift#L45)）。纯逻辑侧由 A13/A14/A16 的持久化断言覆盖；
  **真机上的旧日志文件升级后能否正确恢复未测**。
- **强退恢复**：按方案只对"已经可靠落盘的写入义务"负责——journal 落盘失败时不假装写过（A17 断言停后续步骤但保留补偿义务）。
  实机强杀后重启的恢复路径**未测**。
- **新旧安装包**：同 Developer ID 覆盖安装保留 TCC 授权已被实测多次（0.1.1→0.1.10，见 Compatibility §1）。本轮把**安装动作本身**核对了两次：
  0.1.11 那次——`ditto` 把 dmg 内 bundle 装回 `/Applications/Vistile.app`，安装后包内二进制 `sha256 0ddf55e6…e0a6` 与 dmg 内那份一字不差，
  签名（`Identifier=com.misswell.Vistile`、`U8U443D7ZL`、`flags=0x10000(runtime)`）、`stapler validate`、`spctl --assess` 在安装位置重跑仍全通过，
  bundle id 与签名团队未变，旧 0.1.10+24 移到 `/tmp/Vistile_0110_backup` 未删；
  0.1.12 那次——发布之后（`publishedAt` 19:25:52）下载 dmg、逐条核对再 `ditto` 装回，装进去的是 `dd07d34a…5d9e9`，被替换下来的 0.1.11 移到 `/tmp/Vistile-0.1.11-backup.app` 未删，
  19:54 重读 `/Applications/Vistile.app` 仍是 `0.1.12 / 26` 与这一串 hash。
  **但"这一跳之后权限还在不在"要靠启动一次读 `P0-0` 才能算证据**，
  而锁屏态下启动一次既读不到 AX 窗口列表、也拿不到真实画面（16:06 起七次 `CGSSessionScreenIsLocked=1`，最近一次 19:53:19），不构成 §19 的有效取证环境，
  所以 0.1.10→0.1.11 与 0.1.11→0.1.12 **两跳的授权保留都仍未测**（run14 第一行 `P0-0` 就是它）。

### 11.10 发布后的测量面补齐：§20.2 样本分组（代码完成，真机数字仍是未测）

- **根因**：方案 §20.2 明令「60Hz/120Hz、reduceMotion、冷启动/热路径分别分组」，但 0.1.11 的字节里所有 P95 都是**合池**的——
  `Metrics` 只按指标名聚合，名字里没有环境维度，于是"120Hz 热路径很快"和"60Hz 冷启动很慢"被平均成一个谁都对不上的数字。
  同一轮还发现第二条更硬缺的：「短场景累计至少 1,000 个有效间隔」这条门**没有测量支撑**——报告里只有段数（一次过渡算一段），
  每段里到底有几条有效间隔从未被计数，所以这条门既判不了、也不会被如实记成未判，等于写了个不存在的判据。
- **修改文件**：`Packages/VistileCore/Sources/VistileCore/Domain/PerformanceGroup.swift`（新，纯逻辑：三维分组键、
  `PerformanceGate` 的 n≥100 门与 nearest-rank P95、`PerformanceMetricName` 命名契约）、
  [Diagnostics/Metrics.swift:12](../Diagnostics/Metrics.swift#L12)（`PerformanceEnvironment` 现取刷新率/reduceMotion/冷热）、
  [App/AppCoordinator.swift:1183](../App/AppCoordinator.swift#L1183) 起（飞行开始时定组，四处指标改用带组名）、
  [App/P0Probe.swift:1526](../App/P0Probe.swift#L1526) 起（P0-18 逐组判定与措辞、有效间隔计数、成功率/超时数）、
  两份测试。
- **关键行为**：分组键 = 「档位·reduceMotion=开/关·冷启动/热路径」，档位把 59.94/119.88 归一成 60Hz/120Hz，
  取不到时写「刷新率未知」而不是假装 60Hz；"冷启动"就是该场景在本进程里的第一次飞行；判定逐组给，
  样本不足写**未判**（不写成达标、也不写成超目标）；`点击→落定` 另留一行不带分组键的合池概览，报告里明写"只作概览，判定不看它"；
  `过渡零呈现段`/`过渡回调多于呈现` 两条**故意不按分组拆**——它们是"有没有画面证据"的核对，不是 §20.1 带目标值的数字。
- **回归用例**：核心 7 条（档位归一、本机帧间隔只是事实不当目标、三维各自能把组隔开、样本门、nearest-rank、命名往返、
  分组后热路径达标与冷启动未判不互相掩盖）在
  [Packages/VistileCore/Tests/VistileCoreTests/PerformanceGroupTests.swift:12](../Packages/VistileCore/Tests/VistileCoreTests/PerformanceGroupTests.swift#L12) 起；
  宿主 2 条走**真实 `Metrics`**，钉住"生产侧写的名字读取侧取得回"这条契约
  （[Tests/HostTests/TransitionSceneTests.swift:1337](../Tests/HostTests/TransitionSceneTests.swift#L1337)、
  [:1376](../Tests/HostTests/TransitionSceneTests.swift#L1376)）。契约断掉的表现是读取侧一行都匹配不到、报告只写"没有帧样本"，
  那是测量坏了不是产品慢，所以先让测试红。
- **状态**：代码完成、确定性回归通过（核心 155/64、宿主 182，见 §9），**并已随 `v0.1.12` 发进正式字节**（`dbf2204`，运行包 hash 见 §11.1）。
  发版前这条改动只在工作树里、`v0.1.11` 的字节还在写不带分组键的合池名字，所以那批数字不能拿来交分组这一项；现在字节对了，
  **但仍未在真机跑过**：解锁后 run14 之前的 §20.1 全部数字（含分组后的）仍是**未测**，
  120Hz 组能按本机帧间隔给更严预算这一点也只是把口径写清楚，没有任何本机样本。

### 11.11 两条宿主用例去掉真实时钟赌时序（代码完成，已复跑）

- **现象**：`31d40ca` 的 CI 首跑（run 39023517056 attempt 1）在「宿主测试」这一步红，「核心包 swift test」绿；
  同一 commit 重跑（attempt 2）直接绿。红的两条是
  `T05T07GeometryTransactionTests.testExpiredTokenCompensatesInsteadOfLeavingWindowResized` 与
  `TransitionSceneTests.testReduceMotionPresentsTheSameEndpointsWithoutAnyFlight`（`Executed 182 tests, with 1 test skipped and 2 failures`）。
  "重跑就绿"不是结论，是这条用例在测机器快慢而不是测行为——按方案 §23 必须改判据，不能延长超时或放宽断言。
- **根因**：两条各有各的时钟依赖。
  ① `TransitionCarrierView.play` 在自己的方法体里盖 `startTimestamp`，而 Metal 首帧渲染、图层配置都发生在这之前；
  测试另一头自己调一次 `CACurrentMediaTime()` 当中点基准，两次读数之差没有上界，机器一慢"中点"就落到终点之后，
  于是"还在途中"的对照组读成"已经到终点"。
  ② T07 用 `pendingUntil(timeout: 1) { writer.totalWrites == 2 }` 等补偿那一笔，1 秒是墙钟预算；
  补偿本身要过调度器排队、重取 AX 句柄、写后读回、再落盘结算，慢机器上就是能超过 1 秒。
- **修改文件**：[Presentation/ModeTransitionCoordinator.swift:144](../Presentation/ModeTransitionCoordinator.swift#L144)、
  [:187](../Presentation/ModeTransitionCoordinator.swift#L187)（新增 `startAt:` 起点注入，生产路径仍按进入时刻自取时钟）、
  [Tests/HostTests/TransitionSceneTests.swift:1302](../Tests/HostTests/TransitionSceneTests.swift#L1302)、
  [:1322](../Tests/HostTests/TransitionSceneTests.swift#L1322)（A41 两条播放都给定起点，进度恰好 0.5）、
  [Tests/HostTests/T05T07GeometryTransactionTests.swift:387](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L387) 起。
- **关键行为**：T07 的等待换成三段事件——补偿写入由替身在 `onWillWrite` 上报信（`OneShot`，见
  [:387](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L387)）；事务是否了结问**调度器栅栏**
  `await scheduler.fence(identities: [identity])`（[:408](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L408)），
  它等的就是这一笔在通道上彻底走完（`markRestored → drop` 就在那个工作闭包里），没有时长也没有轮询；
  "补偿不是总超时兜底跑出来的"改成结构判据——补偿到位时不许出现「过渡超时」那条回报（
  [:404](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L404)）。
  唯一的 sleep 是 5 秒看门狗（[:395](../Tests/HostTests/T05T07GeometryTransactionTests.swift#L395)），
  它只把"补偿根本没来"从挂死变成一条可读失败，通过路径永远不经过它，所以这个数字参与不了任何结论。
- **回归用例**：这两条本身就是回归用例（A07/A41），判据未变，只把触发时机从时钟改成事件。
  连续 10 轮单独复跑两条：`Executed 20 tests, with 0 failures`（日志 `/tmp/host_repeat10.log`，18:43）；
  整套宿主 182 条 1 skipped 0 failures（`/tmp/host_full_det.log`），核心 155＋64 全绿（`/tmp/core_det.log`）。
- **状态**：代码完成。真机侧仍是未测（见 §11.12）。

### 11.12 未完成项（直说未完成）

1. §19 M01–M14 全部真机项、§20 的性能数字、30 分钟长跑、录屏、P0-19 真机对照、强退恢复实机——**全部未测**。
   阻塞条件**只有一个：桌面锁定**。八个读数（16:06、16:09、16:17、17:49、19:23:39、19:44:01、19:53:19、20:38:18）全是
   `CGSSessionScreenIsLocked=1`、`onDisplay=1`，同时 `CGGetActiveDisplayList` 回 `active=0`（`online=1`）——
   会话在、屏在，只是锁着，AX 窗口列表读不到、捕获拿不到真实画面。不是代码缺东西，也不是权限缺东西。
   **上一轮卡住这件事的前提已经解掉了**：§11.10 的分组测量面随 `v0.1.12`（`dbf2204`，构建 26）发出，
   并按 §11.1 装进 `/Applications/Vistile.app`（运行包 `dd07d34a…5d9e9`，与 dmg 内那份一字不差；同 Developer ID
   `U8U443D7ZL`、同 bundle id `com.misswell.Vistile`，**授权不用重给**）。所以解锁后跑的就是带分组键的那套指标名，
   取到的是 §20.2 要的数字，不会再退回 0.1.11 的合池老名字。解锁后一条命令即可起跑（任务 §34，
   命令在本文档 §4「怎么跑」与 [Evidence/README.md](Evidence/README.md) 的"run14 起跑前"一节）。
2. `v0.1.12` 已提交（`dbf2204`）、打标签、发布，CI 与 Release 两条 run 均 success；发布包与运行包 hash 已回填进 §11.1。
   工作树里现在只有这一份文档改动（`git status` 只列 `Docs/Acceptance.md`），**代码与已发布字节完全一致**，
   上一轮"代码和文档都比包新"里的**代码**那一半已经不成立。残留的是"文档比字节新一条 doc 提交"——
   这一条不影响被测对象，只要求写回时如实标明它是发布之后补的。
3. §20.1 目标里"点击反馈 P95 ≤50ms"的锚定实现（首帧延迟 + 呈现核对）本轮才落进代码，
   **没有任何真机样本证明它达标**；上一轮（0.1.10）的帧间隔样本 n=36/61/53、p95 32.6–50.7ms 是不同源码轮次、不同口径的读数，只作趋势，不作达标证据。

按方案 §22 的验收通过条件，**本轮不能宣布整体验收通过**：代码项（R01–R10 + 确定性回归）已完成，
真机与性能两项在发布字节上还是空的。

## 12. 第二轮代码审查（基线 `1235207`）修复记录（2026-10-18）

本轮审查在 HEAD `1235207`（= `origin/main`，2026-10-17 20:40）上提出 6 项缺陷（3×P1、3×P2）。
逐条回到真实代码核对：**6 项全部成立**，已全部修复并补确定性回归。**代码项完成；§19 真机项与 §20 性能数字
仍是未测**（阻塞条件同 §11.12：桌面锁定），因此**仍不能宣布整体验收通过**。

### 12.1 逐项：根因 / 改动 / 回归 / 状态

| 编号 | 缺陷 | 核对后的根因 | 改动文件 | 回归用例 | 状态 |
| --- | --- | --- | --- | --- | --- |
| C01（P1） | 日志并发提交失败会丢失已成功提交的恢复记录 | `mutate()` 在锁内基于 `staged` 生成快照并**立即**写入 `staged`，之后才 await 落盘；失败时 `staged = committed` 是对共享暂存区的盲覆盖。两支后果：① 已失败的 A 被 B 的落盘冒充为已提交；② 已报成功的 B/C 被后一批基于旧 `staged` 的落盘静默抹掉。`revision` 还是无锁 stored property，被外部直接读 | [WindowJournalStore.swift](../Recovery/WindowJournalStore.swift)（整批事务进 channel，删 `staged`，`committed` 成唯一提交点；`revision` 改加锁 computed；新增 `JournalDiskWriting` 注入点） | `testConcurrentFailedBatchNeverErasesLaterSuccessfulBatches`、`testRevisionAdvancesOnlyOnPersistedBatches`、`testLaterBatchStartsFromCommittedSnapshotAfterFailedBatch`（[WorkbenchEntryTests.swift](../Tests/HostTests/WorkbenchEntryTests.swift)） | 代码完成；替身回归通过；反向验证：换回旧实现时 6 条断言确定性变红 |
| C02（P1） | 最小化解除没有许可、副作用登记过晚、提前返回不补偿 | `GeometryWriting.setMinimized` 不带 `GeometryWritePermit`，AX 队列内也不查许可；`placeMain()` 解除成功后要等到几何写入阶段才 append `SideEffect`，中间 7 条提前返回路径（目录换代/句柄/实读/纠正/日志/撤销）都会把窗口留在"已展开"状态；`FocusCoordinator.performExpand` 同形 | [AXWindowResolver.swift](../Discovery/AXWindowResolver.swift)（新增 `MinimizeWriteOutcome`，许可在 AX 队列内检查）、[WorkbenchSwitchCoordinator.swift](../Presentation/WorkbenchSwitchCoordinator.swift)（解除成功即登记 `minimizeRelease`，全部提前返回走恢复授权收回；补偿先几何后最小化）、[FocusCoordinator.swift](../Presentation/FocusCoordinator.swift)（同一条许可 + 收口） | `testCancelledMinimizeReleaseNeverTouchesTheWindow`、`testJournalFailureAfterMinimizeReleaseRestoresMinimizedState`、`testRejectedGeometryAfterMinimizeReleaseRollsMinimizedStateBack`（[WorkbenchSwitchTests.swift](../Tests/HostTests/WorkbenchSwitchTests.swift)） | 代码完成；替身回归通过 |
| C03（P1） | 新会话清队列不通知等待者，工作台可能永久忙碌 | `openSession()` 用 `pending.removeAll()`，绕过 `skip()`；`request()` 的 OneShot 只能靠 run/onSkipped 结算，排队项被移出后等待者永不恢复，`activeContext` 收不了口 | [GeometryOperationScheduler.swift](../Presentation/GeometryOperationScheduler.swift)（清队列逐项 `skip(.sessionChanged)`，`skip` 成为唯一终态函数） | `testOpenSessionReleasesQueuedWaiterAndKeepsNewSessionUsable`（[WorkbenchDividerTests.swift](../Tests/HostTests/WorkbenchDividerTests.swift)） | 代码完成；替身回归通过 |
| C04（P2） | 操作前快照不是实读，补偿会被误判失败 | reducer 的 `beforeOperation` 取 `actualFrame`（事务临时值/目录缓存），宿主写前实读只落日志、不回写 reducer；`canClaimOldMainStillMain/canClaimCandidateIsHome` 拿补偿 frame 与计划期快照比 2pt → 外部移动过 A 后正确补偿被判失败并进 `recoveryRequired`。另：缓存 frame 调 `decide()` 会提前拒绝实际放得下的窗口 | [WorkbenchReducer.swift](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift)（补偿判定优先用 `beforeReads`；缓存只作乐观预检 `canDeferPlacement`）、[GeometryOutcome.swift](../Packages/VistileCore/Sources/VistileCore/Recovery/GeometryOutcome.swift)（`WorkbenchCompensationResult.beforeReads`，默认参数兼容）、[WorkbenchSwitchCoordinator.swift](../Presentation/WorkbenchSwitchCoordinator.swift)（补偿回执填 journal 里绑定 operationID 的写前实读） | 核心 4 条：`testExternalMoveBeforeFailureCompensationUsesHostBeforeReads`、`testExternalMoveBeforeFailureWithoutBeforeReadsStillRequiresRecovery`、`testOversizedCachedFrameDefersToHostBeforeReadForMovableWindow`、`testOversizedCachedFrameStillRejectsImmovableWindow`（[WorkbenchTests.swift](../Packages/VistileCore/Tests/VistileCoreTests/WorkbenchTests.swift)）＋宿主回执断言（`testRejectedGeometryAfterMinimizeReleaseRollsMinimizedStateBack` 内） | 代码完成；红测已验证（回退 reducer 时 (a) 落 `recoveryRequired`、(c) 拿不到计划） |
| C05（P2） | `drain(until:)` 的截止保证不成立 | 循环里 `await fence(identities: [])`，在途写入永不返回时 fence 永不恢复，循环回不到顶部查截止 | [GeometryOperationScheduler.swift](../Presentation/GeometryOperationScheduler.swift)（`DrainWaiter`：静默与截止唤醒竞速，先到者结算；新增 `init(now:scheduleDeadline:)` 注入点，生产默认单调时钟定时器） | `testDrainDeadlineWinsAgainstHangingRestoreAndKeepsJournal` | 代码完成；替身回归通过（手动时钟/手动到点，无真实 sleep） |
| C06（P2） | `laneDepth` 不能证明当前调用者是通道内部任务 | `laneDepth > 0` 是 @MainActor 共享状态，`await` 处其他独立任务也能看到并绕过串行队列 | [GeometryOperationScheduler.swift](../Presentation/GeometryOperationScheduler.swift)（删 `laneDepth`，改 `@TaskLocal` 通道令牌 + `activeChannelToken` 身份相等；独立任务必排队，同操作补偿嵌套仍就地执行） | `testIndependentRequestQueuesBehindSuspendedOperation`、`testNestedRequestInsideChannelRunsInlineAndKeepsOrder` | 代码完成；替身回归通过 |

### 12.2 本轮自动回归（全部在本机重跑）

- 核心包 `swift test --package-path Packages/VistileCore`：swift-testing **155 项 / 16 suites**、XCTest **69 项**，0 失败。
- 宿主 `VistileHostTests`：**194 项执行、1 项跳过、0 失败**（`** TEST SUCCEEDED **`）。
  跳过的仍是既有环境项 `T01ActionRoutingTests.testKeyboardFocusReallyLandsOnContentView`（需真实前台激活，按方案 §22 不计成功）。
- 受影响三套（`WorkbenchEntryTests` / `WorkbenchDividerTests` / `WorkbenchSwitchTests`）**重复 5 轮**：
  `Executed 265 tests, with 0 failures (0 unexpected)`（5×53），无新增真实 sleep 或墙钟等待。
- 应用目标 `xcodebuild build -scheme Vistile`：`** BUILD SUCCEEDED **`。
- 基线对比：改动前 182 宿主用例 / 155+64 核心用例；改动后 194 / 155+69，新增 **17 条**确定性用例
  （3 日志并发 + 4 调度器 + 3 最小化许可/补偿 + 4 核心 beforeReads + 1 核心最小化事实 + 1 宿主 original 同批落盘 + 1 宿主最小化恢复事实）。

### 12.3 本轮遗留与风险（直说）

1. **真机项仍全部未测**：§19 M01–M14、§20 性能数字、30 分钟长跑、录屏、P0-19 对照、强退恢复实机——阻塞条件与 §11.12 相同（桌面锁定）。
   本轮的 6 项修复只证明"代码与替身回归"，不证明真实桌面交互。
2. `settleMainFrame`（拖动分隔线的布局结算）仍用缓存 frame 调 `decide()`，同类"缓存过大提前拒绝"**刻意不扩散**：
   结算的契约是"放不下就只改投影、不写窗口"（§9.1），一旦为缓存不可知先起一次写入，
   被宿主拒绝时会在日志里留下一条"计划过但从未写入"的事务，反而多出一条无从解释的恢复义务；
   收益只有"缓存过期但真实放得下"这一种情形，不抵代价。要根治需要把"读一次真实 frame"提前到 reducer 之前，属单独设计。
3. C04 的 deferral 让固定尺寸窗口在"缓存不知道真实尺寸"时按主区目标起动画：揭幕瞬间可能有一次收缩（动画端点与真实落点不同），正确性不受影响。
   （缓存可推出的尺寸一定比主区大，无法在不读真实 frame 的前提下算出更准的端点；因此没有做"猜一个更小目标"的优化。）
4. C02 的最小化恢复失败**已经进入补偿事实**（C08）：`unresolvedMinimizeRestorations` 非空时 reducer 不再宣称"回滚完成/候选归位"，
   转入 `recoveryRequired`；残留风险只剩"权限丢失/窗口已消失导致连补偿授权也写不进去"，此时靠日志与下次启动核对。
5. `JournalDiskWriting` 替身现已覆盖主日志与 settlement backlog 两条落盘路径（C09）；仍未覆盖的是 Windows 目录之外的 IO。
6. 文案变化：缓存不可知但真实放不下时，提示从"受限尺寸"变成过渡失败/交换失败携带真实原因；若历史验收脚本按旧文案比对，需要更新。
7. **本轮改动随 `v0.1.13` 发布**：工作树改动 `16 files changed`（代码 12 个 + 文档 4 个；两轮改动后共重算 50+ 处行锚，
   全仓行锚自检 `links=188 named=46 problems=0`）。发布字节的 SHA、CI 链接与包内二进制哈希在发布后回填到 §12.5。

### 12.4 同轮优化（在上表之后落地，2026-10-18）

审查项的修复完成后，按"把修复本身再做扎实"补了三处改动（不改变对外行为，只减少不确定性与写放大）：

| 编号 | 优化 | 根因/动机 | 改动文件 | 回归用例 | 状态 |
| --- | --- | --- | --- | --- | --- |
| C07 | 写前实读的 original 修正与操作前快照合并为**同一批**落盘 | 原来两次 `update`：先 `correctOriginal` 再写 operationBefore。虽然 `SessionJournal.apply` 的合并规则不会覆盖 originalFrame，但两次落盘之间会短暂出现"纠正已落、before 未落"的分叉，且每次放置多一次磁盘往返（方案 §20.3 第 1 项）。现在改成 `update(request, additional: [.correctOriginal(...)])`，同成同败、一次往返 | [WindowJournalStore.swift](../Recovery/WindowJournalStore.swift)（新增批量 `update` 重载）、[WorkbenchSwitchCoordinator.swift](../Presentation/WorkbenchSwitchCoordinator.swift)（placeMain 只发一批） | `testCorrectedOriginalSurvivesTheSameBatchAsOperationBefore`（新增）；原有 `testStaleCatalogSnapshotIsCorrectedBeforeFirstWrite` 继续通过（证明纠正仍到 device 与 journal） | 代码完成；替身回归通过 |
| C08 | 最小化恢复失败进入补偿事实 | 上一轮只在诊断里记一行，reducer 仍可能按"补偿完整"收口（§6.4 要求失败必须显式）。现在 `WorkbenchCompensationResult.unresolvedMinimizeRestorations` 非空 ⇒ `isComplete` 为假、候选归位不成立 ⇒ `recoveryRequired` | [GeometryOutcome.swift](../Packages/VistileCore/Sources/VistileCore/Recovery/GeometryOutcome.swift)、[WorkbenchReducer.swift](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift)、[WorkbenchSwitchCoordinator.swift](../Presentation/WorkbenchSwitchCoordinator.swift)、[_HostGeometryFakes.swift](../Tests/HostTests/_HostGeometryFakes.swift)（`refusesMinimize` 注入） | 宿主 `testUnrecoveredMinimizeIsReportedInCompensationFacts`、核心 `testUnrecoveredMinimizeRestorationForcesRecoveryRequired`（均新增） | 代码完成；替身回归通过 |
| C09 | settlement backlog 落盘接入同一可注入接缝 | `recordSettlementFailure` 的留档写原本自己起 `queue.async`，故障只能靠真实磁盘坏掉才测得到（方案 §15.1 要求可注入） | [WindowJournalStore.swift](../Recovery/WindowJournalStore.swift)（`writeBacklog` 走 `journalDiskWriter`） | 既有 journal 用例覆盖主路径；留档失败注入未单独加例（风险低，已记入 §12.3 第 5 条） | 代码完成 |

三项都只动内部时序/事实表达，不改产品交互；`git diff` 中对应测试均为确定性替身，无新增 sleep。

### 12.5 0.1.13 发布字节核对（2026-10-18 00:25 发布）

本节记录 `v0.1.13` 的发布事实，供后续 `run14` 真机轮次与下次发布核对。
**发布已成功，但本版仍未在真机上跑过任何一轮**——真机项状态同 §11.12、§12.3 第 1 条。

- 标签 / 提交：`v0.1.13` → `8211f3b`（轻量标签，`git ls-remote` 与 `refs/heads/main` 同 SHA；代码提交 `8ccda2b` + 版本提交 `8211f3b`）。
- CI：CI run [`39049342084`](https://github.com/misswell/Vistile/actions/runs/39049342084) success（核心包 + 宿主构建与测试）。
- Release：run [`39049344986`](https://github.com/misswell/Vistile/actions/runs/39049344986) success；发布页 <https://github.com/misswell/Vistile/releases/tag/v0.1.13>。
  `prerelease=true` 是仓库既有约定（`v0.1.12` 同为 prerelease），不是"候选包"标记。
- 发布资产：`Vistile_v0.1.13_macos_arm64.dmg`，**2,375,689 字节**，
  `sha256 7a9eec18feba590d8bd172bccf488521819c6ed988d830f42244ee49f5bd5a8a`——与 `gh release view v0.1.13 --json assets` 的 `digest` 一字不差
  （下载后先看字节数再哈希：历史上出现过 `gh release download` 截断导致哈希假性不符）。
- dmg 内包体：`Vistile.app/Contents/MacOS/Vistile` 的 `sha256 113109b58256ac860e979250f08152518dd56e07703e460c5e56314de78b5745`，
  `CFBundleShortVersionString=0.1.13`、`CFBundleVersion=27`、`lipo -archs=arm64`；
  `codesign --verify --deep --strict` 通过、`Identifier=com.misswell.Vistile`、`TeamIdentifier=U8U443D7ZL`、
  `flags=0x10000(runtime)`、`xcrun stapler validate` 通过、`spctl -a -t exec -vv` = `accepted` / `source=Notarized Developer ID`。
- **没有做的事**：没有把 0.1.13 装进 `/Applications`（当前仍是 0.1.12 的正式字节），因此也没有 `P0-0` 权限读数与
  任何 `run14` 报告。真机轮次需要按 [Docs/Evidence/README.md](Evidence/README.md) 的「run14 起跑前」：先
  `ditto` 把 dmg 内包体装进 `/Applications`（同 bundle id + 同 Developer ID，屏幕录制/辅助功能授权不需要重给），
  再核对 `P0-0` 与二进制哈希一致，然后才起跑。

复核命令：

```bash
gh release view v0.1.13 --json assets -q '.assets[] | .name+" "+(.size|tostring)+" "+.digest'
shasum -a 256 /tmp/vistile013/Vistile_v0.1.13_macos_arm64.dmg   # 期望 7a9eec18…5bd5a8a
hdiutil attach -nobrowse -readonly /tmp/vistile013/Vistile_v0.1.13_macos_arm64.dmg
shasum -a 256 "/Volumes/Vistile v0.1.13/Vistile.app/Contents/MacOS/Vistile"   # 期望 113109b5…8b5745
```

### 12.6 0.1.13 实机缺陷：交换一次之后界面不再响应（C10）

**这是 0.1.13 发布后在真实桌面上复现的缺陷**，现场证据取自统一日志（`log show --info`，进程 0.1.13/27）：

```
00:35:46  [过渡] 播放 总览→L 型：20 张卡片，240ms
00:35:48  [过渡] 播放 L 型内交换：2 张卡片，180ms
00:35:48  [日志] 事实追加失败 14114:…:4967 原因=日志序号已过期（期望 7，当前 8）：update 9300D53C 未写入
00:35:51  [过渡] 真实窗口未在限时内到位，收起承载层
00:37:21  [focus] 激活确认 …：过渡/交换在途，前台归属交由执行器判定，保持会话   ← 一分钟后仍认为"在途"
```

之后点击任何卡片/按钮都不再产生任何效果；`session-journal.json` 里留下一条 `mutationPlanned`
（同一 operationID）与一条 `verified`，说明交换在第一笔事实处就失败、只写过一个窗口。

**根因（两处叠加）**

1. **守卫维度错了**：`WorkbenchSwitchCoordinator.updateJournal` 把日志**全局 revision** 传给
   `WindowJournalStore.update` 当过期守卫。日志是会话级共享的：退出清理、布局结算、同窗口 latest-wins
   结算都会推进 revision；无关写入一前进，本次交换的第一条事实就被判"序号过期"。实机「期望 7，当前 8」即此。
   （C01 只把 `revision` 的读写加了锁，没有改守卫语义，所以 0.1.13 仍会命中。）
2. **失败收口走错分支**：写前事实落盘失败时 `handleJournalUpdateFailed` 仍走"写后失败"路径，发 `.drainGeometry`；
   宿主 `AppCoordinator.drainGeometry()` 会 `switchCoordinator.cancel()` 交还会话所有权，而这次交换的失败结论
   `mainSwitchFailed` 正是由那条在途链补偿后回报的——先取消它，回报就被 `activeContext == context` 门禁全挡掉，
   reducer 永远停在 `.rollingBack`，之后的点击全被 `mainSwitch.isBusy` 吞掉（focus 日志里"交换在途"就是它的症状）。

**修复**

- 守卫改为"**条目仍存在**"（[WindowJournalStore.swift](../Recovery/WindowJournalStore.swift)）：
  无关写入推进 revision 不再影响；条目被补偿清理后才拒绝迟到写入。没有改用 `operationID` 归属守卫——
  同窗口 latest-wins 会在上一笔仍途时先为新操作准备事务，按归属会把在途那笔的写后事实判成过期（实现时踩过，见宿主用例）。
- 操作自身的日志失败**不再发 `.drainGeometry`**（[WorkbenchReducer.swift](../Packages/VistileCore/Sources/VistileCore/Domain/WorkbenchReducer.swift)）：
  排空只属于隐藏/退出入口；失败由在途链补偿后如实回报，状态机不再停在 rollingBack。
- `preparedRevision` 状态与两次落盘的序号基座一起删除（C07 之后本来就只有一批）。

**回归**（均确定性替身，无真实 sleep）

- 宿主 `testUnrelatedJournalWriteBeforePlacementDoesNotKillSwitch`：写前实读处挂起 → 无关流程写日志推进 revision →
  放行后交换仍必须写入并提交。
- 宿主 `testPreWriteJournalFailureReportsAndKeepsSessionUsable` / `testPostWriteJournalFailureStillReportsAndKeepsSessionUsable`：
  写前/写后事实落盘失败都必须回报 `mainSwitchFailed`，且失败后下一笔交换能正常提交。
- 核心 `testJournalFailureDuringSwitchNeverDrainsTheInFlightOperation`：交换中的日志失败**不得**产生
  `.drainGeometry`（写前、写后两种分类都断言）；`testObservedFactPersistFailure…` 的旧断言按新语义改正。
- 存储 `testJournalUpdateSurvivesUnrelatedRevisionAdvance`：revision 前进不判死；条目被 drop 后迟到写入被拒。

状态：**代码完成、自动回归通过**；修复后的字节尚未在真实桌面复跑同一条操作序列（见 §12.8）。

### 12.7 更新通道：GitHub Releases（D01）

**通道就是本仓库的 GitHub Releases**，不引入第三方更新框架、不做静默自动安装（与多数开源 macOS 项目的
轻量做法一致；Sparkle 这类完整更新器需要额外签名/feed 基础设施，留作后续可选项）。

- 核心纯逻辑 [UpdateChannel.swift](../Packages/VistileCore/Sources/VistileCore/Domain/UpdateChannel.swift)：
  `AppVersion`（逐段数值比较，`v` 前缀、预发布后缀、段数不同都兼容）、
  `GitHubRelease`/`GitHubReleaseAsset`（按 API snake_case 解码）、
  `UpdateChannelPolicy`（忽略 draft、按仓库既有约定把 prerelease 算进通道、选最高版本、
  资产优先 arm64 dmg → 任意 dmg → zip）。
- 宿主 [MenuBarController.swift](../App/MenuBarController.swift)：菜单「检查更新…」+ 启动后 3 秒静默检查
  （**24h 节流**，未认证 GitHub API 限额 60 次/小时；可在设置关闭）。发现新版本弹窗：
  下载并打开（打开资产直链；无资产则发布页）/ 稍后 / 跳过此版本（跳过只影响自动提示，手动检查仍展示）。
  网络取数（`UpdateReleasesFetching`）、当前版本、时钟全部可注入。
- 设置 [SettingsModel.swift](../Settings/SettingsModel.swift)：`autoCheckUpdates`（默认开）、
  `skippedUpdateVersion`、`lastUpdateCheckAt`。
- 回归：核心 7 条（[UpdateChannelTests.swift](../Packages/VistileCore/Tests/VistileCoreTests/UpdateChannelTests.swift)）；
  宿主 8 条（`UpdateChannelHostTests`，在 [T16DiagnosticsOutputTests.swift](../Tests/HostTests/T16DiagnosticsOutputTests.swift)）：
  新版本+资产、已最新、prerelease 计入、跳过版本语义、24h 节流（证明被节流时不发网络请求）、
  关闭自动不影响手动、坏 JSON、限流提示。

**未测**：菜单弹窗与真实 GitHub 下载的一次真实桌面手工验收（网络、系统弹窗、浏览器下载路径）；
自动检查在真实发布节奏下的行为。自动回归只证明决策与接缝，不证明 UI 交互。

### 12.8 0.1.14 发布字节核对与安装（2026-10-18 01:13）

- 发布页：<https://github.com/misswell/Vistile/releases/tag/v0.1.14>（`prerelease=true`，仓库既有约定）。
- 标签 / 提交：`v0.1.14` → `a9f0043`（代码提交 `bc23e6a`：C10 修复 + D01 更新通道；`a9f0043`：版本 0.1.14/28）。
- CI run [`39052451300`](https://github.com/misswell/Vistile/actions/runs/39052451300) success；
  Release run [`39052455211`](https://github.com/misswell/Vistile/actions/runs/39052455211) success。
- 发布资产：`Vistile_v0.1.14_macos_arm64.dmg`，**2,420,239 字节**，
  `sha256 63efc196434fd165748eae93c5c5386b49ae2bc5218068143fb89f0854cb2738`——与 `gh release view` 的 asset digest 一致。
- dmg 内包体：`Vistile.app/Contents/MacOS/Vistile` = `sha256 f3f16de53dc9871bdf7f98ad2ac48bac8a494162ae31627133c0754bc3e53568`，
  `0.1.14 / 28`，`arm64`；`codesign --verify --deep --strict` 通过、`TeamIdentifier=U8U443D7ZL`、
  `xcrun stapler validate` 通过、`spctl -a -t exec -vv` = `accepted` / `source=Notarized Developer ID`。
- **已安装到 `/Applications`**：装前把 0.1.13 移到 `/tmp/Vistile-0.1.13-backup.app`（未删），
  `ditto` 安装后实测二进制哈希与 dmg 内一致（`f3f16de5…e53568`），并已重启应用。
- **真机复测状态**：C10 的原始操作序列（进入工作台 → 切换一次 → 再点任意卡片与按钮）在 0.1.14 上
  **尚未复跑**；D01 的菜单弹窗与真实下载同样**未做手工验收**。两者都需要用户在下一次交互里确认，
  不能拿自动回归代替。
- 更新通道真实网络冒烟（只验接口，不是 UI）：本机带
  `User-Agent: Vistile/0.1.14` + `Accept: application/vnd.github+json` 请求
  `https://api.github.com/repos/misswell/Vistile/releases?per_page=20` → **HTTP 200**、15 条 release、
  `v0.1.14` 在首位且资产/大小与发布页一致。说明真实响应可被 `GitHubRelease` DTO 解码（解码本身由核心用例覆盖）。

### 12.9 下载镜像与更新通道的国内可用性（D02）

**背景（实机报告）**：用户点 GitHub release 直链无法下载。本机复现：不走代理请求
`https://github.com/misswell/Vistile/releases/download/v0.1.14/Vistile_v0.1.14_macos_arm64.dmg`
→ **25s 超时、0 字节**；同一 URL 经本机代理（127.0.0.1:7890）→ 302 → `release-assets.githubusercontent.com` 200、2,420,239 字节。
所以是网络通道问题，不是发布资产问题。

**镜像部署事实**（自有 ECS，`i-uf62tsvf0xbzzpuzi29v`，nginx 站点 `autocrop.liuguofeng.com`）：

- 路径规则：`/home/wwwroot/autocrop.liuguofeng.com/vistile/releases/<tag>/<文件>`
  → <https://autocrop.liuguofeng.com/vistile/releases/v0.1.14/Vistile_v0.1.14_macos_arm64.dmg>
  （0.1.15 起包含同名 `.sha256`）。
- 实测（直连、不走代理）：HTTP **200**、2,420,239 字节、4.4s；
  `sha256 63efc196…cb2738` 与 GitHub 发布资产一字不差；`.sha256` 文件也可直接取。
- 备用第三方前缀：`https://ghfast.top/<GitHub 直链>` 直连 3.9s、2,420,239 字节、哈希一致
  （`gh-proxy.com` 11.2s 可用；`ghproxy.net` 40s 只下到一半，不作为默认）。
  第三方代理不默认使用：安装包只从自有域名取，第三方只作为人工兜底。
- 站点是 SPA，但 nginx `try_files $uri $uri/ /index.html` 优先返回真实文件，静态 dmg/.sha256 可直接下载。

**App 侧改造**（0.1.15）：`UpdateChannelPolicy` 同时产出镜像地址、校验文件地址与 GitHub 直链；
更新弹窗按钮「从镜像下载 / 打开 GitHub 发布页 / 稍后 / 跳过此版本」，正文写明镜像来源与校验方式。
回归：核心 `testPackageCarriesOwnMirrorAndChecksumURL`、`testPackageWithoutAssetHasNoMirror`、
`testMirrorURLEncodesTagAndAssetName`；宿主更新检查用例补镜像断言。

**未完成/风险**

1. 每发一版需**手工**把 dmg 与 `.sha256` 上传到 ECS 镜像目录（发布流水线跑在 GitHub Runner，
   尚未接自有服务器凭据；可后续用 ECS 部署任务自动化）。
2. 镜像下载在 Safari/系统下载器里的手工验收未做；弹窗四个按钮的真实点击路径未做（只有接缝回归）。
3. 镜像域名与证书归用户自有（Let's Encrypt，2026-12-07 到期）；证书续期失效会让更新通道退回 GitHub 直链语义。

### 12.10 0.1.15 发布字节、镜像上传与安装（2026-10-18 01:28）

- 发布页：<https://github.com/misswell/Vistile/releases/tag/v0.1.15>；标签 `v0.1.15` → `4a1e82e`
  （代码 `e008f8f`：D02 镜像与镜像优先更新通道；`4a1e82e`：版本 0.1.15/29）。
- Release run [`39053562601`](https://github.com/misswell/Vistile/actions/runs/39053562601) success。
- 发布资产：`Vistile_v0.1.15_macos_arm64.dmg`，**2,421,139 字节**，
  `sha256 87dc55eb952c2ebbbb727098263d27595d2928f2d29a925bfd0c41412a9a9201`（与 asset digest 一致）。
- 包内二进制：`sha256 800190cf2a6e387957ae832aeb2efa542d4eb6f531f14b417fa4c0d4b866e16d`，
  `0.1.15 / 29`，`arm64`；codesign / stapler / spctl（Notarized Developer ID，Team `U8U443D7ZL`）全通过。
- **镜像已上传**：`/home/wwwroot/autocrop.liuguofeng.com/vistile/releases/v0.1.15/` 下 dmg + `.sha256`；
  镜像直连（不走代理）实测 HTTP 200、2,421,139 字节、4.5s、`sha256 87dc55eb…9201` 与 GitHub 资产一致。
  0.1.14 的镜像也保留在 `releases/v0.1.14/`。
- **已安装到 `/Applications`**：装前把 0.1.14 移到 `/tmp/Vistile-0.1.14-backup.app`（未删）；
  安装后二进制哈希与 dmg 内一致，并已重启应用（0.1.15/29）。
- 仍未做的手工验收：更新弹窗四个按钮的真实点击路径、Safari/系统下载器下载镜像的体验、
  C10 原始操作序列在 0.1.15 上的复跑（见 §12.6 的"待用户复跑"）。

### 12.11 总览置前与切换卡顿优化（P01，0.1.16）

**用户报告**：① 点菜单「打开窗口总览」时总览没有放到最前；② 点击切换窗口时"模糊的时间有点长"。

**证据（0.1.15 实机统一日志 + 终止时的性能样本）**

- 正常交换（07:08:21.821 → 07:08:22.064）：准备 69ms、B 写入 69ms、前景确认 12ms、A 回轨 96ms、提交 4ms，
  点击到提交约 **243ms**——正常路径不是瓶颈。
- 异常交换（07:08:42.223 起）：B 写入 35ms、激活 8ms 后，**A 的"返回"步骤直到 07:08:44.422 才回报**，
  耗时 2,142ms，结论「被拒绝：拿不到 AX 句柄（身份未唯一确定）」。07:09:45 那次同样是 2.14s 后拒绝。
- 性能样本里出现过 `工作台:主区交换 = 2180.8ms`；另有 07:08:26 一次受限窗口交换在"前景确认 → 原主回轨"
  之间空了 665ms。
- 根因：`WindowCatalog.axEntryAfterReview` 的兜底预算是 `axConfirmBudget = 2.0s`。目录某一轮 AX 读取超时会把
  整代 `axEntries` 置空，复核循环每次整轮刷新（读所有应用的 AX），几何路径就一直停在过渡代理里；
  用户看到的就是"模糊的代理画面停很久"。

**改动**

1. 总览置前：[OverviewWindowController.raisePanel()](../Presentation/OverviewWindowController.swift) +
   [AppCoordinator.showOverview](../App/AppCoordinator.swift) 先 `NSApp.activate` 再逐屏置前；
   `activateApplication` 做成可注入闭包供宿主断言。
2. 交互预算：[WorkbenchSwitchCoordinator.interactiveAXBudget = 1.0s](../Presentation/WorkbenchSwitchCoordinator.swift)，
   只用于 `placeMain` 的句柄复核；恢复/退出仍走 2.0s 默认预算。
3. 跳过冗余探测：`record.allowsGeometryControl == true` 时不再调用 `GeometryWriting.geometryWriteability`
   （策略恒定 resize+move，最终仍以写后读回为准）；固定尺寸/不可移动窗口保留探测。
4. 步骤耗时进日志：`[交换] 步骤=… 耗时=Nms 结论=…`，为下一轮优化保留事实。
5. 回归：宿主新增 `testResizableSwitchSkipsRedundantWriteabilityProbe`（探测次数=0）、
   `testOpeningOverviewActivatesApplicationAndRaisesPanels`（激活回调被调用）；
   A02 取消用例改为固定尺寸窗口（只有那时才会发起能力探测）；A24 断言固定尺寸仍探测。
   核心 155 + XCTest 80，宿主 208 项（1 既有环境跳过）0 失败。

**未完成/风险**

1. **尚未真机复测**：需要在 0.1.16 上重复"打开总览 → 切窗口"并读日志里的每步耗时，
   确认 2.1s 级别的停顿消失（理论上界从 2.0s 降到 1.0s，且正常路径不受影响）。
2. 若某些应用 AX 读取长期超时（0.5–1s 成串），1.0s 预算仍可能让点击出现 ~1s 的等待；
   下一步可考虑"只复核目标 pid"的定向读取，而不是整轮刷新（需要谨慎处理身份匹配）。
3. 动画时长未改（交换 180ms）；"模糊"观感若仍明显，需要真机录屏确认是代理放大低分辨率画面还是等待时间。

### 12.12 0.1.16 发布、镜像与安装（2026-10-18 07:19）

- 发布页：<https://github.com/misswell/Vistile/releases/tag/v0.1.16>；标签 `v0.1.16` → `0dc1bc6`
  （代码 `a9a59fd`：P01 总览置前 + 交换卡顿优化；`0dc1bc6`：版本 0.1.16/30）。
- CI run [`39078293096`](https://github.com/misswell/Vistile/actions/runs/39078293096) success；
  Release run [`39078296214`](https://github.com/misswell/Vistile/actions/runs/39078296214) success。
- 发布资产：`Vistile_v0.1.16_macos_arm64.dmg`，**2,422,661 字节**，
  `sha256 da6f83add4a63345578e3263e1905f21f13d76c9b902b2bc031824ffeaf192a8`（与 asset digest 一致）。
- 包内二进制：`sha256 d8ddfbb9c9d830df1c6a3a19b9774198bf164a49d11a4c675170742218ef5280`，
  `0.1.16 / 30`，`arm64`；codesign / stapler / spctl（Notarized Developer ID，Team `U8U443D7ZL`）全通过。
- **镜像已上传**：`releases/v0.1.16/` 下 dmg + `.sha256`；镜像直连（不走代理）实测 HTTP 200、
  2,422,661 字节、4.8s、哈希与 GitHub 资产一致。
- **已安装到 `/Applications`**：旧 0.1.15 移到 `/tmp/Vistile-0.1.15-backup.app`（未删），
  安装后二进制哈希与 dmg 内一致，并已重启应用。
- **待真机复测**：打开总览是否置前；连续切换窗口时日志里
  `[交换] 步骤=… 耗时=Nms` 是否还有 ~1s 级等待、是否还出现「拿不到 AX 句柄」的 2.14s 停顿。
  动画时长未改，若观感仍"模糊时间长"，下一步应优化过渡代理的画面来源（高分辨率预取），需要真机录屏判断。

### 12.13 性能与动效优化（P02，0.1.17）

**基线（0.1.16，真机 P0 探针 100 轮，2026-10-18 08:41）**

- P0-16 固定交换：100/100 收敛，点击→落定 **p95 623ms**（目标 ≤500）。
- P0-17 往返：进入 **p95 750ms**（目标 ≤600）、返回 323ms（目标 ≤500），成功率均 100%。
- P0-18：点击→首帧 p95 进入 **549ms**、交换 **421ms**（n=93，未判）、返回 **110ms**（目标 ≤50）；
  过渡帧间隔 p95（120Hz 热路径）进入 **47.8ms**、交换 25.8ms、返回 29.2ms（目标 ≤20）；
  271 段里 163 段超预算；有 1 段 0 present 之前的历史数据不计入本轮。
- 拆分打点（诊断构建，08:45 一次探针）：`[首帧] 距输入` p50 14ms / p95 260ms，说明“点击→起飞”在尾部就
  可能吃掉数百毫秒；因此本轮同时优化起飞前与起飞后两段。

**改动**

1. 预建承载层：`ModeTransitionCoordinator.prewarm(displayID:)` + `TransitionCarrierView.prewarm()`；
   打开总览时对每屏调用，把窗口/CAMetalLayer/first drawable 的分配移出点击路径
   （[ModeTransitionCoordinator.swift](../Presentation/ModeTransitionCoordinator.swift)）。
2. hover/点击预取主区画面：`OverviewContentView.onHoverIdentity`、`WorkbenchRailView.onHoverIdentity`
   接出身份 → `AppCoordinator.scheduleHoverPrefetch`（90ms 去抖）→ `prefetchFlightFrame`（400ms/身份节流，
   按主区宽度抓帧，5s 过期）；`modes.textureProvider` 优先返回预取帧，飞行不再放大低清帧。
3. 飞行期间推迟 `capture.sync`：只推迟捕获重配（≤240ms），场景结束 `requestSync()` 立即补；
   面板布局与其它同步照旧。目标是把帧间隔 p95 从 25.8–47.8ms 压向 20ms。
4. 诊断：`[首帧] 场景=… 距输入=Nms`、`[首帧] 场景=… 起飞→呈现=Nms`（info 级，每次飞行两行）。

**自动回归**：核心 155 swift-testing + 80 XCTest；宿主 209 项（1 既有环境跳过）0 失败；
新增 `testOverviewHoverPrefetchesHighResolutionFrameAndPrewarmsCarrier`（总览打开即预建承载层、
hover 触发一次主区抓帧、阈值/计数不退化）。

**未完成/风险**

1. **优化后的真机数字未取得**：08:51 复跑探针时桌面已锁（`screenLocked=1`、`activeDisplays=0`），
   按既有判据整轮记未测；解锁后必须用同一探针重跑 P0-16/P0-17/P0-18 才能判定是否达标。
2. 推迟捕获重配期间，两栏新目标的首帧可能延迟到场景结束后的补同步（≤240ms），需要真机肉眼确认
   没有“栏里空白一拍”。
3. 预取只在 hover ≥90ms 或点击时发起；纯键盘/脚本点击没有 hover 预热，观感收益会小一些。

### 12.14 0.1.17 发布与安装（2026-10-18 08:57）

- 发布页：<https://github.com/misswell/Vistile/releases/tag/v0.1.17>；标签 `v0.1.17` → `684567d`
  （代码 `5657365`：P02 性能与动效优化；`684567d`：版本 0.1.17/31）。
- CI / Release：CI run `39084418587` success、Release run `39084421150` success。
- 发布资产：`Vistile_v0.1.17_macos_arm64.dmg`，**2,431,274 字节**，
  `sha256 c4fd923b627fffb29d45deb52667512995bc22ab31a106dd27fa9e37b48ce16d`（与 asset digest 一致）。
- 包内二进制：`sha256 aac9e4207b8ee64446ea4d8da82c337a7144c673b1fc6340e18e845d00ff149d`，
  `0.1.17 / 31`，`arm64`；codesign / stapler / spctl 全通过（Notarized Developer ID，Team `U8U443D7ZL`）。
- 镜像已上传 `releases/v0.1.17/`（dmg + `.sha256`），直连实测 HTTP 200、2,431,274 字节、4.5s、哈希一致。
- 已安装到 `/Applications` 并启动；本地 P02 诊断构建备份在 `/tmp/Vistile-local-p02-backup.app`。

**本版真机复测状态**：08:51 与 08:57 两次读数均为 `CGSSessionScreenIsLocked=1`、`activeDisplays=0`
（会话在、屏熄/锁），按既有判据探针整轮记未测。因此 §12.13 的“优化后数字”仍为空，
解锁后需复跑 P0-16 / P0-17 / P0-18 才能判断是否达标；自动回归（核心 155+80、宿主 209/1 skip/0 fail）
不能替代性能验收。

### 12.15 0.1.17 真机复测与一次被数据否决的优化（2026-10-18 15:41–15:47）

**环境**：桌面已解锁，屏幕 60Hz（`本机帧间隔=16.68ms`）；0.1.16 基线那一轮是 120Hz，两组不能直接横向比，
下面每组只在自己的分组内看趋势。

**0.1.17 正式字节（Probe run 15:41）**

| 项 | 结果 |
| --- | --- |
| P0-16 固定交换 | 通过：100/100 收敛，点击→落定 **p95 624ms**（目标 ≤500，未达标） |
| P0-17 往返 | 通过：进入 **589ms**（目标 ≤600）、返回 298ms（目标 ≤500），成功率均 100% |
| 点击→首帧 p95 | 进入 **371ms**、交换 **397ms**、返回 **103ms**（目标 ≤50，未达标） |
| 过渡帧间隔 p95（60Hz 热路径） | 进入 49ms、交换 25ms、返回 24ms（目标 ≤20）；207 段里 138 段超预算 |
| P0-18 | 未测：60Hz 分组样本 n<100，按 §20.2 记未判 |

与 0.1.16 相比：首帧从 549/421/110 降到 371/397/103（不同刷新率组，只能作趋势）；交换落定 p95 基本没动；
帧间隔仍在 24–49ms，未达标。

**首帧拆分（0.1.17 自带打点）**：`[首帧] 距输入` p50 34ms、**p95 354ms**（进入 p95 374），
而 `起飞→呈现` 与 `距输入` 几乎相同 → 366ms 的尾部全部发生在**场景起飞之前**，不是 GPU/呈现。
同期指标：`日志:批量 prepare p95 12.9ms`、`工作台:AX 排队 p95 40ms`、`几何写入 p95 49.5ms`，都解释不了 350ms 尾部。

**尝试并被否决的优化**：把“捕获重配（capture.sync）在过渡已登记/在飞时一律推迟”扩展到
`armed != nil`（覆盖点击到 journalPrepared 的窗口）。两次探针（15:44、15:47）结果：

- 首帧没有改善（进入 352/387ms、交换 390ms、返回 117ms）；
- 帧间隔反而变差（交换 33–34ms、返回 39–41ms，120Hz 组出现 59ms）；
- 15:44 那轮 P0-17 在 74/100 失败（总览格心漂移 187.1pt），报告同时出现 120Hz/60Hz 混合分组，
  判断是运行中显示器刷新率/几何发生变化的环境噪声，不是该改动的直接结论；但首帧与帧间隔两项否定了改动本身。

该改动已回退，0.1.17 的发布字节未受影响（`/Applications` 已装回 `aac9e420…149d` 正式包）。

**下一轮要拿事实的点（尚未做）**

1. 在点击路径上加分段打点：`action 处理 → dispatch 结束 → prepare 任务开始 → journalPrepared → playTransition`，
   定位 350ms 尾部的具体一跳；目前只能排除 capture.sync、journal prepare 与几何写入。
2. 若尾部在 `journalPrepared` 之前，可考虑“动画先起飞、journal 失败再撤场”（视觉层先行，不改变 AX 先日志后写入的约束）。
3. 帧间隔需要单独 profile（Metal 每帧命令缓冲/纹理取样 vs 主线程 AX 通知），不能再用推迟同步的办法。

### 12.16 点击路径分段打点与两次被否决的“起飞前推迟”实验（2026-10-18 15:49–15:57）

**诊断打点**（已入 0.1.18 开发线，info 级，仅真实输入后各记一行）：`[首帧] 输入到达` →
`dispatch 结束` → `prepare 开始` → `prepare 完成` → `场景=… 距输入`（既有）→ `起飞→呈现`。
一次飞行最多 6 行，可由“输入到达”到“场景”的窗口还原每一跳。

**分段结果（0.1.17 + 打点，P0 探针 15:53）**

- P0-16 100/100，落定 p95 639ms；P0-17 进入 498ms / 返回 314ms，100/100 通过；帧 p95：进入 36.4、交换 20.9、返回 40.1ms（120Hz 组）。
- 首帧中位数很好：进入 **5.6ms**、交换 6.5ms、返回 37.6ms；但 p95 仍是 **345 / 422 / 90ms**，进入 max 463ms。
- 143 次飞行的慢样本只有 6 次；慢样本形态一致：点击后连续 3–6 个 `dispatch 结束` 才到 `prepare 开始`
  （例：158 → 245 → 460ms，随后 prepare 0ms、起飞 463ms）。`prepare` 与 `落盘` 都不是瓶颈，
  **尾部是点击之后、prepare 之前主线程被别的 dispatch/sync 占用**。

**实验 A（已记于 §12.15）**：过渡已登记（`armed`）时推迟 capture.sync → 首帧无改善、帧间隔变差，回退。

**实验 B（15:57）**：点击后、计划已 arm 时把**整次 performSync** 推迟到场景起飞后补。

- 收益：首帧 p50 进入/返回降到 **3ms**，返回 p95 34ms；
- 未解决：进入 p95 **398ms**、交换 p95 **405ms**（尾部不变）；帧间隔未见改善；
- 回归：P0-17 在 75/100 失败，总览格心漂移 187.1pt（与 15:44 那轮推迟实验同样症状）；探针同时出现
  48/120Hz 混合分组（ProMotion 刷新率随内容变化），跨组数字不可横比。
- 结论：尾部不是 sync 造成的；该改动让总览布局同步延后，与 P0-17 的冻结判据冲突，**已回退**，
  0.1.17 发布字节不变；只保留分段打点。

**下一轮候选（尚未实现）**

1. 视觉先行：reducer 在 arm 时额外发一个“预演场景”effect，宿主立刻起飞动画；journal 失败再撤场。
   只需视觉层先行，不改变“AX 写入前必须日志落盘”的约束；代价是 effect 契约与大量 reducer 断言要改。
2. 若不做视觉先行，则需要给点击路径更高的优先级：把 dispatch 之间的 sync 压缩为“只保留布局/只推迟 capture”
   的组合（实验 A/B 表明整段推迟会破坏总览冻结）——需要更细的 sync 分层，而不是一刀切。

### 12.17 视觉先行实验（P03）与真机否决（2026-10-18 16:10–16:23）

**目标**：按 §12.16 的候选 1 实施“点击 arm 后先用同一计划起飞动画，journal 回执到达后不重播，失败撤场”，
只把视觉提前，不改“AX 写入前必须日志落盘”的约束。实现限制在宿主层：
`dispatch` 循环内 arm 出现即 `preplayArmedTransitionIfNeeded()`；`.enterWorkbench` / `.beginMainSwitch`
按令牌跳过重播；`.hideWorkbench` / `.cancelWorkbenchTransition` 撤场。另加一条诊断计数
`preplayedTransitionCount` / `skippedReplayCount`。

**结果（真机 P0 探针，三次）**

| 构建 | P0-16 | P0-17 | 进入首帧 |
| --- | --- | --- | --- |
| 视觉先行（16:14） | 通过，落定 p95 637ms | **失败 66/100**：总览格心漂移 187.1pt | p50 **0ms**、p95 **369ms** |
| +承载窗口登记为自有窗口（16:20） | **失败 43/100**（阶段 focused 未收敛） | **失败**：真实 frame 静默漂移 41/109/161/193pt | p50 0ms、p95 378ms |
| 同构建复测（16:22） | 通过，落定 p95 646ms | **失败**：同样四窗口、同样漂移量（41/109/161/193pt） | — |

**结论**

1. 视觉先行确实把首帧中位数从 3–5ms 降到 **0ms**；但 p95 尾部仍是 ~370ms（部分飞行在点击时还没有 arm，
   要等后续事件才出现计划），因此**没有解决尾延迟**。
2. 视觉先行期间承载窗口在总览态就可见，使总览格子重排（187.1pt ≈ 一格宽）；把它登记为“自有窗口”后
   又出现真实 frame 静默漂移（无 journal 记录），P0-16 也出现未收敛。两次同构建复测漂移量完全一致，
   不是环境噪声。
3. 该方案在“真实几何/恢复一致性”上不可接受，**全部回退**；0.1.17 发布字节与安装包不变。
   自动回归回退后仍全绿：核心 155+80、宿主 209（1 既有环境跳过）0 失败。

**下一步候选**

- 先解释“真实 frame 静默漂移”的机制（承载窗口可见/自有窗口登记与目录、捕获、几何恢复的交互），
  再决定是否重启视觉先行；
- 若继续追尾延迟，需要 core 侧把“arm”提前到点击处理的同一事件内（目前部分点击要等后续事件才 arm），
  并在 arm 前完成必要的目录一致性检查，否则尾部无法消除。

### 12.18 面向“Mission Control 级丝滑”的帧诊断（2026-10-18 16:28–16:40）

**目标换算**（120Hz ProMotion 下）：动画帧间隔 p95 ≤ 8.33ms（不丢帧）、点击→首帧 p95 ≤ 33ms、
过渡期间主线程不做 >10ms 的同步重活、飞行画面用主区分辨率纹理。

**诊断结论（真机探针 + 新增打点）**

- 单帧渲染成本 p95 **0.06–0.17ms**：Metal 绘制不是瓶颈。
- 帧间隔 p95 8.3–41.5ms，掉帧来自主线程同步，实测：
  - `performSync` 里 **`syncOverviewPanels` 单次 448–490ms**（进入/返回飞行期间）；
  - `updateObservers` 单次 40–60ms；
  - `capture.sync` 已有飞行期推迟（0.1.17），不是本轮大头。
- 实验：飞行期间跳过总览面板重排与观察者同步（只做快速收起）后，探针出现
  P0-16 100/100 且落定 p95 **130ms**、P0-17 100/100 且格心漂移 0.00pt、真实 frame 无漂移，
  部分过渡帧间隔到 **8.33ms（120Hz 满帧）**；
  **但**进入落定 p95 709ms、返回 661ms、进入首帧 p95 542ms（比 0.1.17 的 498/298/371 差）。
  这说明“跳过同步”改变了落定判据的收敛路径——指标变快不等于体验变好，属于测量假象/语义错位，
  **不可作为发布依据**，已撤回行为改动，仅保留诊断打点。

**下一步（按 Mission Control 目标）**

1. 把 `syncOverviewPanels` / `updateObservers` / `capture.sync` 从主线程同步执行改为
   “每个 runloop 最多做一小块”的增量同步（或后台 actor 完成、主线程只提交结果），
   让 displayLink 每帧预算稳定在 8.33ms 内；这是丝滑感的根，不是再推迟到哪里。
2. 落定判据与“视觉完成”解耦：视觉按 displayLink 到点即交接，AX 收敛、journal 收尾在后台继续；
   P0 的“落定”必须同时核对视觉帧与几何事实，避免跳过同步造成的假收敛。
3. 验收门槛：120Hz 下帧间隔 p95 ≤8.33ms、掉帧率 <1%、无连续 2 帧掉帧；点击→首帧 p95 ≤33ms；
   P0-16/P0-17 100/100 且格心/真实 frame 零漂移。

### 12.19 Mission Control 级丝滑：交互期不再 orderOut（P04，0.1.18）

**根因（真机打点）**

- 单帧渲染 p95 0.06–0.17ms；帧间隔 p95 8.3–41.5ms，掉帧来自主线程同步。
- `syncOverviewPanels` 内 `controller.hide()` 的 `panel.orderOut` 单次 **460–496ms**（14 次/探针），
  焦点交接 0ms；飞行期间 `updateObservers` 单次 **43–101ms**（91 次/探针）。

**改动**

1. `OverviewWindowController`：新增 `hideCheaply()`（取消手势 → `alpha=0` → `ignoresMouseEvents=true`）
   与 `presented`/`isOrderedButHidden` 事实；`show()` 恢复 alpha 与命中；`hide()` 仍是真正的 `orderOut`。
   `syncOverviewPanels` 在 `modes.isPresenting || modeTransition.isTransitioning || pendingReveal != nil`
   时走 `hideCheaply()`，隐藏/退出/换屏的收尾统一在 `performSync` 的 `!phase.isVisible` 分支真正下屏。
2. `performSync`：`modes.isPresenting` 时推迟 `updateObservers()`，场景结束由 `requestSync()` 补齐。
3. 回归：`testCheapHideKeepsWindowOrderedForCheapHandoff`（210 项宿主测试全绿）。

**真机实测（120Hz ProMotion；两轮探针）**

| 指标 | 0.1.17 | 0.1.18 |
| --- | --- | --- |
| P0-16 交换落定 p95 | 624–640ms | **252ms / 249ms**（两轮，目标 ≤500） |
| P0-17 进入 p95 | 498–750ms | **128ms / —**（第二轮 28 轮后锁屏中断） |
| P0-17 返回 p95 | 298–323ms | **255ms / —** |
| 首帧 p95（热路径） | 345–422ms | **11ms**（n=101，达标） |
| 返回帧间隔 p95 | 24–40ms | **8.3ms**（n=101，120Hz 满帧） |
| 交换帧间隔 p95 | 21–26ms | 16.7–19.5ms（仍高于 8.33，待下一步） |

**环境事实**：第二轮 P0-17 在 28/100 中断，日志为 `阶段 overview→hidden，由 screenLocked`，
属系统锁屏，不是产品回归；第一轮 P0-17 100/100、格心 0.00pt、真实 frame 无漂移。

**剩余（下一轮）**

- 交换动画帧间隔 16.7–19.5ms 仍高于 8.33ms：需单独看交换期间的主线程活（journal 事实追加、
  AX 写入回执）与渲染节拍，不能再靠"推迟同步"掩盖。
- P0-18 的 120Hz 分组仍要求每条路径 ≥100 操作样本；本轮 P0-17 样本够、P0-16 也够，
  但长跑需要防锁屏（`caffeinate` 或系统设置），否则样本会被环境截断。

### 12.20 0.1.18 发布、镜像与安装（2026-10-18 17:02）

- 发布页：<https://github.com/misswell/Vistile/releases/tag/v0.1.18>；标签 `v0.1.18` → `274f635`
  （代码 `4746f8e`：P04 交互期不再 orderOut；`274f635`：版本 0.1.18/32）。
- CI run `39113542751` success；Release run `39113546992` success。
- 资产：`Vistile_v0.1.18_macos_arm64.dmg`，**2,441,305 字节**，
  `sha256 708608fc72dceb8066bd0bcae3eb3ff0c0349828cbdc8e57249ac9e89177eaf1`（与 asset digest 一致）。
- 包内二进制：`sha256 b57daf3597fc2b877d8a3ce698f99411f4db0551a6af47ee5b67d88e135f9ae9`，
  `0.1.18 / 32`，`arm64`；codesign / stapler / spctl 全通过（Notarized Developer ID，Team `U8U443D7ZL`）。
- 镜像已上传 `releases/v0.1.18/`（dmg + `.sha256`），直连实测 HTTP 200、2,441,305 字节、5.9s、哈希一致。
- 已安装到 `/Applications` 并启动；0.1.17 备份在 `/tmp/Vistile-0.1.17-backup.app`。

### 12.21 交换动画满帧：几何执行延后到动画中段（P05，0.1.19）

**根因**：0.1.18 后交换动画帧间隔稳定 16.7ms（每两帧一次）。`[帧] 慢帧` 与 `[主线程]` 打点显示，
交换飞行期间真实 AX 交换步骤持续占用主线程（每步 10–40ms 量级），displayLink 只能隔帧回调；
而落定预算（252ms 对 500ms 目标）还有一倍余量。

**改动**：`.beginMainSwitch` 里动画立即起飞，真实 AX 交换改为 `Task.sleep(110ms)` 后执行，
并在执行前核对 `mainSwitch` 令牌仍是同一笔（取消/过期直接丢弃）；常量
`AppCoordinator.swapExecutionDelayNS`。宿主 210 项（1 环境跳过）0 失败。

**真机实测（120Hz，完整 100 轮）**

| 指标 | 0.1.18 | 0.1.19 |
| --- | --- | --- |
| 交换帧间隔 p95 | 16.7–19.5ms | **8.3ms（n=100，median=8.3）** |
| 返回帧间隔 p95 | 8.3ms | 8.3ms（n=101） |
| 交换首帧 p95 | 11ms | **3ms（n=100）** |
| 交换 / 进入 / 返回落定 p95 | 252 / 128 / 255ms | **253 / 128 / 256ms** |
| P0-16 / P0-17 | 100/100 | **100/100；格心 0.00pt；真实 frame 无漂移** |

**未完成**：进入动画 120Hz 分组本轮样本仅 1 条（P0-18 要求 ≥100，记未判）；原始慢帧仍有
120 帧 14–19ms（集中在进入/返回的个别进度点）。下一步：对进入/返回做同样的"几何执行后移"验证，
并补足每路径 100 条样本（探针期间用 `caffeinate` 防锁屏）。
