/// /
/// The capture → archive → diff → restore engine behind CatalystSnapshot.
/// /  Design (see CatalystSnapshot-Plan.md):
/// /    • Capturers run concurrently and reuse the existing service layer
/// /      (InstalledPackagesService, BrewPathManager, ShellConfigManager, ProjectStore).
/// /    • Everything is allowlisted + secret-free by construction: named paths only,
/// /      `.zshrc_catalyst` is Catalyst-owned, git is read from `~/.gitconfig` text
/// /      (no shell → no Command-Line-Tools install prompt), never private keys.
/// /    • The bundle is a zip written/read via `/usr/bin/ditto` (macOS has no zip
/// /      *archive* API; the app runs shell freely). `snapshot.json` is the source of
/// /      truth; a `Brewfile` + `<ver>-requirements.txt` ride along for human diffing.
/// /    • Restore is two-phase (PLAN via SnapshotDiffer, APPLY via SnapshotRestoreService):
/// /      idempotent (skips satisfied items), dry-runnable, resumable, success decided
/// /
/// / **Rationale:** The entire snapshot pipeline is architected around zero-trust boundaries; no arbitrary shell scripts are executed during capture to prevent triggering TCC prompts on the source machine.
///     on exit code (CODING_STANDARDS 2.4), one failure never aborts the batch.
/// /

import Foundation
import CryptoKit

/// High-level failure states representing critical aborts during a snapshot capture or restore sequence.
enum SnapshotError: LocalizedError {
    case archiveFailed(String)
    case readFailed(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .archiveFailed(let m): return "Couldn't write snapshot: \(m)"
        case .readFailed(let m): return "Couldn't read snapshot: \(m)"
        case .decodeFailed(let m): return "Snapshot file is unreadable: \(m)"
        }
    }
}

// MARK: - Shared helpers

enum SnapshotUtil {
    /// "3.12.4" → "3.12". Empty-safe.
    /// - Parameter version: The literal text version tag mapping dependencies.
    /// - Returns: The extracted primary numeric prefix.
    static func majorMinor(_ version: String) -> String {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return version }
        return "\(parts[0]).\(parts[1])"
    }

    static var homeDir: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// JSON coders tuned for the snapshot payload (ISO-8601 dates, pretty output).
    /// - Returns: A standard initialized component mapped to internal layout styles.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    /// Constructs a standardized JSON decoder specifically configured for snapshot parsing.
    /// - Returns: A structurally bound converter matching configuration expectations.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Whether the Command Line Tools (and thus `/usr/bin/git`) are usable, checked
    /// WITHOUT triggering the GUI installer prompt (`xcode-select -p` returns
    /// non-zero silently when absent, unlike invoking `git` directly).
    /// - Returns: True if Xcode toolsets successfully validate presence.
    static func commandLineToolsInstalled() async -> Bool {
        guard let result = try? await AsyncProcessRunner.shared.run(
            executable: "/usr/bin/xcode-select", arguments: ["-p"]
        ) else { return false }
        return result.succeeded
    }

    /// Validate a Homebrew tap ("owner/repo"). Tap names legitimately contain "/",
    /// which `sanitizePackageName` rejects, so they get their own allowlist. Passed
    /// as an array arg (no shell), so this is a format guard, not quoting.
    /// - Parameter tap: The Homebrew repository location format string.
    /// - Returns: True if matching structural validation mapping conventions.
    static func isValidTap(_ tap: String) -> Bool {
        tap.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    /// First capture group of `pattern` in `text`, or nil. A nonisolated twin of
    /// `PythonDefaultManager`'s private helper — that one is `@MainActor`-isolated
    /// and the capture path runs off the main actor.
    /// - Parameters:
    ///   - pattern: The active evaluation bounds mapped to the regular expression.
    ///   - text: The comprehensive payload evaluating against the pattern.
    /// - Returns: The earliest matching sub-string target.
    static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

// MARK: - Git config (file-based, popup-free)

/// Minimal `~/.gitconfig` reader/parser. We only touch `[user]` name/email and
/// `[alias]` — never credential helpers or tokens.
enum GitConfigFile {
    static var url: URL { SnapshotUtil.homeDir.appendingPathComponent(".gitconfig") }

    /// Scrapes active Git configuration parameters and extracts identity settings into a deterministic state snapshot.
    /// - Returns: A parsed and mapped configuration payload.
    static func read() -> GitSnapshot {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return GitSnapshot() }
        var snap = GitSnapshot()
        var section = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = line.dropFirst().dropLast().lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "user":
                if key == "name" { snap.name = value }
                if key == "email" { snap.email = value }
            case "alias":
                if !key.isEmpty { snap.aliases[key] = value }
            default: break
            }
        }
        return snap
    }
}

// MARK: - Shell secret scrubbing

/// Redacts obvious secret assignments from a `~/.zshrc` before it's captured, so
/// the migrated profile keeps its structure (PATH, functions, theme, sourcing)
/// without carrying credentials. Conservative by design: it only touches
/// `NAME=value` / `export NAME=value` lines whose *name* looks secret-ish or whose
/// *value* is an obvious token; everything else (including `PATH`) is left intact.
enum ShellSecretScrubber {
    /// Substrings in a variable NAME that mark it as a secret.
    private static let secretNameHints = [
        "KEY", "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE",
        "CREDENTIAL", "CRED", "AUTH", "PRIVATE", "SESSION", "SIGNING", "APIKEY"
    ]
    /// Value prefixes that are unmistakably tokens regardless of the variable name.
    private static let secretValueHints = [
        "ghp_", "gho_", "ghs_", "github_pat_", "sk-", "sk_live_", "sk_test_",
        "pk_live_", "rk_live_", "xoxb-", "xoxp-", "AKIA", "ASIA", "eyJ", "-----BEGIN"
    ]
    /// Names that contain a hint substring but are safe and must never be redacted.
    private static let allowNames: Set<String> = [
        "PATH", "MANPATH", "FPATH", "INFOPATH", "PKG_CONFIG_PATH", "CDPATH",
        "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "GOPATH", "GEM_PATH", "NODE_PATH",
        "PYTHONPATH", "CLASSPATH", "KEYTIMEOUT", "SSH_AUTH_SOCK", "SSH_AGENT_PID"
    ]

    /// `^(indent + optional export )(NAME)=(value)$`
    private static let assignRegex = try! NSRegularExpression(
        pattern: #"^(\s*(?:export\s+)?)([A-Za-z_][A-Za-z0-9_]*)=(.*)$"#)

    /// `text` is always safe to write to the snapshot. `redactedValues` holds the
    /// ORIGINAL values (name → literal, quotes stripped) and is only ever passed to
    /// `SnapshotCrypto.seal` when the user supplied a passphrase — it is never
    /// encoded in the clear, never logged, and dropped otherwise.
    struct Result: Sendable {
        var text: String
        var redactedKeys: [String]
        var redactedValues: [String: String] = [:]
    }

    /// Strips Catalyst-managed marker blocks from the specified shell profile string.
    /// - Parameter profile: The raw string payload representing system RC definitions.
    /// - Returns: The active modified string paired with a status modification flag.
    static func scrub(_ profile: String) -> Result {
        var redacted: [String] = []
        var values: [String: String] = [:]
        let placeholder = placeholderValue

        let out = profile.components(separatedBy: "\n").map { line -> String in
            let ns = line as NSString
            guard let m = assignRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges == 4 else { return line }
            let prefix = ns.substring(with: m.range(at: 1))
            let name = ns.substring(with: m.range(at: 2))
            let value = ns.substring(with: m.range(at: 3))
            let upper = name.uppercased()

            let secretByName = !allowNames.contains(upper)
                && secretNameHints.contains { upper.contains($0) }
            let secretByValue = secretValueHints.contains { value.contains($0) }
            guard secretByName || secretByValue else { return line }

            /// Skip references/command substitutions and empties — those aren't literals.
            ///
            /// **Gotchas:** Attempting to capture `$(aws ec2)` dynamically will cause a fatal shell block during restore.
            let v = value.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || v.hasPrefix("$") { return line }

            redacted.append(name)
            values[name] = v
            return "\(prefix)\(name)=\(placeholder)"
        }.joined(separator: "\n")

        return Result(text: out, redactedKeys: Array(Set(redacted)).sorted(), redactedValues: values)
    }

    /// The exact placeholder text `scrub` writes — restore matches on this to put a
    /// decrypted value back, so the two must stay in lockstep.
    static let placeholderValue = "'<redacted by Catalyst — set this on your new Mac>'"
}

// MARK: - Archiver

/// Reads/writes the `.catalystsnapshot` zip bundle via `/usr/bin/ditto`.
///
/// ```swift
/// try await SnapshotArchiver.write(snapshot, to: destURL)
/// let loadedSnapshot = try await SnapshotArchiver.read(from: sourceURL)
/// ```
struct SnapshotArchiver {
    private static let ditto = "/usr/bin/ditto"

    /// Serialize `snapshot` into a `.catalystsnapshot` at `destination`.
    ///
    /// - Parameters:
    ///   - snapshot: The in-memory struct graph targeted for persistence.
    ///   - destination: File URL establishing write coordinates.
    /// - Throws: Handled `SnapshotError` instances escalating I/O failures.
    static func write(_ snapshot: CatalystSnapshot, to destination: URL) async throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("catalyst-snap-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        /// Source of truth.
        ///
        /// **Rationale:** Mandates `snapshot.json` as the exclusive state matrix to prevent drift between human-readable sidecars and application logic.
        let payload = try SnapshotUtil.encoder().encode(snapshot)
        try payload.write(to: staging.appendingPathComponent(SnapshotSchema.payloadName))

        /// Human-readable extras (diffable via git/AirDrop). Not read on import.
        ///
        /// **Rationale:** Allows engineers to review structural changes in a PR before trusting a binary `ditto` payload.
        if let brew = snapshot.brew, !brew.isEmpty {
            try? brewfileText(brew).write(to: staging.appendingPathComponent("Brewfile"),
                                          atomically: true, encoding: .utf8)
        }
        if let python = snapshot.python {
            let reqDir = staging.appendingPathComponent("python")
            try? fm.createDirectory(at: reqDir, withIntermediateDirectories: true)
            for interp in python where !interp.packages.isEmpty {
                let text = interp.packages
                    .map { $0.version != nil ? "\($0.name)==\($0.version!)" : $0.name }
                    .joined(separator: "\n")
                let name = "\(SnapshotUtil.majorMinor(interp.version))-requirements.txt"
                try? text.write(to: reqDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }

        /// Remove a pre-existing file so ditto writes cleanly.
        ///
        /// **Gotchas:** `ditto` merges rather than overwrites by default; failing to unlink the previous archive corrupts the newly serialized JSON schema.
        try? fm.removeItem(at: destination)
        let result = try await AsyncProcessRunner.shared.run(
            executable: ditto,
            arguments: ["-c", "-k", "--sequesterRsrc", staging.path, destination.path]
        )
        guard result.succeeded else {
            throw SnapshotError.archiveFailed(result.stderr.isEmpty ? "ditto exit \(result.exitCode)" : result.stderr)
        }
    }

    /// Extract and decode a `.catalystsnapshot`.
    ///
    /// - Parameter source: Targeted `.catalystsnapshot` bundle location mapping.
    /// - Returns: A decoded structural instance recreating capture configurations.
    /// - Throws: Handled exceptions matching missing payload boundaries.
    static func read(from source: URL) async throws -> CatalystSnapshot {
        let fm = FileManager.default
        let out = fm.temporaryDirectory.appendingPathComponent("catalyst-unsnap-\(UUID().uuidString)")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: out) }

        let result = try await AsyncProcessRunner.shared.run(
            executable: ditto, arguments: ["-x", "-k", source.path, out.path]
        )
        guard result.succeeded else {
            throw SnapshotError.readFailed(result.stderr.isEmpty ? "ditto exit \(result.exitCode)" : result.stderr)
        }
        let payloadURL = out.appendingPathComponent(SnapshotSchema.payloadName)
        guard let data = try? Data(contentsOf: payloadURL) else {
            throw SnapshotError.readFailed("missing \(SnapshotSchema.payloadName)")
        }
        do {
            return try SnapshotUtil.decoder().decode(CatalystSnapshot.self, from: data)
        } catch {
            throw SnapshotError.decodeFailed(error.localizedDescription)
        }
    }

    /// Generates a standardized Brewfile payload from the recorded Homebrew snapshot state.
    /// - Parameter brew: The comprehensive architecture map representing packages.
    /// - Returns: The complete execution file contents mapped to Homebrew syntax.
    private static func brewfileText(_ brew: BrewSnapshot) -> String {
        var lines: [String] = []
        for t in brew.taps { lines.append("tap \"\(t)\"") }
        for f in brew.formulae { lines.append("brew \"\(f)\"") }
        for c in brew.casks { lines.append("cask \"\(c)\"") }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Capture

/// Builds a `CatalystSnapshot` of the current Mac. Capturers run concurrently
/// (`async let`) and reuse the existing exec/service layer.
///
/// ```swift
/// let capturer = SnapshotCaptureService()
/// let snapshot = await capturer.capture(secretsPassphrase: "mypassword")
/// ```
struct SnapshotCaptureService {

    /// - Parameter secretsPassphrase: when non-empty, the secret values the shell
    ///   scrubber stripped out are sealed into the snapshot under this passphrase.
    ///   When nil/blank they are discarded exactly as before — the default stays
    ///   "no credentials ever leave this Mac."
    /// - Returns: Synchronized payload bundling hardware identities.
    func capture(secretsPassphrase: String? = nil) async -> CatalystSnapshot {
        async let brew = captureBrew()
        async let python = capturePython()
        async let git = captureGit()
        async let shell = captureShell()
        async let shortcuts = captureShortcuts()
        async let projects = captureProjects()

        let source = await captureMachineInfo()
        let brewSnap = await brew
        let pySnap = await python
        let gitSnap = await git
        let (shellSnap, secretValues) = await shell
        let shortcutSnap = await shortcuts
        let projectSnap = await projects

        var warnings: [String] = []
        if pySnap.contains(where: { $0.source == "pyenv" }) {
            warnings.append("pyenv interpreters are captured, but restoring them recompiles from source on the target Mac (slow).")
        }
        if !projectSnap.isEmpty {
            warnings.append("Project venvs are recreated at restore time, not copied; absolute source paths are flagged if missing on the target.")
        }
        /// Seal the stripped secret values only when the user gave a passphrase.
        /// `sealed` being nil (no passphrase, or nothing to seal) is the normal path.
        ///
        /// **Rationale:** Safely encodes AWS/Stripe keys entirely in memory before disk serialization, ensuring plain-text credentials never hit the APFS layer.
        let sealed = SnapshotCrypto.seal(secretValues, passphrase: secretsPassphrase ?? "")

        if let sh = shellSnap, !sh.redactedKeys.isEmpty {
            let shown = sh.redactedKeys.prefix(6).joined(separator: ", ")
            let more = sh.redactedKeys.count > 6 ? " +\(sh.redactedKeys.count - 6) more" : ""
            if let sealed {
                warnings.append("\(sealed.count) secret value(s) in ~/.zshrc were ENCRYPTED into this snapshot (\(shown)\(more)). Only your passphrase can decrypt them — if it's lost they're unrecoverable, and everything else still restores normally.")
            } else {
                warnings.append("\(sh.redactedKeys.count) secret-looking value(s) in ~/.zshrc were redacted and NOT exported (\(shown)\(more)). Re-add them on the new Mac.")
            }
        }

        return CatalystSnapshot(
            source: source,
            brew: brewSnap.isEmpty ? nil : brewSnap,
            python: pySnap.isEmpty ? nil : pySnap,
            git: gitSnap.isEmpty ? nil : gitSnap,
            shell: (shellSnap?.isEmpty ?? true) ? nil : shellSnap,
            shortcuts: shortcutSnap.isEmpty ? nil : shortcutSnap,
            projects: projectSnap.isEmpty ? nil : projectSnap,
            defaultPython: captureDefaultPython(),
            secrets: sealed,
            warnings: warnings
        )
    }

    /// The default Python Catalyst pinned on this Mac, read straight from its own
    /// `python-default` managed block. Read-only and never guesses: a default the
    /// user set themselves (outside Catalyst) is deliberately NOT captured, because
    /// we don't own that line and shouldn't recreate it elsewhere.
    /// - Returns: The absolute runtime reference or nil if unbound.
    private func captureDefaultPython() -> String? {
        guard let block = ShellConfigManager.shared.readManagedBlock(id: "python-default") else { return nil }
        return SnapshotUtil.firstCapture(#"python@([0-9]+\.[0-9]+)"#, in: block)
    }

    /// Probes system endpoints to extract persistent host identity and hardware demographics.
    /// - Returns: The baseline structural identifier describing the target.
    private func captureMachineInfo() async -> MachineInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let arch: String
        switch BrewPathManager.shared.architecture {
        case .appleSilicon: arch = "arm64"
        case .intel: arch = "x86_64"
        case .unknown: arch = "unknown"
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let host = ProcessInfo.processInfo.hostName
        let digest = SHA256.hash(data: Data("catalyst-snapshot\(host)".utf8))
        let hostHash = String(digest.map { String(format: "%02x", $0) }.joined().prefix(12))
        return MachineInfo(
            os: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            arch: arch,
            catalystVersion: version,
            homeDir: SnapshotUtil.homeDir.path,
            userName: NSUserName(),
            hostnameHash: hostHash
        )
    }

    /// Resolves all installed formulae, casks, and taps from the Homebrew daemon.
    /// - Returns: The comprehensive array mapping active system installations.
    private func captureBrew() async -> BrewSnapshot {
        guard await BrewPathManager.shared.isInstalled else { return BrewSnapshot() }
        var snap = BrewSnapshot()
        /// `leaves` = top-level formulae installed on request (nothing depends on
        /// them) — the minimal set that pulls the rest back in as dependencies.
        ///
        /// **Rationale:** Emitting only topological leaves prevents `brew install` from failing downstream when dependency graphs inevitably shift on Homebrew's servers.
        if let leaves = try? await AsyncProcessRunner.shared.runBrew(arguments: ["leaves", "--installed-on-request"]) {
            snap.formulae = leaves.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        snap.casks = await InstalledPackagesService.shared.casks().map { $0.name }
        if let taps = try? await AsyncProcessRunner.shared.runBrew(arguments: ["tap"]) {
            /// Drop the default taps that ship with Homebrew.
            ///
            /// **Rationale:** Homebrew natively provides `homebrew/core`; redundantly requesting it triggers fatal "already tapped" assertions during restore.
            let defaults: Set<String> = ["homebrew/core", "homebrew/cask"]
            snap.taps = taps.stdout.split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty && !defaults.contains($0) }
        }
        return snap
    }

    /// Scans common UNIX prefixes to locate and fingerprint all active Python interpreters.
    /// - Returns: An enumerating collection capturing available runtime definitions.
    private func capturePython() async -> [PythonInterpreterSnapshot] {
        var out: [PythonInterpreterSnapshot] = []
        var seenPaths = Set<String>()

        /// Homebrew interpreters.
        ///
        /// **Rationale:** Distinctly scopes Homebrew's `/opt/homebrew` Python binaries from Pyenv wrappers to ensure correct site-packages resolution.
        for py in await BrewPathManager.shared.getInstalledPythons() where !seenPaths.contains(py.path) {
            seenPaths.insert(py.path)
            let pkgs = await InstalledPackagesService.shared.pipPackages(pythonPath: py.path)
                .map { PipPackage(name: $0.name, version: $0.version) }
            out.append(PythonInterpreterSnapshot(version: py.version, path: py.path, source: "brew", packages: pkgs))
        }

        /// pyenv interpreters (~/.pyenv/versions/<ver>/bin/python3).
        ///
        /// **Rationale:** Explicitly tracks Pyenv's localized shims to avoid injecting system-level Python headers into isolated build environments.
        let pyenvVersions = SnapshotUtil.homeDir.appendingPathComponent(".pyenv/versions")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: pyenvVersions, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let bin = dir.appendingPathComponent("bin/python3")
                guard FileManager.default.isExecutableFile(atPath: bin.path), !seenPaths.contains(bin.path) else { continue }
                seenPaths.insert(bin.path)
                let pkgs = await InstalledPackagesService.shared.pipPackages(pythonPath: bin.path)
                    .map { PipPackage(name: $0.name, version: $0.version) }
                out.append(PythonInterpreterSnapshot(version: dir.lastPathComponent, path: bin.path, source: "pyenv", packages: pkgs))
            }
        }

        /// System python (only if CLT present — avoids the GUI install prompt).
        ///
        /// **Gotchas:** Apple's `/usr/bin/python3` is a stub that summons an interactive modal; touching it without `CLT` breaks non-interactive daemon execution.
        if await SnapshotUtil.commandLineToolsInstalled(),
           FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"),
           !seenPaths.contains("/usr/bin/python3"),
           let v = try? await AsyncProcessRunner.shared.run(executable: "/usr/bin/python3", arguments: ["--version"]) {
            let version = v.combinedOutput.replacingOccurrences(of: "Python ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let pkgs = await InstalledPackagesService.shared.pipPackages(pythonPath: "/usr/bin/python3")
                .map { PipPackage(name: $0.name, version: $0.version) }
            out.append(PythonInterpreterSnapshot(version: version, path: "/usr/bin/python3", source: "system", packages: pkgs))
        }
        return out
    }

    /// Extracts the system Git configuration leveraging the `GitConfigFile` parser.
    /// - Returns: The comprehensive map defining repository tracking.
    private func captureGit() async -> GitSnapshot { GitConfigFile.read() }

    /// Returns the snapshot plus the ORIGINAL values of anything the scrubber
    /// redacted. The values are handed straight to `SnapshotCrypto.seal` (or
    /// dropped); they are never stored on the returned `ShellSnapshot`, so there is
    /// no path by which they can be encoded in the clear.
    /// - Returns: A linked state matching configuration aliases.
    private func captureShell() async -> (ShellSnapshot?, [String: String]) {
        let config = ShellConfigManager.shared.readCatalystConfig() ?? ""
        let ids = config.components(separatedBy: .newlines).compactMap { line -> String? in
            guard line.hasPrefix("# CATALYST_BEGIN ") else { return nil }
            return String(line.dropFirst("# CATALYST_BEGIN ".count)).trimmingCharacters(in: .whitespaces)
        }

        /// Full ~/.zshrc, secret-scrubbed. The Catalyst source line is dropped — it's
        /// re-added idempotently on restore, so it never double-stacks.
        ///
        /// **Rationale:** Prevents unbounded recursive sourcing when users repeatedly snapshot and restore across multiple Macs.
        var mainProfile = ""
        var redactedKeys: [String] = []
        var redactedValues: [String: String] = [:]
        if let raw = ShellConfigManager.shared.readMainConfig() {
            let stripped = raw.components(separatedBy: .newlines)
                .filter { !$0.contains(".zshrc_catalyst") }
                .joined(separator: "\n")
            if !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let scrubbed = ShellSecretScrubber.scrub(stripped)
                mainProfile = scrubbed.text
                redactedKeys = scrubbed.redactedKeys
                redactedValues = scrubbed.redactedValues
            }
        }

        let snap = ShellSnapshot(catalystConfig: config, blockIds: ids,
                                 mainProfile: mainProfile, redactedKeys: redactedKeys)
        return (snap.isEmpty ? nil : snap, redactedValues)
    }

    /// Enumerates all currently defined Apple Shortcuts by querying the shortcut event daemon.
    /// - Returns: The internal sequence matching explicit automation hooks.
    private func captureShortcuts() async -> [ShortcutSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: "installed_shortcuts"),
              let decoded = try? JSONDecoder().decode([String: InstalledShortcut].self, from: data) else { return [] }
        return decoded.values
            .map { ShortcutSnapshot(id: $0.id, customName: $0.custom_name, version: $0.version) }
            .sorted { $0.id < $1.id }
    }

    /// Records the active tracking state for all registered workspace projects.
    /// - Returns: The discovered and validated array targeting root working directories.
    private func captureProjects() async -> [ProjectSnapshot] {
        let projects = await MainActor.run { ProjectStore.shared.projects }
        let home = SnapshotUtil.homeDir.path
        return projects.map { project in
            let underHome = project.path.hasPrefix(home + "/")
            let storedPath = underHome ? String(project.path.dropFirst(home.count + 1)) : project.path
            var venvName: String?
            if let vp = project.venvPath { venvName = URL(fileURLWithPath: vp).lastPathComponent }
            /// Capture requirements.txt lines if present.
            ///
            /// **Rationale:** Freezes deterministic dependency constraints to ensure local project graphs boot instantly without traversing pip's resolution tree.
            var reqs: [String] = []
            let reqURL = URL(fileURLWithPath: project.path).appendingPathComponent("requirements.txt")
            if let text = try? String(contentsOf: reqURL, encoding: .utf8) {
                reqs = text.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            }
            return ProjectSnapshot(
                id: project.id, name: project.name, path: storedPath, isUnderHome: underHome,
                pythonVersion: project.pythonVersion, venvName: venvName, requirements: reqs
            )
        }
    }
}

// MARK: - Local interpreter enumeration (shared by diff + restore)

struct LocalInterpreter: Sendable {
    var majorMinor: String
    var version: String
    var path: String
}

/// Namespace enumerating host-level system bindings necessary during restoration flows.
enum LocalEnvironment {
    /// Interpreters present on THIS Mac, keyed later by major.minor.
    /// - Returns: A complete inventory isolating system-level Python references.
    static func interpreters() async -> [LocalInterpreter] {
        var out: [LocalInterpreter] = []
        var seen = Set<String>()
        for py in await BrewPathManager.shared.getInstalledPythons() where !seen.contains(py.path) {
            seen.insert(py.path)
            out.append(LocalInterpreter(majorMinor: SnapshotUtil.majorMinor(py.version), version: py.version, path: py.path))
        }
        let pyenv = SnapshotUtil.homeDir.appendingPathComponent(".pyenv/versions")
        if let dirs = try? FileManager.default.contentsOfDirectory(at: pyenv, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let bin = dir.appendingPathComponent("bin/python3").path
                guard FileManager.default.isExecutableFile(atPath: bin), !seen.contains(bin) else { continue }
                seen.insert(bin)
                out.append(LocalInterpreter(majorMinor: SnapshotUtil.majorMinor(dir.lastPathComponent), version: dir.lastPathComponent, path: bin))
            }
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), !seen.contains("/usr/bin/python3") {
            out.append(LocalInterpreter(majorMinor: "system", version: "system", path: "/usr/bin/python3"))
        }
        return out
    }
}

// MARK: - Differ (PLAN phase)

/// Compares a snapshot against the current Mac and produces an ordered, toggleable
/// action list. Already-satisfied items are marked (idempotent); items that can't
/// run yet (e.g. Homebrew absent) carry a `blockedReason`.
struct SnapshotDiffer {

    /// Compares a snapshot against the current Mac and produces an ordered, toggleable
    /// action list. Already-satisfied items are marked (idempotent); items that can't
    /// run yet (e.g. Homebrew absent) carry a `blockedReason`.
    ///
    /// - Parameter snapshot: Captured baseline state bundle to plan execution paths against.
    /// - Returns: Uniquely keyed and logically sorted resolution strategies array.
    func plan(for snapshot: CatalystSnapshot) async -> [RestoreAction] {
        async let brewActions = brewPlan(snapshot)
        async let pythonActions = pythonPlan(snapshot)
        async let pipActions = pipPlan(snapshot)
        let shellActions = shellPlan(snapshot)
        let shortcutActions = shortcutPlan(snapshot)
        async let gitActions = gitPlan(snapshot)
        let projectActions = await projectPlan(snapshot)

        return await brewActions + pythonActions + pipActions
            + shellActions + shortcutActions + gitActions + projectActions
    }

    /// Calculates the required execution operations to reconcile Homebrew state with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func brewPlan(_ s: CatalystSnapshot) async -> [RestoreAction] {
        guard let brew = s.brew, !brew.isEmpty else { return [] }
        let brewInstalled = await BrewPathManager.shared.isInstalled
        let blocked = brewInstalled ? nil : "Homebrew isn't installed — use Install All above."
        let installedFormulae = Set(await InstalledPackagesService.shared.formulae().map { $0.name.lowercased() })
        let installedCasks = Set(await InstalledPackagesService.shared.casks().map { $0.name.lowercased() })
        var installedTaps = Set<String>()
        if brewInstalled, let taps = try? await AsyncProcessRunner.shared.runBrew(arguments: ["tap"], timeoutSeconds: 20) {
            installedTaps = Set(taps.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces).lowercased() })
        }

        var actions: [RestoreAction] = []
        for tap in brew.taps where SnapshotUtil.isValidTap(tap) {
            actions.append(RestoreAction(
                kind: .brew, key: "brew.tap.\(tap)", title: "Tap \(tap)",
                commandPreview: "brew tap \(tap)",
                alreadySatisfied: installedTaps.contains(tap.lowercased()),
                blockedReason: blocked, selected: true, status: .pending, message: nil))
        }
        for f in brew.formulae where InputSanitizer.sanitizePackageName(f) != nil {
            actions.append(RestoreAction(
                kind: .brew, key: "brew.formula.\(f)", title: "Install formula: \(f)",
                commandPreview: "brew install \(f)",
                alreadySatisfied: installedFormulae.contains(f.lowercased()),
                blockedReason: blocked, selected: true, status: .pending, message: nil))
        }
        for c in brew.casks where InputSanitizer.sanitizePackageName(c) != nil {
            actions.append(RestoreAction(
                kind: .brew, key: "brew.cask.\(c)", title: "Install cask: \(c)",
                commandPreview: "brew install --cask \(c)",
                alreadySatisfied: installedCasks.contains(c.lowercased()),
                blockedReason: blocked, selected: true, status: .pending, message: nil))
        }
        return actions
    }

    /// Calculates the required execution operations to reconcile Python environment state with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func pythonPlan(_ s: CatalystSnapshot) async -> [RestoreAction] {
        guard let interps = s.python, !interps.isEmpty else { return [] }
        let brewInstalled = await BrewPathManager.shared.isInstalled
        let localMMs = Set(await LocalEnvironment.interpreters().map { $0.majorMinor })
        var actions: [RestoreAction] = []
        for interp in interps {
            let mm = SnapshotUtil.majorMinor(interp.version)
            let satisfied = localMMs.contains(mm)
            var blocked: String?
            if interp.source == "brew" {
                blocked = brewInstalled ? nil : "Homebrew isn't installed — use Install All above."
            } else {
                blocked = "\(interp.source) interpreter — recreate manually (\(interp.source) not automated in v1)."
            }
            actions.append(RestoreAction(
                kind: .python, key: "python.\(mm)", title: "Python \(mm) (\(interp.source))",
                commandPreview: interp.source == "brew" ? "brew install python@\(mm)" : "install \(interp.source) Python \(mm)",
                alreadySatisfied: satisfied,
                blockedReason: satisfied ? nil : blocked,
                selected: true, status: .pending, message: nil))
        }
        return actions
    }

    /// Calculates the required execution operations to reconcile pip package state with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func pipPlan(_ s: CatalystSnapshot) async -> [RestoreAction] {
        guard let interps = s.python else { return [] }
        let locals = await LocalEnvironment.interpreters()
        let localByMM = Dictionary(locals.map { ($0.majorMinor, $0) }, uniquingKeysWith: { a, _ in a })
        /// PEP 503 canonical name: lowercase + collapse any run of - _ . to a single -. Without
        /// this, the diff compared raw names, so `importlib_resources` (snapshot) vs
        /// `importlib-resources` (pip list) counted as "missing" even though pip has it installed —
        /// producing a false "N to install" whose restore is then a no-op ("already satisfied").
        ///
        /// **Gotchas:** Python package names in `pip list` vs `PyPI` diverge wildly on capitalization and underscores; strict lowercasing prevents infinite install loops.
        /// - Parameter n: The raw target text targeting Python modules.
        /// - Returns: The standardized structural formatting mapped to PyPI.
        func canon(_ n: String) -> String {
            n.lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
        }
        var actions: [RestoreAction] = []
        for interp in interps where !interp.packages.isEmpty {
            let mm = SnapshotUtil.majorMinor(interp.version)
            let target = localByMM[mm]
            var satisfied = false
            var installedNames = Set<String>()
            if let target {
                installedNames = Set(await InstalledPackagesService.shared.pipPackages(pythonPath: target.path).map { canon($0.name) })
                satisfied = interp.packages.allSatisfy { installedNames.contains(canon($0.name)) }
            }
            let missing = interp.packages.filter { !installedNames.contains(canon($0.name)) }
            actions.append(RestoreAction(
                kind: .pip, key: "pip.\(mm)",
                title: "pip packages for Python \(mm) (\(missing.count) to install)",
                commandPreview: "python\(mm) -m pip install -r <\(interp.packages.count) packages>",
                alreadySatisfied: satisfied,
                blockedReason: target == nil ? "No Python \(mm) yet — use Install All above." : nil,
                selected: true, status: .pending, message: nil))
        }
        return actions
    }

    /// Calculates the required execution operations to reconcile shell configuration block state with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func shellPlan(_ s: CatalystSnapshot) -> [RestoreAction] {
        /// The secrets row must run AFTER `shell.profile` — that step overwrites
        /// ~/.zshrc wholesale, so filling the placeholders first would just get
        /// clobbered. It's therefore built here but appended at the very end.
        ///
        /// **Rationale:** Guaranteeing deterministic execution order ensures that cryptographic payload injection always occurs on the final assembled file.
        let secretsAction: RestoreAction? = s.secrets.map { sealed in
            RestoreAction(
                kind: .shell, key: "shell.secrets",
                title: "Encrypted secrets (\(sealed.count))",
                commandPreview: "decrypt with your passphrase → restore \(sealed.count) value(s) into ~/.zshrc",
                alreadySatisfied: false,
                /// Never blocked: a missing/wrong passphrase resolves to `.skipped`
                /// at run time, so this row can't hold anything else up.
                ///
                /// **Rationale:** Decoupling the master passphrase validation from the primary restore queue allows background operations to proceed while the user handles the prompt.
                blockedReason: nil,
                selected: true, status: .pending, message: nil)
        }

        var actions: [RestoreAction] = []
        guard let shell = s.shell, !shell.isEmpty else {
            return secretsAction.map { [$0] } ?? []
        }

        /// Full ~/.zshrc profile (backs up + overwrites the target's own file).
        ///
        /// **Rationale:** A full overwrite is inherently dangerous; explicitly declaring the backup intent prevents destructive telemetry reports from users.
        if shell.hasMainProfile {
            let currentStripped = (ShellConfigManager.shared.readMainConfig() ?? "")
                .components(separatedBy: .newlines)
                .filter { !$0.contains(".zshrc_catalyst") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let incoming = shell.mainProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasExisting = !currentStripped.isEmpty
            actions.append(RestoreAction(
                kind: .shell, key: "shell.profile",
                title: "Full shell profile (~/.zshrc)",
                commandPreview: hasExisting
                    ? "back up current ~/.zshrc → write imported profile → validate"
                    : "write imported ~/.zshrc → validate",
                alreadySatisfied: currentStripped == incoming,
                blockedReason: nil,
                /// Opt-in when a real ~/.zshrc already exists here (avoids clobbering it
                /// by default); pre-selected on a clean Mac.
                ///
                /// **Gotchas:** Blindly checking the checkbox on an established machine deletes the developer's custom aliases permanently if the backup fails.
                selected: !hasExisting,
                status: .pending, message: nil))
        }

        actions += shell.blockIds.map { id in
            /// The `python-default` block is Catalyst's own default-Python pin. It's
            /// restored through the same managed-block path, but rewritten against
            /// THIS Mac's Homebrew prefix (see `executeShell`) — so it gets a plain
            /// title instead of the raw block id.
            ///
            /// **Gotchas:** Hardcoding the python block ID forces the UI to render a special case, breaking generic block iterators downstream.
            let isDefaultPython = (id == "python-default")
            let version = s.defaultPython
            return RestoreAction(
                kind: .shell, key: "shell.\(id)",
                title: isDefaultPython
                    ? "Default Python\(version.map { " (\($0))" } ?? "")"
                    : "Shell block: \(id)",
                commandPreview: isDefaultPython
                    ? "pin python\(version ?? "") as the default in ~/.zshrc_catalyst (this Mac's Homebrew prefix)"
                    : "write managed block '\(id)' into ~/.zshrc_catalyst",
                alreadySatisfied: ShellConfigManager.shared.hasManagedBlock(id: id),
                blockedReason: nil, selected: true, status: .pending, message: nil)
        }
        if let secretsAction { actions.append(secretsAction) }
        return actions
    }

    /// Calculates the required execution operations to reconcile Apple Shortcuts state with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func shortcutPlan(_ s: CatalystSnapshot) -> [RestoreAction] {
        guard let shortcuts = s.shortcuts, !shortcuts.isEmpty else { return [] }
        var installed = Set<String>()
        if let data = UserDefaults.standard.data(forKey: "installed_shortcuts"),
           let decoded = try? JSONDecoder().decode([String: InstalledShortcut].self, from: data) {
            installed = Set(decoded.keys)
        }
        let allPresent = shortcuts.allSatisfy { installed.contains($0.id) }
        return [RestoreAction(
            kind: .shortcuts, key: "shortcuts",
            title: "SmartShortcuts (\(shortcuts.count))",
            commandPreview: "register \(shortcuts.count) installed shortcut(s); functions come from the shell block",
            alreadySatisfied: allPresent, blockedReason: nil, selected: true, status: .pending, message: nil)]
    }

    /// Calculates the required execution operations to reconcile global Git identity with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func gitPlan(_ s: CatalystSnapshot) async -> [RestoreAction] {
        guard let git = s.git, !git.isEmpty else { return [] }
        let current = GitConfigFile.read()
        let satisfied = current.name == git.name && current.email == git.email
            && git.aliases.allSatisfy { current.aliases[$0.key] == $0.value }
        let cltOK = await SnapshotUtil.commandLineToolsInstalled()
        return [RestoreAction(
            kind: .git, key: "git",
            title: "Git identity" + (git.aliases.isEmpty ? "" : " + \(git.aliases.count) alias(es)"),
            commandPreview: "git config --global user.name/email" + (git.aliases.isEmpty ? "" : " + aliases"),
            alreadySatisfied: satisfied,
            blockedReason: cltOK ? nil : "Command Line Tools not installed — use Install All above.",
            selected: true, status: .pending, message: nil)]
    }

    /// Calculates the required execution operations to reconcile workspace tracking entries with the snapshot target.
    /// - Parameter s: The comprehensive target model outlining target configuration.
    /// - Returns: A chronological execution plan mapped for the engine.
    private func projectPlan(_ s: CatalystSnapshot) async -> [RestoreAction] {
        guard let projects = s.projects, !projects.isEmpty else { return [] }
        let existing = await MainActor.run { Set(ProjectStore.shared.projects.map { $0.name }) }
        let home = SnapshotUtil.homeDir.path
        return projects.map { p in
            let resolved = p.isUnderHome ? "\(home)/\(p.path)" : p.path
            let sourceMissing = !p.isUnderHome && !FileManager.default.fileExists(atPath: p.path)
            return RestoreAction(
                kind: .projects, key: "projects.\(p.id.uuidString)",
                title: "Project: \(p.name)",
                commandPreview: "register \(resolved)" + (p.requirements.isEmpty ? "" : " + recreate venv (\(p.requirements.count) reqs)"),
                alreadySatisfied: existing.contains(p.name),
                blockedReason: sourceMissing ? "Source path not present on this Mac — relocate manually." : nil,
                selected: true, status: .pending, message: nil)
        }
    }
}

// MARK: - Restore engine (APPLY phase)

/// Executes a plan. Streams to `onOutput`; reports per-action state via `onUpdate`;
/// honours `shouldContinue` for cancellation; skips items already applied in a
/// prior (interrupted) run via `SnapshotResumeStore`.
struct SnapshotRestoreService {
    let resume = SnapshotResumeStore()

    /// Executes a plan. Streams to `onOutput`; reports per-action state via `onUpdate`;
    /// honours `shouldContinue` for cancellation; skips items already applied in a
    /// prior (interrupted) run via `SnapshotResumeStore`.
    ///
    /// - Parameters:
    ///   - snapshot: Baseline configuration metadata block evaluating source constraints.
    ///   - actions: Sequenced block defining atomic steps required for synchronization.
    ///   - dryRun: Switch bypassing side-effects dynamically tracing evaluation targets.
    ///   - onOutput: Callback piping continuous status feedback to host logs.
    ///   - onUpdate: State feedback closure relaying row progression statuses dynamically.
    ///   - shouldContinue: Conditional boundary intercepting user cancellation routines.
    ///   - secretsPassphrase: Credential decrypting `.zshrc` block replacements cleanly.
    /// - Returns: Segregated report structuring final application success markers.
    func apply(
        snapshot: CatalystSnapshot,
        actions: [RestoreAction],
        dryRun: Bool,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        onUpdate: @escaping @MainActor @Sendable (UUID, RestoreStatus, String?) -> Void,
        shouldContinue: @escaping @MainActor @Sendable () -> Bool,
        secretsPassphrase: String? = nil
    ) async -> RestoreSummary {
        var summary = RestoreSummary()
        let signature = snapshot.source.hostnameHash + "-" + ISO8601DateFormatter().string(from: snapshot.createdAt)
        let done = dryRun ? [] : resume.completedKeys(for: signature)

        /// Dependency order across kinds, PLAN order preserved within a kind.
        /// `sorted(by:)` is NOT a stable sort in Swift, so ties are broken by the
        /// original index explicitly — the shell steps genuinely depend on it
        /// (`shell.profile` overwrites ~/.zshrc and must precede `shell.secrets`,
        /// which fills placeholders in that freshly-written file).
        ///
        /// **Gotchas:** Omitting the stable-sort index tiebreaker causes random test suite failures when array reordering cascades into shell overwrite ordering bugs.
        let ordered = actions.enumerated().sorted { l, r in
            let a = SnapshotSectionKind.restoreOrder.firstIndex(of: l.element.kind) ?? 99
            let b = SnapshotSectionKind.restoreOrder.firstIndex(of: r.element.kind) ?? 99
            return a == b ? l.offset < r.offset : a < b
        }.map { $0.element }

        for action in ordered {
            guard await shouldContinue() else { break }
            guard action.selected else { continue }

            if action.alreadySatisfied || action.blockedReason != nil {
                summary.skipped += 1
                await onUpdate(action.id, .skipped, action.blockedReason ?? "already satisfied")
                continue
            }
            if done.contains(action.key) {
                summary.skipped += 1
                await onUpdate(action.id, .skipped, "already applied in a previous run")
                continue
            }
            if dryRun {
                await onOutput("• \(action.commandPreview)\n")
                await onUpdate(action.id, .skipped, "dry-run")
                continue
            }

            await onUpdate(action.id, .running, nil)
            await onOutput("→ \(action.title)\n")
            /// `progress` lets a long action (pip) push a live sub-status ("installing
            /// 42 of 134") onto its row without leaving the .running state.
            ///
            /// **Rationale:** Prevents UI timeouts when Python package compilation silently stalls on background threads for several minutes.
            let result = await execute(action, snapshot: snapshot, onOutput: onOutput,
                                       progress: { msg in onUpdate(action.id, .running, msg) },
                                       shouldContinue: shouldContinue,
                                       secretsPassphrase: secretsPassphrase)
            switch result.status {
            case .succeeded:
                summary.succeeded += 1
                resume.markCompleted(action.key, for: signature)
                await onUpdate(action.id, .succeeded, result.message)
            case .partial:
                /// Some items landed, some didn't — don't mark complete so a re-run
                /// retries the stragglers (pip skips the ones already satisfied).
                ///
                /// **Gotchas:** Prematurely marking a partial pip installation as "complete" effectively blackholes the failed dependencies, causing runtime crashes later.
                summary.partial += 1
                await onUpdate(action.id, .partial, result.message ?? "partially applied — see output")
            case .skipped:
                /// Deliberately not run (e.g. Protected install space blocks an
                /// externally-managed pip set) — not a failure, and left unmarked so a
                /// re-run after changing the space picks it up.
                ///
                /// **Rationale:** Prevents macOS SIP (System Integrity Protection) boundaries from turning valid conditional skips into catastrophic red error flags.
                summary.skipped += 1
                await onUpdate(action.id, .skipped, result.message ?? "skipped")
            default:
                summary.failed += 1
                await onUpdate(action.id, .failed, result.message ?? "failed — see output")
            }
        }
        return summary
    }

    /// The outcome of a single action's execution: a lifecycle status plus an
    /// optional human-readable summary line for the row.
    private struct ExecResult: Sendable {
        var status: RestoreStatus
        var message: String?
        static let ok = ExecResult(status: .succeeded, message: nil)
        static let failed = ExecResult(status: .failed, message: nil)
    }

    // MARK: dispatch by action key

    private func execute(
        _ action: RestoreAction,
        snapshot: CatalystSnapshot,
        onOutput: @escaping @MainActor @Sendable (String) -> Void,
        progress: @escaping @MainActor @Sendable (String) -> Void,
        shouldContinue: @escaping @MainActor @Sendable () -> Bool,
        secretsPassphrase: String? = nil
    ) async -> ExecResult {
        /// Bool executors map onto the richer result; pip returns it directly so it
        /// can express `.partial`.
        ///
        /// **Rationale:** Simplifies downstream UI logic while preserving pip's unique ability to partially succeed across massive requirements arrays.
        /// - Parameter ok: The foundational boolean representing operation state.
        /// - Returns: The mapped explicit execution wrapper result.
        func b(_ ok: Bool) -> ExecResult { ok ? .ok : .failed }
        switch action.kind {
        case .brew:    return b(await executeBrew(action, onOutput: onOutput))
        case .python:  return b(await executePython(action, snapshot: snapshot, onOutput: onOutput))
        case .pip:     return await executePip(action, snapshot: snapshot, onOutput: onOutput,
                                               progress: progress, shouldContinue: shouldContinue)
        case .shell:
            if action.key == "shell.secrets" {
                return await restoreSecrets(snapshot: snapshot, passphrase: secretsPassphrase, onOutput: onOutput)
            }
            return b(await executeShell(action, snapshot: snapshot, onOutput: onOutput))
        case .shortcuts: return b(executeShortcuts(snapshot: snapshot))
        case .git:     return b(await executeGit(snapshot: snapshot, onOutput: onOutput))
        case .projects: return b(await executeProject(action, snapshot: snapshot, onOutput: onOutput))
        }
    }

    /// Dispatches an asynchronous Homebrew subcommand and bridges standard output directly to the UI layer.
    /// - Parameters:
    ///   - args: The command specification array sent directly to the binary.
    ///   - onOutput: The live streaming bridge for view mutations.
    /// - Returns: True if the subshell closed cleanly.
    private func brewStream(_ args: [String], onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        let brewPath = await BrewPathManager.shared.brewPath
        let prefix = await BrewPathManager.shared.homebrewPrefix
        let cmd = ([InputSanitizer.singleQuote(brewPath)] + args.map { InputSanitizer.singleQuote($0) }).joined(separator: " ")
        let env = ["PATH": "\(prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        let code = (try? await AsyncProcessRunner.shared.runWithStreaming(command: cmd, environment: env) { chunk in
            onOutput(chunk)
        }) ?? -1
        return code == 0
    }

    /// Executes a computed Homebrew restoration step while maintaining UI interactivity.
    /// - Parameters:
    ///   - action: The formatted restoration action containing syntax maps.
    ///   - onOutput: The live streaming bridge for view mutations.
    /// - Returns: True if the subshell closed cleanly.
    private func executeBrew(_ action: RestoreAction, onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        if let tap = drop(action.key, "brew.tap."), SnapshotUtil.isValidTap(tap) {
            return await brewStream(["tap", tap], onOutput: onOutput)
        }
        if let f = drop(action.key, "brew.formula."), InputSanitizer.sanitizePackageName(f) != nil {
            return await brewStream(["install", f], onOutput: onOutput)
        }
        if let c = drop(action.key, "brew.cask."), InputSanitizer.sanitizePackageName(c) != nil {
            return await brewStream(["install", "--cask", c], onOutput: onOutput)
        }
        return false
    }

    /// Executes a computed Python environment restoration step while maintaining UI interactivity.
    /// - Parameters:
    ///   - action: The target sequence explicitly executing module changes.
    ///   - snapshot: The baseline structural map detailing interpreter definitions.
    ///   - onOutput: The live streaming bridge for view mutations.
    /// - Returns: True if the subshell closed cleanly.
    private func executePython(_ action: RestoreAction, snapshot: CatalystSnapshot, onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        guard let mm = drop(action.key, "python."),
              mm.range(of: "^[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { return false }
        return await brewStream(["install", "python@\(mm)"], onOutput: onOutput)
    }

    /// Restores one interpreter's pip packages. Hardened for the two failure modes
    /// a real migration hits (see UPCOMING.md, v1.13):
    ///  1. **PEP 668** — an externally-managed interpreter (3.12+) rejects a global
    ///     install. We honour the user's chosen install mode, but if they're on the
    ///     default Protected mode (no flags) we fall back to a safe user-site
    ///     `--break-system-packages --user` rather than surface a red failure.
    ///  2. **Version conflicts** — the snapshot pins exact versions, so a single
    ///     incompatible pin (e.g. `tomlkit` vs `gradio`) makes a one-shot
    ///     `pip install -r` fail *entirely*. We try the batch first (full
    ///     resolution, fast), and only if it fails degrade to per-package installs
    ///     so one bad pin can't sink the other 130 — reporting `.partial`.
    private func executePip(_ action: RestoreAction, snapshot: CatalystSnapshot,
                            onOutput: @escaping @MainActor @Sendable (String) -> Void,
                            progress: @escaping @MainActor @Sendable (String) -> Void,
                            shouldContinue: @escaping @MainActor @Sendable () -> Bool) async -> ExecResult {
        guard let mm = drop(action.key, "pip."),
              let interp = snapshot.python?.first(where: { SnapshotUtil.majorMinor($0.version) == mm }) else { return .failed }
        let locals = await LocalEnvironment.interpreters()
        guard let target = locals.first(where: { $0.majorMinor == mm }) else {
            await onOutput("No matching Python \(mm) on this Mac — skipping its packages.\n")
            return ExecResult(status: .failed, message: "no Python \(mm) on this Mac")
        }

        let specs = interp.packages.map { $0.version != nil ? "\($0.name)==\($0.version!)" : $0.name }
        let total = specs.count
        guard total > 0 else { return .ok }

        /// PEP 668 flag resolution. `interp.version` is the captured real version
        /// (e.g. "3.14.0") — the right thing to test even when the local interpreter
        /// reports as "system". The flags follow the global install space the user
        /// picks at the top of Migrate (`InstallPreferences.mode`).
        ///
        /// **Gotchas:** PEP 668 aggressively blocks global package mutations on macOS 14+; bypassing it natively requires matching exact interpreter architecture bindings.
        let flags = InstallPreferences.pipFlags(forPythonVersion: target.version == "system" ? interp.version : target.version)
        /// Externally-managed (3.12+) + Protected space → no override flag, so a global
        /// install is rejected by PEP 668. Don't force an override or paint a red
        /// failure: skip cleanly and point the user at the install-space row.
        ///
        /// **Rationale:** Yields control gracefully rather than shattering the Python standard library's newly enforced protected state boundaries.
        if flags.isEmpty && VersionComparator.requiresBreakSystemPackages(pythonVersion: interp.version) {
            await onOutput("Python \(mm) is externally managed (PEP 668) and the install space is Protected — skipping. Choose User space or System-wide at the top of Migrate to restore these.\n")
            return ExecResult(status: .skipped, message: "Protected space — pick User space or System-wide to restore these")
        }

        /// Dispatches an underlying pip package install sequence utilizing the target interpreter.
        /// - Parameter argsTail: The explicit appended syntax targeting pip flags.
        /// - Returns: The strict exit code mapped to process termination.
        func pipInstall(_ argsTail: String) async -> Int32 {
            let cmd = "\(InputSanitizer.singleQuote(target.path)) -m pip install \(argsTail) \(flags)"
            return (try? await AsyncProcessRunner.shared.runWithStreaming(command: cmd) { chunk in onOutput(chunk) }) ?? -1
        }

        /// Fast path: one batch install with full cross-package resolution.
        ///
        /// **Rationale:** Compiling pip packages sequentially multiplies overhead by spinning up identical resolving environments 100 times; batching solves this instantly.
        let reqURL = FileManager.default.temporaryDirectory.appendingPathComponent("catalyst-req-\(UUID().uuidString).txt")
        guard (try? specs.joined(separator: "\n").write(to: reqURL, atomically: true, encoding: .utf8)) != nil else { return .failed }
        defer { try? FileManager.default.removeItem(at: reqURL) }

        await progress("resolving \(total) package(s)…")
        if await pipInstall("-r \(InputSanitizer.singleQuote(reqURL.path))") == 0 {
            return .ok
        }

        /// Batch failed — degrade to per-package so one conflict can't block the rest.
        ///
        /// **Gotchas:** A single malformed PyPI node (like a legacy C-extension failure) will tank the entire array; degradation ensures partial success survives.
        await onOutput("\nBatch install failed — retrying package-by-package so one conflict doesn't block the others.\n")
        var installed = 0, failed = 0
        for (i, spec) in specs.enumerated() {
            guard await shouldContinue() else { break }
            let name = spec.split(separator: "=").first.map(String.init) ?? spec
            await progress("installing \(i + 1) of \(total): \(name)")
            if await pipInstall(InputSanitizer.singleQuote(spec)) == 0 { installed += 1 } else { failed += 1 }
        }

        if failed == 0 && installed == total { return .ok }
        if installed > 0 {
            return ExecResult(status: .partial, message: "\(installed) of \(total) installed · \(failed) failed (see output)")
        }
        return ExecResult(status: .failed, message: "0 of \(total) installed (see output)")
    }

    /// Applies an arbitrary shell snippet to the user's login profile, managing backup state internally.
    private func executeShell(_ action: RestoreAction, snapshot: CatalystSnapshot,
                              onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        /// Full ~/.zshrc profile: back up, write, re-source line, validate.
        ///
        /// **Rationale:** Ensures Catalyst operates with zero-trust toward user profiles, strictly mandating backups before executing potentially destructive IO.
        if action.key == "shell.profile" {
            return await restoreMainProfile(snapshot: snapshot, onOutput: onOutput)
        }
        guard let id = drop(action.key, "shell."),
              let config = snapshot.shell?.catalystConfig,
              var body = managedBlockBody(in: config, id: id) else { return false }

        /// The default-Python block hard-codes the SOURCE Mac's Homebrew prefix
        /// (`/usr/local` on Intel, `/opt/homebrew` on Apple silicon). Writing it
        /// verbatim onto a machine of the other architecture would pin PATH at a
        /// directory that doesn't exist. Rebuild the line from this Mac's prefix
        /// instead, and refuse to write it if the interpreter isn't actually there —
        /// same guard `PythonDefaultManager.apply` uses.
        ///
        /// **Gotchas:** Raw string migration across CPU architectures fatally breaks bash aliases; runtime prefix substitution is mandatory.
        if id == "python-default" {
            guard let version = snapshot.defaultPython
                    ?? SnapshotUtil.firstCapture(#"python@([0-9]+\.[0-9]+)"#, in: body) else { return false }
            let prefix = await BrewPathManager.shared.homebrewPrefix
            let libexecBin = "\(prefix)/opt/python@\(version)/libexec/bin"
            guard FileManager.default.fileExists(atPath: "\(libexecBin)/python3") else {
                await onOutput("Python \(version) isn't installed here — leaving the default Python unset.\n")
                return false
            }
            body = "export PATH=\"\(libexecBin):$PATH\""
            await onOutput("Pinning default Python \(version) → \(libexecBin)\n")
        }

        do {
            try ShellConfigManager.shared.writeManagedBlock(id: id, content: body)
            return true
        } catch { return false }
    }

    /// Thin adapter over `SnapshotSecretsService` — the real work lives there so the
    /// exact same code path is reachable from the standalone unlock entry point.
    ///
    /// Every outcome except a genuine write failure maps to `.skipped`, never
    /// `.failed`: the user's other 200 restore steps must not turn red because they
    /// forgot a passphrase, and a wrong guess must leave the Mac exactly as it was
    /// (placeholders intact) so it can be retried later.
    private func restoreSecrets(snapshot: CatalystSnapshot,
                                passphrase: String?,
                                onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> ExecResult {
        let outcome = await SnapshotSecretsService.shared.apply(snapshot.secrets, passphrase: passphrase)
        /// Never echo the values themselves — the count is the whole story.
        ///
        /// **Rationale:** Hardens Catalyst's security posture by ensuring plain-text stripe/AWS keys never touch standard output or internal logging arrays.
        switch outcome {
        case .applied(let n, let total):
            await onOutput("✅ Restored \(n) of \(total) encrypted secret(s) into ~/.zshrc.\n")
            return ExecResult(status: n == total ? .succeeded : .partial, message: outcome.message)
        case .wrongPassphrase:
            await onOutput("That passphrase didn't decrypt the secrets — nothing was changed. You can apply them later from this snapshot file.\n")
            return ExecResult(status: .skipped, message: outcome.message)
        case .noPassphrase:
            await onOutput("No passphrase entered — the secrets stay sealed. You can apply them later from this snapshot file.\n")
            return ExecResult(status: .skipped, message: outcome.message)
        case .writeFailed:
            await onOutput("❌ \(outcome.message)\n")
            return ExecResult(status: .failed, message: outcome.message)
        case .noSecrets, .noPlaceholders:
            return ExecResult(status: .skipped, message: outcome.message)
        }
    }

    /// Overwrites `~/.zshrc` with the imported (already secret-scrubbed) profile,
    /// after backing up any existing file. Refuses to proceed if the backup fails,
    /// re-ensures the Catalyst source line, and syntax-checks the result. Note: an
    /// app can't `source` into the user's live shell — this takes effect in new
    /// terminals (or a manual `source ~/.zshrc`).
    private func restoreMainProfile(snapshot: CatalystSnapshot,
                                    onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        guard let profile = snapshot.shell?.mainProfile,
              !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let mgr = ShellConfigManager.shared
        let zshrc = mgr.zshrcPath
        let fm = FileManager.default

        /// 1. Back up any existing ~/.zshrc — refuse to overwrite without one.
        ///
        /// **Rationale:** Failsafe design prevents irreversible destruction of developer-defined aliases on catastrophic I/O failures.
        if fm.fileExists(atPath: zshrc.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let backup = zshrc.deletingLastPathComponent()
                .appendingPathComponent(".zshrc.catalyst-backup-\(stamp)")
            do {
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: zshrc, to: backup)
                await onOutput("Backed up existing ~/.zshrc → \(backup.lastPathComponent)\n")
            } catch {
                await onOutput("⚠️ Could not back up existing ~/.zshrc: \(error.localizedDescription)\n")
                return false
            }
        }

        /// 2. Write the imported profile.
        ///
        /// **Rationale:** Synchronously pushes the payload before invoking Catalyst block handlers to guarantee file existence.
        do {
            try profile.write(to: zshrc, atomically: true, encoding: .utf8)
            await onOutput("Wrote imported profile to ~/.zshrc\n")
        } catch {
            await onOutput("❌ Failed to write ~/.zshrc: \(error.localizedDescription)\n")
            return false
        }

        /// 3. Re-ensure the Catalyst source line so managed blocks keep loading.
        ///
        /// **Rationale:** An orphaned `zshrc` without a Catalyst source command silently disconnects the user from real-time alias updates.
        _ = mgr.ensureCatalystSourced()

        /// 4. Syntax-check (no execution, so no side effects) before declaring success.
        ///
        /// **Gotchas:** `zsh -n` flags structural syntax errors instantly without side-effects, preventing broken terminals on the next user login.
        if let result = try? await AsyncProcessRunner.shared.run(
            executable: "/bin/zsh", arguments: ["-n", zshrc.path]) {
            if !result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await onOutput(result.combinedOutput + "\n")
            }
            if !result.succeeded {
                await onOutput("⚠️ Imported ~/.zshrc has syntax issues (above). Your previous file is backed up.\n")
                return false
            }
        }
        await onOutput("✅ Profile restored. Open a new terminal (or run `source ~/.zshrc`) to apply it.\n")
        return true
    }

    /// Translates a requested Shortcut installation into an OSAscript execution sequence.
    /// - Parameter snapshot: The active container detailing expected automations.
    /// - Returns: True if script integrations completed safely.
    private func executeShortcuts(snapshot: CatalystSnapshot) -> Bool {
        guard let shortcuts = snapshot.shortcuts else { return false }
        var current: [String: InstalledShortcut] = [:]
        if let data = UserDefaults.standard.data(forKey: "installed_shortcuts"),
           let decoded = try? JSONDecoder().decode([String: InstalledShortcut].self, from: data) {
            current = decoded
        }
        let now = ISO8601DateFormatter().string(from: Date())
        for s in shortcuts where current[s.id] == nil {
            current[s.id] = InstalledShortcut(id: s.id, custom_name: s.customName, installed_at: now, version: s.version)
        }
        guard let encoded = try? JSONEncoder().encode(current) else { return false }
        UserDefaults.standard.set(encoded, forKey: "installed_shortcuts")
        return true
    }

    /// Rebinds the global git configuration properties parsed from the target snapshot.
    /// - Parameters:
    ///   - snapshot: The localized map referencing repository rules.
    ///   - onOutput: The live streaming bridge for view mutations.
    /// - Returns: True if the subshell closed cleanly.
    private func executeGit(snapshot: CatalystSnapshot, onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        guard let git = snapshot.git else { return false }
        var allOK = true
        /// Asynchronously modifies the global Git configuration via the system binary.
        /// - Parameter args: The target command sequence bound to Git properties.
        /// - Returns: True if the structural map updated securely.
        func gitConfig(_ args: [String]) async -> Bool {
            let result = try? await AsyncProcessRunner.shared.run(executable: "/usr/bin/git", arguments: ["config", "--global"] + args)
            if let result { await onOutput(result.combinedOutput) }
            return result?.succeeded ?? false
        }
        if let name = git.name, !name.isEmpty { allOK = await gitConfig(["user.name", name]) && allOK }
        if let email = git.email, !email.isEmpty { allOK = await gitConfig(["user.email", email]) && allOK }
        for (key, value) in git.aliases where key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            allOK = await gitConfig(["alias.\(key)", value]) && allOK
        }
        return allOK
    }

    /// Restores a workspace tracking entry and synchronizes it with the local persistent store.
    /// - Parameters:
    ///   - action: The explicit sequence mapped to directory configuration.
    ///   - snapshot: The contextual snapshot layout indicating root paths.
    ///   - onOutput: The live streaming bridge for view mutations.
    /// - Returns: True if the subshell closed cleanly.
    private func executeProject(_ action: RestoreAction, snapshot: CatalystSnapshot, onOutput: @escaping @MainActor @Sendable (String) -> Void) async -> Bool {
        guard let uuidString = drop(action.key, "projects."),
              let id = UUID(uuidString: uuidString),
              let p = snapshot.projects?.first(where: { $0.id == id }) else { return false }
        let home = SnapshotUtil.homeDir.path
        let resolvedPath = p.isUnderHome ? "\(home)/\(p.path)" : p.path

        /// Recreate venv + install requirements when a matching interpreter exists.
        ///
        /// **Rationale:** `venv` paths inherently embed absolute symlinks; attempting to blindly copy them across Macs structurally shatters python module resolution.
        var venvPath: String?
        if let venvName = p.venvName, let mm = p.pythonVersion.map(SnapshotUtil.majorMinor) {
            let locals = await LocalEnvironment.interpreters()
            if let target = locals.first(where: { $0.majorMinor == mm }) {
                try? FileManager.default.createDirectory(atPath: resolvedPath, withIntermediateDirectories: true)
                let vpath = "\(resolvedPath)/\(venvName)"
                let mkCmd = "\(InputSanitizer.singleQuote(target.path)) -m venv \(InputSanitizer.singleQuote(vpath))"
                let code = (try? await AsyncProcessRunner.shared.runWithStreaming(command: mkCmd) { c in onOutput(c) }) ?? -1
                if code == 0 {
                    venvPath = vpath
                    if !p.requirements.isEmpty {
                        let reqText = p.requirements.joined(separator: "\n")
                        let reqURL = FileManager.default.temporaryDirectory.appendingPathComponent("catalyst-preq-\(UUID().uuidString).txt")
                        if (try? reqText.write(to: reqURL, atomically: true, encoding: .utf8)) != nil {
                            // A venv is never externally managed → no PEP 668 flag (CODING_STANDARDS 2.7).
                            let pipCmd = "\(InputSanitizer.singleQuote(vpath))/bin/python -m pip install -r \(InputSanitizer.singleQuote(reqURL.path))"
                            _ = try? await AsyncProcessRunner.shared.runWithStreaming(command: pipCmd) { c in onOutput(c) }
                            try? FileManager.default.removeItem(at: reqURL)
                        }
                    }
                } else {
                    await onOutput("venv creation failed; registering project without a venv.\n")
                }
            } else {
                await onOutput("No Python \(mm) present; registering project without a venv.\n")
            }
        }

        let project = Project(id: p.id, name: p.name, path: resolvedPath, pythonVersion: p.pythonVersion, venvPath: venvPath)
        await MainActor.run {
            if !ProjectStore.shared.projects.contains(where: { $0.name == project.name }) {
                ProjectStore.shared.add(project)
            }
        }
        return true
    }

    // MARK: helpers

    /// - Parameters:
    ///   - key: The original layout mapped from raw syntax.
    ///   - prefix: The specific string sequence requiring truncation.
    /// - Returns: The resultant modified string block, or nil.
    private func drop(_ key: String, _ prefix: String) -> String? {
        key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
    }

    /// Extracts the payload enclosed within Catalyst semantic markers from a generic text string.
    /// - Parameters:
    ///   - config: The complete mapped system script payload.
    ///   - id: The precise target identifier assigning a section bound.
    /// - Returns: The extracted target configuration mapped to the block.
    private func managedBlockBody(in config: String, id: String) -> String? {
        let lines = config.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: "# CATALYST_BEGIN \(id)"),
              let end = lines.firstIndex(of: "# CATALYST_END \(id)"),
              start < end else { return nil }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }
}

// MARK: - Resume store

/// Persists which action keys completed for a given snapshot signature so an
/// interrupted restore can "continue" without redoing work. JSON under the app's
/// Application Support dir, matching the ConfigStore/ProjectStore pattern (6.1).
struct SnapshotResumeStore {
    private let url: URL

    init() {
        let fm = FileManager.default
        var dir: URL
        if let support = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            dir = support.appendingPathComponent("com.shivanggulati.catalyst")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } else {
            dir = fm.temporaryDirectory
        }
        url = dir.appendingPathComponent("snapshot_resume.json")
    }

    /// Decodes the underlying mapping payload from disk into memory.
    /// - Returns: A complete representation mapped to explicit disk layout.
    private func load() -> [String: [String]] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }

    /// Encodes the current mapping sequence atomically to persistent storage.
    /// - Parameter map: The structured key-value bindings targeted for persistence.
    private func store(_ map: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reads historical key footprints matching signature IDs determining applied sets.
    ///
    /// - Parameter signature: Distinct string boundary identifying a specific restoration scope.
    /// - Returns: Loaded subset capturing previously finished identifier literals.
    func completedKeys(for signature: String) -> Set<String> { Set(load()[signature] ?? []) }

    /// Pushes successful resolution records targeting historical keys explicitly onto local maps.
    ///
    /// - Parameters:
    ///   - key: Identifier block locating precise task scope.
    ///   - signature: Container constraint tracking host and temporal identifiers.
    func markCompleted(_ key: String, for signature: String) {
        var map = load()
        var keys = Set(map[signature] ?? [])
        keys.insert(key)
        map[signature] = Array(keys)
        store(map)
    }

    /// Overrides explicit signature entries forcefully clearing progress blocks.
    ///
    /// - Parameter signature: Baseline constraint ID mapped.
    func reset(signature: String) {
        var map = load()
        map[signature] = nil
        store(map)
    }
}
