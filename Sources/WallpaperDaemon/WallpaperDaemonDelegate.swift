import Cocoa
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "daemon")

final class WallpaperDaemonDelegate: NSObject, NSApplicationDelegate {
    private let screenManager = ScreenManager()
    private let videoPlayer = VideoPlayerManager()
    private var configWatcher: ConfigWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("wallpaperd started (pid: \(ProcessInfo.processInfo.processIdentifier))")

        let config = Config.load()
        log.info("Config loaded: \(config.videoPaths.count) video(s), gravity=\(config.videoGravity.rawValue)")

        // Set up screen manager with video player
        screenManager.setUp(videoPlayer: videoPlayer)

        // Start playback
        if let firstVideo = config.videoPaths.first,
           FileManager.default.fileExists(atPath: firstVideo)
        {
            videoPlayer.play(url: URL(fileURLWithPath: firstVideo), gravity: config.videoGravity.avGravity)
            screenManager.attachPlayer(videoPlayer.player)
        } else {
            log.warning("No valid video path in config. Waiting for config update...")
        }

        // Watch config file for changes
        configWatcher = ConfigWatcher { [weak self] newConfig in
            self?.handleConfigUpdate(newConfig)
        }

        // Register signal handlers for control
        installSignalHandlers()

        log.info("wallpaperd ready, \(NSScreen.screens.count) screen(s) detected")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("wallpaperd shutting down")
        videoPlayer.stop()
        screenManager.tearDown()
    }

    // MARK: - Config Update

    private func handleConfigUpdate(_ config: Config) {
        log.info("Config updated")

        if let firstVideo = config.videoPaths.first,
           FileManager.default.fileExists(atPath: firstVideo)
        {
            videoPlayer.play(url: URL(fileURLWithPath: firstVideo), gravity: config.videoGravity.avGravity)
            screenManager.attachPlayer(videoPlayer.player)
        }
    }

    // MARK: - Signal Handlers

    private func installSignalHandlers() {
        // SIGUSR1 = skip to next video
        let usr1Source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        usr1Source.setEventHandler { [weak self] in
            log.info("SIGUSR1 received — next video")
            self?.videoPlayer.nextVideo()
            if let player = self?.videoPlayer.player {
                self?.screenManager.attachPlayer(player)
            }
        }
        usr1Source.resume()
        signal(SIGUSR1, SIG_IGN) // Let DispatchSource handle it

        // SIGUSR2 = reload config
        let usr2Source = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        usr2Source.setEventHandler { [weak self] in
            log.info("SIGUSR2 received — reload config")
            let config = Config.load()
            self?.handleConfigUpdate(config)
        }
        usr2Source.resume()
        signal(SIGUSR2, SIG_IGN)
    }
}
