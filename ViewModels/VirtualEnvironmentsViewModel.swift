import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// A view model governing the top-level "Virtual Environments" index screen.
///
/// It wraps `ProjectStore` to present the persisted list of environments, intercepts
/// Drag and Drop operations for seamless directory importing, and spawns the
/// `VirtualEnvCreationViewModel` when establishing new environments.
///
/// **Caveats:**
/// - `missingProjectIDs` is re-validated gracefully whenever the view appears or pythons change,
///   so missing disks or deleted folders surface cleanly instead of crashing the UI.
///
/// ```swift
/// @StateObject var vm = VirtualEnvironmentsViewModel()
/// await vm.startup()
/// ```
@MainActor
final class VirtualEnvironmentsViewModel: ObservableObject {
    /// The canonical list of active projects hydrated by `ProjectStore`.
    @Published var projects: [Project] = []
    /// Triggers visual drop-target overlays when dragging a directory over the window.
    @Published var isDropTargeted = false
    /// Triggers the presentation of the "New Environment" modal sheet.
    @Published var showInitializationSheet = false
    /// Indicates whether a validation cycle is currently sweeping projects.
    @Published var isRefreshing = false
    /// A set of Project IDs where the underlying `path` is no longer valid on disk.
    @Published var missingProjectIDs: Set<UUID> = []
    
    private var cancellables = Set<AnyCancellable>()
    private let scannerService = ProjectScannerService.shared
    private let store = ProjectStore.shared

    // Refresh when the installed-Python set changes elsewhere (e.g. an uninstall):
    // a venv built on a now-removed interpreter needs re-validation.
    private var pyInventoryObserver: NSObjectProtocol?

    // We hold a reference to the init VM so it survives the sheet
    let creationViewModel: VirtualEnvCreationViewModel

    init() {
        self.creationViewModel = VirtualEnvCreationViewModel()

        store.$projects
            .assign(to: \.projects, on: self)
            .store(in: &cancellables)

        // Validate on load
        $projects
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.validateProjects()
            }
            .store(in: &cancellables)

        pyInventoryObserver = NotificationCenter.default.addObserver(
            forName: .catalystPythonInventoryChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refreshWithDelay() }
        }
    }

    deinit {
        if let pyInventoryObserver { NotificationCenter.default.removeObserver(pyInventoryObserver) }
    }
        
    // MARK: - Startup
    
    /// Triggers an immediate sweep of all cached project paths against the filesystem.
    func startup() async {
        validateProjects()
    }
    
    /// Initiates a non-blocking re-validation cycle.
    func refreshWithDelay() async {
        isRefreshing = true
        // (Removed the purely cosmetic 1.5s artificial delay — validation is local
        // and effectively instant.)
        validateProjects()
        isRefreshing = false
    }
    
    /// Systematically verifies whether `project.path` still resolves to a valid directory.
    ///
    /// **Rationale:**
    /// Using `FileManager.default.fileExists` iteratively guarantees we don't crash when querying the `missingProjectIDs` set downstream.
    func validateProjects() {
        var missing = Set<UUID>()
        for project in projects {
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: project.path, isDirectory: &isDir) {
                missing.insert(project.id)
            }
        }
        self.missingProjectIDs = missing
    }
    
    /// Evaluates whether the UI should badge a specific project as orphaned/missing.
    ///
    /// - Parameter project: The project model to evaluate.
    /// - Returns: True if its ID lives in the `missingProjectIDs` set.
    func isProjectMissing(_ project: Project) -> Bool {
        missingProjectIDs.contains(project.id)
    }
    
    /// Translates NSItemProviders from a Drag and Drop event into directory creation workflows.
    ///
    /// - Parameter providers: Array of items dropped onto the view.
    /// - Returns: True if handled successfully.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }
        
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
            guard let self = self, error == nil, let data = data else { return }
            
            // Parse URL from data
            if let urlString = String(data: data, encoding: .utf8),
               let url = URL(string: urlString) {
                Task { @MainActor in
                    await self.processDroppedURL(url)
                }
            } else if let url = URL(dataRepresentation: data, relativeTo: nil) {
                Task { @MainActor in
                    await self.processDroppedURL(url)
                }
            }
        }
        
        return true
    }
    
    /// Deep parses the dropped URL and kicks off the configuration process if valid.
    private func processDroppedURL(_ url: URL) async {
        let standardizedUrl = url.standardized
        let path = standardizedUrl.path
        
        // Security validation
        guard InputSanitizer.isValidVenvPath(path) else { return }
        
        // Check for duplicates
        if store.projects.contains(where: { $0.path == path }) {
            Logger.shared.log("⚠️ Project already exists: \(url.lastPathComponent)")
            return
        }
        
        // Must be a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        
        await self.creationViewModel.configure(with: standardizedUrl)
        self.showInitializationSheet = true
    }
    
    // MARK: - Project Actions
    
    /// Opens the specified project's root path directly in the macOS Finder.
    ///
    /// - Parameter project: The requested model.
    func openInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }
    
    /// Spawns an external Terminal window CD'ed to the project root, automatically activating the `.venv`.
    ///
    /// - Parameter project: The target project.
    func openInTerminal(_ project: Project) {
        // Build command: cd to project, then activate venv if exists
        let venvPath = "\(project.path)/.venv/bin/activate"
        let hasVenv = FileManager.default.fileExists(atPath: venvPath)
        
        var script: String
        if hasVenv {
            // Source the venv activation script
            // The sourced script modifies the current shell's environment
            script = "cd '\(project.path)' && source .venv/bin/activate"
        } else {
            script = "cd '\(project.path)'"
        }
        
        // Use shared TerminalService
        TerminalService.shared.runCommand(script)
    }
    
    /// Completely eradicates the project's tracking representation from Catalyst (does not delete disk contents).
    ///
    /// - Parameter project: The project to remove.
    func deleteProject(_ project: Project) {
        store.remove(id: project.id)
    }
    
    /// Presents a macOS folder picker bridging into the environment creation flow.
    func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Project"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task { @MainActor in
                await self.processDroppedURL(url)
            }
        }
    }
    
    /// Awaits the sub-viewmodel's generation tasks, committing the new entity to `ProjectStore` on success.
    func finalizeProjectCreation() async {
        if let newProject = await creationViewModel.createEnvironment() {
            store.add(newProject)
            showInitializationSheet = false
        }
    }
}
