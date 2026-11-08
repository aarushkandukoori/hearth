// Turns raw model output into what the chat shows (SPEC §7 "Reply cleanup"): strips template
// tokens and name labels, pulls out [photo: ...] requests, and parses newsletter and memory lists.

import Foundation

struct ParsedReply: Hashable, Sendable {
    var text: String
    /// Set when the reply asked to send a picture ("[photo: the harbor at dawn]").
    var photoCaption: String?
}

enum ReplyParser {
    // MARK: Replies with a fixed opener (GenerationRequest.replyOpener)

    /// Joins a reply opener and what the model wrote after it (either can be empty).
    static func joinOpener(_ opener: String?, _ rest: String) -> String {
        let head = (opener ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return tail }
        return tail.isEmpty ? head : head + " " + tail
    }

    /// What the person sees for a reply that started with a fixed opener: the opener, then the model's
    /// words. A canned refusal after the opener is swapped for a short caring line, and an opener reply
    /// never carries a picture.
    static func withOpener(_ opener: String?, _ reply: ParsedReply) -> ParsedReply {
        guard let opener, !opener.isEmpty else { return reply }
        let rest = isCannedRefusal(reply.text) ? openerFallback : reply.text
        return ParsedReply(text: joinOpener(opener, rest), photoCaption: nil)
    }

    static let openerFallback = "I'm right here with you."

    /// "I cannot continue this conversation", "I can't provide...", "As an AI...": the model stepping out
    /// to decline instead of answering as the friend.
    static func isCannedRefusal(_ text: String) -> Bool {
        text.range(of: #"\bI\s*(cannot|can't|can’t|can not|won't|won’t|am not able to|'m not able to|’m not able to)\s+(continue|provide|engage|help with|assist|respond|fulfill)|\bas an ai\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Chat-template tokens a model sometimes prints. Text after one of these belongs to another turn.
    static let templateTokens = [
        "<|eot_id|>", "<|eom_id|>", "<|im_end|>", "<|im_start|>", "</s>", "<s>", "<end_of_turn>",
        "<start_of_turn>", "<|end|>", "<|endoftext|>", "<|start_header_id|>", "<|end_header_id|>",
        "<|assistant|>", "<|user|>", "<|system|>",
    ]

    static let maxCaptionLength = 200
    static let maxAwayEvents = 3
    static let maxSummaryFacts = 3

    static func clean(_ raw: String, speakerName: String, otherNames: [String], userName: String,
                      cutByMaxTokens: Bool) -> ParsedReply {
        var text = stripTemplateTokens(raw)
        text = cutAtSpeakerLines(text, names: [userName, "You", "User", speakerName] + otherNames)
        text = stripLeadingName(text, speakerName)
        let photo = extractPhoto(text, cutByMaxTokens: cutByMaxTokens)
        text = collapseBlankLines(photo.text)
        if cutByMaxTokens { text = dropDanglingSentence(text) }
        return ParsedReply(text: BrainText.trimmed(text), photoCaption: photo.caption)
    }

    // MARK: - Cleanup steps

    /// Removes leading template tokens, then cuts at the first token that is left.
    static func stripTemplateTokens(_ raw: String) -> String {
        var text = BrainText.trimmed(raw)
        var removedLeading = true
        while removedLeading {
            removedLeading = false
            for token in templateTokens where text.hasPrefix(token) {
                text = BrainText.trimmed(String(text.dropFirst(token.count)))
                removedLeading = true
            }
        }
        let cut = templateTokens.compactMap { text.range(of: $0)?.lowerBound }.min()
        return cut.map { String(text[..<$0]) } ?? text
    }

    /// Cuts everything from the first later line that starts like "Name:" (a new message starting).
    /// The first line is left alone (it is usually the character addressing someone).
    static func cutAtSpeakerLines(_ text: String, names: [String]) -> String {
        let escaped = names.map { BrainText.trimmed($0) }.filter { !$0.isEmpty }.map(NSRegularExpression.escapedPattern)
        guard !escaped.isEmpty,
              let r = BrainText.regex("\\n[ \\t]*[*_]*[ \\t]*(?:\(escaped.joined(separator: "|")))[ \\t]*[*_]*[ \\t]*:"),
              let m = r.firstMatch(in: text, range: BrainText.fullRange(text)),
              let range = Range(m.range, in: text) else { return text }
        return String(text[..<range.lowerBound])
    }

    /// Drops "Name:" (also "**Name:**") from the start, up to twice ("Theo: Theo: hi").
    static func stripLeadingName(_ text: String, _ name: String) -> String {
        let n = BrainText.trimmed(name)
        guard !n.isEmpty,
              let r = BrainText.regex("^[ \\t\\n]*[*_]*[ \\t]*\(NSRegularExpression.escapedPattern(for: n))[ \\t]*[*_]*[ \\t]*:[*_]*[ \\t]*")
        else { return text }
        var out = text
        for _ in 0..<2 {
            guard let m = r.firstMatch(in: out, range: BrainText.fullRange(out)), let range = Range(m.range, in: out) else { break }
            out = String(out[range.upperBound...])
        }
        return out
    }

    /// "[photo: ...]" (also "[You sent a photo: ...]", "[Picture: ...]"); group 2 is "]" when closed.
    private static let photoTag = BrainText.regex(#"\[[ \t]*(?:[a-z' ]{0,24}?[ \t])?(?:photo|picture|pic|image|selfie|snapshot|postcard)[ \t]*:[ \t]*([^\]\n]*)(\]|(?=\n)|$)"#)
    /// Small models often write an action instead: "*sends a photo of the pier at dusk*".
    private static let photoAction = BrainText.regex(#"\*[ \t]*(?:sends?|shares?|snaps?|takes?|shows?)[ \t]+(?:you[ \t]+|over[ \t]+)?(?:a[ \t]+|an[ \t]+|the[ \t]+)?(?:quick[ \t]+)?(?:photo|picture|pic|snapshot|selfie)[ \t]+(?:of[ \t]+)?([^*\n]+)\*"#)

    /// Finds photo tags (or, when there are none, photo actions). Every one is removed from the text and
    /// the first one's caption is returned. An unclosed tag at the end of a cut-off reply still counts,
    /// minus its half-written last word.
    static func extractPhoto(_ text: String, cutByMaxTokens: Bool) -> (text: String, caption: String?) {
        let all = BrainText.fullRange(text)
        let found = [photoTag, photoAction].compactMap { $0 }.lazy
            .map { $0.matches(in: text, range: all) }
            .first { !$0.isEmpty } ?? []
        guard let first = found.first else { return (text, nil) }

        var caption = BrainText.oneLine(BrainText.group(first, 1, in: text) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”*_ "))
        let closed = first.numberOfRanges < 3 || BrainText.group(first, 2, in: text) == "]"
        if !closed && cutByMaxTokens, let space = caption.lastIndex(of: " ") {
            caption = String(caption[..<space])
        }
        caption = BrainText.shortened(caption, maxChars: maxCaptionLength)

        var out = text
        for m in found.reversed() {
            if let range = Range(m.range, in: out) { out.replaceSubrange(range, with: "") }
        }
        let lines = out.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .replacingOccurrences(of: #" ([.!?,])"#, with: "$1", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        out = lines.joined(separator: "\n")
        return (out, caption.isEmpty ? nil : caption)
    }

    /// Trims line ends and turns 3+ newlines into one blank line.
    static func collapseBlankLines(_ text: String) -> String {
        let joined = text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        return joined.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    /// When a reply was cut by maxTokens and ends mid-sentence, go back to the last finished sentence.
    /// Keeps the text as is when there is no finished sentence to fall back to.
    static func dropDanglingSentence(_ text: String) -> String {
        let t = BrainText.trimmed(text)
        guard let last = t.last, last.isLetter || last.isNumber || ",;:-–—(".contains(last) else { return t }
        guard var end = t.lastIndex(where: { ".!?…".contains($0) }) else { return t }
        end = t.index(after: end)
        while end < t.endIndex, "\"'”’)*_~".contains(t[end]) { end = t.index(after: end) }
        let kept = BrainText.trimmed(String(t[..<end]))
        return kept.isEmpty ? t : kept
    }

    // MARK: - Lists ("- " lines)

    /// Items of "- ", "* ", "• " or "1." lines, with markdown bold and wrapping quotes removed.
    /// "none"-style items are skipped.
    static func bulletItems(_ text: String) -> [String] {
        guard let r = BrainText.regex(#"^\s*(?:[-*•–]|\d{1,2}[.)])\s+(.+)$"#) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            guard let m = r.firstMatch(in: line, range: BrainText.fullRange(line)),
                  let item = BrainText.group(m, 1, in: line) else { return nil }
            let cleaned = BrainText.trimmed(item.replacingOccurrences(of: "**", with: ""))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
            let t = BrainText.trimmed(cleaned)
            return t.isEmpty || isNone(t) ? nil : t
        }
    }

    static func isNone(_ item: String) -> Bool {
        let bare = BrainText.fold(item).trimmingCharacters(in: CharacterSet.letters.inverted)
        return ["none", "nothing", "nothing new", "no new facts", "no facts", "n/a", "na"].contains(bare)
    }

    /// Newsletter lines -> events. Detects residents (in mention order) and the first place named.
    /// Dates step back a minute per line so "newest first" keeps the written order.
    static func awayEvents(from text: String, world: WorldDefinition, now: Date) -> [WorldEvent] {
        var events: [WorldEvent] = []
        for item in bulletItems(text) {
            guard events.count < maxAwayEvents else { break }
            let line = BrainText.oneLine(item)
            let words = line.split(separator: " ").count
            guard words >= 3, words <= 40 else { continue }
            let folded = BrainText.fold(line)
            let ids = world.characters
                .compactMap { ch in BrainText.firstMention(of: BrainText.nameKeys(ch.name), in: folded).map { (ch.id, $0) } }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
            let place = world.locations
                .compactMap { loc in BrainText.firstMention(of: placeKeys(loc.name), in: folded).map { (loc.id, $0) } }
                .min { $0.1 < $1.1 }?.0
            events.append(WorldEvent(date: now.addingTimeInterval(-60 * Double(events.count)), text: line,
                                     characterIDs: ids, locationID: place))
        }
        return events
    }

    /// Summary lines -> fact texts (no trailing period, first letter capitalized, at most 3).
    static func facts(from text: String) -> [String] {
        let items: [String] = bulletItems(text).compactMap { item in
            let t = BrainText.withoutTrailingPunctuation(BrainText.oneLine(item))
            let words = t.split(separator: " ").count
            guard words >= 1, words <= 25, let first = t.first else { return nil }
            return first.uppercased() + t.dropFirst()
        }
        return Array(items.prefix(maxSummaryFacts))
    }

    /// "The Harbor" also matches "harbor".
    private static func placeKeys(_ name: String) -> [String] {
        let full = BrainText.fold(BrainText.trimmed(name))
        guard !full.isEmpty else { return [] }
        return full.hasPrefix("the ") ? [full, String(full.dropFirst(4))] : [full]
    }
}
