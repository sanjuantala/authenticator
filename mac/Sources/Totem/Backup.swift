import Foundation
import TotemCore

/// One backup copy, from any backup place.
struct BackupItem: Identifiable {
    let id: String
    let name: String
    let created: Date
}

/// Where encrypted vault copies go. Two kinds: a synced folder (easy) or the Google Drive API (advanced).
protocol BackupStore {
    var displayName: String { get }
    func pull() async throws -> Envelope?
    func push(_ env: Envelope, forceBackup: Bool) async throws
    func list() async throws -> [BackupItem]
    func download(_ id: String) async throws -> Envelope
}

/// The easy way: write into the Google Drive folder that "Google Drive for desktop" keeps in sync.
/// No Google Cloud project and no sign-in inside Totem: Google's own app uploads the (encrypted) files.
/// Works the same with iCloud Drive, Dropbox or any synced folder.
///
///   <folder>/Totem/totem-vault.json                   ← live vault, merged on every sync
///   <folder>/Totem/backups/totem-backup-YYYY-MM-DD.json ← one per day, newest 30 kept
struct FolderBackup: BackupStore {
    let root: URL
    private var dir: URL { root.appendingPathComponent("Totem", isDirectory: true) }
    private var backupsDir: URL { dir.appendingPathComponent("backups", isDirectory: true) }
    private var live: URL { dir.appendingPathComponent("totem-vault.json") }
    static let keep = 30

    var displayName: String { FolderBackup.describe(root) }

    // MARK: finding the folder

    static var chosen: URL? {
        guard let p = UserDefaults.standard.string(forKey: "backupFolder"), !p.isEmpty else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    /// Google Drive for desktop keeps "My Drive" under ~/Library/CloudStorage/GoogleDrive-<email>/.
    static var detectedGoogleDrive: URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let accounts = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for acc in accounts where acc.lastPathComponent.hasPrefix("GoogleDrive-") {
            let kids = (try? FileManager.default.contentsOfDirectory(at: acc, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            if let my = kids.first(where: { $0.lastPathComponent == "My Drive" }) { return my }
            // other languages name "My Drive" differently: take the first normal folder
            if let my = kids.first(where: { !$0.lastPathComponent.hasPrefix(".") && !["Shared drives", "Other computers"].contains($0.lastPathComponent) }) {
                return my
            }
        }
        return nil
    }

    static var iCloudDrive: URL? {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func describe(_ url: URL) -> String {
        let p = url.path
        if p.contains("/CloudStorage/GoogleDrive-") {
            let email = p.components(separatedBy: "/CloudStorage/GoogleDrive-").last?.components(separatedBy: "/").first ?? ""
            return email.isEmpty ? "Google Drive" : "Google Drive (\(email))"
        }
        if p.contains("com~apple~CloudDocs") { return "iCloud Drive" }
        if p.contains("/CloudStorage/Dropbox") || p.contains("/Dropbox") { return "Dropbox" }
        if p.contains("/CloudStorage/OneDrive") { return "OneDrive" }
        return url.lastPathComponent
    }

    // MARK: BackupStore

    func pull() async throws -> Envelope? {
        guard FileManager.default.fileExists(atPath: live.path) else { return nil }
        return try Vault.decodeEnvelope(try Data(contentsOf: live))
    }

    func push(_ env: Envelope, forceBackup: Bool) async throws {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw TotemError.message("The backup folder isn't available. Is Google Drive running and signed in?")
        }
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let content = try Vault.encodeEnvelope(env)
        try content.write(to: live, options: .atomic)
        let iso = ISO8601DateFormatter().string(from: Date())
        let name = forceBackup
            ? "totem-backup-\(iso.replacingOccurrences(of: ":", with: "-").prefix(19)).json"
            : "totem-backup-\(iso.prefix(10)).json"
        try content.write(to: backupsDir.appendingPathComponent(name), options: .atomic)
        for old in files().dropFirst(FolderBackup.keep) { try? FileManager.default.removeItem(atPath: old.id) }
    }

    func files() -> [BackupItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupsDir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.map {
            BackupItem(id: $0.path, name: $0.lastPathComponent,
                       created: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast)
        }.sorted { $0.created > $1.created }
    }

    func list() async throws -> [BackupItem] { files() }

    func download(_ id: String) async throws -> Envelope {
        try Vault.decodeEnvelope(try Data(contentsOf: URL(fileURLWithPath: id)))
    }
}

/// The advanced way (no Google Drive app): Totem talks to the Drive API with your own OAuth client.
extension GoogleDrive: BackupStore {
    var displayName: String { "Google Drive" }
    func list() async throws -> [BackupItem] { try await backups() }
}
