// The Pictures page: whether characters send pictures, and the drawing style Image Playground uses.
// When Image Playground isn't available, characters send postcards and town art instead.

import SwiftUI

struct PicturesSettingsPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var store = app.settingsStore
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HearthCard {
                    Toggle(isOn: $store.settings.picturesEnabled) {
                        SettingsRowLabel(title: "Pictures from characters",
                                         detail: "Now and then a friend sends a picture. Image Playground draws it on this iPhone when it can; otherwise it's a postcard or a picture from the town's own art.",
                                         symbol: "photo.on.rectangle.angled.fill", tint: .hearthGold)
                    }
                }

                if !app.pictures.isAvailable {
                    HearthCard {
                        Label {
                            Text("Drawing new pictures needs Image Playground, which comes with Apple Intelligence. Until it's on, characters send postcards and town art instead.")
                                .font(HearthFont.callout)
                                .foregroundStyle(.hearthText2)
                        } icon: {
                            Image(systemName: "envelope.fill")
                                .foregroundStyle(.hearthGold)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("Style")
                    LazyVGrid(columns: columns, spacing: Spacing.m) {
                        ForEach(PictureStyle.allCases, id: \.self) { style in
                            PictureStyleTile(style: style, selected: store.settings.pictureStyle == style) {
                                withAnimation(.snappy) { store.settings.pictureStyle = style }
                            }
                        }
                    }
                    .disabled(!store.settings.picturesEnabled)
                    .opacity(store.settings.picturesEnabled ? 1 : 0.5)
                }

                Text("Pictures never show people. Lantern Bay is a town of animal folk. Pictures are drawn on this iPhone with Image Playground when it can; otherwise a friend sends a postcard or a picture from the town's own art. Nothing is drawn in the cloud.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.l)
        }
        .hearthScreenBackground()
        .navigationTitle("Pictures")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: app.settings.pictureStyle) { _, _ in app.settings.haptics }
    }

    private var columns: [GridItem] {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 220 : 100
        return [GridItem(.adaptive(minimum: minimum), spacing: Spacing.m)]
    }
}

/// A sample picture with the style's name. The sketch sample is town art shown in pencil tones.
private struct PictureStyleTile: View {
    let style: PictureStyle
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                sample
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.hearthOnAccent, Color.hearthAccent)
                                .padding(6)
                        }
                    }
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(blurb)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .lineLimit(3, reservesSpace: true)
            }
            .padding(Spacing.s)
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(selected ? Color.hearthAccent : Color.hearthLine, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var sample: some View {
        let art = Color.clear.overlay {
            HearthAvatarArt(ref: AvatarRef(asset: asset), pointSize: 160)
        }
        if style == .sketch {
            art.grayscale(1).contrast(1.5).brightness(0.08)
        } else {
            art
        }
    }

    private var asset: String {
        switch style {
        case .animation: return "char-juno"
        case .illustration: return "loc-greenhouse"
        case .sketch: return "loc-lighthouse"
        }
    }

    private var title: String { style.rawValue.capitalized }

    private var blurb: String {
        switch style {
        case .animation: return "Soft and bright, like an animated film."
        case .illustration: return "Flat colors, like a picture book."
        case .sketch: return "Pencil lines, like a quick drawing."
        }
    }
}
