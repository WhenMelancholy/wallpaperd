import AVFoundation
import Foundation
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "config")

/// Configuration for wallpaperd.
/// Loaded from ~/.config/wallpaperd/config.json
struct Config: Codable {
    var videoPaths: [String] = []
    var videoGravity: VideoGravityOption = .fill
    var muted: Bool = true

    enum VideoGravityOption: String, Codable {
        case fill // resizeAspectFill — crops edges to fill screen
        case fit // resizeAspect — letterbox, no cropping
        case stretch // resize — distort to fill

        var avGravity: AVLayerVideoGravity {
            switch self {
            case .fill: .resizeAspectFill
            case .fit: .resizeAspect
            case .stretch: .resize
            }
        }
    }

    // MARK: - File Paths

    static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/wallpaperd", isDirectory: true)
    }

    static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    // MARK: - Load / Save

    static func load() -> Config {
        let file = configFile
        guard FileManager.default.fileExists(atPath: file.path) else {
            log.info("No config file found, creating default at \(file.path)")
            let defaultConfig = Config()
            defaultConfig.save()
            return defaultConfig
        }

        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            log.error("Failed to load config: \(error.localizedDescription)")
            return Config()
        }
    }

    func save() {
        let dir = Config.configDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: Config.configFile)
        } catch {
            log.error("Failed to save config: \(error.localizedDescription)")
        }
    }
}
