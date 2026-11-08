// Hearth's colors (SPEC §3): warm, dark-first tokens that switch between light and dark automatically,
// plus a forgiving hex parser for colors that come from content (avatar gradients, character accents).

import SwiftUI
import UIKit

/// sRGB components (0...1) read from "#RGB", "#RGBA", "#RRGGBB" or "#RRGGBBAA". The "#" is optional.
/// Eight digits are red, green, blue, alpha (the CSS order, same as the website).
struct HexColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    /// What `Color(hex:)` uses for unreadable input: Hearth's muted gray, so bad content never turns invisible.
    static let fallback = HexColor(red: 138 / 255, green: 127 / 255, blue: 116 / 255)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init?(_ string: String) {
        var hex = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard [3, 4, 6, 8].contains(hex.count), hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }

        // Short forms repeat each digit: "F80" means "FF8800".
        let full = hex.count <= 4 ? String(hex.flatMap { [$0, $0] }) : hex
        guard let value = UInt32(full, radix: 16) else { return nil }
        let rgba = full.count == 8 ? value : (value << 8) | 0xFF

        red = Double((rgba >> 24) & 0xFF) / 255
        green = Double((rgba >> 16) & 0xFF) / 255
        blue = Double((rgba >> 8) & 0xFF) / 255
        alpha = Double(rgba & 0xFF) / 255
    }
}

extension Color {
    /// A color from a hex string like "#FF8A4C". Unreadable strings give `HexColor.fallback`.
    init(hex: String) {
        let c = HexColor(hex) ?? .fallback
        self.init(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
    }

    static let hearthBackground = HearthPalette.background
    static let hearthSurface = HearthPalette.surface
    static let hearthSurface2 = HearthPalette.surface2
    static let hearthLine = HearthPalette.line
    static let hearthText = HearthPalette.text
    static let hearthText2 = HearthPalette.text2
    static let hearthMuted = HearthPalette.muted
    static let hearthAccent = HearthPalette.accent
    /// The accent for words ("Try again", "Edit"): darker in light mode so small text stays readable.
    static let hearthAccentText = HearthPalette.accentText
    static let hearthGold = HearthPalette.gold
    static let hearthSea = HearthPalette.sea
    static let hearthSuccess = HearthPalette.success
    static let hearthDanger = HearthPalette.danger
    /// Text and icons drawn on a `hearthAccent` fill, like the label of a primary button.
    static let hearthOnAccent = HearthPalette.onAccent
}

// Lets views write `.foregroundStyle(.hearthText)` as well as `Color.hearthText`.
extension ShapeStyle where Self == Color {
    static var hearthBackground: Color { HearthPalette.background }
    static var hearthSurface: Color { HearthPalette.surface }
    static var hearthSurface2: Color { HearthPalette.surface2 }
    static var hearthLine: Color { HearthPalette.line }
    static var hearthText: Color { HearthPalette.text }
    static var hearthText2: Color { HearthPalette.text2 }
    static var hearthMuted: Color { HearthPalette.muted }
    static var hearthAccent: Color { HearthPalette.accent }
    static var hearthAccentText: Color { HearthPalette.accentText }
    static var hearthGold: Color { HearthPalette.gold }
    static var hearthSea: Color { HearthPalette.sea }
    static var hearthSuccess: Color { HearthPalette.success }
    static var hearthDanger: Color { HearthPalette.danger }
    static var hearthOnAccent: Color { HearthPalette.onAccent }
}

/// The palette values, light and dark. Sea, success and danger have no light values in the spec,
/// so the light ones here are darker versions picked to stay readable (about 4.5:1) on the light background.
/// For the same reason light mode darkens muted text, uses a darker accent for words (accentText), and puts
/// dark text on accent fills, as the web app does (white on the light accent is only 3.3:1).
enum HearthPalette {
    static let background = dynamic(light: "#FBF7F2", dark: "#141110")
    static let surface = dynamic(light: "#FFFFFF", dark: "#1D1916")
    static let surface2 = dynamic(light: "#F3ECE3", dark: "#26211D")
    static let line = dynamic(light: "#E7DDD1", dark: "#332C26")
    static let text = dynamic(light: "#211B16", dark: "#F4EDE4")
    static let text2 = dynamic(light: "#5C5047", dark: "#B9AEA2")
    static let muted = dynamic(light: "#6F6358", dark: "#8A7F74")
    static let accent = dynamic(light: "#E8682E", dark: "#FF8A4C")
    static let accentText = dynamic(light: "#B4481A", dark: "#FF8A4C")
    static let gold = dynamic(light: "#C98A2B", dark: "#F6C177")
    static let sea = dynamic(light: "#2A7387", dark: "#6FB7C9")
    static let success = dynamic(light: "#37775A", dark: "#7FB69B")
    static let danger = dynamic(light: "#C4453A", dark: "#E5675B")
    static let onAccent = dynamic(light: "#1A1310", dark: "#1A1310")

    /// A color that follows the system (or `.preferredColorScheme`) light/dark setting.
    static func dynamic(light: String, dark: String) -> Color {
        let lightColor = uiColor(light)
        let darkColor = uiColor(dark)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }

    private static func uiColor(_ hex: String) -> UIColor {
        let c = HexColor(hex) ?? .fallback
        return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
