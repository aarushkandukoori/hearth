import XCTest
@testable import Hearth

final class SmokeTests: XCTestCase {
    func testDayPartBoundaries() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int) -> DayPart { DayPart.at(c.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h))!, calendar: c) }
        XCTAssertEqual(at(6), .morning); XCTAssertEqual(at(12), .afternoon); XCTAssertEqual(at(18), .evening); XCTAssertEqual(at(23), .night); XCTAssertEqual(at(3), .night)
    }

    /// Normal use keeps no log file (even counts and timings would be a diary of use); developer runs do.
    func testOnlyDeveloperRunsKeepALogFile() {
        XCTAssertFalse(LaunchOptions(arguments: ["Hearth"]).writesLogFile)
        XCTAssertFalse(LaunchOptions(arguments: ["Hearth", "-HearthSkipOnboarding", "1"]).writesLogFile)
        for flag in ["-HearthVerbose", "-HearthBenchmark", "-HearthUITour", "-HearthArtGen"] {
            XCTAssertTrue(LaunchOptions(arguments: ["Hearth", flag, "1"]).writesLogFile, flag)
        }
    }
}
