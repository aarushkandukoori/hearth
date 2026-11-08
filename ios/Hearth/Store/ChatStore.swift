// Every conversation (1:1 chats and town scenes), one JSON file each in chats/<id>.json.
// Changes are saved about half a second later, or right away with flush(). Deleting a message or a
// chat also deletes its photos, pictures and voice notes once nothing else points to them.

import Foundation
import Observation

@MainActor @Observable final class ChatStore: PersistentStore {
    /// All conversations, most recently active first.
    private(set) var conversations: [Conversation] = []

    let storageDirectory: URL
    private let mediaDirectory: URL
    private let debouncer = StoreDebouncer()
    @ObservationIgnored private var unsaved: Set<UUID> = []
    /// Chat files that exist but couldn't be opened yet (the iPhone was locked at launch).
    @ObservationIgnored private var unreadableFiles: [URL] = []

    init(directory: URL = HearthPaths.chats, mediaDirectory: URL = HearthPaths.media) {
        storageDirectory = directory
        self.mediaDirectory = mediaDirectory
        let loaded = Self.loadAll(from: directory)
        conversations = Self.mostRecentFirst(loaded.conversations)
        unreadableFiles = loaded.unreadable
        StoreRegistry.register(self)
    }

    // MARK: Reading

    /// 1:1 chats the user has actually written in (not archived), most recent first.
    var recent: [Conversation] {
        conversations.filter { conversation in
            !conversation.archived && conversation.directCharacterID != nil
                && conversation.messages.contains { $0.role == .user }
        }
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// The most recent 1:1 chat with this character that isn't archived.
    func latestDirect(with characterID: String) -> Conversation? {
        conversations.first { $0.directCharacterID == characterID && !$0.archived }
    }

    /// Every 1:1 chat with this character (archived ones too), most recent first.
    func directChats(with characterID: String) -> [Conversation] {
        conversations.filter { $0.directCharacterID == characterID }
    }

    // MARK: Starting conversations

    /// A new 1:1 chat that opens with the character's greeting ({{user}} and {{char}} filled in).
    /// The alternate greetings ride along as swipeable variants of that first message;
    /// `useAltGreeting` starts on a random one of them instead of the main greeting.
    func startDirect(with c: Character, persona: UserPersona, useAltGreeting: Bool = false) -> Conversation {
        let personaName = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let userName = personaName.isEmpty ? UserPersona().name : personaName
        let greetings = ([c.greeting] + c.altGreetings)
            .map { CharacterCardIO.fillPlaceholders($0, user: userName, char: c.name).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var conversation = Conversation(kind: .direct(characterID: c.id), participantIDs: [c.id])
        if let first = greetings.first {
            var greeting = Message(role: .character, speakerID: c.id, text: first)
            greeting.variants = greetings
            if useAltGreeting, greetings.count > 1 { greeting.selected = Int.random(in: 1..<greetings.count) }
            conversation.messages = [greeting]
        }
        put(conversation)
        return conversation
    }

    /// The one group scene for a location (created the first time), with `present` as its participants.
    func scene(at location: Location, present: [Character]) -> Conversation {
        let ids = present.map(\.id)
        if var existing = conversations.first(where: { $0.sceneLocationID == location.id }) {
            if existing.participantIDs != ids {
                existing.participantIDs = ids
                put(existing)
            }
            return existing
        }
        var conversation = Conversation(kind: .scene(locationID: location.id), participantIDs: ids)
        conversation.title = location.name
        put(conversation)
        return conversation
    }

    // MARK: Changing conversations

    /// Stores a conversation as given (adds it if new). If its messages changed, it counts as activity:
    /// updatedAt becomes now and media that no message uses anymore is deleted.
    func update(_ c: Conversation) {
        var conversation = c
        let old = self.conversation(c.id)
        if let old {
            guard old != conversation else { return }
            if old.messages != conversation.messages { conversation.updatedAt = .now }
        }
        put(conversation)
        if let old { removeMedia(Self.files(in: old.messages).subtracting(Self.files(in: conversation.messages))) }
    }

    func append(_ m: Message, to id: UUID) {
        changeMessages(of: id) { $0.append(m) }
    }

    /// Replaces the message with the same id (new text, a swipe, a rating, a finished attachment...).
    func replace(_ m: Message, in id: UUID) {
        changeMessages(of: id) { messages in
            if let index = messages.firstIndex(where: { $0.id == m.id }) { messages[index] = m }
        }
    }

    func deleteMessage(_ messageID: UUID, in id: UUID) {
        changeMessages(of: id) { $0.removeAll { $0.id == messageID } }
    }

    /// Removes every message after this one (it stays). Used for edit-and-resend and rewinding.
    func truncate(after messageID: UUID, in id: UUID) {
        changeMessages(of: id) { messages in
            if let index = messages.firstIndex(where: { $0.id == messageID }) { messages.removeSubrange((index + 1)...) }
        }
    }

    /// Takes a character out of every group scene: their lines, their invite notes (narrator notes with their
    /// id) and their place in the cast. Returns the scenes that changed, whose parked caches still hold the lines.
    /// The scenes keep their place in the chat list.
    @discardableResult
    func removeFromScenes(characterID: String) -> [Conversation] {
        var changed: [Conversation] = []
        for scene in conversations where scene.sceneLocationID != nil {
            var kept = scene
            kept.messages.removeAll { $0.speakerID == characterID }
            kept.participantIDs.removeAll { $0 == characterID }
            guard kept != scene else { continue }
            put(kept)
            removeMedia(Self.files(in: scene.messages).subtracting(Self.files(in: kept.messages)))
            changed.append(kept)
        }
        return changed
    }

    /// Deletes a conversation, its file and its media.
    func delete(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        let removed = conversations.remove(at: index)
        unsaved.remove(id)
        let url = fileURL(for: id)
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } catch {
            HearthLog.error("chats", "couldn't delete a chat file (\(StoreFiles.describe(error)))")
        }
        removeMedia(Self.files(in: removed.messages))
    }

    /// Puts conversations back from a backup (same id = replaced).
    func restore(_ list: [Conversation]) {
        guard !list.isEmpty else { return }
        var byID = Dictionary(conversations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for conversation in list {
            byID[conversation.id] = conversation
            unsaved.insert(conversation.id)
        }
        conversations = Self.mostRecentFirst(Array(byID.values))
        scheduleSave()
        HearthLog.info("chats", "restored \(list.count) conversation(s)")
    }

    // MARK: PersistentStore

    /// Writes every conversation with unsaved changes now (call when the app goes to the background).
    func flush() {
        debouncer.cancel()
        saveUnsaved()
    }

    func reloadIfNeeded() {
        guard !unreadableFiles.isEmpty else { return }
        var stillLocked: [URL] = []
        var found: [Conversation] = []
        for url in unreadableFiles {
            switch StoreFiles.read(url) {
            case .unreadable:
                stillLocked.append(url)
            case .missing:
                continue
            case .data(let data):
                if let c = try? Self.decodeConversation(data), conversation(c.id) == nil { found.append(Self.settlingUnfinishedMedia(c)) }
            }
        }
        unreadableFiles = stillLocked
        if !found.isEmpty {
            conversations = Self.mostRecentFirst(conversations + found)
            HearthLog.info("chats", "read \(found.count) conversation(s) after unlock")
        }
    }

    func forgetEverything() {
        debouncer.cancel()
        conversations = []
        unsaved = []
        unreadableFiles = []
    }

    // MARK: Private

    /// Applies a change to one conversation's messages; real changes count as activity.
    private func changeMessages(of id: UUID, _ change: (inout [Message]) -> Void) {
        guard var conversation = self.conversation(id) else {
            HearthLog.error("chats", "change for a conversation that isn't loaded")
            return
        }
        let before = conversation.messages
        change(&conversation.messages)
        guard conversation.messages != before else { return }
        conversation.updatedAt = .now
        put(conversation)
        removeMedia(Self.files(in: before).subtracting(Self.files(in: conversation.messages)))
    }

    /// Replaces or adds a conversation in memory and schedules its save.
    private func put(_ conversation: Conversation) {
        var list = conversations
        if let index = list.firstIndex(where: { $0.id == conversation.id }) {
            list[index] = conversation
        } else {
            list.append(conversation)
        }
        conversations = Self.mostRecentFirst(list)
        unsaved.insert(conversation.id)
        scheduleSave()
    }

    private func scheduleSave() {
        debouncer.schedule { [weak self] in self?.saveUnsaved() }
    }

    private func saveUnsaved() {
        guard !unsaved.isEmpty else { return }
        let encoder = StoreJSON.encoder()
        var failures = 0
        for id in unsaved {
            guard let conversation = self.conversation(id) else {
                unsaved.remove(id)
                continue
            }
            do {
                try HearthPaths.write(encoder.encode(conversation), to: fileURL(for: id))
                unsaved.remove(id)
            } catch {
                failures += 1
            }
        }
        // Kept as unsaved: the next change, flush or unlock tries again.
        if failures > 0 { HearthLog.error("chats", "\(failures) chat(s) not saved yet, will retry") }
    }

    private func fileURL(for id: UUID) -> URL {
        storageDirectory.appendingPathComponent(id.uuidString + ".json")
    }

    /// Deletes media files that no message in any conversation points to anymore.
    private func removeMedia(_ candidates: Set<String>) {
        guard !candidates.isEmpty else { return }
        let stillUsed = Self.files(in: conversations.flatMap(\.messages))
        for file in candidates.subtracting(stillUsed) {
            let url = mediaDirectory.appendingPathComponent(file)
            guard StoreFiles.isInside(url, mediaDirectory) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func files(in messages: [Message]) -> Set<String> {
        Set(messages.compactMap { $0.attachment?.file })
    }

    private static func mostRecentFirst(_ list: [Conversation]) -> [Conversation] {
        list.sorted { a, b in
            a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id.uuidString < b.id.uuidString
        }
    }

    private static func loadAll(from folder: URL) -> (conversations: [Conversation], unreadable: [URL]) {
        var byID: [UUID: Conversation] = [:]
        var unreadable: [URL] = []
        var skipped = 0
        for url in StoreFiles.jsonFiles(in: folder) {
            switch StoreFiles.read(url) {
            case .missing:
                continue
            case .unreadable:
                unreadable.append(url)
            case .data(let data):
                guard let conversation = try? decodeConversation(data) else {
                    skipped += 1
                    continue
                }
                if let other = byID[conversation.id], other.updatedAt >= conversation.updatedAt { continue }
                byID[conversation.id] = settlingUnfinishedMedia(conversation)
            }
        }
        if skipped > 0 { HearthLog.error("chats", "skipped \(skipped) unreadable chat file(s)") }
        if !unreadable.isEmpty { HearthLog.error("chats", "\(unreadable.count) chat file(s) can't be opened yet (locked)") }
        HearthLog.info("chats", "loaded \(byID.count) conversation(s)")
        return (Array(byID.values), unreadable)
    }

    /// For chats read from disk: media still marked as on its way can't arrive any more, because the drawing,
    /// recording or photo import that would finish it ended with the app. A picture becomes a failed one
    /// ("The picture didn't come out this time"), a voice note stays a text reply, and a photo that never
    /// finished importing is dropped (with its message, when that has no text either).
    nonisolated static func settlingUnfinishedMedia(_ conversation: Conversation) -> Conversation {
        var settled = conversation
        settled.messages = conversation.messages.compactMap { message in
            guard var attachment = message.attachment, attachment.status == .pending else { return message }
            var m = message
            switch attachment.kind {
            case .picture:
                attachment.status = .failed
                m.attachment = attachment
            case .voice:
                m.attachment = nil
            case .photo:
                m.attachment = nil
                if m.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            }
            return m
        }
        return settled
    }

    /// Reads one chat file. Files from older versions may lack fields added later; those get their
    /// default values (ids, kind, role and text are required).
    nonisolated static func decodeConversation(_ data: Data) throws -> Conversation {
        do {
            return try StoreJSON.decoder().decode(Conversation.self, from: data)
        } catch {
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw error }
            let blankConversation = Conversation(kind: .direct(characterID: ""), participantIDs: [])
            object = StoreJSON.filling(object, from: StoreJSON.object(blankConversation, removing: ["id", "kind"]))
            let messageTemplate = StoreJSON.object(Message(role: .user, text: ""), removing: ["id", "role", "variants"])
            if let messages = object["messages"] as? [[String: Any]] {
                object["messages"] = messages.map { StoreJSON.filling($0, from: messageTemplate) }
            }
            return try StoreJSON.decode(Conversation.self, fromObject: object)
        }
    }
}
