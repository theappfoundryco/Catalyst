import Foundation
import SwiftUI
import Combine

@MainActor
final class PIPPackagesInstallViewModel: ObservableObject {
    @Published var availablePythonVersions: [PythonInstallation] = []
    @Published var selectedPythonVersion: PythonInstallation?
    @Published var searchQuery: String = ""
    @Published var searchResults: [String] = []
    @Published var isSearching = false
    @Published var installingPackage: String?
    /// Streaming install output lives on its own `ConsoleOutput` so appending a
    /// chunk re-renders only the console card, not the whole package catalog +
    /// search (R2). The computed bridge keeps every existing `+=`/read site
    /// working and correct (immediate, not coalesced).
    let console = ConsoleOutput()
    var installationOutput: String {
        get { console.text }
        set { console.set(newValue) }
    }
    @Published var hasSearched = false
    @Published var installedPackages: Set<String> = []
    @Published var isPythonWithPipAvailable = false
    /// Short, user-facing error surfaced as a banner when an install fails (P3).
    @Published var installError: String?
    
    /// Returns true if selected Python version is 3.12+ which requires --break-system-packages
    var requiresBreakSystemPackages: Bool {
        guard let python = selectedPythonVersion else { return false }
        let versionParts = python.version.split(separator: ".")
        guard versionParts.count >= 2,
              let major = Int(versionParts[0]),
              let minor = Int(versionParts[1]) else { return false }
        // Python 3.12+ requires --break-system-packages due to PEP 668
        return major >= 3 && minor >= 12
    }
    
    private let pythonService: PythonService
    private let logger: Logger
    private let baseURL = NetworkConfig.APIEndpoint.pypiURL
    
    struct PackageItem: Codable {
        let name: String
        let fetched_at: String
    }
    
    init(pythonService: PythonService, logger: Logger) {
        self.pythonService = pythonService
        self.logger = logger
    }
    
    func onPythonVersionChange() async {
        await loadInstalledPackages()
    }
    
    func reset() async {
        searchQuery = ""
        searchResults = []
        hasSearched = false
        installingPackage = nil
        installationOutput = ""
        await loadPythonVersions()
    }
    
    func loadPythonVersions() async {
        do {
            availablePythonVersions = try await pythonService.detectPythons()
                .filter { $0.pipAvailable }
            
            isPythonWithPipAvailable = !availablePythonVersions.isEmpty
            
            logger.log("✅ Found \(availablePythonVersions.count) Python installation(s) with pip")
            
            if let first = availablePythonVersions.first {
                selectedPythonVersion = first
            }
            
        } catch {
            logger.log("❌ Failed to detect Python: \(error.localizedDescription)")
            availablePythonVersions = []
            isPythonWithPipAvailable = false
        }
    }
    
    func checkPrerequisites() async {
        isPythonWithPipAvailable = !availablePythonVersions.isEmpty
        logger.log("Prerequisites: Python/pip available = \(isPythonWithPipAvailable)")
    }
    
    func loadInstalledPackages() async {
        guard let python = selectedPythonVersion else { return }
        
        let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip list --format=freeze"
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            let packages = result.stdout.components(separatedBy: .newlines)
                .compactMap { line -> String? in
                    let parts = line.split(separator: "=")
                    return parts.first.map(String.init)?.lowercased()
                }
            installedPackages = Set(packages)
            logger.log("✅ Loaded \(installedPackages.count) installed pip packages")
        } catch {
            logger.log("❌ Failed to load installed packages: \(error.localizedDescription)")
        }
    }
    
    func searchPackages() async {
        guard !searchQuery.isEmpty else {
            searchResults = []
            hasSearched = false
            return
        }
        
        isSearching = true
        hasSearched = true
        
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log("🔍 Searching for pip packages matching: \(query)")
        
        // Get first 2 characters for shard
        let prefix = String(query.prefix(2))
        let urlString = "\(baseURL)/\(prefix).json"
        
        guard let url = URL(string: urlString) else {
            logger.log("❌ Invalid URL for prefix: \(prefix)")
            isSearching = false
            return
        }
        
        do {
            let items = try await NetworkConfig.fetchJSON(from: url, as: [PackageItem].self, ttl: CacheTTL.pypiShard)
            let packages = items.map { $0.name }
            
            // Filter packages that contain the query
            let filtered = packages.filter { pkg in
                pkg.lowercased().contains(query)
            }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            
            searchResults = Array(filtered.prefix(100))
            logger.log("✅ Found \(searchResults.count) matching packages")
        } catch {
            logger.log("❌ Failed to search packages: \(error)")
            searchResults = []
        }
        
        isSearching = false
    }
    
    func installPackage(_ packageName: String) async {
        installError = nil

        guard let python = selectedPythonVersion else {
            logger.log("❌ No Python version selected")
            installError = "No Python version selected."
            return
        }

        guard let sanitizedName = InputSanitizer.sanitizePackageName(packageName) else {
            logger.log("❌ Invalid package name: \(packageName)")
            installError = "Invalid package name: \(packageName)"
            return
        }

        installingPackage = packageName
        installationOutput = ""
        
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       🐍 PIP PACKAGE INSTALLATION", category: .terminal)
        logger.log("       Package: \(sanitizedName)", category: .terminal)
        logger.log("       Python: \(python.version)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        
        logger.log("📦 Installing \(sanitizedName) with Python \(python.version)")
        
        let flags = InstallPreferences.pipFlags(forPythonVersion: python.version)
        let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip install \(InputSanitizer.singleQuote(sanitizedName)) \(flags)"

        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { text in
                self.installationOutput += text
            }
            
            if exitCode == 0 {
                logger.log("✅ Successfully installed \(packageName)")
                installationOutput += "\n\n✅ Installation completed successfully!"
                
                // Reload installed packages
                await loadInstalledPackages()
            } else {
                logger.log("❌ Failed to install \(packageName)")
                installationOutput += "\n\n❌ Installation failed with exit code \(exitCode)"
                installError = "Failed to install \(packageName) (exit code \(exitCode)). See the output log for details."
            }
        } catch {
            logger.log("❌ Installation error: \(error.localizedDescription)")
            installationOutput += "\n\n❌ Error: \(error.localizedDescription)"
            installError = "Error installing \(packageName): \(error.localizedDescription)"
        }

        installingPackage = nil
    }
    
    func clearOutput() {
        installationOutput = ""
    }
}
