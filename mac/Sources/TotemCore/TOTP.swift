import Foundation
import CryptoKit

public enum TotemError: LocalizedError, Equatable {
    case invalidSecret(String)
    case unsupported(String)
    case notAVault
    case badVersion(Int)
    case kdfMismatch
    case badPassword
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSecret(let s): return s
        case .unsupported(let s): return s
        case .notAVault: return "Not a Totem vault file"
        case .badVersion(let v): return "Unsupported vault version \(v)"
        case .kdfMismatch: return "This vault was locked with a different password setup"
        case .badPassword: return "Wrong password or damaged vault"
        case .message(let s): return s
        }
    }
}

public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func normalize(_ s: String) -> String {
        var out = s.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        while out.hasSuffix("=") { out.removeLast() }
        return out
    }

    public static func decode(_ input: String) throws -> Data {
        let s = normalize(input)
        guard !s.isEmpty else { throw TotemError.invalidSecret("Secret is empty") }
        var bits = 0, value = 0
        var out = Data()
        for ch in s {
            guard let idx = alphabet.firstIndex(of: ch) else {
                throw TotemError.invalidSecret("Invalid Base32 character \"\(ch)\"")
            }
            value = ((value << 5) | idx) & 0xFFFF
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out
    }

    public static func encode(_ data: Data) -> String {
        var bits = 0, value = 0
        var out = ""
        for b in data {
            value = ((value << 8) | Int(b)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }
}

public enum OTPAlgorithm: String, Codable, CaseIterable {
    case SHA1, SHA256, SHA512

    public init(loose: String?) throws {
        let k = (loose ?? "SHA1").uppercased().filter { $0.isLetter || $0.isNumber }
        guard let a = OTPAlgorithm(rawValue: k.isEmpty ? "SHA1" : k) else {
            throw TotemError.unsupported("Unsupported algorithm \(loose ?? "")")
        }
        self = a
    }
}

public struct OTPCode: Equatable {
    public let code: String
    public let next: String
    public let remaining: Int
    public let period: Int
}

public enum TOTP {
    public static func hotp(secret: String, counter: UInt64, algorithm: OTPAlgorithm = .SHA1, digits: Int = 6) throws -> String {
        let key = SymmetricKey(data: try Base32.decode(secret))
        var be = counter.bigEndian
        let msg = Data(bytes: &be, count: 8)
        let mac: [UInt8]
        switch algorithm {
        case .SHA1: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: key))
        case .SHA256: mac = Array(HMAC<SHA256>.authenticationCode(for: msg, using: key))
        case .SHA512: mac = Array(HMAC<SHA512>.authenticationCode(for: msg, using: key))
        }
        let off = Int(mac[mac.count - 1] & 0x0F)
        let bin = (UInt32(mac[off] & 0x7F) << 24) | (UInt32(mac[off + 1]) << 16) | (UInt32(mac[off + 2]) << 8) | UInt32(mac[off + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        let s = String(bin % mod)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    public static func code(for a: Account, at date: Date = Date()) throws -> OTPCode {
        let period = max(1, a.period)
        let t = Int(date.timeIntervalSince1970)
        let step = UInt64(t / period)
        let code = try hotp(secret: a.secret, counter: step, algorithm: a.algorithm, digits: a.digits)
        let next = try hotp(secret: a.secret, counter: step + 1, algorithm: a.algorithm, digits: a.digits)
        return OTPCode(code: code, next: next, remaining: period - (t % period), period: period)
    }
}
