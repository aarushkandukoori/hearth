// ModelDownloader: fetches a model once with a background URLSession (it resumes after drops), checks free
// space first and the SHA-256 after, then moves it into Application Support/Hearth/models.
// This is the only network traffic Hearth ever makes.

import CryptoKit
import Foundation
import Observation

@MainActor @Observable final class ModelDownloader {
    enum State: Equatable {
        case idle
        case downloading(fraction: Double, bytes: Int64, total: Int64)
        case verifying
        case installed
        case failed(String)
    }

    nonisolated static let sessionIdentifier = "com.aarushkandukoori.hearth.models"
    /// Privacy audit counter: every byte Hearth has ever downloaded (bytes uploaded are always 0).
    nonisolated static let downloadedBytesKey = "hearth.network.downloadedBytes"
    nonisolated static let activeKey = "hearth.downloads.active"
    /// Room to leave free on the phone beyond the model itself.
    nonisolated static let spareBytes: Int64 = 500 * 1_048_576

    /// Per-model state, keyed by ModelSpec.id. Missing means idle.
    private(set) var states: [String: State] = [:]
    /// Called after a model is downloaded and verified.
    @ObservationIgnored var onInstalled: ((ModelSpec) -> Void)?

    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var unsavedBytes: Int64 = 0
    /// When each download's progress was last published (SwiftUI only needs a few updates a second).
    @ObservationIgnored private var lastProgressAt: [String: Date] = [:]

    init() {
        refreshInstalled()
        verifyStagedFiles()
        if !Self.activeIDs.isEmpty { reconnect() }
    }

    func state(for spec: ModelSpec) -> State { states[spec.id] ?? .idle }

    /// Total bytes downloaded by Hearth so far (for the privacy screen).
    nonisolated static var totalDownloadedBytes: Int64 {
        (UserDefaults.standard.object(forKey: downloadedBytesKey) as? NSNumber)?.int64Value ?? 0
    }

    /// `allowsCellular` is true only after the person chose "Download now" on cellular data. Otherwise a new
    /// download waits for Wi-Fi instead of quietly moving onto mobile data later. (A download resumed from
    /// saved data keeps the setting it started with.)
    func start(_ spec: ModelSpec, allowsCellular: Bool = false) {
        switch state(for: spec) {
        case .downloading, .verifying: return
        default: break
        }
        if ModelCatalog.installedURL(for: spec) != nil {
            states[spec.id] = .installed
            return
        }
        let needed = spec.bytes + Self.spareBytes
        if let free = Self.freeBytes(), free < needed {
            states[spec.id] = .failed("This download needs about \(Self.format(needed)) of free space. Your iPhone has \(Self.format(free)) free right now.")
            return
        }
        let session = Self.session(owner: self)
        let task: URLSessionDownloadTask
        var saved = Self.loadResumeData(spec)
        // Saved progress keeps the network rule its download started with (older saves allowed cellular),
        // so when the person's choice is different the download starts over under the new rule.
        if saved != nil, (UserDefaults.standard.object(forKey: Self.cellularKey(spec)) as? Bool ?? true) != allowsCellular {
            Self.deleteResumeData(spec)
            saved = nil
            HearthLog.info("download", "cellular choice changed for \(spec.id); starting over")
        }
        UserDefaults.standard.set(allowsCellular, forKey: Self.cellularKey(spec))
        if let resume = saved {
            task = session.downloadTask(withResumeData: resume)
        } else {
            var request = URLRequest(url: spec.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.allowsExpensiveNetworkAccess = allowsCellular
            request.allowsConstrainedNetworkAccess = allowsCellular
            task = session.downloadTask(with: request)
        }
        Self.deleteResumeData(spec)
        task.taskDescription = spec.id
        task.countOfBytesClientExpectsToReceive = spec.bytes
        tasks[spec.id] = task
        Self.activeIDs.insert(spec.id)
        states[spec.id] = .downloading(fraction: 0, bytes: 0, total: spec.bytes)
        HearthLog.info("download", "started \(spec.id)")
        task.resume()
    }

    /// Stops a download but keeps what arrived, so `start` picks up where it left off.
    func cancel(_ spec: ModelSpec) {
        guard let task = tasks.removeValue(forKey: spec.id) else { return }
        Self.activeIDs.remove(spec.id)
        states[spec.id] = .idle
        task.cancel(byProducingResumeData: { data in
            if let data { Self.saveResumeData(data, for: spec) }
        })
        flushBytes()
    }

    /// Removes the model from the phone (including a copy pushed into Documents) and any partial download.
    func delete(_ spec: ModelSpec) {
        if let task = tasks.removeValue(forKey: spec.id) { task.cancel() }
        Self.activeIDs.remove(spec.id)
        let fm = FileManager.default
        for url in [HearthPaths.models.appendingPathComponent(spec.fileName),
                    HearthPaths.documents.appendingPathComponent(spec.fileName),
                    Self.stagingURL(for: spec)] {
            try? fm.removeItem(at: url)
        }
        Self.deleteResumeData(spec)
        states[spec.id] = .idle
        HearthLog.info("download", "deleted \(spec.id)")
    }

    /// Hook for the app delegate's application(_:handleEventsForBackgroundURLSession:completionHandler:).
    /// Returns false when the session isn't Hearth's (call the completion yourself then).
    @discardableResult
    static func handleEventsForBackgroundURLSession(identifier: String, completion: @escaping () -> Void) -> Bool {
        guard identifier == sessionIdentifier else { return false }
        backgroundCompletion = completion
        _ = session(owner: nil) // reattach so the system can deliver the finished download
        return true
    }

    // MARK: - Session events (main actor)

    fileprivate func progress(id: String, delta: Int64, written: Int64, expected: Int64) {
        unsavedBytes += delta
        if unsavedBytes >= 16 * 1_048_576 { flushBytes() }
        let now = Date()
        if let last = lastProgressAt[id], now.timeIntervalSince(last) < 0.25, written < expected { return }
        lastProgressAt[id] = now
        let total = expected > 0 ? expected : (ModelCatalog.spec(id: id)?.bytes ?? 0)
        states[id] = .downloading(fraction: total > 0 ? min(1, Double(written) / Double(total)) : 0, bytes: written, total: total)
    }

    fileprivate func downloaded(_ spec: ModelSpec, problem: String?) {
        tasks[spec.id] = nil
        flushBytes()
        if let problem {
            Self.activeIDs.remove(spec.id)
            states[spec.id] = .failed(problem)
            HearthLog.error("download", "\(spec.id) failed after download")
            return
        }
        verify(spec)
    }

    fileprivate func failed(id: String, resumeData: Data?, cancelled: Bool) {
        tasks[id] = nil
        flushBytes()
        guard let spec = ModelCatalog.spec(id: id) else { return }
        if let resumeData { Self.saveResumeData(resumeData, for: spec) }
        if cancelled { return } // cancel() already set the state
        Self.activeIDs.remove(id)
        states[id] = .failed(resumeData == nil
            ? "The download stopped. Please try again."
            : "The connection dropped. Try again to pick up where it left off.")
        HearthLog.error("download", "\(spec.id) stopped (resumable: \(resumeData != nil))")
    }

    private func verify(_ spec: ModelSpec) {
        states[spec.id] = .verifying
        Task.detached(priority: .utility) {
            let problem = Self.verifyAndInstall(spec)
            await MainActor.run { self.installFinished(spec, problem: problem) }
        }
    }

    private func installFinished(_ spec: ModelSpec, problem: String?) {
        Self.activeIDs.remove(spec.id)
        if let problem {
            states[spec.id] = .failed(problem)
            HearthLog.error("download", "\(spec.id) did not verify")
            return
        }
        states[spec.id] = .installed
        HearthLog.info("download", "installed \(spec.id)")
        onInstalled?(spec)
    }

    private func refreshInstalled() {
        for spec in ModelCatalog.all {
            switch states[spec.id] {
            case .downloading?, .verifying?: continue
            default: states[spec.id] = ModelCatalog.installedURL(for: spec) != nil ? .installed : .idle
            }
        }
    }

    /// A download that finished while Hearth wasn't around to check it gets checked now.
    private func verifyStagedFiles() {
        for spec in ModelCatalog.all where ModelCatalog.installedURL(for: spec) == nil
            && FileManager.default.fileExists(atPath: Self.stagingURL(for: spec).path) {
            verify(spec)
        }
    }

    /// Re-attaches to downloads that kept going while Hearth was closed.
    private func reconnect() {
        Self.session(owner: self).getAllTasks { all in
            let found = all.compactMap { $0 as? URLSessionDownloadTask }
            Task { @MainActor in self.adopt(found) }
        }
    }

    private func adopt(_ found: [URLSessionDownloadTask]) {
        for task in found {
            guard let id = task.taskDescription, ModelCatalog.spec(id: id) != nil else { continue }
            tasks[id] = task
            progress(id: id, delta: 0, written: task.countOfBytesReceived, expected: task.countOfBytesExpectedToReceive)
        }
        for id in Self.activeIDs where tasks[id] == nil && states[id] != .verifying {
            Self.activeIDs.remove(id) // nothing left running for it
        }
    }

    private func flushBytes() {
        guard unsavedBytes > 0 else { return }
        UserDefaults.standard.set(NSNumber(value: Self.totalDownloadedBytes + unsavedBytes), forKey: Self.downloadedBytesKey)
        unsavedBytes = 0
    }

    // MARK: - Files and helpers (any thread)

    nonisolated static func stagingURL(for spec: ModelSpec) -> URL {
        HearthPaths.models.appendingPathComponent(spec.fileName + ".download")
    }

    /// Whether the download now saved or running for `spec` may use cellular data.
    nonisolated private static func cellularKey(_ spec: ModelSpec) -> String { "hearth.download.cellular.\(spec.id)" }

    nonisolated private static func resumeURL(for spec: ModelSpec) -> URL {
        HearthPaths.state.appendingPathComponent("download-\(spec.id).resume")
    }

    nonisolated private static func saveResumeData(_ data: Data, for spec: ModelSpec) {
        try? HearthPaths.write(data, to: resumeURL(for: spec))
    }

    nonisolated private static func loadResumeData(_ spec: ModelSpec) -> Data? {
        try? Data(contentsOf: resumeURL(for: spec))
    }

    nonisolated private static func deleteResumeData(_ spec: ModelSpec) {
        try? FileManager.default.removeItem(at: resumeURL(for: spec))
    }

    nonisolated static var activeIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: activeKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: activeKey) }
    }

    nonisolated static func freeBytes() -> Int64? {
        let values = try? HearthPaths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Size check, then a streamed SHA-256 (8 MB at a time, never the whole file in memory), then move into place.
    /// Returns a message for the person if something is wrong, nil on success.
    nonisolated static func verifyAndInstall(_ spec: ModelSpec) -> String? {
        let fm = FileManager.default
        let staged = stagingURL(for: spec)
        guard ModelCatalog.fileSize(staged) == spec.bytes else {
            try? fm.removeItem(at: staged)
            return "The download was incomplete, so Hearth removed it. Please try again."
        }
        guard let digest = try? sha256Hex(of: staged), digest == spec.sha256.lowercased() else {
            try? fm.removeItem(at: staged)
            return "The download didn't match what Hearth expected, so it was removed. Please try again."
        }
        let final = HearthPaths.models.appendingPathComponent(spec.fileName)
        do {
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: staged, to: final)
        } catch {
            return "Hearth couldn't save the model. Please try again."
        }
        // Weights aren't private, and iOS must be able to page them in while the phone is locked.
        try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: final.path)
        HearthPaths.setExcludedFromBackup(true, at: final)
        HearthPaths.setExcludedFromBackup(true, at: HearthPaths.models)
        return nil
    }

    nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 * 1_048_576) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - The one background session

    private static var shared: (session: URLSession, delegate: DownloadDelegate)?
    private static var backgroundCompletion: (() -> Void)?

    private static func session(owner: ModelDownloader?) -> URLSession {
        if let shared {
            if let owner { shared.delegate.owner = owner }
            return shared.session
        }
        let delegate = DownloadDelegate()
        delegate.owner = owner
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        shared = (session, delegate)
        return session
    }

    fileprivate static func finishBackgroundEvents() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }
}

/// Receives URLSession callbacks on a background queue and hands them to the downloader on the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    @MainActor weak var owner: ModelDownloader?

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        Task { @MainActor in
            self.owner?.progress(id: id, delta: bytesWritten, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let spec = ModelCatalog.spec(id: id) else { return }
        // The system deletes `location` when this method returns, so move it right now.
        var problem: String?
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            problem = "The download server didn't send the model (error \(status)). Please try again later."
        } else {
            let staged = ModelDownloader.stagingURL(for: spec)
            do {
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.moveItem(at: location, to: staged)
            } catch {
                problem = "Hearth couldn't save the download. Please try again."
            }
        }
        Task { @MainActor in self.owner?.downloaded(spec, problem: problem) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // success was handled in didFinishDownloadingTo
        let id = task.taskDescription ?? ""
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        Task { @MainActor in self.owner?.failed(id: id, resumeData: resumeData, cancelled: cancelled) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in ModelDownloader.finishBackgroundEvents() }
    }
}
