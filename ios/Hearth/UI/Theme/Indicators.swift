// Small status pieces: TypingIndicator, WaveformView (voice notes), StarRatingView (1-4 stars on a
// reply) and PrivacyBadge ("On-device").

import SwiftUI

/// Three softly bouncing dots while a character is writing. Holds still with Reduce Motion on.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    // Each dot rises in turn; a full cycle takes 1.2 s.
                    let wave = reduceMotion ? 0 : max(0, sin(time * 2 * .pi / 1.2 - Double(index) * 0.8))
                    Circle()
                        .fill(Color.hearthMuted)
                        .frame(width: 7, height: 7)
                        .opacity(0.45 + 0.55 * wave)
                        .offset(y: -3 * wave)
                }
            }
            .padding(.vertical, 6)
        }
        .accessibilityElement()
        .accessibilityLabel("Typing")
    }
}

/// Voice note bars. `samples` are 0...1 heights (32 is typical); bars before `progress` (0...1) use
/// the full tint. Give it a height with `.frame(height:)`; it picks 28 pt by default.
struct WaveformView: View {
    private let samples: [Float]
    private let progress: Double
    private let tint: Color

    init(samples: [Float], progress: Double, tint: Color) {
        self.samples = samples
        self.progress = progress
        self.tint = tint
    }

    var body: some View {
        Canvas { context, size in
            let bars = samples.isEmpty ? Array(repeating: Float(0.2), count: 32) : samples
            let count = CGFloat(bars.count)
            let gap = max(1, min(3, size.width / count * 0.35))
            let barWidth = max(1, (size.width - gap * (count - 1)) / count)
            for (index, sample) in bars.enumerated() {
                let height = max(3, CGFloat(min(max(sample, 0), 1)) * size.height)
                let rect = CGRect(x: CGFloat(index) * (barWidth + gap), y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                let played = (Double(index) + 0.5) / Double(bars.count) <= progress
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                             with: .color(played ? tint : tint.opacity(0.32)))
            }
        }
        .frame(minHeight: 12, idealHeight: 28, maxHeight: 36)
        .accessibilityHidden(true) // the play button around it carries the label
    }
}

/// Character.AI-style rating under a reply: tap 1-4 stars, tap the same star again to clear. Here the stars
/// are a private note for the person; nothing reads them to shape replies. Each star has a 44 pt tap area.
struct StarRatingView: View {
    @Binding private var rating: Int?

    init(rating: Binding<Int?>) {
        _rating = rating
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...4, id: \.self) { star in
                let filled = (rating ?? 0) >= star
                Button {
                    rating = rating == star ? nil : star
                } label: {
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(filled ? Color.hearthGold : Color.hearthMuted)
                        .symbolEffect(.bounce, value: filled)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rate this reply")
        .accessibilityValue(rating.map { "\($0) of 4 stars" } ?? "Not rated")
        .accessibilityHint("Just for you. Stars stay on this iPhone and don't change replies.")
        .accessibilityAdjustableAction { direction in
            let current = rating ?? 0
            switch direction {
            case .increment: rating = min(4, current + 1)
            case .decrement: rating = current > 1 ? current - 1 : nil
            @unknown default: break
            }
        }
    }
}

/// A calm reminder that something stays on this phone, e.g. "On-device" or "Works offline".
struct PrivacyBadge: View {
    private let text: String

    init(_ text: String = "On-device") {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .imageScale(.small)
            Text(text)
                .lineLimit(1)
        }
        .font(HearthFont.small.weight(.semibold))
        .foregroundStyle(.hearthSea)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.hearthSea.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
