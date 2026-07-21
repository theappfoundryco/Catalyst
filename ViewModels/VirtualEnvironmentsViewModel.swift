import Foundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class VirtualEnvironmentsViewModel: ObservableObject {
    @Published var projects: [Project] = []
    @Published var isDropTargeted = false
    @Published var showInitializationSheet = false
    @Published var isRefreshing = false
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
    
    func startup() async {
        validateProjects()
    }
    
    func refreshWithDelay() async {
        isRefreshing = true
        // (Removed the purely cosmetic 1.5s artificial delay — validation is local
        // and effectively instant.)
        validateProjects()
        isRefreshing = false
    }
    
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
    
    func isProjectMissing(_ project: Project) -> Bool {
        missingProjectIDs.contains(project.id)
    }
    
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
    
    func openInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path)
    }
    
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
    
    func deleteProject(_ project: Project) {
        store.remove(id: project.id)
    }
    
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
    
    func finalizeProjectCreation() async {
        if let newProject = await creationViewModel.createEnvironment() {
            store.add(newProject)
            showInitializationSheet = false
        }
    }
}
