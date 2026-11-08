// A group scene at one place in Lantern Bay: the place's art, who is here, the conversation (every line
// shows who said it), "Let them talk", invites, and a composer for talking to everyone at once.

import SwiftUI

struct SceneView: View {
    let locationID: String
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var controller: SceneController?

    init(locationID: String) {
        self.locationID = locationID
    }

    var body: some View {
        Group {
            if let location = app.library.location(locationID) {
                if let controller {
                    SceneScreen(controller: controller, location: location)
                } else {
                    Color.clear
                }
            } else {
                EmptyStateView(symbol: "map", title: "That place isn't on the map",
                               message: "It may have moved. Lantern Bay has plenty of other spots to visit.",
                               actionTitle: "Back to town") { router.popToRoot() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .hearthScreenBackground()
        .onAppear(perform: attach)
        .onDisappear(perform: closeIfLeft)
    }

    private func attach() {
        guard controller == nil, app.library.location(locationID) != nil else { return }
        controller = SceneController.live(for: locationID) ?? SceneController(locationID: locationID, app: app)
    }

    /// Leaving for good (not just opening a profile on top or switching tabs): stop and park.
    private func closeIfLeft() {
        guard let controller else { return }
        let route = AppRoute.scene(locationID: locationID)
        let stillOpen = [router.homePath, router.townPath, router.chatsPath, router.youPath].contains { $0.contains(route) }
        guard !stillOpen else { return }
        Task { await controller.deactivate() }
    }
}

private struct SceneScreen: View {
    @Bindable var controller: SceneController
    let location: Location

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var draft = ""
    @State private var showInvite = false
    @State private var confirmStartOver = false
    @State private var nearBottom = true
    @State private var sentCount = 0
    @FocusState private var composerFocused: Bool

    private static let bottomID = "scene-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.l) {
                    SceneBanner(location: location, worldName: app.library.world.name, part: DayPart.at(.now))
                    ScenePresentStrip(present: controller.present, invited: controller.invitedIDs,
                                      inviteDisabled: controller.isReplying,
                                      onProfile: { router.open(.profile(characterID: $0)) },
                                      onInvite: { showInvite = true })
                    if !controller.present.isEmpty && controller.conversation.messages.isEmpty {
                        tip
                    }
                    ForEach(controller.conversation.messages) { message in
                        SceneLine(message: message, speaker: message.speakerID.flatMap { app.library.character($0) },
                                  canDelete: !controller.isReplying,
                                  onProfile: { router.open(.profile(characterID: $0)) },
                                  onDelete: { controller.deleteMessage(message.id) })
                            .padding(.horizontal, Spacing.l)
                            .transition(.opacity)
                    }
                    if let id = controller.streamingSpeakerID, let speaker = app.library.character(id) {
                        SceneStreamingLine(speaker: speaker, text: controller.streamingText)
                            .padding(.horizontal, Spacing.l)
                    }
                    if controller.present.isEmpty {
                        nobodyHere
                    }
                    if controller.safety != .none {
                        SceneSupportCard(level: controller.safety) {
                            withAnimation(.snappy) { controller.hideSupport() }
                        }
                        .padding(.horizontal, Spacing.l)
                        .transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.bottom, Spacing.s)
                .animation(.snappy, value: controller.conversation.messages.count)
                .animation(.snappy, value: controller.safety)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 160
            } action: { _, isNear in
                nearBottom = isNear
            }
            .onAppear {
                if !controller.conversation.messages.isEmpty { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: controller.conversation.messages.count) { _, _ in
                // Follow along when already at the bottom, and always right after the person speaks.
                let theyJustSpoke = controller.conversation.messages.last?.role == .user
                if nearBottom || theyJustSpoke { withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .onChange(of: controller.streamingText) { _, _ in
                if nearBottom { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: controller.streamingSpeakerID) { _, _ in
                if nearBottom { withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .onChange(of: controller.safety) { _, level in
                if level != .none { withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
            .onChange(of: controller.supportRequests) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: sentCount) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            }
            .onChange(of: composerFocused) { _, focused in
                if focused { withAnimation(.snappy) { proxy.scrollTo(Self.bottomID, anchor: .bottom) } }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .navigationTitle(location.name)
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { menu } }
        .sheet(isPresented: $showInvite) {
            SceneInviteSheet(controller: controller, location: location)
        }
        .confirmationDialog("Start this scene over?", isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Start over", role: .destructive) { controller.startOver() }
        } message: {
            Text("The conversation at \(TownText.inSentence(location.name)) will be cleared from this iPhone. This can't be undone.")
        }
        .hearthToast($controller.notice)
        .sensoryFeedback(trigger: sentCount) { _, _ in app.settings.haptics ? .impact(weight: .light) : nil }
        .task {
            // People come and go as the day moves on.
            while !Task.isCancelled {
                controller.refreshPresent()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var subtitle: String {
        switch controller.present.count {
        case 0: return "Nobody here right now"
        case 1: return "\(controller.present[0].name) is here"
        default: return "\(controller.present.count) here now"
        }
    }

    private var engineReady: Bool { app.engine.state == .ready }

    private var canSend: Bool {
        engineReady && !controller.isReplying && !controller.present.isEmpty
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canTalk: Bool {
        engineReady && !controller.isReplying && controller.present.count >= 2
    }

    // MARK: Content

    private var tip: some View {
        let people = controller.present
        let text = people.count > 1
            ? "Say hello to \(TownText.names(people)). Use a name to talk to someone, or tap Let them talk to listen in."
            : "Say hello to \(people.first?.name ?? "everyone"), or invite someone to join you."
        return Label(text, systemImage: "hand.wave")
            .font(HearthFont.callout)
            .foregroundStyle(.hearthText2)
            .padding(.horizontal, Spacing.l)
    }

    private var nobodyHere: some View {
        HearthCard(padding: 0) {
            EmptyStateView(symbol: "moon.zzz.fill", title: "Nobody's here right now",
                           message: "It's quiet at \(TownText.inSentence(location.name)) for now. Invite someone over to keep you company.",
                           actionTitle: "Invite someone") { showInvite = true }
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Spacing.l)
    }

    private var menu: some View {
        Menu {
            Button("Invite someone", systemImage: "person.badge.plus") { showInvite = true }
                .disabled(controller.isReplying)
            Button("Let them talk", systemImage: "bubble.left.and.bubble.right") { talk() }
                .disabled(!canTalk)
            Button("Get support", systemImage: "heart") {
                withAnimation(.snappy) { controller.showSupport() }
            }
            Divider()
            Button("Start over", systemImage: "arrow.counterclockwise", role: .destructive) { confirmStartOver = true }
                .disabled(controller.isReplying || controller.conversation.messages.isEmpty)
        } label: {
            Label("Scene options", systemImage: "ellipsis")
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: Spacing.s) {
            SceneEngineBanner()
            if let error = controller.errorText {
                ChatErrorBanner(text: error, canRetry: engineReady && controller.canRetry && !controller.isReplying,
                                onRetry: { Task { await controller.retry() } },
                                onDismiss: { controller.dismissError() })
                    .transition(.opacity)
            }
            if !controller.present.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.s) {
                        SceneChip(title: "Let them talk", symbol: "bubble.left.and.bubble.right.fill", action: talk)
                            .disabled(!canTalk)
                        SceneChip(title: "Invite…", symbol: "person.badge.plus") { showInvite = true }
                            .disabled(controller.isReplying)
                    }
                    .padding(.horizontal, Spacing.l)
                }
                .scrollIndicators(.hidden)
                .padding(.horizontal, -Spacing.l)
                // The chips are shortcuts (the ••• menu has them too), so they stop growing before the
                // conversation runs out of room.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
            composer
            Text("Hearth characters are AI. What they say is made up.")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .animation(.smooth(duration: 0.25), value: controller.errorText)
        .background {
            LinearGradient(stops: [.init(color: Color.hearthBackground.opacity(0), location: 0),
                                   .init(color: Color.hearthBackground.opacity(0.94), location: 0.22),
                                   .init(color: Color.hearthBackground, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: Spacing.s) {
            TextField(controller.present.isEmpty ? "Invite someone to start talking" : "Say something to everyone…",
                      text: $draft, axis: .vertical)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .lineLimit(1...5)
                .focused($composerFocused)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .background(Color.hearthSurface2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.hearthLine, lineWidth: 1))
                .disabled(controller.present.isEmpty)
                .accessibilityLabel("Message everyone here")

            Button {
                if controller.isReplying { controller.stop() } else { send() }
            } label: {
                Image(systemName: controller.isReplying ? "stop.fill" : "arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.hearthOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(canSend || controller.isReplying ? Color.hearthAccent : Color.hearthMuted.opacity(0.45)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .disabled(!canSend && !controller.isReplying)
            .accessibilityLabel(controller.isReplying ? "Stop" : "Send")
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !text.isEmpty else { return }
        draft = ""
        sentCount += 1
        Task { await controller.send(text: text) }
    }

    private func talk() {
        guard canTalk else { return }
        sentCount += 1
        Task { await controller.letThemTalk(count: 4) }
    }
}

#Preview("Scene") {
    let app = AppModel()
    NavigationStack { SceneView(locationID: "driftwood-cafe") }
        .environment(app)
        .environment(app.router)
}
