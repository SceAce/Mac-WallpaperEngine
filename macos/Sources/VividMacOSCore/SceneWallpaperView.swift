import AppKit
import MetalKit
import VividSceneClient

public struct ScenePlaybackError: LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(_ reason: String) { self.reason = reason }
}

@MainActor
public final class SceneWallpaperView: MTKView, MTKViewDelegate {
    public var onFrameCompleted: (() -> Void)?
    public var onFailure: ((Error) -> Void)?
    private let project: URL
    private let assets: URL
    private let muted: Bool
    private let cache: URL
    private let presenter: TexturePresenter
    private let commands: MTLCommandQueue
    private var client: VividSceneClient?
    private var pending: VividSceneFrame?
    private var displayed: MTLTexture?
    private var rendering = false
    private var revision = 0
    private var configuredSize = CGSize.zero
    private var pointerTimer: Timer?
    private var lastPointer: SIMD3<Double>?
    private var playbackPaused = false

    public init(project: URL, assets: URL, muted: Bool, device: MTLDevice) throws {
        self.project = project
        self.assets = assets
        self.muted = muted
        cache = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("org.sceace.vivid/scene", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        presenter = try TexturePresenter(device: device)
        guard let commands = device.makeCommandQueue() else {
            throw PresentationError.resource("scene presentation queue")
        }
        self.commands = commands
        super.init(frame: .zero, device: device)
        delegate = self
        colorPixelFormat = .bgra8Unorm_srgb
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Use init(project:assets:device:)") }

    public func configure() {
        guard drawableSize.width > 0, drawableSize.height > 0,
            configuredSize != drawableSize, let device
        else { return }
        stop()
        configuredSize = drawableSize
        let activeRevision = revision
        let client = VividSceneClient(
            device: device,
            onFrame: { [weak self] frame in
                guard let self, self.revision == activeRevision else {
                    frame.releaseFrame()
                    return
                }
                self.pending?.releaseFrame()
                self.pending = frame
                self.needsDisplay = true
            },
            onFailure: { [weak self] reason in
                guard let self, self.revision == activeRevision else { return }
                self.stop()
                self.onFailure?(ScenePlaybackError(reason))
            })
        self.client = client
        client.startProject(
            project, assets: assets, cache: cache,
            width: UInt(drawableSize.width), height: UInt(drawableSize.height), muted: muted)
        if playbackPaused { client.setPaused(true) }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer() }
        }
    }

    public func stop() {
        revision += 1
        pointerTimer?.invalidate()
        pointerTimer = nil
        lastPointer = nil
        client?.stop()
        client = nil
        pending?.releaseFrame()
        pending = nil
        configuredSize = .zero
    }

    private func samplePointer() {
        guard !playbackPaused else { return }
        guard let window, window.frame.width > 0, window.frame.height > 0 else { return }
        let position = NSEvent.mouseLocation
        let x = min(1, max(0, (position.x - window.frame.minX) / window.frame.width))
        let y = min(1, max(0, (window.frame.maxY - position.y) / window.frame.height))
        let left = window.frame.contains(position) && (NSEvent.pressedMouseButtons & 1) != 0
        let pointer = SIMD3<Double>(x, y, left ? 1 : 0)
        guard pointer != lastPointer else { return }
        lastPointer = pointer
        client?.sendPointerX(x, y: y, left: left)
    }

    public func setPaused(_ paused: Bool) {
        playbackPaused = paused
        client?.setPaused(paused)
    }

    public func draw(in view: MTKView) {
        guard !rendering, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let command = commands.makeCommandBuffer()
        else { return }
        let frame = pending
        pending = nil
        do {
            if let frame {
                let source = frame.texture
                if displayed?.width != source.width || displayed?.height != source.height {
                    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: source.pixelFormat, width: source.width, height: source.height,
                        mipmapped: false)
                    descriptor.storageMode = .private
                    descriptor.usage = .shaderRead
                    displayed = device?.makeTexture(descriptor: descriptor)
                }
                guard let displayed, let copy = command.makeBlitCommandEncoder() else {
                    throw PresentationError.resource("scene frame copy")
                }
                copy.copy(
                    from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                    sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                    to: displayed, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
                copy.endEncoding()
            }
            try presenter.encode(
                texture: displayed, clearColor: MTLClearColorMake(0, 0, 0, 1),
                aspectFit: false, pass: pass, command: command, size: drawableSize)
        } catch {
            frame?.releaseFrame()
            stop()
            onFailure?(error)
            return
        }
        rendering = true
        let activeRevision = revision
        command.addCompletedHandler { @Sendable [weak self] buffer in
            let error = buffer.error
            Task { @MainActor [weak self] in
                guard let self else {
                    frame?.releaseFrame()
                    return
                }
                self.rendering = false
                if let error, self.revision == activeRevision {
                    self.stop()
                    self.onFailure?(error)
                } else if frame != nil, self.revision == activeRevision {
                    self.onFrameCompleted?()
                }
                frame?.releaseFrame()
                if self.pending != nil { self.needsDisplay = true }
            }
        }
        command.present(drawable)
        command.commit()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsDisplay = true
    }
}
