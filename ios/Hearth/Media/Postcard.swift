// The postcard a character sends when no town art fits: a warm gradient in the
// character's colors, a symbol that fits the caption, and the caption in New York serif.

import SwiftUI

enum Postcard {
    static let side: CGFloat = 1024

    /// Renders a 1024 x 1024 postcard (SwiftUI rendering, so main actor).
    @MainActor static func render(caption: String, character: Character?) -> CGImage? {
        let colors = gradient(for: character)
        let card = PostcardView(caption: displayCaption(caption), signature: character.map { "from \($0.name)" },
                                symbol: symbol(for: caption), top: colors.top, bottom: colors.bottom)
        let renderer = ImageRenderer(content: card)
        renderer.proposedSize = ProposedViewSize(width: side, height: side)
        renderer.scale = 1
        return renderer.cgImage
    }

    /// An SF Symbol that fits the caption ("tea at dawn" -> cup.and.saucer.fill), else sparkles.
    /// Things come before weather and time of day, so the subject wins.
    static func symbol(for caption: String) -> String {
        let words = PictureMaker.keywords(in: caption)
        return symbolKeywords.first { !$0.words.isDisjoint(with: words) }?.symbol ?? "sparkles"
    }

    static let symbolKeywords: [(symbol: String, words: Set<String>)] = [
        ("cup.and.saucer.fill", ["tea", "coffee", "cup", "mug", "cocoa", "teapot", "kettle", "latte", "cafe"]),
        ("book.fill", ["book", "library", "reading", "story", "poem", "page", "novel", "diary", "journal"]),
        ("music.note", ["music", "song", "guitar", "fiddle", "piano", "melody", "singing", "tune", "band", "violin"]),
        ("fish.fill", ["fish", "fishing", "catch", "trout", "salmon", "minnow"]),
        ("sailboat.fill", ["boat", "sail", "sailboat", "ship", "harbor", "harbour", "dock", "pier", "rowboat"]),
        ("birthday.cake.fill", ["cake", "bread", "bake", "baking", "pie", "pastry", "cookie", "bun", "muffin", "scone"]),
        ("leaf.fill", ["leaf", "leaves", "garden", "plant", "flower", "tree", "forest", "moss", "fern", "herb", "meadow"]),
        ("pawprint.fill", ["paw", "pawprint", "pet", "kitten", "puppy", "footprint", "track"]),
        ("water.waves", ["sea", "ocean", "wave", "tide", "beach", "shore", "surf", "water", "lake", "river", "pond"]),
        ("flame.fill", ["fire", "fireplace", "hearth", "candle", "lantern", "campfire", "bonfire"]),
        ("snowflake", ["snow", "snowy", "frost", "winter", "ice", "icy"]),
        ("cloud.rain.fill", ["rain", "rainy", "storm", "drizzle", "puddle", "umbrella"]),
        ("moon.stars.fill", ["moon", "night", "star", "starry", "midnight", "constellation", "evening"]),
        ("sun.horizon.fill", ["sun", "sunrise", "sunset", "dawn", "dusk", "morning", "sunny", "sunlight", "horizon"]),
        ("house.fill", ["home", "house", "cottage", "porch", "window", "room", "kitchen"]),
        ("envelope.fill", ["letter", "mail", "postcard", "note", "envelope", "parcel"]),
        ("heart.fill", ["love", "heart", "hug", "friendship", "thanks", "grateful"]),
    ]

    /// "the harbor at dawn" -> "The harbor at dawn"
    static func displayCaption(_ caption: String) -> String {
        let clean = PictureMaker.cleanCaption(caption)
        guard let first = clean.first else { return "Greetings from Lantern Bay" }
        return first.uppercased() + clean.dropFirst()
    }

    /// The character's avatar colors, else its accent (lighter at the top, deeper at the bottom),
    /// else Hearth's ember into a deeper ember (dark enough for white text).
    static func gradient(for character: Character?) -> (top: Color, bottom: Color) {
        if let colors = character?.avatar.colors, colors.count >= 2, let top = rgb(colors[0]), let bottom = rgb(colors[1]) {
            return (color(top), color(bottom))
        }
        if let hex = character?.accentHex, let accent = rgb(hex) {
            return (color(mix(accent, (1, 1, 1), 0.12)), color(mix(accent, (0.078, 0.067, 0.063), 0.5)))
        }
        return (color((0.949, 0.631, 0.373)), color((0.725, 0.333, 0.18)))
    }

    typealias RGB = (r: Double, g: Double, b: Double)

    /// "#FF8A4C" -> (1, 0.54, 0.30)
    static func rgb(_ hex: String) -> RGB? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func mix(_ a: RGB, _ b: RGB, _ amount: Double) -> RGB {
        (a.r + (b.r - a.r) * amount, a.g + (b.g - a.g) * amount, a.b + (b.b - a.b) * amount)
    }

    private static func color(_ c: RGB) -> Color {
        Color(red: c.r, green: c.g, blue: c.b)
    }
}

private struct PostcardView: View {
    var caption: String
    var signature: String?
    var symbol: String
    var top: Color
    var bottom: Color

    var body: some View {
        ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 640, height: 640)
                .blur(radius: 70)
                .offset(x: 260, y: -280)
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 5)
                .padding(40)
            VStack(spacing: 0) {
                Text("LANTERN BAY")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer(minLength: 40)
                Image(systemName: symbol)
                    .font(.system(size: 240, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                Spacer(minLength: 48)
                Text(caption)
                    .font(.system(size: 64, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                Spacer(minLength: 40)
                if let signature {
                    Text(signature)
                        .font(.system(size: 38, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .padding(.horizontal, 110)
            .padding(.vertical, 100)
        }
        .frame(width: 1024, height: 1024)
    }
}
