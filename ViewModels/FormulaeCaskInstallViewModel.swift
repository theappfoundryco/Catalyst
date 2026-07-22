import Foundation
import SwiftUI
import Combine

/// A view model representing the "Install Packages" screen for Homebrew formulae and casks.
///
/// Unlike `BrewFormulaeCaskViewModel` (which powers the "Installed" tabs), this VM is dedicated
/// to catalog browsing, searching Cloudflare JSON payloads, and executing new installations.
///
/// **Gotchas:**
/// - `installationOutput` uses a direct `ConsoleOutput` binding, bypassing Swift UI throttling.
///   This ensures log parsing (like checking for "it's just not linked") works perfectly without missed text.
///
/// ```swift
/// await vm.install(package: "wget", type: .formulae)
/// ```
@MainActor
final class FormulaeCaskInstallViewModel: ObservableObject {
    // Formulae State
    @Published var allFormulae: [String] = []
    @Published var installedFormulae: Set<String> = []
    
    // Casks State
    @Published var allCasks: [String] = []
    @Published var installedCasks: Set<String> = []
    
    // Search State
    @Published var searchQuery: String = ""
    @Published var formulaeSearchResults: [String] = []
    @Published var caskSearchResults: [String] = []
    @Published var isSearching = false
    @Published var hasSearched = false
    
    // Installation State
    @Published var installingPackage: String? // Name of package currently installing
    /// Install output on its own observable so a chunk re-renders only the
    /// console, not the formulae/cask catalog (R2). The bridge is immediate (not
    /// coalesced), so the link-detection `.contains(…)` reads below stay correct.
    let console = ConsoleOutput()
    var installationOutput: String {
        get { console.text }
        set { console.set(newValue) }
    }
    
    // System State
    @Published var isBrewInstalled = false
    /// Short, user-facing error surfaced as a banner when an install fails (P3).
    @Published var installError: String?

    private let brewService: BrewService
    private let logger: Logger
    private let formulaeURL = NetworkConfig.APIEndpoint.brewFormulaeURL
    private let casksURL = NetworkConfig.APIEndpoint.brewCasksURL
    
    /// Defines an installable Homebrew formula or cask candidate mapped to the core tap.
    struct PackageItem: Codable {
        let name: String
        let fetched_at: String
    }
    
    /// Initializes ``FormulaeCaskInstallViewModel`` with injected services.
    ///
    /// - Parameters:
    ///   - brewService: Controls Homebrew operations.
    ///   - logger: Reusable terminal output stream.
    init(brewService: BrewService, logger: Logger) {
        self.brewService = brewService
        self.logger = logger
    }
    
    /// Evaluates if Homebrew is present before attempting to list/install.
    /// Synchronously caches the boolean from ``BrewPathManager``.
    func checkPrerequisites() async {
        isBrewInstalled = BrewPathManager.shared.isInstalled
        logger.log("Prerequisites: Brew=\(isBrewInstalled)")
    }
    
    /// Completely resets search state and re-fetches the catalog from Cloudflare JSON endpoints.
    func reset() async {
        searchQuery = ""
        formulaeSearchResults = []
        caskSearchResults = []
        hasSearched = false
        installingPackage = nil
        installationOutput = ""
        await loadAllData()
    }
    
    // MARK: - Data Loading
    
    /// Dispatches parallel loading tasks to pull the JSON catalogs and the local installed lists.
    ///
    /// **Flow:**
    /// 1. Verifies prerequisites.
    /// 2. Executes 4 tasks inside a `TaskGroup` to fetch local arrays and network JSON simultaneously.
    func loadAllData() async {
        await checkPrerequisites()
        
        // Load in parallel
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadFormulae() }
            group.addTask { await self.loadInstalledFormulae() }
            group.addTask { await self.loadCasks() }
            group.addTask { await self.loadInstalledCasks() }
        }
    }
    
    /// Pulls the Homebrew formulae catalog from the backend API.
    ///
    /// **Gotchas:**
    /// - Bails instantly if `allFormulae` is populated to avoid redundant network hits during tab switching.
    func loadFormulae() async {
        guard allFormulae.isEmpty else { return } // Avoid reloading if already loaded
        logger.log("📥 Loading Homebrew formulae list...")
        
        guard let url = URL(string: formulaeURL) else { return }
        
        do {
            let items = try await NetworkConfig.fetchJSON(from: url, as: [PackageItem].self, ttl: CacheTTL.brewCatalog)
            allFormulae = items.map { $0.name }
            logger.log("✅ Loaded \(allFormulae.count) formulae")
        } catch {
            logger.log("❌ Failed to load formulae: \(error.localizedDescription)")
        }
    }
    
    /// Pulls the Homebrew casks catalog from the backend API.
    ///
    /// **Gotchas:**
    /// - Follows the exact same caching strategy as ``loadFormulae()``.
    func loadCasks() async {
        guard allCasks.isEmpty else { return } // Avoid reloading if already loaded
        logger.log("📥 Loading Homebrew casks list...")
        
        guard let url = URL(string: casksURL) else { return }
        
        do {
            let items = try await NetworkConfig.fetchJSON(from: url, as: [PackageItem].self, ttl: CacheTTL.brewCatalog)
            allCasks = items.map { $0.name }
            logger.log("✅ Loaded \(allCasks.count) casks")
        } catch {
            logger.log("❌ Failed to load casks: \(error.localizedDescription)")
        }
    }
    
    /// Runs `brew list --formula` to get the true current state of local formulae.
    /// Parses stdout and normalizes elements to lowercase to build the ``installedFormulae`` set.
    func loadInstalledFormulae() async {
        let brewPath = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
        let command = "\(brewPath) list --formula"
        
        do {
            let result = try await AsyncProcessRunner.shared.runWithBrewPath(command: command)
            if result.succeeded {
                installedFormulae = Set(result.stdout.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty })
            }
        } catch {
            logger.log("❌ Failed to load installed formulae: \(error.localizedDescription)")
        }
    }
    
    /// Runs `brew list --cask` to get the true current state of local casks.
    /// Mirrors ``loadInstalledFormulae()``.
    func loadInstalledCasks() async {
        let brewPath = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
        let command = "\(brewPath) list --cask"
        
        do {
            let result = try await AsyncProcessRunner.shared.runWithBrewPath(command: command)
            if result.succeeded {
                installedCasks = Set(result.stdout.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty })
            }
        } catch {
            logger.log("❌ Failed to load installed casks: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Search
    
    /// Filters both the formulae and cask caches using `searchQuery`.
    ///
    /// **Rationale:**
    /// Searches both arrays simultaneously even if the user is only on one tab. This ensures that switching tabs
    /// feels instantaneous without triggering a re-search.
    ///
    /// - Parameter type: The active tab.
    func search(type: FormulaeCaskInstallView.InstallType) {
        guard !searchQuery.isEmpty else {
            formulaeSearchResults = []
            caskSearchResults = []
            hasSearched = false
            return
        }
        
        isSearching = true
        hasSearched = true
        
        let query = searchQuery.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        logger.log("🔍 Searching for \(type == .formulae ? "formulae" : "casks") matching: \(query)")
        
        // Search both to be ready or just the active one?
        // Let's search both so switching tabs works instantly with same query
        
        Task {
            // Perform filtering off main actor if lists are huge (optional optimization, but simple filter is usually fast enough)
            let matchingFormulae = allFormulae.filter { $0.lowercased().contains(query) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            
            let matchingCasks = allCasks.filter { $0.lowercased().contains(query) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            
            await MainActor.run {
                self.formulaeSearchResults = matchingFormulae
                self.caskSearchResults = matchingCasks
                self.isSearching = false
                self.logger.log("✅ Found \(matchingFormulae.count) formulae, \(matchingCasks.count) casks")
            }
        }
    }
    
    // MARK: - Installation
    
    /// Executes a streaming `brew install` for a given package and type.
    ///
    /// **Flow:**
    /// 1. Sanitizes inputs.
    /// 2. Initiates ``AsyncProcessRunner/runWithStreaming`` to capture chunks directly to ``installationOutput``.
    /// 3. Checks standard output text for Homebrew's famous "it's just not linked" warning.
    /// 4. If found, automatically appends and runs `brew link`.
    /// 5. Refreshes the local installed lists upon completion.
    ///
    /// - Parameters:
    ///   - package: The desired target name.
    ///   - type: Formula or Cask.
    func install(package: String, type: FormulaeCaskInstallView.InstallType) async {
        installError = nil

        guard let sanitizedName = InputSanitizer.sanitizePackageName(package) else {
            logger.log("❌ Invalid package name: \(package)")
            installError = "Invalid package name: \(package)"
            return
        }

        installingPackage = package
        installationOutput = ""
        
        let typeLabel = type == .formulae ? "FORMULA" : "CASK"
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       🍺 BREW \(typeLabel) INSTALLATION", category: .terminal)
        logger.log("       Package: \(sanitizedName)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        
        logger.log("📦 Installing \(sanitizedName)...")
        
        let prefix = BrewPathManager.shared.homebrewPrefix
        let brewPath = InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)
        
        let installCommand: String
        if type == .formulae {
            installCommand = "\(brewPath) install \(InputSanitizer.singleQuote(sanitizedName))"
        } else {
            installCommand = "\(brewPath) install --cask \(InputSanitizer.singleQuote(sanitizedName))"
        }
        
        let fullCommand = "export PATH=\(InputSanitizer.singleQuote(prefix + "/bin")):\"$PATH\" && \(installCommand)"
        
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: fullCommand) { text in
                self.installationOutput += text
            }
            
            // Check for linking issue (Formulae specific usually)
            if type == .formulae && (installationOutput.contains("it's just not linked") || installationOutput.contains("just not linked")) {
                logger.log("🔗 \(sanitizedName) installed but not linked, linking now...")
                installationOutput += "\n\n🔗 Formula installed but not linked, linking now...\n"
                
                let linkCommand = "\(brewPath) link \(InputSanitizer.singleQuote(sanitizedName))"
                let linkFullCommand = "export PATH=\(InputSanitizer.singleQuote(prefix + "/bin")):\"$PATH\" && \(linkCommand)"
                
                let linkResult = try await AsyncProcessRunner.shared.run(command: linkFullCommand)
                installationOutput += linkResult.combinedOutput
                
                if linkResult.succeeded {
                    logger.log("✅ Successfully linked \(package)")
                    installationOutput += "\n\n✅ Formula linked successfully!"
                } else {
                    logger.log("⚠️ Linking failed")
                    installationOutput += "\n\n⚠️ Linking failed. You may need to run: brew link \(sanitizedName)"
                }
                
                await loadInstalledFormulae()
            } else if exitCode == 0 {
                logger.log("✅ Successfully installed \(package)")
                installationOutput += "\n\n✅ Installation completed successfully!"
                
                // Reload list
                if type == .formulae {
                    await loadInstalledFormulae()
                } else {
                    await loadInstalledCasks()
                }
            } else {
                logger.log("❌ Failed to install \(package)")
                installationOutput += "\n\n❌ Installation failed with exit code \(exitCode)"
                installError = "Failed to install \(package) (exit code \(exitCode)). See the output log for details."
            }
        } catch {
            logger.log("❌ Installation error: \(error.localizedDescription)")
            installationOutput += "\n\n❌ Error: \(error.localizedDescription)"
            installError = "Error installing \(package): \(error.localizedDescription)"
        }

        installingPackage = nil
    }
    
    /// Clears the streaming console output view string.
    func clearOutput() {
        installationOutput = ""
    }
}
