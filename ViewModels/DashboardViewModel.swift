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

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var commandLineToolsStatus = "Click Refresh to detect"
    @Published var commandLineToolsStatusColor: Color = .secondary
    // R6: logic-only state (read by AppViewModel, never by a View). Plain `var`
    // so setting it doesn't fire objectWillChange / re-render the Dashboard; the
    // sibling `*Status` string mutation already drives the visible update.
    var commandLineToolsState: DetectionState = .unknown
    @Published var brewStatus = "Click Refresh to detect"
    @Published var brewStatusColor: Color = .secondary
    var brewState: DetectionState = .unknown
    @Published var systemPythonVersion = "Click Refresh to detect"
    @Published var systemPythonError: String? = nil // Track specific error
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
    @Published var pipVersion = "Click Refresh to detect"
    @Published var pipStatusColor: Color = .secondary
    @Published var isDetecting = false
    @Published var hasLoadedOnce = false
    @Published var availablePythonVersions: [AvailableVersion] = []
    @Published var isLoadingAvailableVersions = false
    @Published var selectedVersionToInstall: String? = nil
    @Published var isInstallingPython = false
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
    @Published var brewUnlinkedKegs: [String] = []
    @Published var isInstallingCommandLineTools = false
    @Published var recommendedVersion: String? = nil
    @Published var selectedVersionsToUninstall: Set<String> = []
    @Published var isUninstallingBrew = false
    @Published var isUninstallingPython = false
    @Published var upgradingPipFor: String? = nil
    @Published var repairingPipFor: String? = nil
    /// Per-interpreter pip upgrade target, keyed by interpreter path. A value is
    /// present only when that interpreter's own pip reports pip as outdated (via
    /// `pip list --outdated`), so it honors Requires-Python and is correct
    /// per-interpreter — unlike the old single global PyPI `info.version`.
    @Published var pipUpgradeTargets: [String: String] = [:]
    @Published var isBrewUpdating = false
    @Published var isBrewUpgrading = false
    @Published var isBrewCleaning = false
    @Published var isRunningBrewDoctor = false
    @Published var brewSystemStats: BrewSystemStats?
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
    
    private func detectCommandLineTools() async {
        logger.debugLog("🐛 det: CLT start")
        applyCommandLineTools(await detection.detectCommandLineTools())
        logger.debugLog("🐛 det: CLT end")
    }

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

    private func detectSystemPython() async {
        logger.debugLog("🐛 det: systemPython start")
        let result = await detection.detectSystemPython()
        systemPythonVersion = result.version
        systemPythonError = result.error
        logger.debugLog("🐛 det: systemPython end (\(result.version))")
    }

    private func detectInstalledPythons() async {
        logger.debugLog("🐛 det: installedPythons start")
        installedPythons = await detection.detectInstalledPythons()
        logger.debugLog("🐛 det: installedPythons got \(installedPythons.count); refreshing default-python card")
        // Keep the "default Python" card in sync with what's actually installed.
        await pythonDefaultManager.refresh()
        logger.debugLog("🐛 det: installedPythons end")
    }

    private func detectBrew() async {
        logger.debugLog("🐛 det: brew start")
        applyBrew(await detection.detectBrew())
        logger.debugLog("🐛 det: brew end")
    }

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
    
    /// Repair pip for a specific Python installation
    func repairPip(for installation: PythonInstallation) async {
        repairingPipFor = installation.version

        _ = await python.repairPip(for: installation)

        // Invalidate cache to ensure fresh pip data
        pythonService.invalidateCache()
        await detectInstalledPythons()
        await detectPipUpgrades()

        repairingPipFor = nil
    }

    /// Upgrade pip for a specific Python installation
    func upgradePip(for installation: PythonInstallation) async {
        upgradingPipFor = installation.version

        await python.upgradePip(for: installation)

        // Invalidate cache to ensure fresh pip version data
        pythonService.invalidateCache()
        await detectInstalledPythons()
        await detectPipUpgrades()
        upgradingPipFor = nil
    }
    
    func isPipUpgradeAvailable(for python: PythonInstallation) -> Bool {
        // Present only when this interpreter's own pip reported pip as outdated.
        pipUpgradeTargets[python.path.path] != nil
    }
    
    /// Check if the installed Python version matches the system Python version (major.minor)
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
    
    /// Populate `pipUpgradeTargets` by asking each installed interpreter's own
    /// pip what it can upgrade *pip* to (`pip list --outdated`). Interpreters are
    /// probed concurrently. Replaces the old single global PyPI `info.version`
    /// lookup, which ignored Requires-Python and applied one "latest" to every
    /// interpreter (§7/§46).
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

    private func loadAvailablePythonVersions() async {
        logger.debugLog("🐛 det: availableVersions start")
        isLoadingAvailableVersions = true
        let result = await python.fetchAvailableVersions(installed: installedPythons)
        availablePythonVersions = result.versions
        recommendedVersion = result.recommended
        isLoadingAvailableVersions = false
        logger.debugLog("🐛 det: availableVersions end (\(result.versions.count))")
    }
    

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

    func uninstallHomebrew() async {
        guard !isUninstallingBrew else { return }
        
        isUninstallingBrew = true

        await brew.uninstallHomebrew()

        isUninstallingBrew = false
        await onGlobalRefresh?("Refreshing after Homebrew uninstall...")
    }
    
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
    
    func loadBrewStats() async {
        brewSystemStats = await brew.loadStats()
    }

    func updateBrew() async {
        isBrewUpdating = true
        brewInstallOutput = ""
        await brew.update { self.brewInstallOutput += $0 }
        isBrewUpdating = false
        await loadBrewStats()
    }

    func upgradeAllBrew() async {
        isBrewUpgrading = true
        brewInstallOutput = ""
        await brew.upgradeAll { self.brewInstallOutput += $0 }
        isBrewUpgrading = false
        await loadBrewStats()
    }

    func cleanupBrew() async {
        isBrewCleaning = true
        brewInstallOutput = ""
        await brew.cleanup { self.brewInstallOutput += $0 }
        isBrewCleaning = false
        await loadBrewStats()
    }

    func doctorBrew() async {
        isRunningBrewDoctor = true
        brewInstallOutput = ""
        brewUnlinkedKegs = [] // Reset previous detections
        await brew.doctor { self.brewInstallOutput += $0 }
        // Parse results for unlinked kegs
        brewUnlinkedKegs = brew.parseUnlinkedKegs(from: brewInstallOutput)
        isRunningBrewDoctor = false
    }

    func linkBrewKegs() async {
        guard !brewUnlinkedKegs.isEmpty else { return }

        isBrewLinking = true
        await brew.link(kegs: brewUnlinkedKegs) { self.brewInstallOutput += $0 }
        isBrewLinking = false

        // Re-run doctor to verify fixes
        await doctorBrew()
    }

    func clearBrewMaintenanceOutput() {
        brewInstallOutput = ""
    }
}
