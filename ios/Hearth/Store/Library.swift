// The cast: the built-in Lantern Bay residents (bundled lantern-bay.json) plus characters the user makes
// or imports. User characters are one JSON file each in characters/; avatars are clean JPEGs in media/avatars/.

import Foundation
import Observation

enum LibraryError: LocalizedError, Equatable {
    case nameRequired
    case builtInIsReadOnly
    case imageUnreadable

    var errorDescription: String? {
        switch self {
        case .nameRequired: return "Your character needs a name first."
        case .builtInIsReadOnly: return "Lantern Bay residents can't be deleted, but you can make your own characters."
        case .imageUnreadable: return "That picture couldn't be opened. Try a different one."
        }
    }
}

@MainActor @Observable final class Library: PersistentStore {
    private(set) var world: WorldDefinition
    /// Characters the user made or imported, newest first.
    private(set) var userCharacters: [Character]

    let storageDirectory: URL
    private let mediaDirectory: URL
    /// Character files that exist but couldn't be opened yet (the iPhone was locked at launch).
    @ObservationIgnored private var unreadableFiles: [URL] = []

    /// `world: nil` reads the bundled lantern-bay.json. If that is missing or broken the town starts
    /// empty (and the problem is logged); the app never crashes over it.
    init(world: WorldDefinition? = nil, directory: URL = HearthPaths.characters, mediaDirectory: URL = HearthPaths.media) {
        var world = world ?? Self.loadBundledWorld()
        for index in world.characters.indices { world.characters[index].isBuiltIn = true }
        self.world = world
        storageDirectory = directory
        self.mediaDirectory = mediaDirectory
        let loaded = Self.loadUserCharacters(from: directory)
        userCharacters = Self.newestFirst(loaded.characters)
        unreadableFiles = loaded.unreadable
        StoreRegistry.register(self)
        // Pictures picked for characters that were never saved. Only when every file could be read,
        // so a locked or unreadable character never loses its avatar.
        if loaded.unreadable.isEmpty && loaded.skipped == 0 { removeUnusedAvatars() }
    }

    // MARK: Reading

    /// Built-in residents first, then the user's characters (newest first).
    var allCharacters: [Character] { world.characters + userCharacters }

    func character(_ id: String) -> Character? {
        world.characters.first { $0.id == id } ?? userCharacters.first { $0.id == id }
    }

    func location(_ id: String) -> Location? {
        world.locations.first { $0.id == id }
    }

    func characters(inCategory id: String) -> [Character] {
        allCharacters.filter { $0.categories.contains(id) }
    }

    /// Ranked: name starts with the query > name contains it > tagline, tags or species > bio.
    /// Ignores case and accents. A blank query returns everyone.
    func search(_ query: String) -> [Character] {
        let needle = Self.searchable(query)
        guard !needle.isEmpty else { return allCharacters }
        let words = needle.split(separator: " ").map(String.init)
        var ranked: [(score: Int, order: Int, character: Character)] = []
        for (order, character) in allCharacters.enumerated() {
            let name = Self.searchable(character.name)
            let about = Self.searchable(([character.tagline, character.species ?? ""] + character.tags).joined(separator: " "))
            let bio = Self.searchable(character.bio)
            var score = 0
            if name.hasPrefix(needle) {
                score = 4
            } else if name.contains(needle) {
                score = 3
            } else if Self.hasWord(startingWith: needle, in: about) {
                score = 2
            } else if Self.hasWord(startingWith: needle, in: bio) {
                score = 1
            } else if words.count > 1 {
                // "sleepy fox": every word starts a word somewhere.
                let everything = [name, about, bio].joined(separator: " ")
                if words.allSatisfy({ Self.hasWord(startingWith: $0, in: everything) }) { score = 1 }
            }
            if score > 0 { ranked.append((score, order, character)) }
        }
        return ranked.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.character)
    }

    // MARK: Writing

    /// Saves one of the user's characters and returns it as stored. Anything that isn't already one of
    /// theirs (empty id, a draft, a copy of a resident) is saved as new: it gets an id like "u-juno",
    /// createdAt now, and creator "@you" unless it names one already (imported cards keep their author).
    @discardableResult
    func save(_ character: Character) throws -> Character {
        var c = character
        c.name = c.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.name.isEmpty else { throw LibraryError.nameRequired }
        if c.greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.greeting = "Hi, I'm \(c.name)." }

        let existing = userCharacters.first { $0.id == c.id }
        if let existing {
            c.createdAt = existing.createdAt ?? c.createdAt ?? .now
        } else {
            let copiesResident = world.characters.contains { $0.id == c.id }
            if copiesResident {
                // A copy lives outside the town, so the original keeps its place in it.
                c.creator = "@you"
                c.homeLocationID = nil
                c.schedule = []
                c.relationships = []
            }
            if c.creator.trimmingCharacters(in: .whitespaces).isEmpty { c.creator = "@you" }
            c.id = newID(for: c.name)
            c.createdAt = .now
        }
        c.isBuiltIn = false

        try HearthPaths.write(StoreJSON.encode(c), to: fileURL(for: c.id))
        var list = userCharacters
        if let index = list.firstIndex(where: { $0.id == c.id }) { list[index] = c } else { list.append(c) }
        userCharacters = Self.newestFirst(list)
        if let oldFile = existing?.avatar.file, oldFile != c.avatar.file { removeAvatarIfUnused(oldFile) }
        return c
    }

    /// Deletes one of the user's characters and its avatar. (Its chats and memories live in
    /// ChatStore and MemoryStore; delete those there too.)
    func delete(_ id: String) throws {
        if world.characters.contains(where: { $0.id == id }) { throw LibraryError.builtInIsReadOnly }
        guard let index = userCharacters.firstIndex(where: { $0.id == id }) else { return }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let removed = userCharacters.remove(at: index)
        if let file = removed.avatar.file { removeAvatarIfUnused(file) }
    }

    /// Writes a clean avatar JPEG (no metadata, at most 1024 px) to media/avatars/ and returns a ref to it.
    /// Every call makes a new file, so a draft never changes what a saved character shows (and image
    /// caches never show an old picture); save(_:) deletes the old file once nothing uses it.
    func saveAvatar(_ imageData: Data, for characterID: String) throws -> AvatarRef {
        let jpeg = try AvatarJPEG.make(from: imageData)
        let base = characterID.isEmpty ? "new" : StoreFiles.safeName(characterID)
        let file = "avatars/\(base)-\(UUID().uuidString.prefix(8).lowercased()).jpg"
        try HearthPaths.write(jpeg, to: mediaDirectory.appendingPathComponent(file))
        var ref = character(characterID)?.avatar ?? AvatarRef()
        ref.file = file
        ref.asset = nil
        return ref
    }

    /// Imports a Character Card file (PNG or JSON) as a new character of the user's, picture included.
    @discardableResult
    func importCard(from url: URL) throws -> Character {
        let card = try CharacterCardIO.importCard(from: url)
        var character = card.character
        if let picture = card.avatar, let ref = try? saveAvatar(picture, for: character.id) {
            character.avatar.file = ref.file
        }
        return try save(character)
    }

    /// Puts characters back from a backup with their ids unchanged, so their chats still match.
    /// Same id = replaced; ids that belong to a resident are skipped.
    func restore(_ characters: [Character]) {
        var list = userCharacters
        var restored = 0
        for var c in characters {
            guard !c.id.isEmpty, !world.characters.contains(where: { $0.id == c.id }) else { continue }
            c.isBuiltIn = false
            if let file = c.avatar.file, !StoreFiles.isInside(mediaDirectory.appendingPathComponent(file), mediaDirectory) {
                c.avatar.file = nil
            }
            do {
                try HearthPaths.write(StoreJSON.encode(c), to: fileURL(for: c.id))
            } catch {
                continue
            }
            if let index = list.firstIndex(where: { $0.id == c.id }) { list[index] = c } else { list.append(c) }
            restored += 1
        }
        userCharacters = Self.newestFirst(list)
        HearthLog.info("library", "restored \(restored) character(s)")
    }

    // MARK: PersistentStore

    /// Nothing waits: save(_:) writes right away.
    func flush() {}

    func reloadIfNeeded() {
        guard !unreadableFiles.isEmpty else { return }
        var stillLocked: [URL] = []
        var found: [Character] = []
        for url in unreadableFiles {
            switch StoreFiles.read(url) {
            case .unreadable:
                stillLocked.append(url)
            case .missing:
                continue
            case .data(let data):
                if let c = Self.decodeUserCharacter(data), character(c.id) == nil, !found.contains(where: { $0.id == c.id }) {
                    found.append(c)
                }
            }
        }
        unreadableFiles = stillLocked
        if !found.isEmpty {
            userCharacters = Self.newestFirst(userCharacters + found)
            HearthLog.info("library", "read \(found.count) character(s) after unlock")
        }
    }

    func forgetEverything() {
        userCharacters = []
        unreadableFiles = []
    }

    // MARK: World file

    nonisolated static let emptyWorld = WorldDefinition(id: "empty", name: "Lantern Bay", tagline: "", lore: "",
                                                        categories: [], locations: [], characters: [])

    /// Decodes lantern-bay.json. Keys that have defaults in Core may be left out (altGreetings, voice,
    /// schedule...), and a broken resident, place or category is skipped and counted instead of
    /// emptying the whole town.
    nonisolated static func decodeWorld(from data: Data) throws -> WorldDefinition {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw StoreError.unreadable }
        var skipped = 0
        let categories = StoreJSON.decodeEach(CategoryDef.self, from: root["categories"], skipped: &skipped)
        let locations = StoreJSON.decodeEach(Location.self, from: root["locations"], skipped: &skipped)
        let characters = StoreJSON.decodeEach(Character.self, from: root["characters"], template: residentTemplate, skipped: &skipped)
        // Everything else (id, name, lore...) goes through Codable as usual; the lists were read above.
        root["categories"] = [Any]()
        root["locations"] = [Any]()
        root["characters"] = [Any]()
        root = StoreJSON.filling(root, from: ["starterEvents": [Any]()])
        var world = try StoreJSON.decode(WorldDefinition.self, fromObject: root)
        world.categories = categories
        world.locations = locations
        world.characters = characters.map { resident in
            var resident = resident
            resident.isBuiltIn = true
            return resident
        }
        if skipped > 0 { HearthLog.error("library", "skipped \(skipped) unreadable entries in the world file") }
        if world.characters.isEmpty { HearthLog.error("library", "the world file has no residents") }
        return world
    }

    /// Defaults for resident keys the content file may leave out. Only "id" and "name" are required.
    nonisolated private static var residentTemplate: [String: Any] {
        let blank = Character(id: "", name: "", tagline: "", bio: "", greeting: "", personality: "", speakingStyle: "",
                              avatar: AvatarRef(), accentHex: "#FF8A4C", creator: "@hearth", isBuiltIn: true)
        return StoreJSON.object(blank, removing: ["id", "name"])
    }

    private static func loadBundledWorld() -> WorldDefinition {
        guard let url = HearthPaths.bundledWorld, let data = try? Data(contentsOf: url) else {
            HearthLog.error("library", "bundled world file is missing, starting with an empty town")
            return emptyWorld
        }
        do {
            let world = try decodeWorld(from: data)
            HearthLog.info("library", "world loaded: \(world.characters.count) residents, \(world.locations.count) places")
            return world
        } catch {
            HearthLog.error("library", "bundled world file is unreadable, starting with an empty town")
            return emptyWorld
        }
    }

    // MARK: User character files

    private func fileURL(for id: String) -> URL {
        storageDirectory.appendingPathComponent(StoreFiles.safeName(id) + ".json")
    }

    private func newID(for name: String) -> String {
        let slug = StoreFiles.slug(name)
        let base = "u-" + (slug.isEmpty ? "character" : slug)
        var id = base
        var number = 2
        while character(id) != nil || FileManager.default.fileExists(atPath: fileURL(for: id).path) {
            id = "\(base)-\(number)"
            number += 1
        }
        return id
    }

    private static func loadUserCharacters(from folder: URL) -> (characters: [Character], unreadable: [URL], skipped: Int) {
        var characters: [Character] = []
        var unreadable: [URL] = []
        var skipped = 0
        for url in StoreFiles.jsonFiles(in: folder) {
            switch StoreFiles.read(url) {
            case .missing:
                continue
            case .unreadable:
                unreadable.append(url)
            case .data(let data):
                guard let c = decodeUserCharacter(data), !characters.contains(where: { $0.id == c.id }) else {
                    skipped += 1
                    continue
                }
                characters.append(c)
            }
        }
        if skipped > 0 { HearthLog.error("library", "skipped \(skipped) unreadable character file(s)") }
        if !unreadable.isEmpty { HearthLog.error("library", "\(unreadable.count) character file(s) can't be opened yet (locked)") }
        return (characters, unreadable, skipped)
    }

    nonisolated private static func decodeUserCharacter(_ data: Data) -> Character? {
        let blank = Character(id: "", name: "", tagline: "", bio: "", greeting: "", personality: "", speakingStyle: "",
                              avatar: AvatarRef(), accentHex: "#FF8A4C")
        guard var c = try? StoreJSON.decode(Character.self, from: data, template: StoreJSON.object(blank, removing: ["id", "name"])) else {
            return nil
        }
        c.isBuiltIn = false
        return c
    }

    private static func newestFirst(_ list: [Character]) -> [Character] {
        list.sorted { a, b in
            let dateA = a.createdAt ?? .distantPast
            let dateB = b.createdAt ?? .distantPast
            return dateA != dateB ? dateA > dateB : a.id < b.id
        }
    }

    /// True when `needle` starts a word in `text`, so "tea" finds "tea time" but not "steam".
    private static func hasWord(startingWith needle: String, in text: String) -> Bool {
        var from = text.startIndex
        while from < text.endIndex, let found = text.range(of: needle, range: from..<text.endIndex) {
            if found.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: found.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            from = text.index(after: found.lowerBound)
        }
        return false
    }

    private static func searchable(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    // MARK: Avatar files

    private func removeAvatarIfUnused(_ file: String) {
        let url = mediaDirectory.appendingPathComponent(file)
        guard StoreFiles.isInside(url, mediaDirectory.appendingPathComponent("avatars", isDirectory: true)),
              !userCharacters.contains(where: { $0.avatar.file == file }) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func removeUnusedAvatars() {
        let folder = mediaDirectory.appendingPathComponent("avatars", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        let used = Set(userCharacters.compactMap(\.avatar.file))
        var removed = 0
        for url in files where !used.contains("avatars/" + url.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 { HearthLog.info("library", "removed \(removed) unused avatar picture(s)") }
    }
}
