import Foundation
import Metal

public struct RuntimeSnapshot: Equatable, Sendable {
    public let machine: String
    public let osMajorVersion: Int
    public let hasMetalDevice: Bool

    public init(machine: String, osMajorVersion: Int, hasMetalDevice: Bool) {
        self.machine = machine
        self.osMajorVersion = osMajorVersion
        self.hasMetalDevice = hasMetalDevice
    }
}

public enum RuntimeRequirementFailure: Equatable, Error, Sendable {
    case appleSiliconRequired(machine: String)
    case macOSVersionRequired(minimum: Int, actual: Int)
    case metalDeviceRequired

    public var message: String {
        switch self {
        case .appleSiliconRequired(let machine):
            return "Vivid macOS requires Apple Silicon (arm64); detected \(machine)."
        case .macOSVersionRequired(let minimum, let actual):
            return "Vivid macOS requires macOS \(minimum) or newer; detected macOS \(actual)."
        case .metalDeviceRequired:
            return "Vivid macOS requires a Metal device."
        }
    }
}

public struct RuntimeEnvironment: Sendable {
    public static let minimumOSMajorVersion = 26

    public let snapshot: RuntimeSnapshot

    public init(snapshot: RuntimeSnapshot) {
        self.snapshot = snapshot
    }

    public static func current() -> RuntimeEnvironment {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
            let machine = "arm64"
        #else
            let machine = "non-arm64"
        #endif
        return RuntimeEnvironment(
            snapshot: RuntimeSnapshot(
                machine: machine,
                osMajorVersion: version.majorVersion,
                hasMetalDevice: MTLCreateSystemDefaultDevice() != nil
            ))
    }

    public func validate(minimumOSMajorVersion: Int = RuntimeEnvironment.minimumOSMajorVersion)
        -> [RuntimeRequirementFailure]
    {
        var failures: [RuntimeRequirementFailure] = []
        if snapshot.machine != "arm64" {
            failures.append(.appleSiliconRequired(machine: snapshot.machine))
        }
        if snapshot.osMajorVersion < minimumOSMajorVersion {
            failures.append(
                .macOSVersionRequired(
                    minimum: minimumOSMajorVersion,
                    actual: snapshot.osMajorVersion
                ))
        }
        if !snapshot.hasMetalDevice {
            failures.append(.metalDeviceRequired)
        }
        return failures
    }
}
