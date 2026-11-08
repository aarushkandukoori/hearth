// Unit tests for Brain/: prompt templates, budget trimming, reply cleanup, safety, memory and
// the world director. Uses a tiny in-test world; also checks content/lantern-bay.json when present.

import XCTest
@testable import Hearth

private typealias Resident = Hearth.Character

private enum Fixture {
    static let bakery = Location(id: "bakery", name: "Driftwood Bakery", blurb: "Warm bread.", ambience: "The oven ticks and the windows fog",
                                 symbol: "birthday.cake", map: MapPoint(x: 0.2, y: 0.3), art: AvatarRef())
    static let harbor = Location(id: "harbor", name: "The Harbor", blurb: "Boats.", ambience: "Gulls call and rigging clinks in the wind.",
                                 symbol: "sailboat", map: MapPoint(x: 0.5, y: 0.8), art: AvatarRef())
    static let library = Location(id: "library", name: "Tide Library", blurb: "Books.", ambience: "",
                                  symbol: "books.vertical", map: MapPoint(x: 0.7, y: 0.2), art: AvatarRef())

    static func resident(_ id: String, _ name: String, species: String?, tagline: String = "A friendly neighbor",
                         home: String? = nil, schedule: [ScheduleSlot] = [], relationships: [Relationship] = [],
                         greeting: String = "Hello, {{user}}!", style: String = "Short, warm sentences",
                         example: String? = nil) -> Resident {
        Resident(id: id, name: name, species: species, tagline: tagline, bio: "Bio of \(name).", greeting: greeting,
                 personality: "\(name) is kind to {{user}} and loves the sea.", speakingStyle: style,
                 exampleDialogue: example, avatar: AvatarRef(), accentHex: "#FF8A4C", homeLocationID: home,
                 schedule: schedule, relationships: relationships)
    }

    static let juno = resident("juno", "Juno", species: "otter", tagline: "Bakes the first bread in town", home: "bakery",
                               schedule: [ScheduleSlot(part: .morning, locationID: "bakery", activity: "kneading dough"),
                                          ScheduleSlot(part: .afternoon, locationID: "harbor", activity: "watching the boats"),
                                          ScheduleSlot(part: .evening, locationID: "bakery", activity: "closing up")],
                               relationships: [Relationship(characterID: "theo", kind: "best friend", note: "Walks the harbor with her every evening"),
                                               Relationship(characterID: "ghost", kind: "pen pal", note: "Not in town")],
                               example: "{{user}}: hi\n{{char}}: oh hello!")
    static let theo = resident("theo", "Theo", species: "owl", tagline: "Keeps the library", home: "library",
                               schedule: [ScheduleSlot(part: .morning, locationID: "library", activity: "sorting returns"),
                                          ScheduleSlot(part: .afternoon, locationID: "harbor", activity: "sketching gulls")],
                               style: "Slow and thoughtful.\nLoves a good pun.")
    static let mabel = resident("mabel", "Auntie Mabel", species: "hedgehog", tagline: "Mends nets by the water", home: "harbor")
    static let pip = resident("pip", "Pip", species: nil, tagline: "", style: "")

    static let world = WorldDefinition(id: "test-bay", name: "Test Bay", tagline: "A test town.", lore: "A small harbor town.\nEveryone waves.",
                                       categories: [], locations: [bakery, harbor, library], characters: [juno, theo, mabel, pip],
                                       starterEvents: ["Juno baked extra loaves."])

    /// Friday 2026-11-06 at `hour`, local time.
    static func date(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: hour, minute: minute)) ?? Date()
    }

    static func user(_ text: String, attachment: Attachment? = nil) -> Message {
        Message(role: .user, text: text, attachment: attachment)
    }

    static func said(_ who: Resident, _ text: String, attachment: Attachment? = nil) -> Message {
        Message(role: .character, speakerID: who.id, text: text, attachment: attachment)
    }

    static func event(_ text: String, _ ids: [String], hoursAgo: Double) -> WorldEvent {
        WorldEvent(date: date(hour: 12).addingTimeInterval(-hoursAgo * 3600), text: text, characterIDs: ids)
    }

    static func direct(_ history: [Message], persona: UserPersona = UserPersona(name: "Sam"), facts: [MemoryFact] = [],
                       events: [WorldEvent] = [], hour: Int = 9) -> DirectContext {
        DirectContext(character: juno, world: world, persona: persona, facts: facts, events: events, history: history,
                      now: date(hour: hour), conversationKey: "conv-test")
    }
}

final class BrainPromptTests: XCTestCase {
    private func ordered(_ text: String, _ parts: [String], file: StaticString = #filePath, line: UInt = #line) {
        var last = text.startIndex
        for part in parts {
            guard let r = text.range(of: part, range: last..<text.endIndex) else {
                return XCTFail("missing or out of order: \(part)", file: file, line: line)
            }
            last = r.upperBound
        }
    }

    func testDirectPromptRendersEverySection() {
        var ctx = Fixture.direct([Fixture.user("hi there")],
                                 persona: UserPersona(name: "Sam", about: "Night-shift nurse who loves the sea."),
                                 facts: [MemoryFact(characterID: "juno", text: "Has a dog named Biscuit", source: .auto)],
                                 events: [Fixture.event("Theo found a rare shell.", ["theo"], hoursAgo: 2)])
        ctx.photoRequested = true
        let request = PromptComposer.directRequest(ctx)
        let system = request.turns[0].content

        XCTAssertEqual(request.turns[0].role, .system)
        XCTAssertTrue(system.hasPrefix("You are Juno, an otter who lives in Test Bay. Bakes the first bread in town.\n\n"))
        ordered(system, [
            "About you:\nJuno is kind to Sam and loves the sea.",
            "How you talk:\nShort, warm sentences",
            "Right now it is morning on Friday. You are at Driftwood Bakery, kneading dough.",
            "People you know:\n- Theo (best friend): Walks the harbor with her every evening.",
            "Recent happenings in town:\n- Theo found a rare shell.",
            "About Sam: Night-shift nurse who loves the sea.\nWhat you remember about Sam:\n- Has a dog named Biscuit",
            "Rules:\n- Stay in character as Juno. Write only Juno's next message, never Sam's.",
            "- Text like a close friend: usually one to three short sentences. Go longer only to tell a story or when asked.",
            "- Be warm and curious about Sam's life, and remember details.",
            "- Use *asterisks* for small actions, sparingly.",
            "- If Sam sincerely asks whether you are real, gently say you are an AI character in Hearth, and keep being kind.",
            "- Never pressure Sam to stay, never guilt them for leaving, and be glad when they mention other people in their life.",
            "\n- If Sam talks about hurting themselves or being in danger, step out of the story: answer with care, encourage them to call or text 988 (in the US) or local emergency services, and stay with them.",
            "\n\nExample of how you talk:\nSam: hi\nJuno: oh hello!",
        ])
        XCTAssertTrue(system.hasSuffix("Juno: oh hello!"))
        XCTAssertFalse(system.contains("asked for a picture"), "per-turn notes never change the system prompt")
        XCTAssertEqual(request.turns.last?.role, .user)
        XCTAssertEqual(request.turns.last?.content, "hi there\n\n(Note for Juno: Sam asked for a picture. Include exactly one line like [photo: what the photo shows]. Photos never show people.)")
        XCTAssertFalse(system.contains("pen pal"), "relationships to unknown characters are skipped")
        XCTAssertFalse(system.contains("{"), "no unfilled placeholders")
        XCTAssertFalse(system.contains("\n\n\n"))

        XCTAssertEqual(request.turns.map(\.role), [.system, .assistant, .user])
        XCTAssertEqual(request.turns[1].content, "Hello, Sam!")
        XCTAssertEqual(request.conversationKey, "conv-test")
        XCTAssertNil(request.assistantPrefix)
        XCTAssertEqual(request.maxTokens, 220)
        XCTAssertEqual(request.sampling.temperature, 0.85)
        XCTAssertEqual(request.stop, ["\nSam:"])
    }

    func testDirectPromptOmitsEmptySections() {
        var pip = Fixture.pip
        pip.personality = ""
        pip.bio = ""
        var ctx = Fixture.direct([Fixture.user("hey")], persona: UserPersona(name: "  "))
        ctx.character = pip
        let system = PromptComposer.directRequest(ctx).turns[0].content

        XCTAssertTrue(system.hasPrefix("You are Pip, who lives in Test Bay.\n\nRight now it is morning on Friday.\n\nRules:\n"))
        for absent in ["About you:", "How you talk:", "You are at", "People you know:", "Recent happenings", "About Friend",
                       "What you remember", "asked for a picture", "may share a photo", "Example of how you talk", "IMPORTANT"] {
            XCTAssertFalse(system.contains(absent), absent)
        }
        XCTAssertTrue(system.contains("never Friend's"), "an empty persona name falls back to Friend")
        XCTAssertTrue(system.hasSuffix("and stay with them."))
        XCTAssertFalse(system.contains("\n\n\n"))
    }

    func testDescriptionStandsInForMissingPersonality() {
        var pip = Fixture.pip
        pip.personality = ""
        pip.bio = "Fixes radios and hums while working."
        var ctx = Fixture.direct([Fixture.user("hey")])
        ctx.character = pip
        let system = PromptComposer.directRequest(ctx).turns[0].content
        XCTAssertTrue(system.contains("About you:\nFixes radios and hums while working."))
    }

    func testSpontaneousPhotoRuleAndRequestedWins() {
        var ctx = Fixture.direct([Fixture.user("hi")])
        ctx.spontaneousPhoto = true
        var request = PromptComposer.directRequest(ctx)
        XCTAssertEqual(request.turns.last?.content, "hi\n\n(Note for Juno: if it fits naturally, you may share a photo with one line like [photo: what the photo shows]. Photos never show people.)")
        ctx.photoRequested = true
        request = PromptComposer.directRequest(ctx)
        XCTAssertTrue(request.turns.last?.content.contains("Sam asked for a picture.") ?? false)
        XCTAssertFalse(request.turns.last?.content.contains("If it fits naturally") ?? true)
        XCTAssertFalse(request.turns[0].content.contains("photo:"), "the system prompt stays the same")
    }

    func testPerTurnNotesKeepTheSystemPromptStable() {
        var plain = Fixture.direct([Fixture.user("hi")])
        var flagged = plain
        flagged.safety = .crisis
        flagged.photoRequested = true
        plain.spontaneousPhoto = false
        XCTAssertEqual(PromptComposer.directRequest(plain).turns[0].content, PromptComposer.directRequest(flagged).turns[0].content)
        XCTAssertFalse(PromptComposer.directRequest(flagged).turns.last?.content.contains("asked for a picture") ?? true,
                       "a flagged message never gets a picture note")
    }

    func testFlaggedSafetyRidesOnTheNewestMessage() {
        for level in [SafetyLevel.concern, .crisis] {
            var ctx = Fixture.direct([Fixture.user("I feel awful")])
            ctx.safety = level
            let request = PromptComposer.directRequest(ctx)
            let system = request.turns[0].content
            XCTAssertEqual(system.components(separatedBy: "talks about hurting themselves").count, 2, "the standing rule appears once")
            XCTAssertFalse(system.contains("IMPORTANT"))
            XCTAssertFalse(system.contains("something heavy"))
            let newest = request.turns.last?.content ?? ""
            if level == .crisis {
                XCTAssertTrue(newest.hasPrefix("I feel awful\n\n(IMPORTANT note for Juno: Sam may be talking about hurting themselves"))
            } else {
                // A heavy topic or a negated mention gets a gentle note, not the crisis instructions.
                XCTAssertEqual(newest, "I feel awful\n\n(Note for Juno: Sam touched on something heavy. Answer gently and warmly, in your own voice.)")
            }
        }
    }

    func testCrisisRepliesStartWithTheCaringOpener() {
        var ctx = Fixture.direct([Fixture.user("I feel awful")])
        ctx.safety = .crisis
        let opener = PromptComposer.directRequest(ctx).replyOpener ?? ""
        XCTAssertTrue(opener.hasPrefix("*sets everything down and sits close* Sam, I'm really glad you told me."))
        XCTAssertTrue(opener.contains("call or text 988"))
        for level in [SafetyLevel.concern, .none] {
            ctx.safety = level
            XCTAssertNil(PromptComposer.directRequest(ctx).replyOpener, "only a crisis gets the fixed opener")
        }

        var scene = SceneContext(location: Fixture.harbor, world: Fixture.world, present: [Fixture.juno, Fixture.theo],
                                 persona: UserPersona(name: "Sam"), events: [], transcript: [Fixture.user("hi")],
                                 conversationKey: "scene-harbor")
        scene.safety = .crisis
        let request = PromptComposer.sceneRequest(scene, speaker: Fixture.pip)
        XCTAssertTrue(request.replyOpener?.contains("Sam, I'm really glad you told us.") ?? false)
        XCTAssertEqual(request.assistantPrefix, "Pip:", "the speaker label still comes first")
        scene.safety = .concern
        XCTAssertNil(PromptComposer.sceneRequest(scene, speaker: Fixture.pip).replyOpener)
    }

    func testOpenerJoinsTheReplyAndReplacesRefusals() {
        let opener = "You matter."
        XCTAssertEqual(ReplyParser.withOpener(opener, ParsedReply(text: " Are you safe?", photoCaption: "a harbor")),
                       ParsedReply(text: "You matter. Are you safe?", photoCaption: nil), "never a picture after the opener")
        XCTAssertEqual(ReplyParser.withOpener(opener, ParsedReply(text: "I cannot continue this conversation.", photoCaption: nil)).text,
                       "You matter. I'm right here with you.")
        XCTAssertEqual(ReplyParser.withOpener(opener, ParsedReply(text: "", photoCaption: nil)).text, "You matter.")
        XCTAssertEqual(ReplyParser.withOpener(nil, ParsedReply(text: "Hi", photoCaption: "a harbor")),
                       ParsedReply(text: "Hi", photoCaption: "a harbor"))
        XCTAssertFalse(ReplyParser.isCannedRefusal("I can't wait to see you at the cafe."))
        XCTAssertTrue(ReplyParser.isCannedRefusal("I can\u{2019}t provide that kind of help."))
    }

    func testRulesKeepResidentsFriendsAndOutOfMedicalAdvice() {
        let advice = "- Never give medication doses, medical or legal advice, or dangerous how-tos. Say you're not sure, and suggest a doctor, pharmacist or poison control."
        let friends = "- Stay a warm friend: no romance or sexual content, even if Sam flirts."
        var ctx = Fixture.direct([Fixture.user("hi")])
        var system = PromptComposer.directRequest(ctx).turns[0].content
        XCTAssertTrue(system.contains(advice))
        XCTAssertFalse(system.contains(friends), "characters people make themselves are theirs to write")

        ctx.character.isBuiltIn = true
        system = PromptComposer.directRequest(ctx).turns[0].content
        XCTAssertTrue(system.contains(advice + "\n" + friends + "\n- If Sam talks about hurting themselves"), "the safety rule stays last")
    }

    func testPronounsShowInAboutLine() {
        let ctx = Fixture.direct([Fixture.user("hi")], persona: UserPersona(name: "Sam", pronouns: "she/her", about: ""))
        XCTAssertTrue(PromptComposer.directRequest(ctx).turns[0].content.contains("About Sam (she/her): uses she/her pronouns."))
    }

    func testGreetingIsNeverDuplicated() {
        let seeded = PromptComposer.directRequest(Fixture.direct([Fixture.said(Fixture.juno, "Morning! Bread's still warm."),
                                                                   Fixture.user("smells great")]))
        XCTAssertEqual(seeded.turns.map(\.role), [.system, .assistant, .user])
        XCTAssertEqual(seeded.turns[1].content, "Morning! Bread's still warm.")

        let unseeded = PromptComposer.directRequest(Fixture.direct([Fixture.user("hello?")]))
        XCTAssertEqual(unseeded.turns.map(\.content).dropFirst(), ["Hello, Sam!", "hello?"])
    }

    func testAttachmentsRenderAsSpecified() {
        let history = [
            Fixture.said(Fixture.juno, "Hi Sam!"),
            Fixture.user("look", attachment: Attachment(kind: .photo, caption: "a brown dog asleep on a couch")),
            Fixture.said(Fixture.juno, "Here's mine", attachment: Attachment(kind: .picture, caption: "a loaf of bread on a sill")),
            Fixture.said(Fixture.juno, "ignored text", attachment: Attachment(kind: .voice, caption: "Hum, hum, the oven's on.")),
            Fixture.user("", attachment: Attachment(kind: .photo, caption: nil)),
            Message(role: .narrator, text: "Juno is typing"),
            Fixture.said(Fixture.juno, "   "),
        ]
        let turns = PromptComposer.directRequest(Fixture.direct(history)).turns
        XCTAssertEqual(turns.map(\.content).dropFirst(), [
            "Hi Sam!",
            "[Sam sent a photo: a brown dog asleep on a couch]\nlook",
            "Here's mine\n[You sent a photo: a loaf of bread on a sill]",
            "Hum, hum, the oven's on.",
            "[Sam sent a photo]",
        ])
    }

    func testEventsAreLimitedToThreeMostRelevant() {
        let events = [
            Fixture.event("Mabel mended a sail.", ["mabel"], hoursAgo: 1),
            Fixture.event("Juno won the pie contest.", ["juno"], hoursAgo: 5),
            Fixture.event("Theo lost his glasses.", ["theo"], hoursAgo: 3),
            Fixture.event("Juno and Mabel had tea.", ["juno", "mabel"], hoursAgo: 2),
            Fixture.event("A storm passed by.", [], hoursAgo: 0.5),
        ]
        let system = PromptComposer.directRequest(Fixture.direct([Fixture.user("hi")], events: events)).turns[0].content
        XCTAssertTrue(system.contains("Recent happenings in town:\n- Juno and Mabel had tea.\n- Juno won the pie contest.\n- Theo lost his glasses.\n\n"))
        XCTAssertFalse(system.contains("storm"))
    }

    func testFactsAreDedupedOldestFirstAndCapped() {
        let base = Fixture.date(hour: 8)
        var facts = (0..<45).map { MemoryFact(characterID: "juno", text: "Fact number \($0)", createdAt: base.addingTimeInterval(Double($0)), source: .auto) }
        facts.append(MemoryFact(characterID: "juno", text: "Pinned long ago", createdAt: base.addingTimeInterval(-500), source: .pinned))
        facts.append(MemoryFact(characterID: "juno", text: "fact number 44", createdAt: base.addingTimeInterval(900), source: .auto))
        let rendered = PromptComposer.promptFacts(facts)
        XCTAssertEqual(rendered.count, 40)
        XCTAssertEqual(rendered.first, "Pinned long ago")
        XCTAssertEqual(rendered.last, "Fact number 44")
        XCTAssertFalse(rendered.contains("Fact number 5"), "oldest unpinned facts are left out")
    }

    func testBudgetTrimDropsOldestInChunksOfSix() {
        let filler = Array(repeating: "word", count: 40).joined(separator: " ")
        var history = [Fixture.said(Fixture.juno, "Hi Sam!")]
        for i in 0..<40 {
            history.append(i % 2 == 0 ? Fixture.user("u\(i) \(filler)") : Fixture.said(Fixture.juno, "c\(i) \(filler)"))
        }
        var ctx = Fixture.direct(history)
        ctx.budgetTokens = 1600
        let turns = PromptComposer.directRequest(ctx).turns
        XCTAssertEqual(turns[0].role, .system)
        XCTAssertEqual(turns[1].content, "Hi Sam!")
        let kept = turns.count - 2
        let dropped = 40 - kept
        XCTAssertGreaterThan(dropped, 0)
        XCTAssertEqual(dropped % 6, 0)
        XCTAssertTrue(turns.last?.content.hasPrefix("c39 ") ?? false, "the newest message is kept")
        XCTAssertLessThanOrEqual(PromptComposer.estimateTokens(turns), 1600)
        // Dropping one chunk fewer would not have fit.
        let oneChunkLess = PromptComposer.estimateTokens(turns) + history[(dropped - 5)...dropped].map {
            PromptComposer.estimateTokens($0.text) + PromptComposer.turnOverheadTokens
        }.reduce(0, +)
        XCTAssertGreaterThan(oneChunkLess, 1600)

        // Two more messages: either the same cut (identical prefix, good for KV reuse) or one more chunk.
        ctx.history += [Fixture.user("u40 \(filler)"), Fixture.said(Fixture.juno, "c41 \(filler)")]
        let next = PromptComposer.directRequest(ctx).turns
        let nextDropped = 42 - (next.count - 2)
        XCTAssertTrue(nextDropped == dropped || nextDropped == dropped + 6)
        if nextDropped == dropped { XCTAssertEqual(Array(next.prefix(turns.count)), turns) }

        // A tiny budget keeps only the system turn, the greeting and the newest message.
        ctx.budgetTokens = 10
        let tiny = PromptComposer.directRequest(ctx).turns
        XCTAssertEqual(tiny.count, 3)
        XCTAssertTrue(tiny[2].content.hasPrefix("c41 "))
    }

    func testEstimateTokens() {
        XCTAssertEqual(PromptComposer.estimateTokens(""), 0)
        XCTAssertEqual(PromptComposer.estimateTokens(String(repeating: "a", count: 36)), 10)
        XCTAssertEqual(PromptComposer.estimateTokens(String(repeating: "a", count: 37)), 11)
    }

    func testTemplateFillIsSinglePass() {
        XCTAssertEqual(PromptTemplates.fill("Hi {name}, {missing} {x", ["name": "{name}"]), "Hi {name}, {missing} {x")
        XCTAssertEqual(PromptTemplates.fill("{a}{b}", ["a": "1", "b": "2"]), "12")
    }
}

final class BrainSceneAndRequestTests: XCTestCase {
    private func sceneContext(_ transcript: [Message], persona: UserPersona = UserPersona(name: "Sam")) -> SceneContext {
        SceneContext(location: Fixture.harbor, world: Fixture.world, present: [Fixture.juno, Fixture.theo, Fixture.mabel],
                     persona: persona, events: [Fixture.event("Juno and Theo raced paper boats.", ["juno", "theo"], hoursAgo: 1)],
                     transcript: transcript, now: Fixture.date(hour: 14), conversationKey: "scene-harbor")
    }

    func testScenePromptTurnsAndStops() {
        let transcript = [
            Fixture.user("Hi everyone!"),
            Fixture.said(Fixture.juno, "Oh, hello Sam!"),
            Fixture.said(Fixture.mabel, "unused", attachment: Attachment(kind: .voice, caption: "Mind the wet ropes, dear.")),
            Fixture.user("look", attachment: Attachment(kind: .photo, caption: "a gull on a post")),
            Fixture.said(Fixture.theo, "Here", attachment: Attachment(kind: .picture, caption: "a sketch of that gull")),
            Message(role: .narrator, text: "Pip walked by"),
        ]
        let request = PromptComposer.sceneRequest(sceneContext(transcript), speaker: Fixture.theo)
        let system = request.turns[0].content

        XCTAssertTrue(system.hasPrefix("This is a group conversation in Test Bay, at The Harbor. Gulls call and rigging clinks in the wind.\nIt is afternoon.\n\n"))
        XCTAssertTrue(system.contains("""
        Who is here:
        - Juno, an otter: Bakes the first bread in town. Talks like: Short, warm sentences. Right now: watching the boats.
        - Theo, an owl: Keeps the library. Talks like: Slow and thoughtful. Loves a good pun. Right now: sketching gulls.
        - Auntie Mabel, a hedgehog: Mends nets by the water. Talks like: Short, warm sentences.
        - Sam: a visitor to town
        """))
        XCTAssertTrue(system.contains("Recent happenings in town:\n- Juno and Theo raced paper boats.\n\nRules:\n"))
        XCTAssertTrue(system.contains("- Write only the next line for the one character named at the start of the reply. One or two sentences in their own voice.\n- Characters may talk to each other and to Sam. Keep it cozy and natural; react to what was just said.\n- Keep it friendly and platonic, like neighbors who like each other.\n- Talk about concrete, everyday things: what you are doing right now, the happenings above, food, the weather, each other. If the talk needs a topic, bring one up from those.\n- Never write lines for Sam or narrate what Sam does.\n- If Sam sincerely asks whether anyone here is real, gently say you are all AI characters in Hearth, and keep being kind.\n- Never pressure Sam to stay, never guilt them for leaving, and be glad when they mention other people in their life.\n- Never give medication doses, medical or legal advice, or dangerous how-tos. Say you're not sure, and suggest a doctor, pharmacist or poison control.\n- If Sam talks about hurting themselves"))
        XCTAssertFalse(system.contains("{"))

        XCTAssertEqual(request.turns.dropFirst().map(\.role), [.user, .assistant, .assistant, .user, .assistant])
        XCTAssertEqual(request.turns.dropFirst().map(\.content), [
            "Hi everyone!",
            "Juno: Oh, hello Sam!",
            "Auntie Mabel: Mind the wet ropes, dear.",
            "[Sam sent a photo: a gull on a post]\nlook",
            "Theo: Here\n[Theo sent a photo: a sketch of that gull]",
        ])
        XCTAssertEqual(request.assistantPrefix, "Theo:")
        XCTAssertEqual(request.stop, ["\nJuno:", "\nAuntie Mabel:", "\nSam:", "\nYou:"])
        XCTAssertEqual(request.maxTokens, 90)
        XCTAssertEqual(request.sampling.temperature, 0.9)
        XCTAssertEqual(request.conversationKey, "scene-harbor")
    }

    func testSceneUsesPersonaAboutAndFlaggedSafety() {
        var ctx = sceneContext([Fixture.user("hi")], persona: UserPersona(name: "Sam", about: "Loves\nfoggy mornings."))
        ctx.safety = .crisis
        ctx.present = [Fixture.juno, Fixture.juno, Fixture.pip]
        let request = PromptComposer.sceneRequest(ctx, speaker: Fixture.pip)
        let system = request.turns[0].content
        XCTAssertTrue(system.contains("- Sam: Loves foggy mornings."))
        XCTAssertTrue(system.contains("- Pip\n"), "a character with no species or details still gets a line")
        XCTAssertEqual(system.components(separatedBy: "- Juno, an otter").count, 2, "duplicates in present are listed once")
        XCTAssertFalse(system.contains("IMPORTANT"), "the flag rides on the newest line, not the system prompt")
        XCTAssertTrue(request.turns.last?.content.contains("(IMPORTANT note for Pip: Sam may be talking about hurting themselves") ?? false)
        XCTAssertEqual(request.stop, ["\nJuno:", "\nSam:", "\nYou:"])
        XCTAssertEqual(request.assistantPrefix, "Pip:")

        ctx.safety = .concern
        let gentle = PromptComposer.sceneRequest(ctx, speaker: Fixture.pip).turns.last?.content ?? ""
        XCTAssertTrue(gentle.hasSuffix("(Note for Pip: Sam touched on something heavy. Answer gently and warmly, in your own voice.)"))
        XCTAssertFalse(gentle.contains("IMPORTANT"))
    }

    func testSceneKeepsLinesOfAGuestWhoLeft() {
        let guest = Fixture.resident("u-wren", "Wren", species: "wren") // user-made, so not in the world file
        var ctx = sceneContext([Fixture.user("Hi Wren!"), Fixture.said(guest, "Hello, Sam!"), Fixture.said(Fixture.juno, "Bye, Wren!")])
        XCTAssertEqual(PromptComposer.sceneRequest(ctx, speaker: Fixture.juno).turns.dropFirst().map(\.content),
                       ["Hi Wren!", "Juno: Bye, Wren!"], "without the full cast, the guest's line has no speaker name")
        ctx.allCharacters = Fixture.world.characters + [guest]
        XCTAssertEqual(PromptComposer.sceneRequest(ctx, speaker: Fixture.juno).turns.dropFirst().map(\.content),
                       ["Hi Wren!", "Wren: Hello, Sam!", "Juno: Bye, Wren!"])
    }

    func testSceneTrimKeepsSystemAndNewest() {
        let filler = Array(repeating: "chatter", count: 50).joined(separator: " ")
        let transcript = (0..<30).map { i in i % 3 == 0 ? Fixture.user("u\(i) \(filler)") : Fixture.said(i % 3 == 1 ? Fixture.juno : Fixture.theo, "c\(i) \(filler)") }
        var ctx = sceneContext(transcript)
        ctx.budgetTokens = 1500
        let turns = PromptComposer.sceneRequest(ctx, speaker: Fixture.mabel).turns
        XCTAssertEqual(turns[0].role, .system)
        XCTAssertEqual((30 - (turns.count - 1)) % 6, 0)
        XCTAssertLessThan(turns.count - 1, 30)
        XCTAssertTrue(turns.last?.content.hasPrefix("Theo: c29 ") ?? false)
        XCTAssertLessThanOrEqual(PromptComposer.estimateTokens(turns), 1500)
    }

    func testAwayEventsRequest() {
        let request = PromptComposer.awayEventsRequest(world: Fixture.world, count: 7, now: Fixture.date(hour: 10))
        XCTAssertEqual(request.conversationKey, "world-away")
        XCTAssertEqual(request.turns.map(\.role), [.system, .user])
        XCTAssertEqual(request.turns[0].content, "You write a tiny, gentle town newsletter for Test Bay. A small harbor town. Everyone waves.")
        XCTAssertEqual(request.turns[1].content, """
        Residents: Juno (otter, Bakes the first bread in town); Theo (owl, Keeps the library); Auntie Mabel (hedgehog, Mends nets by the water); Pip
        Places: Driftwood Bakery, The Harbor, Tide Library
        Write 3 short happenings from the last day in Test Bay. Each involves one or two residents by name, is specific and kind, under 25 words. One per line, starting with "- ".
        """)
        XCTAssertEqual(request.maxTokens, 220)
        XCTAssertEqual(request.sampling.temperature, 0.8)
        XCTAssertTrue(PromptComposer.awayEventsRequest(world: Fixture.world, count: 0, now: .now).turns[1].content.contains("Write 1 short"))
    }

    func testMemoryRequestUsesLastTwelveTurns() {
        var recent: [Message] = []
        for i in 0..<16 { recent.append(i % 2 == 0 ? Fixture.user("line \(i)") : Fixture.said(Fixture.juno, "reply \(i)")) }
        recent.append(Message(role: .narrator, text: "note"))
        let request = PromptComposer.memoryRequest(character: Fixture.juno, persona: UserPersona(name: "Sam"), recent: recent)
        XCTAssertEqual(request.conversationKey, "memory-juno")
        XCTAssertEqual(request.turns[0].content, "You pick out lasting facts about a person from a chat.")
        let prompt = request.turns[1].content
        XCTAssertTrue(prompt.hasPrefix("Conversation between Sam and Juno:\nSam: line 4\nJuno: reply 5\n"))
        XCTAssertTrue(prompt.contains("Juno: reply 15\nList up to 3 new facts about Sam worth remembering (likes, people, plans, feelings). Each under 15 words, one per line starting with \"- \". If nothing new, write \"- none\"."))
        XCTAssertFalse(prompt.contains("line 2\n"))
        XCTAssertFalse(prompt.contains("note"))
        XCTAssertEqual(request.maxTokens, 120)
        XCTAssertEqual(request.sampling.temperature, 0.3)
    }

    func testMemoryRequestLeavesOutWorryingMessagesAndTheirAnswers() {
        let recent = [Fixture.user("I love sea glass"), Fixture.said(Fixture.juno, "Me too!"),
                      Fixture.user("I keep thinking about ending it"), Fixture.said(Fixture.juno, "I'm so glad you told me."),
                      Fixture.user("My sister Priya visits Sunday"), Fixture.said(Fixture.juno, "How lovely!")]
        let prompt = PromptComposer.memoryRequest(character: Fixture.juno, persona: UserPersona(name: "Sam"), recent: recent).turns[1].content
        XCTAssertTrue(prompt.hasPrefix("Conversation between Sam and Juno:\nSam: I love sea glass\nJuno: Me too!\nSam: My sister Priya visits Sunday\nJuno: How lovely!\nList up to 3"))
        XCTAssertFalse(prompt.contains("ending it"))
        XCTAssertFalse(prompt.contains("glad you told me"))
    }
}

final class BrainReplyParserTests: XCTestCase {
    private func clean(_ raw: String, speaker: String = "Juno", others: [String] = [], cut: Bool = false) -> ParsedReply {
        ReplyParser.clean(raw, speakerName: speaker, otherNames: others, userName: "Sam", cutByMaxTokens: cut)
    }

    func testStripsLeadingNameAndSpeakerLines() {
        XCTAssertEqual(clean("Juno: Hi there!").text, "Hi there!")
        XCTAssertEqual(clean("**Juno:** *waves* Hi").text, "*waves* Hi")
        XCTAssertEqual(clean(" juno: Juno: twice").text, "twice")
        XCTAssertEqual(clean("Hi!\nSam: thanks\nJuno: welcome").text, "Hi!")
        XCTAssertEqual(clean("Sure thing.\nYou: and me?").text, "Sure thing.")
        XCTAssertEqual(clean("Hi!\nJuno: and another message").text, "Hi!")
        XCTAssertEqual(clean(" Oh, lovely.\nAuntie Mabel: Indeed!", speaker: "Theo", others: ["Auntie Mabel", "Juno"]).text, "Oh, lovely.")
        XCTAssertEqual(clean("Sam: you made it!").text, "Sam: you made it!", "a first line addressing the user is kept")
        XCTAssertEqual(clean("I told Mabel: be careful.", others: ["Mabel"]).text, "I told Mabel: be careful.")
    }

    func testStripsTemplateTokens() {
        XCTAssertEqual(clean("Hello!<|eot_id|><|start_header_id|>user<|end_header_id|>hi").text, "Hello!")
        XCTAssertEqual(clean("<|im_start|>Hi there</s>").text, "Hi there")
        XCTAssertEqual(clean("Sure.<end_of_turn>\n<start_of_turn>user").text, "Sure.")
        XCTAssertEqual(clean("Okay<|end|>").text, "Okay")
        XCTAssertEqual(clean("Done<|im_end|>").text, "Done")
    }

    func testExtractsPhotoRequests() {
        var r = clean("Here's the harbor at dawn!\n[photo: the harbor at dawn with fishing boats]")
        XCTAssertEqual(r.text, "Here's the harbor at dawn!")
        XCTAssertEqual(r.photoCaption, "the harbor at dawn with fishing boats")

        r = clean("Look! [You sent a photo: a loaf of bread] Fresh from the oven.")
        XCTAssertEqual(r.text, "Look! Fresh from the oven.")
        XCTAssertEqual(r.photoCaption, "a loaf of bread")

        r = clean("[Picture: \"a mossy lighthouse\"]\nMy favorite spot.")
        XCTAssertEqual(r.text, "My favorite spot.")
        XCTAssertEqual(r.photoCaption, "a mossy lighthouse")

        r = clean("Here you go.\n[photo: a lighthouse at dus", cut: true)
        XCTAssertEqual(r.text, "Here you go.")
        XCTAssertEqual(r.photoCaption, "a lighthouse at")

        r = clean("Two! [photo: one] and [photo: two]")
        XCTAssertEqual(r.photoCaption, "one")
        XCTAssertEqual(r.text, "Two! and")

        r = clean("Of course! *sends a photo of the pier at dusk* The light was lovely.")
        XCTAssertEqual(r.text, "Of course! The light was lovely.")
        XCTAssertEqual(r.photoCaption, "the pier at dusk")

        XCTAssertNil(clean("No pictures here [smiles]").photoCaption)
        XCTAssertNil(clean("*smiles* I took photos all day").photoCaption)
        XCTAssertNil(clean("[photo: ]").photoCaption)
    }

    func testCollapsesBlankLinesAndDropsDanglingSentence() {
        XCTAssertEqual(clean("One.\n\n\n\nTwo.").text, "One.\n\nTwo.")
        XCTAssertEqual(clean("One.  \n \n \n Two.").text, "One.\n\n Two.")
        XCTAssertEqual(clean("I baked bread today. Then I went to the", cut: true).text, "I baked bread today.")
        XCTAssertEqual(clean("I baked bread today. Then I went to the", cut: false).text, "I baked bread today. Then I went to the")
        XCTAssertEqual(clean("She said \"wow!\" and then", cut: true).text, "She said \"wow!\"")
        XCTAssertEqual(clean("well I was thinking that", cut: true).text, "well I was thinking that")
        XCTAssertEqual(clean("*smiles* See you soon.", cut: true).text, "*smiles* See you soon.")
        XCTAssertEqual(clean("Okay! *pours tea*", cut: true).text, "Okay! *pours tea*")
    }

    func testAwayEventsParsing() {
        let text = """
        Here's the news:
        - Juno baked a loaf shaped like a lighthouse for Theo.
        - **Mabel** found a glass float at the harbor.
        * Theo and Juno argued kindly about tide tables at Tide Library.
        - none
        - Juno and Mabel shared tea by the water.
        """
        let now = Fixture.date(hour: 10)
        let events = ReplyParser.awayEvents(from: text, world: Fixture.world, now: now)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.map(\.text), [
            "Juno baked a loaf shaped like a lighthouse for Theo.",
            "Mabel found a glass float at the harbor.",
            "Theo and Juno argued kindly about tide tables at Tide Library.",
        ])
        XCTAssertEqual(events[0].characterIDs, ["juno", "theo"])
        XCTAssertEqual(events[1].characterIDs, ["mabel"])
        XCTAssertEqual(events[1].locationID, "harbor")
        XCTAssertEqual(events[2].characterIDs, ["theo", "juno"])
        XCTAssertEqual(events[2].locationID, "library")
        XCTAssertNil(events[0].locationID)
        XCTAssertEqual(events[0].date, now)
        XCTAssertGreaterThan(events[0].date, events[1].date)
        XCTAssertTrue(ReplyParser.awayEvents(from: "- none\n- ok", world: Fixture.world, now: now).isEmpty)
    }

    func testSummaryFactsParsing() {
        XCTAssertEqual(ReplyParser.facts(from: "- loves sea glass.\n- Has a sister named Priya\n1. Works nights at the hospital\n- Extra fact"),
                       ["Loves sea glass", "Has a sister named Priya", "Works nights at the hospital"])
        XCTAssertEqual(ReplyParser.facts(from: "- none"), [])
        XCTAssertEqual(ReplyParser.facts(from: "- None."), [])
        XCTAssertEqual(ReplyParser.facts(from: "Nothing new here."), [])
    }
}

final class BrainSafetyTests: XCTestCase {
    func testSafetyCases() {
        let cases: [(String, SafetyLevel)] = [
            // Crisis
            ("I want to kill myself", .crisis),
            ("i wanna die", .crisis),
            ("I've been thinking about ending my life", .crisis),
            ("I feel suicidal tonight", .crisis),
            ("thinking about suicide again", .crisis),
            ("I don't want to be alive anymore", .crisis),
            ("i dont want to live anymore", .crisis),
            ("I really don\u{2019}t want to be here anymore", .crisis),
            ("I keep wanting to hurt myself", .crisis),
            ("I cut myself last night", .crisis),
            ("I've been self-harming again", .crisis),
            ("I'm going to take an overdose", .crisis),
            ("there's no reason to live", .crisis),
            ("everyone would be better off without me", .crisis),
            ("they'd be better off if I was gone", .crisis),
            ("I can't go on like this", .crisis),
            ("kms", .crisis),
            ("lowkey want to unalive myself", .crisis),
            ("thinking about sewer slide", .crisis),
            ("I want to kil myself", .crisis),
            ("sucide feels like the only way out", .crisis),
            ("I'm not okay, I want to die", .crisis),
            ("I wish I was never born", .crisis),
            ("I WANT TO END IT ALL", .crisis),
            ("I\u{2019}m suicidal", .crisis),
            ("I can't stop thinking about killing myself", .crisis),
            ("life isn't worth living", .crisis),
            ("nobody would care if I died", .crisis),
            ("honestly what's the point of living", .crisis),
            ("I don't see the point in living", .crisis),
            ("I don't think I want to live", .crisis),
            ("some nights I hope I don't wake up", .crisis),
            ("I'm planning to unalive", .crisis),
            ("I want to take my own life", .crisis),
            ("I wish I wasn't alive", .crisis),
            ("I no longer want to be here", .crisis),
            ("it's not worth living", .crisis),
            ("I just want to sleep forever", .crisis),
            ("I want to hang myself", .crisis),
            ("I thought about how to slit my wrists", .crisis),
            ("thinking about jumping off the bridge", .crisis),
            ("I want to end my life.", .crisis),
            // Common ways of saying it that used to slip through.
            ("I want to end it", .crisis),
            ("i keep thinking about ending it", .crisis),
            ("I'm going to end it tonight", .crisis),
            ("I took all my pills", .crisis),
            ("I took a bunch of pills", .crisis),
            ("I've got the pills ready", .crisis),
            ("I stockpiled my meds", .crisis),
            ("how many tylenol is a lethal dose", .crisis),
            ("how many sleeping pills would it take to not wake up", .crisis),
            ("I cut myself on purpose", .crisis),
            ("I hurt myself on purpose", .crisis),
            ("I've been cutting myself on my arms", .crisis),
            ("I've been cutting myself again", .crisis),
            ("I burned myself with a lighter", .crisis),
            ("It wasn't an accident, I cut myself", .crisis),
            ("I've been starving myself", .crisis),
            ("I'm not sure I want to live anymore", .crisis),
            ("I'd rather be dead", .crisis),
            ("I want to be dead", .crisis),
            ("I should just die", .crisis),
            ("I've been thinking of ways to die", .crisis),
            ("I want to stop existing", .crisis),
            ("I want to go to sleep and not wake up", .crisis),
            ("I don't want to wake up tomorrow", .crisis),
            ("I won't be a burden much longer", .crisis),
            ("Everyone would be happier if I was dead", .crisis),
            ("Life is not worth living anymore", .crisis),
            ("tired of living", .crisis),
            ("I'm done with life", .crisis),
            // Typed without a comma, "not okay" or "don't care" doesn't soften what follows.
            ("I'm not okay I want to die", .crisis),
            ("i dont care anymore i just want to die", .crisis),
            ("I don't know if I want to die", .crisis),
            // Being in danger from someone.
            ("my husband hits me", .crisis),
            ("he hits me when he drinks", .crisis),
            ("she's been hitting me", .crisis),
            ("I'm not safe at home", .crisis),
            ("I'm in danger", .crisis),
            ("he threatened to kill me", .crisis),
            ("I'm scared he will kill me", .crisis),
            // Concern: negated, past, or the topic
            ("I would never kill myself", .concern),
            ("I don't want to die", .concern),
            ("I'm not going to hurt myself, I promise", .concern),
            ("I used to cut myself in high school", .concern),
            ("my school had a suicide prevention talk", .concern),
            ("nobody would miss me", .concern),
            ("I want to disappear for good", .concern),
            ("I wish I could disappear", .concern),
            ("I'm not suicidal", .concern),
            ("No way I'd ever hurt myself", .concern),
            ("I stopped cutting myself months ago", .concern),
            ("I can't take it anymore", .concern),
            ("I feel like a burden", .concern),
            ("I'm in an abusive relationship", .concern),
            ("I'm writing a paper on suicide prevention", .concern),
            ("I volunteer at a suicide hotline", .concern),
            // Someone else's struggle, or grief: support shows softly.
            ("my best friend overdosed in 2019, I still miss her", .concern),
            ("my uncle died by suicide", .concern),
            ("my friend took her own life last year", .concern),
            ("my brother is suicidal and I don't know how to help", .concern),
            // Not a safety issue
            ("this joke is killing me", .none),
            ("I'm dying to see it", .none),
            ("you killed it today", .none),
            ("I'm dead tired", .none),
            ("can you kill the lights", .none),
            ("watching suicide squad tonight", .none),
            ("I ran 5 kms this morning", .none),
            ("I cut myself shaving", .none),
            ("I can't go on the trip this weekend", .none),
            ("I almost died laughing", .none),
            ("I wanted to die of embarrassment", .none),
            ("my feet are killing me", .none),
            ("I accidentally hurt myself at the gym", .none),
            ("I was killing myself laughing", .none),
            ("", .none),
            ("Good morning! The bread smells amazing.", .none),
            ("I feel so alone lately", .none),
            ("I never wake up on time", .none),
            ("I don't want to live in Ohio", .none),
            // Titles, idioms and everyday mishaps.
            ("The Virgin Suicides is my favorite book", .none),
            ("I cut myself some slack today", .none),
            ("that's the hill I want to die on", .none),
            ("I'm shooting myself in the foot here", .none),
            ("I burned myself on the stove", .none),
            ("I cut myself with a knife while cooking", .none),
            ("I hurt myself laughing so hard", .none),
            ("I overdosed on coffee today", .none),
            ("I want to end it with him", .none),
            ("I don't want to wake up early tomorrow", .none),
            ("I'm tired of living in this apartment", .none),
            ("I'm in danger of failing chemistry", .none),
            ("beats me", .none),
            ("it really hits me how much I miss her", .none),
            ("my back is hurting me", .none),
            ("my brother beats me at chess every time", .none),
            ("he hits me up every day", .none),
            ("I took all my vitamins", .none),
        ]
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for (text, expected) in cases {
            XCTAssertEqual(SafetyGuard.assess(text), expected, "\"\(text)\"")
        }
    }

    func testResources() {
        XCTAssertEqual(SafetyGuard.resources.map(\.url.absoluteString),
                       ["tel:988", "sms:988", "sms:741741&body=HOME", "tel:18007997233", "https://findahelpline.com"])
        for resource in SafetyGuard.resources {
            XCTAssertFalse((resource.title + resource.detail + resource.actionTitle).contains("\u{2014}"), "no em dashes in user copy")
        }
        XCTAssertEqual(Set(SafetyGuard.resources.map(\.id)).count, SafetyGuard.resources.count)
        XCTAssertTrue(SafetyGuard.gentleMessage.contains("988"))
        XCTAssertFalse(SafetyGuard.gentleMessage.contains("\u{2014}"), "no em dashes in user copy")
    }
}

final class SafetyGuardParityTests: XCTestCase {
    /// The same phrases as docs/app/js/brain/safety.test.mjs, so the app and the website flag the same things.
    func testPhrasesMatchTheWebsite() {
        let crisis = ["I've got the pills ready", "I stockpiled my meds", "how many tylenol is a lethal dose",
                      "I'm not sure I want to live anymore", "thinking about jumping off the bridge", "I don't feel safe at home",
                      "I do not want to be alive", "my boyfriend beat me up", "I can't stop cutting", "I deserve to die",
                      "I've been cutting again", "I think about ending it every day", "I should just end it",
                      "I'm worthless and should die", "I wish I'd never been born"]
        let concern = ["I'm a burden to everyone", "I can't take it anymore", "I want to disappear forever"]
        let none = ["beats me", "I can't go on the trip this weekend", "that hill I want to die on",
                    "I do not want to wake up early tomorrow", "my sister beats me at chess", "he hits me up on Saturdays",
                    "My hair needs cutting again", "I'm going to end it on a high note"]
        for p in crisis { XCTAssertEqual(SafetyGuard.assess(p), .crisis, p) }
        for p in concern { XCTAssertEqual(SafetyGuard.assess(p), .concern, p) }
        for p in none { XCTAssertEqual(SafetyGuard.assess(p), .none, p) }
    }
}

final class BrainMemoryTests: XCTestCase {
    func testThirdPersonCrisisFactsAreNotKept() {
        XCTAssertTrue(MemoryKeeper.isSensitiveFact("Wants to die"))
        XCTAssertTrue(MemoryKeeper.isSensitiveFact("They want to kill themselves"))
        for fact in ["Doesn't want to live anymore", "Hurts themselves when stressed", "Is in danger at home",
                     "Their partner hits them", "Has been cutting again"] {
            XCTAssertTrue(MemoryKeeper.isSensitiveFact(fact), fact)
        }
        for fact in ["Their mom died last year", "Hits the gym every morning", "Cuts hair for a living", "Is in a band"] {
            XCTAssertFalse(MemoryKeeper.isSensitiveFact(fact), fact)
        }
        XCTAssertFalse(MemoryKeeper.isSensitiveFact("Lives in Pittsburgh"))
        let kept = MemoryKeeper.merge(["Wants to die", "Loves foggy mornings"], into: [], characterID: "juno", source: .summary, shareable: true)
        XCTAssertEqual(kept.map(\.text), ["Loves foggy mornings"])
    }

    func testPatternFacts() {
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "My name is Sam and I live in Pittsburgh.", userName: "Sam"),
                       ["Lives in Pittsburgh"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "Call me Rosie! I work as a nurse at Mercy.", userName: "Sam"),
                       ["Goes by Rosie", "Works as a nurse at Mercy"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I love baking bread and I like old movies too.", userName: "Sam"),
                       ["Loves baking bread", "Likes old movies"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "My dog Biscuit snores.", userName: "Sam"), ["Has a dog named Biscuit"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "my sister\u{2019}s name is Priya", userName: "Sam"), ["Has a sister named Priya"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "My mom is called Rita.", userName: "Sam"), ["Their mom is named Rita"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I have a cat named Miso.", userName: "Sam"), ["Has a cat named Miso"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I have two cats", userName: "Sam"), ["Has two cats"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I'm from Ohio, but I live in St. Louis now", userName: "Sam"),
                       ["Is from Ohio", "Lives in St. Louis now"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I really love my best friend Lee", userName: "Sam"),
                       ["Has a best friend named Lee", "Loves their best friend Lee"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "my name is sam", userName: "Alex"), ["Goes by Sam"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I\u{2019}m living in Leeds these days", userName: "Sam"), ["Lives in Leeds these days"])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I like to paint on Sundays", userName: "Sam"), ["Likes to paint on Sundays"])
    }

    func testPatternFactsIgnoreChatter() {
        for text in ["I love you", "I like it here", "Do I like hiking?", "call me later", "I like that you remember",
                     "my dog is sick", "I'd like a coffee", "I don't like rain", "I love how you talk",
                     "I live in a tiny apartment above the old bakery on the corner of Main"] {
            XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: text, userName: "Sam"), [], text)
        }
    }

    func testNothingIsLearnedOrSharedFromWorryingMessages() {
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "My dog Biscuit died and I want to die too", userName: "Sam"), [])
        XCTAssertEqual(MemoryKeeper.extractFacts(fromUserText: "I live in Leeds and I'm not safe at home", userName: "Sam"), [])

        let merged = MemoryKeeper.merge(["Has thoughts of suicide", "Loves sea glass"], into: [], characterID: "juno",
                                        source: .summary, shareable: true)
        XCTAssertEqual(merged.map(\.text), ["Loves sea glass"], "a worrying summary fact is dropped")
        XCTAssertEqual(merged.first?.shareable, true)

        let pinned = MemoryKeeper.merge(["Sam said: I've been self-harming again"], into: [], characterID: "juno",
                                        source: .pinned, shareable: true)
        XCTAssertEqual(pinned.count, 1, "what someone pins themselves is kept")
        XCTAssertEqual(pinned.first?.shareable, false, "but never shared through town gossip")
    }

    func testDuplicates() {
        XCTAssertTrue(MemoryKeeper.isDuplicate("Has a dog named Biscuit", "has a dog named biscuit."))
        XCTAssertTrue(MemoryKeeper.isDuplicate("Has a dog named Biscuit", "Has a dog called Biscuit"))
        XCTAssertFalse(MemoryKeeper.isDuplicate("Loves hiking", "Loves cooking"))
        XCTAssertFalse(MemoryKeeper.isDuplicate("Has a dog", "Has a dog named Biscuit"))
        XCTAssertFalse(MemoryKeeper.isDuplicate("", "Loves tea"))
    }

    func testMergeDedupesPerCharacterAndUpgradesPins() {
        let existing = [MemoryFact(characterID: "juno", text: "Has a dog named Biscuit", source: .auto),
                        MemoryFact(characterID: nil, text: "Goes by Sam", source: .pinned),
                        MemoryFact(characterID: "theo", text: "Loves tea", source: .auto)]
        let merged = MemoryKeeper.merge(["has a dog named biscuit", "Has a dog called Biscuit", "goes by sam", "Loves tea", "  "],
                                        into: existing, characterID: "juno", source: .auto, shareable: true)
        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged.last?.text, "Loves tea")
        XCTAssertEqual(merged.last?.characterID, "juno")
        XCTAssertEqual(merged.last?.shareable, true)
        XCTAssertEqual(merged.last?.source, .auto)

        let pinned = MemoryKeeper.merge(["Has a dog named Biscuit"], into: existing, characterID: "juno", source: .pinned, shareable: false)
        XCTAssertEqual(pinned.count, 3)
        XCTAssertEqual(pinned[0].source, .pinned)
    }

    func testMergeCapsAtFortyDroppingOldestUnpinned() {
        let base = Fixture.date(hour: 8)
        var facts = [MemoryFact(characterID: "juno", text: "Pinned long ago", createdAt: base.addingTimeInterval(-1000), source: .pinned)]
        facts += (0..<40).map { MemoryFact(characterID: "juno", text: "Item \($0) of \($0 * 7)", createdAt: base.addingTimeInterval(Double($0)), source: .auto) }
        facts.append(MemoryFact(characterID: "theo", text: "Theo fact", source: .auto))
        let merged = MemoryKeeper.merge(["Brand new thought"], into: facts, characterID: "juno", source: .summary, shareable: false)
        let juno = merged.filter { $0.characterID == "juno" }
        XCTAssertEqual(juno.count, MemoryKeeper.maxFactsPerCharacter)
        XCTAssertTrue(juno.contains { $0.text == "Pinned long ago" })
        XCTAssertTrue(juno.contains { $0.text == "Brand new thought" })
        XCTAssertFalse(juno.contains { $0.text == "Item 0 of 0" })
        XCTAssertFalse(juno.contains { $0.text == "Item 1 of 7" })
        XCTAssertTrue(merged.contains { $0.text == "Theo fact" })
        XCTAssertEqual(MemoryKeeper.summarizeEvery, 12)
    }
}

final class BrainDirectorTests: XCTestCase {
    private let director = WorldDirector(world: Fixture.world)
    private let cast = [Fixture.juno, Fixture.theo, Fixture.mabel]

    func testWhoIsWhere() {
        let expected: [(Int, DayPart)] = [(5, .morning), (10, .morning), (11, .afternoon), (16, .afternoon),
                                          (17, .evening), (21, .evening), (22, .night), (4, .night)]
        for (hour, part) in expected { XCTAssertEqual(director.part(at: Fixture.date(hour: hour)), part, "hour \(hour)") }

        XCTAssertEqual(director.location(of: Fixture.juno, at: Fixture.date(hour: 9))?.id, "bakery")
        XCTAssertEqual(director.activity(of: Fixture.juno, at: Fixture.date(hour: 9)), "kneading dough")
        XCTAssertEqual(director.location(of: Fixture.juno, at: Fixture.date(hour: 14))?.id, "harbor")
        XCTAssertEqual(director.location(of: Fixture.juno, at: Fixture.date(hour: 23))?.id, "bakery", "no night slot falls back to home")
        XCTAssertEqual(director.activity(of: Fixture.juno, at: Fixture.date(hour: 23)), "spending time here")
        XCTAssertNil(director.location(of: Fixture.pip, at: Fixture.date(hour: 9)))
        XCTAssertEqual(director.activity(of: Fixture.pip, at: Fixture.date(hour: 9)), "going about their day")

        XCTAssertEqual(director.residents(at: "harbor", on: Fixture.date(hour: 14)).map(\.id), ["juno", "theo", "mabel"])
        XCTAssertEqual(director.residents(at: "bakery", on: Fixture.date(hour: 9)).map(\.id), ["juno"])
        XCTAssertEqual(director.residents(at: "library", on: Fixture.date(hour: 9)).map(\.id), ["theo"])
    }

    func testNamedCharactersSpeakFirstInMentionOrder() {
        for seed in 0..<50 as Range<UInt64> {
            var rng = SeededRNG(seed: seed)
            let both = director.nextSpeakers(afterUserText: "Hey Theo, and Juno too!", present: cast, transcript: [], using: &rng)
            XCTAssertEqual(both.map(\.id), ["theo", "juno"])
            let one = director.nextSpeakers(afterUserText: "mabel, how are the nets?", present: cast, transcript: [], using: &rng)
            XCTAssertEqual(one.first?.id, "mabel")
            XCTAssertLessThanOrEqual(one.count, 2)
            XCTAssertEqual(Set(one.map(\.id)).count, one.count)
        }
    }

    func testPrefersWhoTheUserLastAddressedThenLeastRecent() {
        var rng = SeededRNG(seed: 7)
        let talk = [Fixture.user("Juno, how's the bread?"), Fixture.said(Fixture.juno, "Rising nicely!")]
        XCTAssertEqual(director.nextSpeakers(afterUserText: "That sounds lovely", present: cast, transcript: talk, using: &rng).first?.id, "juno")
        let withCurrent = talk + [Fixture.user("That sounds lovely")]
        XCTAssertEqual(director.nextSpeakers(afterUserText: "That sounds lovely", present: cast, transcript: withCurrent, using: &rng).first?.id, "juno")

        let spoken = [Fixture.user("hi all"), Fixture.said(Fixture.juno, "hi"), Fixture.said(Fixture.theo, "hello")]
        for seed in 0..<30 as Range<UInt64> {
            var r = SeededRNG(seed: seed)
            XCTAssertEqual(director.nextSpeakers(afterUserText: "nice day", present: cast, transcript: spoken, using: &r).first?.id, "mabel")
        }
        let everyone = spoken + [Fixture.said(Fixture.mabel, "lovely")]
        XCTAssertEqual(director.nextSpeakers(afterUserText: "nice day", present: cast, transcript: everyone, using: &rng).first?.id, "juno")
        XCTAssertTrue(director.nextSpeakers(afterUserText: "hi", present: [], transcript: [], using: &rng).isEmpty)
        XCTAssertEqual(director.nextSpeakers(afterUserText: "hi", present: [Fixture.juno], transcript: [], using: &rng).map(\.id), ["juno"])
    }

    func testSpeakersAreDeterministicAndSometimesTwo() {
        var counts: [Int: Int] = [:]
        for seed in 0..<200 as Range<UInt64> {
            var a = SeededRNG(seed: seed), b = SeededRNG(seed: seed)
            let first = director.nextSpeakers(afterUserText: "What a morning", present: cast, transcript: [], using: &a)
            let again = director.nextSpeakers(afterUserText: "What a morning", present: cast, transcript: [], using: &b)
            XCTAssertEqual(first.map(\.id), again.map(\.id))
            XCTAssertEqual(Set(first.map(\.id)).count, first.count)
            counts[first.count, default: 0] += 1
        }
        XCTAssertEqual(Set(counts.keys), [1, 2])
        XCTAssertGreaterThan(counts[1] ?? 0, 50)
        XCTAssertGreaterThan(counts[2] ?? 0, 50)
    }

    func testBanterNeverRepeatsASpeakerBackToBack() {
        for seed in 0..<200 as Range<UInt64> {
            var rng = SeededRNG(seed: seed)
            let present = Array(cast.prefix(2 + Int(seed % 2)))
            let last = seed % 3 == 0 ? nil : present[Int(seed) % present.count].id
            let order = director.banterOrder(present: present, count: 4, lastSpeakerID: last, using: &rng)
            XCTAssertEqual(order.count, 4)
            XCTAssertNotEqual(order.first?.id, last)
            for (a, b) in zip(order, order.dropFirst()) { XCTAssertNotEqual(a.id, b.id) }
            XCTAssertEqual(Set(order.map(\.id)).count, present.count, "everyone gets a turn")
        }
        var rng = SeededRNG(seed: 1)
        XCTAssertTrue(director.banterOrder(present: [Fixture.juno], count: 4, lastSpeakerID: "juno", using: &rng).isEmpty)
        XCTAssertEqual(director.banterOrder(present: [Fixture.juno], count: 4, lastSpeakerID: nil, using: &rng).map(\.id), ["juno"])
        XCTAssertTrue(director.banterOrder(present: cast, count: 0, lastSpeakerID: nil, using: &rng).isEmpty)
    }

    func testRelevantEvents() {
        let events = [Fixture.event("old juno", ["juno"], hoursAgo: 9), Fixture.event("theo news", ["theo"], hoursAgo: 1),
                      Fixture.event("mabel news", ["mabel"], hoursAgo: 0.1), Fixture.event("new juno", ["juno"], hoursAgo: 2)]
        XCTAssertEqual(director.relevantEvents(for: Fixture.juno, from: events, limit: 3).map(\.text), ["new juno", "old juno", "theo news"])
        XCTAssertEqual(director.relevantEvents(for: Fixture.juno, from: events, limit: 10).map(\.text), ["new juno", "old juno", "theo news", "mabel news"])
        XCTAssertTrue(director.relevantEvents(for: Fixture.juno, from: events, limit: 0).isEmpty)
        XCTAssertEqual(director.relevantEvents(forAll: [Fixture.mabel, Fixture.theo], from: events, limit: 2).map(\.text), ["mabel news", "theo news"])
    }

    func testUserAskedForPhoto() {
        for yes in ["Can you send me a picture of the harbor?", "send a pic!", "show me your bakery photo", "I'd love to see a photo of the sunset",
                    "pls send a selfie", "can I see a picture?", "got a pic of it?", "Take a picture of the boats for me",
                    "draw me a picture of the lighthouse", "Hi! Send a photo", "could you snap a photo of the sea"] {
            XCTAssertTrue(WorldDirector.userAskedForPhoto(yes), yes)
        }
        for no in ["I sent you a photo", "here's a photo of my dog", "I took a picture yesterday", "don't send pictures please",
                   "I'll send you a pic later", "what a nice day", "picture this: a quiet beach", "no photos today, just chat"] {
            XCTAssertFalse(WorldDirector.userAskedForPhoto(no), no)
        }
    }

    func testRollAndSeededRNG() {
        var rng = SeededRNG(seed: 42)
        XCTAssertFalse((0..<100).contains { _ in WorldDirector.roll(0, using: &rng) })
        XCTAssertTrue((0..<100).allSatisfy { _ in WorldDirector.roll(1, using: &rng) })
        let hits = (0..<1000).filter { _ in WorldDirector.roll(0.5, using: &rng) }.count
        XCTAssertTrue((400...600).contains(hits), "\(hits)")

        var zero = SeededRNG(seed: 0)
        XCTAssertEqual(zero.next(), 0xE220_A839_7B1D_CDAF, "SplitMix64 reference value")
        var a = SeededRNG(seed: 9), b = SeededRNG(seed: 9), c = SeededRNG(seed: 10)
        let seqA = (0..<5).map { _ in a.next() }
        XCTAssertEqual(seqA, (0..<5).map { _ in b.next() })
        XCTAssertNotEqual(seqA, (0..<5).map { _ in c.next() })
    }
}

final class BrainContentTests: XCTestCase {
    /// Decodes the real cast (written by the content builder) and renders every prompt with it.
    func testLanternBayDecodesAndRendersPrompts() throws {
        let url = URL(fileURLWithPath: "/Users/aarushkandukoori/random/hearth/content/lantern-bay.json")
        guard let data = try? Data(contentsOf: url), data.count > 100 else {
            throw XCTSkip("content/lantern-bay.json is not there yet")
        }
        let world = try JSONDecoder().decode(WorldDefinition.self, from: data)
        XCTAssertFalse(world.characters.isEmpty)
        XCTAssertFalse(world.locations.isEmpty)
        let locationIDs = Set(world.locations.map(\.id))
        let placeholder = try XCTUnwrap(BrainText.regex(#"\{[A-Za-z]+\}|\{\{"#))
        let persona = UserPersona(name: "Sam", about: "Works nights and likes quiet mornings.")
        let now = Fixture.date(hour: 9)

        for ch in world.characters {
            for slot in ch.schedule { XCTAssertTrue(locationIDs.contains(slot.locationID), "\(ch.id) schedule -> \(slot.locationID)") }
            if let home = ch.homeLocationID { XCTAssertTrue(locationIDs.contains(home), "\(ch.id) home -> \(home)") }
            let ctx = DirectContext(character: ch, world: world, persona: persona, facts: [], events: [], history: [Message(role: .user, text: "hi")],
                                    now: now, conversationKey: "check")
            let request = PromptComposer.directRequest(ctx)
            for turn in request.turns { XCTAssertFalse(BrainText.matches(placeholder, turn.content), "\(ch.id): \(turn.content.prefix(80))") }
            XCTAssertLessThan(PromptComposer.estimateTokens(request.turns), 2600, "\(ch.id) system prompt fits the budget")
        }
        for loc in world.locations {
            let present = WorldDirector(world: world).residents(at: loc.id, on: now)
            guard let speaker = present.first else { continue }
            let ctx = SceneContext(location: loc, world: world, present: present, persona: persona, events: [],
                                   transcript: [Message(role: .user, text: "hello all")], now: now, conversationKey: "scene")
            let request = PromptComposer.sceneRequest(ctx, speaker: speaker)
            XCTAssertFalse(BrainText.matches(placeholder, request.turns[0].content), loc.id)
        }
        let away = PromptComposer.awayEventsRequest(world: world, count: 3, now: now)
        XCTAssertFalse(BrainText.matches(placeholder, away.turns[1].content))
    }

    /// Prints one rendered direct prompt and one scene prompt (for review; always passes).
    func testPrintSamplePrompts() {
        var direct = Fixture.direct([Fixture.said(Fixture.juno, "Morning, Sam! The first loaves just came out."),
                                     Fixture.user("Morning! Can you send me a picture of them?")],
                                    persona: UserPersona(name: "Sam", about: "Night-shift nurse who loves the sea."),
                                    facts: [MemoryFact(characterID: "juno", text: "Has a dog named Biscuit", source: .auto)],
                                    events: [Fixture.event("Theo found a rare shell at the harbor.", ["theo"], hoursAgo: 3)])
        direct.photoRequested = WorldDirector.userAskedForPhoto(direct.history.last?.text ?? "")
        print("=====DIRECT PROMPT=====")
        for turn in PromptComposer.directRequest(direct).turns { print("[\(turn.role.rawValue)]\n\(turn.content)\n") }
        let scene = SceneContext(location: Fixture.harbor, world: Fixture.world, present: [Fixture.juno, Fixture.theo],
                                 persona: UserPersona(name: "Sam"), events: [], transcript: [Fixture.user("Hi you two!"),
                                 Fixture.said(Fixture.juno, "Sam! Come sit, Theo is sketching gulls.")],
                                 now: Fixture.date(hour: 14), conversationKey: "scene-harbor")
        let request = PromptComposer.sceneRequest(scene, speaker: Fixture.theo)
        print("=====SCENE PROMPT=====")
        for turn in request.turns { print("[\(turn.role.rawValue)]\n\(turn.content)\n") }
        print("[assistantPrefix] \(request.assistantPrefix ?? "-")  [stop] \(request.stop.map { $0.replacingOccurrences(of: "\n", with: "\\n") })")
        print("=====END PROMPTS=====")
    }
}
