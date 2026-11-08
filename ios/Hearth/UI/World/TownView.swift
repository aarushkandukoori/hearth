// The Town tab: Lantern Bay at a glance. A cinematic header, the illustrated map with who is where (and a
// peek at other times of day), town news, places to visit and everyone who lives here.

import SwiftUI

struct TownView: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var news = WorldEventsController()
    /// The part of the day being peeked at; nil follows the clock.
    @State private var peek: DayPart?
    /// News that was unseen when it appeared on screen (keeps its dot for this visit).
    @State private var freshIDs: Set<UUID> = []
    @State private var isVisible = false

    var body: some View {
        ZStack(alignment: .top) {
            TimelineView(.everyMinute) { timeline in
                if app.library.world.locations.isEmpty {
                    emptyTown
                } else {
                    content(now: timeline.date)
                }
            }
            .ignoresSafeArea(edges: .top)
            statusBarFade
        }
        .hearthScreenBackground()
        .navigationTitle("Town")
        .toolbar(.hidden, for: .navigationBar)
        .toolbarVisibility(.visible, for: .tabBar) // comes back after a scene hid it (see HomeView)
        .onAppear {
            isVisible = true
            peek = nil
            freshIDs = []
            catchUpOnNews()
            news.refreshIfDue(app: app)
        }
        .onDisappear { isVisible = false }
        .onChange(of: app.events.unseenCount) { _, _ in
            if isVisible { catchUpOnNews() }
        }
        .onChange(of: engineIsFree) { _, free in
            if free && isVisible { news.refreshIfDue(app: app) }
        }
        .sensoryFeedback(trigger: peek) { _, _ in app.settings.haptics ? .selection : nil }
    }

    private var engineIsFree: Bool {
        app.engine.state == .ready && !app.engine.isGenerating
    }

    /// Remembers which happenings are new, then marks them seen (they were just shown).
    private func catchUpOnNews() {
        let unseen = app.events.events.filter { !$0.seen }.map(\.id)
        guard !unseen.isEmpty else { return }
        freshIDs.formUnion(unseen)
        app.events.markAllSeen()
    }

    // MARK: Layout

    private func content(now: Date) -> some View {
        let nowPart = DayPart.at(now)
        let shown = peek ?? nowPart
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                TownHeader(world: app.library.world, now: now)
                mapSection(now: now, nowPart: nowPart, shown: shown)
                TownNewsCard(events: app.events.events, freshIDs: freshIDs, isRefreshing: news.isRefreshing,
                             onOpenPlace: { router.open(.scene(locationID: $0)) },
                             onOpenProfile: { router.open(.profile(characterID: $0)) })
                    .padding(.horizontal, Spacing.l)
                placesSection(now: now)
                residentsSection(now: now)
            }
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.hidden)
    }

    /// Keeps the status bar readable over the art and over scrolled content. A thin strip at the top of the
    /// safe area whose background reaches up under the status bar.
    private var statusBarFade: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Spacing.xl)
            .background(alignment: .bottom) {
                LinearGradient(stops: [
                    .init(color: Color.hearthBackground.opacity(0.96), location: 0),
                    .init(color: Color.hearthBackground.opacity(0.92), location: 0.72),
                    .init(color: Color.hearthBackground.opacity(0), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var emptyTown: some View {
        EmptyStateView(symbol: "map", title: "The town is still waking up",
                       message: "Lantern Bay's map couldn't be loaded. Try closing and opening Hearth again.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Map

    private func mapSection(now: Date, nowPart: DayPart, shown: DayPart) -> some View {
        let world = app.library.world
        let moment = TownText.sampleDate(for: shown, near: now)
        let director = app.director
        let byPlace = Dictionary(world.locations.map { ($0.id, director.residents(at: $0.id, on: moment)) },
                                 uniquingKeysWith: { first, _ in first })
        return VStack(alignment: .leading, spacing: Spacing.m) {
            peekControl(nowPart: nowPart)
            TownMapView(world: world, part: shown, residentsByPlace: byPlace, isNow: shown == nowPart) { location in
                router.open(.scene(locationID: location.id))
            }
            mapHint(nowPart: nowPart, shown: shown)
        }
        .padding(.horizontal, Spacing.l)
    }

    private func peekControl(nowPart: DayPart) -> some View {
        let selection = Binding<DayPart>(
            get: { peek ?? nowPart },
            set: { part in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.7)) {
                    peek = part == nowPart ? nil : part
                }
            }
        )
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Peek at another time")
                .font(HearthFont.caption.weight(.semibold))
                .foregroundStyle(.hearthText2)
            if typeSize.isAccessibilitySize {
                Picker("Peek at another time", selection: selection) { partOptions }
                    .pickerStyle(.menu)
            } else {
                Picker("Peek at another time", selection: selection) { partOptions }
                    .pickerStyle(.segmented)
            }
        }
    }

    private var partOptions: some View {
        ForEach(DayPart.allCases, id: \.self) { part in
            Text(TownText.label(part)).tag(part)
        }
    }

    private func mapHint(nowPart: DayPart, shown: DayPart) -> some View {
        let peeking = shown != nowPart
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.s))
        return layout {
            Label(peeking
                  ? "This is where everyone will be in the \(TownText.label(shown).lowercased()). Places still open with whoever is there now."
                  : "Tap a place to step inside. Whoever is there talks with you, and with each other.",
                  systemImage: peeking ? "eye" : "hand.tap")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthText2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if peeking {
                PillButton("Back to now", symbol: "clock.arrow.circlepath", kind: .secondary) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.7)) { peek = nil }
                }
            }
        }
    }

    // MARK: Places

    private func placesSection(now: Date) -> some View {
        let director = app.director
        return VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader("Places")
                Text("Who is where this \(TownText.label(DayPart.at(now)).lowercased())")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
            ForEach(app.library.world.locations) { location in
                Button {
                    router.open(.scene(locationID: location.id))
                } label: {
                    TownPlaceRow(location: location, people: director.residents(at: location.id, on: now))
                }
                .buttonStyle(.pressable)
                .accessibilityHint("Opens the conversation there")
            }
        }
        .padding(.horizontal, Spacing.l)
    }

    // MARK: Residents

    private func residentsSection(now: Date) -> some View {
        let director = app.director
        // The built-in cast, plus anyone the person made who has a home in town.
        let residents = app.library.allCharacters.filter { $0.isBuiltIn || $0.homeLocationID != nil }
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)]
        return VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader("Residents")
                Text("Everyone who lives in \(app.library.world.name), and where to find them")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
            LazyVGrid(columns: columns, spacing: Spacing.m) {
                ForEach(residents) { character in
                    Button {
                        router.open(.profile(characterID: character.id))
                    } label: {
                        CharacterCardView(character: character,
                                          subtitle: character.species.map(TownText.capitalizedFirst),
                                          badge: director.location(of: character, at: now).map { TownText.at($0.name) })
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("Opens \(character.name)'s profile")
                }
            }
        }
        .padding(.horizontal, Spacing.l)
    }
}

/// The big picture at the top: the town art for this time of day, its name, and the time.
private struct TownHeader: View {
    let world: WorldDefinition
    let now: Date

    var body: some View {
        let part = DayPart.at(now)
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(TownText.nowLine(now), systemImage: TownText.symbol(part))
                .font(HearthFont.callout.weight(.semibold))
                .foregroundStyle(.hearthText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: Capsule())
            Text(world.name)
                .font(HearthFont.title(40))
                .foregroundStyle(.hearthText)
                .accessibilityAddTraits(.isHeader)
            Text(world.tagline)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)
            PrivacyBadge("Lives on this iPhone")
                .padding(.top, Spacing.xs)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, 210)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) { TownHeroArt(part: part) }
    }
}

/// The hero picture with a time-of-day tint, fading into the page.
private struct TownHeroArt: View {
    let part: DayPart

    var body: some View {
        Color.clear
            .frame(height: 360)
            .overlay {
                HearthCachedImage(source: .bundled(TownText.heroAsset(part)), maxPixel: 1024) { phase in
                    if case .loaded(let image) = phase {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(colors: [Color(hex: "#2C4A74"), Color(hex: "#F6C177").opacity(0.6)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
            }
            .overlay { tint }
            .overlay {
                LinearGradient(stops: [
                    .init(color: Color.hearthBackground.opacity(0), location: 0.35),
                    .init(color: Color.hearthBackground.opacity(0.75), location: 0.68),
                    .init(color: Color.hearthBackground, location: 0.96),
                ], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
            .accessibilityHidden(true)
    }

    @ViewBuilder private var tint: some View {
        switch part {
        case .morning:
            LinearGradient(colors: [Color(hex: "#FFD6A0").opacity(0.4), .clear], startPoint: .topLeading, endPoint: .center)
        case .afternoon:
            LinearGradient(colors: [Color(hex: "#BFE3F0").opacity(0.25), .clear], startPoint: .top, endPoint: .center)
        case .evening:
            LinearGradient(colors: [Color(hex: "#FF9650").opacity(0.22), Color(hex: "#8C466E").opacity(0.2)],
                           startPoint: .top, endPoint: .bottom)
        case .night:
            LinearGradient(colors: [Color(hex: "#1E285A").opacity(0.35), Color(hex: "#05081A").opacity(0.2)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}

/// A place in the list: its picture, name, mood, and who is there now.
private struct TownPlaceRow: View {
    let location: Location
    let people: [Character]
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.m))
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        layout {
            AvatarView(location.art, size: 76, shape: .rounded)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(location.name)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(location.ambience)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    .multilineTextAlignment(.leading)
                whoIsHere
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.hearthMuted)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(Spacing.m)
        .background(Color.hearthSurface, in: shape)
        .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
        .contentShape(shape)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var whoIsHere: some View {
        if people.isEmpty {
            Label("Quiet right now", systemImage: "moon.zzz")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthMuted)
        } else {
            HStack(spacing: Spacing.s) {
                HStack(spacing: -8) {
                    ForEach(people.prefix(4)) { person in
                        AvatarView(person.avatar, size: 26)
                            .background(Circle().fill(Color.hearthSurface).padding(-1.5))
                    }
                }
                .accessibilityHidden(true)
                Text("Here now: \(TownText.names(people))")
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthText2)
                    .lineLimit(2)
            }
        }
    }
}

#Preview("Town") {
    let app = AppModel()
    NavigationStack { TownView() }
        .environment(app)
        .environment(app.router)
}
