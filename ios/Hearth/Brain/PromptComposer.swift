// Builds the GenerationRequests Hearth sends to the model: 1:1 chats, group scenes, the town
// newsletter and memory summaries (SPEC §7). Deterministic: the same inputs give the same prompt.

import Foundation

struct DirectContext: Sendable {
    var character: Character
    var world: WorldDefinition
    var persona: UserPersona
    /// Already the right list: this character's facts, plus shareable ones when town gossip is on.
    var facts: [MemoryFact]
    /// Any recent events; the composer picks the 3 most relevant.
    var events: [WorldEvent]
    /// The whole chat including the latest user message. A leading character message is the greeting.
    var history: [Message]
    var now: Date = .now
    var photoRequested = false
    var spontaneousPhoto = false
    var safety: SafetyLevel = .none
    var budgetTokens = 2600
    var conversationKey: String
}

struct SceneContext: Sendable {
    var location: Location
    var world: WorldDefinition
    var present: [Character]
    var persona: UserPersona
    var events: [WorldEvent]
    var transcript: [Message]
    var now: Date = .now
    var safety: SafetyLevel = .none
    var budgetTokens = 2600
    var conversationKey: String
    /// Every character a transcript line may come from (Library.allCharacters). `world` only has the built-in
    /// residents, so without this the earlier lines of a user-made guest who has left would be dropped.
    var allCharacters: [Character] = []
}

enum PromptComposer {
    static let maxEventsInPrompt = 3
    /// History is dropped oldest-first in chunks this size, so the prompt prefix stays stable for KV reuse.
    static let trimChunk = 6
    /// Rough cost of a turn's chat-template header and end token.
    static let turnOverheadTokens = 4

    /// SPEC estimate: characters / 3.6, rounded up.
    static func estimateTokens(_ s: String) -> Int {
        Int((Double(s.count) / 3.6).rounded(.up))
    }

    // MARK: - 1:1 chat

    static func directRequest(_ c: DirectContext) -> GenerationRequest {
        let user = userName(c.persona)
        let name = c.character.name
        var head = [ChatTurn(role: .system, content: directSystem(c, userName: user))]

        // Narrator lines are UI notes and never go to the model.
        let messages = c.history.filter { $0.role != .narrator }
        var rest = messages[...]
        if let first = messages.first, first.role == .character {
            // ChatStore seeds the greeting as the first character message: use it, never duplicate it.
            let greeting = body(of: first, who: PromptTemplates.ownPhotoWho, user: user, char: name)
            if !greeting.isEmpty { head.append(ChatTurn(role: .assistant, content: greeting)) }
            rest = messages.dropFirst()
        } else {
            let greeting = BrainText.trimmed(BrainText.fillNames(c.character.greeting, user: user, char: name))
            if !greeting.isEmpty { head.append(ChatTurn(role: .assistant, content: greeting)) }
        }

        let turns: [ChatTurn] = rest.compactMap { m in
            let isUser = m.role == .user
            let text = body(of: m, who: isUser ? user : PromptTemplates.ownPhotoWho, user: user, char: name)
            return text.isEmpty ? nil : ChatTurn(role: isUser ? .user : .assistant, content: text)
        }

        var notes: [String] = []
        if c.safety != .none { notes.append(safetyNote(c.safety)) }
        if c.safety == .none {
            // A reply to a flagged message never carries a picture.
            if c.photoRequested {
                notes.append(PromptTemplates.notePhotoRequested)
            } else if c.spontaneousPhoto {
                notes.append(PromptTemplates.notePhotoSpontaneous)
            }
        }

        var sampling = SamplingParams()
        sampling.temperature = 0.85
        let fittedTurns = fitted(head: head, body: turns, budget: c.budgetTokens)
        return GenerationRequest(conversationKey: c.conversationKey,
                                 turns: withNotes(fittedTurns, notes, name: name, user: user),
                                 maxTokens: 220, stop: ["\n\(user):"], sampling: sampling,
                                 replyOpener: crisisOpener(c.safety, PromptTemplates.crisisOpener, user: user))
    }

    static func directSystem(_ c: DirectContext, userName user: String) -> String {
        typealias T = PromptTemplates
        let ch = c.character
        let director = WorldDirector(world: c.world)
        func names(_ s: String) -> String { BrainText.trimmed(BrainText.fillNames(s, user: user, char: ch.name)) }
        var sections: [String] = []

        let species = BrainText.trimmed(ch.species ?? "")
        sections.append(BrainText.trimmed(T.fill(species.isEmpty ? T.directIntroNoSpecies : T.directIntro, [
            "name": ch.name, "aSpecies": BrainText.withArticle(species),
            "worldName": c.world.name, "tagline": BrainText.sentence(names(ch.tagline)),
        ])))

        // A character with only a description (common for imported cards) still gets a personality.
        let personality = names(ch.personality.isEmpty ? ch.bio : ch.personality)
        if !personality.isEmpty { sections.append(T.fill(T.directAboutYou, ["personality": personality])) }
        let style = names(ch.speakingStyle)
        if !style.isEmpty { sections.append(T.fill(T.directHowYouTalk, ["speakingStyle": style])) }
        let scenario = names(ch.scenario ?? "")
        if !scenario.isEmpty { sections.append(T.fill(T.directScenario, ["scenario": scenario])) }

        var time = ["dayPart": director.part(at: c.now).rawValue, "weekday": weekday(c.now, calendar: director.calendar)]
        if let place = director.location(of: ch, at: c.now) {
            time["locationName"] = place.name
            time["activity"] = director.activity(of: ch, at: c.now)
            sections.append(T.fill(T.directNowAt, time))
        } else {
            sections.append(T.fill(T.directNow, time))
        }

        let people: [String] = ch.relationships.compactMap { rel in
            guard let other = c.world.characters.first(where: { $0.id == rel.characterID }) else { return nil }
            let note = BrainText.sentence(names(rel.note))
            return T.fill(note.isEmpty ? T.directPersonLineNoNote : T.directPersonLine,
                          ["otherName": other.name, "kind": BrainText.trimmed(rel.kind), "note": note])
        }
        if !people.isEmpty { sections.append(([T.directPeopleHeader] + people).joined(separator: "\n")) }

        let events = director.relevantEvents(for: ch, from: c.events, limit: maxEventsInPrompt)
        if !events.isEmpty { sections.append(list(T.eventsHeader, events.map(\.text))) }

        var userBlock: [String] = []
        if let about = aboutText(c.persona, user: user, char: ch.name) {
            userBlock.append(T.fill(T.directAboutUser, ["userLabel": userLabel(c.persona, user), "about": about]))
        }
        let facts = promptFacts(c.facts)
        if !facts.isEmpty { userBlock.append(list(T.fill(T.directMemoryHeader, ["userName": user]), facts)) }
        if !userBlock.isEmpty { sections.append(userBlock.joined(separator: "\n")) }

        // Only rules that never change between turns live here (see "Per-turn notes" in PromptTemplates).
        var rules = T.directRules.map { T.fill($0, ["name": ch.name, "userName": user]) }
        if ch.isBuiltIn { rules.append(T.fill(T.friendsOnlyRule, ["userName": user])) }
        addSafetyRule(to: &rules, level: .none, userName: user)
        sections.append(([T.rulesHeader] + rules).joined(separator: "\n"))

        let example = names(ch.exampleDialogue ?? "")
        if !example.isEmpty { sections.append(T.fill(T.exampleDialogue, ["exampleDialogue": example])) }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Group scene

    static func sceneRequest(_ c: SceneContext, speaker: Character) -> GenerationRequest {
        let user = userName(c.persona)
        var cast = unique(c.present)
        if !cast.contains(where: { $0.id == speaker.id }) { cast.append(speaker) }

        // Speaker names for transcript lines: anyone in town, guests who have left, then the people present.
        let namesByID = Dictionary((c.world.characters + c.allCharacters + cast).map { ($0.id, $0.name) },
                                   uniquingKeysWith: { _, later in later })
        let turns: [ChatTurn] = c.transcript.compactMap { m in
            switch m.role {
            case .narrator:
                return nil
            case .user:
                let text = body(of: m, who: user, user: user, char: speaker.name)
                return text.isEmpty ? nil : ChatTurn(role: .user, content: text)
            case .character:
                guard let id = m.speakerID, let name = namesByID[id] else { return nil }
                let text = body(of: m, who: name, user: user, char: name)
                guard !text.isEmpty else { return nil }
                return ChatTurn(role: .assistant, content: PromptTemplates.fill(PromptTemplates.speakerLine, ["name": name, "text": text]))
            }
        }

        let others = cast.filter { $0.id != speaker.id }
        var stop = others.map { PromptTemplates.fill(PromptTemplates.sceneStop, ["name": $0.name]) }
        stop.append(PromptTemplates.fill(PromptTemplates.sceneStop, ["name": user]))
        stop.append(PromptTemplates.sceneStopYou)

        var sampling = SamplingParams()
        sampling.temperature = 0.9
        let head = [ChatTurn(role: .system, content: sceneSystem(c, cast: cast, userName: user))]
        let notes = c.safety == .none ? [] : [safetyNote(c.safety)]
        return GenerationRequest(conversationKey: c.conversationKey,
                                 turns: withNotes(fitted(head: head, body: turns, budget: c.budgetTokens), notes,
                                                  name: speaker.name, user: user),
                                 assistantPrefix: PromptTemplates.fill(PromptTemplates.sceneSpeakerPrefix, ["name": speaker.name]),
                                 maxTokens: 90, stop: uniqueStrings(stop), sampling: sampling,
                                 replyOpener: crisisOpener(c.safety, PromptTemplates.crisisOpenerScene, user: user))
    }

    static func sceneSystem(_ c: SceneContext, cast: [Character], userName user: String) -> String {
        typealias T = PromptTemplates
        let director = WorldDirector(world: c.world)
        var sections: [String] = []

        let intro = BrainText.trimmed(T.fill(T.sceneIntro, [
            "worldName": c.world.name, "locationName": c.location.name,
            "locationAmbience": BrainText.sentence(BrainText.oneLine(c.location.ambience)),
        ]))
        sections.append(intro + "\n" + T.fill(T.sceneTime, ["dayPart": director.part(at: c.now).rawValue]))

        var who = [T.sceneWhoHeader]
        for ch in cast {
            func names(_ s: String) -> String { BrainText.trimmed(BrainText.fillNames(s, user: user, char: ch.name)) }
            let style = BrainText.shortened(names(ch.speakingStyle), maxChars: 160)
            // Only a real schedule entry counts; fallback wording like "spending time here" adds nothing.
            let hasSlot = ch.schedule.contains { $0.part == director.part(at: c.now) }
            let activity = hasSlot ? BrainText.oneLine(names(director.activity(of: ch, at: c.now))) : ""
            let details = [BrainText.sentence(BrainText.oneLine(names(ch.tagline))),
                           style.isEmpty ? "" : T.fill(T.sceneTalksLike, ["speakingStyle": BrainText.sentence(style)]),
                           activity.isEmpty ? "" : T.fill(T.sceneRightNow, ["activity": BrainText.withoutTrailingPunctuation(activity)])]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let species = BrainText.trimmed(ch.species ?? "")
            var line = T.fill(species.isEmpty ? T.sceneCharacterLineNoSpecies : T.sceneCharacterLine,
                              ["name": ch.name, "aSpecies": BrainText.withArticle(species), "details": details])
            if details.isEmpty, line.hasSuffix(": ") { line.removeLast(2) }
            who.append(line)
        }
        let about = BrainText.oneLine(aboutText(c.persona, user: user, char: user) ?? "")
        who.append(T.fill(T.sceneUserLine, ["userLabel": userLabel(c.persona, user),
                                            "about": about.isEmpty ? T.sceneUserDefaultAbout : about]))
        sections.append(who.joined(separator: "\n"))

        let events = director.relevantEvents(forAll: cast, from: c.events, limit: maxEventsInPrompt)
        if !events.isEmpty { sections.append(list(T.eventsHeader, events.map(\.text))) }

        var rules = T.sceneRules.map { T.fill($0, ["userName": user]) }
        addSafetyRule(to: &rules, level: .none, userName: user) // a flag rides on the newest line instead
        sections.append(([T.rulesHeader] + rules).joined(separator: "\n"))
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Town newsletter and memory

    /// `now` is not used by the template today; it keeps the call symmetric with
    /// `ReplyParser.awayEvents(from:world:now:)` so a later version can mention the season.
    static func awayEventsRequest(world: WorldDefinition, count: Int, now: Date) -> GenerationRequest {
        typealias T = PromptTemplates
        let residents = world.characters.map { ch -> String in
            let details = [BrainText.trimmed(ch.species ?? ""), BrainText.withoutTrailingPunctuation(BrainText.oneLine(ch.tagline))]
                .filter { !$0.isEmpty }.joined(separator: ", ")
            return details.isEmpty ? ch.name : T.fill(T.awayResident, ["name": ch.name, "details": details])
        }
        let system = BrainText.trimmed(T.fill(T.awaySystem, ["worldName": world.name, "lore": BrainText.oneLine(world.lore)]))
        let prompt = T.fill(T.awayUser, [
            "residents": residents.joined(separator: "; "),
            "places": world.locations.map(\.name).joined(separator: ", "),
            "n": String(min(max(count, 1), 3)), "worldName": world.name,
        ])
        var sampling = SamplingParams()
        sampling.temperature = 0.8
        return GenerationRequest(conversationKey: "world-away",
                                 turns: [ChatTurn(role: .system, content: system), ChatTurn(role: .user, content: prompt)],
                                 maxTokens: 220, sampling: sampling)
    }

    static func memoryRequest(character: Character, persona: UserPersona, recent: [Message]) -> GenerationRequest {
        typealias T = PromptTemplates
        let user = userName(persona)
        var lines: [String] = []
        var skippingReply = false
        for m in recent.filter({ $0.role != .narrator }).suffix(MemoryKeeper.summarizeEvery) {
            let who = m.role == .user ? user : character.name
            let text = BrainText.oneLine(body(of: m, who: who, user: user, char: character.name))
            // Something said by someone who may be in danger never becomes a memory (which could come up again,
            // or travel through town gossip), and neither does the answer to it.
            if m.role == .user {
                skippingReply = SafetyGuard.assess(text) != .none
                if skippingReply { continue }
            } else if skippingReply {
                skippingReply = false
                continue
            }
            if !text.isEmpty { lines.append(T.fill(T.speakerLine, ["name": who, "text": text])) }
        }
        let prompt = T.fill(T.memoryUser, ["userName": user, "name": character.name, "transcript": lines.joined(separator: "\n")])
        var sampling = SamplingParams()
        sampling.temperature = 0.3
        return GenerationRequest(conversationKey: "memory-\(character.id)",
                                 turns: [ChatTurn(role: .system, content: T.memorySystem), ChatTurn(role: .user, content: prompt)],
                                 maxTokens: 120, sampling: sampling)
    }

    // MARK: - Pieces

    static func userName(_ persona: UserPersona) -> String {
        let name = BrainText.trimmed(persona.name)
        return name.isEmpty ? PromptTemplates.defaultUserName : name
    }

    /// What a message contributes to a prompt. Voice notes become their transcript; photos and
    /// pictures become "[{who} sent a photo: caption]" (before user text, after character text).
    static func body(of m: Message, who: String, user: String, char: String) -> String {
        let text = BrainText.trimmed(BrainText.fillNames(m.text, user: user, char: char))
        guard let attachment = m.attachment else { return text }
        switch attachment.kind {
        case .voice:
            let transcript = BrainText.trimmed(BrainText.fillNames(attachment.caption ?? "", user: user, char: char))
            return transcript.isEmpty ? text : transcript
        case .photo, .picture:
            let caption = BrainText.oneLine(attachment.caption ?? "")
            let line = caption.isEmpty
                ? PromptTemplates.fill(PromptTemplates.photoLineNoCaption, ["who": who])
                : PromptTemplates.fill(PromptTemplates.photoLine, ["who": who, "caption": caption])
            let parts = m.role == .user ? [line, text] : [text, line]
            return parts.filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    /// Keeps `head` (system + greeting) and drops the oldest of `body` in chunks of `trimChunk` until the
    /// estimate fits `budget`. The newest message is always kept.
    static func fitted(head: [ChatTurn], body: [ChatTurn], budget: Int) -> [ChatTurn] {
        let costs = body.map(cost)
        var total = head.map(cost).reduce(0, +) + costs.reduce(0, +)
        var drop = 0
        while total > budget && drop < body.count - 1 {
            let next = min(drop + trimChunk, body.count - 1)
            total -= costs[drop..<next].reduce(0, +)
            drop = next
        }
        return head + body[drop...]
    }

    static func cost(_ turn: ChatTurn) -> Int { estimateTokens(turn.content) + turnOverheadTokens }

    /// Estimated prompt size of finished turns (same rule the trimming uses).
    static func estimateTokens(_ turns: [ChatTurn]) -> Int { turns.map(cost).reduce(0, +) }

    /// Adds per-turn notes to the newest user message (or as a final system turn if the chat doesn't end
    /// with one), so the stable part of the prompt stays byte-identical and the engine can reuse its cache.
    static func withNotes(_ turns: [ChatTurn], _ notes: [String], name: String, user: String) -> [ChatTurn] {
        guard !notes.isEmpty else { return turns }
        let text = notes.map { PromptTemplates.fill($0, ["name": name, "userName": user]) }.joined(separator: "\n")
        var out = turns
        if let last = out.indices.last, out[last].role == .user {
            out[last].content += "\n\n" + text
        } else {
            out.append(ChatTurn(role: .system, content: text))
        }
        return out
    }

    /// The fixed caring start of a reply to a crisis-level message; nil otherwise.
    private static func crisisOpener(_ level: SafetyLevel, _ template: String, user: String) -> String? {
        level == .crisis ? PromptTemplates.fill(template, ["userName": user]) : nil
    }

    /// The per-turn note for a flagged message: the crisis note, or a gentle one for a concern.
    private static func safetyNote(_ level: SafetyLevel) -> String {
        level == .crisis ? PromptTemplates.noteSafety : PromptTemplates.noteConcern
    }

    private static func addSafetyRule(to rules: inout [String], level: SafetyLevel, userName: String) {
        if level == .none {
            rules.append(PromptTemplates.fill(PromptTemplates.safetyRule, ["userName": userName]))
        } else {
            rules.insert(PromptTemplates.fill(PromptTemplates.safetyRuleFlagged, ["userName": userName]), at: 0)
        }
    }

    private static func list(_ header: String, _ items: [String]) -> String {
        ([header] + items.map { PromptTemplates.fill(PromptTemplates.listItem, ["item": BrainText.oneLine($0)]) })
            .joined(separator: "\n")
    }

    private static func userLabel(_ persona: UserPersona, _ user: String) -> String {
        let pronouns = BrainText.trimmed(persona.pronouns ?? "")
        return pronouns.isEmpty ? user : "\(user) (\(pronouns))"
    }

    /// The persona's about text, or a pronouns-only line, or nil when there is nothing to say.
    private static func aboutText(_ persona: UserPersona, user: String, char: String) -> String? {
        let about = BrainText.trimmed(BrainText.fillNames(persona.about, user: user, char: char))
        if !about.isEmpty { return about }
        let pronouns = BrainText.trimmed(persona.pronouns ?? "")
        return pronouns.isEmpty ? nil : PromptTemplates.fill(PromptTemplates.pronounsOnly, ["pronouns": pronouns])
    }

    /// Fact texts for the prompt: duplicates removed, oldest first (new facts land at the end, which
    /// keeps more of the prompt prefix reusable), at most `MemoryKeeper.maxFactsPerCharacter`,
    /// keeping pinned facts first when there are too many.
    static func promptFacts(_ facts: [MemoryFact]) -> [String] {
        var seen = Set<String>()
        var kept: [(offset: Int, fact: MemoryFact)] = []
        for (i, f) in facts.enumerated() {
            let text = BrainText.oneLine(f.text)
            guard !text.isEmpty, seen.insert(BrainText.fold(text)).inserted else { continue }
            kept.append((i, f))
        }
        kept.sort { ($0.fact.createdAt, $0.offset) < ($1.fact.createdAt, $1.offset) }
        let limit = MemoryKeeper.maxFactsPerCharacter
        if kept.count > limit {
            let pinned = kept.filter { $0.fact.source == .pinned }.suffix(limit)
            let others = kept.filter { $0.fact.source != .pinned }.suffix(limit - pinned.count)
            kept = (Array(pinned) + Array(others)).sorted { ($0.fact.createdAt, $0.offset) < ($1.fact.createdAt, $1.offset) }
        }
        return kept.map { BrainText.oneLine($0.fact.text) }
    }

    private static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// English weekday name in the calendar's time zone.
    static func weekday(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let index = gregorian.component(.weekday, from: date) - 1
        return weekdayNames.indices.contains(index) ? weekdayNames[index] : "today"
    }

    private static func unique(_ characters: [Character]) -> [Character] {
        var seen = Set<String>()
        return characters.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }
}
