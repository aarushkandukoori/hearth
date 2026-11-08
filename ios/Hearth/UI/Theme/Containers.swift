// Surfaces and screen chrome: HearthCard, EmptyStateView, the warm screen background and toasts.

import SwiftUI

/// A rounded surface for grouping content (settings blocks, profile sections).
struct HearthCard<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = Spacing.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hearthLine.opacity(0.8), lineWidth: 1))
    }
}

/// A friendly placeholder for screens with nothing in them yet.
struct EmptyStateView: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(symbol: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.l) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Color.hearthGold.opacity(0.26), Color.hearthGold.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 60))
                    .frame(width: 120, height: 120)
                Circle()
                    .fill(Color.hearthSurface2)
                    .overlay(Circle().strokeBorder(Color.hearthLine, lineWidth: 1))
                    .frame(width: 72, height: 72)
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.hearthGold)
            }
            .accessibilityHidden(true)

            VStack(spacing: Spacing.s) {
                Text(title)
                    .font(HearthFont.title(22))
                    .foregroundStyle(.hearthText)
                Text(message)
                    .font(HearthFont.body)
                    .foregroundStyle(.hearthText2)
            }
            .multilineTextAlignment(.center)

            if let actionTitle, let action {
                PillButton(actionTitle, action: action)
                    .padding(.top, Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
        .frame(maxWidth: 440)
    }
}

extension View {
    /// The warm app background (with a faint lantern glow at the top), behind safe areas too.
    /// Also hides the default List/Form background so this one shows through.
    func hearthScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background {
                HearthBackdrop().ignoresSafeArea()
            }
    }

    /// Shows `text` as a small floating message at the top, then clears it after a moment.
    /// Tap to dismiss early. VoiceOver reads it out.
    func hearthToast(_ text: Binding<String?>) -> some View {
        modifier(HearthToastModifier(text: text))
    }
}

private struct HearthBackdrop: View {
    var body: some View {
        Color.hearthBackground
            .overlay(alignment: .top) {
                RadialGradient(colors: [Color.hearthAccent.opacity(0.09), .clear],
                               center: .top, startRadius: 0, endRadius: 420)
                    .frame(height: 420)
            }
    }
}

private struct HearthToastModifier: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message = text {
                    Text(message)
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.horizontal, Spacing.l)
                        .padding(.top, Spacing.s)
                        .onTapGesture { text = nil }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            AccessibilityNotification.Announcement(message).post()
                            try? await Task.sleep(for: .seconds(2.6))
                            guard !Task.isCancelled else { return }
                            text = nil
                        }
                }
            }
            .animation(.spring(duration: 0.35), value: text)
    }
}
