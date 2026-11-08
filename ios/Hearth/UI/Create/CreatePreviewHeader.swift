// The top of Create: a live CharacterCardView of the draft (with a soft glow in its color) and the
// avatar choices beside it: a photo, an emoji with colors, or a drawn picture (when drawing is available).

import SwiftUI
import UIKit

struct CreatePreviewHeader: View {
    /// The draft as a character, with placeholder text where fields are still empty.
    let character: Character
    /// A new picture that isn't saved yet (drawn over the card's art).
    let picture: CreatePicture?
    let hasPicture: Bool
    let isLoadingPicture: Bool
    let canDraw: Bool
    let onPhoto: () -> Void
    let onEmoji: () -> Void
    let onDraw: () -> Void
    let onRemovePicture: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.l) {
                card.frame(maxWidth: 260).frame(maxWidth: .infinity)
                choices
            }
        } else {
            HStack(alignment: .center, spacing: Spacing.l) {
                card.frame(width: 168)
                choices
            }
        }
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return CharacterCardView(character: character)
            .overlay(alignment: .top) {
                if let picture {
                    // The new picture isn't saved yet, so it's drawn over the card's square art.
                    GeometryReader { proxy in
                        Image(uiImage: picture.preview)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.width)
                            .clipped()
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topLeading) {
                previewBadge.padding(Spacing.s)
            }
            .overlay {
                if isLoadingPicture {
                    ZStack {
                        shape.fill(Color.black.opacity(0.35))
                        ProgressView()
                            .tint(.white)
                            .controlSize(.large)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Getting the picture ready")
                }
            }
            .background {
                // A warm glow in the character's own color.
                RadialGradient(colors: [Color(hex: character.accentHex).opacity(0.35), .clear],
                               center: .center, startRadius: 10, endRadius: 170)
                    .padding(-48)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .animation(.smooth, value: picture)
            .contentShape(.contextMenuPreview, shape)
            .contextMenu {
                Button("Choose a photo", systemImage: "photo.on.rectangle", action: onPhoto)
                Button("Emoji and colors", systemImage: "face.smiling", action: onEmoji)
                if canDraw {
                    Button("Draw it for me", systemImage: "wand.and.sparkles", action: onDraw)
                }
                if hasPicture {
                    Button("Remove picture", systemImage: "xmark", role: .destructive, action: onRemovePicture)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Live preview: \(character.name). \(character.tagline)")
    }

    /// A small dark glass pill over the art, like the place badges on Town cards.
    private var previewBadge: some View {
        Label("Preview", systemImage: "eye.fill")
            .font(HearthFont.small)
            .foregroundStyle(.hearthText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: Capsule())
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            CreateOptionRow(title: "Choose a photo", symbol: "photo.on.rectangle", action: onPhoto)
            CreateOptionRow(title: "Emoji and colors", symbol: "face.smiling", action: onEmoji)
            if canDraw {
                CreateOptionRow(title: "Draw it for me", symbol: "wand.and.sparkles", tint: .hearthGold, action: onDraw)
            }
            if hasPicture {
                CreateOptionRow(title: "Remove picture", symbol: "xmark", tint: .hearthMuted, action: onRemovePicture)
            }
            Text("Hearth keeps only the picture, never where or when it was taken.")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
