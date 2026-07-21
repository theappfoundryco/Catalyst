import SwiftUI
import Combine

struct FormulaeCaskInstallView: View {
    enum InstallType {
        case formulae
        case casks
    }
    
    @Binding var selectedTab: InstallType
    
    // ViewModels
    @ObservedObject var viewModel: FormulaeCaskInstallViewModel
    
    // Internal state for initialization matching logic
    @State private var currentTab: InstallType
    
    init(viewModel: FormulaeCaskInstallViewModel, initialType: InstallType = .formulae) {
        _selectedTab = Binding.constant(initialType)
        _currentTab = State(initialValue: initialType)
        self.viewModel = viewModel
    }

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "Homebrew Packages",
                    subtitle: "Search and install command-line tools and applications",
                    image: "mug.fill",
                    color: .orange
                )
                if viewModel.isBrewInstalled {
                    // Tab Selector
                    Picker("", selection: $currentTab) {
                        Text("Homebrew Formulae").tag(InstallType.formulae)
                        Text("Homebrew Casks").tag(InstallType.casks)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .onChange(of: currentTab) { newValue in
                        // Trigger search again for new tab if query exists
                        if !viewModel.searchQuery.isEmpty {
                            viewModel.search(type: newValue)
                        }
                    }
                    
                    // Content
                    if currentTab == .formulae {
                        formulaeContent
                    } else {
                        casksContent
                    }
                } else {
                    PrerequisiteGateView.brewMissing()
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle(currentTab == .formulae ? "Homebrew Formulae" : "Homebrew Casks")
        .task {
            // Load all data parallel
            await viewModel.loadAllData()
        }
    }
    
    // MARK: - Formulae Content
    
    private var formulaeContent: some View {
        VStack(spacing: 20) {
            // Formula Browser Card
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Search Formulae")
                        .font(.headline)
                    
                    Spacer()
                    
                    if !viewModel.formulaeSearchResults.isEmpty {
                        Text("\(viewModel.formulaeSearchResults.count) results")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                VStack(spacing: 8) {
                    SearchBarView(placeholder: "Enter formula name (e.g., git, node, python)...", text: $viewModel.searchQuery) {
                        viewModel.search(type: .formulae)
                    }
                    
                    SectionDivider()
                }
                
                // Results Area
                if viewModel.isSearching {
                    LoadingStateView("Searching...")
                } else if viewModel.hasSearched && viewModel.formulaeSearchResults.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", message: "No formulae found")
                } else if !viewModel.formulaeSearchResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.formulaeSearchResults.enumerated()), id: \.element) { index, formula in
                                InstallablePackageRow(
                                    name: formula,
                                    isAlternate: index % 2 == 1,
                                    isInstalling: viewModel.installingPackage == formula,
                                    isInstalled: viewModel.installedFormulae.contains(formula.lowercased()),
                                    canInstall: viewModel.isBrewInstalled,
                                    onInstall: {
                                        Task { await viewModel.install(package: formula, type: .formulae) }
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                    .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
                } else {
                    // Initial State
                    EmptyStateView(icon: "magnifyingglass", message: "Search using the bar above")
                }
            }
            .cardStyle()
            
            // Prominent failure banner (P3), above the streamed log.
            ErrorBanner(message: $viewModel.installError)
                .padding(.horizontal)

            // Installation Output
            ConsoleOutputView(console: viewModel.console)
        }
    }
    
    // MARK: - Casks Content
    
    private var casksContent: some View {
        VStack(spacing: 20) {
            // Cask Browser Card
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Search Casks")
                        .font(.headline)
                    
                    Spacer()
                    
                    if !viewModel.caskSearchResults.isEmpty {
                        Text("\(viewModel.caskSearchResults.count) results")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                VStack(spacing: 8) {
                    SearchBarView(placeholder: "Enter app name (e.g., google-chrome, spotify)...", text: $viewModel.searchQuery) {
                        viewModel.search(type: .casks)
                    }
                    
                    SectionDivider()
                }
                
                // Results Area
                if viewModel.isSearching {
                    LoadingStateView("Searching...")
                } else if viewModel.hasSearched && viewModel.caskSearchResults.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", message: "No casks found")
                } else if !viewModel.caskSearchResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(viewModel.caskSearchResults.enumerated()), id: \.element) { index, cask in
                                InstallablePackageRow(
                                    name: cask,
                                    isAlternate: index % 2 == 1,
                                    isInstalling: viewModel.installingPackage == cask,
                                    isInstalled: viewModel.installedCasks.contains(cask.lowercased()),
                                    canInstall: viewModel.isBrewInstalled,
                                    onInstall: {
                                        Task { await viewModel.install(package: cask, type: .casks) }
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 400)
                    .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
                } else {
                    // Initial State
                    EmptyStateView(icon: "magnifyingglass", message: "Search using the bar above")
                }
            }
            .cardStyle()
            
            // Prominent failure banner (P3), above the streamed log.
            ErrorBanner(message: $viewModel.installError)
                .padding(.horizontal)

            // Installation Output
            ConsoleOutputView(console: viewModel.console)
        }
    }
    
}


