// Loads image files off the main thread, shrunk to the size they are shown at, and keeps them in a
// memory cache. Used by AvatarView and MediaImage. Local files only: nothing here touches the network.

import ImageIO
import SwiftUI
import UIKit

/// Where an image file lives.
enum HearthImageSource: Hashable, Sendable {
    /// Path relative to `HearthPaths.media` (user photos, character pictures, user-made avatars).
    case media(String)
    /// Bundled art name in Resources/Art, e.g. "char-juno".
    case bundled(String)

    var url: URL? {
        switch self {
        case .media(let path): return HearthPaths.mediaURL(path)
        case .bundled(let name): return HearthPaths.bundledArt(name)
        }
    }
}

/// Decoded images by file and size. NSCache is thread-safe; `inFlight` is guarded by `lock`.
final class HearthImageCache: @unchecked Sendable {
    static let shared = HearthImageCache()

    private let cache = NSCache<NSString, UIImage>()
    private let lock = NSLock()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() {
        // Bytes of decoded pixels. Kept modest because the language model needs most of the memory.
        cache.totalCostLimit = 64 * 1024 * 1024
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in
            self?.removeAll()
        }
    }

    /// Rounds a pixel size up to a few fixed steps so one decoded copy serves nearby sizes.
    static func pixelBucket(_ pixels: CGFloat) -> Int {
        let steps = [64, 128, 256, 384, 512, 768, 1024, 1600, 2048]
        guard pixels.isFinite else { return 2048 }
        return steps.first { CGFloat($0) >= pixels } ?? 2048
    }

    static func key(_ source: HearthImageSource, maxPixel: Int) -> String {
        switch source {
        case .media(let path): return "media:\(path)#\(maxPixel)"
        case .bundled(let name): return "art:\(name)#\(maxPixel)"
        }
    }

    /// Instant lookup, safe to call from a view's body.
    func cachedImage(_ source: HearthImageSource, maxPixel: Int) -> UIImage? {
        cache.object(forKey: Self.key(source, maxPixel: maxPixel) as NSString)
    }

    /// Decodes the file off the main thread (once, even if many views ask at the same time).
    /// Returns nil if the file is missing or isn't an image.
    func image(_ source: HearthImageSource, maxPixel: Int) async -> UIImage? {
        let key = Self.key(source, maxPixel: maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }

        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inFlight[key] { return running }
            let started = Task.detached(priority: .userInitiated) { Self.decode(source, maxPixel: maxPixel) }
            inFlight[key] = started
            return started
        }
        let image = await task.value
        lock.withLock { inFlight[key] = nil }
        if let image, let cg = image.cgImage {
            cache.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        return image
    }

    /// Forget every decoded image (for example after "Delete everything", or after overwriting a file).
    func removeAll() {
        cache.removeAllObjects()
    }

    private static func decode(_ source: HearthImageSource, maxPixel: Int) -> UIImage? {
        guard let url = source.url,
              let file = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(file, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

enum HearthImagePhase {
    case loading
    case loaded(UIImage)
    case failed
}

/// Shows a cached or freshly decoded image; `content` decides how each phase looks.
/// A cached image appears on the first frame (no flicker in scrolling grids); a new one fades in.
struct HearthCachedImage<Content: View>: View {
    let source: HearthImageSource?
    let maxPixel: Int
    @ViewBuilder let content: (HearthImagePhase) -> Content

    @State private var result: (key: String, image: UIImage?)?

    var body: some View {
        content(phase)
            .task(id: key) { await load() }
    }

    private var key: String? {
        source.map { HearthImageCache.key($0, maxPixel: maxPixel) }
    }

    private var phase: HearthImagePhase {
        guard let source, let key else { return .failed }
        if let result, result.key == key {
            return result.image.map { .loaded($0) } ?? .failed
        }
        if let hit = HearthImageCache.shared.cachedImage(source, maxPixel: maxPixel) {
            return .loaded(hit)
        }
        return .loading
    }

    private func load() async {
        guard let source, let key,
              HearthImageCache.shared.cachedImage(source, maxPixel: maxPixel) == nil else { return }
        let image = await HearthImageCache.shared.image(source, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            result = (key, image)
        }
    }
}
