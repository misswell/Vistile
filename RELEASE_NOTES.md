# Vistile

把 macOS 全部符合条件的窗口渲染成固定格子的实时缩略图总览；点击卡片时**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景空白处回到总览；收回绝不最小化窗口，临时改过的窗口几何在退出时还原。

只用公开接口：ScreenCaptureKit 多路捕获 + Metal 合成，ApplicationServices AX 读写几何，CGWindowList 提供层级与窗口顺序证据。没有私有 SkyLight/CGS 调用、没有事件注入、没有逐帧全屏截屏、不靠窗口标题控制窗口。日志与事务只存会话 id、进程身份、窗口 id、bundle id、原始/临时几何、显示器 id 与时间，**不含窗口标题与像素**；捕获画面只存在于内存纹理，不落盘。

## 必须先知道的三件事

1. **P0 能力门禁（P0-1…P0-11）没有通过。** 同一个正式版包上跑了两轮：0.1.1+2 有两条失败（P0-1 同进程 AX 索引不唯一、P0-3 提升被点窗口时把同应用兄弟一起提上来）；装上含 R09–R11 的 0.1.3+4 后自动项从 9 条扩到 13 条，结果 **12 通过 / 1 失败**。**0.1.4 查明了这两条失败里至少一条是探针自己的口径错误**：P0-1 旧断言按"全局索引不重复"判，而 AX 索引只在同进程内有意义，所以那两条红都还没被真正回答——P0-1 换了正确判据、P0-3 改成每个多窗口应用都跑一遍，都要 0.1.4 在实机上复跑才有结论。人工与录屏项一律还是「未测」，见 [Docs/Acceptance.md](Docs/Acceptance.md)。
2. **兼容矩阵只有「关联」与「层级」两列有了部分数据。** [Docs/Compatibility.md](Docs/Compatibility.md) 里 12 个真实应用的关联=通过；层级在 Chrome、UGit 上通过、在 Code 上失败，其余格子（捕获、移动、resize、Sheet）仍然全是「未测」——包括 Safari、Finder、Office 与全屏应用。未测不等于可用。
3. **性能数字只有本机两条样本，且其中 CPU 那一条明显不可信。** [Docs/Performance.md](Docs/Performance.md) 里的预算是设计值；授权态两轮记录 CPU 0.2 / 0.3（十几路流），这个数当不了结论，必须用 Activity Monitor / Instruments 对照。帧数那条也要看口径：报告里的"帧 322 张/3.0s"是所有流合计，不是屏幕帧率。

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
shasum -a 256 Vistile_v0.1.3_macos_arm64.dmg   # 期望 0bfb9a52712e2fa954700402606468ae19bef9b6cb7cf5ca556900a1fea760de（1380791 字节）
hdiutil attach Vistile_v0.1.3_macos_arm64.dmg
xcrun stapler validate "/Volumes/"*/Vistile.app      # 期望 The validate action worked!
codesign -dvvv "/Volumes/"*/Vistile.app 2>&1 | grep -E "Authority=Developer ID|flags=0x"
hdiutil detach "/Volumes/"*
xcrun stapler validate Vistile_v0.1.3_macos_arm64.dmg   # 镜像外的那个 .dmg 自己也要有票据
```

覆盖安装即可升级：屏幕录制与辅助功能记在签名身份上，同一个 Developer ID 换版本不需要重新授权。这一条在 0.1.1→0.1.3 的覆盖安装上实测过（没再弹权限窗，探针的 P0-0 仍回两项 true）。

本版（0.1.3）的产物已按上面的步骤核对过：本机从 Release 页重新下载得到 `Vistile_v0.1.3_macos_arm64.dmg`，**1380791 字节**、`sha256 0bfb9a52712e2fa954700402606468ae19bef9b6cb7cf5ca556900a1fea760de`，与 GitHub 资产接口回报的 `digest` 逐字节相同；挂载后 dmg 与镜像里的 `Vistile.app` 票据都 `The staple and validate action worked!`，`codesign --verify --deep --strict` 回 `valid on disk` + `satisfies its Designated Requirement`，证书链 `Developer ID Application: Guofeng Liu (U8U443D7ZL)` → Apple Root CA，`flags=0x10000(runtime)`，`lipo -archs` 只有 `arm64`，`Info.plist` 是 `0.1.3 / 4`；发布那次（run 38866800228）的 CI runner 上 `spctl --status` 是 `assessments enabled`，对构建产物和挂载出来的 app 都回 `accepted / source=Notarized Developer ID`。公证在 runner 日志里成对：`.notarization.zip` 07:24:32 `Accepted` 在前、`.dmg` 07:25:02 `Accepted` 在后。**你自己的 Mac 第一次安装体验仍未测**——权限授予流程、是否被系统二次确认，都要真机才知道；开发机这边 `spctl` 评估是关掉的，测不出这一层。

上一版（0.1.2，1380316 字节、`sha256 f9d1d9786dc7cb0d…537a0c201`）同法核对过，Apple 侧 `notarytool history` 里也是成对出现（`.notarization.zip` 在前、`.dmg` 在后，两条 `Accepted`）。

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
- **P0-1 的旧判据是错的，正确判据要到 0.1.4 的实机复跑才有结论。** 旧断言把整个目录的 AX 索引放在一起比数量，而索引只在同进程内有意义（句柄表按 pid 分桶、写回按 `(pid, index)`）。0.1.4 改成"同进程两个窗口不得解析到同一索引"，冲突时点名进程与窗口编号；跨进程复用同一个索引不再算冲突。这条口径本身有 5 条单元测试守着。
- **P0-3「只提升被点窗口」在 Code 上的失败还没被回答。** 0.1.1 抽到 Code 判失败，0.1.3 抽到 Chrome 判通过——探针每轮只选一个目标，所以 Code 一直没被复测。0.1.4 起 P0-3 对每个"同应用 ≥2 窗口"的进程都跑一遍，也可以 `VISTILE_P0_TARGET=Code` 只测它。
- **P0-9 / P0-10 / P0-11 已在授过权限的正式版上跑出结论**（0.1.3+4，13 条自动项 12 通过）。同一次运行里 P0-9 说真实点击确实转接到了视图，P0-4 却记"协调器没有恰好收到一次卡片动作"——查明是 P0-4 在事件派发后立刻读计数、没等 run loop 落地，0.1.4 已修；键盘归属的最终结论仍属人工项。
- 菜单栏图标已按系统图标的视觉大小重绘，但它在真实菜单栏里的观感仍未经截图确认。
- 最小化与隐藏的窗口不参与实时预览；点最小化卡片会真的把它解除最小化，收回后不会自动放回 Dock。
- 无应用内更新、无更新检查、无 App Store 分发；界面文案只有简体中文。
