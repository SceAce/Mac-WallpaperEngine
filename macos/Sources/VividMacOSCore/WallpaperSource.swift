import Foundation

public enum WallpaperSource: Equatable, Sendable {
    case diagnosticColor(red: Double, green: Double, blue: Double)
    case image(URL)
    case sceneProject(URL)
    case project(URL)

    public static let diagnosticDefault = WallpaperSource.diagnosticColor(
        red: 0.035,
        green: 0.045,
        blue: 0.060
    )

    public static func commandLine(arguments: [String]) throws -> WallpaperSource {
        try LaunchOptions(arguments: arguments).source
    }
}

public struct LaunchOptions {
    public let source: WallpaperSource
    public let probeDuration: TimeInterval?
    public let assetsURL: URL?
    public let muted: Bool
    public let hasSource: Bool
    public let libraryURL: URL?
    public let configURL: URL?
    public let openPanel: Bool

    public init(arguments: [String]) throws {
        var source: WallpaperSource?
        var duration: TimeInterval?
        var assets: URL?
        var muted = false
        var library: URL?
        var config: URL?
        var panel = true
        var index = 1
        while index < arguments.count {
            let option = arguments[index]
            switch arguments[index] {
            case "--mute":
                muted = true
                index += 1
            case "--no-panel":
                panel = false
                index += 1
            case "--library", "--config":
                guard index + 1 < arguments.count else {
                    throw WallpaperSourceError.missingValue(option: option)
                }
                let url = URL(fileURLWithPath: arguments[index + 1])
                if option == "--library" { library = url } else { config = url }
                index += 2
            case "--assets":
                guard assets == nil, index + 1 < arguments.count else {
                    throw WallpaperSourceError.missingValue(option: option)
                }
                assets = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                index += 2
            case "--image", "--scene", "--project":
                guard source == nil else { throw WallpaperSourceError.multipleSources }
                guard index + 1 < arguments.count else {
                    throw WallpaperSourceError.missingValue(option: option)
                }
                let url = URL(fileURLWithPath: arguments[index + 1])
                source = option == "--image" ? .image(url) : .project(url)
                index += 2
            case "--diagnostic-color":
                guard source == nil else { throw WallpaperSourceError.multipleSources }
                guard index + 3 < arguments.count,
                    let red = Double(arguments[index + 1]),
                    let green = Double(arguments[index + 2]),
                    let blue = Double(arguments[index + 3]),
                    [red, green, blue].allSatisfy({ (0.0...1.0).contains($0) })
                else {
                    throw WallpaperSourceError.invalidDiagnosticColor
                }
                source = .diagnosticColor(red: red, green: green, blue: blue)
                index += 4
            case "--probe-duration":
                guard duration == nil, index + 1 < arguments.count,
                    let seconds = Double(arguments[index + 1]), (1...60).contains(seconds)
                else {
                    throw WallpaperSourceError.invalidProbeDuration
                }
                duration = seconds
                index += 2
            default:
                throw WallpaperSourceError.unknownOption(option)
            }
        }
        hasSource = source != nil
        libraryURL = library
        configURL = config
        openPanel = panel
        self.source = source ?? .diagnosticDefault
        probeDuration = duration
        assetsURL = assets
        self.muted = muted
    }
}

public enum WallpaperSourceError: Equatable, LocalizedError, Sendable {
    case missingValue(option: String)
    case invalidDiagnosticColor
    case sceneRequiresService
    case multipleSources
    case unknownOption(String)
    case invalidProbeDuration

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .missingValue(let option):
            return "Missing value for \(option)."
        case .invalidDiagnosticColor:
            return "Diagnostic color components must be three numbers in the range 0...1."
        case .sceneRequiresService:
            return "Scene playback requires the bundled scene service."
        case .multipleSources:
            return "Specify only one wallpaper source."
        case .unknownOption(let option):
            return "Unknown option: \(option)."
        case .invalidProbeDuration:
            return "Probe duration must be specified once, in seconds between 1 and 60."
        }
    }
}
