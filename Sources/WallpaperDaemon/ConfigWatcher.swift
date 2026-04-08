import Foundation
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "watcher")

/// Watches ~/.config/wallpaperd/config.json for changes using GCD file descriptor monitoring.
final class ConfigWatcher {

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let onChange: (Config) -> Void

    init(onChange: @escaping (Config) -> Void) {
        self.onChange = onChange
        startWatching()
    }

    deinit {
        stopWatching()
    }

    private func startWatching() {
        let path = Config.configFile.path

        // Ensure config directory and file exist
        let dir = Config.configDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) {
            Config().save()
        }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            log.error("Failed to open config file for watching: \(path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // File was replaced (e.g., editor save-and-rename pattern)
                log.info("Config file replaced, re-establishing watch")
                self.stopWatching()
                // Brief delay to let the new file settle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.startWatching()
                    let config = Config.load()
                    self?.onChange(config)
                }
            } else {
                log.info("Config file modified")
                let config = Config.load()
                self.onChange(config)
            }
        }

        source.setCancelHandler { [fd = fileDescriptor] in
            close(fd)
        }

        source.resume()
        self.source = source
        log.info("Watching config: \(path)")
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
    }
}
