// Engine layer unit tests: MockEngine streaming, EngineHost queueing and cancel, the Pie inferlet contract,
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

    // MARK: - ModelCatalog

    func testModelCatalogIntegrity() {
        let all = ModelCatalog.all
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "ids are unique")
        XCTAssertEqual(all.filter(\.recommended).map(\.id), ["qwen3.5-2b"])
        for spec in all {
            XCTAssertEqual(spec.sha256.count, 64, spec.id)
            XCTAssertTrue(spec.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, spec.id)
            XCTAssertGreaterThan(spec.bytes, 500_000_000, spec.id)
            XCTAssertEqual(spec.url.scheme, "https", spec.id)
            XCTAssertEqual(spec.url.host, "github.com", spec.id)
            XCTAssertEqual(spec.url.lastPathComponent, spec.fileName, spec.id)
            XCTAssertTrue(spec.fileName.hasSuffix(".metal.zt"), "a Pie Metal artifact: \(spec.id)")
            XCTAssertTrue(spec.deployment.hasPrefix("qwen35-"), spec.id)
            XCTAssertEqual(spec.contextLength, 4096, spec.id)
            XCTAssertFalse(spec.blurb.contains("\u{2014}"), "no em dashes in user-facing copy")
            XCTAssertFalse(spec.displayName.lowercased().contains("llama"), spec.id)
            XCTAssertEqual(ModelCatalog.spec(id: spec.id), spec)
        }
        XCTAssertEqual(ModelCatalog.spec(id: "qwen3.5-0.8b")?.vision, true)
        XCTAssertEqual(ModelCatalog.standard.modelName, "Qwen3.5 2B")
        XCTAssertNil(ModelCatalog.spec(id: "nope"))
        XCTAssertEqual(ModelCatalog.recommended.id, "qwen3.5-2b")
    }

    // MARK: - What PieEngine sends Hearth's inferlet

    func testInferletInputCarriesTheWholeRequestInSnakeCase() throws {
        var sampling = SamplingParams()
        sampling.temperature = 0.9
        sampling.seed = 7
        let request = GenerationRequest(conversationKey: "scene-1",
                                        turns: [ChatTurn(role: .system, content: "You are Theo."),
                                                ChatTurn(role: .user, content: "Hi!")],
                                        assistantPrefix: "Theo:", maxTokens: 90, stop: ["\nSam:"], sampling: sampling,
                                        replyOpener: "*sits close*")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder.pie.encode(InferletInput(request))) as? [String: Any]
        let turns = json?["turns"] as? [[String: String]]
        XCTAssertEqual(turns?.map { $0["role"] }, ["system", "user"])
        XCTAssertEqual(json?["prefix"] as? String, "Theo:")
        XCTAssertEqual(json?["opener"] as? String, "*sits close*")
        XCTAssertEqual(json?["max_tokens"] as? Int, 90)
        XCTAssertEqual(json?["stop"] as? [String], ["\nSam:"])
        XCTAssertEqual((json?["top_p"] as? Double).map { ($0 * 100).rounded() }, 95)
        XCTAssertEqual(json?["seed"] as? Int, 7)
        XCTAssertNotNil(json?["repeat_penalty"])

        let plain = GenerationRequest(conversationKey: "c", turns: [ChatTurn(role: .user, content: "Hi")])
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder.pie.encode(InferletInput(plain))) as? [String: Any]
        XCTAssertNil(bare?["prefix"], "absent options are left out, so the inferlet's defaults apply")
        XCTAssertNil(bare?["opener"])
        XCTAssertNil(bare?["seed"])
    }

    func testInferletOutputDecodesPieStats() throws {
        let json = #"{"text":"Hi!","prompt_tokens":120,"reused_tokens":96,"prefilled_tokens":24,"generated_tokens":5,"stopped_by":"max_tokens","ttft_ms":180.5,"prefill_ms":180.5,"decode_ms":90,"decode_tokens_per_second":44.4,"page_size":16}"#
        let out = try JSONDecoder.pie.decode(InferletOutput.self, from: Data(json.utf8))
        XCTAssertEqual(out.reusedTokens, 96)
        XCTAssertEqual(out.prefilledTokens, 24)
        XCTAssertEqual(out.stoppedBy, "max_tokens")
        XCTAssertEqual(out.decodeTokensPerSecond, 44.4, accuracy: 0.001)
    }

    // MARK: - ModelDownloader (the part after the network)

    func testDownloaderVerifiesHashBeforeInstalling() throws {
        XCTAssertEqual(try ModelDownloader.sha256Hex(of: writeTemporary(Data("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        let digest = try ModelDownloader.sha256Hex(of: writeTemporary(payload))
        var spec = ModelCatalog.customSpec(fileName: "engine-test-\(UUID().uuidString).metal.zt",
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

    func testFailedResumeStartsOverOnlyWhenTheSavedProgressIsUseless() {
        func error(_ code: Int, _ domain: String = NSURLErrorDomain) -> NSError { NSError(domain: domain, code: code) }
        // It never took: an expired or removed link, a stale range, a temporary file that is gone.
        XCTAssertTrue(ModelDownloader.resumeDidNotTake(status: 0, error: error(NSURLErrorFileDoesNotExist)))
        XCTAssertTrue(ModelDownloader.resumeDidNotTake(status: 403, error: error(NSURLErrorBadServerResponse)))
        XCTAssertTrue(ModelDownloader.resumeDidNotTake(status: 410, error: error(NSURLErrorBadServerResponse)))
        XCTAssertTrue(ModelDownloader.resumeDidNotTake(status: 416, error: error(NSURLErrorBadServerResponse)))
        XCTAssertTrue(ModelDownloader.resumeDidNotTake(status: 0, error: error(Int(ENOENT), NSPOSIXErrorDomain)))
        // Temporary trouble, or it resumed and then dropped: the saved progress is still good.
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 503, error: error(NSURLErrorBadServerResponse)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 429, error: error(NSURLErrorBadServerResponse)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 0, error: error(NSURLErrorUnknown)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 0, error: error(NSURLErrorSecureConnectionFailed)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 206, error: error(NSURLErrorUnknown)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 206, error: error(NSURLErrorNetworkConnectionLost)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 0, error: error(NSURLErrorNotConnectedToInternet)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 0, error: error(NSURLErrorTimedOut)))
        XCTAssertFalse(ModelDownloader.resumeDidNotTake(status: 0, error: error(NSURLErrorCancelled)))
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
}
