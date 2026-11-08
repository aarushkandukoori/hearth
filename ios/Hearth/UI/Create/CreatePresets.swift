// Ready-made looks for Create: emoji for animal folk (and a few cozy things) and warm two-color palettes
// for the gradient behind them. A palette also sets the character's accent color.

import Foundation

enum CreatePresets {
    struct Palette: Identifiable, Hashable {
        let name: String
        /// Dark then light, like the residents' gradients.
        let colors: [String]
        /// The character's accent color (rings, tints on their profile).
        let accent: String

        var id: String { name }
    }

    static let defaultPalette = Palette(name: "Ember", colors: ["#5A2E1C", "#FF8A4C"], accent: "#FF8A4C")

    static let palettes: [Palette] = [
        defaultPalette,
        Palette(name: "Lantern", colors: ["#5A4320", "#F6C177"], accent: "#F6C177"),
        Palette(name: "Driftwood", colors: ["#4A3022", "#D9A066"], accent: "#D9A066"),
        Palette(name: "Sea glass", colors: ["#1F4250", "#6FB7C9"], accent: "#6FB7C9"),
        Palette(name: "Tide pool", colors: ["#1F3B3A", "#6FB7A8"], accent: "#6FB7A8"),
        Palette(name: "Moss", colors: ["#2E4A3F", "#7FB69B"], accent: "#7FB69B"),
        Palette(name: "Fern", colors: ["#1F3A24", "#9CC08A"], accent: "#9CC08A"),
        Palette(name: "Blossom", colors: ["#5A2A33", "#E58FA0"], accent: "#E58FA0"),
        Palette(name: "Paper lantern", colors: ["#3A1C2A", "#E8735F"], accent: "#E8735F"),
        Palette(name: "Lavender", colors: ["#3B3058", "#B9A2E8"], accent: "#B9A2E8"),
        Palette(name: "Night sky", colors: ["#141B33", "#9DB8F2"], accent: "#9DB8F2"),
        Palette(name: "Arcade", colors: ["#2A1A40", "#C77DFF"], accent: "#C77DFF"),
    ]

    /// Animal folk first, then a few things that suit a seaside town.
    static let emoji: [String] = [
        "🦊", "🦦", "🐢", "🦔", "🐼", "🐈", "🦉", "🦌", "🐕", "🪿", "🐲", "🦝",
        "🐻", "🐰", "🐸", "🐧", "🦭", "🐙", "🐝", "🐿️", "🦥", "🐨", "🐹", "🦙",
        "🐳", "🦀", "🐑", "🦄", "🦋", "🐌", "🦜", "🦢", "🐴", "🐮", "🐷", "🐭",
        "🐯", "🦁", "🐺", "🐬", "🦩", "🦚", "🤖", "🌙", "⭐️", "🌿", "🍄", "🌻",
        "🕯️", "🌊", "☕️", "📚", "🎨", "🎻", "🧶", "🪴",
    ]

    /// Emoji a brand-new character may start with.
    static let starterEmoji = ["🦊", "🦦", "🦔", "🐼", "🦉", "🐻", "🐰", "🐧", "🦭", "🐨", "🦙", "🐝"]

    /// The last emoji in typed text (people may type a few), or nil when there is none.
    static func lastEmoji(in text: String) -> String? {
        text.reversed().first { letter in
            letter.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }
        }.map { String($0) }
    }
}
