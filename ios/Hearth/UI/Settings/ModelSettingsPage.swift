// The Model page: what the town is talking with right now (and whether replies have been failing), the
// models you can download (with progress, pause, use, delete and their licenses; cellular data asks first),
// Apple Intelligence when this iPhone has it, and what models use on disk and network.

import SwiftUI

struct ModelSettingsPage: View {
    @Environment(AppModel.self) private var app
    @State private var parkedBytes: Int64 = 0
    @State private var freeBytes: Int64?
    @State private var toast: String?
    @State private var deleting: ModelSpec?
    /// A download waiting for the person's OK, because this iPhone is on cellular data.
    @State private var cellularSpec: ModelSpec?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                CurrentEngineCard()

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("Models")
                    Text("Each one runs entirely on this iPhone. Download once, and the town works anywhere, even in Airplane Mode. Downloads are big, so Wi-Fi is best.")
                        .font(HearthFont.callout)
                        .foregroundStyle(.hearthText2)
                    ForEach(ModelCatalog.all) { spec in
                        ModelCatalogCard(spec: spec, onUse: { use(spec.id) }, onDownload: { requestDownload(spec) },
                                         onDelete: { deleting = spec })
                    }
                    if app.engine.appleAvailable {
                        AppleEngineCard { use("apple") }
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.m) {
                    SectionHeader("Storage and network")
                    storageCard
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.l)
        }
        .hearthScreenBackground()
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .hearthToast($toast)
        .task {
            refreshNumbers()
            SettingsModelActions.resumeWatching(app: app)
        }
        .onChange(of: app.engine.installedModels) { refreshNumbers() }
        .confirmationDialog(deleting.map { "Delete \(SettingsModelActions.title($0))?" } ?? "Delete model?",
                            isPresented: deleteBinding, titleVisibility: .visible, presenting: deleting) { spec in
            Button("Delete \(SettingsModelActions.title(spec))", role: .destructive) {
                Task { await delete(spec) }
            }
            Button("Keep it", role: .cancel) {}
        } message: { spec in
            Text("This frees about \(SettingsFormat.approximate(spec.bytes)). Your chats stay, and you can download it again any time.")
        }
        .confirmationDialog("Download over cellular data?", isPresented: cellularBinding, titleVisibility: .visible,
                            presenting: cellularSpec) { spec in
            Button("Download now") { SettingsModelActions.download(spec, app: app, allowsCellular: true) }
            Button("Not now", role: .cancel) {}
        } message: { spec in
            Text("This iPhone isn't on Wi-Fi, and \(SettingsModelActions.title(spec)) is about \(SettingsFormat.approximate(spec.bytes)). Downloading now uses your mobile data.")
        }
    }

    private var storageCard: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HStack(alignment: .center, spacing: Spacing.s) {
                    SettingsRowLabel(title: "Instant resume",
                                     detail: "\(SettingsFormat.bytes(parkedBytes)) of saved chat memory, so switching between friends is quick.",
                                     symbol: "bolt.fill", tint: .hearthGold)
                    Spacer(minLength: Spacing.s)
                    PillButton("Clear", kind: .quiet) { Task { await clearParked() } }
                        .disabled(parkedBytes == 0)
                        .accessibilityLabel("Clear instant resume storage")
                }
                Divider().overlay(Color.hearthLine)
                SettingsRowLabel(title: "Downloaded so far",
                                 detail: "\(SettingsFormat.bytes(app.vault.networkDownloadedBytes)) over the network, all of it models. Your chats, photos and voice never leave this iPhone.",
                                 symbol: "arrow.down.circle.fill", tint: .hearthSea)
                Divider().overlay(Color.hearthLine)
                SettingsRowLabel(title: "Free space",
                                 detail: freeBytes.map { "\(SettingsFormat.bytes($0)) free on this iPhone. A download needs its own size plus about 500 MB to spare." }
                                     ?? "Checking free space on this iPhone.",
                                 symbol: "internaldrive.fill", tint: .hearthMuted)
            }
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var cellularBinding: Binding<Bool> {
        Binding(get: { cellularSpec != nil }, set: { if !$0 { cellularSpec = nil } })
    }

    /// Starts a download right away on Wi-Fi; on cellular data or in Low Data Mode it asks first.
    private func requestDownload(_ spec: ModelSpec) {
        Task {
            if await SettingsModelActions.onExpensiveNetwork() {
                cellularSpec = spec
            } else {
                SettingsModelActions.download(spec, app: app)
            }
        }
    }

    private func refreshNumbers() {
        parkedBytes = app.engine.parkedBytes()
        freeBytes = ModelDownloader.freeBytes()
    }

    private func use(_ engineID: String) {
        Task {
            if await SettingsModelActions.use(engineID, app: app) {
                toast = "Now talking with \(SettingsModelActions.engineName(app.engine.active))"
            } else if case .failed(let message) = app.engine.state {
                toast = message
            } else {
                toast = "That model can't run on this device."
            }
        }
    }

    private func delete(_ spec: ModelSpec) async {
        await app.engine.deleteModel(spec)
        if app.settings.preferredEngineID == spec.id {
            app.settingsStore.update { $0.preferredEngineID = nil }
        }
        refreshNumbers()
        toast = "\(SettingsModelActions.title(spec)) deleted"
    }

    private func clearParked() async {
        await app.engine.purgeParked()
        refreshNumbers()
        toast = "Cleared. Your chats are all still here."
    }
}

/// What the town is talking with right now, and what it is doing.
private struct CurrentEngineCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.m) {
                    SettingsIcon(symbol: "cpu.fill", tint: .hearthAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The town is talking with")
                            .font(HearthFont.caption)
                            .foregroundStyle(.hearthText2)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1) // a small label; it shouldn't outgrow the name under it
                        Text(SettingsModelActions.engineName(app.engine.active))
                            .modifier(SettingsScaledTitle(22))
                            .foregroundStyle(.hearthText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                status
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch app.engine.state {
        case .ready:
            if app.engine.active?.id == "mock" {
                Text("Simple demo replies, with no AI behind them. Download a model below and the town comes alive.")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            } else {
                HStack(spacing: Spacing.s) {
                    PrivacyBadge("On-device")
                    PrivacyBadge("Works offline")
                }
            }
            if ChatController.failedInARow >= 2 {
                Label("Recent replies didn't come through. If it keeps happening, try another model below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .loading(let label):
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text(label)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
        case .idle:
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text("Starting up")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
        case .needsModel:
            Text("There's no model on this iPhone yet. Download one below to wake the town up.")
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(message)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthDanger)
                PillButton("Try again", symbol: "arrow.clockwise", kind: .secondary) {
                    Task { await app.engine.start(preferredEngineID: app.settings.preferredEngineID) }
                }
            }
        }
    }
}

/// One model from the catalog: what it is, and download, pause, use or delete.
private struct ModelCatalogCard: View {
    @Environment(AppModel.self) private var app
    let spec: ModelSpec
    let onUse: () -> Void
    let onDownload: () -> Void
    let onDelete: () -> Void

    private var state: ModelDownloader.State { app.engine.downloader.state(for: spec) }
    /// From EngineHost's list, which is re-read from disk (the downloader's state can lag after "Delete everything").
    private var installed: Bool { SettingsModelActions.isInstalled(spec, app: app) }
    private var inUse: Bool { app.engine.active?.id == spec.id }

    var body: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SettingsModelActions.title(spec))
                            .modifier(SettingsScaledTitle(21))
                            .foregroundStyle(.hearthText)
                        Text(SettingsModelActions.modelName(spec))
                            .font(HearthFont.caption.weight(.semibold))
                            .foregroundStyle(.hearthText2)
                    }
                    Spacer(minLength: Spacing.s)
                    if inUse {
                        SettingsTag("In use", tint: .hearthSuccess)
                    } else if spec.recommended {
                        SettingsTag("Recommended", tint: .hearthGold)
                    }
                }
                Text(spec.blurb)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                license
                if !SettingsModelActions.fitsThisPhone(spec) {
                    Label("Made for iPhones with about \(Int(spec.minimumMemoryGB)) GB of memory. It may be slow or close on this one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(HearthFont.caption)
                        .foregroundStyle(.hearthText2)
                }
                actions
                    .minimumScaleFactor(0.5) // short button labels shrink a little instead of cutting off
            }
        }
        .overlay {
            if inUse {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color.hearthSuccess.opacity(0.6), lineWidth: 1.5)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .downloading(let fraction, let bytes, let total):
            HStack(spacing: Spacing.m) {
                SettingsDownloadRing(fraction: fraction)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading")
                        .font(HearthFont.headline)
                        .foregroundStyle(.hearthText)
                    Text("\(SettingsFormat.bytes(bytes)) of \(SettingsFormat.bytes(total))")
                        .font(HearthFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.hearthText2)
                }
                Spacer(minLength: Spacing.s)
                PillButton("Pause", symbol: "pause.fill", kind: .quiet) {
                    app.engine.downloader.cancel(spec)
                }
                .accessibilityLabel("Pause the download")
            }
        case .verifying:
            HStack(spacing: Spacing.s) {
                ProgressView()
                Text("Checking the download")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthDanger)
                PillButton("Try again", symbol: "arrow.clockwise", kind: .secondary, action: onDownload)
            }
        case .idle, .installed:
            if installed {
                // Side by side when they fit, stacked at large text sizes.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.s) {
                        useControl
                        Spacer(minLength: Spacing.s)
                        deleteButton
                    }
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        useControl
                        deleteButton
                    }
                }
            } else {
                PillButton("Download", symbol: "arrow.down.circle.fill", kind: spec.recommended ? .primary : .secondary,
                           action: onDownload)
                .accessibilityLabel("Download \(SettingsModelActions.title(spec)), \(SettingsFormat.approximate(spec.bytes))")
            }
        }
    }

    /// The license's name, as links to read it (and the Acceptable Use Policy that comes with Llama).
    @ViewBuilder
    private var license: some View {
        let links = SettingsModelActions.licenseLinks(spec.license)
        if links.isEmpty {
            Label(spec.license, systemImage: "doc.text")
                .font(HearthFont.caption)
                .foregroundStyle(.hearthMuted)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "doc.text")
                            .font(HearthFont.caption.weight(.semibold))
                            .foregroundStyle(.hearthAccentText)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityHint("Opens the license on the web")
                }
            }
        }
    }

    @ViewBuilder
    private var useControl: some View {
        if inUse {
            Label("The town is using this one", systemImage: "checkmark.circle.fill")
                .font(HearthFont.callout.weight(.semibold))
                .foregroundStyle(.hearthSuccess)
        } else {
            PillButton("Use this model", kind: .secondary, action: onUse)
        }
    }

    private var deleteButton: some View {
        PillButton("Delete", symbol: "trash", kind: .danger, action: onDelete)
            .accessibilityLabel("Delete \(SettingsModelActions.title(spec))")
    }
}

/// Apple's own on-device model, shown only when this iPhone has Apple Intelligence.
private struct AppleEngineCard: View {
    @Environment(AppModel.self) private var app
    let onUse: () -> Void

    private var inUse: Bool { app.engine.active?.id == "apple" }

    var body: some View {
        HearthCard {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(alignment: .top, spacing: Spacing.s) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Intelligence")
                            .modifier(SettingsScaledTitle(21))
                            .foregroundStyle(.hearthText)
                        Text("Built into this iPhone")
                            .font(HearthFont.caption.weight(.semibold))
                            .foregroundStyle(.hearthText2)
                    }
                    Spacer(minLength: Spacing.s)
                    if inUse { SettingsTag("In use", tint: .hearthSuccess) }
                }
                Text("Apple's own on-device model, with nothing to download. It can be more careful than Hearth's models and may turn down some topics.")
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
                if !inUse {
                    PillButton("Use Apple Intelligence", symbol: "apple.intelligence", kind: .secondary, action: onUse)
                        .minimumScaleFactor(0.5)
                }
            }
        }
    }
}
