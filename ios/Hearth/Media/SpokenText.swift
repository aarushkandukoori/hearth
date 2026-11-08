// What a reply sounds like out loud: no *actions*, emoji, [photo: ...] tags or markdown symbols.
// Also cuts streaming text into finished sentences so live speech can start early.

import Foundation

extension VoiceStudio {
    /// "*waves* Morning! 😊\n[photo: the harbor]" -> "Morning!"
    nonisolated static func spokenText(_ text: String) -> String {
        var s = text
        // Photo tags (the picture itself carries that), then markdown that wraps real words.
        s = s.replacingOccurrences(of: #"\[(photo|picture|image)\s*:[^\]]*\]"#, with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~([^~]+)~~"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "`", with: "")
        // *Actions* are narration, not speech. A lone leftover asterisk just goes.
        s = s.replacingOccurrences(of: #"\*[^*]*\*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: #"(?<!\w)_([^_\n]+)_(?!\w)"#, with: "$1", options: .regularExpression)
        // Headings, quotes and list markers at the start of a line.
        s = s.replacingOccurrences(of: #"(?m)^[ \t]*(#{1,6}|>|[-•]|\d+[.)])[ \t]+"#, with: "", options: .regularExpression)
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isEmojiScalar($0) }))

        // Each line becomes a sentence, so the voice pauses where the text breaks.
        let lines = s.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in line.contains { $0.isLetter || $0.isNumber } }
        var out = lines.map { line in
            guard let last = line.last, !".!?…,;:\"”')".contains(last) else { return line }
            return line + "."
        }.joined(separator: " ")
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.!?;:…])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([.!?])[,;:]+"#, with: "$1", options: .regularExpression)
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—").union(.whitespacesAndNewlines))
    }

    /// Splits text that is still streaming into finished sentences and the unfinished rest.
    /// It never cuts inside *an action* or a [photo: ...] tag. Typical use while a reply streams:
    ///
    ///     buffer += token
    ///     let (ready, rest) = VoiceStudio.splitSentences(buffer)
    ///     buffer = rest
    ///     for sentence in ready { voice.enqueueSpoken(sentence, as: character, overrides: overrides) }
    ///     // when the stream ends: voice.enqueueSpoken(buffer, as: character, overrides: overrides)
    nonisolated static func splitSentences(_ buffer: String) -> (ready: [String], remainder: String) {
        let chars = Array(buffer)
        var ready: [String] = []
        var current = ""
        var inAction = false
        var inTag = false
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            current.append(ch)
            var boundary = false
            if ch == "*" {
                inAction.toggle()
            } else if ch == "[" {
                inTag = true
            } else if ch == "]" {
                inTag = false
            } else if !inAction && !inTag {
                if ch == "\n" {
                    boundary = true
                } else if ".!?…".contains(ch) {
                    // Keep closing quotes and repeated marks with the sentence ("Really?!" stays whole).
                    var next = index + 1
                    while next < chars.count, "\"'”’)!?.…".contains(chars[next]) {
                        current.append(chars[next])
                        next += 1
                    }
                    index = next - 1
                    // Only a following space proves the sentence is over; "3." might become "3.5".
                    boundary = next < chars.count && chars[next].isWhitespace && !endsWithAbbreviation(current)
                }
            }
            if boundary {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { ready.append(sentence) }
                current = ""
            }
            index += 1
        }
        return (ready, current)
    }

    nonisolated private static func endsWithAbbreviation(_ text: String) -> Bool {
        let lastWord = text.split(separator: " ").last.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        return ["mr", "mrs", "ms", "dr", "st", "mt", "jr", "sr", "vs"].contains(lastWord)
    }

    /// Emoji, skin tones, joiners and variation selectors. Digits, # and * count as "emoji" in
    /// Unicode, so plain characters below U+238C are kept.
    nonisolated static func isEmojiScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D, 0xFE0E, 0xFE0F, 0x20E3, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F:
            return true
        default:
            let properties = scalar.properties
            return properties.isEmojiPresentation || (properties.isEmoji && scalar.value > 0x238C)
        }
    }
}
