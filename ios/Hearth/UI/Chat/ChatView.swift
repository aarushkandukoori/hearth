// The 1:1 chat screen (Character.AI layout in Hearth's colors): avatar, name and "by @creator" up top
// with Call and a menu, the messages (the support card follows the one that called for it), then engine
// and error cards, the composer and a quiet AI disclosure. ChatView uses one ChatController (shared with
// a call or a reply still being written) and deactivates it when the screen goes away.

import SwiftUI

struct ChatView: View {
    let conversationID: UUID
    @Environment(AppModel.self) private var app
    @State private var controller: ChatController?
    @State private var holding = false

    var body: some View {
        Group {
            if let controller, controller.conversationID == conversationID {
                ChatScreen(controller: controller)
            } else {
                Color.clear
            }
        }
        .hearthScreenBackground()
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .onChange(of: conversationID) {
            disappear()
            appear()
        }
    }

    private func appear() {
        if controller?.conversationID != conversationID {
            // A call, or a reply still being written after the chat was left, may already have this
            // chat's controller: share it, so there is never a second reply running beside the first.
            controller = ChatController.live(for: conversationID) ?? ChatController(conversationID: conversationID, app: app)
            holding = false
        }
        guard !holding, let controller else { return }
        holding = true
        controller.activate()
    }

    private func disappear() {
        guard holding, let controller else { return }
        holding = false
        Task { await controller.deactivate() }
    }
}

private struct ChatScreen: View {
    let controller: ChatController
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ChatController.readAloudKey) private var readAloud = false
    @State private var showsHistory = false
    @State private var confirmsDelete = false
    @State private var editing: Message?
    @State private var viewing: ChatPictureViewer.Item?
    @State private var supportCardVisible = false

    var body: some View {
        if let character = controller.character, controller.exists {
            chat(character)
        } else {
            EmptyStateView(symbol: "bubble.left.and.text.bubble.right",
                           title: "This chat isn't here anymore",
                           message: "It may have been deleted. Your other chats are in the Chats tab.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func chat(_ character: Character) -> some View {
        @Bindable var controller = controller
        return ChatMessageList(controller: controller, character: character,
                               onEdit: { editing = $0 }, onOpenPicture: { viewing = $0 },
                               supportCardVisible: $supportCardVisible)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatBottomBar(controller: controller, character: character, supportCardVisible: supportCardVisible)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar(character) }
            .toolbarVisibility(.hidden, for: .tabBar)
            .hearthToast($controller.notice)
            .sheet(isPresented: $showsHistory) {
                ChatHistorySheet(character: character, currentID: controller.conversationID) { id in
                    if id != controller.conversationID { router.replaceTop(with: .chat(conversationID: id)) }
                }
            }
            .sheet(item: $editing) { message in
                ChatEditSheet(message: message, characterName: character.name) { text in
                    controller.edit(messageID: message.id, text: text)
                }
            }
            .fullScreenCover(item: $viewing) { item in
                ChatPictureViewer(item: item)
            }
            .confirmationDialog("Delete this chat?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete chat", role: .destructive) { deleteChat() }
            } message: {
                Text("Its messages, photos and voice notes will be erased from this iPhone. What \(character.name) remembers about you stays until you forget it in Memories.")
            }
    }

    @ToolbarContentBuilder
    private func toolbar(_ character: Character) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button { router.open(.profile(characterID: character.id)) } label: {
                HStack(spacing: Spacing.s) {
                    AvatarView(character.avatar, size: 32)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(character.name)
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        Text(ChatPipeline.byLine(character.creator))
                            .font(HearthFont.small)
                            .foregroundStyle(.hearthMuted)
                    }
                    .lineLimit(1)
                }
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // the bar has a fixed height
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(character.name), \(ChatPipeline.byLine(character.creator))")
            .accessibilityHint("Opens their profile")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { router.startCall(conversationID: controller.conversationID) } label: {
                Image(systemName: "phone.fill")
            }
            .accessibilityLabel("Call \(character.name)")

            Menu {
                Button("New chat", systemImage: "square.and.pencil") {
                    router.replaceTop(with: .newChat(characterID: character.id))
                }
                Button("Chat history", systemImage: "clock.arrow.circlepath") { showsHistory = true }
                Button("What \(character.name) remembers", systemImage: "brain.head.profile") {
                    router.open(.memories(characterID: character.id))
                }
                Toggle(isOn: $readAloud) {
                    Label("Play replies aloud", systemImage: "speaker.wave.2")
                }
                Button("Get support", systemImage: "heart") { controller.showSupport() }
                Divider()
                Button("Delete chat", systemImage: "trash", role: .destructive) { confirmsDelete = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Chat options")
        }
    }

    private func deleteChat() {
        controller.stop()
        app.deleteConversation(controller.conversationID)
        dismiss()
    }
}

/// Everything under the messages: engine and error cards, the composer, the disclosure. (The support card
/// scrolls with the messages instead, so it never squeezes the conversation; while it's out of view, a
/// one-line shortcut to call or text stays here.)
private struct ChatBottomBar: View {
    let controller: ChatController
    let character: Character
    let supportCardVisible: Bool
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    /// The shortcut shows a moment after the card leaves the screen, so it doesn't flash while a new card
    /// is still being placed.
    @State private var showsSupportChip = false

    private var wantsSupportChip: Bool { controller.safety != .none && !supportCardVisible }

    var body: some View {
        VStack(spacing: Spacing.s) {
            if showsSupportChip {
                ChatSupportChip { controller.showSupport() }
                    .transition(.opacity)
            }
            ChatEngineBanner()
            if let error = controller.errorText, ChatController.engineAccepts(app.engine.state) {
                // After a couple of failures in a row, trying the same model again isn't enough.
                ChatErrorBanner(text: error, canRetry: controller.canSend,
                                onRetry: {
                                    controller.errorText = nil
                                    Task { await controller.regenerate() }
                                },
                                onDismiss: { controller.errorText = nil },
                                onModels: controller.failedReplies >= 2 ? { router.show(.settings(.model), in: .you) } : nil)
                    .transition(.opacity)
            }
            ChatComposer(controller: controller, character: character)
            Text("Hearth characters are AI. What they say is made up.")
                .font(HearthFont.small)
                .foregroundStyle(.hearthMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.xs)
        .background {
            // Fades the messages out under the composer so the glass stays readable.
            LinearGradient(colors: [Color.hearthBackground.opacity(0), Color.hearthBackground.opacity(0.92)],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(.smooth(duration: 0.25), value: controller.errorText)
        .animation(.smooth(duration: 0.25), value: showsSupportChip)
        .task(id: wantsSupportChip) {
            if wantsSupportChip {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
            }
            showsSupportChip = wantsSupportChip
        }
    }
}

/// This character's other chats, newest first. Tap one to open it here.
private struct ChatHistorySheet: View {
    let character: Character
    let currentID: UUID
    let onOpen: (UUID) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: Conversation?

    var body: some View {
        let chats = app.chats.directChats(with: character.id)
            .filter { $0.id == currentID || $0.messages.contains { $0.role == .user } }
        NavigationStack {
            List {
                ForEach(chats) { conversation in
                    Button {
                        onOpen(conversation.id)
                        dismiss()
                    } label: {
                        row(conversation)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.hearthSurface)
                    // Deleting can't be undone, so it always asks first (like the Chats tab). Not a
                    // destructive-role button: that would animate the row away before the answer.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if conversation.id != currentID {
                            Button { pendingDelete = conversation } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(.hearthDanger)
                        }
                    }
                }
            }
            .hearthScreenBackground()
            .navigationTitle("Chats with \(character.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete this chat with \(character.name)?", isPresented: deleteBinding,
                                titleVisibility: .visible, presenting: pendingDelete) { conversation in
                Button("Delete chat", role: .destructive) { app.deleteConversation(conversation.id) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("It's removed from this iPhone for good, with any photos and voice notes in it.")
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func row(_ conversation: Conversation) -> some View {
        let last = conversation.messages.last { $0.role != .narrator }
        let preview = last.map { BrainText.oneLine($0.text.isEmpty ? ($0.attachment?.caption ?? "") : $0.text) } ?? ""
        let isCurrent = conversation.id == currentID
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthText2)
                if isCurrent {
                    Text("Open now")
                        .font(HearthFont.small)
                        .foregroundStyle(.hearthAccentText)
                }
                Spacer(minLength: 0)
                Text("\(conversation.messages.count) messages")
                    .font(HearthFont.small)
                    .foregroundStyle(.hearthMuted)
            }
            Text(preview.isEmpty ? "Just the greeting so far" : preview)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText)
                .lineLimit(2)
        }
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Edit a message's text (the shown alternate, for a character's reply).
private struct ChatEditSheet: View {
    let message: Message
    let characterName: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(message: Message, characterName: String, onSave: @escaping (String) -> Void) {
        self.message = message
        self.characterName = characterName
        self.onSave = onSave
        _text = State(initialValue: message.text)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(Spacing.m)
                .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .padding(Spacing.l)
                .hearthScreenBackground()
                .navigationTitle(message.role == .user ? "Edit your message" : "Edit \(characterName)'s reply")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}

private extension Router {
    /// Swaps the screen on top of the current tab for another (New chat and history replace this chat).
    func replaceTop(with route: AppRoute) {
        switch tab {
        case .home, .create:
            if !homePath.isEmpty { homePath.removeLast() }
            homePath.append(route)
        case .town:
            if !townPath.isEmpty { townPath.removeLast() }
            townPath.append(route)
        case .chats:
            if !chatsPath.isEmpty { chatsPath.removeLast() }
            chatsPath.append(route)
        case .you:
            if !youPath.isEmpty { youPath.removeLast() }
            youPath.append(route)
        }
    }
}
