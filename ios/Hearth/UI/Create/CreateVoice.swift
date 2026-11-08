// How the character sounds: the voice row, pitch and speed sliders, and a button that speaks their
// greeting; plus the voice list it opens. Speech uses VoiceStudio, on this iPhone.

import SwiftUI

/// Plays the draft's greeting through VoiceStudio and tells Create when its own sample is playing.
@MainActor
enum CreateVoicePreview {
    /// Marks Create's sample in VoiceStudio, so it can tell it apart from other audio.
    static let messageID = UUID()

    /// Speaks the greeting with the draft's voice, pitch and speed. Returns the voice identifier used.
    @discardableResult
    static func play(_ draft: CreateDraft, voiceID: String?, app: AppModel) -> String? {
        var character = draft.makeCharacter(voice: nil, world: app.library.world)
        if character.id.isEmpty { character.id = "create-preview" }
        let overrides = voiceID.map { [character.id: $0] } ?? [:]
        let used = app.voice.voice(for: character, overrides: overrides)?.identifier
        let text = sample(for: draft, userName: PromptComposer.userName(app.settings.persona))
        app.voice.speak(text, as: character, overrides: overrides, messageID: messageID)
        return used
    }

    static func isPlaying(_ app: AppModel) -> Bool {
        app.voice.nowPlayingMessageID == messageID && app.voice.isSpeaking
    }

    /// Stops the sample (and only the sample).
    static func stop(_ app: AppModel) {
        if app.voice.nowPlayingMessageID == messageID { app.voice.stop() }
    }

    /// The greeting with names filled in, or a simple hello when there is no greeting yet.
    static func sample(for draft: CreateDraft, userName: String) -> String {
        let name = CreateDraft.tidy(draft.name)
        let greeting = CreateDraft.tidy(draft.greeting)
        let hello = name.isEmpty ? "Hi there. It's so nice to meet you." : "Hi, I'm \(name). It's so nice to meet you."
        return CharacterCardIO.fillPlaceholders(greeting.isEmpty ? hello : greeting, user: userName,
                                                char: name.isEmpty ? "me" : name)
    }
}

struct CreateVoiceSection: View {
    @Binding var draft: CreateDraft
    let voiceName: String
    let isPreviewing: Bool
    let onChooseVoice: () -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            voiceRow
            HearthCard {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    CreateWordSlider(title: "Pitch", value: pitch, range: 0.7...1.4,
                                     lowLabel: "Lower", highLabel: "Higher", word: Self.pitchWord)
                    CreateWordSlider(title: "Speed", value: rate, range: 0.36...0.62,
                                     lowLabel: "Slower", highLabel: "Faster", word: Self.speedWord)
                }
            }
            PillButton(isPreviewing ? "Stop" : "Hear their greeting",
                       symbol: isPreviewing ? "stop.fill" : "play.fill", kind: .secondary, action: onPreview)
                .fullWidth()
        }
    }

    private var voiceRow: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return Button(action: onChooseVoice) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "waveform")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.hearthAccent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice")
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text(voiceName)
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                }
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.hearthMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(minHeight: 56)
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityHint("Choose the voice they speak with")
    }

    private var pitch: Binding<Double> {
        Binding(get: { Double(draft.pitch) }, set: { draft.pitch = Float($0) })
    }

    private var rate: Binding<Double> {
        Binding(get: { Double(draft.rate) }, set: { draft.rate = Float($0) })
    }

    static func pitchWord(_ value: Double) -> String {
        switch value {
        case ..<0.85: return "Low"
        case ..<0.96: return "A little low"
        case ...1.04: return "Natural"
        case ...1.15: return "A little high"
        default: return "High"
        }
    }

    static func speedWord(_ value: Double) -> String {
        switch value {
        case ..<0.42: return "Slow"
        case ..<0.47: return "Unhurried"
        case ...0.53: return "Natural"
        case ...0.57: return "A little quick"
        default: return "Quick"
        }
    }
}

/// The list of voices installed on this iPhone, grouped by accent. Tapping one picks it and plays a sample.
struct CreateVoicePicker: View {
    @Binding var voiceID: String?
    let onSample: (String?) -> Void
    let onStop: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @State private var showOtherLanguages = false

    var body: some View {
        List {
            Section {
                row(title: "Automatic", detail: "Hearth picks a voice that sets them apart from the rest of town.", id: nil)
            }
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.voices) { voice in
                        row(title: voice.name, detail: Self.detail(for: voice), id: voice.id)
                    }
                }
            }
            Section {
                Toggle("Show other languages", isOn: $showOtherLanguages)
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText)
                    .tint(.hearthAccent)
                    .listRowBackground(Color.hearthSurface)
            } footer: {
                Text("For more natural voices, download Enhanced or Premium voices in the Settings app, under Accessibility, Spoken Content, Voices.")
            }
        }
        .listStyle(.insetGrouped)
        .hearthScreenBackground()
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await app.voice.refreshVoices()
            if let voiceID, let chosen = app.voice.availableVoices.first(where: { $0.id == voiceID }),
               !Self.isEnglish(chosen) {
                showOtherLanguages = true
            }
        }
        .onDisappear(perform: onStop)
    }

    private func row(title: String, detail: String, id: String?) -> some View {
        let selected = voiceID == id
        return Button {
            voiceID = id
            if !voiceOverOn { onSample(id) }
        } label: {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text(detail)
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthText2)
                }
                Spacer(minLength: Spacing.s)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.hearthAccent)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.hearthSurface)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: "Play a sample") { onSample(id) }
    }

    private struct VoiceGroup: Identifiable {
        let id: String
        let title: String
        let voices: [VoiceOption]
    }

    /// Voices grouped by language, in VoiceStudio's order (English and the best voices first).
    private var groups: [VoiceGroup] {
        var order: [String] = []
        var byLanguage: [String: [VoiceOption]] = [:]
        for voice in app.voice.availableVoices where showOtherLanguages || Self.isEnglish(voice) {
            if byLanguage[voice.language] == nil { order.append(voice.language) }
            byLanguage[voice.language, default: []].append(voice)
        }
        return order.map { language in
            let voices = byLanguage[language] ?? []
            return VoiceGroup(id: language, title: voices.first?.languageName ?? language, voices: voices)
        }
    }

    private static func isEnglish(_ voice: VoiceOption) -> Bool {
        voice.language.lowercased().hasPrefix("en")
    }

    /// "Enhanced · Female", with "Default" shown as "Standard".
    static func detail(for voice: VoiceOption) -> String {
        let quality = voice.quality == "Default" ? "Standard" : voice.quality
        guard voice.gender != "neutral" else { return quality }
        return "\(quality) · \(voice.gender.capitalized)"
    }
}
