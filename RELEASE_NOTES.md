# Vistile

把 macOS 全部符合条件的窗口渲染成固定格子的实时缩略图总览；点击卡片时**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景空白处回到总览；收回绝不最小化窗口，临时改过的窗口几何在退出时还原。

只用公开接口：ScreenCaptureKit 多路捕获 + Metal 合成，ApplicationServices AX 读写几何，CGWindowList 提供层级与窗口顺序证据。没有私有 SkyLight/CGS 调用、没有事件注入、没有逐帧全屏截屏、不靠窗口标题控制窗口。日志与事务只存会话 id、进程身份、窗口 id、bundle id、原始/临时几何、显示器 id 与时间，**不含窗口标题与像素**；捕获画面只存在于内存纹理，不落盘。

## 必须先知道的三件事

1. **P0 能力门禁（P0-1…P0-11）没有通过。** 同一个正式版包上已经跑了三轮：0.1.1+2 有两条失败（P0-1 同进程 AX 索引不唯一、P0-3 提升被点窗口时把同应用兄弟一起提上来）；0.1.3+4 把自动项从 9 条扩到 13 条，结果 12 通过 / 1 失败；**0.1.4+5 用改正后的口径复跑，13 条自动项 1 失败**，其中 **P0-1 换了正确判据之后实机通过**（17 个窗口、同进程 AX 索引无重复=true），所以那条红了两个版本的问题不是产品缺陷，是探针测错了东西。剩下两格仍没有结论，而且原因都在探针自己的取证时序上：P0-3 这轮第一次把每个多窗口应用都跑一遍，Code（3 窗口）判通过、Chrome（2 窗口）报"兄弟一起被提升"，但那次读数取在上一轮提升还没落定的窗口列表上；P0-4 记"未测"（动作次数=0、阶段到达=false），因为上一项留下的受控目标让总览打不开。这两处 0.1.5 已修，要复跑才算定性。人工与录屏项一律还是「未测」，见 [Docs/Acceptance.md](Docs/Acceptance.md)。
2. **兼容矩阵只有「关联」与「层级」两列有了部分数据。** [Docs/Compatibility.md](Docs/Compatibility.md) 里 12 个真实应用的关联=通过；层级在 Code 与 ChatGPT 上通过、在 Chrome 上失败（0.1.4 那轮 P0-3 逐应用复测的结果，Chrome 那条红的取证基准有问题，见上一条，因此还不能当成 Chrome 的定论），其余格子（捕获、移动、resize、Sheet）仍然全是「未测」——包括 Safari、Finder、Office 与全屏应用。未测不等于可用。
3. **性能数字只有本机几条样本，且其中 CPU 那一条明显不可信。** [Docs/Performance.md](Docs/Performance.md) 里的预算是设计值；授权态三轮记录 CPU 0.2 / 0.3 / 0.3（十几路流），这个数当不了结论，必须用 Activity Monitor / Instruments 对照。帧数那条也要看口径：报告里的"帧 139 张/3.1s"是所有流合计，不是屏幕帧率。

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
cd Packages/VistileCore && swift test    # 131 项纯逻辑，13 个 suite
cd ../..
xcodebuild -project Vistile.xcodeproj -scheme VistileHostTests \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test    # 80 项宿主测试
```

必须用 `-scheme`，用 `-target Vistile` 会报 `Unable to resolve module dependency: 'VistileCore'`。

自动 P0 探针（只产出证据，不等于验收结论）：

```bash
xcodebuild -project Vistile.xcodeproj -scheme P0Probe -configuration Debug \
  -derivedDataPath build build
open --env VISTILE_P0_MODE=1 build/Build/Products/Debug/Vistile.app
```

产物写在 `~/Desktop/Vistile Diagnostics/`。缺少屏幕录制或辅助功能权限时，相关项记为「未测」并给出原因，不会伪装成通过或失败。

## 已知限制

- 展开真实窗口后前台 App 的键盘归属、Sheet 与子窗口的跟随、多显示器混合 DPI 下的拖拽，均未经真机确认。
- **P0-1 已经回答：0.1.4 实机通过。** 旧断言把整个目录的 AX 索引放在一起比数量，而索引只在同进程内有意义（句柄表按 pid 分桶、写回按 `(pid, index)`）。改成"同进程两个窗口不得解析到同一索引"后，正式包里 17 个窗口回 `窗口编号无重复=true；同进程 AX 索引无重复=true`，多窗口进程 2 个、AX 唯一对应 17 个。口径本身有 5 条单元测试守着（`CatalogIdentityAudit`）。
- **P0-3「只提升被点窗口」现在是一格通过、一格待复测。** 0.1.4 第一次把每个"同应用 ≥2 窗口"的进程都跑一遍：Code（3 窗口）目标 #17→#9、兄弟 #18→#18 ⇒ 通过（这一格在 0.1.1 判红之后一直没被复测过）；Chrome（2 窗口）报兄弟 #17→#13 一起被提升 ⇒ 失败，但那次基准取在上一轮提升还没落定的窗口列表上，0.1.5 用稳定读数复测后才能定性。也可以 `VISTILE_P0_TARGET=Chrome` 只测它。
- **P0-9 / P0-10 / P0-11 已在授过权限的正式版上跑出结论**（0.1.4+5：13 条自动项 1 失败）。P0-4 在 0.1.3 记"未测"是探针在事件派发后立刻读计数，0.1.4 加了等待仍记"未测"，查明还有第二层原因：上一项留下的受控目标让总览压根没打开，点击点不到格子。0.1.5 用 `restoreOverview()` 把两项的进场阶段都清了，键盘归属的最终结论仍属人工项。
- 菜单栏图标已按系统图标的视觉大小重绘，但它在真实菜单栏里的观感仍未经截图确认。
- 最小化与隐藏的窗口不参与实时预览；点最小化卡片会真的把它解除最小化，收回后不会自动放回 Dock。
- 无应用内更新、无更新检查、无 App Store 分发；界面文案只有简体中文。
