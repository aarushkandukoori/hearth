// EngineLab: a Mac command-line harness that runs Hearth's real engine code on real GGUF files and checks
// what SPEC §6 promises: prefix reuse, park/restore, scenes with stop strings, cancel, emoji, overflow.
// Build and run with ios/EngineLab/run.sh. Results go to ios/EngineLab/RESULTS.md.

import Foundation
import llama

// MARK: - Bookkeeping

struct Row {
    var model: String
    var test: String
    var passed: Bool
    var detail: String
}

struct Numbers {
    var model = ""
    var loadMs = 0.0
    var ttftMs = 0.0
    var prefillTPS = 0.0
    var decodeTPS = 0.0
    var secondTurnTTFTMs = 0.0
    var secondTurnReused = 0
    var secondTurnPrefilled = 0
    var parkMs = 0.0
    var parkedTokens = 0
    var parkedMB = 0.0
    var restoreMs = 0.0
    var restoredTTFTMs = 0.0
    var coldTTFTMs = 0.0
}

var rows: [Row] = []
var numbers: [Numbers] = []
var notes: [String] = []

@MainActor func check(_ model: String, _ test: String, _ passed: Bool, _ detail: String) {
    rows.append(Row(model: model, test: test, passed: passed, detail: detail))
    print("\(passed ? "PASS" : "FAIL")  [\(model)] \(test): \(detail)")
}

struct Run {
    var text = ""
    var pieces: [String] = []
    var stats: GenerationStats?
    var doneEvents = 0
    var eventsAfterDone = 0
    var error: Error?
    var piecesAtCancel: Int?
    var cancelToDoneMs: Double?
}

/// Streams one request to the end, optionally calling cancelCurrent() after `cancelAfter` text pieces.
@MainActor func collect(_ engine: any LanguageEngine, _ request: GenerationRequest, cancelAfter: Int? = nil) async -> Run {
    var run = Run()
    var cancelledAt: Date?
    do {
        for try await event in engine.generate(request) {
            if run.doneEvents > 0 { run.eventsAfterDone += 1 }
            switch event {
            case .token(let text):
                run.text += text
                run.pieces.append(text)
                if let n = cancelAfter, run.pieces.count == n, cancelledAt == nil {
                    cancelledAt = Date()
                    run.piecesAtCancel = n
                    engine.cancelCurrent()
                }
            case .done(let stats):
                run.stats = stats
                run.doneEvents += 1
                if let cancelledAt { run.cancelToDoneMs = Date().timeIntervalSince(cancelledAt) * 1000 }
            }
        }
    } catch {
        run.error = error
    }
    return run
}

func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }
func f1(_ x: Double) -> String { String(format: "%.1f", x) }
func short(_ text: String, _ n: Int = 90) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " / ").replacingOccurrences(of: "|", with: "/")
    return flat.count > n ? String(flat.prefix(n)) + "..." : flat
}

// MARK: - Prompts (same shape as SPEC §7)

func directSystem(name: String, species: String, tagline: String, personality: String, style: String,
                  place: String, activity: String, user: String = "Sam") -> String {
    """
    You are \(name), a \(species) who lives in Lantern Bay. \(tagline)

    About you:
    \(personality)

    How you talk:
    \(style)

    Right now it is evening on Thursday. You are at \(place), \(activity).

    People you know:
    - Theo (friend): a heron who runs the little ferry and tells long stories.
    - Mira (neighbor): a fox who keeps the library and lends out umbrellas.

    Recent happenings in town:
    - The lanterns along the pier were repainted gold.
    - Someone left a basket of plums on the library steps.

    About \(user): likes rainy days and old songs.

    Rules:
    - Stay in character as \(name). Write only \(name)'s next message, never \(user)'s.
    - Text like a close friend: usually one to three short sentences. Go longer only to tell a story or when asked.
    - Be warm and curious about \(user)'s life, and remember details.
    - Use *asterisks* for small actions, sparingly.
    - If \(user) sincerely asks whether you are real, gently say you are an AI character in Hearth, and keep being kind.
    - Never pressure \(user) to stay, never guilt them for leaving, and be glad when they mention other people in their life.
    - If \(user) talks about hurting themselves or being in danger, step out of the story: answer with care, encourage them to call or text 988 (in the US) or local emergency services, and stay with them.
    """
}

let junoSystem = directSystem(name: "Juno", species: "sea otter", tagline: "Runs the harbor bakery and remembers everyone's order.",
                              personality: "Cheerful, practical and a little nosy in a kind way. Bakes when she's worried.",
                              style: "Short, warm sentences. Calls people \"friend\". Loves food metaphors.",
                              place: "the Harbor Bakery", activity: "wiping flour off the counter")
let wrenSystem = directSystem(name: "Wren", species: "barn owl", tagline: "Keeps the lighthouse and writes letters to the sea.",
                              personality: "Gentle, thoughtful, a night owl in every sense. Notices small things.",
                              style: "Soft and unhurried. Asks one good question at a time.",
                              place: "the lighthouse", activity: "polishing the big lamp")

let smallTalk: [(String, String)] = [
    ("I tried baking bread today. It came out kind of flat.", "*laughs* Flat bread is still bread, friend! Did you let it rise long enough?"),
    ("Probably not. I was impatient.", "Patience is half the recipe. Next time, cover it with a warm towel and go read for an hour."),
    ("It rained all afternoon here.", "Rainy days are the best baking days. Did you get to listen to it on the roof?"),
    ("I did. I put on some old records too.", "That sounds perfect. What were you listening to?"),
    ("Mostly jazz. My grandmother used to play it.", "That's lovely. Music like that carries people with it, doesn't it?"),
    ("Yeah. I miss her sometimes.", "Of course you do. Missing someone is just love with nowhere to go for a while. Tell me about her?"),
    ("She grew tomatoes on her balcony and talked to them.", "*grins* Smart woman. Plants grow better when someone's rooting for them."),
    ("I want to try growing basil this spring.", "Basil is a great start. Lots of sun, and pinch the tops so it gets bushy."),
]

func longConversation(_ system: String, greeting: String, rounds: Int) -> [ChatTurn] {
    var turns = [ChatTurn(role: .system, content: system), ChatTurn(role: .assistant, content: greeting)]
    for i in 0..<rounds {
        let pair = smallTalk[i % smallTalk.count]
        turns.append(ChatTurn(role: .user, content: pair.0))
        turns.append(ChatTurn(role: .assistant, content: pair.1))
    }
    return turns
}

func sampling(_ seed: UInt32?) -> SamplingParams {
    var s = SamplingParams()
    s.seed = seed
    return s
}

// MARK: - Pure checks (no model needed)

@MainActor func pureChecks() {
    let m = "pure"
    // UTF-8 reassembly: feed an emoji and a CJK character one byte at a time.
    var assembler = UTF8Assembler()
    var rebuilt = ""
    for byte in Array("🪼 你好".utf8) { rebuilt += assembler.append([byte]) }
    check(m, "UTF8Assembler byte-by-byte", rebuilt == "🪼 你好" && !assembler.hasPending, "rebuilt \"\(rebuilt)\"")

    // Stop strings: split across feeds, never shown, held text released when it turns out harmless.
    var filter = StopFilter(["\nTheo:", "\nSam:"])
    var shown = ""
    for part in ["Hello", " there", "\n", "The", "o: hi"] { shown += filter.feed(part) }
    check(m, "StopFilter split stop", shown == "Hello there" && filter.stopped, "shown \"\(shown)\"")
    var harmless = StopFilter(["\nTheo:"])
    var out = ""
    for part in ["a\n", "Th", "en more"] { out += harmless.feed(part) }
    out += harmless.flush()
    check(m, "StopFilter releases false alarm", out == "a\nThen more" && !harmless.stopped, "shown \"\(short(out))\"")

    var stripper = LeadingLabelStripper(label: "Theo:")
    var stripped = ""
    for part in [" The", "o: Morning", " all"] { stripped += stripper.feed(part) }
    stripped += stripper.flush()
    var keeper = LeadingLabelStripper(label: "Theo:")
    var kept = keeper.feed("Morning")
    kept += keeper.flush()
    check(m, "LeadingLabelStripper", stripped == "Morning all" && kept == "Morning", "\"\(stripped)\" / \"\(kept)\"")

    // KV cache LRU in a temp folder.
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("enginelab-kv-\(UUID().uuidString)")
    let cache = KVStateCache(modelID: "test", root: root, maxBytes: 10_000, maxFiles: 3)
    func fake(_ key: String, _ size: Int) throws {
        try Data(repeating: 7, count: size).write(to: cache.temporaryURL(for: key))
        try cache.commit(key: key, tokens: size / 10)
    }
    do {
        try fake("a", 1000); try fake("b", 1000); try fake("c", 1000)
        cache.touch(key: "a")
        try fake("d", 1000) // over 3 files: evicts the oldest untouched ("b")
        let keys = Set(cache.entries().map(\.key))
        try fake("e", 9500) // over 10 KB: evicts everything else, keeps "e"
        let after = cache.entries().map(\.key)
        check(m, "KVStateCache LRU", keys == ["a", "c", "d"] && after == ["e"], "after count limit \(keys.sorted()), after size limit \(after)")
    } catch {
        check(m, "KVStateCache LRU", false, "error \(error)")
    }
    try? FileManager.default.removeItem(at: root)

    // Apple plan trimming: drops oldest turns to fit, merges same-side neighbors, keeps the last user turn as prompt.
    var turns = [ChatTurn(role: .system, content: String(repeating: "s", count: 400))]
    for i in 0..<40 {
        turns.append(ChatTurn(role: .user, content: "user line \(i) " + String(repeating: "u", count: 200)))
        turns.append(ChatTurn(role: .assistant, content: "Theo: reply \(i)"))
        turns.append(ChatTurn(role: .assistant, content: "Mira: reply \(i)"))
    }
    turns.append(ChatTurn(role: .user, content: "last question"))
    let plan = AppleEngine.plan(for: GenerationRequest(conversationKey: "k", turns: turns, assistantPrefix: "Mira:"), budget: 1000)
    let alternates = zip(plan.history, plan.history.dropFirst()).allSatisfy { $0.role != $1.role }
    check(m, "AppleEngine.plan budget", plan.estimatedTokens <= 1000 && plan.droppedTurns > 0 && alternates
          && plan.prompt.hasPrefix("last question") && plan.prompt.contains("Mira's next line"),
          "~\(plan.estimatedTokens) tokens, dropped \(plan.droppedTurns), kept \(plan.history.count)")
}

@MainActor func mockChecks() async {
    let m = "mock"
    let engine = MockEngine(wordDelayMilliseconds: 1)
    let request = GenerationRequest(conversationKey: "m", turns: [
        ChatTurn(role: .system, content: "You are Juno, a sea otter who lives in Lantern Bay. You are at the Harbor Bakery, baking."),
        ChatTurn(role: .user, content: "Hi Juno!"),
    ], sampling: sampling(7))
    let a = await collect(engine, request)
    let b = await collect(engine, request)
    check(m, "deterministic stream + one done", a.doneEvents == 1 && a.eventsAfterDone == 0 && !a.text.isEmpty && a.text == b.text,
          "\"\(short(a.text, 60))\"")
    var photo = request
    photo.turns[0].content += "\n- Sam asked for a picture. Include exactly one line like [photo: what the photo shows]."
    let p = await collect(engine, photo)
    check(m, "photo line", p.text.contains("[photo: "), short(p.text.components(separatedBy: "\n").last ?? ""))
    var stopping = request
    stopping.stop = [" "]
    let s = await collect(engine, stopping)
    check(m, "stop string", s.stats?.stoppedBy == "stop" && !s.text.contains(" "), "\"\(s.text)\" stop \(s.stats?.stoppedBy ?? "-")")
    let slow = MockEngine(wordDelayMilliseconds: 30)
    let c = await collect(slow, request, cancelAfter: 2)
    check(m, "cancel", c.stats?.stoppedBy == "cancelled" && c.pieces.count <= 3, "\(c.pieces.count) pieces, stop \(c.stats?.stoppedBy ?? "-")")
}

// MARK: - Llama checks

@MainActor func llamaChecks(modelPath: String, kvRoot: URL) async {
    let url = URL(fileURLWithPath: modelPath)
    guard let size = ModelCatalog.fileSize(url) else {
        check(url.lastPathComponent, "model file", false, "missing at \(modelPath)")
        return
    }
    let spec = ModelCatalog.all.first { $0.fileName == url.lastPathComponent }
        ?? ModelCatalog.customSpec(fileName: url.lastPathComponent, url: url, bytes: size)
    let name = spec.id
    var n = Numbers()
    n.model = name
    let engine = LlamaEngine(spec: spec, modelURL: url, kvRoot: kvRoot)

    let loadStart = Date()
    do {
        try await engine.prepare()
        n.loadMs = Date().timeIntervalSince(loadStart) * 1000
        check(name, "load", true, String(format: "%.0f ms, n_ctx %d", n.loadMs, spec.contextLength))
    } catch {
        check(name, "load", false, error.localizedDescription)
        return
    }
    var allRuns: [Run] = []

    // 1. Basic chat.
    let turns1 = [ChatTurn(role: .system, content: junoSystem),
                  ChatTurn(role: .assistant, content: "*waves a floury paw* Evening, friend! Fresh buns just came out."),
                  ChatTurn(role: .user, content: "Hi Juno! What are you baking tonight?")]
    let basic = await collect(engine, GenerationRequest(conversationKey: "lab-basic", turns: turns1, maxTokens: 64, sampling: sampling(42)))
    allRuns.append(basic)
    if let s = basic.stats {
        n.ttftMs = s.timeToFirstToken * 1000
        n.prefillTPS = s.prefillTokensPerSecond
        n.decodeTPS = s.decodeTokensPerSecond
        let noThink = !basic.text.contains("<think>") && !basic.text.contains("</think>")
        check(name, "basic chat", basic.error == nil && !basic.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && noThink,
              "\(s.promptTokens) prompt tokens, ttft \(ms(s.timeToFirstToken)), prefill \(Int(s.prefillTokensPerSecond)) tok/s, decode \(f1(s.decodeTokensPerSecond)) tok/s, stop \(s.stoppedBy): \"\(short(basic.text))\"")
    } else {
        check(name, "basic chat", false, "error \(String(describing: basic.error))")
    }

    // 2. Second turn reuses the first turn's KV (same conversation key).
    let turns2 = turns1 + [ChatTurn(role: .assistant, content: basic.text),
                           ChatTurn(role: .user, content: "Ooh, can I have one? I had a long day.")]
    let second = await collect(engine, GenerationRequest(conversationKey: "lab-basic", turns: turns2, maxTokens: 64, sampling: sampling(42)))
    allRuns.append(second)
    if let s = second.stats, let first = basic.stats {
        n.secondTurnTTFTMs = s.timeToFirstToken * 1000
        n.secondTurnReused = s.reusedTokens
        n.secondTurnPrefilled = s.prefilledTokens
        check(name, "second-turn prefix reuse", s.reusedTokens >= first.promptTokens && s.prefilledTokens < 60,
              "reused \(s.reusedTokens) of \(s.promptTokens) (turn 1 prompt was \(first.promptTokens)), prefilled \(s.prefilledTokens), ttft \(ms(s.timeToFirstToken)): \"\(short(second.text))\"")
    } else {
        check(name, "second-turn prefix reuse", false, "error \(String(describing: second.error))")
    }

    // 3. Park A -> run B -> resume A, against a never-parked baseline with the same seed.
    let longA = longConversation(junoSystem, greeting: "*waves a floury paw* Evening, friend!", rounds: 12)
    let a1 = longA + [ChatTurn(role: .user, content: "What should I bake this weekend?")]
    let seed: UInt32 = 1234
    let base1 = await collect(engine, GenerationRequest(conversationKey: "lab-baseline", turns: a1, maxTokens: 40, sampling: sampling(seed)))
    let a2base = a1 + [ChatTurn(role: .assistant, content: base1.text), ChatTurn(role: .user, content: "Okay! And what should I drink with it?")]
    let never = await collect(engine, GenerationRequest(conversationKey: "lab-baseline", turns: a2base, maxTokens: 40, sampling: sampling(seed)))

    let parkA1 = await collect(engine, GenerationRequest(conversationKey: "lab-A", turns: a1, maxTokens: 40, sampling: sampling(seed)))
    let turnsB = [ChatTurn(role: .system, content: wrenSystem), ChatTurn(role: .assistant, content: "Hoo. You're up late too?"),
                  ChatTurn(role: .user, content: "Can't sleep. What are you doing up there?")]
    let runB = await collect(engine, GenerationRequest(conversationKey: "lab-B", turns: turnsB, maxTokens: 40, sampling: sampling(seed)))
    let entryA = engine.parked.entry(for: "lab-A")
    let fileA = engine.parked.stateURL(for: "lab-A")
    let a2 = a1 + [ChatTurn(role: .assistant, content: parkA1.text), ChatTurn(role: .user, content: "Okay! And what should I drink with it?")]
    let resumed = await collect(engine, GenerationRequest(conversationKey: "lab-A", turns: a2, maxTokens: 40, sampling: sampling(seed)))
    let cold = await collect(engine, GenerationRequest(conversationKey: "lab-A-cold", turns: a2, maxTokens: 40, sampling: sampling(seed)))
    allRuns += [base1, never, parkA1, runB, resumed, cold]

    check(name, "same seed, same reply (fresh cache)", base1.text == parkA1.text && !base1.text.isEmpty, "\"\(short(base1.text, 60))\"")
    if let b = runB.stats, let entryA {
        n.parkMs = b.parkMilliseconds ?? 0
        n.parkedTokens = entryA.tokens
        n.parkedMB = Double(entryA.bytes) / 1_048_576
        let protected = FileManager.default.fileExists(atPath: fileA.path)
        check(name, "park on switch", b.parkMilliseconds != nil && protected && entryA.bytes > 0,
              String(format: "parked %d tokens, %.1f MB in %.0f ms", entryA.tokens, n.parkedMB, n.parkMs))
    } else {
        check(name, "park on switch", false, "no parked state for A (park ms \(String(describing: runB.stats?.parkMilliseconds)))")
    }
    if let r = resumed.stats, let p = parkA1.stats, let c = cold.stats {
        n.restoreMs = r.restoreMilliseconds ?? 0
        n.restoredTTFTMs = r.timeToFirstToken * 1000
        n.coldTTFTMs = c.timeToFirstToken * 1000
        check(name, "resume A from flash", r.restoredFromDisk && r.restoreMilliseconds != nil && r.reusedTokens >= p.promptTokens && r.prefilledTokens < 60,
              String(format: "restore %.0f ms, reused %d of %d, prefilled %d, ttft %.0f ms vs cold %.0f ms (cold prefilled %d)",
                     n.restoreMs, r.reusedTokens, r.promptTokens, r.prefilledTokens, n.restoredTTFTMs, n.coldTTFTMs, c.prefilledTokens))
        check(name, "resumed reply == never-parked reply", resumed.text == never.text && !never.text.isEmpty,
              resumed.text == never.text ? "identical: \"\(short(never.text, 60))\"" : "resumed \"\(short(resumed.text, 50))\" vs never \"\(short(never.text, 50))\"")
    } else {
        check(name, "resume A from flash", false, "error \(String(describing: resumed.error ?? cold.error))")
    }

    // 4. A three-speaker scene: assistantPrefix forces the speaker, stop strings end the line.
    let sceneSystem = """
    This is a group conversation in Lantern Bay, at the Harbor Bakery. Warm light, the smell of cinnamon, rain on the windows.
    It is evening.

    Who is here:
    - Juno, a sea otter: Runs the harbor bakery. Talks like: short, warm sentences, calls people "friend".
    - Theo, a heron: Runs the little ferry. Talks like: slow, dry humor, loves a long story.
    - Mira, a fox: Keeps the library. Talks like: quick and curious, quotes books.
    - Sam: likes rainy days and old songs.

    Rules:
    - Write only the next line for the one character named at the start of the reply. One or two sentences in their own voice.
    - Characters may talk to each other and to Sam. Keep it cozy and natural; react to what was just said.
    - Never write lines for Sam or narrate what Sam does.
    """
    let sceneTurns = [ChatTurn(role: .system, content: sceneSystem),
                      ChatTurn(role: .user, content: "Evening, everyone! Did anyone see the fog roll in?"),
                      ChatTurn(role: .assistant, content: "Theo: Saw it from the ferry. Thick as porridge, and twice as quiet."),
                      ChatTurn(role: .assistant, content: "Juno: Good thing I made extra porridge, then.")]
    let stops = ["\nJuno:", "\nTheo:", "\nMira:", "\nSam:", "\nYou:"]
    let scene = await collect(engine, GenerationRequest(conversationKey: "lab-scene", turns: sceneTurns, assistantPrefix: "Mira:",
                                                        maxTokens: 80, stop: stops, sampling: sampling(7)))
    allRuns.append(scene)
    let leaked = stops.contains { scene.text.contains($0) }
    check(name, "scene line (prefix Mira:)", scene.error == nil && !leaked && !scene.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          "stop \(scene.stats?.stoppedBy ?? "-"): \"Mira:\(short(scene.text))\"")
    // A script-like history makes small models want to keep writing other speakers; the stop must catch it.
    let scriptTurns = [ChatTurn(role: .system, content: sceneSystem),
                       ChatTurn(role: .user, content: "Tell me a story together, one line each, going around the room!"),
                       ChatTurn(role: .assistant, content: "Theo: Once, a lantern floated out to sea.\nJuno: It bumped into a sleepy whale.\nMira: The whale asked it for directions home.\nTheo: The lantern said, follow the light.\nJuno: So the whale did.")]
    var scriptHits = 0
    var scriptLeaks = 0
    for s in UInt32(1)...UInt32(4) {
        let r = await collect(engine, GenerationRequest(conversationKey: "lab-scene", turns: scriptTurns, assistantPrefix: "Mira:",
                                                        maxTokens: 120, stop: stops, sampling: sampling(s)))
        allRuns.append(r)
        if r.stats?.stoppedBy == "stop" { scriptHits += 1 }
        if stops.contains(where: { r.text.contains($0) }) { scriptLeaks += 1 }
    }
    check(name, "stop strings in a round-robin scene", scriptLeaks == 0, "\(scriptHits)/4 runs ended on a stop string, \(scriptLeaks) leaked")
    let period = await collect(engine, GenerationRequest(conversationKey: "lab-scene", turns: sceneTurns, assistantPrefix: "Mira:",
                                                         maxTokens: 80, stop: ["."], sampling: sampling(7)))
    allRuns.append(period)
    check(name, "forced stop (\".\")", period.stats?.stoppedBy == "stop" && !period.text.contains("."),
          "stop \(period.stats?.stoppedBy ?? "-"): \"\(short(period.text))\"")

    // 5. Cancel mid-stream.
    let story = turns1 + [ChatTurn(role: .assistant, content: basic.text),
                          ChatTurn(role: .user, content: "Tell me a long story about the lighthouse, with lots of detail.")]
    let cancelled = await collect(engine, GenerationRequest(conversationKey: "lab-basic", turns: story, maxTokens: 300, sampling: sampling(3)), cancelAfter: 5)
    allRuns.append(cancelled)
    if let s = cancelled.stats, let at = cancelled.piecesAtCancel {
        let overshoot = s.generatedTokens - at
        check(name, "cancel mid-stream", s.stoppedBy == "cancelled" && s.generatedTokens < 300 && (cancelled.cancelToDoneMs ?? 999) < 250,
              String(format: "cancelled after %d pieces; engine made %d tokens (%d after the cancel call, incl. buffered), done %.0f ms later",
                     at, s.generatedTokens, overshoot, cancelled.cancelToDoneMs ?? -1))
    } else {
        check(name, "cancel mid-stream", false, "never reached 5 pieces or no stats (\(cancelled.pieces.count) pieces)")
    }

    // 6. Emoji and other multi-byte text, end to end.
    let emojiTurns = [ChatTurn(role: .system, content: "You repeat text exactly. Reply with only the text, nothing else."),
                      ChatTurn(role: .user, content: "Repeat exactly: 🪼🦭🪸 café 你好 🧜🏽‍♀️")]
    let emoji = await collect(engine, GenerationRequest(conversationKey: "lab-emoji", turns: emojiTurns, maxTokens: 40, sampling: sampling(1)))
    allRuns.append(emoji)
    let replacement = emoji.pieces.contains { $0.contains("\u{FFFD}") }
    let hasEmoji = emoji.text.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    check(name, "emoji UTF-8 stream", !replacement && hasEmoji, "\(emoji.pieces.count) pieces, no U+FFFD: \"\(short(emoji.text, 60))\"")

    // 7. Overflow: prompt + maxTokens beyond n_ctx throws, and the engine keeps working afterwards.
    let huge = [ChatTurn(role: .system, content: junoSystem),
                ChatTurn(role: .user, content: String(repeating: "lantern ", count: spec.contextLength + 200))]
    let overflow = await collect(engine, GenerationRequest(conversationKey: "lab-basic", turns: huge, maxTokens: 64))
    var isOverflow = false
    if let e = overflow.error as? EngineError, case .contextOverflow = e { isOverflow = true }
    let after = await collect(engine, GenerationRequest(conversationKey: "lab-basic", turns: turns2, maxTokens: 16, sampling: sampling(42)))
    allRuns.append(after)
    check(name, "context overflow error", isOverflow && overflow.doneEvents == 0 && after.error == nil && (after.stats?.reusedTokens ?? 0) > 0,
          "threw \(overflow.error.map { "\($0)" } ?? "nothing"); next request still reused \(after.stats?.reusedTokens ?? 0) tokens")

    // Every finished stream carried exactly one .done, and nothing after it.
    let finished = allRuns.filter { $0.error == nil }
    check(name, "exactly one .done per stream", finished.allSatisfy { $0.doneEvents == 1 && $0.eventsAfterDone == 0 }, "\(finished.count) streams")

    await engine.purgeParkedState()
    await engine.shutdown()
    numbers.append(n)
}

/// Uses the model's own tokenizer to show that some tokens really are partial UTF-8, and that they reassemble.
@MainActor func tokenizerUTF8Check(modelPath: String) {
    var params = llama_model_default_params()
    params.vocab_only = true
    guard let model = llama_model_load_from_file(modelPath, params) else { return }
    defer { llama_model_free(model) }
    guard let vocab = llama_model_get_vocab(model) else { return }
    let text = "🪼🦭🪸 café 你好 🧜🏽‍♀️"
    let tokens = LlamaEngine.tokenize(text, vocab: vocab, addSpecial: false)
    var assembler = UTF8Assembler()
    var rebuilt = ""
    var partial = 0
    for token in tokens {
        let bytes = LlamaEngine.piece(token, vocab: vocab)
        if String(bytes: bytes, encoding: .utf8) == nil { partial += 1 }
        rebuilt += assembler.append(bytes)
    }
    let name = URL(fileURLWithPath: modelPath).lastPathComponent
    check(name, "tokenizer split UTF-8", rebuilt == text, "\(tokens.count) tokens, \(partial) of them partial UTF-8, rebuilt exactly: \(rebuilt == text)")
}

@MainActor func appleChecks() async {
    let m = "apple"
    guard AppleEngine.isAvailable else {
        notes.append("Apple's model was not available on this Mac: \(AppleEngine.unavailableReason ?? "unknown").")
        return
    }
    let engine = AppleEngine()
    let turns = [ChatTurn(role: .system, content: junoSystem),
                 ChatTurn(role: .assistant, content: "*waves a floury paw* Evening, friend!"),
                 ChatTurn(role: .user, content: "Hi Juno! What are you baking tonight?")]
    let basic = await collect(engine, GenerationRequest(conversationKey: "apple", turns: turns, maxTokens: 80))
    check(m, "basic chat", basic.error == nil && !basic.text.isEmpty && basic.doneEvents == 1,
          "ttft \(ms(basic.stats?.timeToFirstToken ?? 0)), stop \(basic.stats?.stoppedBy ?? "-"): \"\(short(basic.error.map { "\($0)" } ?? basic.text))\"")
    let long = longConversation(junoSystem, greeting: "Evening, friend!", rounds: 60) + [ChatTurn(role: .user, content: "What should I bake this weekend?")]
    let trimmed = await collect(engine, GenerationRequest(conversationKey: "apple", turns: long, maxTokens: 80))
    check(m, "long history trimmed to fit", trimmed.error == nil && !trimmed.text.isEmpty,
          "~\(trimmed.stats?.promptTokens ?? 0) prompt tokens: \"\(short(trimmed.error.map { "\($0)" } ?? trimmed.text))\"")
    let sceneTurns = [ChatTurn(role: .system, content: "This is a group conversation in Lantern Bay, at the bakery. Juno is a sea otter baker, Theo a heron ferryman, Mira a fox librarian."),
                      ChatTurn(role: .user, content: "Evening, everyone! Did anyone see the fog?"),
                      ChatTurn(role: .assistant, content: "Theo: Saw it from the ferry. Thick as porridge.")]
    let scene = await collect(engine, GenerationRequest(conversationKey: "apple", turns: sceneTurns, assistantPrefix: "Mira:", maxTokens: 60,
                                                        stop: ["\nJuno:", "\nTheo:", "\nSam:"]))
    check(m, "scene line without label", scene.error == nil && !scene.text.isEmpty && !scene.text.lowercased().hasPrefix("mira:"),
          "\"\(short(scene.error.map { "\($0)" } ?? scene.text))\"")
    let cancel = await collect(engine, GenerationRequest(conversationKey: "apple", turns: turns + [ChatTurn(role: .assistant, content: "Buns!"), ChatTurn(role: .user, content: "Tell me a long, detailed story about the lighthouse.")], maxTokens: 400), cancelAfter: 3)
    check(m, "cancel", cancel.stats?.stoppedBy == "cancelled" && cancel.doneEvents == 1,
          "stop \(cancel.stats?.stoppedBy ?? "-"), \(cancel.pieces.count) pieces, done \(String(format: "%.0f", cancel.cancelToDoneMs ?? -1)) ms after cancel")
}

/// Runs the app's own EngineHost + HearthBenchmark (SPEC §12) with the model placed in Documents,
/// the way a USB push puts it on the iPhone. Returns the benchmark's summary line.
@MainActor func benchCheck(modelPath: String) async -> [String: Any]? {
    let m = "host+bench"
    let fm = FileManager.default
    let source = URL(fileURLWithPath: modelPath)
    let placed = HearthPaths.documents.appendingPathComponent(source.lastPathComponent)
    let benchFile = HearthPaths.documents.appendingPathComponent("bench.jsonl")
    HearthPaths.ensure(HearthPaths.documents)
    try? fm.removeItem(at: placed)
    try? fm.removeItem(at: benchFile)
    do {
        try fm.linkItem(at: source, to: placed) // a hard link: no extra disk space
    } catch {
        check(m, "place model in Documents", false, "couldn't hard-link \(source.lastPathComponent): \(error.localizedDescription)")
        return nil
    }
    defer { try? fm.removeItem(at: placed) }
    let expected = ModelCatalog.all.first { $0.fileName == source.lastPathComponent }?.id ?? "?"
    let host = EngineHost()
    await host.start(preferredEngineID: nil)
    check(m, "EngineHost picks the model in Documents", host.state == .ready && host.active?.id == expected,
          "state \(host.state), active \(host.active?.id ?? "none"), installed \(host.installedModels.map(\.id))")
    guard host.state == .ready else { return nil }
    await HearthBenchmark.run(host: host)
    let lines = (try? String(contentsOf: benchFile, encoding: .utf8))?.split(separator: "\n") ?? []
    let objects = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    let summary = objects.last?["summary"] as? [String: Any]
    let restores = objects.filter { $0["phase"] as? String == "restore" }
    let allRestored = !restores.isEmpty && restores.allSatisfy { $0["restoredFromDisk"] as? Bool == true }
    let speedup = (summary?["resumeSpeedup"] as? NSNumber)?.doubleValue ?? 0
    check(m, "benchmark: 5 characters, all restored from flash", summary != nil && restores.count == 5 && allRestored,
          "\(objects.count) HEARTHBENCH lines, \(restores.count) restores, resume speedup \(f1(speedup))x")
    check(m, "benchmark cleans up its parked files", host.parkedBytes() == 0, "\(host.parkedBytes()) bytes left")
    await host.switchTo(engineID: "mock")
    check(m, "switch to demo engine unloads the model", host.state == .ready && host.active?.id == "mock", "active \(host.active?.id ?? "none")")
    return summary
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
var resultsPath: String?
if let i = args.firstIndex(of: "--results"), i + 1 < args.count {
    resultsPath = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let wantApple = args.contains("--apple")
var benchModel: String?
if let i = args.firstIndex(of: "--bench"), i + 1 < args.count {
    benchModel = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
let models = args.filter { $0.hasSuffix(".gguf") }

let kvRoot = HearthPaths.kvCache.appendingPathComponent("enginelab", isDirectory: true)
print("EngineLab: Hearth engine checks on \(models.count) model(s); KV files in \(kvRoot.path)")
let labStart = Date()
pureChecks()
await mockChecks()
for path in models {
    tokenizerUTF8Check(modelPath: path)
    await llamaChecks(modelPath: path, kvRoot: kvRoot)
}
if wantApple { await appleChecks() }
var benchSummary: [String: Any]?
if let benchModel { benchSummary = await benchCheck(modelPath: benchModel) }
try? FileManager.default.removeItem(at: kvRoot)

let failed = rows.filter { !$0.passed }
let seconds = Date().timeIntervalSince(labStart)
print("\nEngineLab: \(rows.count - failed.count)/\(rows.count) checks passed in \(Int(seconds)) s")

if let resultsPath {
    var chip = [CChar](repeating: 0, count: 128)
    var length = chip.count
    sysctlbyname("machdep.cpu.brand_string", &chip, &length, nil, 0)
    let machine = String(cString: chip)
    let date = ISO8601DateFormatter().string(from: Date())
    var md = """
    # EngineLab results

    Generated by `ios/EngineLab/run.sh` on \(date) (\(machine), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)).
    It compiles the app's real `Engine/` sources for macOS and runs them on llama.cpp b12180's macOS slice (Metal),
    with the same settings as the iPhone: n_gpu_layers 999, mmap, n_batch 512, flash attention, q8_0 KV cache.
    Mac numbers are much faster than an iPhone's; on-device numbers come from `-HearthBenchmark 1`.

    **\(rows.count - failed.count) of \(rows.count) checks passed** in \(Int(seconds)) s.

    ## Speed and instant resume

    | Model | Load | TTFT (turn 1) | Prefill | Decode | Turn 2: reused / new tokens, TTFT | Park on switch | Restore from flash | TTFT restored vs re-read |
    |---|---|---|---|---|---|---|---|---|

    """
    for x in numbers {
        md += String(format: "| %@ | %.0f ms | %.0f ms | %.0f tok/s | %.1f tok/s | %d / %d, %.0f ms | %d tokens, %.1f MB, %.0f ms | %.0f ms | %.0f ms vs %.0f ms |\n",
                     x.model, x.loadMs, x.ttftMs, x.prefillTPS, x.decodeTPS, x.secondTurnReused, x.secondTurnPrefilled, x.secondTurnTTFTMs,
                     x.parkedTokens, x.parkedMB, x.parkMs, x.restoreMs, x.restoredTTFTMs, x.coldTTFTMs)
    }
    if let b = benchSummary {
        func v(_ key: String) -> String { (b[key] as? NSNumber).map { "\($0)" } ?? "-" }
        md += """

        ## HearthBenchmark through EngineHost (\(b["model"] as? String ?? "?"))

        The app's own `-HearthBenchmark 1` code, run here on the Mac: 5 characters with ~\(v("avgPromptTokens"))-token prompts.
        Cold read: TTFT \(v("avgColdTTFTMs")) ms, prefill \(v("avgPrefillTokPerSec")) tok/s, decode \(v("avgDecodeTokPerSec")) tok/s.
        Park on switch: \(v("avgParkMs")) ms for \(v("avgParkMB")) MB. Restore from flash: \(v("avgRestoreMs")) ms.
        Coming back to a conversation: TTFT \(v("avgTTFTRestoredMs")) ms restored vs \(v("avgTTFTColdMs")) ms re-reading it (\(v("resumeSpeedup"))x faster).

        """
    }
    md += "\n## Checks\n\n| Model | Check | Result | Details |\n|---|---|---|---|\n"
    for r in rows {
        md += "| \(r.model) | \(r.test) | \(r.passed ? "PASS" : "**FAIL**") | \(r.detail.replacingOccurrences(of: "|", with: "/")) |\n"
    }
    if !notes.isEmpty { md += "\n## Notes\n\n" + notes.map { "- \($0)" }.joined(separator: "\n") + "\n" }
    try? md.write(toFile: resultsPath, atomically: true, encoding: .utf8)
    print("Wrote \(resultsPath)")
}
exit(failed.isEmpty ? 0 : 1)
