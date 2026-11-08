// The brain of one 1:1 chat screen: sends the user's messages, streams the character's reply (SPEC §7),
// adds voice notes and pictures (§9), learns small memories, and keeps everything in ChatStore.
// Message text never goes to the log; only counts and error kinds do.

import Foundation
import Observation

@MainActor @Observable final class ChatController {
    /// UserDefaults key for the chat menu's "Play replies aloud" switch (a display preference, no chat text).
    nonisolated static let readAloudKey = "hearth.chat.playRepliesAloud"
    /// UserDefaults key: the person was told once that stars are just for them (a display flag, no chat text).
    nonisolated static let ratingsExplainedKey = "hearth.chat.ratingsExplained"
    /// Quiet time after a reply before the memory summary runs, so it never slows the conversation.
    static let summaryDelay: Duration = .seconds(8)
    /// Replies in a row that didn't come through, in any chat. The Model page mentions it after two.
    private(set) static var failedInARow = 0

    let conversationID: UUID

    /// The reply as it streams in, already without a leading "Name:". nil when no reply is running.
    private(set) var streamingText: String?
    /// True from sending until the reply's text is complete (voice notes and pictures may finish later).
    private(set) var isReplying = false
    /// Snapshot of memory and town news for this visit (see `reply`); cleared when the chat closes.
    @ObservationIgnored private var sessionFacts: [MemoryFact]?
    @ObservationIgnored private var sessionEvents: [WorldEvent]?
    /// Highest safety level seen in this chat. The screens offer support resources until it's hidden.
    private(set) var safety: SafetyLevel = .none
    /// The message the support card follows in the chat: the latest worrying one, or the last message when
    /// support was asked for from the menu. nil (or a deleted message) puts the card after the last message.
    private(set) var supportAfterID: UUID?
    /// Goes up each time the person asks for support from the menu, so the chat can scroll to the card.
    private(set) var supportRequests = 0
    /// Replies in a row that didn't come through in this chat. After two, the error offers the Models page.
    private(set) var failedReplies = 0
    /// A friendly problem to show above the composer.
    var errorText: String?
    /// A short confirmation for a toast ("Juno will remember this.").
    var notice: String?
    /// Dev and UI tour: make the next reply a voice note when it is short enough.
    var forceVoiceNoteOnNextReply = false
    /// The message getting a new alternate (regenerate or swipe past the end). nil for a new reply.
    private(set) var regeneratingID: UUID?
    /// The call screen turns this on: replies are spoken sentence by sentence as they stream.
    var speaksRepliesLive = false

    private let app: AppModel
    @ObservationIgnored private var fallback: Conversation
    /// Screens currently using this controller (the chat, a call on top of it).
    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var summarizedBlocks: Int
    @ObservationIgnored private var summaryTask: Task<Void, Never>?
    /// True while a memory summary runs. App wide (one at a time), so a new message in any chat can stop it.
    private static var summaryRunning = false
    /// Support stays offered for a chat until the person hides it: through a call, "Type instead" and later
    /// visits while Hearth is open. Kept in memory only.
    private static var supportStates: [UUID: (level: SafetyLevel, afterID: UUID?)] = [:]

    init(conversationID: UUID, app: AppModel) {
        self.conversationID = conversationID
        self.app = app
        let stored = app.chats.conversation(conversationID)
        fallback = stored ?? Conversation(id: conversationID, kind: .direct(characterID: ""), participantIDs: [])
        // Only messages sent from now on lead to a new summary.
        let userCount = stored?.messages.filter { $0.role == .user }.count ?? 0
        summarizedBlocks = userCount / MemoryKeeper.summarizeEvery
        if let support = Self.supportStates[conversationID] {
            safety = support.level
            supportAfterID = support.afterID
        }
    }

    // MARK: - Registry (the UI tour, the chat and the call screen find the open chat here)

    private final class WeakBox {
        weak var controller: ChatController?
        init(_ controller: ChatController) { self.controller = controller }
    }

    private static var registry: [UUID: WeakBox] = [:]

    /// The controller a screen is using for this conversation, or one still finishing a reply there.
    static func live(for id: UUID) -> ChatController? {
        registry[id]?.controller
    }

    /// True while a screen (the chat, or a call on top of it) is using this controller.
    var isInUse: Bool { holders > 0 }

    /// A screen starts using this chat. Pair every call with `deactivate()`.
    func activate() {
        holders += 1
        Self.registry[conversationID] = WeakBox(self)
    }

    /// A screen stops using this chat. When the last one leaves: stop audio, run a memory summary
    /// that is due, and park the KV cache on flash so coming back is instant.
    func deactivate() async {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        // A reply still being written keeps this controller findable, so coming back shows that reply
        // instead of starting a second one beside it. The registry holds it weakly: it goes once it's done.
        if !isReplying, Self.registry[conversationID]?.controller === self { Self.registry[conversationID] = nil }
        speaksRepliesLive = false
        sessionFacts = nil
        sessionEvents = nil
        app.voice.stop()
        summaryTask?.cancel()
        summaryTask = nil
        guard exists else { return }
        if summaryIsDue && !isReplying && !app.engine.isGenerating { await summarize() }
        await app.engine.park(conversationKey: conversation.engineKey)
    }

    // MARK: - What the screen reads

    /// The conversation as ChatStore has it right now.
    var conversation: Conversation { app.chats.conversation(conversationID) ?? fallback }
    /// False once the chat has been deleted.
    var exists: Bool { app.chats.conversation(conversationID) != nil }
    var character: Character? { conversation.directCharacterID.flatMap { app.library.character($0) } }

    /// Whether a new message can go out now (the engine banner explains when it can't).
    var canSend: Bool {
        !isReplying && exists && character != nil && Self.engineAccepts(app.engine.state)
    }

    /// The reply that swipes, stars and regenerate act on.
    var lastReply: Message? {
        let messages = conversation.messages
        return ChatPipeline.lastReplyIndex(in: messages).map { messages[$0] }
    }

    /// The greeting ChatStore put first. It swipes through its alternate greetings but is never rewritten.
    func isGreeting(_ message: Message) -> Bool {
        message.role == .character && conversation.messages.first?.id == message.id
    }

    /// Loading counts: requests wait in line until the model is ready. No model or a failed load does not.
    nonisolated static func engineAccepts(_ state: EngineHost.State) -> Bool {
        switch state {
        case .needsModel, .failed: return false
        case .idle, .loading, .ready: return true
        }
    }

    // MARK: - Sending

    /// Sends text and returns once the reply's text is complete.
    func send(text: String) async {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, canSend else { return }
        app.chats.append(Message(role: .user, text: clean), to: conversationID)
        await respond(toUserText: clean)
    }

    /// Sends a photo (shrunk, stripped of metadata and described on this iPhone) with an optional caption.
    @discardableResult
    func sendPhoto(_ data: Data, caption: String) async -> Bool {
        guard canSend else { return false }
        let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholder = Message(role: .user, text: text, attachment: Attachment(kind: .photo, status: .pending))
        isReplying = true
        app.chats.append(placeholder, to: conversationID)
        do {
            let photo = try await PhotoReader.importPhoto(data)
            guard var stored = storedMessage(placeholder.id) else {
                Self.removeMediaFile(photo.file)
                isReplying = false
                return false
            }
            stored.attachment = photo
            app.chats.replace(stored, in: conversationID)
        } catch {
            app.chats.deleteMessage(placeholder.id, in: conversationID)
            isReplying = false
            errorText = (error as? LocalizedError)?.errorDescription ?? "That photo couldn't be opened. Try a different one."
            return false
        }
        isReplying = false
        await respond(toUserText: text)
        return true
    }

    /// Sends a voice message the user recorded. Its transcript is what the character reads.
    func sendVoice(_ attachment: Attachment) async {
        let transcript = (attachment.caption ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !transcript.isEmpty else {
            Self.removeMediaFile(attachment.file)
            return
        }
        var voice = attachment
        voice.caption = transcript
        app.chats.append(Message(role: .user, text: transcript, attachment: voice), to: conversationID)
        await respond(toUserText: transcript)
    }

    private func respond(toUserText text: String) async {
        let level = SafetyGuard.assess(text)
        raiseSafety(level, after: conversation.messages.last { $0.role == .user }?.id)
        learnFacts(from: text)
        await generateReply(userText: text, safety: level, replacing: nil)
        scheduleSummaryIfDue()
    }

    // MARK: - Alternates

    /// A new alternate for the last reply, or a fresh try when the last message is the user's.
    func regenerate() async {
        guard canSend else { return }
        let messages = conversation.messages
        if let index = ChatPipeline.lastReplyIndex(in: messages) {
            let reply = messages[index]
            guard !isGreeting(reply) else { return }
            stopAudio(for: reply.id)
            let userText = messages[..<index].last { $0.role == .user }?.text ?? ""
            await generateReply(userText: userText, safety: SafetyGuard.assess(userText), replacing: reply.id)
        } else if let last = messages.last(where: { $0.role != .narrator }), last.role == .user {
            await generateReply(userText: last.text, safety: SafetyGuard.assess(last.text), replacing: nil)
        }
    }

    /// Swipe on the last reply: -1 / +1 through its alternates; +1 past the end writes a new one.
    func showAlternate(delta: Int) async {
        guard !isReplying else { return }
        let messages = conversation.messages
        guard let index = ChatPipeline.lastReplyIndex(in: messages) else { return }
        var reply = messages[index]
        switch ChatPipeline.alternateStep(selected: reply.selected, count: reply.variants.count, delta: delta,
                                          canGenerate: !isGreeting(reply)) {
        case .select(let selected):
            stopAudio(for: reply.id)
            reply.selected = selected
            app.chats.replace(reply, in: conversationID)
        case .generate:
            await regenerate()
        case .none:
            break
        }
    }

    // MARK: - Changing messages

    func edit(messageID: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, var message = storedMessage(messageID), message.text != clean else { return }
        let oldText = message.text
        message.text = clean
        if var voice = message.attachment, voice.kind == .voice {
            if message.role == .user {
                voice.caption = clean // fixing a misheard transcript
                message.attachment = voice
            } else if voice.caption == oldText {
                stopAudio(for: messageID)
                message.attachment = nil // the recording no longer says this
            }
        }
        app.chats.replace(message, in: conversationID)
        forgetParkedMemory()
        if message.role == .user {
            raiseSafety(SafetyGuard.assess(clean), after: messageID)
            learnFacts(from: clean)
        }
    }

    func delete(messageID: UUID) {
        stopAudio(for: messageID)
        app.chats.deleteMessage(messageID, in: conversationID)
        forgetParkedMemory()
    }

    /// 1-4 stars, nil clears. Stars are a private note: nothing reads them to shape replies.
    func rate(messageID: UUID, stars: Int?) {
        guard var message = storedMessage(messageID) else { return }
        message.rating = stars.map { min(4, max(1, $0)) }
        app.chats.replace(message, in: conversationID)
        // Elsewhere stars train the replies, so say once that here they don't.
        if stars != nil, !UserDefaults.standard.bool(forKey: Self.ratingsExplainedKey) {
            UserDefaults.standard.set(true, forKey: Self.ratingsExplainedKey)
            notice = "Stars are just for you. They stay on this iPhone and don't change replies."
        }
    }

    /// "Remember this": the message becomes a pinned memory for this character.
    func pin(messageID: UUID) {
        guard var message = storedMessage(messageID), let character else { return }
        let text = ChatPipeline.pinText(for: message, characterName: character.name)
        guard !text.isEmpty else { return }
        let existing = app.memory.facts(for: character.id, includeShareable: false)
        let merged = MemoryKeeper.merge([text], into: existing, characterID: character.id, source: .pinned,
                                        shareable: app.settings.townGossip)
        let before = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for fact in merged {
            if let old = before[fact.id] {
                guard old.source != .pinned, fact.source == .pinned else { continue }
                app.memory.remove(old.id) // already known: now kept as pinned
            }
            app.memory.add([fact])
        }
        message.pinned = true
        app.chats.replace(message, in: conversationID)
        notice = "\(character.name) will remember this."
    }

    /// Undo "Remember this".
    func unpin(messageID: UUID) {
        guard var message = storedMessage(messageID), let character else { return }
        let text = ChatPipeline.pinText(for: message, characterName: character.name)
        for fact in app.memory.facts where fact.characterID == character.id && fact.source == .pinned
            && MemoryKeeper.isDuplicate(fact.text, text) {
            app.memory.remove(fact.id)
        }
        message.pinned = false
        app.chats.replace(message, in: conversationID)
        // The forgotten memory may be in this visit's prompt and in the model's saved memory of this chat.
        sessionFacts = nil
        forgetParkedMemory()
    }

    /// Plays a voice note, or reads a character's message aloud in their voice. Again stops it.
    func play(messageID: UUID) {
        guard let message = storedMessage(messageID) else { return }
        if let voice = ChatPipeline.playableVoice(message) {
            app.voice.togglePlayback(voice, messageID: messageID)
            return
        }
        guard message.role == .character, let character else { return }
        if app.voice.nowPlayingMessageID == messageID && app.voice.isSpeaking {
            app.voice.stop()
            return
        }
        app.voice.speak(message.text, as: character, overrides: app.settings.voiceOverrides, messageID: messageID)
    }

    /// Stops the reply being written and any audio. (`streamingText` is non-nil only while this chat's
    /// own reply is being generated; the engine's cancel would also stop other screens' requests.)
    func stop() {
        if streamingText != nil { app.engine.cancel() }
        app.voice.stop()
    }

    func dismissSafety() {
        safety = .none
        supportAfterID = nil
        Self.supportStates[conversationID] = nil
    }

    /// "Get support" in the chat menu: shows the support card again after the last message (and the chat
    /// scrolls to it).
    func showSupport() {
        raiseSafety(.concern, after: conversation.messages.last?.id)
        supportRequests += 1
    }

    // MARK: - The reply pipeline

    private func generateReply(userText: String, safety level: SafetyLevel, replacing target: UUID?) async {
        guard let character, exists else { return }
        preemptSummary()
        let settings = app.settings
        var history = conversation.messages
        if let target, let index = history.firstIndex(where: { $0.id == target }) {
            history = Array(history[..<index]) // the alternate answers the same moment
        }
        let wantsPhoto = settings.picturesEnabled && WorldDirector.userAskedForPhoto(userText)
        // Facts and town news are frozen for this visit to the chat: if they changed between turns the
        // system prompt would change too, and the engine would have to re-read the whole conversation.
        if sessionFacts == nil { sessionFacts = app.memory.facts(for: character.id, includeShareable: settings.townGossip) }
        if sessionEvents == nil { sessionEvents = app.events.recent(limit: 20) }
        var context = DirectContext(
            character: character, world: app.library.world, persona: settings.persona,
            facts: sessionFacts ?? [],
            events: sessionEvents ?? [], history: history,
            photoRequested: wantsPhoto,
            // No surprise pictures in answer to someone who may be hurting, or for the rest of that visit.
            spontaneousPhoto: settings.picturesEnabled && !wantsPhoto && level == .none && safety == .none
                && Self.roll(character.media.photoChance),
            safety: level, conversationKey: conversation.engineKey)
        let userName = PromptComposer.userName(settings.persona)

        errorText = nil
        isReplying = true
        regeneratingID = target
        streamingText = ""
        defer {
            isReplying = false
            streamingText = nil
            regeneratingID = nil
        }
        let spokeLive = speaksLiveNow
        if spokeLive { app.voice.stop() } // a new reply replaces whatever was still being read

        while true {
            do {
                // A reply to a worrying message is never read out while it streams: only the finished,
                // cleaned answer is (see finishReply).
                let request = PromptComposer.directRequest(context)
                let reply = try await streamReply(request, character: character,
                                                  userName: userName, speaksWhileStreaming: level == .none)
                finishReply(raw: reply.raw, opener: request.replyOpener, stats: reply.stats, character: character,
                            userName: userName, target: target, spokeLive: spokeLive, safety: level,
                            photoRequested: wantsPhoto)
                return
            } catch EngineError.contextOverflow where context.budgetTokens > Self.retryBudget {
                // The estimate can run short (emoji, other languages): try once more with less history.
                context.budgetTokens = Self.retryBudget
                HearthLog.info("chat", "prompt too long for the model, retrying with less history")
            } catch {
                handle(error, character: character, userName: userName, target: target, safety: level)
                return
            }
        }
    }

    /// History budget for the one retry after a context overflow (the normal budget is 2600).
    private static let retryBudget = 1400

    /// Streams one reply into `streamingText` (and live speech when it's on and allowed). Reads the stream
    /// to its end, which is exactly one `.done(stats)`, and returns the raw text with those stats.
    private func streamReply(_ request: GenerationRequest, character: Character, userName: String,
                             speaksWhileStreaming: Bool) async throws -> (raw: String, stats: GenerationStats) {
        var raw = ""
        var finalStats: GenerationStats?
        var speech = ChatSpeechFeeder()
        let overrides = app.settings.voiceOverrides
        // A crisis reply's fixed caring opener shows at once; the model's words follow it.
        if let opener = request.replyOpener, !opener.isEmpty { streamingText = opener }
        for try await event in app.engine.generate(request) {
            switch event {
            case .token(let piece):
                raw += piece
                let live = ReplyParser.joinOpener(request.replyOpener,
                                                  ChatPipeline.liveText(raw, speakerName: character.name, userName: userName))
                if live != streamingText { streamingText = live }
                if speaksWhileStreaming && speaksLiveNow {
                    for sentence in speech.feed(live) { app.voice.enqueueSpoken(sentence, as: character, overrides: overrides) }
                }
            case .done(let stats):
                finalStats = stats
                if speaksWhileStreaming && speaksLiveNow && stats.stoppedBy != "cancelled" {
                    let tail = speech.finish()
                    if !tail.isEmpty { app.voice.enqueueSpoken(tail, as: character, overrides: overrides) }
                }
            }
        }
        // No stats means the stream was cut short (its task was cancelled): treat it like Stop.
        return (raw, finalStats ?? GenerationStats(engine: app.engine.active?.id ?? "none", stoppedBy: "cancelled"))
    }

    /// Live speech is on during a call or with "Play replies aloud", and only while the chat is open.
    private var speaksLiveNow: Bool {
        holders > 0 && (speaksRepliesLive || UserDefaults.standard.bool(forKey: Self.readAloudKey))
    }

    /// Cleans the finished reply, stores it (as a new message or a new alternate) and starts its media.
    private func finishReply(raw: String, opener: String?, stats: GenerationStats, character: Character, userName: String,
                             target: UUID?, spokeLive: Bool, safety level: SafetyLevel, photoRequested: Bool) {
        let settings = app.settings
        let cancelled = stats.stoppedBy == "cancelled"
        let others = app.library.world.characters.map(\.name).filter { $0 != character.name }
        let parsed = ReplyParser.withOpener(opener, ReplyParser.clean(raw, speakerName: character.name, otherNames: others,
                                                                      userName: userName,
                                                                      cutByMaxTokens: stats.stoppedBy == "maxTokens"))
        // Never a picture in answer to someone who may be hurting, and for the rest of that visit only
        // ones they ask for (the model can copy a "[photo: ...]" line from the history on its own).
        let photoAllowed = level == .none && (photoRequested || safety == .none)
        let photoCaption = settings.picturesEnabled && !cancelled && photoAllowed ? parsed.photoCaption : nil
        guard !parsed.text.isEmpty || photoCaption != nil else {
            forceVoiceNoteOnNextReply = false
            guard !cancelled else { return }
            noteFailure()
            if level != .none {
                addCaringReply(character: character, userName: userName, target: target)
            } else {
                errorText = "\(character.name) didn't find the words that time. You can try again."
            }
            return
        }
        guard exists else { return }
        noteSuccess()

        var attachment: Attachment?
        if let photoCaption {
            attachment = Attachment(kind: .picture, caption: PictureMaker.cleanCaption(photoCaption), status: .pending)
        } else if !cancelled, !speaksRepliesLive, settings.voiceNotesEnabled,
                  level == .none, safety == .none, // after a worrying message, replies stay as text to read right away
                  forceVoiceNoteOnNextReply || Self.roll(character.media.voiceNoteChance),
                  ChatPipeline.suitsVoiceNote(parsed.text) {
            attachment = Attachment(kind: .voice, caption: parsed.text, status: .pending)
        }
        forceVoiceNoteOnNextReply = false

        let messageID: UUID
        let variant: Int
        if let target, var message = storedMessage(target) {
            message.variants.append(parsed.text)
            message.selected = message.variants.count - 1
            message.stats = stats
            message.rating = nil
            message.attachment = attachment // media belongs to the newest alternate
            app.chats.replace(message, in: conversationID)
            messageID = target
            variant = message.variants.count - 1
        } else {
            var message = Message(role: .character, speakerID: character.id, text: parsed.text, attachment: attachment)
            message.stats = stats
            app.chats.append(message, to: conversationID)
            messageID = message.id
            variant = 0
        }
        HearthLog.info("chat", "reply \(parsed.text.count) chars, stop \(stats.stoppedBy), media \(attachment?.kind.rawValue ?? "none")")

        if level != .none, !cancelled, !parsed.text.isEmpty, speaksLiveNow {
            // Not read while it streamed (see generateReply): read the finished answer now.
            app.voice.speak(parsed.text, as: character, overrides: settings.voiceOverrides, messageID: messageID)
        }

        switch attachment?.kind {
        case .picture?:
            Task {
                await self.drawPicture(caption: photoCaption ?? "", messageID: messageID, variant: variant, character: character)
            }
        case .voice?:
            let text = parsed.text
            Task { await self.recordVoiceNote(text: text, messageID: messageID, character: character, autoPlay: !spokeLive) }
        default:
            break
        }
    }

    /// A fixed, caring answer with real help in it, for when the model can't answer someone who may be
    /// hurting (it declined, failed, or found no words). Stored like a reply, and read aloud in a call.
    private func addCaringReply(character: Character, userName: String, target: UUID?) {
        guard exists else { return }
        let text = ChatPipeline.caringLine(userName: userName)
        let messageID: UUID
        if let target, var message = storedMessage(target) {
            message.variants.append(text)
            message.selected = message.variants.count - 1
            message.stats = nil
            message.rating = nil
            message.attachment = nil
            app.chats.replace(message, in: conversationID)
            messageID = target
        } else {
            let message = Message(role: .character, speakerID: character.id, text: text)
            app.chats.append(message, to: conversationID)
            messageID = message.id
        }
        if speaksLiveNow {
            app.voice.speak(text, as: character, overrides: app.settings.voiceOverrides, messageID: messageID)
        }
    }

    private func handle(_ error: Error, character: Character, userName: String, target: UUID?, safety level: SafetyLevel) {
        forceVoiceNoteOnNextReply = false
        if case .cancelled? = error as? EngineError { return }
        noteFailure()
        // Someone who may be hurting never gets an error or a refusal note in place of an answer.
        if level != .none {
            addCaringReply(character: character, userName: userName, target: target)
            HearthLog.info("chat", "no reply to a worrying message; added the caring line")
            return
        }
        switch error as? EngineError {
        case .modelMissing?:
            errorText = EngineError.modelMissing.errorDescription
            HearthLog.error("chat", "reply failed: model missing")
        case .refused(let why)?:
            // Shown as a quiet note in the chat; notes never go back to the model.
            app.chats.append(Message(role: .narrator, text: why), to: conversationID)
            HearthLog.info("chat", "reply refused by the engine")
        case .cancelled?:
            break
        case let engineError?:
            errorText = engineError.errorDescription
            HearthLog.error("chat", "reply failed: engine error")
        case nil:
            errorText = "\(character.name) couldn't reply just now. You can try again."
            HearthLog.error("chat", "reply failed: \(String(describing: type(of: error)))")
        }
    }

    // MARK: - Media that arrives after the text

    /// `variant` is the alternate the picture belongs to: if a newer alternate came meanwhile, it has its
    /// own drawing on the way and this one is thrown away.
    private func drawPicture(caption: String, messageID: UUID, variant: Int, character: Character) async {
        let picture = await app.pictures.makePicture(caption: caption, for: character, style: app.settings.pictureStyle)
        guard var message = storedMessage(messageID), message.variants.count - 1 == variant,
              let pending = message.attachment, pending.kind == .picture, pending.status == .pending else {
            Self.removeMediaFile(picture.file) // the message changed or the chat was deleted meanwhile
            return
        }
        message.attachment = picture
        app.chats.replace(message, in: conversationID)
    }

    private func recordVoiceNote(text: String, messageID: UUID, character: Character, autoPlay: Bool) async {
        let note: Attachment
        do {
            note = try await app.voice.renderVoiceNote(text, as: character, overrides: app.settings.voiceOverrides)
        } catch {
            if var message = storedMessage(messageID), message.attachment?.kind == .voice, message.attachment?.status == .pending {
                message.attachment = nil // stays a text reply
                app.chats.replace(message, in: conversationID)
            }
            return
        }
        guard var message = storedMessage(messageID), let pending = message.attachment, pending.kind == .voice,
              pending.status == .pending, message.text == text else {
            Self.removeMediaFile(note.file)
            return
        }
        message.attachment = note
        app.chats.replace(message, in: conversationID)
        if autoPlay, holders > 0, app.settings.autoPlayVoiceNotes, !app.dictation.isListening, !app.voice.isSpeaking {
            app.voice.play(note, messageID: messageID)
        }
    }

    // MARK: - Memory

    private func learnFacts(from text: String) {
        guard let character else { return }
        // "*waves* I love tea" is read as "waves I love tea", so memories never carry asterisks.
        let found = MemoryKeeper.extractFacts(fromUserText: ChatMarkup.plain(text),
                                              userName: PromptComposer.userName(app.settings.persona))
        addFacts(found, source: .auto, for: character)
    }

    private func addFacts(_ texts: [String], source: MemorySource, for character: Character) {
        guard !texts.isEmpty else { return }
        let existing = app.memory.facts(for: character.id, includeShareable: false)
        let merged = MemoryKeeper.merge(texts, into: existing, characterID: character.id, source: source,
                                        shareable: app.settings.townGossip)
        let known = Set(existing.map(\.id))
        let added = merged.filter { !known.contains($0.id) }
        if !added.isEmpty { app.memory.add(added) }
    }

    private var summaryIsDue: Bool {
        let userCount = conversation.messages.filter { $0.role == .user }.count
        return ChatPipeline.summaryDue(userMessages: userCount, summarizedBlocks: summarizedBlocks)
    }

    private func scheduleSummaryIfDue() {
        guard summaryIsDue else { return }
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: ChatController.summaryDelay)
            guard !Task.isCancelled else { return }
            await self?.summarize()
        }
    }

    /// The SPEC §7 summary prompt over the last 12 turns; new facts are saved as `.summary`.
    private func summarize() async {
        guard summaryIsDue, !isReplying, !Self.summaryRunning, !app.engine.isGenerating, app.engine.state == .ready,
              let character else { return }
        let messages = conversation.messages
        let previous = summarizedBlocks
        summarizedBlocks = messages.filter { $0.role == .user }.count / MemoryKeeper.summarizeEvery
        let request = PromptComposer.memoryRequest(character: character, persona: app.settings.persona, recent: messages)
        Self.summaryRunning = true
        var raw = ""
        var finished = false
        do {
            for try await event in app.engine.generate(request) {
                switch event {
                case .token(let piece): raw += piece
                case .done(let stats): finished = stats.stoppedBy != "cancelled"
                }
            }
        } catch {
            finished = false
        }
        Self.summaryRunning = false
        // The summary's KV cache holds chat text and is never reused: drop it instead of parking it.
        await app.engine.forget(conversationKey: request.conversationKey)
        guard finished else {
            summarizedBlocks = previous // try again after a later reply
            return
        }
        let facts = ReplyParser.facts(from: raw)
        addFacts(facts, source: .summary, for: character)
        HearthLog.info("chat", "summary found \(facts.count) fact(s)")
    }

    /// The user always comes first: a summary that is waiting gives way to their message, and so does one
    /// that is running, even when it was started by another chat they just left.
    private func preemptSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        if Self.summaryRunning { app.engine.cancel() }
    }

    // MARK: - Small helpers

    private func storedMessage(_ id: UUID) -> Message? {
        app.chats.conversation(conversationID)?.messages.first { $0.id == id }
    }

    /// The model's saved memory of this chat (in memory and parked on flash) still holds words that were just
    /// deleted, edited or forgotten: drop it so they are really gone. The next reply reads the chat afresh.
    private func forgetParkedMemory() {
        let key = conversation.engineKey
        Task { await app.engine.forget(conversationKey: key) }
    }

    /// Shows the support card after `messageID` (the newest worrying message), keeping the highest level seen.
    private func raiseSafety(_ level: SafetyLevel, after messageID: UUID?) {
        guard level != .none else { return }
        if Self.rank(level) > Self.rank(safety) { safety = level }
        supportAfterID = messageID
        Self.supportStates[conversationID] = (safety, messageID)
        ChatSafetyCard.announce()
    }

    private func noteFailure() {
        failedReplies += 1
        Self.failedInARow += 1
    }

    private func noteSuccess() {
        failedReplies = 0
        Self.failedInARow = 0
    }

    private static func rank(_ level: SafetyLevel) -> Int {
        switch level {
        case .none: return 0
        case .concern: return 1
        case .crisis: return 2
        }
    }

    private func stopAudio(for messageID: UUID) {
        if app.voice.nowPlayingMessageID == messageID { app.voice.stop() }
    }

    private static func roll(_ chance: Double) -> Bool {
        var rng = SystemRandomNumberGenerator()
        return WorldDirector.roll(chance, using: &rng)
    }

    /// Deletes a media file nothing points to (a photo, picture or recording that never made it into the chat).
    static func removeMediaFile(_ file: String?) {
        guard let file, !file.isEmpty else { return }
        try? FileManager.default.removeItem(at: HearthPaths.mediaURL(file))
    }
}
