import SwiftUI
import Combine

struct PIPPackagesView: View {
    @ObservedObject var viewModel: PIPPackagesViewModel
    @State private var pipSearchQuery = ""
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "pip Packages",
                    subtitle: "Manage installed Python packages",
                    image: "shippingbox.fill",
                    color: .blue
                )
                
                if !viewModel.availablePythonVersions.filter({ $0.pipAvailable }).isEmpty {
                    if !viewModel.availablePythonVersions.isEmpty {
                        SelectPythonVersionDropdown(
                            selection: $viewModel.selectedPythonVersion,
                            availableVersions: viewModel.availablePythonVersions.filter { $0.pipAvailable },
                            onSelectionChange: {
                                // Action handled by ViewModel observation or no action needed
                            },
                            warningBanners: [
                                (title: nil, message: "Uninstalling packages uses --ignore-dependencies flag. Removing dependencies may break other packages. Use at your own risk.")
                            ]
                        )
                    }
                
                // Package Lists
                if viewModel.isLoading {
                    LoadingStateView("Loading packages...")
                } else {
                    pipPackagesCard
                }
                } else {
                    PrerequisiteGateView.pythonMissing()
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("Installed pip Packages")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarContent(
                    isLoading: viewModel.isLoading,
                    action: { await viewModel.loadInstalledPackages(forceRefresh: true) }
                )
            }
        }
        .task {
            // Ensure data is loaded
             if !viewModel.hasLoadedOnce {
                await viewModel.loadInstalledPackages()
            }
        }
        .onChange(of: viewModel.selectedPythonVersion) { _, _ in
            Task { await viewModel.loadPipPackagesForSelectedPython() }
        }
    }
    
    // MARK: - pip Packages Card
    
    private var filteredPipPackages: [InstalledPackage] {
        if pipSearchQuery.isEmpty {
            return viewModel.installedPipPackages
        }
        return viewModel.installedPipPackages.filter { pkg in
            pkg.name.lowercased().contains(pipSearchQuery.lowercased())
        }
    }
    
    private var pipPackagesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Installed pip Packages")
                .font(.headline)
            
            SectionDivider()
            
            VStack(spacing: 8) {
                SearchBarView(placeholder: "Search in pip packages...", text: $pipSearchQuery)

                SectionDivider()
            }
            
            if viewModel.installedPipPackages.isEmpty {
                EmptyStateView(icon: "tray", message: "No pip packages installed")
            } else if filteredPipPackages.isEmpty {
                EmptyStateView(icon: "magnifyingglass", message: "No packages match '\(pipSearchQuery)'")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredPipPackages.enumerated()), id: \.element.name) { index, pkg in
                        InstalledPackageRow(
                            name: pkg.name,
                            version: pkg.version,
                            isAlternate: index % 2 == 1,
                            isProcessing: viewModel.processingPackages.contains(pkg.name),
                            onUninstall: {
                                Task {
                                    await viewModel.uninstallPipPackage(pkg.name)
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


