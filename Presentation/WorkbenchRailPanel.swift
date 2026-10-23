import AppKit
import CoreGraphics
import Foundation
import QuartzCore
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
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        // The shell supplies its own depth; a window shadow would spill toward mainRect.
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

/// A visual shell inside the unchanged panel bounds. The divider and viewport remain
/// siblings: rounding the background must not round away their rectangular hit areas.
final class WorkbenchRailShellView: NSView {
    let shellLayer = CALayer()
    let dividerHitLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var isOpaque: Bool { false }

    private func configure() {
        wantsLayer = true
        let root = CALayer()
        ImmediateLayerUpdates.configure(root, shellLayer, dividerHitLayer)
        root.isOpaque = false
        root.backgroundColor = NSColor.clear.cgColor
        layer = root
        // Clip only at the panel boundary, never at the shell's rounded outline.
        // AppKit resets masksToBounds when a layer is installed via `layer =`, so this must follow it.
        root.masksToBounds = true
        shellLayer.name = "rail-shell"
        shellLayer.cornerRadius = 18
        shellLayer.cornerCurve = .continuous
        shellLayer.backgroundColor = NSColor(srgbRed: 0.110, green: 0.118, blue: 0.137, alpha: 1).cgColor
        shellLayer.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        shellLayer.zPosition = -1
        root.addSublayer(shellLayer)
        // Fully transparent window pixels can pass clicks through at WindowServer.
        // Keep only the frozen divider band faintly backed, never the shell corners.
        dividerHitLayer.name = "divider-hit-surface"
        dividerHitLayer.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        dividerHitLayer.zPosition = -1
        root.addSublayer(dividerHitLayer)
    }

    /// The supplied rect excludes the divider gap, for either side of the workbench.
    func updateShell(in rect: CGRect, dividerHitRect: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shellFrame = rect.intersection(bounds)
        shellLayer.frame = shellFrame.isNull ? .zero : shellFrame
        shellLayer.contentsScale = scale
        shellLayer.borderWidth = 1 / max(1, scale)
        let hitFrame = dividerHitRect.intersection(bounds)
        dividerHitLayer.frame = hitFrame.isNull ? .zero : hitFrame
        dividerHitLayer.contentsScale = scale
        CATransaction.commit()
    }
}
