// First-run flow (RootView shows it until onboarding is done): welcome, the privacy promise, 18+, town gossip
// and the AI disclosure, your name, the town's voice (model), and a first friend. Finishing opens that chat
// on Home. A model download on cellular data asks first.

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .welcome
    @State private var movingForward = true
    @State private var draft = OnboardingDraft()
    /// A model download waiting for the person's OK, because this iPhone is on cellular data.
    @State private var cellularChoice: OnboardingEngineChoice?
    @State private var checkingNetwork = false

    private enum Step: Int, CaseIterable {
        case welcome, privacy, consent, name, voice, town
    }

    /// Suggested first friends, in this order. Anyone missing is replaced by another resident.
    private static let firstFriendIDs = ["juno", "theo", "luna", "agnes", "nora", "pip"]

    var body: some View {
        ZStack {
            Color.hearthBackground
                .ignoresSafeArea()
            page
                .id(step)
                .transition(pageTransition)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay(alignment: .topLeading) { backButton }
        .sensoryFeedback(.impact(weight: .light), trigger: step) { _, _ in app.settings.haptics }
        .confirmationDialog("Download over cellular data?", isPresented: cellularBinding, titleVisibility: .visible,
                            presenting: cellularChoice) { choice in
            Button("Download now") {
                if OnboardingVoiceOptions.confirm(choice, app: app, allowsCellular: true) { advance() }
            }
            Button("Later, on Wi-Fi") {
                OnboardingVoiceOptions.skip(app: app)
                advance()
            }
        } message: { choice in
            Text(OnboardingVoiceOptions.cellularMessage(for: choice))
        }
    }

    private var cellularBinding: Binding<Bool> {
        Binding(get: { cellularChoice != nil }, set: { if !$0 { cellularChoice = nil } })
    }

    // MARK: Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            OnboardingWelcomePage()
        case .privacy:
            OnboardingPrivacyPage()
        case .consent:
            OnboardingConsentPage(isAdult: $draft.isAdult, townGossip: $draft.townGossip)
        case .name:
            OnboardingNamePage(name: $draft.name, about: $draft.about, suggestedFaces: Array(residents.prefix(4)))
        case .voice:
            OnboardingVoicePage(choice: $draft.engine)
        case .town:
            OnboardingTownPage(friendID: $draft.friendID, residents: residents)
        }
    }

    /// The new page slides in from the side you're heading to; the old one fades away.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let shift: CGFloat = movingForward ? 56 : -56
        return .asymmetric(insertion: .offset(x: shift).combined(with: .opacity), removal: .opacity)
    }

    private var residents: [Character] {
        let library = app.library
        var picked = Self.firstFriendIDs.compactMap { library.character($0) }
        for character in library.world.characters where picked.count < 6 && !picked.contains(where: { $0.id == character.id }) {
            picked.append(character)
        }
        return picked
    }

    // MARK: Bottom bar and back button

    private struct CallToAction {
        var title: String
        var symbol: String?
        var enabled = true
        /// Shown under the button while it is disabled.
        var hint: String?
    }

    private var callToAction: CallToAction {
        switch step {
        case .welcome:
            return CallToAction(title: "Get started")
        case .privacy:
            return CallToAction(title: "Sounds good")
        case .consent:
            return CallToAction(title: "Continue", enabled: draft.isAdult,
                                hint: "Please confirm you're 18 or older to continue.")
        case .name:
            return CallToAction(title: "Continue", enabled: !draft.trimmedName.isEmpty,
                                hint: "Add a name so they know what to call you.")
        case .voice:
            return CallToAction(title: OnboardingVoiceOptions.buttonTitle(for: draft.engine, app: app, short: largeText),
                                enabled: draft.engine != nil)
        case .town:
            if residents.isEmpty { return CallToAction(title: "Start exploring") }
            guard let id = draft.friendID, let friend = app.library.character(id) else {
                return CallToAction(title: "Pick someone to meet", enabled: false)
            }
            return CallToAction(title: "Say hi to \(friend.name)", symbol: largeText ? nil : "bubble.left.fill")
        }
    }

    /// At accessibility text sizes the button keeps its words short so they fit on one line.
    private var largeText: Bool { dynamicTypeSize.isAccessibilitySize }

    private var bottomBar: some View {
        let action = callToAction
        return VStack(spacing: Spacing.m) {
            OnboardingPageDots(count: Step.allCases.count, current: step.rawValue)
            PillButton(action.title, symbol: action.symbol, action: primaryTapped)
                .fullWidth()
                .minimumScaleFactor(0.5)
                .disabled(!action.enabled)
            if let hint = action.hint, !action.enabled {
                Text(hint)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .multilineTextAlignment(.center)
            }
            if step == .voice {
                PillButton("Not now", kind: .quiet) {
                    OnboardingVoiceOptions.skip(app: app)
                    advance()
                }
                .accessibilityHint("Skip the download for now. You can get a model later in You, Model.")
                Text(OnboardingVoiceOptions.skipNote(app: app))
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background {
            // Solid behind the bar, with a short fade above it so scrolling text slips away softly.
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.hearthBackground.opacity(0), Color.hearthBackground],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
                Color.hearthBackground
            }
            .padding(.top, -28)
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.snappy, value: step)
    }

    @ViewBuilder
    private var backButton: some View {
        if step != .welcome {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.hearthText)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, Spacing.l)
            .padding(.top, Spacing.xs)
            .accessibilityLabel("Back")
        }
    }

    // MARK: Moving through the steps

    private func primaryTapped() {
        switch step {
        case .welcome, .privacy, .consent, .name:
            advance()
        case .voice:
            guard let choice = draft.engine else { return }
            guard OnboardingVoiceOptions.startsDownload(choice, app: app) else {
                if OnboardingVoiceOptions.confirm(choice, app: app) { advance() }
                return
            }
            // Models are big (Lite about 0.8 GB, Standard about 2 GB): on cellular data or in Low Data Mode, ask first.
            guard !checkingNetwork else { return }
            checkingNetwork = true
            Task {
                if await SettingsModelActions.onExpensiveNetwork() {
                    cellularChoice = choice
                } else if OnboardingVoiceOptions.confirm(choice, app: app) {
                    advance()
                }
                checkingNetwork = false
            }
        case .town:
            finish()
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        move(to: next, forward: true)
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        move(to: previous, forward: false)
    }

    private func move(to next: Step, forward: Bool) {
        movingForward = forward
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.38)) {
            step = next
        }
    }

    /// Saves who you are, marks onboarding done, and opens the chat with your first friend on Home.
    private func finish() {
        let name = draft.trimmedName
        let about = draft.trimmedAbout
        router.homePath = []
        if let id = draft.friendID, app.library.character(id) != nil {
            router.show(.startChat(characterID: id), in: .home)
        } else {
            router.tab = .home
        }
        app.settingsStore.update { settings in
            settings.persona.name = name.isEmpty ? UserPersona().name : name
            settings.persona.about = about
            settings.townGossip = draft.townGossip
            settings.confirmedAdult = true
            settings.onboardingDone = true
        }
    }
}

/// Small dots that show which step you're on; the current one is a wider ember capsule.
private struct OnboardingPageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Color.hearthAccent : Color.hearthMuted.opacity(0.45))
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
