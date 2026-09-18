import AppKit
import VividMacOSCore

@main
struct VividMacOSAppMain {
    @MainActor static func main() {
        do {
            let options = try LaunchOptions(arguments: CommandLine.arguments)
            let application = NSApplication.shared
            let delegate = AppDelegate(options: options)
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            withExtendedLifetime(delegate) { application.run() }
            exit(delegate.exitCode)
        } catch {
            FileHandle.standardError.write(Data("Vivid: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
