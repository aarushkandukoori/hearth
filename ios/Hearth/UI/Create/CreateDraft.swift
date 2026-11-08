// The character being made or edited in Create: plain fields the form edits, turned into a `Character`
// for the live preview and for Library.save. A new picture stays in memory until Save writes it.

import SwiftUI
import UIKit

/// A picture picked, drawn or imported in Create. It stays in memory until Save writes it to disk.
struct CreatePicture: Equatable {
    let id = UUID()
    /// A clean JPEG: the right way up, at most 1024 px, with no location or camera details.
    let data: Data
    let preview: UIImage

    static func == (a: CreatePicture, b: CreatePicture) -> Bool { a.id == b.id }

    /// Cleans any image file (HEIC, PNG, JPEG...) into an avatar picture, off the main thread.
    static func make(from raw: Data) async throws -> CreatePicture {
        try await Task.detached(priority: .userInitiated) {
            let jpeg = try AvatarJPEG.make(from: raw, maxPixels: 1024, quality: 0.9)
            guard let image = UIImage(data: jpeg) else { throw LibraryError.imageUnreadable }
            return CreatePicture(data: jpeg, preview: image.preparingForDisplay() ?? image)
        }.value
    }
}

/// The avatar part of a draft: an emoji on a two-color gradient, or a picture.
struct CreateAvatar: Equatable {
    var emoji = "🦊"
    var symbol: String?
    var colors = ["#5A2E1C", "#FF8A4C"]
    /// A picture already saved for this character (path inside the media folder).
    var file: String?
    /// A bundled portrait, kept when copying a Lantern Bay resident.
    var asset: String?
    /// A new picture waiting for Save. It wins over `file` and `asset`.
    var picture: CreatePicture?
    /// The idea behind a drawn picture.
    var artPrompt: String?

    var hasPicture: Bool { picture != nil || file != nil || asset != nil }

    /// Back to the emoji on its gradient.
    mutating func removePicture() {
        picture = nil
        file = nil
        asset = nil
    }

    /// What AvatarView can draw. A new picture isn't on disk yet, so the preview shows it separately.
    var ref: AvatarRef {
        AvatarRef(asset: asset, file: file, emoji: emoji.isEmpty ? nil : emoji, symbol: symbol, colors: colors)
    }
}

struct CreateDraft: Equatable {
    /// Name and tagline stop at their limit. The others are gentle limits: long text crowds the chat.
    enum Limit {
        static let name = 30
        static let tagline = 70
        static let bio = 600
        static let greeting = 800
        static let personality = 1500
        static let style = 500
        static let example = 1500
        static let scenario = 500
    }

    /// "" until Library.save gives the character an id.
    var id = ""
    var name = ""
    var species = ""
    var tagline = ""
    var bio = ""
    var greeting = ""
    var personality = ""
    var speakingStyle = ""
    var exampleDialogue = ""
    var scenario = ""
    var categories: Set<String> = []
    var avatar = CreateAvatar()
    var accentHex = "#FF8A4C"
    /// The system voice picked in Create (an identifier). nil lets Hearth choose.
    var voiceID: String?
    var pitch: Float = 1
    var rate: Float = 0.5
    var voiceNoteChance = MediaHabits().voiceNoteChance
    var photoChance = MediaHabits().photoChance
    var livesInTown = false
    var homeLocationID: String?
    /// Places for the parts of the day that differ from home.
    var dayPlaces: [DayPart: String] = [:]
    /// The character this draft started from. Keeps what the form doesn't show (alternate greetings, tags...).
    var base: Character?

    init() {}

    /// A blank character with a random emoji and palette.
    static func fresh() -> CreateDraft {
        var draft = CreateDraft()
        let palette = CreatePresets.palettes.randomElement() ?? CreatePresets.defaultPalette
        draft.avatar.emoji = CreatePresets.starterEmoji.randomElement() ?? "🦊"
        draft.avatar.colors = palette.colors
        draft.accentHex = palette.accent
        return draft
    }

    init(from c: Character, voiceID: String?) {
        id = c.id
        name = c.name
        species = c.species ?? ""
        tagline = c.tagline
        bio = c.bio
        greeting = c.greeting
        personality = c.personality
        speakingStyle = c.speakingStyle
        exampleDialogue = c.exampleDialogue ?? ""
        scenario = c.scenario ?? ""
        categories = Set(c.categories)
        avatar.emoji = c.avatar.emoji ?? ""
        avatar.symbol = c.avatar.symbol
        if avatar.emoji.isEmpty && avatar.symbol == nil { avatar.emoji = "🙂" }
        avatar.colors = c.avatar.colors ?? CreatePresets.defaultPalette.colors
        avatar.file = c.avatar.file
        avatar.asset = c.avatar.asset
        avatar.artPrompt = c.artPrompt
        accentHex = c.accentHex
        self.voiceID = voiceID
        pitch = c.voice.pitch
        rate = c.voice.rate
        voiceNoteChance = c.media.voiceNoteChance
        photoChance = c.media.photoChance
        let home = c.homeLocationID ?? c.schedule.first { $0.part == .night }?.locationID
        homeLocationID = home
        livesInTown = home != nil
        for slot in c.schedule where slot.locationID != home {
            dayPlaces[slot.part] = slot.locationID
        }
        base = c
    }

    // MARK: Checks

    /// The first required field that is still empty: the name, then the greeting.
    var firstMissingField: CreateFocus? {
        if Self.tidy(name).isEmpty { return .name }
        if Self.tidy(greeting).isEmpty { return .greeting }
        return nil
    }

    /// True when the advanced definition has anything in it (so the form opens it).
    var hasDefinition: Bool {
        ![speakingStyle, exampleDialogue, scenario].allSatisfy { Self.tidy($0).isEmpty }
    }

    /// The draft as it would be saved, for spotting unsaved changes.
    var comparable: CreateDraft {
        var d = self
        let texts: [WritableKeyPath<CreateDraft, String>] = [
            \.name, \.species, \.tagline, \.bio, \.greeting, \.personality, \.speakingStyle, \.exampleDialogue, \.scenario,
        ]
        for path in texts { d[keyPath: path] = Self.tidy(d[keyPath: path]) }
        if !d.livesInTown {
            d.homeLocationID = nil
            d.dayPlaces = [:]
        }
        return d
    }

    /// A starting idea for "Draw it for me".
    var drawingIdea: String {
        if let idea = avatar.artPrompt, !Self.tidy(idea).isEmpty { return idea }
        let kind = Self.plainSpecies(species)
        guard !kind.isEmpty else { return "" }
        return "A friendly \(kind), head-and-shoulders portrait, soft simple background"
    }

    // MARK: Building the character

    /// The character Library.save stores. `voice` is the chosen voice (nil lets Hearth pick one).
    func makeCharacter(voice: VoiceOption?, world: WorldDefinition) -> Character {
        var c = base ?? Character(id: "", name: "", tagline: "", bio: "", greeting: "", personality: "",
                                  speakingStyle: "", avatar: AvatarRef(), accentHex: accentHex)
        c.id = id
        c.name = Self.tidy(name)
        let kind = Self.plainSpecies(species)
        c.species = kind.isEmpty ? nil : kind
        c.tagline = Self.tidy(tagline)
        c.bio = Self.tidy(bio)
        c.greeting = Self.tidy(greeting)
        c.personality = Self.tidy(personality)
        c.speakingStyle = Self.tidy(speakingStyle)
        c.exampleDialogue = Self.tidy(exampleDialogue).isEmpty ? nil : Self.tidy(exampleDialogue)
        c.scenario = Self.tidy(scenario).isEmpty ? nil : Self.tidy(scenario)
        // Town categories in their usual order; ones this town doesn't know (from a card) stay at the end.
        let known = world.categories.map(\.id)
        c.categories = known.filter(categories.contains) + categories.filter { !known.contains($0) }.sorted()
        c.avatar = avatar.ref
        c.artPrompt = avatar.artPrompt
        c.accentHex = accentHex
        c.voice.pitch = pitch
        c.voice.rate = rate
        if let voice {
            c.voice.preferredVoiceNames = [voice.name]
            c.voice.locale = voice.language
            c.voice.gender = voice.gender
        } else {
            c.voice.preferredVoiceNames = nil
        }
        c.media.voiceNoteChance = voiceNoteChance
        c.media.photoChance = photoChance
        let places = Set(world.locations.map(\.id))
        if livesInTown, let home = homeLocationID, places.contains(home) {
            c.homeLocationID = home
            c.schedule = DayPart.allCases.map { part in
                var place = dayPlaces[part] ?? home
                if !places.contains(place) { place = home }
                // Keep an activity the character already had there; otherwise a gentle default.
                let kept = base?.schedule.first { $0.part == part && $0.locationID == place }?.activity
                return ScheduleSlot(part: part, locationID: place, activity: kept ?? Self.defaultActivity(part))
            }
        } else {
            c.homeLocationID = nil
            c.schedule = []
        }
        c.isBuiltIn = false
        return c
    }

    // MARK: Text helpers

    static func tidy(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "a sleepy corgi" -> "sleepy corgi" (the prompts add their own "a" or "an").
    static func plainSpecies(_ text: String) -> String {
        let t = tidy(text)
        for article in ["a ", "an ", "the "] where t.lowercased().hasPrefix(article) {
            return tidy(String(t.dropFirst(article.count)))
        }
        return t
    }

    /// At most `limit` characters, cut at a word with "…" when it has to be shortened.
    static func shortened(_ text: String, to limit: Int) -> String {
        let t = tidy(text)
        guard t.count > limit else { return t }
        let head = String(t.prefix(limit - 1))
        let cut = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return tidy(cut) + "…"
    }

    /// What a resident is doing at a part of the day, for the prompt ("You are at the harbor, ...").
    static func defaultActivity(_ part: DayPart) -> String {
        switch part {
        case .morning: return "easing into the morning"
        case .afternoon: return "spending a quiet afternoon here"
        case .evening: return "enjoying the evening"
        case .night: return "winding down for the night"
        }
    }
}
