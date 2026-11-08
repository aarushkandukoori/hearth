// EngineHost: the one place the app talks to a language engine. It picks the engine (a Hearth model run by
// Pie, or demo replies), loads it, runs one generation at a time, and exposes state.

import Foundation
import Observation

@MainActor @Observable final class EngineHost {
    enum State: Equatable {
        case idle
        /// No model on the phone yet: show the download screen.
        case needsModel
        /// A label to show while weights load, e.g. "Loading Hearth Standard (Qwen3.5 2B)".
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
    /// Set when the person picked (or finished downloading) a model other than the one Pie booted with:
    /// Pie loads one model per launch, so the current one keeps talking and the new one takes over next launch.
    private(set) var pendingSwitch: ModelSpec?
    let downloader = ModelDownloader()
    /// Models whose files are on this phone (catalog models, plus a `-HearthModel` file).
    private(set) var installedModels: [ModelSpec] = ModelCatalog.installedSpecs()

    @ObservationIgnored private var engine: (any LanguageEngine)?
    /// The last queued operation. Loads and generations run strictly one after another.
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var queuedRequests = 0
    @ObservationIgnored private var cancelEpoch = 0
    /// The conversation of the last reply (callers tell the engine when it goes idle).
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
    /// preference, an installed Hearth model (never on the Simulator), else `.needsModel`.
    func start(preferredEngineID: String?) async {
        self.preferredEngineID = preferredEngineID
        installedModels = ModelCatalog.installedSpecs()
        let choice = choose(preferred: preferredEngineID)

        if case .pie(let spec, _) = choice, let crashed = UserDefaults.standard.string(forKey: Self.loadingMarkerKey) {
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

    /// Switches to a ModelSpec id or "mock". Unknown or unavailable ids leave the current engine alone.
    /// Pie boots once per app launch with one model, so switching between two models takes a relaunch:
    /// the choice is saved and the engine says so.
    func switchTo(engineID: String) async {
        installedModels = ModelCatalog.installedSpecs()
        let choice: Choice
        switch engineID {
        case "mock":
            choice = .mock
        default:
            guard let pie = pieChoice(id: engineID) else {
                HearthLog.error("engine", "switch to \(engineID) ignored: not installed or can't run here")
                return
            }
            choice = pie
        }
        preferredEngineID = engineID
        if active?.id == engineID, state == .ready { return }
        cancel()
        await perform { await self.activate(choice) }
    }

    private enum Choice {
        case pie(ModelSpec, URL)
        case mock
        case needsModel

        var engineID: String? {
            switch self {
            case .pie(let spec, _): return spec.id
            case .mock: return "mock"
            case .needsModel: return nil
            }
        }
    }

    private func choose(preferred: String?) -> Choice {
        switch LaunchOptions.shared.engine?.lowercased() {
        case "mock"?: return .mock
        case "pie"?: return firstPie(preferred: preferred) ?? .needsModel
        default: break
        }
        if let override = launchModelChoice() { return override }
        if let preferred {
            if preferred == "mock" { return .mock }
            if let choice = pieChoice(id: preferred) { return choice }
        }
        if let choice = firstPie(preferred: nil) { return choice }
        return .needsModel
    }

    /// Pie's Metal engine runs on a real iPhone; the Simulator links a stub, so models never load there.
    static var pieCanRun: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    /// An installed Hearth model this build can run.
    private func pieChoice(id: String) -> Choice? {
        guard Self.pieCanRun, let spec = ModelCatalog.spec(id: id), let url = ModelCatalog.installedURL(for: spec) else { return nil }
        return .pie(spec, url)
    }

    private func launchModelChoice() -> Choice? {
        guard Self.pieCanRun, let override = ModelCatalog.launchOverride() else { return nil }
        return .pie(override.spec, override.url)
    }

    /// The `-HearthModel` file, else the preferred model, else the recommended installed one, else any installed.
    private func firstPie(preferred: String?) -> Choice? {
        if let override = launchModelChoice() { return override }
        if let preferred, let choice = pieChoice(id: preferred) { return choice }
        let installed = ModelCatalog.all.filter { ModelCatalog.installedURL(for: $0) != nil }
        guard let pick = installed.first(where: \.recommended) ?? installed.first else { return nil }
        return pieChoice(id: pick.id)
    }

    private func activate(_ choice: Choice) async {
        if let id = choice.engineID, active?.id == id, state == .ready { return } // already running it
        if case .pie(let spec, _) = choice, let booted = await PieRuntime.shared.bootedModelID, booted != spec.id {
            // Pie already holds another model in this launch and can't load a second one. Keep the one that
            // works (the choice is saved, so it takes over next launch) instead of leaving the town silent.
            pendingSwitch = spec
            HearthLog.info("engine", "\(spec.id) takes over at the next launch (Pie is running \(booted))")
            if engine == nil {
                // Nothing is answering (for example the model in use was just deleted): reattach to the model
                // Pie still holds in memory. Its file isn't read again once Pie has booted.
                if let running = ModelCatalog.spec(id: booted) ?? ModelCatalog.launchOverride()?.spec {
                    let pie = PieEngine(spec: running, modelURL: ModelCatalog.installedURL(for: running) ?? URL(fileURLWithPath: "/"))
                    if (try? await pie.prepare()) != nil {
                        install(pie)
                        return
                    }
                }
                state = .failed("Close and reopen Hearth to start \(spec.displayName). Pie loads one model each time Hearth starts.")
            }
            return
        }
        if case .pie(let spec, _) = choice, pendingSwitch?.id == spec.id { pendingSwitch = nil }
        await deactivate(park: true)
        switch choice {
        case .needsModel:
            state = .needsModel
        case .mock:
            install(MockEngine())
        case .pie(let spec, let url):
            state = .loading("Loading \(spec.displayName)")
            UserDefaults.standard.set(spec.id, forKey: Self.loadingMarkerKey)
            let pie = PieEngine(spec: spec, modelURL: url)
            do {
                try await pie.prepare()
                UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey)
                install(pie)
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.loadingMarkerKey)
                HearthLog.error("engine", "\(spec.id) failed to load")
                state = .failed(error.localizedDescription)
            }
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
        // A model the person just downloaded replaces the download screen or the demo replies, or the model
        // in use when it's the one they picked. It queues behind any reply in progress and any waiting (no
        // cancel, unlike switchTo), so a finished download never cuts a reply off.
        let preferred = preferredEngineIDProvider?() ?? preferredEngineID
        guard LaunchOptions.shared.engine == nil,
              state == .needsModel || active?.id == "mock" || preferred == spec.id,
              active?.id != spec.id,
              let choice = pieChoice(id: spec.id) else { return }
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

    // MARK: - Conversations and models

    /// Going to the background: Pie keeps and evicts KV on its own, so there is nothing to save, but this
    /// waits until the reply that was just stopped has finished and been stored, so the caller's flush that
    /// follows includes it.
    func parkCurrent() async {
        await perform {}
    }

    /// Same as above, for one conversation (switching chats): nothing to do with Pie.
    func park(conversationKey: String) async {}

    /// A chat was deleted: forget it here. Pie's cached pages for it are just unused pages to Pie and age out.
    func forget(conversationKey: String) async {
        if lastConversationKey == conversationKey { lastConversationKey = nil }
    }

    /// Deletes a downloaded model, then falls back to another engine. Pie can't unload the model it booted
    /// with, so deleting the one in use takes effect fully at the next launch.
    func deleteModel(_ spec: ModelSpec) async {
        if active?.id == spec.id {
            cancel()
            await perform { await self.deactivate(park: false) }
        }
        downloader.delete(spec)
        installedModels = ModelCatalog.installedSpecs()
        if engine == nil {
            await start(preferredEngineID: preferredEngineID == spec.id ? nil : preferredEngineID)
        }
    }

    // MARK: - Photos

    /// One or two sentences about a photo the person sent, from the loaded model's own vision (Pie's caption
    /// mode). Nil when the model has no vision (Hearth Standard), when no model is ready, or when it fails:
    /// the caller then keeps the on-device Vision labels. Runs in the same queue as replies.
    func describePhoto(_ jpeg: Data) async -> String? {
        guard let pie = engine as? PieEngine, pie.spec.vision, state == .ready else { return nil }
        var caption: String?
        await perform { caption = await pie.describePhoto(jpeg) }
        return caption
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
