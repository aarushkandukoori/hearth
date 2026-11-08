// Parked KV caches on flash: HearthPaths.kvCache/<modelID>/<sha256(key)>.kvstate plus a .json sidecar.
// They hold conversation content, so files get complete protection, skip backups, and old ones are evicted.

import CryptoKit
import Foundation

final class KVStateCache: @unchecked Sendable {
    /// What the .json sidecar next to each .kvstate file records.
    struct Entry: Codable, Hashable, Sendable {
        var key: String
        var tokens: Int
        var bytes: Int64
        var lastUsed: Date
    }

    static let defaultMaxBytes: Int64 = 1_500_000_000
    static let defaultMaxFiles = 16
    /// Free space to leave on the iPhone. Parked states are only a cache, and a full disk breaks saving chats.
    static let defaultMinFreeBytes: Int64 = 1_000_000_000

    let directory: URL
    let maxBytes: Int64
    let maxFiles: Int
    let minFreeBytes: Int64
    private let lock = NSLock()

    init(modelID: String, root: URL = HearthPaths.kvCache,
         maxBytes: Int64 = KVStateCache.defaultMaxBytes, maxFiles: Int = KVStateCache.defaultMaxFiles,
         minFreeBytes: Int64 = KVStateCache.defaultMinFreeBytes) {
        directory = root.appendingPathComponent(Self.folderName(modelID), isDirectory: true)
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
        self.minFreeBytes = minFreeBytes
        ensureFolder()
    }

    /// Makes the folder again if something deleted it while this model stayed loaded ("Delete everything"
    /// keeping the models, or clearing every model's cache), so parking keeps working.
    func ensureFolder() {
        let root = directory.deletingLastPathComponent()
        HearthPaths.ensure(directory)
        HearthPaths.setExcludedFromBackup(true, at: root)
        HearthPaths.setExcludedFromBackup(true, at: directory)
    }

    // MARK: - Paths

    func stateURL(for key: String) -> URL { directory.appendingPathComponent(Self.digest(key) + ".kvstate") }
    func sidecarURL(for key: String) -> URL { directory.appendingPathComponent(Self.digest(key) + ".json") }
    /// Save here first, then `commit`, so a crash mid-save never leaves a half-written state in place.
    func temporaryURL(for key: String) -> URL { directory.appendingPathComponent(Self.digest(key) + ".kvstate.tmp") }

    // MARK: - Reading

    /// The parked state for `key`, if its file is really there.
    func entry(for key: String) -> Entry? {
        lock.withLock { readEntry(sidecarURL(for: key)) }
    }

    /// Every parked state for this model, most recently used first.
    func entries() -> [Entry] {
        lock.withLock { allEntries().map(\.entry).sorted { $0.lastUsed > $1.lastUsed } }
    }

    func totalBytes() -> Int64 {
        lock.withLock { allEntries().reduce(0) { $0 + $1.entry.bytes } }
    }

    // MARK: - Writing

    /// Moves a state saved at `temporaryURL(for:)` into place, protects it, writes the sidecar and
    /// evicts the least recently used states beyond the limits (never the one just saved).
    @discardableResult
    func commit(key: String, tokens: Int) throws -> Entry {
        try lock.withLock {
            let fm = FileManager.default
            let temporary = temporaryURL(for: key)
            let final = stateURL(for: key)
            if fm.fileExists(atPath: final.path) {
                _ = try fm.replaceItemAt(final, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: final)
            }
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: final.path)
            HearthPaths.setExcludedFromBackup(true, at: final)
            let entry = Entry(key: key, tokens: tokens, bytes: ModelCatalog.fileSize(final) ?? 0, lastUsed: .now)
            try writeSidecar(entry)
            evict(keeping: key)
            return entry
        }
    }

    /// Marks a state as just used (so LRU eviction keeps it longer).
    func touch(key: String) {
        lock.withLock {
            guard var entry = readEntry(sidecarURL(for: key)) else { return }
            entry.lastUsed = .now
            try? writeSidecar(entry)
        }
    }

    func remove(key: String) {
        lock.withLock { deleteFiles(digest: Self.digest(key)) }
    }

    /// Deletes every parked state for this model.
    func purge() {
        lock.withLock {
            try? FileManager.default.removeItem(at: directory)
            HearthPaths.ensure(directory)
            HearthPaths.setExcludedFromBackup(true, at: directory)
        }
    }

    /// Removes leftovers: unfinished .tmp saves, states without a sidecar, and sidecars without a state.
    /// Call when the engine starts (not while it may be saving).
    func sweep() {
        lock.withLock {
            let fm = FileManager.default
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
            for name in names {
                let url = directory.appendingPathComponent(name)
                let stem = (name as NSString).deletingPathExtension
                if name.hasSuffix(".tmp") {
                    try? fm.removeItem(at: url)
                } else if name.hasSuffix(".kvstate"), !fm.fileExists(atPath: directory.appendingPathComponent(stem + ".json").path) {
                    try? fm.removeItem(at: url)
                } else if name.hasSuffix(".json"), !fm.fileExists(atPath: directory.appendingPathComponent(stem + ".kvstate").path) {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - Across all models

    /// Bytes used by parked states of every model.
    static func totalBytes(root: URL = HearthPaths.kvCache) -> Int64 { HearthPaths.size(of: root) }

    /// Deletes parked states of every model.
    static func purgeAll(root: URL = HearthPaths.kvCache) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: folder)
        }
    }

    /// Deletes one conversation's parked state under every model (used when a chat is deleted).
    static func removeEverywhere(key: String, root: URL = HearthPaths.kvCache) {
        let fm = FileManager.default
        let digest = digest(key)
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for ext in ["kvstate", "json", "kvstate.tmp"] {
                try? fm.removeItem(at: folder.appendingPathComponent("\(digest).\(ext)"))
            }
        }
    }

    // MARK: - Private (call with `lock` held)

    private func allEntries() -> [(digest: String, entry: Entry)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            let digest = (name as NSString).deletingPathExtension
            return readEntry(directory.appendingPathComponent(name)).map { (digest, $0) }
        }
    }

    private func readEntry(_ sidecar: URL) -> Entry? {
        guard let data = try? Data(contentsOf: sidecar),
              let entry = try? Self.decoder.decode(Entry.self, from: data),
              FileManager.default.fileExists(atPath: stateURL(for: entry.key).path) else { return nil }
        return entry
    }

    private func writeSidecar(_ entry: Entry) throws {
        let url = sidecarURL(for: entry.key)
        try HearthPaths.write(try Self.encoder.encode(entry), to: url)
        HearthPaths.setExcludedFromBackup(true, at: url)
    }

    private func evict(keeping key: String) {
        let keep = Self.digest(key)
        var list = allEntries().sorted { $0.entry.lastUsed < $1.entry.lastUsed } // oldest first
        var total = list.reduce(0) { $0 + $1.entry.bytes }
        // Unknown free space (the volume didn't say) doesn't evict anything by itself.
        var free = minFreeBytes > 0 ? Self.freeBytes(at: directory) : nil
        while total > maxBytes || list.count > maxFiles || (free.map { $0 < minFreeBytes } ?? false) {
            guard let index = list.firstIndex(where: { $0.digest != keep }) else { break }
            let victim = list.remove(at: index)
            deleteFiles(digest: victim.digest)
            total -= victim.entry.bytes
            free = free.map { $0 + victim.entry.bytes }
            HearthLog.info("kv", "evicted a parked state (\(victim.entry.tokens) tokens)")
        }
    }

    /// Space left for important writes on the volume holding `url` (nil if it can't be read).
    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func deleteFiles(digest: String) {
        for ext in ["kvstate", "json", "kvstate.tmp"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(digest).\(ext)"))
        }
    }

    // MARK: - Helpers

    static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Model ids are already simple, but keep folder names safe anyway.
    static func folderName(_ modelID: String) -> String {
        String(modelID.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "-" })
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970 // sub-second precision keeps LRU order exact
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
