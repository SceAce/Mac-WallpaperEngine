import AppKit
import CoreGraphics
import MetalKit
import VividMacOSCore

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperWindowController: NSWindowController {
    private let wallpaperView: MTKView
    private let sceneView: SceneWallpaperView?
    let muted: Bool
    private(set) var completedFrames = 0

    init(
        screen: NSScreen, source: WallpaperSource, assetsURL: URL?, muted: Bool,
        onFailure: @escaping (Error) -> Void
    ) throws {
        self.muted = muted
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PresentationError.resource("Metal device")
        }
        let wallpaperView: MTKView
        let diagnosticView: MetalWallpaperView?
        if case .sceneProject(let project) = source {
            guard let assetsURL else {
                throw ScenePlaybackError("Specify the Wallpaper Engine assets directory with --assets.")
            }
            let scene = try SceneWallpaperView(
                project: project, assets: assetsURL, muted: muted, device: device)
            wallpaperView = scene
            sceneView = scene
            diagnosticView = nil
        } else {
            let diagnostic = try MetalWallpaperView(source: source, device: device)
            wallpaperView = diagnostic
            sceneView = nil
            diagnosticView = diagnostic
        }
        self.wallpaperView = wallpaperView

        let window = WallpaperWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
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
        diagnosticView?.onFailure = onFailure
        diagnosticView?.onFrameCompleted = { [weak self] in self?.completedFrames += 1 }
        sceneView?.onFailure = onFailure
        sceneView?.onFrameCompleted = { [weak self] in self?.completedFrames += 1 }
        update(screen: screen)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(screen: NSScreen) {
        window?.setFrame(screen.frame, display: false)
        wallpaperView.drawableSize = CGSize(
            width: screen.frame.width * screen.backingScaleFactor,
            height: screen.frame.height * screen.backingScaleFactor
        )
        wallpaperView.needsDisplay = true
        sceneView?.configure()
    }

    override func close() {
        sceneView?.stop()
        super.close()
    }

    func setPaused(_ paused: Bool) { sceneView?.setPaused(paused) }
}
