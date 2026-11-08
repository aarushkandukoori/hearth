// MockEngine: canned, character-aware replies streamed word by word. No AI at all. Used for
// `-HearthEngine mock`, Simulator screenshots and unit tests; the same input always gives the same reply.

import Foundation

final class MockEngine: LanguageEngine, @unchecked Sendable {
    let descriptor = EngineDescriptor(id: "mock", displayName: "Demo replies", modelName: "Built-in demo (no AI)",
                                      contextLength: 8192, supportsKVPersistence: false)

    private let wordDelay: UInt64
    private let lock = NSLock()
    private var running: Task<Void, Never>?
    /// How often each exact input was answered, so "regenerate" gives a different canned reply.
    private var repeats: [UInt64: Int] = [:]

    /// `wordDelayMilliseconds` is the pause before each word (25 ms feels like typing).
    init(wordDelayMilliseconds: Int = 25) {
        wordDelay = UInt64(max(0, wordDelayMilliseconds)) * 1_000_000
    }

    func prepare() async throws {}

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let reply = compose(request)
        return AsyncThrowingStream { continuation in
            let task = Task { await self.stream(reply, request, continuation) }
            lock.withLock { running = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelCurrent() {
        lock.withLock { running?.cancel() }
    }

    func countTokens(_ text: String) async -> Int { (text.count + 3) / 4 }
    func park(conversationKey: String) async {}
    func purgeParkedState() async {}
    func shutdown() async { cancelCurrent() }

    // MARK: - Streaming

    private func stream(_ reply: String, _ request: GenerationRequest,
                        _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        let started = Date()
        let promptChars = request.turns.reduce(0) { $0 + $1.content.count }
        var stats = GenerationStats(engine: descriptor.id, promptTokens: (promptChars + 3) / 4, prefilledTokens: (promptChars + 3) / 4)
        var filter = StopFilter(request.stop)
        stats.stoppedBy = "eos"
        for word in Self.words(reply) {
            if stats.generatedTokens >= request.maxTokens {
                stats.stoppedBy = "maxTokens"
                break
            }
            if wordDelay > 0 { try? await Task.sleep(nanoseconds: wordDelay) }
            if Task.isCancelled {
                stats.stoppedBy = "cancelled"
                break
            }
            if stats.generatedTokens == 0 { stats.timeToFirstToken = Date().timeIntervalSince(started) }
            stats.generatedTokens += 1
            let visible = filter.feed(word)
            if !visible.isEmpty { continuation.yield(.token(visible)) }
            if filter.stopped {
                stats.stoppedBy = "stop"
                break
            }
        }
        let tail = filter.flush()
        if !tail.isEmpty { continuation.yield(.token(tail)) }
        let seconds = Date().timeIntervalSince(started) - stats.timeToFirstToken
        if stats.generatedTokens > 1, seconds > 0 { stats.decodeTokensPerSecond = Double(stats.generatedTokens - 1) / seconds }
        continuation.yield(.done(stats))
        continuation.finish()
    }

    /// Splits text into words that keep their leading space, so joining them gives the text back.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            if ch == " " || ch == "\n", !current.isEmpty, !current.allSatisfy({ $0 == " " || $0 == "\n" }) {
                out.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: - Canned replies

    func compose(_ request: GenerationRequest) -> String {
        let system = request.turns.first { $0.role == .system }?.content ?? ""
        let lastUser = request.turns.last { $0.role == .user }?.content ?? ""

        if system.hasPrefix("You pick out lasting facts") { return "- none" }
        if system.contains("town newsletter") { return newsletter(lastUser) }

        // A crisis reply already opens with the fixed caring words (shown by the caller): just continue.
        if let opener = request.replyOpener, !opener.isEmpty {
            return "Will you reach out to them, or text HOME to 741741? I'm right here with you."
        }
        // When the safety check flagged the last message, demo replies stay caring too (never cheerful).
        if request.turns.contains(where: { $0.content.contains("IMPORTANT note for") || $0.content.contains("- IMPORTANT: If") }) {
            return "*sets everything down and sits close* I'm really glad you told me. You matter, and you deserve support from a real person right now. If you're in the US, you can call or text 988 any time, or text HOME to 741741. Will you reach out to one of them? I'm right here with you."
        }
        // A heavy topic (PromptTemplates.noteConcern) gets a gentle reply.
        if request.turns.contains(where: { $0.content.contains("touched on something heavy") }) {
            return "*listens closely* Thank you for telling me. I'm right here, and we can talk about it as much or as little as you like."
        }

        let name = Self.speakerName(request)
        let seed = Self.fnv1a("\(name)|\(lastUser)|\(request.turns.count)")
        let variant: Int
        if let fixed = request.sampling.seed {
            variant = Int(truncatingIfNeeded: seed &+ UInt64(fixed))
        } else {
            variant = lock.withLock { () -> Int in
                let n = repeats[seed, default: 0]
                repeats[seed] = n + 1
                return Int(truncatingIfNeeded: seed) &+ n
            }
        }

        let place = Self.firstMatch(#"You are at ([^,.\n]+)"#, in: system)
        let pool = request.assistantPrefix == nil ? Self.directReplies(place: place) : Self.sceneReplies
        var reply = pool[Self.index(variant, pool.count)]
        if system.contains("[photo:") {
            reply += "\n[photo: \(Self.photoIdeas[Self.index(variant / 3, Self.photoIdeas.count)])]"
        }
        return reply
    }

    private func newsletter(_ userText: String) -> String {
        let residents = Self.firstMatch(#"Residents: ([^\n]+)"#, in: userText) ?? ""
        let names = residents.components(separatedBy: ";").compactMap { part -> String? in
            let name = part.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? nil : name
        }
        let count = Int(Self.firstMatch(#"Write (\d+) short happenings"#, in: userText) ?? "") ?? 3
        let cast = names.isEmpty ? ["A neighbor", "a friend"] : names
        let lines = [
            "\(cast[0]) left a jar of wildflowers on the harbor wall for anyone who needed cheering up.",
            "\(cast[min(1, cast.count - 1)]) fixed the squeaky gate by the bakery and stayed for a cup of tea.",
            "\(cast[min(2, cast.count - 1)]) counted twelve lanterns glowing on the water after sunset.",
            "\(cast[0]) and \(cast[min(1, cast.count - 1)]) traded recipes and laughed about a very flat loaf.",
        ]
        return lines.prefix(max(1, min(count, lines.count))).map { "- " + $0 }.joined(separator: "\n")
    }

    static func speakerName(_ request: GenerationRequest) -> String {
        if let label = request.assistantPrefix?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            return label.hasSuffix(":") ? String(label.dropLast()) : label
        }
        let system = request.turns.first { $0.role == .system }?.content ?? ""
        return firstMatch(#"You are ([^,.\n]+)[,.]"#, in: system) ?? "Your friend"
    }

    static func directReplies(place: String?) -> [String] {
        [
            "*looks up and smiles* There you are! I was just thinking about you. How has your day been?",
            "That sounds like a lot to carry. I'm glad you told me. What part of it is staying with you the most?",
            "*sets down a warm cup* Here, this one's on me. Tell me everything, I've got time.",
            "Oh, I love that. You always notice the little things. What happened next?",
            "Honestly? That made me smile. Thank you for sharing it with me.",
            "I'm right here. Take your time, there's no rush at all.",
            "You know, that reminds me of something that happened by the harbor last week. Want to hear it?",
            place.map { "Come sit with me here at \($0) for a bit. It's quiet tonight, and the company is nice." }
                ?? "The lanterns are just coming on down by the water. It's my favorite time of day. What's yours?",
        ]
    }

    static let sceneReplies = [
        "Ha! You should have seen the harbor this morning. The gulls were definitely up to something.",
        "I was hoping someone would bring that up. I've been thinking about it all day.",
        "*nods slowly* That's fair. Though I'd add a second cup of cocoa to that plan.",
        "Oh, don't get me started. Last time we tried that, the whole pier smelled like cinnamon for a week.",
        "Welcome in! Grab a seat, we were just trading stories.",
        "Now that you mention it, the lighthouse looked extra bright last night.",
    ]

    static let photoIdeas = [
        "the harbor at golden hour, lanterns reflecting on calm water",
        "a tray of warm cinnamon buns on a wooden counter",
        "a cozy reading nook with a stack of old books and a teacup",
        "the lighthouse at dusk with the first stars coming out",
        "a little garden bed of sweet peas after the rain",
    ]

    // MARK: - Helpers

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    /// Stable 64-bit hash (Swift's own hashValue changes every launch, which would break determinism).
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func index(_ value: Int, _ count: Int) -> Int {
        let r = value % count
        return r < 0 ? r + count : r
    }
}
