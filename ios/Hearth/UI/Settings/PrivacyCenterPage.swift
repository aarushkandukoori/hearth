// The Privacy Center: what stays on this iPhone (all of it), what Hearth uses the network for, App Lock and
// the other protections, town gossip, storage by kind, encrypted backups, and "Delete everything".

import LocalAuthentication
import SwiftUI

struct PrivacyCenterPage: View {
    @Environment(AppModel.self) private var app
    @State private var storage: [StorageItem] = []
    @State private var unlockMethod = "Face ID"
    @State private var toast: String?
    @State private var lockProblem: String?
    @State private var showExport = false
    @State private var showImport = false
    @State private var showDelete = false

    var body: some View {
        @Bindable var store = app.settingsStore
        List {
            Section {
                PrivacyPromiseCard()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent {
                    Text(SettingsFormat.bytes(app.vault.networkDownloadedBytes))
                        .monospacedDigit()
                } label: {
                    SettingsRowLabel(title: "Downloaded", detail: "AI models only", symbol: "arrow.down.circle.fill",
                                     tint: .hearthSea)
                }
                // A promise, not a byte count: downloads send a little request data of their own, but nothing
                // about you ever goes out.
                SettingsRowLabel(title: "Your data", detail: "Chats, photos, voice and memories are never uploaded",
                                 symbol: "arrow.up.circle.fill", tint: .hearthSuccess)
            } header: {
                SettingsSectionTitle("Network use")
            } footer: {
                Text("Hearth uses the internet for one thing: downloading a model. Turn on Airplane Mode and everything keeps working.")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                Toggle(isOn: appLockBinding) {
                    SettingsRowLabel(title: "App Lock", detail: "Ask for \(unlockMethod) when Hearth opens",
                                     symbol: "faceid", tint: .hearthAccent)
                }
                Toggle(isOn: $store.settings.hideInAppSwitcher) {
                    SettingsRowLabel(title: "Hide in app switcher", detail: "Show a plain lantern instead of your chats",
                                     symbol: "rectangle.on.rectangle.slash", tint: .hearthGold)
                }
                Toggle(isOn: backupBinding) {
                    SettingsRowLabel(title: "Keep out of iCloud backups",
                                     detail: "Chats stay off iCloud and computer backups. Make an encrypted backup below if you want a copy.",
                                     symbol: "icloud.slash.fill", tint: .hearthSea)
                }
            } header: {
                SettingsSectionTitle("Protection")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                Toggle(isOn: $store.settings.townGossip) {
                    SettingsRowLabel(title: "Town gossip",
                                     detail: "Residents may mention things you told someone else in town, like news in a small town. Turn it off to keep each chat to itself.",
                                     symbol: "bubble.left.and.text.bubble.right.fill", tint: .hearthGold)
                }
            } header: {
                SettingsSectionTitle("Between friends")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                ForEach(storage) { item in
                    LabeledContent(item.label) {
                        Text(SettingsFormat.bytes(item.bytes))
                            .monospacedDigit()
                    }
                    .font(HearthFont.callout)
                }
                LabeledContent {
                    Text(SettingsFormat.bytes(storage.reduce(0) { $0 + $1.bytes }))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                } label: {
                    Text("Total")
                        .fontWeight(.semibold)
                }
                .font(HearthFont.callout)
            } header: {
                SettingsSectionTitle("Space Hearth uses on this iPhone")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                SettingsLinkRow(title: "Make an encrypted backup", detail: "Chats, characters, memories and settings, locked with a passphrase",
                                symbol: "square.and.arrow.up.fill", tint: .hearthSea) { showExport = true }
                SettingsLinkRow(title: "Bring in a backup", detail: "Adds a backup's chats, characters and memories to what's here. Nothing here is deleted.",
                                symbol: "square.and.arrow.down.fill", tint: .hearthSea) { showImport = true }
            } header: {
                SettingsSectionTitle("Backups")
            } footer: {
                Text("Backups hold text only. Photos, pictures and voice notes stay on this iPhone.")
            }
            .listRowBackground(Color.hearthSurface)

            Section {
                Button(role: .destructive) { showDelete = true } label: {
                    SettingsRowLabel(title: "Delete everything", detail: "Erase all chats, characters and settings from this iPhone",
                                     symbol: "trash.fill", tint: .hearthDanger, titleColor: .hearthDanger)
                }
            }
            .listRowBackground(Color.hearthSurface)
        }
        .listStyle(.insetGrouped)
        .hearthScreenBackground()
        .navigationTitle("Privacy Center")
        .navigationBarTitleDisplayMode(.inline)
        .hearthToast($toast)
        .task {
            unlockMethod = app.vault.unlockMethodName
            refreshStorage()
        }
        .sheet(isPresented: $showExport) {
            ExportBackupSheet { message in toast = message }
        }
        .sheet(isPresented: $showImport, onDismiss: refreshStorage) {
            ImportBackupSheet { message in toast = message }
        }
        .sheet(isPresented: $showDelete) {
            DeleteEverythingSheet()
        }
        .alert("App Lock", isPresented: lockProblemBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(lockProblem ?? "")
        }
    }

    // MARK: Toggles with side effects

    /// Turning App Lock on first checks that Face ID or the passcode works, so nobody gets locked out.
    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { app.settings.appLock },
            set: { on in
                if on {
                    Task { await turnOnAppLock() }
                } else {
                    app.settingsStore.update { $0.appLock = false }
                }
            }
        )
    }

    private var backupBinding: Binding<Bool> {
        Binding(
            get: { app.settings.excludeFromBackup },
            set: { excluded in
                app.settingsStore.update { $0.excludeFromBackup = excluded }
                app.vault.applyBackupExclusion(excluded)
            }
        )
    }

    private var lockProblemBinding: Binding<Bool> {
        Binding(get: { lockProblem != nil }, set: { if !$0 { lockProblem = nil } })
    }

    private func turnOnAppLock() async {
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            if problem?.code == LAError.Code.passcodeNotSet.rawValue {
                lockProblem = "To use App Lock, first set a passcode for this iPhone in Settings > Face ID & Passcode."
            } else {
                lockProblem = "This iPhone can't check Face ID or a passcode right now. Please try again later."
            }
            return
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                      localizedReason: "Check that you can unlock Hearth before App Lock turns on.")
            if ok {
                app.settingsStore.update { $0.appLock = true }
                toast = "App Lock is on"
            }
        } catch {
            // Cancelled or not recognized: App Lock stays off, nothing else to do.
        }
    }

    private func refreshStorage() {
        storage = app.vault.storageBreakdown().map { StorageItem(label: $0.label, bytes: $0.bytes) }
    }
}

private struct StorageItem: Identifiable {
    var id: String { label }
    let label: String
    let bytes: Int64
}

/// "Everything stays on this iPhone", with the four facts behind it.
private struct PrivacyPromiseCard: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Spacing.l) {
            HStack(alignment: .center, spacing: Spacing.m) {
                HearthLanternMark(height: 48)
                PrivacyBadge("On-device")
                Spacer(minLength: 0)
            }
            Text("Everything stays on this iPhone")
                .modifier(SettingsScaledTitle(26))
                .foregroundStyle(.hearthText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Spacing.m) {
                PromiseFact(symbol: "person.crop.circle.badge.xmark", title: "No account",
                            detail: "No sign-up, email or password.")
                PromiseFact(symbol: "icloud.slash.fill", title: "No servers",
                            detail: "Your chats, photos and voice notes never leave this iPhone.")
                PromiseFact(symbol: "eye.slash.fill", title: "No analytics or ads",
                            detail: "Nobody keeps track of what you do here.")
                PromiseFact(symbol: "airplane", title: "Works offline",
                            detail: "After one model download, Hearth runs in Airplane Mode.")
            }
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(Color.hearthSurface)
                .overlay {
                    RadialGradient(colors: [Color.hearthAccent.opacity(0.14), .clear],
                                   center: .topLeading, startRadius: 0, endRadius: 320)
                        .clipShape(shape)
                }
        }
        .overlay(shape.strokeBorder(Color.hearthLine, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }
}

private struct PromiseFact: View {
    let symbol: String
    let title: String
    let detail: String
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 26

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.hearthSuccess)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(HearthFont.headline)
                    .foregroundStyle(.hearthText)
                Text(detail)
                    .font(HearthFont.callout)
                    .foregroundStyle(.hearthText2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
