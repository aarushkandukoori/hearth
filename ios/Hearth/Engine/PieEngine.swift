// PieEngine: Hearth's characters run on Pie (github.com/pie-project/pie), in-process on the iPhone's GPU
// through Pie's Swift package. Every reply is one launch of Hearth's inferlet (Resources/Pie/hearth.wasm,
// source in /inferlet), which renders the chat with the model's own template, samples on the device and
// streams the reply back piece by piece.
//
// The inferlet ends its prefill with a recurrent-state checkpoint, so when Pie still holds it the next turn
// maps the earlier turns back in and reads only what is new (measured once on the iPhone: about 0.2 s to the
// first word instead of about 4 s). Pie drops a kept checkpoint whenever a live write needs its state slot,
// so on the phone that reuse is intermittent today; the inferlet reports how many tokens were reused. Pie
// boots once per process with one model, so switching models needs a relaunch.

import Foundation
import ImageIO
import PieServer

final class PieEngine: LanguageEngine, @unchecked Sendable {
    let spec: ModelSpec
    let modelURL: URL
    let descriptor: EngineDescriptor

    private let lock = NSLock()
    private var running: [Int: PieProcess] = [:]
    private var lastIssued = 0
    private var cancelledThrough = 0

    init(spec: ModelSpec, modelURL: URL) {
        self.spec = spec
        self.modelURL = modelURL
        descriptor = EngineDescriptor(id: spec.id, displayName: spec.displayName,
                                      modelName: spec.modelName,
                                      contextLength: spec.contextLength, supportsKVPersistence: false)
    }

    // MARK: - LanguageEngine

    func prepare() async throws {
        _ = try await PieRuntime.shared.ready(spec: spec, modelURL: modelURL)
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let id = lock.withLock { () -> Int in lastIssued += 1; return lastIssued }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let stats = try await run(request, id: id) { continuation.yield(.token($0)) }
                    continuation.yield(.done(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    task.cancel()
                    self?.terminate(id: id)
                }
            }
        }
    }

    /// Stops the running reply (and any already queued) right away. The stream still ends with
    /// `.done(stats)` and `stats.stoppedBy == "cancelled"`; the text so far stays valid.
    func cancelCurrent() {
        let ids = lock.withLock { () -> [Int] in
            cancelledThrough = lastIssued
            return Array(running.keys)
        }
        ids.forEach(terminate(id:))
    }

    func countTokens(_ text: String) async -> Int {
        // Qwen's tokenizer averages a little under 4 bytes of English per token.
        Int((Double(text.utf8.count) / 3.6).rounded(.up))
    }

    /// Pie's runtime keeps and evicts KV itself (its memory governor and cache tiers), so there is nothing
    /// for Hearth to park. Pie's durable snapshots exist, but save recurrent state on CUDA only for now.
    func park(conversationKey: String) async {}
    func purgeParkedState() async {}

    /// The runtime boots once per process and cannot be restarted, so it stays up; only replies stop.
    func shutdown() async {
        cancelCurrent()
    }

    // MARK: - One reply

    private func run(_ request: GenerationRequest, id: Int, emit: @escaping (String) -> Void) async throws -> GenerationStats {
        let started = Date()
        var stats = GenerationStats(engine: descriptor.id)
        if isCancelled(id) {
            stats.stoppedBy = "cancelled"
            return stats
        }
        let pie = try await PieRuntime.shared.ready(spec: spec, modelURL: modelURL)
        let input = InferletInput(request)
        if input.estimatedTokens + request.maxTokens > spec.contextLength { throw EngineError.contextOverflow }

        let process: PieProcess
        do {
            process = try await pie.client.launch(pie.program, json: try JSONEncoder.pie.encode(input))
        } catch {
            HearthLog.error("pie", "launch failed: \(error.localizedDescription)")
            throw EngineError.unavailable("Pie couldn't start the reply. Please try again.")
        }
        lock.withLock { running[id] = process }
        defer { lock.withLock { _ = running.removeValue(forKey: id) } }
        if isCancelled(id) { terminate(id: id) }

        var output: InferletOutput?
        var streamed = 0
        do {
            for try await event in process.events {
                switch event {
                case .message(let piece):
                    streamed += 1
                    if streamed == 1 { stats.timeToFirstToken = Date().timeIntervalSince(started) }
                    emit(piece)
                case .returned(let json):
                    do {
                        output = try JSONDecoder.pie.decode(InferletOutput.self, from: Data(json.utf8))
                    } catch {
                        // Never log the JSON itself: it carries the reply text.
                        HearthLog.error("pie", "couldn't read the inferlet's stats (\(json.utf8.count) bytes): \(error.localizedDescription)")
                    }
                case .stderr(let line):
                    HearthLog.debug("pie", "inferlet: " + line.trimmingCharacters(in: .whitespacesAndNewlines))
                case .stdout, .file:
                    break
                }
            }
        } catch where isCancelled(id) || Task.isCancelled {
            stats.stoppedBy = "cancelled" // the words so far stand
            return stats
        } catch {
            let reason = (error as? PieError)?.errorDescription ?? error.localizedDescription
            HearthLog.error("pie", "reply failed: \(reason)")
            if reason.contains("max_model_len") || reason.contains("one sequence holds") { throw EngineError.contextOverflow }
            throw EngineError.unavailable("The reply stopped unexpectedly. Please try again.")
        }

        guard let output else {
            HearthLog.error("pie", "reply ended without stats after \(streamed) piece(s)\(isCancelled(id) ? " (cancelled)" : "")")
            stats.stoppedBy = isCancelled(id) ? "cancelled" : "eos"
            return stats
        }
        stats.promptTokens = output.promptTokens
        stats.reusedTokens = output.reusedTokens
        stats.prefilledTokens = output.prefilledTokens
        stats.generatedTokens = output.generatedTokens
        // Pie's own clock: from the inferlet's start to the first sampled token.
        stats.timeToFirstToken = output.ttftMs / 1000
        stats.prefillTokensPerSecond = output.prefillMs > 0 ? Double(output.prefilledTokens) / (output.prefillMs / 1000) : 0
        stats.decodeTokensPerSecond = output.decodeTokensPerSecond
        stats.stoppedBy = output.stoppedBy == "max_tokens" ? "maxTokens" : output.stoppedBy
        HearthLog.info("pie", String(format: "reply: prompt %d (reused %d, new %d), %d tokens, ttft %.0f ms, decode %.1f tok/s, stop %@",
                                     stats.promptTokens, stats.reusedTokens, stats.prefilledTokens, stats.generatedTokens,
                                     output.ttftMs, stats.decodeTokensPerSecond, stats.stoppedBy))
        return stats
    }

    // MARK: - Photos

    /// One or two plain sentences about a photo, from the model's vision tower (Hearth Lite). Nil if the model
    /// has no vision or the caption fails; the caller keeps its on-device labels then.
    func describePhoto(_ jpeg: Data) async -> String? {
        guard spec.vision, let small = Self.captionJPEG(jpeg) else { return nil }
        do {
            let pie = try await PieRuntime.shared.ready(spec: spec, modelURL: modelURL)
            let input = CaptionInput(imageB64: small.base64EncodedString())
            let process = try await pie.client.launch(pie.program, json: try JSONEncoder.pie.encode(input))
            let json = try await process.result()
            let out = try JSONDecoder.pie.decode(InferletOutput.self, from: Data(json.utf8))
            let caption = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            HearthLog.info("pie", String(format: "described a photo: %d prompt tokens, %.0f ms", out.promptTokens, out.ttftMs + out.decodeMs))
            return caption.isEmpty ? nil : caption
        } catch {
            HearthLog.error("pie", "photo caption failed: \((error as? PieError)?.errorDescription ?? error.localizedDescription)")
            return nil
        }
    }

    /// The photo shrunk so it fits Pie's vision pass, as a JPEG. Pie's vision tower takes at most 512 patch
    /// rows of 16x16 pixels in one fire, and can't cut a picture across fires (measured on the iPhone: a
    /// 608 px picture made 1,444 rows and was refused), so the picture keeps at most `maxPatches` patches:
    /// about 335 x 335 px for a square photo. The tower then merges 2x2 patches, so the language model reads
    /// about a quarter as many rows.
    static func captionJPEG(_ data: Data, maxPatches: Int = 440) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        let scale = min(1, (Double(maxPatches) * 16 * 16 / Double(w * h)).squareRoot())
        let side = max(64, Int((Double(max(w, h)) * scale).rounded(.down)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return MediaFiles.jpegData(image, quality: 0.85)
    }

    private func terminate(id: Int) {
        guard let process = lock.withLock({ running[id] }) else { return }
        Task { try? await process.terminate() }
    }

    private func isCancelled(_ id: Int) -> Bool {
        lock.withLock { id <= cancelledThrough }
    }
}

// MARK: - The one Pie runtime in this process

/// Pie's server, the client session and the installed inferlet. Pie boots once per process with one model.
actor PieRuntime {
    static let shared = PieRuntime()

    struct Ready: Sendable {
        let server: PieServer
        let client: PieClient
        /// "hearth@0.1.0", what `launch` takes.
        let program: String
        let modelID: String
    }

    private var ready: Ready?
    /// Kept once `PieServer.start` succeeds: the runtime can't start twice in a process, so a later step
    /// that failed (installing the inferlet, connecting) is retried on this same server.
    private var server: (value: PieServer, modelID: String)?
    private var booting: (task: Task<Ready, Error>, modelID: String)?

    /// The id of the model Pie booted with, if it has.
    var bootedModelID: String? { server?.modelID ?? booting?.modelID }

    func ready(spec: ModelSpec, modelURL: URL) async throws -> Ready {
        if let booted = bootedModelID, booted != spec.id {
            throw EngineError.unavailable("Close and reopen Hearth to finish switching to \(spec.displayName). Pie loads one model each time Hearth starts.")
        }
        if let ready { return ready }
        if let booting { return try await booting.task.value }
        let existing = server?.value
        let task = Task { try await Self.boot(spec: spec, modelURL: modelURL, existing: existing) }
        booting = (task, spec.id)
        defer { booting = nil }
        let value = try await task.value
        ready = value
        return value
    }

    private func started(_ server: PieServer, modelID: String) {
        self.server = (server, modelID)
    }

    private static func boot(spec: ModelSpec, modelURL: URL, existing: PieServer?) async throws -> Ready {
        let started = Date()
        guard let wasm = Bundle.main.url(forResource: "hearth", withExtension: "wasm", subdirectory: "Pie")
                ?? Bundle.main.url(forResource: "hearth", withExtension: "wasm") else {
            throw EngineError.loadFailed("Hearth's inferlet is missing from the app.")
        }
        do {
            let server: PieServer
            if let existing {
                server = existing
            } else {
                // Model files must stay readable while the phone is locked.
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: modelURL.path)
                if LaunchOptions.shared.verbose {
                    // Developer runs: Pie's own debug lines for its KV cache (kept checkpoints, attaches), or any
                    // filter given with -HearthPieLog; -HearthPieTrace 1000 prints the pools every second.
                    setenv("RUST_LOG", UserDefaults.standard.string(forKey: "HearthPieLog") ?? "warn,pie::kv=debug", 1)
                    if let trace = UserDefaults.standard.string(forKey: "HearthPieTrace") {
                        setenv("PIE_CONTENTION_TRACE_MS", trace, 1)
                    }
                }
                server = try await PieServer.start(model: modelURL, configuration: phoneConfiguration(spec), home: HearthPaths.pieHome)
                await PieRuntime.shared.started(server, modelID: spec.id)
            }
            let program = try await server.install(contentsOf: wasm)
            let client = try await server.connect()
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let s = server.summary
            let c = phoneConfiguration(spec)
            HearthLog.info("pie", "booted \(s.deployment) in \(ms) ms: weights \(s.weightBytes / 1_048_576) MiB, kv pages \(s.kvPages) x \(s.kvPageSize), lanes \(s.maxLanes), program \(program); config kv \(c.deviceKvBudget ?? "auto"), slots \(c.maxStateSlots), processes \(c.maxConcurrentProcesses.map(String.init) ?? "-"), sandbox \(c.sandboxMemoryMB) MB")
            return Ready(server: server, client: client, program: program, modelID: spec.id)
        } catch {
            let reason = (error as? PieError)?.errorDescription ?? error.localizedDescription
            HearthLog.error("pie", "boot failed: \(reason)")
            throw EngineError.loadFailed("Pie couldn't start \(spec.displayName) on this iPhone. Closing other apps and reopening Hearth can help.")
        }
    }

    /// Sized for an iPhone. Pie sizes its KV and state pools from Metal's working-set hint, which on a phone
    /// is far more than iOS lets one app use (the app was killed at about 2.8 GB), so the budget is stated.
    /// It holds both the recurrent-state slots (about 24 MB each for Qwen3.5 2B) and the KV pages: 8 slots and
    /// 512 MiB leave room for one 4,096-token reply plus some of the recent chats. Two lanes: Hearth runs one
    /// reply at a time (plus, on Lite, a photo caption), and fewer lanes mean smaller per-lane buffers.
    /// This build of Pie carries ios/scripts/pie-ios-fixes.patch: without it, 16 or fewer slots never work
    /// (the slot commit rounds past its reservation), and a stated budget can leave no contiguous 2 GiB for
    /// the growth reservation wasmtime makes for every inferlet instance.
    static func phoneConfiguration(_ spec: ModelSpec) -> PieServer.Configuration {
        var c = PieServer.Configuration()
        c.maxModelLength = spec.contextLength
        c.maxForwardTokens = 512
        c.maxForwardRequests = 2
        c.maxStateSlots = 8
        c.deviceKvBudget = "512MiB"
        c.sandboxMemoryMB = 128
        // Not lower: Pie sizes its wasm instance pool from this, a component needs several instances, and when
        // the pool runs out wasmtime falls back to a 2 GiB reservation that iOS refuses.
        c.maxConcurrentProcesses = 4
        // Developer runs can override these with launch arguments, e.g. -HearthPieKV 768 (MiB, or "auto" to
        // leave the budget to Pie) -HearthPieSlots 33 -HearthPieLanes 4 -HearthPieProcesses 4.
        let defaults = UserDefaults.standard
        if let kv = defaults.string(forKey: "HearthPieKV") {
            if kv == "auto" { c.deviceKvBudget = nil } else if let mib = Int(kv), mib > 0 { c.deviceKvBudget = "\(mib)MiB" }
        }
        if case let n = defaults.integer(forKey: "HearthPieSlots"), n > 0 { c.maxStateSlots = n }
        if case let n = defaults.integer(forKey: "HearthPieLanes"), n > 0 { c.maxForwardRequests = n }
        if case let n = defaults.integer(forKey: "HearthPieProcesses"), n > 0 { c.maxConcurrentProcesses = n }
        if case let n = defaults.integer(forKey: "HearthPieSandboxMB"), n > 0 { c.sandboxMemoryMB = n }
        return c
    }
}

// MARK: - What crosses into the inferlet

/// Hearth's inferlet input (see inferlet/src/lib.rs). Keys are snake_case.
struct InferletInput: Encodable {
    struct Turn: Encodable {
        var role: String
        var content: String
    }

    var turns: [Turn]
    var prefix: String?
    var opener: String?
    var maxTokens: Int
    var stop: [String]
    var temperature: Float
    var topP: Float
    var topK: Int32
    var minP: Float
    var repeatPenalty: Float
    var seed: UInt32?

    init(_ request: GenerationRequest) {
        turns = request.turns.map { Turn(role: $0.role.rawValue, content: $0.content) }
        prefix = request.assistantPrefix
        opener = request.replyOpener
        maxTokens = request.maxTokens
        stop = request.stop
        temperature = request.sampling.temperature
        topP = request.sampling.topP
        topK = request.sampling.topK
        minP = request.sampling.minP
        repeatPenalty = request.sampling.repeatPenalty
        seed = request.sampling.seed
    }

    /// A rough prompt size, to refuse chats past the model's window before launching.
    var estimatedTokens: Int {
        turns.reduce(0) { $0 + Int((Double($1.content.utf8.count) / 3.6).rounded(.up)) + 6 }
    }
}

/// Caption mode's input: the photo as base64 JPEG.
struct CaptionInput: Encodable {
    var mode = "caption"
    var imageB64: String
    var maxTokens = 80
}

struct InferletOutput: Decodable {
    var text: String
    var promptTokens: Int
    var reusedTokens: Int
    var prefilledTokens: Int
    var generatedTokens: Int
    var stoppedBy: String
    var ttftMs: Double
    var prefillMs: Double
    var decodeMs: Double
    var decodeTokensPerSecond: Double
}

extension JSONEncoder {
    static var pie: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

extension JSONDecoder {
    static var pie: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
