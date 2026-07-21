import SwiftUI

struct VirtualEnvCreationSheet: View {
    @ObservedObject var viewModel: VirtualEnvCreationViewModel
    @Binding var isPresented: Bool
    
    // Callback when user clicks Create
    var onCreate: () async -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            headerView
            SectionDivider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pythonSelectionSection
                    environmentSettingsSection
                    detectedFilesSection
                    gitDetailsSection
                    gitConfigurationSection
                    verificationResultsSection
                    logConsoleSection
                }
                .padding()
            }
            
            SectionDivider()
            footerView
        }
        .frame(width: 500, height: 600)
    }
    
    // MARK: - Subviews
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Initialize Environment")
                    .font(.headline)
                Text(viewModel.metadata?.name ?? "Project")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    private var pythonSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Python Version From Homebrew")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            if viewModel.installedPythons.isEmpty {
                Text("No Homebrew Python installations found.")
                    .foregroundColor(.orange)
                    .font(.caption)
            } else {
                Picker("", selection: $viewModel.selectedPython) {
                    ForEach(viewModel.installedPythons) { python in
                        Text(python.displayName)
                            .tag(python as BrewPathManager.BrewPython?)
                    }
                }
                .labelsHidden()
            }
            
            // Missing Version Warning
            if viewModel.isRecommendedVersionMissing {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "xmark.bin.fill")
                        .foregroundColor(.red)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Missing Required Version")
                            .font(.headline)
                            .foregroundColor(.red)
                        
                        Text("Project requires Python \(viewModel.metadata?.recommendedPythonVersion ?? ""), which is not installed via Homebrew.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("Please install it from the Dashboard, then try again.")
                            .font(.caption)
                            .bold()
                            .padding(.top, 2)
                    }
                }
                .padding()
                .background(Color.red.opacity(0.1))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.3), lineWidth: 1))
            } else if let recommended = viewModel.metadata?.recommendedPythonVersion {
                 // Success match
                 if let selected = viewModel.selectedPython, selected.version == recommended || selected.version.starts(with: recommended) {
                     Label("Matches .python-version requirement (\(recommended))", systemImage: "checkmark.circle.fill")
                         .font(.caption)
                         .foregroundColor(.green)
                 }
            }
        }
    }
    
    private var environmentSettingsSection: some View {
        VStack(alignment: .leading) {
            Text("Environment Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextField("Environment Name", text: $viewModel.venvName)
                .textFieldStyle(.roundedBorder)

            if let nameError = viewModel.venvNameError, !viewModel.venvName.isEmpty {
                Label(nameError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }

            Toggle("Install dependencies from requirements.txt", isOn: $viewModel.shouldInstallRequirements)
                .disabled(!(viewModel.metadata?.hasRequirementsTxt ?? false))
        }
    }
    
    @ViewBuilder
    private var detectedFilesSection: some View {
        if let meta = viewModel.metadata {
            VStack(alignment: .leading, spacing: 8) {
                Text("Detected Files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                HStack {
                    Badge(text: "requirements.txt", isDetected: meta.hasRequirementsTxt)
                    Badge(text: "Pipfile", isDetected: meta.hasPipfile)
                    Badge(text: "pyproject.toml", isDetected: meta.hasPyProjectToml)
                    Badge(text: "Git Repo", isDetected: meta.isGitRepo)
                }
            }
        }
    }
    
    @ViewBuilder
    private var gitDetailsSection: some View {
        if let git = viewModel.metadata?.gitInfo {
            VStack(alignment: .leading, spacing: 8) {
                Text("Repository")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    gitDetailRow(icon: "arrow.triangle.branch",
                                 label: "Current Branch",
                                 value: git.currentBranch ?? "Detached HEAD")
                    Divider()
                    gitDetailRow(icon: "square.stack.3d.up",
                                 label: "Local Branches",
                                 value: "\(git.localBranchCount)")
                    Divider()
                    gitDetailRow(icon: "tag",
                                 label: "Tags",
                                 value: "\(git.tagCount)")
                    if let remote = git.remoteURL {
                        Divider()
                        gitDetailRow(icon: "link", label: "Remote", value: remote)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
        }
    }

    private func gitDetailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var gitConfigurationSection: some View {
        if let gitMessage = viewModel.gitStatusMessage {
            VStack(alignment: .leading) {
                Text("Git Configuration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Toggle(isOn: $viewModel.shouldAddToGitignore) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Add \(viewModel.venvName.isEmpty ? ".venv" : viewModel.venvName) to .gitignore")
                            Text(gitMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .disabled(viewModel.metadata?.isVenvIgnored == true)
            }
        }
    }
    
    @ViewBuilder
    private var verificationResultsSection: some View {
        compatibilityWarningView
        verificationSummaryView
    }
    
    @ViewBuilder
    private var compatibilityWarningView: some View {
        if !viewModel.requirementsIssues.isEmpty && !viewModel.verificationComplete && !viewModel.isCreating {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundColor(.orange)
                    VStack(alignment: .leading) {
                        Text("Potential Incompatibility Detected")
                            .font(.headline)
                        Text("Some packages in requirements.txt are pinned to versions incompatible with Python \(viewModel.metadata?.recommendedPythonVersion ?? viewModel.selectedPython?.version ?? "selected").")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                SectionDivider()
                
                ForEach(viewModel.requirementsIssues) { issue in
                    HStack(alignment: .top) {
                         Text("•")
                        VStack(alignment: .leading) {
                            Text("\(issue.package) \(issue.pinnedVersion)")
                                .font(.caption.monospaced().bold())
                            Text(issue.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 8)
                
                HStack {
                    Button {
                        viewModel.shouldRelaxVersions = true
                        Task { await viewModel.performSmartInstall() }
                    } label: {
                        Text("Relax Versions & Install")
                        Text("(Recommended)")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    
                    Button("Install Exact Versions") {
                        viewModel.shouldRelaxVersions = false
                         Task { await viewModel.performSmartInstall() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 8)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.3), lineWidth: 1))
        }
    }
    
    @ViewBuilder
    private var verificationSummaryView: some View {
        if viewModel.verificationComplete {
            VStack(alignment: .leading, spacing: 12) {
                verificationHeader
                failedPackagesList
                successfulPackagesList
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(viewModel.failedPackages.isEmpty ? Color.green.opacity(0.05) : Color.orange.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(viewModel.failedPackages.isEmpty ? Color.green.opacity(0.2) : Color.orange.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
    
    private var verificationHeader: some View {
        HStack {
            Image(systemName: viewModel.failedPackages.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(viewModel.failedPackages.isEmpty ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.failedPackages.isEmpty ? "Installation Successful" : "Installation Partially Completed")
                    .font(.headline)
                
                // Counts only — status icon lives in the header, so we don't
                // repeat a second green checkmark.
                HStack(spacing: 6) {
                    Text("\(viewModel.successfulPackages.count) installed")
                    if !viewModel.failedPackages.isEmpty {
                        Text("·")
                        Text("\(viewModel.failedPackages.count) failed")
                            .foregroundColor(.red)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
    
    @ViewBuilder
    private var failedPackagesList: some View {
        if !viewModel.failedPackages.isEmpty {
            SectionDivider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Failed Packages")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.red)
                
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.failedPackages, id: \.self) { package in
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
                
                HStack(spacing: 12) {
                    Button {
                        Task { await viewModel.retryFailedPackages() }
                    } label: {
                        Label("Retry Failed", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isCreating)
                    
                    Button {
                        viewModel.exportFailedPackages()
                    } label: {
                        Label("Export List", systemImage: "square.and.arrow.up")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
    
    @ViewBuilder
    private var successfulPackagesList: some View {
        if !viewModel.successfulPackages.isEmpty {
            DisclosureGroup {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.successfulPackages, id: \.self) { package in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                
                                Text(package)
                                    .font(.caption.monospaced())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
                .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.05))
                )
            } label: {
                HStack {
                    Text("Successful Packages (\(viewModel.successfulPackages.count))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.green)
                    
                    Spacer()
                }
            }
        }
    }
    
    @ViewBuilder
    private var logConsoleSection: some View {
        if viewModel.isCreating || !viewModel.creationOutput.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Log")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    // Copy Button
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(viewModel.creationOutput, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Log")
                    
                    // Export Button
                    Button {
                        viewModel.exportLog()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Export Log")
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(viewModel.creationOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("logOutput")
                    }
                    .frame(height: 220)
                    .scrollBounceBehavior(.basedOnSize) // toAvoid.md Rule 1
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(6)
                    .onChange(of: viewModel.creationOutput) { _ in
                        // Auto-scroll to bottom when text changes
                        withAnimation {
                            proxy.scrollTo("logOutput", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
    
    private var footerView: some View {
        HStack {
            Button("Cancel") {
                isPresented = false
            }
            .disabled(viewModel.isCreating)
            
            Spacer()
            
            if viewModel.isComplete || (viewModel.verificationComplete && !viewModel.isCreating) {
                Button("Done") {
                    Task {
                         await onCreate()
                    }
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Create Environment") {
                    Task {
                        await onCreate()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isCreating || viewModel.isRecommendedVersionMissing || viewModel.selectedPython == nil || !viewModel.isVenvNameValid)
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// Simple Badge Helper
struct Badge: View {
    let text: String
    let isDetected: Bool
    
    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isDetected ? Color.green.opacity(0.1) : Color.secondary.opacity(0.1))
            .foregroundColor(isDetected ? .green : .secondary)
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isDetected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
            )
    }
}
