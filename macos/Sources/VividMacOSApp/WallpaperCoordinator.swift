import AppKit
import VividMacOSCore

@MainActor
final class WallpaperCoordinator {
    static let supportedSettings = [
        "change-wallpaper-directory-path", "assets-path", "mute", "volume", "content-fit", "scene-fps",
        "playing", "current-config-display-key", "primary-display-key", "multi-display-mode",
        "change-wallpaper", "change-wallpaper-mode", "change-wallpaper-interval",
    ]
    private var controllers: [String: WallpaperWindowController] = [:]
    private var pendingControllers: [WallpaperWindowController] = []
    private var observers: [NSObjectProtocol] = []
    private let options: LaunchOptions
    private let configURL: URL
    private let onFailure: (Error) -> Void
    private(set) var config: [String: Any]
    private(set) var lastError: String?
    private var applying = false
    private var screensDirty = false
    private var stopped = false
    private var rotation: Timer?
    private var diagnostic: WallpaperSource?
    var paused: Bool { !(config["playing"] as? Bool ?? true) }

    init(options: LaunchOptions, onFailure: @escaping (Error) -> Void) throws {
        self.options = options
        self.onFailure = onFailure
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        configURL = options.configURL ?? support.appendingPathComponent("org.sceace.vivid/config.json")
        config = Self.defaults()
        if options.probeDuration == nil, FileManager.default.fileExists(atPath: configURL.path) {
            guard
                let stored = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL))
                    as? [String: Any]
            else {
                throw ProjectError("Invalid configuration: \(configURL.path)")
            }
            config.merge(stored) { _, new in new }
        }
        if let library = options.libraryURL { config["change-wallpaper-directory-path"] = library.path }
        if let assets = options.assetsURL { config["assets-path"] = assets.path }
        if options.muted { config["mute"] = true }
        if options.hasSource {
            switch options.source {
            case .project(let url), .sceneProject(let url):
                let key = NSScreen.screens.first?.displayKey ?? "primary"
                var outputs = config["per-output-projects"] as? [String: Any] ?? [:]
                outputs[key] = ["project-path": url.path]
                config["per-output-projects"] = outputs
            default:
                diagnostic = options.source
                config["per-output-projects"] = [String: Any]()
            }
        }
    }

    static func defaults() -> [String: Any] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Pictures/Wallpapers/WallpaperEngine")
        return [
            "change-wallpaper-directory-path": library.path, "assets-path": "",
            "mute": false, "volume": 100, "content-fit": 1, "scene-fps": 30, "playing": true,
            "multi-display-mode": "independent", "per-output-projects": [String: Any](),
            "change-wallpaper": false, "change-wallpaper-mode": 0, "change-wallpaper-interval": 15,
        ]
    }

    func start() async {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.applying {
                        self.screensDirty = true
                        return
                    }
                    await self.restoreScreens()
                }
            })
        do { try await apply([:]) } catch { record(error) }
    }

    private func restoreScreens() async {
        do { try await apply([:], persist: false) } catch { record(error) }
    }

    func stop() {
        stopped = true
        rotation?.invalidate()
        rotation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        pendingControllers.forEach { $0.close() }
        pendingControllers.removeAll()
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }

    func record(_ error: Error) {
        lastError = error.localizedDescription
        onFailure(error)
    }

    func snapshot() -> [String: Any] {
        let primary = NSScreen.screens.first?.displayKey ?? ""
        let outputs: [[String: Any]] = NSScreen.screens.enumerated().map { index, screen in
            let key = screen.displayKey
            var output: [String: Any] = [
                "displayKey": key, "displayName": screen.localizedName, "primary": key == primary,
                "monitorIndex": index, "consumerOutputId": index + 1,
                "x": screen.frame.minX, "y": -screen.frame.maxY,
                "logicalWidth": screen.frame.width, "logicalHeight": screen.frame.height,
                "physicalWidth": screen.frame.width * screen.backingScaleFactor,
                "physicalHeight": screen.frame.height * screen.backingScaleFactor,
                "status": controllers[key] == nil
                    ? "stopped"
                    : controllers[key]?.failureMessage != nil ? "failed" : paused ? "paused" : "playing",
                "completedFrames": controllers[key]?.completedFrames ?? 0,
            ]
            if let time = controllers[key]?.playbackTime, time.isFinite { output["playbackTime"] = time }
            return output
        }
        var result: [String: Any] = [
            "global": config, "outputs": outputs,
            "capabilities": [
                "platform": "macos", "settings": Self.supportedSettings,
                "displayModes": ["independent"], "types": ["scene", "video", "web"],
            ],
            "applying": applying,
        ]
        if let lastError { result["lastError"] = lastError }
        return result
    }

    /// Stage renderers, persist atomically, then commit the screen assignments.
    /// A failed stage leaves both the old windows and persisted configuration intact.
    func apply(_ patch: [String: Any], persist: Bool = true) async throws {
        guard !stopped, !applying else { throw ProjectError("Another wallpaper change is in progress.") }
        applying = true
        defer {
            applying = false
            if screensDirty && !stopped {
                screensDirty = false
                Task { await restoreScreens() }
            }
        }
        var next = patch["reset-defaults"] as? Bool == true ? Self.defaults() : config
        for (key, value) in patch where key != "reset-defaults" { next[key] = value }
        try validate(next, patch: patch)
        let screens = NSScreen.screens
        let keys = Set(screens.map(\.displayKey))
        for key in ["primary-display-key", "current-config-display-key"] {
            if !keys.contains(next[key] as? String ?? "") { next[key] = screens.first?.displayKey ?? "" }
        }
        var entries = next["per-output-projects"] as? [String: [String: Any]] ?? [:]
        for screen in screens
        where entries[screen.displayKey] != nil && entries[screen.displayKey]?["mute"] == nil {
            entries[screen.displayKey]?["mute"] = screen.displayKey != next["primary-display-key"] as? String
        }
        next["per-output-projects"] = entries
        let assets = (next["assets-path"] as? String).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        var replacements: [String: WallpaperWindowController] = [:]
        var settingsByKey: [String: PlaybackSettings] = [:]
        var requested = Set<String>()
        do {
            for screen in screens {
                let key = screen.displayKey
                let entry = entries[key] ?? [:]
                let path = entry["project-path"] as? String ?? ""
                guard !path.isEmpty || diagnostic != nil else { continue }
                requested.insert(key)
                let project: WallpaperProject?
                let source: WallpaperSource
                if !path.isEmpty {
                    let saved = entry["saved-projects"] as? [String: [String: Any]] ?? [:]
                    let overrides = saved[path]?["user-properties"] as? [String: Any] ?? [:]
                    project = try WallpaperProject.load(
                        URL(fileURLWithPath: path),
                        overrides: JSONSerialization.data(withJSONObject: overrides))
                    source = .project(URL(fileURLWithPath: path))
                } else {
                    project = nil
                    source = diagnostic!
                }
                let settings = PlaybackSettings(
                    muted: (next["mute"] as? Bool ?? false) || (entry["mute"] as? Bool ?? false),
                    volume: (next["volume"] as? Double ?? 100) / 100,
                    fit: next["content-fit"] as? Int ?? 1, fps: next["scene-fps"] as? Int ?? 30,
                    properties: project?.properties ?? Data("{}".utf8))
                settingsByKey[key] = settings
                if let existing = controllers[key], existing.failureMessage == nil, existing.source == source,
                    existing.project?.contentDirectory == project?.contentDirectory,
                    existing.project?.entry == project?.entry, existing.project?.kind == project?.kind,
                    config["assets-path"] as? String == next["assets-path"] as? String
                {
                    continue
                }
                var stagingSettings = settings
                stagingSettings.muted = true
                let candidate = try WallpaperWindowController(
                    screen: screen, source: source, project: project,
                    assetsURL: assets, settings: stagingSettings
                ) { [weak self] error in self?.record(error) }
                pendingControllers.append(candidate)
                try await candidate.start(behind: controllers[key])
                guard !stopped else { throw CancellationError() }
                replacements[key] = candidate
            }
            if persist && options.probeDuration == nil {
                try FileManager.default.createDirectory(
                    at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoded = try JSONSerialization.data(
                    withJSONObject: next, options: [.prettyPrinted, .sortedKeys])
                guard encoded.count <= 900_000 else {
                    throw ProjectError("Saved configuration exceeds 900 KiB.")
                }
                try encoded.write(to: configURL, options: .atomic)
            }
        } catch {
            pendingControllers.forEach { $0.close() }
            pendingControllers.removeAll()
            lastError = error.localizedDescription
            throw error
        }
        let rotationChanged =
            (config["change-wallpaper"] as? Bool) != (next["change-wallpaper"] as? Bool)
            || (config["change-wallpaper-interval"] as? Double)
                != (next["change-wallpaper-interval"] as? Double)
        config = next
        lastError = nil
        for (key, replacement) in replacements {
            controllers.removeValue(forKey: key)?.close()
            controllers[key] = replacement
        }
        pendingControllers.removeAll()
        for key in controllers.keys.filter({ !requested.contains($0) || !keys.contains($0) }) {
            controllers.removeValue(forKey: key)?.close()
        }
        for screen in screens {
            let key = screen.displayKey
            controllers[key]?.update(screen: screen)
            if let settings = settingsByKey[key] { controllers[key]?.apply(settings) }
            controllers[key]?.setPaused(paused)
        }
        if rotationChanged || rotation == nil { scheduleRotation() }
    }

    private func validate(_ values: [String: Any], patch: [String: Any]) throws {
        let extra = [
            "per-output-projects", "reset-defaults", "project-browser-sort-key",
            "project-browser-filter-state",
        ]
        for key in patch.keys where !Self.supportedSettings.contains(key) && !extra.contains(key) {
            // Browser preferences have no renderer side effects.
            guard key.hasPrefix("project-browser-") else {
                throw ProjectError("Unsupported macOS setting: \(key)")
            }
        }
        for (key, range) in [
            "volume": 0.0...100.0, "scene-fps": 5.0...240.0, "content-fit": 1.0...3.0,
            "change-wallpaper-mode": 0.0...2.0, "change-wallpaper-interval": 1.0...1440.0,
        ] {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                value.doubleValue.isFinite, range.contains(value.doubleValue),
                value.doubleValue.rounded() == value.doubleValue
            else {
                throw ProjectError("Invalid value for \(key).")
            }
        }
        for key in ["playing", "mute", "change-wallpaper"] {
            guard let value = values[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw ProjectError("\(key) must be true or false.")
            }
        }
        for key in ["change-wallpaper-directory-path", "assets-path"] {
            guard values[key] is String else { throw ProjectError("\(key) must be a path.") }
        }
        guard values["multi-display-mode"] as? String == "independent" else {
            throw ProjectError("macOS currently supports independent playback per display.")
        }
        guard let outputs = values["per-output-projects"] as? [String: [String: Any]] else {
            throw ProjectError("Invalid per-display wallpaper assignments.")
        }
        for entry in outputs.values {
            guard entry["project-path"] == nil || entry["project-path"] is String else {
                throw ProjectError("Invalid project path.")
            }
        }
    }

    private func scheduleRotation() {
        rotation?.invalidate()
        rotation = nil
        guard config["change-wallpaper"] as? Bool == true else { return }
        rotation = Timer.scheduledTimer(
            withTimeInterval: (config["change-wallpaper-interval"] as? Double ?? 15) * 60, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.rotate() }
        }
    }

    private func rotate() async {
        guard !applying, !paused else { return }
        let root = URL(fileURLWithPath: config["change-wallpaper-directory-path"] as? String ?? "")
        do {
            let paths = try WallpaperLibrary.projectDirectories(in: root).map(\.path)
            guard !paths.isEmpty else { return }
            var entries = config["per-output-projects"] as? [String: [String: Any]] ?? [:]
            for screen in NSScreen.screens {
                var entry = entries[screen.displayKey] ?? [:]
                let index = paths.firstIndex(of: entry["project-path"] as? String ?? "") ?? -1
                let mode = config["change-wallpaper-mode"] as? Int ?? 0
                let alternatives = paths.filter { $0 != entry["project-path"] as? String }
                let sequentialIndex =
                    index < 0
                    ? (mode == 1 ? paths.count - 1 : 0)
                    : (index + (mode == 1 ? paths.count - 1 : 1)) % paths.count
                let next = mode == 2 ? (alternatives.randomElement() ?? paths[0]) : paths[sequentialIndex]
                entry["project-path"] = next
                entries[screen.displayKey] = entry
            }
            try await apply(["per-output-projects": entries])
        } catch { record(error) }
    }

    func validateProbe() -> Bool {
        !controllers.isEmpty
            && controllers.values.allSatisfy { controller in
                guard let window = controller.window else { return false }
                print(
                    "desktop-probe window=\(window.windowNumber) frames=\(controller.completedFrames) videoTime=\(controller.playbackTime ?? 0) size=\(window.frame.size)"
                )
                return controller.completedFrames > 0 && window.isVisible && !window.isKeyWindow
                    && window.ignoresMouseEvents
                    && window.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow))
                    && (controller.playbackTime == nil || (controller.playbackTime ?? 0) > 0)
            }
    }
}

extension NSScreen {
    var displayKey: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return localizedName }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
