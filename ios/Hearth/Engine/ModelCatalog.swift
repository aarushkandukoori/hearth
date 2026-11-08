// The models Hearth can run on the iPhone, all through Pie: Pie artifacts (`.metal.zt`, made by
// `pie model import`), where each one is downloaded from, and how to find an installed copy (downloaded into
// Application Support, or pushed into Documents over USB).

import Foundation

struct ModelSpec: Identifiable, Codable, Hashable, Sendable {
    /// Engine id, e.g. "qwen3.5-2b".
    var id: String
    /// "Hearth Standard (Qwen3.5 2B)"
    var displayName: String
    /// "Standard", for small labels.
    var shortName: String
    /// "Qwen3.5"
    var family: String
    /// The Pie deployment inside the artifact, e.g. "qwen35-d2b-u4g64-kv-bf16".
    var deployment: String
    var fileName: String
    var url: URL
    /// Exact file size; used to spot partial copies without hashing gigabytes.
    var bytes: Int64
    /// Lowercase hex SHA-256 of the file, checked after every download.
    var sha256: String
    /// Context window Hearth runs the model with (Pie's max_model_len).
    var contextLength: Int
    var recommended: Bool
    /// Rough device RAM this model needs to run comfortably.
    var minimumMemoryGB: Double
    /// True when the model has a vision tower, so Pie can describe photos the person sends.
    var vision: Bool
    var license: String
    /// One plain sentence for the model picker.
    var blurb: String

    /// "Qwen3.5 2B", taken from the display name.
    var modelName: String {
        guard let open = displayName.firstIndex(of: "("), let close = displayName.lastIndex(of: ")"), open < close else {
            return displayName
        }
        return String(displayName[displayName.index(after: open)..<close])
    }
}

enum ModelCatalog {
    static let all: [ModelSpec] = [standard, lite]

    /// Where the Pie artifacts are published (GitHub release assets of the Hearth repo).
    static let releaseBase = "https://github.com/aarushkandukoori/hearth/releases/download/pie-models-1/"

    static let standard = ModelSpec(
        id: "qwen3.5-2b",
        displayName: "Hearth Standard (Qwen3.5 2B)",
        shortName: "Standard",
        family: "Qwen3.5",
        deployment: "qwen35-d2b-u4g64-kv-bf16",
        fileName: "qwen3.5-2b.metal.zt",
        url: link(releaseBase + "qwen3.5-2b.metal.zt"),
        bytes: 1_074_698_212,
        sha256: "116d5547ad1f9aaa85886ead8ee894e2f1b08a2b8de7c09ea556d5faf4b378c9",
        contextLength: 4096,
        recommended: true,
        minimumMemoryGB: 6,
        vision: false,
        license: "Apache 2.0",
        blurb: "The everyday choice. Warm, steady conversation, run by Pie on this iPhone's GPU. About 1.1 GB.")

    static let lite = ModelSpec(
        id: "qwen3.5-0.8b",
        displayName: "Hearth Lite (Qwen3.5 0.8B)",
        shortName: "Lite",
        family: "Qwen3.5",
        deployment: "qwen35-d0.8b-vision-u4g64-kv-bf16",
        fileName: "qwen3.5-0.8b-vision.metal.zt",
        url: link(releaseBase + "qwen3.5-0.8b-vision.metal.zt"),
        bytes: 648_146_919,
        sha256: "1ac0483e8956940c968a2ed30b35e8a70e961b13f1494a8ab7fc2097957933af",
        contextLength: 4096,
        recommended: false,
        minimumMemoryGB: 4,
        vision: true,
        license: "Apache 2.0",
        blurb: "Smaller and quicker, with simpler replies, and it can look at photos you send. About 650 MB.")

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
    /// to its catalog model; any other Pie artifact becomes a "custom-..." model (handy for testing).
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
            deployment: "custom",
            fileName: fileName,
            url: url,
            bytes: bytes,
            sha256: "",
            contextLength: 4096,
            recommended: false,
            minimumMemoryGB: 0,
            vision: false,
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
