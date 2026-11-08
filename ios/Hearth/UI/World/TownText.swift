// Small words and helpers shared by the Town and scene screens: part-of-day labels, place phrasing,
// name lists and *action* styling for character lines. Pure functions, no state.

import SwiftUI

enum TownText {
    static func label(_ part: DayPart) -> String {
        switch part {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    static func symbol(_ part: DayPart) -> String {
        switch part {
        case .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening: return "sunset.fill"
        case .night: return "moon.stars.fill"
        }
    }

    /// Bundled hero art for a part of the day (the dusk picture works for every part but night).
    static func heroAsset(_ part: DayPart) -> String {
        part == .night ? "hero-night" : "hero-town"
    }

    /// "7:42 PM", in the person's own clock format.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Evening · 7:42 PM"
    static func nowLine(_ date: Date, calendar: Calendar = .current) -> String {
        "\(label(DayPart.at(date, calendar: calendar))) · \(clock(date))"
    }

    /// "The Lighthouse" -> "the Lighthouse", for use in the middle of a sentence.
    static func inSentence(_ placeName: String) -> String {
        placeName.hasPrefix("The ") ? "the " + placeName.dropFirst(4) : placeName
    }

    /// "At Driftwood Cafe", "At the Lighthouse".
    static func at(_ placeName: String) -> String {
        "At " + inSentence(placeName)
    }

    /// Short map label: "Driftwood Cafe" -> "Cafe", "The Night Market" -> "Market".
    static func shortName(_ placeName: String) -> String {
        let words = placeName.split(separator: " ").filter { $0 != "The" }
        return words.last.map(String.init) ?? placeName
    }

    /// "Juno", "Juno and Felix", "Juno, Felix, and Ada" (in the person's language).
    static func names(_ people: [Character]) -> String {
        people.map(\.name).formatted(.list(type: .and))
    }

    /// "river otter" -> "River otter".
    static func capitalizedFirst(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "Theo comes over from the Lighthouse to join you." Used as the scene's invite note.
    static func arrival(of name: String, from: Location?, to place: Location) -> String {
        guard let from, from.id != place.id else { return "\(name) comes over to join you." }
        return "\(name) comes over from \(inSentence(from.name)) to join you."
    }

    /// A line with *actions* set apart (italic, a softer color) and the asterisks removed. A lone asterisk
    /// stays as typed. SF Pro Rounded has no italic, so actions use the standard system face in italic at
    /// `textStyle` (match the Text's own HearthFont: .callout for HearthFont.body, .footnote for caption).
    static func styled(_ text: String, textStyle: Font.TextStyle = .callout) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "*"),
              let close = rest[rest.index(after: open)...].firstIndex(of: "*") {
            result += AttributedString(String(rest[..<open]))
            var action = AttributedString(String(rest[rest.index(after: open)..<close]))
            action.inlinePresentationIntent = .emphasized
            action.swiftUI.font = .system(textStyle).italic()
            action.swiftUI.foregroundColor = .hearthText2
            result += action
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }

    /// The same line without asterisks, for VoiceOver and copying.
    static func plain(_ text: String) -> String {
        String(styled(text).characters)
    }

    /// A moment inside `part` on the same day as `now` (or `now` itself when it is that part already).
    /// Used to ask the director who is where when peeking at another time.
    static func sampleDate(for part: DayPart, near now: Date, calendar: Calendar = .current) -> Date {
        if DayPart.at(now, calendar: calendar) == part { return now }
        let hour: Int
        switch part {
        case .morning: hour = 8
        case .afternoon: hour = 14
        case .evening: hour = 19
        case .night: hour = 23
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
    }

    /// A compact engine line under a reply when "Show engine stats" is on (counts and timings only).
    static func statsLine(_ stats: GenerationStats) -> String {
        var parts = [stats.engine, "\(stats.promptTokens) prompt", "\(stats.reusedTokens) reused"]
        parts.append(String(format: "%.2f s first word", stats.timeToFirstToken))
        if stats.decodeTokensPerSecond > 0 { parts.append(String(format: "%.0f tok/s", stats.decodeTokensPerSecond)) }
        if stats.restoredFromDisk { parts.append("resumed from flash") }
        return parts.joined(separator: " · ")
    }
}
