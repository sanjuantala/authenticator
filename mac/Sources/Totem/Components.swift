import AppKit
import Combine
import SwiftUI
import TotemCore

// MARK: - design tokens ("brass key": ink surfaces, one warm brass accent)

private func dynamic(_ dark: NSColor, _ light: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
}
private func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

enum Theme {
    static let ink = dynamic(hex(0x12151C), hex(0xF4F5F7))        // window
    static let slate = dynamic(hex(0x1A1F29), hex(0xFFFFFF))      // raised surface
    static let field = dynamic(hex(0x222835), hex(0xEEF0F3))      // inputs, hover
    static let line = dynamic(hex(0xECE8E1, 0.08), hex(0x161A22, 0.09))
    static let bone = dynamic(hex(0xECE8E1), hex(0x161A22))       // text
    static let mist = dynamic(hex(0x98A0AE), hex(0x667085))       // secondary text
    static let brass = dynamic(hex(0xD4B074), hex(0x9A7434))      // the one accent
    static let brassHi = dynamic(hex(0xEBD3A0), hex(0xB48A45))
    static let brassInk = dynamic(hex(0x1A1408), hex(0xFFFFFF))
    static let rose = dynamic(hex(0xF08A8A), hex(0xC2413F))
    static let good = Color(nsColor: hex(0x7FC8A9))
    static let brassFill = LinearGradient(colors: [brassHi, brass], startPoint: .top, endPoint: .bottom)
    static func code(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .medium, design: .monospaced) }

    // legacy names used by older views
    static let accent = brass
    static let accentInk = brassInk
    static let warn = rose
    static let mono = code()
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.brassFill))
            .foregroundStyle(Theme.brassInk)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(destructive ? Theme.rose.opacity(0.14) : Theme.field))
            .foregroundStyle(destructive ? Theme.rose : Theme.bone)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 14))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .foregroundStyle(Theme.bone)
    }
}
extension View { func totemField() -> some View { modifier(FieldStyle()) } }

// MARK: - brand

/// Three stacked brass tiles — the Totem mark.
struct TotemMark: View {
    var scale: CGFloat = 1
    var body: some View {
        VStack(spacing: 3.2 * scale) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 2.6 * scale, style: .continuous)
                    .fill(Theme.brassFill)
                    .opacity([1, 0.85, 0.7][i])
                    .frame(width: CGFloat([16, 24, 32][i]) * scale, height: 7 * scale)
            }
        }
    }
}

/// The mark inside a softly lit tile, for lock and empty screens.
struct MarkHalo: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.slate)
            RadialGradient(colors: [Theme.brass.opacity(0.25), .clear], center: .init(x: 0.5, y: 0.35), startRadius: 0, endRadius: 52)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.line)
            TotemMark(scale: 1.25)
        }
        .frame(width: 80, height: 80)
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }
}

/// Menu bar glyph: the mark as a template image (adapts to light/dark menu bars). Hollow when locked.
enum MenuBarIcon {
    static func image(locked: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            let bars: [(CGFloat, CGFloat)] = [(5.5, 7), (3.5, 11), (1.5, 15)]
            for (i, (x, w)) in bars.enumerated() {
                let r = NSRect(x: x, y: 2 + CGFloat(i) * 4.5, width: w, height: 3.2)
                let path = NSBezierPath(roundedRect: r, xRadius: 1.3, yRadius: 1.3)
                NSColor.black.setFill(); NSColor.black.setStroke()
                if locked { path.lineWidth = 1; path.stroke() } else { path.fill() }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - accounts

private func fnv(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for scalar in (s.isEmpty ? "?" : s).lowercased().unicodeScalars { h = (h ^ UInt32(String(scalar).utf16.first ?? 0)) &* 16777619 }
    return h
}

/// A calm, per-service monogram (same hue as in the browser extension).
struct Monogram: View {
    @Environment(\.colorScheme) var scheme
    let name: String
    var size: CGFloat = 36

    var body: some View {
        let hue = Double(fnv(name) % 360) / 360
        let dark = scheme == .dark
        let words = name.split(separator: " ")
        let text = words.count > 1 ? "\(words[0].prefix(1))\(words[1].prefix(1))" : String(name.trimmingCharacters(in: .whitespaces).prefix(1))
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(Color(hue: hue, saturation: dark ? 0.3 : 0.12, brightness: dark ? 0.24 : 0.98))
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .strokeBorder(Color(hue: hue, saturation: 0.4, brightness: dark ? 0.6 : 0.5).opacity(dark ? 0.2 : 0.14))
            Text((text.isEmpty ? "?" : text).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(hue: hue, saturation: dark ? 0.45 : 0.6, brightness: dark ? 0.92 : 0.38))
        }
        .frame(width: size, height: size)
    }
}

/// Older name kept so nothing else breaks.
typealias Sigil = Monogram

/// The signature element: a brass line that burns down with the 30-second window.
struct Fuse: View {
    let now: Date
    var body: some View {
        let remaining = 30 - Int(now.timeIntervalSince1970) % 30
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(remaining <= 5 ? AnyShapeStyle(Theme.rose) : AnyShapeStyle(LinearGradient(colors: [Theme.brass, Theme.brassHi], startPoint: .leading, endPoint: .trailing)))
                    .frame(width: geo.size.width * CGFloat(remaining) / 30)
                    .animation(remaining == 30 ? nil : .linear(duration: 1), value: remaining)
            }
        }
        .frame(height: 2)
    }
}

struct CountdownRing: View {
    let remaining: Int
    let period: Int
    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: 2.5)
            Circle().trim(from: 0, to: Double(remaining) / Double(max(period, 1)))
                .stroke(remaining <= 5 ? Theme.rose : Theme.brass, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}

func groupedCode(_ code: String) -> String {
    let half = code.count == 8 ? 4 : 3
    return String(code.prefix(half)) + " " + String(code.dropFirst(half))
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let account: Account
    var selected = false
    var large = false
    @Local var hovering = false

    var body: some View {
        let otp = model.code(account)
        let reveal = !model.privacyMode || hovering || selected
        let copied = model.lastCopiedId == account.id
        HStack(spacing: 12) {
            Monogram(name: account.title, size: large ? 38 : 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.bone).lineLimit(1)
                if !account.subtitle.isEmpty {
                    Text(account.subtitle).font(.system(size: 12)).foregroundStyle(Theme.mist).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let otp {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(copied ? "Copied" : groupedCode(otp.code))
                        .font(copied ? .system(size: 15, weight: .semibold) : Theme.code(large ? 22 : 20))
                        .foregroundStyle(copied ? Theme.brass : otp.remaining <= 5 ? Theme.rose : Theme.bone)
                        .blur(radius: reveal || copied ? 0 : 6)
                        .contentTransition(.numericText())
                    Text("next \(groupedCode(otp.next))")
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.mist)
                        .opacity((selected || hovering) && reveal ? 1 : 0)
                }
                if otp.period != 30 { CountdownRing(remaining: otp.remaining, period: otp.period) }
            } else {
                Text("Invalid key").font(.system(size: 12)).foregroundStyle(Theme.rose)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected || hovering ? Theme.slate : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Theme.line : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.bone))
            .foregroundStyle(Theme.ink)
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - password strength (same rules as the extension's lib/strength.js)

enum PasswordStrength {
    static let common = ["password", "passw0rd", "qwerty", "letmein", "welcome", "admin", "iloveyou", "monkey", "dragon",
                         "football", "baseball", "master", "shadow", "sunshine", "princess", "abc123", "123456", "totem", "secret", "google"]

    static func score(_ s: String) -> (score: Int, label: String, hint: String) {
        guard !s.isEmpty else { return (0, "", "") }
        var pool = 0
        if s.range(of: "[a-z]", options: .regularExpression) != nil { pool += 26 }
        if s.range(of: "[A-Z]", options: .regularExpression) != nil { pool += 26 }
        if s.range(of: "[0-9]", options: .regularExpression) != nil { pool += 10 }
        if s.range(of: "[^a-zA-Z0-9]", options: .regularExpression) != nil { pool += 33 }
        var bits = Double(s.count) * log2(Double(max(pool, 1)))
        let lower = s.lowercased()
        if common.contains(where: { lower.contains($0) }) { bits -= 28 }
        if s.range(of: "(.)\\1\\1", options: .regularExpression) != nil { bits -= 10 }
        if lower.range(of: "(012|123|234|345|456|567|678|789|abc|bcd|cde|qwe|wer|asd)", options: .regularExpression) != nil { bits -= 10 }
        if s.range(of: "^[a-zA-Z]+[0-9]{1,4}[^a-zA-Z0-9]?$", options: .regularExpression) != nil { bits -= 12 }
        let words = s.split(whereSeparator: { " -_.".contains($0) }).filter { $0.count >= 3 }
        if words.count >= 4 { bits = max(bits, 60) }
        let score = s.count < 10 ? 0 : bits < 40 ? 1 : bits < 60 ? 2 : bits < 80 ? 3 : 4
        let label = ["Too short", "Weak", "Fair", "Strong", "Excellent"][score]
        let hint = score == 0 ? "Use at least 10 characters."
            : score == 1 ? "Easy to guess. Try four random words, like “copper lantern orbit mango”."
            : score == 2 ? "Okay. A few more words or characters make it much stronger." : ""
        return (score, label, hint)
    }
}

struct StrengthMeter: View {
    let password: String
    var body: some View {
        let r = PasswordStrength.score(password)
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<4) { i in
                    Capsule().fill(i < r.score ? (r.score <= 1 ? Theme.rose : r.score == 2 ? Theme.brass : Theme.good) : Theme.field)
                        .frame(height: 4)
                }
            }.frame(width: 100)
            Text(r.hint.isEmpty ? r.label : "\(r.label). \(r.hint)")
                .font(.system(size: 11.5)).foregroundStyle(Theme.mist).fixedSize(horizontal: false, vertical: true)
        }
        .opacity(password.isEmpty ? 0 : 1)
    }
}

// MARK: - @State replacement

/// Drop-in replacement for SwiftUI's `@State`.
/// Newer macOS SDKs implement `@State` as a compiler macro whose plugin ships only with full Xcode,
/// so it fails to build with the Command Line Tools. This uses `@StateObject`, which needs no plugin.
final class LocalBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@propertyWrapper
struct Local<Value>: DynamicProperty {
    @StateObject private var box: LocalBox<Value>

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: LocalBox(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> {
        let box = self.box
        return Binding(get: { box.value }, set: { box.value = $0 })
    }
}
