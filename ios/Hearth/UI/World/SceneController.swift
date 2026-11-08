// Runs the group scene at one Lantern Bay place: who is there, who speaks next, streaming their lines,
// invites, the safety card, and a failed line's error with "Try again". SceneView draws it; UITour drives it
// through `SceneController.live(for:)`. Privacy: never logs what anyone says (counts only).

import SwiftUI

@MainActor @Observable final class SceneController {
    let locationID: String
    /// This place's scene (one per place, kept by ChatStore).
    private(set) var conversation: Conversation
    /// Residents scheduled here now, then anyone invited during this part of the day.
    private(set) var present: [Character] = []
    /// Who is writing right now, and their words so far (nil until the first word arrives).
    private(set) var streamingSpeakerID: String?
    private(set) var streamingText: String?
    private(set) var isReplying = false
    /// The support card on screen (.none hides it). Set when a line from the person sounds worrying.
    private(set) var safety: SafetyLevel = .none
    /// Goes up each time the person asks for support from the menu, so the scene can scroll to the card.
    private(set) var supportRequests = 0
    /// A short note for the person, shown once as a toast (the view clears it).
    var notice: String?
    /// Why the last line couldn't be written. Stays above the composer (with "Try again") until dismissed.
    private(set) var errorText: String?

    private let app: AppModel
    @ObservationIgnored private var stopRequested = false
    /// How worrying the person's latest line was. While set, prompts ask everyone to answer with care.
    @ObservationIgnored private var promptSafety: SafetyLevel = .none
    /// Who still had a line to say when one failed, for "Try again".
    @ObservationIgnored private var pendingRetry: (speakers: [Character], caring: Bool)?

    // MARK: Open scenes (UITour finds them here)

    private struct WeakRef { weak var controller: SceneController? }
    private static var registry: [String: WeakRef] = [:]

    /// The controller of the scene open at this place, if there is one.
    static func live(for locationID: String) -> SceneController? {
        registry[locationID]?.controller
    }

    init(locationID: String, app: AppModel) {
        self.locationID = locationID
        self.app = app
        let existing = app.chats.conversations.first { $0.sceneLocationID == locationID }
        let people = Self.people(at: locationID, now: .now, messages: existing?.messages ?? [], app: app)
        if let location = app.library.location(locationID) {
            conversation = app.chats.scene(at: location, present: people)
        } else {
            conversation = Conversation(kind: .scene(locationID: locationID), participantIDs: []) // never stored
        }
        present = people
        Self.registry[locationID] = WeakRef(controller: self)
    }

    var location: Location? { app.library.location(locationID) }

    /// Ids of the people here because they were invited (not because of their schedule).
    var invitedIDs: Set<String> {
        let scheduled = Set(app.director.residents(at: locationID, on: .now).map(\.id))
        return Set(present.map(\.id)).subtracting(scheduled)
    }

    // MARK: Who is here

    /// People come and go as the day moves on; call this now and then (the view does, every minute).
    func refreshPresent(now: Date = .now) {
        let people = Self.people(at: locationID, now: now, messages: conversation.messages, app: app)
        guard people.map(\.id) != present.map(\.id) else { return }
        present = people
        if let location { conversation = app.chats.scene(at: location, present: people) }
    }

    private static func people(at locationID: String, now: Date, messages: [Message], app: AppModel) -> [Character] {
        let director = app.director
        var people = director.residents(at: locationID, on: now)
        let since = partStart(of: now, calendar: director.calendar)
        for id in guestIDs(in: messages, since: since) where !people.contains(where: { $0.id == id }) {
            if let guest = app.library.character(id) { people.append(guest) }
        }
        return people
    }

    /// When the current part of the day began: 5:00, 11:00, 17:00 or 22:00 (yesterday's, before 5:00).
    nonisolated static func partStart(of date: Date, calendar: Calendar = .current) -> Date {
        let startHour: Int
        switch DayPart.at(date, calendar: calendar) {
        case .morning: startHour = 5
        case .afternoon: startHour = 11
        case .evening: startHour = 17
        case .night: startHour = 22
        }
        guard let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: date) else { return date }
        if start > date { return calendar.date(byAdding: .day, value: -1, to: start) ?? start }
        return start
    }

    /// Guests invited since `start`. An invite is a narrator note whose speakerID is the guest, so it
    /// survives relaunches and ends by itself when the part of the day is over.
    nonisolated static func guestIDs(in messages: [Message], since start: Date) -> [String] {
        var ids: [String] = []
        for message in messages where message.role == .narrator && message.createdAt >= start {
            if let id = message.speakerID, !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    // MARK: Talking

    /// Adds the person's line; then one or two of the people here answer (the director picks who).
    func send(text: String) async {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !isReplying, location != nil else { return }
        refreshPresent()
        guard !present.isEmpty else {
            notice = "Nobody is here to hear that yet. Invite someone to join you."
            return
        }
        ensureConversation()

        let level = SafetyGuard.assess(line)
        promptSafety = level
        if level != .none { offerSupport(level) }

        app.chats.append(Message(role: .user, text: line), to: conversation.id)
        sync()
        remember(line)

        var rng = SystemRandomNumberGenerator()
        var speakers = app.director.nextSpeakers(afterUserText: line, present: present,
                                                 transcript: conversation.messages, using: &rng)
        // After a worrying line, one friend answers with care instead of a chatty back-and-forth.
        if level != .none { speakers = Array(speakers.prefix(1)) }
        await run(speakers, answeringWorry: level != .none)
    }

    /// "Let them talk": `count` lines between the people here, never the same speaker twice in a row.
    func letThemTalk(count: Int = 4) async {
        guard !isReplying, location != nil else { return }
        refreshPresent()
        guard present.count >= 2 else {
            notice = "It takes two to chat. Invite someone to join you first."
            return
        }
        ensureConversation()
        let lastSpeaker = conversation.messages.last { $0.role == .character }?.speakerID
        var rng = SystemRandomNumberGenerator()
        await run(app.director.banterOrder(present: present, count: count, lastSpeakerID: lastSpeaker, using: &rng))
    }

    /// Brings someone over until this part of the day ends. They say hello when the model is ready.
    func invite(characterID: String) {
        guard !isReplying, let location, let guest = app.library.character(characterID),
              !present.contains(where: { $0.id == characterID }) else { return }
        ensureConversation()
        let from = app.director.location(of: guest, at: .now)
        let note = Message(role: .narrator, speakerID: guest.id,
                           text: TownText.arrival(of: guest.name, from: from, to: location))
        app.chats.append(note, to: conversation.id)
        sync()
        refreshPresent()
        guard app.engine.state == .ready else { return }
        isReplying = true // controls disable right away; run() takes it from here
        Task { await run([guest]) }
    }

    /// Stops the line being written and any lines still to come.
    func stop() {
        guard isReplying else { return }
        stopRequested = true
        app.engine.cancel()
    }

    /// Call when the scene closes: stops replies and saves this scene's model memory to flash, so coming
    /// back is quick.
    func deactivate() async {
        stop()
        // A scene that was cleared (Start over, Delete everything) must never be written back to flash.
        guard app.chats.conversation(conversation.id) != nil else { return }
        await app.engine.park(conversationKey: conversation.engineKey)
    }

    func hideSupport() {
        safety = .none
    }

    /// "Get support" in the scene menu: shows the support card again (and the scene scrolls to it).
    func showSupport() {
        offerSupport(.concern)
        supportRequests += 1
    }

    /// True when the last failed line can be asked for again.
    var canRetry: Bool { pendingRetry != nil }

    /// "Try again" after a line failed: the same people answer, starting with the one who couldn't.
    func retry() async {
        guard !isReplying, let plan = pendingRetry else { return }
        pendingRetry = nil
        errorText = nil
        refreshPresent()
        let speakers = plan.speakers.filter { person in present.contains { $0.id == person.id } }
        guard !speakers.isEmpty else { return }
        await run(speakers, answeringWorry: plan.caring)
    }

    func dismissError() {
        errorText = nil
        pendingRetry = nil
    }

    /// Clears this scene's conversation (and its saved model memory) and starts fresh.
    func startOver() {
        guard !isReplying, let location else { return }
        app.deleteConversation(conversation.id)
        promptSafety = .none
        safety = .none
        dismissError()
        present = app.director.residents(at: locationID, on: .now)
        conversation = app.chats.scene(at: location, present: present)
        HearthLog.info("scene", "started over at \(locationID)")
    }

    func deleteMessage(_ id: UUID) {
        guard !isReplying else { return }
        app.chats.deleteMessage(id, in: conversation.id)
        sync()
        refreshPresent() // deleting an invite note sends that guest home
        // The model's saved memory of this scene still holds the deleted words: drop it so they're really gone.
        let key = conversation.engineKey
        Task { await app.engine.forget(conversationKey: key) }
    }

    // MARK: Writing lines

    private func run(_ speakers: [Character], answeringWorry: Bool = false) async {
        isReplying = true
        stopRequested = false
        errorText = nil
        pendingRetry = nil
        for (index, speaker) in speakers.enumerated() {
            if stopRequested { break }
            let caring = answeringWorry && index == 0
            let keepGoing = await speakLine(speaker, caring: caring)
            if !keepGoing {
                if errorText != nil { pendingRetry = (Array(speakers[index...]), caring) }
                break
            }
        }
        streamingSpeakerID = nil
        streamingText = nil
        isReplying = false
    }

    /// Streams one line from `speaker` into the scene. Returns false when the scene should stop talking.
    private func speakLine(_ speaker: Character, caring: Bool) async -> Bool {
        guard let location else { return false }
        streamingSpeakerID = speaker.id
        streamingText = nil
        defer {
            streamingSpeakerID = nil
            streamingText = nil
        }
        let userName = PromptComposer.userName(app.settings.persona)
        let others = present.filter { $0.id != speaker.id }.map(\.name)

        if caring && app.engine.active?.id == "mock" {
            // Demo replies can't read the room, so a worrying line always gets a caring answer.
            try? await Task.sleep(for: .milliseconds(700))
            add(ParsedReply(text: Self.caringLine(userName: userName), photoCaption: nil), from: speaker, stats: nil)
            return true
        }

        let recentLines = Set(conversation.messages.suffix(8).filter { $0.role == .character }.map { Self.comparable($0.text) })
        for attempt in 0..<2 {
            let request = PromptComposer.sceneRequest(context(at: location), speaker: speaker)
            var raw = ""
            var stats: GenerationStats?
            do {
                for try await event in app.engine.generate(request) {
                    switch event {
                    case .token(let piece):
                        raw += piece
                        streamingText = ReplyParser.joinOpener(request.replyOpener,
                                                               ReplyParser.clean(raw, speakerName: speaker.name, otherNames: others,
                                                                                 userName: userName, cutByMaxTokens: false).text)
                    case .done(let finished):
                        stats = finished
                    }
                }
            } catch {
                if case .cancelled? = error as? EngineError { return false }
                errorText = Self.friendly(error)
                HearthLog.error("scene", "a line could not be written (\(type(of: error)))")
                return false
            }
            let cancelled = stopRequested || stats?.stoppedBy == "cancelled"
            let reply = ReplyParser.withOpener(request.replyOpener,
                                               ReplyParser.clean(raw, speakerName: speaker.name, otherNames: others,
                                                                 userName: userName, cutByMaxTokens: stats?.stoppedBy == "maxTokens"))
            if attempt == 0, !cancelled, !reply.text.isEmpty, recentLines.contains(Self.comparable(reply.text)) {
                streamingText = nil
                continue // the very same words as a moment ago: write it once more
            }
            add(reply, from: speaker, stats: stats)
            if let stats { HearthLog.debug("scene", "line tokens=\(stats.generatedTokens) stoppedBy=\(stats.stoppedBy)") }
            return !cancelled
        }
        return true
    }

    private func context(at location: Location) -> SceneContext {
        SceneContext(location: location, world: app.library.world, present: present, persona: app.settings.persona,
                     events: app.events.recent(limit: 12), transcript: conversation.messages,
                     safety: promptSafety, conversationKey: conversation.engineKey,
                     allCharacters: app.library.allCharacters)
    }

    /// Adds a finished line, and starts drawing its picture if it asked for one. Never a picture in answer
    /// to someone who may be hurting, or while the support card is up (the model can copy a "[photo: ...]"
    /// line from the transcript on its own).
    private func add(_ reply: ParsedReply, from speaker: Character, stats: GenerationStats?) {
        let photoAllowed = app.settings.picturesEnabled && promptSafety == .none && safety == .none
        let caption = photoAllowed ? reply.photoCaption : nil
        guard !reply.text.isEmpty || caption != nil else { return }
        var message = Message(role: .character, speakerID: speaker.id, text: reply.text)
        message.stats = stats
        if let caption { message.attachment = Attachment(kind: .picture, caption: caption, status: .pending) }
        app.chats.append(message, to: conversation.id)
        sync()
        if let caption { drawPicture(caption, by: speaker, messageID: message.id) }
    }

    private func drawPicture(_ caption: String, by speaker: Character, messageID: UUID) {
        let conversationID = conversation.id
        let style = app.settings.pictureStyle
        Task {
            let picture = await app.pictures.makePicture(caption: caption, for: speaker, style: style)
            guard var message = app.chats.conversation(conversationID)?.messages.first(where: { $0.id == messageID }),
                  let pending = message.attachment, pending.kind == .picture, pending.status == .pending else {
                ChatController.removeMediaFile(picture.file) // the line or the scene was deleted meanwhile
                return
            }
            message.attachment = picture
            app.chats.replace(message, in: conversationID)
            sync()
        }
    }

    // MARK: Helpers

    /// Makes sure this place's scene is in the store (it may have been cleared) and up to date.
    private func ensureConversation() {
        guard let location else { return }
        conversation = app.chats.scene(at: location, present: present)
    }

    private func sync() {
        if let fresh = app.chats.conversation(conversation.id) { conversation = fresh }
    }

    private func offerSupport(_ level: SafetyLevel) {
        if safety == .none || level == .crisis { safety = level }
        ChatSafetyCard.announce()
    }

    /// Simple facts from the person's line ("I love tea"), learned by everyone who heard it.
    private func remember(_ line: String) {
        let found = MemoryKeeper.extractFacts(fromUserText: line, userName: PromptComposer.userName(app.settings.persona))
        guard !found.isEmpty else { return }
        let shareable = app.settings.townGossip
        for character in present {
            let known = app.memory.facts(for: character.id, includeShareable: false)
            app.memory.add(MemoryKeeper.merge(found, into: known, characterID: character.id, source: .auto, shareable: shareable))
        }
    }

    /// What a friend says to a worrying line when only demo replies are available.
    nonisolated static func caringLine(userName: String) -> String {
        "*sets everything down and sits right beside you* \(userName), I'm really glad you told us. You matter. "
            + "If you're thinking about hurting yourself, please call or text 988 (in the US), or text HOME to 741741, "
            + "to talk with someone right now. I'm right here with you."
    }

    nonisolated private static func comparable(_ text: String) -> String {
        BrainText.fold(BrainText.oneLine(text))
    }

    nonisolated private static func friendly(_ error: Error) -> String {
        if let engineError = error as? EngineError, let text = engineError.errorDescription { return text }
        return "Couldn't write a line just now. Try again in a moment."
    }
}
