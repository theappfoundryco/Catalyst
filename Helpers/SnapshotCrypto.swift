/// Passphrase-sealed secrets for `.catalystsnapshot`.
/// SAFETY MODEL (this is the only part of a snapshot that ever holds real
/// credentials, so the rules are strict):
///   • ONLY the secrets blob is encrypted. The rest of the snapshot stays
///     plaintext and inspectable — encrypting it wholesale would make the file
///     un-auditable for no benefit.
///   • The key is derived from a passphrase the user types, with PBKDF2-HMAC-SHA256
///     and a fresh random salt per snapshot. The passphrase is NEVER written to the
///     file, to disk, to the log, or to UserDefaults — it lives only in memory for
///     the duration of the capture / restore.
/// /    • There is no hint, no recovery, and no fallback key. A lost passphrase means
/// /      the secrets are gone. That is the point: the file can be handed to anyone
/// /      and the secrets stay sealed.
/// /    • A wrong passphrase is NON-FATAL. `open` returns nil and the caller skips the
/// /      secrets section — every other section restores exactly as it would have if
/// /      no secrets were ever captured.
/// /
/// / **Rationale:** Strict zero-recovery cryptography guarantees user privacy, while graceful fallback ensures a forgotten password doesn't ruin a full system migration.
/// /  AES-GCM is authenticated, so a wrong key (or a tampered file) fails to open
/// /  rather than yielding garbage plaintext.
/// /
/// / **Gotchas:** Using unauthenticated modes like AES-CBC without a MAC can result in silent decryption failures that silently inject garbage values into keychain items.

import Foundation
import CryptoKit
import CommonCrypto

/// The sealed secrets section of a snapshot. Everything here is safe to store in
/// the clear — salt and nonce are public inputs; only `ciphertext` is sensitive,
/// and it's useless without the passphrase.
///
/// ```swift
/// let secrets = EncryptedSecrets(salt: saltData, ciphertext: encryptedData, rounds: 210000, count: 5)
/// ```
struct EncryptedSecrets: Codable, Sendable {
    /// Random per-snapshot PBKDF2 salt.
    var salt: Data
    /// AES-GCM sealed box, combined form (nonce ‖ ciphertext ‖ tag).
    var ciphertext: Data
    /// PBKDF2 iteration count actually used, so a future build can raise the
    /// default without breaking older files.
    var rounds: Int
    /// How many secrets are inside — shown in the UI so the user knows what's at
    /// stake without needing to decrypt first. Count only; never the names.
    var count: Int
}

/// Cryptographic utilities for sealing and unsealing snapshot secrets.
///
/// ```swift
/// let sealed = SnapshotCrypto.seal(["API_KEY": "123"], passphrase: "password")
/// let secrets = SnapshotCrypto.open(sealed!, passphrase: "password")
/// ```
enum SnapshotCrypto {
    /// OWASP-recommended floor for PBKDF2-HMAC-SHA256. Costs ~0.2s on Apple silicon —
    /// unnoticeable once per capture, expensive enough to make guessing painful.
    static let defaultRounds = 210_000

    /// Derive a 256-bit key from `passphrase` + `salt`.
    /// - Parameters:
    ///   - passphrase: The user-supplied cryptographic entropy.
    ///   - salt: The deterministic binary vector binding key generation.
    ///   - rounds: The aggregate complexity assigned to derivation loops.
    /// - Returns: The resulting cipher object, or nil on mathematical failures.
    private static func deriveKey(passphrase: String, salt: Data, rounds: Int) -> SymmetricKey? {
        let passBytes = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuf -> Int32 in
            guard let saltBase = saltBuf.bindMemory(to: UInt8.self).baseAddress else { return Int32(kCCParamError) }
            return CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passBytes.map { Int8(bitPattern: $0) }, passBytes.count,
                saltBase, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(rounds),
                &derived, derived.count
            )
        }
        guard status == kCCSuccess else { return nil }
        return SymmetricKey(data: Data(derived))
    }

    /// Seal `secrets` (variable name → value) under `passphrase`.
    /// Returns nil on an empty set or a blank passphrase — callers treat that as
    /// "no secrets section", which is a normal, supported snapshot.
    /// - Parameters:
    ///   - secrets: The unencrypted plaintext configuration map.
    ///   - passphrase: The targeted text entropy used for AES initialization.
    /// - Returns: A structurally secure payload mapped to export specifications.
    static func seal(_ secrets: [String: String], passphrase: String) -> EncryptedSecrets? {
        guard !secrets.isEmpty,
              !passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var saltBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else { return nil }
        let salt = Data(saltBytes)
        guard let key = deriveKey(passphrase: passphrase, salt: salt, rounds: defaultRounds),
              let plaintext = try? JSONEncoder().encode(secrets),
              let box = try? AES.GCM.seal(plaintext, using: key),
              let combined = box.combined else { return nil }
        return EncryptedSecrets(salt: salt, ciphertext: combined,
                                rounds: defaultRounds, count: secrets.count)
    }

    /// Open a sealed secrets blob. Returns nil for a wrong passphrase or a tampered
    /// blob — deliberately indistinguishable, and deliberately not an error: the
    /// caller skips the section rather than failing the restore.
    /// - Parameters:
    ///   - sealed: The export layout bridging cipher data with extraction salts.
    ///   - passphrase: The raw text string necessary to compute derivation keys.
    /// - Returns: The fully accessible plaintext configuration map, or nil.
    static func open(_ sealed: EncryptedSecrets, passphrase: String) -> [String: String]? {
        guard !passphrase.isEmpty,
              let key = deriveKey(passphrase: passphrase, salt: sealed.salt, rounds: sealed.rounds),
              let box = try? AES.GCM.SealedBox(combined: sealed.ciphertext),
              let plaintext = try? AES.GCM.open(box, using: key),
              let secrets = try? JSONDecoder().decode([String: String].self, from: plaintext) else { return nil }
        return secrets
    }
}
