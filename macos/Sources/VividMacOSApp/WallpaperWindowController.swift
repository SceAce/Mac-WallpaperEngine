import AppKit
import CoreGraphics
import MetalKit
import VividMacOSCore

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WallpaperWindowController: NSWindowController {
    private let wallpaperView: NSView
    private let sceneView: RenderServiceView?
    private let videoView: VideoWallpaperView?
    private var readiness: CheckedContinuation<Void, Error>?
    private var readinessTimeout: Task<Void, Never>?
    private(set) var failureMessage: String?
    private var ready = false
    private var stopped = false
    private let onFailure: (Error) -> Void
    let source: WallpaperSource
    let project: WallpaperProject?
    private(set) var completedFrames = 0

    init(
        screen: NSScreen, source: WallpaperSource, project: WallpaperProject?, assetsURL: URL?,
        settings: PlaybackSettings, onFailure: @escaping (Error) -> Void
    ) throws {
        self.source = source
        self.project = project
        self.onFailure = onFailure
        let diagnosticView: MetalWallpaperView?
        if let project, project.kind == .video {
            let video = VideoWallpaperView(url: project.entry)
            wallpaperView = video
            videoView = video
            sceneView = nil
            diagnosticView = nil

        } else {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw PresentationError.resource("Metal device")
            }
            videoView = nil
            if let project {
                guard
                    project.kind == .web
                        || (assetsURL != nil
                            && FileManager.default.fileExists(
                                atPath: assetsURL!.appendingPathComponent("shaders/common.h").path))
                else {
                    throw ProjectError(
                        "Set the Wallpaper Engine assets directory in Settings, or use --assets.")
                }
                let scene = try RenderServiceView(
                    project: project.contentDirectory, assets: assetsURL ?? project.contentDirectory,
                    muted: settings.muted, device: device, web: project.kind == .web)
                wallpaperView = scene
                sceneView = scene
                diagnosticView = nil
            } else {
                let diagnostic = try MetalWallpaperView(source: source, device: device)
                wallpaperView = diagnostic
                diagnosticView = diagnostic
                sceneView = nil
            }
        }
        let window = WallpaperWindow(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false, screen: screen)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.contentView = wallpaperView
        super.init(window: window)
        diagnosticView?.onFailure = { [weak self] in self?.failed($0) }
        diagnosticView?.onFrameCompleted = { [weak self] in self?.presented() }
        sceneView?.onFailure = { [weak self] in self?.failed($0) }
        sceneView?.onFrameCompleted = { [weak self] in self?.presented() }
        videoView?.onReady = { [weak self] in self?.presented() }
        videoView?.onFailure = { [weak self] in self?.failed($0) }
        apply(settings)
        update(screen: screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(screen:...)") }

    func start(behind old: WallpaperWindowController?) async throws {
        if let oldWindow = old?.window {
            window?.order(.below, relativeTo: oldWindow.windowNumber)
        } else {
            window?.orderFrontRegardless()
        }
        setPaused(false)
        if ready { return }
        try await withCheckedThrowingContinuation { continuation in
            readiness = continuation
            readinessTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.failed(ProjectError("Wallpaper did not produce its first frame within 30 seconds."))
            }
        }
    }

    private func presented() {
        completedFrames += 1
        ready = true
        readinessTimeout?.cancel()
        readinessTimeout = nil
        readiness?.resume()
        readiness = nil
    }

    private func failed(_ error: Error) {
        guard !stopped else { return }
        failureMessage = error.localizedDescription
        readinessTimeout?.cancel()
        readinessTimeout = nil
        if let continuation = readiness {
            readiness = nil
            continuation.resume(throwing: error)
        } else {
            onFailure(error)
        }
    }

    func update(screen: NSScreen) {
        window?.setFrame(screen.frame, display: false)
        if let metalView = wallpaperView as? MTKView {
            metalView.drawableSize = CGSize(
                width: screen.frame.width * screen.backingScaleFactor,
                height: screen.frame.height * screen.backingScaleFactor)
            metalView.needsDisplay = true
        }
        sceneView?.configure()
    }

    func apply(_ settings: PlaybackSettings) {
        sceneView?.apply(settings)
        videoView?.apply(settings)
    }

    override func close() {
        stopped = true
        readinessTimeout?.cancel()
        readinessTimeout = nil
        readiness?.resume(throwing: CancellationError())
        readiness = nil
        sceneView?.stop()
        videoView?.stop()
        super.close()
    }

    func setPaused(_ paused: Bool) {
        sceneView?.setPaused(paused)
        videoView?.setPaused(paused)
    }

    var playbackTime: Double? { videoView?.playbackTime }
}
