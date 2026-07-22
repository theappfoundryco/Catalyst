import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appVM: AppViewModel
    @ObservedObject private var infoCenter = InfoCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showProfile = false

    var body: some View {
        Group {
        if appVM.isEntitled {
            // Full app — sidebar + toolbar + content — only once signed in & entitled.
            NavigationSplitView {
                // Sidebar
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

                    // Auto-update badge (P9): "Update available" → "Downloading…" →
                    // "Relaunch to update". Renders nothing when up to date.
                    SidebarUpdateBadge()
                        .padding(.horizontal, 8)
                        .padding(.top, 6)

                    // Status indicator at bottom of sidebar (now also surfaces the
                    // integrity/install-mode state via its shield + popover control).
                    StatusIndicatorView(networkMonitor: appVM.networkMonitor)
                        .padding(.horizontal, 8)
                        .padding(.top, 6)

                    // User row (name + avatar) below the status row → opens UserView.
                    UserProfileRow(authVM: appVM.authViewModel) { showProfile = true }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                .navigationTitle("Catalyst")
                .navigationSplitViewColumnWidth(min: 235, ideal: 235)
            } detail: {
                NavigationStack {
                    // Main content
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
                // App-wide fix: force detail symbols to monochrome so a button's
                // SF Symbol always follows its label color instead of rendering in
                // a mismatched accent/multicolor. Applies to all screens + their
                // toolbars, but NOT the sidebar (which keeps its colored icons).
                // Explicit colors/gradients on icons are preserved.
                .symbolRenderingMode(.monochrome)
            }
            // Main app toolbar is always visible — this branch only renders once
            // entitled, so no need to conditionally hide it. Traffic lights stay native.
            .toolbar(.visible, for: .windowToolbar)
            // One shared info sheet for the whole app; any InfoDot deep-links here.
            .sheet(item: $infoCenter.topic) { topic in
                AppInfoSheet(initialTopic: topic)
            }
            // Blocking Privacy/Terms consent sheet — window-modal over the whole entitled app.
            // Hosted on its OWN view node (a clear background) rather than stacked as a second
            // `.sheet` on this NavigationSplitView: two sheet modifiers on one view is unsupported
            // and thrashes SwiftUI's presentation state. A macOS sheet is window-modal regardless
            // of which view hosts it, so it still blocks the whole app. Non-dismissable (the sheet
            // itself sets `interactiveDismissDisabled`); acceptance clears the requirement, which
            // nils the item and dismisses. Recomputed from persisted state on launch, so it
            // survives force-quit/relaunch and re-appears on a version bump.
            .background(
                Color.clear.sheet(item: $appVM.legalRequirement) { req in
                    LegalConsentSheet(vm: appVM.legalViewModel, requirement: req)
                }
            )
        } else {
            // Plain sign-in window — NO sidebar, NO toolbar. Renders the brief token
            // check, then the sign-in form (or locked state). Once entitled, the whole
            // app (sidebar + toolbar + content) replaces this in place.
            AuthGateView(vm: appVM.authViewModel, legal: appVM.legalViewModel)
        }
        }
        .sheet(isPresented: $showProfile) {
            UserProfileSheet(authVM: appVM.authViewModel)
        }
        // On app-foreground, re-check entitlement immediately (bounded ≤8s) so a seat taken on
        // another Mac — or a renewal/lapse — is caught the moment the user returns, not just on
        // the 60s timer. No-op unless currently entitled.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await appVM.authViewModel.recheckEntitlement() }
                // Re-check legal versions on return — no-op unless the 14-day window has elapsed.
                Task { await appVM.legalViewModel.refreshDue() }
            }
        }
    }
}

// MARK: - Auto-update badge (P9)

/// Production wrapper: mirrors the live `UpdaterController` singleton and renders `UpdateBadgeView`.
/// Kept thin so the visual (`UpdateBadgeView`) can be driven by explicit state in Xcode Previews
/// without touching the runtime controller. Hidden when up to date.
struct SidebarUpdateBadge: View {
    @ObservedObject private var updates = UpdaterController.shared

    var body: some View {
        UpdateBadgeView(phase: updates.phase,
                        notesHTML: updates.releaseNotesHTML,
                        onRelaunch: { UpdaterController.shared.relaunchToUpdate() })
    }
}

/// Pure-visual badge: takes an explicit `UpdatePhase` + notes so it renders identically in the app
/// and in previews. Tapping opens a popover with the release notes; when the update is downloaded
/// the badge (and the popover) offers "Relaunch to Update".
struct UpdateBadgeView: View {
    let phase: UpdatePhase
    let notesHTML: String?
    let onRelaunch: () -> Void
    @State private var showNotes = false

    var body: some View {
        Group {
            switch phase {
            case .idle:
                EmptyView()
            case .available:
                badgeButton(icon: "arrow.down.circle.fill", tint: .blue,
                            text: "Update available")
            case .downloading:
                badgeButton(icon: "arrow.down.circle", tint: .blue,
                            text: "Downloading update…")
            case .readyToRelaunch:
                badgeButton(icon: "arrow.triangle.2.circlepath.circle.fill", tint: .green,
                            text: "Relaunch to update", primaryRelaunch: true)
            }
        }
        .sheet(isPresented: $showNotes) {
            ReleaseNotesSheet(phase: phase, notesHTML: notesHTML) {
                onRelaunch()
            }
        }
    }

    @ViewBuilder
    private func badgeButton(icon: String, tint: Color, text: String,
                             primaryRelaunch: Bool = false) -> some View {
        Button {
            if primaryRelaunch { onRelaunch() } else { showNotes = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundColor(tint)
                Text(text).font(.caption).fontWeight(.medium)
                    .foregroundColor(.primary).lineLimit(1)
                Spacer(minLength: 0)
                // A tap target to read notes even when the row's primary action is Relaunch.
                Image(systemName: "info.circle")
                    .font(.caption).foregroundColor(.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { showNotes = true }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.35), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .help(text)
    }
}

/// Sheet showing the pending update's version + release notes (rendered from the appcast
/// <description> HTML). Scrollable for long changelogs; offers "Relaunch to Update" once the
/// update is downloaded. Sized to match `AppInfoSheet` (460×400) for a consistent modal feel.
private struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let phase: UpdatePhase
    let notesHTML: String?
    let onRelaunch: () -> Void

    private var version: String {
        switch phase {
        case .available(let v), .downloading(let v), .readyToRelaunch(let v): return v
        case .idle: return ""
        }
    }
    private var isReady: Bool { if case .readyToRelaunch = phase { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New").font(.headline)
                    Text("Catalyst \(version)").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if case .downloading = phase {
                    Text("Downloading…").font(.caption).foregroundStyle(.secondary)
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ScrollView {
                if let notes = notesHTML, let attr = Self.attributed(fromHTML: notes) {
                    Text(attr).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No release notes provided for this version.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)

            if isReady {
                Divider()
                Button { dismiss(); onRelaunch() } label: {
                    Label("Relaunch to Update", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Text("This update will finish installing the next time you relaunch Catalyst.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }

    /// Render Sparkle release-note HTML to an AttributedString for display.
    static func attributed(fromHTML html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let ns = try? NSAttributedString(data: data, options: opts, documentAttributes: nil)
        else { return nil }
        return AttributedString(ns)
    }
}

// MARK: - Previews (canvas only — excluded from Release builds; never touches production state)

#if DEBUG
private let sampleNotes = """
<h2>Catalyst 1.1</h2>
<ul><li>Faster package scans.</li><li>New Git graph filters.</li><li>Bug fixes.</li></ul>
"""

/// Preview every sidebar update state, side by side, on a sidebar-like background.
#Preview("Sidebar update badge — all states") {
    VStack(alignment: .leading, spacing: 10) {
        Text("Update available").font(.caption2).foregroundColor(.secondary)
        UpdateBadgeView(phase: .available(version: "1.1"), notesHTML: sampleNotes, onRelaunch: {})

        Text("Downloading").font(.caption2).foregroundColor(.secondary)
        UpdateBadgeView(phase: .downloading(version: "1.1"), notesHTML: sampleNotes, onRelaunch: {})

        Text("Ready — relaunch to update").font(.caption2).foregroundColor(.secondary)
        UpdateBadgeView(phase: .readyToRelaunch(version: "1.1"), notesHTML: sampleNotes, onRelaunch: {})
    }
    .padding()
    .frame(width: 235)                       // matches the sidebar column width
    .background(Color(NSColor.controlBackgroundColor))
    .preferredColorScheme(.dark)
}

/// Preview the release-notes sheet in its "ready to relaunch" form.
#Preview("Release notes sheet") {
    ReleaseNotesSheet(phase: .readyToRelaunch(version: "1.1"), notesHTML: sampleNotes, onRelaunch: {})
        .preferredColorScheme(.dark)
}
#endif
