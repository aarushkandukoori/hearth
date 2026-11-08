// One-time cleanup of what the llama.cpp version of Hearth left on iPhones that upgraded: its parked KV
// caches (Application Support/Hearth/kv, which hold conversation content) and its .gguf model files (about
// 0.8 to 2.5 GB each, in Application Support/Hearth/models or pushed into Documents). Pie uses neither.
// AppModel.boot runs it before the engine starts. Pie's models (.metal.zt) are never touched.

import Foundation

enum LegacyCleanup {
    /// Set once a run removed everything it found, so the cleanup never runs again.
    static let doneKey = "hearth.legacyCleanup.llama"

    /// What one run did (counts and sizes only, never names: the log stays free of anything personal).
    struct Result: Equatable, Sendable {
        var removedKVCaches = false
        var removedModelFiles = 0
        var bytes: Int64 = 0
        /// Items that couldn't be removed. Any failure leaves `doneKey` unset, so the next launch tries again.
        var failures = 0
    }

    /// Removes `root/kv` and every .gguf file (finished, or a ".gguf.download" left mid-download) directly
    /// inside `models` and `documents`, unless `defaults` says this already ran. Returns nil when it had.
    @discardableResult
    static func runOnce(root: URL = HearthPaths.root, models: URL = HearthPaths.models,
                        documents: URL = HearthPaths.documents, defaults: UserDefaults = .standard) -> Result? {
        guard !defaults.bool(forKey: doneKey) else { return nil }
        let result = clean(root: root, models: models, documents: documents)
        if result.failures == 0 { defaults.set(true, forKey: doneKey) }
        if result.removedKVCaches || result.removedModelFiles > 0 || result.failures > 0 {
            let size = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
            HearthLog.info("cleanup", "removed the llama.cpp version's leftovers: KV caches \(result.removedKVCaches ? "yes" : "no"), \(result.removedModelFiles) .gguf files, \(size) in all; \(result.failures) could not be removed")
        } else {
            HearthLog.info("cleanup", "nothing left from the llama.cpp version")
        }
        return result
    }

    static func clean(root: URL, models: URL, documents: URL) -> Result {
        let fm = FileManager.default
        var result = Result()
        let kv = root.appendingPathComponent("kv", isDirectory: true)
        if fm.fileExists(atPath: kv.path) {
            let bytes = HearthPaths.size(of: kv)
            if (try? fm.removeItem(at: kv)) != nil {
                result.removedKVCaches = true
                result.bytes += bytes
            } else {
                result.failures += 1
            }
        }
        for folder in [models, documents] {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])) ?? []
            for url in files where isOldModel(url) {
                let bytes = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                if (try? fm.removeItem(at: url)) != nil {
                    result.removedModelFiles += 1
                    result.bytes += bytes
                } else {
                    result.failures += 1
                }
            }
        }
        return result
    }

    /// A llama.cpp model file, finished or mid-download. A Pie artifact (.metal.zt) never matches.
    static func isOldModel(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".gguf") || name.hasSuffix(".gguf.download")
    }
}
