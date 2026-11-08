// Small pieces shared by the You tab, its pages and onboarding: tinted row icons, row labels, tags,
// a download ring, list section headers, titles that grow with Dynamic Type, and sizes in plain words.

import SwiftUI

/// A small rounded-square icon like the ones in iOS Settings, tinted with a Hearth color.
struct SettingsIcon: View {
    let symbol: String
    var tint: Color = .hearthAccent
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: side * 0.47, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon, title and an optional detail line. Used as the label of rows, toggles and buttons.
struct SettingsRowLabel: View {
    let title: String
    var detail: String?
    let symbol: String
    var tint: Color = .hearthAccent
    var titleColor: Color = .hearthText

    var body: some View {
        HStack(spacing: Spacing.m) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(titleColor)
                if let detail {
                    Text(detail)
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthText2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A list row that opens something: icon, title, detail and a chevron.
struct SettingsLinkRow: View {
    let title: String
    var detail: String?
    let symbol: String
    var tint: Color = .hearthAccent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                SettingsRowLabel(title: title, detail: detail, symbol: symbol, tint: tint)
                Spacer(minLength: Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.hearthMuted)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
    }
}

/// A quiet list section header in Hearth's type (no all-caps).
struct SettingsSectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(HearthFont.caption.weight(.semibold))
            .foregroundStyle(.hearthText2)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A small label like "Recommended" or "In use": a colored dot and text on a soft tint
/// (the text stays in the main text color so it reads well in light mode too).
struct SettingsTag: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color = .hearthGold) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .lineLimit(1)
        }
        .font(HearthFont.small.weight(.semibold))
        .foregroundStyle(.hearthText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.16), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A ring that fills as a download moves along, with the percent inside.
struct SettingsDownloadRing: View {
    let fraction: Double
    var size: CGFloat = 36

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        ZStack {
            Circle()
                .stroke(Color.hearthLine, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.02, clamped))
                .stroke(Color.hearthAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(clamped * 100))")
                .font(.system(size: size * 0.3, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.hearthText)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: clamped)
        .accessibilityElement()
        .accessibilityLabel("Downloading")
        .accessibilityValue("\(Int(clamped * 100)) percent")
    }
}

/// HearthFont.title at a size that grows with Dynamic Type, capped so a big title never swamps the screen.
/// (HearthFont.title itself is a fixed size; without this, captions outgrow titles at large text sizes.)
struct SettingsScaledTitle: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let base: CGFloat
    private let cap: CGFloat

    init(_ base: CGFloat, cap: CGFloat = 2) {
        _size = ScaledMetric(wrappedValue: base, relativeTo: .title2)
        self.base = base
        self.cap = cap
    }

    func body(content: Content) -> some View {
        content.font(HearthFont.title(min(size, base * cap)))
    }
}

/// Sizes and counts in plain words.
enum SettingsFormat {
    /// "1.2 MB", "2.02 GB" (decimal units, like the Files app). Zero reads "0 bytes".
    static func bytes(_ count: Int64) -> String {
        count <= 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// A rounded size for model downloads: "2 GB", "2.5 GB", "0.8 GB".
    static func approximate(_ count: Int64) -> String {
        let gigabytes = Double(count) / 1_000_000_000
        var text = String(format: "%.1f", gigabytes)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return "\(text) GB"
    }

    /// "1 chat", "3 chats".
    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : (plural ?? singular + "s"))"
    }
}
