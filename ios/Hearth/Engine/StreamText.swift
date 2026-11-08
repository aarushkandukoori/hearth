// Streaming text helpers shared by every engine: rebuild UTF-8 characters that arrive split across
// tokens, hold back text that might be the start of a stop string, and drop an echoed "Name:" label.

import Foundation

/// Collects raw bytes from token pieces and releases only complete UTF-8 characters.
/// (An emoji can arrive as 2-4 separate byte tokens; showing half of one would print a "?".)
struct UTF8Assembler {
    private var pending: [UInt8] = []

    /// Adds bytes and returns whatever text is now complete (often empty while a character is split).
    mutating func append(_ bytes: [UInt8]) -> String {
        pending.append(contentsOf: bytes)
        let cut = Self.completeLength(pending)
        guard cut > 0 else { return "" }
        let text = String(decoding: pending[..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return text
    }

    /// True while some bytes are waiting for the rest of their character.
    var hasPending: Bool { !pending.isEmpty }

    /// Length of the longest prefix that does not stop in the middle of a multi-byte character.
    static func completeLength(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var continuationBytes = 0
        while i >= 0, continuationBytes < 3, bytes[i] & 0xC0 == 0x80 {
            continuationBytes += 1
            i -= 1
        }
        guard i >= 0 else { return bytes.count } // only stray continuation bytes: let the decoder replace them
        let needed: Int
        switch bytes[i] {
        case 0xF0...0xF7: needed = 4
        case 0xE0...0xEF: needed = 3
        case 0xC0...0xDF: needed = 2
        default: needed = 1
        }
        return needed > continuationBytes + 1 ? i : bytes.count
    }
}

/// Watches streamed text for stop strings. Text that could still turn into a stop string is held back,
/// so the user never sees a stop string or the first half of one.
struct StopFilter {
    private let stops: [[UInt8]]
    private var held: [UInt8] = []
    /// Becomes true once a stop string appeared. Everything from it onward is dropped.
    private(set) var stopped = false

    init(_ stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }.map { Array($0.utf8) }
    }

    /// Feeds new text and returns the part that is safe to show now.
    mutating func feed(_ text: String) -> String {
        guard !stopped else { return "" }
        held.append(contentsOf: text.utf8)
        if let cut = earliestMatch() {
            stopped = true
            let visible = String(decoding: held[..<cut], as: UTF8.self)
            held.removeAll()
            return visible
        }
        let release = held.count - longestPartialMatch()
        let visible = String(decoding: held[..<release], as: UTF8.self)
        held.removeFirst(release)
        return visible
    }

    /// Call when the stream ends for another reason: returns text that was held back but never became a stop.
    mutating func flush() -> String {
        defer { held.removeAll() }
        return stopped ? "" : String(decoding: held, as: UTF8.self)
    }

    /// Byte offset of the earliest complete stop string in `held`.
    private func earliestMatch() -> Int? {
        var best: Int?
        for stop in stops where stop.count <= held.count {
            guard let start = Self.firstIndex(of: stop, in: held) else { continue }
            if best.map({ start < $0 }) ?? true { best = start }
        }
        return best
    }

    /// Length of the longest tail of `held` that is the beginning of some stop string.
    private func longestPartialMatch() -> Int {
        var best = 0
        for stop in stops {
            var length = min(stop.count - 1, held.count)
            while length > best {
                if held.suffix(length).elementsEqual(stop.prefix(length)) {
                    best = length
                    break
                }
                length -= 1
            }
        }
        return best
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }
        for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }
}

/// Drops a leading speaker label such as "Theo:" that a model may echo at the start of its reply.
/// Used by engines that cannot force the label into the prompt (Apple's model).
struct LeadingLabelStripper {
    private let label: String?
    private var buffer = ""
    private var decided = false

    /// `label` is the assistantPrefix, e.g. "Theo:". nil or empty means pass everything through.
    init(label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.label = trimmed.isEmpty ? nil : trimmed.lowercased()
        decided = self.label == nil
    }

    mutating func feed(_ text: String) -> String {
        guard !decided, let label else { return text }
        buffer += text
        let start = buffer.drop { $0 == " " || $0 == "\n" }
        let lowered = start.lowercased()
        if lowered.count >= label.count {
            decided = true
            defer { buffer = "" }
            guard lowered.hasPrefix(label) else { return buffer }
            return String(start.dropFirst(label.count).drop { $0 == " " })
        }
        if !label.hasPrefix(lowered) {
            decided = true
            defer { buffer = "" }
            return buffer
        }
        return ""
    }

    /// Returns anything still buffered when the stream ends.
    mutating func flush() -> String {
        decided = true
        defer { buffer = "" }
        return buffer
    }
}
