import SwiftUI
/// A view for discovering and applying updates to installed Homebrew formulae and casks.
///
/// ```swift
/// OutdatedBrewView(vm: outdatedBrewViewModel)
/// ```
struct OutdatedBrewView: View {
    @ObservedObject var vm: OutdatedBrewViewModel
    @State private var selectedFilter: BrewFilter = .all
    
    /// Controls the active subset view of outdated Homebrew packages.
    enum BrewFilter: String, CaseIterable {
        case all = "All"
        case formula = "Formulae"
        case cask = "Casks"
    }
    
    /// Filtered to only show brew packages (formula + cask)
    var brewPackages: [OutdatedPackage] {
        vm.outdatedPackages.filter { $0.type == .brewFormula || $0.type == .brewCask }
    }
    
    var filteredPackages: [OutdatedPackage] {
        switch selectedFilter {
        case .all:
            return brewPackages
        case .formula:
            return vm.outdatedPackages.filter { $0.type == .brewFormula }
        case .cask:
            return vm.outdatedPackages.filter { $0.type == .brewCask }
        }
    }
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "Homebrew Updates",
                    subtitle: "Update formulae and casks",
                    image: "mug.fill",
                    color: .orange
                )
                
                if vm.isBrewAvailable {
                    BannerView(
                        .info,
                        title: "Homebrew Update Information",
                        message: "• Uses brew upgrade for formulae and casks\n• Some casks may require manual updates"
                    )

                    // Pre-scan Info Box (only show before first scan)
                    if !vm.hasScannedOnce && !vm.isLoading {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                Task { await vm.checkForBrewUpdates() }
                            } label: {
                                Label("Scan for Updates", systemImage: "arrow.clockwise")
                                    .labelStyle(.matched)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }
                            .appButton(.primary)
                            .tint(.orange)
                        }
                        .padding(.horizontal)
                    }
                
                // Filter Picker
                if vm.hasScannedOnce && !vm.isLoading && !brewPackages.isEmpty {
                    Picker("", selection: $selectedFilter) {
                        ForEach(BrewFilter.allCases, id: \.self) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                
                // Update All Button
                if vm.hasScannedOnce && !vm.isLoading && !filteredPackages.isEmpty {
                    Button {
                        Task { await vm.updateFiltered(filteredPackages) }
                    } label: {
                        Label("Update \(selectedFilter.rawValue) (\(filteredPackages.count))", systemImage: "arrow.up.circle.fill")
                            .labelStyle(.matched)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .appButton(.primary)
                    .tint(.orange)
                    .disabled(vm.isUpdatingAll)
                    .padding(.horizontal)
                }
                
                // Scanning Progress
                if vm.isLoading {
                    LoadingStateView("Scanning for updates...", verticalPadding: 60)
                        .cardStyle()
                }
                
                // Results: No updates for filter
                if vm.hasScannedOnce && !vm.isLoading && filteredPackages.isEmpty && !brewPackages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        
                        Text("No \(selectedFilter.rawValue) updates!")
                            .font(.headline)
                        
                        Text("All \(selectedFilter.rawValue.lowercased()) are up to date")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .cardStyle()
                }
                
                if vm.hasScannedOnce && !vm.isLoading && brewPackages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        
                        Text("All Homebrew packages are up to date!")
                            .font(.headline)
                        
                        Text("No updates available at this time")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .cardStyle()
                }
                
                // Results: Outdated packages list
                if vm.hasScannedOnce && !vm.isLoading && !filteredPackages.isEmpty { // Targets Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Targets")
                            .font(.headline)
                        
                        SectionDivider()
                        
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredPackages.enumerated()), id: \.element.name) { index, package in
                                OutdatedPackageRow(
                                    package: package,
                                    isAlternate: index % 2 == 1,
                                    isUpdating: vm.updatingPackage == package.name,
                                    isFailed: vm.failedPackages.contains(where: { $0.name == package.name }),
                                    onUpdate: {
                                        Task { await vm.updatePackage(package.name, type: package.type) }
                                    }
                                )
                                .equatable()
                            }
                        }
                    }
                    .cardStyle()
                }
                
                // Update Results Summary Card (shows after batch update)
                if vm.showUpdateResults && (vm.successfulPackages.count > 0 || vm.failedPackages.count > 0) {
                    // Only show brew-related results
                    let brewSuccessful = vm.successfulPackages.filter { $0.type == .brewFormula || $0.type == .brewCask }
                    let brewFailed = vm.failedPackages.filter { $0.type == .brewFormula || $0.type == .brewCask }
                    
                    if !brewSuccessful.isEmpty || !brewFailed.isEmpty {
                        UpdateResultsSummaryCard(
                            successfulPackages: brewSuccessful,
                            failedPackages: brewFailed,
                            onDismiss: { vm.showUpdateResults = false },
                            onRetry: { name, pkg in
                                Task { await vm.updatePackage(pkg.name, type: pkg.type) }
                            }
                        )
                    }
                }
                } else {
                    PrerequisiteGateView.brewMissing()
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("Brew Updates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.hasScannedOnce {
                    Button {
                        Task { await vm.checkForBrewUpdates() }
                    } label: {
                        Label("Scan Again", systemImage: "arrow.clockwise")
                    }
                    .disabled(vm.isLoading || vm.isUpdatingAll || vm.updatingPackage != nil || !vm.isBrewAvailable)
                }
            }
        }
    }
}
