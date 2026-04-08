import Cocoa
import AVFoundation
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "screen")

/// Manages one DesktopWindow per connected screen.
/// Handles screen plug/unplug and resolution changes.
final class ScreenManager {

    private var windowsByScreenID: [CGDirectDisplayID: DesktopWindow] = [:]
    private weak var videoPlayer: VideoPlayerManager?

    func setUp(videoPlayer: VideoPlayerManager) {
        self.videoPlayer = videoPlayer

        // Listen for screen configuration changes (plug/unplug, resolution change, Dock resize)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        reconfigureWindows()
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        for (_, window) in windowsByScreenID {
            window.detachPlayer()
            window.close()
        }
        windowsByScreenID.removeAll()
    }

    /// Attach an AVPlayer to all existing windows
    func attachPlayer(_ player: AVPlayer?) {
        guard let player = player else { return }
        let gravity = videoPlayer?.currentGravity ?? .resizeAspectFill
        for (_, window) in windowsByScreenID {
            window.attachPlayer(player, gravity: gravity)
        }
    }

    // MARK: - Screen Change Handling

    @objc private func screenParametersDidChange(_ notification: Notification) {
        log.info("Screen parameters changed, reconfiguring windows")
        reconfigureWindows()
    }

    private func reconfigureWindows() {
        let currentScreens = NSScreen.screens
        let currentIDs = Set(currentScreens.compactMap { screenID(for: $0) })

        // Remove windows for disconnected screens
        for (id, window) in windowsByScreenID where !currentIDs.contains(id) {
            log.info("Screen \(id) disconnected, removing window")
            window.detachPlayer()
            window.close()
            windowsByScreenID.removeValue(forKey: id)
        }

        // Create or update windows for current screens
        for screen in currentScreens {
            guard let id = screenID(for: screen) else { continue }

            if let existing = windowsByScreenID[id] {
                // Update frame for existing window (resolution may have changed)
                existing.updateFrame(for: screen)
            } else {
                // Create new window for newly connected screen
                log.info("Screen \(id) connected, creating window")
                let window = DesktopWindow(screen: screen)

                // Attach the current player if available
                if let player = videoPlayer?.player {
                    let gravity = videoPlayer?.currentGravity ?? .resizeAspectFill
                    window.attachPlayer(player, gravity: gravity)
                }

                window.showOnDesktop()
                windowsByScreenID[id] = window
            }
        }

        log.info("Now managing \(self.windowsByScreenID.count) screen(s)")
    }

    /// Extract CGDirectDisplayID from NSScreen
    private func screenID(for screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
