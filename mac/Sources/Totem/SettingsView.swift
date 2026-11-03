import AppKit
import ServiceManagement
import SwiftUI
import TotemCore
import UniformTypeIdentifiers

enum BrowserBridge {
    static let hostName = "com.totem.bridge"
    static let defaultExtensionId = "mdbaiajlghmojiingboeggblieidhpen" // fixed by the "key" in the extension manifest

    static var extensionId: String {
        let v = UserDefaults.standard.string(forKey: "extensionId") ?? ""
        return v.isEmpty ? defaultExtensionId : v
    }

    static let browsers: [(name: String, dir: String)] = [
        ("Chrome", "Google/Chrome"), ("Brave", "BraveSoftware/Brave-Browser"), ("Edge", "Microsoft Edge"),
        ("Arc", "Arc/User Data"), ("Chromium", "Chromium"), ("Vivaldi", "Vivaldi"),
    ]

    static var bridgeExecutable: URL {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("TotemBridge")
    }

    /// Writes the native-messaging host manifest for every installed Chromium browser.
    @discardableResult
    static func install() throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: bridgeExecutable.path) else {
            throw TotemError.message("TotemBridge not found next to the app (\(bridgeExecutable.path)). Build with scripts/build-app.sh.")
        }
        let manifest: [String: Any] = [
            "name": hostName, "description": "Totem for Mac bridge", "path": bridgeExecutable.path, "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionId)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .withoutEscapingSlashes])
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        var done: [String] = []
        for b in browsers {
            let browserDir = base.appendingPathComponent(b.dir)
            guard FileManager.default.fileExists(atPath: browserDir.path) else { continue }
            let hosts = browserDir.appendingPathComponent("NativeMessagingHosts")
            try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent("\(hostName).json"), options: .atomic)
            done.append(b.name)
        }
        return done
    }

    static var installedIn: [String] {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return browsers.filter {
            FileManager.default.fileExists(atPath: base.appendingPathComponent("\($0.dir)/NativeMessagingHosts/\(hostName).json").path)
        }.map(\.name)
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("autoLockMin") private var autoLockMin = 15
    @AppStorage("clipboardSec") private var clipboardSec = 30
    @AppStorage("hotkey") private var hotkey = HotKey.presets[0].label
    @AppStorage("driveClientId") private var clientId = ""
    @AppStorage("driveClientSecret") private var clientSecret = ""
    @AppStorage("driveEnabled") private var driveEnabled = false
    @AppStorage("extensionId") private var extensionId = ""
    @AppStorage("privacyMode") private var privacyMode = false
    @AppStorage("backupFolder") private var backupFolder = ""
    @Local private var touchID = UserDefaults.standard.object(forKey: "touchID") as? Bool ?? true
    @Local private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Local private var bridgeNote = BrowserBridge.installedIn.isEmpty ? "Not connected yet" : "Connected: \(BrowserBridge.installedIn.joined(separator: ", "))"
    @Local private var oldPw = ""
    @Local private var newPw = ""
    @Local private var joinPw = ""
    @Local private var backups: [BackupItem] = []
    @Local private var busy = false
    @Local private var note = ""
    @Local private var refresh = 0

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            sync.tabItem { Label("Backup & Browser", systemImage: "arrow.triangle.2.circlepath") }
            importExport.tabItem { Label("Import & Export", systemImage: "square.and.arrow.down.on.square") }
        }
        .frame(width: 540, height: 520)
        .tint(Theme.brass)
        .overlay(alignment: .bottom) { if !note.isEmpty { ToastView(text: note) } }
    }

    private func pickUpdate() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let v = Updater.version(in: url) else { flash("That isn't a Totem update file"); return }
        model.update = Updater.Found(zip: url, version: v)
        model.installUpdate(url)
    }

    private func flash(_ s: String) {
        note = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if note == s { note = "" } }
    }

    // MARK: general

    private var general: some View {
        Form {
            Section("Security") {
                Picker("Auto-lock after", selection: $autoLockMin) {
                    Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("1 hour").tag(60); Text("4 hours").tag(240); Text("Never").tag(0)
                }
                Picker("Clear copied code after", selection: $clipboardSec) {
                    Text("15 seconds").tag(15); Text("30 seconds").tag(30); Text("60 seconds").tag(60); Text("Never").tag(0)
                }
                Toggle(Biometrics.hasTouchID ? "Unlock with Touch ID" : "Unlock with Mac password / Apple Watch", isOn: $touchID)
                    .onChange(of: touchID) { model.setTouchID(touchID) }
                Toggle("Hide codes until hovered", isOn: $privacyMode)
                Text(SecureUnlock.isEnrolled
                     ? "Touch ID is enforced by your Mac's Secure Enclave chip. Totem also locks when your Mac sleeps or the screen locks."
                     : "Totem locks when your Mac sleeps or the screen locks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quick search") {
                Picker("Global shortcut", selection: $hotkey) {
                    ForEach(HotKey.presets) { Text($0.label).tag($0.label) }
                }
                .onChange(of: hotkey) { model.applyHotKey() }
                Toggle("Open Totem at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) {
                        do { if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { flash("Couldn't change login item: \(error.localizedDescription)") }
                    }
            }
            Section("Updates") {
                LabeledContent("Version", value: Updater.current)
                if model.updating {
                    Text("Installing… Totem restarts by itself when it's done.").foregroundStyle(.secondary)
                } else if let u = model.update {
                    Button("Install update \(u.version)") { model.installUpdate() }.buttonStyle(.borderedProminent)
                    Text("Found \(u.zip.lastPathComponent) in Downloads.").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Check Downloads for an update") {
                            model.checkForUpdate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if model.update == nil { flash("No newer Totem zip in Downloads") } }
                        }
                        Button("Install from a file…") { pickUpdate() }
                    }
                }
                Text("Download the newest ZIP from github.com/sanjuantala/authenticator, then click Install update. The browser extension updates itself too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Change master password") {
                SecureField("Current password", text: $oldPw)
                SecureField("New password", text: $newPw)
                StrengthMeter(password: newPw)
                Button("Change password") {
                    Task {
                        guard PasswordStrength.score(newPw).score >= 2 else { flash(PasswordStrength.score(newPw).hint); return }
                        do { try await model.changePassword(current: oldPw, new: newPw); oldPw = ""; newPw = ""
                            flash("Changed. Your browser will ask for the new password once.") }
                        catch { flash(error.localizedDescription) }
                    }
                }.disabled(model.locked || oldPw.isEmpty || newPw.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: sync

    private var sync: some View {
        Form {
            Section("Browser extension") {
                LabeledContent("Status", value: bridgeNote)
                TextField("Extension ID", text: $extensionId, prompt: Text(BrowserBridge.defaultExtensionId))
                    .font(.system(.body, design: .monospaced))
                Button("Connect browsers") {
                    do {
                        let done = try BrowserBridge.install()
                        bridgeNote = done.isEmpty ? "No Chromium browsers found" : "Connected: \(done.joined(separator: ", "))"
                        flash(done.isEmpty ? "No Chrome/Brave/Edge/Arc found" : "Done. Reload the extension once.")
                    } catch { flash(error.localizedDescription) }
                }
                Text("The extension and this app share one encrypted vault through a private local channel. Nothing goes over the network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup") {
                if let folder = FolderBackup.chosen {
                    LabeledContent("Saving to", value: FolderBackup.describe(folder))
                    LabeledContent("Last backup", value: model.backupStatus.isEmpty
                                   ? (model.lastBackupAt?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet") : model.backupStatus)
                    HStack {
                        Button("Back up now") { Task { await model.syncBackup(forceBackup: true); flash(model.backupStatus) } }
                        Button("Restore…") { Task { await loadBackups() } }
                        Spacer()
                        Button("Turn off") { backupFolder = ""; model.backupStatus = "" }
                    }.disabled(model.locked)
                    backupList
                    Text("Every copy is encrypted with your master password. Google's Drive app uploads it; Google only ever sees scrambled data.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let drive = FolderBackup.detectedGoogleDrive {
                    Text("Back up to Google Drive with one click. Totem saves an encrypted copy into your Drive folder and the Google Drive app uploads it.")
                        .font(.callout)
                    Button("Back up to \(FolderBackup.describe(drive))") { useFolder(drive) }
                        .buttonStyle(.borderedProminent).disabled(model.locked)
                } else {
                    Text("To back up to Google Drive, install Google Drive for desktop and sign in. Totem finds it automatically, with nothing else to set up.")
                        .font(.callout)
                    HStack {
                        Button("Get Google Drive for desktop") { NSWorkspace.shared.open(URL(string: "https://www.google.com/drive/download/")!) }
                            .buttonStyle(.borderedProminent)
                        Button("Check again") { refresh += 1 }
                    }
                    if let icloud = FolderBackup.iCloudDrive {
                        Button("Use iCloud Drive instead") { useFolder(icloud) }.disabled(model.locked)
                    }
                }
                if FolderBackup.chosen == nil {
                    Button("Choose another folder…") { chooseFolder() }.buttonStyle(.link).disabled(model.locked)
                }
            }
            Section {
                DisclosureGroup("Advanced: Google Drive without the Drive app") {
                    if GoogleDrive.shared.isConnected {
                        Toggle("Back up through the Google Drive API", isOn: $driveEnabled)
                        HStack {
                            Button("Back up now") { Task { await model.syncBackup(forceBackup: true); flash(model.backupStatus) } }
                            Spacer()
                            Button("Disconnect", role: .destructive) { GoogleDrive.shared.disconnect(); driveEnabled = false; model.backupStatus = "" }
                        }.disabled(model.locked)
                        if FolderBackup.chosen == nil { backupList }
                    } else {
                        Text("Only needed if you can't install Google Drive for desktop. Needs your own Google Cloud OAuth client (see README).")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("OAuth client ID", text: $clientId, prompt: Text("xxxx.apps.googleusercontent.com"))
                        SecureField("OAuth client secret", text: $clientSecret)
                        Button(busy ? "Waiting for Google…" : "Connect") {
                            Task {
                                busy = true
                                do {
                                    try await GoogleDrive.shared.connect()
                                    driveEnabled = true
                                    await model.syncBackup(forceBackup: true)
                                    flash("Google Drive connected")
                                } catch { flash(error.localizedDescription) }
                                busy = false
                            }
                        }.disabled(busy || clientId.isEmpty || clientSecret.isEmpty)
                    }
                }
            }
            if model.pendingJoin != nil {
                Section("Another vault was found") {
                    Text("Your backup uses a different master password. Enter it to merge both into one vault.")
                        .font(.caption)
                    SecureField("That vault's password", text: $joinPw)
                    Button("Join and merge") {
                        Task {
                            do { try await model.joinPending(password: joinPw); joinPw = ""; flash("Merged. One vault everywhere.") }
                            catch { flash(error.localizedDescription) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var backupList: some View {
        ForEach(backups) { b in
            HStack {
                Text(b.created.formatted(date: .abbreviated, time: .shortened)).font(.callout)
                Spacer()
                Button("Restore") { Task { await restore(b) } }.buttonStyle(.link)
            }
        }
    }

    private func useFolder(_ url: URL) {
        backupFolder = url.path
        Task {
            await model.syncBackup(forceBackup: true)
            flash(model.backupStatus.hasPrefix("Backed up") ? "Backups are on. Saved to \(FolderBackup.describe(url))." : model.backupStatus)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back up here"
        panel.message = "Choose a folder that syncs to the cloud, like Google Drive, iCloud Drive or Dropbox."
        if panel.runModal() == .OK, let url = panel.url { useFolder(url) }
    }

    private func loadBackups() async {
        guard let store = model.backupStore else { return }
        do { backups = try await store.list(); if backups.isEmpty { flash("No backups yet") } }
        catch { flash(error.localizedDescription) }
    }

    private func restore(_ b: BackupItem) async {
        do { flash(try await model.restoreBackup(b.id, password: nil)) }
        catch TotemError.kdfMismatch {
            let alert = NSAlert()
            alert.messageText = "This backup used an older password. Enter it:"
            let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = f
            alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { flash(try await model.restoreBackup(b.id, password: f.stringValue)) } catch { flash(error.localizedDescription) }
        } catch { flash(error.localizedDescription) }
    }

    // MARK: import / export

    private var importExport: some View {
        Form {
            Section("Import") {
                Text("Google Authenticator (scan its “Transfer accounts” QR with Scan screen), Aegis, 2FAS, Bitwarden, otpauth links, or a Totem backup. Duplicates are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Choose file…") { importFile() }.disabled(model.locked)
            }
            Section("Export") {
                Button("Encrypted backup (.totem)…") { export(encrypted: true) }.disabled(model.locked)
                Button("Plain otpauth links (.txt)…") { export(encrypted: false) }.disabled(model.locked)
                Text("The encrypted backup opens with your master password in Totem on any device. The plain file contains raw secrets, so delete it after use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Files") {
                LabeledContent("Vault", value: Paths.vault.path).font(.caption).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Paths.vault]) }
            }
        }
        .formStyle(.grouped)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        do { flash(try model.importText(text)) }
        catch is AppModel.ImportNeedsPassword {
            let alert = NSAlert()
            alert.messageText = "Password for this Totem backup"
            let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = f
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { flash(try model.importText(text, password: f.stringValue)) } catch { flash(error.localizedDescription) }
        } catch { flash(error.localizedDescription) }
    }

    private func export(encrypted: Bool) {
        if !encrypted {
            let a = NSAlert()
            a.messageText = "Export unencrypted secrets?"
            a.informativeText = "Anyone with this file can generate your 2FA codes."
            a.addButton(withTitle: "Export"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = encrypted ? "totem-backup-\(day).totem" : "totem-plain-\(day).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = encrypted ? try model.exportEncrypted() : Data(model.exportPlain().utf8)
            try content.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            flash("Saved")
        } catch { flash(error.localizedDescription) }
    }
}
