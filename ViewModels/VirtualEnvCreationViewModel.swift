import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class VirtualEnvCreationViewModel: ObservableObject {
    @Published var metadata: ProjectMetadata?

    
    // MARK: - Python Selection
    @Published var installedPythons: [BrewPathManager.BrewPython] = []
    @Published var selectedPython: BrewPathManager.BrewPython?
    @Published var isRecommendedVersionMissing = false
    
    // MARK: - Environment Settings
    @Published var venvName = ".venv"

    /// Inline validation for the environment name. Allows an optional single leading dot
    /// (so the conventional `.venv` is fine), an alphanumeric first character, then only
    /// letters/numbers/`-`/`_` — no internal dots or separators. This rejects degenerate
    /// inputs like `.venv.venv`, `..`, `../`, `foo/bar`, and empty/oversized names.
    /// Returns a user-facing reason when invalid, else `nil`.
    var venvNameError: String? {
        let name = venvName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "Name can’t be empty." }
        if name.count > 64 { return "Keep the name under 64 characters." }
        if name.range(of: #"^\.?[A-Za-z0-9][A-Za-z0-9_-]*$"#, options: .regularExpression) == nil {
            return "Use letters, numbers, - or _ (one optional leading dot, e.g. .venv)."
        }
        return nil
    }

    /// True when the environment name is safe to create.
    var isVenvNameValid: Bool { venvNameError == nil }
    
    // MARK: - Dependencies
    private let scannerService = ProjectScannerService.shared
    // BrewPathManager is a singleton, accessed via .shared
    /// FS/process work (gitignore, verify, retry) extracted out of this VM (R1).
    private let builder = VenvBuilder()

    private let logger: Logger
    
    init(logger: Logger = Logger.shared) {
        self.logger = logger
    }
    
    // MARK: - Initialization
    func configure(with url: URL) {
        guard !isCreating else { return }
        
        // Reset state
        self.requirementsIssues = []
        self.failedPackages = []
        self.successfulPackages = []
        self.creationOutput = ""
        self.creationError = nil
        self.verificationComplete = false
        self.tempCreatedProject = nil
        self.shouldRelaxVersions = false
        self.isRecommendedVersionMissing = false
        
        Task {
            // 1. Scan Project
            let meta = await scannerService.scan(url: url)
            
            // 2. Scan for Brew Pythons
            let pythons = await BrewPathManager.shared.getInstalledPythons()
            
            await MainActor.run {
                self.metadata = meta
                self.installedPythons = pythons
                
                // Auto-select logic
                if let recommended = meta.recommendedPythonVersion {
                    // Try to find exact match or match by prefix
                    if let exactMatch = pythons.first(where: { $0.version == recommended }) {
                        self.selectedPython = exactMatch
                    } else if let prefixMatch = pythons.first(where: { $0.version.starts(with: recommended) }) {
                        self.selectedPython = prefixMatch
                    } else {
                         // Recommended version NOT found
                         self.isRecommendedVersionMissing = true
                         // Default to latest available as fallback
                         self.selectedPython = pythons.first
                    }
                } else {
                    // No recommendation, select newest
                    self.selectedPython = pythons.first
                }
                
                // Update Git Ignore logic default
                if meta.isGitRepo, !meta.isVenvIgnored {
                    self.shouldAddToGitignore = true
                    self.gitStatusMessage = "Will define rule to ignore venv"
                } else if meta.isGitRepo, meta.isVenvIgnored {
                    self.shouldAddToGitignore = false
                    self.gitStatusMessage = "Already ignored in .gitignore"
                } else {
                    self.shouldAddToGitignore = false
                    self.gitStatusMessage = nil
                }
            }
        }
    }
    
    // MARK: - Verification State
    @Published var failedPackages: [String] = []
    @Published var successfulPackages: [String] = []
    @Published var verificationComplete = false
    @Published var isVerifying = false
    
    @Published var requirementsIssues: [CompatibilityIssue] = []
    @Published var isRelaxingRequirements = false
    
    // Tracks if we should relax versions during install
    @Published var shouldRelaxVersions = false
    
    struct CompatibilityIssue: Identifiable, Equatable {
        let id = UUID()
        let package: String
        let pinnedVersion: String
        let reason: String
        
        var localizedDescription: String {
            "\(package) \(pinnedVersion): \(reason)"
        }
    }
    
    // Store project temporarily if verification fails
    private var tempCreatedProject: Project?
    
    // MARK: - Creation
    
    @Published var isCreating = false
    @Published var creationOutput = ""
    @Published var creationError: String?
    @Published var isComplete = false
    
    @Published var shouldInstallRequirements = true
    @Published var shouldAddToGitignore = false
    @Published var gitStatusMessage: String?
    
    // MARK: - Helpers
    private func log(_ message: String) {
        creationOutput += message
        Logger.shared.log("[VirtualEnvCreation] \(message.trimmingCharacters(in: .newlines))")
    }

    // MARK: - Smart Dependency Logic
    


    // MARK: - Creation
    
    func createEnvironment() async -> Project? {
        // If we already created it but stopped due to verification failure
        if let existing = tempCreatedProject {
            return existing
        }
        
        guard let metadata = metadata, let python = selectedPython else { return nil }
        
        isCreating = true
        creationError = nil
        creationOutput = "Preparing environment with \(python.displayName)...\n"
        
        let projectPath = metadata.path
        let venvPath = projectPath.appendingPathComponent(venvName).path
        let pythonExecutablePath = python.path
        
        creationOutput += "✅ Using Python at \(pythonExecutablePath)\n"

        // Handle Gitignore
        if shouldAddToGitignore && metadata.isGitRepo {
            builder.writeGitignore(projectPath: projectPath, venvName: venvName) { [weak self] in
                self?.creationOutput += $0
            }
        }
        
        // Command: /opt/homebrew/bin/python3.x -m venv .venv
        let command = "\(InputSanitizer.singleQuote(pythonExecutablePath)) -m venv \(InputSanitizer.singleQuote(venvPath))"
        
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { text in
                self.creationOutput += text
            }
            
            if exitCode == 0 {
                if shouldInstallRequirements && metadata.hasRequirementsTxt {
                    // Direct install without compatibility pre-checks
                    self.tempCreatedProject = Project(
                        name: metadata.name,
                        path: projectPath.path,
                        pythonVersion: python.version,
                        venvPath: venvPath
                    )
                    
                    await performSmartInstall()
                    
                    if !failedPackages.isEmpty {
                         return nil
                    } else {
                         isComplete = true
                         isCreating = false
                         return self.tempCreatedProject
                    }
                } else {
                    // No requirements, just finish
                    let newProject = Project(
                        name: metadata.name,
                        path: projectPath.path,
                        pythonVersion: python.version,
                        venvPath: venvPath
                    )
                    isComplete = true
                    isCreating = false
                    return newProject
                }
            } else {
                creationError = "Failed with exit code \(exitCode)"
                isCreating = false
                return nil
            }
        } catch {
            creationError = error.localizedDescription
            isCreating = false
            return nil
        }
    }
    func performSmartInstall() async {
        guard let project = self.tempCreatedProject, let venvPath = project.venvPath else { return }
        
        self.isCreating = true
        self.creationOutput += "\n🚀 Starting Smart Install...\n"
        
        // ... (skipping unchanged parts)
        
        
        let reqPath = URL(fileURLWithPath: project.path).appendingPathComponent("requirements.txt").path
        let venvPythonPath = venvPath + "/bin/python3"
        
        let installCmd = "\(InputSanitizer.singleQuote(venvPythonPath)) -m pip install -r \(InputSanitizer.singleQuote(reqPath)) -v"
        
        self.log("⚙️ Executing Smart Install: \(installCmd)\n")
        
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: installCmd) { text in
                self.log(text)
            }
            
            if exitCode == 0 {
                self.creationOutput += "\n✅ Smart Install Successful!\n"
                self.creationOutput += "\n🔍 Verifying installed packages...\n"
                await verifyInstallation(venvPath: venvPath, projectPath: project.path)
            } else {
                self.creationOutput += "\n❌ Smart Install Failed with code \(exitCode)\n"
                self.failedPackages = ["Install Failed (Code \(exitCode))"]
            }
            
        } catch {
            self.creationOutput += "\n❌ Execution Error: \(error.localizedDescription)\n"
        }
        
        // ...
        

        
        self.isCreating = false
        // Trigger completion if successful? Or let user click Done.
        // We update tempProject so UI reflects state
    }
    // MARK: - Verification Logic
    
    private func verifyInstallation(venvPath: String, projectPath: String) async {
        isVerifying = true
        successfulPackages = []
        failedPackages = []

        let outcome = await builder.verify(venvPath: venvPath, projectPath: projectPath) { [weak self] in
            self?.log($0)
        }

        switch outcome {
        case .requirementsUnreadable:
            failedPackages = ["Could not read requirements.txt"]
        case .freezeFailed:
            failedPackages = ["Verification Script Error"]
        case .systemError:
            break // logged via output; leave packages as-is (matches prior behavior)
        case .success(let successful, let failed):
            successfulPackages = successful
            failedPackages = failed
            verificationComplete = true
        }

        isVerifying = false
    }

    func retryFailedPackages() async {
        guard let _ = tempCreatedProject, !failedPackages.isEmpty else { return }
        
        // We need venvPath. Since we have tempCreatedProject, use it.
        guard let project = tempCreatedProject, let venvPath = project.venvPath else { return }
        let pipPath = venvPath + "/bin/pip"
        
        isCreating = true
        creationOutput += "\n\n🔄 Retrying failed packages...\n"
        
        let packagesToRetry = failedPackages

        await builder.retryInstall(packages: packagesToRetry, pipPath: pipPath) { [weak self] in
            self?.creationOutput += $0
        }

        // Re-verify
        creationOutput += "🔍 Re-verifying...\n"
        await verifyInstallation(venvPath: venvPath, projectPath: project.path)
        
        if failedPackages.isEmpty {
            isComplete = true
        }
        
        isCreating = false
    }
    
    func exportFailedPackages() {
        guard !failedPackages.isEmpty else { return }
        exportText(failedPackages.joined(separator: "\n"), filename: "failed_requirements.txt")
    }
    
    func exportLog() {
        guard !creationOutput.isEmpty else { return }
        exportText(creationOutput, filename: "creation_log.txt")
    }
    
    private func exportText(_ text: String, filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = filename
        panel.message = "Save Log"
        panel.prompt = "Export"
        
        panel.begin { [weak self] response in
            guard let self = self else { return }
            
            if response == .OK, let url = panel.url {
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    Task { @MainActor in
                        self.creationOutput += "\n✅ Log exported to \(url.lastPathComponent)\n"
                    }
                } catch {
                    Task { @MainActor in
                        self.creationOutput += "\n❌ Export failed: \(error.localizedDescription)\n"
                    }
                }
            }
        }
    }
    
}
