/// Subview components extracted from DashboardView for better modularity.

import SwiftUI

// MARK: - System Status Card
/// A dashboard card displaying the health and installation status of core system tools.
///
/// ```swift
/// SystemStatusCard(vm: viewModel, showSystemPythonErrorPopover: $showError)
/// ```
struct SystemStatusCard: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var showSystemPythonErrorPopover: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Status")
                .font(.headline)
            
            SectionDivider()
            
            // System Python
            HStack(spacing: 12) {
                Image(systemName: "apple.logo")
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Python")
                        .font(.subheadline)
                    
                    HStack(spacing: 8) {
                        Text(vm.systemPythonVersion)
                            .font(.caption)
                            .foregroundColor(vm.systemPythonError != nil ? .red : .secondary)
                        
                        if vm.systemPythonError != nil {
                            Button {
                                showSystemPythonErrorPopover = true
                            } label: {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .appButton(.plain)
                            .popover(isPresented: $showSystemPythonErrorPopover) {
                                if let err = vm.systemPythonError {
                                    Text(err)
                                        .padding()
                                        .frame(width: 300)
                                }
                            }
                        }
                    }
                }
                
                Spacer()
            }

            // Command Line Tools
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "hammer.fill")
                        .foregroundColor(vm.commandLineToolsStatusColor)
                        .frame(width: 10)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Command Line Tools")
                            .font(.subheadline)
                        Text(vm.commandLineToolsStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if vm.commandLineToolsStatus == "Not Installed" {
                        Button {
                            Task { await vm.installCommandLineTools() }
                        } label: {
                            Text(vm.isInstallingCommandLineTools ? "Requesting..." : "Install")
                        }
                        .appButton(.primary)
                        .disabled(vm.isBusy)
                    }
                }
                
                if vm.commandLineToolsStatus == "Not Installed" {
                    BannerView(
                        .info,
                        title: "Clicking Install will open a dialog",
                        message: "You'll be guided through the installation by macOS. This is required for many developer tools.",
                        size: .compact
                    )
                }
            }
            
            // Homebrew
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "mug.fill")
                        .foregroundColor(vm.brewStatusColor)
                        .frame(width: 10)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Homebrew")
                            .font(.subheadline)
                        Text(vm.brewStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if vm.brewStatus == "Not Installed" {
                        Button {
                            Task { await vm.installHomebrew() }
                        } label: {
                            Text(vm.isInstallingBrew ? "Installing..." : "Install")
                        }
                        .appButton(.primary)
                        .disabled(vm.isBusy)
                    }
                }
                
                if vm.brewStatus == "Not Installed" {
                    BannerView(
                        .info,
                        title: "One-Click In-App Install",
                        message: "You'll be prompted for your password. After installation, broken symlinks will be automatically detected and repaired.",
                        size: .compact
                    )
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - Installed Pythons Card
/// A dashboard card listing all detected Python installations and offering pip repair/upgrade actions.
///
/// ```swift
/// InstalledPythonsCard(vm: viewModel)
/// ```
struct InstalledPythonsCard: View {
    @ObservedObject var vm: DashboardViewModel
    /// Observed so pip-upgrade rows re-render when the global tier changes.
    @ObservedObject private var installPrefs = InstallPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Installed Python Versions")
                    .font(.headline)
                
                Spacer()
                
                Text("\(vm.installedPythons.count) found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            SectionDivider()
            
            if vm.installedPythons.isEmpty {
                EmptyStateView(icon: "tray", message: "No Python versions found", verticalPadding: 20)
            } else {
                VStack(spacing: 8) {
                    let sortedPythons = Array(vm.sortedInstalledPythons.enumerated())

                    ForEach(sortedPythons, id: \.element.path) { index, python in
                        PythonInstallationRow(
                            python: python,
                            isRepairing: vm.repairingPipFor == python.version,
                            isUpgrading: vm.upgradingPipFor == python.version,
                            isBusy: vm.isBusy,
                            isPipUpgradeAvailable: vm.isPipUpgradeAvailable(for: python),
                            isSystemPythonConflict: vm.isSystemPythonConflict(for: python),
                            latestPipVersion: vm.pipUpgradeTargets[python.path.path],
                            systemPythonVersion: vm.systemPythonVersion,
                            installMode: installPrefs.mode,
                            onRepair: { Task { await vm.repairPip(for: python) } },
                            onUpgrade: { Task { await vm.upgradePip(for: python) } }
                        )
                        .equatable()

                        if index < vm.installedPythons.count - 1 {
                            SectionDivider()
                        }
                    }
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - Python Installation Row

/// Leaf row for one Python installation. Takes plain values + action closures
/// instead of the whole `@ObservedObject` VM (R1-row), and is `Equatable` so
/// SwiftUI skips re-rendering rows whose inputs didn't change when an unrelated
/// part of the dashboard updates. Closures are intentionally excluded from `==`.
///
/// ```swift
/// PythonInstallationRow(python: py, isRepairing: false, isUpgrading: false, ...)
/// ```
struct PythonInstallationRow: View, Equatable {
    let python: PythonInstallation
    let isRepairing: Bool
    let isUpgrading: Bool
    let isBusy: Bool
    let isPipUpgradeAvailable: Bool
    let isSystemPythonConflict: Bool
    let latestPipVersion: String?
    let systemPythonVersion: String
    /// Current global install tier. On a 3.12+ interpreter it decides whether
    /// the Upgrade action is offered and which pip flags the backend applies.
    let installMode: PipInstallMode
    let onRepair: () -> Void
    let onUpgrade: () -> Void

    /// One-time confirmation before a System-wide pip upgrade (can break OS pkgs).
    @State private var showSystemWideConfirm = false
    /// Staged (not-yet-applied) override tier awaiting confirmation. Selecting a
    /// non-Protected mode parks it here until the user confirms.
    @State private var pendingMode: PipInstallMode?

    /// Picker binding: switching to Protected applies immediately (always safe);
    /// switching to an override stages `pendingMode` for confirmation instead.
    private var installModeBinding: Binding<PipInstallMode> {
        Binding(
            get: { installMode },
            set: { newMode in
                if newMode == .protected {
                    InstallPreferences.shared.mode = .protected
                } else if newMode != installMode {
                    pendingMode = newMode
                }
            }
        )
    }

    static func == (lhs: PythonInstallationRow, rhs: PythonInstallationRow) -> Bool {
        lhs.python == rhs.python &&
        lhs.isRepairing == rhs.isRepairing &&
        lhs.isUpgrading == rhs.isUpgrading &&
        lhs.isBusy == rhs.isBusy &&
        lhs.isPipUpgradeAvailable == rhs.isPipUpgradeAvailable &&
        lhs.isSystemPythonConflict == rhs.isSystemPythonConflict &&
        lhs.latestPipVersion == rhs.latestPipVersion &&
        lhs.systemPythonVersion == rhs.systemPythonVersion &&
        lhs.installMode == rhs.installMode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Python \(python.version)")
                        .font(.subheadline)
                    Text(python.path.path)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // pip badge
                HStack(spacing: 4) {
                    Image(systemName: python.pipAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(python.pipAvailable ? .green : .red)
                    
                    if let pipVer = python.pipVersion {
                        Text("pip \(pipVer)")
                            .font(.caption)
                    } else {
                        Text("pip")
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(python.pipAvailable ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
                )
                
                // Repair pip
                if !python.pipAvailable {
                    Button {
                        onRepair()
                    } label: {
                        if isRepairing {
                            ProgressView().scaleEffect(0.7).frame(width: 50)
                        } else {
                            Text("Repair")
                        }
                    }
                    .appButton(.primary)
                    .controlSize(.small)
                    .disabled(isBusy)
                }

                // Upgrade pip — pre-3.12 interpreters upgrade directly (no
                // override needed). 3.12+ (externally-managed) upgrades are
                // handled by the install-mode control below the row, which
                // requires choosing an override tier first.
                if python.pipAvailable && isPipUpgradeAvailable &&
                    !VersionComparator.requiresBreakSystemPackages(pythonVersion: python.version) {
                    Button {
                        onUpgrade()
                    } label: {
                        if isUpgrading {
                            ProgressView().scaleEffect(0.7).frame(width: 50)
                        } else {
                            Text("Upgrade")
                        }
                    }
                    .appButton(.primary)
                    .controlSize(.small)
                    .disabled(isBusy)
                }
            }

            // pip upgrade available on a 3.12+ (externally-managed) interpreter:
            // pick an override tier and upgrade inline. Upgrade stays disabled
            // under Protected by design — no more clickable disclaimer banner.
            if python.pipAvailable && isPipUpgradeAvailable && VersionComparator.requiresBreakSystemPackages(pythonVersion: python.version) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: installMode.icon)
                            .foregroundColor(installMode.tint)
                        Text("Install mode")
                            .font(.subheadline.weight(.medium))
                        InfoDot(topic: .installModes)

                        Spacer()

                        Picker("", selection: installModeBinding) {
                            ForEach(PipInstallMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()

                        Button {
                            // System-wide can corrupt OS/Homebrew packages: confirm once.
                            if installMode == .systemWide {
                                showSystemWideConfirm = true
                            } else {
                                onUpgrade()
                            }
                        } label: {
                            if isUpgrading {
                                ProgressView().scaleEffect(0.7).frame(width: 60)
                            } else {
                                Text("Upgrade")
                            }
                        }
                        .appButton(.primary)
                        .controlSize(.small)
                        .disabled(isBusy || installMode == .protected)
                        .confirmationDialog(
                            "Upgrade pip system-wide?",
                            isPresented: $showSystemWideConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Upgrade (System-wide)", role: .destructive) { onUpgrade() }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("pip will upgrade with --break-system-packages, writing into the OS-managed Python. This can break Homebrew/system packages.")
                        }
                    }

                    // The static warning we originally shipped — restored.
                    BannerView(
                        .warning,
                        message: "pip \(latestPipVersion ?? "upgrade") available — Catalyst respects system integrity and won't use \"--break-system-packages\" to upgrade unless you pick an override above.",
                        size: .compact
                    )
                }
                .padding(.bottom, 6)
                // Switching away from Protected applies to every Python action,
                // so confirm the tier before committing to it.
                .confirmationDialog(
                    "Switch to \(pendingMode?.title ?? "")?",
                    isPresented: Binding(
                        get: { pendingMode != nil },
                        set: { if !$0 { pendingMode = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingMode
                ) { mode in
                    Button("Switch to \(mode.title)", role: mode == .systemWide ? .destructive : nil) {
                        InstallPreferences.shared.mode = mode
                        pendingMode = nil
                    }
                    Button("Cancel", role: .cancel) { pendingMode = nil }
                } message: { mode in
                    Text(mode.confirmMessage)
                }
            }

            if isSystemPythonConflict {
                BannerView(
                    .warning,
                    message: "Caution: Matches System Python (\(systemPythonVersion)). Ensure you are targeting the correct environment.",
                    size: .compact
                )
                .padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Install Python Card
/// A dashboard card providing the interface to install new Python versions via Homebrew.
///
/// ```swift
/// InstallPythonCard(vm: viewModel, showInstallConfirmation: $showConfirm)
/// ```
struct InstallPythonCard: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var showInstallConfirmation: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install New Python Version")
                .font(.headline)
            
            SectionDivider()
            
            if vm.isLoadingAvailableVersions {
                LoadingStateView("Loading available versions...", verticalPadding: 20)
            } else if vm.availablePythonVersions.isEmpty {
                VStack(spacing: 8) {
                    Text("All versions installed")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if !vm.installedVersionsList.isEmpty {
                        Text("Installed version(s): \(vm.installedVersionsList)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                HStack(spacing: 12) {
                    Picker("Version", selection: $vm.selectedVersionToInstall) {
                        Text("Select version").tag(nil as String?)
                        ForEach(vm.availablePythonVersions) { v in
                            Text(v.deprecated ? "Python \(v.version)  (deprecated)" : "Python \(v.version)")
                                .tag(v.version as String?)
                        }
                    }
                    // Hide the built-in "Version" label: on macOS 26 (Tahoe) a labeled menu picker
                    // pins the control to the right and shrinks it to its content, leaving a large
                    // gap between the label and the control. With the label hidden, the menu control
                    // itself fills `maxWidth: .infinity` across every window size. The inline
                    // "Select version" placeholder still tells the user what it is.
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(vm.brewStatus != "Installed")
                    
                    Button {
                        showInstallConfirmation = true
                    } label: {
                        Text(vm.isInstallingPython ? "Installing..." : "Install")
                    }
                    .appButton(.primary)
                    .disabled(vm.selectedVersionToInstall == nil || vm.isBusy || vm.brewStatus != "Installed")
                    .confirmationDialog(
                        "Install Python \(vm.selectedVersionToInstall ?? "")?",
                        isPresented: $showInstallConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Install & Link", role: .none) {
                            Task { await vm.installSelectedPython() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will install Python \(vm.selectedVersionToInstall ?? "") and set it as your primary version (via brew link).\n\nThis updates your system 'python3' command to point to this version.")
                    }
                }

                if let sel = vm.selectedVersionToInstall,
                   vm.availablePythonVersions.first(where: { $0.version == sel })?.deprecated == true {
                    Label("Python \(sel) is deprecated in Homebrew — prefer a newer version.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                if !vm.installedVersionsList.isEmpty {
                    Text("Installed version(s): \(vm.installedVersionsList)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - Uninstall Card
/// A dashboard card for uninstalling Homebrew and selected Python versions.
///
/// ```swift
/// UninstallCard(vm: viewModel, showUninstallBrewConfirmation: $showBrew, showUninstallPythonConfirmation: $showPy)
/// ```
struct UninstallCard: View {
    @ObservedObject var vm: DashboardViewModel
    @Binding var showUninstallBrewConfirmation: Bool
    @Binding var showUninstallPythonConfirmation: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Uninstall")
                .font(.headline)
            
            SectionDivider()
            
            if vm.brewStatus == "Installed" {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Homebrew")
                            .font(.subheadline)
                        Text("Remove Homebrew and all installed packages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        showUninstallBrewConfirmation = true
                    } label: {
                        Text(vm.isUninstallingBrew ? "Uninstalling..." : "Uninstall")
                    }
                    .appButton(.destructive)
                    .disabled(vm.isBusy)
                    .confirmationDialog(
                        "Uninstall Homebrew?",
                        isPresented: $showUninstallBrewConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Uninstall Homebrew", role: .destructive) {
                            Task { await vm.uninstallHomebrew() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will remove Homebrew and all installed packages. This action cannot be undone.")
                    }
                }
            }
            
            if !vm.installedPythons.isEmpty {
                if vm.brewStatus == "Installed" {
                    SectionDivider()
                }
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Python Versions")
                        .font(.subheadline)
                    
                    ForEach(vm.sortedInstalledPythons, id: \.version) { python in
                        Toggle(isOn: Binding(
                            get: { vm.selectedVersionsToUninstall.contains(python.version) },
                            set: { isSelected in
                                if isSelected {
                                    vm.selectedVersionsToUninstall.insert(python.version)
                                } else {
                                    vm.selectedVersionsToUninstall.remove(python.version)
                                }
                            }
                        )) {
                            Text("Python \(python.version)")
                                .font(.subheadline)
                        }
                    }
                    
                    Button {
                        showUninstallPythonConfirmation = true
                    } label: {
                        Text(vm.isUninstallingPython ? "Uninstalling..." : "Uninstall Selected")
                            .frame(maxWidth: .infinity)
                    }
                    .appButton(.destructiveProminent)
                    .disabled(vm.selectedVersionsToUninstall.isEmpty || vm.isBusy)
                    .confirmationDialog(
                        "Uninstall Python Versions?",
                        isPresented: $showUninstallPythonConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Uninstall \(vm.selectedVersionsToUninstall.count) Python Version(s)", role: .destructive) {
                            Task { await vm.uninstallSelectedPythons() }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("This will remove the selected Python versions. This action cannot be undone.")
                    }
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - Homebrew Maintenance Components
/// A dashboard card grouping Homebrew maintenance operations like update, upgrade, cleanup, and doctor.
///
/// ```swift
/// BrewMaintenanceCard(vm: viewModel)
/// ```
struct BrewMaintenanceCard: View {
    @ObservedObject var vm: DashboardViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            // Unlinked Kegs Warning
            if !vm.brewUnlinkedKegs.isEmpty {
                UnlinkedKegsSection(kegs: vm.brewUnlinkedKegs, isLinking: vm.isBrewLinking) {
                    Task { await vm.linkBrewKegs() }
                }
            }
            
            VStack(alignment: .leading, spacing: 16) {
                Text("Homebrew Maintenance")
                    .font(.headline)
                
                SectionDivider()
                
                if let stats = vm.brewSystemStats {
                    HStack(spacing: 0) {
                        StatColumn(label: "Cache Size", value: stats.cacheSize)
                        SectionDivider().frame(height: 30)
                        StatColumn(label: "Cellar Size", value: stats.cellarSize)
                        SectionDivider().frame(height: 30)
                        StatColumn(label: "Can Be Cleaned", value: stats.cleanableSize)
                        SectionDivider().frame(height: 30)
                        StatColumn(label: "Last Updated", value: stats.lastUpdate)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    
                    SectionDivider()
                }
                
                VStack(spacing: 12) {
                    MaintenanceOperationRow(
                        icon: "arrow.triangle.2.circlepath",
                        title: "Update Homebrew",
                        description: "Fetch the newest version of Homebrew and all formulae",
                        color: .blue,
                        buttonTitle: "Run",
                        loadingTitle: "Updating...",
                        isRunning: vm.isBrewUpdating,
                        isBusy: vm.isBusy
                    ) {
                        Task { await vm.updateBrew() }
                    }
                    .equatable()
                    
                    SectionDivider()
                    
                    MaintenanceOperationRow(
                        icon: "arrow.up.circle.fill",
                        title: "Upgrade Packages",
                        description: "Upgrade all outdated packages to their latest versions",
                        color: .green,
                        buttonTitle: "Run",
                        loadingTitle: "Upgrading...",
                        isRunning: vm.isBrewUpgrading,
                        isBusy: vm.isBusy
                    ) {
                        Task { await vm.upgradeAllBrew() }
                    }
                    .equatable()
                    
                    SectionDivider()
                    
                    MaintenanceOperationRow(
                        icon: "trash.fill",
                        title: "Cleanup",
                        description: "Remove old versions and clear cache",
                        color: .orange,
                        buttonTitle: "Run",
                        loadingTitle: "Cleaning...",
                        isRunning: vm.isBrewCleaning,
                        isBusy: vm.isBusy
                    ) {
                        Task { await vm.cleanupBrew() }
                    }
                    .equatable()
                    
                    SectionDivider()
                    
                    MaintenanceOperationRow(
                        icon: "stethoscope.circle.fill",
                        title: "Doctor",
                        description: "Check system for potential problems",
                        color: .red,
                        buttonTitle: "Run",
                        loadingTitle: "Running...",
                        isRunning: vm.isRunningBrewDoctor,
                        isBusy: vm.isBusy
                    ) {
                        Task { await vm.doctorBrew() }
                    }
                    .equatable()
                }
            }
            .cardStyle()
            
            // Output Console (isolated observable — see ConsoleOutput, R2)
            ConsoleOutputView(console: vm.console, title: "Output", maxHeight: 250)
        }
        .task {
            await vm.loadBrewStats()
        }
    }
}

/// Leaf row for one Homebrew maintenance action. Takes plain values + an action
/// closure instead of the whole `@ObservedObject` VM (R1-row); `Equatable` so
/// SwiftUI skips re-rendering rows whose inputs didn't change. Closure excluded
/// from `==`.
///
/// ```swift
/// MaintenanceOperationRow(icon: "trash", title: "Cleanup", description: "...", color: .orange, ...)
/// ```
struct MaintenanceOperationRow: View, Equatable {
    let icon: String
    let title: String
    let description: String
    let color: Color
    let buttonTitle: String
    let loadingTitle: String
    let isRunning: Bool
    let isBusy: Bool
    let action: () -> Void

    static func == (lhs: MaintenanceOperationRow, rhs: MaintenanceOperationRow) -> Bool {
        lhs.icon == rhs.icon &&
        lhs.title == rhs.title &&
        lhs.description == rhs.description &&
        lhs.color == rhs.color &&
        lhs.buttonTitle == rhs.buttonTitle &&
        lhs.loadingTitle == rhs.loadingTitle &&
        lhs.isRunning == rhs.isRunning &&
        lhs.isBusy == rhs.isBusy
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                action()
            } label: {
                Text(isRunning ? loadingTitle : buttonTitle)
            }
            .appButton(.primary)
            .tint(color)
            .disabled(isBusy)
        }
    }
}

/// A vertical statistic display showing a label and its corresponding value.
///
/// ```swift
/// StatColumn(label: "Cache Size", value: "1.2 GB")
/// ```
struct StatColumn: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A dashboard section warning the user about unlinked Homebrew kegs and providing a link action.
///
/// ```swift
/// UnlinkedKegsSection(kegs: ["python@3.11"], isLinking: false) { link() }
/// ```
struct UnlinkedKegsSection: View {
    let kegs: [String]
    let isLinking: Bool
    let onLink: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundColor(.orange)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlinked Packages Detected")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("The following packages are installed but not linked. This may cause 'command not found' errors:")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text(kegs.joined(separator: ", "))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            Button {
                onLink()
            } label: {
                HStack {
                    if isLinking {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                            .tint(.white)
                    } else {
                        Image(systemName: "link")
                    }
                    Text(isLinking ? "Linking Packages..." : "Link Packages")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .appButton(.primary)
            .tint(.orange)
            .disabled(isLinking)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Default Python Version card
//
// Lets the user choose which installed Homebrew Python is the *default* (a bare `python` /
// `python3` / `pip` in new shells). Every edit goes through `PythonDefaultManager`, which only
// ever writes Catalyst's own marker-delimited block in `~/.zshrc_catalyst` — never the user's
// `~/.zshrc`. Shows the current default, warns if one is pinned outside Catalyst, and lets the
// user switch to any OTHER installed version.
struct DefaultPythonCard: View {
    @ObservedObject var vm: DashboardViewModel
    @ObservedObject var manager: PythonDefaultManager

    /// Installed versions the user can switch TO — unique by formula, excluding the current default.
    private var candidates: [PythonInstallation] {
        var seen = Set<String>()
        return vm.sortedInstalledPythons.filter { p in
            guard seen.insert(p.formula).inserted else { return false }
            return PythonDefaultManager.majorMinor(fromFormula: p.formula) != manager.current.version
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Default Python Version")
                .font(.headline)

            SectionDivider()

            // Current default — an inset row whose two lines convey the whole state. The reset
            // action sits inline at the trailing edge, shown only when Catalyst set the default.
            HStack(spacing: 12) {
                Image(systemName: currentIcon)
                    .font(.title3)
                    .foregroundColor(currentTint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current default")
                        .font(.subheadline.weight(.medium))
                    Text(currentSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                if manager.current.source == .catalyst {
                    Button {
                        Task { await manager.reset() }
                    } label: {
                        Label("Remove Catalyst default", systemImage: "arrow.uturn.backward")
                    }
                    .appButton(.secondary)
                    .disabled(manager.isApplying)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )

            // Switch to another installed version.
            if candidates.isEmpty {
                Text(manager.current.source == .none
                     ? "No installed Homebrew Python versions to set as default."
                     : "No other installed versions to switch to.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Switch to another version")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Picker("Default Python", selection: $manager.selection) {
                            Text("Select version").tag(nil as String?)
                            ForEach(candidates) { p in
                                Text("Python \(PythonDefaultManager.majorMinor(fromFormula: p.formula))")
                                    .tag(p.formula as String?)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(manager.isApplying)

                        Button {
                            if let formula = manager.selection {
                                Task { await manager.apply(formula: formula) }
                            }
                        } label: {
                            if manager.isApplying {
                                ProgressView().scaleEffect(0.7).frame(width: 44)
                            } else {
                                Text("Apply")
                            }
                        }
                        .appButton(.primary)
                        .disabled(manager.selection == nil || manager.isApplying)
                    }
                }
            }
        }
        .cardStyle()
        .task { await manager.refresh() }
    }

    private var currentIcon: String {
        switch manager.current.source {
        case .none:     return "circle.dashed"
        case .catalyst: return "checkmark.seal.fill"
        case .external: return "exclamationmark.triangle.fill"
        }
    }
    private var currentTint: Color {
        switch manager.current.source {
        case .none:     return .secondary
        case .catalyst: return .green
        case .external: return .orange
        }
    }
    private var currentSubtitle: String {
        switch manager.current.source {
        case .none:     return "Not set by Catalyst — using your system default"
        case .catalyst: return "Python \(manager.current.version ?? "?") · set by Catalyst"
        case .external: return "Python \(manager.current.version ?? "?") · in your ~/.zshrc (applying here overrides it)"
        }
    }
}
