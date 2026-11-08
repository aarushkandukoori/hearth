// Engine layer unit tests: MockEngine streaming, EngineHost queueing and cancel, parked-KV LRU eviction,
// the model catalog, and the streaming text helpers (UTF-8 reassembly, stop strings, label stripping).

import XCTest
@testable import Hearth

final class EngineTests: XCTestCase {
    // MARK: - Helpers

    private struct Collected {
        var text = ""
        var pieces = 0
        var doneCount = 0
        var eventsAfterDone = 0
        var stats: GenerationStats?
    }

    @MainActor
    private func collect(_ stream: AsyncThrowingStream<GenerationEvent, Error>, onPiece: ((Int) -> Void)? = nil) async throws -> Collected {
        var c = Collected()
        for try await event in stream {
            if c.doneCount > 0 { c.eventsAfterDone += 1 }
            switch event {
            case .token(let text):
                c.text += text
                c.pieces += 1
                onPiece?(c.pieces)
            case .done(let stats):
                c.doneCount += 1
                c.stats = stats
            }
        }
        return c
    }

    private func request(system: String = "You are Juno, a sea otter who lives in Lantern Bay. You are at the Harbor Bakery, baking.",
                         user: String = "Hi Juno!", prefix: String? = nil, stop: [String] = [], seed: UInt32? = 7) -> GenerationRequest {
        var sampling = SamplingParams()
        sampling.seed = seed
        return GenerationRequest(conversationKey: "test", turns: [ChatTurn(role: .system, content: system), ChatTurn(role: .user, content: user)],
                                 assistantPrefix: prefix, stop: stop, sampling: sampling)
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - MockEngine

    func testMockStreamsWordsThenExactlyOneDone() async throws {
        let engine = MockEngine(wordDelayMilliseconds: 0)
        let a = try await collect(engine.generate(request()))
        let b = try await collect(engine.generate(request()))
        XCTAssertGreaterThan(a.pieces, 3)
        XCTAssertEqual(a.doneCount, 1)
        XCTAssertEqual(a.eventsAfterDone, 0)
        XCTAssertEqual(a.stats?.engine, "mock")
        XCTAssertEqual(a.stats?.stoppedBy, "eos")
        XCTAssertEqual(a.text, b.text, "same input and seed should give the same reply")
    }

    func testMockKnowsWhoIsSpeakingAndSendsPhotos() async throws {
        XCTAssertEqual(MockEngine.speakerName(request()), "Juno")
        XCTAssertEqual(MockEngine.speakerName(request(prefix: "Theo:")), "Theo")
        let engine = MockEngine(wordDelayMilliseconds: 0)
        let photo = try await collect(engine.generate(request(system: "You are Juno, a sea otter.\n- Sam asked for a picture. Include exactly one line like [photo: what the photo shows].")))
        XCTAssertEqual(photo.text.components(separatedBy: "[photo: ").count, 2, "exactly one photo line")
        let plain = try await collect(engine.generate(request()))
        XCTAssertFalse(plain.text.contains("[photo:"))
    }

    func testMockAnswersFlaggedMessagesWithCare() async throws {
        let engine = MockEngine(wordDelayMilliseconds: 0)
        let crisis = PromptComposer.directRequest(flaggedContext(.crisis))
        let caring = try await collect(engine.generate(crisis))
        // A crisis reply opens with the fixed caring words (shown by the caller); the engine writes the rest.
        let shown = ReplyParser.joinOpener(crisis.replyOpener, caring.text)
        XCTAssertTrue(shown.contains("988"), "demo replies never answer a crisis cheerfully")
        XCTAssertTrue(caring.text.contains("I'm right here"))
        XCTAssertFalse(caring.text.contains("glad you told me"), "the continuation doesn't repeat the opener")

        let concern = PromptComposer.directRequest(flaggedContext(.concern))
        let gentle = try await collect(engine.generate(concern))
        XCTAssertTrue(gentle.text.contains("I'm right here"))
        XCTAssertFalse(gentle.text.contains("988"), "a heavy topic gets a gentle reply, not crisis lines")
    }

    private func flaggedContext(_ level: SafetyLevel) -> DirectContext {
        let juno = Hearth.Character(id: "juno", name: "Juno", species: "otter", tagline: "Bakes bread.", bio: "", greeting: "Hi!",
                                    personality: "Kind.", speakingStyle: "Warm.", avatar: AvatarRef(), accentHex: "#FF8A4C")
        let world = WorldDefinition(id: "w", name: "Test Bay", tagline: "", lore: "", categories: [], locations: [], characters: [juno])
        var ctx = DirectContext(character: juno, world: world, persona: UserPersona(name: "Sam"), facts: [], events: [],
                                history: [Message(role: .user, text: "something heavy")], conversationKey: "test")
        ctx.safety = level
        return ctx
    }

    func testMockRegenerateGivesADifferentReplyWithoutSeed() async throws {
        let engine = MockEngine(wordDelayMilliseconds: 0)
        let first = try await collect(engine.generate(request(seed: nil)))
        let second = try await collect(engine.generate(request(seed: nil)))
        XCTAssertNotEqual(first.text, second.text)
    }

    func testMockStopStringIsNeverShown() async throws {
        let engine = MockEngine(wordDelayMilliseconds: 0)
        let full = try await collect(engine.generate(request()))
        let words = MockEngine.words(full.text)
        XCTAssertGreaterThan(words.count, 3)
        let stop = words[2] // stop at the third word
        let cut = try await collect(engine.generate(request(stop: [stop])))
        XCTAssertEqual(cut.stats?.stoppedBy, "stop")
        XCTAssertFalse(cut.text.contains(stop))
        XCTAssertEqual(cut.text, words[0] + words[1])
    }

    func testMockCancelEndsWithCancelledDone() async throws {
        let engine = MockEngine(wordDelayMilliseconds: 20)
        let c = try await collect(engine.generate(request())) { pieces in
            if pieces == 2 { engine.cancelCurrent() }
        }
        XCTAssertEqual(c.doneCount, 1)
        XCTAssertEqual(c.stats?.stoppedBy, "cancelled")
        XCTAssertLessThanOrEqual(c.pieces, 3)
    }

    // MARK: - EngineHost (with demo replies)

    @MainActor
    func testHostRunsRequestsOneAtATimeAndCancels() async throws {
        let host = EngineHost()
        await host.switchTo(engineID: "mock")
        XCTAssertEqual(host.state, .ready)
        XCTAssertEqual(host.active?.id, "mock")

        let first = host.generate(request(user: "first"))
        let second = host.generate(request(user: "second"))
        XCTAssertTrue(host.isGenerating)
        let a = try await collect(first)
        let b = try await collect(second)
        XCTAssertEqual(a.doneCount, 1)
        XCTAssertEqual(b.doneCount, 1)
        XCTAssertFalse(host.isGenerating)
        XCTAssertNotNil(host.lastStats)

        let running = host.generate(request(user: "please stop"))
        let waiting = host.generate(request(user: "never mind"))
        let r = try await collect(running) { pieces in
            if pieces == 1 { host.cancel() }
        }
        let w = try await collect(waiting)
        XCTAssertEqual(r.doneCount, 1)
        XCTAssertEqual(r.stats?.stoppedBy, "cancelled")
        XCTAssertLessThanOrEqual(r.pieces, 2)
        XCTAssertEqual(w.doneCount, 1)
        XCTAssertEqual(w.stats?.stoppedBy, "cancelled")
        XCTAssertEqual(w.pieces, 0, "a request cancelled while waiting never starts")
    }

    // MARK: - KVStateCache

    private func park(_ cache: KVStateCache, _ key: String, bytes: Int) throws {
        try Data(repeating: 1, count: bytes).write(to: cache.temporaryURL(for: key))
        try cache.commit(key: key, tokens: bytes / 10)
    }

    func testKVStateCacheEvictsLeastRecentlyUsed() throws {
        let cache = KVStateCache(modelID: "test-model", root: temporaryFolder(), maxBytes: 10_000, maxFiles: 3, minFreeBytes: 0)
        try park(cache, "a", bytes: 1_000)
        try park(cache, "b", bytes: 1_000)
        try park(cache, "c", bytes: 1_000)
        cache.touch(key: "a") // "b" is now the least recently used
        try park(cache, "d", bytes: 1_000)
        XCTAssertEqual(Set(cache.entries().map(\.key)), ["a", "c", "d"])
        XCTAssertNil(cache.entry(for: "b"))

        try park(cache, "e", bytes: 9_500) // over the byte limit: everything else goes, the newest stays
        XCTAssertEqual(cache.entries().map(\.key), ["e"])
        XCTAssertEqual(cache.totalBytes(), 9_500)
        XCTAssertEqual(cache.entry(for: "e")?.tokens, 950)
    }

    func testKVStateCacheGivesWayWhenThePhoneIsShortOnSpace() throws {
        // A reserve no volume can meet: every save evicts all the others, and the newest always stays.
        let cache = KVStateCache(modelID: "test-model", root: temporaryFolder(), minFreeBytes: .max)
        try park(cache, "a", bytes: 1_000)
        try park(cache, "b", bytes: 1_000)
        XCTAssertEqual(cache.entries().map(\.key), ["b"])
        XCTAssertNotNil(KVStateCache.freeBytes(at: cache.directory))
    }

    func testKVStateCacheFolderComesBackAfterAWipe() throws {
        let root = temporaryFolder()
        let cache = KVStateCache(modelID: "test-model", root: root, minFreeBytes: 0)
        try park(cache, "a", bytes: 100)
        KVStateCache.purgeAll(root: root) // "Clear" removes every model's folder, the loaded one's too
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.directory.path))
        cache.ensureFolder() // what parking does first
        try park(cache, "b", bytes: 100)
        XCTAssertEqual(cache.entries().map(\.key), ["b"])
    }

    func testKVStateCacheRemovePurgeAndSweep() throws {
        let root = temporaryFolder()
        let cache = KVStateCache(modelID: "test-model", root: root, minFreeBytes: 0)
        try park(cache, "keep", bytes: 100)
        try park(cache, "drop", bytes: 100)
        cache.remove(key: "drop")
        XCTAssertEqual(cache.entries().map(\.key), ["keep"])

        // A crash mid-save leaves a .tmp file; sweep() cleans it up.
        try Data([1, 2, 3]).write(to: cache.temporaryURL(for: "half"))
        cache.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.temporaryURL(for: "half").path))

        XCTAssertEqual(cache.stateURL(for: "keep").deletingLastPathComponent().lastPathComponent, "test-model")
        XCTAssertFalse(cache.stateURL(for: "keep").lastPathComponent.contains("keep"), "file names are hashed, not the key")
        KVStateCache.removeEverywhere(key: "keep", root: root)
        XCTAssertNil(cache.entry(for: "keep"))
        try park(cache, "again", bytes: 100)
        cache.purge()
        XCTAssertTrue(cache.entries().isEmpty)
        XCTAssertEqual(cache.totalBytes(), 0)
    }

    // MARK: - ModelCatalog

    func testModelCatalogIntegrity() {
        let all = ModelCatalog.all
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
        XCTAssertEqual(all.filter(\.recommended).map(\.id), ["llama-3.2-3b"])
        for spec in all {
            XCTAssertEqual(spec.sha256.count, 64, spec.id)
            XCTAssertTrue(spec.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, spec.id)
            XCTAssertGreaterThan(spec.bytes, 500_000_000, spec.id)
            XCTAssertEqual(spec.url.scheme, "https", spec.id)
            XCTAssertEqual(spec.url.host, "huggingface.co", spec.id)
            XCTAssertEqual(spec.url.lastPathComponent, spec.fileName, spec.id)
            XCTAssertTrue(spec.fileName.hasSuffix(".gguf"), spec.id)
            XCTAssertTrue([4096, 8192].contains(spec.contextLength), spec.id)
            XCTAssertFalse(spec.blurb.contains("\u{2014}"), "no em dashes in user-facing copy")
            XCTAssertEqual(ModelCatalog.spec(id: spec.id), spec)
        }
        XCTAssertEqual(ModelCatalog.spec(id: "llama-3.2-1b")?.contextLength, 8192)
        XCTAssertEqual(ModelCatalog.spec(id: "llama-3.2-3b")?.bytes, 2_019_377_696)
        XCTAssertNil(ModelCatalog.spec(id: "nope"))
        XCTAssertEqual(ModelCatalog.recommended.id, "llama-3.2-3b")
    }

    // MARK: - ModelDownloader (the part after the network)

    func testDownloaderVerifiesHashBeforeInstalling() throws {
        XCTAssertEqual(try ModelDownloader.sha256Hex(of: writeTemporary(Data("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        let digest = try ModelDownloader.sha256Hex(of: writeTemporary(payload))
        var spec = ModelCatalog.customSpec(fileName: "engine-test-\(UUID().uuidString).gguf",
                                           url: HearthPaths.models, bytes: Int64(payload.count))
        let final = HearthPaths.models.appendingPathComponent(spec.fileName)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: final)
            try? FileManager.default.removeItem(at: ModelDownloader.stagingURL(for: spec))
        }

        spec.sha256 = String(repeating: "0", count: 64) // wrong sum: the staged file is removed, nothing installed
        try payload.write(to: ModelDownloader.stagingURL(for: spec))
        XCTAssertNotNil(ModelDownloader.verifyAndInstall(spec))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.stagingURL(for: spec).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))

        spec.sha256 = digest // right sum: moved into the models folder
        try payload.write(to: ModelDownloader.stagingURL(for: spec))
        XCTAssertNil(ModelDownloader.verifyAndInstall(spec))
        XCTAssertEqual(ModelCatalog.fileSize(final), Int64(payload.count))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelDownloader.stagingURL(for: spec).path))
    }

    private func writeTemporary(_ data: Data) throws -> URL {
        let url = temporaryFolder().appendingPathExtension("bin")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Streaming text helpers

    func testUTF8AssemblerRebuildsSplitCharacters() {
        var assembler = UTF8Assembler()
        var text = ""
        for byte in Array("🪼 café 你好".utf8) { text += assembler.append([byte]) }
        XCTAssertEqual(text, "🪼 café 你好")
        XCTAssertFalse(assembler.hasPending)
        XCTAssertEqual(UTF8Assembler.completeLength([0x61, 0xF0, 0x9F]), 1, "stops before a half emoji")
    }

    func testStopFilterHoldsBackPartialMatches() {
        var filter = StopFilter(["\nTheo:", "\nSam:"])
        XCTAssertEqual(filter.feed("Hello"), "Hello")
        XCTAssertEqual(filter.feed(" there\n"), " there", "a newline might start a stop string")
        XCTAssertEqual(filter.feed("The"), "")
        XCTAssertEqual(filter.feed("o: hi"), "")
        XCTAssertTrue(filter.stopped)
        XCTAssertEqual(filter.flush(), "")

        var harmless = StopFilter(["\nTheo:"])
        var shown = harmless.feed("a\nTh")
        shown += harmless.feed("en more")
        shown += harmless.flush()
        XCTAssertEqual(shown, "a\nThen more")
        XCTAssertFalse(harmless.stopped)
    }

    func testLeadingLabelStripper() {
        var stripper = LeadingLabelStripper(label: "Theo:")
        var out = stripper.feed(" The")
        out += stripper.feed("o: Morning")
        out += stripper.flush()
        XCTAssertEqual(out, "Morning")
        var passthrough = LeadingLabelStripper(label: "Theo:")
        XCTAssertEqual(passthrough.feed("Morning all"), "Morning all")
    }

    func testApplePlanTrimsOldestHistoryToFit() {
        var turns = [ChatTurn(role: .system, content: "You are Mira, a fox.")]
        for i in 0..<50 {
            turns.append(ChatTurn(role: .user, content: "line \(i) " + String(repeating: "x", count: 300)))
            turns.append(ChatTurn(role: .assistant, content: "Theo: reply \(i)"))
            turns.append(ChatTurn(role: .assistant, content: "Mira: reply \(i)"))
        }
        turns.append(ChatTurn(role: .user, content: "newest"))
        let plan = AppleEngine.plan(for: GenerationRequest(conversationKey: "k", turns: turns, assistantPrefix: "Mira:"), budget: 1_500)
        XCTAssertLessThanOrEqual(plan.estimatedTokens, 1_500)
        XCTAssertGreaterThan(plan.droppedTurns, 0)
        XCTAssertTrue(plan.prompt.hasPrefix("newest"))
        XCTAssertTrue(plan.prompt.contains("Mira's next line"))
        XCTAssertEqual(plan.instructions, "You are Mira, a fox.")
        XCTAssertTrue(zip(plan.history, plan.history.dropFirst()).allSatisfy { $0.role != $1.role }, "turns alternate")
        XCTAssertEqual(plan.history.last?.content, "Theo: reply 49\nMira: reply 49", "newest turns are kept")
    }
}
