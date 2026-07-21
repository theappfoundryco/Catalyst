//
//  RequirementsView.swift
//  Catalyst
//
//  Created by Shivang Gulati on 28/01/26.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

struct RequirementsView: View {
    @ObservedObject var vm: RequirementsViewModel
    /// Observed so the Install button re-enables the instant the global install
    /// mode changes (the gate reads `InstallPreferences.shared.mode`).
    @ObservedObject private var installPrefs = InstallPreferences.shared

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 20) {
                
                MasterHeaderView(
                    title: "Requirements Installer",
                    subtitle: "Install packages from requirements.txt to Global Python",
                    image: "doc.text.fill",
                    color: .purple
                )
                
                // File Upload Section
                VStack(alignment: .leading, spacing: 16) {
                    Text("Upload Requirements File")
                        .font(.headline)
                    
                    SectionDivider()
                    
                    if let fileURL = vm.selectedFileURL {
                        // File selected
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundColor(.purple)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fileURL.lastPathComponent)
                                    .font(.subheadline.weight(.medium))
                                Text(fileURL.path)
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button {
                                vm.removeFile()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .disabled(vm.isInstalling)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.purple.opacity(0.1))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(Color.purple.opacity(0.3), lineWidth: 1)
                                )
                        )
                        
                        // File Preview
                        if !vm.fileContents.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("File Contents (\(vm.packageCount) packages)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                ScrollView {
                                    Text(vm.fileContents)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 150)
                                .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
                                .codePanel()
                            }
                        }
                    } else {
                        // No file selected
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.doc")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            
                            Text("No file selected")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Button {
                                vm.selectFile()
                            } label: {
                                Label("Select requirements.txt", systemImage: "folder")
                                    .labelStyle(.matched)
                            }
                            .tint(.purple)
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .cardStyle()
                
                // Python Version Selection
                if vm.selectedFileURL != nil {
                    if vm.availablePythonVersions.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 30))
                                .foregroundColor(.orange)
                            
                            Text("No Python versions installed")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            Text("Install Python from the Dashboard first")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .cardStyle()
                    } else {
                        SelectPythonVersionDropdown(
                            selection: $vm.selectedPythonVersion,
                            availableVersions: vm.availablePythonVersions,
                            onSelectionChange: {
                                // No async action needed on change here, VM handles selection
                            },
                            installCommandTemplate: "pip install -r requirements.txt",
                            systemPythonVersion: vm.systemPythonVersion,
                            isSystemPython: vm.isSystemPython
                        )
                    }
                }
                    
                // Install Button
                if vm.selectedFileURL != nil && vm.selectedPythonVersion != nil {
                    Button {
                        Task { await vm.installPackages() }
                    } label: {
                        Group {
                            if vm.isInstalling {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Installing Packages...")
                                }
                            } else {
                                Label("Install All Packages", systemImage: "arrow.down.circle.fill")
                                    .labelStyle(.matched)
                            }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(vm.isInstallDisabled)
                    .padding(.horizontal)

                    // Inline reason when the button is blocked purely because
                    // Python 3.12+ is externally managed and mode is Protected.
                    if vm.isBlockedByProtectedMode {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .foregroundColor(.secondary)
                            Text("This Python is externally managed. Choose an Install mode override above to install.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    }
                }
                
                // Verification Status Card
                if vm.verificationComplete {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: vm.failedPackages.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.title2)
                                .foregroundColor(vm.failedPackages.isEmpty ? .green : .orange)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(vm.failedPackages.isEmpty ? "Installation Successful" : "Installation Partially Completed")
                                    .font(.headline)
                                
                                // Counts only — status icon lives in the header,
                                // so we don't repeat a second green checkmark.
                                HStack(spacing: 6) {
                                    Text("\(vm.successfulPackages.count) installed")
                                    if !vm.failedPackages.isEmpty {
                                        Text("·")
                                        Text("\(vm.failedPackages.count) failed")
                                            .foregroundColor(.red)
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                        
                        if !vm.failedPackages.isEmpty {
                            SectionDivider()
                            
                            // Failed Packages List
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Failed Packages")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(.red)
                                
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 4) {
                                        ForEach(vm.failedPackages, id: \.self) { package in
                                            HStack(spacing: 8) {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundColor(.red)
                                                    .font(.caption)
                                                
                                                Text(package)
                                                    .font(.caption.monospaced())
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 100)
                                .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.red.opacity(0.05))
                                )
                                
                                // Action Buttons
                                HStack(spacing: 12) {
                                    Button {
                                        Task { await vm.retryFailedPackages() }
                                    } label: {
                                        Label("Retry Failed", systemImage: "arrow.clockwise")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(vm.isInstallDisabled)
                                    
                                    Button {
                                        vm.exportFailedPackages()
                                    } label: {
                                        Label("Export List", systemImage: "square.and.arrow.up")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        
                        // Successful packages (collapsible)
                        if !vm.successfulPackages.isEmpty {
                            ResultDisclosureGroup(
                                title: "Successful Packages (\(vm.successfulPackages.count))",
                                packages: vm.successfulPackages,
                                status: .success,
                                onDismiss: {
                                    vm.successfulPackages = []
                                    vm.failedPackages = []
                                    vm.verificationComplete = false
                                },
                                maxHeight: 150
                            )
                        }
                    }
                    .cardStyle()
                }
                
                // Prominent failure banner (P3), above the streamed log.
                ErrorBanner(message: $vm.installError)
                    .padding(.horizontal)

                // Installation Output (isolated observable — see ConsoleOutput, R2)
                ConsoleOutputView(console: vm.console, title: "Installation Log")
                
                Spacer()
            }
                .padding(.vertical)
        }
        .navigationTitle("Requirements")
        .task {
            await vm.loadPythonVersions()
        }
    }
}
