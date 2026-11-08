// The one object that owns every service. Views read it with `@Environment(AppModel.self)`.

import SwiftUI

@MainActor @Observable final class AppModel {
    let settingsStore: SettingsStore
    let library: Library
    let chats: ChatStore
    let memory: MemoryStore
    let events: WorldEventStore
    let engine: EngineHost
    let voice: VoiceStudio
    let dictation: Dictation
    let pictures: PictureMaker
    let vault: PrivacyVault
    let router = Router()

    /// Shortcut for reading and writing settings (saved by SettingsStore).
    var settings: AppSettings {
        get { settingsStore.settings }
        set { settingsStore.settings = newValue }
    }

    /// Who is where, who speaks next in scenes. User characters who moved into town (they have a home)
    /// count as residents too.
    var director: WorldDirector {
        var world = library.world
        world.characters = library.allCharacters.filter { $0.isBuiltIn || $0.homeLocationID != nil }
        return WorldDirector(world: world)
    }

    @ObservationIgnored private var booted = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        let options = LaunchOptions.shared
        if options.reset { AppModel.eraseLocalData() }
        settingsStore = SettingsStore()
        library = Library()
        chats = ChatStore()
        memory = MemoryStore()
        events = WorldEventStore()
        engine = EngineHost()
        voice = VoiceStudio()
        dictation = Dictation()
        pictures = PictureMaker()
        vault = PrivacyVault()
        engine.preferredEngineIDProvider = { [weak settingsStore] in settingsStore?.settings.preferredEngineID }
        // Lock before the first frame so chats never flash on screen. Settings that can't be opened yet (iOS
        // started Hearth in the background while the iPhone was locked, for a model download) may have App Lock
        // on, so lock until they can be read: their stand-in defaults have it off.
        if settingsStore.isWaitingForUnlock {
            vault.lockUntilSettingsAreRead()
        } else {
            vault.lockIfNeeded(appLockEnabled: settingsStore.settings.appLock)
        }
        settingsStore.onReload = { [weak self] settings in self?.settingsBecameReadable(settings) }
        if options.skipOnboarding {
            settingsStore.update {
                $0.onboardingDone = true
                $0.confirmedAdult = true
                if $0.persona.name == UserPersona().name { $0.persona.name = "Sam" }
            }
        }
    }

    /// Runs once when the first window appears.
    func boot() async {
        guard !booted else { return }
        booted = true
        let options = LaunchOptions.shared
        vault.applyBackupExclusion(settings.excludeFromBackup)
        voice.assignDistinctVoices(for: library.allCharacters)
        if events.events.isEmpty { seedStarterEvents() }
        if options.seedDemo { DemoSeeder.seed(self) }
        await engine.start(preferredEngineID: settings.preferredEngineID)
        HearthLog.info("app", "booted engine=\(engine.active?.id ?? "none") characters=\(library.allCharacters.count)")
        if options.artGen { await ArtGen.run() }
        if options.benchmark { await HearthBenchmark.run(host: engine) }
        // The UI tour (App/Root/UITour.swift) is started by RootView after boot.
    }

    /// Lock, shield and save as the app moves between foreground and background.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Files locked at launch are read now if the unlock notice came while iOS kept Hearth suspended
            // (the settings among them, which re-applies App Lock).
            StoreRegistry.reloadAll()
            vault.shieldVisible = false
        case .inactive:
            if settings.hideInAppSwitcher { vault.shieldVisible = true }
        case .background:
            // iOS refuses GPU work from a background app, so a reply still being written would fail and lose the
            // chat's model memory. Stop it instead: the words so far are kept, and the cache stays good.
            engine.cancel()
            StoreRegistry.reloadAndFlushAll()
            if settings.hideInAppSwitcher { vault.shieldVisible = true }
            vault.lockIfNeeded(appLockEnabled: settings.appLock)
            parkInBackground()
        @unknown default:
            break
        }
    }

    /// The settings file was locked at launch and could be read now: apply what it says.
    private func settingsBecameReadable(_ settings: AppSettings) {
        vault.settingsWereRead(appLockEnabled: settings.appLock)
        vault.applyBackupExclusion(settings.excludeFromBackup)
    }

    /// Saves the open conversation's KV cache to flash while iOS gives us a little background time.
    private func parkInBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "park-kv") { [weak self] in
            self?.endBackgroundTask()
        }
        Task {
            await engine.parkCurrent()
            StoreRegistry.reloadAndFlushAll() // the reply stopped above, saved before iOS suspends Hearth
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Deleting things everywhere they live

    /// Deletes a conversation and its parked KV cache (which holds the conversation's content).
    func deleteConversation(_ id: UUID) {
        guard let conversation = chats.conversation(id) else { return }
        let key = conversation.engineKey
        chats.delete(id)
        Task { await engine.forget(conversationKey: key) }
    }

    /// Deletes a user-made character with its chats, memories and avatar. Group scenes stay for the others in
    /// them, minus this character's lines and invites, and their parked caches go (they hold those lines).
    func deleteCharacter(_ id: String) throws {
        for conversation in chats.directChats(with: id) { deleteConversation(conversation.id) }
        for scene in chats.removeFromScenes(characterID: id) {
            let key = scene.engineKey
            Task { await engine.forget(conversationKey: key) }
        }
        memory.removeAll(for: id)
        try library.delete(id)
        settingsStore.update { $0.voiceOverrides[id] = nil }
        voice.assignDistinctVoices(for: library.allCharacters)
    }

    /// "Delete everything": stops work, drops caches, wipes files, and returns to onboarding.
    func wipeEverything(includeModels: Bool) async throws {
        engine.cancel()
        voice.stop()
        dictation.cancel()
        await engine.purgeParked()
        try await vault.wipeEverything(includeModels: includeModels)
        HearthImageCache.shared.removeAll()
        settingsStore.update { $0 = AppSettings() }
        router.homePath = []
        router.townPath = []
        router.chatsPath = []
        router.youPath = []
        router.tab = .home
        if includeModels {
            for spec in ModelCatalog.all { engine.downloader.delete(spec) }
            await engine.start(preferredEngineID: nil)
        }
    }

    /// The first time the town opens there is already a little news.
    private func seedStarterEvents() {
        let world = library.world
        let names = world.characters.map { ($0.id, $0.name) }
        let seeded = world.starterEvents.prefix(3).enumerated().map { index, text in
            WorldEvent(date: Date().addingTimeInterval(Double(-3600 * (index + 1) * 3)),
                       text: text,
                       characterIDs: names.filter { text.contains($0.1) }.map(\.0))
        }
        events.add(Array(seeded))
    }

    /// Synchronous wipe for `-HearthReset 1` (keeps downloaded models).
    static func eraseLocalData() {
        let fm = FileManager.default
        for dir in [HearthPaths.chats, HearthPaths.characters, HearthPaths.media, HearthPaths.state, HearthPaths.kvCache] {
            try? fm.removeItem(at: dir)
        }
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("hearth.") && key != "hearth.network.downloadedBytes" {
            UserDefaults.standard.removeObject(forKey: key)
        }
        HearthLog.info("app", "local data erased by launch option")
    }
}
