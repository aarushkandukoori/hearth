// Developer sweep (-HearthSweep 1): controlled measurements of Pie on this iPhone, for the research figures.
//
// E1 "length": target prompt lengths 512 to 3,328 tokens, three trials, the lengths shuffled in each trial.
//   (3,328 is the longest the app's own size check lets all three requests through; it counts 6 tokens a turn.)
//   cold     read a new chat (a unique tag starts the system prompt, so nothing can match)
//   reuse    send that chat one more message right away: Pie maps in the turns it just read
//   control  the same longer chat with a second unique tag at the start, so Pie must compute all of it
// E2 "turns": one ~1,000-token chat carried on for 12 more turns. All the controls (each turn's prompt with a
//   unique tag) run first, then the chain itself, where each turn reuses the one before. Running the controls
//   first puts the reuse runs on the warmer phone, which can only make them look slower.
// E3 "retention": read chat X, then K other new chats, then come back to X with a new message, and record how
//   much of X Pie still held. K = 0, 1, 2, 4; three trials, K shuffled in each.
//
// Every request writes one HEARTHSWEEP line (also Documents/sweep.jsonl): tokens, the inferlet's own time to
// first token, the app's wall-clock time to the first streamed piece, memory, power and thermal state.
// The run first lets the phone cool to "fair" or better (up to 2 minutes). After that no request waits unless iOS
// reports "critical": waiting out "serious" while charging took minutes per request, so throttling is recorded
// instead (every line carries the thermal state) and analyzed as a variable. A request that comes back cancelled (the app left the screen) is
// logged and run again once Hearth is back in front.

import Foundation
#if os(iOS)
import UIKit
#endif

enum PieSweep {
    static let lengths = [512, 1_024, 1_536, 2_048, 2_560, 3_072, 3_328]
    static let retentionK = [0, 1, 2, 4]
    static let trials = 3
    /// Real tokens per estimated token (characters / 3.6) for these prompts: the benchmark's 1,150 estimate
    /// came out at 1,289 to 1,321 tokens.
    static let tokensPerEstimate = 1.135
    static let file = "sweep.jsonl"
    static let backMessage = "Sorry, I had to step away for a bit. I'm back now!"

    @MainActor
    static func run(host: EngineHost) async {
        if host.state == .idle { await host.start(preferredEngineID: nil) }
        guard host.state == .ready, let engine = host.active else {
            emit(["event": "error", "reason": "engine not ready: \(host.state)"])
            return
        }
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true // the phone must not lock in the middle of the run
        UIDevice.current.isBatteryMonitoringEnabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        try? FileManager.default.removeItem(at: HearthPaths.documents.appendingPathComponent(file))
        let sweep = SweepRun(host: host)
        await sweep.coolDown(above: .fair, limit: 120)
        emit(["event": "start", "run": sweep.runID, "engine": engine.id, "model": engine.modelName,
              "contextLength": engine.contextLength, "lengths": lengths, "retentionK": retentionK, "trials": trials,
              "device": deviceModel(), "os": ProcessInfo.processInfo.operatingSystemVersionString,
              "thermal": thermal()].merging(power()) { a, _ in a }.merging(HearthBenchmark.memory()) { a, _ in a })
        await sweep.lengthSweep()
        await sweep.turnSweep()
        await sweep.retentionSweep()
        emit(["event": "done", "run": sweep.runID, "requests": sweep.seq,
              "seconds": HearthBenchmark.round1(Date().timeIntervalSince(sweep.started)), "thermal": thermal()]
            .merging(power()) { a, _ in a }.merging(HearthBenchmark.memory()) { a, _ in a })
        HearthLog.emit("HEARTHSWEEP DONE")
    }

    static func emit(_ object: [String: Any]) {
        HearthBenchmark.emit(object, marker: "HEARTHSWEEP", file: file)
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// Low Power Mode slows the GPU a lot, so every record says whether it was on, with the battery.
    @MainActor
    static func power() -> [String: Any] {
        var out: [String: Any] = ["lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled]
        #if os(iOS)
        let device = UIDevice.current
        out["battery"] = HearthBenchmark.round1(Double(device.batteryLevel) * 100)
        out["batteryState"] = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        #endif
        return out
    }

    /// The hardware model, e.g. "iPhone17,1" (iPhone 16 Pro).
    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// E2's conversation after the opening chat: (the character's reply, Sam's next message).
    static let script: [(String, String)] = [
        ("*stretches* Just finished stacking firewood for the weekend. Now I'm making tea and thinking about those plums on the library steps. What about you?",
         "I'm trying to decide whether to start a new book or finish the one I gave up on last month."),
        ("Finish the old one first, I'd say. If a chapter in it still doesn't hold you, let it go with no guilt. What was it about?",
         "It's a long novel about a family that runs a lighthouse. Beautiful writing, but really slow."),
        ("Slow books are like slow walks. Sometimes the point is the scenery, not getting somewhere. Wren would adore that one.",
         "That's a nice way to put it. Maybe I'll read a chapter tonight with some tea."),
        ("Perfect plan. What kind of tea? I'm a mint person myself, but I won't judge.",
         "Chamomile, usually. My roommate says it tastes like hay."),
        ("*laughs* Your roommate isn't wrong, but hay is cozy! Add a little honey and it tastes like a summer field.",
         "I'll try that. Also, I finally called my sister today. We hadn't talked in weeks."),
        ("Oh, I'm so glad. How did it feel to hear her voice again?",
         "Really good. She's planning to visit next month, and I want to show her around."),
        ("That's wonderful. Where would you take her first?",
         "Probably the farmers market on Saturday morning, then the little bakery by the river."),
        ("A market and a bakery, you know the way to a sister's heart. Get there early, the good bread goes fast.",
         "Ha, noted. I'm a little nervous about cleaning the apartment before she comes, though."),
        ("One room a day. Put on music and it stops feeling like a chore. By the end of the week it's done.",
         "That actually sounds doable. Do you have a cleaning playlist?"),
        ("Old sea shanties, every time. Hard to be gloomy while you're singing about a whale.",
         "I'm going to need that playlist. Okay, I think I'll head to bed soon."),
        ("Sleep well, friend. Tell me tomorrow how the lighthouse book is going.",
         "I will. Thanks for the company tonight."),
        ("Anytime. *waves* The porch light's always on here.",
         "Goodnight!"),
    ]
}

/// One run of the sweep: numbering, timing and the shuffle all live here.
@MainActor
private final class SweepRun {
    let host: EngineHost
    let runID = String(UUID().uuidString.prefix(8))
    let started = Date()
    var seq = 0
    /// Fixed seed, so the shuffled orders are the same every run.
    var rng = SeededGenerator(seed: 20_261_108)

    init(host: EngineHost) {
        self.host = host
    }

    // MARK: Experiments

    func lengthSweep() async {
        for trial in 1...PieSweep.trials {
            for (i, target) in PieSweep.lengths.shuffled(using: &rng).enumerated() {
                let common: [String: Any] = ["exp": "length", "trial": trial, "target": target, "order": i]
                let base = chat(tokens: target, character: trial + i)
                let reply = await measure(base, maxTokens: 24, with(common, ["kind": "cold"]))
                let next = base + [ChatTurn(role: .assistant, content: nonEmpty(reply)),
                                   ChatTurn(role: .user, content: PieSweep.backMessage)]
                await measure(next, maxTokens: 24, with(common, ["kind": "reuse"]))
                await measure(tagged(next), maxTokens: 24, with(common, ["kind": "control"]))
            }
        }
    }

    func turnSweep() async {
        var turns = chat(tokens: 1_024, character: 2)
        var prompts = [turns]
        for (reply, message) in PieSweep.script {
            turns += [ChatTurn(role: .assistant, content: reply), ChatTurn(role: .user, content: message)]
            prompts.append(turns)
        }
        for (step, prompt) in prompts.enumerated() {
            await measure(tagged(prompt), maxTokens: 24, ["exp": "turns", "step": step, "kind": "control"])
        }
        for (step, prompt) in prompts.enumerated() {
            await measure(prompt, maxTokens: 24, ["exp": "turns", "step": step, "kind": step == 0 ? "cold" : "reuse"])
        }
    }

    func retentionSweep() async {
        for trial in 1...PieSweep.trials {
            for (i, k) in PieSweep.retentionK.shuffled(using: &rng).enumerated() {
                let common: [String: Any] = ["exp": "retention", "trial": trial, "k": k, "order": i]
                let x = chat(tokens: 768, character: trial)
                let reply = await measure(x, maxTokens: 16, with(common, ["kind": "first"]))
                for j in 0..<k {
                    await measure(chat(tokens: 768, character: trial + j + 1), maxTokens: 8, with(common, ["kind": "between", "j": j]))
                }
                let back = x + [ChatTurn(role: .assistant, content: nonEmpty(reply)),
                                ChatTurn(role: .user, content: PieSweep.backMessage)]
                await measure(back, maxTokens: 16, with(common, ["kind": "return"]))
            }
        }
    }

    // MARK: Helpers

    /// A new chat of about `tokens` tokens. Its system prompt starts with a fresh random tag, so Pie has never
    /// seen any of it.
    func chat(tokens: Int, character: Int) -> [ChatTurn] {
        let tag = "\(UUID().uuidString.prefix(8)) \(runID)"
        let personas = HearthBenchmark.makePersonas(tag: tag, estimatedTokens: Double(tokens) / PieSweep.tokensPerEstimate)
        return personas[character % personas.count].turns
    }

    /// The same chat with a unique tag at the very start, so nothing in it can match what Pie holds.
    func tagged(_ turns: [ChatTurn]) -> [ChatTurn] {
        var copy = turns
        copy[0].content = "[control \(UUID().uuidString.prefix(8))]\n" + copy[0].content
        return copy
    }

    func nonEmpty(_ reply: String?) -> String {
        let trimmed = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "*smiles*" : trimmed
    }

    func with(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        a.merging(b) { _, new in new }
    }

    /// Waits while the phone's thermal state is above `above` (by default only "critical" waits). Logs the wait.
    func coolDown(above: ProcessInfo.ThermalState = .serious, limit: TimeInterval = 300) async {
        func hot() -> Bool { ProcessInfo.processInfo.thermalState.rawValue > above.rawValue }
        guard hot() else { return }
        let from = PieSweep.thermal()
        let waitStarted = Date()
        while hot(), Date().timeIntervalSince(waitStarted) < limit {
            try? await Task.sleep(for: .seconds(2))
        }
        PieSweep.emit(["event": "cooldown", "run": runID, "afterSeq": seq, "from": from, "to": PieSweep.thermal(),
                       "seconds": HearthBenchmark.round1(Date().timeIntervalSince(waitStarted)),
                       "t": HearthBenchmark.round1(Date().timeIntervalSince(started))])
    }

    /// Requests can't use the GPU while Hearth is in the background, so wait until it is in front again.
    func waitForForeground() async {
        #if os(iOS)
        guard UIApplication.shared.applicationState != .active else { return }
        let waitStarted = Date()
        while UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .seconds(1))
        }
        PieSweep.emit(["event": "foreground", "run": runID, "afterSeq": seq,
                       "seconds": HearthBenchmark.round1(Date().timeIntervalSince(waitStarted))])
        #endif
    }

    /// Runs one request and writes its HEARTHSWEEP line, once more if it came back cancelled. Returns the text.
    @discardableResult
    func measure(_ turns: [ChatTurn], maxTokens: Int, _ fields: [String: Any]) async -> String? {
        for attempt in 1...2 {
            await waitForForeground()
            await coolDown()
            if let text = await once(turns, maxTokens: maxTokens, with(fields, ["attempt": attempt])) { return text }
        }
        return nil
    }

    /// One try. Returns nil when the request failed or was cancelled (logged as an error line).
    func once(_ turns: [ChatTurn], maxTokens: Int, _ fields: [String: Any]) async -> String? {
        seq += 1
        var sampling = SamplingParams()
        sampling.seed = 7
        let request = GenerationRequest(conversationKey: "sweep-\(runID)-\(seq)", turns: turns, maxTokens: maxTokens, sampling: sampling)
        let sent = Date()
        var firstPiece: TimeInterval?
        var text = ""
        var stats: GenerationStats?
        do {
            for try await event in host.generate(request) {
                switch event {
                case .token(let piece):
                    if firstPiece == nil { firstPiece = Date().timeIntervalSince(sent) }
                    text += piece
                case .done(let s):
                    stats = s
                }
            }
        } catch {
            PieSweep.emit(with(fields, ["event": "error", "run": runID, "seq": seq, "reason": error.localizedDescription]))
            return nil
        }
        guard let stats else {
            PieSweep.emit(with(fields, ["event": "error", "run": runID, "seq": seq, "reason": "no stats"]))
            return nil
        }
        guard stats.stoppedBy != "cancelled", stats.promptTokens > 0 else {
            PieSweep.emit(with(fields, ["event": "error", "run": runID, "seq": seq, "reason": "cancelled",
                                        "stoppedBy": stats.stoppedBy]))
            return nil
        }
        let r1 = HearthBenchmark.round1
        var record: [String: Any] = [
            "run": runID, "seq": seq, "t": r1(Date().timeIntervalSince(started)),
            "promptTokens": stats.promptTokens, "reusedTokens": stats.reusedTokens,
            "prefilledTokens": stats.prefilledTokens, "generatedTokens": stats.generatedTokens,
            "ttftMs": r1(stats.timeToFirstToken * 1000),
            "wallFirstMs": firstPiece.map { r1($0 * 1000) as Any } ?? NSNull(),
            "wallTotalMs": r1(Date().timeIntervalSince(sent) * 1000),
            "prefillTokPerSec": r1(stats.prefillTokensPerSecond), "decodeTokPerSec": r1(stats.decodeTokensPerSecond),
            "thermal": PieSweep.thermal(),
        ]
        record.merge(PieSweep.power()) { a, _ in a }
        record.merge(HearthBenchmark.memory()) { a, _ in a }
        record.merge(fields) { _, new in new }
        PieSweep.emit(record)
        return text
    }
}

/// SplitMix64: a small seeded generator for the shuffles.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
