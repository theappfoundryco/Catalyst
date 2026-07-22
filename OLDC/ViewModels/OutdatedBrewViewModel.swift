import Foundation
import Combine
import SwiftUI

@MainActor
final class OutdatedBrewViewModel: ObservableObject, OutdatedUpdating {
    @Published var outdatedPackages: [OutdatedPackage] = []
    @Published var isLoading = false
    @Published var hasScannedOnce = false
    @Published var lastScanDate: Date? = nil

    // Brew availability
    @Published var isBrewAvailable = false

    // Update tracking
    @Published var isUpdatingAll = false
    @Published var updatingPackage: String?
    @Published var failedPackages: [OutdatedPackage] = []
    @Published var successfulPackages: [OutdatedPackage] = []
    // brew doesn't distinguish "held back" (no Requires-Python analogue); kept to
    // satisfy the shared `OutdatedUpdating` surface and stays empty.
    @Published var heldBackPackages: [OutdatedPackage] = []
    @Published var heldBackReasons: [String: String] = [:]
    @Published var showUpdateResults = false

    /// brew does not re-scan after a batch update (pip does).
    func rescanAfterUpdates() async {}

    private let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
        // `isBrewAvailable` is resolved synchronously at the start of every
        // scan/reset; the old detached init Task was redundant and could race
        // with those assignments.
    }
    
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
