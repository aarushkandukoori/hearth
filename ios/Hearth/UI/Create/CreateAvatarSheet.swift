// "Emoji and colors": pick the emoji and the two-color gradient behind it. The palette also sets the
// character's accent color. Picking an emoji replaces a picture; picking colors keeps it.

import SwiftUI

struct CreateAvatarSheet: View {
    @Binding var avatar: CreateAvatar
    @Binding var accentHex: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                AvatarView(AvatarRef(emoji: avatar.emoji, symbol: avatar.symbol, colors: avatar.colors), size: 112, shape: .rounded)
                    .frame(maxWidth: .infinity)
                if avatar.hasPicture {
                    Text("Picking an emoji replaces their picture. Colors still tint their profile.")
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthText2)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                emojiPicker
                palettePicker
            }
            .padding(Spacing.l)
        }
        .hearthScreenBackground()
        .navigationTitle("Emoji and colors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sensoryFeedback(.selection, trigger: avatar.emoji) { _, _ in app.settings.haptics }
        .sensoryFeedback(.selection, trigger: avatar.colors) { _, _ in app.settings.haptics }
    }

    private var emojiPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Emoji")
                .font(HearthFont.headline)
                .foregroundStyle(.hearthText)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: Spacing.s)], spacing: Spacing.s) {
                ForEach(CreatePresets.emoji, id: \.self) { emoji in
                    emojiButton(emoji)
                }
            }
            TextField("Or type any emoji", text: $typed)
                .font(HearthFont.body)
                .padding(.horizontal, Spacing.m + 2)
                .frame(minHeight: 48)
                .background(Color.hearthSurface2, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Color.hearthLine, lineWidth: 1))
                .onChange(of: typed) { _, text in
                    guard let emoji = CreatePresets.lastEmoji(in: text) else {
                        if !text.isEmpty { typed = "" }
                        return
                    }
                    if text != emoji { typed = emoji }
                    choose(emoji)
                }
        }
    }

    private func emojiButton(_ emoji: String) -> some View {
        let selected = emoji == avatar.emoji && !avatar.hasPicture
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        return Button {
            choose(emoji)
        } label: {
            Text(emoji)
                .font(.system(size: 28))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(selected ? Color.hearthSurface : Color.hearthSurface2, in: shape)
                .overlay(shape.strokeBorder(selected ? Color.hearthAccent : Color.hearthLine, lineWidth: selected ? 2 : 1))
                .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var palettePicker: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Colors")
                .font(HearthFont.headline)
                .foregroundStyle(.hearthText)
            Text("The gradient behind the emoji, and a touch of color on their profile.")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthText2)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: Spacing.m)], spacing: Spacing.m) {
                ForEach(CreatePresets.palettes) { palette in
                    swatch(palette)
                }
            }
        }
    }

    private func swatch(_ palette: CreatePresets.Palette) -> some View {
        let selected = palette.colors == avatar.colors
        return Button {
            withAnimation(.snappy) {
                avatar.colors = palette.colors
                accentHex = palette.accent
            }
        } label: {
            Circle()
                .fill(LinearGradient(colors: palette.colors.map { Color(hex: $0) },
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 48, height: 48)
                .overlay {
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(4)
                .overlay(Circle().strokeBorder(selected ? Color.hearthText : Color.clear, lineWidth: 2))
                .frame(maxWidth: .infinity, minHeight: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// An emoji avatar: any picture goes away.
    private func choose(_ emoji: String) {
        withAnimation(.snappy) {
            avatar.emoji = emoji
            avatar.symbol = nil
            avatar.removePicture()
            avatar.artPrompt = nil
        }
    }
}
