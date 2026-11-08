// Tests for the Theme: hex color parsing behind Color(hex:), its fallback for bad input,
// and the palette tokens switching between light and dark.

import SwiftUI
import XCTest
@testable import Hearth

final class ThemeTests: XCTestCase {
    // MARK: HexColor parsing

    func testSixDigitsWithOrWithoutHash() {
        assertHex("#FF8A4C", 0xFF, 0x8A, 0x4C)
        assertHex("ff8a4c", 0xFF, 0x8A, 0x4C)
        assertHex("  #141110\n", 0x14, 0x11, 0x10)
    }

    func testThreeDigitsRepeatEachDigit() {
        assertHex("#F80", 0xFF, 0x88, 0x00)
        assertHex("abc", 0xAA, 0xBB, 0xCC)
    }

    func testEightDigitsEndWithAlpha() {
        assertHex("#FF8A4C80", 0xFF, 0x8A, 0x4C, alpha: 0x80)
        assertHex("00000000", 0x00, 0x00, 0x00, alpha: 0x00)
    }

    func testFourDigitsAreShortRGBA() {
        assertHex("#F808", 0xFF, 0x88, 0x00, alpha: 0x88)
    }

    func testInvalidInputIsRejected() {
        let bad = ["", "#", "12", "#12345", "#1234567", "#123456789", "GGGGGG", "#12 456",
                   "+FF", "-12345", "0x123456", "##FFFFFF", "＃FFFFFF", "１２３", "red"]
        for input in bad {
            XCTAssertNil(HexColor(input), "\"\(input)\" should not parse")
        }
    }

    // MARK: Color(hex:)

    func testColorUsesParsedValues() {
        assertResolved(Color(hex: "#6FB7C9"), HexColor(red: 0x6F / 255, green: 0xB7 / 255, blue: 0xC9 / 255))
        assertResolved(Color(hex: "#FF8A4C80"), HexColor(red: 1, green: 0x8A / 255, blue: 0x4C / 255, alpha: 0x80 / 255))
    }

    func testColorFallsBackForInvalidInput() {
        assertResolved(Color(hex: "not a color"), HexColor.fallback)
        assertResolved(Color(hex: ""), HexColor.fallback)
    }

    // MARK: Palette tokens

    func testTokensFollowTheColorScheme() throws {
        try assertResolved(Color.hearthBackground, XCTUnwrap(HexColor("#141110")), scheme: .dark)
        try assertResolved(Color.hearthBackground, XCTUnwrap(HexColor("#FBF7F2")), scheme: .light)
        try assertResolved(Color.hearthAccent, XCTUnwrap(HexColor("#FF8A4C")), scheme: .dark)
        try assertResolved(Color.hearthAccent, XCTUnwrap(HexColor("#E8682E")), scheme: .light)
    }

    // MARK: Helpers

    private func assertHex(_ input: String, _ red: Int, _ green: Int, _ blue: Int, alpha: Int = 0xFF,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let color = HexColor(input) else {
            return XCTFail("\"\(input)\" did not parse", file: file, line: line)
        }
        XCTAssertEqual(color.red, Double(red) / 255, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color.green, Double(green) / 255, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color.blue, Double(blue) / 255, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(color.alpha, Double(alpha) / 255, accuracy: 0.0001, file: file, line: line)
    }

    private func assertResolved(_ color: Color, _ expected: HexColor, scheme: ColorScheme = .light,
                                file: StaticString = #filePath, line: UInt = #line) {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        let resolved = color.resolve(in: environment)
        XCTAssertEqual(Double(resolved.red), expected.red, accuracy: 0.003, file: file, line: line)
        XCTAssertEqual(Double(resolved.green), expected.green, accuracy: 0.003, file: file, line: line)
        XCTAssertEqual(Double(resolved.blue), expected.blue, accuracy: 0.003, file: file, line: line)
        XCTAssertEqual(Double(resolved.opacity), expected.alpha, accuracy: 0.003, file: file, line: line)
    }
}
