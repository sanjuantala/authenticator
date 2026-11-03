import AppKit
import SwiftUI
import TotemCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Screen: Equatable { case list, add, edit(String) }

    @Published var hasVault = false
    @Published var locked = true
    @Published var data = VaultData()
    @Published var now = Date()
    @Published var screen: Screen = .list
    @Published var query = ""
    @Published var toast: String?
    @Published var backupStatus = ""
    @Published var syncing = false
    @Published var pendingJoin: Envelope?
    @Published var lastCopiedId: String?
    @Published var update: Updater.Found?
    @Published var updating = false

    private(set) var session: VaultSession?
    private var ticker: Timer?
    private var lockWork: DispatchWorkItem?
    private var syncWork: DispatchWorkItem?
    private var bridge: BridgeServer?
    private var hotKey: HotKey?

    // settings (also bound with @AppStorage in SettingsView)
    private var defaults: UserDefaults { .standard }
    var autoLockMin: Int { defaults.object(forKey: "autoLockMin") as? Int ?? 15 }
    var clipboardSec: Int { defaults.object(forKey: "clipboardSec") as? Int ?? 30 }
    var touchIDEnabled: Bool { defaults.object(forKey: "touchID") as? Bool ?? true }
    var deviceName: String { defaults.string(forKey: "device") ?? (Host.current().localizedName ?? "Mac") }
    var privacyMode: Bool { defaults.bool(forKey: "privacyMode") }
    /// Touch ID is set up (Secure Enclave, or the older Keychain copy from earlier builds).
    var hasStoredKey: Bool { SecureUnlock.isEnrolled || Keychain.get("vault.session") != nil }

    /// Where backups go: the Google Drive folder (easy) or the Drive API (advanced), or nowhere.
    var backupStore: BackupStore? {
        if let folder = FolderBackup.chosen { return FolderBackup(root: folder) }
        if defaults.bool(forKey: "driveEnabled") && GoogleDrive.shared.isConnected { return GoogleDrive.shared }
        return nil
    }
    var backupEnabled: Bool { backupStore != nil }
    var lastBackupAt: Date? { defaults.object(forKey: "lastBackupAt") as? Date }

    var accounts: [Account] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let live = data.live
        guard !q.isEmpty else { return live }
        return live.filter { "\($0.issuer) \($0.label) \($0.domains.joined(separator: " "))".lowercased().contains(q) }
    }

    // MARK: lifecycle

    func bootstrap() {
        hasVault = FileManager.default.fileExists(atPath: Paths.vault.path)
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.now = Date() }
        }
        bridge = BridgeServer { req in await AppModel.shared.handleBridge(req) }
        bridge?.start()
        applyHotKey()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.lock() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in AppModel.shared.lock() }
        }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.syncBackup() }
        }
    }

    func shutdown() { bridge?.stop() }

    // MARK: updates

    /// Looks for a newer version: a zip in Downloads first, then GitHub (at most once an hour unless forced).
    func checkForUpdate(force: Bool = false) {
        guard !updating else { return }
        let last = defaults.object(forKey: "lastOnlineUpdateCheck") as? Date ?? .distantPast
        let askOnline = force || Date().timeIntervalSince(last) > 3600
        Task.detached(priority: .utility) {
            var found = Updater.findDownloaded()
            if found == nil, askOnline {
                await MainActor.run { UserDefaults.standard.set(Date(), forKey: "lastOnlineUpdateCheck") }
                if let v = await Updater.latestOnline(), Updater.isNewer(v, than: Updater.current) {
                    found = Updater.Found(zip: nil, version: v)
                }
            }
            let result = found
            await MainActor.run {
                if result != nil || askOnline { AppModel.shared.update = result }
            }
        }
    }

    func installUpdate(_ zip: URL? = nil) {
        guard !updating else { return }
        let chosen = zip ?? update?.zip
        updating = true
        say(chosen == nil ? "Downloading the update…" : "Installing…")
        Task {
            do {
                let file: URL
                if let chosen { file = chosen } else { file = try await Updater.downloadLatest() }
                try Updater.install(file)
                say("Installing… Totem restarts by itself in about a minute.")
            } catch {
                updating = false
                say("Couldn't update: \(error.localizedDescription)")
            }
        }
    }

    // MARK: vault file

    private func readEnvelope() -> Envelope? {
        guard let d = try? Data(contentsOf: Paths.vault) else { return nil }
        return try? Vault.decodeEnvelope(d)
    }

    private func writeEnvelope(_ env: Envelope) throws {
        try Vault.encodeEnvelope(env).write(to: Paths.vault, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.vault.path)
        hasVault = true
    }

    private func backupCurrentFile() {
        guard FileManager.default.fileExists(atPath: Paths.vault.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.copyItem(at: Paths.vault, to: Paths.support.appendingPathComponent("vault.before-\(stamp).json"))
    }

    private func persist(sync: Bool = true) throws {
        guard let session else { throw TotemError.message("Totem is locked") }
        try writeEnvelope(try Vault.seal(data, session: session, device: deviceName))
        if sync { scheduleSync() }
    }

    // MARK: lock / unlock

    func create(password: String) throws {
        guard password.count >= 8 else { throw TotemError.message("Use at least 8 characters") }
        let s = Vault.createSession(password: password)
        session = s
        data = VaultData()
        try persist()
        didUnlock(s)
    }

    func unlock(password: String) throws {
        guard let env = readEnvelope() else { throw TotemError.message("No vault found") }
        let s = try Vault.session(password: password, for: env)
        data = try Vault.open(env, session: s)
        session = s
        didUnlock(s)
        scheduleSync()
    }

    /// Touch ID (or Mac password) → Secure Enclave releases the key → open vault.
    @discardableResult
    func unlockWithTouchID(reason: String = "unlock your authenticator codes") async -> Bool {
        guard let env = readEnvelope() else { return false }
        var found: VaultSession?
        if SecureUnlock.isEnrolled {
            found = await SecureUnlock.unlock(reason: reason)
        } else if let raw = Keychain.get("vault.session"), await Biometrics.confirm(reason) {
            found = try? JSONDecoder().decode(VaultSession.self, from: raw) // older builds; upgraded on success
        }
        guard let s = found else { return false }
        do {
            data = try Vault.open(env, session: s)
            session = s
            didUnlock(s)
            scheduleSync()
            return true
        } catch {
            SecureUnlock.remove(); Keychain.delete("vault.session") // password changed elsewhere: ask for it once
            say("Your password changed on another device. Enter it once.")
            return false
        }
    }

    private func didUnlock(_ s: VaultSession) {
        locked = false
        hasVault = true
        if touchIDEnabled { storeTouchID(s) }
        touch()
    }

    func lock() {
        session = nil
        data = VaultData()
        locked = true
        screen = .list
        query = ""
        lockWork?.cancel()
        QuickPanel.shared.close()
    }

    /// Reset the auto-lock countdown on activity.
    func touch() {
        lockWork?.cancel()
        guard autoLockMin > 0 else { return }
        let work = DispatchWorkItem { Task { @MainActor in AppModel.shared.lock() } }
        lockWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(autoLockMin * 60), execute: work)
    }

    func setTouchID(_ on: Bool) {
        defaults.set(on, forKey: "touchID")
        if !on { SecureUnlock.remove(); Keychain.delete("vault.session") }
        else if let s = session { storeTouchID(s) }
    }

    /// Prefer the Secure Enclave; only Macs without one fall back to a Keychain copy.
    private func storeTouchID(_ s: VaultSession) {
        if SecureUnlock.enroll(s) {
            Keychain.delete("vault.session")
        } else if let raw = try? JSONEncoder().encode(s) {
            Keychain.set(raw, for: "vault.session")
        }
    }

    func changePassword(current: String, new: String) async throws {
        guard let env = readEnvelope() else { return }
        _ = try Vault.session(password: current, for: env)
        guard new.count >= 8 else { throw TotemError.message("Use at least 8 characters") }
        let s = Vault.createSession(password: new)
        session = s
        data.updatedAt = Vault.nowMs()
        try persist(sync: false)
        didUnlock(s)
        if let store = backupStore { try await store.push(try Vault.seal(data, session: s, device: deviceName), forceBackup: true) }
    }

    /// Merge a vault created elsewhere (different password setup) and adopt its key.
    func joinPending(password: String) async throws {
        guard let env = pendingJoin else { return }
        let s = try Vault.session(password: password, for: env)
        let remote = try Vault.open(env, session: s)
        data = Vault.merge(data, remote)
        session = s
        try persist(sync: false)
        didUnlock(s)
        pendingJoin = nil
        await syncBackup()
    }

    // MARK: codes & edits

    func code(_ a: Account) -> OTPCode? { try? TOTP.code(for: a, at: now) }

    func copy(_ a: Account) {
        guard let c = try? TOTP.code(for: a, at: Date()) else { return }
        let value = c.remaining <= 2 ? c.next : c.code
        Clipboard.copy(value, clearAfter: clipboardSec)
        lastCopiedId = a.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.lastCopiedId == a.id { self?.lastCopiedId = nil }
        }
        touch()
    }

    func currentCode(_ a: Account) -> String? {
        guard let c = try? TOTP.code(for: a, at: Date()) else { return nil }
        return c.remaining <= 2 ? c.next : c.code
    }

    @discardableResult
    func add(_ list: [Account]) throws -> (added: Int, skipped: Int) {
        let r = Vault.add(list, to: &data)
        try persist()
        return r
    }

    func update(_ id: String, _ change: (inout Account) -> Void) throws {
        try Vault.update(id, in: &data, change)
        try persist()
    }

    func delete(_ id: String) throws {
        Vault.delete(id, in: &data)
        try persist()
    }

    func account(_ id: String) -> Account? { data.accounts.first { $0.id == id && !$0.deleted } }

    /// Returns a message for the user. Throws `needsPassword` for Totem backups when no password is given.
    func importText(_ text: String, password: String? = nil) throws -> String {
        switch try Importer.parse(text) {
        case .accounts(let kind, let list, let skippedParse):
            let r = try add(list)
            return "\(kind == "otpauth" ? "Added" : "\(kind): added") \(r.added)" + (r.skipped + skippedParse > 0 ? ", skipped \(r.skipped + skippedParse)" : "")
        case .totemVault(let env):
            guard let password, !password.isEmpty else { throw ImportNeedsPassword() }
            let s = try Vault.session(password: password, for: env)
            let r = try add(try Vault.open(env, session: s).live)
            return "Totem backup: added \(r.added)" + (r.skipped > 0 ? ", skipped \(r.skipped)" : "")
        }
    }
    struct ImportNeedsPassword: Error {}

    func scanScreen() async {
        do {
            let links = try await ScreenQR.scanScreens()
            var added = 0, skipped = 0
            for link in links {
                if case .accounts(_, let list, let s) = try Importer.parse(link) {
                    let r = try add(list); added += r.added; skipped += r.skipped + s
                }
            }
            say(added > 0 ? "Added \(added) account\(added == 1 ? "" : "s") from your screen" : "Already in Totem")
            screen = .list
        } catch {
            say(error.localizedDescription)
        }
    }

    func exportEncrypted() throws -> Data {
        guard let session else { throw TotemError.message("Totem is locked") }
        return try Vault.encodeEnvelope(try Vault.seal(data, session: session, device: deviceName))
    }

    func exportPlain() -> String { Importer.plainExport(data.live) }

    // MARK: Google Drive sync

    func scheduleSync() {
        syncWork?.cancel()
        let w = DispatchWorkItem { Task { @MainActor in await AppModel.shared.syncBackup() } }
        syncWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    /// Merge with the copy in the backup place, then write the merged vault (+ a dated backup) back.
    func syncBackup(forceBackup: Bool = false) async {
        guard let session, let store = backupStore, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            let remote = try await store.pull()
            var remoteData: VaultData?
            if let remote {
                guard session.matches(remote) else {
                    pendingJoin = remote
                    backupStatus = "Your backup uses a different master password. Join it in Settings."
                    return
                }
                remoteData = try Vault.open(remote, session: session)
            }
            let merged = remoteData.map { Vault.merge(data, $0) } ?? data
            if !Vault.same(merged, data) { data = merged; try persist(sync: false) }
            if forceBackup || remoteData == nil || !Vault.same(remoteData!, merged) || !backedUpToday {
                try await store.push(try Vault.seal(merged, session: session, device: deviceName), forceBackup: forceBackup)
            }
            defaults.set(Date(), forKey: "lastBackupAt")
            backupStatus = "Backed up \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            backupStatus = error.localizedDescription
        }
    }

    private var backedUpToday: Bool {
        guard let d = lastBackupAt else { return false }
        return Calendar.current.isDateInToday(d)
    }

    func restoreBackup(_ id: String, password: String?) async throws -> String {
        guard let session else { throw TotemError.message("Totem is locked") }
        guard let store = backupStore else { throw TotemError.message("Backups aren't set up") }
        let env = try await store.download(id)
        let s: VaultSession
        if session.matches(env) { s = session }
        else if let password, !password.isEmpty { s = try Vault.session(password: password, for: env) }
        else { throw TotemError.kdfMismatch }
        let r = try add(try Vault.open(env, session: s).live) // brings back missing accounts, never wipes
        return r.added > 0 ? "Brought back \(r.added) account\(r.added == 1 ? "" : "s")" : "Nothing missing. All accounts are already here."
    }

    // MARK: browser bridge

    func handleBridge(_ raw: Data) async -> Data {
        let reply: [String: Any]
        do {
            guard let req = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw TotemError.message("Bad request") }
            reply = try await bridgeReply(req)
        } catch {
            reply = ["ok": false, "error": error.localizedDescription]
        }
        return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
    }

    private func envJSON(_ env: Envelope?) -> Any {
        guard let env, let d = try? Vault.encodeEnvelope(env, pretty: false),
              let o = try? JSONSerialization.jsonObject(with: d) else { return NSNull() }
        return o
    }

    private func bridgeReply(_ req: [String: Any]) async throws -> [String: Any] {
        switch req["type"] as? String {
        case "status":
            var backup: [String: Any] = ["enabled": backupEnabled]
            if let store = backupStore { backup["provider"] = store.displayName }
            if let at = lastBackupAt { backup["at"] = Int64(at.timeIntervalSince1970 * 1000) }
            return ["ok": true, "running": true, "unlocked": !locked, "hasVault": hasVault, "device": deviceName, "backup": backup]

        case "getVault":
            return ["ok": true, "vault": envJSON(readEnvelope()), "running": true]

        case "putVault":
            guard let obj = req["vault"], let d = try? JSONSerialization.data(withJSONObject: obj) else {
                throw TotemError.message("No vault in request")
            }
            let incoming = try Vault.decodeEnvelope(d)
            let force = req["force"] as? Bool ?? false
            if let session, session.matches(incoming) {
                // unlocked with the same key: merge, never lose either side
                let merged = Vault.merge(data, try Vault.open(incoming, session: session))
                if !Vault.same(merged, data) { data = merged; try persist() }
                return ["ok": true, "merged": true]
            }
            let current = readEnvelope()
            let base = (req["base"] as? NSNumber)?.int64Value
            guard current == nil || force || base == current?.updatedAt else {
                return ["ok": false, "error": "The Mac vault changed meanwhile. Sync again.", "code": "CONFLICT"]
            }
            backupCurrentFile()
            try writeEnvelope(incoming)
            if !locked {
                lock() // new key setup arrived (password changed in the browser)
                say("Password changed in your browser. Unlock with the new one.")
            }
            return ["ok": true]

        case "requestKey":
            if locked {
                guard hasVault else { return ["ok": false, "error": "Create your vault in Totem for Mac first"] }
                guard await unlockWithTouchID(reason: "unlock Totem in your browser") else {
                    return ["ok": false, "error": hasStoredKey ? "Not confirmed on the Mac" : "Unlock Totem for Mac with your password once, then try again"]
                }
            } else if SecureUnlock.isEnrolled {
                guard let s = await SecureUnlock.unlock(reason: "unlock Totem in your browser"), s == session else {
                    return ["ok": false, "error": "Not confirmed on the Mac"]
                }
            } else {
                guard await Biometrics.confirm("unlock Totem in your browser") else { return ["ok": false, "error": "Not confirmed on the Mac"] }
            }
            guard let session else { return ["ok": false, "error": "Totem is locked"] }
            return ["ok": true, "session": ["key": session.key, "salt": session.salt, "iterations": session.iterations],
                    "vault": envJSON(readEnvelope())]

        default:
            throw TotemError.message("Unknown request")
        }
    }
}
