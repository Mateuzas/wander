import ImageIO
import UIKit

/// Loads remote photos (place heroes, thumbnails) with two caches: decoded images in
/// memory, and the HTTP responses on disk via a dedicated `URLCache`, so a photo seen
/// once shows at once next time, even offline. Concurrent requests for the same URL
/// share one download. Failures aren't cached, so a later view retries.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    /// Longest edge a decoded image keeps; enough for a full-width 3x hero.
    private nonisolated static let maxPixelSize: CGFloat = 1400

    private let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 120
        return cache
    }()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 150 << 20,
                                   directory: FileManager.default
                                       .urls(for: .cachesDirectory, in: .userDomainMask).first?
                                       .appendingPathComponent("PlacePhotos", isDirectory: true))
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["User-Agent": "WanderMVP/0.1 (personal walking-route prototype)"]
        return URLSession(configuration: config)
    }()

    /// Already decoded, so a view can show it on its first frame without a placeholder flash.
    func cached(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The image at `url`, decoded and downsampled off the main thread. Nil on any failure.
    func image(for url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        if let running = inFlight[url] { return await running.value }
        let session = session
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.decode(data) }.value
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    /// Downsamples with ImageIO so a 4000 px website image doesn't sit in memory at full size.
    private nonisolated static func decode(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
