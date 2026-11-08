// Relationship notes in lantern-bay.json are written to the character ("Rents the attic room above your
// cafe"). A profile shows them in the character's own words instead ("...above my cafe"), as a quote.

import Foundation

enum HomeRelationshipNote {
    /// "You pretend to be strict" -> "I pretend to be strict", "lets you nap" -> "lets me nap",
    /// "the two of you" -> "the two of us". Text without "you" comes back unchanged.
    static func inTheirWords(_ note: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(you['’]re|you['’]ve|you['’]d|you['’]ll|yourself|yours|your|you)\b"#,
                                                   options: [.caseInsensitive]) else { return note }
        let text = note as NSString
        var out = ""
        var cursor = 0
        for match in regex.matches(in: note, range: NSRange(location: 0, length: text.length)) {
            let range = match.range
            out += text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            out += swap(text.substring(with: range),
                        before: text.substring(to: range.location),
                        after: text.substring(from: range.location + range.length))
            cursor = range.location + range.length
        }
        out += text.substring(from: cursor)
        return fixVerbs(out)
    }

    // MARK: - One word

    private static func swap(_ word: String, before: String, after: String) -> String {
        let together = isTogether(before: before, after: after)
        var swapped: String
        switch word.lowercased().replacingOccurrences(of: "’", with: "'") {
        case "you're": swapped = together ? "we're" : "I'm"
        case "you've": swapped = together ? "we've" : "I've"
        case "you'd": swapped = together ? "we'd" : "I'd"
        case "you'll": swapped = together ? "we'll" : "I'll"
        case "yourself": swapped = "myself"
        case "yours": swapped = "mine"
        case "your": swapped = "my"
        default:
            if isGroup(before: before) {
                swapped = "us"
            } else if isObject(before: before, after: after) {
                swapped = "me"
            } else {
                swapped = together ? "we" : "I"
            }
        }
        // Keep a capital at the start of a sentence ("Your" -> "My"). "I" is always a capital.
        if word.first?.isUppercase == true {
            swapped = swapped.prefix(1).uppercased() + swapped.dropFirst()
        }
        return swapped
    }

    /// "for you.", "let you." (end of a clause), "at you", "lets you nap", "pays you in dumplings".
    private static func isObject(before: String, after: String) -> Bool {
        guard let next = after.first(where: { $0 != " " }) else { return true }
        if ".,;:!?)".contains(next) { return true }
        guard let previous = lastWord(of: before) else { return false }
        return takesSomeone.contains(previous)
    }

    /// "the two of you", "both of you" -> "us".
    private static func isGroup(before: String) -> Bool {
        let words = before.lowercased().split(whereSeparator: { !$0.isLetter })
        guard words.count >= 2, words[words.count - 1] == "of" else { return false }
        return ["two", "both", "all", "three", "each"].contains(String(words[words.count - 2]))
    }

    /// "together you've decided", "you can sit together" -> "we".
    private static func isTogether(before: String, after: String) -> Bool {
        if lastWord(of: before) == "together" { return true }
        let clause = after.prefix { !".,;:!?".contains($0) }.lowercased()
        return clause.split(whereSeparator: { !$0.isLetter }).contains("together")
    }

    /// The word right before, or nil when punctuation (or nothing) comes first, which starts a clause.
    private static func lastWord(of text: String) -> String? {
        let trimmed = text.reversed().drop(while: { $0 == " " })
        guard let last = trimmed.first, last.isLetter else { return nil }
        return String(trimmed.prefix(while: { $0.isLetter }).reversed()).lowercased()
    }

    /// "I are" -> "I am" and friends, after the swap.
    private static func fixVerbs(_ text: String) -> String {
        var out = text
        for (wrong, right) in [("I are", "I am"), ("I were", "I was"), ("I aren't", "I'm not"), ("I weren't", "I wasn't")] {
            out = out.replacingOccurrences(of: "\\b\(wrong)\\b", with: right, options: .regularExpression)
        }
        return out
    }

    /// Prepositions and verbs that are followed by the person they act on ("asks you", "with you").
    private static let takesSomeone: Set<String> = [
        "at", "for", "to", "with", "of", "about", "from", "into", "onto", "behind", "beside", "without",
        "around", "toward", "towards", "near", "past", "by", "against", "between", "beyond", "under", "over", "upon",
        "let", "lets", "ask", "asks", "asked", "asking", "tell", "tells", "told", "give", "gives", "gave",
        "show", "shows", "showed", "help", "helps", "helped", "make", "makes", "made", "call", "calls", "called",
        "bring", "brings", "brought", "send", "sends", "sent", "teach", "teaches", "taught", "join", "joins", "joined",
        "feed", "feeds", "fed", "pay", "pays", "paid", "save", "saves", "saved", "keep", "keeps", "kept",
        "take", "takes", "took", "wake", "wakes", "woke", "thank", "thanks", "love", "loves", "loved",
        "miss", "misses", "missed", "remind", "reminds", "invite", "invites", "pull", "pulls", "drag", "drags",
        "hand", "hands", "offer", "offers", "rent", "rents", "buy", "buys", "bought", "sneak", "sneaks",
        "shush", "shushes", "owe", "owes", "trust", "trusts", "need", "needs", "find", "finds", "found",
        "meet", "meets", "met", "see", "sees", "saw", "hear", "hears", "heard", "follow", "follows",
        "lend", "lends", "lent", "visit", "visits", "greet", "greets", "tease", "teases", "hug", "hugs",
    ]
}
