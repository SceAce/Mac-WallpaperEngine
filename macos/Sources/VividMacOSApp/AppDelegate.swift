import AppKit
import VividMacOSCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: WallpaperCoordinator?
    private var statusItem: NSStatusItem?
    private let options: LaunchOptions
    private var probeTimer: Timer?
    private(set) var exitCode: Int32 = EXIT_SUCCESS

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = RuntimeEnvironment.current()
            let failures = environment.validate()
            guard failures.isEmpty else {
                throw AppStartupError.requirements(failures)
            }
            coordinator = WallpaperCoordinator(
                source: options.source, assetsURL: options.assetsURL, muted: options.muted
            ) { [weak self] error in
                self?.exitCode = EXIT_FAILURE
                self?.presentStartupError(error)
                NSApplication.shared.terminate(nil)
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Vivid")
            item.button?.toolTip = "Vivid"
            let menu = NSMenu()
            if case .sceneProject = options.source {
                let pause = menu.addItem(
                    withTitle: "Pause", action: #selector(togglePlayback(_:)), keyEquivalent: "")
                pause.target = self
                pause.image = NSImage(systemSymbolName: "pause", accessibilityDescription: nil)
                menu.addItem(.separator())
            }
            menu.addItem(
                withTitle: "Quit Vivid", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
            coordinator?.start()
            if let duration = options.probeDuration {
                probeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
                    [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let passed = self.coordinator?.validateProbe() == true
                        self.exitCode = passed ? EXIT_SUCCESS : EXIT_FAILURE
                        print(passed ? "PASS: desktop probe" : "FAIL: desktop probe")
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        } catch {
            exitCode = EXIT_FAILURE
            presentStartupError(error)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        probeTimer?.invalidate()
        coordinator?.stop()
        if exitCode != EXIT_SUCCESS { exit(exitCode) }
    }

    @objc private func togglePlayback(_ item: NSMenuItem) {
        guard let coordinator else { return }
        coordinator.setPaused(!coordinator.paused)
        item.title = coordinator.paused ? "Resume" : "Pause"
        item.image = NSImage(
            systemSymbolName: coordinator.paused ? "play" : "pause", accessibilityDescription: nil)
    }

    private func presentStartupError(_ error: Error) {
        let message: String
        if let startupError = error as? AppStartupError {
            message = startupError.message
        } else if let sourceError = error as? WallpaperSourceError {
            message = sourceError.message
        } else {
            message = error.localizedDescription
        }
        FileHandle.standardError.write(Data("Vivid: \(message)\n".utf8))
        guard options.probeDuration == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Vivid macOS cannot start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
}

private enum AppStartupError: Error {
    case requirements([RuntimeRequirementFailure])

    var message: String {
        switch self {
        case .requirements(let failures):
            return failures.map(\.message).joined(separator: "\n")
        }
    }
}
