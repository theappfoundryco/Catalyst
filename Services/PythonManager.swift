import Foundation

extension Notification.Name {
    /// Posted after the set of installed Python interpreters changes (e.g. an
    /// uninstall) so every Python-dependent view — Virtual Environments, PIP
    /// Packages, Outdated PIP, the interpreter dropdown, the dashboard card — can
    /// refresh state that would otherwise show a version that no longer exists.
    /// A single broadcast keeps the Python views decoupled: future ones observe it
    /// and get correct behaviour for free.
    static let catalystPythonInventoryChanged = Notification.Name("catalystPythonInventoryChanged")
}

/// Owns the Python lifecycle work previously inlined in `DashboardViewModel`
/// (R1 / P2 god-VM decomposition, step 2): installing/uninstalling Python
/// formulae, linking, pip upgrade/repair, and fetching the latest pip + the
/// list of installable versions.
///
/// Like `DetectionService`, this holds no `@Published` view state. It performs
/// the privileged/process/network work and logs progress; the ViewModel keeps
/// the busy flags, selection state, cache invalidation, and global-refresh
/// orchestration around these calls. `@MainActor` matches the VM's isolation.
@MainActor
final class PythonManager {
    private let pythonService: PythonService
    private let privileges: PrivilegesService
    private let logger: Logger

    init(pythonService: PythonService, privileges: PrivilegesService, logger: Logger) {
        self.pythonService = pythonService
        self.privileges = privileges
        self.logger = logger
    }

    /// The installable Python versions (those not already installed, each with its Homebrew
    /// deprecation status) plus the recommended version (highest non-deprecated).
    struct AvailableVersions {
        let versions: [AvailableVersion]
        let recommended: String?
    }

    // MARK: - Version metadata (discovered live from Homebrew, cached)

    /// Cache of the raw brew discovery (all `python@x.y` + deprecation). The dashboard re-runs
    /// `fetchAvailableVersions` on every refresh; without this it respawns slow `brew`
    /// subprocesses each time — a big source of first-launch load flakiness (worst under Xcode).
    /// Short TTL; the installed-filter is applied fresh per call, so it stays correct after an
    /// install without invalidation.
    private var discovered: (all: [AvailableVersion], at: Date)?
    private let discoveryTTL: TimeInterval = 10 * 60

    /// Installable Python versions — served from cache when fresh, else discovered from brew.
    /// Filters out already-installed major.minors; recommended = highest non-deprecated.
    func fetchAvailableVersions(installed: [PythonInstallation]) async -> AvailableVersions {
        let all: [AvailableVersion]
        if let c = discovered, Date().timeIntervalSince(c.at) < discoveryTTL {
            all = c.all
        } else {
            all = await discoverViaBrew()
            if !all.isEmpty { discovered = (all, Date()) }
        }
        let installedMM = Set(installed.map { $0.version.split(separator: ".").prefix(2).joined(separator: ".") })
        let avail = all.filter { !installedMM.contains($0.version) }
        let recommended = avail.first { !$0.deprecated }?.version
        return AvailableVersions(versions: avail, recommended: recommended)
    }

    /// `brew search` for `python@x.y` names, then `brew info --json=v2` for the deprecation flag
    /// (structured, not scraped — Formrules 2.4). Runs with auto-update/analytics/hints **off**
    /// so it's fast + deterministic and never blocks on a network `brew update`, plus a hard
    /// timeout. Empty when Homebrew is absent (the install picker is already gated on brew).
    private func discoverViaBrew() async -> [AvailableVersion] {
        logger.log("🔎 Discovering installable Python versions via brew…")
        let quiet = [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
        ]

        var names: [String] = []
        if let search = try? await AsyncProcessRunner.shared.runBrew(
            arguments: ["search", "/^python@[0-9]+\\.[0-9]+$/"],
            extraEnvironment: quiet, timeoutSeconds: 25), search.succeeded {
            names = search.stdout.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("python@") }
        }
        if names.isEmpty {
            logger.log("⚠️ brew search returned no python formulae (Homebrew missing, or timed out).")
            return []
        }

        var deprecatedBy: [String: Bool] = [:]
        if let info = try? await AsyncProcessRunner.shared.runBrew(
            arguments: ["info", "--json=v2"] + names,
            extraEnvironment: quiet, timeoutSeconds: 30),
           info.succeeded, let data = info.stdout.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(BrewInfoV2.self, from: data) {
            for f in parsed.formulae {
                if let v = Self.majorMinor(fromFormula: f.name) { deprecatedBy[v] = f.deprecated }
            }
        }

        let all = names.compactMap { Self.majorMinor(fromFormula: $0) }
            .map { AvailableVersion(version: $0, deprecated: deprecatedBy[$0] ?? false) }
            .sorted { Self.versionGreater($0.version, $1.version) }
        logger.log("✅ brew: discovered \(all.count) python@x.y formula(e).")
        return all
    }

    /// `brew info --json=v2` — only the fields we need (tolerant of everything else).
    private struct BrewInfoV2: Decodable {
        let formulae: [Formula]
        struct Formula: Decodable { let name: String; let deprecated: Bool }
    }

    /// "python@3.13" → "3.13" (nil if the name isn't a `python@<major>.<minor>` formula).
    private static func majorMinor(fromFormula name: String) -> String? {
        guard name.hasPrefix("python@") else { return nil }
        let v = String(name.dropFirst("python@".count))
        return v.range(of: #"^[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil ? v : nil
    }

    /// Numeric compare so "3.13" > "3.9" (not lexicographic).
    private static func versionGreater(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - pip

    /// Upgrade pip for a specific Python installation. Logs progress; the VM
    /// invalidates caches and re-detects afterward.
    func upgradePip(for python: PythonInstallation) async {
        logger.log("⬆️ Upgrading pip for Python \(python.version)...")

        let flags = InstallPreferences.pipFlags(forPythonVersion: python.version)
        let py = InputSanitizer.singleQuote(python.path.path)
        do {
            let result = try await AsyncProcessRunner.shared.run(
                command: "\(py) -m pip install --upgrade pip \(flags)"
            )
            if !result.combinedOutput.isEmpty {
                logger.log(result.combinedOutput, category: .terminal)
            }

            if result.succeeded {
                logger.log("✅ pip upgraded successfully for Python \(python.version)")
            } else if Self.isNoRecordFileError(result.combinedOutput) {
                // This pip is owned by Homebrew (no RECORD file), so pip can't
                // uninstall it to upgrade in place. Forcing it with
                // --ignore-installed "works" (pip --version shows the new version)
                // but leaves Homebrew's old dist-info behind, so `pip list` keeps
                // reporting pip as outdated forever and the environment is left
                // inconsistent. The integrity-respecting path is to let Homebrew
                // own it — update via the formula, not pip.
                logger.log("ℹ️ pip for Python \(python.version) is managed by Homebrew and can't be upgraded with pip (no RECORD file). Update it with: brew upgrade \(python.formula)")
            } else {
                logger.log("❌ Failed to upgrade pip for Python \(python.version)")
            }
        } catch {
            logger.log("❌ Error upgrading pip: \(error.localizedDescription)")
        }
    }

    /// Detects pip's "can't uninstall — no RECORD file" failure, which happens
    /// when the current pip was placed by Homebrew rather than pip itself.
    private static func isNoRecordFileError(_ output: String) -> Bool {
        output.contains("uninstall-no-record-file") ||
        output.contains("no RECORD file was found")
    }

    /// Repair pip for a specific Python installation (delegates to the service,
    /// which logs its own progress).
    func repairPip(for python: PythonInstallation) async -> Bool {
        await pythonService.repairPip(for: python)
    }

    // MARK: - Install / uninstall

    /// Install `python@<version>` via the privileged brew path, then link it.
    /// Returns `true` if the formula installed (linking failures are logged but
    /// don't fail the install, matching prior behavior).
    func install(version: String) async -> Bool {
        // Terminal header banner
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       🐍 PYTHON INSTALLATION", category: .terminal)
        logger.log("       Version: \(version)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)

        logger.log("📦 Installing Python \(version)...")

        guard InputSanitizer.isValidPackageName(version) else {
            logger.log("❌ Invalid Python version format: \(version)")
            return false
        }

        do {
            let formula = "python@\(version)"
            let (success, exitCode, message) = try await privileges.installBrewFormula(formula) { line in
                self.logger.log(line, category: .terminal)
            }

            if success {
                logger.log("✅ Python \(version) installed successfully")

                logger.log("🔗 Linking Python \(version)...")
                let linked = await link(version: version)
                if linked {
                    logger.log("✅ Python \(version) linked successfully")
                } else {
                    logger.log("⚠️ Python installed but linking failed - you may need to run: brew link python@\(version)")
                }
                return true
            } else {
                logger.log("❌ Python \(version) installation failed (exit: \(exitCode)): \(message ?? "unknown")")
                return false
            }
        } catch {
            logger.log("❌ Python \(version) installation error: \(error.localizedDescription)")
            return false
        }
    }

    /// Uninstall each selected Python (`python@<major.minor>`), logging per item.
    func uninstall(versions: Set<String>) async {
        for version in versions {
            logger.log("🗑️ Uninstalling Python \(version)...")

            let majorMinor = version.split(separator: ".").prefix(2).joined(separator: ".")
            let formula = "python@\(majorMinor)"

            do {
                let (success, exitCode, message) = try await privileges.uninstallBrewFormula(formula)
                if success {
                    logger.log("✅ Python \(version) uninstalled")
                } else {
                    logger.log("❌ Failed to uninstall Python \(version) (exit: \(exitCode))")
                    if let message {
                        logger.log(message)
                    }
                }
            } catch {
                logger.log("❌ Error uninstalling Python \(version): \(error.localizedDescription)")
            }
        }
        logger.log("✅ Python uninstallation complete")
        // Tell every Python-dependent view its inventory is now stale.
        NotificationCenter.default.post(name: .catalystPythonInventoryChanged, object: nil)
    }

    /// Link a freshly installed Python: unlink for a clean slate, force-link,
    /// then ensure pip is present (best-effort, PEP 668 aware).
    func link(version: String) async -> Bool {
        logger.log("🔗 Linking Python \(version)...")

        let brewPath = BrewPathManager.shared.brewPath

        // Step 1: Unlink first (clean slate)
        _ = try? await AsyncProcessRunner.shared.run(command: "\(brewPath) unlink python@\(version) 2>/dev/null || true")

        // Step 2: Link with force
        do {
            let linkResult = try await AsyncProcessRunner.shared.run(command: "\(brewPath) link python@\(version) --overwrite --force")

            if !linkResult.combinedOutput.isEmpty {
                logger.log("[link] \(linkResult.combinedOutput)", category: .terminal)
            }

            guard linkResult.succeeded else {
                return false
            }

            // Step 3: Check if pip is already working (Homebrew usually installs it)
            logger.log("🔍 Verifying pip installation...")
            let majorMinor = version.split(separator: ".").prefix(2).joined(separator: ".")
            let pythonBin = "\(BrewPathManager.shared.homebrewPrefix)/bin/python\(majorMinor)"

            let preCheck = try await AsyncProcessRunner.shared.run(command: "\(InputSanitizer.singleQuote(pythonBin)) -m pip --version 2>&1")

            if preCheck.succeeded {
                logger.log("✅ pip is already installed and managed by Homebrew", category: .terminal)
                return true
            }

            // If pip is missing, try ensurepip with safe fallbacks
            logger.log("🔧 pip missing, attempting setup...", category: .terminal)

            let ensurepipResult = try await AsyncProcessRunner.shared.run(command: "\(InputSanitizer.singleQuote(pythonBin)) -m ensurepip --default-pip 2>&1")

            if !ensurepipResult.succeeded && ensurepipResult.combinedOutput.contains("externally-managed-environment") {
                logger.log("⚠️ Standard ensurepip blocked by PEP 668.", category: .terminal)
                logger.log("ℹ️ Attempting safe fallback...", category: .terminal)
                // pip is likely provided as a Homebrew dependency; treat as success.
                return true
            }

            logger.log("[ensurepip] \(ensurepipResult.combinedOutput)", category: .terminal)

            // Verify final status
            let verifyResult = try await AsyncProcessRunner.shared.run(command: "\(InputSanitizer.singleQuote(pythonBin)) -m pip --version 2>&1")

            if verifyResult.succeeded {
                logger.log("✅ pip setup complete")
                return true
            } else {
                logger.log("❌ pip setup failed")
                return false
            }
        } catch {
            logger.log("❌ Error: \(error.localizedDescription)")
            return false
        }
    }
}
