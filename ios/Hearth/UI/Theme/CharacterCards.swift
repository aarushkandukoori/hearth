// Character tiles: CharacterCardView for Discover/Town grids and carousels, CharacterRowView for lists.
// Wrap them in a Button or NavigationLink with `.buttonStyle(.pressable)` to make them tappable.

import SwiftUI

struct CharacterCardView: View {
    private let character: Character
    private let subtitle: String?
    private let badge: String?

    /// Lantern gold in dark mode; a deeper gold in light mode so small text stays readable (about 5:1).
    private static let subtitleColor = HearthPalette.dynamic(light: "#94621A", dark: "#F6C177")

    /// `subtitle` is an optional extra line under the name (for example the species).
    /// `badge` floats over the art, for example "At the cafe".
    init(character: Character, subtitle: String? = nil, badge: String? = nil) {
        self.character = character
        self.subtitle = subtitle
        self.badge = badge
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            art
            VStack(alignment: .leading, spacing: 3) {
                Text(character.name)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(Self.subtitleColor)
                        .lineLimit(1)
                }
                Text(character.tagline)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .lineLimit(2, reservesSpace: true) // keeps cards in a grid row the same height
                Text(byLine(character.creator))
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
                    .lineLimit(1)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.top, Spacing.s + 2)
            .padding(.bottom, Spacing.m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hearthSurface)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }

    /// Square art filling the card's width.
    private var art: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    HearthAvatarArt(ref: character.avatar, pointSize: proxy.size.width)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .accessibilityHidden(true)
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if let badge {
                    PlaceBadge(text: badge).padding(Spacing.s)
                }
            }
    }
}

struct CharacterRowView: View {
    private let character: Character
    private let detail: String?
    private let trailing: String?

    /// `detail` is the second line (for example the last message); nil shows the tagline.
    /// `trailing` is a short note on the right, for example "2h".
    init(character: Character, detail: String?, trailing: String?) {
        self.character = character
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(character.avatar, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(character.name)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    if let trailing {
                        Text(trailing)
                            .font(HearthFont.caption)
                            .foregroundStyle(.hearthMuted)
                            .lineLimit(1)
                    }
                }
                Text(detail ?? character.tagline)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Spacing.s)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Small glass pill over card art, e.g. "At the cafe". Always dark so it reads over any picture.
private struct PlaceBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.hearthSuccess)
                .frame(width: 6, height: 6)
            Text(text)
                .font(HearthFont.small)
                .lineLimit(1)
        }
        .foregroundStyle(.hearthText)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

/// "by @juno" from a creator name stored with or without the "@".
private func byLine(_ creator: String) -> String {
    let name = creator.trimmingCharacters(in: .whitespaces)
    if name.isEmpty { return " " } // keep the line so grid cards stay the same height
    return "by " + (name.hasPrefix("@") ? name : "@" + name)
}
