//
//  RequirementsViewModel.swift
//  Catalyst
//
//  Created by Shivang Gulati on 28/01/26.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
final class RequirementsViewModel: ObservableObject {
    @Published var selectedFileURL: URL?
    @Published var fileContents: String = ""
    @Published var availablePythonVersions: [PythonInstallation] = []
    @Published var selectedPythonVersion: PythonInstallation?
    @Published var isInstalling = false
    /// Install/verify log on its own observable so appends re-render only the
    /// console, not the parsed-requirements list (R2). Bridge keeps `+=` sites.
    let console = ConsoleOutput()
    var installationOutput: String {
        get { console.text }
        set { console.set(newValue) }
    }
    @Published var failedPackages: [String] = []
    @Published var successfulPackages: [String] = []
    @Published var isVerifying = false
    @Published var verificationComplete = false
    @Published var systemPythonVersion: String? = nil
    /// Short, user-facing error surfaced as a banner when the install command
    /// itself fails (P3). Per-package failures use the `failedPackages` UI.
    @Published var installError: String?

    private var allRequestedPackages: [String] = []
    private let pythonService: PythonService
    private let logger: Logger
    
    var packageCount: Int {
        fileContents.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
            .count
    }
    
    init(pythonService: PythonService, logger: Logger) {
        self.pythonService = pythonService
        self.logger = logger
    }
    
    func reset() async {
        isInstalling = false
        isVerifying = false
        verificationComplete = false
        await loadPythonVersions()
    }
    
    func loadPythonVersions() async {
        logger.log("🔍 Loading Python versions...")
        
        // 1. Detect System Python first
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "/usr/bin/python3 --version")
            if result.succeeded {
                if let version = result.combinedOutput.components(separatedBy: " ").dropFirst().first {
                    self.systemPythonVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } catch {
            // Ignore if missing, defaulting to nil
        }
        
        do {
            let pythons = try await pythonService.detectPythons()
            availablePythonVersions = pythons.filter { $0.pipAvailable }
            logger.log("✅ Found \(availablePythonVersions.count) Python versions with pip")
            
            // Auto-select first version if available
            if selectedPythonVersion == nil {
                selectedPythonVersion = availablePythonVersions.first
            }
        } catch {
            logger.log("❌ Failed to load Python versions: \(error.localizedDescription)")
            availablePythonVersions = []
        }
    }
    
    // Check if the selected Python is System Python
    func isSystemPython(for python: PythonInstallation) -> Bool {
        guard let systemVersion = systemPythonVersion else { return false }
        
        let systemComponents = systemVersion.split(separator: ".")
        let installedComponents = python.version.split(separator: ".")
        
        guard systemComponents.count >= 2, installedComponents.count >= 2 else { return false }
        
        let systemMajorMinor = systemComponents.prefix(2).joined(separator: ".")
        let installedMajorMinor = installedComponents.prefix(2).joined(separator: ".")
        
        return systemMajorMinor == installedMajorMinor
    }
    
    // Check if Python requires --break-system-packages (Python 3.12+)
    func requiresBreakSystemPackages(_ python: PythonInstallation) -> Bool {
        VersionComparator.requiresBreakSystemPackages(pythonVersion: python.version)
    }
    
    // Helper to check if install should be disabled.
    //
    // On an externally-managed interpreter (3.12+) we only block when the global
    // install mode is Protected — that's the futile state where pip would refuse
    // to write and add no override flag. Enabling a User space / System-wide
    // override makes the install possible again, so the button re-enables.
    var isInstallDisabled: Bool {
        guard let python = selectedPythonVersion else { return true }
        if isInstalling { return true }
        return requiresBreakSystemPackages(python) && InstallPreferences.shared.mode == .protected
    }

    /// True when the action is blocked purely by Protected mode on a 3.12+
    /// interpreter (drives the inline "enable an override" hint). Distinct from
    /// `isInstallDisabled`, which is also true mid-install.
    var isBlockedByProtectedMode: Bool {
        guard let python = selectedPythonVersion else { return false }
        return requiresBreakSystemPackages(python) && InstallPreferences.shared.mode == .protected
    }
    
    func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.text, .plainText]
        panel.message = "Select requirements.txt or any text file with package names"
        panel.prompt = "Select"
        
        panel.begin { [weak self] response in
            guard let self = self else { return }
            
            if response == .OK, let url = panel.url {
                Task { @MainActor in
                    self.selectedFileURL = url
                    self.loadFileContents(url)
                }
            }
        }
    }
    
    func removeFile() {
        selectedFileURL = nil
        fileContents = ""
        installationOutput = ""
        successfulPackages = []
        failedPackages = []
    }
    
    private func loadFileContents(_ url: URL) {
        do {
            let contents = try String(contentsOf: url, encoding: .utf8)
            fileContents = contents
            logger.log("✅ Loaded file: \(url.lastPathComponent) (\(packageCount) packages)")
        } catch {
            logger.log("❌ Failed to read file: \(error.localizedDescription)")
            fileContents = ""
        }
    }
    
    func installPackages() async {
        guard let fileURL = selectedFileURL,
              let python = selectedPythonVersion else {
            return
        }
        
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("    📦 REQUIREMENTS INSTALLATION", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        
        // Reset state
        isInstalling = true
        installationOutput = ""
        failedPackages = []
        successfulPackages = []
        verificationComplete = false
        installError = nil
        
        // Parse requested packages
        allRequestedPackages = parsePackageNames(from: fileContents)
        
        logger.log("📦 Installing \(allRequestedPackages.count) packages from \(fileURL.lastPathComponent)")
        installationOutput += "📦 Installing \(allRequestedPackages.count) packages...\n\n"
        
        let flags = InstallPreferences.pipFlags(forPythonVersion: python.version)
        let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip install -r \(InputSanitizer.sanitizeFilePath(fileURL.path)) \(flags)"
        
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { text in
                self.installationOutput += text
                self.logger.log(text, category: .terminal)
            }
            
            if exitCode == 0 {
                logger.log("✅ Installation command completed")
                installationOutput += "\n\n✅ Installation command completed\n"
            } else {
                logger.log("⚠️ Installation completed with errors (exit code \(exitCode))")
                installationOutput += "\n\n⚠️ Installation completed with errors\n"
            }
            
            // Verify installation regardless of exit code
            installationOutput += "\n🔍 Verifying installed packages...\n"
            await verifyInstallation(python: python)
            
        } catch {
            logger.log("❌ Installation error: \(error.localizedDescription)")
            installationOutput += "\n\n❌ Error: \(error.localizedDescription)"
            installError = "Failed to install requirements: \(error.localizedDescription)"
        }

        isInstalling = false
    }

    func clearOutput() {
        installationOutput = ""
    }
    
    private func parsePackageNames(from contents: String) -> [String] {
        contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                // Extract package name from "package==version" or "package>=version" etc.
                let packageName = line.components(separatedBy: CharacterSet(charactersIn: "=<>!~")).first ?? line
                return normalizePackageName(packageName.trimmingCharacters(in: .whitespaces))
            }
    }
    
    private func normalizePackageName(_ name: String) -> String {
        // Normalize according to PEP 503: lowercase and replace [-_.] with single dash
        name.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func verifyInstallation(python: PythonInstallation) async {
        isVerifying = true
        
        let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip list --format=freeze"
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            
            if !result.succeeded {
                logger.log("❌ Failed to verify installations")
                installationOutput += "❌ Verification failed\n"
                isVerifying = false
                return
            }
            
            let output = result.stdout
            
            // Get installed package names (normalized)
            let installedPackages = Set(output.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: "=")
                guard let packageName = parts.first else { return nil }
                return normalizePackageName(String(packageName))
            })
            
            // Check each requested package
            for package in allRequestedPackages {
                if installedPackages.contains(package) {
                    successfulPackages.append(package)
                } else {
                    failedPackages.append(package)
                }
            }
            
            // Sort for consistent display
            successfulPackages.sort()
            failedPackages.sort()
            
            if failedPackages.isEmpty {
                logger.log("✅ All \(successfulPackages.count) packages verified successfully")
                installationOutput += "\n✅ All \(successfulPackages.count) packages installed and verified!\n"
            } else {
                logger.log("⚠️ \(failedPackages.count)/\(allRequestedPackages.count) packages failed to install")
                installationOutput += "\n⚠️ Verification complete: \(successfulPackages.count) successful, \(failedPackages.count) failed\n"
            }
            
            verificationComplete = true
            
        } catch {
            logger.log("❌ Verification error: \(error.localizedDescription)")
            installationOutput += "\n❌ Verification error: \(error.localizedDescription)\n"
        }
        
        isVerifying = false
    }

    func retryFailedPackages() async {
        guard let python = selectedPythonVersion, !failedPackages.isEmpty else {
            return
        }
        
        isInstalling = true
        installationOutput += "\n\n🔄 Retrying failed packages...\n\n"
        
        logger.log("🔄 Retrying \(failedPackages.count) failed packages")
        
        // Store failed packages before clearing
        let packagesToRetry = failedPackages
        
        // Install each failed package individually
        for package in packagesToRetry {
            guard let sanitizedPackage = InputSanitizer.sanitizePackageName(package) else {
                logger.log("❌ Invalid package name: \(package)")
                installationOutput += "❌ Invalid package name: \(package)\n"
                continue
            }
            
            installationOutput += "Installing \(sanitizedPackage)...\n"
            
            let flags = InstallPreferences.pipFlags(forPythonVersion: python.version)
            let command = "\(InputSanitizer.singleQuote(python.path.path)) -m pip install \(InputSanitizer.singleQuote(sanitizedPackage)) \(flags)"
            
            do {
                let result = try await AsyncProcessRunner.shared.run(command: command)
                
                installationOutput += result.combinedOutput + "\n"
                
                if result.succeeded {
                    installationOutput += "✅ \(package) installed\n\n"
                } else {
                    installationOutput += "❌ \(package) failed\n\n"
                }
            } catch {
                installationOutput += "❌ Error installing \(package): \(error.localizedDescription)\n\n"
            }
        }
        
        // Reset before re-verification
        failedPackages = []
        successfulPackages = []
        
        // Re-verify after retry
        installationOutput += "🔍 Re-verifying packages...\n"
        await verifyInstallation(python: python)
        
        isInstalling = false
    }

    func exportFailedPackages() {
        guard !failedPackages.isEmpty else { return }
        
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "failed_requirements.txt"
        panel.message = "Save failed packages list"
        panel.prompt = "Export"
        
        panel.begin { [weak self] response in
            guard let self = self else { return }
            
            if response == .OK, let url = panel.url {
                let content = self.failedPackages.joined(separator: "\n")
                
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    Task { @MainActor in
                        self.logger.log("✅ Exported \(self.failedPackages.count) failed packages to \(url.lastPathComponent)")
                        self.installationOutput += "\n✅ Failed packages exported to \(url.lastPathComponent)\n"
                    }
                } catch {
                    Task { @MainActor in
                        self.logger.log("❌ Failed to export: \(error.localizedDescription)")
                        self.installationOutput += "\n❌ Export failed: \(error.localizedDescription)\n"
                    }
                }
            }
        }
    }
}
