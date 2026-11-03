import AppKit
import SwiftUI
import TotemCore
import UniformTypeIdentifiers

/// The menu bar window.
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if !model.hasVault { CreateView() }
                else if model.locked { LockView() }
                else {
                    switch model.screen {
                    case .list: ListView(openSettings: openSettings)
                    case .add: AddView()
                    case .edit(let id): EditView(id: id)
                    }
                }
            }
            if let t = model.toast { ToastView(text: t) }
            // ⌘Q quits from any screen
            Button("") { NSApp.terminate(nil) }.keyboardShortcut("q").opacity(0).frame(width: 0, height: 0)
        }
        .frame(width: 360, height: 500)
        .background(Theme.ink)
        .foregroundStyle(Theme.bone)
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }
}

struct QuitButton: View {
    var body: some View {
        Button { NSApp.terminate(nil) } label: {
            Label("Quit Totem", systemImage: "power").font(.system(size: 11.5))
        }
        .buttonStyle(.plain).foregroundStyle(Theme.mist).help("Quit Totem (⌘Q)")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Theme.mist).help(help)
    }
}

// MARK: - create / lock

struct CreateView: View {
    @EnvironmentObject var model: AppModel
    @Local private var pw = ""
    @Local private var pw2 = ""
    @Local private var error = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 28)
            MarkHalo()
            Text("Create your vault").font(.system(size: 20, weight: .semibold)).padding(.top, 18)
            Text("Choose a master password. It never leaves this Mac and can't be recovered, so keep it somewhere safe.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.mist).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6).padding(.horizontal, 6)
            VStack(spacing: 10) {
                SecureField("Master password", text: $pw).totemField()
                SecureField("Repeat password", text: $pw2).totemField().onSubmit(create)
                StrengthMeter(password: pw).frame(minHeight: 16)
                Button("Create vault", action: create).buttonStyle(PrimaryButtonStyle())
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Theme.rose).multilineTextAlignment(.center) }
            }
            .padding(.top, 22)
            Spacer()
            HStack { Spacer(); QuitButton() }
        }
        .padding(24)
    }

    private func create() {
        let r = PasswordStrength.score(pw)
        guard r.score >= 2 else { error = r.hint.isEmpty ? "Choose a stronger password" : r.hint; return }
        guard pw == pw2 else { error = "The passwords don't match"; return }
        do { try model.create(password: pw); pw = ""; pw2 = "" } catch { self.error = error.localizedDescription }
    }
}

struct LockView: View {
    @EnvironmentObject var model: AppModel
    @Local private var pw = ""
    @Local private var error = ""
    @Local private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 36)
            MarkHalo()
            Text("Unlock Totem").font(.system(size: 20, weight: .semibold)).padding(.top, 18)
            Text("Your codes stay encrypted on this Mac.").font(.system(size: 12.5)).foregroundStyle(Theme.mist).padding(.top, 5)
            VStack(spacing: 10) {
                if model.hasStoredKey && model.touchIDEnabled {
                    Button { Task { await touchID() } } label: {
                        Label(Biometrics.hasTouchID ? "Unlock with Touch ID" : "Unlock with your Mac password", systemImage: "touchid")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    Text("or use your master password").font(.system(size: 11.5)).foregroundStyle(Theme.mist).padding(.vertical, 2)
                }
                SecureField("Master password", text: $pw).totemField().focused($focused).onSubmit(unlock)
                if !(model.hasStoredKey && model.touchIDEnabled) {
                    Button(busy ? "Unlocking…" : "Unlock", action: unlock).buttonStyle(PrimaryButtonStyle()).disabled(busy || pw.isEmpty)
                }
                if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Theme.rose) }
            }
            .padding(.top, 24)
            Spacer()
            HStack {
                if let u = model.update, !model.updating {
                    Button { model.installUpdate() } label: { Label("Install update \(u.version)", systemImage: "arrow.down.circle.fill") }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.brass)
                } else if model.updating {
                    Text("Installing update…").font(.system(size: 11.5)).foregroundStyle(Theme.brass)
                }
                Spacer(); QuitButton()
            }
        }
        .padding(24)
        .onAppear { if !(model.hasStoredKey && model.touchIDEnabled) { focused = true }; model.checkForUpdate() }
    }

    private func unlock() {
        guard !pw.isEmpty else { return }
        busy = true
        let p = pw
        DispatchQueue.main.async {
            do { try model.unlock(password: p); pw = "" } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func touchID() async {
        if !(await model.unlockWithTouchID()) { error = "Not unlocked. Use your master password." }
    }
}

// MARK: - list

struct ListView: View {
    @EnvironmentObject var model: AppModel
    let openSettings: () -> Void
    @Local private var selection = 0
    @FocusState private var searchFocused: Bool

    var body: some View {
        let list = model.accounts
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TotemMark(scale: 0.62).padding(.trailing, 6)
                TextField("Search accounts", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 14.5))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(searchFocused ? Theme.field : .clear))
                    .focused($searchFocused)
                    .onSubmit { if list.indices.contains(selection) { model.copy(list[selection]) } }
                    .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                    .onChange(of: model.query) { selection = 0 }
                Menu {
                    Button("Scan screen for a QR code") { Task { await model.scanScreen() } }
                    Button("Paste a link from the clipboard") { pasteFromClipboard() }
                    Button("Enter details by hand") { model.screen = .add }
                    Divider()
                    Button("Import a file…") { importFile() }
                } label: { Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).frame(width: 28, height: 28)
                    .foregroundStyle(Theme.mist).help("Add account")
                IconButton(symbol: "slider.horizontal.3", help: "Settings", action: openSettings)
                IconButton(symbol: "lock", help: "Lock") { model.lock() }
                IconButton(symbol: "power", help: "Quit Totem (⌘Q)") { NSApp.terminate(nil) }
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 10)
            Fuse(now: model.now).padding(.horizontal, 16)

            if model.data.live.isEmpty {
                EmptyState()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                                AccountRow(account: a, selected: i == selection)
                                    .id(a.id)
                                    .onTapGesture { selection = i; model.copy(a) }
                                    .contextMenu {
                                        Button("Copy code") { model.copy(a) }
                                        Button("Edit…") { model.screen = .edit(a.id) }
                                        Button(a.pinned ? "Unpin" : "Pin to the top") { try? model.update(a.id) { $0.pinned.toggle() } }
                                    }
                            }
                            if list.isEmpty {
                                Text("No accounts match your search").font(.system(size: 12.5)).foregroundStyle(Theme.mist).padding(.top, 40)
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selection) { if list.indices.contains(selection) { proxy.scrollTo(list[selection].id) } }
                }
            }

            HStack(spacing: 8) {
                if model.updating {
                    ProgressView().controlSize(.mini)
                    Text("Installing update…").foregroundStyle(Theme.brass)
                } else if let u = model.update {
                    Button { model.installUpdate() } label: {
                        Label("Install update \(u.version)", systemImage: "arrow.down.circle.fill").fontWeight(.semibold)
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.brass).help("From \(u.zip.lastPathComponent) in Downloads")
                } else {
                    Text("\(HotKeyLabel.current) opens quick search").foregroundStyle(Theme.mist)
                }
                Spacer()
                if model.backupEnabled {
                    Button { Task { await model.syncBackup(forceBackup: true) } } label: {
                        HStack(spacing: 5) {
                            Circle().fill(model.backupStatus.hasPrefix("Backed up") || model.backupStatus.isEmpty ? Theme.good : Theme.rose).frame(width: 6, height: 6)
                            Text(model.syncing ? "Backing up…" : model.backupStatus.isEmpty ? "Backup on" : model.backupStatus).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.mist).help("Back up now")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
        .onAppear { searchFocused = true; model.touch(); model.checkForUpdate() }
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return model.say("The clipboard is empty") }
        do { model.say(try model.importText(text)) } catch { model.say(error.localizedDescription) }
    }

    private func importFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .plainText, .image, UTType(filenameExtension: "totem") ?? .data, UTType(filenameExtension: "2fas") ?? .data]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            guard let link = ScreenQR.decode(fileURL: url).first else { return model.say("No QR code found in that image") }
            do { model.say(try model.importText(link)) } catch { model.say(error.localizedDescription) }
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return model.say("Couldn't read that file") }
        do {
            model.say(try model.importText(text))
        } catch is AppModel.ImportNeedsPassword {
            let alert = NSAlert()
            alert.messageText = "Password for this Totem backup"
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            do { model.say(try model.importText(text, password: field.stringValue)) } catch { model.say(error.localizedDescription) }
        } catch { model.say(error.localizedDescription) }
    }
}

enum HotKeyLabel {
    static var current: String { UserDefaults.standard.string(forKey: "hotkey") ?? HotKey.presets[0].label }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            MarkHalo()
            Text("No accounts yet").font(.system(size: 17, weight: .semibold)).padding(.top, 18)
            Text("Open a site's two-factor setup page so its QR code is on screen, then scan it.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.mist).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            VStack(spacing: 8) {
                Button { Task { await model.scanScreen() } } label: { Label("Scan screen for a QR code", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Other ways to add") { model.screen = .add }.buttonStyle(QuietButtonStyle())
            }
            .frame(maxWidth: 250).padding(.top, 20)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - add (manual)

struct AddView: View {
    @EnvironmentObject var model: AppModel
    @Local private var link = ""
    @Local private var issuer = ""
    @Local private var label = ""
    @Local private var secret = ""
    @Local private var algorithm = OTPAlgorithm.SHA1
    @Local private var digits = 6
    @Local private var period = 30
    @Local private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: "Add account")
            Button { Task { await model.scanScreen() } } label: { Label("Scan screen for a QR code", systemImage: "qrcode.viewfinder") }
                .buttonStyle(PrimaryButtonStyle())
            TextField("Or paste an otpauth:// link", text: $link).totemField()
            Text("Or enter the details by hand").font(.system(size: 12)).foregroundStyle(Theme.mist).padding(.top, 6)
            HStack(spacing: 8) {
                TextField("Service, e.g. GitHub", text: $issuer).totemField()
                TextField("Account", text: $label).totemField()
            }
            TextField("Secret key", text: $secret).totemField().font(.system(size: 13, design: .monospaced))
            HStack {
                Picker("", selection: $algorithm) { ForEach(OTPAlgorithm.allCases, id: \.self) { Text($0.rawValue) } }
                Picker("", selection: $digits) { ForEach([6, 7, 8], id: \.self) { Text("\($0) digits") } }
                Picker("", selection: $period) { Text("Every 30 s").tag(30); Text("Every 60 s").tag(60) }
            }.labelsHidden()
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(Theme.rose) }
            Spacer()
            Button("Add account", action: add).buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
    }

    private func add() {
        do {
            if !link.trimmingCharacters(in: .whitespaces).isEmpty {
                model.say(try model.importText(link))
            } else {
                let r = try model.add([Account(issuer: issuer, label: label, secret: secret, algorithm: algorithm, digits: digits, period: period)])
                if r.added == 0 { throw TotemError.message(r.skipped > 0 ? "Already in Totem, or the secret key isn't valid" : "Enter a secret key") }
                model.say("Account added")
            }
            model.screen = .list
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - edit

struct EditView: View {
    @EnvironmentObject var model: AppModel
    let id: String
    @Local private var issuer = ""
    @Local private var label = ""
    @Local private var domains = ""
    @Local private var showQR = false
    @Local private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: "Edit account")
            if let a = model.account(id) {
                HStack(spacing: 12) {
                    Monogram(name: issuer.isEmpty ? a.title : issuer, size: 46)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Service", text: $issuer).totemField()
                        TextField("Account", text: $label).totemField()
                    }
                }
                Text("Sites for browser auto-fill").font(.system(size: 12)).foregroundStyle(Theme.mist).padding(.top, 4)
                TextField("github.com", text: $domains).totemField()
                Text("Codes fill automatically only on these sites. Separate with commas.").font(.system(size: 11)).foregroundStyle(Theme.mist)
                Button("Save", action: save).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
                HStack(spacing: 8) {
                    Button(showQR ? "Hide QR code" : "Show QR for a phone") { showQR.toggle() }.buttonStyle(QuietButtonStyle())
                    Button("Delete") { confirmDelete = true }.buttonStyle(QuietButtonStyle(destructive: true))
                }
                if showQR, let img = ScreenQR.image(for: OTPAuth.uri(a)) {
                    VStack(spacing: 6) {
                        Image(nsImage: img).interpolation(.none).resizable().frame(width: 150, height: 150)
                            .padding(8).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text("Anyone who sees this can copy your two-factor codes. Hide it when you're done.")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.mist).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                }
                Spacer()
            }
        }
        .padding(16)
        .onAppear {
            guard let a = model.account(id) else { return }
            issuer = a.issuer; label = a.label; domains = a.domains.joined(separator: ", ")
        }
        .confirmationDialog("Delete this account?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                try? model.delete(id); model.screen = .list; model.say("Deleted")
            }
        } message: { Text("Make sure two-factor is turned off on that site, or you have another way in.") }
    }

    private func save() {
        let list: [String] = domains.split(whereSeparator: { $0 == "," || $0 == " " }).map { (part: Substring) -> String in
            var d = part.lowercased()
            for p in ["https://", "http://", "www."] where d.hasPrefix(p) { d.removeFirst(p.count) }
            return d.split(separator: "/").first.map(String.init) ?? d
        }.filter { !$0.isEmpty }
        do {
            try model.update(id) { $0.issuer = issuer; $0.label = label; $0.domains = list }
            model.say("Saved"); model.screen = .list
        } catch { model.say(error.localizedDescription) }
    }
}

struct Header: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Button { model.screen = .list } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 24, height: 24) }
                .buttonStyle(.plain).foregroundStyle(Theme.mist).keyboardShortcut(.cancelAction)
            Text(title).font(.system(size: 15, weight: .semibold))
            Spacer()
        }
        .padding(.bottom, 4)
    }
}
