import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import VistileCore

/// 一帧读到的事实。任何一项读不出来就是 nil：缺 status 不许当成完整帧（方案 §10.1）。
struct FrameReadout: Hashable {
    var status: CapturedFrameStatus? = nil
    var pointPixelScale: CGFloat? = nil
    var contentRectInPoints: CGRect? = nil
    var contentScale: CGFloat? = nil
    /// 附件字典本身是否存在：用于区分"系统没给附件"与"附件里缺某个键"。
    var hasAttachmentDictionary: Bool = false
}

/// ScreenCaptureKit 把帧信息挂在 sample attachment 字典（首条）上，
/// 不是 sample 级 CMGetAttachment，所以必须走 CMSampleBufferGetSampleAttachmentsArray（方案 §10.1）。
///
/// 桥接形态不止一种：CGRect/CGSize 可能是 NSValue，也可能是带 X/Y/Width/Height 的字典，
/// 数值可能是 NSNumber 或字符串。这里把形态兼容收敛在一个入口，读不出来就明确返回 nil，
/// 而不是靠未经验证的强转假装拿到了。
enum SampleAttachmentReader {
    static func readout(of sampleBuffer: CMSampleBuffer) -> FrameReadout {
        guard let attachments = attachments(of: sampleBuffer) else {
            return FrameReadout(hasAttachmentDictionary: false)
        }
        return FrameReadout(status: number(attachments[.status]).flatMap { CapturedFrameStatus(rawValue: Int($0)) },
                            pointPixelScale: number(attachments[.scaleFactor]).map { CGFloat($0) },
                            contentRectInPoints: rect(attachments[.contentRect]),
                            contentScale: uniformScale(attachments[.contentScale]),
                            hasAttachmentDictionary: true)
    }

    static func attachments(of sampleBuffer: CMSampleBuffer) -> [SCStreamFrameInfo: Any]? {
        guard let arrays = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                  createIfNecessary: false) as? [[SCStreamFrameInfo: Any]] else {
            return nil
        }
        return arrays.first
    }

    // MARK: - 形态兼容

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    static func rect(_ value: Any?) -> CGRect? {
        // 本机 SDK 的 NSValue 只暴露 rectValue/sizeValue（没有 cgRectValue/cgSizeValue），
        // 而 rectValue 对不认识的编码会直接抛异常，所以必须先按 objCType 编码确认再取。
        if let box = value as? NSValue, matches(box, prefixes: ["{CGRect", "{_NSRect", "{NSRect"]) {
            return box.rectValue
        }
        if let dictionary = dictionary(value) {
            guard let x = number(any(in: dictionary, keys: ["X", "x"])),
                  let y = number(any(in: dictionary, keys: ["Y", "y"])),
                  let width = number(any(in: dictionary, keys: ["Width", "width"])),
                  let height = number(any(in: dictionary, keys: ["Height", "height"])) else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        return nil
    }

    static func size(_ value: Any?) -> CGSize? {
        if let box = value as? NSValue, matches(box, prefixes: ["{CGSize", "{_NSSize", "{NSSize"]) {
            return box.sizeValue
        }
        if let dictionary = dictionary(value) {
            guard let width = number(any(in: dictionary, keys: ["Width", "width"])),
                  let height = number(any(in: dictionary, keys: ["Height", "height"])) else { return nil }
            return CGSize(width: width, height: height)
        }
        return nil
    }

    /// contentScale 按数值解析：单个数字是均匀倍率，成对数字必须一致才敢当倍率用（方案 §10.1）。
    static func uniformScale(_ value: Any?) -> CGFloat? {
        if let scalar = number(value).map({ CGFloat($0) }) { return scalar }
        guard let pair = size(value) else { return nil }
        guard pair.width > 0, abs(pair.width - pair.height) < 0.001 else { return nil }
        return pair.width
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        if let typed = value as? [String: Any] { return typed }
        guard let raw = value as? [AnyHashable: Any] else { return nil }
        var result: [String: Any] = [:]
        for (key, item) in raw {
            if let name = key as? String { result[name] = item }
            if let name = key as? NSString { result[name as String] = item }
        }
        return result
    }

    private static func any(in dictionary: [String: Any], keys: [String]) -> Any? {
        for key in keys { if let value = dictionary[key] { return value } }
        return nil
    }

    private static func matches(_ value: NSValue, prefixes: [String]) -> Bool {
        let encoding = String(cString: value.objCType)
        return prefixes.contains { encoding.hasPrefix($0) }
    }
}
