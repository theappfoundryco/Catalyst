import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// A view model governing the configuration and instantiation of Python virtual environments.
///
/// It coordinates the discovery of project metadata, validates the proposed environment name,
/// orchestrates the `python -m venv` generation step, automatically writes to `.gitignore`,
/// and performs a smart install of `requirements.txt` dependencies.
///
/// **Caveats:**
/// - It works in tandem with `VenvBuilder` to safely offload synchronous shell tasks.
/// - The `isRecommendedVersionMissing` flag gracefully degrades the UI when a project dictates
///   a specific interpreter that isn't installed natively.
///
/// ```swift
/// @StateObject var vm = VirtualEnvCreationViewModel()
/// vm.configure(with: url)
/// await vm.createEnvironment()
/// ```
@MainActor
final class VirtualEnvCreationViewModel: ObservableObject {
    /// Discovered attributes of the selected target directory (e.g. `isGitRepo`).
    @Published var metadata: ProjectMetadata?

    
    // MARK: - Python Selection
    /// Detected Homebrew Python interpreters capable of serving as venv bases.
    @Published var installedPythons: [BrewPathManager.BrewPython] = []
    /// The user-selected (or auto-selected) Python interpreter for environment generation.
    @Published var selectedPython: BrewPathManager.BrewPython?
    /// Set if the project explicitly demands a Python version the system doesn't have.
    @Published var isRecommendedVersionMissing = false
    
    // MARK: - Environment Settings
    /// The intended directory name for the virtual environment (defaults to `.venv`).
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
    // FS/process work (gitignore, verify, retry) extracted out of this VM (R1).
    private let builder = VenvBuilder()

    private let logger: Logger
    
    init(logger: Logger = Logger.shared) {
        self.logger = logger
    }
    
    // MARK: - Initialization
    /// Probes the specified URL to determine defaults (ignores, requirements) before UI presentation.
    ///
    /// **Flow:**
    /// 1. Resets all tracking variables (`requirementsIssues`, `failedPackages`, etc).
    /// 2. Detaches an async task to scan the folder (via ``ProjectScannerService``) for `.gitignore` and `requirements.txt`.
    /// 3. Probes ``BrewPathManager`` for the list of available pythons.
    /// 4. Evaluates `recommendedPythonVersion`. If requested version doesn't exist, sets `isRecommendedVersionMissing` true.
    ///
    /// - Parameter url: The absolute local file URL of the target project directory.
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
    /// A subset of requested packages that failed post-install verification.
    @Published var failedPackages: [String] = []
    /// A subset of requested packages that passed post-install verification.
    @Published var successfulPackages: [String] = []
    /// Indicates whether the verification sweep is currently running or completed.
    @Published var verificationComplete = false
    @Published var isVerifying = false
    
    /// Unused array of detected strict compatibility bounds (e.g. `< 2.0`).
    @Published var requirementsIssues: [CompatibilityIssue] = []
    /// Unused toggle for bypassing strict dependency constraints.
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
    
    /// True while `venv` creation or `pip` installation is actively running.
    @Published var isCreating = false
    /// The streamed text output from creation/installation steps.
    @Published var creationOutput = ""
    /// Transient error text if the baseline `venv` creation crashes.
    @Published var creationError: String?
    /// True when the entire creation and optional installation cycle finishes.
    @Published var isComplete = false
    
    /// Configures whether Catalyst automatically executes `pip install -r requirements.txt`.
    @Published var shouldInstallRequirements = true
    /// Configures whether Catalyst automatically appends the `venvName` to `.gitignore`.
    @Published var shouldAddToGitignore = false
    /// Contextual helper text for the gitignore toggle (e.g. "Already ignored").
    @Published var gitStatusMessage: String?
    
    // MARK: - Helpers
    /// Pipes diagnostic lines into both the UI console and the persistent `Logger`.
    private func log(_ message: String) {
        creationOutput += message
        Logger.shared.log("[VirtualEnvCreation] \(message.trimmingCharacters(in: .newlines))")
    }

    // MARK: - Smart Dependency Logic
    


    // MARK: - Creation
    
    /// Executes the underlying `python -m venv` and wires up smart install features.
    ///
    /// **Flow:**
    /// 1. If ``tempCreatedProject`` exists (i.e. a previous install failed verification), returns it immediately.
    /// 2. If `shouldAddToGitignore` is toggled, appends the venv directory to the project's `.gitignore`.
    /// 3. Emits `python3 -m venv .venv` through the async process runner.
    /// 4. If `shouldInstallRequirements` is true, routes through ``performSmartInstall()``.
    ///
    /// - Returns: A hydrated ``Project`` model if successful, or `nil` on fatal error.
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
    /// Invokes `pip install -r requirements.txt` directly against the new environment.
    ///
    /// **Gotchas:**
    /// This bypasses compatibility pre-checks and directly invokes the generated `.venv/bin/pip`.
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
    
    /// Calls `VenvBuilder` to validate that installed packages match the requested list.
    ///
    /// - Parameters:
    ///   - venvPath: Absolute path to the virtual environment folder.
    ///   - projectPath: Absolute path to the parent directory.
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

    /// Triggers a localized `pip install` exclusively on the subset of packages that failed.
    ///
    /// **Rationale:**
    /// Bypasses the bulk `-r` execution in favor of discrete install commands via ``VenvBuilder/retryInstall(packages:pipPath:onOutput:)`` to isolate stubborn failures.
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
    
    /// Saves the names of packages that failed to install into a plain text file.
    func exportFailedPackages() {
        guard !failedPackages.isEmpty else { return }
        exportText(failedPackages.joined(separator: "\n"), filename: "failed_requirements.txt")
    }
    
    /// Saves the full, streamed creation/installation log to a plain text file.
    func exportLog() {
        guard !creationOutput.isEmpty else { return }
        exportText(creationOutput, filename: "creation_log.txt")
    }
    
    /// Presents a macOS `NSSavePanel` and writes the provided payload.
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
