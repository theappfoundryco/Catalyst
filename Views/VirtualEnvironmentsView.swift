import SwiftUI
import UniformTypeIdentifiers
/// A view for managing and discovering Python virtual environments and projects.
///
/// ```swift
/// VirtualEnvironmentsView(viewModel: virtualEnvViewModel)
/// ```
struct VirtualEnvironmentsView: View {
    @ObservedObject var viewModel: VirtualEnvironmentsViewModel
    @State private var projectToRemove: Project?
    @State private var showRemoveConfirmation = false
    
    var body: some View {
            GeometryReader { geometry in
                if viewModel.projects.isEmpty {
                    // Empty: fill the window with no scroll. The scroll container is
                    // only introduced once projects are imported (below).
                    VStack(spacing: 24) {
                        MasterHeaderView(
                            title: "Virtual Environments",
                            subtitle: "Manage your Python projects and environments",
                            image: "cube.fill",
                            color: .blue
                        )

                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                Text("Active Projects")
                                    .font(.headline)
                                Spacer()
                                Text("\(viewModel.projects.count) projects")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            SectionDivider()

                            VirtualProjectDropZone(isTargeted: viewModel.isDropTargeted) {
                                viewModel.selectFolder()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .cardStyle()
                        .frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else {
                    SmoothPageScroll {
                        VStack(spacing: 24) {
                            MasterHeaderView(
                                title: "Virtual Environments",
                                subtitle: "Manage your Python projects and environments",
                                image: "cube.fill",
                                color: .blue
                            )

                            // Projects List
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text("Active Projects")
                                        .font(.headline)
                                    Spacer()
                                    Text("\(viewModel.projects.count) projects")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                SectionDivider()

                                LazyVStack(spacing: 0) {
                                    ForEach(Array(viewModel.projects.enumerated()), id: \.element.id) { index, project in
                                        ProjectRow(
                                            project: project,
                                            isMissing: viewModel.isProjectMissing(project),
                                            onOpenInFinder: {
                                                viewModel.openInFinder(project)
                                            },
                                            onOpenInTerminal: {
                                                viewModel.openInTerminal(project)
                                            },
                                            onRemove: {
                                                projectToRemove = project
                                                showRemoveConfirmation = true
                                            }
                                        )

                                        if index < viewModel.projects.count - 1 {
                                            SectionDivider()
                                                .padding(.leading, 32)
                                        }
                                    }
                                }

                                Button {
                                    viewModel.selectFolder()
                                } label: {
                                    Label("Add Project", systemImage: "plus")
                                }
                                .appButton(.secondary)
                                .padding(.top, 8)
                            }
                            .cardStyle()
                            .confirmationDialog(
                                "Remove \"\(projectToRemove?.name ?? "Project")\" from list?",
                                isPresented: $showRemoveConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Remove from List", role: .destructive) {
                                    if let project = projectToRemove {
                                        viewModel.deleteProject(project)
                                    }
                                    projectToRemove = nil
                                }
                                Button("Cancel", role: .cancel) {
                                    projectToRemove = nil
                                }
                            } message: {
                                Text("This will only remove the project from this list. The folder and virtual environment on disk will not be deleted.")
                            }

                            Spacer()
                        }
                        .padding(.vertical)
                        .frame(minHeight: geometry.size.height)
                    }
                }
            }
            .navigationTitle("Projects")
            .onDrop(of: [.fileURL], isTargeted: $viewModel.isDropTargeted) { providers in
                viewModel.handleDrop(providers: providers)
            }
            .sheet(isPresented: $viewModel.showInitializationSheet) {
                VirtualEnvCreationSheet(
                    viewModel: viewModel.creationViewModel,
                    isPresented: $viewModel.showInitializationSheet,
                    onCreate: {
                        await viewModel.finalizeProjectCreation()
                    }
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    RefreshToolbarContent(
                        isLoading: viewModel.isRefreshing,
                        minimumDelay: 0,
                        action: { await viewModel.refreshWithDelay() }
                    )
                }
            }
        }
    }
    
    /// Renders a single workspace entry containing a tracked Python virtual environment.
    struct ProjectRow: View {
        let project: Project
        let isMissing: Bool
        let onOpenInFinder: () -> Void
        let onOpenInTerminal: () -> Void
        let onRemove: () -> Void
        
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // Main Row
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(isMissing ? .red : .blue)
                        .font(.title2)
                        .opacity(isMissing ? 0.5 : 1)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(isMissing ? .secondary : .primary)
                            .strikethrough(isMissing)
                        
                        if isMissing {
                            Text("Folder missing")
                                .font(.caption)
                                .foregroundColor(.red)
                        } else {
                            Text(project.path)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    
                    Spacer()
                    
                    if isMissing {
                        // Trash button for missing folders
                        Button(role: .destructive) {
                            onRemove()
                        } label: {
                            Image(systemName: "trash.fill")
                                .foregroundColor(.red)
                        }
                        .appButton(.plain)
                    } else {
                        // Environment Badge
                        HStack(spacing: 6) {
                            if let version = project.pythonVersion {
                                Text("Python \(version)")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.1))
                        )
                    }
                }
                
                // Action Buttons Row (trailing aligned)
                HStack(spacing: 8) {
                    Spacer()
                    
                    Button {
                        onOpenInFinder()
                    } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    .appButton(.secondary)
                    .disabled(isMissing)

                    Button {
                        onOpenInTerminal()
                    } label: {
                        Label("Open venv in Terminal", systemImage: "terminal")
                    }
                    .appButton(.secondary)
                    .disabled(isMissing)

                    // Destructive row action. Solid red + white label via `.destructiveAction`,
                    // which matches `.secondaryAction`'s metrics exactly so all three buttons in
                    // this row are the same height. Deliberately NOT `role: .destructive`, which
                    // AppKit renders as tinted-red-on-neutral at its own control height.
                    Button {
                        onRemove()
                    } label: {
                        Label("Remove from list", systemImage: "xmark.circle")
                    }
                    .appButton(.destructive)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
    }
    
    /// Defines the active drag-and-drop boundary for registering new workspaces.
    struct VirtualProjectDropZone: View {
        var isTargeted: Bool
        var action: () -> Void
        
        var body: some View {
            Button {
                action()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.2))
                        .background(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)
                    
                    VStack(spacing: 10) {
                        Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus.viewfinder")
                            .font(.system(size: 30))
                            .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.8))
                        
                        VStack(spacing: 4) {
                            Text(isTargeted ? "Drop to Import" : "Add Project")
                                .font(.headline)
                            
                            Text("Drag folder here or click to browse")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .appButton(.plain)
        }
    }

