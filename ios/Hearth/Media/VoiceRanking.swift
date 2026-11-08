// Chooses system voices for characters: ranks installed voices, drops novelty and legacy ones,
// and gives each character a stable voice that fits its VoiceStyle. Pure logic, unit-tested.

import AVFoundation

/// One installed voice, as the voice picker shows it.
struct VoiceOption: Identifiable, Hashable, Sendable {
    /// AVSpeechSynthesisVoice identifier.
    var id: String
    /// "Samantha" (without the quality suffix).
    var name: String
    /// "Premium", "Enhanced" or "Default".
    var quality: String
    /// "female", "male" or "neutral".
    var gender: String
    /// BCP-47 code such as "en-US".
    var language: String

    /// "English (United States)" in the user's own language.
    var languageName: String { Locale.current.localizedString(forIdentifier: language) ?? language }
}

/// What ranking needs to know about a voice. Built from AVSpeechSynthesisVoice, or by hand in tests.
struct VoiceCandidate: Hashable, Sendable {
    var identifier: String
    /// Name as the system reports it, e.g. "Samantha (Enhanced)".
    var name: String
    var language: String
    /// 1 = default, 2 = enhanced, 3 = premium (AVSpeechSynthesisVoiceQuality raw values).
    var quality: Int
    /// "female", "male" or "neutral".
    var gender: String
    var isNovelty: Bool
    var isPersonal: Bool

    init(identifier: String? = nil, name: String, quality: Int, language: String, gender: String = "neutral",
         isNovelty: Bool = false, isPersonal: Bool = false) {
        self.identifier = identifier ?? "test.\(language).\(name)"
        self.name = name
        self.quality = quality
        self.language = language
        self.gender = gender
        self.isNovelty = isNovelty
        self.isPersonal = isPersonal
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        let gender: String
        switch voice.gender {
        case .female: gender = "female"
        case .male: gender = "male"
        default: gender = "neutral"
        }
        self.init(identifier: voice.identifier, name: voice.name, quality: voice.quality.rawValue,
                  language: voice.language, gender: gender,
                  isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
                  isPersonal: voice.voiceTraits.contains(.isPersonalVoice))
    }

    /// "Samantha (Enhanced)" -> "Samantha", "Eddy (German (Germany))" -> "Eddy".
    var family: String {
        let base = name.components(separatedBy: " (").first ?? name
        return base.trimmingCharacters(in: .whitespaces)
    }

    var isEnglish: Bool { language.lowercased().hasPrefix("en") }

    var qualityName: String {
        switch quality {
        case 3...: return "Premium"
        case 2: return "Enhanced"
        default: return "Default"
        }
    }

    var option: VoiceOption {
        VoiceOption(id: identifier, name: family, quality: qualityName, gender: gender, language: language)
    }

    /// One voice per name and accent ("Daniel|en-gb").
    fileprivate var familyKey: String { "\(family.lowercased())|\(language.lowercased())" }
}

enum VoiceRanking {
    /// Novelty, legacy and Eloquence voices that sound like sound effects or old computers.
    static let excludedNames: Set<String> = [
        "albert", "bad news", "bahh", "bells", "boing", "bubbles", "cellos", "good news", "jester", "organ",
        "superstar", "trinoids", "whisper", "wobble", "zarvox", "fred", "junior", "kathy", "ralph",
        "eddy", "flo", "grandma", "grandpa", "reed", "rocko", "sandy", "shelley",
    ]

    /// Personal Voice is never used automatically (and never asked for).
    static func isUsable(_ voice: VoiceCandidate) -> Bool {
        if voice.isNovelty || voice.isPersonal { return false }
        if voice.identifier.hasPrefix("com.apple.eloquence") { return false }
        return !excludedNames.contains(voice.family.lowercased())
    }

    /// Voices for the picker: English first, then Premium > Enhanced > Default, then the user's own
    /// region, then a few familiar accents, then name.
    static func ranked(_ voices: [VoiceCandidate], region: String? = Locale.current.region?.identifier) -> [VoiceCandidate] {
        let regions = [region?.uppercased(), "US", "GB", "AU", "IE", "CA", "NZ", "IN", "ZA"].compactMap { $0 }
        func regionRank(_ voice: VoiceCandidate) -> Int {
            let code = voice.language.split(separator: "-").last.map { $0.uppercased() } ?? ""
            return regions.firstIndex(of: code) ?? regions.count
        }
        return voices.filter(isUsable).sorted { a, b in
            if a.isEnglish != b.isEnglish { return a.isEnglish }
            if a.quality != b.quality { return a.quality > b.quality }
            if a.isEnglish, regionRank(a) != regionRank(b) { return regionRank(a) < regionRank(b) }
            if a.language != b.language { return a.language < b.language }
            if a.family != b.family { return a.family < b.family }
            return a.identifier < b.identifier
        }
    }

    /// The voice for a character. Order: an installed `preferredVoiceNames` match, then a stable pick
    /// (hash of the id) among voices matching the style's locale and gender, one per name and accent,
    /// each at its best installed quality. `usage` (voice family -> times used) steers the pick toward
    /// voices nobody has yet; leave it empty for a pure hash pick.
    static func pick(for style: VoiceStyle, characterID: String, from voices: [VoiceCandidate],
                     usage: [String: Int] = [:]) -> VoiceCandidate? {
        let usable = voices.filter(isUsable)
        let wantedLocale = style.locale.map(normalizedLocale)

        for wanted in style.preferredVoiceNames ?? [] {
            let matches = usable.filter {
                $0.family.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame
            }
            let best = matches.max { a, b in
                let aLocale = a.language.lowercased() == wantedLocale, bLocale = b.language.lowercased() == wantedLocale
                if aLocale != bLocale { return bLocale }
                if a.quality != b.quality { return a.quality < b.quality }
                return a.identifier > b.identifier
            }
            if let best { return best }
        }

        let families = familyPool(for: style, in: usable)
        guard !families.isEmpty else { return nil }
        let start = Int(stableHash(characterID) % UInt64(families.count))
        var chosen = start
        for step in 0..<families.count {
            let index = (start + step) % families.count
            if usage[families[index].familyKey, default: 0] < usage[families[chosen].familyKey, default: 0] {
                chosen = index
            }
        }
        return families[chosen]
    }

    /// Voices for a whole cast, in order (built-in residents first, then the user's own), so that
    /// characters share a voice only once every fitting voice is taken. Returns characterID -> identifier.
    static func distinctAssignment(for cast: [Character], from voices: [VoiceCandidate]) -> [String: String] {
        var usage: [String: Int] = [:]
        var result: [String: String] = [:]
        for character in cast where result[character.id] == nil {
            guard let voice = pick(for: character.voice, characterID: character.id, from: voices, usage: usage) else { continue }
            result[character.id] = voice.identifier
            usage[voice.familyKey, default: 0] += 1
        }
        return result
    }

    /// FNV-1a: the same id always gives the same number (Swift's hashValue changes every launch).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Voices that fit a style, best variant per name and accent, in a fixed order.
    private static func familyPool(for style: VoiceStyle, in usable: [VoiceCandidate]) -> [VoiceCandidate] {
        let english = usable.filter(\.isEnglish)
        var pool: [VoiceCandidate]
        if let raw = style.locale, !raw.isEmpty {
            let locale = normalizedLocale(raw)
            let language = locale.split(separator: "-").first.map(String.init) ?? locale
            let exact = usable.filter { $0.language.lowercased() == locale }
            let sameLanguage = usable.filter { $0.language.lowercased().hasPrefix(language) }
            pool = !exact.isEmpty ? exact : (!sameLanguage.isEmpty ? sameLanguage : english)
        } else {
            // No locale asked for: any English accent, which gives the town more distinct voices.
            pool = english
        }
        if pool.isEmpty { pool = usable }

        if let gender = style.gender?.lowercased(), gender == "female" || gender == "male" {
            let matching = pool.filter { $0.gender == gender }
            if !matching.isEmpty { pool = matching }
        }

        var best: [String: VoiceCandidate] = [:]
        for voice in pool {
            if let current = best[voice.familyKey],
               current.quality > voice.quality || (current.quality == voice.quality && current.identifier < voice.identifier) {
                continue
            }
            best[voice.familyKey] = voice
        }
        return best.values.sorted { $0.familyKey < $1.familyKey }
    }

    private static func normalizedLocale(_ locale: String) -> String {
        locale.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
