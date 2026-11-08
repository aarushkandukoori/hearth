// The Voice page: voice notes on or off, auto-play, and a voice for each character (with a preview).
// Every voice is a system voice on this iPhone; nothing is sent anywhere to speak.

import AVFoundation
import SwiftUI

struct VoiceSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var picking: Character?

    var body: some View {
        @Bindable var store = app.settingsStore
        List {
            Section {
                Toggle(isOn: $store.settings.voiceNotesEnabled) {
                    SettingsRowLabel(title: "Voice notes", detail: "Characters sometimes answer with a short voice note.",
                                     symbol: "waveform", tint: .hearthSea)
                }
                Toggle(isOn: $store.settings.autoPlayVoiceNotes) {
                    SettingsRowLabel(title: "Play them automatically", detail: "New voice notes start playing when they arrive.",
                                     symbol: "play.circle.fill", tint: .hearthSea)
                }
                .disabled(!store.settings.voiceNotesEnabled)
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                ForEach(app.library.allCharacters) { character in
                    Button { picking = character } label: {
                        CharacterVoiceRow(character: character, voiceName: voiceName(for: character))
                    }
                }
            } header: {
                SettingsSectionTitle("Character voices")
            } footer: {
                Text("Each friend gets a voice of their own. Tap one to pick a different voice and hear how it sounds.")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                Label {
                    Text("For richer voices, add Enhanced voices in Settings > Accessibility > Spoken Content > Voices > English.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                } icon: {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.hearthGold)
                }
            } header: {
                SettingsSectionTitle("Tip")
            }
            .listRowBackground(Color.hearthSurface)
        }
        .listStyle(.insetGrouped)
        .hearthScreenBackground()
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $picking) { character in
            VoicePickerSheet(character: character)
        }
        .task { await app.voice.refreshVoices() }
    }

    /// The voice this character speaks with now: "Samantha", or "Automatic (Samantha)" when Hearth picks.
    private func voiceName(for character: Character) -> String {
        let overrides = app.settings.voiceOverrides
        let name = app.voice.voice(for: character, overrides: overrides).map { voice in
            app.voice.availableVoices.first { $0.id == voice.identifier }?.name ?? voice.name
        } ?? "System voice"
        return overrides[character.id] == nil ? "Automatic (\(name))" : name
    }
}

private struct CharacterVoiceRow: View {
    let character: Character
    let voiceName: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(character.avatar, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(character.name)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(voiceName)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.hearthMuted)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Choose a voice")
    }
}

/// Pick a voice for one character, with a preview button on every row.
private struct VoicePickerSheet: View {
    let character: Character
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The voice id being previewed ("" = automatic), so its button can show stop.
    @State private var previewing: String?

    private var overrideID: String? { app.settings.voiceOverrides[character.id] }
    private var englishVoices: [VoiceOption] {
        app.voice.availableVoices.filter { $0.language.lowercased().hasPrefix("en") }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VoiceChoiceRow(title: "Automatic", detail: "Hearth picks a voice that suits \(character.name).",
                                   selected: overrideID == nil, playing: isPlaying(""),
                                   select: { choose(nil) }, preview: { preview(nil) })
                }
                .listRowBackground(Color.hearthSurface)

                if englishVoices.isEmpty {
                    Section {
                        HStack(spacing: Spacing.s) {
                            ProgressView()
                            Text("Finding voices on this iPhone")
                                .font(HearthFont.callout)
                                .foregroundStyle(.hearthText2)
                        }
                    }
                    .listRowBackground(Color.hearthSurface)
                }

                ForEach(["Premium", "Enhanced", "Default"], id: \.self) { quality in
                    let voices = englishVoices.filter { $0.quality == quality }
                    if !voices.isEmpty {
                        Section {
                            ForEach(voices) { voice in
                                VoiceChoiceRow(title: voice.name, detail: voice.languageName,
                                               selected: overrideID == voice.id, playing: isPlaying(voice.id),
                                               select: { choose(voice.id) }, preview: { preview(voice.id) })
                            }
                        } header: {
                            SettingsSectionTitle(quality == "Default" ? "Standard" : quality)
                        }
                        .listRowBackground(Color.hearthSurface)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .hearthScreenBackground()
            .navigationTitle("\(character.name)'s voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onDisappear { app.voice.stop() }
        .onChange(of: app.vault.isLocked) { _, locked in
            if locked { dismiss() }
        }
    }

    private func isPlaying(_ id: String) -> Bool {
        previewing == id && app.voice.isSpeaking
    }

    private func choose(_ voiceID: String?) {
        app.settingsStore.update { settings in
            if let voiceID {
                settings.voiceOverrides[character.id] = voiceID
            } else {
                settings.voiceOverrides.removeValue(forKey: character.id)
            }
        }
        play(voiceID)
    }

    /// The row's play button: plays the voice, or stops it if it is the one playing.
    private func preview(_ voiceID: String?) {
        if isPlaying(voiceID ?? "") {
            app.voice.stop()
            previewing = nil
        } else {
            play(voiceID)
        }
    }

    private func play(_ voiceID: String?) {
        var overrides = app.settings.voiceOverrides
        if let voiceID { overrides[character.id] = voiceID } else { overrides.removeValue(forKey: character.id) }
        previewing = voiceID ?? ""
        app.voice.speak("Hi, it's \(character.name). This is how I'll sound in my voice notes.",
                        as: character, overrides: overrides, messageID: nil)
    }
}

private struct VoiceChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let playing: Bool
    let select: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button(action: select) {
                HStack(spacing: Spacing.m) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selected ? Color.hearthAccent : Color.hearthMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Text(detail)
                            .font(HearthFont.caption)
                            .foregroundStyle(.hearthText2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button(action: preview) {
                Image(systemName: playing ? "stop.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.hearthAccent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playing ? "Stop preview" : "Preview \(title)")
        }
    }
}
