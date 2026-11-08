// What characters remember about the user (MemoryFact in Core), kept in state/memories.json.
// Saved about half a second after a change. Keeps at most 40 facts per character.

import Foundation
import Observation

@MainActor @Observable final class MemoryStore: PersistentStore {
    static let maxPerCharacter = 40

    /// Every fact, oldest first.
    private(set) var facts: [MemoryFact] = []

    let storageDirectory: URL
    private let debouncer = StoreDebouncer()
    @ObservationIgnored private var isDirty = false
    /// memories.json exists but couldn't be opened (iPhone locked): never overwrite it with less.
    @ObservationIgnored private var needsReload = false

    private var fileURL: URL { storageDirectory.appendingPathComponent("memories.json") }

    init(directory: URL = HearthPaths.state) {
        storageDirectory = directory
        let loaded = Self.load(directory.appendingPathComponent("memories.json"))
        facts = loaded.facts
        needsReload = loaded.unreadable
        StoreRegistry.register(self)
    }

    /// What this character knows: its own facts, facts known to everyone (characterID nil), and, with
    /// `includeShareable` (town gossip on), what other residents learned that may be shared. Oldest first.
    func facts(for characterID: String, includeShareable: Bool) -> [MemoryFact] {
        facts.filter { fact in
            fact.characterID == characterID || fact.characterID == nil || (includeShareable && fact.shareable)
        }
    }

    /// Adds facts, skipping blanks, ids already stored, and the same text already known to that
    /// character (ignoring case and punctuation). Over 40 for a character, the oldest automatic ones go
    /// first; facts from pinned messages are kept longest.
    func add(_ newFacts: [MemoryFact]) {
        var list = facts
        for fact in newFacts {
            let text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = Self.comparable(text)
            let known = list.contains { $0.id == fact.id || ($0.characterID == fact.characterID && Self.comparable($0.text) == key) }
            guard !known else { continue }
            var cleaned = fact
            cleaned.text = text
            list.append(cleaned)
        }
        list = Self.capped(list)
        guard list != facts else { return }
        facts = list
        changed()
    }

    func remove(_ id: UUID) {
        guard facts.contains(where: { $0.id == id }) else { return }
        facts.removeAll { $0.id == id }
        changed()
    }

    /// Forgets what one character knows. `nil` forgets every fact (the "forget everything" button).
    func removeAll(for characterID: String?) {
        let kept = characterID.map { id in facts.filter { $0.characterID != id } } ?? []
        guard kept.count != facts.count else { return }
        facts = kept
        changed()
    }

    // MARK: PersistentStore

    func flush() {
        debouncer.cancel()
        reloadIfNeeded()
        guard isDirty, !needsReload else { return }
        do {
            try HearthPaths.write(StoreJSON.encode(facts), to: fileURL)
            isDirty = false
        } catch {
            HearthLog.error("memory", "save failed (\(StoreFiles.describe(error))), will retry")
        }
    }

    func reloadIfNeeded() {
        guard needsReload else { return }
        let loaded = Self.load(fileURL)
        guard !loaded.unreadable else { return }
        needsReload = false
        // What's on disk, plus anything learned while the file couldn't be opened.
        let onDisk = Set(loaded.facts.map(\.id))
        let merged = Self.capped(loaded.facts + facts.filter { !onDisk.contains($0.id) })
        isDirty = merged != loaded.facts
        facts = merged
        HearthLog.info("memory", "memories read after unlock")
    }

    func forgetEverything() {
        debouncer.cancel()
        facts = []
        isDirty = false
        needsReload = false
    }

    // MARK: Private

    private func changed() {
        isDirty = true
        debouncer.schedule { [weak self] in self?.flush() }
    }

    private static func load(_ url: URL) -> (facts: [MemoryFact], unreadable: Bool) {
        switch StoreFiles.read(url) {
        case .missing:
            return ([], false)
        case .unreadable:
            HearthLog.error("memory", "memories file can't be opened yet (locked)")
            return ([], true)
        case .data(let data):
            var skipped = 0
            let template = StoreJSON.object(MemoryFact(text: "", source: .auto), removing: ["id", "text"])
            guard let facts = try? StoreJSON.decodeArray(MemoryFact.self, from: data, template: template, skipped: &skipped) else {
                HearthLog.error("memory", "memories file unreadable, starting fresh")
                return ([], false)
            }
            if skipped > 0 { HearthLog.error("memory", "skipped \(skipped) unreadable memories") }
            return (facts.sorted { $0.createdAt < $1.createdAt }, false)
        }
    }

    /// Lowercased, single spaces, no trailing punctuation: "I love tea." == "i love  tea".
    private static func comparable(_ text: String) -> String {
        let words = text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
    }

    private static func capped(_ list: [MemoryFact]) -> [MemoryFact] {
        var dropped = Set<UUID>()
        for bucket in Dictionary(grouping: list, by: \.characterID).values where bucket.count > maxPerCharacter {
            let forgetFirst = bucket.sorted { a, b in
                let pinnedA = a.source == .pinned ? 1 : 0
                let pinnedB = b.source == .pinned ? 1 : 0
                return pinnedA != pinnedB ? pinnedA < pinnedB : a.createdAt < b.createdAt
            }
            dropped.formUnion(forgetFirst.prefix(bucket.count - maxPerCharacter).map(\.id))
        }
        return dropped.isEmpty ? list : list.filter { !dropped.contains($0.id) }
    }
}
