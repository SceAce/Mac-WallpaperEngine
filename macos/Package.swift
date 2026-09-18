// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "VividMacOS",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "vivid-macos", targets: ["VividMacOSApp"]),
        .executable(name: "vivid-macos-selftest", targets: ["VividMacOSSelfTest"]),
        .executable(name: "vivid-scene-selftest", targets: ["VividSceneSelfTest"]),
        .library(name: "VividMacOSCore", targets: ["VividMacOSCore"]),
    ],
    targets: [
        .target(
            name: "VividSceneClient",
            path: "Sources/VividSceneClient",
            cSettings: [.unsafeFlags(["-fobjc-arc", "-Wall", "-Wextra", "-Werror"])],
            linkerSettings: [
                .linkedFramework("IOSurface"), .linkedFramework("CoreVideo"), .linkedFramework("Metal"),
            ]
        ),
        .target(
            name: "VividMacOSCore",
            dependencies: ["VividSceneClient"],
            path: "Sources/VividMacOSCore"
        ),
        .executableTarget(
            name: "VividMacOSApp",
            dependencies: ["VividMacOSCore"],
            path: "Sources/VividMacOSApp"
        ),
        .executableTarget(
            name: "VividMacOSSelfTest",
            dependencies: ["VividMacOSCore"],
            path: "Sources/VividMacOSSelfTest"
        ),
        .executableTarget(
            name: "VividSceneSelfTest", dependencies: ["VividSceneClient"],
            path: "Sources/VividSceneSelfTest"),
    ]
)
