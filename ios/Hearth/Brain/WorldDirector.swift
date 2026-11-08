// The "director" for Lantern Bay (SPEC §7): who is where at each part of the day, who speaks next
// in a group scene, which town events matter to whom. No language model; randomness is injected.

import Foundation

struct WorldDirector {
    let world: WorldDefinition
    var calendar: Calendar = .current

    // MARK: - Who is where

    func part(at date: Date) -> DayPart { DayPart.at(date, calendar: calendar) }

    /// The location from the character's schedule for that part of the day (falls back to home).
    func location(of character: Character, at date: Date) -> Location? {
        guard let slot = character.slot(for: part(at: date)) else { return nil }
        return world.locations.first { $0.id == slot.locationID }
    }

    func activity(of character: Character, at date: Date) -> String {
        let activity = BrainText.trimmed(character.slot(for: part(at: date))?.activity ?? "")
        return activity.isEmpty ? "going about their day" : activity
    }

    /// Residents at a location during that part of the day, in world order.
    func residents(at locationID: String, on date: Date) -> [Character] {
        let now = part(at: date)
        return world.characters.filter { $0.slot(for: now)?.locationID == locationID }
    }

    // MARK: - Group scenes

    /// Who answers a user line (at most 2): characters named in the text first, in the order named.
    /// Otherwise the one the user addressed in their previous line, else whoever spoke least recently.
    /// Then, with a 50% chance, one more character reacts.
    func nextSpeakers<R: RandomNumberGenerator>(afterUserText text: String, present: [Character],
                                                transcript: [Message], using rng: inout R) -> [Character] {
        let cast = Self.unique(present)
        guard !cast.isEmpty else { return [] }

        let named = Self.mentioned(cast, in: text)
        if named.count >= 2 { return Array(named.prefix(2)) }

        let first: Character
        if let pick = named.first ?? previouslyAddressed(cast, transcript: transcript, currentText: text) {
            first = pick
        } else {
            first = leastRecent(cast, transcript: transcript, using: &rng)[0]
        }
        let others = cast.filter { $0.id != first.id }
        guard !others.isEmpty, Self.roll(0.5, using: &rng) else { return [first] }
        return [first, leastRecent(others, transcript: transcript, using: &rng)[0]]
    }

    /// "Let them talk": `count` lines among the present characters, never the same speaker twice in a
    /// row (counting `lastSpeakerID`), giving turns to whoever has had the fewest in this round.
    func banterOrder<R: RandomNumberGenerator>(present: [Character], count: Int, lastSpeakerID: String?,
                                               using rng: inout R) -> [Character] {
        let cast = Self.unique(present)
        var order: [Character] = []
        var turns: [String: Int] = [:]
        var last = lastSpeakerID
        for _ in 0..<max(count, 0) {
            let candidates = cast.filter { $0.id != last }
            guard let fewest = candidates.map({ turns[$0.id, default: 0] }).min() else { break }
            let pool = candidates.filter { turns[$0.id, default: 0] == fewest }
            let pick = pool[Int.random(in: 0..<pool.count, using: &rng)]
            order.append(pick)
            turns[pick.id, default: 0] += 1
            last = pick.id
        }
        return order
    }

    // MARK: - Town events

    /// Events about the character first, then about people they have a relationship with, then the
    /// rest of the town news; newest first within each group.
    func relevantEvents(for character: Character, from events: [WorldEvent], limit: Int) -> [WorldEvent] {
        relevantEvents(forAll: [character], from: events, limit: limit)
    }

    /// Same ranking for a group (used by scenes).
    func relevantEvents(forAll characters: [Character], from events: [WorldEvent], limit: Int) -> [WorldEvent] {
        guard limit > 0 else { return [] }
        let selves = Set(characters.map(\.id))
        let friends = Set(characters.flatMap { $0.relationships.map(\.characterID) }).subtracting(selves)
        func score(_ e: WorldEvent) -> Int {
            let ids = Set(e.characterIDs)
            if !ids.isDisjoint(with: selves) { return 2 }
            return ids.isDisjoint(with: friends) ? 0 : 1
        }
        let ranked = events.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            if sa != sb { return sa > sb }
            if a.element.date != b.element.date { return a.element.date > b.element.date }
            return a.offset < b.offset
        }
        return Array(ranked.prefix(limit).map(\.element))
    }

    // MARK: - Small decisions

    private static let photoWords = "(?:photo|photos|pic|pics|picture|pictures|image|images|selfie|snapshot|drawing|sketch|postcard)"
    private static let photoAsks: [NSRegularExpression] = [
        #"\b(send|show|share|snap|take|draw|sketch|paint|make)\s+(me|us)\b[^.!?\n]{0,25}\b"# + photoWords,
        #"\b(can|could|would|will)\s+(you|u)\s+(please\s+|pls\s+)?(send|show|share|snap|take|draw|sketch|paint|make|get)\b[^.!?\n]{0,25}\b"# + photoWords,
        #"(^|[.!?\n]\s*)(please\s+|pls\s+|plz\s+)?(send|show|share|snap|take|draw|sketch|paint)\b[^.!?\n]{0,25}\b"# + photoWords,
        #"\b(can|could|may)\s+i\s+see\b[^.!?\n]{0,20}\b"# + photoWords,
        #"\b(let\s+me|lemme)\s+see\b[^.!?\n]{0,20}\b"# + photoWords,
        #"\b(i'd|i\s+would)\s+love\s+(to\s+see\s+)?(a|an|the|your|some)\b[^.!?\n]{0,20}\b"# + photoWords,
        #"\b(wanna|want\s+to)\s+see\b[^.!?\n]{0,20}\b"# + photoWords,
        #"\b(any|got)\s+(a\s+|an\s+)?"# + photoWords + #"\s+of\b"#,
    ].compactMap { BrainText.regex($0) }
    private static let photoRefusals = BrainText.regex(#"\b(don't|dont|do\s+not|never|no\s+need\s+to)\s+(send|show|share)\b|\bno\s+"# + photoWords + #"\b"#)

    /// True when the user is asking a character to send a picture ("send me a pic of the harbor").
    static func userAskedForPhoto(_ text: String) -> Bool {
        let t = BrainText.fold(text)
        if let refusal = photoRefusals, BrainText.matches(refusal, t) { return false }
        return photoAsks.contains { BrainText.matches($0, t) }
    }

    /// True with probability `chance` (0 never, 1 always).
    static func roll<R: RandomNumberGenerator>(_ chance: Double, using rng: inout R) -> Bool {
        guard chance > 0 else { return false }
        guard chance < 1 else { return true }
        return Double.random(in: 0..<1, using: &rng) < chance
    }

    // MARK: - Helpers

    private static func unique(_ characters: [Character]) -> [Character] {
        var seen = Set<String>()
        return characters.filter { seen.insert($0.id).inserted }
    }

    /// Present characters named in the text, in the order they are first mentioned.
    private static func mentioned(_ cast: [Character], in text: String) -> [Character] {
        let folded = BrainText.fold(text)
        return cast.compactMap { ch in BrainText.firstMention(of: BrainText.nameKeys(ch.name), in: folded).map { (ch, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// The character named in the user's previous line (the transcript may or may not already end
    /// with the current line; if it does, that one is skipped).
    private func previouslyAddressed(_ cast: [Character], transcript: [Message], currentText: String) -> Character? {
        var userLines = transcript.filter { $0.role == .user }.map(\.text)
        if let last = userLines.last, BrainText.trimmed(last) == BrainText.trimmed(currentText) { userLines.removeLast() }
        guard let previous = userLines.last else { return nil }
        return Self.mentioned(cast, in: previous).first
    }

    /// Characters ordered by how long ago they last spoke (never spoken first); random tie-breaks.
    private func leastRecent<R: RandomNumberGenerator>(_ cast: [Character], transcript: [Message],
                                                       using rng: inout R) -> [Character] {
        var lastSpoke: [String: Int] = [:]
        for (i, m) in transcript.enumerated() where m.role == .character {
            if let id = m.speakerID { lastSpoke[id] = i }
        }
        return cast.map { ($0, lastSpoke[$0.id] ?? -1, rng.next()) }
            .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
            .map(\.0)
    }
}

/// Small, fast, seedable random numbers (SplitMix64), so director choices can be replayed in tests.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
