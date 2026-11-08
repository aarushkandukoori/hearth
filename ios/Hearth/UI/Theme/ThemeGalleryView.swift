// Every Theme component on one scrolling page, for screenshot review in light and dark mode.
// Uses sample characters built in code (not the real Lantern Bay cast).

import SwiftUI

struct ThemeGalleryView: View {
    @State private var category = "All"
    @State private var rating: Int? = 3
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                intro.id("intro")
                palette.id("palette")
                typography.id("type")
                avatars.id("avatars")
                cards.id("cards")
                rows.id("rows")
                controls.id("controls")
                chatPieces.id("chat")
                containers.id("containers")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xl)
        }
        .hearthScreenBackground()
        .hearthToast($toast)
    }

    // MARK: Sections

    private var intro: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Hearth")
                .font(HearthFont.title(40))
                .foregroundStyle(.hearthText)
            Text("A little town of friends that lives on your phone.")
                .font(HearthFont.body)
                .foregroundStyle(.hearthText2)
            HStack(spacing: Spacing.s) {
                PrivacyBadge()
                PrivacyBadge("Works offline")
            }
            .padding(.top, Spacing.xs)
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Palette")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Spacing.s)], spacing: Spacing.m) {
                ForEach(Swatch.all) { swatch in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(swatch.color)
                            .frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.hearthLine, lineWidth: 1))
                        Text(swatch.name)
                            .font(HearthFont.small)
                            .foregroundStyle(.hearthText2)
                    }
                }
            }
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Type")
            Text("Lantern Bay").font(HearthFont.title(34))
            Text("Evening at the harbor").font(HearthFont.title())
            Text("Headline - Juno").font(HearthFont.headline)
            Text("Body - The kettle's on. Come sit by the window and tell me about your day.")
                .font(HearthFont.body)
            Text("Callout - Keeps the lighthouse lit").font(HearthFont.callout).foregroundStyle(.hearthText2)
            Text("Caption - by @lanternbay, 2h ago").font(HearthFont.caption).foregroundStyle(.hearthMuted)
            Text("Small - Hearth characters are AI").font(HearthFont.small).foregroundStyle(.hearthMuted)
        }
        .foregroundStyle(.hearthText)
    }

    private var avatars: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Avatars")
            HStack(alignment: .bottom, spacing: Spacing.l) {
                AvatarView(Self.cast[0].avatar, size: 32)
                AvatarView(Self.cast[1].avatar, size: 44)
                AvatarView(Self.cast[2].avatar, size: 64, ring: .hearthAccent)
                AvatarView(Self.cast[3].avatar, size: 96, shape: .rounded)
            }
            HStack(alignment: .bottom, spacing: Spacing.l) {
                AvatarView(Self.cast[4].avatar, size: 64) // SF Symbol fallback
                AvatarView(AvatarRef(emoji: "🦉"), size: 64, shape: .rounded, ring: .hearthGold) // no colors
                AvatarView(AvatarRef(asset: "char-missing", symbol: "not.a.symbol"), size: 64) // nothing usable
            }
        }
    }

    private var cards: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Featured", actionTitle: "See all") { toast = "See all tapped" }
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.m) {
                    ForEach(Self.cast) { character in
                        Button { toast = "Opening \(character.name)" } label: {
                            CharacterCardView(character: character)
                                .frame(width: 156)
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .scrollIndicators(.hidden)

            SectionHeader("Around town")
                .padding(.top, Spacing.s)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)],
                      spacing: Spacing.m) {
                ForEach(Array(Self.cast.prefix(4).enumerated()), id: \.element.id) { index, character in
                    Button { toast = "Opening \(character.name)" } label: {
                        CharacterCardView(character: character,
                                          subtitle: character.species?.capitalized,
                                          badge: Self.places[index])
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Chats")
            CharacterRowView(character: Self.cast[0], detail: "The fog rolled in early, so I lit the lamp at four.", trailing: "2m")
            Divider().overlay(Color.hearthLine)
            CharacterRowView(character: Self.cast[1], detail: "Sent a voice note", trailing: "1h")
            Divider().overlay(Color.hearthLine)
            CharacterRowView(character: Self.cast[2], detail: nil, trailing: "Tue")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SectionHeader("Controls")
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.s) {
                    ForEach(Self.categories, id: \.title) { item in
                        CategoryChip(item.title, symbol: item.symbol, selected: category == item.title) {
                            category = item.title
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            HStack(spacing: Spacing.s) {
                PillButton("Chat", symbol: "bubble.left.fill") { toast = "Primary" }
                PillButton("Call", symbol: "phone.fill", kind: .secondary) { toast = "Secondary" }
                PillButton("Not now", kind: .quiet) { toast = "Quiet" }
            }
            HStack(spacing: Spacing.s) {
                PillButton("Delete chat", symbol: "trash", kind: .danger) { toast = "Danger" }
                PillButton("Disabled") {}.disabled(true)
            }
            PillButton("Walk into town", symbol: "map.fill") { toast = "Full width" }
                .fullWidth()
        }
    }

    private var chatPieces: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SectionHeader("Chat pieces")

            HStack(alignment: .top, spacing: Spacing.s) {
                AvatarView(Self.cast[0].avatar, size: 32)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(Self.cast[0].name)
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    Text("*sets down two mugs* The lamp's lit. How was today, really?")
                        .font(HearthFont.body)
                        .foregroundStyle(.hearthText)
                    StarRatingView(rating: $rating)
                        .padding(.leading, -8)
                }
            }

            Text("Honestly a bit quiet. I'm glad you're here.")
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.hearthSurface2, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)

            HStack(alignment: .top, spacing: Spacing.s) {
                AvatarView(Self.cast[1].avatar, size: 32)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(Self.cast[1].name)
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    TypingIndicator()
                }
            }

            HStack(spacing: Spacing.m) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.hearthOnAccent)
                    .frame(width: 34, height: 34)
                    .background(Color.hearthAccent, in: Circle())
                WaveformView(samples: Self.waveform, progress: 0.4, tint: .hearthAccent)
                    .frame(height: 28)
                Text("0:12")
                    .font(HearthFont.caption.monospacedDigit())
                    .foregroundStyle(.hearthText2)
            }
            .padding(10)
            .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))
            .frame(maxWidth: 280)

            MediaImage(relativePath: "gallery/missing-picture.jpg")
                .frame(width: 220, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: Radius.bubble, style: .continuous))

            Text("Hearth characters are AI. What they say is made up.")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .frame(maxWidth: .infinity)
        }
    }

    private var containers: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SectionHeader("Containers")
            HearthCard {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack {
                        Text("Nothing leaves this iPhone")
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Spacer()
                        PrivacyBadge()
                    }
                    Text("No account, no servers, no analytics. After the one-time model download, Hearth works in Airplane Mode.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                }
            }
            HearthCard(padding: 0) {
                EmptyStateView(symbol: "lamp.table.fill",
                               title: "No chats yet",
                               message: "Say hello to someone in Lantern Bay. They're happy to meet you.",
                               actionTitle: "Find someone") { toast = "Off to town" }
                    .frame(maxWidth: .infinity)
            }
            PillButton("Show a toast", symbol: "text.bubble", kind: .secondary) {
                toast = "Saved to Juno's memory"
            }
        }
    }

    // MARK: Sample data

    private struct Swatch: Identifiable {
        let name: String
        let color: Color
        var id: String { name }

        static let all = [
            Swatch(name: "background", color: .hearthBackground), Swatch(name: "surface", color: .hearthSurface),
            Swatch(name: "surface2", color: .hearthSurface2), Swatch(name: "line", color: .hearthLine),
            Swatch(name: "text", color: .hearthText), Swatch(name: "text2", color: .hearthText2),
            Swatch(name: "muted", color: .hearthMuted), Swatch(name: "accent", color: .hearthAccent),
            Swatch(name: "gold", color: .hearthGold), Swatch(name: "sea", color: .hearthSea),
            Swatch(name: "success", color: .hearthSuccess), Swatch(name: "danger", color: .hearthDanger),
        ]
    }

    private static let categories: [(title: String, symbol: String?)] = [
        ("All", nil), ("Cozy", "cup.and.saucer.fill"), ("Helpers", "hands.sparkles.fill"),
        ("Storytellers", "book.fill"), ("Adventure", "map.fill"),
    ]

    private static let places = ["At the cafe", "At the lighthouse", "Home", "On the pier"]

    /// A made-up but natural-looking voice shape.
    private static let waveform: [Float] = (0..<32).map { index in
        let x = Double(index)
        let syllables = abs(sin(x * 0.55))
        let phrase = 0.6 + 0.4 * cos(x * 0.21)
        return Float(0.25 + 0.6 * syllables * phrase)
    }

    static let cast: [Character] = [
        sample("juno", "Juno", "otter", "Keeps the lighthouse lit and the kettle on.", "🦦", ["#24414D", "#6FB7C9"]),
        sample("bramble", "Bramble", "hedgehog", "Bakes too much bread and gives the rest away.", "🦔", ["#4A3020", "#C98A2B"]),
        sample("moss", "Moss", "tortoise", "Runs the bookshop. Never in a hurry.", "🐢", ["#24392F", "#7FB69B"]),
        sample("ember", "Ember", "fox", "Paints the harbor at sunrise, badly and happily.", "🦊", ["#4F2620", "#FF8A4C"]),
        sample("ollie", "Ollie", "owl", "Stays up late counting stars over the bay.", nil, ["#25243F", "#6B6AA8"], symbol: "moon.stars.fill"),
    ]

    private static func sample(_ id: String, _ name: String, _ species: String, _ tagline: String,
                               _ emoji: String?, _ colors: [String], symbol: String? = nil) -> Character {
        Character(id: id, name: name, species: species, tagline: tagline,
                  bio: "", greeting: "Hello!", personality: "", speakingStyle: "",
                  avatar: AvatarRef(emoji: emoji, symbol: symbol, colors: colors),
                  accentHex: colors.last ?? "#FF8A4C", creator: "@lanternbay", isBuiltIn: true)
    }
}

#Preview("Dark") {
    ThemeGalleryView().preferredColorScheme(.dark)
}

#Preview("Light") {
    ThemeGalleryView().preferredColorScheme(.light)
}
