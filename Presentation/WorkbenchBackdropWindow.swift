import AppKit
import QuartzCore

/// 覆盖式工作台的"壁纸底"：铺满目标屏、显示桌面壁纸并轻度暗化，**排在真实主窗口的下一层**。
/// 目的是让用户看到"只有一个真实窗口在最前"的干净背景，同时不改变任何窗口几何：
/// 主窗口是别人应用的真实窗口，必须留在最上层；其余应用的窗口都被这层盖住。
/// 窗口编号登记为自有窗口，避免被目录/采集当成一张新卡片。
final class WorkbenchBackdropWindow: NSWindow {
    private let imageLayer = CALayer()
    private let dimLayer = CALayer()

    init(screenFrame: CGRect) {
        super.init(contentRect: screenFrame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        view.wantsLayer = true
        let root = CALayer()
        root.frame = view.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.frame = root.bounds
        imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        root.addSublayer(imageLayer)
        dimLayer.frame = root.bounds
        dimLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        dimLayer.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.18).cgColor
        root.addSublayer(dimLayer)
        view.layer = root
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 更新屏幕 frame 与壁纸图（壁纸不存在时退回深色底）。
    func apply(screenFrame: CGRect, wallpaper: NSImage?) {
        if frame != screenFrame { setFrame(screenFrame, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = screenFrame.size
        imageLayer.frame = CGRect(origin: .zero, size: size)
        dimLayer.frame = CGRect(origin: .zero, size: size)
        if let cgImage = wallpaper?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            imageLayer.contents = cgImage
            imageLayer.backgroundColor = nil
        } else {
            imageLayer.contents = nil
            imageLayer.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
        }
        CATransaction.commit()
    }

    /// 压到某块真实窗口的下一层：这是"看起来只有一个窗口在最前"的关键。
    func orderBelow(windowNumber: Int) {
        order(.below, relativeTo: windowNumber)
    }

    static func wallpaperImage(for displayID: UInt32) -> NSImage? {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }
}
