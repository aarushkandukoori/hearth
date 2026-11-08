// EngineHost: the one place the app talks to a language engine. It picks the engine (a Hearth model,
// Apple's on-device model, or demo replies), loads it, runs one generation at a time, and exposes state.

import Foundation
import Observation

@MainActor @Observable final class EngineHost {
    enum State: Equatable {
        case idle
        /// No model on the phone yet: show the download screen.
        case needsModel
        /// A label to show while weights load, e.g. "Loading Hearth Standard (Llama 3.2 3B)".
        case loading(String)
        case ready
        /// A message for the person (already friendly).
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var active: EngineDescriptor?
    private(set) var lastStats: GenerationStats?
    /// True from the moment a request is queued until the last queued request finishes.
    private(set) var isGenerating = false
    let downloader = ModelDownloader()
    private(set) var appleAvailable = AppleEngine.isAvailable
    /// Models whose files are on this phone (catalog models, plus a `-HearthModel` file).
    private(set) var installedModels: [ModelSpec] = ModelCatalog.installedSpecs()

    @ObservationIgnored private var engine: (any LanguageEngine)?
    /// The last queued operation. Loads and generations run strictly one after another.
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var queuedRequests = 0
    @ObservationIgnored private var cancelEpoch = 0
    /// Conversation whose KV cache the engine holds, so a switch can park it first.
    @ObservationIgnored private var lastConversationKey: String?
    @ObservationIgnored private var preferredEngineID: String?
    /// Reads the person's current engine choice from settings (set by AppModel), so a finished download
    /// knows whether it was the one they picked.
    @ObservationIgnored var preferredEngineIDProvider: (@MainActor () -> String?)?

    /// Set while a model loads. If it is still set at the next launch, the app was killed mid-load.
    static let loadingMarkerKey = "hearth.engine.loadingModel"

    init() {
        downloader.onInstalled = { [weak self] spec in self?.modelInstalled(spec) }
    }

    // MARK: - Choosing and loading

    /// Picks and loads an engine. Order: `-HearthEngine` override, `-HearthModel` file, the person's
    /// preference, an installed Hearth model (never on the Simulator), Apple's model, else `.needsModel`.
    func start(preferredEngineID: String?) async {
        self.preferredEngineID = preferredEngineID
        appleAvailable = AppleEngine.isAvailable
        installedModels = ModelCatalog.installedSpecs()
        let choice = choose(preferred: preferredEngineID)

        if case .llama(let spec, _) = choice, let crashed = UserDefaults.standard.string(forKey: Self.loadingMarkerKey) {
            UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey)
            if crashed == spec.id {
                HearthLog.error("engine", "\(spec.id) did not finish loading last time; waiting for the person to choose")
                await perform {
                    await self.deactivate(park: true)
                    self.state = .failed("Last time, Hearth closed while loading \(spec.displayName). This often means the iPhone ran short on memory. You can try again, or pick a smaller model.")
                }
                return
            }
        }
        if let id = choice.engineID, active?.id == id, state == .ready { return }
        await perform { await self.activate(choice) }
    }

    /// Switches to a ModelSpec id, "apple" or "mock". Unknown or unavailable ids leave the current engine alone.
    func switchTo(engineID: String) async {
        appleAvailable = AppleEngine.isAvailable
        installedModels = ModelCatalog.installedSpecs()
        let choice: Choice
        switch engineID {
        case "mock":
            choice = .mock
        case "apple":
            guard appleAvailable else {
                HearthLog.error("engine", "switch to apple ignored: not available")
                return
            }
            choice = .apple
        default:
            guard let llama = llamaChoice(id: engineID) else {
                HearthLog.error("engine", "switch to \(engineID) ignored: not installed or can't run here")
                return
            }
            choice = llama
        }
        preferredEngineID = engineID
        if active?.id == engineID, state == .ready { return }
        cancel()
        await perform { await self.activate(choice) }
    }

    private enum Choice {
        case llama(ModelSpec, URL)
        case apple
        case mock
        case needsModel

        var engineID: String? {
            switch self {
            case .llama(let spec, _): return spec.id
            case .apple: return "apple"
            case .mock: return "mock"
            case .needsModel: return nil
            }
        }
    }

    private func choose(preferred: String?) -> Choice {
        switch LaunchOptions.shared.engine?.lowercased() {
        case "mock"?: return .mock
        case "apple"? where appleAvailable: return .apple
        case "llama"?: return firstLlama(preferred: preferred) ?? .needsModel
        default: break
        }
        if let override = launchModelChoice() { return override }
        if let preferred {
            if preferred == "mock" { return .mock }
            if preferred == "apple", appleAvailable { return .apple }
            if let choice = llamaChoice(id: preferred) { return choice }
        }
        if let choice = firstLlama(preferred: nil) { return choice }
        if appleAvailable { return .apple }
        return .needsModel
    }

    /// An installed Hearth model this build can run. Simulator builds have no llama.cpp, so never there.
    private func llamaChoice(id: String) -> Choice? {
        #if canImport(llama)
        guard let spec = ModelCatalog.spec(id: id), let url = ModelCatalog.installedURL(for: spec) else { return nil }
        return .llama(spec, url)
        #else
        return nil
        #endif
    }

    private func launchModelChoice() -> Choice? {
        #if canImport(llama)
        guard let override = ModelCatalog.launchOverride() else { return nil }
        return .llama(override.spec, override.url)
        #else
        return nil
        #endif
    }

    /// The `-HearthModel` file, else the preferred model, else the recommended installed one, else any installed.
    private func firstLlama(preferred: String?) -> Choice? {
        if let override = launchModelChoice() { return override }
        if let preferred, let choice = llamaChoice(id: preferred) { return choice }
        let installed = ModelCatalog.all.filter { ModelCatalog.installedURL(for: $0) != nil }
        guard let pick = installed.first(where: \.recommended) ?? installed.first else { return nil }
        return llamaChoice(id: pick.id)
    }

    private func activate(_ choice: Choice) async {
        if let id = choice.engineID, active?.id == id, state == .ready { return } // already running it
        await deactivate(park: true)
        switch choice {
        case .needsModel:
            state = .needsModel
        case .mock:
            install(MockEngine())
        case .apple:
            let apple = AppleEngine()
            do {
                try await apple.prepare()
                install(apple)
            } catch {
                state = .failed(error.localizedDescription)
            }
        case .llama(let spec, let url):
            #if canImport(llama)
            state = .loading("Loading \(spec.displayName)")
            UserDefaults.standard.set(spec.id, forKey: Self.loadingMarkerKey)
            let llama = LlamaEngine(spec: spec, modelURL: url)
            do {
                try await llama.prepare()
                UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey)
                install(llama)
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey)
                HearthLog.error("engine", "\(spec.id) failed to load")
                state = .failed(error.localizedDescription)
            }
            #else
            _ = (spec, url)
            state = .needsModel
            #endif
        }
    }

    private func install(_ newEngine: any LanguageEngine) {
        engine = newEngine
        active = newEngine.descriptor
        state = .ready
        HearthLog.info("engine", "active engine: \(newEngine.descriptor.id)")
    }

    /// Stops and frees the current engine, parking its conversation first when asked.
    private func deactivate(park: Bool) async {
        guard let old = engine else { return }
        engine = nil
        active = nil
        state = .idle
        old.cancelCurrent()
        if park, let key = lastConversationKey { await old.park(conversationKey: key) }
        await old.shutdown()
    }

    private func modelInstalled(_ spec: ModelSpec) {
        installedModels = ModelCatalog.installedSpecs()
        // A model the person just downloaded replaces the download screen or the demo replies, and it also
        // replaces Apple's model when it's the one they picked. It queues behind any reply in progress and any
        // waiting (no cancel, unlike switchTo), so a finished download never cuts a reply off.
        let preferred = preferredEngineIDProvider?() ?? preferredEngineID
        guard LaunchOptions.shared.engine == nil,
              state == .needsModel || active?.id == "mock" || preferred == spec.id,
              active?.id != spec.id,
              let choice = llamaChoice(id: spec.id) else { return }
        preferredEngineID = spec.id
        Task { await self.perform { await self.activate(choice) } }
    }

    // MARK: - Generating

    /// Streams a reply from the active engine. Requests run one at a time in the order they were made;
    /// a new one waits for the running one. Ends with exactly one `.done(stats)` unless it throws.
    /// After `cancel()`, the stream still ends with `.done` and `stats.stoppedBy == "cancelled"`.
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<GenerationEvent, Error>.makeStream()
        let epoch = cancelEpoch
        queuedRequests += 1
        isGenerating = true
        let task = enqueue { [weak self] in
            guard let self else {
                continuation.finish(throwing: EngineError.cancelled)
                return
            }
            await self.run(request, epoch: epoch, continuation)
            self.queuedRequests -= 1
            self.isGenerating = self.queuedRequests > 0
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() } // the reader went away
        }
        return stream
    }

    private func run(_ request: GenerationRequest, epoch: Int,
                     _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        if Task.isCancelled {
            continuation.finish()
            return
        }
        guard epoch == cancelEpoch else { // cancel() was called while this request waited its turn
            continuation.yield(.done(GenerationStats(engine: active?.id ?? "none", stoppedBy: "cancelled")))
            continuation.finish()
            return
        }
        guard let engine, state == .ready else {
            continuation.finish(throwing: notReadyError())
            return
        }
        lastConversationKey = request.conversationKey
        do {
            for try await event in engine.generate(request) {
                if case .done(let stats) = event { lastStats = stats }
                continuation.yield(event)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Stops the running reply within about one token, and drops requests still waiting.
    func cancel() {
        cancelEpoch += 1
        engine?.cancelCurrent()
    }

    private func notReadyError() -> EngineError {
        switch state {
        case .needsModel: return .modelMissing
        case .failed(let message): return .unavailable(message)
        default: return .unavailable("Hearth is still getting its model ready.")
        }
    }

    // MARK: - Parked conversations and models

    /// Saves this conversation's KV cache to flash now (call when the app goes to the background).
    func park(conversationKey: String) async {
        await engine?.park(conversationKey: conversationKey)
    }

    /// Parks whatever conversation the engine currently holds (call when the app goes to the background).
    func parkCurrent() async {
        guard let key = lastConversationKey else { return }
        await park(conversationKey: key)
    }

    /// Forgets one conversation's cache in memory and on flash (call when a chat is deleted).
    func forget(conversationKey: String) async {
        #if canImport(llama)
        if let llama = engine as? LlamaEngine { await llama.forget(conversationKey: conversationKey) }
        #endif
        KVStateCache.removeEverywhere(key: conversationKey)
        if lastConversationKey == conversationKey { lastConversationKey = nil }
    }

    /// Deletes a downloaded model and its parked caches, then falls back to another engine.
    func deleteModel(_ spec: ModelSpec) async {
        if active?.id == spec.id {
            cancel()
            await perform { await self.deactivate(park: false) }
        }
        downloader.delete(spec)
        KVStateCache(modelID: spec.id).purge()
        installedModels = ModelCatalog.installedSpecs()
        if engine == nil {
            await start(preferredEngineID: preferredEngineID == spec.id ? nil : preferredEngineID)
        }
    }

    /// Bytes of parked KV caches on flash, across all models.
    func parkedBytes() -> Int64 { KVStateCache.totalBytes() }

    /// Deletes every parked KV cache (conversations stay; they are just re-read next time).
    func purgeParked() async {
        // Every model's folder first, then the loaded model's own purge, which makes its folder again so it can
        // keep parking. (The other order deleted that folder last and parking failed until a relaunch.)
        KVStateCache.purgeAll()
        await engine?.purgeParkedState()
        lastConversationKey = nil
    }

    // MARK: - Serial queue on the main actor

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) async {
        await enqueue(operation).value
    }
}
