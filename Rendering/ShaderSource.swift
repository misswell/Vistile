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

    /// 切换流光的共享参数。axis 是面板本地的飞行方向（y 向上、已归一化）；
    /// phase 推进光带中心，intensity/settle 由 CPU 侧的速度与呼吸包络给出。
    struct FlowUniforms: Sendable {
        var axis: SIMD2<Float>
        var phase: Float
        /// 垂直飞行轴的半宽（归一化到面板短边，0…0.5）：快时窄、减速后展开。
        var bandWidth: Float
        /// 沿轴拖尾长度（归一化）：速度越快拖得越长。
        var trail: Float
        var intensity: Float
        /// 0 = 纯扫掠光带，1 = 完全展开为到达时的径向柔光。
        var settle: Float
        var colorA: SIMD4<Float>
        var colorB: SIMD4<Float>
        var rectSize: SIMD2<Float>
        var cornerRadius: Float

        static func blank(rectSize: SIMD2<Float>) -> FlowUniforms {
            FlowUniforms(axis: SIMD2<Float>(1, 0), phase: 0, bandWidth: 0.1, trail: 0.35,
                         intensity: 0, settle: 0, colorA: SIMD4<Float>(1, 1, 1, 1),
                         colorB: SIMD4<Float>(1, 1, 1, 1), rectSize: rectSize, cornerRadius: 0)
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

    struct FlowUniforms {
        float2 axis;
        float phase;
        float bandWidth;
        float trail;
        float intensity;
        float settle;
        float4 colorA;
        float4 colorB;
        float2 rectSize;
        float cornerRadius;
    };

    // 切换流光：叠加在飞行面板之上的定向光带。
    // 形态由三部分混合——沿飞行方向扫过的各向异性高斯光带（前缘陡、尾缘长的能量拖尾）、
    // 垂直方向收窄的横向辉光、到达段从光带展开的径向柔光（水滴落定）。
    // 输出预乘色并配加法混合管线：光只增不遮，面板本身的填充与描边仍由下层决定。
    fragment float4 vistile_flow(VertexOut vs [[stage_in]],
                                 constant FlowUniforms &u [[buffer(0)]]) {
        if (u.intensity <= 0.001) { return float4(0.0); }
        float2 halfSize = u.rectSize * 0.5;
        float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
        float2 p = vs.uv * u.rectSize;
        float2 q = abs(p - halfSize) - (halfSize - radius);
        float distanceToEdge = length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
        float mask = 1.0 - smoothstep(-0.5, 0.5, distanceToEdge);
        if (mask <= 0.0) { return float4(0.0); }

        // 面板内归一化坐标（-1…1，各按半轴），s 沿飞行方向、t 垂直。
        float2 rel = (p - halfSize) / halfSize;
        float s = dot(rel, u.axis);
        float t = rel.x * (-u.axis.y) + rel.y * u.axis.x;

        // 扫掠光带：中心沿 s 从 -1 推到 +1，前缘锐、尾缘拖出能量。
        float center = mix(-1.0, 1.0, clamp(u.phase, 0.0, 1.0));
        float ds = (s - center) / max(0.05, u.trail);
        float leading = exp(-ds * ds * 2.0);
        float trailing = exp(-ds * ds * 0.5);
        float along = s < center ? trailing : leading;
        float across = exp(-(t * t) / max(0.004, u.bandWidth * u.bandWidth * 4.0));
        float band = along * across;

        // 到达段：光带让位给从中心涌出的径向柔光，半径随 settle 扩张。
        float r = length(rel);
        float bloomRadius = 0.30 + 0.55 * u.settle;
        float bloom = exp(-(r * r) / (bloomRadius * bloomRadius)) * u.settle;

        float energy = band * (1.0 - 0.65 * u.settle) + bloom;
        float3 rgb = mix(u.colorB.rgb, u.colorA.rgb, clamp(0.5 + 0.5 * s, 0.0, 1.0));
        float alpha = clamp(energy * u.intensity, 0.0, 1.0) * mask;
        return float4(rgb * alpha, alpha);
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

/// 管线集合：纯色、纹理与流光三条。流光用加法混合（光只增不遮），
/// 与面板的常规预乘 alpha 覆盖互不干扰。
final class RenderPipelines {
    let solid: MTLRenderPipelineState
    let textured: MTLRenderPipelineState
    let flow: MTLRenderPipelineState

    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let library = ShaderSource.library(on: device),
              let vertex = library.makeFunction(name: "vistile_vertex"),
              let solidFragment = library.makeFunction(name: "vistile_solid"),
              let texturedFragment = library.makeFunction(name: "vistile_textured"),
              let flowFragment = library.makeFunction(name: "vistile_flow") else { return nil }

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

        // 流光：加法叠加。src 预乘、dst 直加，alpha 同步相加（clamp 到 1），
        // 光永远只提亮底下的面板与内容，不会遮住它们。
        let flowDescriptor = MTLRenderPipelineDescriptor()
        flowDescriptor.vertexFunction = vertex
        flowDescriptor.fragmentFunction = flowFragment
        flowDescriptor.colorAttachments[0].pixelFormat = colorFormat
        flowDescriptor.colorAttachments[0].isBlendingEnabled = true
        flowDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        flowDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        flowDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        flowDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        guard let flow = try? device.makeRenderPipelineState(descriptor: flowDescriptor) else { return nil }

        self.solid = solid
        self.textured = textured
        self.flow = flow
    }
}
