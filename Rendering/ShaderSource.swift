import Foundation
import Metal

/// 卡片绘制用的最小内联着色器集合。用 makeLibrary(source:) 编译，
/// 避免为预览管线引入额外的 shader build target。
enum ShaderSource {
    /// 与 GPU 共享的绘制参数：tint 为预乘强度，uvRect 表达内容区在纹理中的归一化范围，
    /// rectSize 是本次视口的像素尺寸（把 uv 还原成像素坐标），cornerRadius 是圆角半径（像素）。
    struct DrawUniforms: Sendable {
        var tint: SIMD4<Float>
        var uvRect: SIMD4<Float>
        /// 视口像素尺寸：纯色面要按它把 0…1 的 uv 还原成像素，才能算圆角距离场。
        var rectSize: SIMD2<Float>
        /// 圆角半径（像素）。0 = 直角，走不额外计算距离场的快路径。
        var cornerRadius: Float

        static func solid(tint: SIMD4<Float>, rectSize: SIMD2<Float>, cornerRadius: Float) -> DrawUniforms {
            DrawUniforms(tint: tint, uvRect: SIMD4<Float>(0, 0, 1, 1),
                         rectSize: rectSize, cornerRadius: cornerRadius)
        }

        static func textured(tint: SIMD4<Float>, uvRect: SIMD4<Float>) -> DrawUniforms {
            DrawUniforms(tint: tint, uvRect: uvRect, rectSize: SIMD2<Float>(0, 0), cornerRadius: 0)
        }
    }

    static let text = """
    #include <metal_stdlib>
    using namespace metal;

    struct DrawUniforms {
        float4 tint;
        float4 uvRect;
        float2 rectSize;
        float cornerRadius;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    // 四角：NDC 位置与纹理坐标。CVPixelBuffer 的 y 轴向下，因此 v 需要翻转。
    // 必须放在函数外：MSL 不允许函数体内的自动变量带 constant 地址空间。
    static constant float2 kNDC[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    static constant float2 kUV[4]  = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };

    vertex VertexOut vistile_vertex(uint vid [[vertex_id]]) {
        VertexOut out;
        out.position = float4(kNDC[vid], 0.0, 1.0);
        out.uv = kUV[vid];
        return out;
    }

    // 预乘 alpha：过渡代理与卡片画面可以做短交叉淡化。
    // 圆角用矩形距离场做一次 1px 抗锯齿；cornerRadius = 0 时直接返回，不多算一步。
    fragment float4 vistile_solid(VertexOut vs [[stage_in]],
                                  constant DrawUniforms &u [[buffer(0)]]) {
        float4 color = float4(u.tint.rgb * u.tint.a, u.tint.a);
        if (u.cornerRadius <= 0.0) {
            return color;
        }
        float2 halfSize = u.rectSize * 0.5;
        float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
        // uv 的 y 轴朝上（kUV 把 0 放在上边），距离场对 x/y 对称，方向不影响结果。
        float2 p = vs.uv * u.rectSize;
        float2 q = abs(p - halfSize) - (halfSize - radius);
        float distanceToEdge = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        float coverage = 1.0 - smoothstep(-0.5, 0.5, distanceToEdge);
        return color * coverage;
    }

    fragment float4 vistile_textured(VertexOut vs [[stage_in]],
                                     constant DrawUniforms &u [[buffer(0)]],
                                     texture2d<float> image [[texture(0)]]) {
        constexpr sampler mix_sampler(filter::linear, address::clamp_to_edge);
        float2 coord = u.uvRect.xy + vs.uv * u.uvRect.zw;
        float4 color = image.sample(mix_sampler, coord);
        return float4(color.rgb * color.a * u.tint.a, color.a * u.tint.a);
    }
    """

    private static weak var cachedLibrary: MTLLibrary?

    static func library(on device: MTLDevice) -> MTLLibrary? {
        if let cachedLibrary { return cachedLibrary }
        guard let library = try? device.makeLibrary(source: text, options: nil) else { return nil }
        cachedLibrary = library
        return library
    }
}

/// 管线集合：一条纯色、一条纹理即可覆盖全部卡片与留边。
final class RenderPipelines {
    let solid: MTLRenderPipelineState
    let textured: MTLRenderPipelineState

    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let library = ShaderSource.library(on: device),
              let vertex = library.makeFunction(name: "vistile_vertex"),
              let solidFragment = library.makeFunction(name: "vistile_solid"),
              let texturedFragment = library.makeFunction(name: "vistile_textured") else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = solidFragment
        descriptor.colorAttachments[0].pixelFormat = colorFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let solid = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        let texturedDescriptor = MTLRenderPipelineDescriptor()
        texturedDescriptor.vertexFunction = vertex
        texturedDescriptor.fragmentFunction = texturedFragment
        texturedDescriptor.colorAttachments[0].pixelFormat = colorFormat
        texturedDescriptor.colorAttachments[0].isBlendingEnabled = true
        texturedDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        texturedDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        texturedDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        texturedDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let textured = try? device.makeRenderPipelineState(descriptor: texturedDescriptor) else { return nil }

        self.solid = solid
        self.textured = textured
    }
}
