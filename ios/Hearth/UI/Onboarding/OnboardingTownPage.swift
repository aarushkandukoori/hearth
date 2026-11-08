// Onboarding step 6, "Meet the town": six residents to pick a first friend from. Where each one is right
// now shows on their card, because the town keeps its own schedule.

import SwiftUI

struct OnboardingTownPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var friendID: String?
    let residents: [Character]

    var body: some View {
        OnboardingPageScroll {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                OnboardingTitle(title: "Meet the town",
                                subtitle: "Who would you like to talk with first? Everyone else is around too, whenever you want to say hello.")
                if residents.isEmpty {
                    EmptyStateView(symbol: "map.fill", title: "The town is resting",
                                   message: "Lantern Bay's residents couldn't be loaded right now. You can still look around.")
                        .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: columns, spacing: Spacing.m) {
                        ForEach(residents) { character in
                            ResidentChoice(character: character, place: placeName(for: character),
                                           selected: friendID == character.id) {
                                withAnimation(.snappy) { friendID = character.id }
                            }
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: friendID) { _, _ in app.settings.haptics }
    }

    private var columns: [GridItem] {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 260 : 150
        return [GridItem(.adaptive(minimum: minimum), spacing: Spacing.m)]
    }

    /// "At Driftwood Cafe", "At the Lighthouse".
    private func placeName(for character: Character) -> String? {
        guard let name = app.director.location(of: character, at: .now)?.name else { return nil }
        return name.hasPrefix("The ") ? "At the \(name.dropFirst(4))" : "At \(name)"
    }
}

/// A resident's card with a ring and a check when chosen.
private struct ResidentChoice: View {
    let character: Character
    let place: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            CharacterCardView(character: character, subtitle: species, badge: place)
                .overlay {
                    shape.strokeBorder(selected ? Color.hearthAccent : Color.clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.hearthOnAccent, Color.hearthAccent)
                            .padding(Spacing.s)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .scaleEffect(selected ? 1.0 : 0.98)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Choose \(character.name) as your first friend")
    }

    /// "River otter" from "river otter".
    private var species: String? {
        guard let species = character.species, let first = species.first else { return nil }
        return first.uppercased() + species.dropFirst()
    }
}
