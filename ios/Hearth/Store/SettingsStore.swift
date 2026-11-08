// The user's settings (AppSettings in Core), kept in state/settings.json.
// Any change saves itself about half a second later; flush() saves right away.

import Foundation
import Observation

@MainActor @Observable final class SettingsStore: PersistentStore {
    /// Assign or mutate freely (also through bindings); every real change is saved.
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            isDirty = true
            debouncer.schedule { [weak self] in self?.flush() }
        }
    }

    let storageDirectory: URL
    private let debouncer = StoreDebouncer()
    @ObservationIgnored private var isDirty = false
    /// settings.json exists but couldn't be opened (iPhone locked): never overwrite it with defaults.
    @ObservationIgnored private var needsReload = false
    /// Called once settings that were locked at launch have been read (AppModel re-applies App Lock with them).
    @ObservationIgnored var onReload: (@MainActor (AppSettings) -> Void)?

    /// True while the settings shown are stand-in defaults because settings.json couldn't be opened yet.
    var isWaitingForUnlock: Bool { needsReload }

    private var fileURL: URL { storageDirectory.appendingPathComponent("settings.json") }

    init(directory: URL = HearthPaths.state) {
        storageDirectory = directory
        let loaded = Self.load(directory.appendingPathComponent("settings.json"))
        settings = loaded.settings
        needsReload = loaded.unreadable
        StoreRegistry.register(self)
    }

    /// Several changes in one go (saved once).
    func update(_ change: (inout AppSettings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
    }

    func flush() {
        debouncer.cancel()
        reloadIfNeeded()
        guard isDirty, !needsReload else { return }
        do {
            try HearthPaths.write(StoreJSON.encode(settings), to: fileURL)
            isDirty = false
        } catch {
            HearthLog.error("settings", "save failed (\(StoreFiles.describe(error))), will retry")
        }
    }

    func reloadIfNeeded() {
        guard needsReload else { return }
        let loaded = Self.load(fileURL)
        guard !loaded.unreadable else { return }
        needsReload = false
        // What's on disk wins over the defaults shown while the file was locked.
        settings = loaded.settings
        isDirty = false
        debouncer.cancel()
        HearthLog.info("settings", "settings read after unlock")
        onReload?(settings)
    }

    func forgetEverything() {
        needsReload = false
        settings = AppSettings()
        isDirty = false
        debouncer.cancel()
    }

    private static func load(_ url: URL) -> (settings: AppSettings, unreadable: Bool) {
        switch StoreFiles.read(url) {
        case .missing:
            return (AppSettings(), false)
        case .unreadable:
            HearthLog.error("settings", "settings file can't be opened yet (locked), using defaults for now")
            return (AppSettings(), true)
        case .data(let data):
            do {
                // Settings added in later versions get their default values.
                return (try StoreJSON.decode(AppSettings.self, from: data, template: StoreJSON.object(AppSettings())), false)
            } catch {
                HearthLog.error("settings", "settings file unreadable, using defaults")
                return (AppSettings(), false)
            }
        }
    }
}
