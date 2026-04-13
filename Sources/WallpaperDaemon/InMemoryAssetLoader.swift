import AVFoundation
import os.log

private let log = Logger(subsystem: "wallpaperd", category: "loader")

/// Custom URL scheme prefix for in-memory video assets.
/// AVPlayer sees "memory-asset://path" and asks our delegate for data
/// instead of reading from disk.
private let memoryScheme = "memory-asset"

/// Loads a video file entirely into memory and serves it to AVPlayer
/// via AVAssetResourceLoaderDelegate, eliminating continuous disk I/O.
final class InMemoryAssetLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let videoData: Data
    private let contentType: String

    /// Initialize with the full video file data.
    init(data: Data, contentType: String = "video/mp4") {
        self.videoData = data
        self.contentType = contentType
        super.init()
    }

    /// Create an AVURLAsset that reads from memory instead of disk.
    /// The caller must retain this InMemoryAssetLoader for the asset's lifetime.
    static func createAsset(from url: URL) -> (AVURLAsset, InMemoryAssetLoader)? {
        guard let data = try? Data(contentsOf: url) else {
            log.error("Failed to read video file into memory: \(url.lastPathComponent)")
            return nil
        }

        log.info("Loaded \(data.count / 1_024)KB into memory from \(url.lastPathComponent)")

        let loader = InMemoryAssetLoader(data: data)

        // Replace the file URL scheme with our custom scheme
        // e.g., file:///path/to/video.mp4 → memory-asset:///path/to/video.mp4
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            log.error("Failed to parse URL components: \(url)")
            return nil
        }
        components.scheme = memoryScheme
        guard let memoryURL = components.url else {
            log.error("Failed to construct memory URL")
            return nil
        }

        let asset = AVURLAsset(url: memoryURL)
        asset.resourceLoader.setDelegate(loader, queue: .global(qos: .userInteractive))

        return (asset, loader)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // Handle content information request (file size, content type)
        if let contentRequest = loadingRequest.contentInformationRequest {
            contentRequest.contentType = contentType
            contentRequest.contentLength = Int64(videoData.count)
            contentRequest.isByteRangeAccessSupported = true
        }

        // Handle data request (serve bytes from memory)
        if let dataRequest = loadingRequest.dataRequest {
            let requestedOffset = Int(dataRequest.requestedOffset)
            let requestedLength = dataRequest.requestedLength

            let start = requestedOffset
            let end = min(start + requestedLength, videoData.count)

            guard start < videoData.count else {
                loadingRequest.finishLoading()
                return true
            }

            let subdata = videoData.subdata(in: start ..< end)
            dataRequest.respond(with: subdata)
            loadingRequest.finishLoading()
        }

        return true
    }
}
