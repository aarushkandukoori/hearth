// The contract every language engine implements (llama.cpp, Apple's on-device model, mock).
// UI and Brain code only ever talk to `LanguageEngine` through EngineHost.

import Foundation

enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

struct ChatTurn: Codable, Hashable, Sendable {
    var role: ChatRole
    var content: String
}

struct SamplingParams: Codable, Hashable, Sendable {
    var temperature: Float = 0.8
    var topP: Float = 0.95
    var topK: Int32 = 40
    var minP: Float = 0.05
    var repeatPenalty: Float = 1.1
    var repeatLastN: Int32 = 128
    /// nil = random seed each time (alternates differ).
    var seed: UInt32?
}

struct GenerationRequest: Sendable {
    /// Identifies whose KV cache this is (Conversation.engineKey). Switching keys parks the old cache on flash.
    var conversationKey: String
    var turns: [ChatTurn]
    /// Forced text right after the assistant header, e.g. "Theo:" in group scenes. Not included in the output.
    var assistantPrefix: String?
    var maxTokens: Int = 256
    var stop: [String] = []
    var sampling = SamplingParams()
    /// Fixed start of the reply that the person DOES see, e.g. the caring opener for a crisis message.
    /// Engines that can prefill (llama) put it right after the assistant header (and after
    /// `assistantPrefix`) and write only the rest. The output never includes it: the caller shows
    /// `replyOpener + " " + output`. On a 3B model this stops canned "I cannot continue" refusals.
    var replyOpener: String?
}

struct GenerationStats: Codable, Hashable, Sendable {
    var engine: String
    var promptTokens: Int = 0
    /// Tokens already in the KV cache (prefix reuse or restored from flash).
    var reusedTokens: Int = 0
    /// Tokens that had to be computed for this request's prompt.
    var prefilledTokens: Int = 0
    var generatedTokens: Int = 0
    var timeToFirstToken: Double = 0
    var prefillTokensPerSecond: Double = 0
    var decodeTokensPerSecond: Double = 0
    var restoredFromDisk: Bool = false
    var restoreMilliseconds: Double?
    var parkMilliseconds: Double?
    var stoppedBy: String = "eos"
}

enum GenerationEvent: Sendable {
    case token(String)
    case done(GenerationStats)
}

struct EngineDescriptor: Hashable, Sendable {
    /// ModelSpec id, "apple" or "mock".
    var id: String
    var displayName: String
    var modelName: String
    var contextLength: Int
    var supportsKVPersistence: Bool
}

enum EngineError: LocalizedError, Sendable {
    case modelMissing
    case loadFailed(String)
    case contextOverflow
    case busy
    case refused(String)
    case unavailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "The character model isn't on this iPhone yet."
        case .loadFailed(let why): return "The model couldn't load: \(why)"
        case .contextOverflow: return "This chat got too long for the model's memory."
        case .busy: return "Still thinking about the last message."
        case .refused(let why): return why
        case .unavailable(let why): return why
        case .cancelled: return "Stopped."
        }
    }
}

/// Implemented by LlamaEngine, AppleEngine and MockEngine.
protocol LanguageEngine: AnyObject, Sendable {
    var descriptor: EngineDescriptor { get }
    /// Load weights / warm up. Safe to call more than once.
    func prepare() async throws
    /// Stream a reply. Finishes with exactly one `.done(stats)` unless it throws.
    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
    /// Stop the running generation within about one token.
    func cancelCurrent()
    /// Rough token count for prompt budgeting.
    func countTokens(_ text: String) async -> Int
    /// Save this conversation's KV cache to flash now (no-op if unsupported).
    func park(conversationKey: String) async
    /// Delete every parked KV file.
    func purgeParkedState() async
    /// Free memory (model weights, contexts).
    func shutdown() async
}
