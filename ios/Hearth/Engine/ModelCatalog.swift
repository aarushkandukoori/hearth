// The models Hearth can run on the iPhone, where each one is downloaded from, and how to find an
// installed copy (downloaded into Application Support, or pushed into Documents over USB).

import Foundation

struct ModelSpec: Identifiable, Codable, Hashable, Sendable {
    /// Engine id, e.g. "llama-3.2-3b". Also names the model's folder of parked KV caches.
    var id: String
    /// "Hearth Standard (Llama 3.2 3B)"
    var displayName: String
    /// "Standard", for small labels.
    var shortName: String
    /// "Llama 3.2" or "Qwen3"
    var family: String
    var fileName: String
    var url: URL
    /// Exact file size; used to spot partial copies without hashing 2 GB.
    var bytes: Int64
    /// Lowercase hex SHA-256 of the file, checked after every download.
    var sha256: String
    /// Context window Hearth runs the model with (n_ctx).
    var contextLength: Int
    var recommended: Bool
    /// Rough device RAM this model needs to run comfortably.
    var minimumMemoryGB: Double
    var license: String
    /// One plain sentence for the model picker.
    var blurb: String
}

enum ModelCatalog {
    static let all: [ModelSpec] = [standard, lite, plus]

    static let standard = ModelSpec(
        id: "llama-3.2-3b",
        displayName: "Hearth Standard (Llama 3.2 3B)",
        shortName: "Standard",
        family: "Llama 3.2",
        fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
        url: link("https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"),
        bytes: 2_019_377_696,
        sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
        contextLength: 4096,
        recommended: true,
        minimumMemoryGB: 6,
        license: "Llama 3.2 Community License",
        blurb: "The everyday choice. Warm, steady conversation on most recent iPhones. About 2 GB.")

    static let lite = ModelSpec(
        id: "llama-3.2-1b",
        displayName: "Hearth Lite (Llama 3.2 1B)",
        shortName: "Lite",
        family: "Llama 3.2",
        fileName: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        url: link("https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf"),
        bytes: 807_694_464,
        sha256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
        contextLength: 8192,
        recommended: false,
        minimumMemoryGB: 4,
        license: "Llama 3.2 Community License",
        blurb: "Smaller and quicker, with simpler replies. Good for older iPhones or when space is tight. About 800 MB.")

    static let plus = ModelSpec(
        id: "qwen3-4b-2507",
        displayName: "Hearth Plus (Qwen3 4B Instruct 2507)",
        shortName: "Plus",
        family: "Qwen3",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        url: link("https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"),
        bytes: 2_497_281_120,
        sha256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        contextLength: 4096,
        recommended: false,
        minimumMemoryGB: 8,
        license: "Apache 2.0",
        blurb: "The most thoughtful replies, for iPhones with 8 GB of memory or more. About 2.5 GB.")

    static var recommended: ModelSpec { all.first { $0.recommended } ?? standard }

    /// A catalog model, or the developer `-HearthModel` file when its id matches.
    static func spec(id: String) -> ModelSpec? {
        if let spec = all.first(where: { $0.id == id }) { return spec }
        if let override = launchOverride(), override.spec.id == id { return override.spec }
        return nil
    }

    /// Where an installed copy of this model lives, if any. A copy counts only when its size is exact,
    /// so a half-finished USB push or download is never loaded.
    static func installedURL(for spec: ModelSpec) -> URL? {
        if let override = launchOverride(), override.spec.id == spec.id { return override.url }
        for folder in [HearthPaths.models, HearthPaths.documents] {
            let url = folder.appendingPathComponent(spec.fileName)
            if fileSize(url) == spec.bytes { return url }
        }
        return nil
    }

    /// Every model that is ready to load: catalog models on disk, plus the `-HearthModel` file.
    static func installedSpecs() -> [ModelSpec] {
        var specs = all.filter { installedURL(for: $0) != nil }
        if let override = launchOverride(), !specs.contains(where: { $0.id == override.spec.id }) {
            specs.append(override.spec)
        }
        return specs
    }

    /// The `-HearthModel <fileName>` launch argument, resolved to a file on disk. A catalog file name maps
    /// to its catalog model; any other GGUF becomes a "custom-..." model (handy for testing other models).
    static func launchOverride() -> (spec: ModelSpec, url: URL)? {
        guard let name = LaunchOptions.shared.modelFile, !name.isEmpty else { return nil }
        if let spec = all.first(where: { $0.fileName == name }) {
            for folder in [HearthPaths.models, HearthPaths.documents] {
                let url = folder.appendingPathComponent(spec.fileName)
                if fileSize(url) == spec.bytes { return (spec, url) }
            }
        }
        let candidates = name.hasPrefix("/")
            ? [URL(fileURLWithPath: name)]
            : [HearthPaths.models.appendingPathComponent(name), HearthPaths.documents.appendingPathComponent(name)]
        guard let url = candidates.first(where: { fileSize($0) != nil }), let size = fileSize(url) else { return nil }
        return (customSpec(fileName: url.lastPathComponent, url: url, bytes: size), url)
    }

    /// A spec for a model file that is not in the catalog.
    static func customSpec(fileName: String, url: URL, bytes: Int64) -> ModelSpec {
        let stem = (fileName as NSString).deletingPathExtension
        let slug = String(stem.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
        return ModelSpec(
            id: "custom-\(slug)",
            displayName: "Custom model (\(stem))",
            shortName: "Custom",
            family: "Custom",
            fileName: fileName,
            url: url,
            bytes: bytes,
            sha256: "",
            contextLength: 4096,
            recommended: false,
            minimumMemoryGB: 0,
            license: "See the model's own license",
            blurb: "A model file loaded with a developer launch option.")
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func link(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }
}
