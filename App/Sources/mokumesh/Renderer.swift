// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import IOSurface
import Metal
import MokumeshLink
import MokumeshMapping
import QuartzCore
import simd

/// 届いた絵を、領域ごとに 4 点合わせで歪めて drawable へ描く。
///
/// 領域の矩形をそのまま覆う四角形を描き、断片ごとに逆の射影変換で絵の座標を求めて取る。
/// 四角形の外 (絵の外) は黒にする。`bgra8Unorm_srgb` の drawable へ線形の値で書く
/// (層の色空間は Display P3)。
///
/// | 来た道 | 読み方 | alpha |
/// | --- | --- | --- |
/// | 専用の受け渡し | 面を `rgba8Unorm_srgb` で読む (線形で補間される) | straight なので黒の上へ `rgb × a` |
/// | Syphon | そのまま読み、断片で sRGB の曲線を外す | 乗算済み (Syphon の慣習) なので `rgb` をそのまま |
@MainActor
final class Renderer {
    static let drawablePixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    /// 面を包んだ texture。面の識別子で引く。面の組が替わると古いものは使われなくなるので、
    /// 溜まりすぎたら捨てる。
    private var textures: [IOSurfaceID: any MTLTexture] = [:]

    struct Uniforms {
        var inverse: simd_float3x3
        var regionOrigin: SIMD2<Float>
        var regionSize: SIMD2<Float>
        var drawableSize: SIMD2<Float>
        /// 1: 断片で sRGB の曲線を外す / 2: 乗算済み
        var flags: UInt32
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.queue = queue
        queue.label = "mokumesh.present"
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "mapVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "mapFragment")
            descriptor.colorAttachments[0].pixelFormat = Self.drawablePixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler
    }

    /// 1 枚の drawable に、領域を全部描く。`frames` は映像の名前で引く。
    ///
    /// 描いた絵 (`SourceFrame`) は投入が終わるまで持ち続ける — 持っている間は受け手が面を
    /// 送り手へ返さないので、GPU が読んでいる途中に上書きされない。
    func draw(
        regions: [MappingConfig.Region], frames: [String: SourceFrame], into layer: CAMetalLayer,
        presented: (@Sendable (_ presentedTime: Double, _ frames: [SourceFrame]) -> Void)? = nil
    ) {
        guard let drawable = layer.nextDrawable(), let commands = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let drawableSize = SIMD2(Float(drawable.texture.width), Float(drawable.texture.height))
        var used: [SourceFrame] = []

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for region in regions {
            guard let frame = frames[region.stream], let homography = region.homography else { continue }
            let texture = frame.texture
            used.append(frame)
            let inverse = homography.inverse
            var uniforms = Uniforms(
                inverse: simd_float3x3(
                    columns: (
                        SIMD3<Float>(inverse.columns.0), SIMD3<Float>(inverse.columns.1),
                        SIMD3<Float>(inverse.columns.2))),
                regionOrigin: SIMD2(Float(region.rect.x), Float(region.rect.y)) * drawableSize,
                regionSize: SIMD2(Float(region.rect.width), Float(region.rect.height)) * drawableSize,
                drawableSize: drawableSize,
                flags: (frame.decodesInShader ? 1 : 0) | (frame.premultiplied ? 2 : 0))
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()

        let holding = used
        if let presented {
            drawable.addPresentedHandler { drawable in
                presented(drawable.presentedTime, holding)
            }
        }
        commands.present(drawable)
        // 投入が終わるまで絵を持つ。終わったら手放し、最後の持ち手が居なくなった面が送り手へ返る
        commands.addCompletedHandler { _ in _ = holding }
        commands.commit()
    }

    /// 専用の受け渡しの面を、`rgba8Unorm_srgb` の texture に包む。面の識別子で覚えておく。
    func texture(for frame: LinkFrame) -> (any MTLTexture)? {
        let id = IOSurfaceGetID(frame.surface)
        if let texture = textures[id], texture.width == frame.width, texture.height == frame.height {
            return texture
        }
        if textures.count > 12 { textures = [:] }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: frame.width, height: frame.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: frame.surface, plane: 0)
        else { return nil }
        textures[id] = texture
        return texture
    }

    private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float3x3 inverse;
            float2 regionOrigin;
            float2 regionSize;
            float2 drawableSize;
            uint flags;
        };

        static float3 decodeSRGB(float3 c) {
            return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
        }

        struct Varyings {
            float4 position [[position]];
            float2 region;
        };

        vertex Varyings mapVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
            const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
            float2 corner = corners[id];
            float2 pixel = u.regionOrigin + corner * u.regionSize;
            Varyings out;
            out.position = float4(
                pixel.x / u.drawableSize.x * 2 - 1, 1 - pixel.y / u.drawableSize.y * 2, 0, 1);
            out.region = corner;
            return out;
        }

        fragment float4 mapFragment(
            Varyings in [[stage_in]], constant Uniforms &u [[buffer(0)]],
            texture2d<float> picture [[texture(0)]], sampler linear [[sampler(0)]]) {
            float3 projected = u.inverse * float3(in.region, 1);
            if (projected.z <= 0) return float4(0, 0, 0, 1);
            float2 uv = projected.xy / projected.z;
            if (any(uv < 0) || any(uv > 1)) return float4(0, 0, 0, 1);
            float4 color = picture.sample(linear, uv);
            if (u.flags & 1) color.rgb = decodeSRGB(color.rgb);
            float3 over = (u.flags & 2) ? color.rgb : color.rgb * color.a;
            return float4(over, 1);
        }
        """
}
