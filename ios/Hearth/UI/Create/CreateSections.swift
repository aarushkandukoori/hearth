// The word parts of Create: the basics, personality (with the advanced definition), categories,
// how often they send voice notes and pictures, and the privacy note.

import SwiftUI

struct CreateBasicsSection: View {
    @Binding var draft: CreateDraft
    let focus: FocusState<CreateFocus?>.Binding
    /// Show "needs a name" style errors (after someone tried to save).
    let showErrors: Bool

    var body: some View {
        CreateSection("The basics") {
            CreateTextField(title: "Name", placeholder: "e.g. Biscuit", text: $draft.name,
                            limit: CreateDraft.Limit.name, hardLimit: true, required: true,
                            error: showErrors && CreateDraft.tidy(draft.name).isEmpty ? "Your character needs a name." : nil,
                            focus: focus, field: .name) { focus.wrappedValue = .species }
                .id(CreateFocus.name)
            CreateTextField(title: "What are they?",
                            hint: "Lantern Bay is a town of animal folk. This also helps when drawing their picture.",
                            placeholder: "e.g. sleepy corgi, barn owl, small dragon", text: $draft.species,
                            focus: focus, field: .species) { focus.wrappedValue = .tagline }
            CreateTextField(title: "Tagline", hint: "A short line people see under their name.",
                            placeholder: "e.g. Retired sailor who knits sweaters for the whole harbor.",
                            text: $draft.tagline, limit: CreateDraft.Limit.tagline, hardLimit: true,
                            focus: focus, field: .tagline) { focus.wrappedValue = .bio }
            CreateTextField(title: "Description", hint: "How they'd introduce themselves. It shows on their profile.",
                            placeholder: "Where do they live? What do they love? What are they like to be around?",
                            text: $draft.bio, limit: CreateDraft.Limit.bio, multiline: true,
                            focus: focus, field: .bio)
            CreateTextField(title: "Greeting",
                            hint: "The first thing they say in a new chat. Write {{user}} where your name should go.",
                            placeholder: "*waves from the porch* Oh, hello {{user}}! Come sit, the tea is still warm.",
                            text: $draft.greeting, limit: CreateDraft.Limit.greeting, multiline: true, required: true,
                            error: showErrors && CreateDraft.tidy(draft.greeting).isEmpty ? "Write the first thing they'll say to you." : nil,
                            focus: focus, field: .greeting)
                .id(CreateFocus.greeting)
        }
    }
}

struct CreatePersonalitySection: View {
    @Binding var draft: CreateDraft
    let focus: FocusState<CreateFocus?>.Binding
    @Binding var showDefinition: Bool

    var body: some View {
        CreateSection("Personality", subtitle: "Your character reads this before every reply.") {
            CreateTextField(title: "What they're like",
                            hint: "Writing it to them works well: \"You love rainy days and terrible puns.\"",
                            placeholder: "You're kind, curious and a little dramatic about soup. You love old maps and hearing about people's plans.",
                            text: $draft.personality, limit: CreateDraft.Limit.personality, multiline: true,
                            focus: focus, field: .personality)
            if CreateDraft.tidy(draft.personality).isEmpty && !CreateDraft.tidy(draft.bio).isEmpty {
                CreateHelperButton(title: "Start from the description", symbol: "text.append") {
                    draft.personality = draft.bio
                }
            }
            CreateDisclosure("Advanced: definition", subtitle: "Speaking style, example lines and the scene.",
                             isExpanded: $showDefinition) {
                definition
            }
        }
    }

    private var definition: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            CreateTextField(title: "Speaking style", hint: "How they talk: rhythm, favorite words, little habits.",
                            placeholder: "Short, warm sentences. Uses old sailing words. Laughs easily.",
                            text: $draft.speakingStyle, limit: CreateDraft.Limit.style, multiline: true,
                            focus: focus, field: .style)
            VStack(alignment: .leading, spacing: Spacing.s) {
                CreateTextField(title: "Example dialogue",
                                hint: "A few lines that show how they talk. Start each line with {{user}}: or {{char}}:",
                                placeholder: "{{user}}: Long day today.\n{{char}}: *pulls out a chair* Sit. Tell me everything.",
                                text: $draft.exampleDialogue, limit: CreateDraft.Limit.example, multiline: true,
                                focus: focus, field: .example)
                CreateHelperButton(title: "Add a pair of lines", symbol: "plus.bubble", action: addExamplePair)
            }
            CreateTextField(title: "Scenario", hint: "Where you are and what's happening when you chat.",
                            placeholder: "A rainy evening at the harbor. The lanterns are just coming on.",
                            text: $draft.scenario, limit: CreateDraft.Limit.scenario, multiline: true,
                            focus: focus, field: .scenario)
        }
    }

    private func addExamplePair() {
        let pair = "{{user}}: \n{{char}}: "
        let current = draft.exampleDialogue.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.exampleDialogue = current.isEmpty ? pair : current + "\n" + pair
        focus.wrappedValue = .example
    }
}

struct CreateCategoriesSection: View {
    @Binding var draft: CreateDraft
    let categories: [CategoryDef]
    @Environment(AppModel.self) private var app

    var body: some View {
        CreateSection("Categories", subtitle: "Pick any that fit. They help you find them on Home.") {
            CreateFlowLayout(spacing: Spacing.s) {
                ForEach(categories) { category in
                    CategoryChip(category.title, symbol: category.symbol,
                                 selected: draft.categories.contains(category.id)) {
                        toggle(category.id)
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: draft.categories) { _, _ in app.settings.haptics }
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) {
            if draft.categories.contains(id) {
                draft.categories.remove(id)
            } else {
                draft.categories.insert(id)
            }
        }
    }
}

struct CreateMediaSection: View {
    @Binding var draft: CreateDraft
    @Binding var isExpanded: Bool

    var body: some View {
        CreateDisclosure("Advanced: voice notes and pictures", subtitle: "How often they send them on their own.",
                         isExpanded: $isExpanded) {
            HearthCard {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    CreateWordSlider(title: "Voice notes", value: $draft.voiceNoteChance, range: 0...0.5,
                                     lowLabel: "Never", highLabel: "Often", word: Self.howOften)
                    CreateWordSlider(title: "Pictures", value: $draft.photoChance, range: 0...0.4,
                                     lowLabel: "Never", highLabel: "Often", word: Self.howOften)
                    Text("Pictures never show people. You can turn voice notes and pictures off for everyone in the You tab.")
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func howOften(_ chance: Double) -> String {
        switch chance {
        case ..<0.01: return "Never"
        case ..<0.08: return "Rarely"
        case ..<0.18: return "Sometimes"
        case ..<0.3: return "Often"
        default: return "Very often"
        }
    }
}

/// Where the character lives: only here.
struct CreateVisibilityNote: View {
    var body: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Visibility")
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                PrivacyBadge("Private")
                Text("This character lives only on this iPhone.")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
