// "About you": the name, pronouns and short note characters read before every chat.
// Changes save as you type (an empty name is never saved).

import SwiftUI

struct PersonaSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var pronouns = ""
    @State private var about = ""
    @State private var loaded = false
    @FocusState private var focus: Field?

    private enum Field { case name, pronouns, about }
    private static let aboutLimit = 400
    private static let pronounChoices = ["she/her", "he/him", "they/them"]

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $name)
                    .font(HearthFont.body)
                    .textContentType(.givenName)
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .pronouns }
            } header: {
                SettingsSectionTitle("What they call you")
            } footer: {
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Characters need something to call you. Until you type a name, they keep using the one from before.")
                        .foregroundStyle(.hearthDanger)
                }
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                TextField("Pronouns (optional)", text: $pronouns)
                    .font(HearthFont.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .pronouns)
                    .onSubmit { focus = .about }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.s) {
                        ForEach(Self.pronounChoices, id: \.self) { choice in
                            CategoryChip(choice, selected: pronouns == choice) {
                                withAnimation(.snappy) { pronouns = pronouns == choice ? "" : choice }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SettingsSectionTitle("Pronouns")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                TextField("For example: I love rainy days, I'm learning to bake, and my cat is called Biscuit.",
                          text: $about, axis: .vertical)
                    .font(HearthFont.body)
                    .lineLimit(3...10)
                    .focused($focus, equals: .about)
            } header: {
                SettingsSectionTitle("A little about you")
            } footer: {
                Text("Characters read this before every chat, so they can ask about the things you care about. It stays on this iPhone. \(about.count)/\(Self.aboutLimit)")
            }
            .listRowBackground(Color.hearthSurface)
        }
        .hearthScreenBackground()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("About you")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
        }
        .onAppear(perform: load)
        .onChange(of: name) { save() }
        .onChange(of: pronouns) { save() }
        .onChange(of: about) {
            if about.count > Self.aboutLimit { about = String(about.prefix(Self.aboutLimit)) }
            save()
        }
    }

    private func load() {
        guard !loaded else { return }
        let persona = app.settings.persona
        name = persona.name
        pronouns = persona.pronouns ?? ""
        about = persona.about
        loaded = true
    }

    private func save() {
        guard loaded else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPronouns = pronouns.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAbout = about.trimmingCharacters(in: .whitespacesAndNewlines)
        app.settingsStore.update { settings in
            if !cleanName.isEmpty { settings.persona.name = cleanName }
            settings.persona.pronouns = cleanPronouns.isEmpty ? nil : cleanPronouns
            settings.persona.about = cleanAbout
        }
    }
}
