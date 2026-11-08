// A character's page, Character.AI style: big art, Chat / Call / New chat, where they are right now,
// their story and people, past chats, what they remember, and edit, share or delete for your own.

import SwiftUI

struct CharacterProfileView: View {
    let characterID: String

    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// Keeps the page drawn while it slides away after a delete.
    @State private var departing: Character?
    @State private var titleVisible = false
    @State private var toast: String?

    init(characterID: String) {
        self.characterID = characterID
    }

    private var character: Character? {
        app.library.character(characterID) ?? departing
    }

    var body: some View {
        Group {
            if let character {
                TimelineView(.everyMinute) { context in
                    page(character, now: context.date)
                }
                .background(alignment: .top) { accentWash(character) }
            } else {
                missing
            }
        }
        .hearthScreenBackground()
        .navigationTitle(titleVisible ? (character?.name ?? "") : "")
        .navigationBarTitleDisplayMode(.inline)
        .hearthToast($toast)
        .onDisappear { HomeCharacterCardFile.cleanUp() }
    }

    // MARK: - Page

    private func page(_ c: Character, now: Date) -> some View {
        let director = app.director
        let location = director.location(of: c, at: now)
        let chats = app.chats.directChats(with: c.id).filter { $0.messages.contains { $0.role == .user } }
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                HomeProfileHeader(character: c)
                HomeProfileActions(name: c.name,
                                   chat: { router.open(.startChat(characterID: c.id)) },
                                   call: { call(c) },
                                   newChat: { router.open(.newChat(characterID: c.id)) })
                if let location {
                    HomeProfileRightNow(name: c.name,
                                        location: location,
                                        activity: director.activity(of: c, at: now),
                                        part: director.part(at: now),
                                        day: day(of: c)) {
                        router.open(.scene(locationID: location.id))
                    }
                }
                HomeProfileAbout(character: c) { router.open(.search(query: $0)) }
                let people = self.people(of: c)
                if !people.isEmpty {
                    HomeProfilePeople(ownerName: c.name, people: people) { router.open(.profile(characterID: $0)) }
                }
                HomeProfilePastChats(chats: chats, now: now,
                                     open: { router.open(.chat(conversationID: $0)) },
                                     newChat: { router.open(.newChat(characterID: c.id)) })
                HomeProfileMemoryRow(name: c.name,
                                     count: app.memory.facts(for: c.id, includeShareable: app.settings.townGossip).count) {
                    router.open(.memories(characterID: c.id))
                }
                if !c.isBuiltIn {
                    HomeProfileOwnerTools(character: c,
                                          edit: { router.open(.create(editingID: c.id)) },
                                          delete: { delete(c) })
                }
                Text("\(c.name) is an AI character. What they say is made up.")
                    .font(HearthFont.small)
                    .foregroundStyle(.hearthMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xxl)
        }
        // The name moves into the bar once the big one has scrolled away.
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 250
        } action: { _, past in
            withAnimation(.smooth(duration: 0.2)) { titleVisible = past }
        }
    }

    /// A soft wash of the character's color behind the top of the page.
    private func accentWash(_ c: Character) -> some View {
        LinearGradient(colors: [Color(hex: c.accentHex).opacity(0.24), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: 440)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private var missing: some View {
        EmptyStateView(symbol: "person.crop.circle.badge.questionmark",
                       title: "Nobody here",
                       message: "This character isn't on this iPhone anymore.",
                       actionTitle: "Go back") {
            dismiss()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func people(of c: Character) -> [HomeProfilePerson] {
        c.relationships.compactMap { relationship in
            app.library.character(relationship.characterID).map { HomeProfilePerson(relationship: relationship, character: $0) }
        }
    }

    /// Morning to night from their schedule (residents only; characters the user made live outside town).
    private func day(of c: Character) -> [HomeProfileDaySlot] {
        guard !c.schedule.isEmpty else { return [] }
        return DayPart.allCases.compactMap { part in
            guard let slot = c.slot(for: part) else { return nil }
            return HomeProfileDaySlot(part: part, place: app.library.location(slot.locationID), activity: slot.activity)
        }
    }

    // MARK: - Actions

    /// Calls pick up the latest chat (or start one) so the call and the chat share one conversation.
    private func call(_ c: Character) {
        let conversation = app.chats.latestDirect(with: c.id) ?? app.chats.startDirect(with: c, persona: app.settings.persona)
        router.startCall(conversationID: conversation.id)
    }

    private func delete(_ c: Character) {
        departing = c
        do {
            try app.deleteCharacter(c.id)
            dismiss()
        } catch {
            departing = nil
            toast = error.localizedDescription
        }
    }
}
