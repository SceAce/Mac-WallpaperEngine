import Foundation
import ImageIO
import MetalKit
import UniformTypeIdentifiers
import VividMacOSCore

@main
struct VividMacOSSelfTest {
    static func main() throws {
        checkRuntimeValidation()
        checkSourceParsing()
        try checkMetalRendering()
        print("PASS: VividMacOSCore self-test")
    }

    private static func checkRuntimeValidation() {
        let supported = RuntimeEnvironment(
            snapshot: RuntimeSnapshot(
                machine: "arm64",
                osMajorVersion: 26,
                hasMetalDevice: true
            ))
        precondition(supported.validate().isEmpty)

        let intel = RuntimeEnvironment(
            snapshot: RuntimeSnapshot(
                machine: "x86_64",
                osMajorVersion: 26,
                hasMetalDevice: true
            ))
        precondition(intel.validate() == [.appleSiliconRequired(machine: "x86_64")])

        let incomplete = RuntimeEnvironment(
            snapshot: RuntimeSnapshot(
                machine: "arm64",
                osMajorVersion: 25,
                hasMetalDevice: false
            ))
        precondition(
            incomplete.validate() == [
                .macOSVersionRequired(minimum: 26, actual: 25),
                .metalDeviceRequired,
            ])
    }

    private static func checkSourceParsing() {
        let source = try! WallpaperSource.commandLine(arguments: [
            "vivid-macos", "--image", "/tmp/wallpaper.png",
        ])
        precondition(source == .image(URL(fileURLWithPath: "/tmp/wallpaper.png")))

        do {
            _ = try WallpaperSource.commandLine(arguments: [
                "vivid-macos", "--diagnostic-color", "1.2", "0", "0",
            ])
            preconditionFailure("invalid diagnostic color was accepted")
        } catch {
            // Expected validation failure.
        }
        for arguments in [
            ["app", "--unknown"],
            ["app", "--image", "/tmp/a.png", "--scene", "/tmp/b"],
            ["app", "--probe-duration", "nan"],
        ] {
            do {
                _ = try LaunchOptions(arguments: arguments)
                preconditionFailure("invalid arguments were accepted")
            } catch {}
        }
    }

    private static func checkMetalRendering() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PresentationError.resource("Metal device for the GPU self-test")
        }
        print("GPU: \(device.name)")
        let directory =
            CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputURL = directory.appendingPathComponent("diagnostic-input.png")
        let colors: [[UInt8]] = [
            [128, 64, 32, 255], [0, 255, 0, 255], [0, 0, 255, 255], [128, 128, 128, 255],
        ]
        var input: [UInt8] = []
        for y in 0..<32 {
            for x in 0..<64 { input += colors[(y < 16 ? 0 : 2) + (x < 32 ? 0 : 1)] }
        }
        try saveRGBA(input, width: 64, height: 32, to: inputURL)
        let renderer = try DiagnosticRenderer(source: .image(inputURL), device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor), let command = queue.makeCommandBuffer()
        else {
            throw PresentationError.resource("offscreen GPU target")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        try renderer.encode(pass: pass, command: command, size: CGSize(width: 64, height: 64))
        let completed = DispatchSemaphore(value: 0)
        command.addCompletedHandler { _ in completed.signal() }
        command.commit()
        precondition(completed.wait(timeout: .now() + 10) == .success, "GPU completion timed out")
        if let error = command.error { throw error }
        precondition(command.status == .completed)
        var bgra = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bgra.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: 64 * 4,
                from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        }
        let samples = [
            (16, 24, colors[0]), (48, 24, colors[1]), (16, 40, colors[2]),
            (48, 40, colors[3]), (32, 8, [UInt8](arrayLiteral: 0, 0, 0, 255)),
            (32, 56, [UInt8](arrayLiteral: 0, 0, 0, 255)),
        ]
        for (x, y, rgba) in samples {
            let expected = [rgba[2], rgba[1], rgba[0], rgba[3]]
            for channel in 0..<4 {
                precondition(
                    abs(Int(bgra[(y * 64 + x) * 4 + channel]) - Int(expected[channel])) <= 1,
                    "Pixel mismatch at (\(x), \(y)), channel \(channel): orientation, color or aspect ratio")
            }
        }
        var rgba = bgra
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgba[offset] = bgra[offset + 2]
            rgba[offset + 2] = bgra[offset]
        }
        try saveRGBA(
            rgba, width: 64, height: 64, to: directory.appendingPathComponent("diagnostic-output.png"))
        print("PASS: GPU image orientation, sRGB midtones and aspect ratio; artifacts: \(directory.path)")
    }

    private static func saveRGBA(_ bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard
            let output = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw PresentationError.resource("PNG diagnostic output")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw PresentationError.resource("PNG encoding") }
    }
}
