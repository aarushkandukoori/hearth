// Core data models shared by every part of Hearth.
// The world/cast types decode content/lantern-bay.json (same file the website reads).

import Foundation

// MARK: - World content (decoded from lantern-bay.json)

/// How to draw an avatar or a piece of art. The UI tries, in order: file, asset, emoji, symbol.
struct AvatarRef: Codable, Hashable, Sendable {
    /// Bundled image name in Resources/Art without extension, e.g. "char-juno".
    var asset: String?
    /// Path relative to `HearthPaths.media` for user-made images.
    var file: String?
    var emoji: String?
    /// SF Symbol name used when there is no image and no emoji.
    var symbol: String?
    /// Hex colors for the gradient behind emoji/symbol fallbacks, e.g. ["#2E4A3F", "#7FB69B"].
    var colors: [String]?
}

struct VoiceStyle: Codable, Hashable, Sendable {
    /// "female", "male" or "neutral". Only a hint for picking a system voice.
    var gender: String?
    /// AVSpeechUtterance pitchMultiplier, 0.5...2.0 (1.0 = normal).
    var pitch: Float = 1.0
    /// 0...1 where 0.5 is a normal speaking rate.
    var rate: Float = 0.5
    var preferredVoiceNames: [String]?
    var locale: String?
}

struct MediaHabits: Codable, Hashable, Sendable {
    /// Chance (0...1) that a reply becomes a voice note.
    var voiceNoteChance: Double = 0.1
    /// Chance (0...1) that the character may spontaneously share a photo in a reply.
    var photoChance: Double = 0.08
    /// Things this character might photograph. Never people.
    var photoIdeas: [String] = []
}

enum DayPart: String, Codable, CaseIterable, Sendable {
    case morning, afternoon, evening, night

    /// 5-11 morning, 11-17 afternoon, 17-22 evening, else night (local time).
    static func at(_ date: Date = .now, calendar: Calendar = .current) -> DayPart {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<11: return .morning
        case 11..<17: return .afternoon
        case 17..<22: return .evening
        default: return .night
        }
    }
}

struct ScheduleSlot: Codable, Hashable, Sendable {
    var part: DayPart
    var locationID: String
    var activity: String
}

struct Relationship: Codable, Hashable, Sendable {
    var characterID: String
    var kind: String
    var note: String
}

struct Character: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var species: String?
    var tagline: String
    var bio: String
    var greeting: String
    var altGreetings: [String] = []
    var personality: String
    var speakingStyle: String
    var scenario: String?
    var exampleDialogue: String?
    var categories: [String] = []
    var tags: [String] = []
    var avatar: AvatarRef
    var accentHex: String
    var voice: VoiceStyle = VoiceStyle()
    var media: MediaHabits = MediaHabits()
    var homeLocationID: String?
    var schedule: [ScheduleSlot] = []
    var relationships: [Relationship] = []
    var creator: String = "@you"
    var isBuiltIn: Bool = false
    var createdAt: Date?
    /// Image Playground prompt used to make the avatar (no humans).
    var artPrompt: String?

    /// Where this character is during a part of the day (falls back to home).
    func slot(for part: DayPart) -> ScheduleSlot? {
        schedule.first { $0.part == part }
            ?? homeLocationID.map { ScheduleSlot(part: part, locationID: $0, activity: "spending time here") }
    }
}

struct MapPoint: Codable, Hashable, Sendable {
    /// Normalized 0...1 coordinates on the town map (x right, y down).
    var x: Double
    var y: Double
}

struct Location: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var blurb: String
    var ambience: String
    var symbol: String
    var emoji: String?
    var map: MapPoint
    var art: AvatarRef
    var artPrompt: String?
}

struct CategoryDef: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String
    var emoji: String?
}

struct WorldDefinition: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var tagline: String
    var lore: String
    var categories: [CategoryDef]
    var locations: [Location]
    var characters: [Character]
    var starterEvents: [String] = []
}

// MARK: - Conversations

enum MessageRole: String, Codable, Sendable {
    case user, character, narrator
}

enum AttachmentKind: String, Codable, Sendable {
    /// A photo the user sent (described on-device by PhotoReader).
    case photo
    /// A picture a character sent (made by PictureMaker).
    case picture
    /// A voice note (character TTS or user recording). `caption` holds the transcript.
    case voice
}

enum AttachmentStatus: String, Codable, Sendable {
    case pending, ready, failed
}

struct Attachment: Codable, Hashable, Sendable {
    var kind: AttachmentKind
    /// Path relative to `HearthPaths.media`.
    var file: String?
    /// Photo description, picture caption, or voice transcript.
    var caption: String?
    /// Seconds, for voice notes.
    var duration: Double?
    var status: AttachmentStatus = .ready
    /// 32 normalized bar heights (0...1) for voice note waveforms.
    var waveform: [Float]?
}

struct Message: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var role: MessageRole
    /// Character id for `.character` messages (needed in group scenes).
    var speakerID: String?
    var createdAt: Date = .now
    /// Swipe alternates for character replies; user messages have exactly one.
    var variants: [String]
    var selected: Int = 0
    var attachment: Attachment?
    /// Character.AI-style 1-4 star rating of a reply.
    var rating: Int?
    var pinned: Bool = false
    var stats: GenerationStats?

    init(role: MessageRole, speakerID: String? = nil, text: String, attachment: Attachment? = nil) {
        self.role = role
        self.speakerID = speakerID
        self.variants = [text]
        self.attachment = attachment
    }

    var text: String {
        get { variants.indices.contains(selected) ? variants[selected] : (variants.last ?? "") }
        set {
            if variants.indices.contains(selected) { variants[selected] = newValue } else { variants = [newValue]; selected = 0 }
        }
    }
}

enum ConversationKind: Codable, Hashable, Sendable {
    case direct(characterID: String)
    case scene(locationID: String)
}

struct Conversation: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: ConversationKind
    var title: String?
    var participantIDs: [String]
    var messages: [Message] = []
    var createdAt: Date = .now
    var updatedAt: Date = .now
    var archived: Bool = false

    /// Stable key the engine uses to park/restore this conversation's KV cache.
    var engineKey: String { "conv-\(id.uuidString)" }

    var directCharacterID: String? {
        if case .direct(let id) = kind { return id }
        return nil
    }

    var sceneLocationID: String? {
        if case .scene(let id) = kind { return id }
        return nil
    }
}

// MARK: - The user, memory and the living world

struct UserPersona: Codable, Hashable, Sendable {
    var name: String = "Friend"
    var pronouns: String?
    var about: String = ""
}

enum MemorySource: String, Codable, Sendable {
    case pinned, auto, summary
}

struct MemoryFact: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    /// Which character learned this. nil = known to everyone.
    var characterID: String?
    var text: String
    var createdAt: Date = .now
    var source: MemorySource
    /// May come up with other residents when town gossip is on.
    var shareable: Bool = false
}

struct WorldEvent: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var date: Date = .now
    var text: String
    var characterIDs: [String] = []
    var locationID: String?
    var seen: Bool = false
}

// MARK: - Settings

enum PictureStyle: String, Codable, CaseIterable, Sendable {
    case animation, illustration, sketch
}

struct AppSettings: Codable, Hashable, Sendable {
    var persona = UserPersona()
    var onboardingDone = false
    var confirmedAdult = false
    /// Engine id the user chose: a ModelSpec id, "apple", or "mock".
    var preferredEngineID: String?
    var voiceNotesEnabled = true
    var autoPlayVoiceNotes = false
    var picturesEnabled = true
    var pictureStyle: PictureStyle = .animation
    var townGossip = false
    var appLock = false
    var hideInAppSwitcher = true
    var excludeFromBackup = true
    var showEngineStats = false
    var haptics = true
    /// Per-character voice override: characterID -> AVSpeechSynthesisVoice identifier.
    var voiceOverrides: [String: String] = [:]
    var lastAwayEventsAt: Date?
}
