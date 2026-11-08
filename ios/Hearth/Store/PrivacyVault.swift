// Privacy controls: App Lock (Face ID, Touch ID or passcode), the app-switcher shield, iCloud backup
// exclusion, "Delete everything", encrypted backups (.hearth files) and the privacy center's numbers.

import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Observation

enum PrivacyVaultError: LocalizedError, Equatable {
    case emptyPassphrase
    case notAHearthBackup
    case wrongPassphrase
    case damaged
    case newerVersion
    case couldNotEncrypt
    case someFilesRemain(Int)

    var errorDescription: String? {
        switch self {
        case .emptyPassphrase: return "Please choose a passphrase."
        case .notAHearthBackup: return "This isn't a Hearth backup file."
        case .wrongPassphrase: return "That passphrase doesn't open this backup. Check it and try again."
        case .damaged: return "This backup file is damaged and can't be read."
        case .newerVersion: return "This backup was made by a newer version of Hearth. Update the app, then try again."
        case .couldNotEncrypt: return "The backup couldn't be locked. Please try again."
        case .someFilesRemain(let count): return "Almost everything was deleted, but \(count) item(s) couldn't be removed. Please try again."
        }
    }
}

@MainActor @Observable final class PrivacyVault {
    /// True while App Lock covers the app until Face ID or the passcode opens it.
    private(set) var isLocked = false
    /// The shield shown over the app while it isn't active (the app sets this on scene phase changes).
    var shieldVisible = false

    /// UserDefaults key the model downloader adds downloaded bytes to.
    nonisolated static let downloadedBytesKey = "hearth.network.downloadedBytes"

    private let root: URL
    private let defaults: UserDefaults
    /// The app's own vault also clears temporary files and caches when wiping (test vaults don't).
    private let isAppVault: Bool
    @ObservationIgnored private var isAuthenticating = false
    /// True while the lock only stands in for settings that couldn't be read yet (see `lockUntilSettingsAreRead`).
    @ObservationIgnored private var lockedUntilSettingsRead = false

    /// `root: nil` means the app's real folder (HearthPaths.root).
    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? HearthPaths.root
        self.defaults = defaults
        isAppVault = root == nil
    }

    // MARK: App Lock

    /// Locks when App Lock is on. Call it when the app goes to the background (not on .inactive:
    /// the Face ID prompt itself makes the app inactive) and once at launch, before the first frame.
    func lockIfNeeded(appLockEnabled: Bool) {
        if appLockEnabled { isLocked = true }
    }

    /// The settings file couldn't be opened at launch (iOS started Hearth in the background while the iPhone
    /// was locked, for a model download), so nobody knows yet whether App Lock is on: stay locked until it's known.
    func lockUntilSettingsAreRead() {
        isLocked = true
        lockedUntilSettingsRead = true
    }

    /// The settings could be read at last: keep the stand-in lock when App Lock is on, lift it when it's off.
    /// (Already unlocked with Face ID or the passcode: nothing to do.)
    func settingsWereRead(appLockEnabled: Bool) {
        guard lockedUntilSettingsRead else { return }
        lockedUntilSettingsRead = false
        isLocked = appLockEnabled
    }

    /// Asks for Face ID, Touch ID or the passcode and returns whether the app is now unlocked. If the
    /// iPhone has no passcode at all there is nothing to check against, so it just unlocks.
    func unlock(reason: String) async -> Bool {
        guard isLocked else { return true }
        guard !isAuthenticating else { return false }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
            if problem?.code == LAError.Code.passcodeNotSet.rawValue {
                isLocked = false
                lockedUntilSettingsRead = false
                return true
            }
            HearthLog.error("vault", "can't ask for Face ID or the passcode (code \(problem?.code ?? 0))")
            return false
        }
        let prompt = reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unlock your chats" : reason
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: prompt)
            if ok {
                isLocked = false
                lockedUntilSettingsRead = false
            }
            return ok
        } catch {
            HearthLog.info("vault", "unlock didn't go through (code \((error as NSError).code))")
            return false
        }
    }

    /// What App Lock asks for on this iPhone: "Face ID", "Touch ID", "Optic ID" or "Passcode".
    var unlockMethodName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    // MARK: Backups and deleting

    /// Keeps the whole Hearth folder out of iCloud and computer backups (or lets it back in). The AI model
    /// stays out either way: it's large and can be downloaded again. (Pie's own files live in Caches, which
    /// is never backed up.)
    func applyBackupExclusion(_ excluded: Bool) {
        HearthPaths.setExcludedFromBackup(excluded, at: root)
        for name in ["models"] {
            let url = root.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { HearthPaths.setExcludedFromBackup(true, at: url) }
        }
    }

    /// Deletes every chat, character, memory, photo, picture, voice note, setting and resume cache (and
    /// the AI model when `includeModels`), plus Hearth's "hearth." preferences. The stores forget what they
    /// hold in memory first, so nothing gets written back. Stop any reply in progress before calling this.
    func wipeEverything(includeModels: Bool) async throws {
        StoreRegistry.forgetEverything(under: root)
        let root = root
        let alsoAppFolders = isAppVault
        let failures = await Task.detached(priority: .userInitiated) {
            Self.deleteFiles(root: root, includeModels: includeModels, alsoAppFolders: alsoAppFolders)
        }.value
        // The settings start over as well, and the Hearth folder itself stays: give it the default backup
        // choice now, or it keeps the old one (backed up) until the next launch.
        applyBackupExclusion(AppSettings().excludeFromBackup)
        // The download count stays while the downloaded model is still on the phone.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hearth.") {
            if key == Self.downloadedBytesKey && !includeModels { continue }
            defaults.removeObject(forKey: key)
        }
        HearthLog.info("vault", "deleted everything (models \(includeModels ? "deleted" : "kept"), \(failures) left)")
        if failures > 0 { throw PrivacyVaultError.someFilesRemain(failures) }
    }

    /// Returns how many items under `root` couldn't be deleted.
    nonisolated private static func deleteFiles(root: URL, includeModels: Bool, alsoAppFolders: Bool) -> Int {
        let fileManager = FileManager.default
        var failures = 0
        for url in (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if !includeModels && url.lastPathComponent == "models" { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                failures += 1
            }
        }
        guard alsoAppFolders else { return failures }
        // Best effort: temporary files, caches (app-switcher snapshots live there), the console log, and
        // model files copied in over USB.
        var extras: [URL] = []
        for folder in [fileManager.temporaryDirectory] + fileManager.urls(for: .cachesDirectory, in: .userDomainMask) {
            extras += (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        // Pie's home stays, because the running server needs its compiled copy of Hearth's inferlet for every
        // reply. But its KV disk tier (cache/kv, where Pie may spill pages of chats under memory pressure) is
        // conversation-derived, so its contents go. Pie computes anything it then can't find again.
        let pieHome = HearthPaths.pieHome.standardizedFileURL.path
        extras.removeAll { $0.standardizedFileURL.path == pieHome }
        let kvTier = HearthPaths.pieHome.appendingPathComponent("cache/kv", isDirectory: true)
        extras += (try? fileManager.contentsOfDirectory(at: kvTier, includingPropertiesForKeys: nil)) ?? []
        for url in (try? fileManager.contentsOfDirectory(at: HearthPaths.documents, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent.lowercased()
            if name == "hearth-console.log" || (includeModels && name.hasSuffix(".zt")) { extras.append(url) }
        }
        for url in extras { try? fileManager.removeItem(at: url) }
        return failures
    }

    // MARK: Encrypted backups

    nonisolated private static let magic = Data("HEARTH1".utf8)
    nonisolated private static let saltLength = 16
    nonisolated private static let rounds: UInt32 = 600_000

    /// A .hearth file: "HEARTH1", a 16-byte random salt, then AES-GCM (nonce + ciphertext + tag) of the
    /// export's JSON. The key comes from the passphrase: PBKDF2-SHA256 with 600,000 rounds (CommonCrypto,
    /// so guessing is slow), then HKDF-SHA256 with the same salt. Takes a moment; fine to call off the main thread.
    nonisolated func exportEncrypted(_ payload: HearthExport, passphrase: String) throws -> Data {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try Self.key(from: passphrase, salt: salt)
        let json = try StoreJSON.encode(payload)
        guard let sealed = try? AES.GCM.seal(json, using: key), let combined = sealed.combined else {
            throw PrivacyVaultError.couldNotEncrypt
        }
        return Self.magic + salt + combined
    }

    nonisolated func importEncrypted(_ data: Data, passphrase: String) throws -> HearthExport {
        let start = data.startIndex
        let saltStart = start + Self.magic.count
        let boxStart = saltStart + Self.saltLength
        // The sealed part is at least a 12-byte nonce and a 16-byte tag.
        guard data.count > Self.magic.count + Self.saltLength + 28, data[start..<saltStart] == Self.magic else {
            throw PrivacyVaultError.notAHearthBackup
        }
        let key = try Self.key(from: passphrase, salt: Data(data[saltStart..<boxStart]))
        let json: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data[boxStart...])
            json = try AES.GCM.open(box, using: key)
        } catch {
            // AES-GCM can't tell a wrong passphrase from a changed file; both fail here.
            throw PrivacyVaultError.wrongPassphrase
        }
        if let probe = try? JSONDecoder().decode(ExportVersion.self, from: json), probe.version > HearthExport.currentVersion {
            throw PrivacyVaultError.newerVersion
        }
        guard let export = try? StoreJSON.decoder().decode(HearthExport.self, from: json) else {
            throw PrivacyVaultError.damaged
        }
        return export
    }

    nonisolated private static func key(from passphrase: String, salt: Data) throws -> SymmetricKey {
        // The same passphrase typed on another keyboard can use different Unicode forms: normalize first.
        let password = passphrase.precomposedStringWithCanonicalMapping
        guard !password.isEmpty else { throw PrivacyVaultError.emptyPassphrase }
        let saltBytes = [UInt8](salt)
        var stretched = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                          saltBytes, saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                          rounds, &stretched, stretched.count)
        guard status == Int32(kCCSuccess) else { throw PrivacyVaultError.couldNotEncrypt }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: stretched), salt: saltBytes,
                                      info: Data("hearth-backup-v1".utf8), outputByteCount: 32)
    }

    // MARK: Privacy center numbers

    /// Bytes Hearth has downloaded. The only download is the AI model, counted by the model downloader.
    var networkDownloadedBytes: Int64 {
        Int64(defaults.integer(forKey: Self.downloadedBytesKey))
    }

    /// Hearth never uploads anything. Shown next to the download count.
    var networkUploadedBytes: Int64 { 0 }

    /// For the model downloader: adds to the downloaded-bytes count.
    nonisolated static func recordDownloadedBytes(_ bytes: Int64, defaults: UserDefaults = .standard) {
        let total = Int64(defaults.integer(forKey: downloadedBytesKey)) + max(0, bytes)
        defaults.set(total, forKey: downloadedBytesKey)
    }

    /// Space Hearth uses on this iPhone, by kind, for the privacy center.
    func storageBreakdown() -> [(label: String, bytes: Int64)] {
        let parts = [
            ("Chats", "chats"),
            ("Your characters", "characters"),
            ("Photos, pictures and voice notes", "media"),
            ("Memories and settings", "state"),
            ("AI models", "models"),
        ]
        return parts.map { part in
            (label: part.0, bytes: HearthPaths.size(of: root.appendingPathComponent(part.1, isDirectory: true)))
        }
    }
}

/// Just the version number of an export, read before the rest.
private struct ExportVersion: Decodable {
    var version: Int
}
