// "Draw it for me": Image Playground draws an avatar on this iPhone from a short idea. It draws animals,
// objects and places (never people), so the sheet says so, shows progress, and lets you try again.

import SwiftUI

struct CreateDrawSheet: View {
    let onUse: (CreatePicture, String) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var idea: String
    @State private var style: PictureStyle
    @State private var phase: Phase = .ready
    @State private var drawing: Task<Void, Never>?
    @FocusState private var ideaFocused: Bool

    private enum Phase: Equatable {
        case ready, drawing, drawn(CreatePicture), failed(String)
    }

    init(idea: String, style: PictureStyle, onUse: @escaping (CreatePicture, String) -> Void) {
        self.onUse = onUse
        _idea = State(initialValue: idea)
        _style = State(initialValue: style)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                canvas
                ideaField
                Picker("Style", selection: $style) {
                    ForEach(PictureStyle.allCases, id: \.self) { style in
                        Text(style.rawValue.capitalized).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(phase == .drawing)
                Text("Image Playground draws animals, objects and places. It can't draw people, which is why everyone in Lantern Bay is animal folk. The drawing happens on this iPhone.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
                buttons
            }
            .padding(Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .hearthScreenBackground()
        .navigationTitle("Draw it for me")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onDisappear { drawing?.cancel() }
        .sensoryFeedback(.success, trigger: phase) { _, new in
            if case .drawn = new { return app.settings.haptics }
            return false
        }
    }

    // MARK: Pieces

    private var canvas: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Color.hearthSurface2
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                switch phase {
                case .ready:
                    message(symbol: "wand.and.sparkles", tint: .hearthGold,
                            text: "Describe how they look, then tap Draw.")
                case .drawing:
                    VStack(spacing: Spacing.m) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.hearthGold)
                        Text("Drawing on this iPhone. This can take a little while.")
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthText2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Spacing.xl)
                    .accessibilityElement(children: .combine)
                case .drawn(let picture):
                    Image(uiImage: picture.preview)
                        .resizable()
                        .scaledToFill()
                        .accessibilityLabel("The drawn picture")
                case .failed(let reason):
                    message(symbol: "exclamationmark.triangle.fill", tint: .hearthDanger, text: reason)
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.hearthLine, lineWidth: 1))
            .frame(maxWidth: 360)
            .frame(maxWidth: .infinity)
            .animation(.smooth, value: phase)
    }

    private func message(symbol: String, tint: Color, text: String) -> some View {
        VStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .multilineTextAlignment(.center)
        }
        .padding(Spacing.xl)
    }

    private var ideaField: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("What should it show?")
                .font(HearthFont.headline)
                .foregroundStyle(.hearthText)
            TextField("What should it show?", text: $idea,
                      prompt: Text("A sleepy fox in a knitted scarf, head-and-shoulders portrait, soft simple background")
                        .foregroundStyle(Color.hearthMuted),
                      axis: .vertical)
                .lineLimit(2...5)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .focused($ideaFocused)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, Spacing.m + 2)
                .padding(.vertical, Spacing.s)
                .background(Color.hearthSurface2, in: shape)
                .overlay(shape.strokeBorder(ideaFocused ? Color.hearthAccent.opacity(0.8) : Color.hearthLine,
                                            lineWidth: ideaFocused ? 1.5 : 1))
                .disabled(phase == .drawing)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch phase {
        case .ready:
            PillButton("Draw", symbol: "wand.and.sparkles", action: draw).fullWidth()
        case .drawing:
            PillButton("Drawing...", symbol: "hourglass", kind: .secondary) {}
                .fullWidth()
                .disabled(true)
        case .drawn(let picture):
            VStack(spacing: Spacing.m) {
                PillButton("Use this picture", symbol: "checkmark") {
                    onUse(picture, CreateDraft.tidy(idea))
                    dismiss()
                }
                .fullWidth()
                PillButton("Try again", symbol: "arrow.clockwise", kind: .secondary, action: draw).fullWidth()
            }
        case .failed:
            PillButton("Try again", symbol: "arrow.clockwise", action: draw).fullWidth()
        }
    }

    // MARK: Drawing

    private func draw() {
        let prompt = CreateDraft.tidy(idea)
        guard !prompt.isEmpty else {
            phase = .failed("Describe what to draw first, like a sleepy fox in a knitted scarf.")
            ideaFocused = true
            return
        }
        ideaFocused = false
        phase = .drawing
        let chosenStyle = style
        drawing?.cancel()
        drawing = Task {
            do {
                let png = try await app.pictures.makeAvatar(prompt: prompt, style: chosenStyle)
                let picture = try await CreatePicture.make(from: png)
                guard !Task.isCancelled else { return }
                phase = .drawn(picture)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? LocalizedError)?.errorDescription ?? "That picture didn't come out. Please try again.")
            }
        }
    }
}
