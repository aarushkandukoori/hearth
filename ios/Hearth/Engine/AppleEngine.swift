// AppleEngine: Apple's on-device foundation model (Apple Intelligence, iOS 26). Used when no Hearth model
// is downloaded yet. It runs on the phone like the others; it has a 4096-token window and no KV parking.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

final class AppleEngine: LanguageEngine, @unchecked Sendable {
    /// Total tokens Apple's model can see at once (instructions + history + reply).
    static let contextTokens = 4096

    let descriptor = EngineDescriptor(id: "apple", displayName: "Apple Intelligence",
                                      modelName: "Apple on-device model", contextLength: AppleEngine.contextTokens,
                                      supportsKVPersistence: false)

    private let lock = NSLock()
    private var running: Task<Void, Never>?

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        return SystemLanguageModel.default.isAvailable
        #else
        return false
        #endif
    }

    /// Why Apple's model can't be used right now, in words a person can act on (nil when it can).
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This iPhone can't run Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is turned off. You can turn it on in Settings."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready. Try again in a little while."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
        #else
        return "Apple Intelligence isn't available on this device."
        #endif
    }

    func prepare() async throws {
        if let reason = Self.unavailableReason { throw EngineError.unavailable(reason) }
    }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(request, continuation) }
            lock.withLock { running = task }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cancelCurrent() {
        lock.withLock { running?.cancel() }
    }

    func countTokens(_ text: String) async -> Int { Self.estimateTokens(text) }
    func park(conversationKey: String) async {}
    func purgeParkedState() async {}
    func shutdown() async { cancelCurrent() }

    // MARK: - Prompt plan (pure, unit-testable)

    /// What we hand Apple's model: instructions (the system turn), earlier turns, and the newest prompt.
    struct Plan: Equatable {
        var instructions: String
        var history: [ChatTurn]
        var prompt: String
        var droppedTurns: Int
        var estimatedTokens: Int
    }

    /// About 4 characters per token, plus a little framing per turn.
    static func estimateTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    /// Builds the plan and drops the oldest history until it fits in `budget` tokens.
    static func plan(for request: GenerationRequest, budget: Int) -> Plan {
        var instructions = request.turns.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var rest = request.turns.filter { $0.role != .system }
        var prompt = "Continue the conversation."
        if let last = rest.last, last.role == .user {
            prompt = last.content
            rest.removeLast()
        }
        if let label = request.assistantPrefix?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            let name = label.hasSuffix(":") ? String(label.dropLast()) : label
            prompt += "\n\n(Reply with only \(name)'s next line, in \(name)'s own voice. Don't write \"\(name):\" or anyone else's lines.)"
        }
        // Apple's model can't be prefilled, so it is told the opener is already said (the caller shows it).
        if let opener = request.replyOpener?.trimmingCharacters(in: .whitespacesAndNewlines), !opener.isEmpty {
            prompt += "\n\n(Your reply already begins with: \"\(opener)\" Write only what comes next, one or two warm sentences, without repeating it.)"
        }

        // Neighboring turns from the same side are merged, so the transcript always alternates.
        var history: [ChatTurn] = []
        for turn in rest {
            if let last = history.last, last.role == turn.role {
                history[history.count - 1].content += "\n" + turn.content
            } else {
                history.append(turn)
            }
        }

        func cost() -> Int {
            estimateTokens(instructions) + estimateTokens(prompt) + history.reduce(0) { $0 + estimateTokens($1.content) + 4 } + 16
        }
        var dropped = 0
        while cost() > budget, !history.isEmpty {
            history.removeFirst()
            dropped += 1
        }
        if cost() > budget { // still too long: keep the start of the instructions (who the character is)
            let room = max(200, budget - estimateTokens(prompt) - 16) * 4
            instructions = String(instructions.prefix(room))
        }
        return Plan(instructions: instructions, history: history, prompt: prompt, droppedTurns: dropped, estimatedTokens: cost())
    }

    // MARK: - Generation

    private func run(_ request: GenerationRequest, _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async {
        #if canImport(FoundationModels)
        let started = Date()
        var budget = Self.contextTokens - max(64, request.maxTokens) - 200
        for attempt in 0..<2 {
            let plan = Self.plan(for: request, budget: budget)
            var shownAnything = false
            do {
                let stats = try await stream(plan, request, started: started, shownAnything: &shownAnything, continuation)
                continuation.yield(.done(stats))
                continuation.finish()
                return
            } catch let error as LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error, attempt == 0, !shownAnything {
                    budget /= 2 // our estimate was too generous; trim harder and try once more
                    HearthLog.info("apple", "context window exceeded; retrying with a smaller history")
                    continue
                }
                continuation.finish(throwing: Self.map(error))
                return
            } catch {
                if Task.isCancelled {
                    continuation.yield(.done(GenerationStats(engine: descriptor.id, stoppedBy: "cancelled")))
                    continuation.finish()
                } else {
                    let ns = error as NSError
                    HearthLog.error("apple", "generation failed: \(ns.domain) \(ns.code)")
                    continuation.finish(throwing: error)
                }
                return
            }
        }
        continuation.finish(throwing: EngineError.contextOverflow)
        #else
        continuation.finish(throwing: EngineError.unavailable(Self.unavailableReason ?? "Apple Intelligence isn't available."))
        #endif
    }

    #if canImport(FoundationModels)
    private func stream(_ plan: Plan, _ request: GenerationRequest, started: Date, shownAnything: inout Bool,
                        _ continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation) async throws -> GenerationStats {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: [.text(Transcript.TextSegment(content: plan.instructions))], toolDefinitions: []))
        ]
        for turn in plan.history {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: turn.content))
            switch turn.role {
            case .user: entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            case .assistant: entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            case .system: break
            }
        }
        let session = LanguageModelSession(model: SystemLanguageModel.default, tools: [], transcript: Transcript(entries: entries))
        let s = request.sampling
        let options = GenerationOptions(sampling: .random(probabilityThreshold: Double(s.topP), seed: s.seed.map(UInt64.init)),
                                        temperature: Double(s.temperature), maximumResponseTokens: max(1, request.maxTokens))

        var stats = GenerationStats(engine: descriptor.id, promptTokens: plan.estimatedTokens, prefilledTokens: plan.estimatedTokens)
        var stripper = LeadingLabelStripper(label: request.assistantPrefix)
        var filter = StopFilter(request.stop)
        var received = "" // cumulative text from the model
        var firstAt: Date?
        stats.stoppedBy = "eos"

        for try await snapshot in session.streamResponse(to: plan.prompt, options: options) {
            if Task.isCancelled {
                stats.stoppedBy = "cancelled"
                break
            }
            let full = snapshot.content // each snapshot is the whole reply so far
            guard full.count > received.count else { continue }
            let delta = String(full.dropFirst(received.count))
            received = full
            if firstAt == nil {
                firstAt = Date()
                stats.timeToFirstToken = Date().timeIntervalSince(started)
            }
            let visible = filter.feed(stripper.feed(delta))
            if !visible.isEmpty {
                shownAnything = true
                continuation.yield(.token(visible))
            }
            if filter.stopped {
                stats.stoppedBy = "stop"
                break
            }
        }
        if Task.isCancelled, stats.stoppedBy == "eos" { stats.stoppedBy = "cancelled" } // the stream just ends on cancel
        if !filter.stopped {
            var tail = filter.feed(stripper.flush())
            tail += filter.flush()
            if !tail.isEmpty { continuation.yield(.token(tail)) }
        }
        stats.generatedTokens = Self.estimateTokens(received)
        if stats.stoppedBy == "eos", stats.generatedTokens >= request.maxTokens { stats.stoppedBy = "maxTokens" }
        if let firstAt {
            let seconds = Date().timeIntervalSince(firstAt)
            if seconds > 0, stats.generatedTokens > 1 { stats.decodeTokensPerSecond = Double(stats.generatedTokens - 1) / seconds }
            stats.prefillTokensPerSecond = Double(plan.estimatedTokens) / max(firstAt.timeIntervalSince(started), 0.001)
        }
        HearthLog.info("apple", String(format: "reply: ~%d prompt tokens (%d turns dropped), ~%d tokens, ttft %.0f ms, stop %@",
                                       plan.estimatedTokens, plan.droppedTurns, stats.generatedTokens,
                                       stats.timeToFirstToken * 1000, stats.stoppedBy))
        return stats
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> EngineError {
        switch error {
        case .guardrailViolation, .refusal:
            return .refused("Apple's model declined to answer that. The Hearth model is more flexible.")
        case .exceededContextWindowSize:
            return .contextOverflow
        case .assetsUnavailable:
            return .unavailable("Apple Intelligence is still getting ready on this iPhone. Try again in a little while.")
        case .unsupportedLanguageOrLocale:
            return .unavailable("Apple's model doesn't support this language yet.")
        case .rateLimited, .concurrentRequests:
            return .busy
        default:
            return .unavailable("Apple's model couldn't answer just now. Please try again.")
        }
    }
    #endif
}
