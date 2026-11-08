// Where Hearth keeps things on disk. Everything private lives under Application Support/Hearth
// (file protection: complete) and is excluded from iCloud backup when the user wants that.

import Foundation

enum HearthPaths {
    static let fileManager = FileManager.default

    /// Library/Application Support/Hearth
    static var root: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent("Hearth", isDirectory: true))
    }

    static var chats: URL { ensure(root.appendingPathComponent("chats", isDirectory: true)) }
    static var characters: URL { ensure(root.appendingPathComponent("characters", isDirectory: true)) }
    static var media: URL { ensure(root.appendingPathComponent("media", isDirectory: true)) }
    static var models: URL { ensure(root.appendingPathComponent("models", isDirectory: true)) }
    static var state: URL { ensure(root.appendingPathComponent("state", isDirectory: true)) }

    /// Pie's runtime home: Hearth's inferlet as Pie installed it, its compile cache, model recipe files, and
    /// a KV disk tier (cache/kv) Pie may spill pages to under memory pressure (Delete everything empties
    /// that). Disposable, so it lives in Caches: never backed up, and Pie rebuilds what it needs.
    static var pieHome: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return ensure(caches.appendingPathComponent("pie", isDirectory: true))
    }

    /// Documents is used only for developer artifacts (benchmarks, tour screenshots, art, the developer-run
    /// log) and for model files pushed over USB.
    static var documents: URL { fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Creates the directory (and parents) with complete file protection if missing.
    @discardableResult
    static func ensure(_ url: URL) -> URL {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                             attributes: [.protectionKey: FileProtectionType.complete])
        }
        return url
    }

    /// Atomically writes data with complete file protection.
    static func write(_ data: Data, to url: URL) throws {
        ensure(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Marks a file or folder as excluded (or not) from iCloud/iTunes backup.
    static func setExcludedFromBackup(_ excluded: Bool, at url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try? url.setResourceValues(values)
    }

    /// Total bytes used by a directory tree.
    static func size(of url: URL) -> Int64 {
        guard let walker = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// Resolves a media-relative path.
    static func mediaURL(_ relative: String) -> URL { media.appendingPathComponent(relative) }

    /// Bundled art (Resources/Art folder reference), e.g. bundledArt("char-juno") -> Art/char-juno.png.
    static func bundledArt(_ asset: String) -> URL? {
        for ext in ["png", "jpg", "jpeg", "webp", "heic"] {
            if let url = Bundle.main.url(forResource: asset, withExtension: ext, subdirectory: "Art") { return url }
        }
        return nil
    }

    /// The bundled world file.
    static var bundledWorld: URL? { Bundle.main.url(forResource: "lantern-bay", withExtension: "json") }
}
