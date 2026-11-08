// Small lasting facts about the user (SPEC §7 Memory): cheap pattern facts from what they type,
// duplicate checks, and the per-character cap. Facts read in third person: "Has a dog named Biscuit".

import Foundation

enum MemoryKeeper {
    /// Run the summary prompt after this many new user messages (and use this many turns in it).
    static let summarizeEvery = 12
    static let maxFactsPerCharacter = 40
    static let maxFactsPerMessage = 5
    /// Longer phrases are skipped rather than cut mid-thought (the summary prompt catches them).
    static let maxPhraseWords = 8

    // MARK: - Pattern facts

    static func extractFacts(fromUserText text: String, userName: String) -> [String] {
        // Nothing is learned from a message that may come from someone in danger: it could come up again out of
        // context, or travel to every resident through town gossip.
        guard SafetyGuard.assess(text) == .none else { return [] }
        var found: [String] = []
        let straight = text.replacingOccurrences(of: "\u{2019}", with: "'")
        for sentence in sentences(straight) where !sentence.isQuestion {
            found += relationFacts(in: sentence.text)
            for clause in clauses(sentence.text) { found += phraseFacts(in: clause, userName: userName) }
        }
        var unique: [String] = []
        for fact in found where !unique.contains(where: { isDuplicate($0, fact) }) { unique.append(fact) }
        return Array(unique.prefix(maxFactsPerMessage))
    }

    private static let pets = ["guinea pig", "dog", "cat", "puppy", "kitten", "bird", "parrot", "rabbit", "bunny",
                               "hamster", "fish", "turtle", "horse", "snake", "lizard"]
    /// People someone usually has one of: "Their mom is named Rita".
    private static let onlyOne = ["mom", "mum", "mother", "dad", "father", "wife", "husband", "partner",
                                  "girlfriend", "boyfriend", "fiance", "fiancee", "boss"]
    private static let otherPeople = ["best friend", "sister", "brother", "son", "daughter", "friend", "roommate",
                                      "grandma", "grandmother", "grandpa", "grandfather", "aunt", "uncle", "cousin",
                                      "niece", "nephew", "kid", "baby", "coworker"]
    private static let notNames: Set<String> = ["Is", "Was", "And", "The", "But", "So", "Has", "Had", "Just", "Always",
                                                "Never", "Really", "Who", "That", "This", "He", "She", "They", "It", "We"]

    private static var relationWords: String {
        (pets + onlyOne + otherPeople).map { $0.replacingOccurrences(of: " ", with: "\\s+") }.joined(separator: "|")
    }

    /// The name part is case-sensitive on purpose: "my dog Biscuit" counts, "my dog is sick" does not.
    private static let namedRelation = BrainText.regex(
        #"(?i:\bmy\s+("# + relationWords + #")(?:'s\s+name\s+is|\s+is\s+called|\s+is\s+named|,?\s+named|,?\s+called|,)?\s+)([A-Z][a-zA-Z'\-]{1,20})"#,
        caseInsensitive: false)
    private static let haveNamed = BrainText.regex(
        #"(?i:\bi\s+have\s+an?\s+("# + relationWords + #")\s+(?:named|called)\s+)([A-Z][a-zA-Z'\-]{1,20})"#,
        caseInsensitive: false)
    private static let haveCount = BrainText.regex(
        #"\bi\s+have\s+(a|an|two|three|four|2|3|4)\s+(guinea\s+pigs?|dogs?|cats?|puppy|puppies|kittens?|birds?|parrots?|rabbits?|bunny|bunnies|hamsters?|fish|turtles?|horses?|sisters?|brothers?|sons?|daughters?|kids?)\b"#)

    private static func relationFacts(in sentence: String) -> [String] {
        var facts: [String] = []
        for r in [namedRelation, haveNamed].compactMap({ $0 }) {
            for m in r.matches(in: sentence, range: BrainText.fullRange(sentence)) {
                guard let relation = BrainText.group(m, 1, in: sentence).map({ BrainText.oneLine($0.lowercased()) }),
                      let name = BrainText.group(m, 2, in: sentence), !notNames.contains(name) else { continue }
                facts.append(onlyOne.contains(relation)
                             ? "Their \(relation) is named \(name)"
                             : "Has \(BrainText.withArticle(relation)) named \(name)")
            }
        }
        if facts.isEmpty, let r = haveCount, let m = r.firstMatch(in: sentence, range: BrainText.fullRange(sentence)),
           let count = BrainText.group(m, 1, in: sentence), let noun = BrainText.group(m, 2, in: sentence) {
            facts.append("Has \(count.lowercased()) \(BrainText.oneLine(noun.lowercased()))")
        }
        return facts
    }

    private static let nameIs = BrainText.regex(#"\b(?:my name is|my name's|i'm called|i am called)\s+([a-z][a-z'\-]{1,20})\b"#)
    private static let callMe = BrainText.regex(#"(?i:\bcall me\s+)([A-Z][a-zA-Z'\-]{1,20})\b"#, caseInsensitive: false)
    private static let livesIn = BrainText.regex(#"\bi(?:\s+live|\s+am\s+living|'m\s+living|\s+currently\s+live|\s+now\s+live)\s+in\s+([^,;:()]+)"#)
    private static let isFrom = BrainText.regex(#"\bi(?:'m|\s+am)\s+from\s+([^,;:()]+)"#)
    private static let worksAs = BrainText.regex(#"\bi\s+work\s+(as|at|in|for)\s+([^,;:()]+)"#)
    private static let likes = BrainText.regex(#"\bi\s+(?:really\s+|also\s+|just\s+|totally\s+|absolutely\s+|kinda\s+|kind\s+of\s+|do\s+)?(love|like|adore|enjoy)\s+([^,;:()]+)"#)

    private static func phraseFacts(in s: String, userName: String) -> [String] {
        let all = BrainText.fullRange(s)
        var facts: [String] = []

        for r in [nameIs, callMe].compactMap({ $0 }) {
            guard let m = r.firstMatch(in: s, range: all), let raw = BrainText.group(m, 1, in: s) else { continue }
            let name = raw.prefix(1).uppercased() + raw.dropFirst()
            let skip: Set<String> = ["not", "a", "an", "the", "just", "so", "very", "really", "kind", "sort"]
            if !skip.contains(raw.lowercased()), BrainText.fold(name) != BrainText.fold(userName) {
                facts.append("Goes by \(name)")
            }
        }
        if let r = livesIn, let m = r.firstMatch(in: s, range: all),
           let place = phrase(BrainText.group(m, 1, in: s)) { facts.append("Lives in \(place)") }
        if let r = isFrom, let m = r.firstMatch(in: s, range: all),
           let place = phrase(BrainText.group(m, 1, in: s)) { facts.append("Is from \(place)") }
        if let r = worksAs, let m = r.firstMatch(in: s, range: all), let how = BrainText.group(m, 1, in: s),
           let job = phrase(BrainText.group(m, 2, in: s)) { facts.append("Works \(how.lowercased()) \(job)") }
        if let r = likes {
            let verbs = ["love": "Loves", "like": "Likes", "adore": "Adores", "enjoy": "Enjoys"]
            for m in r.matches(in: s, range: all) {
                guard let verb = BrainText.group(m, 1, in: s).flatMap({ verbs[$0.lowercased()] }),
                      let thing = phrase(BrainText.group(m, 2, in: s), forLikes: true) else { continue }
                facts.append("\(verb) \(thing)")
            }
        }
        return facts
    }

    private static let clauseBreaks = [" but ", " because ", " so ", " though ", " when ", " if ", " since ",
                                       " and i ", " and it ", " and that ", " and then ", " which "]
    private static let fillers = ["too", "also", "lol", "haha", "honestly", "tbh", "anyway", "though", "so much",
                                  "a lot", "very much", "really"]
    private static let notLikable: Set<String> = ["you", "u", "ya", "it", "its", "it's", "that", "this", "these", "those",
                                                  "them", "him", "her", "when", "how", "what", "where", "who", "why",
                                                  "being", "about", "if", "because", "so", "too", "very", "much", "here",
                                                  "there", "everything", "nothing", "anything", "something", "someone",
                                                  "somebody", "everyone", "everybody"]
    private static let thirdPerson = ["my": "their", "me": "them", "mine": "theirs", "myself": "themselves"]

    /// Cleans the captured end of a sentence into a short third-person phrase, or nil if it is not one.
    private static func phrase(_ raw: String?, forLikes: Bool = false) -> String? {
        guard let raw else { return nil }
        var p = " " + BrainText.oneLine(raw) + " "
        for stop in clauseBreaks {
            if let r = p.range(of: stop, options: .caseInsensitive) { p = String(p[..<r.lowerBound]) + " " }
        }
        var words = p.split(separator: " ").map(String.init)
        var trimming = true
        while trimming, !words.isEmpty {
            trimming = false
            for filler in fillers {
                let parts = filler.split(separator: " ").map(String.init)
                if words.count > parts.count, words.suffix(parts.count).map({ $0.lowercased() }) == parts {
                    words.removeLast(parts.count)
                    trimming = true
                }
            }
        }
        words = words.map { thirdPerson[$0.lowercased()] ?? $0 }
        guard let first = words.first?.lowercased(), (1...maxPhraseWords).contains(words.count) else { return nil }
        let lower = Set(words.map { $0.lowercased() })
        if !lower.isDisjoint(with: ["you", "your", "yours", "u", "ur"]) { return nil }
        if forLikes && notLikable.contains(first) { return nil }
        let joined = BrainText.withoutTrailingPunctuation(words.joined(separator: " "))
        return joined.contains(where: { $0.isLetter }) ? joined : nil
    }

    /// "I love tea, and I like old movies" -> ["I love tea", "i like old movies"], so each part can match.
    private static func clauses(_ sentence: String) -> [String] {
        var s = " " + sentence + " "
        for (marker, replacement) in [(",", "|"), (";", "|"), (" and i ", "| i "), (" but ", "|"), (" because ", "|"),
                                      (" so ", "|"), (" though ", "|"), (" although ", "|"), (" while ", "|")] {
            s = s.replacingOccurrences(of: marker, with: replacement, options: .caseInsensitive)
        }
        return s.split(separator: "|").map { BrainText.trimmed(String($0)) }.filter { !$0.isEmpty }
    }

    /// Splits on . ! ? and newlines, but not inside "St. Louis" or "3.5".
    private static func sentences(_ text: String) -> [(text: String, isQuestion: Bool)] {
        let abbreviations: Set<String> = ["st", "mt", "mr", "mrs", "ms", "dr", "jr", "sr", "vs"]
        var result: [(String, Bool)] = []
        var current = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            if ".!?\n".contains(ch) {
                let lastWord = current.split(separator: " ").last.map { $0.lowercased() } ?? ""
                let between = i > 0 && i + 1 < chars.count && chars[i - 1].isNumber && chars[i + 1].isNumber
                if ch == "." && (abbreviations.contains(lastWord) || between) { current.append(ch); continue }
                let t = BrainText.trimmed(current)
                if !t.isEmpty { result.append((t, ch == "?")) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = BrainText.trimmed(current)
        if !tail.isEmpty { result.append((tail, false)) }
        return result
    }

    // MARK: - Dedupe and merge

    /// Same fact if equal ignoring case and punctuation, or the word sets overlap by more than 60% (Jaccard).
    static func isDuplicate(_ a: String, _ b: String) -> Bool {
        let wa = words(a), wb = words(b)
        if wa.isEmpty || wb.isEmpty { return wa.isEmpty && wb.isEmpty }
        if wa == wb { return true }
        let sa = Set(wa), sb = Set(wb)
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count) > 0.6
    }

    private static func words(_ s: String) -> [String] {
        BrainText.fold(s).split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    /// Adds new fact texts for `characterID` (nil = known to everyone), skipping duplicates of facts that
    /// character already knows. Pinning an existing fact upgrades it. Keeps at most
    /// `maxFactsPerCharacter` per character, dropping the oldest unpinned ones first.
    /// A fact that sounds like someone may be in danger is never shared, and only kept when it was pinned.
    static func merge(_ new: [String], into existing: [MemoryFact], characterID: String?,
                      source: MemorySource, shareable: Bool) -> [MemoryFact] {
        var result = existing
        for raw in new {
            let text = BrainText.oneLine(raw)
            guard !text.isEmpty else { continue }
            let sensitive = isSensitiveFact(text)
            if sensitive && source != .pinned { continue }
            if let i = result.firstIndex(where: { ($0.characterID == characterID || $0.characterID == nil) && isDuplicate($0.text, text) }) {
                if source == .pinned, result[i].characterID == characterID { result[i].source = .pinned }
                continue
            }
            result.append(MemoryFact(characterID: characterID, text: text, source: source, shareable: shareable && !sensitive))
        }
        return capped(result, characterID: characterID)
    }

    /// A fact that sounds like someone may be in danger: flagged as written, or a crisis once read in first
    /// person. Summary facts are third person ("Wants to die") and the safety check reads first person.
    static func isSensitiveFact(_ text: String) -> Bool {
        SafetyGuard.assess(text) != .none || SafetyGuard.assess(firstPerson(text)) == .crisis
    }

    /// Reads a stored fact as if the person said it ("Wants to die" -> "I want to die", "Their partner hits
    /// them" -> "my partner hits me"). Only used to check safety, never shown.
    static func firstPerson(_ text: String) -> String {
        let swaps: [(String, String)] = [
            (#"\bthemsel(?:f|ves)\b"#, "myself"), (#"\btheir\b"#, "my"), (#"\bthem\b"#, "me"),
            (#"\bthey(?:'re|\x{2019}re|\s+are)\b"#, "i am"), (#"\bthey\b"#, "i"),
            (#"\bdoesn(?:'|\x{2019})?t\b"#, "don't"), (#"\bdoes\s+not\b"#, "do not"),
        ]
        var t = BrainText.oneLine(text)
        for (pattern, template) in swaps {
            t = t.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        // Summary facts usually leave out the subject ("Is in danger at home"): put "I" back in front.
        var words = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first?.lowercased() else { return t }
        let subjects: Set<String> = ["i", "i'm", "i\u{2019}m", "my", "me", "myself", "i've", "i'll", "i'd"]
        guard !subjects.contains(first) else { return t }
        words[0] = firstPersonVerb(first)
        return "I " + words.joined(separator: " ")
    }

    /// "is" -> "am", "has" -> "have", "wishes" -> "wish", "hurts" -> "hurt" (any other word stays as it is).
    private static func firstPersonVerb(_ word: String) -> String {
        switch word {
        case "is": return "am"
        case "has": return "have"
        case "does": return "do"
        default: break
        }
        for ending in ["shes", "ches", "sses", "xes", "zes"] where word.hasSuffix(ending) { return String(word.dropLast(2)) }
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { return String(word.dropLast()) }
        return word
    }

    private static func capped(_ facts: [MemoryFact], characterID: String?) -> [MemoryFact] {
        let mine = facts.indices.filter { facts[$0].characterID == characterID }
        let extra = mine.count - maxFactsPerCharacter
        guard extra > 0 else { return facts }
        let dropOrder = mine.sorted { a, b in
            let pinnedA = facts[a].source == .pinned, pinnedB = facts[b].source == .pinned
            if pinnedA != pinnedB { return !pinnedA }
            return (facts[a].createdAt, a) < (facts[b].createdAt, b)
        }
        let removed = Set(dropOrder.prefix(extra))
        return facts.indices.filter { !removed.contains($0) }.map { facts[$0] }
    }
}
