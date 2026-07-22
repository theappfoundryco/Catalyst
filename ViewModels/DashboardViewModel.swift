import Foundation
import SwiftUI
import Combine

/// The result of a tool-presence detection, modeled as state rather than a
/// display string. Use this for logic (e.g. `brewState == .installed`); the
/// `*Status` strings remain for display only.
enum DetectionState {
    case installed
    case notInstalled
    case unknown
}

/// The main view model driving the Catalyst Dashboard, coordinating system detection
/// and high-level installation actions.
///
/// `DashboardViewModel` manages the asynchronous detection sequence that populates
/// the dashboard tiles (Brew, Python, pip). It delegates lower-level shell tasks to
/// `DetectionService`, `PythonManager`, and `BrewMaintenanceManager`.
///
/// **Caveats:**
/// - The `runDetection` method fires concurrently for initial checks, but defers
///   heavy I/O operations (`detectPipUpgrades` and `loadBrewStats`) until the end
///   to prevent blocking the initial UI render.
///
/// ```swift
/// await vm.runDetection()
/// if vm.brewState == .installed { ... }
/// ```
@MainActor
final class DashboardViewModel: ObservableObject {
    /// The user-facing status string for Command Line Tools.
    @Published var commandLineToolsStatus = "Click Refresh to detect"
    /// The UI color representing the Command Line Tools state.
    @Published var commandLineToolsStatusColor: Color = .secondary
    // R6: logic-only state (read by AppViewModel, never by a View). Plain `var`
    // so setting it doesn't fire objectWillChange / re-render the Dashboard; the
    // sibling `*Status` string mutation already drives the visible update.
    var commandLineToolsState: DetectionState = .unknown
    
    /// The user-facing status string for Homebrew.
    @Published var brewStatus = "Click Refresh to detect"
    /// The UI color representing the Homebrew state.
    @Published var brewStatusColor: Color = .secondary
    /// Logic-only enum state for Homebrew presence.
    var brewState: DetectionState = .unknown
    
    /// The user-facing status string for the system's default Python version.
    @Published var systemPythonVersion = "Click Refresh to detect"
    /// A potential user-facing error encountered when querying the system Python.
    @Published var systemPythonError: String? = nil // Track specific error
    
    /// The raw list of discovered Python installations.
    @Published var installedPythons: [PythonInstallation] = [] {
        didSet {
            // Sort once when the set changes, not on every render of the card (R3).
            sortedInstalledPythons = installedPythons.sorted {
                VersionComparator.compare($0.version, $1.version) < 0
            }
        }
    }
    /// `installedPythons` ordered by version — read by the dashboard card so it
    /// doesn't `.sorted{}` inside `body`.
    @Published private(set) var sortedInstalledPythons: [PythonInstallation] = []
    
    /// The user-facing status string for pip.
    @Published var pipVersion = "Click Refresh to detect"
    /// The UI color representing the pip state.
    @Published var pipStatusColor: Color = .secondary
    
    /// Indicates whether a detection scan is currently in progress.
    @Published var isDetecting = false
    /// True after the very first successful detection pass.
    @Published var hasLoadedOnce = false
    
    /// List of available Python versions fetched from the Homebrew catalog.
    @Published var availablePythonVersions: [AvailableVersion] = []
    /// Indicates whether the available versions list is being downloaded.
    @Published var isLoadingAvailableVersions = false
    /// Tracks which version the user selected in the UI to install.
    @Published var selectedVersionToInstall: String? = nil
    
    /// Indicates if a Python installation is actively running.
    @Published var isInstallingPython = false
    /// Indicates if a Homebrew installation is actively running.
    @Published var isInstallingBrew = false
    
    /// Brew install/maintenance output on its own observable so a streamed chunk
    /// re-renders only the console card, not the whole dashboard (R2). The bridge
    /// is immediate, so the post-stream `brew.parseUnlinkedKegs(from:)` read in
    /// `doctorBrew()` stays correct.
    let console = ConsoleOutput()
    var brewInstallOutput: String {
        get { console.text }
        set { console.set(newValue) }
    }
    
    /// The list of unlinked Homebrew kegs discovered during a `doctorBrew` run.
    @Published var brewUnlinkedKegs: [String] = []
    /// Indicates if the CLT installer trigger is active.
    @Published var isInstallingCommandLineTools = false
    /// A Catalyst-recommended version of Python for users who are unsure.
    @Published var recommendedVersion: String? = nil
    /// A set of python paths marked for deletion in the UI.
    @Published var selectedVersionsToUninstall: Set<String> = []
    
    /// Indicates if Homebrew is currently being uninstalled.
    @Published var isUninstallingBrew = false
    /// Indicates if Python(s) are currently being uninstalled.
    @Published var isUninstallingPython = false
    
    /// The version string of the Python installation currently upgrading its pip.
    @Published var upgradingPipFor: String? = nil
    /// The version string of the Python installation currently repairing its pip.
    @Published var repairingPipFor: String? = nil
    /// Per-interpreter pip upgrade target, keyed by interpreter path. A value is
    /// present only when that interpreter's own pip reports pip as outdated (via
    /// `pip list --outdated`), so it honors Requires-Python and is correct
    /// per-interpreter — unlike the old single global PyPI `info.version`.
    @Published var pipUpgradeTargets: [String: String] = [:]
    
    /// Indicates if a `brew update` is running.
    @Published var isBrewUpdating = false
    /// Indicates if a `brew upgrade` is running.
    @Published var isBrewUpgrading = false
    /// Indicates if a `brew cleanup` is running.
    @Published var isBrewCleaning = false
    /// Indicates if a `brew doctor` is running.
    @Published var isRunningBrewDoctor = false
    /// The parsed file system metrics for the Homebrew cellar and cache.
    @Published var brewSystemStats: BrewSystemStats?
    /// Indicates if a `brew link` operation is running.
    @Published var isBrewLinking = false
    /// Short, user-facing error surfaced as a banner when a Homebrew/Python
    /// install fails (P3) — the install output otherwise only reaches the Logs
    /// screen, so failures would be invisible on the dashboard.
    @Published var installError: String?

    /// `true` when any action (install, uninstall, upgrade, repair, detect) is in progress.
    var isBusy: Bool {
        isDetecting || isInstallingPython || isUninstallingPython ||
        isInstallingBrew || isUninstallingBrew ||
        isInstallingCommandLineTools || isLoadingAvailableVersions ||
        upgradingPipFor != nil || repairingPipFor != nil
    }
    
    private let brewService: BrewService
    private let pythonService: PythonService
    private let privileges: PrivilegesService
    private let logger: Logger
    /// Tool-presence detection logic, extracted out of this VM (R1 step 1).
    private let detection: DetectionService
    /// Python lifecycle logic (install/uninstall/link/pip/versions), extracted
    /// out of this VM (R1 step 2).
    private let python: PythonManager
    /// Homebrew install/uninstall + maintenance logic, extracted out of this VM
    /// (R1 step 3).
    private let brew: BrewMaintenanceManager

    /// Owns the "default Python" shell block (surgically edits only `~/.zshrc_catalyst`).
    /// Driven by the Default Python card on the dashboard.
    let pythonDefaultManager = PythonDefaultManager()

    /// Callback triggered after install/uninstall completes to refresh all ViewModels.
    /// The label (e.g. "Installing Homebrew...") is shown in the ActionOverlayView.
    var onGlobalRefresh: ((_ actionLabel: String?) async -> Void)?
    
    var installedVersionsList: String {
        let majorMinor = installedPythons.map { version in
            let components = version.version.split(separator: ".")
            return components.prefix(2).joined(separator: ".")
        }
        // Sort versions in ascending order using VersionComparator
        let sorted = majorMinor.sorted { VersionComparator.compare($0, $1) < 0 }
        return sorted.joined(separator: ", ")
    }
    
    /// Initializes the dashboard controller and instantiates its sub-managers.
    ///
    /// - Parameters:
    ///   - brewService: Dependency for raw Homebrew shell execution.
    ///   - pythonService: Dependency for python-build and pip parsing.
    ///   - privileges: Dependency for escalating AppleScript execution.
    ///   - logger: Reusable terminal output stream.
    init(brewService: BrewService, pythonService: PythonService, privileges: PrivilegesService, logger: Logger) {
        self.brewService = brewService
        self.pythonService = pythonService
        self.privileges = privileges
        self.logger = logger
        self.detection = DetectionService(
            brewService: brewService,
            pythonService: pythonService,
            logger: logger
        )
        self.python = PythonManager(
            pythonService: pythonService,
            privileges: privileges,
            logger: logger
        )
        self.brew = BrewMaintenanceManager(
            privileges: privileges,
            logger: logger
        )
    }
    
    /// Executes the primary detection sequence to locate Homebrew, Pythons, and pip.
    ///
    /// **Flow:**
    /// 1. Resets error states.
    /// 2. Fires off CLT, Brew, System Python, and Installed Python checks in a parallel batch.
    /// 3. Fires off pip and available remote Python version checks in a second parallel batch.
    /// 4. Flips ``isDetecting`` to `false`, unblocking the UI.
    /// 5. Detaches asynchronous background probes for pip upgrades and brew celler size (heavy I/O).
    ///
    /// - Parameter force: If true, invalidates the Python cache forcing a full disk scan.
    func runDetection(force: Bool = false) async {
        guard !isDetecting else { return }
        
        if force {
            pythonService.invalidateCache()
        }
        
        isDetecting = true
        hasLoadedOnce = true
        logger.log("🔍 Starting detection...")
        
        systemPythonError = nil // Reset error
        
        async let toolsLaunch: () = detectCommandLineTools()
        async let brewLaunch: () = detectBrew()
        async let pyLaunch: () = detectSystemPython()
        async let instPyLaunch: () = detectInstalledPythons()
        
        _ = await (toolsLaunch, brewLaunch, pyLaunch, instPyLaunch)
        logger.debugLog("🐛 det: batch1 COMPLETE (tools/brew/sysPy/instPy)")

        async let pipLaunch: () = detectPip()
        async let availPyLaunch: () = loadAvailablePythonVersions()

        _ = await (pipLaunch, availPyLaunch)
        logger.debugLog("🐛 det: batch2 COMPLETE (pip/availVersions)")

        isDetecting = false
        logger.log("✅ Detection complete")

        // pip-upgrade availability is a non-critical hint, and the per-interpreter
        // `pip list --outdated` probes are network-heavy (a full env scan each).
        // Run them AFTER detection is marked complete so they never block launch
        // or a refresh — `pipUpgradeTargets` is @Published, so rows fill in the
        // "upgrade available" hint when the background probe finishes.
        Task { await self.detectPipUpgrades() }

        // Brew stats run `du -sh` on the Homebrew Cellar/Caches — slow recursive
        // disk I/O that on a large Cellar can take many seconds and previously hung
        // the launch screen (launch waits on runDetection). Load them AFTER
        // detection completes; `brewSystemStats` is @Published, so the stats tile
        // fills in when the background walk finishes.
        Task { await self.loadBrewStats() }
    }
    
    /// Detects if macOS Command Line Tools are active via ``DetectionService/detectCommandLineTools()``.
    private func detectCommandLineTools() async {
        logger.debugLog("🐛 det: CLT start")
        applyCommandLineTools(await detection.detectCommandLineTools())
        logger.debugLog("🐛 det: CLT end")
    }

    /// Maps the raw detection enum to user-facing strings and colors for the Command Line Tools tile.
    private func applyCommandLineTools(_ state: DetectionState) {
        commandLineToolsState = state
        switch state {
        case .installed:
            commandLineToolsStatus = "Installed"
            commandLineToolsStatusColor = .green
        case .notInstalled, .unknown:
            commandLineToolsStatus = "Not Installed"
            commandLineToolsStatusColor = .red
        }
    }

    /// Scans the host system for a globally accessible Python via ``DetectionService/detectSystemPython()``.
    private func detectSystemPython() async {
        logger.debugLog("🐛 det: systemPython start")
        let result = await detection.detectSystemPython()
        systemPythonVersion = result.version
        systemPythonError = result.error
        logger.debugLog("🐛 det: systemPython end (\(result.version))")
    }

    /// Reads the `.pyenv/versions` equivalent structure to enumerate isolated Pythons via ``DetectionService/detectInstalledPythons()``.
    private func detectInstalledPythons() async {
        logger.debugLog("🐛 det: installedPythons start")
        installedPythons = await detection.detectInstalledPythons()
        logger.debugLog("🐛 det: installedPythons got \(installedPythons.count); refreshing default-python card")
        // Keep the "default Python" card in sync with what's actually installed.
        await pythonDefaultManager.refresh()
        logger.debugLog("🐛 det: installedPythons end")
    }

    /// Checks for the `brew` binary via ``DetectionService/detectBrew()``.
    private func detectBrew() async {
        logger.debugLog("🐛 det: brew start")
        applyBrew(await detection.detectBrew())
        logger.debugLog("🐛 det: brew end")
    }

    /// Maps the raw detection enum to user-facing strings and colors for the Homebrew tile.
    private func applyBrew(_ state: DetectionState) {
        brewState = state
        switch state {
        case .installed:
            brewStatus = "Installed"
            brewStatusColor = .green
        case .notInstalled, .unknown:
            brewStatus = "Not Installed"
            brewStatusColor = .red
        }
    }

    /// Scans the first discovered Python environment for its pip binary and version.
    private func detectPip() async {
        logger.debugLog("🐛 det: pip start (first=\(installedPythons.first?.version ?? "none"))")
        defer { logger.debugLog("🐛 det: pip end") }
        switch await detection.detectPip(for: installedPythons.first) {
        case .version(let v):
            pipVersion = v
            pipStatusColor = .green
        case .available:
            pipVersion = "Available"
            pipStatusColor = .green
        case .notAvailable:
            pipVersion = "Not Available"
            pipStatusColor = .red
        case .noPython:
            pipVersion = "Not Available"
            pipStatusColor = .secondary
        }
    }
    
    /// Triggers the pip repair script (`ensurepip`) for a specific Python installation.
    ///
    /// **Flow:**
    /// 1. Sets ``repairingPipFor`` to lock the UI button.
    /// 2. Defers to ``PythonManager/repairPip(for:)``.
    /// 3. Invalidates caches and re-triggers detection to sync the UI.
    ///
    /// - Parameter installation: The Python target to repair.
    func repairPip(for installation: PythonInstallation) async {
        repairingPipFor = installation.version

        _ = await python.repairPip(for: installation)

        // Invalidate cache to ensure fresh pip data
        pythonService.invalidateCache()
        await detectInstalledPythons()
        await detectPipUpgrades()

        repairingPipFor = nil
    }

    /// Triggers `pip install --upgrade pip` for a specific Python installation.
    ///
    /// **Flow:**
    /// Matches the UI locking and invalidation flow of ``repairPip(for:)``.
    ///
    /// - Parameter installation: The Python target to upgrade.
    func upgradePip(for installation: PythonInstallation) async {
        upgradingPipFor = installation.version

        await python.upgradePip(for: installation)

        // Invalidate cache to ensure fresh pip version data
        pythonService.invalidateCache()
        await detectInstalledPythons()
        await detectPipUpgrades()
        upgradingPipFor = nil
    }
    
    /// Synchronous helper to determine if a specific python has a known pip upgrade pending.
    ///
    /// - Parameter python: The installation to check.
    /// - Returns: `true` if this specific interpreter's isolated pip is outdated.
    func isPipUpgradeAvailable(for python: PythonInstallation) -> Bool {
        // Present only when this interpreter's own pip reported pip as outdated.
        pipUpgradeTargets[python.path.path] != nil
    }
    
    /// Checks if the installed Homebrew Python major/minor version matches the system-level python fallback.
    ///
    /// **Rationale:**
    /// Used to surface warnings about conflicting `PATH` resolutions where `python3` resolves to a system framework
    /// rather than the Homebrew Cellar.
    ///
    /// - Parameter python: The Homebrew installation to check.
    /// - Returns: `true` if the versions structurally overlap.
    func isSystemPythonConflict(for python: PythonInstallation) -> Bool {
        // Ensure system python version is valid
        guard systemPythonVersion != "Unknown" && 
              systemPythonVersion != "Not Available" && 
              systemPythonVersion != "Click Refresh to detect" &&
              systemPythonVersion != "Checking..." else {
            return false
        }
        
        let systemComponents = systemPythonVersion.split(separator: ".")
        let installedComponents = python.version.split(separator: ".")
        
        guard systemComponents.count >= 2, installedComponents.count >= 2 else {
            return false
        }
        
        let systemMajorMinor = systemComponents.prefix(2).joined(separator: ".")
        let installedMajorMinor = installedComponents.prefix(2).joined(separator: ".")
        
        return systemMajorMinor == installedMajorMinor
    }
    
    /// Populates ``pipUpgradeTargets`` by concurrently asking each installed interpreter's own pip if it is outdated.
    ///
    /// **Gotchas:**
    /// - Replaces the old single global PyPI lookup because global lookups ignore the `Requires-Python` constraints
    ///   (e.g., Python 3.7 cannot support pip 24.x, and a global lookup would falsely flag it for upgrade).
    func detectPipUpgrades() async {
        let pythons = installedPythons
        var targets: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for py in pythons where py.pipAvailable {
                group.addTask { [detection] in
                    (py.path.path, await detection.detectPipUpgrade(for: py))
                }
            }
            for await (path, target) in group {
                if let target { targets[path] = target }
            }
        }
        pipUpgradeTargets = targets
    }

    /// Contacts Catalyst APIs to retrieve the master list of compatible Python formulas for this architecture.
    private func loadAvailablePythonVersions() async {
        logger.debugLog("🐛 det: availableVersions start")
        isLoadingAvailableVersions = true
        let result = await python.fetchAvailableVersions(installed: installedPythons)
        availablePythonVersions = result.versions
        recommendedVersion = result.recommended
        isLoadingAvailableVersions = false
        logger.debugLog("🐛 det: availableVersions end (\(result.versions.count))")
    }
    
    /// Installs Homebrew globally, invoking AppleScript privileges if required.
    ///
    /// **Flow:**
    /// 1. Toggles ``isInstallingBrew``.
    /// 2. Awaits ``BrewMaintenanceManager/installHomebrew()``.
    /// 3. Upon success, triggers the global cross-ViewModel refresh hook.
    func installHomebrew() async {
        guard !isInstallingBrew else { return }

        isInstallingBrew = true
        brewInstallOutput = ""
        brewUnlinkedKegs = []
        installError = nil

        let success = await brew.installHomebrew()

        isInstallingBrew = false
        if success {
            await onGlobalRefresh?("Refreshing after Homebrew install...")
        } else {
            installError = "Homebrew installation failed or was cancelled. See the Logs screen for details."
        }
    }

    /// Triggers the macOS Command Line Tools installation dialog via `xcode-select --install`.
    /// 
    /// **Gotchas:**
    /// - This does not install CLT automatically; it only summons the GUI dialog. The macOS system handles
    ///   the rest asynchronously, and Catalyst must wait for the user to click through the system window.
    func installCommandLineTools() async {
        guard !isInstallingCommandLineTools else { return }
        
        isInstallingCommandLineTools = true
        logger.log("🛠️ Requesting Command Line Tools installation...")
        
        do {
            // xcode-select --install brings up a GUI dialog. 
            // We can't force it purely via CLI without user interaction in the GUI.
            // But we can trigger it.
            let result = try await AsyncProcessRunner.shared.run(command: "xcode-select --install")
            
            if result.succeeded {
                logger.log("✅ Install dialog requested. Please follow the prompts on your screen.")
            } else {
                // If it fails, it might be already installed or another error
                if result.combinedOutput.contains("already installed") {
                    logger.log("✅ Command Line Tools are already installed.")
                    await runDetection()
                } else {
                    logger.log("❌ Failed to request install: \(result.combinedOutput)")
                }
            }
        } catch {
            logger.log("❌ Error requesting install: \(error.localizedDescription)")
        }
        
        isInstallingCommandLineTools = false
    }

    /// Installs the specific Python version saved in `selectedVersionToInstall` via Homebrew.
    ///
    /// **Flow:**
    /// Similar to Homebrew installation; hooks directly into ``PythonManager/install(version:)``.
    func installSelectedPython() async {
        guard let version = selectedVersionToInstall, !isInstallingPython else { return }

        isInstallingPython = true
        installError = nil

        if await python.install(version: version) {
            // Wait for filesystem to sync
            try? await Task.sleep(for: .seconds(2))
            selectedVersionToInstall = nil
        } else {
            installError = "Python \(version) installation failed. See the Logs screen for details."
        }

        isInstallingPython = false
        await onGlobalRefresh?("Refreshing after Python install...")
    }

    /// Uninstalls Homebrew globally, invoking AppleScript privileges to wipe the `/opt/homebrew` structure.
    func uninstallHomebrew() async {
        guard !isUninstallingBrew else { return }
        
        isUninstallingBrew = true

        await brew.uninstallHomebrew()

        isUninstallingBrew = false
        await onGlobalRefresh?("Refreshing after Homebrew uninstall...")
    }
    
    /// Uninstalls all Pythons marked in `selectedVersionsToUninstall` sequentially.
    func uninstallSelectedPythons() async {
        guard !isUninstallingPython, !selectedVersionsToUninstall.isEmpty else { return }
        
        isUninstallingPython = true

        await python.uninstall(versions: selectedVersionsToUninstall)
        selectedVersionsToUninstall.removeAll()

        // Invalidate cache before full refresh
        pythonService.invalidateCache()
        
        isUninstallingPython = false
        await onGlobalRefresh?("Refreshing after Python uninstall...")
    }
    // MARK: - Homebrew Maintenance
    
    /// Triggers a cellar space calculation `du -sh` and updates the UI stats.
    ///
    /// **Rationale:**
    /// Takes significant time on large installations; runs entirely off the main thread.
    func loadBrewStats() async {
        brewSystemStats = await brew.loadStats()
    }

    /// Executes `brew update` to refresh local Homebrew taps.
    func updateBrew() async {
        isBrewUpdating = true
        brewInstallOutput = ""
        await brew.update { self.brewInstallOutput += $0 }
        isBrewUpdating = false
        await loadBrewStats()
    }

    /// Executes `brew upgrade` to update all outdated formulae and casks simultaneously.
    func upgradeAllBrew() async {
        isBrewUpgrading = true
        brewInstallOutput = ""
        await brew.upgradeAll { self.brewInstallOutput += $0 }
        isBrewUpgrading = false
        await loadBrewStats()
    }

    /// Executes `brew cleanup` to reclaim SSD space from stale lock files and old downloads.
    func cleanupBrew() async {
        isBrewCleaning = true
        brewInstallOutput = ""
        await brew.cleanup { self.brewInstallOutput += $0 }
        isBrewCleaning = false
        await loadBrewStats()
    }

    /// Executes `brew doctor` and captures diagnostic warnings, looking specifically for unlinked kegs.
    ///
    /// **Flow:**
    /// 1. Runs the command and streams to ``brewInstallOutput``.
    /// 2. Evaluates the string against ``BrewMaintenanceManager/parseUnlinkedKegs(from:)``.
    func doctorBrew() async {
        isRunningBrewDoctor = true
        brewInstallOutput = ""
        brewUnlinkedKegs = [] // Reset previous detections
        await brew.doctor { self.brewInstallOutput += $0 }
        // Parse results for unlinked kegs
        brewUnlinkedKegs = brew.parseUnlinkedKegs(from: brewInstallOutput)
        isRunningBrewDoctor = false
    }

    /// Re-links any detached kegs discovered by a prior ``doctorBrew()`` scan.
    func linkBrewKegs() async {
        guard !brewUnlinkedKegs.isEmpty else { return }

        isBrewLinking = true
        await brew.link(kegs: brewUnlinkedKegs) { self.brewInstallOutput += $0 }
        isBrewLinking = false

        // Re-run doctor to verify fixes
        await doctorBrew()
    }

    /// Flushes the live console view string.
    func clearBrewMaintenanceOutput() {
        brewInstallOutput = ""
    }
}
