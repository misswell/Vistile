import Foundation
import Metal
import simd

/// 正在被 GPU 使用的纹理引用集合。command buffer 完成前不能释放，
/// 完成后统一回收（方案 §9.5）。
final class TexturePool: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [UInt64: [MetalFrame]] = [:]
    private var nextBufferID: UInt64 = 1

    /// 为一次绘制登记引用，返回用于完成回调的标识。
    func retain(_ frames: [MetalFrame], for bufferID: UInt64) {
        lock.lock()
        inFlight[bufferID] = frames
        lock.unlock()
    }

    func release(bufferID: UInt64) {
        lock.lock()
        inFlight.removeValue(forKey: bufferID)
        lock.unlock()
    }

    func allocateBufferID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextBufferID &+= 1
        return nextBufferID
    }

    /// 退出总览后必须回到 0，否则说明有引用泄漏。
    var inFlightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.values.reduce(0) { $0 + $1.count }
    }

    var inFlightBufferCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.count
    }

    func dropAll() {
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
    }
}

/// 卡片颜色与强度的最小描述。
struct CardTint {
    var color: SIMD4<Float>
    var opacity: Float

    static let hiddenPlaceholder = CardTint(color: SIMD4<Float>(0.08, 0.08, 0.09, 1), opacity: 1)
}

/// CG 全局坐标（左上原点）到 Metal 绘制坐标的换算。
/// CAMetalLayer 未使用 geometryFlipped，纹理坐标原点在左下，因此需要按整屏高度翻转一次。
enum MetalGeometry {
    static func pixelRect(cgRect: CGRect, containerHeight: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(x: (cgRect.minX * scale).rounded(),
               y: ((containerHeight - cgRect.maxY) * scale).rounded(),
               width: max(1, (cgRect.width * scale).rounded()),
               height: max(1, (cgRect.height * scale).rounded()))
    }

    static func viewport(for rect: CGRect) -> MTLViewport {
        MTLViewport(originX: Double(rect.minX), originY: Double(rect.minY),
                    width: Double(rect.width), height: Double(rect.height),
                    znear: 0, zfar: 1)
    }

    /// 内容区在整张纹理中的归一化范围。缺元数据时退回整幅，绝不猜单位。
    static func uvRect(contentRect: CGRect, pixelSize: CGSize) -> SIMD4<Float> {
        guard pixelSize.width > 0, pixelSize.height > 0,
              contentRect.width > 0, contentRect.height > 0 else {
            return SIMD4<Float>(0, 0, 1, 1)
        }
        let originX = max(0, contentRect.minX) / pixelSize.width
        let originY = max(0, contentRect.minY) / pixelSize.height
        let width = min(1 - originX, contentRect.width / pixelSize.width)
        let height = min(1 - originY, contentRect.height / pixelSize.height)
        guard width > 0, height > 0 else { return SIMD4<Float>(0, 0, 1, 1) }
        return SIMD4<Float>(Float(originX), Float(originY), Float(width), Float(height))
    }
}
