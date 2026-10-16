import AppKit
import CoreGraphics
import Foundation
import VistileCore

/// 工作台栏承载窗口（方案 §9.2、§9.3）：普通 level 的非激活无边框面板。
/// 只覆盖顶栏/侧栏矩形，绝不覆盖 mainRect；键盘只在搜索期间才接收，
/// 其余时候点击不激活本应用、不抢真实主窗口的前台。
final class WorkbenchRailPanel: NSPanel {
    /// 只有搜索框正在编辑时才接受键盘。普通点击卡片不改这个开关。
    var acceptsKeyboard = false

    init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = true
        // 与渲染器清屏色一致：Metal 还没画第一帧时也不闪白。
        backgroundColor = NSColor(srgbRed: 0.078, green: 0.082, blue: 0.094, alpha: 1)
        hasShadow = false
        level = .normal
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = false
        title = "Vistile Workbench"
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
}
