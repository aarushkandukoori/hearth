// Safety and support: a plain AI disclosure, people to call or text any time (SafetyGuard.resources),
// how Hearth responds when someone may be in danger, and the kind-by-design principles.

import SwiftUI

struct SafetySettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HearthCard {
                    HStack(alignment: .top, spacing: Spacing.m) {
                        SettingsIcon(symbol: "sparkles", tint: .hearthGold)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Hearth characters are AI")
                                .font(HearthFont.headline)
                                .foregroundStyle(.hearthText)
                            Text("What they say is made up, and they can get things wrong. They aren't doctors, therapists or emergency services.")
                                .font(HearthFont.callout)
                                .foregroundStyle(.hearthText2)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("If you're struggling")
                    Text("You deserve support from real people too. These are free and confidential, and someone is there day and night.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                    ForEach(SafetyGuard.resources) { resource in
                        ResourceCard(resource: resource)
                    }
                    Text("If you or someone else is in immediate danger, call your local emergency number (911 in the US).")
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthText)
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("How Hearth responds")
                    HearthCard {
                        VStack(alignment: .leading, spacing: Spacing.m) {
                            Text("If something you write or say sounds like you might be in danger, Hearth shows these resources right in the chat, group scene or call, and your friend is told to step out of the story, answer with care and encourage you to reach out.")
                            Text("The check looks for certain words, so it can miss things. These lines are always here, and Get support in any chat or scene menu brings them back.")
                            Text("Your chat keeps going. The check happens on this iPhone, and nothing is sent anywhere.")
                        }
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("Kind by design")
                    HearthCard {
                        VStack(alignment: .leading, spacing: Spacing.l) {
                            Principle(symbol: "calendar.badge.checkmark", title: "No streaks or scores",
                                      detail: "Come and go whenever you like. Nobody keeps count.")
                            Principle(symbol: "hand.wave.fill", title: "No guilt",
                                      detail: "Characters never make you feel bad for leaving or for being away.")
                            Principle(symbol: "person.2.fill", title: "Real people matter",
                                      detail: "Your friends here are glad when you spend time with the people in your life.")
                            Principle(symbol: "sparkles", title: "Honest about being AI",
                                      detail: "Ask a character sincerely and it will tell you it's an AI.")
                            Principle(symbol: "leaf.fill", title: "Breaks are good",
                                      detail: "If Hearth starts taking more of your day than you'd like, step away for a while. The town will be here.")
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.l)
        }
        .hearthScreenBackground()
        .navigationTitle("Safety and support")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One helpline with a call, text or open button.
private struct ResourceCard: View {
    let resource: SafetyResource

    var body: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.m) {
                    SettingsIcon(symbol: symbol, tint: .hearthDanger)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resource.title)
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Text(resource.detail)
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthText2)
                    }
                }
                Link(destination: resource.url) {
                    Label(resource.actionTitle, systemImage: symbol)
                        .font(HearthFont.headline)
                        .foregroundStyle(isFirstChoice ? Color.hearthOnAccent : Color.hearthText)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(isFirstChoice ? Color.hearthAccent : Color.hearthSurface2, in: Capsule())
                        .overlay {
                            if !isFirstChoice { Capsule().strokeBorder(Color.hearthLine, lineWidth: 1) }
                        }
                }
                .buttonStyle(.pressable)
            }
        }
    }

    /// Calling 988 gets the strongest button; the others are quieter so the page doesn't shout.
    private var isFirstChoice: Bool { resource.id == SafetyGuard.resources.first?.id }

    private var symbol: String {
        switch resource.url.scheme {
        case "tel": return "phone.fill"
        case "sms": return "message.fill"
        default: return "globe"
        }
    }
}

private struct Principle: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            SettingsIcon(symbol: symbol, tint: .hearthSuccess)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(detail)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
