import Foundation

public enum WallpaperLibrary {
    /// Same library roots as Vivid's catalog: a backup folder or a Steam library.
    public static func projectDirectories(in directory: URL) throws -> [URL] {
        let manager = FileManager.default
        var root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var steam: URL?
        while true {
            if manager.fileExists(
                atPath: root.appendingPathComponent("steamapps/common/wallpaper_engine").path)
            {
                steam = root
                break
            }
            let parent = root.deletingLastPathComponent()
            if parent == root { break }
            root = parent
        }
        let roots: [URL]
        if let steam {
            roots = [
                "steamapps/workshop/content/431960", "Steamapps/Workshop/content/431960",
                "Steamapps/Workshop/Content/431960", "steamapps/Workshop/Content/431960",
                "steamapps/common/wallpaper_engine/projects/defaultprojects",
                "steamapps/common/wallpaper_engine/projects/myprojects",
            ].map { steam.appendingPathComponent($0) }
        } else {
            roots = [directory]
        }
        var paths = Set<URL>()
        for candidate in roots where manager.fileExists(atPath: candidate.path) {
            for project in try manager.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil) {
                if manager.fileExists(atPath: project.appendingPathComponent("project.json").path) {
                    paths.insert(project.resolvingSymlinksInPath())
                }
            }
        }
        return paths.sorted { $0.path < $1.path }
    }
}
