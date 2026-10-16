# Vistile

把 macOS 全部符合条件的窗口渲染成固定格子的实时缩略图总览；点击卡片时**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景空白处回到总览；收回绝不最小化窗口，临时改过的窗口几何在退出时还原。

只用公开接口：ScreenCaptureKit 多路捕获 + Metal 合成，ApplicationServices AX 读写几何，CGWindowList 提供层级与窗口顺序证据。没有私有 SkyLight/CGS 调用、没有事件注入、没有逐帧全屏截屏、不靠窗口标题控制窗口。日志与事务只存会话 id、进程身份、窗口 id、bundle id、原始/临时几何、显示器 id 与时间，**不含窗口标题与像素**；捕获画面只存在于内存纹理，不落盘。

## 必须先知道的三件事

1. **P0 能力门禁（P0-1…P0-11）没有通过。** 通过它需要真机录屏与肉眼验收，本仓库只给出进程内的客观证据与逐项人工步骤，见 [Docs/Acceptance.md](Docs/Acceptance.md)。其中任何一项都可能在你第一次实测时失败。
2. **兼容矩阵全部是「未测」。** [Docs/Compatibility.md](Docs/Compatibility.md) 里没有一格写成「支持」——包括 Chrome、Safari、VS Code、Electron 应用、Office 与全屏应用。未测不等于可用。
3. **性能数字只有本机一条样本。** [Docs/Performance.md](Docs/Performance.md) 里的预算是设计值，不是实测值；CPU、内存、首帧延迟、掉帧率在授予权限后尚未复测。

## 本版（0.1.2）相对 0.1.1 的行为变化

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
hdiutil attach Vistile_v0.1.2_macos_arm64.dmg
xcrun stapler validate "/Volumes/"*/Vistile.app      # 期望 The validate action worked!
codesign -dvvv "/Volumes/"*/Vistile.app 2>&1 | grep -E "Authority=Developer ID|flags=0x"
hdiutil detach "/Volumes/"*
```

这台包在 CI 里已经过了 Gatekeeper 评估开启的干净 arm64 机器：runner 上 `spctl --status` 是 `assessments enabled`，对构建产物和挂载出来的 app 都回 `accepted / source=Notarized Developer ID`。**你自己的 Mac 第一次安装体验仍未测**——权限授予流程、是否被系统二次确认，都要真机才知道；开发机这边 `spctl` 评估是关掉的，测不出这一层。

## 构建与测试

```bash
brew install xcodegen
xcodegen generate                        # Vistile.xcodeproj 由 project.yml 生成
xcodebuild -project Vistile.xcodeproj -scheme Vistile -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
cd Packages/VistileCore && swift test    # 126 项纯逻辑，12 个 suite
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
- 探针新增的 P0-9（真实事件链路与 present）、P0-10（层级改写频率与策略迁移）、P0-11（背景点击令牌不吞后续激活）三项目前只在代码与宿主测试里有证据，还没在授过权限的真机上跑出结论。
- 菜单栏图标已按系统图标的视觉大小重绘，但它在真实菜单栏里的观感仍未经截图确认。
- 最小化与隐藏的窗口不参与实时预览；点最小化卡片会真的把它解除最小化，收回后不会自动放回 Dock。
- 无应用内更新、无更新检查、无 App Store 分发；界面文案只有简体中文。
