// The Home tab, like Character.AI's "For you": a greeting, chats to pick back up, featured residents,
// who is out in Lantern Bay right now, everyone by category, and the user's own characters.

import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    /// "all" or a category id.
    @State private var category = HomeView.everyone

    private static let everyone = "all"

    var body: some View {
        TimelineView(.everyMinute) { context in
            page(now: context.date)
        }
        .hearthScreenBackground()
        .navigationTitle("Home")
        // Tab roots always ask for the tab bar, so it comes back after a chat or scene that hid it, even when
        // the app jumped here on its own (a Models button, the end of a call).
        .toolbarVisibility(.visible, for: .tabBar)
        .toolbarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    router.open(.search(query: ""))
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
        }
        .sensoryFeedback(.selection, trigger: category) { _, _ in app.settings.haptics }
    }

    private func page(now: Date) -> some View {
        let world = app.library.world
        let town = HomeTownSnapshot(world: world, director: app.director, now: now)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                HomeGreeting(title: "\(HomeText.greeting(at: now)), \(HomeText.personaName(app.settings.persona))",
                             line: townLine(world: world, town: town, now: now))
                if app.library.allCharacters.isEmpty {
                    emptyTown
                } else {
                    continueOrWelcome(world: world, town: town, now: now)
                    featured(world: world, town: town, now: now)
                    aroundTown(town)
                    explore(world: world, town: town)
                    yourCharacters
                    HomeFooter()
                }
            }
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.xxl)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func continueOrWelcome(world: WorldDefinition, town: HomeTownSnapshot, now: Date) -> some View {
        let items = continueItems
        if items.isEmpty {
            HomeWelcomeCard(worldName: world.name, residentCount: world.characters.count, night: town.part == .night)
                .padding(.horizontal, Spacing.l)
        } else {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader("Continue chatting", actionTitle: "All chats") { router.tab = .chats }
                    .padding(.horizontal, Spacing.l)
                HomeContinueRow(items: items, now: now) { router.open(.chat(conversationID: $0.id)) }
            }
        }
    }

    @ViewBuilder
    private func featured(world: WorldDefinition, town: HomeTownSnapshot, now: Date) -> some View {
        let picks = HomeFeatured.picks(from: world.characters, at: now)
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                SectionHeader("Featured")
                    .padding(.horizontal, Spacing.l)
                HomeFeaturedCarousel(characters: picks,
                                     place: { id in town.sighting(for: id).map { HomeText.atPlace($0.location) } },
                                     open: { router.open(.profile(characterID: $0.id)) },
                                     chat: { router.open(.startChat(characterID: $0.id)) })
            }
        }
    }

    @ViewBuilder
    private func aroundTown(_ town: HomeTownSnapshot) -> some View {
        let around = Array(town.upAndAbout.prefix(8))
        if !around.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    SectionHeader("Around town right now", actionTitle: "Town") { router.tab = .town }
                    if town.part == .night {
                        Text("Most of the town is home for the night. These friends are still up.")
                            .font(HearthFont.callout)
                            .foregroundStyle(.hearthText2)
                    }
                }
                .padding(.horizontal, Spacing.l)
                HomeAroundTownRow(sightings: around) { router.open(.profile(characterID: $0.character.id)) }
            }
        }
    }

    private func explore(world: WorldDefinition, town: HomeTownSnapshot) -> some View {
        let categories = world.categories.filter { !app.library.characters(inCategory: $0.id).isEmpty }
        let active = categories.contains { $0.id == category } ? category : Self.everyone
        let shown = active == Self.everyone ? app.library.allCharacters : app.library.characters(inCategory: active)
        let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.m, alignment: .top),
                            count: typeSize.isAccessibilitySize ? 1 : 2)
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Explore")
                .padding(.horizontal, Spacing.l)
            if !categories.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.s) {
                        CategoryChip("All", selected: active == Self.everyone) { select(Self.everyone) }
                        ForEach(categories) { item in
                            CategoryChip(item.title, symbol: item.symbol, selected: active == item.id) { select(item.id) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, Spacing.l, for: .scrollContent)
            }
            LazyVGrid(columns: columns, spacing: Spacing.m) {
                ForEach(shown) { character in
                    Button {
                        router.open(.profile(characterID: character.id))
                    } label: {
                        CharacterCardView(character: character,
                                          badge: town.sighting(for: character.id).map { HomeText.shortPlaceName($0.location) })
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("Opens their profile")
                }
            }
            .padding(.horizontal, Spacing.l)
        }
    }

    private var yourCharacters: some View {
        let mine = app.library.userCharacters
        return VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader("Your characters")
                .padding(.horizontal, Spacing.l)
            if mine.isEmpty {
                HomeCreatePrompt { router.open(.create(editingID: nil)) }
                    .padding(.horizontal, Spacing.l)
            } else {
                HomeYourCharactersRow(characters: mine,
                                      create: { router.open(.create(editingID: nil)) },
                                      open: { router.open(.profile(characterID: $0.id)) })
            }
        }
    }

    private var emptyTown: some View {
        EmptyStateView(symbol: "light.beacon.max",
                       title: "The town is still waking up",
                       message: "Lantern Bay's residents couldn't be loaded on this iPhone. You can still make a character of your own.",
                       actionTitle: "Create a character") {
            router.open(.create(editingID: nil))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Data

    /// The latest chat with each character the user has written to, newest first.
    private var continueItems: [HomeContinueItem] {
        var seen = Set<String>()
        var items: [HomeContinueItem] = []
        for conversation in app.chats.recent {
            guard let id = conversation.directCharacterID, !seen.contains(id),
                  let character = app.library.character(id) else { continue }
            seen.insert(id)
            items.append(HomeContinueItem(conversation: conversation, character: character))
            if items.count == 12 { break }
        }
        return items
    }

    /// "Lantern Bay · 8:42 PM · 6 friends are out"
    private func townLine(world: WorldDefinition, town: HomeTownSnapshot, now: Date) -> String {
        var parts = [world.name.isEmpty ? "Lantern Bay" : world.name, now.formatted(date: .omitted, time: .shortened)]
        if !town.sightings.isEmpty {
            parts.append(Self.countPhrase(town.upAndAbout.count, night: town.part == .night))
        }
        // A no-break space keeps each dot at the end of a line when large text wraps.
        return parts.joined(separator: "\u{00A0}· ")
    }

    private static func countPhrase(_ count: Int, night: Bool) -> String {
        switch (count, night) {
        case (0, true): return "The town is asleep"
        case (0, false): return "Quiet in town"
        case (1, true): return "1 friend is still up"
        case (1, false): return "1 friend is out"
        case (_, true): return "\(count) friends are still up"
        default: return "\(count) friends are out"
        }
    }

    private func select(_ id: String) {
        withAnimation(.snappy) { category = id }
    }
}
