# Vistile

把 macOS 全部符合条件的窗口渲染成固定格子的实时缩略图总览；点击卡片时**真实窗口**本身被放大到接近全屏，其余窗口留在原地作为背景；点击背景空白处回到总览；收回绝不最小化窗口，临时改过的窗口几何在退出时还原。

只用公开接口：ScreenCaptureKit 多路捕获 + Metal 合成，ApplicationServices AX 读写几何，CGWindowList 提供层级与窗口顺序证据。没有私有 SkyLight/CGS 调用、没有事件注入、没有逐帧全屏截屏、不靠窗口标题控制窗口。日志与事务只存会话 id、进程身份、窗口 id、bundle id、原始/临时几何、显示器 id 与时间，**不含窗口标题与像素**；捕获画面只存在于内存纹理，不落盘。

## 必须先知道的三件事

1. **P0 能力门禁（P0-1…P0-8）没有通过。** 通过它需要真机录屏与肉眼验收，本仓库只给出进程内的客观证据与逐项人工步骤，见 [Docs/Acceptance.md](Docs/Acceptance.md)。其中任何一项都可能在你第一次实测时失败。
2. **兼容矩阵全部是「未测」。** [Docs/Compatibility.md](Docs/Compatibility.md) 里没有一格写成「支持」——包括 Chrome、Safari、VS Code、Electron 应用、Office 与全屏应用。未测不等于可用。
3. **性能数字只有本机一条样本。** [Docs/Performance.md](Docs/Performance.md) 里的预算是设计值，不是实测值；CPU、内存、首帧延迟、掉帧率在授予权限后尚未复测。

## 安装

下载 `.dmg`，把 Vistile 拖进「应用程序」。首次启动需要在「系统设置 → 隐私与安全性」里手动授予**屏幕录制**与**辅助功能**，然后重启 App。默认呼出热键是 **⌃⌥空格**。

安装包由 GitHub Actions 用 Developer ID 签名、经 Apple 公证并装订票据，Gatekeeper 不会拦；架构只有 arm64（Apple Silicon），Intel 包不提供。

## 构建与测试

```bash
brew install xcodegen
xcodegen generate                        # Vistile.xcodeproj 由 project.yml 生成
xcodebuild -project Vistile.xcodeproj -scheme Vistile -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build build
cd Packages/VistileCore && swift test    # 76 项单元测试，9 个 suite
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
- 最小化与隐藏的窗口不参与实时预览。
- 无应用内更新、无更新检查、无 App Store 分发；界面文案只有简体中文。
