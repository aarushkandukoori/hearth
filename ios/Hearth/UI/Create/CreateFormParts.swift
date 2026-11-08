// Building blocks for the Create form: labeled text boxes with counters, sections, a disclosure row,
// a wrapping layout for chips, a slider that says its value in words, and a tappable option row.

import SwiftUI

/// The text fields in Create, for keyboard focus and for scrolling to a missing field.
enum CreateFocus: Hashable {
    case name, species, tagline, bio, greeting, personality, style, example, scenario
}

/// A titled text box in Character.AI's style: title, hint, the field, a counter and a gentle error.
struct CreateTextField: View {
    let title: String
    var hint: String?
    let placeholder: String
    @Binding var text: String
    var limit: Int?
    /// Stop typing at `limit` (name, tagline). Otherwise going over only shows a note.
    var hardLimit = false
    var multiline = false
    var required = false
    var error: String?
    let focus: FocusState<CreateFocus?>.Binding
    let field: CreateFocus
    var onSubmit: () -> Void = {}

    var body: some View {
        let isFocused = focus.wrappedValue == field
        let count = text.count
        let isOver = limit.map { count > $0 } ?? false
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)

        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                if required {
                    Text("Required")
                        .font(HearthFont.small)
                        .foregroundStyle(.hearthMuted)
                }
                Spacer(minLength: Spacing.s)
                if let limit {
                    Text("\(count)/\(limit)")
                        .font(HearthFont.small.monospacedDigit())
                        .foregroundStyle(isOver ? Color.hearthDanger : Color.hearthMuted)
                        .accessibilityLabel("\(count) of \(limit) characters")
                }
            }
            if let hint {
                Text(hint)
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(title, text: $text, prompt: Text(placeholder).foregroundStyle(Color.hearthMuted),
                      axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 3...12 : 1...1)
                .font(HearthFont.body)
                .foregroundStyle(.hearthText)
                .focused(focus, equals: field)
                .submitLabel(multiline ? .return : .next)
                .onSubmit(onSubmit)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, Spacing.m + 2)
                .padding(.vertical, multiline ? Spacing.s : Spacing.xs)
                .background(Color.hearthSurface2, in: shape)
                .overlay(shape.strokeBorder(borderColor(isFocused: isFocused), lineWidth: isFocused ? 1.5 : 1))
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(HearthFont.caption.weight(.semibold))
                    .foregroundStyle(.hearthDanger)
            } else if isOver && !hardLimit {
                Text("A little long. Shorter leaves more room for your chats.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
        }
        .onChange(of: text) { _, new in
            if hardLimit, let limit, new.count > limit { text = String(new.prefix(limit)) }
        }
    }

    private func borderColor(isFocused: Bool) -> Color {
        if isFocused { return Color.hearthAccent.opacity(0.8) }
        return error == nil ? Color.hearthLine : Color.hearthDanger
    }
}

/// A form section: serif title, an optional line under it, then the content.
struct CreateSection<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader(title)
                if let subtitle {
                    Text(subtitle)
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
    }
}

/// A card-like row that shows or hides more options under it.
struct CreateDisclosure<Content: View>: View {
    private let title: String
    private let subtitle: String?
    @Binding private var isExpanded: Bool
    private let content: Content

    init(_ title: String, subtitle: String? = nil, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.l) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Spacing.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(HearthFont.headline)
                            .foregroundStyle(.hearthText)
                        if let subtitle {
                            Text(subtitle)
                                .font(HearthFont.caption)
                                .foregroundStyle(.hearthText2)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: Spacing.s)
                    Image(systemName: "chevron.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.hearthMuted)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .frame(minHeight: 56)
                .background(Color.hearthSurface, in: shape)
                .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
                .contentShape(shape)
            }
            .buttonStyle(.pressable)
            .accessibilityValue(isExpanded ? "Open" : "Closed")

            if isExpanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Lays chips out in rows, wrapping to the next row when one is full.
struct CreateFlowLayout: Layout {
    var spacing: CGFloat = Spacing.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth) // a chip wider than a row gets the row to itself
            if !row.items.isEmpty, row.width + spacing + size.width > maxWidth {
                rows.append(row)
                row = Row()
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A slider that says its value in words ("Natural", "Often"), on screen and to VoiceOver.
struct CreateWordSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let lowLabel: String
    let highLabel: String
    let word: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Spacer(minLength: Spacing.s)
                Text(word(value))
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
            .accessibilityHidden(true) // the slider below says the same
            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Text(lowLabel)
                    .font(HearthFont.small)
                    .foregroundStyle(.hearthMuted)
            } maximumValueLabel: {
                Text(highLabel)
                    .font(HearthFont.small)
                    .foregroundStyle(.hearthMuted)
            }
            .tint(.hearthAccent)
            .accessibilityValue(word(value))
        }
    }
}

/// An icon in a soft circle and a short title, used for the avatar choices next to the preview.
struct CreateOptionRow: View {
    let title: String
    let symbol: String
    var tint: Color = .hearthAccent
    let action: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var circle: CGFloat = 36

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: circle, height: circle)
                    .background(Color.hearthSurface2, in: Circle())
                    .overlay(Circle().strokeBorder(Color.hearthLine, lineWidth: 1))
                    .accessibilityHidden(true)
                Text(title)
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

/// A small text button for helpers inside a section ("Add a pair of lines"). Wraps at large text sizes.
struct CreateHelperButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(.hearthAccent)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.hearthText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(HearthFont.callout.weight(.semibold))
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}
