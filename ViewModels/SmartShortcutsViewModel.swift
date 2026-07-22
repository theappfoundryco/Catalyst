import Foundation
import SwiftUI
import Combine

/// A view model governing the Catalyst "Smart Shortcuts" discovery and installation tab.
///
/// It fetches a remote catalog of curated bash functions/aliases from `NetworkConfig.APIEndpoint.shortcutsURL`,
/// categorizes them, and bridges to `ShortcutInstaller` to append them safely to `~/.zshrc`.
///
/// **Caveats:**
/// - Caching is aggressive (7-day API cache, 14-day local JSON cache) to avoid GitHub rate limits.
///   Use `forceReload` to bust this caching layer if immediate freshness is required.
///
/// ```swift
/// @StateObject var vm = SmartShortcutsViewModel(logger: ..., pythonService: ...)
/// await vm.loadData()
/// ```
@MainActor
final class SmartShortcutsViewModel: ObservableObject {
    // Derived lists recompute on input change, not per render (R3).
    /// The master list of all fetched shortcuts.
    @Published var shortcuts: [ShortcutItem] = [] { didSet { recomputeDerived() } }
    /// A dictionary mapping shortcut IDs to their installed metadata (e.g. custom function name).
    @Published var installedShortcuts: [String: InstalledShortcut] = [:] // id -> details
    /// Indicates whether the catalog is actively fetching from the network.
    @Published var isLoading = false
    /// The user's active search query for filtering the catalog.
    @Published var searchQuery = "" { didSet { recomputeFiltered() } }
    /// The user's selected category for filtering the catalog.
    @Published var selectedCategory: String? = nil { didSet { recomputeFiltered() } }

    /// The subset of `shortcuts` matching current search and category filters.
    @Published private(set) var filteredShortcuts: [ShortcutItem] = []
    /// All discovered categories across the master shortcuts list.
    @Published private(set) var categories: [String] = []
    /// Indicates if Homebrew is available (used for prerequisites check).
    @Published var isBrewInstalled = false
    /// Indicates if a valid Python interpreter with pip is available.
    @Published var isPythonWithPipAvailable = false
    /// Prevents redundant catalog fetches during view lifecycle appearances.
    @Published var hasLoadedOnce = false

    private let logger: Logger
    private let pythonService: PythonService
    /// Install/uninstall engine (deps, shell-config writes, helpers) extracted
    /// out of this VM (R1).
    private let installer: ShortcutInstaller
    private let baseURL = NetworkConfig.APIEndpoint.shortcutsURL

    // Cache expiry: 7 days
    private let cacheExpirySeconds: TimeInterval = 14 * 24 * 60 * 60
    private let cacheTimestampKey = "shortcuts_cache_timestamp"

    init(logger: Logger, pythonService: PythonService) {
        self.logger = logger
        self.pythonService = pythonService
        self.installer = ShortcutInstaller(pythonService: pythonService, logger: logger)
    }
    
    /// Entry point for view appearance: hydrates local caches and validates system deps.
    ///
    /// **Gotchas:**
    /// Exits early if `hasLoadedOnce` is true, preserving scroll state and avoiding unnecessary network bursts.
    func loadData() async {
        guard !hasLoadedOnce else { return }
        
        loadInstalledShortcuts()
        loadShortcutsCache()
        await checkPrerequisites()
        await loadShortcuts()
    }
    
    /// Recomputes the sorted `categories` array and invokes the downstream `recomputeFiltered()`.
    private func recomputeDerived() {
        categories = Array(Set(shortcuts.map { $0.category })).sorted()
        recomputeFiltered()
    }

    /// Filters the master `shortcuts` array by active search string and category.
    private func recomputeFiltered() {
        var filtered = shortcuts

        // Filter by category
        if let category = selectedCategory {
            filtered = filtered.filter { $0.category == category }
        }

        // Filter by search query
        if !searchQuery.isEmpty {
            filtered = filtered.filter { shortcut in
                shortcut.title.localizedCaseInsensitiveContains(searchQuery) ||
                shortcut.tagline.localizedCaseInsensitiveContains(searchQuery) ||
                shortcut.category.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        filteredShortcuts = filtered
    }

    /// Pulls the catalog over the network, bypassing the view-lifecycle lock but respecting HTTP caches.
    ///
    /// **Flow:**
    /// 1. Verifies prerequisites.
    /// 2. Manually purges the local JSON caches and 7-day memory caches.
    /// 3. Initiates a fresh ``loadShortcuts()`` sweep.
    func refresh() async {
        await checkPrerequisites()
        await clearShortcutsCaches()
        hasLoadedOnce = false
        await loadShortcuts()
    }

    /// Busts every cache layer between the app and the published index so a
    /// force-refresh actually reflects add/remove changes.
    ///
    /// **Rationale:**
    /// Drops the 7-day `RemoteCache` copy of `index.json` AND the local `UserDefaults` list snapshot (14-day).
    /// Without this, a removed shortcut lingers in the list until both TTLs elapse.
    private func clearShortcutsCaches() async {
        if let url = URL(string: "\(baseURL)/index.json") {
            await RemoteCache.shared.clear(url)
        }
        UserDefaults.standard.removeObject(forKey: "shortcuts_cache")
        UserDefaults.standard.removeObject(forKey: cacheTimestampKey)
    }
    
    /// Pulls the catalog index JSON over the network and caches it to disk.
    ///
    /// **Flow:**
    /// 1. Decodes ``ShortcutsIndex``.
    /// 2. Sorts descending by `date_added` (newest first).
    /// 3. Backs up the JSON dictionary via ``saveShortcutsCache()``.
    func loadShortcuts() async {
        guard !hasLoadedOnce else { return }
        
        isLoading = true
        logger.log("📦 Loading SmartShortcuts index...")
        
        do {
            guard let url = URL(string: "\(baseURL)/index.json") else {
                throw URLError(.badURL)
            }
            
            let index = try await NetworkConfig.fetchJSON(from: url, as: ShortcutsIndex.self, ttl: CacheTTL.shortcutsIndex)
            let sortedShortcuts = index.shortcuts.sorted { $0.date_added > $1.date_added }

            shortcuts = sortedShortcuts
            logger.log("✅ Loaded \(shortcuts.count) shortcuts")
            hasLoadedOnce = true

            // Cache shortcuts to disk
            saveShortcutsCache()
            
        } catch {
            logger.log("❌ Failed to load shortcuts: \(error.localizedDescription)")
        }
        
        isLoading = false
    }

    /// Hard clears all cache layers and forces a fresh catalog download.
    func forceReload() async {
        await clearShortcutsCaches()
        hasLoadedOnce = false
        await loadShortcuts()
    }
    
    /// Serializes `shortcuts` to `UserDefaults`.
    private func saveShortcutsCache() {
        if let encoded = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(encoded, forKey: "shortcuts_cache")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
            logger.log("💾 Cached \(shortcuts.count) shortcuts")
        }
    }

    /// Hydrates `shortcuts` from `UserDefaults` if the cache is under `cacheExpirySeconds` (14 days).
    private func loadShortcutsCache() {
        // Check cache timestamp - expire after 24 hours
        let cacheTimestamp = UserDefaults.standard.double(forKey: cacheTimestampKey)
        let cacheAge = Date().timeIntervalSince1970 - cacheTimestamp
        
        if cacheAge > cacheExpirySeconds {
            logger.log("⚠️ Shortcuts cache expired (\(Int(cacheAge / 3600))h old), will refresh")
            return
        }
        
        if let data = UserDefaults.standard.data(forKey: "shortcuts_cache"),
           let decoded = try? JSONDecoder().decode([ShortcutItem].self, from: data) {
            shortcuts = decoded
            hasLoadedOnce = true  // Mark as loaded so we don't fetch immediately
            logger.log("📂 Loaded \(shortcuts.count) shortcuts from cache (\(Int(cacheAge / 60))m old)")
        }
    }
    
    /// Evaluates `brew` and `python3 -m pip` availability for the UI prerequisites card.
    func checkPrerequisites() async {
        // Check Homebrew
        isBrewInstalled = BrewPathManager.shared.isInstalled
        
        // Check if any Python with pip is available in Homebrew
        do {
            let result = try await AsyncProcessRunner.shared.runWithBrewPath(command: "python3 -m pip --version 2>/dev/null")
            isPythonWithPipAvailable = result.succeeded
        } catch {
            isPythonWithPipAvailable = false
        }
        
        logger.log("Prerequisites: Brew=\(isBrewInstalled), Python/pip=\(isPythonWithPipAvailable)")
    }
        
    /// Returns true if the shortcut is present in the `~/.zshrc` tracking dictionary.
    ///
    /// - Parameter shortcutId: Target string identifier.
    func isInstalled(_ shortcutId: String) -> Bool {
        installedShortcuts[shortcutId] != nil
    }
    
    /// Resolves the user's custom function name for the given shortcut ID (if overridden during install).
    ///
    /// - Parameter shortcutId: Target string identifier.
    func getCustomName(_ shortcutId: String) -> String? {
        installedShortcuts[shortcutId]?.custom_name
    }
    
    /// Reads the active `.zshrc` tracking dictionary from disk.
    private func loadInstalledShortcuts() {
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "installed_shortcuts"),
           let decoded = try? JSONDecoder().decode([String: InstalledShortcut].self, from: data) {
            installedShortcuts = decoded
            logger.log("📂 Loaded \(installedShortcuts.count) installed shortcuts")
        }
    }
    
    /// Persists the active dictionary of installed shortcuts to `UserDefaults`.
    func saveInstalledShortcuts() {
        if let encoded = try? JSONEncoder().encode(installedShortcuts) {
            UserDefaults.standard.set(encoded, forKey: "installed_shortcuts")
        }
    }
    
    // MARK: - Shortcut Detail State
    
    @Published var detail: ShortcutDetail?
    @Published var isLoadingDetail = false
    @Published var isInstalling = false
    /// Install log on its own observable so appends re-render only the console,
    /// not the shortcuts catalog (R2). Bridge keeps `+=`/`= ""` sites working.
    let console = ConsoleOutput()
    var installationOutput: String {
        get { console.text }
        set { console.set(newValue) }
    }
    @Published var showingNameConflict = false
    /// Short, user-facing error surfaced as a banner when install/uninstall
    /// fails (P3). Name conflicts use the dedicated `showingNameConflict` UI.
    @Published var installError: String?
    /// Set when loading the shortcut detail fails, so the view shows a retry
    /// state instead of a permanent "Loading…".
    @Published var detailError: String?
    
    // MARK: - Load Detail
    
    /// Fetches the deep-dive JSON for a single shortcut (includes code snippets, dependencies, etc).
    ///
    /// - Parameter shortcutId: Target string identifier.
    func loadDetail(shortcutId: String) async {
        // Already have this shortcut's detail (cache/prior load) — don't reload.
        if let current = detail, current.id == shortcutId { return }

        detailError = nil
        isLoadingDetail = true
        logger.log("📥 Loading detail for: \(shortcutId)")

        do {
            guard let url = URL(string: "\(baseURL)/\(shortcutId).json") else {
                throw URLError(.badURL)
            }

            detail = try await NetworkConfig.fetchJSON(from: url, as: ShortcutDetail.self, ttl: CacheTTL.shortcutDetail)
            logger.log("✅ Loaded detail for \(shortcutId)")
        } catch {
            detail = nil
            detailError = "Couldn't load this shortcut. Check your connection and try again."
            logger.log("❌ Failed to load detail: \(error.localizedDescription)")
        }

        isLoadingDetail = false
    }

    /// Reset detail state when navigating away from the detail view.
    func resetDetail() {
        detail = nil
        detailError = nil
        isLoadingDetail = false
        isInstalling = false
        installationOutput = ""
        showingNameConflict = false
    }
    
    // MARK: - Install Shortcut
    
    /// Orchestrates downloading dependencies and appending the script body to `~/.zshrc`.
    ///
    /// **Flow:**
    /// 1. Yields immediately to the isolated ``ShortcutInstaller/install(_:shortcutId:customName:onOutput:)``.
    /// 2. Funnels the live log into `installationOutput`.
    /// 3. Appends success payloads to `installedShortcuts`.
    ///
    /// - Parameters:
    ///   - detail: The fully inflated JSON payload.
    ///   - shortcutId: The internal identifier.
    ///   - customName: User-overridden name string.
    func installShortcut(_ detail: ShortcutDetail, shortcutId: String, customName: String) async {
        isInstalling = true
        installationOutput = ""
        installError = nil

        let outcome = await installer.install(detail, shortcutId: shortcutId, customName: customName) { [weak self] in
            self?.installationOutput += $0
        }

        switch outcome {
        case .success(let installed):
            installedShortcuts[shortcutId] = installed
            saveInstalledShortcuts()
        case .nameConflict:
            showingNameConflict = true
        case .invalidName:
            installError = "Invalid function name. Use only letters, numbers, dashes, and underscores."
        case .dependencyFailed:
            installError = "A dependency failed to install. See the output log for details."
        case .shellConfigFailed:
            installError = "Failed to configure the shell environment."
        case .writeFailed(let message):
            installError = "Failed to write shell configuration: \(message)"
        }

        isInstalling = false
    }
    
    // MARK: - Uninstall Shortcut
    
    /// Safely purges the managed Catalyst block for this shortcut from `~/.zshrc` and cleans up tracking.
    ///
    /// - Parameter shortcutId: The identifier to purge.
    func uninstallShortcut(_ shortcutId: String) async {
        logger.log("🗑️ Uninstalling \(shortcutId)...")
        installationOutput = ""
        isInstalling = true

        let proceed = installer.uninstall(shortcutId: shortcutId) { [weak self] in
            self?.installationOutput += $0
        }

        if proceed {
            // Remove from UserDefaults
            installedShortcuts.removeValue(forKey: shortcutId)
            saveInstalledShortcuts()
            installationOutput += "✅ Uninstall complete\n"
            logger.log("✅ Shortcut uninstalled")
        }

        isInstalling = false
    }
}

