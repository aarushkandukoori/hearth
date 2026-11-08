// Tests for the chat screen's pure helpers (UI/Chat/ChatPipeline.swift): live text while a reply
// streams, voice-note and swipe decisions, the caring line and support buttons, pinned-memory text, labels,
// live speech and *action* markup.

import SwiftUI
import XCTest
@testable import Hearth

final class ChatTests: XCTestCase {
    // MARK: Live text while streaming

    func testLiveTextDropsTheNameLabel() {
        XCTAssertEqual(ChatPipeline.liveText("Juno: Hi there", speakerName: "Juno", userName: "Sam"), "Hi there")
        XCTAssertEqual(ChatPipeline.liveText("**Juno:** Hi", speakerName: "Juno", userName: "Sam"), "Hi")
        XCTAssertEqual(ChatPipeline.liveText("  *waves* Hello!  ", speakerName: "Juno", userName: "Sam"), "*waves* Hello!")
    }

    func testLiveTextWaitsWhileTheLabelIsHalfWritten() {
        for partial in ["J", "Ju", "Juno", "juno", "**Jun"] {
            XCTAssertEqual(ChatPipeline.liveText(partial, speakerName: "Juno", userName: "Sam"), "", partial)
        }
        XCTAssertEqual(ChatPipeline.liveText("Just", speakerName: "Juno", userName: "Sam"), "Just")
    }

    func testLiveTextHidesAPhotoTagAsSoonAsItStarts() {
        XCTAssertEqual(ChatPipeline.liveText("Look at this!\n[photo: the har", speakerName: "Juno", userName: "Sam"),
                       "Look at this!")
        XCTAssertEqual(ChatPipeline.liveText("Here [", speakerName: "Juno", userName: "Sam"), "Here")
    }

    func testLiveTextStopsWhereTheModelWritesForTheUser() {
        XCTAssertEqual(ChatPipeline.liveText("Sure!\nSam: and then", speakerName: "Juno", userName: "Sam"), "Sure!")
        XCTAssertEqual(ChatPipeline.liveText("Okay.<|eot_id|>junk", speakerName: "Juno", userName: "Sam"), "Okay.")
    }

    // MARK: Voice notes

    func testShortRepliesWithWordsSuitVoiceNotes() {
        XCTAssertTrue(ChatPipeline.suitsVoiceNote("*smiles* That made my whole morning. Thank you."))
        XCTAssertFalse(ChatPipeline.suitsVoiceNote(String(repeating: "A long story about the harbor. ", count: 12)))
        XCTAssertFalse(ChatPipeline.suitsVoiceNote("*waves*"))
        XCTAssertFalse(ChatPipeline.suitsVoiceNote("😊"))
        XCTAssertFalse(ChatPipeline.suitsVoiceNote(""))
    }

    func testPlayableVoiceMatchesTheShownAlternate() {
        let onDisk: (String) -> Bool = { _ in true }
        let note = Attachment(kind: .voice, file: "voice/a.m4a", caption: "Hello there", duration: 2, status: .ready)
        var reply = Message(role: .character, speakerID: "juno", text: "Hello there", attachment: note)
        XCTAssertEqual(ChatPipeline.playableVoice(reply, fileExists: onDisk), note)

        reply.variants.append("A different answer")
        reply.selected = 1
        XCTAssertNil(ChatPipeline.playableVoice(reply, fileExists: onDisk), "another alternate shows as text")

        var pending = note
        pending.status = .pending
        XCTAssertNil(ChatPipeline.playableVoice(Message(role: .character, text: "Hello there", attachment: pending), fileExists: onDisk))
        var noFile = note
        noFile.file = nil
        XCTAssertNil(ChatPipeline.playableVoice(Message(role: .character, text: "Hello there", attachment: noFile), fileExists: onDisk))

        // The user's own recording plays even after its transcript was edited.
        let mine = Message(role: .user, text: "Edited words", attachment: note)
        XCTAssertEqual(ChatPipeline.playableVoice(mine, fileExists: onDisk), note)
        XCTAssertNil(ChatPipeline.playableVoice(Message(role: .user, text: "Just text"), fileExists: onDisk))
    }

    func testVoiceNotesWhoseFileIsMissingShowAsText() {
        // A backup restored on another iPhone brings the messages but not the recordings.
        let note = Attachment(kind: .voice, file: "voice/restored.m4a", caption: "Hello there", duration: 2, status: .ready)
        let reply = Message(role: .character, speakerID: "juno", text: "Hello there", attachment: note)
        XCTAssertNil(ChatPipeline.playableVoice(reply, fileExists: { _ in false }))
        XCTAssertNil(ChatPipeline.playableVoice(Message(role: .user, text: "Hi", attachment: note), fileExists: { _ in false }))
        XCTAssertNil(ChatPipeline.playableVoice(reply), "nothing is at that path in the test sandbox")
    }

    // MARK: Safety

    func testCaringLineNamesThePersonAndRealHelp() {
        let line = ChatPipeline.caringLine(userName: "Sam")
        XCTAssertTrue(line.contains("Sam"))
        XCTAssertTrue(line.contains("988"))
        XCTAssertTrue(line.contains("741741"))
        XCTAssertFalse(line.contains("\u{2014}")) // no em dashes in copy
    }

    func testSupportButtonsSayWhichLinesAreUSOnly() throws {
        let call = SafetyResource(id: "988-call", title: "988 Suicide & Crisis Lifeline", detail: "Call 988 any time (US).",
                                  actionTitle: "Call 988", url: try XCTUnwrap(URL(string: "tel:988")))
        let world = SafetyResource(id: "find-a-helpline", title: "Find a helpline", detail: "Helplines in other countries.",
                                   actionTitle: "Open findahelpline.com", url: try XCTUnwrap(URL(string: "https://findahelpline.com")))
        XCTAssertEqual(ChatSafetyCard.buttonTitle(for: call), "Call 988 (US)")
        XCTAssertEqual(ChatSafetyCard.buttonTitle(for: world), "Open findahelpline.com")
    }

    // MARK: Swipes and the last reply

    func testAlternateSteps() {
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 0, count: 3, delta: 1, canGenerate: true), .select(1))
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 2, count: 3, delta: -1, canGenerate: true), .select(1))
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 2, count: 3, delta: 1, canGenerate: true), .generate)
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 0, count: 1, delta: 1, canGenerate: true), .generate)
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 2, count: 3, delta: 1, canGenerate: false), .none, "greetings never get rewritten")
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 0, count: 3, delta: -1, canGenerate: true), .none)
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 1, count: 3, delta: 0, canGenerate: true), .none)
        XCTAssertEqual(ChatPipeline.alternateStep(selected: 0, count: 0, delta: 1, canGenerate: true), .none)
    }

    func testLastReplyIndexSkipsNotesAndStopsAtTheUser() {
        let greeting = Message(role: .character, speakerID: "juno", text: "Hi!")
        let user = Message(role: .user, text: "Hello")
        let reply = Message(role: .character, speakerID: "juno", text: "How are you?")
        let note = Message(role: .narrator, text: "A note")
        XCTAssertEqual(ChatPipeline.lastReplyIndex(in: [greeting]), 0)
        XCTAssertNil(ChatPipeline.lastReplyIndex(in: [greeting, user]))
        XCTAssertEqual(ChatPipeline.lastReplyIndex(in: [greeting, user, reply, note]), 2)
        XCTAssertNil(ChatPipeline.lastReplyIndex(in: [greeting, user, note]))
        XCTAssertNil(ChatPipeline.lastReplyIndex(in: []))
    }

    // MARK: Memory

    func testPinText() {
        XCTAssertEqual(ChatPipeline.pinText(for: Message(role: .user, text: "My interview is on Friday."), characterName: "Juno"),
                       "My interview is on Friday.")
        XCTAssertEqual(ChatPipeline.pinText(for: Message(role: .character, text: "I'll save you a cinnamon roll."), characterName: "Juno"),
                       "Juno said: I'll save you a cinnamon roll.")
        XCTAssertEqual(ChatPipeline.pinText(for: Message(role: .character, text: "*winks* See you Friday."), characterName: "Juno"),
                       "Juno said: winks See you Friday.", "memories never keep the asterisks")
        let photo = Message(role: .user, text: "", attachment: Attachment(kind: .photo, file: "photos/a.jpg", caption: "A dog on the grass."))
        XCTAssertEqual(ChatPipeline.pinText(for: photo, characterName: "Juno"), "Sent a photo: A dog on the grass.")
        XCTAssertEqual(ChatPipeline.pinText(for: Message(role: .user, text: "  "), characterName: "Juno"), "")

        let long = ChatPipeline.pinText(for: Message(role: .user, text: String(repeating: "word ", count: 80)), characterName: "Juno")
        XCTAssertLessThanOrEqual(long.count, 200)
        XCTAssertFalse(long.contains("\n"))
    }

    func testSummaryRunsOncePerTwelveUserMessages() {
        XCTAssertFalse(ChatPipeline.summaryDue(userMessages: 11, summarizedBlocks: 0))
        XCTAssertTrue(ChatPipeline.summaryDue(userMessages: 12, summarizedBlocks: 0))
        XCTAssertFalse(ChatPipeline.summaryDue(userMessages: 23, summarizedBlocks: 1))
        XCTAssertTrue(ChatPipeline.summaryDue(userMessages: 24, summarizedBlocks: 1))
    }

    // MARK: Labels

    func testStatsLine() {
        var stats = GenerationStats(engine: "llama-3.2-3b", promptTokens: 900, reusedTokens: 812, prefilledTokens: 88,
                                    generatedTokens: 40, timeToFirstToken: 0.42, decodeTokensPerSecond: 21.3,
                                    restoredFromDisk: true, restoreMilliseconds: 140.2)
        XCTAssertEqual(ChatPipeline.statsLine(stats),
                       "on-device · 21 tok/s · first token 420 ms · reused 812 · resumed from flash in 140 ms")
        stats.timeToFirstToken = 2.34
        XCTAssertTrue(ChatPipeline.statsLine(stats).contains("first token 2.3 s"))
        stats.stoppedBy = "cancelled"
        XCTAssertTrue(ChatPipeline.statsLine(stats).hasSuffix(" · stopped"))
        // Canned demo lines never claim a model wrote them on the device.
        XCTAssertEqual(ChatPipeline.statsLine(GenerationStats(engine: "mock")), "demo reply, no AI")
        XCTAssertEqual(ChatPipeline.statsLine(GenerationStats(engine: "apple")), "on-device")
    }

    func testTimeGroupsStartAfterALongPause() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(ChatPipeline.startsTimeGroup(previous: nil, current: start))
        XCTAssertFalse(ChatPipeline.startsTimeGroup(previous: start, current: start.addingTimeInterval(10 * 60)))
        XCTAssertTrue(ChatPipeline.startsTimeGroup(previous: start, current: start.addingTimeInterval(31 * 60)))
    }

    func testTimeLabelsNameTodayAndYesterday() throws {
        let calendar = Calendar(identifier: .gregorian)
        let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
        XCTAssertTrue(ChatPipeline.timeLabel(for: noon.addingTimeInterval(-2 * 3600), now: noon, calendar: calendar).hasPrefix("Today "))
        XCTAssertTrue(ChatPipeline.timeLabel(for: noon.addingTimeInterval(-24 * 3600), now: noon, calendar: calendar).hasPrefix("Yesterday "))
        let older = ChatPipeline.timeLabel(for: noon.addingTimeInterval(-20 * 24 * 3600), now: noon, calendar: calendar)
        XCTAssertFalse(older.hasPrefix("Today") || older.hasPrefix("Yesterday"))
    }

    func testByLine() {
        XCTAssertEqual(ChatPipeline.byLine("@lanternbay"), "by @lanternbay")
        XCTAssertEqual(ChatPipeline.byLine("kata"), "by @kata")
        XCTAssertEqual(ChatPipeline.byLine("  "), "A Hearth character")
    }

    func testDurationLabels() {
        XCTAssertEqual(ChatPipeline.durationLabel(0), "0:00")
        XCTAssertEqual(ChatPipeline.durationLabel(12.4), "0:12")
        XCTAssertEqual(ChatPipeline.durationLabel(59.6), "1:00")
        XCTAssertEqual(ChatPipeline.durationLabel(75), "1:15")
        XCTAssertEqual(ChatPipeline.durationLabel(-3), "0:00")
    }

    func testEngineStatesThatAcceptMessages() {
        XCTAssertTrue(ChatController.engineAccepts(.ready))
        XCTAssertTrue(ChatController.engineAccepts(.loading("Loading Hearth Standard")))
        XCTAssertTrue(ChatController.engineAccepts(.idle))
        XCTAssertFalse(ChatController.engineAccepts(.needsModel))
        XCTAssertFalse(ChatController.engineAccepts(.failed("No memory")))
    }

    // MARK: Live speech

    func testSpeechFeederReleasesFinishedSentencesOnly() {
        var feeder = ChatSpeechFeeder()
        XCTAssertEqual(feeder.feed("Hi there."), [], "no space yet, so it might still be 3.5")
        XCTAssertEqual(feeder.feed("Hi there. How"), ["Hi there."])
        XCTAssertEqual(feeder.feed("Hi there. How are you?"), [])
        XCTAssertEqual(feeder.finish(), "How are you?")
        XCTAssertEqual(feeder.finish(), "", "finish empties the buffer")
    }

    func testSpeechFeederIgnoresTextThatChangedEarlierOn() {
        var feeder = ChatSpeechFeeder()
        _ = feeder.feed("Hello friend. It")
        XCTAssertEqual(feeder.feed("Something else entirely. Yes"), [])
        XCTAssertEqual(feeder.feed("Hello friend. It is late. "), ["It is late."])
    }

    // MARK: Markup

    func testActionsBecomeItalicSegments() {
        XCTAssertEqual(ChatMarkup.segments("*waves* Hi"),
                       [.init(text: "waves", italic: true), .init(text: " Hi")])
        XCTAssertEqual(ChatMarkup.segments("**big** news"),
                       [.init(text: "big", bold: true), .init(text: " news")])
        XCTAssertEqual(ChatMarkup.segments("***wow***"),
                       [.init(text: "wow", italic: true, bold: true)])
    }

    func testLoneStarsStayStars() {
        XCTAssertEqual(ChatMarkup.segments("5 * 3 = 15"), [.init(text: "5 * 3 = 15")])
        XCTAssertEqual(ChatMarkup.segments("a * b *"), [.init(text: "a * b *")])
        XCTAssertEqual(ChatMarkup.segments(""), [])
    }

    func testAnUnclosedActionStaysItalicWhileStreaming() {
        XCTAssertEqual(ChatMarkup.segments("Okay *sips tea"),
                       [.init(text: "Okay "), .init(text: "sips tea", italic: true)])
    }

    func testPlainTextDropsTheStars() {
        XCTAssertEqual(ChatMarkup.plain("*waves* hi **there**"), "waves hi there")
    }

    func testAttributedTextUsesEmphasis() throws {
        let styled = ChatMarkup.attributed("*waves* hi", actionColor: .red)
        let runs = Array(styled.runs)
        XCTAssertEqual(runs.count, 2)
        let first = try XCTUnwrap(runs.first)
        XCTAssertEqual(first.inlinePresentationIntent, .emphasized)
        XCTAssertNotNil(first[AttributeScopes.SwiftUIAttributes.FontAttribute.self], "actions carry a real italic face")
        XCTAssertEqual(String(styled[first.range].characters), "waves")
        XCTAssertNil(runs[1].inlinePresentationIntent)
        XCTAssertNil(runs[1][AttributeScopes.SwiftUIAttributes.FontAttribute.self])
    }
}
