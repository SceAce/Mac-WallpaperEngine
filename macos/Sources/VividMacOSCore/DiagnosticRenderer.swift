import MetalKit

public enum PresentationError: LocalizedError {
    case resource(String)
    public var errorDescription: String? {
        switch self {
        case .resource(let name): return "Could not create \(name)."
        }
    }
}

public final class DiagnosticRenderer {
    private let clearColor: MTLClearColor
    private let texture: MTLTexture?
    private let presenter: TexturePresenter

    public init(source: WallpaperSource, device: MTLDevice) throws {
        switch source {
        case .diagnosticColor(let red, let green, let blue):
            clearColor = MTLClearColor(red: red, green: green, blue: blue, alpha: 1)
            texture = nil
        case .image(let url):
            clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            texture = try MTKTextureLoader(device: device).newTexture(
                URL: url,
                options: [.SRGB: true, .origin: MTKTextureLoader.Origin.topLeft, .generateMipmaps: false])
        case .sceneProject:
            throw WallpaperSourceError.sceneRequiresService
        }
        presenter = try TexturePresenter(device: device)
    }

    public func encode(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer, size: CGSize) throws {
        try presenter.encode(
            texture: texture, clearColor: clearColor, aspectFit: true,
            pass: pass, command: command, size: size)
    }
}
