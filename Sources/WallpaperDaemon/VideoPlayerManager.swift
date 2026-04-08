import AVFoundation
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "player")

/// Manages a single shared AVPlayer for video wallpaper playback.
/// Uses AVMutableComposition to repeat the video N times, so the seek-to-zero
/// stutter only happens every N * duration instead of every loop.
/// Combined with ffmpeg crossfade preprocessing, the loop is virtually invisible.
final class VideoPlayerManager {

    private(set) var player: AVPlayer?
    private(set) var currentGravity: AVLayerVideoGravity = .resizeAspectFill

    private var loopObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var videoPaths: [String] = []
    private var currentIndex: Int = 0
    private var currentURL: URL?

    /// How many times to repeat the video in the composition.
    /// 50 repeats of an 8s video = ~350s between seeks = ~6 minutes.
    private let repeatCount = 50

    // MARK: - Playback Control

    func play(url: URL, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        stop()
        currentGravity = gravity
        currentURL = url

        let composition = createRepeatedComposition(from: url)
        let item: AVPlayerItem
        if let composition = composition {
            item = AVPlayerItem(asset: composition)
        } else {
            item = AVPlayerItem(url: url)
        }

        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .none
        self.player = player

        // Loop: seek back to zero when composition ends
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak player] _ in
            guard let player = player else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
            log.info("Loop reset")
        }

        // Watchdog: check every 10s that playback hasn't stalled
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkPlaybackHealth()
        }

        player.play()
        let label = composition != nil ? "composition x\(repeatCount)" : "fallback"
        log.info("Playing (\(label)): \(url.lastPathComponent)")
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
        currentURL = nil
    }

    func nextVideo() {
        guard !videoPaths.isEmpty else { return }
        currentIndex = (currentIndex + 1) % videoPaths.count
        let path = videoPaths[currentIndex]
        if FileManager.default.fileExists(atPath: path) {
            play(url: URL(fileURLWithPath: path), gravity: currentGravity)
        }
    }

    func loadPlaylist(_ paths: [String]) {
        videoPaths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        currentIndex = 0
    }

    deinit { stop() }

    // MARK: - Health Check

    private func checkPlaybackHealth() {
        guard let player = player else { return }

        // If player rate is 0 (paused/stalled) but we expect it to be playing, restart
        if player.rate == 0 {
            if player.currentItem?.status == .failed {
                log.warning("Player item failed, restarting from scratch")
                if let url = currentURL {
                    play(url: url, gravity: currentGravity)
                }
            } else {
                log.warning("Player stalled (rate=0), resuming")
                player.play()
            }
        }
    }

    // MARK: - Composition

    /// Repeat the video track N times in an AVMutableComposition.
    /// Only the track references are duplicated, not the actual video data.
    private func createRepeatedComposition(from url: URL) -> AVMutableComposition? {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            log.error("No video track in asset")
            return nil
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            log.error("Failed to add composition track")
            return nil
        }

        let duration = asset.duration
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        for i in 0..<repeatCount {
            let insertTime = CMTimeMultiply(duration, multiplier: Int32(i))
            do {
                try compositionTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)
            } catch {
                log.error("Failed to insert segment \(i): \(error.localizedDescription)")
                return nil
            }
        }

        compositionTrack.preferredTransform = videoTrack.preferredTransform
        return composition
    }
}
