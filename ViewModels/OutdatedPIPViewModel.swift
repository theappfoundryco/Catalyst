import Foundation
import SwiftUI
import Combine

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

    func resetUpdateResults() {
        failedPackages = []
        successfulPackages = []
        heldBackPackages = []
        heldBackReasons = [:]
        showUpdateResults = false
    }

    func hasNetworkConnection() async -> Bool {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "curl -s --connect-timeout 3 https://pypi.org > /dev/null 2>&1")
            return result.succeeded
        } catch {
            return false
        }
    }

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

@MainActor
final class OutdatedPIPViewModel: ObservableObject, OutdatedUpdating {
    @Published var outdatedPackages: [OutdatedPackage] = []
    @Published var isLoading = false
    @Published var isUpdatingAll = false
    @Published var updatingPackage: String?
    @Published var hasScannedOnce = false
    @Published var lastScanDate: Date? = nil

    // Update results tracking
    @Published var availablePythonVersions: [PythonInstallation] = []
    @Published var selectedPythonVersion: PythonInstallation?
    @Published var failedPackages: [OutdatedPackage] = []
    @Published var successfulPackages: [OutdatedPackage] = []
    @Published var heldBackPackages: [OutdatedPackage] = []
    @Published var heldBackReasons: [String: String] = [:]
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
    
    /// Check only pip updates
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

    /// Order the list so packages needing attention float to the top: failed
    /// first, then held-back, then the rest — each group alphabetical.
    private func problemsFirst(_ packages: [OutdatedPackage]) -> [OutdatedPackage] {
        let failedNames = Set(failedPackages.map(\.name))
        let heldNames = Set(heldBackPackages.map(\.name))
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
    
    func updatePackage(_ name: String, type: PackageType) async {
        guard type == .pip else { return }
        await updatePipPackage(name)
    }

    /// pip re-scans after a batch update (brew's equivalent does not).
    func rescanAfterUpdates() async {
        // Refresh the outdated list to reflect the new environment, but KEEP the
        // per-package verdicts (successful / failed / held-back) so the summary
        // card and the red/amber row states survive the rescan. Problem packages
        // float to the top.
        let refreshed = await getOutdatedPip()
        outdatedPackages = problemsFirst(refreshed)
        lastScanDate = Date()
    }
    
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

    /// Drop any existing verdict for a package (used before a fresh attempt/retry).
    private func clearVerdict(for name: String) {
        failedPackages.removeAll { $0.name == name }
        heldBackPackages.removeAll { $0.name == name }
        successfulPackages.removeAll { $0.name == name }
        heldBackReasons[name] = nil
    }

    /// Best-effort explanation for why pip held a package back. Surfaces pip's own
    /// incompatibility line when present; otherwise a generic but honest reason.
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

    /// Run an upgrade command, returning success plus the combined output so the
    /// caller can classify the outcome (upgraded / held back / failed). Network
    /// connectivity is checked by the caller.
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
    
    /// Reset all cached state so the view re-evaluates from scratch.
    /// Called by `fullRefresh()` after install/uninstall.
    func reset() async {
        hasScannedOnce = false
        outdatedPackages = []
        lastScanDate = nil
        resetUpdateResults()
        await loadPythonVersions()
    }
}

