// Small text helpers shared by the Brain files: folding for matching, whole-word search,
// sentence tidying and regex shortcuts. Pure Foundation, no state.

import Foundation

enum BrainText {
    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Lowercased, accent-free, curly quotes made straight. Only used for matching, never shown.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    /// Collapses all whitespace (newlines too) into single spaces.
    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Adds a period when the text ends in a letter or digit ("Bakes bread" -> "Bakes bread.").
    static func sentence(_ s: String) -> String {
        let t = trimmed(s)
        guard let last = t.last, last.isLetter || last.isNumber else { return t }
        return t + "."
    }

    /// Drops trailing sentence punctuation, for items inside lists or parentheses.
    static func withoutTrailingPunctuation(_ s: String) -> String {
        var t = trimmed(s)
        while let last = t.last, ".!?;,".contains(last) { t.removeLast() }
        return t
    }

    /// "otter" -> "an otter", "hedgehog" -> "a hedgehog". Keeps an article that is already there.
    static func withArticle(_ noun: String) -> String {
        let t = trimmed(noun)
        let lower = t.lowercased()
        if lower.hasPrefix("a ") || lower.hasPrefix("an ") || lower.hasPrefix("the ") { return t }
        guard let first = lower.first else { return "" }
        return ("aeiou".contains(first) ? "an " : "a ") + t
    }

    /// One line of at most `maxChars`, ending at a sentence if one ends late enough, else at a word.
    static func shortened(_ s: String, maxChars: Int) -> String {
        let t = oneLine(s)
        guard t.count > maxChars else { return t }
        let head = String(t.prefix(maxChars))
        if let end = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: end) >= maxChars / 3 {
            return String(head[...end])
        }
        if let space = head.lastIndex(of: " ") { return String(head[..<space]) }
        return head
    }

    /// Replaces Character Card placeholders {{user}} and {{char}} (any letter case).
    static func fillNames(_ s: String, user: String, char: String) -> String {
        s.replacingOccurrences(of: "{{user}}", with: user, options: .caseInsensitive)
            .replacingOccurrences(of: "{{char}}", with: char, options: .caseInsensitive)
    }

    // MARK: - Whole-word matching (pass folded strings)

    static func isWordChar(_ c: Swift.Character) -> Bool { c.isLetter || c.isNumber }

    /// Where `phrase` appears in `text` with no letter or digit touching either side.
    static func wholeWordRange(of phrase: String, in text: String) -> Range<String.Index>? {
        guard !phrase.isEmpty else { return nil }
        var start = text.startIndex
        while start < text.endIndex, let r = text.range(of: phrase, range: start..<text.endIndex) {
            let beforeOK = r.lowerBound == text.startIndex || !isWordChar(text[text.index(before: r.lowerBound)])
            let afterOK = r.upperBound == text.endIndex || !isWordChar(text[r.upperBound])
            if beforeOK && afterOK { return r }
            start = text.index(after: r.lowerBound)
        }
        return nil
    }

    private static let nameTitles: Set<String> = [
        "mr", "mrs", "ms", "dr", "miss", "mister", "sir", "lady", "old", "little", "big", "young",
        "auntie", "aunt", "uncle", "captain", "cap'n", "the", "of", "grandma", "grandpa", "granny",
        "madame", "professor", "prof", "doc", "nana",
    ]

    /// Folded strings that count as mentioning a name: the full name, plus each longer word of a
    /// multi-word name except titles ("Auntie Mabel" -> "auntie mabel", "mabel").
    static func nameKeys(_ name: String) -> [String] {
        let full = fold(trimmed(name))
        guard !full.isEmpty else { return [] }
        let words = full.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [full] }
        return [full] + words.filter { $0.count >= 3 && !nameTitles.contains($0) }
    }

    /// Earliest whole-word mention of any key in already-folded text.
    static func firstMention(of keys: [String], in foldedText: String) -> String.Index? {
        keys.compactMap { wholeWordRange(of: $0, in: foldedText)?.lowerBound }.min()
    }

    // MARK: - Regex shortcuts

    static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    static func fullRange(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    static func matches(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: fullRange(s)) != nil
    }

    /// Text of capture group `group` in a match, if that group took part.
    static func group(_ m: NSTextCheckingResult, _ group: Int, in s: String) -> String? {
        guard group < m.numberOfRanges, let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }
}
