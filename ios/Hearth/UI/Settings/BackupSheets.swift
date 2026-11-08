// Encrypted backups: make one (passphrase, then save "Hearth Backup.hearth" with the Files picker) or bring
// one in (pick the file, type its passphrase, and its contents are added to what's already here).

import SwiftUI
import UniformTypeIdentifiers

/// The sealed backup bytes, ready for the Files picker.
struct HearthBackupFile: FileDocument {
    /// ".hearth" files. Without a declared type this is a dynamic type that still carries the extension.
    static let contentType = UTType(filenameExtension: "hearth", conformingTo: .data) ?? .data
    static var readableContentTypes: [UTType] { [contentType] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Choose a passphrase, seal everything, then save the file where you like.
struct ExportBackupSheet: View {
    /// Called with a short message for a toast once the file is saved.
    let onSaved: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var document: HearthBackupFile?
    @State private var showSaver = false
    @State private var problem: String?

    private static let minimumLength = 8

    private var canSave: Bool {
        passphrase.count >= Self.minimumLength && passphrase == confirmation && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BackupExplainer(symbol: "lock.doc.fill",
                                    text: "Your chats, characters, memories and settings go into one file, locked with a passphrase you choose. Photos, pictures and voice notes aren't included.")
                }
                .listRowBackground(Color.hearthSurface)

                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Type it again", text: $confirmation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    SettingsSectionTitle("Passphrase")
                } footer: {
                    Text(passphraseHint)
                        .foregroundStyle(hintIsWarning ? Color.hearthDanger : Color.hearthText2)
                }
                .listRowBackground(Color.hearthSurface)

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.hearthDanger)
                    }
                    .listRowBackground(Color.hearthSurface)
                }
            }
            .hearthScreenBackground()
            .safeAreaInset(edge: .bottom) {
                PillButton(isWorking ? "Locking your backup..." : "Save backup", symbol: "lock.fill") {
                    Task { await makeBackup() }
                }
                .fullWidth()
                .minimumScaleFactor(0.5)
                .disabled(!canSave)
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.s)
            }
            .navigationTitle("Encrypted backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileExporter(isPresented: $showSaver, document: document, contentType: HearthBackupFile.contentType,
                          defaultFilename: "Hearth Backup") { result in
                document = nil
                switch result {
                case .success:
                    onSaved("Backup saved")
                    dismiss()
                case .failure:
                    problem = "The backup couldn't be saved there. Please try another place."
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onChange(of: app.vault.isLocked) { _, locked in
            if locked { dismiss() }
        }
    }

    private var hintIsWarning: Bool {
        !confirmation.isEmpty && passphrase != confirmation
    }

    private var passphraseHint: String {
        if hintIsWarning { return "The two passphrases don't match yet." }
        return "Use at least \(Self.minimumLength) characters. A short sentence is easy to remember and hard to guess. If you forget it, nobody can open the backup, not even us."
    }

    private func makeBackup() async {
        guard canSave else { return }
        isWorking = true
        problem = nil
        let payload = HearthExport.gather(settings: app.settingsStore, library: app.library, chats: app.chats,
                                          memory: app.memory, events: app.events)
        let vault = app.vault
        let secret = passphrase
        do {
            // Stretching the passphrase takes a moment, so it runs off the main thread.
            let sealed = try await Task.detached(priority: .userInitiated) {
                try vault.exportEncrypted(payload, passphrase: secret)
            }.value
            passphrase = ""
            confirmation = ""
            document = HearthBackupFile(data: sealed)
            showSaver = true
        } catch {
            problem = error.localizedDescription
        }
        isWorking = false
    }
}

/// Pick a .hearth file, type its passphrase, and add what's inside to this iPhone.
struct ImportBackupSheet: View {
    /// Called with a short message for a toast after the backup is added.
    let onAdded: (String) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var fileData: Data?
    @State private var fileName: String?
    @State private var passphrase = ""
    @State private var showPicker = false
    @State private var isWorking = false
    @State private var problem: String?

    /// Backups are text only, so anything this big isn't one.
    private static let largestBackup = 512 * 1_048_576

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    BackupExplainer(symbol: "arrow.down.doc.fill",
                                    text: "Chats, characters and memories from the backup are added to what's here. If something is in both, the backup's copy is kept, and nothing else is deleted. This iPhone keeps your name and About you, its town gossip choice, App Lock and model choices. Other settings, like voice notes and pictures, come from the backup.")
                }
                .listRowBackground(Color.hearthSurface)

                Section {
                    Button { showPicker = true } label: {
                        SettingsRowLabel(title: fileName ?? "Choose a backup file",
                                         detail: fileName == nil ? "A .hearth file you saved before" : "Tap to choose a different file",
                                         symbol: "doc.fill", tint: .hearthSea)
                    }
                    SecureField("Passphrase", text: $passphrase)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    SettingsSectionTitle("Backup file")
                }
                .listRowBackground(Color.hearthSurface)

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.hearthDanger)
                    }
                    .listRowBackground(Color.hearthSurface)
                }
            }
            .hearthScreenBackground()
            .safeAreaInset(edge: .bottom) {
                PillButton(isWorking ? "Opening your backup..." : "Add to Hearth", symbol: "tray.and.arrow.down.fill") {
                    Task { await addBackup() }
                }
                .fullWidth()
                .minimumScaleFactor(0.5)
                .disabled(fileData == nil || passphrase.isEmpty || isWorking)
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.s)
            }
            .navigationTitle("Bring in a backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [HearthBackupFile.contentType, .data]) { result in
                readFile(result)
            }
        }
        .interactiveDismissDisabled(isWorking)
        .onChange(of: app.vault.isLocked) { _, locked in
            if locked { dismiss() }
        }
    }

    private func readFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        problem = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.largestBackup else {
            problem = "That file is too big to be a Hearth backup."
            return
        }
        do {
            fileData = try Data(contentsOf: url)
            fileName = url.lastPathComponent
        } catch {
            problem = "That file couldn't be opened. If it's in iCloud Drive, make sure it has finished downloading."
        }
    }

    private func addBackup() async {
        guard let data = fileData, !passphrase.isEmpty else { return }
        isWorking = true
        problem = nil
        let vault = app.vault
        let secret = passphrase
        do {
            let backup = try await Task.detached(priority: .userInitiated) {
                try vault.importEncrypted(data, passphrase: secret)
            }.value
            restore(backup)
            passphrase = ""
            onAdded("Added \(SettingsFormat.count(backup.conversations.count, "chat")) and \(SettingsFormat.count(backup.userCharacters.count, "character"))")
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
        isWorking = false
    }

    /// Merges the backup into the stores. The backup's preferences come along, but this iPhone keeps its own
    /// protections and model choice (they belong to the device, not the person's chats), its town gossip
    /// choice (a backup must never turn sharing back on), and the name and About you already written here
    /// (the backup's only fill in what's empty).
    private func restore(_ backup: HearthExport) {
        let kept = app.settings
        backup.restore(settings: app.settingsStore, library: app.library, chats: app.chats,
                       memory: app.memory, events: app.events)
        app.settingsStore.update { settings in
            settings.onboardingDone = kept.onboardingDone
            settings.confirmedAdult = kept.confirmedAdult
            settings.preferredEngineID = kept.preferredEngineID
            settings.appLock = kept.appLock
            settings.hideInAppSwitcher = kept.hideInAppSwitcher
            settings.excludeFromBackup = kept.excludeFromBackup
            settings.voiceOverrides = kept.voiceOverrides
            settings.townGossip = kept.townGossip
            if !kept.persona.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.persona.name = kept.persona.name }
            if !kept.persona.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.persona.about = kept.persona.about }
            if kept.persona.pronouns?.isEmpty == false { settings.persona.pronouns = kept.persona.pronouns }
        }
        app.vault.applyBackupExclusion(app.settings.excludeFromBackup)
        app.voice.assignDistinctVoices(for: app.library.allCharacters)
    }
}

/// An icon and a short paragraph at the top of a backup sheet.
private struct BackupExplainer: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            SettingsIcon(symbol: symbol, tint: .hearthSea)
            Text(text)
                .font(HearthFont.callout)
                .foregroundStyle(.hearthText2)
        }
        .padding(.vertical, Spacing.xs)
    }
}
