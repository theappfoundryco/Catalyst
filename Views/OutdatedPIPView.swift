import SwiftUI
// OutdatedPIPView
/// A view for managing and applying updates to outdated Python packages via pip.
///
/// ```swift
/// OutdatedPIPView(vm: pipViewModel)
/// ```
struct OutdatedPIPView: View {
    @ObservedObject var vm: OutdatedPIPViewModel
    @State private var isRefreshing = false
    
    /// Filtered to only show pip packages
    var pipPackages: [OutdatedPackage] {
        vm.outdatedPackages.filter { $0.type == .pip }
    }
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "pip Updates",
                    subtitle: "Manage outdated pip packages",
                    image: "shippingbox.fill",
                    color: .blue
                )
                
                if !vm.availablePythonVersions.isEmpty {
                    // Python Version Selector
                    VStack(spacing: 6) {
                        SelectPythonVersionDropdown(
                            selection: $vm.selectedPythonVersion,
                            availableVersions: vm.availablePythonVersions,
                            onSelectionChange: {
                                // Action handled by ViewModel or triggered manually by scan button
                            },
                            infoBannerTitle: "pip Update Information",
                            infoBannerMessage: "• Uses pip install --upgrade for Python packages\n• Only versions installable on the selected Python are shown"
                        )
                    }
                    // Pre-scan Info Box (hidden once scanning starts, matching Brew)
                    if !vm.hasScannedOnce && !vm.isLoading {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                Task { await vm.checkForPipUpdates(force: true) }
                            } label: {
                                Label("Scan for Updates", systemImage: "arrow.clockwise")
                                    .labelStyle(.matched)
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding()
                            }
                            .appButton(.primary)
                            .tint(.blue)
                        }
                        .padding(.horizontal)
                    }
                
                // Update All Button
                if vm.hasScannedOnce && !vm.isLoading && !pipPackages.isEmpty {
                    Button {
                        Task { await vm.updateFiltered(pipPackages) }
                    } label: {
                        Label("Update All (\(pipPackages.count))", systemImage: "arrow.up.circle.fill")
                            .labelStyle(.matched)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .appButton(.primary)
                    .disabled(vm.isUpdatingAll)
                    .padding(.horizontal)
                }
                
                // Scanning Progress
                if vm.isLoading {
                    LoadingStateView("Scanning for updates...", verticalPadding: 60)
                        .cardStyle()
                }
                
                if vm.hasScannedOnce && !vm.isLoading && pipPackages.isEmpty && !vm.availablePythonVersions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        
                        Text("All pip packages are up to date!")
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
                if vm.hasScannedOnce && !vm.isLoading && !pipPackages.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Outdated Pip Packages")
                            .font(.headline)
                        
                        SectionDivider()
                        
                        LazyVStack(spacing: 0) {
                            ForEach(Array(pipPackages.enumerated()), id: \.element.name) { index, package in
                                OutdatedPackageRow(
                                    package: package,
                                    isAlternate: index % 2 == 1,
                                    isUpdating: vm.updatingPackage == package.name,
                                    isFailed: vm.failedPackages.contains(where: { $0.name == package.name }),
                                    isHeldBack: vm.heldBackPackages.contains(where: { $0.name == package.name }),
                                    heldBackReason: vm.heldBackReasons[package.name],
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
                if vm.showUpdateResults && (vm.successfulPackages.count > 0 || vm.failedPackages.count > 0 || vm.heldBackPackages.count > 0) {
                    // Only show pip-related results
                    let pipSuccessful = vm.successfulPackages.filter { $0.type == .pip }
                    let pipFailed = vm.failedPackages.filter { $0.type == .pip }
                    let pipHeldBack = vm.heldBackPackages.filter { $0.type == .pip }

                    if !pipSuccessful.isEmpty || !pipFailed.isEmpty || !pipHeldBack.isEmpty {
                        UpdateResultsSummaryCard(
                            successfulPackages: pipSuccessful,
                            failedPackages: pipFailed,
                            heldBackPackages: pipHeldBack,
                            heldBackReasons: vm.heldBackReasons,
                            onDismiss: { vm.showUpdateResults = false },
                            onRetry: { name, pkg in
                                Task { await vm.updatePackage(pkg.name, type: pkg.type) }
                            }
                        )
                    }
                }
                } else {
                    PrerequisiteGateView.pythonMissing()
                }
                
                Spacer()
            }
        }
            .padding(.vertical)
        .navigationTitle("pip Updates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.hasScannedOnce {
                    if isRefreshing || vm.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            Task {
                                isRefreshing = true
                                // try? await Task.sleep(for: .seconds(1.5))
                                await vm.checkForPipUpdates(force: true)
                                isRefreshing = false
                            }
                        } label: {
                            Label("Scan Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(vm.isUpdatingAll || vm.updatingPackage != nil || vm.availablePythonVersions.isEmpty)
                    }
                }
            }
        }
        .task {
            await vm.loadPythonVersions()
        }
        .onChange(of: vm.selectedPythonVersion) { _, _ in
            // Clear results when Python version changes
            vm.showUpdateResults = false
            vm.successfulPackages = []
            vm.failedPackages = []
            vm.heldBackPackages = []
            vm.heldBackReasons = [:]
            if vm.hasScannedOnce {
                Task { await vm.checkForPipUpdates() }
            }
        }
    }
}
