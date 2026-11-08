// The Chats tab: every conversation on this iPhone, newest first, as "Friends" (1:1 chats) and
// "Town scenes" (group scenes). Search by name or last message; swipe to delete, after a confirmation.

import SwiftUI

struct ChatsListView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var query = ""
    @State private var pendingDelete: Conversation?
    @State private var deletions = 0
    @State private var toast: String?

    var body: some View {
        let friends = friendChats
        let scenes = sceneChats
        Group {
            if friends.isEmpty && scenes.isEmpty {
                ScrollView { emptyState }
            } else {
                TimelineView(.everyMinute) { context in
                    list(friends: friends.filter { matches($0.searchFields) },
                         scenes: scenes.filter { matches($0.searchFields) },
                         now: context.date)
                }
                .searchable(text: $query, prompt: "Search chats")
            }
        }
        .hearthScreenBackground()
        .navigationTitle("Chats")
        .toolbarVisibility(.visible, for: .tabBar) // comes back after a chat hid it (see HomeView)
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible, presenting: pendingDelete) { conversation in
            Button(conversation.sceneLocationID == nil ? "Delete chat" : "Delete scene", role: .destructive) {
                delete(conversation)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It's removed from this iPhone for good, with any photos and voice notes in it.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: deletions) { _, _ in app.settings.haptics }
        .hearthToast($toast)
    }

    // MARK: - List

    private func list(friends: [ChatsFriend], scenes: [ChatsScene], now: Date) -> some View {
        List {
            if !friends.isEmpty {
                Section {
                    ForEach(friends) { friend in
                        friendRow(friend, now: now)
                    }
                } header: {
                    sectionTitle("Friends")
                }
            }
            if !scenes.isEmpty {
                Section {
                    ForEach(scenes) { scene in
                        sceneRow(scene, now: now)
                    }
                } header: {
                    sectionTitle("Town scenes")
                }
            }
            if friends.isEmpty && scenes.isEmpty {
                noMatches
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            PrivacyBadge("Chats stay on this iPhone")
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.l)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .listSectionSeparator(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private func friendRow(_ friend: ChatsFriend, now: Date) -> some View {
        let time = friend.conversation.updatedAt
        return Button { router.open(.chat(conversationID: friend.conversation.id)) } label: {
            CharacterRowView(character: friend.character,
                             detail: friend.preview.isEmpty ? nil : friend.preview,
                             trailing: HomeText.shortTime(time, now: now))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.m }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(friend.character.name). \(friend.preview). \(HomeText.spokenTime(time, now: now))")
        .accessibilityHint("Opens the chat")
        .modifier(ChatsRowStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteSwipe(friend.conversation) }
        .contextMenu {
            Button { router.open(.chat(conversationID: friend.conversation.id)) } label: {
                Label("Open chat", systemImage: "bubble.left.and.bubble.right")
            }
            if friend.isInLibrary {
                Button { router.open(.profile(characterID: friend.character.id)) } label: {
                    Label("View profile", systemImage: "person.crop.circle")
                }
            }
            Divider()
            Button(role: .destructive) { pendingDelete = friend.conversation } label: {
                Label("Delete chat", systemImage: "trash")
            }
        }
    }

    private func sceneRow(_ scene: ChatsScene, now: Date) -> some View {
        let time = scene.conversation.updatedAt
        return Button {
            if let id = scene.conversation.sceneLocationID { router.open(.scene(locationID: id)) }
        } label: {
            ChatsSceneRowView(scene: scene, time: HomeText.shortTime(time, now: now))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.m }
        }
        .buttonStyle(.pressable)
        .accessibilityLabel("\(scene.title). \(scene.who). \(scene.preview). \(HomeText.spokenTime(time, now: now))")
        .accessibilityHint("Opens the scene")
        .modifier(ChatsRowStyle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) { deleteSwipe(scene.conversation) }
        .contextMenu {
            if let id = scene.conversation.sceneLocationID {
                Button { router.open(.scene(locationID: id)) } label: {
                    Label("Open scene", systemImage: "person.3")
                }
            }
            Divider()
            Button(role: .destructive) { pendingDelete = scene.conversation } label: {
                Label("Delete scene", systemImage: "trash")
            }
        }
    }

    /// Not a destructive-role button: that would make the list animate the row away before the user
    /// has confirmed.
    private func deleteSwipe(_ conversation: Conversation) -> some View {
        Button { pendingDelete = conversation } label: {
            Label("Delete", systemImage: "trash")
        }
        .tint(.hearthDanger)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(HearthFont.title(19))
            .foregroundStyle(.hearthText)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    private var noMatches: some View {
        VStack(spacing: Spacing.s) {
            Text("No chats match “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .font(HearthFont.headline)
                .foregroundStyle(.hearthText)
            Text("Try a name, or a word from the last message.")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    private var emptyState: some View {
        EmptyStateView(symbol: "bubble.left.and.bubble.right",
                       title: "No chats yet",
                       message: "Say hello to someone in Lantern Bay. Your conversations will show up here, and they stay on this iPhone.",
                       actionTitle: "Find someone to talk to") {
            router.tab = .home
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
    }

    // MARK: - Data

    /// 1:1 chats the user has written in, newest first.
    private var friendChats: [ChatsFriend] {
        app.chats.recent.map { conversation in
            let id = conversation.directCharacterID ?? ""
            let known = app.library.character(id)
            return ChatsFriend(conversation: conversation,
                               character: known ?? Self.someoneWhoLeft(id),
                               isInLibrary: known != nil,
                               preview: HomeText.preview(of: conversation))
        }
    }

    /// Group scenes that have at least one line in them, newest first.
    private var sceneChats: [ChatsScene] {
        app.chats.conversations
            .filter { !$0.archived && $0.sceneLocationID != nil && $0.messages.contains { $0.role != .narrator } }
            .map { conversation in
                let location = conversation.sceneLocationID.flatMap { app.library.location($0) }
                return ChatsScene(conversation: conversation,
                                  title: location?.name ?? conversation.title ?? "Town scene",
                                  art: location.map { HomeText.locationArt($0) } ?? AvatarRef(symbol: "map.fill"),
                                  cast: cast(of: conversation),
                                  preview: HomeText.preview(of: conversation) { app.library.character($0)?.name })
            }
    }

    /// Who spoke in a scene, in the order they first spoke (or who was there, if nobody has yet).
    private func cast(of conversation: Conversation) -> [String] {
        var ids: [String] = []
        for message in conversation.messages where message.role == .character {
            if let id = message.speakerID, !ids.contains(id) { ids.append(id) }
        }
        if ids.isEmpty { ids = conversation.participantIDs }
        return ids.compactMap { app.library.character($0)?.name }
    }

    private func matches(_ fields: [String]) -> Bool {
        let needle = HomeText.fold(query)
        guard !needle.isEmpty else { return true }
        return fields.contains { HomeText.fold($0).contains(needle) }
    }

    /// Shown for a chat whose character is no longer on this iPhone.
    private static func someoneWhoLeft(_ id: String) -> Character {
        Character(id: id, name: "Someone who left town", tagline: "", bio: "", greeting: "", personality: "",
                  speakingStyle: "", avatar: AvatarRef(symbol: "person.fill", colors: ["#3A322C", "#8A7F74"]),
                  accentHex: "#8A7F74")
    }

    // MARK: - Deleting

    private var deleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let conversation = pendingDelete else { return "Delete this chat?" }
        if let id = conversation.directCharacterID, let character = app.library.character(id) {
            return "Delete your chat with \(character.name)?"
        }
        if let id = conversation.sceneLocationID, let location = app.library.location(id) {
            return "Delete the scene \(HomeText.atPlace(location, startsSentence: false))?"
        }
        return "Delete this chat?"
    }

    /// Deletes the chat and its media (AppModel.deleteConversation).
    private func delete(_ conversation: Conversation) {
        withAnimation(.smooth) {
            app.deleteConversation(conversation.id)
        }
        deletions += 1
        toast = conversation.sceneLocationID == nil ? "Chat deleted" : "Scene deleted"
    }
}

// MARK: - Rows

private struct ChatsFriend: Identifiable {
    let conversation: Conversation
    let character: Character
    let isInLibrary: Bool
    let preview: String
    var id: UUID { conversation.id }
    var searchFields: [String] { [character.name, preview, conversation.messages.last?.text ?? ""] }
}

private struct ChatsScene: Identifiable {
    let conversation: Conversation
    let title: String
    let art: AvatarRef
    let cast: [String]
    let preview: String
    var id: UUID { conversation.id }
    var searchFields: [String] { [title, preview, conversation.messages.last?.text ?? ""] + cast }

    /// "With Juno, Felix and Wren" (long casts end with "and 2 others").
    var who: String {
        guard !cast.isEmpty else { return "Nobody has spoken yet" }
        if cast.count <= 3 { return "With " + HomeText.names(cast) }
        let others = cast.count - 2
        return "With \(cast[0]), \(cast[1]) and \(others) others"
    }
}

/// Like CharacterRowView, with the place's art and who was there.
private struct ChatsSceneRowView: View {
    let scene: ChatsScene
    let time: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(scene.art, size: 52, shape: .rounded)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(scene.title)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                        .lineLimit(1)
                    Spacer(minLength: Spacing.s)
                    Text(time)
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthMuted)
                        .lineLimit(1)
                }
                Text(scene.who)
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthSea)
                    .lineLimit(1)
                if !scene.preview.isEmpty {
                    Text(scene.preview)
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.s)
        .contentShape(Rectangle())
    }
}

/// Clear rows on the warm background, with separators in the palette's line color.
private struct ChatsRowStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Color.hearthLine)
            .listRowInsets(EdgeInsets(top: 2, leading: Spacing.l, bottom: 2, trailing: Spacing.l))
    }
}
