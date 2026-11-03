import AppKit
import Carbon.HIToolbox
import LocalAuthentication
import Security

enum Paths {
    static let support: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Totem", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }()
    static let vault = support.appendingPathComponent("vault.json")
    static let socket = support.appendingPathComponent("bridge.sock")
}

// MARK: - Keychain (login keychain, this user only)

enum Keychain {
    static let service = "app.totem.mac"

    static func set(_ value: Data, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

// MARK: - Touch ID / password confirmation

enum Biometrics {
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
    static var hasTouchID: Bool {
        let c = LAContext()
        return c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) && c.biometryType == .touchID
    }
    /// Touch ID, Apple Watch, or the Mac login password as fallback.
    static func confirm(_ reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) }
        catch { return false }
    }
}

// MARK: - Clipboard: concealed from clipboard managers, cleared after N seconds if untouched

enum Clipboard {
    private static var clearWork: DispatchWorkItem?

    static func copy(_ text: String, clearAfter seconds: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        // tells clipboard managers (Maccy, Raycast, Alfred, Paste…) not to keep it
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let count = pb.changeCount
        clearWork?.cancel()
        guard seconds > 0 else { return }
        let work = DispatchWorkItem {
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    /// Types the text into whatever app is in front (needs Accessibility permission).
    static func typeIntoFrontApp(_ text: String) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text.utf16 {
            var c = ch
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(8000)
        }
        return true
    }
}

// MARK: - Global hotkey (Carbon, works without Accessibility permission)

final class HotKey {
    struct Combo: Hashable, Identifiable {
        let keyCode: UInt32, modifiers: UInt32, label: String
        var id: String { label }
    }
    static let presets: [Combo] = [
        Combo(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(optionKey | cmdKey), label: "⌥⌘2"),
        Combo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space"),
        Combo(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey | shiftKey | cmdKey), label: "⌥⇧⌘T"),
        Combo(keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | cmdKey), label: "⌃⌘O"),
    ]

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var current: HotKey?

    init(_ combo: Combo, action: @escaping () -> Void) {
        self.action = action
        HotKey.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x544F544D), id: 1) // "TOTM"
        RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
