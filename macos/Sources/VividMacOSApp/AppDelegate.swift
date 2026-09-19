import AppKit
import VividMacOSCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var coordinator: WallpaperCoordinator?
    private var webUI: WebUIService?
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
            let failures = RuntimeEnvironment.current().validate()
            guard failures.isEmpty else {
                throw ProjectError(failures.map(\.message).joined(separator: "\n"))
            }
            let coordinator = try WallpaperCoordinator(options: options) { [weak self] error in
                self?.report(error)
            }
            self.coordinator = coordinator
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Vivid")
            item.button?.toolTip = "Vivid"
            let menu = NSMenu()
            menu.delegate = self
            let panel = menu.addItem(
                withTitle: "打开壁纸面板 / Open Panel", action: #selector(openPanel), keyEquivalent: "")
            panel.target = self
            let pause = menu.addItem(
                withTitle: "暂停 / Pause", action: #selector(togglePlayback(_:)), keyEquivalent: "")
            pause.target = self
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "退出 Vivid / Quit", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q")
            item.menu = menu
            statusItem = item
            if options.probeDuration == nil {
                let webUI = WebUIService(
                    coordinator: coordinator,
                    onReady: { [weak self] url in
                        if self?.options.openPanel == true { NSWorkspace.shared.open(url) }
                    }, onFailure: { [weak self] in self?.report($0) })
                self.webUI = webUI
                try webUI.start()
            }
            Task {
                await coordinator.start()
                if let duration = options.probeDuration {
                    probeTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) {
                        [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            let passed =
                                self.coordinator?.validateProbe() == true && self.exitCode == EXIT_SUCCESS
                            self.exitCode = passed ? EXIT_SUCCESS : EXIT_FAILURE
                            print(passed ? "PASS: desktop probe" : "FAIL: desktop probe")
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }
            }
        } catch {
            exitCode = EXIT_FAILURE
            report(error)
            if options.probeDuration == nil {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Vivid startup error"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        probeTimer?.invalidate()
        webUI?.stop()
        coordinator?.stop()
        if exitCode != EXIT_SUCCESS { exit(exitCode) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let coordinator,
            let playback = menu.items.first(where: { $0.action == #selector(togglePlayback(_:)) })
        {
            playback.title = coordinator.paused ? "继续 / Resume" : "暂停 / Pause"
            statusItem?.button?.toolTip = coordinator.lastError.map { "Vivid: \($0)" } ?? "Vivid"
        }
    }

    @objc private func openPanel() {
        if let url = webUI?.url { NSWorkspace.shared.open(url) }
    }

    @objc private func togglePlayback(_ item: NSMenuItem) {
        guard let coordinator else { return }
        Task {
            do {
                try await coordinator.apply(["playing": coordinator.paused])
                item.title = coordinator.paused ? "继续 / Resume" : "暂停 / Pause"
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("Vivid: \(error.localizedDescription)\n".utf8))
        statusItem?.button?.toolTip = "Vivid: \(error.localizedDescription)"
        if options.probeDuration != nil { exitCode = EXIT_FAILURE }
    }
}
