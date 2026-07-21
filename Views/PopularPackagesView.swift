import SwiftUI

struct PopularPackagesView: View {
    @ObservedObject var vm: PopularPackagesViewModel
    @State private var selectedTab = 0

    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                
                MasterHeaderView(
                    title: "Popular Packages",
                    subtitle: "50 Most downloaded and trending packages",
                    image: "star.fill",
                    color: .yellow
                )
                // Tab Selector
                Picker("", selection: $selectedTab) {
                    Text("pip Packages").tag(0)
                    Text("Homebrew Formulae").tag(1)
                    Text("Homebrew Casks").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                // Gate per-tab: show PrerequisiteGateView if prerequisite missing
                if selectedTab == 0 && !vm.isPythonWithPipAvailable {
                    PrerequisiteGateView.pythonMissing()
                } else if (selectedTab == 1 || selectedTab == 2) && !vm.isBrewInstalled {
                    PrerequisiteGateView.brewMissing()
                } else {
                    // Python Version Selection (only show for pip tab)
                    if selectedTab == 0 && !vm.availablePythonVersions.isEmpty {
                        SelectPythonVersionDropdown(
                            selection: $vm.selectedPythonVersion,
                            availableVersions: vm.availablePythonVersions
                        ) {
                            await vm.loadPipPackagesForSelectedPython()
                        }
                    }
                    
                    // Package Lists
                    if vm.isLoading {
                        LoadingStateView("Loading popular packages...")
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(selectedTab == 0 ? "Top pip Packages" : selectedTab == 1 ? "Top Homebrew Formulae" : "Top Homebrew Casks")
                                .font(.headline)
                            
                            SectionDivider()
                            
                            LazyVStack(spacing: 0) {
                                ForEach(Array(currentPackages().enumerated()), id: \.element.name) { index, package in
                                    PopularPackageRow(
                                        package: package,
                                        rank: index + 1,
                                        isAlternate: index % 2 == 1,
                                        isInstalled: vm.isInstalled(package.name, type: currentType()),
                                        isInstalling: vm.installingPackage == package.name,
                                        canInstall: currentType() == .pip ? vm.isPythonWithPipAvailable : vm.isBrewInstalled,
                                        onInstall: {
                                            Task { await vm.installPackage(package.name, type: currentType()) }
                                        }
                                    )
                                    .equatable()
                                }
                            }
                        }
                        .cardStyle()
                    }
                    
                    // Prominent failure banner (P3), above the streamed log.
                    ErrorBanner(message: $vm.installError)
                        .padding(.horizontal)

                    // Installation Output (isolated observable — see ConsoleOutput, R2)
                    ConsoleOutputView(console: vm.console)
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("Popular")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarContent(
                    isLoading: vm.isLoading,
                    action: { await vm.refresh(forceRefresh: true) }
                )
            }
        }
        .task {
            await vm.checkPrerequisites()
            await vm.loadPopularPackages()
            await vm.loadInstalledPackages()
        }
    }
    
    private func currentPackages() -> [PopularPackage] {
        switch selectedTab {
        case 0: return vm.popularPip
        case 1: return vm.popularFormulae
        case 2: return vm.popularCasks
        default: return []
        }
    }
    
    private func currentType() -> PackageType {
        switch selectedTab {
        case 0: return .pip
        case 1: return .brewFormula
        case 2: return .brewCask
        default: return .pip
        }
    }
}
