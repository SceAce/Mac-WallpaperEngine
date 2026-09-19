import Foundation

/// Resolves a project once, before a renderer is created. Original assets remain read-only.
public struct WallpaperProject: Equatable, Sendable {
    public enum Kind: String, Sendable { case scene, video, web }
    public let directory: URL
    public let contentDirectory: URL
    public let entry: URL
    public let kind: Kind
    public let properties: Data
    public let propertyTypes: [String: String]

    public static func load(_ directory: URL, overrides: Data = Data("{}".utf8)) throws -> Self {
        try resolve(directory, overrides: overrides, visited: [])
    }

    private static func resolve(_ directory: URL, overrides: Data, visited: Set<URL>) throws -> Self {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw ProjectError("Wallpaper directory does not exist: \(root.path)")
        }
        guard !visited.contains(root), visited.count < 16 else {
            throw ProjectError("Circular or excessively deep wallpaper dependency: \(root.path)")
        }
        let manifestURL = root.appendingPathComponent("project.json")
        guard
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
                as? [String: Any]
        else {
            throw ProjectError("Invalid project.json: \(manifestURL.path)")
        }
        guard let overrides = try JSONSerialization.jsonObject(with: overrides) as? [String: Any] else {
            throw ProjectError("Wallpaper properties must be a JSON object.")
        }
        if let dependency = manifest["dependency"] as? String,
            let preset = manifest["preset"] as? [String: Any]
        {
            guard !dependency.isEmpty, dependency.allSatisfy({ $0.isNumber }) else {
                throw ProjectError("Invalid wallpaper dependency ID: \(dependency)")
            }
            let base = try resolve(
                root.deletingLastPathComponent().appendingPathComponent(dependency),
                overrides: Data("{}".utf8), visited: visited.union([root]))
            var values = try JSONSerialization.jsonObject(with: base.properties) as! [String: Any]
            for (key, value) in preset where !(value is NSNull) {
                if ["file", "directory", "scenetexture"].contains(base.propertyTypes[key] ?? ""),
                    let path = value as? String, !path.isEmpty, !path.hasPrefix("/")
                {
                    values[key] = try confined(path, to: root).path
                } else {
                    values[key] = value
                }
            }
            for (key, value) in overrides {
                values[key] = (value as? [String: Any])?["value"] ?? value
            }
            return Self(
                directory: root, contentDirectory: base.contentDirectory, entry: base.entry,
                kind: base.kind, properties: try json(values), propertyTypes: base.propertyTypes)
        }
        let filename = manifest["file"] as? String ?? ""
        let declared = (manifest["type"] as? String ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let inferred: String
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "json", "pkg": inferred = "scene"
        case "html", "htm": inferred = "web"
        case "mp4", "mov", "m4v", "webm": inferred = "video"
        default: inferred = ""
        }
        guard let kind = Kind(rawValue: declared.isEmpty ? inferred : declared) else {
            throw ProjectError("Unsupported wallpaper type ‘\(declared)’ in \(root.path)")
        }
        let relative = filename.isEmpty ? (kind == .scene ? "scene.json" : "index.html") : filename
        let entry = try confined(relative, to: root)
        let package = entry.deletingPathExtension().appendingPathExtension("pkg")
        guard
            FileManager.default.fileExists(atPath: entry.path)
                || (kind == .scene && FileManager.default.fileExists(atPath: package.path))
        else {
            throw ProjectError("Wallpaper entry is missing: \(entry.path)")
        }
        let definitions =
            (manifest["general"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
        var values = definitions.compactMapValues { $0["value"] }
        for (key, value) in overrides {
            // The panel may send either raw values or Wallpaper Engine {value: ...} objects.
            values[key] = (value as? [String: Any])?["value"] ?? value
        }
        return Self(
            directory: root, contentDirectory: root, entry: entry, kind: kind, properties: try json(values),
            propertyTypes: definitions.compactMapValues { ($0["type"] as? String)?.lowercased() })
    }

    private static func confined(_ path: String, to root: URL) throws -> URL {
        let result = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), result.path.hasPrefix(root.path + "/") else {
            throw ProjectError("Wallpaper entry escapes its project directory: \(path)")
        }
        return result
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

public struct ProjectError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PlaybackSettings: Equatable, Sendable {
    public var muted: Bool
    public var volume: Double
    public var fit: Int
    public var fps: Int
    public var properties: Data
    public init(
        muted: Bool = false, volume: Double = 1, fit: Int = 1, fps: Int = 30,
        properties: Data = Data("{}".utf8)
    ) {
        self.muted = muted
        self.volume = volume
        self.fit = fit
        self.fps = fps
        self.properties = properties
    }
}
