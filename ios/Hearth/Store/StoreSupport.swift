// Shared plumbing for the Store: JSON with ISO 8601 dates, tolerant reading of older or partly broken
// files, safe file names, a save debouncer, and the list of live stores (so "Delete everything" can
// clear them first, and files that were locked at launch get read once the iPhone unlocks).

import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

enum StoreError: Error {
    case unreadable
}

// MARK: - JSON

enum StoreJSON {
    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// Dates are written as ISO 8601 with microseconds (see formatDate).
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatDate(date))
        }
        return encoder
    }

    /// "2026-11-06T20:05:00.123456Z". Microseconds (not just milliseconds), so changes made a moment
    /// apart (a reply streaming in, several chats touched at once) keep their order after a relaunch.
    static func formatDate(_ date: Date) -> String {
        let time = date.timeIntervalSince1970
        var seconds = time.rounded(.down)
        var micros = Int(((time - seconds) * 1_000_000).rounded())
        if micros >= 1_000_000 {
            micros -= 1_000_000
            seconds += 1
        }
        let whole = Date(timeIntervalSince1970: seconds).formatted(Date.ISO8601FormatStyle()) // ends in "Z"
        return String(whole.dropLast()) + "." + String(format: "%06ld", micros) + "Z"
    }

    /// Reads ISO 8601 dates with or without fractional seconds, and plain days like "2026-11-06".
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date")
            }
            return date
        }
        return decoder
    }

    static func parseDate(_ text: String) -> Date? {
        if let date = try? isoWithFraction.parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        return try? Date.ISO8601FormatStyle().year().month().day().parse(text)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    /// The JSON object form of a value, minus some keys. Used as a template of default values.
    static func object<T: Encodable>(_ value: T, removing keys: [String] = []) -> [String: Any] {
        guard let data = try? encode(value),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        for key in keys { object.removeValue(forKey: key) }
        return object
    }

    /// Copies keys that `object` lacks (or holds as null) from `template`, going into nested objects.
    /// This lets a file written before a field existed still load, with that field's default value.
    static func filling(_ object: [String: Any], from template: [String: Any]) -> [String: Any] {
        var result = object
        for (key, fallback) in template {
            let current = result[key]
            if current == nil || current is NSNull {
                result[key] = fallback
            } else if let nested = current as? [String: Any], let nestedFallback = fallback as? [String: Any] {
                result[key] = filling(nested, from: nestedFallback)
            }
        }
        return result
    }

    /// Decodes a value from an already-parsed JSON object (dictionary or array).
    static func decode<T: Decodable>(_ type: T.Type, fromObject object: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(object) else { throw StoreError.unreadable }
        return try decoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    /// Decodes `type`; if that fails, fills missing keys from `template` and tries once more.
    /// (The template is only built when it's needed.)
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, template: @autoclosure () -> [String: Any]) throws -> T {
        do {
            return try decoder().decode(type, from: data)
        } catch {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw error }
            return try decode(type, fromObject: filling(object, from: template()))
        }
    }

    /// Decodes the items of a JSON array one by one, skipping the ones that can't be read
    /// (`skipped` counts them). Each item is filled from `template` first.
    static func decodeEach<T: Decodable>(_ type: T.Type, from value: Any?, template: [String: Any] = [:],
                                         skipped: inout Int) -> [T] {
        guard let items = value as? [Any] else { return [] }
        var result: [T] = []
        for item in items {
            let filled: Any = (item as? [String: Any]).map { filling($0, from: template) } ?? item
            if let decoded = try? decode(type, fromObject: filled) {
                result.append(decoded)
            } else {
                skipped += 1
            }
        }
        return result
    }

    /// Decodes a file that holds one JSON array. Fast path first; item by item if part of it is bad.
    static func decodeArray<T: Decodable>(_ type: T.Type, from data: Data, template: @autoclosure () -> [String: Any],
                                          skipped: inout Int) throws -> [T] {
        if let all = try? decoder().decode([T].self, from: data) { return all }
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { throw StoreError.unreadable }
        return decodeEach(type, from: items, template: template(), skipped: &skipped)
    }
}

// MARK: - Files

enum StoreFiles {
    enum ReadResult {
        /// No file yet (first launch).
        case missing
        /// The file is there but can't be opened right now (data protection keeps it closed while the
        /// iPhone is locked). Never overwrite such a file with what's in memory.
        case unreadable
        case data(Data)
    }

    static func read(_ url: URL) -> ReadResult {
        do {
            return .data(try Data(contentsOf: url))
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
    }

    /// The .json files directly inside a folder (none if the folder doesn't exist yet).
    static func jsonFiles(in folder: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A file name that is safe to build from an id: "u-juno" stays as it is, anything unusual
    /// (slashes, dots, emoji, very long) becomes a short hash, so an id can never point outside its folder.
    static func safeName(_ id: String) -> String {
        let plain = !id.isEmpty && id.count <= 80 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
        if plain { return id }
        let digest = SHA256.hash(data: Data(id.utf8))
        return "id-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// "Juno Fairweather!" -> "juno-fairweather". Non-Latin names are transliterated first; may be empty.
    static func slug(_ text: String, maxLength: Int = 40) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let folded = latin.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var slug = ""
        for scalar in folded.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                guard slug.unicodeScalars.count < maxLength else { break }
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug
    }

    /// True when `url` is strictly inside `folder` (".." tricks don't count). Paths are compared as text,
    /// with /private/var and /var treated as the same place.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let base = comparablePath(folder)
        return comparablePath(url).hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        comparablePath(url) == comparablePath(folder) || isInside(url, folder)
    }

    private static func comparablePath(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Error text for logs without file names (they can contain character names): domain and code only.
    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }
}

// MARK: - Debounced saving

/// Coalesces quick changes into one write: the save runs `delay` after the first unsaved change, and
/// later changes in that window join it. So a streaming reply is saved about twice a second, not per token.
@MainActor final class StoreDebouncer {
    private let delay: Duration
    private var task: Task<Void, Never>?

    init(delay: Duration = .milliseconds(500)) {
        self.delay = delay
    }

    var isPending: Bool { task != nil }

    func schedule(_ save: @escaping @MainActor () -> Void) {
        guard task == nil else { return }
        let delay = delay
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.task = nil
            save()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

// MARK: - Live stores

/// A store that keeps user data in memory and writes it into a folder.
@MainActor protocol PersistentStore: AnyObject {
    /// The folder this store writes into.
    var storageDirectory: URL { get }
    /// Writes anything waiting to be saved, right now.
    func flush()
    /// Reads files that couldn't be opened earlier (the app was started in the background while locked).
    func reloadIfNeeded()
    /// Drops everything in memory and any pending writes ("Delete everything" calls this before files go).
    func forgetEverything()
}

/// Every live store, held weakly.
@MainActor enum StoreRegistry {
    private final class WeakBox {
        weak var store: (any PersistentStore)?
        init(_ store: any PersistentStore) { self.store = store }
    }

    private static var boxes: [WeakBox] = []
    private static var watchingUnlock = false

    static func register(_ store: any PersistentStore) {
        boxes.removeAll { $0.store == nil }
        boxes.append(WeakBox(store))
        watchForUnlock()
    }

    private static var stores: [any PersistentStore] { boxes.compactMap(\.store) }

    /// Tells every store whose folder is inside `root` to forget its data and drop pending writes.
    static func forgetEverything(under root: URL) {
        for store in stores where StoreFiles.isSameOrInside(store.storageDirectory, root) {
            store.forgetEverything()
        }
    }

    /// Reads anything that was locked and writes anything waiting.
    static func reloadAndFlushAll() {
        for store in stores {
            store.reloadIfNeeded()
            store.flush()
        }
    }

    /// Reads anything that was locked (nothing to do when nothing was). AppModel calls it each time Hearth
    /// becomes active, because the unlock notice below never reaches an app iOS kept suspended.
    static func reloadAll() {
        for store in stores { store.reloadIfNeeded() }
    }

    /// If the app started in the background while the iPhone was locked (a model download finishing),
    /// protected files couldn't be read. Read them as soon as the iPhone unlocks.
    private static func watchForUnlock() {
        #if canImport(UIKit)
        guard !watchingUnlock else { return }
        watchingUnlock = true
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StoreRegistry.reloadAndFlushAll() }
        }
        #endif
    }
}
