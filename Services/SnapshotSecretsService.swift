/// /
/// /  The encrypted-secrets step, deliberately extracted OUT of the restore pipeline.
/// /
/// /  WHY THIS IS STANDALONE: applying secrets needs only three things — the
/// /  ciphertext, the passphrase, and placeholder lines still present in `~/.zshrc`.
/// /  It needs no diff, no plan, no dependency ordering, no Homebrew, no Python. When
/// /  it lived only inside `SnapshotRestoreService.apply`, a user who skipped the
/// /  passphrase (or mistyped it) had to redo the entire Migrate journey to try again.
/// /  That was an artificial dependency, not a real one. Everything here is callable
/// /  from the restore pipeline AND directly from a standalone "unlock" entry point.
/// /
/// /  IDEMPOTENT BY CONSTRUCTION: `apply` only rewrites lines whose value is still the
/// /  exact Catalyst placeholder, so running it twice is harmless and a value the user
/// /  has already set by hand is never clobbered. A failed attempt leaves the
/// /  placeholders intact, which is what makes retry-forever possible.
/// /
/// / **Rationale:** Decoupling cryptographic operations ensures the application can attempt password retries instantaneously without tearing down the entire environment state matrix.

import Foundation

/// Orchestrates the extraction and decryption of sensitive environment variables during snapshot capture.
struct SnapshotSecretsService {
    static let shared = SnapshotSecretsService()

    /// The outcome of applying secrets. Only `writeFailed` is a genuine error —
    /// everything else is a normal, recoverable state the user can retry from.
    ///
    /// ```swift
    /// let secretsService = SnapshotSecretsService.shared
    /// let outcome = await secretsService.apply(snapshot.secrets, passphrase: "mypassword")
    /// ```
    enum ApplyOutcome: Sendable, Equatable {
        /// `applied` of `total` placeholders filled.
        case applied(Int, total: Int)
        case noSecrets
        case noPassphrase
        case wrongPassphrase
        case noPlaceholders
        case writeFailed(String)

        /// Human-readable line for the restore row / status banner.
        var message: String {
            switch self {
            case .applied(let n, let total):
                return n == total ? "\(n) secret(s) restored" : "\(n) of \(total) restored"
            case .noSecrets:       return "no secrets in this snapshot"
            case .noPassphrase:    return "no passphrase entered — secrets left sealed"
            case .wrongPassphrase: return "wrong passphrase — secrets left sealed"
            case .noPlaceholders:  return "no placeholders left to fill"
            case .writeFailed(let why): return "couldn't write ~/.zshrc: \(why)"
            }
        }
    }

    // MARK: - Validation

    /// Definitively check a passphrase, WITHOUT touching the Mac.
    ///
    /// This is a real check, not a heuristic: AES-GCM is authenticated, so the tag
    /// either verifies or it doesn't. Returns the number of secrets the passphrase
    /// unlocks, or nil if it's wrong.
    ///
    /// Runs off the main actor — PBKDF2 at 210k rounds takes ~0.2s and would
    /// visibly hitch the UI if done inline on every Validate tap.
    ///
    /// - Parameters:
    ///   - sealed: The `EncryptedSecrets` payload container carrying secure bits.
    ///   - passphrase: Raw candidate string entered by the user.
    /// - Returns: A count of unlocked keys if decryption passes, or `nil` natively.
    func validate(_ sealed: EncryptedSecrets, passphrase: String) async -> Int? {
        guard !passphrase.isEmpty else { return nil }
        return await Task.detached(priority: .userInitiated) {
            SnapshotCrypto.open(sealed, passphrase: passphrase)?.count
        }.value
    }

    // MARK: - Pending detection

    /// How many Catalyst placeholders are still sitting in `~/.zshrc`.
    ///
    /// This is what lets the app find the user instead of the other way round: the
    /// placeholder string is distinctive and self-describing, so we can always tell
    /// there's unfinished business and prompt for it — the user never has to
    /// remember that they skipped the passphrase.
    ///
    /// - Returns: The total integer count of identified placeholders.
    func pendingPlaceholderCount() -> Int {
        guard let text = try? String(contentsOf: ShellConfigManager.shared.zshrcPath, encoding: .utf8) else { return 0 }
        let placeholder = ShellSecretScrubber.placeholderValue
        return text.components(separatedBy: "\n").reduce(into: 0) { count, line in
            if line.hasSuffix(placeholder) { count += 1 }
        }
    }

    // MARK: - Apply

    /// Decrypt and write the real values over the placeholders in `~/.zshrc`.
    ///
    /// - Parameters:
    ///   - sealed: The AES-encrypted backup configuration block.
    ///   - passphrase: The verified text entry key.
    /// - Returns: Enumerated explicit status defining apply progression constraints.
    func apply(_ sealed: EncryptedSecrets?, passphrase: String?) async -> ApplyOutcome {
        guard let sealed else { return .noSecrets }
        guard let passphrase, !passphrase.isEmpty else { return .noPassphrase }
        guard let secrets = await Task.detached(priority: .userInitiated, operation: {
            SnapshotCrypto.open(sealed, passphrase: passphrase)
        }).value else { return .wrongPassphrase }

        let zshrc = ShellConfigManager.shared.zshrcPath
        guard let current = try? String(contentsOf: zshrc, encoding: .utf8) else { return .noPlaceholders }

        var restored = 0
        let placeholder = ShellSecretScrubber.placeholderValue
        let updated = current.components(separatedBy: "\n").map { line -> String in
            /// Only lines still holding the EXACT placeholder are ours to touch.
            ///
            /// **Gotchas:** Replacing arbitrary lines without placeholder validation risks destroying user modifications made manually post-restore.
            guard line.hasSuffix(placeholder) else { return line }
            let head = String(line.dropLast(placeholder.count))
            guard !head.isEmpty, head.hasSuffix("=") else { return line }
            let name = head.dropLast().components(separatedBy: .whitespaces).last ?? ""
            guard let value = secrets[String(name)] else { return line }
            restored += 1
            return head + value
        }.joined(separator: "\n")

        guard restored > 0 else { return .noPlaceholders }
        do {
            try updated.write(to: zshrc, atomically: true, encoding: .utf8)
        } catch {
            return .writeFailed(error.localizedDescription)
        }
        return .applied(restored, total: sealed.count)
    }
}
