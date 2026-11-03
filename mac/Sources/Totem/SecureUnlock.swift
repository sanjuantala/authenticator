import CryptoKit
import Foundation
import LocalAuthentication
import Security
import TotemCore

/// Touch ID unlock, enforced by the Secure Enclave (not just by app code).
///
/// The vault key is encrypted with a key derived from a Secure Enclave P-256 key that was created with
/// `.userPresence`. That private key never leaves the chip and the chip refuses to use it until you pass
/// Touch ID (or your Mac password). The file on disk is useless on any other Mac or without your finger.
enum SecureUnlock {
    private static let file = Paths.support.appendingPathComponent("touchid.key")

    private struct Blob: Codable {
        var se: Data          // Secure Enclave key handle (encrypted by the chip, device-bound)
        var ephemeral: Data   // public half of a one-time key used for the key agreement
        var box: Data         // AES-GCM(vault session) with the agreed key
    }

    static var isAvailable: Bool { SecureEnclave.isAvailable }
    static var isEnrolled: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Store the vault key for Touch ID unlock. Returns false if the Secure Enclave can't be used here.
    @discardableResult
    static func enroll(_ session: VaultSession) -> Bool {
        guard SecureEnclave.isAvailable,
              let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .userPresence], nil) else { return false }
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
            let eph = P256.KeyAgreement.PrivateKey()
            let key = wrapKey(try eph.sharedSecretFromKeyAgreement(with: se.publicKey))
            let box = try AES.GCM.seal(try JSONEncoder().encode(session), using: key).combined ?? Data()
            let blob = Blob(se: se.dataRepresentation, ephemeral: eph.publicKey.rawRepresentation, box: box)
            try JSONEncoder().encode(blob).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return true
        } catch {
            NSLog("Totem: Secure Enclave enrollment failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Asks the Secure Enclave to release the vault key. macOS shows the Touch ID / password prompt.
    static func unlock(reason: String) async -> VaultSession? {
        guard let raw = try? Data(contentsOf: file), let blob = try? JSONDecoder().decode(Blob.self, from: raw) else { return nil }
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Use Password"
        // evaluate first so the prompt shows our reason; the key below is still gated by the chip itself
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return nil }
        do {
            let se = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob.se, authenticationContext: ctx)
            let pub = try P256.KeyAgreement.PublicKey(rawRepresentation: blob.ephemeral)
            let key = wrapKey(try se.sharedSecretFromKeyAgreement(with: pub))
            let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: blob.box), using: key)
            return try JSONDecoder().decode(VaultSession.self, from: plain)
        } catch {
            NSLog("Totem: Secure Enclave unlock failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func remove() { try? FileManager.default.removeItem(at: file) }

    private static func wrapKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("totem-touchid-v1".utf8),
                                       sharedInfo: Data(), outputByteCount: 32)
    }
}
