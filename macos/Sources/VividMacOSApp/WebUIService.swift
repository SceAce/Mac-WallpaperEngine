import AppKit
import VividMacOSCore

/// The child owns HTTP and catalog queries; the app alone owns configuration and playback.
@MainActor
final class WebUIService {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let coordinator: WallpaperCoordinator
    private let onReady: (URL) -> Void
    private let onFailure: (Error) -> Void
    private var buffer = Data()
    private var stopped = false
    private(set) var url: URL?

    init(
        coordinator: WallpaperCoordinator, onReady: @escaping (URL) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.coordinator = coordinator
        self.onReady = onReady
        self.onFailure = onFailure
    }

    func start() throws {
        guard let resources = Bundle.main.resourceURL else { throw ProjectError("Missing WebUI resources.") }
        let script = resources.appendingPathComponent("webui/vivid_webui_server.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw ProjectError("WebUI is missing. Run macos/build-scene.sh and launch Vivid.app.")
        }
        // Python is a documented development dependency; use a deterministic executable.
        let candidates = ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw ProjectError("Python 3 is required for the Vivid panel.")
        }
        process.executableURL = URL(fileURLWithPath: python)
        // Resources in the signed bundle must stay read-only (including Python caches).
        process.arguments = ["-B", "-u", script.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in self?.receive(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.onFailure(ProjectError("WebUI backend exited (\(status))."))
                self.stop()
            }
        }
        try process.run()
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        buffer.append(data)
        guard buffer.count <= 1024 * 1024 else {
            onFailure(ProjectError("WebUI message exceeds 1 MiB."))
            stop()
            return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            do {
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ProjectError("Invalid WebUI control message.")
                }
                if message["event"] as? String == "ready", let address = message["url"] as? String,
                    let url = URL(string: address), url.host == "127.0.0.1", url.scheme == "http"
                {
                    self.url = url
                    print("Vivid panel: \(url.absoluteString)")
                    onReady(url)
                } else {
                    // Each task is actor-isolated; coordinator rejects overlapping mutations.
                    Task { await self.handle(message) }
                }
            } catch {
                onFailure(error)
                stop()
            }
        }
    }

    private func handle(_ request: [String: Any]) async {
        let id = request["id"] as? Int ?? 0
        do {
            let opcode = request["opcode"] as? Int ?? 0
            let payload = request["payload"] as? [String: Any] ?? [:]
            if opcode != 1 {
                let patch: [String: Any]
                switch opcode {
                case 4: patch = ["playing": payload["playing"] ?? payload["value"] ?? true]
                case 5: patch = ["mute": payload["muted"] ?? payload["mute"] ?? payload["value"] ?? false]
                case 6: patch = ["volume": payload["volume"] ?? payload["value"] ?? 100]
                case 7:
                    patch = [
                        "content-fit": payload["content-fit"] ?? payload["contentFit"] ?? payload["value"]
                            ?? coordinator.config["content-fit"] ?? 1
                    ]
                case 8:
                    patch = [
                        "scene-fps": payload["scene-fps"] ?? payload["sceneFps"] ?? payload["value"]
                            ?? coordinator.config["scene-fps"] ?? 30
                    ]
                case 13: patch = payload
                default: throw ProjectError("Unsupported control opcode: \(opcode)")
                }
                try await coordinator.apply(patch)
            }
            try send(["id": id, "ok": true, "control": ["opcode": 2, "payload": coordinator.snapshot()]])
        } catch {
            try? send(["id": id, "ok": false, "error": error.localizedDescription])
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard !stopped else { return }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard data.count <= 1024 * 1024 else { throw ProjectError("Configuration exceeds 1 MiB.") }
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        url = nil
    }
}
