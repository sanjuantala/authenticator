import Foundation
import CryptoKit
import CommonCrypto
import Security

// Byte-compatible with extension/lib/vault.js. See docs/VAULT_FORMAT.md.

public struct Account: Codable, Identifiable, Equatable, Hashable {
    public var id: String
    public var issuer: String
    public var label: String
    public var secret: String
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int
    public var domains: [String]
    public var order: Double
    public var pinned: Bool
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deleted: Bool

    public init(id: String = UUID().uuidString.lowercased(), issuer: String, label: String, secret: String,
                algorithm: OTPAlgorithm = .SHA1, digits: Int = 6, period: Int = 30, domains: [String] = [],
                order: Double = 0, pinned: Bool = false, createdAt: Int64 = Vault.nowMs(),
                updatedAt: Int64 = Vault.nowMs(), deleted: Bool = false) {
        self.id = id; self.issuer = issuer; self.label = label; self.secret = secret
        self.algorithm = algorithm; self.digits = digits; self.period = period; self.domains = domains
        self.order = order; self.pinned = pinned; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deleted = deleted
    }

    enum CodingKeys: String, CodingKey { case id, issuer, label, secret, algorithm, digits, period, domains, order, pinned, createdAt, updatedAt, deleted }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
        algorithm = (try? OTPAlgorithm(loose: try c.decodeIfPresent(String.self, forKey: .algorithm))) ?? .SHA1
        digits = Int(try c.decodeIfPresent(Double.self, forKey: .digits) ?? 6)
        period = Int(try c.decodeIfPresent(Double.self, forKey: .period) ?? 30)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        order = try c.decodeIfPresent(Double.self, forKey: .order) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        createdAt = Int64(try c.decodeIfPresent(Double.self, forKey: .createdAt) ?? 0)
        updatedAt = Int64(try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    /** Validates and cleans up an account (same rules as normalizeAccount in JS). */
    public func normalized() throws -> Account {
        if deleted {
            return Account(id: id, issuer: "", label: "", secret: "", createdAt: createdAt, updatedAt: updatedAt, deleted: true)
        }
        var a = self
        a.secret = Base32.normalize(secret)
        _ = try Base32.decode(a.secret)
        a.issuer = issuer.trimmingCharacters(in: .whitespacesAndNewlines)
        a.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        a.digits = [6, 7, 8].contains(digits) ? digits : 6
        a.period = period > 0 ? period : 30
        a.domains = domains.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return a
    }

    public var fingerprint: String { "\(secret)|\(issuer.lowercased())|\(label.lowercased())" }
    public var title: String { issuer.isEmpty ? (label.isEmpty ? "Unnamed" : label) : issuer }
    public var subtitle: String { issuer.isEmpty ? "" : label }
}

public struct VaultData: Codable, Equatable {
    public var accounts: [Account]
    public var updatedAt: Int64

    public init(accounts: [Account] = [], updatedAt: Int64 = Vault.nowMs()) {
        self.accounts = accounts; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case accounts, updatedAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        accounts = try c.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        updatedAt = Int64(try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0)
    }

    public var live: [Account] {
        accounts.filter { !$0.deleted }.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

public struct KDFParams: Codable, Equatable {
    public var alg: String
    public var iterations: Int
    public var salt: String
}

public struct CipherBox: Codable, Equatable {
    public var alg: String
    public var iv: String
    public var data: String
}

public struct Envelope: Codable, Equatable {
    public var format: String
    public var version: Int
    public var kdf: KDFParams
    public var cipher: CipherBox
    public var updatedAt: Int64
    public var device: String

    enum CodingKeys: String, CodingKey { case format, version, kdf, cipher, updatedAt, device }
    public init(format: String, version: Int, kdf: KDFParams, cipher: CipherBox, updatedAt: Int64, device: String) {
        self.format = format; self.version = version; self.kdf = kdf; self.cipher = cipher; self.updatedAt = updatedAt; self.device = device
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        kdf = try c.decode(KDFParams.self, forKey: .kdf)
        cipher = try c.decode(CipherBox.self, forKey: .cipher)
        updatedAt = Int64(try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0)
        device = try c.decodeIfPresent(String.self, forKey: .device) ?? ""
    }
}

/// What we keep while unlocked. `key` never touches disk (except the optional Touch ID Keychain copy).
public struct VaultSession: Codable, Equatable {
    public var key: String        // base64 raw 32-byte key
    public var salt: String       // base64
    public var iterations: Int

    public init(key: String, salt: String, iterations: Int) { self.key = key; self.salt = salt; self.iterations = iterations }

    var symmetricKey: SymmetricKey { SymmetricKey(data: Data(base64Encoded: key) ?? Data()) }
    public func matches(_ env: Envelope) -> Bool { env.kdf.salt == salt && env.kdf.iterations == iterations }
}

public enum Vault {
    public static let format = "totem-vault"
    public static let version = 1
    public static let iterations = 600_000
    static let aad = Data("totem-vault-v1".utf8)

    public static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    public static func deriveKey(password: String, salt: Data, iterations: Int) -> Data {
        let pw = password.precomposedStringWithCanonicalMapping // NFC, same as the extension
        let pwLen = pw.utf8.count
        var out = Data(count: 32)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pwLen,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return out
    }

    public static func createSession(password: String, iterations: Int = Vault.iterations) -> VaultSession {
        let salt = randomBytes(16)
        return VaultSession(key: deriveKey(password: password, salt: salt, iterations: iterations).base64EncodedString(),
                            salt: salt.base64EncodedString(), iterations: iterations)
    }

    public static func session(password: String, for env: Envelope) throws -> VaultSession {
        try check(env)
        guard let salt = Data(base64Encoded: env.kdf.salt) else { throw TotemError.notAVault }
        let s = VaultSession(key: deriveKey(password: password, salt: salt, iterations: env.kdf.iterations).base64EncodedString(),
                             salt: env.kdf.salt, iterations: env.kdf.iterations)
        _ = try open(env, session: s)
        return s
    }

    static func check(_ env: Envelope) throws {
        guard env.format == format else { throw TotemError.notAVault }
        guard env.version == version else { throw TotemError.badVersion(env.version) }
    }

    public static func seal(_ data: VaultData, session: VaultSession, device: String) throws -> Envelope {
        let plain = try JSONEncoder().encode(data)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: session.symmetricKey, nonce: nonce, authenticating: aad)
        let iv = nonce.withUnsafeBytes { Data($0) }
        return Envelope(format: format, version: version,
                        kdf: KDFParams(alg: "PBKDF2-SHA256", iterations: session.iterations, salt: session.salt),
                        cipher: CipherBox(alg: "AES-256-GCM", iv: iv.base64EncodedString(),
                                          data: (box.ciphertext + box.tag).base64EncodedString()),
                        updatedAt: data.updatedAt, device: device)
    }

    public static func open(_ env: Envelope, session: VaultSession) throws -> VaultData {
        try check(env)
        guard session.matches(env) else { throw TotemError.kdfMismatch }
        guard let iv = Data(base64Encoded: env.cipher.iv), let combined = Data(base64Encoded: env.cipher.data),
              combined.count >= 16 else { throw TotemError.badPassword }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                            ciphertext: combined.prefix(combined.count - 16),
                                            tag: combined.suffix(16))
            let plain = try AES.GCM.open(box, using: session.symmetricKey, authenticating: aad)
            var data = try JSONDecoder().decode(VaultData.self, from: plain)
            data.accounts = data.accounts.compactMap { try? $0.normalized() }
            return data
        } catch {
            throw TotemError.badPassword
        }
    }

    // MARK: - merge & edits (same semantics as JS)

    public static func merge(_ a: VaultData, _ b: VaultData) -> VaultData {
        var byId: [String: Account] = [:]
        for acc in a.accounts + b.accounts {
            if let cur = byId[acc.id], cur.updatedAt >= acc.updatedAt { continue }
            byId[acc.id] = acc
        }
        var seen = Set<String>()
        var out: [Account] = []
        for acc in byId.values.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            if acc.deleted { out.append(acc); continue }
            if seen.contains(acc.fingerprint) { continue }
            seen.insert(acc.fingerprint)
            out.append(acc)
        }
        return VaultData(accounts: out, updatedAt: max(a.updatedAt, b.updatedAt))
    }

    public static func same(_ a: VaultData, _ b: VaultData) -> Bool {
        func key(_ d: VaultData) -> [String] { d.accounts.map { "\($0.id)@\($0.updatedAt)" }.sorted() }
        return key(a) == key(b)
    }

    @discardableResult
    public static func add(_ incoming: [Account], to data: inout VaultData) -> (added: Int, skipped: Int) {
        var existing = Set(data.accounts.filter { !$0.deleted }.map(\.fingerprint))
        let now = nowMs()
        var added = 0, skipped = 0
        for raw in incoming {
            var a = raw
            a.id = UUID().uuidString.lowercased(); a.createdAt = now; a.updatedAt = now; a.deleted = false
            guard let n = try? a.normalized() else { skipped += 1; continue }
            if existing.contains(n.fingerprint) { skipped += 1; continue }
            existing.insert(n.fingerprint)
            data.accounts.append(n)
            added += 1
        }
        data.updatedAt = now
        return (added, skipped)
    }

    public static func update(_ id: String, in data: inout VaultData, _ change: (inout Account) -> Void) throws {
        guard let i = data.accounts.firstIndex(where: { $0.id == id }) else { return }
        var a = data.accounts[i]
        change(&a)
        a.updatedAt = nowMs()
        data.accounts[i] = try a.normalized()
        data.updatedAt = a.updatedAt
    }

    public static func delete(_ id: String, in data: inout VaultData) {
        guard let i = data.accounts.firstIndex(where: { $0.id == id }) else { return }
        let now = nowMs()
        data.accounts[i] = Account(id: id, issuer: "", label: "", secret: "", createdAt: data.accounts[i].createdAt,
                                   updatedAt: now, deleted: true)
        data.updatedAt = now
    }

    // MARK: - JSON helpers

    public static func encodeEnvelope(_ env: Envelope, pretty: Bool = true) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try enc.encode(env)
    }

    public static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data) else { throw TotemError.notAVault }
        try check(env)
        return env
    }
}
