// The App Lock screen (asks for Face ID, Touch ID or the passcode once each time Hearth comes back) and the
// plain shield that hides Hearth in the app switcher. Neither shows anything private.

import SwiftUI

struct LockView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var askedThisVisit = false
    @State private var failedTries = 0
    @State private var method = "Face ID"

    var body: some View {
        VStack(spacing: Spacing.xl) {
            Spacer(minLength: Spacing.xl)
            HearthLanternMark(height: 128)
            VStack(spacing: Spacing.s) {
                Text("Hearth is locked")
                    .modifier(SettingsScaledTitle(32))
                    .foregroundStyle(.hearthText)
                    .accessibilityAddTraits(.isHeader)
                Text("Your chats stay private until you unlock.")
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText2)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Spacing.xl)
            Spacer(minLength: Spacing.xl)
            PillButton(buttonTitle, symbol: buttonSymbol) {
                Task { await unlock() }
            }
            .fullWidth()
            .minimumScaleFactor(0.5)
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { LockBackdrop() }
        .task {
            method = app.vault.unlockMethodName
            if scenePhase == .active { await askOnce() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await askOnce() }
            case .background: askedThisVisit = false
            default: break
            }
        }
        .sensoryFeedback(.error, trigger: failedTries) { _, _ in app.settings.haptics }
    }

    private var buttonTitle: String {
        method == "Passcode" ? "Unlock with passcode" : "Unlock with \(method)"
    }

    private var buttonSymbol: String {
        switch method {
        case "Face ID": return "faceid"
        case "Touch ID": return "touchid"
        case "Optic ID": return "opticid"
        default: return "lock.open.fill"
        }
    }

    /// Prompts by itself once per return to the app, so cancelling the prompt never makes it pop up again.
    private func askOnce() async {
        guard !askedThisVisit, app.vault.isLocked else { return }
        askedThisVisit = true
        await unlock()
    }

    private func unlock() async {
        let unlocked = await app.vault.unlock(reason: "Unlock your chats")
        if !unlocked { failedTries += 1 }
    }
}

/// A soft, blurred night view of the town behind the lock screen.
private struct LockBackdrop: View {
    var body: some View {
        Color.hearthBackground
            .overlay {
                HearthCachedImage(source: .bundled("hero-night"), maxPixel: 512) { phase in
                    if case .loaded(let image) = phase {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 36)
                            .opacity(0.55)
                    }
                }
            }
            .overlay {
                LinearGradient(colors: [Color.hearthBackground.opacity(0.35), Color.hearthBackground.opacity(0.9)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay {
                RadialGradient(colors: [Color.hearthAccent.opacity(0.18), .clear], center: .center, startRadius: 0, endRadius: 360)
            }
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Covers Hearth while it isn't active, so the app switcher only shows the lantern.
struct PrivacyShieldView: View {
    var body: some View {
        ZStack {
            Color.hearthBackground
                .ignoresSafeArea()
            HearthLanternMark(height: 112)
        }
        .accessibilityElement()
        .accessibilityLabel("Hearth")
    }
}
