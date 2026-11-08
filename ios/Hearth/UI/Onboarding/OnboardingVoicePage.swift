// Onboarding step 5, "Give the town a voice": Hearth Standard or Lite (downloaded once, and the person can
// keep going while it downloads) or Apple Intelligence when this iPhone has it.

import SwiftUI

struct OnboardingVoicePage: View {
    @Environment(AppModel.self) private var app
    @Binding var choice: OnboardingEngineChoice?

    var body: some View {
        OnboardingPageScroll(art: "loc-observatory", artHeight: 220) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                OnboardingTitle(title: "Give the town a voice",
                                subtitle: "Hearth's characters think with a small AI model that runs right on your iPhone. Download it once, and the town works anywhere, even in Airplane Mode.")
                VStack(spacing: Spacing.m) {
                    ForEach(OnboardingVoiceOptions.models) { spec in
                        VoiceOptionCard(title: SettingsModelActions.title(spec),
                                        subtitle: "\(SettingsModelActions.modelName(spec)), about \(SettingsFormat.approximate(spec.bytes))",
                                        detail: OnboardingVoiceOptions.detail(for: spec),
                                        tag: OnboardingVoiceOptions.tag(for: spec, app: app),
                                        status: status(for: spec),
                                        selected: choice == .model(spec.id)) {
                            withAnimation(.snappy) { choice = .model(spec.id) }
                        }
                    }
                    if app.engine.appleAvailable {
                        VoiceOptionCard(title: "Apple Intelligence",
                                        subtitle: "Built into this iPhone, nothing to download",
                                        detail: "Apple's own on-device model. It can be more careful than Hearth's models and may turn down some topics.",
                                        tag: nil, status: .none, selected: choice == .apple) {
                            withAnimation(.snappy) { choice = .apple }
                        }
                    }
                }
                Label("It's a big download, so Wi-Fi is best. This is the only time Hearth uses the internet, and you can keep going while it downloads.",
                      systemImage: "wifi")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
        }
        .task {
            if choice == nil { choice = OnboardingVoiceOptions.defaultChoice(app: app) }
            SettingsModelActions.resumeWatching(app: app)
        }
        .sensoryFeedback(.selection, trigger: choice) { _, _ in app.settings.haptics }
    }

    private func status(for spec: ModelSpec) -> VoiceOptionCard.Status {
        switch app.engine.downloader.state(for: spec) {
        case .downloading(let fraction, _, _): return .downloading(fraction)
        case .verifying: return .verifying
        case .failed(let message): return .failed(message)
        case .installed, .idle: return SettingsModelActions.isInstalled(spec, app: app) ? .ready : .none
        }
    }
}

/// What the voice step offers, what its button says, and what pressing it does.
@MainActor
enum OnboardingVoiceOptions {
    static let models = [ModelCatalog.standard, ModelCatalog.lite]

    /// A ready model first, then one already downloading, then Standard (or Lite on iPhones with less memory).
    static func defaultChoice(app: AppModel) -> OnboardingEngineChoice {
        if let ready = models.first(where: { SettingsModelActions.isInstalled($0, app: app) }) {
            return .model(ready.id)
        }
        if let busy = models.first(where: { SettingsModelActions.isBusy(app.engine.downloader.state(for: $0)) }) {
            return .model(busy.id)
        }
        return .model(bestFit.id)
    }

    /// Standard when it fits this iPhone's memory, else Lite.
    static var bestFit: ModelSpec {
        SettingsModelActions.fitsThisPhone(ModelCatalog.standard) ? ModelCatalog.standard : ModelCatalog.lite
    }

    static func detail(for spec: ModelSpec) -> String {
        if spec.id == ModelCatalog.lite.id {
            return "Smaller and quicker, with simpler replies. Good for older iPhones or when space is tight."
        }
        if !SettingsModelActions.fitsThisPhone(spec) {
            return "Warm, steady conversation, but it needs more memory than this iPhone has, so it may be slow or close."
        }
        return "Warm, steady conversation. The everyday choice for most recent iPhones."
    }

    static func tag(for spec: ModelSpec, app: AppModel) -> (text: String, tint: Color)? {
        if SettingsModelActions.isInstalled(spec, app: app) { return ("Ready", .hearthSuccess) }
        if spec.id == bestFit.id { return (spec.recommended ? "Recommended" : "Best for this iPhone", .hearthGold) }
        return nil
    }

    /// `short` gives one-word labels for very large text sizes (the chosen card already says what it is).
    static func buttonTitle(for choice: OnboardingEngineChoice?, app: AppModel, short: Bool = false) -> String {
        switch choice {
        case nil:
            return short ? "Choose one" : "Choose one to continue"
        case .apple:
            return short ? "Continue" : "Use Apple Intelligence"
        case .model(let id):
            guard let spec = ModelCatalog.spec(id: id) else { return "Continue" }
            if SettingsModelActions.isInstalled(spec, app: app) {
                return short ? "Continue" : "Use \(SettingsModelActions.title(spec))"
            }
            if SettingsModelActions.isBusy(app.engine.downloader.state(for: spec)) { return "Continue" }
            return short ? "Download" : "Download and continue"
        }
    }

    /// Acts on the choice. Returns false when the person should stay on this step (the card says why,
    /// for example when there isn't enough free space). A download started earlier for another option is
    /// paused, so two big files don't download at once.
    static func confirm(_ choice: OnboardingEngineChoice, app: AppModel, allowsCellular: Bool = false) -> Bool {
        switch choice {
        case .apple:
            SettingsModelActions.pauseOtherDownloads(keeping: nil, app: app)
            Task { await SettingsModelActions.use("apple", app: app) }
            return true
        case .model(let id):
            guard let spec = ModelCatalog.spec(id: id) else { return true }
            SettingsModelActions.pauseOtherDownloads(keeping: spec.id, app: app)
            if SettingsModelActions.isInstalled(spec, app: app) {
                Task { await SettingsModelActions.use(spec.id, app: app) }
                return true
            }
            return SettingsModelActions.download(spec, app: app, allowsCellular: allowsCellular)
        }
    }

    /// "Not now": carry on with Apple's model when this iPhone has it. Without it the town waits quietly for
    /// a model (no canned demo replies).
    static func skip(app: AppModel) {
        SettingsModelActions.keepTownTalking(app: app)
    }

    /// The line under "Not now", so skipping is never a surprise later.
    static func skipNote(app: AppModel) -> String {
        app.engine.appleAvailable
            ? "Until then, Apple Intelligence talks for the town."
            : "Without a model the town can't talk yet. You can download one any time in You > Model."
    }

    /// True when confirming this choice starts a new download (not a model that's ready or already coming).
    static func startsDownload(_ choice: OnboardingEngineChoice, app: AppModel) -> Bool {
        guard case .model(let id) = choice, let spec = ModelCatalog.spec(id: id) else { return false }
        return !SettingsModelActions.isInstalled(spec, app: app) && !SettingsModelActions.isBusy(app.engine.downloader.state(for: spec))
    }

    /// What the cellular question says about this download.
    static func cellularMessage(for choice: OnboardingEngineChoice) -> String {
        guard case .model(let id) = choice, let spec = ModelCatalog.spec(id: id) else {
            return "This iPhone isn't on Wi-Fi right now."
        }
        return "This iPhone isn't on Wi-Fi, and \(SettingsModelActions.title(spec)) is about \(SettingsFormat.approximate(spec.bytes)). "
            + "Downloading now uses your mobile data. You can also start it later in You > Model."
    }
}

/// One selectable option on the voice step, with its download progress when there is one.
private struct VoiceOptionCard: View {
    enum Status: Equatable {
        case none, ready, verifying
        case downloading(Double)
        case failed(String)
    }

    let title: String
    let subtitle: String
    let detail: String
    let tag: (text: String, tint: Color)?
    let status: Status
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selected ? Color.hearthAccent : Color.hearthMuted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if let tag {
                        SettingsTag(tag.text, tint: tag.tint)
                            .padding(.bottom, 2)
                    }
                    Text(title)
                        .modifier(SettingsScaledTitle(20))
                        .foregroundStyle(.hearthText)
                    Text(subtitle)
                        .font(HearthFont.caption.weight(.semibold))
                        .foregroundStyle(.hearthText2)
                    Text(detail)
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                        .fixedSize(horizontal: false, vertical: true)
                    statusRow
                        .padding(.top, Spacing.xs)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.hearthSurface2 : Color.hearthSurface, in: shape)
            .overlay(shape.strokeBorder(selected ? Color.hearthAccent : Color.hearthLine, lineWidth: selected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .none:
            EmptyView()
        case .ready:
            Label("On this iPhone and ready", systemImage: "checkmark.seal.fill")
                .font(HearthFont.caption.weight(.semibold))
                .foregroundStyle(.hearthSuccess)
        case .verifying:
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text("Checking the download")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
        case .downloading(let fraction):
            HStack(spacing: Spacing.s) {
                SettingsDownloadRing(fraction: fraction, size: 30)
                Text("Downloading. You can keep going.")
                    .font(HearthFont.caption)
                    .foregroundStyle(.hearthText2)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthDanger)
        }
    }
}
