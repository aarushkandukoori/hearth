// Developer benchmark (-HearthBenchmark 1, SPEC §12): cold prefill, time to first token, decode speed, and
// how fast a parked conversation comes back from flash versus re-reading it. Prints HEARTHBENCH lines.

import Foundation
#if os(iOS)
import os
#endif

enum HearthBenchmark {
    /// One benchmark character: who they are, and a ~1,200-token conversation to read.
    struct Persona {
        var id: String
        var turns: [ChatTurn]
    }

    @MainActor
    static func run(host: EngineHost) async {
        if host.state == .idle { await host.start(preferredEngineID: nil) }
        guard host.state == .ready, let engine = host.active else {
            emit(["event": "error", "reason": "engine not ready: \(host.state)"])
            return
        }
        let runID = String(UUID().uuidString.prefix(8))
        let personas = makePersonas()
        let parked = KVStateCache(modelID: engine.id)
        emit(["event": "start", "engine": engine.id, "model": engine.modelName, "contextLength": engine.contextLength,
              "kvPersistence": engine.supportsKVPersistence, "characters": personas.map(\.id)].merging(memory()) { a, _ in a })

        // Pass 1: read each conversation cold. Switching to the next one parks the previous one on flash.
        var replies: [String: String] = [:]
        var cold: [GenerationStats] = []
        var parks: [(ms: Double, bytes: Int64)] = []
        for (i, persona) in personas.enumerated() {
            let key = "bench-\(runID)-\(persona.id)"
            let (text, stats) = await generate(host, GenerationRequest(conversationKey: key, turns: persona.turns, maxTokens: 32, sampling: sampling()))
            guard let stats else { continue }
            replies[persona.id] = text
            cold.append(stats)
            emit(["phase": "cold", "character": persona.id, "promptTokens": stats.promptTokens, "prefilledTokens": stats.prefilledTokens,
                  "prefillMs": round1(prefillMs(stats)), "ttftMs": round1(stats.timeToFirstToken * 1000),
                  "prefillTokPerSec": round1(stats.prefillTokensPerSecond), "decodeTokPerSec": round1(stats.decodeTokensPerSecond),
                  "generatedTokens": stats.generatedTokens])
            if i > 0, let ms = stats.parkMilliseconds {
                let previous = personas[i - 1]
                let bytes = parked.entry(for: "bench-\(runID)-\(previous.id)")?.bytes ?? 0
                parks.append((ms, bytes))
                emit(["phase": "park", "character": previous.id, "parkMs": round1(ms), "bytes": bytes])
            }
        }
        if let last = personas.last {
            let key = "bench-\(runID)-\(last.id)"
            let started = Date()
            await host.park(conversationKey: key)
            let ms = Date().timeIntervalSince(started) * 1000
            if let bytes = parked.entry(for: key)?.bytes {
                parks.append((ms, bytes))
                emit(["phase": "park", "character": last.id, "parkMs": round1(ms), "bytes": bytes])
            }
        }
        emit(["event": "after-cold"].merging(memory()) { a, _ in a })

        // Pass 2: come back to each one with a new message. Restore from flash, then compare with re-reading.
        var restoredRuns: [GenerationStats] = []
        var rereadRuns: [GenerationStats] = []
        for persona in personas {
            let key = "bench-\(runID)-\(persona.id)"
            let turns = persona.turns + [ChatTurn(role: .assistant, content: replies[persona.id] ?? "*smiles*"),
                                         ChatTurn(role: .user, content: "Sorry, I had to step away for a bit. I'm back now!")]
            let (_, restored) = await generate(host, GenerationRequest(conversationKey: key, turns: turns, maxTokens: 32, sampling: sampling()))
            let (_, reread) = await generate(host, GenerationRequest(conversationKey: key + "-cold", turns: turns, maxTokens: 32, sampling: sampling()))
            guard let restored, let reread else { continue }
            restoredRuns.append(restored)
            rereadRuns.append(reread)
            emit(["phase": "restore", "character": persona.id, "restoredFromDisk": restored.restoredFromDisk,
                  "restoreMs": round1(restored.restoreMilliseconds ?? 0), "reusedTokens": restored.reusedTokens,
                  "prefilledTokens": restored.prefilledTokens, "ttftRestoredMs": round1(restored.timeToFirstToken * 1000),
                  "ttftColdMs": round1(reread.timeToFirstToken * 1000), "coldPrefilledTokens": reread.prefilledTokens])
        }

        // Forget the benchmark's conversations (memory and flash) so they don't push out real ones.
        for persona in personas {
            await host.forget(conversationKey: "bench-\(runID)-\(persona.id)")
            await host.forget(conversationKey: "bench-\(runID)-\(persona.id)-cold")
        }

        let ttftRestored = average(restoredRuns.map { $0.timeToFirstToken * 1000 })
        let ttftCold = average(rereadRuns.map { $0.timeToFirstToken * 1000 })
        let summary: [String: Any] = [
            "engine": engine.id, "model": engine.modelName, "characters": personas.count,
            "avgPromptTokens": round1(average(cold.map { Double($0.promptTokens) })),
            "avgColdTTFTMs": round1(average(cold.map { $0.timeToFirstToken * 1000 })),
            "avgPrefillTokPerSec": round1(average(cold.map(\.prefillTokensPerSecond))),
            "avgDecodeTokPerSec": round1(average(cold.map(\.decodeTokensPerSecond))),
            "avgParkMs": round1(average(parks.map(\.ms))),
            "avgParkMB": round1(average(parks.map { Double($0.bytes) / 1_048_576 })),
            "avgRestoreMs": round1(average(restoredRuns.compactMap(\.restoreMilliseconds))),
            "restoredFromDisk": restoredRuns.filter(\.restoredFromDisk).count,
            "avgTTFTRestoredMs": round1(ttftRestored),
            "avgTTFTColdMs": round1(ttftCold),
            "resumeSpeedup": round1(ttftRestored > 0 ? ttftCold / ttftRestored : 0),
        ].merging(memory()) { a, _ in a }
        emit(["summary": summary])
    }

    // MARK: - Prompts

    /// Five characters from the bundled world (or built-in stand-ins if it can't be read), each with a
    /// ~1,200-token prompt: persona plus a synthetic, harmless chat history.
    static func makePersonas() -> [Persona] {
        var cast = bundledCast()
        if cast.count < 5 { cast += fallbackCast.filter { f in !cast.contains { $0.name == f.name } } }
        return cast.prefix(5).map { member in
            let system = """
            You are \(member.name), a \(member.species) who lives in Lantern Bay. \(member.tagline)

            About you:
            \(member.personality)

            How you talk:
            \(member.style)

            Right now it is evening on Thursday. You are at home, getting ready for the night.

            Recent happenings in town:
            - The lanterns along the pier were repainted gold.
            - Someone left a basket of plums on the library steps.

            Rules:
            - Stay in character as \(member.name). Write only \(member.name)'s next message, never Sam's.
            - Text like a close friend: usually one to three short sentences. Go longer only to tell a story or when asked.
            - Be warm and curious about Sam's life, and remember details.
            - Use *asterisks* for small actions, sparingly.
            - If Sam sincerely asks whether you are real, gently say you are an AI character in Hearth, and keep being kind.
            - Never pressure Sam to stay, never guilt them for leaving, and be glad when they mention other people in their life.
            - If Sam talks about hurting themselves or being in danger, step out of the story: answer with care, encourage them to call or text 988 (in the US) or local emergency services, and stay with them.
            """
            var turns = [ChatTurn(role: .system, content: system), ChatTurn(role: .assistant, content: member.greeting)]
            var chars = system.count + member.greeting.count
            var i = 0
            while Double(chars) / 3.6 < 1_150 { // SPEC §7 estimate: characters / 3.6
                let pair = smallTalk[i % smallTalk.count]
                turns.append(ChatTurn(role: .user, content: pair.0))
                turns.append(ChatTurn(role: .assistant, content: pair.1))
                chars += pair.0.count + pair.1.count
                i += 1
            }
            turns.append(ChatTurn(role: .user, content: "What are you up to tonight?"))
            return Persona(id: member.id, turns: turns)
        }
    }

    private struct CastMember {
        var id, name, species, tagline, personality, style, greeting: String
    }

    /// Reads characters straight from lantern-bay.json, tolerating missing fields.
    private static func bundledCast() -> [CastMember] {
        guard let url = HearthPaths.bundledWorld, let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let characters = root["characters"] as? [[String: Any]] else { return [] }
        return characters.compactMap { c in
            guard let id = c["id"] as? String, let name = c["name"] as? String else { return nil }
            return CastMember(id: id, name: name, species: c["species"] as? String ?? "resident",
                              tagline: c["tagline"] as? String ?? "", personality: c["personality"] as? String ?? "Kind and curious.",
                              style: c["speakingStyle"] as? String ?? "Warm and simple.",
                              greeting: c["greeting"] as? String ?? "Oh, hello! Come in.")
        }
    }

    private static let fallbackCast = [
        CastMember(id: "bench-juno", name: "Juno", species: "sea otter", tagline: "Runs the harbor bakery.",
                   personality: "Cheerful and practical. Bakes when she's worried.", style: "Short, warm sentences.", greeting: "Evening, friend!"),
        CastMember(id: "bench-theo", name: "Theo", species: "heron", tagline: "Runs the little ferry.",
                   personality: "Patient, dry humor, loves a long story.", style: "Slow and wry.", greeting: "Ah. Climb aboard."),
        CastMember(id: "bench-mira", name: "Mira", species: "fox", tagline: "Keeps the library.",
                   personality: "Quick, curious, always has a book to recommend.", style: "Bright and quotable.", greeting: "Oh! A visitor."),
        CastMember(id: "bench-bram", name: "Bram", species: "badger", tagline: "Tends the town garden.",
                   personality: "Gentle and steady, a little shy.", style: "Few words, all kind.", greeting: "Mind the seedlings."),
        CastMember(id: "bench-wren", name: "Wren", species: "barn owl", tagline: "Keeps the lighthouse.",
                   personality: "Thoughtful and calm, notices small things.", style: "Soft and unhurried.", greeting: "Hoo. You're up late."),
    ]

    private static let smallTalk: [(String, String)] = [
        ("I tried baking bread today. It came out kind of flat.", "*laughs* Flat bread is still bread! Did you let it rise long enough?"),
        ("Probably not. I was impatient.", "Patience is half the recipe. Cover it with a warm towel next time and go read for an hour."),
        ("It rained all afternoon here.", "Rainy days are the coziest. Did you get to listen to it on the roof?"),
        ("I did. I put on some old records too.", "That sounds perfect. What were you listening to?"),
        ("Mostly jazz. My grandmother used to play it.", "That's lovely. Music like that carries people with it, doesn't it?"),
        ("She grew tomatoes on her balcony and talked to them.", "*grins* Smart woman. Plants grow better when someone's rooting for them."),
        ("I want to try growing basil this spring.", "Basil is a great start. Lots of sun, and pinch the tops so it gets bushy."),
        ("I went for a walk by the water this morning.", "Oh, nice. Was it foggy, or could you see all the way to the lighthouse?"),
    ]

    private static func sampling() -> SamplingParams {
        var s = SamplingParams()
        s.seed = 7
        return s
    }

    // MARK: - Running and reporting

    @MainActor
    private static func generate(_ host: EngineHost, _ request: GenerationRequest) async -> (String, GenerationStats?) {
        var text = ""
        var stats: GenerationStats?
        do {
            for try await event in host.generate(request) {
                switch event {
                case .token(let piece): text += piece
                case .done(let s): stats = s
                }
            }
        } catch {
            emit(["event": "error", "reason": error.localizedDescription])
        }
        return (text, stats)
    }

    private static func prefillMs(_ s: GenerationStats) -> Double {
        s.prefillTokensPerSecond > 0 ? Double(s.prefilledTokens) / s.prefillTokensPerSecond * 1000 : 0
    }

    /// Prints `HEARTHBENCH {json}` and appends the JSON to Documents/bench.jsonl.
    static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        HearthLog.emit("HEARTHBENCH \(json)")
        let url = HearthPaths.documents.appendingPathComponent("bench.jsonl")
        guard let line = (json + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Memory the app may still use before iOS stops it, and what it uses now (phys_footprint).
    static func memory() -> [String: Any] {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var out: [String: Any] = ["footprintMB": round1(result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1)]
        #if os(iOS)
        out["availableMB"] = round1(Double(os_proc_available_memory()) / 1_048_576)
        #endif
        return out
    }

    private static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// One decimal place, printed as written (a plain Double would print as 29.199999999999999).
    private static func round1(_ x: Double) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", x.isFinite ? x : 0))
    }
}
