// LlamaEngine: runs a GGUF model on the phone with llama.cpp (Metal), one request at a time.
// It reuses the shared start of each prompt, parks a conversation's KV cache on flash when you switch
// away, and restores it when you come back, so returning to a chat does not re-read the whole thing.

#if canImport(llama)
import Foundation
import llama
#if os(iOS)
import os
#endif

final class LlamaEngine: LanguageEngine, @unchecked Sendable {
    let spec: ModelSpec
    let modelURL: URL
    let descriptor: EngineDescriptor
    /// Parked KV caches for this model.
    let parked: KVStateCache

    /// Every llama.cpp call happens on this one serial queue.
    private let queue = DispatchQueue(label: "com.aarushkandukoori.hearth.llama", qos: .userInitiated)

    // Owned by `queue`.
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var batch: llama_batch?
    private var batchCapacity = 512
    private var contextSize = 0
    private var chatTemplate: String?
    /// Qwen3 "thinking" models get an empty <think></think> block so they answer right away.
    private var skipsThinking = false
    /// Mirrors what sequence 0 of the KV cache holds right now.
    private var cachedTokens: [llama_token] = []
    /// Conversation whose tokens are in `cachedTokens`.
    private var currentKey: String?
    /// The tokens last written to (or read from) flash for `currentKey`, so leaving a chat twice doesn't
    /// write the same ~70 MB state twice.
    private var flashSnapshot: (key: String, tokens: [llama_token])?

    // Shared with other threads, guarded by `lock`.
    private let lock = NSLock()
    private var lastIssued = 0
    private var cancelledThrough = 0
    private var cancelledIDs: Set<Int> = []
    private var tokenizer: OpaquePointer?

    init(spec: ModelSpec, modelURL: URL, kvRoot: URL = HearthPaths.kvCache) {
        self.spec = spec
        self.modelURL = modelURL
        parked = KVStateCache(modelID: spec.id, root: kvRoot)
        descriptor = EngineDescriptor(id: spec.id, displayName: spec.displayName,
                                      modelName: (spec.fileName as NSString).deletingPathExtension,
                                      contextLength: spec.contextLength, supportsKVPersistence: true)
    }

    deinit {
        // Queued work holds `self` strongly, so nothing can still be running here.
        if let batch { llama_batch_free(batch) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    // MARK: - LanguageEngine

    func prepare() async throws {
        try await onQueue { try self.loadIfNeeded() }
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let id = lock.withLock { () -> Int in lastIssued += 1; return lastIssued }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel(id: id) }
            }
            queue.async { [self] in
                defer { lock.withLock { _ = cancelledIDs.remove(id) } }
                do {
                    let stats = try run(request, id: id) { continuation.yield(.token($0)) }
                    continuation.yield(.done(stats))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Stops the running request (and any already queued) within about one token. A cancelled stream
    /// still ends with `.done(stats)` and `stats.stoppedBy == "cancelled"`; the text so far stays valid.
    func cancelCurrent() {
        lock.withLock { cancelledThrough = lastIssued }
    }

    func countTokens(_ text: String) async -> Int {
        lock.withLock {
            guard let tokenizer else { return Int((Double(text.utf8.count) / 3.6).rounded(.up)) }
            return Self.tokenize(text, vocab: tokenizer, addSpecial: false).count
        }
    }

    func park(conversationKey: String) async {
        await onQueue {
            guard self.currentKey == conversationKey else { return }
            _ = self.parkNow(key: conversationKey)
        }
    }

    func purgeParkedState() async {
        await onQueue {
            self.parked.purge()
            // What's in memory may belong to a conversation that was just deleted: drop it too, so a later
            // park can't write it back to flash.
            self.clearMemory()
            self.currentKey = nil
        }
    }

    func shutdown() async {
        await onQueue {
            self.lock.withLock { self.tokenizer = nil }
            if let batch = self.batch { llama_batch_free(batch) }
            if let context = self.context { llama_free(context) }
            if let model = self.model { llama_model_free(model) }
            self.batch = nil
            self.context = nil
            self.model = nil
            self.vocab = nil
            self.cachedTokens = []
            self.flashSnapshot = nil
            self.currentKey = nil
            HearthLog.info("llama", "unloaded \(self.spec.id)")
        }
    }

    /// Drops a conversation from memory and flash (used when a chat is deleted).
    func forget(conversationKey: String) async {
        await onQueue {
            if self.currentKey == conversationKey {
                self.clearMemory()
                self.currentKey = nil
            }
            self.parked.remove(key: conversationKey)
        }
    }

    // MARK: - Loading

    private static let backendReady: Void = {
        llama_log_set({ level, text, _ in
            guard let text else { return }
            let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            if level == GGML_LOG_LEVEL_ERROR {
                HearthLog.error("llama.cpp", line)
            } else {
                HearthLog.debug("llama.cpp", line)
            }
        }, nil)
        llama_backend_init()
    }()

    private func loadIfNeeded() throws {
        if context != nil { return }
        _ = Self.backendReady
        let started = Date()
        logMemory("before load")
        // Model files are not private, and they must stay readable while the phone is locked
        // (iOS pages mmapped weights back in from the file at any time).
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                               ofItemAtPath: modelURL.path)

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP
        guard let loadedModel = llama_model_load_from_file(modelURL.path, modelParams) else {
            throw EngineError.loadFailed("the model file couldn't be read. Deleting and downloading it again can help.")
        }

        var params = llama_context_default_params()
        params.n_ctx = UInt32(spec.contextLength)
        params.n_batch = 512
        params.n_ubatch = 512
        params.n_seq_max = 1
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED
        params.type_k = GGML_TYPE_Q8_0
        params.type_v = GGML_TYPE_Q8_0
        var kvType = "q8_0"
        var loadedContext = llama_init_from_model(loadedModel, params)
        if loadedContext == nil {
            HearthLog.error("llama", "q8_0 KV with flash attention failed; retrying with f16")
            params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
            params.type_k = GGML_TYPE_F16
            params.type_v = GGML_TYPE_F16
            kvType = "f16"
            loadedContext = llama_init_from_model(loadedModel, params)
        }
        guard let context = loadedContext else {
            llama_model_free(loadedModel)
            throw EngineError.loadFailed("there wasn't enough free memory. Closing other apps or choosing Hearth Lite can help.")
        }

        let newBatch = llama_batch_init(512, 0, 1)
        guard newBatch.token != nil, newBatch.pos != nil, newBatch.n_seq_id != nil,
              newBatch.seq_id != nil, newBatch.logits != nil else {
            llama_free(context)
            llama_model_free(loadedModel)
            throw EngineError.loadFailed("there wasn't enough free memory.")
        }

        model = loadedModel
        self.context = context
        vocab = llama_model_get_vocab(loadedModel)
        batch = newBatch
        contextSize = Int(llama_n_ctx(context))
        batchCapacity = min(512, Int(llama_n_batch(context)))
        chatTemplate = llama_model_chat_template(loadedModel, nil).map { String(cString: $0) }
        skipsThinking = (chatTemplate?.contains("<think>") ?? false)
            && !spec.fileName.lowercased().contains("instruct-2507")
        lock.withLock { tokenizer = vocab }
        parked.sweep()

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        HearthLog.info("llama", "loaded \(spec.id) in \(ms) ms: ctx \(contextSize), kv \(kvType), batch \(batchCapacity), no-think \(skipsThinking)")
        logMemory("after load")
    }

    private func logMemory(_ label: String) {
        #if os(iOS)
        HearthLog.info("llama", "\(label): \(os_proc_available_memory() / 1_048_576) MB available to the app")
        #endif
    }

    // MARK: - One request

    private func run(_ request: GenerationRequest, id: Int, emit: (String) -> Void) throws -> GenerationStats {
        let started = Date()
        var stats = GenerationStats(engine: descriptor.id)
        try loadIfNeeded()
        guard let context, let vocab else { throw EngineError.modelMissing }
        if isCancelled(id) {
            stats.stoppedBy = "cancelled"
            return stats
        }

        // 1. The full prompt, as tokens.
        let tokens = Self.tokenize(try renderPrompt(request), vocab: vocab, addSpecial: true)
        stats.promptTokens = tokens.count
        guard !tokens.isEmpty else { throw EngineError.unavailable("There was nothing to reply to.") }
        if tokens.count + max(1, request.maxTokens) > contextSize { throw EngineError.contextOverflow }

        // 2. Switching conversations: park the old one on flash, then restore the new one if we have it.
        var restoredTokens = 0
        if currentKey != request.conversationKey {
            if let old = currentKey { stats.parkMilliseconds = parkNow(key: old) }
            clearMemory()
            currentKey = request.conversationKey
            if let restored = restoreNow(key: request.conversationKey) {
                stats.restoreMilliseconds = restored.milliseconds
                restoredTokens = restored.tokens
            }
        }

        // 3. Keep the longest shared start, drop the rest, and always recompute at least one token
        //    (the cache stores keys and values, not the logits we need to sample from).
        var keep = min(Self.commonPrefixLength(cachedTokens, tokens), tokens.count - 1)
        if keep < cachedTokens.count {
            if llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(keep), -1) {
                cachedTokens.removeSubrange(keep...)
            } else {
                clearMemory()
                keep = 0
            }
        }
        stats.reusedTokens = keep
        stats.prefilledTokens = tokens.count - keep
        stats.restoredFromDisk = restoredTokens > 0 && keep > 0

        // 4. Prefill whatever is new. A request stopped meanwhile ends as cancelled even if the GPU then refused
        //    work (iOS does that once Hearth is in the background).
        let prefillStarted = Date()
        do {
            guard try decode(tokens[keep...], context: context, id: id) else {
                stats.stoppedBy = "cancelled"
                return stats
            }
        } catch where isCancelled(id) {
            stats.stoppedBy = "cancelled"
            return stats
        }
        llama_synchronize(context) // Metal runs asynchronously; wait so the timing is real
        stats.prefillTokensPerSecond = Double(stats.prefilledTokens) / max(Date().timeIntervalSince(prefillStarted), 0.000_001)

        // 5. Sample until end of turn, a stop string, maxTokens, or cancel.
        guard let sampler = makeSampler(request.sampling, vocab: vocab) else {
            throw EngineError.unavailable("The model couldn't start replying. Try again.")
        }
        defer { llama_sampler_free(sampler) }
        var assembler = UTF8Assembler()
        var filter = StopFilter(request.stop)
        var firstTokenAt: Date?
        var lastTokenAt = Date()
        stats.stoppedBy = "maxTokens"
        while stats.generatedTokens < request.maxTokens {
            if isCancelled(id) {
                stats.stoppedBy = "cancelled"
                break
            }
            let token = llama_sampler_sample(sampler, context, -1)
            let now = Date()
            if firstTokenAt == nil {
                firstTokenAt = now
                stats.timeToFirstToken = now.timeIntervalSince(started)
            }
            if llama_vocab_is_eog(vocab, token) {
                stats.stoppedBy = "eos"
                break
            }
            stats.generatedTokens += 1
            lastTokenAt = now
            let text = assembler.append(Self.piece(token, vocab: vocab))
            if !text.isEmpty {
                let visible = filter.feed(text)
                if !visible.isEmpty { emit(visible) }
                if filter.stopped {
                    stats.stoppedBy = "stop"
                    break
                }
            }
            if stats.generatedTokens >= request.maxTokens { break } // no need to compute a token we won't use
            do {
                guard try decode(ArraySlice([token]), context: context, id: id, checkCancel: false) else { break }
            } catch where isCancelled(id) {
                stats.stoppedBy = "cancelled" // the words so far stand, as with any stop
                break
            }
        }
        let tail = filter.flush() // held-back text that never became a stop string
        if !tail.isEmpty { emit(tail) }
        if let firstTokenAt, stats.generatedTokens > 1 {
            stats.decodeTokensPerSecond = Double(stats.generatedTokens - 1) / max(lastTokenAt.timeIntervalSince(firstTokenAt), 0.000_001)
        }

        HearthLog.info("llama", String(format: "reply: prompt %d (reused %d, new %d%@), %d tokens, ttft %.0f ms, prefill %.0f tok/s, decode %.1f tok/s, stop %@",
                                       stats.promptTokens, stats.reusedTokens, stats.prefilledTokens,
                                       stats.restoredFromDisk ? ", restored" : "", stats.generatedTokens,
                                       stats.timeToFirstToken * 1000, stats.prefillTokensPerSecond,
                                       stats.decodeTokensPerSecond, stats.stoppedBy))
        return stats
    }

    /// Decodes `tokens` into sequence 0 in batches of up to 512; only the very last token gets logits.
    /// Returns false if the request was cancelled between batches.
    private func decode(_ tokens: ArraySlice<llama_token>, context: OpaquePointer, id: Int, checkCancel: Bool = true) throws -> Bool {
        guard var batch else { throw EngineError.modelMissing }
        var start = tokens.startIndex
        while start < tokens.endIndex {
            if checkCancel, isCancelled(id) { return false }
            let end = min(start + batchCapacity, tokens.endIndex)
            let position = cachedTokens.count
            batch.n_tokens = Int32(end - start)
            for (i, token) in tokens[start..<end].enumerated() {
                batch.token[i] = token
                batch.pos[i] = llama_pos(position + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]?[0] = 0
                batch.logits[i] = 0
            }
            if end == tokens.endIndex { batch.logits[end - start - 1] = 1 }
            let result = llama_decode(context, batch)
            guard result == 0 else {
                // Only this batch is lost (for example the GPU refused it because Hearth went to the background):
                // drop whatever it wrote and keep the chat before it, so the next reply needn't re-read it all.
                if !llama_memory_seq_rm(llama_get_memory(context), 0, llama_pos(cachedTokens.count), -1) { clearMemory() }
                HearthLog.error("llama", "decode failed with code \(result)")
                throw EngineError.unavailable("The model stopped unexpectedly. Please try again.")
            }
            cachedTokens.append(contentsOf: tokens[start..<end])
            start = end
        }
        return true
    }

    private func makeSampler(_ s: SamplingParams, vocab: OpaquePointer) -> UnsafeMutablePointer<llama_sampler>? {
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), s.repeatLastN, s.repeatPenalty, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(s.seed ?? LLAMA_DEFAULT_SEED))
        return chain
    }

    // MARK: - Park and restore

    /// Saves sequence 0 to flash under `key`. Returns the milliseconds it took, or nil if nothing was saved.
    private func parkNow(key: String) -> Double? {
        guard let context, !cachedTokens.isEmpty else { return nil }
        if let snapshot = flashSnapshot, snapshot.key == key, snapshot.tokens == cachedTokens, parked.entry(for: key) != nil {
            return nil // already on flash, unchanged since
        }
        let started = Date()
        parked.ensureFolder() // "Clear" or "Delete everything" may have removed it while this model stayed loaded
        let temporary = parked.temporaryURL(for: key)
        let written = cachedTokens.withUnsafeBufferPointer { tokens in
            llama_state_seq_save_file(context, temporary.path, 0, tokens.baseAddress, tokens.count)
        }
        guard written > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            HearthLog.error("llama", "couldn't park a conversation")
            return nil
        }
        do {
            let entry = try parked.commit(key: key, tokens: cachedTokens.count)
            flashSnapshot = (key, cachedTokens)
            let ms = Date().timeIntervalSince(started) * 1000
            HearthLog.info("llama", String(format: "parked %d tokens (%.1f MB) in %.0f ms", entry.tokens, Double(entry.bytes) / 1_048_576, ms))
            return ms
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            HearthLog.error("llama", "couldn't store a parked conversation")
            return nil
        }
    }

    /// Loads `key`'s parked state into the (empty) sequence 0 and sets `cachedTokens` from it.
    private func restoreNow(key: String) -> (milliseconds: Double, tokens: Int)? {
        guard let context, parked.entry(for: key) != nil else { return nil }
        // Unreadable right now (for example the phone is locked): keep the file and just re-read the chat.
        guard let probe = try? FileHandle(forReadingFrom: parked.stateURL(for: key)) else { return nil }
        try? probe.close()
        let started = Date()
        var tokens = [llama_token](repeating: 0, count: contextSize)
        var count = 0
        let read = llama_state_seq_load_file(context, parked.stateURL(for: key).path, 0, &tokens, tokens.count, &count)
        let memory = llama_get_memory(context)
        // Trust it only if the cache now holds exactly the tokens the file says it does.
        guard read > 0, count > 0, llama_memory_seq_pos_max(memory, 0) == llama_pos(count - 1) else {
            clearMemory()
            parked.remove(key: key) // from another model build, or damaged
            HearthLog.error("llama", "a parked conversation couldn't be restored; reading it again instead")
            return nil
        }
        cachedTokens = Array(tokens.prefix(count))
        flashSnapshot = (key, cachedTokens)
        parked.touch(key: key)
        let ms = Date().timeIntervalSince(started) * 1000
        HearthLog.info("llama", String(format: "restored %d tokens in %.0f ms", count, ms))
        return (ms, count)
    }

    private func clearMemory() {
        if let context { llama_memory_clear(llama_get_memory(context), true) }
        cachedTokens = []
        flashSnapshot = nil
    }

    // MARK: - Prompt and tokens

    private static let emptyThink = "<think>\n\n</think>\n\n"

    /// Chat template + optional empty think block (Qwen3) + optional forced speaker label.
    private func renderPrompt(_ request: GenerationRequest) throws -> String {
        var turns = request.turns
        if skipsThinking {
            // Earlier replies get the same empty think block the new reply starts with, so they match
            // what is already in the KV cache and prefix reuse keeps working turn after turn.
            turns = turns.map { $0.role == .assistant ? ChatTurn(role: .assistant, content: Self.emptyThink + $0.content) : $0 }
        }
        var text = try applyTemplate(turns)
        if skipsThinking { text += Self.emptyThink }
        let prefix = request.assistantPrefix ?? ""
        text += prefix
        if let opener = request.replyOpener, !opener.isEmpty {
            text += (prefix.isEmpty ? "" : " ") + opener
        }
        return text
    }

    private func applyTemplate(_ turns: [ChatTurn]) throws -> String {
        // llama.cpp reads C strings, so copy every role and content into memory we free afterwards.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        var messages: [llama_chat_message] = []
        for turn in turns {
            guard let role = strdup(turn.role.rawValue), let content = strdup(turn.content) else {
                throw EngineError.unavailable("The phone ran out of memory.")
            }
            owned += [role, content]
            messages.append(llama_chat_message(role: role, content: content))
        }
        let templates = [chatTemplate, "chatml"].compactMap { $0 }
        for template in templates {
            var capacity = turns.reduce(0) { $0 + $1.content.utf8.count } * 2 + 1024
            for _ in 0..<2 {
                var buffer = [CChar](repeating: 0, count: capacity)
                let length = Int(llama_chat_apply_template(template, &messages, messages.count, true, &buffer, Int32(capacity)))
                if length < 0 { break } // template not understood: try the next one
                if length <= capacity {
                    return String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                capacity = length + 1
            }
            HearthLog.error("llama", "chat template not supported; falling back")
        }
        throw EngineError.unavailable("This model's chat format isn't supported.")
    }

    /// Text to tokens. Special tokens written in the text (like <|eot_id|>) are parsed as special.
    static func tokenize(_ text: String, vocab: OpaquePointer, addSpecial: Bool) -> [llama_token] {
        var addBOS = addSpecial
        let bos = llama_vocab_bos(vocab)
        if addBOS, llama_vocab_get_add_bos(vocab), bos != LLAMA_TOKEN_NULL, let raw = llama_vocab_get_text(vocab, bos) {
            let bosText = String(cString: raw)
            if !bosText.isEmpty, text.hasPrefix(bosText) { addBOS = false } // the template already wrote it
        }
        let bytes = Array(text.utf8)
        var tokens = [llama_token](repeating: 0, count: bytes.count + 8)
        for _ in 0..<2 {
            let count = bytes.withUnsafeBufferPointer { raw in
                raw.withMemoryRebound(to: CChar.self) { chars in
                    llama_tokenize(vocab, chars.baseAddress, Int32(chars.count), &tokens, Int32(tokens.count), addBOS, true)
                }
            }
            if count >= 0 { return Array(tokens.prefix(Int(count))) }
            if count == Int32.min { return [] }
            tokens = [llama_token](repeating: 0, count: Int(-count))
        }
        return []
    }

    /// The raw bytes a token stands for (may be part of a multi-byte character).
    static func piece(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return length > 0 ? buffer[..<Int(length)].map { UInt8(bitPattern: $0) } : []
    }

    static func commonPrefixLength(_ a: [llama_token], _ b: [llama_token]) -> Int {
        var n = 0
        let limit = min(a.count, b.count)
        while n < limit, a[n] == b[n] { n += 1 }
        return n
    }

    // MARK: - Cancel and queue helpers

    private func cancel(id: Int) {
        lock.withLock { _ = cancelledIDs.insert(id) }
    }

    private func isCancelled(_ id: Int) -> Bool {
        lock.withLock { id <= cancelledThrough || cancelledIDs.contains(id) }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func onQueue(_ work: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                work()
                continuation.resume()
            }
        }
    }
}
#endif
