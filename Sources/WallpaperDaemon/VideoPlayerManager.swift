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
    private var videoPaths: [String] = []
    private var currentIndex: Int = 0

    /// How many times to repeat the video in the composition.
    /// Higher = less frequent stutter, but more memory for the composition metadata.
    /// 50 repeats of an 8s video = ~400s between stutters = ~6.7 minutes.
    private let repeatCount = 50

    // MARK: - Playback Control

    func play(url: URL, gravity: AVLayerVideoGravity = .resizeAspectFill) {
        stop()
        currentGravity = gravity

        // Try composition-based playback first
        if let composition = createRepeatedComposition(from: url) {
            let item = AVPlayerItem(asset: composition)
            let player = AVPlayer(playerItem: item)
            configurePlayer(player)
            self.player = player

            // When the long composition ends, seek back to zero
            loopObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak player] _ in
                player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            player.play()
            log.info("Playing (composition x\(self.repeatCount)): \(url.lastPathComponent)")
        } else {
            // Fallback: plain AVPlayer
            let player = AVPlayer(url: url)
            configurePlayer(player)
            player.actionAtItemEnd = .none
            self.player = player

            if let item = player.currentItem {
                loopObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak player] _ in
                    player?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }

            player.play()
            log.info("Playing (fallback): \(url.lastPathComponent)")
        }
    }

    func stop() {
        if let observer = loopObserver {
            NotificationCenter.default.removeObserver(observer)
            loopObserver = nil
        }
        player?.pause()
        player = nil
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

    // MARK: - Private

    private func configurePlayer(_ player: AVPlayer) {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
    }

    /// Repeat the video track N times in an AVMutableComposition.
    /// The composition metadata is lightweight — only the track references are duplicated,
    /// not the actual video data. The file is read once from disk.
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
        log.info("Composition created: \(self.repeatCount) x \(CMTimeGetSeconds(duration))s = \(CMTimeGetSeconds(duration) * Double(self.repeatCount))s")
        return composition
    }
}
