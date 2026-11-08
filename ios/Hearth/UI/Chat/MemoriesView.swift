// What a character remembers about the user: their own memories, things everyone knows, and (with town
// gossip on) what other residents learned. Swipe to forget (it leaves every prompt from then on), or add
// something by hand. All on this iPhone.

import SwiftUI

struct MemoriesView: View {
    let characterID: String
    @Environment(AppModel.self) private var app
    @State private var newFact = ""
    @State private var confirmsForgetAll = false
    @FocusState private var adding: Bool

    var body: some View {
        if let character = app.library.character(characterID) {
            list(character)
        } else {
            EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "This character isn't here",
                           message: "Their memories went with them.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .hearthScreenBackground()
        }
    }

    private func list(_ character: Character) -> some View {
        let gossip = app.settings.townGossip
        let facts = app.memory.facts(for: characterID, includeShareable: gossip).reversed()
        let own = facts.filter { $0.characterID == characterID || $0.characterID == nil }
        let shared = facts.filter { $0.characterID != characterID && $0.characterID != nil }
        return List {
            Section {
                HStack(alignment: .top, spacing: Spacing.m) {
                    AvatarView(character.avatar, size: 44)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("\(character.name) uses these to remember you between chats. They stay on this iPhone and are never sent anywhere.")
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthText2)
                            .fixedSize(horizontal: false, vertical: true)
                        PrivacyBadge()
                    }
                }
                .padding(.vertical, Spacing.xs)
                .listRowBackground(Color.clear)
            }

            Section {
                HStack(spacing: Spacing.s) {
                    TextField("Something \(character.name) should know", text: $newFact, axis: .vertical)
                        .font(HearthFont.body)
                        .lineLimit(1...3)
                        .focused($adding)
                        .submitLabel(.done)
                    Button("Add") { add(for: character) }
                        .font(HearthFont.callout.weight(.semibold))
                        .disabled(newFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .frame(minHeight: 44)
                }
                .listRowBackground(Color.hearthSurface)
            } header: {
                Text("Add a memory")
            } footer: {
                Text("For example: \"My dog is called Biscuit\" or \"I'm learning the piano\".")
            }

            Section {
                if own.isEmpty {
                    Text("Nothing yet. As you chat, \(character.name) will remember small things you share, and you can long-press any message and choose Remember this.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .listRowBackground(Color.hearthSurface)
                }
                ForEach(own) { fact in
                    ChatMemoryRow(fact: fact, detail: Self.source(fact))
                        .listRowBackground(Color.hearthSurface)
                        .swipeActions {
                            Button("Forget", systemImage: "trash", role: .destructive) { forget(fact) }
                        }
                }
            } header: {
                Text("What \(character.name) remembers")
            }

            if !shared.isEmpty {
                Section {
                    ForEach(shared) { fact in
                        ChatMemoryRow(fact: fact, detail: "Town knows, from \(name(of: fact.characterID))")
                            .listRowBackground(Color.hearthSurface)
                            .swipeActions {
                                Button("Forget", systemImage: "trash", role: .destructive) { forget(fact) }
                            }
                    }
                } header: {
                    Text("Town knows")
                } footer: {
                    Text("Town gossip is on, so things you told other residents can come up here too. Forgetting one here forgets it everywhere. You can turn gossip off in You > Privacy.")
                }
            }

            if !own.isEmpty {
                Section {
                    Button("Forget everything \(character.name) remembers", role: .destructive) { confirmsForgetAll = true }
                        .frame(minHeight: 44)
                        .listRowBackground(Color.hearthSurface)
                }
            }
        }
        .hearthScreenBackground()
        .navigationTitle("Memories")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth(duration: 0.25), value: app.memory.facts)
        .confirmationDialog("Forget everything \(character.name) remembers?", isPresented: $confirmsForgetAll,
                            titleVisibility: .visible) {
            Button("Forget all", role: .destructive) {
                let gone = app.memory.facts.filter { $0.characterID == characterID }
                withAnimation(.smooth) { app.memory.removeAll(for: characterID) }
                forgetSavedChats(knowing: gone)
            }
        } message: {
            Text("Your chats stay. \(character.name) will start learning about you again as you talk.")
        }
        .sensoryFeedback(.success, trigger: app.memory.facts.count) { old, new in new > old && app.settings.haptics }
    }

    private func add(for character: Character) {
        let text = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let existing = app.memory.facts(for: character.id, includeShareable: false)
        let merged = MemoryKeeper.merge([text], into: existing, characterID: character.id, source: .pinned,
                                        shareable: app.settings.townGossip)
        let known = Set(existing.map(\.id))
        withAnimation(.smooth) {
            app.memory.add(merged.filter { !known.contains($0.id) })
        }
        newFact = ""
        adding = false
    }

    private func forget(_ fact: MemoryFact) {
        withAnimation(.smooth) { app.memory.remove(fact.id) }
        forgetSavedChats(knowing: [fact])
    }

    /// A forgotten memory leaves every prompt from now on. Pie reuses KV only while a prompt starts the same
    /// way, so in the chats whose prompts had it, everything from that point on is read afresh next time, and
    /// the old KV that held it (in memory only) is never used again. The engine is told to forget them too.
    private func forgetSavedChats(knowing facts: [MemoryFact]) {
        guard !facts.isEmpty else { return }
        // Known to everyone, or shareable (gossip may have put it in other residents' prompts).
        let everyone = facts.contains { $0.characterID == nil || $0.shareable }
        let owners = Set(facts.compactMap(\.characterID))
        let keys = app.chats.conversations.compactMap { conversation -> String? in
            guard let id = conversation.directCharacterID, everyone || owners.contains(id) else { return nil }
            return conversation.engineKey
        }
        let engine = app.engine
        Task {
            for key in keys { await engine.forget(conversationKey: key) }
        }
    }

    private func name(of characterID: String?) -> String {
        characterID.flatMap { app.library.character($0)?.name } ?? "a neighbor"
    }

    private static func source(_ fact: MemoryFact) -> String {
        if fact.characterID == nil { return "Everyone knows" }
        switch fact.source {
        case .pinned: return "You asked to remember this"
        case .auto: return "Picked up in chat"
        case .summary: return "From a chat summary"
        }
    }
}

private struct ChatMemoryRow: View {
    let fact: MemoryFact
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ChatMarkup.attributed(fact.text, actionColor: .hearthText2))
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.xs) {
                Image(systemName: fact.source == .pinned ? "pin.fill" : "sparkles")
                    .imageScale(.small)
                Text(detail)
                Text("·")
                Text(fact.createdAt.formatted(date: .abbreviated, time: .omitted))
            }
            .font(HearthFont.small)
            .foregroundStyle(.hearthMuted)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
