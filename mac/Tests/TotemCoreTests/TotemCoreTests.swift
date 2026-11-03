import XCTest
@testable import TotemCore

final class TotemCoreTests: XCTestCase {
    private func b32(_ s: String) -> String { Base32.encode(Data(s.utf8)) }

    func testRFC6238Vectors() throws {
        let cases: [(String, OTPAlgorithm, Double, String)] = [
            ("12345678901234567890", .SHA1, 59, "94287082"),
            ("12345678901234567890", .SHA1, 1111111109, "07081804"),
            ("12345678901234567890123456789012", .SHA256, 59, "46119246"),
            ("1234567890123456789012345678901234567890123456789012345678901234", .SHA512, 59, "90693936"),
            ("1234567890123456789012345678901234567890123456789012345678901234", .SHA512, 2000000000, "38618901"),
        ]
        for (seed, alg, t, want) in cases {
            let a = Account(issuer: "x", label: "y", secret: b32(seed), algorithm: alg, digits: 8)
            XCTAssertEqual(try TOTP.code(for: a, at: Date(timeIntervalSince1970: t)).code, want, "\(alg) @\(t)")
        }
    }

    func testBase32RoundTrip() throws {
        let d = Vault.randomBytes(20)
        XCTAssertEqual(try Base32.decode(Base32.encode(d)), d)
        XCTAssertEqual(try Base32.decode("jbsw y3dp-ehpk 3pxp=="), try Base32.decode("JBSWY3DPEHPK3PXP"))
    }

    /// The decisive test: open a vault that the browser extension encrypted.
    func testOpensVaultWrittenByExtension() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "js-vault", withExtension: "json", subdirectory: "Fixtures"))
        let env = try Vault.decodeEnvelope(Data(contentsOf: url))
        XCTAssertThrowsError(try Vault.session(password: "nope", for: env))
        let s = try Vault.session(password: "interop-password", for: env)
        let data = try Vault.open(env, session: s)
        XCTAssertEqual(data.live.count, 1)
        let a = data.live[0]
        XCTAssertEqual(a.issuer, "GitHub")
        XCTAssertEqual(a.domains, ["github.com"])
        XCTAssertEqual(try TOTP.code(for: a, at: Date(timeIntervalSince1970: 59)).code, "94287082")

        // and the Mac's re-sealed copy opens again with the same session (what the extension will read)
        let resealed = try Vault.seal(data, session: s, device: "mac-test")
        XCTAssertEqual(try Vault.open(resealed, session: s), data)
        let json = String(decoding: try Vault.encodeEnvelope(resealed), as: UTF8.self)
        XCTAssertFalse(json.contains("GitHub"))
    }

    func testMergeDeleteWins() throws {
        var d = VaultData()
        Vault.add([Account(issuer: "GitHub", label: "me", secret: "JBSWY3DPEHPK3PXP")], to: &d)
        let id = d.accounts[0].id
        var a = d; try Vault.update(id, in: &a) { $0.label = "renamed" }
        Thread.sleep(forTimeInterval: 0.01)
        var b = d; Vault.delete(id, in: &b)
        Vault.add([Account(issuer: "Google", label: "x", secret: "GEZDGNBVGY3TQOJQ")], to: &b)
        let m = Vault.merge(a, b)
        XCTAssertEqual(m.live.map(\.issuer), ["Google"])
        XCTAssertTrue(Vault.same(Vault.merge(m, a), m))
        var dup = m
        XCTAssertEqual(Vault.add([Account(issuer: "Google", label: "x", secret: "GEZD GNBV GY3T QOJQ")], to: &dup).added, 0)
    }

    func testOtpauthAndImports() throws {
        let a = try OTPAuth.parse("otpauth://totp/ACME%20Co:john@example.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&algorithm=SHA256&digits=8&period=60")
        XCTAssertEqual(a.issuer, "ACME Co"); XCTAssertEqual(a.label, "john@example.com")
        XCTAssertEqual(a.algorithm, .SHA256); XCTAssertEqual(a.digits, 8); XCTAssertEqual(a.period, 60)
        let back = try OTPAuth.parse(OTPAuth.uri(a))
        XCTAssertEqual([back.issuer, back.label, back.secret], [a.issuer, a.label, a.secret])

        let aegis = #"{"version":1,"db":{"entries":[{"type":"totp","name":"me","issuer":"Proton","info":{"secret":"JBSWY3DPEHPK3PXP","algo":"SHA1","digits":6,"period":30}}]}}"#
        guard case .accounts(let kind, let list, _) = try Importer.parse(aegis) else { return XCTFail() }
        XCTAssertEqual(kind, "Aegis"); XCTAssertEqual(list.first?.issuer, "Proton")
    }

    func testGoogleMigration() throws {
        // payload built by the JS tests: one TOTP (Example / alice@example.com) + one HOTP that must be skipped
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
        XCTAssertEqual(r.accounts.count, 1); XCTAssertEqual(r.skipped, 1)
        XCTAssertEqual(r.accounts[0].issuer, "Example")
        XCTAssertEqual(r.accounts[0].secret, b32("12345678901234567890"))
    }
}
