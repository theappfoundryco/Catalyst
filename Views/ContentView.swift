import SwiftUI
/// The main entry point and master navigation split view for the Catalyst application.
///
/// ```swift
/// ContentView()
/// ```
struct ContentView: View {
    @EnvironmentObject var appVM: AppViewModel
    @ObservedObject private var infoCenter = InfoCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            /// Catalyst is free and unauthenticated: there is no sign-in gate and no entitlement
            /// branch. The full app renders immediately on launch.
            ///
            /// **Gotchas:** Attempting to introduce async authorization checks here will cause a white-screen flash before the primary window renders.
            NavigationSplitView {
                /// Sidebar
                ///
                /// **Rationale:** Encapsulating sidebar rendering offloads state observation from the primary container view.
                VStack(spacing: 0) {
                    List(selection: $appVM.currentScreen) {
                        Section("Project Management") {
                            NavigationLink(value: AppViewModel.Screen.dashboard) {
                                Label("Dashboard", systemImage: "chart.bar.fill")
                            }
                            NavigationLink(value: AppViewModel.Screen.projects) {
                                Label("Virtual Environments", systemImage: "cube.fill")
                            }
                        }
                        
                        Section("Manage Existing Packages") {
                            NavigationLink(value: AppViewModel.Screen.installedPip) {
                                Label("pip Packages", systemImage: "shippingbox.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.installedBrew) {
                                Label("Formulae / Casks Packages", systemImage: "mug.fill")
                            }
                        }
                        
                        Section("Update Existing Packages") {
                            NavigationLink(value: AppViewModel.Screen.updates) {
                                Label("pip Updates", systemImage: "shippingbox.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.brewUpdates) {
                                Label("Formulae / Casks Updates", systemImage: "mug.fill")
                            }
                        }
                        
                        Section("Install New Packages") {
                            NavigationLink(value: AppViewModel.Screen.pipPackages) {
                                Label("Install pip Packages", systemImage: "shippingbox.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.brewPackages) {
                                Label("Install Formulae / Casks", systemImage: "mug.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.requirements) {
                                Label("requirements.txt Installer", systemImage: "doc.text.fill")
                            }
                        }
                        
                        
                        Section("Discover New") {
                            NavigationLink(value: AppViewModel.Screen.popular) {
                                Label("Popular Packages", systemImage: "star.fill")
                            }
                        }
                        
                        
                        Section("Developer Workflow") {
                            NavigationLink(value: AppViewModel.Screen.shortcuts) {
                                Label("SmartShortcuts", systemImage: "bolt.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.aliases) {
                                Label("Aliases", systemImage: "command.circle.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.terminalTimeTravel) {
                                Label("Terminal Time Travel", systemImage: "clock.arrow.circlepath")
                            }

                            NavigationLink(value: AppViewModel.Screen.pathEditor) {
                                Label("PATH Editor", systemImage: "arrow.left.arrow.right.square.fill")
                            }

                            NavigationLink(value: AppViewModel.Screen.gitGraph) {
                                Label("Git Graph", systemImage: "point.3.filled.connected.trianglepath.dotted")
                            }
                        }

                        Section("Health & Maintenance") {
                            NavigationLink(value: AppViewModel.Screen.drCatalyst) {
                                Label("Dr. Catalyst", systemImage: "stethoscope.circle.fill")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.ssdHealth) {
                                Label("Disk Vitals", systemImage: "internaldrive.fill")
                            }

                            NavigationLink(value: AppViewModel.Screen.batteryHealth) {
                                Label("Battery Health", systemImage: "battery.100.bolt")
                            }
                            
                            NavigationLink(value: AppViewModel.Screen.cruftSweeper) {
                                Label("Cruft Sweeper", systemImage: "trash.slash.fill")
                            }

                            NavigationLink(value: AppViewModel.Screen.networkDiagnostics) {
                                Label("Network Diagnostics", systemImage: "network")
                            }

                            NavigationLink(value: AppViewModel.Screen.loginItems) {
                                Label("Startup Items", systemImage: "power.circle.fill")
                            }

                            NavigationLink(value: AppViewModel.Screen.sshKeys) {
                                Label("SSH Keys", systemImage: "key.fill")
                            }

                            NavigationLink(value: AppViewModel.Screen.logs) {
                                Label("Logs", systemImage: "list.clipboard.fill")
                            }
                        }
                        
                        
                        Section("Migration") {
                            NavigationLink(value: AppViewModel.Screen.snapshot) {
                                Label("Snapshot & Migrate", systemImage: "arrow.triangle.2.circlepath.circle.fill")
                            }
                        }

                        Section("Help & Info"){
                            NavigationLink(value: AppViewModel.Screen.about) {
                                Label("About", systemImage: "info.circle.fill")
                            }
                        }
                    }
                    .listStyle(.sidebar)

                    /// Auto-update badge (P9): "Update available" → "Downloading…" →
                    /// "Relaunch to update". Renders nothing when up to date.
                    ///
                    /// **Rationale:** Directly mirroring the Sparkle state machine in the UI ensures users are never blind to background payload transfers.
                    SidebarUpdateBadge()
                        .padding(.horizontal, 8)
                        .padding(.top, 6)

                    /// Status indicator at bottom of sidebar (now also surfaces the
                    /// integrity/install-mode state via its shield + popover control).
                    ///
                    /// **Gotchas:** Hiding this indicator on small windows completely obscures critical SIP or permission warnings.
                    StatusIndicatorView(networkMonitor: appVM.networkMonitor)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)

                    /// Local user profile row (avatar + name) below the status
                    /// row; opens ``UserProfileSheet``. Groundwork for the
                    /// identity area from the paid era (licence/invoice details
                    /// return here in future releases).
                    UserProfileRow()
                        .padding(.horizontal, 8)
                        .padding(.top, 6)
                        .padding(.bottom, 6)
                }
                .navigationTitle("Catalyst")
                .navigationSplitViewColumnWidth(min: 235, ideal: 235)
            } detail: {
                NavigationStack {
                    /// Main content
                    ///
                    /// **Rationale:** Maintains a clean declarative separation between the navigation sidebar and the active workspace panel.
                    Group {
                        switch appVM.currentScreen {
                        case .dashboard:
                            DashboardView(vm: appVM.dashboardViewModel)
                            
                        case .projects:
                            VirtualEnvironmentsView(viewModel: appVM.virtualEnvViewModel)
                            
                        case .requirements:
                            RequirementsView(vm: appVM.requirementsViewModel)
                            
                        case .installedPip:
                            PIPPackagesView(viewModel: appVM.pipPackagesViewModel)
                            
                        case .installedBrew:
                            BrewFormulaeCaskView(viewModel: appVM.brewPackagesViewModel)
                            
                        case .updates:
                            OutdatedPIPView(vm: appVM.outdatedPIPViewModel)
                            
                        case .brewUpdates:
                            OutdatedBrewView(vm: appVM.outdatedBrewViewModel)
                            
                        case .popular:
                            PopularPackagesView(vm: appVM.popularPackagesViewModel)
                            
                        case .pipPackages:
                            PIPPackagesInstallView(vm: appVM.pipPackagesInstallViewModel)
                            
                        case .brewPackages:
                            FormulaeCaskInstallView(viewModel: appVM.formulaeCaskInstallViewModel)
                            
                        case .shortcuts:
                            SmartShortcutsView(vm: appVM.smartShortcutsViewModel)
                            
                        case .aliases:
                            AliasView(vm: appVM.aliasViewModel)
                            
                        case .drCatalyst:
                            DrCatalystView(vm: appVM.drCatalystViewModel)
                            
                        case .terminalTimeTravel:
                            TerminalTimeTravelView(vm: appVM.terminalTimeTravelViewModel)
                            
                        case .ssdHealth:
                            SSDHealthView(
                                vm: appVM.ssdHealthViewModel,
                                onNavigateToDashboard: { appVM.currentScreen = .dashboard }
                            )
                            
                        case .cruftSweeper:
                            CruftSweeperView(vm: appVM.cruftSweeperViewModel)

                        case .networkDiagnostics:
                            NetworkDiagnosticsView(vm: appVM.networkDiagnosticsViewModel)

                        case .loginItems:
                            LoginItemsView(vm: appVM.loginItemsViewModel)

                        case .batteryHealth:
                            BatteryHealthView(vm: appVM.batteryHealthViewModel)

                        case .sshKeys:
                            SSHKeyView(vm: appVM.sshKeyViewModel)

                        case .pathEditor:
                            PathEditorView(vm: appVM.pathEditorViewModel)

                        case .gitGraph:
                            GitGraphView(vm: appVM.gitGraphViewModel)

                        case .snapshot:
                            SnapshotView(vm: appVM.snapshotViewModel)

                        case .logs:
                            LogsView(vm: appVM.logsViewModel)
                            
                        case .about:
                            AboutView(vm: appVM.aboutViewModel)
                        }
                    }
                }
                /// App-wide fix: force detail symbols to monochrome so a button's
                /// SF Symbol always follows its label color instead of rendering in
                /// a mismatched accent/multicolor. Applies to all screens + their
                /// toolbars, but NOT the sidebar (which keeps its colored icons).
                /// Explicit colors/gradients on icons are preserved.
                ///
                /// **Gotchas:** Stripping this modifier causes SF Symbols in disabled buttons to remain bright blue instead of gracefully dimming to gray.
                .symbolRenderingMode(.monochrome)
            }
            /// Main app toolbar is always visible. Traffic lights stay native.
            ///
            /// **Gotchas:** Overriding the window style to `.hiddenTitleBar` unexpectedly destroys the native macOS traffic light hover interactions.
            .toolbar(.visible, for: .windowToolbar)
            /// One shared info sheet for the whole app; any InfoDot deep-links here.
            ///
            /// **Rationale:** Consolidating documentation into a single global sheet prevents SwiftUI presentation stack collisions when multiple views request help simultaneously.
            .sheet(item: $infoCenter.topic) { topic in
                AppInfoSheet(initialTopic: topic)
            }
            /// Blocking Privacy/Terms consent sheet — window-modal over the whole app.
            /// Hosted on its OWN view node (a clear background) rather than stacked as a second
            /// `.sheet` on this NavigationSplitView: two sheet modifiers on one view is unsupported
            /// and thrashes SwiftUI's presentation state. A macOS sheet is window-modal regardless
            /// of which view hosts it, so it still blocks the whole app. Non-dismissable (the sheet
            /// itself sets `interactiveDismissDisabled`); acceptance clears the requirement, which
            /// nils the item and dismisses. Recomputed from persisted state on launch, so it
            /// survives force-quit/relaunch and re-appears on a version bump.
            ///
            /// **Gotchas:** Attaching this second `.sheet` directly to the `NavigationSplitView` crashes SwiftUI silently on macOS 14 when the app launches.
            .background(
                Color.clear.sheet(item: $appVM.legalRequirement) { req in
                    LegalConsentSheet(vm: appVM.legalViewModel, requirement: req)
                }
            )
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                /// Re-check legal versions on return — no-op unless the 14-day window has elapsed.
                ///
                /// **Rationale:** Tying the remote check to `onReceive` ensures users who leave the app running for months still get prompted when policies change.
                Task { await appVM.legalViewModel.refreshDue() }
            }
        }
    }
}

// MARK: - Auto-update badge (P9)

/// Production wrapper: mirrors the live `UpdaterController` singleton and renders `UpdateBadgeView`.
/// Kept thin so the visual (`UpdateBadgeView`) can be driven by explicit state in Xcode Previews
/// without touching the runtime controller. Hidden when up to date.
///
/// ```swift
/// SidebarUpdateBadge()
/// ```
struct SidebarUpdateBadge: View {
    @ObservedObject private var updates = UpdaterController.shared

    var body: some View {
        UpdateBadgeView(phase: updates.phase,
                        onRelaunch: { UpdaterController.shared.relaunchToUpdate() })
    }
}

/// Pure-visual badge: takes an explicit `UpdatePhase` so it renders identically in the app and in
/// previews.
///
/// Deliberately has no release-notes affordance. Updates download in the background and the only
/// thing the user ever has to decide is *when to relaunch* — so `available` and `downloading` are
/// plain status text with nothing to click, and only `readyToRelaunch` is interactive. An earlier
/// version put an `info.circle` on every state that opened a notes sheet; it made a passive status
/// row look like it needed attention. What changed in a release belongs on the release page, not in
/// a sidebar popover.
///
/// ```swift
/// UpdateBadgeView(phase: .available, onRelaunch: { relaunch() })
/// ```
struct UpdateBadgeView: View {
    let phase: UpdatePhase
    let onRelaunch: () -> Void

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .available:
            badge(icon: "arrow.down.circle.fill", tint: .blue, text: "Update available")
        case .downloading:
            badge(icon: "arrow.down.circle", tint: .blue, text: "Downloading update…")
        case .readyToRelaunch:
            Button(action: onRelaunch) {
                badge(icon: "arrow.triangle.2.circlepath.circle.fill", tint: .green,
                      text: "Relaunch to update")
            }
            .buttonStyle(.plain)
            .help("Relaunch to update")
        }
    }

    /// The row itself. Not a button — the `readyToRelaunch` case wraps it in one. Keeping the
    /// chrome in a plain view means the two passive states cannot accidentally acquire a hover
    /// or press affordance that implies they do something.
    /// - Parameters:
    ///   - icon: The associated SF Symbol glyph.
    ///   - tint: The color mapping applied to background shading.
    ///   - text: The localized status string indicating state.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func badge(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundColor(tint)
            Text(text).font(.caption).fontWeight(.medium)
                .foregroundColor(.primary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35), lineWidth: 1))
        )
    }
}


// MARK: - Previews (canvas only — excluded from Release builds; never touches production state)

#if DEBUG
/// Preview every sidebar update state, side by side, on a sidebar-like background.
#Preview("Sidebar update badge — all states") {
    VStack(alignment: .leading, spacing: 10) {
        Text("Update available").font(.caption2).foregroundColor(.secondary)
        UpdateBadgeView(phase: .available(version: "1.1"), onRelaunch: {})

        Text("Downloading").font(.caption2).foregroundColor(.secondary)
        UpdateBadgeView(phase: .downloading(version: "1.1"), onRelaunch: {})

        Text("Ready — relaunch to update").font(.caption2).foregroundColor(.secondary)
        UpdateBadgeView(phase: .readyToRelaunch(version: "1.1"), onRelaunch: {})
    }
    .padding()
    .frame(width: 235)                       // matches the sidebar column width
    .background(Color(NSColor.controlBackgroundColor))
    .preferredColorScheme(.dark)
}
#endif
