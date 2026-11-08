// Imports Character Card V1, V2 and V3 files (JSON, or a PNG with the card inside a text chunk) and
// exports a Hearth character as a V2 card. Imported characters live outside the town (no home, no schedule).

import Foundation

enum CharacterCardError: LocalizedError, Equatable {
    case unreadable
    case tooLarge
    case notACard
    case missingName
    case charxUnsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file couldn't be opened."
        case .tooLarge: return "This file is too big to be a character card."
        case .notACard: return "This doesn't look like a character card. Hearth can read Character Card V1, V2 and V3 files saved as .png or .json."
        case .missingName: return "This character card has no name in it."
        case .charxUnsupported: return "CHARX files can't be opened yet. If you can, save the card as .png or .json instead."
        }
    }
}

/// Hearth-only fields kept inside an exported card (data.extensions.hearth), so a card made in Hearth
/// comes back exactly as it left.
struct HearthCardExtension: Codable, Hashable, Sendable {
    var species: String?
    var tagline: String?
    var bio: String?
    var personality: String?
    var speakingStyle: String?
    var accentHex: String?
    var emoji: String?
    var symbol: String?
    var colors: [String]?
    var categories: [String]?
    var voice: VoiceStyle?
    var media: MediaHabits?

    init(_ c: Character) {
        species = c.species
        tagline = c.tagline
        bio = c.bio
        personality = c.personality
        speakingStyle = c.speakingStyle
        accentHex = c.accentHex
        emoji = c.avatar.emoji
        symbol = c.avatar.symbol
        colors = c.avatar.colors
        categories = c.categories
        voice = c.voice
        media = c.media
    }

    func apply(to c: inout Character) {
        if let species { c.species = species }
        if let tagline, !tagline.isEmpty { c.tagline = tagline }
        if let bio { c.bio = bio }
        if let personality, !personality.isEmpty { c.personality = personality }
        if let speakingStyle { c.speakingStyle = speakingStyle }
        if let accentHex, !accentHex.isEmpty { c.accentHex = accentHex }
        if emoji != nil || symbol != nil {
            c.avatar.emoji = emoji
            c.avatar.symbol = symbol
        }
        if let colors { c.avatar.colors = colors }
        if let categories { c.categories = categories }
        if let voice { c.voice = voice }
        if let media { c.media = media }
    }
}

enum CharacterCardIO {
    static let maxFileBytes = 40 * 1024 * 1024

    /// Reads a card file the user picked (works with security-scoped URLs from the Files app).
    /// `avatar` is the PNG itself when the card was a picture; save it with Library.saveAvatar.
    static func importCard(from url: URL) throws -> (character: Character, avatar: Data?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes {
            throw CharacterCardError.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw CharacterCardError.unreadable }
        return try importCard(data: data, fileName: url.lastPathComponent)
    }

    /// The returned character has an empty id: Library.save gives it one.
    static func importCard(data: Data, fileName: String) throws -> (character: Character, avatar: Data?) {
        guard data.count <= maxFileBytes else { throw CharacterCardError.tooLarge }
        if CardPNGText.isPNG(data) {
            let chunks = CardPNGText.textChunks(in: data)
            var lastError = CharacterCardError.notACard
            // V3 first: when a picture carries both, it is the newer, fuller copy.
            for keyword in ["ccv3", "chara"] {
                guard let text = chunks[keyword], let json = CardPNGText.cardJSON(fromChunkText: text) else { continue }
                do {
                    return (try character(fromCardJSON: json), data)
                } catch let error as CharacterCardError {
                    lastError = error
                }
            }
            throw lastError
        }
        let isZip = data.starts(with: [0x50, 0x4B, 0x03, 0x04])
        if isZip || fileName.lowercased().hasSuffix(".charx") { throw CharacterCardError.charxUnsupported }
        return (try character(fromCardJSON: data), nil)
    }

    /// A V2 card (pretty JSON) that other apps can read. Hearth-only fields ride along under
    /// data.extensions.hearth. The user's own "@you" handle isn't written into the card.
    static func exportV2JSON(_ c: Character) throws -> Data {
        var description = c.personality
        if !c.speakingStyle.isEmpty {
            description += (description.isEmpty ? "" : "\n\n") + "How {{char}} talks: " + c.speakingStyle
        }
        var creator = c.creator.hasPrefix("@") ? String(c.creator.dropFirst()) : c.creator
        if creator == "you" { creator = "" }
        let card = CardV2(data: CardV2.Fields(
            name: c.name,
            description: description,
            personality: c.tagline,
            scenario: c.scenario ?? "",
            first_mes: c.greeting,
            mes_example: c.exampleDialogue ?? "",
            creator_notes: c.bio,
            system_prompt: "",
            post_history_instructions: "",
            alternate_greetings: c.altGreetings,
            tags: c.tags,
            creator: creator,
            character_version: "1",
            extensions: ["hearth": HearthCardExtension(c)]))
        return try StoreJSON.encoder(pretty: true).encode(card)
    }

    /// Fills {{user}} and {{char}} (any capitalization, and the older <USER> and <BOT>) with names.
    static func fillPlaceholders(_ text: String, user: String, char: String) -> String {
        var out = text
        for (pattern, value) in [("{{user}}", user), ("<user>", user), ("{{char}}", char), ("<bot>", char)] {
            out = out.replacingOccurrences(of: pattern, with: value, options: .caseInsensitive)
        }
        return out
    }

    // MARK: Reading a card

    /// Maps card fields to a Hearth character: description -> bio (about 400 characters, ending at a
    /// sentence) and personality (description + personality), first_mes -> greeting, and so on.
    /// System prompts and jailbreak fields in cards are ignored on purpose.
    static func character(fromCardJSON data: Data) throws -> Character {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CharacterCardError.notACard
        }
        // V2 ("chara_card_v2") and V3 ("chara_card_v3") keep the card under "data"; V1 is flat.
        let fields = (root["data"] as? [String: Any]) ?? root
        let name = text(fields, "name", "char_name")
        let description = text(fields, "description", "char_persona")
        let personality = text(fields, "personality")
        let scenario = text(fields, "scenario", "world_scenario")
        let firstMessage = text(fields, "first_mes", "char_greeting")
        let examples = text(fields, "mes_example", "example_dialogue")
        guard [description, personality, scenario, firstMessage, examples].contains(where: { !$0.isEmpty }) else {
            throw CharacterCardError.notACard
        }
        guard !name.isEmpty else { throw CharacterCardError.missingName }

        let look = looks.randomElement() ?? looks[0]
        let bio = excerpt(forReading(collapsed(description.isEmpty ? personality : description), name: name), limit: 400)
        let definition = description == personality
            ? description
            : [description, personality].filter { !$0.isEmpty }.joined(separator: "\n\n")
        var character = Character(
            id: "",
            name: name,
            tagline: bio.isEmpty ? "Imported character" : excerpt(bio, limit: 90),
            bio: bio,
            greeting: firstMessage.isEmpty ? "Hi, I'm \(name)." : firstMessage,
            altGreetings: list(fields, "alternate_greetings"),
            personality: definition,
            speakingStyle: "",
            scenario: scenario.isEmpty ? nil : scenario,
            exampleDialogue: examples.isEmpty ? nil : examples,
            tags: Array(list(fields, "tags").prefix(12)),
            avatar: AvatarRef(emoji: look.emoji, colors: look.colors),
            accentHex: look.accent,
            creator: handle(text(fields, "creator")))
        if let hearth = (fields["extensions"] as? [String: Any])?["hearth"],
           let extra = try? StoreJSON.decode(HearthCardExtension.self, fromObject: hearth) {
            extra.apply(to: &character)
        }
        return character
    }

    /// About `limit` characters, ending at a sentence when one ends late enough, otherwise at a word.
    static func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.lastIndex(where: { ".!?".contains($0) }),
           head.distance(from: head.startIndex, to: end) >= limit / 3 {
            return String(head[...end])
        }
        if let space = head.lastIndex(of: " ") { return String(head[..<space]) + "…" }
        return head + "…"
    }

    /// Accent color, avatar gradient and emoji for an imported character (one picked at random).
    private static let looks: [(accent: String, colors: [String], emoji: String)] = [
        ("#FF8A4C", ["#5A2E1C", "#FF8A4C"], "🕯️"),
        ("#F6C177", ["#5A4320", "#F6C177"], "🌙"),
        ("#6FB7C9", ["#1F4250", "#6FB7C9"], "🌊"),
        ("#7FB69B", ["#2E4A3F", "#7FB69B"], "🌿"),
        ("#E58FA0", ["#5A2A33", "#E58FA0"], "🌸"),
        ("#B9A2E8", ["#3B3058", "#B9A2E8"], "✨"),
    ]

    private static func text(_ fields: [String: Any], _ keys: String...) -> String {
        for key in keys {
            guard let value = fields[key] as? String else { continue }
            let cleaned = normalizedNewlines(value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return ""
    }

    /// A list field; also accepts one comma-separated string (some cards store tags that way).
    private static func list(_ fields: [String: Any], _ key: String) -> [String] {
        let raw: [String]
        if let array = fields[key] as? [Any] {
            raw = array.compactMap { $0 as? String }
        } else if let joined = fields[key] as? String {
            raw = joined.split(separator: ",").map(String.init)
        } else {
            raw = []
        }
        return raw.map { normalizedNewlines($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// "@kata" for the card's creator, "@imported" when the card doesn't say.
    private static func handle(_ creator: String) -> String {
        let compact = String(creator.filter { !$0.isWhitespace }.prefix(40))
        guard !compact.isEmpty else { return "@imported" }
        return compact.hasPrefix("@") ? compact : "@" + compact
    }

    /// For text the user reads (the bio): {{char}} becomes the name and {{user}} becomes "you".
    private static func forReading(_ text: String, name: String) -> String {
        var out = text
        for pattern in ["{{user}}'s", "<user>'s"] {
            out = out.replacingOccurrences(of: pattern, with: "your", options: .caseInsensitive)
        }
        out = fillPlaceholders(out, user: "you", char: name)
        for (wrong, right) in [("\\byou is\\b", "you are"), ("\\byou was\\b", "you were"), ("\\byou has\\b", "you have")] {
            out = out.replacingOccurrences(of: wrong, with: right, options: [.regularExpression, .caseInsensitive])
        }
        if out.hasPrefix("you ") || out.hasPrefix("your ") { out = out.prefix(1).uppercased() + out.dropFirst() }
        return out.replacingOccurrences(of: ". you", with: ". You").replacingOccurrences(of: ". your", with: ". Your")
    }
}

/// Character Card V2 layout. Field names follow the card spec.
private struct CardV2: Encodable {
    var spec = "chara_card_v2"
    var spec_version = "2.0"
    var data: Fields

    struct Fields: Encodable {
        var name: String
        var description: String
        var personality: String
        var scenario: String
        var first_mes: String
        var mes_example: String
        var creator_notes: String
        var system_prompt: String
        var post_history_instructions: String
        var alternate_greetings: [String]
        var tags: [String]
        var creator: String
        var character_version: String
        var extensions: [String: HearthCardExtension]
    }
}
