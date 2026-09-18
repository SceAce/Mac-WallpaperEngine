import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import VividSceneClient

@MainActor
final class SceneTest: NSObject, NSApplicationDelegate {
    private var client: VividSceneClient?
    private var timeout: Timer?
    private var frames = 0
    private var samples: [[UInt8]] = []
    private var started = Date()
    private var firstFrameTime: Date?
    private var completed = false
    private var pauseVerified = false
    private var backpressureVerified = false
    private var heldFrames: [VividSceneFrame] = []
    private var captureDuration: TimeInterval = 0
    private var stopped = false
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var commands = device.makeCommandQueue()!
    private var output: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            finish("Usage: vivid-scene-selftest <project directory> <assets directory> <output directory>")
            return
        }
        output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        do { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) } catch {
            finish(error.localizedDescription)
            return
        }
        client = VividSceneClient(
            device: device,
            onFrame: { [weak self] frame in
                self?.receive(frame)
            }, onFailure: { [weak self] reason in self?.finish(reason) })
        let cache = output.appendingPathComponent("cache", isDirectory: true)
        started = Date()
        client?.startProject(
            URL(fileURLWithPath: arguments[1]), assets: URL(fileURLWithPath: arguments[2]),
            cache: cache, width: 960, height: 600, muted: true)
        timeout = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish("Timed out waiting for scene frames") }
        }
    }

    private func receive(_ frame: VividSceneFrame) {
        defer {
            if frames <= 3 && !completed { heldFrames.append(frame) } else { frame.releaseFrame() }
        }
        guard !completed else { return }
        if stopped {
            finish("Frame arrived after stop")
            return
        }
        frames += 1
        if firstFrameTime == nil { firstFrameTime = Date() }
        if frames == 1 || frames == 45 || frames == 90 {
            let captureStart = Date()
            do { try capture(frame.texture) } catch {
                finish(error.localizedDescription)
                return
            }
            captureDuration += Date().timeIntervalSince(captureStart)
        }
        if frames == 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.completed else { return }
                guard self.frames == 3 else {
                    self.finish("Producer overwrote an outstanding frame lease")
                    return
                }
                self.backpressureVerified = true
                for frame in self.heldFrames {
                    frame.releaseFrame()
                    frame.releaseFrame()
                }
                self.heldFrames.removeAll()
            }
        }
        if frames >= 20 && frames <= 95 {
            let phase = Double(frames - 20) / 30.0
            client?.sendPointerX(
                0.5 + 0.35 * cos(phase * .pi),
                y: 0.5 + 0.3 * sin(phase * .pi), left: frames >= 40 && frames < 50)
        }
        if frames == 60 {
            client?.setPaused(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let pausedFrames = self.frames
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, !self.completed else { return }
                    guard self.frames == pausedFrames else {
                        self.finish("Scene rendered while paused")
                        return
                    }
                    self.pauseVerified = true
                    self.client?.setPaused(false)
                }
            }
        }
        if frames == 100 {
            stopped = true
            client?.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.validate() }
        }
    }

    private func capture(_ source: MTLTexture) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
            let command = commands.makeCommandBuffer(), let copy = command.makeBlitCommandEncoder()
        else {
            throw NSError(domain: "SceneTest", code: 1)
        }
        copy.copy(
            from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        copy.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            target.getBytes(
                buffer.baseAddress!, bytesPerRow: source.width * 4,
                from: MTLRegionMake2D(0, 0, source.width, source.height), mipmapLevel: 0)
        }
        samples.append(bytes)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(
            width: source.width, height: source.height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: source.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = output.appendingPathComponent("frame-\(frames).png")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "SceneTest", code: 2) }
    }

    private func validate() {
        guard samples.count == 3, pauseVerified, backpressureVerified, let firstFrameTime else {
            finish("Incomplete frame or lifecycle verification")
            return
        }
        for sample in samples {
            let transparentPixels = stride(from: 3, to: sample.count, by: 4).filter { sample[$0] != 255 }
                .count
            guard transparentPixels == 0 else {
                finish("Opaque desktop scene lost coverage at \(transparentPixels) pixels")
                return
            }
        }
        var colors = Set<UInt32>()
        for i in stride(from: 0, to: samples[2].count, by: 4) {
            colors.insert(
                UInt32(samples[2][i]) << 16 | UInt32(samples[2][i + 1]) << 8 | UInt32(samples[2][i + 2]))
        }
        guard colors.count > 256 else {
            finish("Scene output is blank or lacks image detail")
            return
        }
        var changed = 0
        for i in stride(from: 0, to: samples[0].count, by: 4) {
            if (0..<3).contains(where: { abs(Int(samples[1][i + $0]) - Int(samples[2][i + $0])) > 3 }) {
                changed += 1
            }
        }
        let fps =
            Double(frames - 1) / max(0.001, Date().timeIntervalSince(firstFrameTime) - 2.0 - captureDuration)
        print(
            "scene-test frames=\(frames) colors=\(colors.count) changedPixels=\(changed) fps=\(String(format: "%.1f", fps)) firstFrame=\(String(format: "%.2f", firstFrameTime.timeIntervalSince(started)))s backpressure=pass pause=pass stop=pass"
        )
        guard changed > 20 else {
            finish("Expected an animated scene but sampled frames did not change")
            return
        }
        finish(nil)
    }

    private func finish(_ failure: String?) {
        guard !completed else { return }
        completed = true
        timeout?.invalidate()
        client?.stop()
        heldFrames.removeAll()
        print(failure.map { "FAIL: \($0)" } ?? "PASS: scene playback")
        fflush(stdout)
        exit(failure == nil ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

@main
struct SceneSelfTestMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let test = SceneTest()
        app.delegate = test
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(test) { app.run() }
    }
}
