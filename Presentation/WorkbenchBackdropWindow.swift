import AppKit
import ImageIO
import QuartzCore

/// 更新背景层时执行的图层写入。此观察器仅供内部测试使用；通知紧跟对应的 AppKit/Core Animation 写入。
enum WorkbenchBackdropLayerMutation {
    case windowFrame
    case imageFrame
    case dimFrame
    case imageContents(CGImage?)
    case fallbackBackgroundColor
}

struct WorkbenchWallpaperCacheKey: Hashable, Sendable {
    let displayID: UInt32
    let url: URL
    let modificationDate: Date?

    init(displayID: UInt32, url: URL, modificationDate: Date?) {
        self.displayID = displayID
        self.url = url.standardizedFileURL
        self.modificationDate = modificationDate
    }
}

struct WorkbenchBackdropRequestContext: Hashable, Sendable {
    let displayID: UInt32
    let sessionEpoch: UInt64
    let wallpaperKey: WorkbenchWallpaperCacheKey?
}

struct WorkbenchBackdropRequestToken: Hashable, Sendable {
    let context: WorkbenchBackdropRequestContext
    let generation: UInt64
}

/// 覆盖式工作台的壁纸底：它位于真实主窗口下方，同时遮住选中窗口后面的其他桌面窗口。
final class WorkbenchBackdropWindow: NSWindow {
    private let imageLayer = CALayer()
    private let dimLayer = CALayer()
    private let rasterizeWallpaper: (NSImage) -> CGImage?
    private var currentRequestContext: WorkbenchBackdropRequestContext?
    private var requestGeneration: UInt64 = 0
    private weak var lastRasterizedWallpaperSource: NSImage?
    private var lastRasterizedWallpaper: CGImage?
    private var hasRasterizedWallpaperSource = false
    private var lastAppliedWallpaper: CGImage?
    private var hasAppliedWallpaperState = false

    /// 仅供内部测试使用的观察器；回调对应真实窗口或图层写入。
    var layerMutationObserver: ((WorkbenchBackdropLayerMutation) -> Void)?

    init(screenFrame: CGRect, rasterizeWallpaper: ((NSImage) -> CGImage?)? = nil) {
        self.rasterizeWallpaper = rasterizeWallpaper ?? {
            $0.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
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

    /// 更新屏幕 frame 和壁纸；壁纸不可用时退回深色底。保留 NSImage 入口以兼容现有调用方。
    func apply(screenFrame: CGRect, wallpaper: NSImage?) {
        let cgImage: CGImage?
        if let wallpaper, hasRasterizedWallpaperSource, lastRasterizedWallpaperSource === wallpaper {
            cgImage = lastRasterizedWallpaper
        } else {
            cgImage = wallpaper.flatMap(rasterizeWallpaper)
            lastRasterizedWallpaperSource = wallpaper
            lastRasterizedWallpaper = cgImage
            hasRasterizedWallpaperSource = true
        }
        applyContents(screenFrame: screenFrame,
                      wallpaperCGImage: cgImage)
    }

    /// 为显示器、会话和壁纸来源组合创建请求标记。
    func beginWallpaperRequest(for context: WorkbenchBackdropRequestContext) -> WorkbenchBackdropRequestToken {
        if currentRequestContext != context {
            currentRequestContext = context
            requestGeneration &+= 1
        }
        return WorkbenchBackdropRequestToken(context: context, generation: requestGeneration)
    }

    /// 应用已解码的图片，并确认结果属于当前显示器与会话请求。
    @discardableResult
    func apply(screenFrame: CGRect,
               wallpaperCGImage: CGImage?,
               requestToken: WorkbenchBackdropRequestToken) -> Bool {
        guard currentRequestContext == requestToken.context,
              requestGeneration == requestToken.generation else { return false }
        applyContents(screenFrame: screenFrame, wallpaperCGImage: wallpaperCGImage)
        return true
    }

    /// 将背景层压到真实窗口下方。
    func orderBelow(windowNumber: Int) {
        order(.below, relativeTo: windowNumber)
    }

    private func applyContents(screenFrame: CGRect, wallpaperCGImage: CGImage?) {
        if frame != screenFrame {
            setFrame(screenFrame, display: false)
            layerMutationObserver?(.windowFrame)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = screenFrame.size
        let layerFrame = CGRect(origin: .zero, size: size)
        if imageLayer.frame != layerFrame {
            imageLayer.frame = layerFrame
            layerMutationObserver?(.imageFrame)
        }
        if dimLayer.frame != layerFrame {
            dimLayer.frame = layerFrame
            layerMutationObserver?(.dimFrame)
        }
        if let wallpaperCGImage {
            if !hasAppliedWallpaperState || !sameImage(lastAppliedWallpaper, wallpaperCGImage) {
                imageLayer.contents = wallpaperCGImage
                layerMutationObserver?(.imageContents(wallpaperCGImage))
                lastAppliedWallpaper = wallpaperCGImage
                hasAppliedWallpaperState = true
            }
            if imageLayer.backgroundColor != nil {
                imageLayer.backgroundColor = nil
                layerMutationObserver?(.fallbackBackgroundColor)
            }
        } else {
            if !hasAppliedWallpaperState || lastAppliedWallpaper != nil {
                imageLayer.contents = nil
                layerMutationObserver?(.imageContents(nil))
                lastAppliedWallpaper = nil
                hasAppliedWallpaperState = true
            }
            let fallbackColor = NSColor(calibratedWhite: 0.09, alpha: 1).cgColor
            if imageLayer.backgroundColor == nil || imageLayer.backgroundColor != fallbackColor {
                imageLayer.backgroundColor = fallbackColor
                layerMutationObserver?(.fallbackBackgroundColor)
            }
        }
        CATransaction.commit()
    }

    private func sameImage(_ lhs: CGImage?, _ rhs: CGImage?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs === rhs
    }

    static func wallpaperImage(for displayID: UInt32) -> NSImage? {
        guard let url = wallpaperURL(for: displayID),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }

    static func wallpaperURL(for displayID: UInt32) -> URL? {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
        guard let screen else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    static func wallpaperCacheKey(for displayID: UInt32) -> WorkbenchWallpaperCacheKey? {
        guard let url = wallpaperURL(for: displayID) else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return WorkbenchWallpaperCacheKey(displayID: displayID,
                                          url: url,
                                          modificationDate: values?.contentModificationDate)
    }
}

/// 壁纸解码与缓存边界：按显示器、标准化 URL 和文件修改时间缓存，并合并同一来源的并发解码。
@MainActor
final class WorkbenchWallpaperImageCache {
    private struct CacheEntry {
        let image: CGImage
        var accessOrder: UInt64
    }

    private let capacity = 8
    private let decoder: @Sendable (URL) -> CGImage?
    private var decodedImages: [WorkbenchWallpaperCacheKey: CacheEntry] = [:]
    private var inFlightDecodes: [WorkbenchWallpaperCacheKey: Task<DecodedWallpaper, Never>] = [:]
    private var accessOrder: UInt64 = 0

    var cachedImageCount: Int { decodedImages.count }

    init() {
        self.decoder = { url in decodeWallpaperImage(url) }
    }

    init(decoder: @escaping @Sendable (URL) -> CGImage?) {
        self.decoder = decoder
    }

    func image(for key: WorkbenchWallpaperCacheKey) async -> CGImage? {
        if var entry = decodedImages[key] {
            accessOrder &+= 1
            entry.accessOrder = accessOrder
            decodedImages[key] = entry
            return entry.image
        }

        let decodeTask: Task<DecodedWallpaper, Never>
        if let inFlight = inFlightDecodes[key] {
            decodeTask = inFlight
        } else {
            let decoder = self.decoder
            decodeTask = Task.detached(priority: .utility) {
                DecodedWallpaper(image: decoder(key.url))
            }
            inFlightDecodes[key] = decodeTask
        }

        let image = await decodeTask.value.image
        inFlightDecodes[key] = nil
        if let image {
            accessOrder &+= 1
            decodedImages[key] = CacheEntry(image: image, accessOrder: accessOrder)
            evictOldestImagesIfNeeded()
        }
        return image
    }

    private func evictOldestImagesIfNeeded() {
        while decodedImages.count > capacity,
              let oldestKey = decodedImages.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key {
            decodedImages[oldestKey] = nil
        }
    }
}

private struct DecodedWallpaper: @unchecked Sendable {
    let image: CGImage?
}

private func decodeWallpaperImage(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}
