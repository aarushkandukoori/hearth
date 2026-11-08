// Cards for the chat: the model's state when it isn't ready (or is only the demo), a friendly error, the
// safety card with crisis resources (SPEC §2) and its one-line shortcut. None of them ever block the chat.

import SwiftUI

/// Shown when the model can't answer for real right away: missing or downloading, loading, failed to
/// load, or the demo engine (canned lines, no AI) standing in.
struct ChatEngineBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        switch app.engine.state {
        case .ready:
            if app.engine.active?.id == "mock" {
                ChatBannerCard(symbol: "theatermasks.fill", tint: .hearthGold,
                               title: "Demo replies",
                               message: "These are simple canned lines with no AI behind them, so they don't really read your messages. Download a model to talk for real.") {
                    PillButton("Models", symbol: "arrow.down", kind: .secondary) {
                        router.show(.settings(.model), in: .you)
                    }
                }
            }
        case .idle:
            progress("Getting ready…", detail: nil)
        case .loading(let label):
            progress(label + "…", detail: "The first time can take a little while. You can start typing.")
        case .needsModel:
            if let download = SettingsModelActions.downloadLine(app.engine) {
                progress(download, detail: "Everyone can talk as soon as it's on this iPhone. You can look around town meanwhile.")
            } else {
                ChatBannerCard(symbol: "arrow.down.circle.fill", tint: .hearthAccent,
                               title: "Hearth's model isn't on this iPhone yet",
                               message: "Download it once, and every chat works offline after that, even in Airplane Mode.") {
                    PillButton("Download the Hearth model", symbol: "arrow.down") {
                        router.show(.settings(.model), in: .you)
                    }
                }
            }
        case .failed(let message):
            ChatBannerCard(symbol: "exclamationmark.triangle.fill", tint: .hearthGold,
                           title: "The model couldn't start", message: message) {
                HStack(spacing: Spacing.s) {
                    PillButton("Try again", symbol: "arrow.clockwise", kind: .secondary) {
                        Task { await app.engine.start(preferredEngineID: app.settings.preferredEngineID) }
                    }
                    PillButton("Models", kind: .quiet) { router.show(.settings(.model), in: .you) }
                }
            }
        }
    }

    private func progress(_ title: String, detail: String?) -> some View {
        HStack(spacing: Spacing.m) {
            ProgressView().tint(.hearthText2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthText)
                if let detail {
                    Text(detail)
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthText2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hearthLine, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// A problem with the last reply, with "Try again" (and "Models" when the same model keeps failing).
struct ChatErrorBanner: View {
    let text: String
    let canRetry: Bool
    let onRetry: () -> Void
    let onDismiss: () -> Void
    var onModels: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(.hearthGold)
                .accessibilityHidden(true)
            Text(text)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if canRetry {
                Button("Try again", action: onRetry)
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthAccentText)
                    .frame(minHeight: 44)
            }
            if let onModels {
                Button("Models", action: onModels)
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthAccentText)
                    .frame(minHeight: 44)
                    .accessibilityHint("Opens You, Model, to try another model")
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.hearthMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss")
        }
        .buttonStyle(.plain)
        .padding(.leading, Spacing.l)
        .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hearthLine, lineWidth: 1))
    }
}

/// Gentle support resources after a worrying message. The chat keeps going underneath.
struct ChatSafetyCard: View {
    let level: SafetyLevel
    let onDismiss: () -> Void
    @Environment(\.openURL) private var openURL

    /// Tells VoiceOver that support options just appeared (in a chat, a call or a scene). The card sits in the
    /// conversation, so VoiceOver wouldn't notice it by itself.
    static func announce() {
        AccessibilityNotification.Announcement("Support options are showing. You can call or text 988 any time in the US.").post()
    }

    /// "Call 988 (US)": the button says which lines are US only, not just its hint.
    static func buttonTitle(for resource: SafetyResource) -> String {
        resource.detail.contains("(US)") ? "\(resource.actionTitle) (US)" : resource.actionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.hearthAccent)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                Text(level == .crisis ? "Real people are ready to listen, any time"
                                      : "If things ever feel heavy, people are ready to listen")
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.hearthMuted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -12)
                .padding(.trailing, -12)
                .accessibilityLabel("Hide support options")
            }
            if level == .crisis {
                Text(SafetyGuard.gentleMessage)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: Spacing.s)], alignment: .leading, spacing: Spacing.s) {
                ForEach(SafetyGuard.resources) { resource in
                    Button { openURL(resource.url) } label: {
                        Label(Self.buttonTitle(for: resource), systemImage: Self.symbol(for: resource.url))
                            .font(HearthFont.callout.weight(.semibold))
                            .foregroundStyle(.hearthText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal, Spacing.s)
                            .background(Color.hearthSurface2, in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
                    }
                    .buttonStyle(.pressable)
                    .accessibilityHint("\(resource.title). \(resource.detail)")
                }
            }
            Text("If you're in immediate danger, call your local emergency number.")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthText2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.l)
        .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .strokeBorder(Color.hearthAccent.opacity(0.35), lineWidth: 1))
    }

    private static func symbol(for url: URL) -> String {
        switch url.scheme {
        case "tel": return "phone.fill"
        case "sms": return "message.fill"
        default: return "globe"
        }
    }
}

/// One line above the composer while the support card is scrolled out of view: call or text right away,
/// or bring the whole card back down to the newest message.
struct ChatSupportChip: View {
    let onShowAll: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(SafetyGuard.resources.prefix(2))
            row(SafetyGuard.resources.prefix(1))
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge) // a shortcut; the full card grows with the text
    }

    private func row(_ resources: ArraySlice<SafetyResource>) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "heart.fill")
                .foregroundStyle(.hearthAccent)
                .accessibilityHidden(true)
            ForEach(resources) { resource in
                Button { openURL(resource.url) } label: {
                    Text(resource.actionTitle)
                        .font(HearthFont.callout.weight(.semibold))
                        .foregroundStyle(.hearthText)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, Spacing.m)
                        .frame(minHeight: 36)
                        .background(Color.hearthSurface2, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityHint("\(resource.title). \(resource.detail)")
            }
            Spacer(minLength: 0)
            Button(action: onShowAll) {
                Text("More help")
                    .font(HearthFont.callout.weight(.semibold))
                    .foregroundStyle(.hearthAccentText)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all the support options in the chat")
        }
        .padding(.horizontal, Spacing.m)
        .background(Color.hearthSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.hearthAccent.opacity(0.35), lineWidth: 1))
    }
}

/// The shared look of the engine cards: icon, title, message, then actions.
private struct ChatBannerCard<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(title)
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text(message)
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            actions()
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.hearthSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Color.hearthLine, lineWidth: 1))
    }
}
