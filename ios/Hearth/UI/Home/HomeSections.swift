// The pieces of the Home tab: greeting, first-run welcome, "Continue chatting", the Featured carousel,
// "Around town right now", "Your characters" with the Create card, and the quiet footer.

import SwiftUI

// MARK: - Greeting

struct HomeGreeting: View {
    let title: String
    /// "Lantern Bay · 8:42 PM · 6 friends are out"
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title)
                .font(HearthFont.title(30))
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(line)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .accessibilityLabel(line.replacingOccurrences(of: "\u{00A0}· ", with: ", "))
        }
        .padding(.horizontal, Spacing.l)
    }
}

// MARK: - First run

/// Shown until the user has chatted with someone, so the top of Home never looks empty.
struct HomeWelcomeCard: View {
    let worldName: String
    let residentCount: Int
    let night: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 150)
                .overlay {
                    HearthAvatarArt(ref: AvatarRef(asset: night ? "hero-night" : "hero-town", emoji: "🏮",
                                                   colors: ["#2A211B", "#FF8A4C"]),
                                    pointSize: 360)
                }
                .clipped()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Welcome to \(worldName.isEmpty ? "Lantern Bay" : worldName)")
                    .font(HearthFont.title(24))
                    .foregroundStyle(.hearthText)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
                PrivacyBadge("Everything stays on this iPhone")
                    .padding(.top, Spacing.xs)
            }
            .padding(Spacing.l)
        }
        .background(Color.hearthSurface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
    }

    private var message: String {
        switch residentCount {
        case 0: return "Make a character of your own below, then say hello. Everything you share stays with you."
        case 1: return "One neighbor lives here, with a home, a daily routine and friends of their own. Say hello below."
        default: return "\(residentCount) neighbors live here, each with a home, a daily routine and friends of their own. Pick someone below and say hello."
        }
    }
}

// MARK: - Continue chatting

struct HomeContinueItem: Identifiable {
    let conversation: Conversation
    let character: Character
    var id: UUID { conversation.id }
}

struct HomeContinueRow: View {
    let items: [HomeContinueItem]
    let now: Date
    let open: (Conversation) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Spacing.m) {
                ForEach(items) { item in
                    Button { open(item.conversation) } label: {
                        HomeContinueBubble(character: item.character,
                                           time: HomeText.shortTime(item.conversation.updatedAt, now: now))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Continue chatting with \(item.character.name)")
                    .accessibilityValue(HomeText.spokenTime(item.conversation.updatedAt, now: now))
                }
            }
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Spacing.l, for: .scrollContent)
    }
}

private struct HomeContinueBubble: View {
    let character: Character
    let time: String
    @ScaledMetric(relativeTo: .callout) private var width: CGFloat = 80

    var body: some View {
        VStack(spacing: 6) {
            AvatarView(character.avatar, size: 66, ring: Color(hex: character.accentHex))
            Text(character.name)
                .font(HearthFont.callout.weight(.semibold))
                .foregroundStyle(.hearthText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(time)
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .lineLimit(1)
        }
        .frame(width: width)
        .contentShape(Rectangle())
    }
}

// MARK: - Featured

/// Three residents, big art, swipe between them. Picks change with each part of the day.
struct HomeFeaturedCarousel: View {
    let characters: [Character]
    let place: (String) -> String?
    let open: (Character) -> Void
    let chat: (Character) -> Void
    @State private var currentID: String?

    var body: some View {
        VStack(spacing: Spacing.m) {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.m) {
                    ForEach(characters) { character in
                        HomeFeaturedCard(character: character, place: place(character.id),
                                         open: { open(character) }, chat: { chat(character) })
                            .containerRelativeFrame(.horizontal)
                            .id(character.id)
                    }
                }
                .scrollTargetLayout()
                .fixedSize(horizontal: false, vertical: true) // every card as tall as the tallest
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, Spacing.l, for: .scrollContent)

            if characters.count > 1 {
                pageDots
            }
        }
    }

    private var pageDots: some View {
        // The picks change with the part of the day, so a remembered page may no longer be there.
        let current = characters.contains { $0.id == currentID } ? currentID : characters.first?.id
        return HStack(spacing: 6) {
            ForEach(characters) { character in
                Capsule()
                    .fill(character.id == current ? Color.hearthAccent : Color.hearthLine)
                    .frame(width: character.id == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true) // swiping the cards is how VoiceOver moves between them
    }
}

private struct HomeFeaturedCard: View {
    let character: Character
    let place: String?
    let open: () -> Void
    let chat: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Not scaled: larger text makes the card taller on its own.
    private let minHeight: CGFloat = 390

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.m) {
            Spacer(minLength: 0)
            if let place {
                HomePlacePill(text: place, lines: typeSize.isAccessibilitySize ? 2 : 1)
            }
            Button(action: open) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(character.name)
                        .font(HearthFont.title(34))
                    if let species = character.species, !species.isEmpty {
                        Text(HomeText.capitalizedFirst(species))
                            .font(HearthFont.callout.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    Text(character.tagline)
                        .font(HearthFont.body)
                        .foregroundStyle(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens their profile")

            PillButton(typeSize.isAccessibilitySize ? "Chat" : "Chat with \(character.name)", symbol: "bubble.left.fill", action: chat)
                .accessibilityLabel("Chat with \(character.name)")
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .bottomLeading)
        .background { HomeFeaturedArt(character: character) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .contentShape(shape)
        .onTapGesture(perform: open) // the art itself opens the profile too
        .accessibilityElement(children: .contain)
    }
}

/// The character's art, darkened toward the bottom so white text reads in light and dark mode.
private struct HomeFeaturedArt: View {
    let character: Character

    var body: some View {
        HearthAvatarArt(ref: character.avatar, pointSize: 330)
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0), location: 0.3),
                    .init(color: .black.opacity(0.5), location: 0.58),
                    .init(color: .black.opacity(0.86), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                // A breath of the character's own color behind the text.
                RadialGradient(colors: [Color(hex: character.accentHex).opacity(0.28), .clear],
                               center: .bottomLeading, startRadius: 0, endRadius: 320)
            }
            .accessibilityHidden(true)
    }
}

/// "At Driftwood Cafe" on a dark glass pill, readable over any picture.
private struct HomePlacePill: View {
    let text: String
    let lines: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.hearthSuccess)
                .frame(width: 7, height: 7)
            Text(text)
                .font(HearthFont.small)
                .lineLimit(lines)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Around town right now

struct HomeAroundTownRow: View {
    let sightings: [HomeTownSnapshot.Sighting]
    let open: (HomeTownSnapshot.Sighting) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Spacing.m) {
                ForEach(sightings) { sighting in
                    Button { open(sighting) } label: {
                        HomeTownCard(sighting: sighting)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("\(sighting.character.name), \(HomeText.atPlace(sighting.location, startsSentence: false)), \(sighting.activity)")
                    .accessibilityHint("Opens their profile")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Spacing.l, for: .scrollContent)
    }
}

private struct HomeTownCard: View {
    let sighting: HomeTownSnapshot.Sighting
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 228

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 104)
                .overlay { HearthAvatarArt(ref: HomeText.locationArt(sighting.location), pointSize: 240) }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    AvatarView(sighting.character.avatar, size: 52)
                        .padding(3)
                        .background(Color.hearthSurface, in: Circle())
                        .offset(x: Spacing.m, y: 28)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(sighting.character.name)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                    .lineLimit(1)
                Label(HomeText.atPlace(sighting.location), systemImage: sighting.location.symbol)
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthSea)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                Text(HomeText.sentence(sighting.activity))
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.top, 38)
            .padding(.bottom, Spacing.m)
        }
        .containerRelativeFrame(.horizontal) { length, _ in min(width, length * 0.85) }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.hearthSurface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
        .contentShape(shape)
    }
}

// MARK: - Your characters

struct HomeYourCharactersRow: View {
    let characters: [Character]
    let create: () -> Void
    let open: (Character) -> Void
    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 160

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Spacing.m) {
                HomeCreateCard(action: create)
                    .containerRelativeFrame(.horizontal) { length, _ in min(width, length * 0.8) }
                ForEach(characters) { character in
                    Button { open(character) } label: {
                        CharacterCardView(character: character)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("Opens their profile")
                    .containerRelativeFrame(.horizontal) { length, _ in min(width, length * 0.8) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, Spacing.l, for: .scrollContent)
    }
}

/// The first card in "Your characters": a dashed outline with a plus.
private struct HomeCreateCard: View {
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            VStack(spacing: Spacing.m) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.hearthAccent)
                    .frame(width: 56, height: 56)
                    .background(Color.hearthSurface2, in: Circle())
                    .accessibilityHidden(true)
                Text("Create a character")
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text("Give them a name, a look and a voice.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
            .multilineTextAlignment(.center)
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.hearthSurface.opacity(0.5), in: shape)
            .overlay(shape.strokeBorder(Color.hearthMuted.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
    }
}

/// "Your characters" before the user has made any.
struct HomeCreatePrompt: View {
    let create: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.m))
        HearthCard {
            layout {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.hearthGold)
                    .frame(width: 48, height: 48)
                    .background(Color.hearthGold.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Make someone new")
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text("Give them a name, a look and a way of talking. They live only on this iPhone.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton("Create a character", symbol: "plus", kind: .secondary, action: create)
                        .padding(.top, Spacing.xs)
                }
            }
        }
    }
}

// MARK: - Footer

struct HomeFooter: View {
    var body: some View {
        VStack(spacing: Spacing.s) {
            PrivacyBadge("Lives on this iPhone")
            Text("Hearth characters are AI. What they say is made up.")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.l)
    }
}
