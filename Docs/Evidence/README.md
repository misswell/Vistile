# 实测原件

文档里每一轮 P0 数字的原件。文件名就是「那份报告自己的生成时间 + 构建」，
与 `_archive/` 的命名口径一致（`CompatibilityRecorder.archiveName()`）。

| 原件 | 构建 | 报告内生成时间 | 这一轮能不能用 |
| --- | --- | --- | --- |
| `2026-10-16-151340-0.1.1+2-capability-report.md` | 0.1.1+2 | 15:13:40 | 可用（自动 9 项，2 失败） |
| `2026-10-16-150010-0.1.2+3-capability-report.md` | 0.1.2+3 | 15:00:10 | 可用，但 0.1.2 的探针退出挂死，产物是中途快照 |
| `2026-10-16-152633-0.1.3+4-capability-report.md` | 0.1.3+4 | 15:26:33 | 可用（自动 13 项，1 失败＝P0-1 探针判错） |
| `2026-10-16-155655-0.1.4+5-capability-report.md` | 0.1.4+5 | 15:56:55 | 可用（自动 13 项，1 失败＝P0-3，取证基准脏） |
| `2026-10-16-163725-0.1.5+6-capability-report.md` | 0.1.5+6 | 16:37:25 | 可用（自动 13 项，2 失败＝P0-3、P0-7） |
| `2026-10-16-173702-0.1.6+7-capability-report.md` | 0.1.6+7 | 17:37:02 | **作废**：全程 0 帧、AX 只解析出 5/15，依赖帧的 4 项与 P0-3 都是环境产物 |
| `2026-10-16-174616-0.1.6+7-capability-report.md` | 0.1.6+7 | 17:46:16 | 可用（自动 13 项，2 失败＝P0-7、P0-9；P0-3 转通过） |
| `2026-10-16-181450-0.1.8+9-capability-report.md` | 0.1.8+9 | 18:14:50 | **作废**：全程 0 帧、AX 可解析 0/10——会话锁着 |
| `2026-10-16-181734-0.1.8+9-capability-report.md` | 0.1.8+9 | 18:17:34 | **作废**：同上，同一条命令复跑仍 0 帧 |
| `2026-10-16-183354-0.1.8+9-capability-report.md` | 0.1.8+9 | 18:33:54 | 有帧可判（208 帧、present 680），自动 14 项 13 通过 / 1 失败＝P0-3；**但这一轮仍是锁定态**：AX 可解析 0/10，所以那条红是环境不是产品（0.1.9 起记未测） |
| `2026-10-16-202559-0.1.9+11-capability-report.md` | 0.1.9+11 | 20:25:59 | **诊断轮**：P0-4 红＝「总览面板持有键盘=true，键盘归属=overview」——红在取证时机不在产品，修复前的对照 |
| `2026-10-16-202912-0.1.9+12-capability-report.md` | 0.1.9+12 | 20:29:12 | **诊断轮**：P0-4 红＝「5s 内没落定＋总览面板持有键盘」，形状同 +11；两轮都进了 `_archive/` 才留下 |
| `2026-10-16-203854-0.1.9+13-capability-report.md` | 0.1.9+13 | 20:38:54 | 可用（自动 17 项 0 失败；P0-4 转通过＝进入主区 n=3；P0-7 未测＝本轮只接 1 块屏） |
| `2026-10-17-000238-0.1.10+16-capability-report.md` | 0.1.10+16 | 00:02:38 | 可用（P0-12/13/14 转通过；P0-16=2/100、P0-17=12/100 未达目标）：两处拒绝同一个根因——窗口服务器几何提交滞后 AX 约 0.6s，目录采样把刚移动的窗口判成未唯一；修复在 +17 |
| `2026-10-17-001525-0.1.10+17-capability-report.md` | 0.1.10+17 | 00:15:25 | 可用（P0-16=6/100、P0-17=21/100，推进但仍有 2 项未达目标）：新失败形状＝目录快照把一次 AX 读超时折叠成"不可调整尺寸"（isResizable=false），写前守卫拿坏采样当事实拒绝；修复在 +18（写前直接问窗口一次，读不到≠不可写） |
| `2026-10-17-002231-0.1.10+18-capability-report.md` | 0.1.10+18 | 00:22:31 | **诊断轮**：P0-16=1/100（第 2 次交换后会话静默退出：阶段=hidden、主区=空），P0-17 未测（总览没能打开）、P0-14=失败＝面板 300ms 取样早于返回动画落地、环境自检误报 0 帧（取样在退出之后）。静默退出的根因＝焦点核对把一次 AX 读回失败/自己的唤起通知当成失焦证据（+19 修），另两处是探针取样时机（+19 修）；本轮另留 `-live-log.txt`/`-snapshots.txt` 原件 |
| `2026-10-17-004336-0.1.10+19-capability-report.md` | 0.1.10+19 | 00:43:36 | **诊断轮**：P0-16=3/100、P0-17=9/100——两处都是被点身份瞬时未唯一（窗口服务器几何提交滞后，方案 §6.1 的已知瞬态）时宿主把点击丢掉：P0-17 第 10 轮有日志留痕（「身份暂未唯一，复核目录后再判断」后无声放弃），P0-16 第 4 次点击后没有任何后续事件。+19 的焦点阶梯修复本轮零静默退出（4 次交换＋10 轮往返全部完成）。修复在 +20（点击复核重试约 2s＋提示留痕）；本轮另留 `-live-log.txt`/`-snapshots.txt` 原件 |
| `2026-10-17-005027-0.1.10+20-capability-report.md` | 0.1.10+20 | 00:50:27 | 可用（自动 21 项 1 失败）：P0-16 转通过（100/100，交换 p95=384ms）；P0-17=失败——一个窗口报 241.0pt 漂移，但独立快照（00:50:22.6）证明它已在原位：写回后首次采样撞上窗口服务器约 0.6s 的几何提交滞后＝探针单次取样误报（+21 修：连续两次读到同一偏差才判）；P0-18 仍未测（帧样本 66/94/67 < 100，超预算 151 段）。另在日志里抓到两条幻影提示「Code 的窗口尺寸未能恢复」（00:48:40.5 focusLost、00:50:21.8 returnShortcut）：返回总览写回已被恢复路径结算并删掉日志条目，state.transactions 却留成待恢复，下次中断恢复拿不到条目→误报；根因在 +21 修（WorkbenchReducer 同步收口＋回归测试）。本轮另留 `-live-log.txt`/`-snapshots.txt` 原件 |
| `2026-10-17-010924-0.1.10+21-capability-report.md` | 0.1.10+21 | 01:09:24 | **诊断轮**：3 个自动项失败——P0-16=19/100（第 20 次交换拒绝「拿不到 AX 句柄（身份未唯一确定）」）、P0-17=11/100（第 12 轮进入没落定）＋真实漂移（2263 偏 144.0pt、14114 偏 234.0pt）；备注另记「补偿恢复未完成（未执行恢复：辅助功能句柄暂不可用）」。两处句柄路径都是"一个坏采样就判死"：修复在 +22（句柄取不到先带截止时间复核目录，预算用尽才算事实——`axEntryAfterReview` 接入进入路径与恢复路径）。本轮另留 `-live-log.txt`/`-snapshots.txt` 原件 |
| `2026-10-17-013723-0.1.10+22-capability-report.md` | 0.1.10+22 | 01:37:23 | **诊断轮**：1 个自动项失败——P0-16 转通过（100/100，p95=552ms）；P0-17=3/100（第 4 轮 Chrome 位置写入报 -25204、读回其实已在目标位（66,184≈66,183），分类没认读回而按错误码拒绝并回滚）＋漂移 2263 偏 241.0pt（基线在窗口服务器几何提交滞后的约 0.6s 窗口内采样）与 19645 偏 44.0pt（ZCode 自播动画，产品侧已回报）。修复在 +23（分类读回优先、补偿回报、稳定基线、漂移分账）。本轮另留 `-live-log.txt`/`-snapshots.txt` 原件 |
| `2026-10-17-015830-0.1.10+23-capability-report.md` | 0.1.10+23 | 01:58:30 | **诊断轮**：P0-16=通过（100/100，p95=554ms）；P0-17=61/100——第 62 轮 Chrome 写入双侧错误码=0、单次读回读不到被按「不能宣称到位」拒绝并补偿回滚，但恢复路径 32ms 后就读到了 66,184（应用刚被改几何时 AX 短暂忙）：单次读失败被当成终审。幻影提示与真实漂移本轮均已消失（+23 四项修复生效）。修复在 +24（写后读回有界重试）。本轮 P0-3/P0-9 因中途锁定段记未测、桌面另有系统授权弹窗干扰，只作诊断不作验收；`-live-log.txt` 为原始流转换件（当时捕获命令少了 `--signpost` 且非 compact，区间行缺失；run12 起恢复标准命令） |

## run14 起跑前（0.1.11 发布字节已就位，原件还没产生）

**先决定跑哪一份字节**：17:18 那轮回归之后工作树比包新——§20.2 的样本分组改动（[Acceptance.md §11.10](../Acceptance.md)）只在树里，
`v0.1.11` 的 `P0-18` 还在写不带分组键的合池指标名。直接跑在装好的 0.1.11 上，M01–M14 与三条路径的数字有效，
但"60Hz/120Hz、reduceMotion、冷/热分组"这一项只能记**未测**（名字里没有分组键，逐组判定读不到任何行）。
要一次拿全，先把这份改动装进 `/Applications/Vistile.app`（同 Developer ID `U8U443D7ZL`、同 bundle id `com.misswell.Vistile`，
授权不用重给），并在 Acceptance §11.1 记下重装包的实际 hash 与版本号——**报告里的构建行必须与那串 hash 对得上**，否则这轮不算在发布字节上。

0.1.11 的发布包已按方案 §19 核对并装到 `/Applications/Vistile.app`（`/Applications/Vistile.app/Contents/MacOS/Vistile`
= `sha256 0ddf55e60a4de0e628f80254380443e5bd84c64f2a3274e48fff5c94c348e0a6`，与 dmg 内那份一字不差；dmg 本身
`2328935` 字节 / `sha256 5facbd52…0061` 与 GitHub 资产 `digest` 相同）。**但 run14 到现在一次都没跑**，因为桌面是锁的：
16:06、16:09、16:17 与 17:49 四次读会话字典都是 `CGSSessionScreenIsLocked=1`（`onDisplay=1`，会话在、屏幕锁着），
锁屏态下 AX 窗口列表读不到、捕获不到真实画面，历史三轮（0.1.6 17:37、0.1.8 18:14/18:17）就是这么废掉的。
判据脚本先落盘再跑（`/tmp` 里的副本会没，别依赖上一次留下的）：

```bash
cat > /tmp/lockcheck.swift <<'EOF'
import CoreGraphics
import Foundation
if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
    print("locked=\(d["CGSSessionScreenIsLocked"] ?? "absent") onDisplay=\(d["kCGSSessionOnConsoleKey"] ?? "absent")")
} else { print("no session dictionary") }
EOF

cat > /tmp/disp.swift <<'EOF'
import CoreGraphics
import Foundation
func dump(_ ids: [CGDirectDisplayID], _ name: String) {
    print("\(name)=\(ids.count) ids=\(ids)")
    for id in ids {
        if let mm = CGDisplayCopyDisplayMode(id) {
            print("   id=\(id) px=\(mm.width)x\(mm.height) Hz=\(mm.refreshRate) asleep=\(CGDisplayIsAsleep(id) == 1)"
                + " on=\(CGDisplayIsOnline(id) == 1) main=\(CGDisplayIsMain(id) == 1) bounds=\(CGDisplayBounds(id))")
        } else { print("   id=\(id) mode=nil asleep=\(CGDisplayIsAsleep(id) == 1)") }
    }
}
func grab(_ n: inout UInt32) -> [CGDirectDisplayID] { [CGDirectDisplayID](repeating: 0, count: Int(n)) }
var n1: UInt32 = 0; CGGetActiveDisplayList(0, nil, &n1); var a = grab(&n1); CGGetActiveDisplayList(n1, &a, &n1)
dump(Array(a.prefix(Int(n1))), "active")
var n2: UInt32 = 0; CGGetOnlineDisplayList(0, nil, &n2); var o = grab(&n2); CGGetOnlineDisplayList(n2, &o, &n2)
dump(Array(o.prefix(Int(n2))), "online")
print("main=\(CGMainDisplayID())")
EOF

xcrun swift /tmp/lockcheck.swift   # 期望 locked=0 才能起跑；locked=1 就停，别跑
xcrun swift /tmp/disp.swift        # 刷新率与布局读 online 那一段（active 在熄屏时是 0）
```

**为什么两套列表都要打**：16:17 实测本机 `active=0` 但 `online=1`——同一块内置屏 `id=1`、`px=1800x1169`、
**`Hz=120.0`**、`asleep=true`、`main=true`、`bounds=(0,0,1800,1169)`。只看 active 会误判成"屏幕消失了、刷新率取不到"，
而 §20.2 的 60Hz/120Hz 分组要靠 online 的 `refreshRate`。ProMotion 会在静止内容与动画之间升降，
所以 run14 的分组读数必须在动画进行中再重读一次，不能拿静态一格给整轮定性。

两条判据都绿了再按顺序跑下面三条（§19/§20 都要，别只跑第一条）：

```bash
# ① 常规轮：M01–M14 + §20 三条路径 + P0-19 台账
open -n -g -W --env VISTILE_P0_MODE=1 /Applications/Vistile.app

# ② 30 分钟长跑（§22「30 分钟资源曲线与隐藏后清理」）
open -n -g -W --env VISTILE_P0_MODE=1 --env VISTILE_P0_LONG_MINUTES=30 /Applications/Vistile.app

# ③ 跑之前先起两条原始记录，跑完立刻按下面「怎么保持不丢」归档
/usr/bin/log stream --level debug --signpost --style compact \
  --predicate 'subsystem == "com.misswell.Vistile"' > /tmp/vistile_run14_live.log 2>&1 &
/tmp/vistile_snapshot_loop > /tmp/vistile_snapshots_run14.log 2>&1 &
```

跑完必须复核的四件事，任一条不成立就把那轮记为作废而不是"通过"：`P0-0` 两权限仍为 true（这一跳 0.1.10→0.1.11 的授权保留到此刻才算有证据）；
报告里的构建行与实际运行的二进制哈希一致（跑的是上面那串 `0ddf55e6…e0a6`，还是重装后的新 hash，两者都要写进 Acceptance §11.1）；
`P0-18` 每一行都带分组键（`档位·reduceMotion=开/关·冷启动|热路径`），逐组的样本 n≥100／累计有效间隔≥1,000 各自过门才判，
不足按 §20.2 写"未判"；三条路径各自的"落定核对：成功率X%（落定/派发）、超时N"一行都要在报告里读得到，缺行就是没测而不是 100%；
中途出现锁屏/睡眠/授权弹窗的段落单列环境中断，不静默删除。
分组键一个都不出现，说明跑的是没带 §20.2 分组改动的旧字节——那一轮的分组项按**未测**记，不能拿合池数字顶。

## 一轮能不能用，怎么当场判

报告里「运行环境自检」那一行会直接给结论（帧 + AX + 会话锁定）。要自己复核，三条公开接口就够：

```bash
# ① 会话是否锁定：CGSessionCopyCurrentDictionary 是 CoreGraphics 公开接口
printf 'import CoreGraphics\nimport Foundation\nprint(CGSessionCopyCurrentDictionary() as Any)\n' > /tmp/lock.swift
xcrun swiftc /tmp/lock.swift -o /tmp/lock && /tmp/lock | tr ',' '\n' | grep -i lock
#    锁定 → CGSSessionScreenIsLocked = 1

# ② 锁定态下任何应用的 AX 窗口列表都读不到（UI elements enabled 仍是 true，权限预检也仍回 true）
osascript -e 'tell application "System Events" to UI elements enabled'      # → true
osascript -e 'tell application "System Events" to get count of windows of process "Code"'   # 锁定时 → 0

# ③ 画面到底有没有在更新（锁屏时抓出来就是锁屏界面）
screencapture -x -o /tmp/now.png && ls -l /tmp/now.png   # 黑屏/锁屏界面只有 ~150KB，真实桌面是 MB 级
```

**为什么必须写这一节**：0.1.6 的 17:37 轮与 0.1.8 的 18:14/18:17/18:27 三轮都是这个形状，
而 18:27 那轮距覆盖安装已经 14 分钟——"等一会儿就好"是错的，锁屏才是根因。
`0.1.8+9` 那三轮里 P0-3 记的「Raise 没有发出（拿不到 AX 句柄）」、P0-4/P0-9 记的「没有可放大的窗口」
全部来自同一个环境，都不能当产品结论；0.1.9 起这三项在锁定态记未测。

`-capability-report.json` 是同一轮的结构化原件，`-P0-acceptance-checklist.md` 是同一轮的人工/自动清单。
17:37 与 17:46 两轮跑的是同一个已授权包（`/Applications/Vistile.app`，二进制 `sha256 5354600c…0817` 相同）、
同一条命令，差别只在桌面当时的状态——这就是"作废"判定的依据，不是猜测。

## 怎么保持不丢

探针每轮都写同一组文件名，桌面上的原件只保留最近一轮；`_archive/` 里的归档又会被
下一轮启动时序影响（0.1.6 之前，启动事实会先就地覆盖上一轮）。所以每跑完一轮，
立刻把三份原件拷进本目录再改文档：

```bash
R="$HOME/Desktop/Vistile Diagnostics"
V=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/Vistile.app/Contents/Info.plist)
B=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' /Applications/Vistile.app/Contents/Info.plist)
T=$(sed -n 's/^- 生成时间：//p' "$R/capability-report.md" | tr ' ' '-' | tr -d ':')
cd Docs/Evidence
for f in capability-report.md capability-report.json P0-acceptance-checklist.md; do
  cp "$R/$f" "$T-$V+$B-$f"
done
grep -m2 -E '^- 构建|^- 生成时间' "$T-$V+$B-capability-report.md"   # 确认拷的是哪一轮
```

> 这条 `tr` 是 0.1.8 改的：上一版写的是 `tr -d ' :-'`，把连字符也一起删了，
> 拷出来的文件名（`20261016181450-…`）和本目录既有命名（`2026-10-16-181450-…`）不一致。

从 0.1.10+18 起，诊断轮另把两份原始日志作为补充原件留档：`-live-log.txt` 是同轮的统一日志
（`subsystem == "com.misswell.Vistile"`，只留本轮应用进程的行），`-snapshots.txt` 是每秒的
窗口清单＋前台应用＋事务日志前缀。它们不是报告机器生成的，是当时桌面上的原始记录：

```bash
/usr/bin/log stream --level debug --signpost --style compact \
  --predicate 'subsystem == "com.misswell.Vistile"' > /tmp/vistile_runN_live.log 2>&1 &
/tmp/vistile_snapshot_loop > /tmp/vistile_snapshots_runN.log 2>&1 &
```
