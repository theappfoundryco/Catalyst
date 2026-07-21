import Foundation
import Combine

/// A single catalog entry from the backend formulae/casks JSON. Hoisted out of
/// `loadBrewFormulae`/`loadBrewCasks`, which each defined an identical local copy.
private struct BrewCatalogItem: Codable {
    let name: String
}

@MainActor
final class BrewFormulaeCaskViewModel: ObservableObject {
    // Installed packages
    @Published var installedBrewFormulae: [InstalledPackage] = []
    @Published var installedBrewCasks: [InstalledPackage] = []
    
    // Search results
    @Published var brewFormulaeSearchResults: [String] = []
    @Published var brewCasksSearchResults: [String] = []
    
    // Loading states
    @Published var isLoading = false
    @Published var hasLoadedOnce = false
    @Published var isSearchingBrewFormulae = false
    @Published var isSearchingBrewCasks = false
    
    // Processing packages
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
    
    init(brewService: BrewService) {
        self.brewService = brewService
    }
    
    /// Whether Homebrew is installed on the system.
    @Published var isBrewInstalled = false
    
    // MARK: - Startup
    
    func startup() async {
        isBrewInstalled = BrewPathManager.shared.isInstalled
        await loadInstalledPackages()
    }

    // MARK: - Load Installed Packages
    
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

    private func runCommand(executable: String, args: [String]) async -> String {
        // Array-args: no shell, no quoting — arguments can't be reinterpreted.
        do {
            return try await AsyncProcessRunner.shared.run(executable: executable, arguments: args).stdout
        } catch {
            return ""
        }
    }

}
