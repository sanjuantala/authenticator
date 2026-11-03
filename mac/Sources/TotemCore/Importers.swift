import Foundation

/// Same formats as extension/lib/importers.js.
public enum ImportResult {
    case accounts(kind: String, accounts: [Account], skipped: Int)
    case totemVault(Envelope)
}

public enum OTPAuth {
    public static func parse(_ uri: String) throws -> Account {
        guard let c = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)), c.scheme == "otpauth" else {
            throw TotemError.message("Not an otpauth:// link")
        }
        guard (c.host ?? "").lowercased() == "totp" else {
            throw TotemError.unsupported("Only time-based (TOTP) codes are supported")
        }
        var path = c.path
        while path.hasPrefix("/") { path.removeFirst() }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        var issuer = q["issuer"] ?? ""
        var label = path
        if let colon = path.firstIndex(of: ":") {
            if issuer.isEmpty { issuer = String(path[..<colon]) }
            label = String(path[path.index(after: colon)...])
        }
        let secret = Base32.normalize(q["secret"] ?? "")
        _ = try Base32.decode(secret)
        return Account(issuer: issuer.trimmingCharacters(in: .whitespaces), label: label.trimmingCharacters(in: .whitespaces),
                       secret: secret, algorithm: try OTPAlgorithm(loose: q["algorithm"]),
                       digits: Int(q["digits"] ?? "") ?? 6, period: Int(q["period"] ?? "") ?? 30)
    }

    public static func uri(_ a: Account) -> String {
        var c = URLComponents()
        c.scheme = "otpauth"
        c.host = "totp"
        c.path = "/" + (a.issuer.isEmpty ? a.label : "\(a.issuer):\(a.label)")
        var items = [URLQueryItem(name: "secret", value: a.secret)]
        if !a.issuer.isEmpty { items.append(URLQueryItem(name: "issuer", value: a.issuer)) }
        items += [URLQueryItem(name: "algorithm", value: a.algorithm.rawValue),
                  URLQueryItem(name: "digits", value: String(a.digits)),
                  URLQueryItem(name: "period", value: String(a.period))]
        c.queryItems = items
        return c.string ?? ""
    }
}

public enum Importer {
    // MARK: Google Authenticator migration (protobuf)

    private static func varint(_ b: [UInt8], _ i: inout Int) throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            guard i < b.count, shift < 64 else { throw TotemError.message("Damaged transfer code") }
            let byte = b[i]; i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    private enum PBValue { case int(UInt64), bytes([UInt8]) }

    private static func fields(_ b: [UInt8]) throws -> [(Int, PBValue)] {
        var i = 0
        var out: [(Int, PBValue)] = []
        while i < b.count {
            let tag = try varint(b, &i)
            let field = Int(tag >> 3), wire = Int(tag & 7)
            switch wire {
            case 0: out.append((field, .int(try varint(b, &i))))
            case 2:
                let len = Int(try varint(b, &i))
                guard i + len <= b.count else { throw TotemError.message("Damaged transfer code") }
                out.append((field, .bytes(Array(b[i..<(i + len)])))); i += len
            case 1: i += 8
            case 5: i += 4
            default: throw TotemError.message("Damaged transfer code")
            }
        }
        return out
    }

    public static func migration(_ uri: String) throws -> (accounts: [Account], skipped: Int) {
        guard let c = URLComponents(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)),
              var data = c.queryItems?.first(where: { $0.name == "data" })?.value else {
            throw TotemError.message("Transfer link has no data")
        }
        data = data.replacingOccurrences(of: " ", with: "+").replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while data.count % 4 != 0 { data += "=" }
        guard let bytes = Data(base64Encoded: data) else { throw TotemError.message("Damaged transfer code") }
        var out: [Account] = []
        var skipped = 0
        for (f, v) in try fields(Array(bytes)) {
            guard f == 1, case .bytes(let p) = v else { continue }
            var secret = Data(), name = "", issuer = "", alg: UInt64 = 1, digits: UInt64 = 1, type: UInt64 = 2
            for (pf, pv) in try fields(p) {
                switch (pf, pv) {
                case (1, .bytes(let s)): secret = Data(s)
                case (2, .bytes(let s)): name = String(decoding: s, as: UTF8.self)
                case (3, .bytes(let s)): issuer = String(decoding: s, as: UTF8.self)
                case (4, .int(let n)): alg = n
                case (5, .int(let n)): digits = n
                case (6, .int(let n)): type = n
                default: break
                }
            }
            if type == 1 { skipped += 1; continue }
            var label = name
            if let colon = name.firstIndex(of: ":") {
                if issuer.isEmpty { issuer = String(name[..<colon]) }
                label = String(name[name.index(after: colon)...])
            }
            let algorithm: OTPAlgorithm = alg == 2 ? .SHA256 : alg == 3 ? .SHA512 : .SHA1
            out.append(Account(issuer: issuer.trimmingCharacters(in: .whitespaces), label: label.trimmingCharacters(in: .whitespaces),
                               secret: Base32.encode(secret), algorithm: algorithm, digits: digits == 2 ? 8 : 6, period: 30))
        }
        return (out, skipped)
    }

    // MARK: detection

    public static func parse(_ text: String) throws -> ImportResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TotemError.message("Nothing to import") }
        if trimmed.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            if json["format"] as? String == Vault.format { return .totemVault(try Vault.decodeEnvelope(Data(trimmed.utf8))) }
            if json["db"] != nil, json["version"] != nil { return try aegis(json) }
            if json["services"] != nil || json["servicesEncrypted"] != nil { return try twofas(json) }
            if json["items"] != nil || json["encrypted"] != nil { return try bitwarden(json) }
        }
        var accounts: [Account] = []
        var skipped = 0
        let pattern = try NSRegularExpression(pattern: "otpauth(?:-migration)?://[^\\s\"'<>]+")
        let ns = trimmed as NSString
        for m in pattern.matches(in: trimmed, range: NSRange(location: 0, length: ns.length)) {
            let link = ns.substring(with: m.range)
            do {
                if link.hasPrefix("otpauth-migration") {
                    let r = try migration(link); accounts += r.accounts; skipped += r.skipped
                } else { accounts.append(try OTPAuth.parse(link)) }
            } catch { skipped += 1 }
        }
        if accounts.isEmpty && skipped == 0 {
            let s = Base32.normalize(trimmed)
            if s.count >= 16, s.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".contains($0) }) {
                return .accounts(kind: "secret", accounts: [Account(issuer: "", label: "New account", secret: s)], skipped: 0)
            }
            throw TotemError.message("No authenticator accounts found in that file or text")
        }
        return .accounts(kind: "otpauth", accounts: accounts, skipped: skipped)
    }

    private static func aegis(_ json: [String: Any]) throws -> ImportResult {
        guard let db = json["db"] as? [String: Any] else {
            throw TotemError.message("This Aegis export is encrypted. In Aegis, export again with encryption turned off, import, then delete that file.")
        }
        var out: [Account] = []; var skipped = 0
        for e in db["entries"] as? [[String: Any]] ?? [] {
            guard e["type"] as? String == "totp", let info = e["info"] as? [String: Any] else { skipped += 1; continue }
            out.append(Account(issuer: e["issuer"] as? String ?? "", label: e["name"] as? String ?? "",
                               secret: info["secret"] as? String ?? "", algorithm: (try? OTPAlgorithm(loose: info["algo"] as? String)) ?? .SHA1,
                               digits: info["digits"] as? Int ?? 6, period: info["period"] as? Int ?? 30))
        }
        return .accounts(kind: "Aegis", accounts: out, skipped: skipped)
    }

    private static func twofas(_ json: [String: Any]) throws -> ImportResult {
        if json["servicesEncrypted"] != nil {
            throw TotemError.message("This 2FAS backup is password-protected. Export it again without a password, import, then delete that file.")
        }
        var out: [Account] = []; var skipped = 0
        for s in json["services"] as? [[String: Any]] ?? [] {
            let otp = s["otp"] as? [String: Any] ?? [:]
            if let t = otp["tokenType"] as? String, t != "TOTP" { skipped += 1; continue }
            out.append(Account(issuer: otp["issuer"] as? String ?? s["name"] as? String ?? "",
                               label: otp["account"] as? String ?? otp["label"] as? String ?? "",
                               secret: s["secret"] as? String ?? "",
                               algorithm: (try? OTPAlgorithm(loose: otp["algorithm"] as? String)) ?? .SHA1,
                               digits: otp["digits"] as? Int ?? 6, period: otp["period"] as? Int ?? 30))
        }
        return .accounts(kind: "2FAS", accounts: out, skipped: skipped)
    }

    private static func bitwarden(_ json: [String: Any]) throws -> ImportResult {
        if json["encrypted"] as? Bool == true {
            throw TotemError.message("This Bitwarden export is encrypted. Export as unencrypted JSON, import, then delete that file.")
        }
        var out: [Account] = []; var skipped = 0
        for item in json["items"] as? [[String: Any]] ?? [] {
            guard let login = item["login"] as? [String: Any], let t = login["totp"] as? String, !t.isEmpty else { continue }
            var a: Account
            if t.hasPrefix("otpauth://") {
                guard let p = try? OTPAuth.parse(t) else { skipped += 1; continue }
                a = p
                if a.issuer.isEmpty { a.issuer = item["name"] as? String ?? "" }
            } else if t.hasPrefix("steam://") { skipped += 1; continue }
            else { a = Account(issuer: item["name"] as? String ?? "", label: login["username"] as? String ?? "", secret: t) }
            if let uris = login["uris"] as? [[String: Any]], let u = uris.first?["uri"] as? String, let host = URL(string: u)?.host {
                a.domains = [host.hasPrefix("www.") ? String(host.dropFirst(4)) : host]
            }
            out.append(a)
        }
        return .accounts(kind: "Bitwarden", accounts: out, skipped: skipped)
    }

    public static func plainExport(_ accounts: [Account]) -> String {
        (["# Totem plain export — THESE ARE UNENCRYPTED SECRETS. Delete this file after use."] + accounts.map(OTPAuth.uri) + [""])
            .joined(separator: "\n")
    }
}
