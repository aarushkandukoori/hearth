// What onboarding and the Model page can do with the town's language model: use one, download one
// (Apple's model keeps the town talking meanwhile when there is one), switch once a download finishes,
// check for cellular data before a big download, and describe the engine and its license in words.

import Network
import SwiftUI

@MainActor
enum SettingsModelActions {
    /// Makes an installed model, "apple" or "mock" the person's choice and switches to it.
    /// Returns whether that engine is now the active one.
    @discardableResult
    static func use(_ engineID: String, app: AppModel) async -> Bool {
        app.settingsStore.update { $0.preferredEngineID = engineID }
        await app.engine.switchTo(engineID: engineID)
        return app.engine.active?.id == engineID
    }

    /// Starts (or resumes) a model download and remembers it as the person's choice. Until it is ready the
    /// town keeps talking with Apple's model when this iPhone has it; otherwise the chats say the model is on
    /// its way. Returns false when the download couldn't start (for example, not enough free space); the
    /// downloader's state says why.
    @discardableResult
    static func download(_ spec: ModelSpec, app: AppModel, allowsCellular: Bool = false) -> Bool {
        let downloader = app.engine.downloader
        downloader.start(spec, allowsCellular: allowsCellular)
        if case .failed = downloader.state(for: spec) { return false }
        app.settingsStore.update { $0.preferredEngineID = spec.id }
        switchWhenInstalled(spec, app: app)
        keepTownTalking(app: app)
        return true
    }

    /// When nothing can answer yet, use Apple's model if this iPhone has it. Never the canned demo replies:
    /// they can't read what someone writes, so the town waits for a real model instead (demo replies are only
    /// for `-HearthEngine mock`, screenshots and tests).
    static func keepTownTalking(app: AppModel) {
        guard app.engine.appleAvailable else { return }
        switch app.engine.state {
        case .needsModel, .failed:
            Task { await app.engine.switchTo(engineID: "apple") }
        default:
            break
        }
    }

    /// True when this iPhone is on cellular data, a hotspot or Low Data Mode right now, so a big download
    /// should ask first. Only looks at the network path; nothing is sent.
    static func onExpensiveNetwork() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = ResumeOnce()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                monitor.pathUpdateHandler = nil // lets the monitor go
                continuation.resume(returning: path.isExpensive || path.isConstrained)
            }
            monitor.start(queue: DispatchQueue(label: "hearth.network-check"))
        }
    }

    /// Watches any download that is already running (for example one that kept going while Hearth was closed).
    static func resumeWatching(app: AppModel) {
        for spec in ModelCatalog.all where isBusy(app.engine.downloader.state(for: spec)) {
            switchWhenInstalled(spec, app: app)
        }
    }

    /// Switches to the model when its download finishes, if it is still the person's choice. EngineHost does
    /// this on its own when nothing else could talk; this also covers moving over from Apple's model.
    /// A reply that is being written gets to finish first (switching would cut it off).
    static func switchWhenInstalled(_ spec: ModelSpec, app: AppModel) {
        guard watchers[spec.id] == nil else { return }
        watchers[spec.id] = Task {
            while isBusy(app.engine.downloader.state(for: spec)) {
                try? await Task.sleep(for: .seconds(1))
            }
            while app.engine.isGenerating {
                try? await Task.sleep(for: .seconds(1))
            }
            if app.engine.downloader.state(for: spec) == .installed,
               app.settings.preferredEngineID == spec.id,
               app.engine.active?.id != spec.id {
                await app.engine.switchTo(engineID: spec.id)
            }
            watchers[spec.id] = nil
        }
    }

    /// Pauses running downloads other than `keepID` (they keep what arrived and can resume later).
    static func pauseOtherDownloads(keeping keepID: String?, app: AppModel) {
        for spec in ModelCatalog.all where spec.id != keepID && isBusy(app.engine.downloader.state(for: spec)) {
            app.engine.downloader.cancel(spec)
        }
    }

    private static var watchers: [String: Task<Void, Never>] = [:]

    static func isBusy(_ state: ModelDownloader.State) -> Bool {
        switch state {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: Words for the UI

    static func isInstalled(_ spec: ModelSpec, app: AppModel) -> Bool {
        app.engine.installedModels.contains { $0.id == spec.id }
    }

    /// "Hearth Standard" for catalog models.
    static func title(_ spec: ModelSpec) -> String {
        "Hearth \(spec.shortName)"
    }

    /// "Llama 3.2 3B", taken from the display name "Hearth Standard (Llama 3.2 3B)".
    static func modelName(_ spec: ModelSpec) -> String {
        let name = spec.displayName
        guard let open = name.firstIndex(of: "("), let close = name.lastIndex(of: ")"), open < close else {
            return spec.family
        }
        return String(name[name.index(after: open)..<close])
    }

    /// What the town is talking with, in a few words: "Hearth Standard", "Apple Intelligence", "Demo replies".
    static func engineName(_ descriptor: EngineDescriptor?) -> String {
        guard let descriptor else { return "No model yet" }
        switch descriptor.id {
        case "apple": return "Apple Intelligence"
        case "mock": return "Demo replies"
        default: return ModelCatalog.spec(id: descriptor.id).map(title) ?? descriptor.displayName
        }
    }

    /// "Downloading Hearth Standard, 42%" (or "Checking Hearth Standard") while a model download runs, else nil.
    static func downloadLine(_ engine: EngineHost) -> String? {
        guard let spec = ModelCatalog.all.first(where: { isBusy(engine.downloader.state(for: $0)) }) else { return nil }
        if case .downloading(let fraction, _, _) = engine.downloader.state(for: spec) {
            return "Downloading \(title(spec)), \(Int(fraction * 100))%"
        }
        return "Checking \(title(spec))"
    }

    /// A short status for rows: the engine's name when ready, else what it is doing.
    static func statusLine(_ engine: EngineHost) -> String {
        if let download = downloadLine(engine) { return download }
        switch engine.state {
        case .idle: return "Starting up"
        case .needsModel: return "No model yet"
        case .loading: return "Getting ready"
        case .ready: return engineName(engine.active)
        case .failed: return "Needs a look"
        }
    }

    /// Rough memory check: iOS reports a little less than the label on the box, so allow some slack.
    static func fitsThisPhone(_ spec: ModelSpec) -> Bool {
        let gigabytes = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        return gigabytes + 0.75 >= spec.minimumMemoryGB
    }

    /// Where to read a model's license (and, for Llama, the Acceptable Use Policy it includes).
    static func licenseLinks(_ license: String) -> [LicenseLink] {
        let links: [(String, String)]
        if license.hasPrefix("Llama 3.2") {
            links = [("Llama 3.2 Community License", "https://www.llama.com/llama3_2/license/"),
                     ("Llama 3.2 Acceptable Use Policy", "https://www.llama.com/llama3_2/use-policy/")]
        } else if license.hasPrefix("Apache") {
            links = [("Apache License 2.0", "https://www.apache.org/licenses/LICENSE-2.0")]
        } else {
            links = []
        }
        return links.compactMap { title, link in URL(string: link).map { LicenseLink(title: title, url: $0) } }
    }
}

/// A license (or policy) by name, and where to read it.
struct LicenseLink: Identifiable, Hashable {
    let title: String
    let url: URL
    var id: URL { url }
}

/// Lets only the first network path update answer `onExpensiveNetwork` (more can arrive before cancel lands).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
