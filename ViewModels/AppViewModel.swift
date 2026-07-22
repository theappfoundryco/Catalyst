import Foundation
import Combine
import SwiftUI

/// The central orchestrator view model representing the entire app's navigation and global state.
///
/// `AppViewModel` holds the instances of all other view models and services, acting as the primary
/// dependency injection container for `ContentView`. It also manages the global navigation (`currentScreen`),
/// the initial startup detection sequence, and coordinates full app refreshes (e.g., after an installation).
///
/// ```swift
/// @StateObject var appViewModel = AppViewModel()
/// // ...
/// await appViewModel.startupChecks()
/// ```
@MainActor
final class AppViewModel: ObservableObject {
    /// Represents the currently active screen in the main navigation sidebar.
    enum Screen {
        case dashboard
        case projects
        case requirements
        case installedPip
        case installedBrew
        case pipPackages
        case brewPackages
        case updates       
        case brewUpdates
        case popular
        case logs
        case shortcuts
        case aliases
        case drCatalyst
        case terminalTimeTravel
        case ssdHealth
        case cruftSweeper
        case networkDiagnostics
        case loginItems
        case batteryHealth
        case sshKeys
        case pathEditor
        case gitGraph
        case snapshot
        case about

        /// Display title for analytics (`feature_opened`).
        var telemetryName: String {
            switch self {
            case .dashboard:          return "Dashboard"
            case .projects:           return "Virtual Environments"
            case .requirements:       return "requirements.txt Installer"
            case .installedPip:       return "pip Packages"
            case .installedBrew:      return "Brew Packages"
            case .pipPackages:        return "Install pip"
            case .brewPackages:       return "Install Brew"
            case .updates:            return "pip Updates"
            case .brewUpdates:        return "Brew Updates"
            case .popular:            return "Popular Packages"
            case .logs:               return "Logs"
            case .shortcuts:          return "SmartShortcuts"
            case .aliases:            return "Aliases"
            case .drCatalyst:         return "Dr. Catalyst"
            case .terminalTimeTravel: return "Terminal Time Travel"
            case .ssdHealth:          return "SSD Health"
            case .cruftSweeper:       return "Cruft Sweeper"
            case .networkDiagnostics: return "Network Diagnostics"
            case .loginItems:         return "Login Items"
            case .batteryHealth:      return "Battery Health"
            case .sshKeys:            return "SSH Keys"
            case .pathEditor:         return "PATH Editor"
            case .gitGraph:           return "Git Graph"
            case .snapshot:           return "Snapshot"
            case .about:              return "About"
            }
        }
    }

    /// The active screen driving the main `ContentView` detail area.
    @Published var currentScreen: Screen = .dashboard {
        didSet { Telemetry.log(.featureOpened(feature: currentScreen.telemetryName)) }
    }
    /// Set to true once the initial 1.5-second minimum animation floor and start checks complete.
    @Published var isAppReady = false
    /// True when a global refresh is spinning across all view models.
    @Published var isPerformingFullRefresh = false
    /// A user-facing description of why the refresh is happening (e.g., "Installing Python...").
    @Published var fullRefreshActionLabel: String? = nil
    /// Mirrors `legalViewModel.requirement` so `ContentView` (which observes this VM) can present
    /// the blocking Privacy/Terms consent sheet. Non-nil ⇒ show the sheet.
    @Published var legalRequirement: LegalConsentRequirement?

    /// Guards the first full detection so it runs exactly once per launch. Kept after the removal
    /// of the entitlement gate: `startupChecks()` is the only caller today, but the guard is what
    /// makes a second call harmless rather than a duplicate shell-probe burst.
    private var didRunInitialDetection = false
    private var cancellables = Set<AnyCancellable>()

    // ProcessRunner removed (replaced by AsyncProcessRunner)

    let logger = Logger.shared
    let config = ConfigStore.shared
    let privileges: PrivilegesService
    let brewService: BrewService
    let pythonService: PythonService
    let dashboardViewModel: DashboardViewModel
    let pipPackagesViewModel: PIPPackagesViewModel
    let brewPackagesViewModel: BrewFormulaeCaskViewModel
    let outdatedPIPViewModel: OutdatedPIPViewModel
    let outdatedBrewViewModel: OutdatedBrewViewModel
    let smartShortcutsViewModel: SmartShortcutsViewModel
    let popularPackagesViewModel: PopularPackagesViewModel
    let aliasViewModel: AliasViewModel
    
    // Installation ViewModels
    let formulaeCaskInstallViewModel: FormulaeCaskInstallViewModel
    let pipPackagesInstallViewModel: PIPPackagesInstallViewModel
    let requirementsViewModel: RequirementsViewModel
    let virtualEnvViewModel: VirtualEnvironmentsViewModel
    let logsViewModel: LogsViewModel
    let networkMonitor: NetworkMonitor
    let aboutViewModel: AboutViewModel
    let drCatalystViewModel: DrCatalystViewModel
    let terminalTimeTravelViewModel: TerminalTimeTravelViewModel
    let ssdHealthViewModel: SSDHealthViewModel
    let cruftSweeperViewModel: CruftSweeperViewModel
    let networkDiagnosticsViewModel: NetworkDiagnosticsViewModel
    let loginItemsViewModel: LoginItemsViewModel
    let batteryHealthViewModel: BatteryHealthViewModel
    let sshKeyViewModel: SSHKeyViewModel
    let pathEditorViewModel: PathEditorViewModel
    let gitGraphViewModel: GitGraphViewModel
    let snapshotViewModel: SnapshotViewModel
    /// Owns versioned Privacy Policy / Terms & Conditions consent (blocking sheet + 14-day check).
    let legalViewModel = LegalConsentViewModel()

    /// Initializes the root ``AppViewModel`` and injects all downstream dependencies.
    ///
    /// **Rationale:**
    /// Acts as a central Dependency Injection (DI) container. By constructing all ViewModels and Services here,
    /// we guarantee a single unified state that is passed down through `ContentView` via `@EnvironmentObject` or explicit parameters.
    /// This prevents cyclic dependencies and ensures services like ``BrewService`` are singletons in practice.
    init() {
        self.privileges = PrivilegesService(logger: logger)
        self.brewService = BrewService(logger: logger, privileges: privileges)
        self.pythonService = PythonService(logger: logger, config: config, privileges: privileges)
        
        // Initialize DashboardViewModel
        self.dashboardViewModel = DashboardViewModel(
            brewService: brewService,
            pythonService: pythonService,
            privileges: privileges,
            logger: logger
        )
        
        // Initialize Package ViewModels
        self.pipPackagesViewModel = PIPPackagesViewModel(pythonService: pythonService)
        self.brewPackagesViewModel = BrewFormulaeCaskViewModel(brewService: brewService)
        
        // Initialize OutdatedPIPViewModel
        self.outdatedPIPViewModel = OutdatedPIPViewModel(
            logger: logger,
            pythonService: pythonService
        )
        
        // Initialize OutdatedBrewViewModel
        self.outdatedBrewViewModel = OutdatedBrewViewModel(logger: logger)
        
        // Initialize SmartShortcutsViewModel
        self.smartShortcutsViewModel = SmartShortcutsViewModel(logger: logger, pythonService: pythonService)
        
        // Initialize PopularPackagesViewModel
        self.popularPackagesViewModel = PopularPackagesViewModel(
            pythonService: pythonService,
            logger: logger
        )
        
        // Initialize aliasViewModel
        self.aliasViewModel = AliasViewModel(logger: logger)
        
        // Initialize VirtualEnvironmentsViewModel
        self.virtualEnvViewModel = VirtualEnvironmentsViewModel()
        
        // Initialize Installation ViewModels
        self.formulaeCaskInstallViewModel = FormulaeCaskInstallViewModel(brewService: brewService, logger: logger)
        self.pipPackagesInstallViewModel = PIPPackagesInstallViewModel(pythonService: pythonService, logger: logger)
        self.requirementsViewModel = RequirementsViewModel(pythonService: pythonService, logger: logger)
        
        // Initialize LogsViewModel
        self.logsViewModel = LogsViewModel(logger: logger)
        
        // Initialize NetworkMonitor
        self.networkMonitor = NetworkMonitor()
        
        // Initialize AboutViewModel
        self.aboutViewModel = AboutViewModel()
        
        // Initialize DrCatalystViewModel
        self.drCatalystViewModel = DrCatalystViewModel()
        
        // Initialize TerminalTimeTravelViewModel
        self.terminalTimeTravelViewModel = TerminalTimeTravelViewModel()
        
        // Initialize SSDHealthViewModel
        self.ssdHealthViewModel = SSDHealthViewModel(privileges: privileges)
        
        // Initialize CruftSweeperViewModel
        self.cruftSweeperViewModel = CruftSweeperViewModel()

        // Initialize NetworkDiagnosticsViewModel
        self.networkDiagnosticsViewModel = NetworkDiagnosticsViewModel()

        // Initialize LoginItemsViewModel
        self.loginItemsViewModel = LoginItemsViewModel()

        // Initialize BatteryHealthViewModel
        self.batteryHealthViewModel = BatteryHealthViewModel()

        // Initialize SSHKeyViewModel
        self.sshKeyViewModel = SSHKeyViewModel()

        // Initialize PathEditorViewModel
        self.pathEditorViewModel = PathEditorViewModel()

        // Initialize GitGraphViewModel
        self.gitGraphViewModel = GitGraphViewModel()

        // Initialize SnapshotViewModel
        self.snapshotViewModel = SnapshotViewModel()

        // Let Migrate resolve a fresh Mac itself: back its "Install All" with the
        // Dashboard's real installers + a PythonManager. `installHomebrew` returns
        // live presence (BrewPathManager recomputes), so the Python step that follows
        // sees the just-installed brew. CLT hands off to Apple's dialog (can't await).
        let snapshotPyManager = PythonManager(pythonService: pythonService, privileges: privileges, logger: logger)
        self.snapshotViewModel.prerequisiteInstaller = PrerequisiteInstaller(
            installHomebrew: { [weak self] in
                await self?.dashboardViewModel.installHomebrew()
                return await BrewPathManager.shared.isInstalled
            },
            installCLT: { [weak self] in
                await self?.dashboardViewModel.installCommandLineTools()
            },
            installPython: { mm in
                await snapshotPyManager.install(version: mm)
            },
            refreshDetection: { [weak self] in
                // New interpreters aren't seen until the Python cache is cleared;
                // then reload every VM (same path as post-install/uninstall refresh).
                self?.pythonService.invalidateCache()
                await self?.fullRefresh()
            }
        )

        // Wire global refresh: after install/uninstall, refresh all VMs
        self.dashboardViewModel.onGlobalRefresh = { [weak self] actionLabel in
            self?.fullRefreshActionLabel = actionLabel
            await self?.fullRefresh()
        }

        // Mirror the legal-consent requirement so ContentView can present the blocking sheet.
        self.legalViewModel.$requirement
            .removeDuplicates()
            .assign(to: &$legalRequirement)
    }

    /// Runs all VM startup/detection tasks in parallel.
    ///
    /// **Flow:**
    /// 1. Sets ``isPerformingFullRefresh`` flag.
    /// 2. Spawns a `TaskGroup` to execute the `.startup()` or `.reset()` functions of all loaded ViewModels simultaneously.
    /// 3. Resolves the network monitor status using the newly gathered stats.
    ///
    /// **Rationale:**
    /// This is fired globally whenever a package or Python is installed/uninstalled, guaranteeing
    /// that all tabs (Pip, Brew, Envs, Dashboard) reflect the updated filesystem truth seamlessly without requiring app restarts.
    func fullRefresh() async {
        isPerformingFullRefresh = true
        
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.dashboardViewModel.runDetection(force: true) }
            group.addTask { await self.drCatalystViewModel.scan() }
            group.addTask { await self.virtualEnvViewModel.startup() }
            group.addTask { await self.pipPackagesViewModel.startup() }
            group.addTask { await self.brewPackagesViewModel.startup() }
            group.addTask { await self.outdatedBrewViewModel.reset() }
            group.addTask { await self.outdatedPIPViewModel.reset() }
            group.addTask { await self.popularPackagesViewModel.loadPopularPackages() }
            
            // Installation view refresh hooks
            group.addTask { await self.formulaeCaskInstallViewModel.reset() }
            group.addTask { await self.pipPackagesInstallViewModel.reset() }
            group.addTask { await self.requirementsViewModel.reset() }
        }
        
        networkMonitor.updateSystemStatus(
            brewInstalled: dashboardViewModel.brewState == .installed,
            pythonCount: dashboardViewModel.installedPythons.count
        )
        
        isPerformingFullRefresh = false
        fullRefreshActionLabel = nil
    }

    /// Initiates the app's initial detection sequences and clears the splash screen.
    ///
    /// **Flow:**
    /// 1. Immediately triggers ``LogsViewModel/startup()`` to capture startup logs.
    /// 2. Evaluates ``didRunInitialDetection`` to run a detached ``fullRefresh()``.
    /// 3. Initiates ``LegalConsentViewModel/start()``.
    /// 4. Awaits 1.5 seconds strictly for animation pacing, then reveals the main app by setting ``isAppReady``.
    ///
    /// **Gotchas:**
    /// - Holds the launch screen artificially for 1.5s to prevent jarring flashes on M-series Macs
    ///   where the detection happens almost instantly.
    /// - Only triggers the detection sweep once, guarded by `didRunInitialDetection`.
    func startupChecks() async {
        logger.log("Catalyst launched - running initial detection")

        // Start listening for logs immediately.
        logsViewModel.startup()

        // Kick off the first full detection exactly once. This used to be triggered by entitlement
        // resolving to `.entitled`; with no sign-in gate there is nothing to wait for, so it starts
        // here. It stays a detached Task rather than an `await` so the launch-screen floor below
        // runs concurrently — every detection result is `@Published`, so the dashboard fills in as
        // each check finishes rather than blocking the reveal.
        if !didRunInitialDetection {
            didRunInitialDetection = true
            Task { await self.fullRefresh() }
        }

        // Resolve legal consent in parallel: refresh remote versions if the 14-day window elapsed,
        // then compute whether the blocking sheet is needed.
        Task { await legalViewModel.start() }

        // Hold the launch screen only for the animation floor, then reveal the app.
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            self.isAppReady = true
        }
    }
}
