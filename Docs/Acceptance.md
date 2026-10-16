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
| 纯逻辑层 147 项/15 suite ＋ XCTest 46 项 / 宿主层 157 项（1 skip） | `swift test`、`xcodebuild test -scheme VistileHostTests`，2026-10-17 02:24 最终一轮全过；CI 两条同步在跑（数字见 §7） |

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
