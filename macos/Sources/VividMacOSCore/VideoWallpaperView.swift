import AVFoundation
import AppKit

/// AVFoundation owns the media clock, decode surfaces and loop scheduling.
@MainActor
public final class VideoWallpaperView: NSView {
    public var onReady: (() -> Void)?
    public var onFailure: ((Error) -> Void)?
    private let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    private let videoLayer: AVPlayerLayer
    private var observations: [NSKeyValueObservation] = []

    public init(url: URL) {
        player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        videoLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = videoLayer
        observations.append(
            videoLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.videoLayer.isReadyForDisplay else { return }
                    self.onReady?()
                }
            })
        observations.append(
            looper.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.looper.status == .failed else { return }
                    self.onFailure?(
                        self.looper.error ?? ProjectError("AVFoundation could not decode this video."))
                }
            })
        observations.append(
            player.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.player.status == .failed else { return }
                    self.onFailure?(self.player.error ?? ProjectError("Video playback failed."))
                }
            })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(url:)") }

    public func apply(_ settings: PlaybackSettings) {
        player.isMuted = settings.muted
        player.volume = Float(settings.volume)
        videoLayer.videoGravity =
            settings.fit == 1 ? .resizeAspectFill : settings.fit == 2 ? .resizeAspect : .resize
    }

    public func setPaused(_ value: Bool) {
        if value { player.pause() } else { player.play() }
    }

    public func stop() {
        observations.removeAll()
        player.pause()
        looper.disableLooping()
        player.removeAllItems()
        videoLayer.player = nil
    }

    public var playbackTime: Double { player.currentTime().seconds }
}
