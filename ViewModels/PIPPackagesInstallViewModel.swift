import Foundation
import SwiftUI
import Combine

/// A view model that orchestrates PyPI package searching and installation.
///
/// It hits the `NetworkConfig.APIEndpoint.pypiURL` prefix shards to perform debounced
/// typeahead searching for pip packages, then executes `pip install` on the user-selected
/// Python interpreter.
///
/// **Caveats:**
/// - It accurately handles PEP 668 constraints by appending `--break-system-packages`
///   when dealing with Python >= 3.12, ensuring installs don't fail mysteriously on macOS.
///
/// ```swift
/// await vm.searchPackages()
/// await vm.installPackage("requests")
/// ```
@MainActor
final class PIPPackagesInstallViewModel: ObservableObject {
    /// Discovered Python installations with a valid pip executable.
    @Published var availablePythonVersions: [PythonInstallation] = []
    /// The interpreter that packages will be installed into.
    @Published var selectedPythonVersion: PythonInstallation?
    
    /// The raw text typed by the user.
    @Published var searchQuery: String = ""
    /// The PyPI packages matching the search query.
    @Published var searchResults: [String] = []
    /// Indicates if a search request is actively flying to the backend.
    @Published var isSearching = false
    
    /// The name of the package currently running through `pip install`.
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
    /// True after the first search is performed, allowing the UI to show "No results".
    @Published var hasSearched = false
    /// The list of already installed packages for the selected python (to prevent double-installs).
    @Published var installedPackages: Set<String> = []
    /// Indicates whether at least one pip-capable Python exists on the system.
    @Published var isPythonWithPipAvailable = false
    /// Short, user-facing error surfaced as a banner when an install fails (P3).
    @Published var installError: String?
    
    /// Whether the selected interpreter is externally managed under PEP 668 (Python 3.12+),
    /// meaning pip needs `--break-system-packages` (an install-mode override) to write to it.
    ///
    /// Delegates to ``VersionComparator/requiresBreakSystemPackages(pythonVersion:)`` — the
    /// single version-parsing implementation — instead of a local reparse. (The old inline
    /// check compared `major >= 3 && minor >= 12`, which would misclassify a future 4.x.)
    ///
    /// - Returns: `false` when no interpreter is selected (nothing to protect yet).
    var requiresBreakSystemPackages: Bool {
        guard let python = selectedPythonVersion else { return false }
        return VersionComparator.requiresBreakSystemPackages(pythonVersion: python.version)
    }
    
    private let pythonService: PythonService
    private let logger: Logger
    private let baseURL = NetworkConfig.APIEndpoint.pypiURL
    
    /// Defines an installable Python package candidate mapped to a PyPI registry entry.
    struct PackageItem: Codable {
        let name: String
        let fetched_at: String
    }
    
    init(pythonService: PythonService, logger: Logger) {
        self.pythonService = pythonService
        self.logger = logger
    }
    
    /// Refreshes the local installed package list when a user swaps interpreters.
    func onPythonVersionChange() async {
        await loadInstalledPackages()
    }
    
    /// Resets search state and clears installation history.
    ///
    /// **Rationale:**
    /// Ensures stale `searchResults` and `installationOutput` from a prior attempt do not flash when reopening the install sheet.
    func reset() async {
        searchQuery = ""
        searchResults = []
        hasSearched = false
        installingPackage = nil
        installationOutput = ""
        await loadPythonVersions()
    }
    
    /// Populates ``availablePythonVersions`` via the central ``PythonService``.
    ///
    /// **Gotchas:**
    /// Filters the global inventory to only retain environments where `.pipAvailable` is true.
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
    
    /// Verifies that pip operations are actually possible on the current system by checking the populated versions.
    func checkPrerequisites() async {
        isPythonWithPipAvailable = !availablePythonVersions.isEmpty
        logger.log("Prerequisites: Python/pip available = \(isPythonWithPipAvailable)")
    }
    
    /// Loads the existing packages for `selectedPythonVersion` to prevent installing duplicates.
    ///
    /// **Flow:**
    /// 1. Emits `pip list --format=freeze`.
    /// 2. Splits output by `=` and downcases to build a fast-lookup `Set`.
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
    
    /// Triggers a fetch to the Cloudflare PyPI shards to filter matching package names.
    ///
    /// **Flow:**
    /// 1. Takes the first 2 characters of the user's query to hit the pre-computed static JSON shard.
    /// 2. Downloads the shard containing all PyPI packages starting with that prefix.
    /// 3. Performs a substring `.contains()` match locally.
    /// 4. Caps results at 100 to prevent SwiftUI `LazyVStack` stutter.
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
    
    /// Executes a streaming `pip install` for the specified package against the chosen Python.
    ///
    /// **Flow:**
    /// 1. Validates the Python version and sanitizes the target package name.
    /// 2. Extracts `pipFlags` via ``InstallPreferences``, appending `--break-system-packages` if Python >= 3.12 (PEP 668).
    /// 3. Streams stdout/stderr directly into ``installationOutput`` via a blocking shell execution.
    /// 4. On success, reloads the `installedPackages` set.
    ///
    /// - Parameter packageName: The PyPI package name to install.
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
    
    /// Clears the streaming console output view for the next operation.
    func clearOutput() {
        installationOutput = ""
    }
}
