import Foundation
import SwiftUI
import Combine

/// A curated, high-value ecosystem package displayed in the recommendation grid.
struct PopularPackage: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let downloads: String?
    
    init(id: UUID = UUID(), name: String, downloads: String?) {
        self.id = id
        self.name = name
        self.downloads = downloads
    }
}

/// A view model that orchestrates the "Popular Packages" discovery tab.
///
/// It fetches curated JSON lists (from `NetworkConfig.APIEndpoint.popularURL`) for Pip,
/// Formulae, and Casks, and allows one-click installation by bridging to `PackageInstaller`.
///
/// **Caveats:**
/// - Loading three separate JSON endpoints (pip, formulae, casks) can be slow. A local caching
///   mechanism (`loadPopularCache`) runs asynchronously on init to ensure immediate UI presentation.
/// - Installed state is tracked aggressively so packages immediately swap from "Install" to "Installed"
///   without requiring a full environment refresh.
///
/// ```swift
/// @StateObject var vm = PopularPackagesViewModel(pythonService: ..., logger: ...)
/// await vm.refresh()
/// ```
@MainActor
final class PopularPackagesViewModel: ObservableObject {
    /// The fetched array of trending/popular Pip packages.
    @Published var popularPip: [PopularPackage] = []
    @Published var popularFormulae: [PopularPackage] = []
    @Published var popularCasks: [PopularPackage] = []
    @Published var installedPip: Set<String> = []
    @Published var installedFormulae: Set<String> = []
    @Published var installedCasks: Set<String> = []
    @Published var isLoading = false
    @Published var installingPackage: String?
    /// Install output on its own observable so a chunk re-renders only the
    /// console, not the popular-packages catalog (R2). Bridge keeps `+=` sites.
    let console = ConsoleOutput()
    var output: String {
        get { console.text }
        set { console.set(newValue) }
    }
    /// Indicates if Homebrew is available on the system.
    @Published var isBrewInstalled = false
    /// Indicates if at least one valid Python with Pip is available.
    @Published var isPythonWithPipAvailable = false
    /// Prevents redundant reloading during view lifecycle (`onAppear`).
    @Published var hasLoadedOnce = false
    /// Short, user-facing error surfaced as a banner when an install fails (P3).
    /// Distinct from the streamed console output. Cleared on the next install.
    @Published var installError: String?

    // Python version selection
    /// Locally cached Python interpreters with Pip capabilities.
    @Published var availablePythonVersions: [PythonInstallation] = []
    /// The user-selected Python interpreter for pip package operations.
    @Published var selectedPythonVersion: PythonInstallation?

    /// Whether the selected interpreter is externally managed under PEP 668 (Python 3.12+).
    ///
    /// Drives the pip tab's "Protected Mode" badge: combined with
    /// ``PipInstallMode/protected`` in the view, it swaps the Install button for a
    /// passive badge, because pip would refuse the write and the failure used to be
    /// silent. Mirrors `PIPPackagesInstallViewModel.requiresBreakSystemPackages`.
    ///
    /// - Note: Only consulted for the pip tab — PEP 668 has no Homebrew analogue.
    var requiresBreakSystemPackages: Bool {
        guard let python = selectedPythonVersion else { return false }
        return VersionComparator.requiresBreakSystemPackages(pythonVersion: python.version)
    }

    private let pythonService: PythonService
    private let logger: Logger
    /// Builds + runs the install command (extracted out of this VM, R1).
    private let installer: PackageInstaller
    private let popularURL = NetworkConfig.APIEndpoint.popularURL
    
    /// The top-level schema mapping the remote community-curated package manifest.
    struct PopularData: Codable {
        let name: String
        let downloads: String?
    }
    
    init(pythonService: PythonService, logger: Logger) {
        self.pythonService = pythonService
        self.logger = logger
        self.installer = PackageInstaller(logger: logger)

        // Load cache asynchronously to avoid blocking main thread (#28)
        Task {
            loadPopularCache()
            await checkPrerequisites()
        }
    }

    /// Verifies base system requirements before querying for packages.
    ///
    /// **Flow:**
    /// 1. Synchronously checks if `BrewPathManager` sees `brew`.
    /// 2. Asynchronously asks `PythonService` for interpreters capable of pip.
    /// 3. Auto-selects the first valid Python if none is currently active.
    func checkPrerequisites() async {
        // Check Homebrew
        isBrewInstalled = BrewPathManager.shared.isInstalled
        
        // Check Python with pip and load versions
        do {
            let pythons = try await pythonService.detectPythons()
            availablePythonVersions = pythons.filter { $0.pipAvailable }
            isPythonWithPipAvailable = !availablePythonVersions.isEmpty
            
            // Auto-select first Python with pip if none selected
            if selectedPythonVersion == nil, let first = availablePythonVersions.first {
                selectedPythonVersion = first
            }
        } catch {
            isPythonWithPipAvailable = false
            availablePythonVersions = []
        }
        
        logger.log("Prerequisites: Brew=\(isBrewInstalled), Python/pip=\(isPythonWithPipAvailable), versions=\(availablePythonVersions.count)")
    }
    
    /// Pulls the JSON feeds for popular packages, updating caches automatically.
    ///
    /// **Flow:**
    /// 1. Emits three concurrent fetch tasks (`async let`) for pip, formulae, and casks.
    /// 2. Awaits all three network responses.
    /// 3. Replaces the local arrays and writes them to `UserDefaults` (via ``savePopularCache()``).
    func loadPopularPackages() async {
        guard !hasLoadedOnce else { return }
        
        isLoading = true
        logger.log("📥 Loading popular packages...")
        
        async let pip = fetchPopular(type: "pip")
        async let formulae = fetchPopular(type: "formulae")
        async let casks = fetchPopular(type: "casks")
        
        let (pipData, formulaeData, casksData) = await (pip, formulae, casks)
        
        popularPip = pipData
        popularFormulae = formulaeData
        popularCasks = casksData
        
        logger.log("✅ Loaded popular packages: \(popularPip.count) pip, \(popularFormulae.count) formulae, \(popularCasks.count) casks")
        hasLoadedOnce = true
        savePopularCache()  // Save to cache
        
        isLoading = false
    }
    
    /// Forces a bypass of `hasLoadedOnce`, wiping all caches and re-checking prerequisites.
    ///
    /// - Parameter forceRefresh: Flag to explicitly purge backing caches.
    func refresh(forceRefresh: Bool = false) async {
        hasLoadedOnce = false
        // Invalidate Python cache on manual refresh
        pythonService.invalidateCache()
        await checkPrerequisites()
        await loadPopularPackages()
        await loadInstalledPackages()
    }
    
    /// Generic helper to download and decode a specific package category JSON.
    ///
    /// - Parameter type: The string suffix mapping to the remote JSON endpoint.
    /// - Returns: An array of ``PopularPackage`` models.
    private func fetchPopular(type: String) async -> [PopularPackage] {
        guard let url = URL(string: "\(popularURL)/\(type).json") else {
            logger.log("❌ Invalid URL for \(type)")
            return []
        }
        
        do {
            let items = try await NetworkConfig.fetchJSON(from: url, as: [PopularData].self, ttl: CacheTTL.popular)
            return items.map { PopularPackage(name: $0.name, downloads: $0.downloads) }
        } catch {
            logger.log("❌ Failed to fetch popular \(type): \(error.localizedDescription)")
            return []
        }
    }
    
    /// Populates the fast-lookup sets (`installedPip`, etc) for UI badging.
    ///
    /// **Rationale:**
    /// By maintaining `Set<String>` representations of installed tools, the UI can badge an item as
    /// "Installed" in O(1) time rather than scanning disk artifacts repeatedly.
    func loadInstalledPackages() async {
        // Load installed pip packages for selected Python
        await loadPipPackagesForSelectedPython()
        
        // Load installed formulae
        installedFormulae = await getInstalledFormulae()
        
        // Load installed casks
        installedCasks = await getInstalledCasks()
        
        logger.log("✅ Loaded installed packages: \(installedPip.count) pip, \(installedFormulae.count) formulae, \(installedCasks.count) casks")
    }
    
    /// Load pip packages for the currently selected Python version.
    func loadPipPackagesForSelectedPython() async {
        guard let python = selectedPythonVersion else {
            installedPip = []
            return
        }
        installedPip = await getInstalledPip(pythonPath: python.path.path)
        logger.log("📦 Loaded \(installedPip.count) pip packages for Python \(python.version)")
    }
    
    /// Fetches the raw freeze array and maps it to a unique set for PIP.
    private func getInstalledPip(pythonPath: String) async -> Set<String> {
        Set(await InstalledPackagesService.shared.pipPackages(pythonPath: pythonPath).map { $0.name })
    }

    /// Fetches the raw array and maps it to a unique set for Formulae.
    private func getInstalledFormulae() async -> Set<String> {
        Set(await InstalledPackagesService.shared.formulae().map { $0.name })
    }

    /// Fetches the raw array and maps it to a unique set for Casks.
    private func getInstalledCasks() async -> Set<String> {
        Set(await InstalledPackagesService.shared.casks().map { $0.name })
    }
    
    /// Synchronously writes the in-memory arrays to `UserDefaults`.
    private func savePopularCache() {
        let cache = [
            "pip": popularPip,
            "formulae": popularFormulae,
            "casks": popularCasks
        ]
        
        if let encoded = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(encoded, forKey: "popular_packages_cache")
            logger.log("💾 Cached popular packages")
        }
    }

    /// Synchronously hydrates the arrays from `UserDefaults` to provide an instant UI layout.
    private func loadPopularCache() {
        if let data = UserDefaults.standard.data(forKey: "popular_packages_cache"),
           let cache = try? JSONDecoder().decode([String: [PopularPackage]].self, from: data) {
            popularPip = cache["pip"] ?? []
            popularFormulae = cache["formulae"] ?? []
            popularCasks = cache["casks"] ?? []
            hasLoadedOnce = true
            logger.log("📂 Loaded popular packages from cache")
        }
    }
    
    /// Returns true if the given package name exists in the appropriate local tracking set.
    ///
    /// - Parameters:
    ///   - name: The package string identifier.
    ///   - type: Disambiguates whether to check the pip, formula, or cask sets.
    /// - Returns: True if present.
    func isInstalled(_ name: String, type: PackageType) -> Bool {
        let lowerName = name.lowercased()
        switch type {
        case .pip:
            return installedPip.contains(InputSanitizer.normalizePipPackageName(name))
        case .brewFormula:
            return installedFormulae.contains(lowerName)
        case .brewCask:
            return installedCasks.contains(lowerName)
        }
    }
    
    /// Routes the package to the centralized ``PackageInstaller`` and handles UI updates.
    ///
    /// **Flow:**
    /// 1. Clears prior errors/console and sets the active `installingPackage`.
    /// 2. Invokes the injected ``PackageInstaller``, funneling its stdout into `output`.
    /// 3. On `.success`, *optimistically* injects the package name into the fast-lookup sets, instantly updating the UI button to "Installed".
    /// 4. Dispatches an async ``loadInstalledPackages()`` to perform a true disk validation sweep.
    ///
    /// - Parameters:
    ///   - name: The target application or package.
    ///   - type: Formula, Cask, or Pip.
    func installPackage(_ name: String, type: PackageType) async {
        installingPackage = name
        output = ""
        installError = nil

        let result = await installer.install(
            name: name,
            type: type,
            pythonPath: selectedPythonVersion?.path.path,
            pythonVersion: selectedPythonVersion?.version
        ) { [weak self] in
            self?.output += $0
        }

        switch result {
        case .invalidName:
            installError = "Invalid package name: \(name)"
            installingPackage = nil
        case .noPython:
            installError = "No Python version selected."
            installingPackage = nil
        case .success:
            // Immediately update installed state (before the async reload).
            let lowerName = name.lowercased()
            switch type {
            case .pip: installedPip.insert(InputSanitizer.normalizePipPackageName(name))
            case .brewFormula: installedFormulae.insert(lowerName)
            case .brewCask: installedCasks.insert(lowerName)
            }
            installingPackage = nil
            await loadInstalledPackages()
        case .failure(let message):
            installError = message
            installingPackage = nil
            await loadInstalledPackages()
        }
    }

    /// Clears the streaming console output view for the next operation.
    func clearOutput() {
        output = ""
    }
}
