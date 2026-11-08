// The first four onboarding steps: welcome, the privacy promise, the 18+ check with the town gossip choice
// and the AI disclosure, and what the town should call you.

import SwiftUI

/// Step 1: the town at dusk, the name and the tagline.
struct OnboardingWelcomePage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Very large text: the picture across the top and the words below it, never on top of it.
            OnboardingPageScroll(art: "hero-town", artHeight: 280) {
                WelcomeWords()
            }
        } else {
            GeometryReader { proxy in
                ScrollView {
                    WelcomeWords()
                        .padding(.horizontal, Spacing.xl)
                        .padding(.bottom, Spacing.l)
                        .frame(maxWidth: 560, alignment: .leading)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .bottomLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background { WelcomeBackdrop() }
        }
    }
}

private struct WelcomeWords: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HearthLanternMark(height: 64)
                .padding(.bottom, Spacing.xs)
            Text("Hearth")
                .font(HearthFont.title(52))
                .foregroundStyle(.hearthText)
                .accessibilityAddTraits(.isHeader)
            Text("A little town of friends that lives on your phone.")
                .modifier(SettingsScaledTitle(24, cap: 1.6))
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Talk with the warm, curious residents of Lantern Bay whenever you like. Everything stays on this iPhone.")
                .font(HearthFont.body)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyBadge("Not in the cloud")
                .padding(.top, Spacing.xs)
        }
    }
}

/// hero-town filling the screen, fading into the background where the text sits.
private struct WelcomeBackdrop: View {
    var body: some View {
        OnboardingArt(name: "hero-town")
            .overlay {
                LinearGradient(stops: [.init(color: .black.opacity(0.3), location: 0),
                                       .init(color: .clear, location: 0.16),
                                       .init(color: .clear, location: 0.3),
                                       .init(color: Color.hearthBackground.opacity(0.9), location: 0.54),
                                       .init(color: Color.hearthBackground, location: 0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
    }
}

/// Step 2: everything stays on this iPhone.
struct OnboardingPrivacyPage: View {
    var body: some View {
        OnboardingPageScroll(art: "hero-night", artHeight: 300) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                OnboardingTitle(title: "Everything stays on this iPhone",
                                subtitle: "Hearth is a quiet place of your own.")
                VStack(alignment: .leading, spacing: Spacing.l) {
                    OnboardingFactRow(symbol: "person.crop.circle.badge.xmark", title: "No account",
                                      detail: "No sign-up, email or password.")
                    OnboardingFactRow(symbol: "icloud.slash.fill", title: "No servers",
                                      detail: "Your chats, photos and voice notes never leave this iPhone.")
                    OnboardingFactRow(symbol: "eye.slash.fill", title: "No analytics or ads",
                                      detail: "Nobody keeps track of what you do here.")
                    OnboardingFactRow(symbol: "airplane", title: "Works in Airplane Mode",
                                      detail: "After one download, Hearth doesn't need the internet at all.")
                    OnboardingFactRow(symbol: "faceid", title: "Face ID lock",
                                      detail: "Lock Hearth any time in You > Privacy Center.")
                }
            }
        }
    }
}

/// Step 3: the 18+ confirmation (required), whether residents may share what you tell them (off unless
/// turned on), the AI disclosure, and where support lives.
struct OnboardingConsentPage: View {
    @Binding var isAdult: Bool
    @Binding var townGossip: Bool

    var body: some View {
        OnboardingPageScroll(art: "loc-lighthouse", artHeight: 240) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                OnboardingTitle(title: "Before we start",
                                subtitle: "A few honest words about Hearth.")
                HearthCard {
                    Toggle(isOn: $isAdult) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("I'm 18 or older")
                                .font(HearthFont.headline)
                                .foregroundStyle(.hearthText)
                            Text("Hearth is made for adults.")
                                .font(HearthFont.callout)
                                .foregroundStyle(.hearthText2)
                        }
                    }
                    .tint(.hearthAccent)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(isAdult ? Color.hearthAccent.opacity(0.7) : Color.clear, lineWidth: 1.5)
                }
                HearthCard {
                    Toggle(isOn: $townGossip) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Town gossip")
                                .font(HearthFont.headline)
                                .foregroundStyle(.hearthText)
                            Text("Let residents mention things you told someone else in town. With it off, what you tell one friend stays with that friend. You can change this any time in You > Privacy Center.")
                                .font(HearthFont.callout)
                                .foregroundStyle(.hearthText2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(.hearthAccent)
                }
                VStack(alignment: .leading, spacing: Spacing.l) {
                    OnboardingFactRow(symbol: "sparkles", tint: .hearthGold, title: "The characters are AI",
                                      detail: "Hearth characters are AI. What they say is made up, and they can get things wrong.")
                    OnboardingFactRow(symbol: "heart.fill", tint: .hearthDanger, title: "Help is always close",
                                      detail: "If you're ever going through something hard, you'll find people to call or text in You > Safety.")
                    OnboardingFactRow(symbol: "hand.wave.fill", tint: .hearthSea, title: "Come and go as you like",
                                      detail: "No streaks and no guilt. Your friends here are happy whenever you stop by.")
                }
            }
        }
    }
}

/// Step 4: your name (required) and a little about you (optional).
struct OnboardingNamePage: View {
    @Binding var name: String
    @Binding var about: String
    let suggestedFaces: [Character]
    @FocusState private var focus: Field?

    private enum Field { case name, about }

    var body: some View {
        OnboardingPageScroll {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !suggestedFaces.isEmpty {
                    WavingFaces(characters: suggestedFaces)
                }
                OnboardingTitle(title: "What should they call you?",
                                subtitle: "The town would love to know your name.")
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Your name")
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    TextField("Name", text: $name)
                        .font(HearthFont.body)
                        .textContentType(.givenName)
                        .submitLabel(.next)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .about }
                        .onboardingField(focused: focus == .name)
                }
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("A little about you (optional)")
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    TextField("For example: I love rainy days and I'm learning to bake.", text: $about, axis: .vertical)
                        .font(HearthFont.body)
                        .lineLimit(3...6)
                        .focused($focus, equals: .about)
                        .onboardingField(focused: focus == .about)
                }
                Label("This stays on your iPhone. You can change it any time in You.", systemImage: "lock.fill")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
            }
        }
        .task {
            // Bring up the keyboard once the page has slid in.
            guard name.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            focus = .name
        }
        .onChange(of: about) {
            if about.count > 400 { about = String(about.prefix(400)) }
        }
    }
}

/// A few residents peeking in, to make the name question feel friendly.
private struct WavingFaces: View {
    let characters: [Character]

    var body: some View {
        HStack(spacing: -14) {
            ForEach(characters.prefix(4)) { character in
                AvatarView(character.avatar, size: 58, ring: Color.hearthBackground)
            }
            Text("👋")
                .font(.system(size: 30))
                .padding(.leading, Spacing.l)
                .accessibilityHidden(true)
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// A soft rounded field that warms up while it's being typed in.
    func onboardingField(focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        return self
            .foregroundStyle(.hearthText)
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .frame(minHeight: 50)
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(focused ? Color.hearthAccent : Color.hearthLine, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}
