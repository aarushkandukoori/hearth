// Pure helpers behind the chat screen (no state, unit-tested in ChatTests): live text while a reply
// streams, when a reply suits a voice note, swipe decisions, the caring line, pinned-memory text, the
// stats line and time labels. Also ChatSpeechFeeder (speaks a streaming reply sentence by sentence) and
// ChatMarkup.

import Foundation
import SwiftUI

enum ChatPipeline {
    /// Replies longer than this (as spoken) stay text instead of becoming voice notes.
    static let voiceNoteMaxCharacters = 280
    /// A gap this long between two messages shows a time label between them.
    static let timeGap: TimeInterval = 30 * 60

    // MARK: Streaming

    /// What the chat shows while a reply streams: no "Name:" label (not even half of one), nothing
    /// from a [photo: ...] tag on, and no line where the model starts writing for the user.
    static func liveText(_ raw: String, speakerName: String, userName: String) -> String {
        var text = ReplyParser.stripTemplateTokens(raw)
        text = ReplyParser.cutAtSpeakerLines(text, names: [userName, "You", "User"])
        text = ReplyParser.stripLeadingName(text, speakerName)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Ju" or "**Juno" could still turn into the label "Juno:", so wait for the next piece.
        let bare = text.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))
        if !bare.isEmpty, (speakerName + ":").lowercased().hasPrefix(bare.lowercased()) { return "" }

        if let bracket = text.firstIndex(of: "[") { text = String(text[..<bracket]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Short replies with real words can become voice notes; long ones and pure *actions* stay text.
    static func suitsVoiceNote(_ text: String) -> Bool {
        let spoken = VoiceStudio.spokenText(text)
        return !spoken.isEmpty && spoken.count <= voiceNoteMaxCharacters
    }

    /// The voice note to play for a message, if it has one that matches what is shown. A character's
    /// voice note belongs to one swipe alternate (its transcript), so other alternates show as text.
    /// A recording whose file isn't on this iPhone (a backup restored on another phone holds text only)
    /// shows as plain text too.
    static func playableVoice(_ message: Message, fileExists: (String) -> Bool = ChatPipeline.mediaFileExists) -> Attachment? {
        guard let a = message.attachment, a.kind == .voice, a.status == .ready, let file = a.file, !file.isEmpty,
              fileExists(file) else { return nil }
        if message.role == .user { return a }
        return a.caption == message.text ? a : nil
    }

    /// True when a file under HearthPaths.media is on this iPhone.
    static func mediaFileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: HearthPaths.mediaURL(relativePath).path)
    }

    // MARK: Safety

    /// The fixed, caring answer a friend gives when the model can't answer someone who may be hurting
    /// (it declined, failed, or found no words). Real help first; no em dashes in copy.
    static func caringLine(userName: String) -> String {
        "*sets everything down and sits close* \(userName), I'm really glad you told me. You matter. "
            + "If you're thinking about hurting yourself, please call or text 988 (in the US), or text HOME to 741741, "
            + "to talk with someone right now. I'm right here with you."
    }

    // MARK: Swipes

    enum AlternateStep: Equatable {
        case select(Int)
        case generate
        case none
    }

    /// Swiping the last reply: move between its alternates, or past the last one write a new one.
    static func alternateStep(selected: Int, count: Int, delta: Int, canGenerate: Bool) -> AlternateStep {
        guard delta != 0, count > 0 else { return .none }
        let target = selected + delta
        if target >= 0 && target < count { return .select(target) }
        if target >= count && delta > 0 && canGenerate { return .generate }
        return .none
    }

    /// Index of the character reply that can be swiped: the last one, as long as the user hasn't
    /// written since (notes from the app don't count).
    static func lastReplyIndex(in messages: [Message]) -> Int? {
        for index in messages.indices.reversed() {
            switch messages[index].role {
            case .narrator: continue
            case .user: return nil
            case .character: return index
            }
        }
        return nil
    }

    // MARK: Memory

    /// The fact a pinned message becomes. The user's own words stay as they are; a character's line
    /// says who said it, so the memory reads clearly later ("Juno said: ...").
    static func pinText(for message: Message, characterName: String) -> String {
        let body = BrainText.shortened(ChatMarkup.plain(message.text), maxChars: 200)
        let caption = BrainText.shortened(message.attachment?.caption ?? "", maxChars: 160)
        switch message.role {
        case .user:
            if !body.isEmpty { return body }
            return caption.isEmpty ? "" : "Sent a photo: \(caption)"
        case .character:
            if !body.isEmpty { return "\(characterName) said: \(body)" }
            return caption.isEmpty ? "" : "\(characterName) sent a picture: \(caption)"
        case .narrator:
            return body
        }
    }

    /// The summary prompt runs once per `MemoryKeeper.summarizeEvery` user messages.
    static func summaryDue(userMessages: Int, summarizedBlocks: Int) -> Bool {
        userMessages / MemoryKeeper.summarizeEvery > summarizedBlocks
    }

    // MARK: Labels

    /// "on-device · 21 tok/s · first token 420 ms · reused 812 · resumed from flash in 140 ms".
    /// Canned demo replies say so instead of "on-device", since no model wrote them.
    static func statsLine(_ s: GenerationStats) -> String {
        var parts = [s.engine == "mock" ? "demo reply, no AI" : "on-device"]
        if s.decodeTokensPerSecond > 0 { parts.append("\(Int(s.decodeTokensPerSecond.rounded())) tok/s") }
        if s.timeToFirstToken > 0 {
            parts.append(s.timeToFirstToken < 1
                ? "first token \(Int((s.timeToFirstToken * 1000).rounded())) ms"
                : String(format: "first token %.1f s", s.timeToFirstToken))
        }
        if s.reusedTokens > 0 { parts.append("reused \(s.reusedTokens)") }
        if s.restoredFromDisk, let ms = s.restoreMilliseconds { parts.append("resumed from flash in \(Int(ms.rounded())) ms") }
        if s.stoppedBy == "cancelled" { parts.append("stopped") }
        return parts.joined(separator: " · ")
    }

    /// True when a time label belongs above this message (the first one, or after a long pause).
    static func startsTimeGroup(previous: Date?, current: Date, gap: TimeInterval = timeGap) -> Bool {
        guard let previous else { return true }
        return current.timeIntervalSince(previous) >= gap
    }

    /// "Today 4:12 PM", "Yesterday 9:03 AM", "Mon 4:12 PM" or "Nov 2, 4:12 PM".
    static func timeLabel(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days >= 0, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// "by @juno" from a creator stored with or without the "@".
    static func byLine(_ creator: String) -> String {
        let name = creator.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "A Hearth character" }
        return "by " + (name.hasPrefix("@") ? name : "@" + name)
    }

    /// 12.4 -> "0:12", 75 -> "1:15".
    static func durationLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Feeds a streaming reply to live speech one finished sentence at a time. `feed` takes the whole
/// live text each time and returns sentences that just finished; `finish` returns what is left.
struct ChatSpeechFeeder {
    private var fed = ""
    private var buffer = ""

    mutating func feed(_ live: String) -> [String] {
        guard live.count > fed.count, live.hasPrefix(fed) else { return [] }
        buffer += live.dropFirst(fed.count)
        fed = live
        let split = VoiceStudio.splitSentences(buffer)
        buffer = split.remainder
        return split.ready
    }

    mutating func finish() -> String {
        defer { buffer = "" }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Character.AI-style text: *actions* in italics (and a softer color), **words** in bold.
enum ChatMarkup {
    struct Segment: Equatable {
        var text: String
        var italic = false
        var bold = false
    }

    /// Splits text at asterisk pairs. A star with spaces on both sides ("5 * 3") stays a star, and a
    /// run that never closes keeps its style to the end (handy while a reply streams in).
    static func segments(_ text: String) -> [Segment] {
        let chars = Array(text)
        var out: [Segment] = []
        var current = ""
        var italic = false
        var bold = false

        func flush() {
            guard !current.isEmpty else { return }
            out.append(Segment(text: current, italic: italic, bold: bold))
            current = ""
        }

        var i = 0
        while i < chars.count {
            guard chars[i] == "*" else {
                current.append(chars[i])
                i += 1
                continue
            }
            var run = 0
            while i + run < chars.count, chars[i + run] == "*" { run += 1 }
            let before: Swift.Character? = i > 0 ? chars[i - 1] : nil
            let after: Swift.Character? = i + run < chars.count ? chars[i + run] : nil
            let canOpen = after.map { !$0.isWhitespace } ?? false
            let canClose = before.map { !$0.isWhitespace } ?? false
            let wantsItalic = run == 1 || run >= 3
            let wantsBold = run >= 2
            let isOpen = (wantsItalic ? italic : true) && (wantsBold ? bold : true)
            let isClosed = (wantsItalic ? !italic : true) && (wantsBold ? !bold : true)

            if isOpen && canClose {
                flush()
                if wantsItalic { italic = false }
                if wantsBold { bold = false }
            } else if isClosed && canOpen {
                flush()
                if wantsItalic { italic = true }
                if wantsBold { bold = true }
            } else {
                current += String(repeating: "*", count: run)
            }
            i += run
        }
        flush()
        return out
    }

    /// The words without the asterisks, for VoiceOver labels ("*waves* hi" -> "waves hi").
    static func plain(_ text: String) -> String {
        segments(text).map(\.text).joined()
    }

    /// The styled text for a SwiftUI Text. Actions use `actionColor` and an italic face; everything
    /// else keeps the Text's own color and font. `style` should match the Text's text style (chat
    /// text uses HearthFont.body, which is .callout) so Dynamic Type sizes stay the same.
    static func attributed(_ text: String, actionColor: Color, style: Font.TextStyle = .callout) -> AttributedString {
        var result = AttributedString()
        for segment in segments(text) {
            var piece = AttributedString(segment.text)
            var intent: InlinePresentationIntent = []
            if segment.italic { intent.insert(.emphasized) }
            if segment.bold { intent.insert(.stronglyEmphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if segment.italic {
                // SF Pro Rounded has no italic face, so actions use SF Pro's italic at the same size.
                let italic = Font.system(style).italic()
                piece[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = segment.bold ? italic.bold() : italic
                piece[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = actionColor
            }
            result += piece
        }
        return result
    }
}
