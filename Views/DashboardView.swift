import SwiftUI
/// The main dashboard view providing a high-level overview of the system status, Python installations, and Homebrew health.
///
/// ```swift
/// DashboardView(vm: dashboardViewModel)
/// ```
struct DashboardView: View {
    @ObservedObject var vm: DashboardViewModel
    @State private var showUninstallBrewConfirmation = false
    @State private var showUninstallPythonConfirmation = false
    @State private var showInstallConfirmation = false
    @State private var showSystemPythonErrorPopover = false
    @State private var isRefreshing = false
    
    var body: some View {
        // SmoothPageScroll (NSScrollView-backed List) for native macOS scroll
        // physics — same pattern as every other screen.
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Dashboard",
                    subtitle: "System status overview",
                    image: "chart.bar.fill",
                    color: .blue
                )

                // Prominent failure banner (P3) — install output only reaches the
                // Logs screen, so this is the dashboard's visible failure signal.
                ErrorBanner(message: $vm.installError)
                    .padding(.horizontal)

                SystemStatusCard(vm: vm, showSystemPythonErrorPopover: $showSystemPythonErrorPopover)

                InstalledPythonsCard(vm: vm)

                InstallPythonCard(vm: vm, showInstallConfirmation: $showInstallConfirmation)

                // Choose the default `python`/`python3`/`pip` for new shells (edits only
                // ~/.zshrc_catalyst). Only meaningful once at least one version is installed.
                if !vm.installedPythons.isEmpty {
                    DefaultPythonCard(vm: vm, manager: vm.pythonDefaultManager)
                }

                if vm.brewStatus == "Installed" || !vm.installedPythons.isEmpty {
                    UninstallCard(
                        vm: vm,
                        showUninstallBrewConfirmation: $showUninstallBrewConfirmation,
                        showUninstallPythonConfirmation: $showUninstallPythonConfirmation
                    )
                }

                if vm.brewStatus == "Installed" {
                    BrewMaintenanceCard(vm: vm)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isRefreshing || vm.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            isRefreshing = true
                            try? await Task.sleep(for: .seconds(1.5))
                            await vm.runDetection(force: true)
                            isRefreshing = false
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
