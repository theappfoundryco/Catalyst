import Foundation
import Combine

@MainActor
final class PIPPackagesViewModel: ObservableObject {
    // Installed packages
    @Published var installedPipPackages: [InstalledPackage] = []
    @Published var availablePythonVersions: [PythonInstallation] = []
    @Published var selectedPythonVersion: PythonInstallation?
    
    // Search results
    @Published var pipSearchResults: [String] = []
    
    // Loading states
    @Published var isLoading = false
    @Published var hasLoadedOnce = false
    @Published var isSearchingPip = false
    
    // Processing packages
    @Published var processingPackages: Set<String> = []
    
    private let baseURL = NetworkConfig.APIEndpoint.baseURL
    private let logger = Logger.shared
    private let pythonService: PythonService
    
    // Cache
    private var installedPipSet: Set<String> = []
    private var pipPackagesCache: [String: [InstalledPackage]] = [:]
    
    // Debounce tracking
    private var pipSearchTask: Task<Void, Never>?

    // Refresh when the installed-Python set changes elsewhere (e.g. an uninstall).
    private var pyInventoryObserver: NSObjectProtocol?

    init(pythonService: PythonService) {
        self.pythonService = pythonService
        pyInventoryObserver = NotificationCenter.default.addObserver(
            forName: .catalystPythonInventoryChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.loadPythonVersions()
                await self.loadInstalledPackages(forceRefresh: true)
            }
        }
    }

    deinit {
        if let pyInventoryObserver { NotificationCenter.default.removeObserver(pyInventoryObserver) }
    }
    
    private func normalizePackageName(_ name: String) -> String {
        // PEP 503 normalization
        InputSanitizer.normalizePipPackageName(name)
    }
    
    // MARK: - Startup
    
    func startup() async {
        await loadInstalledPackages()
    }

    // MARK: - Load Installed Packages
    
    func loadInstalledPackages(forceRefresh: Bool = false) async {
        guard !isLoading else { return }
        guard forceRefresh || !hasLoadedOnce else { return }
        
        isLoading = true
        logger.log("📦 Loading installed pip packages...")
        
        // Always reload Python versions on force refresh, or if empty
        if forceRefresh || availablePythonVersions.isEmpty {
            if forceRefresh {
                pythonService.invalidateCache()
            }
            await loadPythonVersions()
        }
        
        // Load pip (with caching)
        await loadPipPackagesForSelectedPython(forceRefresh: forceRefresh)
        
        hasLoadedOnce = true
        isLoading = false
    }
    
    func loadPythonVersions() async {
        do {
            availablePythonVersions = try await pythonService.detectPythons()
            logger.log("✅ Found \(availablePythonVersions.count) Python installation(s)")
            
            // Auto-select first Python with pip if none selected
            if selectedPythonVersion == nil, let first = availablePythonVersions.first(where: { $0.pipAvailable }) {
                selectedPythonVersion = first
            }
        } catch {
            logger.log("❌ Failed to detect Python: \(error.localizedDescription)")
            availablePythonVersions = []
        }
    }
    
    /// Load pip packages for selected Python, using cache if available
    func loadPipPackagesForSelectedPython(forceRefresh: Bool = false) async {
        guard let python = selectedPythonVersion else { return }
        
        // Check cache first (unless force refresh)
        if !forceRefresh, let cached = pipPackagesCache[python.version] {
            installedPipPackages = cached
            installedPipSet = Set(cached.map { $0.name })
            logger.log("📦 Using cached pip packages for Python \(python.version): \(cached.count) packages")
            return
        }
        
        // Fetch from Python
        logger.log("📦 Loading pip packages for Python \(python.version)...")
        let pipList = await getInstalledPipPackages()

        installedPipSet = Set(pipList.map { $0.name })
        installedPipPackages = pipList
            .map { InstalledPackage(name: $0.name, version: $0.version) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        
        // Cache the result
        pipPackagesCache[python.version] = installedPipPackages
        logger.log("✅ Loaded and cached \(installedPipPackages.count) pip packages for Python \(python.version)")
    }
    
    /// Clear cache for a specific Python version (call after install/uninstall)
    func invalidatePipCache(forPython version: String? = nil) {
        if let version = version {
            pipPackagesCache.removeValue(forKey: version)
        } else if let selected = selectedPythonVersion {
            pipPackagesCache.removeValue(forKey: selected.version)
        }
    }
    
    private func getInstalledPipPackages() async -> [(name: String, version: String?)] {
        // Use selected Python version
        guard let python = selectedPythonVersion else {
            logger.log("⚠️ No Python version selected")
            return []
        }
        return await InstalledPackagesService.shared.pipPackages(pythonPath: python.path.path)
    }
    
    // MARK: - Search Methods (Debounced)
    
    func searchPip(query: String) {
        pipSearchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        guard trimmed.count >= 2 else {
            pipSearchResults = []
            return
        }
        
        pipSearchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            
            if Task.isCancelled { return }
            
            await performPipSearch(query: trimmed)
        }
    }
    
    private func performPipSearch(query: String) async {
        isSearchingPip = true
        
        // Get first 2 characters for shard
        let prefix = String(query.prefix(2))
        let shardURL = "\(baseURL)/pypi/\(prefix).json"
        
        do {
            guard let url = URL(string: shardURL) else {
                throw URLError(.badURL)
            }
            
            // ⚠️ CONTRACT MISMATCH (flagged): this decodes [String], but the pypi
            // shards are [{ name, fetched_at }] objects (PIPPackagesInstallViewModel
            // correctly uses [PackageItem]). As-is this decode fails → installed-pip
            // search returns nothing. Preserved behavior during centralization;
            // fix by switching to [PackageItem] + .map { $0.name } when you're ready.
            let packages = try await NetworkConfig.fetchJSON(from: url, as: [String].self, ttl: CacheTTL.pypiShard)
            let filtered = Array(packages
                .filter { $0.lowercased().contains(query) }
                .prefix(100))
            
            pipSearchResults = filtered
            logger.log("🔍 Found \(pipSearchResults.count) pip packages")
        } catch {
            logger.log("❌ Failed to search pip: \(error.localizedDescription)")
            pipSearchResults = []
        }
        
        isSearchingPip = false
    }
    
    // MARK: - Check Status
    
    func isPackageInstalled(_ name: String) -> Bool {
        let normalized = normalizePackageName(name)
        return installedPipSet.contains(normalized)
    }
    
    // MARK: - Install/Uninstall pip
    
    func installPipPackage(_ name: String) async {
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return
        }
        
        guard let python = selectedPythonVersion else {
            logger.log("❌ No Python version selected")
            return
        }
        
        processingPackages.insert(name)
        logger.log("📦 Installing \(sanitizedName) via Python \(python.version)...")
        
        let success = await runCommandWithStatus(
            executable: python.path.path,
            args: ["-m", "pip", "install", sanitizedName]
        )

        if success {
            logger.log("✅ Installed \(name)")
        } else {
            logger.log("❌ Failed to install \(name)")
        }

        // Re-query the real installed set instead of mutating the list
        // optimistically. Optimistic updates drift from reality: "Requirement
        // already satisfied" (exit 0, no change) and partial failures would
        // otherwise leave the UI showing the wrong thing until a full refresh.
        invalidatePipCache(forPython: python.version)
        await loadPipPackagesForSelectedPython(forceRefresh: true)

        processingPackages.remove(name)
    }
    
    func uninstallPipPackage(_ name: String) async {
        guard let sanitizedName = InputSanitizer.sanitizePackageName(name) else {
            logger.log("❌ Invalid package name: \(name)")
            return
        }
        
        processingPackages.insert(name)
        logger.log("🗑️ Uninstalling \(sanitizedName)...")
        
        guard let python = selectedPythonVersion else {
            logger.log("❌ No Python version selected")
            processingPackages.remove(name)
            return
        }
        
        do {
            // Array-args: no shell, no quoting.
            let result = try await AsyncProcessRunner.shared.run(
                executable: python.path.path,
                arguments: ["-m", "pip", "uninstall", "-y", sanitizedName]
            )

            if !result.combinedOutput.isEmpty {
                logger.log("📄 Output: \(result.combinedOutput)")
            }

            // Decide success by exit code, not by scraping output strings
            // (locale/version fragile). `pip uninstall -y` exits 0 both when it
            // removes the package and when it was already absent — either way
            // the package is gone, which the re-query below reflects.
            if result.succeeded {
                logger.log("✅ \(name) is no longer installed")
            } else {
                logger.log("❌ Failed to uninstall \(name) — exit code \(result.exitCode)")
            }
        } catch {
            logger.log("❌ Exception: \(error.localizedDescription)")
        }

        // Re-query real state rather than mutating the list optimistically.
        invalidatePipCache(forPython: python.version)
        await loadPipPackagesForSelectedPython(forceRefresh: true)

        processingPackages.remove(name)
    }
    
    private func runCommandWithStatus(executable: String, args: [String]) async -> Bool {
        // Array-args: no shell, no quoting.
        do {
            return try await AsyncProcessRunner.shared.run(executable: executable, arguments: args).succeeded
        } catch {
            return false
        }
    }
}
