// Search (pushed from Home or a profile tag): live results while typing, this session's recent searches
// (kept in memory only, never saved to disk), and interests to browse when the field is empty.

import SwiftUI

struct SearchResultsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var query: String
    @FocusState private var fieldFocused: Bool
    private let initialQuery: String

    init(query: String) {
        initialQuery = query
        _query = State(initialValue: query)
    }

    private var recents: HomeRecentSearches { .shared }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            if trimmed.isEmpty {
                suggestions
            } else {
                results(HomeSearch.characters(matching: trimmed, in: app.library))
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .hearthScreenBackground()
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Names, places or interests")
        .searchFocused($fieldFocused)
        .onSubmit(of: .search) { recents.add(query) }
        .onChange(of: initialQuery) { _, newValue in query = newValue } // the route was replaced in place
        .task {
            // An empty search opens with the keyboard up, once the push has finished.
            guard trimmed.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            fieldFocused = true
        }
    }

    // MARK: - Empty field

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("Try a name like \(app.library.world.characters.first?.name ?? "Juno"), a place like the harbor, or something you love, like books or stars.")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)

            if !recents.terms.isEmpty {
                recentSearches
            }

            let categories = app.library.world.categories.filter { !app.library.characters(inCategory: $0.id).isEmpty }
            if !categories.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("Browse by interest")
                    let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.m),
                                        count: typeSize.isAccessibilitySize ? 1 : 2)
                    LazyVGrid(columns: columns, spacing: Spacing.m) {
                        ForEach(categories) { category in
                            Button { search(category.title) } label: {
                                HomeInterestTile(category: category,
                                                 count: app.library.characters(inCategory: category.id).count)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.l)
    }

    private var recentSearches: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Recent", actionTitle: "Clear") {
                withAnimation(.smooth) { recents.clear() }
            }
            VStack(spacing: 0) {
                ForEach(recents.terms, id: \.self) { term in
                    Button { search(term) } label: {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.hearthMuted)
                                .accessibilityHidden(true)
                            Text(term)
                                .font(HearthFont.body)
                                .foregroundStyle(.hearthText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.left")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.hearthMuted)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                    .accessibilityLabel("Search again for \(term)")
                    if term != recents.terms.last {
                        Divider().overlay(Color.hearthLine)
                    }
                }
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func results(_ found: [Character]) -> some View {
        if found.isEmpty {
            EmptyStateView(symbol: "magnifyingglass",
                           title: "Nobody by that name yet",
                           message: "Try another word, like tea, stars or music. Or make a character of your own.",
                           actionTitle: "Create a character") {
                router.open(.create(editingID: nil))
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text(found.count == 1 ? "1 character" : "\(found.count) characters")
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthMuted)
                    .padding(.bottom, Spacing.xs)
                ForEach(found) { character in
                    Button { open(character) } label: {
                        CharacterRowView(character: character, detail: nil, trailing: nil)
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("Opens their profile")
                    if character.id != found.last?.id {
                        Divider().overlay(Color.hearthLine).padding(.leading, 52 + Spacing.m)
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
        }
    }

    // MARK: - Actions

    private func search(_ term: String) {
        query = term
        recents.add(term)
        fieldFocused = false
    }

    private func open(_ character: Character) {
        recents.add(query)
        router.open(.profile(characterID: character.id))
    }
}

// MARK: - Matching

enum HomeSearch {
    /// Library's ranked search (names first), then everyone in a matching interest ("comfort"),
    /// then residents who spend time at a matching place ("harbor"). No duplicates.
    @MainActor
    static func characters(matching query: String, in library: Library) -> [Character] {
        var found = library.search(query)
        let needle = HomeText.fold(query.hasPrefix("#") ? String(query.dropFirst()) : query)
        guard !needle.isEmpty else { return found }
        func add(_ more: [Character]) {
            for c in more where !found.contains(where: { $0.id == c.id }) { found.append(c) }
        }
        for category in library.world.categories where HomeText.fold(category.title).hasPrefix(needle) {
            add(library.characters(inCategory: category.id))
        }
        let places = Set(library.world.locations.filter { HomeText.fold($0.name).contains(needle) }.map(\.id))
        if !places.isEmpty {
            add(library.world.characters.filter { c in
                c.schedule.contains { places.contains($0.locationID) } || c.homeLocationID.map { places.contains($0) } == true
            })
        }
        return found
    }
}

/// Searches typed in this session, newest first. In memory only: gone when the app quits.
@MainActor @Observable final class HomeRecentSearches {
    static let shared = HomeRecentSearches()
    private(set) var terms: [String] = []

    func add(_ text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        var list = terms.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        terms = Array(list.prefix(6))
    }

    func clear() {
        terms = []
    }
}

/// A category to browse: its symbol, title and how many characters share it.
private struct HomeInterestTile: View {
    let category: CategoryDef
    let count: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        HStack(spacing: Spacing.m) {
            Image(systemName: category.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.hearthGold)
                .frame(width: 40, height: 40)
                .background(Color.hearthGold.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(count == 1 ? "1 character" : "\(count) characters")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.hearthSurface, in: shape)
        .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Searches for \(category.title.lowercased())")
    }
}
