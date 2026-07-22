import Foundation
import Combine

/// A view model that coordinates the display and removal of installed pip packages.
///
/// It aggregates the raw list of Python modules by wrapping `pip list --format=freeze`.
/// It implements a caching layer (`pipPackagesCache`) keyed by Python version to prevent UI
/// delays when rapidly swapping between installed Pythons.
///
/// ```swift
/// await vm.loadInstalledPackages()
/// await vm.uninstallPipPackage("requests")
/// ```
@MainActor
final class PIPPackagesViewModel: ObservableObject {
    // Installed packages
    /// The sorted array of packages installed in the currently selected Python environment.
    @Published var installedPipPackages: [InstalledPackage] = []
    /// Available Python environments that can host pip packages.
    @Published var availablePythonVersions: [PythonInstallation] = []
    /// The Python environment currently being viewed.
    @Published var selectedPythonVersion: PythonInstallation?
    
    // Search results
    /// Search results filtering the locally installed pip packages.
    @Published var pipSearchResults: [String] = []
    
    // Loading states
    /// Indicates if installed packages are actively being fetched.
    @Published var isLoading = false
    /// Tracks if the initial load has been performed, preventing redundant `onAppear` fetches.
    @Published var hasLoadedOnce = false
    /// Indicates if a local search filter is actively running.
    @Published var isSearchingPip = false
    
    // Processing packages
    /// The set of package names currently undergoing installation or uninstallation.
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
    
    /// Downcases and sanitizes a package name per PEP 503 logic.
    ///
    /// - Parameter name: Raw package string.
    /// - Returns: Safely normalized identifier.
    private func normalizePackageName(_ name: String) -> String {
        // PEP 503 normalization
        InputSanitizer.normalizePipPackageName(name)
    }
    
    // MARK: - Startup
    
    /// Bootstraps the VM by eagerly loading installed packages for the first valid Python.
    func startup() async {
        await loadInstalledPackages()
    }

    // MARK: - Load Installed Packages
    
    /// Pulls the installed pip list for the active Python, respecting the cache unless `forceRefresh` is true.
    ///
    /// **Flow:**
    /// 1. Prevents duplicate concurrent loads.
    /// 2. If `forceRefresh` is requested, it flushes the ``PythonService`` cache and re-scans the environment.
    /// 3. Yields to ``loadPipPackagesForSelectedPython`` which checks the local `pipPackagesCache`.
    ///
    /// - Parameter forceRefresh: Skips the in-memory dictionary cache if true.
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
    
    /// Scans the system for installed Pythons using ``PythonService``.
    /// Automatically selects the first environment with pip available.
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
    
    /// Load pip packages for selected Python, using cache if available.
    ///
    /// **Rationale:**
    /// Querying `pip list` takes 200-500ms depending on disk speed. Caching this per-interpreter
    /// prevents stutter when the user toggles back and forth in the UI picker.
    ///
    /// - Parameter forceRefresh: Bypasses the `pipPackagesCache` entirely.
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
    
    /// Purges the cached package dictionary for a specific Python interpreter.
    ///
    /// **Gotchas:**
    /// - Call this *immediately* after an install/uninstall succeeds to ensure the next UI read pulls fresh data.
    ///
    /// - Parameter version: The version string (e.g. `3.12.1`) to purge. If nil, purges the currently selected one.
    func invalidatePipCache(forPython version: String? = nil) {
        if let version = version {
            pipPackagesCache.removeValue(forKey: version)
        } else if let selected = selectedPythonVersion {
            pipPackagesCache.removeValue(forKey: selected.version)
        }
    }
    
    /// Delegates out to ``InstalledPackagesService/pipPackages(pythonPath:)`` to get the raw tuple array.
    private func getInstalledPipPackages() async -> [(name: String, version: String?)] {
        // Use selected Python version
        guard let python = selectedPythonVersion else {
            logger.log("⚠️ No Python version selected")
            return []
        }
        return await InstalledPackagesService.shared.pipPackages(pythonPath: python.path.path)
    }
    
    // MARK: - Search Methods (Debounced)
    
    /// Debounces and filters the locally installed pip packages based on user input.
    ///
    /// **Flow:**
    /// 1. Cancels the existing `pipSearchTask`.
    /// 2. Demands a minimum of 2 characters.
    /// 3. Sleeps for 500ms before hitting the network shard.
    ///
    /// - Parameter query: The text to search for on PyPI.
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
    
    /// Executes the PyPI shard fetch.
    ///
    /// **Caveats:**
    /// - ⚠️ CONTRACT MISMATCH (flagged in source): decodes `[String]` but the actual PyPI shards are `[{ name, fetched_at }]`.
    ///   Preserved current behavior to avoid breaking changes during documentation.
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
    
    /// Synchronously checks if a package exists in the current `installedPipSet`.
    ///
    /// - Parameter name: The raw package name to verify.
    /// - Returns: `true` if locally installed.
    func isPackageInstalled(_ name: String) -> Bool {
        let normalized = normalizePackageName(name)
        return installedPipSet.contains(normalized)
    }
    
    // MARK: - Install/Uninstall pip
    
    /// Uses the local environment to directly install a package by name.
    ///
    /// **Flow:**
    /// 1. Sanitizes input via ``InputSanitizer/sanitizePackageName(_:)``.
    /// 2. Invokes `-m pip install` directly via Array-args (no shell injection risk).
    /// 3. Imperatively purges the local cache (`invalidatePipCache`) and triggers a hard reload.
    ///
    /// - Parameter name: The PyPI package name.
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
    
    /// Uninstalls a pip package via `pip uninstall -y`.
    ///
    /// **Flow:**
    /// 1. Sanitizes input.
    /// 2. Executes `-m pip uninstall -y` via safe Array-args.
    /// 3. Exits cleanly regardless of whether the package existed (since `-y` exits 0 if absent).
    /// 4. Re-queries real state rather than mutating the list optimistically (prevents UI drift).
    ///
    /// - Parameter name: The package to remove.
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
    
    /// Private helper to fire off an array-argument execution without shell bridging.
    private func runCommandWithStatus(executable: String, args: [String]) async -> Bool {
        // Array-args: no shell, no quoting.
        do {
            return try await AsyncProcessRunner.shared.run(executable: executable, arguments: args).succeeded
        } catch {
            return false
        }
    }
}
