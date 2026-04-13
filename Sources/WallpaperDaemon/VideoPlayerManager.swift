import AVFoundation
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "player")

/// Manages a single shared AVPlayer for video wallpaper playback.
/// Loads video entirely into memory via InMemoryAssetLoader (no continuous disk I/O).
/// Uses AVMutableComposition to repeat the video N times for near-infinite seamless looping.
final class VideoPlayerManager {
    private(set) var player: AVPlayer?
    private(set) var currentGravity: AVLayerVideoGravity = .resizeAspectFill

    private var loopObserver: NSObjectProtocol?
    private var watchdog: Timer?
    private var assetLoader: InMemoryAssetLoader? // Must retain for asset's lifetime
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

        // Load video into memory — no more continuous disk reads
        guard let (memoryAsset, loader) = InMemoryAssetLoader.createAsset(from: url) else {
            log.error("Failed to load video into memory, falling back to disk")
            playFromDisk(url: url, gravity: gravity)
            return
        }
        self.assetLoader = loader

        let composition = createRepeatedComposition(from: memoryAsset)
        let item = if let composition {
            AVPlayerItem(asset: composition)
        } else {
            AVPlayerItem(asset: memoryAsset)
        }

        let player = AVPlayer(playerItem: item)
        configurePlayer(player)
        self.player = player

        setupLoop(item: item, player: player)
        startWatchdog()

        player.play()
        let label = composition != nil ? "in-memory composition x\(self.repeatCount)" : "in-memory"
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
        assetLoader = nil
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

    // MARK: - Private

    /// Fallback: play directly from disk if memory loading fails
    private func playFromDisk(url: URL, gravity: AVLayerVideoGravity) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        configurePlayer(player)
        self.player = player
        setupLoop(item: item, player: player)
        startWatchdog()
        player.play()
        log.info("Playing (disk fallback): \(url.lastPathComponent)")
    }

    private func configurePlayer(_ player: AVPlayer) {
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.actionAtItemEnd = .none
    }

    private func setupLoop(item: AVPlayerItem, player: AVPlayer) {
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            guard let player else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                player.play()
            }
        }
    }

    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.checkPlaybackHealth()
        }
    }

    private func checkPlaybackHealth() {
        guard let player else { return }
        if player.rate == 0 {
            if player.currentItem?.status == .failed {
                log.warning("Player item failed, restarting")
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
    private func createRepeatedComposition(from asset: AVAsset) -> AVMutableComposition? {
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            log.error("No video track in asset")
            return nil
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )
        else {
            log.error("Failed to add composition track")
            return nil
        }

        let duration = asset.duration
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        for i in 0 ..< repeatCount {
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
