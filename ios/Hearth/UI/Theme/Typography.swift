// Type scale and layout constants. UI text uses SF Pro Rounded text styles, so it grows with the
// user's Dynamic Type setting (sizes below are the defaults); big titles use New York (serif).

import SwiftUI
import UIKit

enum HearthFont {
    /// New York semibold for screen and section titles. Fixed size: pick one per screen.
    static func title(_ size: CGFloat = 28) -> Font {
        // Grows with the person's text size (capped at twice the design size) so titles never end up
        // smaller than the body text around them.
        let scaled = UIFontMetrics(forTextStyle: .title1).scaledValue(for: size)
        return .system(size: min(scaled, size * 2), weight: .semibold, design: .serif)
    }

    /// Rounded semibold 17: names, buttons, row titles.
    static let headline: Font = .system(.headline, design: .rounded)
    /// Rounded 16: chat messages and paragraphs.
    static let body: Font = .system(.callout, design: .rounded)
    /// Rounded 15: taglines and secondary lines.
    static let callout: Font = .system(.subheadline, design: .rounded)
    /// Rounded 13: details like "by @creator" and times.
    static let caption: Font = .system(.footnote, design: .rounded)
    /// Rounded medium 12: badges and fine print.
    static let small: Font = .system(.caption, design: .rounded, weight: .medium)
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    static let card: CGFloat = 18
    static let bubble: CGFloat = 20
    static let chip: CGFloat = 14
    /// Corner radius for big rounded-square avatars; smaller avatars scale it down (see AvatarView).
    static let avatarSquare: CGFloat = 22
}
