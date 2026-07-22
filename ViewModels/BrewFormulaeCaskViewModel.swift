import Foundation
import Combine

/// A single catalog entry from the backend formulae/casks JSON. Hoisted out of
/// `loadBrewFormulae`/`loadBrewCasks`, which each defined an identical local copy.
private struct BrewCatalogItem: Codable {
    let name: String
}

/// A view model managing the state for Homebrew formulae and casks.
///
/// `BrewFormulaeCaskViewModel` handles fetching the installed packages, searching the remote
/// Cloudflare catalog (via `NetworkConfig`), and performing installs/uninstalls.
///
/// **Caveats:**
/// - It performs safety checks (`uses --installed`) before uninstalling a formula to prevent
///   breaking other installed packages silently.
/// - The install/uninstall operations re-query the true filesystem state after completion instead
///   of optimistically mutating the local array.
///
/// ```swift
/// await vm.loadInstalledPackages()
/// if vm.isPackageInstalled("wget", type: .brewFormula) { ... }
/// ```
@MainActor
final class BrewFormulaeCaskViewModel: ObservableObject {
    // Installed packages
    /// The list of installed Homebrew formulae (command-line tools).
    @Published var installedBrewFormulae: [InstalledPackage] = []
    /// The list of installed Homebrew casks (GUI applications).
    @Published var installedBrewCasks: [InstalledPackage] = []
    
    // Search results
    /// Formulae matching the current search query, pulled from the cached catalog.
    @Published var brewFormulaeSearchResults: [String] = []
    /// Casks matching the current search query, pulled from the cached catalog.
    @Published var brewCasksSearchResults: [String] = []
    
    // Loading states
    /// Indicates if installed packages are actively being fetched from the system.
    @Published var isLoading = false
    /// Tracks if the initial load has been performed, preventing redundant `onAppear` fetches.
    @Published var hasLoadedOnce = false
    /// Indicates if a remote formulae search is actively filtering.
    @Published var isSearchingBrewFormulae = false
    /// Indicates if a remote cask search is actively filtering.
    @Published var isSearchingBrewCasks = false
    
    // Processing packages
    /// Names of packages currently undergoing an install or uninstall operation.
    @Published var processingPackages: Set<String> = []

    /// Set when an uninstall is blocked because other installed formulae depend on it.
    /// The View can surface this as a warning banner. Cleared on the next uninstall attempt.
    @Published var lastUninstallWarning: String?
    
    private let baseURL = NetworkConfig.APIEndpoint.baseURL
    private let logger = Logger.shared
    private let brewService: BrewService
    
    // Cache
    private var brewFormulaeCache: [String] = []
    private var brewCasksCache: [String] = []
    private var installedBrewFormulaeSet: Set<String> = []
    private var installedBrewCasksSet: Set<String> = []
    
    // Debounce tracking
    private var formulaeSearchTask: Task<Void, Never>?
    private var casksSearchTask: Task<Void, Never>?
    
    /// Initializes the ``BrewFormulaeCaskViewModel`` with injected dependencies.
    ///
    /// - Parameter brewService: The shared ``BrewService`` instance used for low-level Homebrew operations.
    init(brewService: BrewService) {
        self.brewService = brewService
    }
    
    /// Whether Homebrew is installed on the system.
    @Published var isBrewInstalled = false
    
    // MARK: - Startup
    
    /// Initializes the view model by detecting Homebrew's presence and loading installed packages.
    ///
    /// **Gotchas:**
    /// - Sets ``isBrewInstalled`` synchronously based on the cached ``BrewPathManager/isInstalled`` flag to prevent UI flicker.
    func startup() async {
        isBrewInstalled = BrewPathManager.shared.isInstalled
        await loadInstalledPackages()
    }

    // MARK: - Load Installed Packages
    
    /// Refreshes the local arrays of installed formulae and casks by asking ``InstalledPackagesService``.
    ///
    /// **Flow:**
    /// 1. Bails early if actively loading.
    /// 2. Fetches both sets consecutively.
    /// 3. Maps to the uniform ``InstalledPackage`` protocol and sorts them alphabetically.
    ///
    /// - Parameter forceRefresh: If `true`, bypasses the ``hasLoadedOnce`` check to force a disk read.
    func loadInstalledPackages(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        guard forceRefresh || !hasLoadedOnce else { return }
        
        isLoading = true
        logger.log("📦 Loading installed brew packages...")
        
        // Load brew formulae (with versions)
        let formulae = await InstalledPackagesService.shared.formulae()
        installedBrewFormulaeSet = Set(formulae.map { $0.name })
        installedBrewFormulae = formulae.map { InstalledPackage(name: $0.name, version: $0.version) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Load brew casks (with versions)
        let casks = await InstalledPackagesService.shared.casks()
        installedBrewCasksSet = Set(casks.map { $0.name })
        installedBrewCasks = casks.map { InstalledPackage(name: $0.name, version: $0.version) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        logger.log("✅ Loaded: \(installedBrewFormulae.count) formulae, \(installedBrewCasks.count) casks")
        hasLoadedOnce = true
        isLoading = false
    }
    
    // MARK: - Search Methods (Debounced)
    
    /// Debounces and executes a search against the cached Homebrew formulae catalog.
    ///
    /// **Rationale:**
    /// Wraps the actual filtering logic in a half-second `Task.sleep` debounce so rapid typing doesn't instantly spike CPU.
    ///
    /// - Parameter query: The user's search string. Short queries (< 2 chars) are instantly rejected.
    func searchBrewFormulae(query: String) {
        formulaeSearchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard trimmed.count >= 2 else {
            brewFormulaeSearchResults = []
            return
        }
        
        formulaeSearchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if Task.isCancelled { return }
            
            await performBrewFormulaeSearch(query: trimmed)
        }
    }
    
    /// Debounces and executes a search against the cached Homebrew cask catalog.
    ///
    /// **Rationale:**
    /// Identical debounce pattern to `searchBrewFormulae`.
    ///
    /// - Parameter query: The user's search string. Short queries (< 2 chars) are instantly rejected.
    func searchBrewCasks(query: String) {
        casksSearchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard trimmed.count >= 2 else {
            brewCasksSearchResults = []
            return
        }
        
        casksSearchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            if Task.isCancelled { return }
            
            await performBrewCasksSearch(query: trimmed)
        }
    }
    
    /// Performs the heavy filtering operation on the formulae cache.
    ///
    /// **Caveats:**
    /// - Throws the `.filter` execution onto a detached task. The cached catalog is ~6,000 items; filtering it synchronously
    ///   on the MainActor causes dropped frames during typing.
    ///
    /// - Parameter query: The validated, debounced lowercase string to match.
    private func performBrewFormulaeSearch(query: String) async {
        isSearchingBrewFormulae = true
        
        // Load cache if empty
        if brewFormulaeCache.isEmpty {
            await loadBrewFormulae()
        }
        
        // Filter
        let filtered = await Task.detached {
            await self.brewFormulaeCache
                .filter { $0.lowercased().contains(query) }
                .prefix(100)
        }.value
        
        brewFormulaeSearchResults = Array(filtered)
        logger.log("🔍 Found \(brewFormulaeSearchResults.count) formulae")
        
        isSearchingBrewFormulae = false
    }
    
    /// Performs the heavy filtering operation on the cask cache.
    ///
    /// **Caveats:**
    /// - Matches the detached task performance optimization seen in ``performBrewFormulaeSearch(query:)``.
    ///
    /// - Parameter query: The validated, debounced lowercase string to match.
    private func performBrewCasksSearch(query: String) async {
        isSearchingBrewCasks = true
        
        // Load cache if empty
        if brewCasksCache.isEmpty {
            await loadBrewCasks()
        }
        
        // Filter
        let filtered = await Task.detached {
            await self.brewCasksCache
                .filter { $0.lowercased().contains(query) }
                .prefix(100)
        }.value
        
        brewCasksSearchResults = Array(filtered)
        logger.log("🔍 Found \(brewCasksSearchResults.count) casks")
        
        isSearchingBrewCasks = false
    }
    
    /// Downloads the canonical `homebrew_formulae.json` index from Catalyst's API endpoint.
    ///
    /// **Rationale:**
    /// Caches strictly by `name` rather than carrying the full payload. Relies on ``NetworkConfig/fetchJSON`` to handle HTTP-level TTLs.
    private func loadBrewFormulae() async {
        let url = "\(baseURL)/homebrew_formulae.json"
        
        do {
            guard let apiURL = URL(string: url) else { return }
            let items = try await NetworkConfig.fetchJSON(from: apiURL, as: [BrewCatalogItem].self, ttl: CacheTTL.brewCatalog)
            let names = items.map { $0.name }
            
            brewFormulaeCache = names
            logger.log("✅ Cached \(brewFormulaeCache.count) brew formulae")
        } catch {
            logger.log("❌ Failed to load brew formulae: \(error.localizedDescription)")
        }
    }
    
    /// Downloads the canonical `homebrew_casks.json` index from Catalyst's API endpoint.
    ///
    /// **Rationale:**
    /// Caches strictly by `name` rather than carrying the full payload. Relies on ``NetworkConfig/fetchJSON`` to handle HTTP-level TTLs.
    private func loadBrewCasks() async {
        let url = "\(baseURL)/homebrew_casks.json"
        
        do {
            guard let apiURL = URL(string: url) else { return }
            let items = try await NetworkConfig.fetchJSON(from: apiURL, as: [BrewCatalogItem].self, ttl: CacheTTL.brewCatalog)
            let names = items.map { $0.name }
            
            brewCasksCache = names
            logger.log("✅ Cached \(brewCasksCache.count) brew casks")
        } catch {
            logger.log("❌ Failed to load brew casks: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Check Installation Status
    
    /// Synchronously checks if a package is currently in the installed `Set`.
    ///
    /// - Parameters:
    ///   - name: The raw package name to evaluate.
    ///   - type: Disambiguates whether to look in ``installedBrewFormulaeSet`` or ``installedBrewCasksSet``.
    /// - Returns: `true` if locally installed.
    func isPackageInstalled(_ name: String, type: PackageType) -> Bool {
        let normalized = name.lowercased()
        switch type {
        case .brewFormula:
            return installedBrewFormulaeSet.contains(normalized)
        case .brewCask:
            return installedBrewCasksSet.contains(normalized)
        default:
            return false
        }
    }
    
    // MARK: - Install/Uninstall Brew Formulae
    
    /// Installs a specific formula, showing it in the `processingPackages` set until completion.
    ///
    /// **Flow:**
    /// 1. Sanitizes the name.
    /// 2. Fires off `brew install <name>` via ``AsyncProcessRunner``.
    /// 3. Once resolved, requests a complete cache refresh rather than mutating arrays optimistically.
    ///
    /// - Important: Employs ``InputSanitizer`` to prevent shell injection.
    /// - Parameter name: The formula name to install.
    func installBrewFormula(_ name: String) async {
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return
        }
        
        processingPackages.insert(name)
        logger.log("🍺 Installing \(sanitizedName)...")
        
        let success = ((try? await AsyncProcessRunner.shared.runBrew(arguments: ["install", sanitizedName]))?.succeeded) ?? false

        if success {
            logger.log("✅ Installed \(name)")
        } else {
            logger.log("❌ Failed to install \(name)")
        }

        // Re-query real installed set instead of an optimistic in-place mutation.
        await loadInstalledPackages(forceRefresh: true)

        processingPackages.remove(name)
    }

    // MARK: - Install/Uninstall Brew Casks
    
    /// Installs a specific cask, showing it in the `processingPackages` set until completion.
    ///
    /// **Flow:**
    /// Similar to ``installBrewFormula(name:)``, but pushes the `--cask` flag to `brew install`.
    ///
    /// - Parameter name: The cask name to install.
    func installBrewCask(_ name: String) async {
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return
        }
        
        processingPackages.insert(name)
        logger.log("🍺 Installing \(sanitizedName)...")
        
        let success = ((try? await AsyncProcessRunner.shared.runBrew(arguments: ["install", "--cask", sanitizedName]))?.succeeded) ?? false

        if success {
            logger.log("✅ Installed \(name)")
        } else {
            logger.log("❌ Failed to install \(name)")
        }

        // Re-query real installed set instead of an optimistic in-place mutation.
        await loadInstalledPackages(forceRefresh: true)

        processingPackages.remove(name)
    }

    /// Uninstalls a formula after verifying no other installed formulae depend on it.
    ///
    /// **Gotchas:**
    /// - **Safety Mechanism:** Refuses to silently break dependents. Calls `brew uses --installed` to list
    ///   installed formulae that depend on this one. If any exist, aborts and surfaces a warning string in
    ///   ``lastUninstallWarning`` rather than passing `--ignore-dependencies`.
    ///
    /// - Parameter name: The formula name to uninstall.
    func uninstallBrewFormula(_ name: String) async {
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return
        }
        
        processingPackages.insert(name)
        lastUninstallWarning = nil
        logger.log("🗑️ Uninstalling brew formula: \(sanitizedName)...")

        // Safety: refuse to silently break dependents. `brew uses --installed`
        // lists installed formulae that depend on this one. If any exist, abort
        // and surface a warning rather than passing --ignore-dependencies.
        let dependents = await runCommand(
            executable: BrewPathManager.shared.brewPath,
            args: ["uses", "--installed", sanitizedName]
        )
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

        if !dependents.isEmpty {
            let list = dependents.joined(separator: ", ")
            logger.log("⚠️ Not uninstalling \(name): still required by \(list)")
            lastUninstallWarning = "\(name) can't be removed because these installed formulae depend on it: \(list)."
            processingPackages.remove(name)
            return
        }

        do {
            let result = try await AsyncProcessRunner.shared.runBrew(arguments: ["uninstall", sanitizedName])

            if !result.combinedOutput.isEmpty {
                logger.log("📄 Brew output: \(result.combinedOutput)")
            }

            if result.succeeded {
                logger.log("✅ Uninstalled \(name)")
            } else {
                logger.log("❌ Failed to uninstall \(name) - Exit code: \(result.exitCode)")
            }
        } catch {
            logger.log("❌ Exception: \(error.localizedDescription)")
        }

        // Re-query real installed set instead of an optimistic in-place mutation.
        await loadInstalledPackages(forceRefresh: true)

        processingPackages.remove(name)
    }

    /// Uninstalls a cask forcefully (`--force`).
    ///
    /// **Rationale:**
    /// Casks are fundamentally `.app` bundles, so "dependents" check aren't strictly necessary.
    /// We aggressively pass `--force` to ensure it wipes out the cask even if there's minor symlink drift.
    ///
    /// - Parameter name: The cask name to remove.
    func uninstallBrewCask(_ name: String) async {
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return
        }
        
        processingPackages.insert(name)
        logger.log("🗑️ Uninstalling brew cask: \(sanitizedName)...")
        
        do {
            let result = try await AsyncProcessRunner.shared.runBrew(arguments: ["uninstall", "--cask", "--force", sanitizedName])

            if !result.combinedOutput.isEmpty {
                logger.log("📄 Brew output: \(result.combinedOutput)")
            }

            if result.succeeded {
                logger.log("✅ Uninstalled \(name)")
            } else {
                logger.log("❌ Failed to uninstall \(name) - Exit code: \(result.exitCode)")
            }
        } catch {
            logger.log("❌ Exception: \(error.localizedDescription)")
        }

        // Re-query real installed set instead of an optimistic in-place mutation.
        await loadInstalledPackages(forceRefresh: true)

        processingPackages.remove(name)
    }

    /// Executes a low-level binary without a subshell wrapper.
    ///
    /// **Rationale:**
    /// Uses array-arguments rather than string concatenation. Because this skips the shell environment (`/bin/sh -c`),
    /// no shell injection is possible, making it inherently safer for dynamic user inputs.
    ///
    /// - Parameters:
    ///   - executable: The absolute path to the binary (e.g., `BrewPathManager.shared.brewPath`).
    ///   - args: The components of the command payload.
    /// - Returns: The extracted `stdout`.
    private func runCommand(executable: String, args: [String]) async -> String {
        // Array-args: no shell, no quoting — arguments can't be reinterpreted.
        do {
            return try await AsyncProcessRunner.shared.run(executable: executable, arguments: args).stdout
        } catch {
            return ""
        }
    }

}
