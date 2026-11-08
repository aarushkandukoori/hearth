// Everything the user made, gathered into one value for encrypted backups (PrivacyVault).
// Version 1 holds text only: photos, pictures, voice notes and avatar images are not included.

import Foundation

struct HearthExport: Codable, Sendable {
    static let currentVersion = 1

    var version = 1
    var exportedAt: Date
    var settings: AppSettings
    var userCharacters: [Character]
    var conversations: [Conversation]
    var facts: [MemoryFact]
    var events: [WorldEvent]
}

extension HearthExport {
    /// A snapshot of the stores, ready for PrivacyVault.exportEncrypted.
    @MainActor static func gather(settings: SettingsStore, library: Library, chats: ChatStore,
                                  memory: MemoryStore, events: WorldEventStore) -> HearthExport {
        HearthExport(exportedAt: .now, settings: settings.settings, userCharacters: library.userCharacters,
                     conversations: chats.conversations, facts: memory.facts, events: events.events)
    }

    /// Adds a backup's contents to the stores. Same ids are replaced, nothing else is deleted, and the
    /// backup's settings become the current settings.
    @MainActor func restore(settings: SettingsStore, library: Library, chats: ChatStore,
                            memory: MemoryStore, events: WorldEventStore) {
        settings.settings = self.settings
        library.restore(userCharacters)
        chats.restore(conversations)
        memory.add(facts)
        events.add(self.events)
    }
}
