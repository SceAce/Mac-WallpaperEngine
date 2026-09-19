import Foundation
import Testing

@testable import VividMacOSCore

struct ProjectTests {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func write(_ manifest: [String: Any], at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: directory.appendingPathComponent("project.json"))
    }

    @Test func typeDispatchAndMissingPath() throws {
        try fixture { root in
            try Data([0]).write(to: root.appendingPathComponent("中文视频.mp4"))
            try write(["type": "Video", "file": "中文视频.mp4"], at: root)
            #expect(try WallpaperProject.load(root).kind == .video)
            try write(["type": "Scene", "file": "scene.json"], at: root)
            try Data([0]).write(to: root.appendingPathComponent("scene.pkg"))
            #expect(try WallpaperProject.load(root).kind == .scene)
            #expect(throws: Error.self) { try WallpaperProject.load(root.appendingPathComponent("missing")) }
        }
    }

    @Test func presetResolutionAndOverridePrecedence() throws {
        try fixture { root in
            let base = root.appendingPathComponent("1")
            let preset = root.appendingPathComponent("2")
            try write(
                [
                    "type": "Web", "file": "index.html",
                    "general": [
                        "properties": [
                            "label": ["type": "textinput", "value": "default"],
                            "tint": ["type": "color", "value": "1 1 1"],
                            "background": ["type": "file", "value": ""],
                            "empty": ["type": "file", "value": ""],
                        ]
                    ],
                ], at: base)
            try Data("<html>test</html>".utf8).write(to: base.appendingPathComponent("index.html"))
            try write(
                [
                    "dependency": "1",
                    "preset": ["label": "preset", "tint": NSNull(), "background": "image.png", "empty": ""],
                ], at: preset)
            try Data([0]).write(to: preset.appendingPathComponent("image.png"))
            let project = try WallpaperProject.load(
                preset, overrides: Data(#"{"label":{"value":"edited"}}"#.utf8))
            let values = try JSONSerialization.jsonObject(with: project.properties) as! [String: Any]
            #expect(project.directory.path == preset.path)
            #expect(project.contentDirectory.path == base.path)
            #expect(values["label"] as? String == "edited")
            #expect(values["tint"] as? String == "1 1 1")
            #expect(values["empty"] as? String == "")
            #expect(values["background"] as? String == preset.appendingPathComponent("image.png").path)
            try write(["dependency": "2", "preset": [:]], at: base)
            #expect(throws: Error.self) { try WallpaperProject.load(preset) }
        }
    }

    @Test func entryCannotEscapeProject() throws {
        try fixture { root in
            let project = root.appendingPathComponent("project")
            try Data("outside".utf8).write(to: root.appendingPathComponent("outside.html"))
            for entry in ["../outside.html", root.appendingPathComponent("outside.html").path] {
                try write(["type": "web", "file": entry], at: project)
                #expect(throws: Error.self) { try WallpaperProject.load(project) }
            }
            try FileManager.default.createSymbolicLink(
                at: project.appendingPathComponent("index.html"),
                withDestinationURL: root.appendingPathComponent("outside.html"))
            try write(["type": "web", "file": "index.html"], at: project)
            #expect(throws: Error.self) { try WallpaperProject.load(project) }
        }
    }
}
