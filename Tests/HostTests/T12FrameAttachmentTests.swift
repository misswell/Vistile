import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import XCTest
import VistileCore
@testable import Vistile

/// T12：帧元数据的读取入口与单位（方案 §10.1、§10.2）。
///
/// 这里必须用真的 `CMSampleBuffer`：自己造一个"看起来像"的字典只会测到测试自己编的形态。
/// CoreMedia 建一帧、按 SDK 的真实键写进 sample attachment 首条字典，再分两步判定：
/// 先用原始 `[[String: Any]]` 回读确认"系统侧确实有这个键值"，再看产品入口 `SampleAttachmentReader`
/// 能否读到同一事实。前者有、后者没有，就是读取入口选错了（CMGetAttachment 那条路永远拿不到）。
/// SCStream 自己会不会填这些键、填得对不对，属实的机器验收项，这里不冒充。
final class T12FrameAttachmentTests: XCTestCase {
    // MARK: - 真帧构造

    private func makeSampleBuffer(width: Int = 320, height: Int = 200) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let created = CVPixelBufferCreate(kCFAllocatorDefault,
                                          width,
                                          height,
                                          kCVPixelFormatType_32BGRA,
                                          nil,
                                          &pixelBuffer)
        XCTAssertEqual(created, kCVReturnSuccess, "CVPixelBufferCreate 失败：\(created)")
        let imageBuffer = try XCTUnwrap(pixelBuffer)
        var formatDescription: CMFormatDescription?
        let described = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                     imageBuffer: imageBuffer,
                                                                     formatDescriptionOut: &formatDescription)
        XCTAssertEqual(described, noErr, "CMVideoFormatDescriptionCreateForImageBuffer 失败：\(described)")
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: 1.5, preferredTimescale: 600),
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let made = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                      imageBuffer: imageBuffer,
                                                      dataReady: true,
                                                      makeDataReadyCallback: nil,
                                                      refcon: nil,
                                                      formatDescription: try XCTUnwrap(formatDescription),
                                                      sampleTiming: &timing,
                                                      sampleBufferOut: &sampleBuffer)
        XCTAssertEqual(made, noErr, "CMSampleBufferCreateForImageBuffer 失败：\(made)")
        return try XCTUnwrap(sampleBuffer)
    }

    /// 把键值写进 sample attachment 首条字典，并回读原始形态作为"系统侧确有此值"的对照。
    private func attach(_ values: [(SCStreamFrameInfo, Any)], to sampleBuffer: CMSampleBuffer) -> [String: Any] {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) else {
            XCTFail("CoreMedia 没能创建 sample attachment 数组"); return [:]
        }
        let list = array as NSArray
        XCTAssertEqual(list.count, 1, "附件数组的首条才是这一帧的字典")
        guard let pointer = CFArrayGetValueAtIndex(array, 0) else { XCTFail("附件数组里没有字典"); return [:] }
        let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(pointer).takeUnretainedValue() as NSMutableDictionary
        for (key, value) in values { dictionary.setObject(value, forKey: key.rawValue as NSString) }
        let raw = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                          createIfNecessary: false) as? [[String: Any]])?.first ?? [:]
        for (key, _) in values {
            XCTAssertNotNil(raw[key.rawValue], "对照回读也拿不到 \(key.rawValue)：这一条样本没造成功")
        }
        return raw
    }

    // MARK: - 读取入口

    func testStatusRectAndScaleComeFromTheAttachmentDictionary() throws {
        let sampleBuffer = try makeSampleBuffer()
        let rect = CGRect(x: 4, y: 6, width: 150, height: 94)
        let raw = attach([(SCStreamFrameInfo.status, NSNumber(value: SCFrameStatus.complete.rawValue)),
                          (SCStreamFrameInfo.scaleFactor, NSNumber(value: 2.0)),
                          (SCStreamFrameInfo.contentRect, NSValue(rect: rect)),
                          (SCStreamFrameInfo.contentScale, NSNumber(value: 1.5))],
                         to: sampleBuffer)
        XCTAssertNotNil(raw[SCStreamFrameInfo.status.rawValue])

        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        XCTAssertTrue(readout.hasAttachmentDictionary)
        XCTAssertEqual(readout.status, .complete,
                       "status 没从 sample attachment 读到：捕获入口选错了，卡片会一直空白")
        XCTAssertEqual(readout.pointPixelScale, 2)
        XCTAssertEqual(readout.contentRectInPoints, rect)
        XCTAssertEqual(readout.contentScale, 1.5)
    }

    /// 空附件与"有字典但缺键"是两种不同的事实：混在一起就没法判断是系统没给还是读错了键。
    func testMissingAttachmentsAndMissingKeysAreDistinguishable() throws {
        let bare = try makeSampleBuffer()
        let bareReadout = SampleAttachmentReader.readout(of: bare)
        XCTAssertNil(bareReadout.status)

        let half = try makeSampleBuffer()
        attach([(SCStreamFrameInfo.contentRect, NSValue(rect: CGRect(x: 0, y: 0, width: 10, height: 10)))], to: half)
        let halfReadout = SampleAttachmentReader.readout(of: half)
        XCTAssertTrue(halfReadout.hasAttachmentDictionary, "已经有附件字典了，不该报成没有附件")
        XCTAssertNil(halfReadout.status, "字典里没有 status 就是没有：不许当成完整帧")
    }

    /// 只有 complete 能刷新纹理；idle/blank/suspended 保留最后一帧；started 只是开场通知。
    func testEveryFrameStatusMapsToItsOwnTreatment() throws {
        let pairs: [(SCFrameStatus, CapturedFrameStatus)] = [
            (.complete, .complete), (.idle, .idle), (.blank, .blank),
            (.suspended, .suspended), (.started, .started), (.stopped, .stopped),
        ]
        for (system, expected) in pairs {
            let sampleBuffer = try makeSampleBuffer()
            attach([(SCStreamFrameInfo.status, NSNumber(value: system.rawValue))], to: sampleBuffer)
            let readout = SampleAttachmentReader.readout(of: sampleBuffer)
            XCTAssertEqual(readout.status, expected, "\(system) 被读成了别的状态")
            let meta = CapturedFrameMeta(pixelWidth: 320,
                                         pixelHeight: 200,
                                         contentRectInPoints: readout.contentRectInPoints,
                                         pointPixelScale: readout.pointPixelScale ?? 1,
                                         contentScale: readout.contentScale,
                                         sourceSizeInPoints: CGSize(width: 160, height: 100),
                                         status: expected,
                                         isValid: true,
                                         presentTime: 0)
            XCTAssertEqual(meta.shouldUpdateTexture, expected == .complete,
                           "只有 complete 允许换纹理；idle 会把静止画面当成新帧，blank 会把黑屏当画面")
            XCTAssertEqual(meta.keepsLastFrame,
                           expected == .idle || expected == .blank || expected == .suspended)
        }
    }

    /// contentRect 单位是点：算 UV 前必须按 scaleFactor 换成像素，不能直接当像素用。
    func testContentRectIsInPointsAndScalesIntoPixels() throws {
        let sampleBuffer = try makeSampleBuffer(width: 640, height: 400)
        let rectInPoints = CGRect(x: 10, y: 20, width: 300, height: 180)
        attach([(SCStreamFrameInfo.status, NSNumber(value: SCFrameStatus.complete.rawValue)),
                (SCStreamFrameInfo.scaleFactor, NSNumber(value: 2.0)),
                (SCStreamFrameInfo.contentRect, NSValue(rect: rectInPoints))],
               to: sampleBuffer)
        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        let meta = CapturedFrameMeta(pixelWidth: 640,
                                     pixelHeight: 400,
                                     contentRectInPoints: readout.contentRectInPoints,
                                     pointPixelScale: readout.pointPixelScale ?? 1,
                                     contentScale: readout.contentScale,
                                     sourceSizeInPoints: CGSize(width: 320, height: 200),
                                     status: .complete,
                                     isValid: true,
                                     presentTime: 0)
        XCTAssertEqual(meta.contentRectInPixels, CGRect(x: 20, y: 40, width: 600, height: 360))
        XCTAssertEqual(meta.normalizedContentRect,
                       CGRect(x: 20.0 / 640.0, y: 40.0 / 400.0, width: 600.0 / 640.0, height: 360.0 / 400.0))
        XCTAssertEqual(meta.sourceSizeInPoints, CGSize(width: 320, height: 200))
    }

    /// 缺元数据时宁可退回整幅也不猜：零矩形曾被当成"内容占满全帧"，于是 UV 一直偏。
    func testIncompleteMetadataFallsBackInsteadOfGuessing() throws {
        let sampleBuffer = try makeSampleBuffer()
        attach([(SCStreamFrameInfo.status, NSNumber(value: SCFrameStatus.complete.rawValue)),
                (SCStreamFrameInfo.scaleFactor, NSNumber(value: 0))],
               to: sampleBuffer)
        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        let meta = CapturedFrameMeta(pixelWidth: 320,
                                     pixelHeight: 200,
                                     contentRectInPoints: readout.contentRectInPoints,
                                     pointPixelScale: readout.pointPixelScale ?? 1,
                                     contentScale: readout.contentScale,
                                     sourceSizeInPoints: nil,
                                     status: .complete,
                                     isValid: true,
                                     presentTime: 0)
        XCTAssertNil(meta.contentRectInPixels, "没有 contentRect 不许伪造一个零矩形")
        XCTAssertNil(meta.normalizedContentRect)
    }

    // MARK: - 形态兼容

    /// 系统给的形态不止 NSValue：字典形态与字符串数字也要读得出来。
    func testDictionaryAndStringShapesAreAccepted() throws {
        let sampleBuffer = try makeSampleBuffer()
        attach([(SCStreamFrameInfo.status, NSNumber(value: SCFrameStatus.complete.rawValue)),
                (SCStreamFrameInfo.scaleFactor, "2"),
                (SCStreamFrameInfo.contentRect, ["X": 1, "Y": 2, "Width": 30, "Height": 40] as NSDictionary),
                (SCStreamFrameInfo.contentScale, ["Width": 2, "Height": 2] as NSDictionary)],
               to: sampleBuffer)
        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        XCTAssertEqual(readout.status, .complete)
        XCTAssertEqual(readout.pointPixelScale, 2, "字符串数字没读出来")
        XCTAssertEqual(readout.contentRectInPoints, CGRect(x: 1, y: 2, width: 30, height: 40))
        XCTAssertEqual(readout.contentScale, 2)
    }

    /// contentScale 是倍率而不是尺寸：长宽不一致时不能拿它当倍率用。
    func testNonUniformContentScaleIsRejected() throws {
        let sampleBuffer = try makeSampleBuffer()
        attach([(SCStreamFrameInfo.contentScale, NSValue(size: CGSize(width: 2, height: 3)))], to: sampleBuffer)
        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        XCTAssertNil(readout.contentScale, "非均匀倍率被当成缩放系数，画面会被拉变形")
    }

    /// NSValue 编码不符时 rectValue 会抛异常：先按 objCType 判编码，再决定取不取。
    func testMismatchedValueEncodingIsIgnoredRatherThanCrashing() throws {
        let sampleBuffer = try makeSampleBuffer()
        var point = CGPoint(x: 3, y: 4)
        attach([(SCStreamFrameInfo.contentRect, NSValue(bytes: &point, objCType: "{CGPoint=dd}"))],
               to: sampleBuffer)
        let readout = SampleAttachmentReader.readout(of: sampleBuffer)
        XCTAssertNil(readout.contentRectInPoints, "把 CGPoint 的盒子当 CGRect 读：要么崩要么读到错值")
    }
}
