// Town happenings for the "While you were away" feed (WorldEvent in Core), kept in state/events.json.
// Newest first, at most 200 (the oldest fall off).

import Foundation
import Observation

@MainActor @Observable final class WorldEventStore: PersistentStore {
    static let maxEvents = 200

    /// Newest first.
    private(set) var events: [WorldEvent] = []

    let storageDirectory: URL
    private let debouncer = StoreDebouncer()
    @ObservationIgnored private var isDirty = false
    /// events.json exists but couldn't be opened (iPhone locked): never overwrite it with less.
    @ObservationIgnored private var needsReload = false

    private var fileURL: URL { storageDirectory.appendingPathComponent("events.json") }

    init(directory: URL = HearthPaths.state) {
        storageDirectory = directory
        let loaded = Self.load(directory.appendingPathComponent("events.json"))
        events = loaded.events
        needsReload = loaded.unreadable
        StoreRegistry.register(self)
    }

    var unseenCount: Int {
        events.reduce(0) { count, event in event.seen ? count : count + 1 }
    }

    /// Adds happenings. Ids already stored and text the feed already shows are skipped, so the same
    /// starter news is never listed twice.
    func add(_ newEvents: [WorldEvent]) {
        var list = events
        for event in newEvents {
            let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let duplicate = list.contains { $0.id == event.id || $0.text.caseInsensitiveCompare(text) == .orderedSame }
            guard !duplicate else { continue }
            var cleaned = event
            cleaned.text = text
            list.append(cleaned)
        }
        list = Self.newestFirst(list)
        guard list != events else { return }
        events = list
        changed()
    }

    func markAllSeen() {
        guard events.contains(where: { !$0.seen }) else { return }
        events = events.map { event in
            var event = event
            event.seen = true
            return event
        }
        changed()
    }

    func recent(limit: Int) -> [WorldEvent] {
        Array(events.prefix(max(0, limit)))
    }

    // MARK: PersistentStore

    func flush() {
        debouncer.cancel()
        reloadIfNeeded()
        guard isDirty, !needsReload else { return }
        do {
            try HearthPaths.write(StoreJSON.encode(events), to: fileURL)
            isDirty = false
        } catch {
            HearthLog.error("events", "save failed (\(StoreFiles.describe(error))), will retry")
        }
    }

    func reloadIfNeeded() {
        guard needsReload else { return }
        let loaded = Self.load(fileURL)
        guard !loaded.unreadable else { return }
        needsReload = false
        let onDisk = Set(loaded.events.map(\.id))
        let merged = Self.newestFirst(loaded.events + events.filter { !onDisk.contains($0.id) })
        isDirty = merged != loaded.events
        events = merged
        HearthLog.info("events", "town news read after unlock")
    }

    func forgetEverything() {
        debouncer.cancel()
        events = []
        isDirty = false
        needsReload = false
    }

    // MARK: Private

    private func changed() {
        isDirty = true
        debouncer.schedule { [weak self] in self?.flush() }
    }

    private static func newestFirst(_ list: [WorldEvent]) -> [WorldEvent] {
        let sorted = list.sorted { a, b in
            a.date != b.date ? a.date > b.date : a.id.uuidString < b.id.uuidString
        }
        return Array(sorted.prefix(maxEvents))
    }

    private static func load(_ url: URL) -> (events: [WorldEvent], unreadable: Bool) {
        switch StoreFiles.read(url) {
        case .missing:
            return ([], false)
        case .unreadable:
            HearthLog.error("events", "town news file can't be opened yet (locked)")
            return ([], true)
        case .data(let data):
            var skipped = 0
            let template = StoreJSON.object(WorldEvent(text: ""), removing: ["id", "text"])
            guard let events = try? StoreJSON.decodeArray(WorldEvent.self, from: data, template: template, skipped: &skipped) else {
                HearthLog.error("events", "town news file unreadable, starting fresh")
                return ([], false)
            }
            if skipped > 0 { HearthLog.error("events", "skipped \(skipped) unreadable happenings") }
            return (newestFirst(events), false)
        }
    }
}
