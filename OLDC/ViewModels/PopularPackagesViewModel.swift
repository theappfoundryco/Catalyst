import Foundation
import SwiftUI
import Combine

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

@MainActor
final class PopularPackagesViewModel: ObservableObject {
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
    @Published var isBrewInstalled = false
    @Published var isPythonWithPipAvailable = false
    @Published var hasLoadedOnce = false
    /// Short, user-facing error surfaced as a banner when an install fails (P3).
    /// Distinct from the streamed console output. Cleared on the next install.
    @Published var installError: String?

    // Python version selection
    @Published var availablePythonVersions: [PythonInstallation] = []
    @Published var selectedPythonVersion: PythonInstallation?

    private let pythonService: PythonService
    private let logger: Logger
    /// Builds + runs the install command (extracted out of this VM, R1).
    private let installer: PackageInstaller
    private let popularURL = NetworkConfig.APIEndpoint.popularURL
    
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
    
    func refresh(forceRefresh: Bool = false) async {
        hasLoadedOnce = false
        // Invalidate Python cache on manual refresh
        pythonService.invalidateCache()
        await checkPrerequisites()
        await loadPopularPackages()
        await loadInstalledPackages()
    }
    
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
    
    func loadInstalledPackages() async {
        // Load installed pip packages for selected Python
        await loadPipPackagesForSelectedPython()
        
        // Load installed formulae
        installedFormulae = await getInstalledFormulae()
        
        // Load installed casks
        installedCasks = await getInstalledCasks()
        
        logger.log("✅ Loaded installed packages: \(installedPip.count) pip, \(installedFormulae.count) formulae, \(installedCasks.count) casks")
    }
    
    /// Load pip packages for the currently selected Python version
    func loadPipPackagesForSelectedPython() async {
        guard let python = selectedPythonVersion else {
            installedPip = []
            return
        }
        installedPip = await getInstalledPip(pythonPath: python.path.path)
        logger.log("📦 Loaded \(installedPip.count) pip packages for Python \(python.version)")
    }
    
    private func getInstalledPip(pythonPath: String) async -> Set<String> {
        Set(await InstalledPackagesService.shared.pipPackages(pythonPath: pythonPath).map { $0.name })
    }

    private func getInstalledFormulae() async -> Set<String> {
        Set(await InstalledPackagesService.shared.formulae().map { $0.name })
    }

    private func getInstalledCasks() async -> Set<String> {
        Set(await InstalledPackagesService.shared.casks().map { $0.name })
    }
    
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

    func clearOutput() {
        output = ""
    }
}
