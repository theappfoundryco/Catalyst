import Foundation
import SwiftUI
import Combine

/// Represents a Python package with an available upstream version update.
struct OutdatedPackage: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let currentVersion: String
    let newVersion: String
    let type: PackageType  // Uses centralized PackageType from Models/
    let pythonPath: String?
    let pythonVersion: String?
}

/// Shared surface for the two "Outdated packages" view models (pip + brew),
/// which were ~70% duplicated. Conformers supply the package-source specifics
/// (`updatePackage`, `rescanAfterUpdates`); everything else is provided here.
@MainActor
protocol OutdatedUpdating: AnyObject {
    var outdatedPackages: [OutdatedPackage] { get set }
    var isUpdatingAll: Bool { get set }
    var updatingPackage: String? { get set }
    var failedPackages: [OutdatedPackage] { get set }
    var successfulPackages: [OutdatedPackage] { get set }
    /// Packages pip refused to move (a newer version exists but isn't installable
    /// here — a dependency constraint or Python-version limit). Distinct from a
    /// hard failure so the UI can show them as "held back" rather than "failed".
    var heldBackPackages: [OutdatedPackage] { get set }
    /// Human-readable reason per held-back package name (for tooltips/summary).
    var heldBackReasons: [String: String] { get set }
    var showUpdateResults: Bool { get set }
    var lastScanDate: Date? { get set }

    /// Update a single package (pip vs brew specific).
    func updatePackage(_ name: String, type: PackageType) async
    /// Hook run after a batch update — pip re-scans, brew is a no-op.
    func rescanAfterUpdates() async
}

/// Cached formatter for `formattedLastScanDate`. Allocating a `DateFormatter`
/// per access (it was read from `body`) is notoriously expensive (R4).
private enum OutdatedScanDateFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        return f
    }()
}

extension OutdatedUpdating {
    var formattedLastScanDate: String {
        guard let date = lastScanDate else { return "" }
        return OutdatedScanDateFormat.formatter.string(from: date) + " " + (TimeZone.current.abbreviation() ?? "")
    }

    /// Clears the transient state mapping of previously attempted package updates.
    func resetUpdateResults() {
        failedPackages = []
        successfulPackages = []
        heldBackPackages = []
        heldBackReasons = [:]
        showUpdateResults = false
    }

    /// Verifies outbound connectivity to PyPI before attempting package resolution.
    func hasNetworkConnection() async -> Bool {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "curl -s --connect-timeout 3 https://pypi.org > /dev/null 2>&1")
            return result.succeeded
        } catch {
            return false
        }
    }

    /// Concurrently processes a batch update sequence for the specified Python packages.
    func updateFiltered(_ packages: [OutdatedPackage]) async {
        guard await hasNetworkConnection() else {
            Logger.shared.log("❌ No network connection")
            return
        }

        isUpdatingAll = true
        resetUpdateResults()
        Logger.shared.log("⬆️ Updating \(packages.count) packages...")

        for package in packages {
            await updatePackage(package.name, type: package.type)
        }

        Logger.shared.log("✅ Updates complete: \(successfulPackages.count) successful, \(failedPackages.count) failed")
        isUpdatingAll = false
        showUpdateResults = true
        await rescanAfterUpdates()
    }
}

/// A view model that coordinates detecting and upgrading outdated Python pip packages.
///
/// `OutdatedPIPViewModel` conforms to `OutdatedUpdating`, providing the pip-specific
/// implementation of `updatePackage`. It checks updates exclusively on a *per-interpreter* basis,
/// using `pip list --outdated` directly, avoiding false positives from global PyPI lookups.
///
/// **Caveats:**
/// - Unlike Brew, `pip` provides specific feedback when a package is "held back" (e.g., requires
///   a higher Python version). These are gracefully diverted to `heldBackPackages` rather than
///   being flagged as hard failures.
/// - The view model must re-query `detectPythons()` dynamically to stay in sync with the global
///   Python environment cache.
///
/// ```swift
/// await vm.checkForPipUpdates()
/// if !vm.outdatedPackages.isEmpty { await vm.updateFiltered(vm.outdatedPackages) }
/// ```
@MainActor
final class OutdatedPIPViewModel: ObservableObject, OutdatedUpdating {
    /// The master list of outdated pip packages for the selected Python version.
    @Published var outdatedPackages: [OutdatedPackage] = []
    /// Indicates if `pip list --outdated` is actively running.
    @Published var isLoading = false
    /// Indicates if a batch update is actively running.
    @Published var isUpdatingAll = false
    /// The name of the package currently running through `pip install --upgrade`.
    @Published var updatingPackage: String?
    /// Flag indicating whether the view has scanned at least once.
    @Published var hasScannedOnce = false
    /// The timestamp of the last successful scan.
    @Published var lastScanDate: Date? = nil

    // Update results tracking
    /// The list of discovered Python interpreters capable of running pip.
    @Published var availablePythonVersions: [PythonInstallation] = []
    /// The specific interpreter currently being queried for outdated packages.
    @Published var selectedPythonVersion: PythonInstallation?
    /// Packages that threw an error during upgrade or remained outdated afterwards.
    @Published var failedPackages: [OutdatedPackage] = []
    /// Packages verified to be fully upgraded.
    @Published var successfulPackages: [OutdatedPackage] = []
    /// Packages that pip refused to upgrade due to constraints (e.g. Requires-Python).
    @Published var heldBackPackages: [OutdatedPackage] = []
    /// Human-readable reasons mapping to the held back package names.
    @Published var heldBackReasons: [String: String] = [:]
    /// Toggles the UI overlay showing success/fail results.
    @Published var showUpdateResults = false

    private let logger: Logger
    private let pythonService: PythonService

    // Refresh when the installed-Python set changes elsewhere (e.g. an uninstall).
    private var pyInventoryObserver: NSObjectProtocol?

    init(logger: Logger, pythonService: PythonService) {
        self.logger = logger
        self.pythonService = pythonService
        pyInventoryObserver = NotificationCenter.default.addObserver(
            forName: .catalystPythonInventoryChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.loadPythonVersions()
                await self.checkForPipUpdates(force: true)
            }
        }
    }

    deinit {
        if let pyInventoryObserver { NotificationCenter.default.removeObserver(pyInventoryObserver) }
    }
    
    /// Populates ``availablePythonVersions`` via the central ``PythonService``.
    /// Automatically selects the first valid interpreter upon successful load.
    func loadPythonVersions() async {
        do {
            availablePythonVersions = try await pythonService.detectPythons().filter { $0.pipAvailable }
            logger.log("✅ Found \(availablePythonVersions.count) Python version(s) with pip")
            
            // Auto-select first if none selected
            if selectedPythonVersion == nil, let first = availablePythonVersions.first {
                selectedPythonVersion = first
            }
        } catch {
            logger.log("❌ Failed to detect Python versions: \(error.localizedDescription)")
            availablePythonVersions = []
        }
    }
    
    // MARK: - Check Updates
    
    /// Check only pip updates for the `selectedPythonVersion`.
    ///
    /// **Flow:**
    /// 1. Resets prior update results.
    /// 2. If `force`, invalidates the Python global cache.
    /// 3. Refreshes available Pythons to ensure the selector isn't stale.
    /// 4. Calls ``getOutdatedPip()`` to scrape the actual packages.
    ///
    /// - Parameter force: If true, flushes the global python cache.
    func checkForPipUpdates(force: Bool = false) async {
        resetUpdateResults() // Clear previous results
        
        if force {
            pythonService.invalidateCache()
        }
        
        isLoading = true
        logger.log("🔍 Checking for outdated pip packages...")
        
        // Refresh Python versions first
        await loadPythonVersions()
        
        outdatedPackages = []
        
        // Check pip only
        let pipPackages = await getOutdatedPip()
        outdatedPackages.append(contentsOf: pipPackages)
        
        logger.log("✅ Found \(pipPackages.count) outdated pip packages")
        hasScannedOnce = true
        lastScanDate = Date()
        isLoading = false
    }
    
    /// Invokes `pip list --outdated --format=json` against the selected Python interpreter.
    ///
    /// **Gotchas:**
    /// - **Singleton Truth:** This is the *only* source of truth. Querying PyPI's `info.version` globally
    ///   would surface releases that dropped support for this specific Python (e.g. numpy 2.x on Python 3.8).
    ///   `pip` internally respects `Requires-Python` constraints.
    /// - **Self-Reporting Bug:** Pip can report *itself* as outdated due to stale metadata (like Homebrew symlinks).
    ///   We cross-reference pip's version string actively to prevent un-upgradable phantoms.
    ///
    /// - Returns: A decoded array of ``OutdatedPackage`` objects.
    private func getOutdatedPip() async -> [OutdatedPackage] {
        // Use selected Python only
        guard let python = selectedPythonVersion else {
            logger.log("⚠️ No Python version selected for pip updates")
            return []
        }

        logger.log("🔍 Checking Python \(python.version) for outdated packages...")

        // Ask pip itself, via `pip list --outdated`. This is the single source of
        // truth: pip's finder only reports the newest version that is actually
        // INSTALLABLE on this interpreter (respecting Requires-Python and wheel
        // availability). Querying PyPI's `info.version` instead would surface
        // releases that dropped support for this Python — an update pip can never
        // apply, i.e. a permanent false positive (e.g. numpy 2.5 on Python 3.11).
        let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip list --outdated --format=json 2>/dev/null"

        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)

            /// Decodes the JSON payload emitted by the `pip list --outdated` command.
            struct PipOutdated: Codable {
                let name: String
                let version: String
                let latest_version: String
            }

            guard let data = result.stdout.data(using: .utf8),
                  let packages = try? JSONDecoder().decode([PipOutdated].self, from: data) else {
                logger.log("❌ Failed to parse pip outdated output")
                return []
            }

            let outdated = packages.filter { pkg in
                // pip can report ITSELF as outdated when its on-disk metadata is
                // stale — e.g. a Homebrew pip left with a duplicate dist-info —
                // while the interpreter actually imports the newer pip. Trust
                // `pip --version` (python.pipVersion) and drop that phantom so it
                // doesn't sit in the list, un-upgradable, forever.
                guard pkg.name.lowercased() == "pip", let real = python.pipVersion else { return true }
                return VersionComparator.isOlder(real, than: pkg.latest_version)
            }.map { pkg in
                OutdatedPackage(
                    name: pkg.name,
                    currentVersion: pkg.version,
                    newVersion: pkg.latest_version,
                    type: .pip,
                    pythonPath: python.path.path,
                    pythonVersion: python.version
                )
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            logger.log("✅ Found \(outdated.count) outdated pip packages installable on Python \(python.version)")
            return outdated

        } catch {
            logger.log("❌ Error checking Python \(python.version): \(error.localizedDescription)")
            return []
        }
    }

    /// Orders the list so packages needing attention float to the top.
    ///
    /// **Rationale:**
    /// Sorting hierarchy is: Failed -> Held-back -> Normal.
    /// Each sub-group is ordered alphabetically.
    ///
    /// - Parameter packages: The raw unordered package array.
    /// - Returns: The grouped and sorted array.
    private func problemsFirst(_ packages: [OutdatedPackage]) -> [OutdatedPackage] {
        let failedNames = Set(failedPackages.map(\.name))
        let heldNames = Set(heldBackPackages.map(\.name))
        /// Computes a heuristic sort weighting based on semantic versioning disparities.
        func rank(_ p: OutdatedPackage) -> Int {
            if failedNames.contains(p.name) { return 0 }
            if heldNames.contains(p.name) { return 1 }
            return 2
        }
        return packages.sorted {
            let (r0, r1) = (rank($0), rank($1))
            if r0 != r1 { return r0 < r1 }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
    
    // MARK: - Update Methods
    
    /// Upgrades a single pip package using `pip install --upgrade`.
    ///
    /// - Parameters:
    ///   - name: The target package name.
    ///   - type: Must be `.pip`.
    func updatePackage(_ name: String, type: PackageType) async {
        guard type == .pip else { return }
        await updatePipPackage(name)
    }

    /// Refreshes the pip state post-batch update.
    ///
    /// **Gotchas:**
    /// - Refreshes the outdated list to reflect the new environment, but explicitly **KEEPS** the
    ///   per-package verdicts (successful / failed / held-back) so the summary card and the red/amber
    ///   row states survive the rescan UI wipe.
    func rescanAfterUpdates() async {
        // Refresh the outdated list to reflect the new environment, but KEEP the
        // per-package verdicts (successful / failed / held-back) so the summary
        // card and the red/amber row states survive the rescan. Problem packages
        // float to the top.
        let refreshed = await getOutdatedPip()
        outdatedPackages = problemsFirst(refreshed)
        lastScanDate = Date()
    }
    
    /// Performs the heavy-lifting subshell execution to run `pip install --upgrade`.
    ///
    /// **Flow:**
    /// 1. Drops any prior verdicts for this package.
    /// 2. Sanitizes input and validates network connectivity.
    /// 3. Appends PEP 668 flags if necessary via ``InstallPreferences``.
    /// 4. Executes the upgrade via ``runUpgradeCapturing(_:)``.
    /// 5. Re-runs `verifyUpdate()` as the ultimate source of truth.
    /// 6. Parses standard output strictly if the update failed, to deduce if the package was merely "held back".
    ///
    /// - Parameter name: The package to upgrade.
    private func updatePipPackage(_ name: String) async {
        updatingPackage = name
        
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       🐍 PIP PACKAGE UPDATE", category: .terminal)
        logger.log("       Package: \(name)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        
        logger.log("⬆️ Updating \(name)...")
        
        // Store original package info
        guard let originalPackage = outdatedPackages.first(where: { $0.name == name }) else {
            logger.log("❌ Package not found in list")
            updatingPackage = nil
            return
        }
        
        // Use the specific Python that detected this package as outdated
        guard let pythonPath = originalPackage.pythonPath else {
            logger.log("❌ No Python path stored for package")
            updatingPackage = nil
            return
        }
        
        // Clear any prior verdict so a retry reclassifies this package cleanly.
        clearVerdict(for: name)

        logger.log("📍 Using Python at: \(pythonPath)")

        // Sanitize inputs to prevent shell command injection
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name, refusing to update: \(name)")
            failedPackages.append(originalPackage)
            updatingPackage = nil
            return
        }

        guard await hasNetworkConnection() else {
            logger.log("❌ No network connection")
            failedPackages.append(originalPackage)
            updatingPackage = nil
            return
        }

        let flags = InstallPreferences.pipFlags(forPythonVersion: originalPackage.pythonVersion)
        let command = "\(InputSanitizer.singleQuote(pythonPath)) -m pip install --upgrade \(InputSanitizer.singleQuote(sanitizedName)) \(flags)"
        let (exitOK, output) = await runUpgradeCapturing(command)

        // Source of truth: does pip still report it outdated afterwards?
        let upgraded = await verifyUpdate(name, pythonPath: pythonPath)

        if upgraded {
            outdatedPackages.removeAll { $0.name == name }
            successfulPackages.append(originalPackage)
            logger.log("✅ Update verified and removed \(name) from list")
            updatingPackage = nil
            return
        }

        // Still outdated — decide WHY, so the UI can show "held back" (amber)
        // vs a genuine "failed" (red).
        let lower = output.lowercased()
        let hardError = !exitOK
            || lower.contains("error:")
            || lower.contains("could not")
            || lower.contains("no matching distribution")
            || lower.contains("failed to")
        let actuallyInstalled = lower.contains("successfully installed")
        let alreadySatisfied = lower.contains("already satisfied")

        if !hardError && alreadySatisfied && !actuallyInstalled {
            // pip declined to move it: a newer version exists but isn't installable
            // in this environment (dependency constraint or Requires-Python).
            heldBackPackages.append(originalPackage)
            heldBackReasons[name] = heldBackReason(for: name, output: output)
            logger.log("⚠️ \(name) held back — \(heldBackReasons[name] ?? "")")
        } else {
            failedPackages.append(originalPackage)
            logger.log("❌ Update failed for \(name)")
        }

        updatingPackage = nil
    }

    /// Drops any existing verdict for a package (used before a fresh attempt or retry).
    ///
    /// - Parameter name: Package identifier.
    private func clearVerdict(for name: String) {
        failedPackages.removeAll { $0.name == name }
        heldBackPackages.removeAll { $0.name == name }
        successfulPackages.removeAll { $0.name == name }
        heldBackReasons[name] = nil
    }

    /// Extracts a best-effort explanation for why pip refused to upgrade a package.
    ///
    /// **Rationale:**
    /// Surfaces pip's own incompatibility string when present (e.g., dependency limits); otherwise provides a generic honest fallback.
    ///
    /// - Parameters:
    ///   - name: The package name.
    ///   - output: The stdout payload from pip.
    /// - Returns: A human-readable diagnostic string.
    private func heldBackReason(for name: String, output: String) -> String {
        let needle = name.lowercased()
        if let line = output
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: {
                let l = $0.lowercased()
                return l.contains("incompatible") || (l.contains("requires") && l.contains(needle))
            }) {
            return String(line)
        }
        return "A newer version exists but isn't installable on this Python (dependency constraint or Requires-Python)."
    }

    /// Verifies if a package successfully dropped off the `pip list --outdated` array post-upgrade.
    ///
    /// **Gotchas:**
    /// - Forces a 500ms delay to allow pip to stabilize its internal `.dist-info` structures.
    /// - Fail-closed: If the verification command crashes, we assume the upgrade failed.
    ///
    /// - Parameters:
    ///   - name: The package name.
    ///   - pythonPath: The absolute path to the Python environment.
    /// - Returns: `true` if the package is **NO LONGER** outdated.
    private func verifyUpdate(_ name: String, pythonPath: String?) async -> Bool {
        logger.log("🔍 Verifying update for \(name)...")
        
        // Give pip a moment to update its internal state
        try? await Task.sleep(for: .milliseconds(500))
        
        guard let path = pythonPath else {
            logger.log("❌ No Python path for verification")
            return false
        }
        
        // Check if package is still in outdated list using the SAME Python
        let command = "\(InputSanitizer.singleQuote(path)) -m pip list --outdated --format=json 2>/dev/null"
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            
            /// A minimal package definition used for internal PyPI resolution lookups.
            struct PipPackage: Codable {
                let name: String
            }
            
            if let data = result.stdout.data(using: .utf8),
               let packages = try? JSONDecoder().decode([PipPackage].self, from: data) {
                let stillOutdated = packages.contains { InputSanitizer.normalizePipPackageName($0.name) == InputSanitizer.normalizePipPackageName(name) }
                
                if stillOutdated {
                    logger.log("⚠️ \(name) still appears in outdated list")
                    return false
                } else {
                    logger.log("✅ \(name) no longer in outdated list - upgrade successful")
                    return true
                }
            } else {
                // If we can't parse the list, assume failure (fail-closed for safety)
                logger.log("⚠️ Could not verify \(name), assuming update may have failed")
                return false
            }
        } catch {
            logger.log("❌ Verification failed: \(error.localizedDescription)")
            // Fail-closed: assume failure if verification fails
            return false
        }
    }

    /// Runs an upgrade command, capturing and logging output.
    ///
    /// - Parameter command: The pip execution string.
    /// - Returns: A tuple containing the exit status and the raw output stream.
    private func runUpgradeCapturing(_ command: String) async -> (ok: Bool, output: String) {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            if !result.combinedOutput.isEmpty {
                logger.log(result.combinedOutput, category: .terminal)
            }
            return (result.succeeded, result.combinedOutput)
        } catch {
            logger.log("❌ Error: \(error.localizedDescription)")
            return (false, "")
        }
    }
    
    /// Resets all cached state so the view re-evaluates from scratch.
    ///
    /// **Rationale:**
    /// Called by `fullRefresh()` or global actions after a package install/uninstall forces the state out of sync.
    func reset() async {
        hasScannedOnce = false
        outdatedPackages = []
        lastScanDate = nil
        resetUpdateResults()
        await loadPythonVersions()
    }
}

