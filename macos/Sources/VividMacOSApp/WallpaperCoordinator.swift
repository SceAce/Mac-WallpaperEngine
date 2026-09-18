import AppKit
import VividMacOSCore

@MainActor
final class WallpaperCoordinator {
    private var controllers: [CGDirectDisplayID: WallpaperWindowController] = [:]
    private let source: WallpaperSource
    private let assetsURL: URL?
    private let muted: Bool
    private var observers: [NSObjectProtocol] = []
    private let onFailure: (Error) -> Void
    private(set) var paused = false

    init(source: WallpaperSource, assetsURL: URL?, muted: Bool, onFailure: @escaping (Error) -> Void) {
        self.source = source
        self.assetsURL = assetsURL
        self.muted = muted
        self.onFailure = onFailure
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated { self?.synchronizeScreens() }
            })
        synchronizeScreens()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for controller in controllers.values { controller.close() }
        controllers.removeAll()
    }

    func validateProbe() -> Bool {
        guard !controllers.isEmpty else { return false }
        return controllers.values.allSatisfy { controller in
            guard let window = controller.window else { return false }
            print(
                "desktop-probe window=\(window.windowNumber) frames=\(controller.completedFrames) size=\(window.frame.size) level=\(window.level.rawValue)"
            )
            return controller.completedFrames > 0 && window.isVisible && !window.isKeyWindow
                && window.ignoresMouseEvents
                && window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow))
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        for controller in controllers.values { controller.setPaused(value) }
    }

    private func synchronizeScreens() {
        guard !observers.isEmpty else { return }
        let visibleScreens = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                screen.displayID.map { ($0, screen) }
            })

        let audioDisplay = NSScreen.screens.first?.displayID
        for (displayID, screen) in visibleScreens {
            let displayMuted = muted || displayID != audioDisplay
            if let controller = controllers[displayID], controller.muted == displayMuted {
                controller.update(screen: screen)
            } else {
                controllers.removeValue(forKey: displayID)?.close()
                do {
                    let controller = try WallpaperWindowController(
                        screen: screen, source: source, assetsURL: assetsURL, muted: displayMuted,
                        onFailure: onFailure)
                    controllers[displayID] = controller
                    controller.setPaused(paused)
                    controller.window?.orderFrontRegardless()
                } catch {
                    onFailure(error)
                    return
                }
            }
        }

        let removedIDs = controllers.keys.filter { visibleScreens[$0] == nil }
        for displayID in removedIDs {
            controllers.removeValue(forKey: displayID)?.close()
        }
    }
}

extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
