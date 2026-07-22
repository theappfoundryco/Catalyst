import Foundation

// MARK: - Models

/// One SSH key pair discovered in `~/.ssh`.
struct SSHKey: Identifiable, Sendable {
    var id: String { privatePath ?? publicPath ?? name }
    let name: String                 // base filename, e.g. "id_ed25519"
    let type: String                 // ED25519 / RSA / ECDSA / DSA
    let bits: Int
    let fingerprint: String          // SHA256:…
    let comment: String
    let privatePath: String?
    let publicPath: String?
    let publicKeyContent: String?
    /// Private-key file mode == 0o600 (nil when there's no private key).
    let privatePermsOK: Bool?

    var hasPublicKey: Bool { publicPath != nil }

    /// RSA below 2048 bits is considered weak.
    var isWeak: Bool { type.uppercased() == "RSA" && bits < 2048 }
}

/// Snapshot of the user's SSH key directory.
struct SSHKeyReport: Sendable {
    let scanDate: Date
    let dirExists: Bool
    /// `~/.ssh` mode == 0o700.
    let dirPermsOK: Bool
    let keys: [SSHKey]
}

/// Result of a key-generation attempt.
struct SSHKeyGenResult: Sendable {
    let success: Bool
    let message: String
}

/// Lists, generates, and hardens SSH keys in `~/.ssh`. Uses `ssh-keygen` and
/// direct file reads; no privileges. Complements `SecurityDoctor`'s checks.
///
/// ```swift
/// let report = await SSHKeyService.shared.scan()
/// for key in report.keys {
///     print(key.name)
/// }
/// ```
final class SSHKeyService: Sendable {

    static let shared = SSHKeyService()
    private init() {}

    private let runner = AsyncProcessRunner.shared
    private let sshKeygenPath = "/usr/bin/ssh-keygen"
    private let chmodPath = "/bin/chmod"

    private var sshDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    }

    // MARK: - Scan

    /// Discovers existing SSH entities and flags standard directory permissions limits.
    ///
    /// - Returns: A payload encapsulating fingerprint data strings alongside native filesystem checks.
    func scan() async -> SSHKeyReport {
        let fm = FileManager.default
        let dirExists = fm.fileExists(atPath: sshDir.path)
        guard dirExists else {
            return SSHKeyReport(scanDate: Date(), dirExists: false, dirPermsOK: false, keys: [])
        }

        var dirPermsOK = false
        if let attrs = try? fm.attributesOfItem(atPath: sshDir.path),
           let perms = attrs[.posixPermissions] as? Int {
            dirPermsOK = (perms & 0o777) == 0o700
        }

        let contents = (try? fm.contentsOfDirectory(atPath: sshDir.path)) ?? []

        /// Determine the set of key "bases": every .pub, plus id_* private files.
        ///
        /// **Rationale:** Apple inherently groups SSH key components into pairs. Scanning globally prevents orphan tracking when users delete just the `.pub` file.
        var bases = Set<String>()
        for name in contents {
            if name.hasSuffix(".pub") {
                bases.insert(String(name.dropLast(4)))
            } else if name.hasPrefix("id_") {
                bases.insert(name)
            }
        }

        var keys: [SSHKey] = []
        for base in bases {
            let privateURL = sshDir.appendingPathComponent(base)
            let publicURL = sshDir.appendingPathComponent(base + ".pub")
            let hasPrivate = fm.fileExists(atPath: privateURL.path)
            let hasPublic = fm.fileExists(atPath: publicURL.path)
            guard hasPrivate || hasPublic else { continue }

            let inspectPath = hasPublic ? publicURL.path : privateURL.path
            guard let info = await fingerprintInfo(path: inspectPath) else { continue }

            var pubContent: String?
            if hasPublic {
                pubContent = (try? String(contentsOf: publicURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var privatePermsOK: Bool?
            if hasPrivate, let attrs = try? fm.attributesOfItem(atPath: privateURL.path),
               let perms = attrs[.posixPermissions] as? Int {
                privatePermsOK = (perms & 0o777) == 0o600
            }

            keys.append(SSHKey(
                name: base,
                type: info.type,
                bits: info.bits,
                fingerprint: info.fingerprint,
                comment: info.comment,
                privatePath: hasPrivate ? privateURL.path : nil,
                publicPath: hasPublic ? publicURL.path : nil,
                publicKeyContent: pubContent,
                privatePermsOK: privatePermsOK
            ))
        }

        keys.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return SSHKeyReport(scanDate: Date(), dirExists: true, dirPermsOK: dirPermsOK, keys: keys)
    }

    /// A transient container defining key cryptographic footprints parsed from standard output.
    private struct FingerprintInfo { let bits: Int; let fingerprint: String; let comment: String; let type: String }

    /// Parses `ssh-keygen -l -f <path>` → "<bits> SHA256:… <comment> (TYPE)".
    ///
    /// - Parameter path: Explicit location pointing to target file configuration blocks.
    /// - Returns: Discovered bit-level architecture attributes and keys mapped back into generic types.
    private func fingerprintInfo(path: String) async -> FingerprintInfo? {
        do {
            let r = try await runner.run(executable: sshKeygenPath, arguments: ["-l", "-f", path], timeoutSeconds: 6)
            guard r.succeeded else { return nil }
            let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }

            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, let bits = Int(parts[0]) else { return nil }
            let fingerprint = parts[1]

            var type = "Unknown"
            if let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
                type = String(line[line.index(after: open)..<close])
            }

            var comment = ""
            if parts.count >= 3 {
                var rest = parts[2]
                if let open = rest.range(of: " (") { rest = String(rest[..<open.lowerBound]) }
                comment = rest.trimmingCharacters(in: .whitespaces)
            }

            return FingerprintInfo(bits: bits, fingerprint: fingerprint, comment: comment, type: type)
        } catch {
            return nil
        }
    }

    // MARK: - Generate

    /// Generates a new key. Refuses to overwrite an existing file.
    ///
    /// - Parameters:
    ///   - type: "ed25519" or "rsa".
    ///   - fileName: base name written to `~/.ssh`.
    ///   - comment: `-C` comment.
    ///   - passphrase: empty string ⇒ no passphrase.
    /// - Returns: Explicit result configuration blocks reporting CLI execution success markers.
    func generate(type: String, fileName: String, comment: String, passphrase: String) async -> SSHKeyGenResult {
        let fm = FileManager.default

        /// Ensure ~/.ssh exists at 0o700.
        ///
        /// **Rationale:** Prevents catastrophic `ssh-keygen` failures by bootstrapping the base directory infrastructure before attempting cryptographic generation.
        if !fm.fileExists(atPath: sshDir.path) {
            try? fm.createDirectory(at: sshDir, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }

        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespaces)
        guard !safeName.isEmpty else {
            return SSHKeyGenResult(success: false, message: "Please provide a file name.")
        }
        let keyURL = sshDir.appendingPathComponent(safeName)
        guard !fm.fileExists(atPath: keyURL.path) else {
            return SSHKeyGenResult(success: false, message: "A key named “\(safeName)” already exists. Choose another name.")
        }

        var args = ["-t", type, "-f", keyURL.path, "-N", passphrase]
        if !comment.trimmingCharacters(in: .whitespaces).isEmpty {
            args.append(contentsOf: ["-C", comment])
        }
        if type == "rsa" { args.append(contentsOf: ["-b", "4096"]) }

        do {
            let r = try await runner.run(executable: sshKeygenPath, arguments: args, timeoutSeconds: 30)
            if r.succeeded {
                /// ssh-keygen already sets 0o600; enforce defensively.
                ///
                /// **Gotchas:** Apple's `ssh-keygen` implementation drops permissions down if the user's umask is configured securely, but strict enforcement ensures 100% compliance.
                _ = try? await runner.run(executable: chmodPath, arguments: ["600", keyURL.path], timeoutSeconds: 5)
                return SSHKeyGenResult(success: true, message: "Created \(safeName) (\(type)).")
            } else {
                let err = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return SSHKeyGenResult(success: false, message: err.isEmpty ? "ssh-keygen failed." : err)
            }
        } catch {
            return SSHKeyGenResult(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Permissions

    /// Rewrites native permission boundaries strictly forcing `~/.ssh` to 0700.
    ///
    /// - Returns: Validation boolean isolating whether execution cleanly modified bounds.
    func fixDirPermissions() async -> Bool {
        let r = try? await runner.run(executable: chmodPath, arguments: ["700", sshDir.path], timeoutSeconds: 5)
        return r?.succeeded ?? false
    }

    /// Modifies individual SSH target limits masking access only directly available strictly to 0600 natively.
    ///
    /// - Parameter key: Evaluated `SSHKey` configuration item mapped internally against paths.
    /// - Returns: Result isolating `chmod` process status blocks.
    func fixKeyPermissions(_ key: SSHKey) async -> Bool {
        guard let priv = key.privatePath else { return false }
        let r = try? await runner.run(executable: chmodPath, arguments: ["600", priv], timeoutSeconds: 5)
        if let pub = key.publicPath {
            _ = try? await runner.run(executable: chmodPath, arguments: ["644", pub], timeoutSeconds: 5)
        }
        return r?.succeeded ?? false
    }
}
