import SwiftUI
/// A view for browsing and managing installed Homebrew formulae and casks.
///
/// ```swift
/// BrewFormulaeCaskView(viewModel: brewViewModel)
/// ```
struct BrewFormulaeCaskView: View {
    @ObservedObject var viewModel: BrewFormulaeCaskViewModel
    @State private var selectedTab = 0
    @State private var formulaeSearchQuery = ""
    @State private var casksSearchQuery = ""
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "Homebrew Packages",
                    subtitle: "Manage installed Formulae and Casks",
                    image: "mug.fill",
                    color: .orange
                )
                
                if viewModel.isBrewInstalled {
                    /// Warning Box
                    ///
                    /// **Gotchas:** Users regularly uninstall active system dependencies; this banner acts as a vital circuit breaker before destructive operations.
                    BannerView(
                        .warning,
                        message: "Uninstalling packages uses --ignore-dependencies flag. Removing dependencies may break other packages. Use at your own risk."
                    )
                    
                    /// Tab Selector
                    ///
                    /// **Rationale:** Scopes the enormous Homebrew registry into logically discrete segments to prevent user decision paralysis.
                    Picker("", selection: $selectedTab) {
                        Text("Formulae").tag(0)
                        Text("Casks").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    
                    /// Package Lists
                    ///
                    /// **Rationale:** Conditionally switches the data source beneath the common search/filter interface based on the active tab segment.
                    if viewModel.isLoading {
                        LoadingStateView("Loading packages...")
                    } else {
                        if selectedTab == 0 {
                            formulaeCard
                        } else {
                            casksCard
                        }
                    }
                } else {
                    PrerequisiteGateView.brewMissing()
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("Homebrew Packages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarContent(
                    isLoading: viewModel.isLoading,
                    action: { await viewModel.loadInstalledPackages(forceRefresh: true) }
                )
            }
        }
        .task {
            /// Ensure data is loaded if not already
            ///
            /// **Rationale:** Defers network fetching until the exact moment the view appears, preserving bandwidth if the user never opens this specific screen.
            if !viewModel.hasLoadedOnce {
                await viewModel.loadInstalledPackages()
            }
        }
    }
    
    // MARK: - Formulae Card
    
    private var filteredFormulae: [InstalledPackage] {
        if formulaeSearchQuery.isEmpty {
            return viewModel.installedBrewFormulae
        }
        return viewModel.installedBrewFormulae.filter { pkg in
            pkg.name.lowercased().contains(formulaeSearchQuery.lowercased())
        }
    }
    
    private var formulaeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installed Formulae")
                .font(.headline)
            
            SectionDivider()
            
            /// Search Bar
            ///
            /// **Rationale:** Provides rapid inline filtering over potentially thousands of packages without requiring round trips to the backend.
            SearchBarView(placeholder: "Search in formulae...", text: $formulaeSearchQuery)

            SectionDivider()

            if viewModel.installedBrewFormulae.isEmpty {
                EmptyStateView(icon: "tray", message: "No Homebrew formulae installed")
            } else if filteredFormulae.isEmpty {
                EmptyStateView(icon: "magnifyingglass", message: "No formulae match '\(formulaeSearchQuery)'")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredFormulae.enumerated()), id: \.element.name) { index, pkg in
                        InstalledPackageRow(
                            name: pkg.name,
                            version: nil,
                            isAlternate: index % 2 == 1,
                            isProcessing: viewModel.processingPackages.contains(pkg.name),
                            onUninstall: {
                                Task {
                                    await viewModel.uninstallBrewFormula(pkg.name)
                                }
                            }
                        )
                        .equatable()
                    }
                }
            }
        }
        .cardStyle()
    }
    
    // MARK: - Casks Card
    
    private var filteredCasks: [InstalledPackage] {
        if casksSearchQuery.isEmpty {
            return viewModel.installedBrewCasks
        }
        return viewModel.installedBrewCasks.filter { pkg in
            pkg.name.lowercased().contains(casksSearchQuery.lowercased())
        }
    }
    
    private var casksCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installed Casks")
                .font(.headline)
            
            SectionDivider()
            
            /// Search Bar
            ///
            /// **Rationale:** Mirrors the formulae search interface exactly to maintain cognitive consistency across tabs.
            SearchBarView(placeholder: "Search in casks...", text: $casksSearchQuery)

            SectionDivider()
            
            if viewModel.installedBrewCasks.isEmpty {
                EmptyStateView(icon: "tray", message: "No Homebrew casks installed")
            } else if filteredCasks.isEmpty {
                EmptyStateView(icon: "magnifyingglass", message: "No casks match '\(casksSearchQuery)'")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredCasks.enumerated()), id: \.element.name) { index, pkg in
                        InstalledPackageRow(
                            name: pkg.name,
                            version: nil,
                            isAlternate: index % 2 == 1,
                            isProcessing: viewModel.processingPackages.contains(pkg.name),
                            onUninstall: {
                                Task {
                                    await viewModel.uninstallBrewCask(pkg.name)
                                }
                            }
                        )
                        .equatable()
                    }
                }
            }
        }
        .cardStyle()
    }
}
