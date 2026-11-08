// Buttons and headers: PillButton, CategoryChip, SectionHeader, and `.buttonStyle(.pressable)`
// for making cards and rows tappable with a gentle press-down effect.

import SwiftUI

struct PillButton: View {
    enum Kind { case primary, secondary, quiet, danger }

    private let title: String
    private let symbol: String?
    private let kind: Kind
    private let action: () -> Void
    private var expands = false

    init(_ title: String, symbol: String? = nil, kind: Kind = .primary, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.kind = kind
        self.action = action
    }

    /// Stretch to the full available width (for bottom-of-screen actions).
    func fullWidth(_ on: Bool = true) -> PillButton {
        var copy = self
        copy.expands = on
        return copy
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .buttonStyle(PillButtonStyle(kind: kind, expands: expands))
    }
}

private struct PillButtonStyle: ButtonStyle {
    let kind: PillButton.Kind
    let expands: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HearthFont.headline)
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .quiet ? Spacing.m : Spacing.xl - 2)
            .frame(minHeight: 48)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(background, in: Capsule())
            .overlay {
                if kind == .secondary {
                    Capsule().strokeBorder(Color.hearthLine, lineWidth: 1)
                } else if kind == .danger {
                    Capsule().strokeBorder(Color.hearthDanger.opacity(0.35), lineWidth: 1)
                }
            }
            // A soft ember glow under the main action.
            .shadow(color: kind == .primary && isEnabled ? Color.hearthAccent.opacity(0.28) : .clear, radius: 12, y: 4)
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.88 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .hearthOnAccent
        case .secondary: return .hearthText
        case .quiet: return .hearthText2
        case .danger: return .hearthDanger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return .hearthAccent
        case .secondary: return .hearthSurface2
        case .quiet: return .clear
        case .danger: return Color.hearthDanger.opacity(0.14)
        }
    }
}

struct CategoryChip: View {
    private let title: String
    private let symbol: String?
    private let selected: Bool
    private let action: () -> Void

    init(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol)
                        .imageScale(.small)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(HearthFont.callout.weight(.semibold))
            .foregroundStyle(selected ? Color.hearthBackground : Color.hearthText2)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(selected ? Color.hearthText : Color.hearthSurface2, in: shape)
            .overlay(shape.strokeBorder(selected ? Color.clear : Color.hearthLine, lineWidth: 1))
            // Looks 36 pt tall, but the tap target is the full 44 pt.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(.easeOut(duration: 0.18), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct SectionHeader: View {
    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(_ title: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(title)
                .font(HearthFont.title(21))
                .foregroundStyle(.hearthText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthAccentText)
                        .padding(.vertical, Spacing.xs) // a bigger tap target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

/// Shrinks and dims slightly while pressed. Keeps the label's own colors (unlike the default style).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
