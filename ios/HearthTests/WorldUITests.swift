// Unit tests for the Town and scene screens' pure logic: when town news is due and where it comes from,
// scene guests and day-part boundaries, place phrasing, and the map's pin and avatar layout.

import XCTest
import SwiftUI
@testable import Hearth

private typealias Resident = Hearth.Character

private enum WorldFixture {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        return c
    }()

    /// Friday 2026-11-06 at `hour`:`minute`, New York time.
    static func date(day: Int = 6, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? Date()
    }

    static let cafe = Location(id: "cafe", name: "Driftwood Cafe", blurb: "", ambience: "", symbol: "cup.and.saucer.fill",
                               map: MapPoint(x: 0.4, y: 0.62), art: AvatarRef())
    static let lighthouse = Location(id: "lighthouse", name: "The Lighthouse", blurb: "", ambience: "",
                                     symbol: "light.beacon.max.fill", map: MapPoint(x: 0.86, y: 0.72), art: AvatarRef())

    static func resident(_ id: String, _ name: String) -> Resident {
        Resident(id: id, name: name, species: "otter", tagline: "Kind.", bio: "", greeting: "Hi.", personality: "",
                 speakingStyle: "", avatar: AvatarRef(), accentHex: "#FF8A4C", homeLocationID: "cafe")
    }

    static let world = WorldDefinition(id: "test", name: "Test Bay", tagline: "", lore: "", categories: [],
                                       locations: [cafe, lighthouse],
                                       characters: [resident("juno", "Juno"), resident("theo", "Theo")],
                                       starterEvents: [
                                           "Juno baked buns at Driftwood Cafe for everyone.",
                                           "Theo lit the lamp early at the Lighthouse tonight.",
                                           "Juno and Theo watched the boats come in together.",
                                           "Theo fixed the old foghorn with a borrowed wrench.",
                                       ])

    static func note(_ guestID: String?, at date: Date) -> Message {
        var m = Message(role: .narrator, speakerID: guestID, text: "Someone comes over to join you.")
        m.createdAt = date
        return m
    }
}

final class WorldNewsTests: XCTestCase {
    func testDueWhenThereWasNeverABatch() {
        XCTAssertTrue(WorldEventsController.isDue(lastBatchAt: nil, now: Date()))
    }

    func testDueAfterSixHoursNotBefore() {
        let now = WorldFixture.date(hour: 18)
        XCTAssertFalse(WorldEventsController.isDue(lastBatchAt: now.addingTimeInterval(-5 * 3600 - 3599), now: now))
        XCTAssertTrue(WorldEventsController.isDue(lastBatchAt: now.addingTimeInterval(-6 * 3600), now: now))
        XCTAssertTrue(WorldEventsController.isDue(lastBatchAt: now.addingTimeInterval(-30 * 3600), now: now))
    }

    func testDueWhenTheClockMovedBackwards() {
        let now = WorldFixture.date(hour: 9)
        XCTAssertTrue(WorldEventsController.isDue(lastBatchAt: now.addingTimeInterval(3600), now: now))
    }

    func testPlanAsksTheModelOnlyWhenItIsFree() {
        XCTAssertEqual(WorldEventsController.plan(engineState: .ready, isGenerating: false, engineID: "qwen3.5-2b"), .askModel)
        XCTAssertEqual(WorldEventsController.plan(engineState: .ready, isGenerating: false, engineID: "qwen3.5-0.8b"), .askModel)
        XCTAssertEqual(WorldEventsController.plan(engineState: .ready, isGenerating: true, engineID: "qwen3.5-2b"), .wait)
        XCTAssertEqual(WorldEventsController.plan(engineState: .loading("Loading"), isGenerating: false, engineID: nil), .wait)
        XCTAssertEqual(WorldEventsController.plan(engineState: .idle, isGenerating: false, engineID: nil), .wait)
    }

    func testPlanUsesTheTownNotebookWithoutAModel() {
        XCTAssertEqual(WorldEventsController.plan(engineState: .ready, isGenerating: false, engineID: "mock"), .useStarters)
        XCTAssertEqual(WorldEventsController.plan(engineState: .ready, isGenerating: true, engineID: "mock"), .useStarters)
        XCTAssertEqual(WorldEventsController.plan(engineState: .needsModel, isGenerating: false, engineID: nil), .useStarters)
        XCTAssertEqual(WorldEventsController.plan(engineState: .failed("x"), isGenerating: false, engineID: nil), .useStarters)
    }

    func testUnusedStartersSkipWhatTheFeedAlreadyShows() {
        let starters = WorldFixture.world.starterEvents
        let existing = [WorldEvent(text: "  juno BAKED buns at driftwood cafe   for everyone. ")]
        let picked = WorldEventsController.unusedStarters(starters, existing: existing, limit: 2)
        XCTAssertEqual(picked, [starters[1], starters[2]])
    }

    func testUnusedStartersRunOutQuietly() {
        let starters = WorldFixture.world.starterEvents
        let existing = starters.map { WorldEvent(text: $0) }
        XCTAssertEqual(WorldEventsController.unusedStarters(starters, existing: existing, limit: 3), [])
        XCTAssertEqual(WorldEventsController.unusedStarters(starters + [starters[0]], existing: [], limit: 9).count, 4)
    }

    func testStarterEventsNameResidentsAndPlaces() {
        let now = WorldFixture.date(hour: 12)
        let events = WorldEventsController.starterEvents(Array(WorldFixture.world.starterEvents.prefix(3)),
                                                         world: WorldFixture.world, now: now)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].characterIDs, ["juno"])
        XCTAssertEqual(events[0].locationID, "cafe")
        XCTAssertEqual(events[1].locationID, "lighthouse")
        XCTAssertEqual(events[2].characterIDs, ["juno", "theo"])
        XCTAssertEqual(events[0].date, now)
        XCTAssertTrue(events.allSatisfy { !$0.seen })
        XCTAssertEqual(WorldEventsController.starterEvents([], world: WorldFixture.world, now: now), [])
    }
}

final class WorldSceneTests: XCTestCase {
    func testPartStartForEachPartOfTheDay() {
        let c = WorldFixture.calendar
        XCTAssertEqual(SceneController.partStart(of: WorldFixture.date(hour: 8, minute: 30), calendar: c), WorldFixture.date(hour: 5))
        XCTAssertEqual(SceneController.partStart(of: WorldFixture.date(hour: 13), calendar: c), WorldFixture.date(hour: 11))
        XCTAssertEqual(SceneController.partStart(of: WorldFixture.date(hour: 17), calendar: c), WorldFixture.date(hour: 17))
        XCTAssertEqual(SceneController.partStart(of: WorldFixture.date(hour: 23, minute: 30), calendar: c), WorldFixture.date(hour: 22))
    }

    func testNightAfterMidnightStartedYesterday() {
        let c = WorldFixture.calendar
        XCTAssertEqual(SceneController.partStart(of: WorldFixture.date(day: 7, hour: 2), calendar: c),
                       WorldFixture.date(day: 6, hour: 22))
    }

    func testGuestsAreInviteNotesFromThisPartOfTheDay() {
        let start = WorldFixture.date(hour: 17)
        let messages = [
            WorldFixture.note("theo", at: WorldFixture.date(hour: 16)),       // invited last afternoon: gone home
            WorldFixture.note("juno", at: WorldFixture.date(hour: 17, minute: 5)),
            Message(role: .user, text: "hello"),
            WorldFixture.note(nil, at: WorldFixture.date(hour: 18)),          // a note about nobody
            WorldFixture.note("mika", at: WorldFixture.date(hour: 19)),
            WorldFixture.note("juno", at: WorldFixture.date(hour: 20)),       // invited twice, counted once
        ]
        XCTAssertEqual(SceneController.guestIDs(in: messages, since: start), ["juno", "mika"])
    }

    func testCaringLineNamesThePersonAndTheLifeline() {
        let line = SceneController.caringLine(userName: "Sam")
        XCTAssertTrue(line.contains("Sam"))
        XCTAssertTrue(line.contains("988"))
        XCTAssertTrue(line.contains("741741"))
        XCTAssertFalse(line.contains("\u{2014}")) // no em dashes in copy
    }
}

final class WorldTextTests: XCTestCase {
    func testPlacePhrasing() {
        XCTAssertEqual(TownText.at("The Lighthouse"), "At the Lighthouse")
        XCTAssertEqual(TownText.at("Driftwood Cafe"), "At Driftwood Cafe")
        XCTAssertEqual(TownText.inSentence("The Night Market"), "the Night Market")
        XCTAssertEqual(TownText.shortName("The Night Market"), "Market")
        XCTAssertEqual(TownText.shortName("Hilltop Observatory"), "Observatory")
        XCTAssertEqual(TownText.shortName("Lighthouse"), "Lighthouse")
    }

    func testArrivalNote() {
        let cafe = WorldFixture.cafe, lighthouse = WorldFixture.lighthouse
        XCTAssertEqual(TownText.arrival(of: "Theo", from: lighthouse, to: cafe), "Theo comes over from the Lighthouse to join you.")
        XCTAssertEqual(TownText.arrival(of: "Theo", from: nil, to: cafe), "Theo comes over to join you.")
        XCTAssertEqual(TownText.arrival(of: "Theo", from: cafe, to: cafe), "Theo comes over to join you.")
    }

    func testActionsBecomeItalicWithoutAsterisks() {
        let styled = TownText.styled("*waves* Hi there, *sits* ok")
        XCTAssertEqual(String(styled.characters), "waves Hi there, sits ok")
        let italic = styled.runs.filter { $0.inlinePresentationIntent == .emphasized }.map { String(styled[$0.range].characters) }
        XCTAssertEqual(italic, ["waves", "sits"])
        XCTAssertEqual(TownText.plain("5 * 3 is fifteen"), "5 * 3 is fifteen") // a lone asterisk stays
    }

    func testSampleDateStaysInsideTheAskedPart() {
        let c = WorldFixture.calendar
        let now = WorldFixture.date(hour: 19, minute: 42)
        XCTAssertEqual(TownText.sampleDate(for: .evening, near: now, calendar: c), now)
        for part in DayPart.allCases {
            XCTAssertEqual(DayPart.at(TownText.sampleDate(for: part, near: now, calendar: c), calendar: c), part)
        }
    }

    func testNowLine() {
        let line = TownText.nowLine(WorldFixture.date(hour: 19, minute: 42), calendar: WorldFixture.calendar)
        XCTAssertTrue(line.hasPrefix("Evening · "))
    }
}

final class WorldMapLayoutTests: XCTestCase {
    func testPlacesSitInsideTheInsetFrame() {
        let size = CGSize(width: 400, height: 500)
        let topLeft = TownMapArt.point(0, 0, in: size)
        let bottomRight = TownMapArt.point(1, 1, in: size)
        XCTAssertEqual(topLeft.x, 32, accuracy: 0.001)
        XCTAssertEqual(topLeft.y, 45, accuracy: 0.001)
        XCTAssertEqual(bottomRight.x, 368, accuracy: 0.001)
        XCTAssertEqual(bottomRight.y, 455, accuracy: 0.001)
    }

    func testAvatarSlotsAreCenteredUnderTheMarker() {
        let marker = CGPoint(x: 100, y: 100)
        XCTAssertTrue(TownMapLayout.avatarSlots(count: 0, marker: marker).isEmpty)
        let one = TownMapLayout.avatarSlots(count: 1, marker: marker)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].x, 100, accuracy: 0.001)
        XCTAssertGreaterThan(one[0].y, marker.y)
        let three = TownMapLayout.avatarSlots(count: 3, marker: marker)
        XCTAssertEqual((three[0].x + three[2].x) / 2, 100, accuracy: 0.001)
        XCTAssertEqual(three[1].x - three[0].x, TownMapLayout.avatarStep, accuracy: 0.001)
    }

    func testCrowdedPinsShowAPlusChip() {
        XCTAssertEqual(TownMapLayout.avatarSlots(count: 9, marker: .zero).count, TownMapLayout.maxSlots)
        XCTAssertEqual(TownMapLayout.visibleAvatars(count: 4), 4)
        XCTAssertEqual(TownMapLayout.visibleAvatars(count: 5), 3)
        XCTAssertEqual(TownMapLayout.visibleAvatars(count: 2), 2)
    }

    func testPinFrameKeepsTheMarkerOnThePlace() {
        let marker = CGPoint(x: 50, y: 80)
        let center = TownMapLayout.pinCenter(forMarker: marker)
        let markerTop = center.y - TownMapLayout.pinHeight / 2
        XCTAssertEqual(markerTop + TownMapLayout.markerSize / 2, marker.y, accuracy: 0.001)
        XCTAssertEqual(center.x, marker.x)
    }

    func testEveryPartHasAPalette() {
        XCTAssertFalse(TownMapPalette.forPart(.afternoon).lampsLit)
        XCTAssertTrue(TownMapPalette.forPart(.evening).lampsLit)
        XCTAssertTrue(TownMapPalette.forPart(.night).lampsLit)
        XCTAssertEqual(TownMapPalette.forPart(.night).glowOpacity, 1)
    }
}
