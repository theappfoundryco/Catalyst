//
//  PIPPackagesInstallView.swift
//  Catalyst
//
//  Created by Shivang Gulati on 28/01/26.
//

import SwiftUI
import Combine

struct PIPPackagesInstallView: View {
    @ObservedObject var vm: PIPPackagesInstallViewModel
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "pip Packages",
                    subtitle: "Search and install from 730,000+ Python packages",
                    image: "shippingbox.fill",
                    color: .blue
                )
                
                if vm.isPythonWithPipAvailable {
                    if !vm.availablePythonVersions.isEmpty {
                        SelectPythonVersionDropdown(
                            selection: $vm.selectedPythonVersion,
                            availableVersions: vm.availablePythonVersions,
                            onSelectionChange: {
                                await vm.loadInstalledPackages()
                            },
                            installCommandTemplate: "pip install <package>"
                        )
                    }
                    
                    // Package Browser Card
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Search Packages")
                                .font(.headline)
                            
                            Spacer()
                            
                            if !vm.searchResults.isEmpty {
                                Text("\(vm.searchResults.count) packages")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        VStack(spacing: 8) {
                            SearchBarView(placeholder: "Enter package name (e.g., requests, numpy)...", text: $vm.searchQuery) {
                                Task { await vm.searchPackages() }
                            }
                            
                            SectionDivider()
                        }
                        
                        // Results Area
                        if vm.isSearching {
                            LoadingStateView("Searching...")
                        } else if vm.hasSearched && vm.searchResults.isEmpty {
                            EmptyStateView(icon: "magnifyingglass", message: "No packages found")
                        } else if !vm.searchResults.isEmpty {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(vm.searchResults.enumerated()), id: \.element) { index, package in
                                        InstallablePackageRow(
                                            name: package,
                                            isAlternate: index % 2 == 1,
                                            isInstalling: vm.installingPackage == package,
                                            isInstalled: vm.installedPackages.contains(package.lowercased()),
                                            canInstall: vm.isPythonWithPipAvailable,
                                            onInstall: {
                                                Task { await vm.installPackage(package) }
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
                    ErrorBanner(message: $vm.installError)
                        .padding(.horizontal)

                    // Installation Output (isolated observable — see ConsoleOutput, R2)
                    ConsoleOutputView(console: vm.console)
                } else {
                    PrerequisiteGateView.pythonMissing()
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("pip Packages")
        .task {
            await vm.loadPythonVersions()
            await vm.checkPrerequisites()
            await vm.loadInstalledPackages()
        }
    }
}



