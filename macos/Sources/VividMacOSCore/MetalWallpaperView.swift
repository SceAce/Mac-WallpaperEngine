import MetalKit

@MainActor
public final class MetalWallpaperView: MTKView, MTKViewDelegate {
    public var onFrameCompleted: (() -> Void)?
    public var onFailure: ((Error) -> Void)?
    private let renderer: DiagnosticRenderer
    private let commandQueue: MTLCommandQueue
    private var rendering = false
    private var redrawPending = false

    public init(source: WallpaperSource, device: MTLDevice) throws {
        renderer = try DiagnosticRenderer(source: source, device: device)
        guard let queue = device.makeCommandQueue() else {
            throw PresentationError.resource("Metal command queue")
        }
        commandQueue = queue
        super.init(frame: .zero, device: device)
        delegate = self
        colorPixelFormat = .bgra8Unorm_srgb
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(source:device:)") }

    public func draw(in view: MTKView) {
        guard !rendering else {
            redrawPending = true
            return
        }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        guard let command = commandQueue.makeCommandBuffer() else {
            onFailure?(PresentationError.resource("Metal command buffer"))
            return
        }
        do {
            try renderer.encode(pass: pass, command: command, size: drawableSize)
        } catch {
            onFailure?(error)
            return
        }
        rendering = true
        // Metal invokes completion on its own queue, even when registration is
        // on MainActor. Explicit Sendable prevents actor-isolation inference.
        command.addCompletedHandler { @Sendable [weak self] buffer in
            let error = buffer.error
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.rendering = false
                if let error {
                    self.onFailure?(error)
                } else {
                    self.onFrameCompleted?()
                }
                if self.redrawPending {
                    self.redrawPending = false
                    self.needsDisplay = true
                }
            }
        }
        command.present(drawable)
        command.commit()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }
}
