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
