import Combine
import AppKit
import SwiftUI
import TotemCore

/// Spotlight-style quick search, opened with the global hotkey from any app.
/// Enter copies the code. ⇧Enter types it straight into the app you were in.
/// It's a non-activating panel, so the app you were using keeps focus behind it.
@MainActor
final class QuickPanel {
    static let shared = QuickPanel()
    private var panel: KeyPanel?
    private var resignObserver: Any?

    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        let model = AppModel.shared
        model.query = ""
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: QuickView().environmentObject(model))
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { _ in
                Task { @MainActor in QuickPanel.shared.close() }
            }
            panel = p
        }
        guard let p = panel else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - f.height * 0.22 - p.frame.height))
        }
        p.makeKeyAndOrderFront(nil)
        if model.locked && model.hasStoredKey && model.touchIDEnabled {
            Task { await model.unlockWithTouchID() }
        }
    }

    func close() { panel?.orderOut(nil) }

    /// Close, then type the code into whichever app is in front.
    func closeAndType(_ code: String) {
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !Clipboard.typeIntoFrontApp(code) {
                AppModel.shared.say("Allow Totem in System Settings → Privacy & Security → Accessibility to type codes for you. Copied instead.")
            }
        }
    }
}

struct QuickView: View {
    @EnvironmentObject var model: AppModel
    @Local private var selection = 0
    @Local private var pw = ""
    @Local private var error = ""
    @FocusState private var focused: Bool

    var body: some View {
        let list = Array(model.accounts.prefix(7))
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                TotemMark(scale: 0.8)
                if model.locked {
                    SecureField("Master password", text: $pw)
                        .textFieldStyle(.plain).font(.system(size: 21)).foregroundStyle(Theme.bone).focused($focused)
                        .onSubmit {
                            do { try model.unlock(password: pw); pw = ""; error = "" } catch { self.error = error.localizedDescription }
                        }
                } else {
                    TextField("Search two-factor codes", text: $model.query)
                        .textFieldStyle(.plain).font(.system(size: 21)).foregroundStyle(Theme.bone).focused($focused)
                        .onKeyPress(.downArrow) { selection = min(selection + 1, max(list.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selection = max(selection - 1, 0); return .handled }
                        .onKeyPress(.return, phases: .down) { press in
                            guard list.indices.contains(selection) else { return .handled }
                            let a = list[selection]
                            if press.modifiers.contains(.shift), let code = model.currentCode(a) {
                                model.copy(a)
                                QuickPanel.shared.closeAndType(code)
                            } else {
                                model.copy(a)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { QuickPanel.shared.close() }
                            }
                            return .handled
                        }
                        .onChange(of: model.query) { selection = 0 }
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
            Fuse(now: model.now).padding(.horizontal, 20)

            if model.locked {
                Text(error.isEmpty ? "Totem is locked. Type your master password, or use Touch ID." : error)
                    .font(.system(size: 12)).foregroundStyle(error.isEmpty ? Theme.mist : Theme.rose).padding(.vertical, 14)
            } else if !list.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                        AccountRow(account: a, selected: i == selection, large: true)
                            .onTapGesture { model.copy(a); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { QuickPanel.shared.close() } }
                    }
                }
                .padding(10)
                HStack(spacing: 16) {
                    hint("↩", "Copy"); hint("⇧↩", "Type into the app"); hint("↑↓", "Choose"); hint("esc", "Close")
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
                .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
            } else {
                Text(model.data.live.isEmpty ? "No accounts yet. Add one from the menu bar." : "No accounts match your search")
                    .font(.system(size: 13)).foregroundStyle(Theme.mist).padding(.vertical, 18)
            }
        }
        .frame(width: 580)
        .background(Theme.ink, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { focused = true; selection = 0 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            focused = true; selection = 0
        }
        .onExitCommand { QuickPanel.shared.close() }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10.5, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.field))
                .foregroundStyle(Theme.bone)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.mist)
        }
    }
}
