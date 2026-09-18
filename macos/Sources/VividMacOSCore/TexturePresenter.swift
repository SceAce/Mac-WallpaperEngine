import MetalKit

public final class TexturePresenter {
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState

    public init(device: MTLDevice) throws {
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertices")
        descriptor.fragmentFunction = library.makeFunction(name: "sampleImage")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let sampling = MTLSamplerDescriptor()
        sampling.minFilter = .linear
        sampling.magFilter = .linear
        sampling.sAddressMode = .clampToEdge
        sampling.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sampling) else {
            throw PresentationError.resource("Metal sampler")
        }
        self.sampler = sampler
    }

    public func encode(
        texture: MTLTexture?, clearColor: MTLClearColor, aspectFit: Bool,
        pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, size: CGSize
    ) throws {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw PresentationError.resource("Metal render encoder")
        }
        defer { encoder.endEncoding() }
        guard let texture, size.width > 0, size.height > 0 else { return }
        var scale = SIMD2<Float>(1, 1)
        if aspectFit {
            let sourceAspect = Double(texture.width) / Double(texture.height)
            let outputAspect = size.width / size.height
            if sourceAspect > outputAspect {
                scale.y = Float(outputAspect / sourceAspect)
            } else {
                scale.x = Float(sourceAspect / outputAspect)
            }
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct Output { float4 position [[position]]; float2 uv; };
        vertex Output vertices(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            const float2 positions[4] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
            const float2 uv[4] = { {0, 1}, {1, 1}, {0, 0}, {1, 0} };
            return {float4(positions[id] * scale, 0, 1), uv[id]};
        }
        fragment half4 sampleImage(Output in [[stage_in]], texture2d<half> image [[texture(0)]],
                                   sampler sampling [[sampler(0)]]) {
            const half4 pixel = image.sample(sampling, in.uv);
            return half4(pixel.rgb * pixel.a, 1);
        }
        """
}
