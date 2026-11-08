// Helpers shared by the Home, Search, Profile and Chats screens: friendly wording, short times, chat
// previews, who is out in Lantern Bay right now, and the character card file used by "Share card".

import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Wording

enum HomeText {
    /// "Good evening" for the hour (after midnight it is just "Hello").
    static func greeting(at date: Date, calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: date) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<24: return "Good evening"
        default: return "Hello"
        }
    }

    static func dayPartName(_ part: DayPart) -> String {
        switch part {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    /// The user's name from their persona, or "friend".
    static func personaName(_ persona: UserPersona) -> String {
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "friend" : name
    }

    /// "The Lighthouse" -> "Lighthouse", for small badges.
    static func shortPlaceName(_ location: Location) -> String {
        location.name.hasPrefix("The ") ? String(location.name.dropFirst(4)) : location.name
    }

    /// A location's art, falling back to its emoji or symbol (location art refs carry only colors).
    static func locationArt(_ location: Location) -> AvatarRef {
        var ref = location.art
        if ref.emoji == nil { ref.emoji = location.emoji }
        if ref.symbol == nil { ref.symbol = location.symbol }
        return ref
    }

    /// "At the Lighthouse", "At Driftwood Cafe" (or "at the Lighthouse" in the middle of a sentence).
    static func atPlace(_ location: Location, startsSentence: Bool = true) -> String {
        let at = startsSentence ? "At" : "at"
        return location.name.hasPrefix("The ") ? "\(at) the " + location.name.dropFirst(4) : "\(at) " + location.name
    }

    /// "baking cinnamon buns" -> "Baking cinnamon buns."
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "" }
        let capitalized = first.uppercased() + trimmed.dropFirst()
        return ".!?".contains(capitalized.last ?? ".") ? capitalized : capitalized + "."
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "@lanternbay" from "lanternbay" or "@lanternbay".
    static func handle(_ creator: String) -> String {
        let name = creator.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "@you" }
        return name.hasPrefix("@") ? name : "@" + name
    }

    /// "River otter · @lanternbay"
    static func speciesAndCreator(_ c: Character) -> String {
        let species = c.species.map { capitalizedFirst($0.trimmingCharacters(in: .whitespaces)) } ?? ""
        return species.isEmpty ? handle(c.creator) : "\(species) · \(handle(c.creator))"
    }

    /// "Juno", "Juno and Felix", "Juno, Felix and Wren".
    static func names(_ list: [String]) -> String {
        list.formatted(.list(type: .and))
    }

    // MARK: Times

    /// "now", "5m", "3h", "Yesterday", "Tue", "Oct 3".
    static func shortTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What VoiceOver says for a short time: "5 minutes ago".
    static func spokenTime(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return spokenFormatter.localizedString(for: date, relativeTo: now)
    }

    private static let spokenFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    // MARK: Chat previews

    /// The last line of a chat for a list: "You: long day", "Sent a picture", "Juno: Oh hi!".
    /// `speakerName` is used for character lines in group scenes.
    static func preview(of conversation: Conversation, speakerName: ((String) -> String?)? = nil) -> String {
        guard let last = conversation.messages.last(where: { $0.role != .narrator }) else { return "" }
        var text = withoutActions(last.text)
        switch last.attachment?.kind {
        case .photo?: if text.isEmpty { text = "Sent a photo" }
        case .picture?: if text.isEmpty { text = "Sent a picture" }
        case .voice?: text = text.isEmpty ? "Voice note" : "Voice note: \(text)"
        case nil: break
        }
        switch last.role {
        case .user:
            return "You: " + text
        case .character:
            if let speakerName, let id = last.speakerID, let name = speakerName(id) { return "\(name): \(text)" }
            return text
        case .narrator:
            return text
        }
    }

    /// "*waves* Oh hi!" -> "Oh hi!" (or "waves" when the message is only an action).
    static func withoutActions(_ text: String) -> String {
        let spoken = text.replacingOccurrences(of: #"\*[^*\n]+\*"#, with: " ", options: .regularExpression)
        let tidy = collapsed(spoken)
        return tidy.isEmpty ? collapsed(text.replacingOccurrences(of: "*", with: "")) : tidy
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Ignores case and accents, for matching search text.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Who is out in town right now

/// Where every resident is at one moment, from their daily schedule (WorldDirector).
struct HomeTownSnapshot {
    struct Sighting: Identifiable {
        let character: Character
        let location: Location
        let activity: String
        /// Somewhere other than home, e.g. Juno swimming at the harbor in the evening.
        let awayFromHome: Bool
        /// Not asleep or winding down at home (see `isUp`).
        let isUp: Bool
        var id: String { character.id }
    }

    let part: DayPart
    let sightings: [Sighting]

    init(world: WorldDefinition, director: WorldDirector, now: Date) {
        let part = director.part(at: now)
        self.part = part
        sightings = world.characters.compactMap { c in
            guard let location = director.location(of: c, at: now) else { return nil }
            let activity = director.activity(of: c, at: now)
            return Sighting(character: c, location: location, activity: activity,
                            awayFromHome: c.homeLocationID != location.id,
                            isUp: Self.isUp(activity: activity, part: part))
        }
    }

    /// Residents who are up and about, the ones away from home first.
    var upAndAbout: [Sighting] {
        sightings.filter(\.isUp).filter(\.awayFromHome) + sightings.filter(\.isUp).filter { !$0.awayFromHome }
    }

    /// Where someone is right now (residents only).
    func sighting(for characterID: String) -> Sighting? {
        sightings.first { $0.character.id == characterID }
    }

    /// The schedule has no "asleep" flag, so this reads the activity: anyone sleeping or dozing is
    /// resting, and at night anyone tucked in at home ("at home with cocoa", "in her nook") is too.
    /// Night owls keep a public activity ("on the air", "keeping watch over the light").
    static func isUp(activity: String, part: DayPart) -> Bool {
        let text = activity.lowercased()
        if ["sleep", "in bed", "dozing", "dreaming"].contains(where: { text.contains($0) }) { return false }
        guard part == .night else { return true }
        let tuckedIn = ["in ", "at home", "upstairs", "on his ", "on her ", "aboard", "curled", "recharging"]
        return !tuckedIn.contains(where: { text.hasPrefix($0) })
    }
}

// MARK: - Featured residents

enum HomeFeatured {
    /// Three residents that change four times a day (each part of the day), the same for everyone looking.
    static func picks(from residents: [Character], at date: Date, calendar: Calendar = .current) -> [Character] {
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        let part = DayPart.allCases.firstIndex(of: DayPart.at(date, calendar: calendar)) ?? 0
        var rng = SeededRNG(seed: UInt64(day * 4 + part))
        return Array(residents.shuffled(using: &rng).prefix(3))
    }
}

// MARK: - Sharing a character card

/// A user-made character as a Character Card V2 .json file, written only when the user shares it.
struct HomeCharacterCardFile: Transferable {
    let character: Character

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { card in
            SentTransferredFile(try card.writeFile())
        }
    }

    /// Writes the card to a private temporary folder (cleared by "Delete everything" and by iOS).
    func writeFile() throws -> URL {
        let data = try CharacterCardIO.exportV2JSON(character)
        let url = Self.folder.appendingPathComponent(fileName)
        try HearthPaths.write(data, to: url)
        return url
    }

    /// "Captain Bea.json", with characters that don't belong in file names removed.
    var fileName: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(character.name.unicodeScalars.filter { allowed.contains($0) })
            .trimmingCharacters(in: .whitespaces)
        return (cleaned.isEmpty ? "Character" : cleaned) + ".json"
    }

    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("card-export", isDirectory: true)
    }

    /// Removes cards written for earlier shares.
    static func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
    }
}

