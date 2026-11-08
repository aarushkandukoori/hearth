// A push-to-talk voice call: hold the big button and talk, let go, and the character answers out loud
// sentence by sentence as the reply is written. Speech is recognized on this iPhone only, and
// everything said lands in the chat as text. Support resources show here too when something sounds worrying.

import SwiftUI

struct CallView: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var controller: ChatController?
    /// True when the chat screen is open under the call (we share its controller).
    @State private var chatIsOpen = false

    var body: some View {
        Group {
            if let controller, let character = controller.character, controller.exists {
                CallScreen(controller: controller, character: character, chatIsOpen: chatIsOpen)
            } else if controller != nil {
                VStack(spacing: Spacing.xl) {
                    EmptyStateView(symbol: "phone.down.fill", title: "This call can't start",
                                   message: "The chat it belongs to isn't here anymore.")
                    PillButton("Close", kind: .secondary) { router.endCall() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
            }
        }
        .hearthScreenBackground()
        .onAppear(perform: begin)
        .onDisappear(perform: end)
    }

    private func begin() {
        guard controller == nil else { return }
        let live = ChatController.live(for: conversationID)
        chatIsOpen = live?.isInUse == true
        let shared = live ?? ChatController(conversationID: conversationID, app: app)
        shared.activate()
        shared.speaksRepliesLive = true
        controller = shared
    }

    private func end() {
        guard let controller else { return }
        controller.speaksRepliesLive = false
        app.dictation.cancel()
        app.voice.stop()
        Task { await controller.deactivate() }
    }
}

private enum CallPhase {
    case idle, listening, thinking, speaking
}

private struct CallScreen: View {
    let controller: ChatController
    let character: Character
    let chatIsOpen: Bool

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @GestureState private var pressing = false
    @State private var talking = false
    @State private var problem: String?
    @State private var cannotListen = false

    private var phase: CallPhase {
        if talking { return .listening }
        if app.voice.isSpeaking { return .speaking }
        if controller.isReplying { return .thinking }
        return .idle
    }

    var body: some View {
        // The talk and end buttons stay pinned at the bottom. Everything above them scrolls when it doesn't
        // fit (small iPhones, very large text, the support card) and stays centered when it does.
        GeometryReader { proxy in
            ScrollView {
                content(height: proxy.size.height)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .background {
            RadialGradient(colors: [Color(hex: character.accentHex).opacity(0.28), .clear],
                           center: .init(x: 0.5, y: 0.32), startRadius: 10, endRadius: 420)
                .ignoresSafeArea()
        }
        .animation(.smooth(duration: 0.3), value: phase)
        .animation(.smooth(duration: 0.3), value: controller.safety)
        .onChange(of: pressing) { _, isPressing in
            if isPressing { startTalking() } else if talking { stopTalking() }
        }
        .onChange(of: app.dictation.state) { _, state in
            switch state {
            case .unavailable(let message):
                talking = false
                cannotListen = true
                problem = message
            case .failed(let message):
                talking = false
                problem = message
            default:
                break
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: talking) { _, isOn in isOn && app.settings.haptics }
    }

    private func content(height: CGFloat) -> some View {
        VStack(spacing: Spacing.l) {
            HStack {
                PrivacyBadge("On-device call")
                Spacer()
            }
            .padding(.horizontal, Spacing.xl)

            CallAvatar(character: character, accent: Color(hex: character.accentHex), phase: phase,
                       level: app.dictation.level, scale: avatarScale(height: height))
            VStack(spacing: Spacing.s) {
                Text(character.name)
                    .font(HearthFont.title(32))
                    .foregroundStyle(.hearthText)
                Text(stateText)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText2)
                    .contentTransition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            captions
            if phase == .idle, problem == nil, let message = replyProblem {
                problemCard(message, onRetry: retryReply)
            }
            if controller.safety != .none {
                ChatSafetyCard(level: controller.safety) { controller.dismissSafety() }
                    .frame(maxWidth: 460)
                    .padding(.horizontal, Spacing.l)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, Spacing.l)
    }

    /// The avatar takes what the screen has room for: full size on big iPhones, smaller on small ones, with
    /// very large text, or while support options are showing.
    private func avatarScale(height: CGFloat) -> CGFloat {
        if typeSize.isAccessibilitySize || controller.safety != .none { return 0.6 }
        return min(1, max(0.55, height * 0.45 / 300))
    }

    /// Always on screen: talk (or what's in the way of talking), end the call, and the AI disclosure.
    private var controls: some View {
        VStack(spacing: Spacing.l) {
            if let problem {
                problemCard(problem, onRetry: cannotListen ? nil : { self.problem = nil })
            } else if !ChatController.engineAccepts(app.engine.state) {
                problemCard("Hearth needs its model on this iPhone before you can talk.", modelButton: true)
            } else {
                talkButton(accent: Color(hex: character.accentHex))
            }
            endButton
            Text("Hearth characters are AI. What they say is made up.")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.xl)
        }
        .padding(.top, Spacing.m)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: .infinity)
        .background {
            // Fades what scrolls underneath, so the buttons stay easy to see.
            LinearGradient(colors: [Color.hearthBackground.opacity(0), Color.hearthBackground.opacity(0.92)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var stateText: String {
        switch phase {
        case .idle: return "Hold the button to talk"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        }
    }

    /// Why the last thing said got no answer: an error, or a note that the model declined. nil otherwise.
    private var replyProblem: String? {
        guard !controller.isReplying, ChatController.engineAccepts(app.engine.state) else { return nil }
        if let error = controller.errorText { return error }
        if let last = controller.conversation.messages.last, last.role == .narrator { return last.text }
        return nil
    }

    /// What is being said right now, as text (your words while you talk, then the reply).
    private var captions: some View {
        let line: String
        switch phase {
        case .listening:
            line = app.dictation.transcript
        case .thinking, .speaking:
            line = controller.streamingText ?? controller.lastReply?.text ?? ""
        case .idle:
            line = controller.lastReply?.text ?? ""
        }
        return Text(ChatMarkup.attributed(line, actionColor: .hearthMuted))
            .font(HearthFont.body)
            .foregroundStyle(phase == .idle ? Color.hearthMuted : Color.hearthText)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .truncationMode(.head)
            .frame(maxWidth: 460, minHeight: 60)
            .padding(.horizontal, Spacing.xl)
            .accessibilityLabel(line.isEmpty ? "" : line)
    }

    private func talkButton(accent: Color) -> some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: talking ? "waveform" : "mic.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.hearthOnAccent)
                .symbolEffect(.variableColor.iterative, isActive: talking)
                .frame(width: 104, height: 104)
                .background(Color.hearthAccent, in: Circle())
                .shadow(color: Color.hearthAccent.opacity(talking ? 0.55 : 0.25), radius: talking ? 24 : 12)
                .scaleEffect(talking ? 1.08 : 1)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true })
                .accessibilityElement()
                .accessibilityLabel(talking ? "Stop talking" : "Hold to talk")
                .accessibilityHint("With VoiceOver, double-tap to start talking and double-tap again when you're done.")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    if talking { stopTalking() } else { startTalking() }
                }
            Text(talking ? "Let go when you're done" : "Hold to talk")
                .font(HearthFont.callout.weight(.semibold))
                .foregroundStyle(.hearthText2)
                .accessibilityHidden(true)
        }
        .animation(.snappy(duration: 0.2), value: talking)
    }

    private var endButton: some View {
        Button { router.endCall() } label: {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.hearthDanger, in: Circle())
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("End call")
    }

    /// A problem with talking or with the last reply. `onRetry` nil hides "Try again".
    private func problemCard(_ message: String, modelButton: Bool = false, onRetry: (() -> Void)? = nil) -> some View {
        VStack(spacing: Spacing.m) {
            Text(message)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if modelButton {
                PillButton("Get the model", symbol: "arrow.down") {
                    router.endCall()
                    router.show(.settings(.model), in: .you)
                }
            } else {
                HStack(spacing: Spacing.s) {
                    PillButton("Type instead", symbol: "keyboard", kind: .secondary) { typeInstead() }
                    if let onRetry {
                        PillButton("Try again", kind: .quiet, action: onRetry)
                    }
                }
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: 420)
        .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(.horizontal, Spacing.xl)
    }

    // MARK: Talking

    private func startTalking() {
        guard !talking, problem == nil else { return }
        // Talking over the character stops them, like a real call.
        if controller.isReplying || app.voice.isSpeaking { controller.stop() }
        controller.errorText = nil
        talking = true
        Task { await app.dictation.start() }
    }

    private func stopTalking() {
        guard talking else { return }
        talking = false
        Task {
            let result = await app.dictation.stop()
            ChatController.removeMediaFile(result.attachment?.file) // a call keeps your words, not the recording
            let words = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            // Talking over a reply stops it, but the stop can take a moment to land (the model only checks
            // between batches). Wait for it, so what the person said is never dropped.
            var waits = 0
            while controller.isReplying && waits < 40 { // up to 4 seconds
                controller.stop()
                try? await Task.sleep(for: .milliseconds(100))
                waits += 1
            }
            guard controller.canSend else {
                controller.errorText = "That got lost while the reply was still going. Please say it again."
                return
            }
            await controller.send(text: words)
        }
    }

    /// Asks for the answer again; like every reply in a call, it is spoken as it comes.
    private func retryReply() {
        controller.errorText = nil
        Task { await controller.regenerate() }
    }

    private func typeInstead() {
        router.endCall()
        if !chatIsOpen { router.open(.chat(conversationID: controller.conversationID)) }
    }
}

/// The character with soft rings: they follow your voice while you talk and pulse while they speak.
private struct CallAvatar: View {
    let character: Character
    let accent: Color
    let phase: CallPhase
    let level: Float
    /// 1 on big iPhones; smaller on small ones, with very large text, or while support options show.
    var scale: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || phase == .idle)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let size = (200 + CGFloat(ring) * 48) * scale
                    Circle()
                        .fill(accent.opacity(0.16 - Double(ring) * 0.04))
                        .frame(width: size, height: size)
                        .scaleEffect(ringScale(ring: ring, time: time))
                        .opacity(phase == .idle ? 0.55 : 1)
                }
                AvatarView(character.avatar, size: 176 * scale, ring: accent.opacity(0.8))
            }
        }
        .frame(width: 300 * scale, height: 300 * scale)
        .animation(.smooth(duration: 0.15), value: level)
        .accessibilityHidden(true)
    }

    private func ringScale(ring: Int, time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let r = Double(ring)
        switch phase {
        case .idle:
            return 1
        case .listening:
            return 1 + CGFloat(min(max(level, 0), 1)) * CGFloat(0.08 + 0.05 * r)
        case .thinking:
            return 1 + CGFloat(0.025 * sin(time * 2 * .pi / 2.4 - r * 0.6))
        case .speaking:
            return 1 + CGFloat(0.06 * (0.5 + 0.5 * sin(time * 2 * .pi / 1.2 - r * 0.8)))
        }
    }
}
