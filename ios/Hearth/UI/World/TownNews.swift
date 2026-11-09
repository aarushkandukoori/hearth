// "While you were away": WorldEventsController writes a small batch of town happenings (at most every
// 6 hours, on this iPhone) and TownNewsCard shows the newest ones with who was involved.

import SwiftUI

@MainActor @Observable final class WorldEventsController {
    /// A new batch at most this often (SPEC §7 away events).
    nonisolated static let batchInterval: TimeInterval = 6 * 60 * 60
    nonisolated static let batchSize = 3

    /// True while a batch is being written (the card shows "Catching up on town news").
    private(set) var isRefreshing = false

    /// What to do when a batch is due.
    enum Plan: Equatable {
        /// The engine is loading or busy: try again when it is free.
        case wait
        /// Ask the model on this iPhone to write the newsletter.
        case askModel
        /// No model to ask (demo replies, or none installed): use the town's own starter notes.
        case useStarters
    }

    // MARK: Pure decisions (unit-tested)

    /// Due when there was never a batch, the last one is 6+ hours old, or the clock moved backwards.
    nonisolated static func isDue(lastBatchAt: Date?, now: Date, interval: TimeInterval = batchInterval) -> Bool {
        guard let last = lastBatchAt else { return true }
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    nonisolated static func plan(engineState: EngineHost.State, isGenerating: Bool, engineID: String?) -> Plan {
        switch engineState {
        case .ready:
            if engineID == "mock" { return .useStarters }
            return isGenerating ? .wait : .askModel
        case .needsModel, .failed:
            return .useStarters
        case .idle, .loading:
            return .wait
        }
    }

    /// Starter notes the feed doesn't show yet, in the world's order (case and spacing ignored).
    nonisolated static func unusedStarters(_ starters: [String], existing: [WorldEvent], limit: Int) -> [String] {
        let shown = Set(existing.map { comparable($0.text) })
        var picked: [String] = []
        for line in starters where picked.count < limit {
            let key = comparable(line)
            guard !key.isEmpty, !shown.contains(key), !picked.contains(where: { comparable($0) == key }) else { continue }
            picked.append(line)
        }
        return picked
    }

    /// Starter lines as events, with residents and places detected the same way as model-written news.
    nonisolated static func starterEvents(_ lines: [String], world: WorldDefinition, now: Date) -> [WorldEvent] {
        guard !lines.isEmpty else { return [] }
        return ReplyParser.awayEvents(from: lines.map { "- " + $0 }.joined(separator: "\n"), world: world, now: now)
    }

    nonisolated private static func comparable(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    // MARK: Refreshing

    /// Starts a new batch when one is due and the engine is free. Returns right away; the store updates later.
    func refreshIfDue(app: AppModel, now: Date = .now) {
        // Developer measurements need the engine to themselves.
        guard !LaunchOptions.shared.sweep, !LaunchOptions.shared.benchmark else { return }
        guard !isRefreshing, Self.isDue(lastBatchAt: app.settings.lastAwayEventsAt, now: now) else { return }
        let plan = Self.plan(engineState: app.engine.state, isGenerating: app.engine.isGenerating,
                             engineID: app.engine.active?.id)
        guard plan != .wait else { return }
        isRefreshing = true
        // Its own task: the Town screen's tasks restart when the engine gets busy, and that must not cancel this.
        Task {
            await makeBatch(app: app, plan: plan, now: now)
            isRefreshing = false
        }
    }

    private func makeBatch(app: AppModel, plan: Plan, now: Date) async {
        let world = app.library.world
        var fresh: [WorldEvent] = []
        if plan == .askModel {
            guard let written = await askModel(app: app, world: world, now: now) else {
                HearthLog.info("town", "news batch stopped; will try again later")
                return
            }
            fresh = written
        }
        if fresh.isEmpty {
            let lines = Self.unusedStarters(world.starterEvents, existing: app.events.events, limit: Self.batchSize)
            fresh = Self.starterEvents(lines, world: world, now: now)
        }
        app.events.add(fresh)
        app.settingsStore.update { $0.lastAwayEventsAt = now }
        HearthLog.info("town", "news batch added=\(fresh.count) source=\(plan == .askModel ? "model" : "notebook")")
    }

    /// The newsletter from the model, parsed into events. nil when it was stopped (try again later);
    /// an empty list when it failed (the starter notes fill in).
    private func askModel(app: AppModel, world: WorldDefinition, now: Date) async -> [WorldEvent]? {
        let request = PromptComposer.awayEventsRequest(world: world, count: Self.batchSize, now: now)
        var text = ""
        var stoppedBy = "eos"
        do {
            for try await event in app.engine.generate(request) {
                switch event {
                case .token(let piece): text += piece
                case .done(let stats): stoppedBy = stats.stoppedBy
                }
            }
        } catch {
            HearthLog.error("town", "news batch failed (\(type(of: error)))")
            return []
        }
        if stoppedBy == "cancelled" { return nil }
        return ReplyParser.awayEvents(from: text, world: world, now: now)
    }
}

/// The "While you were away" card on the Town tab.
struct TownNewsCard: View {
    let events: [WorldEvent]
    /// Events that were new when the card appeared (they get a dot).
    let freshIDs: Set<UUID>
    let isRefreshing: Bool
    var onOpenPlace: (String) -> Void
    var onOpenProfile: (String) -> Void

    @Environment(AppModel.self) private var app
    @State private var showAll = false

    private static let collapsedCount = 4
    private static let expandedCount = 20

    var body: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                header
                if isRefreshing { catchingUp }
                if events.isEmpty && !isRefreshing {
                    Text("Quiet in town so far. Check back in a little while.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                }
                ForEach(shown) { event in
                    row(event)
                    if event.id != shown.last?.id {
                        Divider().overlay(Color.hearthLine)
                    }
                }
                if events.count > Self.collapsedCount {
                    Button(showAll ? "Show less" : "Show more") {
                        withAnimation(.snappy) { showAll.toggle() }
                    }
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthAccentText)
                    .frame(minHeight: 44)
                }
            }
        }
    }

    private var shown: [WorldEvent] {
        Array(events.prefix(showAll ? Self.expandedCount : Self.collapsedCount))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: "envelope.open.fill")
                    .foregroundStyle(.hearthAccent)
                    .accessibilityHidden(true)
                Text("While you were away")
                    .font(HearthFont.title(21))
                    .foregroundStyle(.hearthText)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.s)
                if !freshIDs.isEmpty {
                    Text("\(freshIDs.count) new")
                        .font(HearthFont.small.weight(.bold))
                        .foregroundStyle(.hearthOnAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.hearthAccent, in: Capsule())
                }
            }
            Text("Little things that happened around town.")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
        }
    }

    private var catchingUp: some View {
        HStack(spacing: Spacing.m) {
            ProgressView()
                .frame(width: 40, height: 40)
            Text("Catching up on town news…")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(_ event: WorldEvent) -> some View {
        let people = event.characterIDs.compactMap { app.library.character($0) }
        let place = event.locationID.flatMap { app.library.location($0) }
        let isNew = freshIDs.contains(event.id)
        return Button {
            if let place { onOpenPlace(place.id) } else if let first = people.first { onOpenProfile(first.id) }
        } label: {
            TownNewsRow(event: event, people: people, place: place, isNew: isNew)
        }
        .buttonStyle(.pressable)
        .disabled(place == nil && people.isEmpty)
        .contextMenu {
            if let place {
                Button("Visit \(TownText.inSentence(place.name))", systemImage: "door.left.hand.open") { onOpenPlace(place.id) }
            }
            ForEach(people) { person in
                Button("\(person.name)'s profile", systemImage: "person.crop.circle") { onOpenProfile(person.id) }
            }
        }
        .accessibilityHint(hint(place: place, people: people))
    }

    /// What tapping a happening does: visit its place, or else see the first resident's profile.
    private func hint(place: Location?, people: [Character]) -> String {
        if let place { return "Opens \(place.name)" }
        if let first = people.first { return "Opens \(first.name)'s profile" }
        return ""
    }
}

/// One happening: who was involved, what happened, where and when.
private struct TownNewsRow: View {
    let event: WorldEvent
    let people: [Character]
    let place: Location?
    let isNew: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                // Big text: faces and the new dot on top, then the words at full width.
                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(alignment: .top) {
                        faces
                        Spacer(minLength: Spacing.s)
                        newDot
                    }
                    words
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.m) {
                    faces
                    words
                    newDot
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isNew ? "New" : "")
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(event.text)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            meta
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var newDot: some View {
        if isNew {
            Circle()
                .fill(Color.hearthAccent)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityHidden(true)
        }
    }

    /// Where and when. With big text the place gets its own line instead of being cut short.
    private var meta: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            if let place {
                Label(place.name, systemImage: place.symbol)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                if !typeSize.isAccessibilitySize {
                    Text("·").accessibilityHidden(true)
                }
            }
            Text(event.date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
        }
        .font(HearthFont.caption)
        .foregroundStyle(.hearthMuted)
    }

    /// One face, two overlapping faces, or a little lantern glow when nobody is named.
    @ViewBuilder private var faces: some View {
        switch people.count {
        case 0:
            Image(systemName: "sparkles")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.hearthGold)
                .frame(width: 42, height: 42)
                .background(Color.hearthSurface2, in: Circle())
                .accessibilityHidden(true)
        case 1:
            AvatarView(people[0].avatar, size: 42)
        default:
            ZStack(alignment: .topLeading) {
                AvatarView(people[0].avatar, size: 30)
                AvatarView(people[1].avatar, size: 30)
                    .background(Circle().fill(Color.hearthSurface).padding(-2))
                    .offset(x: 13, y: 13)
            }
            .frame(width: 43, height: 43, alignment: .topLeading)
        }
    }
}
