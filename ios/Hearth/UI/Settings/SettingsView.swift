// The You tab: who you are to the town, plus the model, voices, pictures, privacy, safety and about pages.
// Every row opens its page through the router (`.settings(page)`).

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var store = app.settingsStore
        List {
            Section {
                ProfileHeader(persona: store.settings.persona) { router.open(.settings(.persona)) }
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                SettingsLinkRow(title: "Model", detail: SettingsModelActions.statusLine(app.engine),
                                symbol: "cpu.fill", tint: .hearthAccent) { router.open(.settings(.model)) }
                SettingsLinkRow(title: "Voice", detail: voiceDetail, symbol: "waveform", tint: .hearthSea) {
                    router.open(.settings(.voice))
                }
                SettingsLinkRow(title: "Pictures", detail: picturesDetail, symbol: "photo.on.rectangle.angled.fill",
                                tint: .hearthGold) { router.open(.settings(.pictures)) }
            } header: {
                SettingsSectionTitle("Your town")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                SettingsLinkRow(title: "Privacy Center", detail: "Everything stays on this iPhone",
                                symbol: "lock.shield.fill", tint: .hearthSuccess) { router.open(.settings(.privacy)) }
                SettingsLinkRow(title: "Safety and support", detail: "People to talk to, any time",
                                symbol: "heart.fill", tint: .hearthDanger) { router.open(.settings(.safety)) }
            } header: {
                SettingsSectionTitle("Privacy and care")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                Toggle(isOn: $store.settings.showEngineStats) {
                    SettingsRowLabel(title: "Show engine stats in chats", detail: "Speed and memory numbers under replies",
                                     symbol: "gauge.with.dots.needle.33percent", tint: .hearthMuted)
                }
                Toggle(isOn: $store.settings.haptics) {
                    SettingsRowLabel(title: "Haptics", detail: "Gentle taps when things happen",
                                     symbol: "hand.tap.fill", tint: .hearthMuted)
                }
            } header: {
                SettingsSectionTitle("Chats")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                SettingsLinkRow(title: "About Hearth", detail: "Version, open source and credits",
                                symbol: "info.circle.fill", tint: .hearthText2) { router.open(.settings(.about)) }
            } footer: {
                Text("Hearth characters are AI. What they say is made up.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.m)
            }
            .listRowBackground(Color.hearthSurface)
        }
        .listStyle(.insetGrouped)
        .hearthScreenBackground()
        .navigationTitle("You")
        .toolbarVisibility(.visible, for: .tabBar) // comes back after a chat or scene hid it (see HomeView)
        .task { SettingsModelActions.resumeWatching(app: app) }
    }

    private var voiceDetail: String {
        guard app.settings.voiceNotesEnabled else { return "Voice notes off" }
        return app.settings.autoPlayVoiceNotes ? "Voice notes on, auto-play on" : "Voice notes on"
    }

    private var picturesDetail: String {
        guard app.settings.picturesEnabled else { return "Off" }
        return "On, \(app.settings.pictureStyle.rawValue.capitalized) style"
    }
}

/// Your name, pronouns and "about you", with a way into the persona page.
private struct ProfileHeader: View {
    let persona: UserPersona
    let edit: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: edit) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.l))
                layout {
                    PersonaMonogram(name: persona.name, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                            Text(displayName)
                                .modifier(SettingsScaledTitle(26))
                                .foregroundStyle(.hearthText)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                            if let pronouns = persona.pronouns, !pronouns.isEmpty {
                                Text(pronouns)
                                    .font(HearthFont.caption)
                                    .foregroundStyle(.hearthMuted)
                            }
                        }
                        Text(aboutLine)
                            .font(HearthFont.callout)
                            .foregroundStyle(persona.about.isEmpty ? Color.hearthMuted : Color.hearthText2)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 8 : 3)
                            .multilineTextAlignment(.leading)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.s) {
                        PrivacyBadge("On-device")
                        Spacer(minLength: Spacing.s)
                        editLabel
                    }
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        PrivacyBadge("On-device")
                        editLabel
                    }
                }
            }
            .padding(.vertical, Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit what characters know about you")
    }

    private var editLabel: some View {
        Text("Edit")
            .font(HearthFont.callout.weight(.semibold))
            .foregroundStyle(.hearthAccentText)
    }

    private var displayName: String {
        let name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? UserPersona().name : name
    }

    private var aboutLine: String {
        persona.about.isEmpty ? "Add a little about you, so your friends in town can ask about your day." : persona.about
    }
}

/// A warm circle with the first letter of your name.
private struct PersonaMonogram: View {
    let name: String
    var size: CGFloat = 64

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.42, weight: .semibold, design: .serif))
            .foregroundStyle(Color.hearthOnAccent)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [.hearthGold, .hearthAccent], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle())
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "H"
    }
}
