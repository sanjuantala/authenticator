// Self-check that needs no XCTest (works with Command Line Tools only).
// Usage: swift run TotemCoreCheck Tests/TotemCoreTests/Fixtures/js-vault.json
import Foundation
import TotemCore

var failures = 0
func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
    } catch {
        print("  ✗ \(name): \(error.localizedDescription)"); failures += 1
    }
}
func b32(_ s: String) -> String { Base32.encode(Data(s.utf8)) }

print("Totem core self-check")

check("RFC 6238 vectors (SHA1 / SHA256 / SHA512)") {
    let cases: [(String, OTPAlgorithm, Double, String)] = [
        ("12345678901234567890", .SHA1, 59, "94287082"),
        ("12345678901234567890", .SHA1, 1111111109, "07081804"),
        ("12345678901234567890123456789012", .SHA256, 59, "46119246"),
        ("1234567890123456789012345678901234567890123456789012345678901234", .SHA512, 59, "90693936"),
        ("1234567890123456789012345678901234567890123456789012345678901234", .SHA512, 2000000000, "38618901"),
    ]
    for (seed, alg, t, want) in cases {
        let a = Account(issuer: "x", label: "y", secret: b32(seed), algorithm: alg, digits: 8)
        guard try TOTP.code(for: a, at: Date(timeIntervalSince1970: t)).code == want else { return false }
    }
    return true
}

check("Base32 round trip and lenient input") {
    let d = Vault.randomBytes(20)
    return try Base32.decode(Base32.encode(d)) == d
        && Base32.decode("jbsw y3dp-ehpk 3pxp==") == Base32.decode("JBSWY3DPEHPK3PXP")
}

let fixture = CommandLine.arguments.dropFirst().first ?? "Tests/TotemCoreTests/Fixtures/js-vault.json"
check("Opens a vault encrypted by the browser extension") {
    let env = try Vault.decodeEnvelope(Data(contentsOf: URL(fileURLWithPath: fixture)))
    guard (try? Vault.session(password: "wrong", for: env)) == nil else { return false }
    let s = try Vault.session(password: "interop-password", for: env)
    let data = try Vault.open(env, session: s)
    guard data.live.count == 1, let a = data.live.first, a.issuer == "GitHub", a.domains == ["github.com"] else { return false }
    guard try TOTP.code(for: a, at: Date(timeIntervalSince1970: 59)).code == "94287082" else { return false }
    let resealed = try Vault.seal(data, session: s, device: "check")
    let json = String(decoding: try Vault.encodeEnvelope(resealed), as: UTF8.self)
    return try Vault.open(resealed, session: s) == data && !json.contains("GitHub")
}

check("Merge: a delete beats an older edit, duplicates are skipped") {
    var d = VaultData()
    Vault.add([Account(issuer: "GitHub", label: "me", secret: "JBSWY3DPEHPK3PXP")], to: &d)
    let id = d.accounts[0].id
    var a = d; try Vault.update(id, in: &a) { $0.label = "renamed" }
    Thread.sleep(forTimeInterval: 0.01)
    var b = d; Vault.delete(id, in: &b)
    Vault.add([Account(issuer: "Google", label: "x", secret: "GEZDGNBVGY3TQOJQ")], to: &b)
    let m = Vault.merge(a, b)
    var dup = m
    return m.live.map(\.issuer) == ["Google"] && Vault.same(Vault.merge(m, a), m)
        && Vault.add([Account(issuer: "Google", label: "x", secret: "GEZD GNBV GY3T QOJQ")], to: &dup).added == 0
}

check("Delete removes an account from the codes and the saved vault") {
    let s = try Vault.session(password: "interop-password",
                              for: Vault.decodeEnvelope(Data(contentsOf: URL(fileURLWithPath: fixture))))
    var d = VaultData()
    Vault.add([Account(issuer: "Baystate", label: "", secret: "JBSWY3DPEHPK3PXP"),
               Account(issuer: "GitHub", label: "me", secret: "GEZDGNBVGY3TQOJQ")], to: &d)
    let id = d.live.first { $0.issuer == "Baystate" }!.id
    Vault.delete(id, in: &d)
    let reopened = try Vault.open(try Vault.seal(d, session: s, device: "check"), session: s)
    return d.live.map(\.issuer) == ["GitHub"] && reopened.live.map(\.issuer) == ["GitHub"]
        && reopened.accounts.first { $0.id == id }?.deleted == true
        && reopened.accounts.first { $0.id == id }?.secret == ""
}

check("otpauth links and Aegis import") {
    let a = try OTPAuth.parse("otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60")
    let back = try OTPAuth.parse(OTPAuth.uri(a))
    let aegis = #"{"version":1,"db":{"entries":[{"type":"totp","name":"me","issuer":"Proton","info":{"secret":"JBSWY3DPEHPK3PXP","algo":"SHA1","digits":6,"period":30}}]}}"#
    guard case .accounts(let kind, let list, _) = try Importer.parse(aegis) else { return false }
    return a.issuer == "ACME Co" && a.label == "john@example.com" && a.algorithm == .SHA256 && a.digits == 8 && a.period == 60
        && [back.issuer, back.label, back.secret] == [a.issuer, a.label, a.secret]
        && kind == "Aegis" && list.first?.issuer == "Proton"
}

check("Google Authenticator transfer QR") {
    func pb(_ fields: [(Int, Any)]) -> [UInt8] {
        var out: [UInt8] = []
        func v(_ n: Int) { var n = n; while n > 127 { out.append(UInt8(n & 127 | 128)); n >>= 7 }; out.append(UInt8(n)) }
        for (f, val) in fields {
            if let n = val as? Int { v(f << 3); v(n) }
            else { let b = (val as? [UInt8]) ?? Array((val as! String).utf8); v(f << 3 | 2); v(b.count); out += b }
        }
        return out
    }
    let secret = Array("12345678901234567890".utf8)
    let p1 = pb([(1, secret), (2, "alice@example.com"), (3, "Example"), (4, 1), (5, 1), (6, 2)])
    let p2 = pb([(1, secret), (2, "hotp"), (6, 1)])
    let payload = Data(pb([(1, p1), (1, p2), (2, 1)])).base64EncodedString()
    let r = try Importer.migration("otpauth-migration://offline?data=" + payload)
    return r.accounts.count == 1 && r.skipped == 1 && r.accounts[0].issuer == "Example"
        && r.accounts[0].secret == b32("12345678901234567890")
}

if failures > 0 {
    print("\n\(failures) check(s) failed. Don't use this build.")
    exit(1)
}
print("\nAll checks passed.")
