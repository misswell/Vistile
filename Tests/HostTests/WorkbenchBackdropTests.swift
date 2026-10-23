import AppKit
import Foundation
import XCTest
@testable import Vistile

@MainActor
final class WorkbenchBackdropBehaviorTests: XCTestCase {
    func testSameWallpaperAndFrameDoNotDecodeOrWriteLayersTwice() throws {
        let frame = CGRect(x: -1200, y: 140, width: 1200, height: 800)
        let cgImage = makeImage(.systemBlue)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: 18, height: 18))
        let probe = BackdropBehaviorProbe()
        let backdrop = WorkbenchBackdropWindow(screenFrame: frame) { _ in
            probe.recordDecode(onMainThread: Thread.isMainThread)
            return cgImage
        }
        defer { backdrop.close() }
        backdrop.layerMutationObserver = { probe.recordLayerMutation($0) }

        backdrop.apply(screenFrame: frame, wallpaper: image)
        let firstApplyMutationCount = probe.layerMutationCount
        backdrop.apply(screenFrame: frame, wallpaper: image)

        XCTAssertEqual(probe.decodeCount, 1, "相同 NSImage 不应重复转成 CGImage")
        XCTAssertGreaterThan(firstApplyMutationCount, 0, "首帧必须写入真实图层")
        XCTAssertEqual(probe.layerMutationCount, firstApplyMutationCount,
                       "同 frame 和壁纸再次 apply 不应重复写 CALayer")
    }

    func testWallpaperCacheDeduplicatesSameKeyAndSeparatesDisplayURLAndModificationDate() async throws {
        let probe = BackdropBehaviorProbe()
        let image = makeImage(.systemGreen)
        let cache = WorkbenchWallpaperImageCache { url in
            probe.recordDecode(onMainThread: Thread.isMainThread)
            return image
        }
        let url = URL(fileURLWithPath: "/tmp/vistile-wallpaper-a.jpg")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let original = WorkbenchWallpaperCacheKey(displayID: 10, url: url, modificationDate: date)
        let otherDisplay = WorkbenchWallpaperCacheKey(displayID: 11, url: url, modificationDate: date)
        let otherURL = WorkbenchWallpaperCacheKey(displayID: 10,
                                                  url: URL(fileURLWithPath: "/tmp/vistile-wallpaper-b.jpg"),
                                                  modificationDate: date)
        let changedFile = WorkbenchWallpaperCacheKey(displayID: 10,
                                                     url: url,
                                                     modificationDate: date.addingTimeInterval(1))

        _ = await cache.image(for: original)
        _ = await cache.image(for: original)
        _ = await cache.image(for: otherDisplay)
        _ = await cache.image(for: otherURL)
        _ = await cache.image(for: changedFile)

        XCTAssertEqual(probe.decodeCount, 4,
                       "缓存需合并同一 key，并区分 displayID、URL 和文件修改时间")
    }

    func testConcurrentRequestsForSameKeyShareOneInflightDecode() async throws {
        let probe = BackdropBehaviorProbe()
        let image = makeImage(.systemTeal)
        let cache = WorkbenchWallpaperImageCache { _ in
            probe.recordDecode(onMainThread: Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.05)
            return image
        }
        let key = WorkbenchWallpaperCacheKey(displayID: 22,
                                             url: URL(fileURLWithPath: "/tmp/vistile-concurrent-wallpaper.jpg"),
                                             modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let firstRequest = Task { await cache.image(for: key) }
        let secondRequest = Task { await cache.image(for: key) }

        let firstImage = await firstRequest.value
        let secondImage = await secondRequest.value

        XCTAssertEqual(probe.decodeCount, 1, "同一 key 的并发请求必须共用未完成的解码任务")
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        XCTAssertEqual(ObjectIdentifier(firstImage!), ObjectIdentifier(secondImage!))
    }

    func testWallpaperCacheBoundsRetainedImagesWhenTheWallpaperChangesRepeatedly() async throws {
        let probe = BackdropBehaviorProbe()
        let image = makeImage(.systemPink)
        let cache = WorkbenchWallpaperImageCache { _ in
            probe.recordDecode(onMainThread: Thread.isMainThread)
            return image
        }
        let url = URL(fileURLWithPath: "/tmp/vistile-changing-wallpaper.jpg")
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for change in 0..<24 {
            let key = WorkbenchWallpaperCacheKey(displayID: 23,
                                                 url: url,
                                                 modificationDate: baseDate.addingTimeInterval(Double(change)))
            _ = await cache.image(for: key)
            XCTAssertLessThanOrEqual(cache.cachedImageCount, 8,
                                     "壁纸频繁更换时缓存项数必须有界")
        }

        XCTAssertEqual(cache.cachedImageCount, 8)
        XCTAssertEqual(probe.decodeCount, 24)
    }

    func testWallpaperDecodeRunsOffMainThread() async throws {
        let probe = BackdropBehaviorProbe()
        let image = makeImage(.systemOrange)
        let cache = WorkbenchWallpaperImageCache { _ in
            probe.recordDecode(onMainThread: Thread.isMainThread)
            return image
        }
        let key = WorkbenchWallpaperCacheKey(displayID: 12,
                                             url: URL(fileURLWithPath: "/tmp/vistile-wallpaper.jpg"),
                                             modificationDate: Date(timeIntervalSince1970: 1_700_000_000))

        _ = await cache.image(for: key)

        XCTAssertEqual(probe.decodeThreads, [false], "图像解码不能占用 MainActor 主线程")
    }

    func testWallpaperKeyChangeUpdatesTheBackdropLayer() throws {
        let frame = CGRect(x: -1200, y: 140, width: 1200, height: 800)
        let backdrop = WorkbenchBackdropWindow(screenFrame: frame)
        defer { backdrop.close() }
        let probe = BackdropBehaviorProbe()
        backdrop.layerMutationObserver = { probe.recordLayerMutation($0) }
        let url = URL(fileURLWithPath: "/tmp/vistile-wallpaper.jpg")
        let firstKey = WorkbenchWallpaperCacheKey(displayID: 10,
                                                  url: url,
                                                  modificationDate: Date(timeIntervalSince1970: 1_700_000_000))
        let secondKey = WorkbenchWallpaperCacheKey(displayID: 10,
                                                   url: url,
                                                   modificationDate: Date(timeIntervalSince1970: 1_700_000_001))
        let firstContext = WorkbenchBackdropRequestContext(displayID: 10, sessionEpoch: 5, wallpaperKey: firstKey)
        let secondContext = WorkbenchBackdropRequestContext(displayID: 10, sessionEpoch: 5, wallpaperKey: secondKey)
        let firstToken = backdrop.beginWallpaperRequest(for: firstContext)
        let firstImage = makeImage(.systemBlue)
        let secondImage = makeImage(.systemPurple)

        XCTAssertTrue(backdrop.apply(screenFrame: frame, wallpaperCGImage: firstImage, requestToken: firstToken))
        let secondToken = backdrop.beginWallpaperRequest(for: secondContext)
        XCTAssertTrue(backdrop.apply(screenFrame: frame, wallpaperCGImage: secondImage, requestToken: secondToken))

        XCTAssertEqual(probe.contentImageIDs, [ObjectIdentifier(firstImage), ObjectIdentifier(secondImage)],
                       "文件修改时间变化后必须把新壁纸写入真实图层")
    }

    func testLateWallpaperResultCannotReplaceNewDisplayOrSession() throws {
        let url = URL(fileURLWithPath: "/tmp/vistile-wallpaper.jpg")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cases: [(old: WorkbenchBackdropRequestContext, current: WorkbenchBackdropRequestContext)] = [
            (WorkbenchBackdropRequestContext(displayID: 10, sessionEpoch: 5,
                                             wallpaperKey: WorkbenchWallpaperCacheKey(displayID: 10, url: url, modificationDate: date)),
             WorkbenchBackdropRequestContext(displayID: 11, sessionEpoch: 5,
                                             wallpaperKey: WorkbenchWallpaperCacheKey(displayID: 11, url: url, modificationDate: date))),
            (WorkbenchBackdropRequestContext(displayID: 10, sessionEpoch: 5,
                                             wallpaperKey: WorkbenchWallpaperCacheKey(displayID: 10, url: url, modificationDate: date)),
             WorkbenchBackdropRequestContext(displayID: 10, sessionEpoch: 6,
                                             wallpaperKey: WorkbenchWallpaperCacheKey(displayID: 10, url: url, modificationDate: date)))
        ]

        for (oldContext, currentContext) in cases {
            let frame = CGRect(x: -1200, y: 140, width: 1200, height: 800)
            let backdrop = WorkbenchBackdropWindow(screenFrame: frame)
            defer { backdrop.close() }
            let probe = BackdropBehaviorProbe()
            backdrop.layerMutationObserver = { probe.recordLayerMutation($0) }
            let oldToken = backdrop.beginWallpaperRequest(for: oldContext)
            let currentToken = backdrop.beginWallpaperRequest(for: currentContext)
            let currentImage = makeImage(.systemGreen)
            let lateImage = makeImage(.systemRed)

            XCTAssertTrue(backdrop.apply(screenFrame: frame,
                                         wallpaperCGImage: currentImage,
                                         requestToken: currentToken))
            XCTAssertFalse(backdrop.apply(screenFrame: frame,
                                          wallpaperCGImage: lateImage,
                                          requestToken: oldToken),
                           "display/session 已变化时必须拒绝迟到结果")
            XCTAssertEqual(probe.contentImageIDs, [ObjectIdentifier(currentImage)],
                           "迟到结果不得覆盖当前真实图层内容")
        }
    }

    private func makeImage(_ color: NSColor) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: 4,
                                      pixelsHigh: 4,
                                      bitsPerSample: 8,
                                      samplesPerPixel: 4,
                                      hasAlpha: true,
                                      isPlanar: false,
                                      colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0,
                                      bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage!
    }
}

private final class BackdropBehaviorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var decodeThreadsStorage: [Bool] = []
    private var layerMutationCountStorage = 0
    private var contentImageIDsStorage: [ObjectIdentifier] = []

    var decodeCount: Int { withLock { decodeThreadsStorage.count } }
    var decodeThreads: [Bool] { withLock { decodeThreadsStorage } }
    var layerMutationCount: Int { withLock { layerMutationCountStorage } }
    var contentImageIDs: [ObjectIdentifier] { withLock { contentImageIDsStorage } }

    func recordDecode(onMainThread: Bool) {
        withLock { decodeThreadsStorage.append(onMainThread) }
    }

    func recordLayerMutation(_ mutation: WorkbenchBackdropLayerMutation) {
        withLock {
            layerMutationCountStorage += 1
            if case let .imageContents(image) = mutation, let image {
                contentImageIDsStorage.append(ObjectIdentifier(image))
            }
        }
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
