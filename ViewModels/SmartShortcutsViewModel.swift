import Foundation
import SwiftUI
import Combine

@MainActor
final class SmartShortcutsViewModel: ObservableObject {
    // Derived lists recompute on input change, not per render (R3).
    @Published var shortcuts: [ShortcutItem] = [] { didSet { recomputeDerived() } }
    @Published var installedShortcuts: [String: InstalledShortcut] = [:] // id -> details
    @Published var isLoading = false
    @Published var searchQuery = "" { didSet { recomputeFiltered() } }
    @Published var selectedCategory: String? = nil { didSet { recomputeFiltered() } }

    @Published private(set) var filteredShortcuts: [ShortcutItem] = []
    @Published private(set) var categories: [String] = []
    @Published var isBrewInstalled = false
    @Published var isPythonWithPipAvailable = false
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
    
    func loadData() async {
        guard !hasLoadedOnce else { return }
        
        loadInstalledShortcuts()
        loadShortcutsCache()
        await checkPrerequisites()
        await loadShortcuts()
    }
    
    private func recomputeDerived() {
        categories = Array(Set(shortcuts.map { $0.category })).sorted()
        recomputeFiltered()
    }

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

    func refresh() async {
        await checkPrerequisites()
        await clearShortcutsCaches()
        hasLoadedOnce = false
        await loadShortcuts()
    }

    /// Busts every cache layer between the app and the published index so a
    /// force-refresh actually reflects add/remove changes: the 7-day RemoteCache
    /// copy of index.json AND the local UserDefaults list snapshot (14-day). Without
    /// this, a removed shortcut lingers in the list until both TTLs elapse.
    private func clearShortcutsCaches() async {
        if let url = URL(string: "\(baseURL)/index.json") {
            await RemoteCache.shared.clear(url)
        }
        UserDefaults.standard.removeObject(forKey: "shortcuts_cache")
        UserDefaults.standard.removeObject(forKey: cacheTimestampKey)
    }
    
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

    func forceReload() async {
        await clearShortcutsCaches()
        hasLoadedOnce = false
        await loadShortcuts()
    }
    
    private func saveShortcutsCache() {
        if let encoded = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(encoded, forKey: "shortcuts_cache")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimestampKey)
            logger.log("💾 Cached \(shortcuts.count) shortcuts")
        }
    }

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
        
    func isInstalled(_ shortcutId: String) -> Bool {
        installedShortcuts[shortcutId] != nil
    }
    
    func getCustomName(_ shortcutId: String) -> String? {
        installedShortcuts[shortcutId]?.custom_name
    }
    
    private func loadInstalledShortcuts() {
        // Load from UserDefaults
        if let data = UserDefaults.standard.data(forKey: "installed_shortcuts"),
           let decoded = try? JSONDecoder().decode([String: InstalledShortcut].self, from: data) {
            installedShortcuts = decoded
            logger.log("📂 Loaded \(installedShortcuts.count) installed shortcuts")
        }
    }
    
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

    /// Reset detail state when navigating away
    func resetDetail() {
        detail = nil
        detailError = nil
        isLoadingDetail = false
        isInstalling = false
        installationOutput = ""
        showingNameConflict = false
    }
    
    // MARK: - Install Shortcut
    
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

