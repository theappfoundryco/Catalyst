import Foundation
import Combine
import SwiftUI

/// A view model that coordinates detecting and updating outdated Homebrew packages.
///
/// `OutdatedBrewViewModel` conforms to `OutdatedUpdating`, providing the brew-specific
/// implementation of `updatePackage` and managing the `brew outdated --json` payload.
///
/// **Caveats:**
/// - Unlike `pip`, Homebrew does not reliably distinguish between "held back" and "failed",
///   so all failed updates fall into `failedPackages`.
/// - Homebrew's JSON output parsing is fragile and relies on `BrewOutdatedResult` mapping.
///
/// ```swift
/// await vm.checkForBrewUpdates()
/// if !vm.outdatedPackages.isEmpty { await vm.updateFiltered(vm.outdatedPackages) }
/// ```
@MainActor
final class OutdatedBrewViewModel: ObservableObject, OutdatedUpdating {
    /// The master list of packages needing updates.
    @Published var outdatedPackages: [OutdatedPackage] = []
    /// Indicates if `brew outdated` is currently running.
    @Published var isLoading = false
    /// Flag indicating whether the view has scanned at least once.
    @Published var hasScannedOnce = false
    /// The timestamp of the last successful scan.
    @Published var lastScanDate: Date? = nil

    // Brew availability
    /// Validated boolean to determine if brew logic should run at all.
    @Published var isBrewAvailable = false

    // Update tracking
    /// Shared OutdatedUpdating protocol requirement: true when batch updating.
    @Published var isUpdatingAll = false
    /// The name of the package currently running through `brew upgrade`.
    @Published var updatingPackage: String?
    /// Packages that threw an error during upgrade or remained outdated afterwards.
    @Published var failedPackages: [OutdatedPackage] = []
    /// Packages verified to be fully upgraded.
    @Published var successfulPackages: [OutdatedPackage] = []
    
    // brew doesn't distinguish "held back" (no Requires-Python analogue); kept to
    // satisfy the shared `OutdatedUpdating` surface and stays empty.
    /// Protocol conformance; always empty for Homebrew.
    @Published var heldBackPackages: [OutdatedPackage] = []
    /// Protocol conformance; always empty for Homebrew.
    @Published var heldBackReasons: [String: String] = [:]
    /// Toggles the UI overlay showing success/fail results.
    @Published var showUpdateResults = false

    /// Required by `OutdatedUpdating`, but explicitly a no-op for Homebrew.
    ///
    /// **Rationale:**
    /// Unlike pip, `brew upgrade` automatically purges upgraded packages from its own outdated tree internally,
    /// and running a full `brew outdated` sweep is computationally expensive. Therefore, we rely on the per-package
    /// `verifyUpdate()` checks to maintain the local list, saving seconds of blocking UI time.
    func rescanAfterUpdates() async {}

    private let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
        // `isBrewAvailable` is resolved synchronously at the start of every
        // scan/reset; the old detached init Task was redundant and could race
        // with those assignments.
    }
    
    /// Queries `brew outdated` for both formulae and casks simultaneously.
    ///
    /// **Flow:**
    /// 1. Validates brew availability.
    /// 2. Fires off two detached tasks to fetch formulae and casks in parallel.
    /// 3. Joins the results, sorts them alphabetically by name.
    /// 4. Updates the UI bindings.
    ///
    /// **Gotchas:**
    /// - Sets `hasScannedOnce` to `true` even if Brew is not installed, so the UI stops showing a loading spinner
    ///   and correctly renders the empty/fallback state.
    func checkForBrewUpdates() async {
        resetUpdateResults()
        isBrewAvailable = BrewPathManager.shared.isInstalled
        
        guard isBrewAvailable else {
            logger.log("⚠️ Homebrew not installed, skipping brew updates")
            outdatedPackages = []
            hasScannedOnce = true
            return
        }
        
        isLoading = true
        logger.log("🔍 Checking for outdated Homebrew packages...")
        
        outdatedPackages = []
        
        async let formulae = getOutdatedFormulae()
        async let casks = getOutdatedCasks()
        
        let (f, c) = await (formulae, casks)
        outdatedPackages.append(contentsOf: f)
        outdatedPackages.append(contentsOf: c)
        
        // Sort alphabetically
        outdatedPackages.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        logger.log("✅ Found \(outdatedPackages.count) outdated Homebrew packages")
        hasScannedOnce = true
        lastScanDate = Date()
        isLoading = false
    }
    
    /// Executes the `brew outdated --json --formula` command and maps the output to domain models.
    ///
    /// **Rationale:**
    /// We explicitly inject the Homebrew prefix bin directory into the `$PATH` to ensure the subshell
    /// uses the exact brew executable the user installed, rather than falling back to system binaries.
    ///
    /// - Returns: An array of `OutdatedPackage` parsed from stdout, or empty if the command crashes.
    private func getOutdatedFormulae() async -> [OutdatedPackage] {
        let command = "export PATH=\"\(BrewPathManager.shared.homebrewPrefix)/bin:$PATH\" && \(BrewPathManager.shared.brewPath) outdated --json --formula"
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            if result.succeeded {
                return parseOutdatedJSON(result.stdout, type: .brewFormula)
            }
        } catch {
            logger.log("❌ Failed to get outdated formulae: \(error.localizedDescription)")
        }
        return []
    }
    
    /// Executes the `brew outdated --json --cask` command and maps the output to domain models.
    ///
    /// **Rationale:**
    /// Similar to `getOutdatedFormulae`, explicitly forces the `$PATH` to avoid environment corruption.
    /// Casks often require admin privileges to update, but detecting outdated status is generally safe and unprivileged.
    ///
    /// - Returns: An array of `OutdatedPackage` parsed from stdout, or empty if the command crashes.
    private func getOutdatedCasks() async -> [OutdatedPackage] {
        let command = "export PATH=\"\(BrewPathManager.shared.homebrewPrefix)/bin:$PATH\" && \(BrewPathManager.shared.brewPath) outdated --json --cask"
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            if result.succeeded {
                return parseOutdatedJSON(result.stdout, type: .brewCask)
            }
        } catch {
            logger.log("❌ Failed to get outdated casks: \(error.localizedDescription)")
        }
        return []
    }
    
    /// Decodes the strict `BrewOutdatedResult` JSON schema and flattens it into Catalyst's unified `OutdatedPackage`.
    ///
    /// **Gotchas:**
    /// - Homebrew's JSON structure embeds the active version in `current_version`, but lists installed artifacts in
    ///   an array `installed_versions`. We extract `.first` because Homebrew guarantees the first item is the active installation.
    ///
    /// - Parameters:
    ///   - json: The raw standard output from the brew command.
    ///   - type: Disambiguates whether we are mapping the `.formulae` or `.casks` array from the payload.
    /// - Returns: A mapped array, dropping any malformed entries.
    private func parseOutdatedJSON(_ json: String, type: PackageType) -> [OutdatedPackage] {
        guard let data = json.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        
        do {
            let result = try decoder.decode(BrewOutdatedResult.self, from: data)
            let items = type == .brewFormula ? result.formulae : result.casks
            
            return items.compactMap { item in
                guard let currentVersion = item.current_version,
                      let installedVersions = item.installed_versions,
                      let installedVersion = installedVersions.first else {
                    return nil
                }
                
                return OutdatedPackage(
                    name: item.name,
                    currentVersion: installedVersion,
                    newVersion: currentVersion,
                    type: type,
                    pythonPath: nil,
                    pythonVersion: nil
                )
            }
        } catch {
            logger.log("⚠️ Failed to parse Brew JSON: \(error)")
            return []
        }
    }
    
    // MARK: - Updates

    /// Runs `brew upgrade` on a specific formula or cask, subsequently verifying the upgrade.
    ///
    /// **Flow:**
    /// 1. Validates and sanitizes the package name to prevent shell injection (a critical security vector).
    /// 2. Synthesizes a safe subshell command injecting the brew path.
    /// 3. Runs the command via `runCommand`, capturing streaming output to the terminal logger.
    /// 4. Executes a secondary `verifyUpdate` pass to ensure the package actually left the outdated list.
    ///
    /// - Parameters:
    ///   - name: The raw package name requested for upgrade.
    ///   - type: Must be `.brewFormula` or `.brewCask`.
    func updatePackage(_ name: String, type: PackageType) async {
        guard type == .brewFormula || type == .brewCask else { return }
        
        updatingPackage = name
        logger.log("⬆️ Updating \(name)...")
        
        guard let originalPackage = outdatedPackages.first(where: { $0.name == name }) else {
            updatingPackage = nil
            return
        }
        
        // Sanitize inputs to prevent shell command injection
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name, refusing to update: \(name)")
            failedPackages.append(originalPackage)
            updatingPackage = nil
            return
        }
        let pathBin = InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/bin")
        let brew = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
        let pkg = InputSanitizer.singleQuote(sanitizedName)

        let command: String
        if type == .brewFormula {
            command = "export PATH=\(pathBin):\"$PATH\" && \(brew) upgrade \(pkg)"
        } else {
            command = "export PATH=\(pathBin):\"$PATH\" && \(brew) upgrade --cask \(pkg)"
        }
        
        let success = await runCommand(command)
        
        if success {
            let actuallyUpdated = await verifyUpdate(name, type: type)
            if actuallyUpdated {
                outdatedPackages.removeAll { $0.name == name }
                successfulPackages.append(originalPackage)
                logger.log("✅ Update verified: \(name)")
            } else {
                failedPackages.append(originalPackage)
                logger.log("⚠️ Update completed but package still outdated")
            }
        } else {
            failedPackages.append(originalPackage)
            logger.log("❌ Update failed for \(name)")
        }
        
        updatingPackage = nil
    }
    
    /// Performs a focused, post-upgrade check to confirm a package successfully installed.
    ///
    /// **Gotchas:**
    /// - Homebrew can sometimes report a different casing in its JSON than the user-supplied name (e.g. `Python@3.10` vs `python@3.10`).
    /// - To prevent a successful update from being falsely marked as failed, we compare package names using a case-insensitive match (`.orderedSame`).
    ///
    /// - Parameters:
    ///   - name: The package name to hunt for in the updated list.
    ///   - type: The specific type (Formula/Cask) to narrow the `brew outdated` query.
    /// - Returns: `true` if the package is **NO LONGER** present in the outdated list.
    private func verifyUpdate(_ name: String, type: PackageType) async -> Bool {
        guard let _ = InputSanitizer.sanitizePackageName(name) else { return false }
        let isCask = type == .brewCask
        
        // Check if still listed in outdated
        let command = isCask ?
            "export PATH=\"\(BrewPathManager.shared.homebrewPrefix)/bin:$PATH\" && \(BrewPathManager.shared.brewPath) outdated --cask --json" :
            "export PATH=\"\(BrewPathManager.shared.homebrewPrefix)/bin:$PATH\" && \(BrewPathManager.shared.brewPath) outdated --formula --json"
            
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            if result.succeeded {
               // Parse to see if it's still there. Compare case-insensitively:
               // brew can report a different casing than the user-supplied name,
               // which would otherwise mark a successful update as failed.
               let packages = parseOutdatedJSON(result.stdout, type: type)
               return !packages.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
            return false
        } catch {
            return false
        }
    }
    
    /// Wraps `AsyncProcessRunner` to execute a shell string, automatically logging stdout/stderr to the Catalyst terminal window.
    ///
    /// **Caveats:**
    /// - Fast-fails if `hasNetworkConnection()` returns false, because Homebrew `upgrade` strictly requires internet access.
    ///
    /// - Parameters:
    ///   - command: The fully sanitized, absolute-pathed shell command.
    /// - Returns: `true` if the process exits with code 0.
    private func runCommand(_ command: String) async -> Bool {
        guard await hasNetworkConnection() else { return false }
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            if !result.combinedOutput.isEmpty {
                logger.log(result.combinedOutput, category: .terminal)
            }
            return result.succeeded
        } catch {
            logger.log("❌ Error: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Reset all cached state so the view re-evaluates from scratch.
    ///
    /// **Rationale:**
    /// Used heavily when the user navigates away or when a completely unrelated feature alters the Homebrew tree,
    /// forcing this view to drop its caches and fetch fresh data.
    ///
    /// Called by `fullRefresh()` after install/uninstall.
    func reset() async {
        isBrewAvailable = BrewPathManager.shared.isInstalled
        hasScannedOnce = false
        outdatedPackages = []
        lastScanDate = nil
        resetUpdateResults()
    }
}

// MARK: - Homebrew JSON Models

/// Root structure for `brew outdated --json` output
struct BrewOutdatedResult: Codable {
    let formulae: [BrewOutdatedItem]
    let casks: [BrewOutdatedItem]
}

/// Represents a single outdated item (formula or cask)
struct BrewOutdatedItem: Codable {
    let name: String
    let current_version: String?
    let installed_versions: [String]?
    
    // Custom coding keys to handle potential variations or simply for clarity
    enum CodingKeys: String, CodingKey {
        case name
        case current_version
        case installed_versions
    }
}
