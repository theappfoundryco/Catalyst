import SwiftUI
import Combine
/// A view for managing shell command aliases, allowing users to create, search, and delete custom shortcuts.
///
/// ```swift
/// AliasView(vm: aliasViewModel)
/// ```
struct AliasView: View {
    @ObservedObject var vm: AliasViewModel
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                MasterHeaderView(
                    title: "Alias Manager",
                    subtitle: "Create shortcuts for your favorite terminal commands",
                    image: "command.circle.fill",
                    color: .purple
                )
                
                /// Tip Box
                ///
                /// **Rationale:** Highlights the context-specific limitations (like unmanaged aliases) before the user attempts to modify them.
                BannerView(
                    .tip,
                    message: "After adding or removing an alias, close and reopen Terminal to start using it right away!"
                )
                
                /// What are Aliases? Info Card
                ///
                /// **Rationale:** Educates novice users on the core value proposition of shell aliases without forcing them to external documentation.
                infoCard
                
                /// Add New Alias Section
                ///
                /// **Rationale:** Keeps the primary action surface explicitly visible at the top instead of hiding it behind a generic "+" button.
                createAliasCard
                
                /// Search Aliases
                ///
                /// **Rationale:** Prevents scrolling fatigue for power users who have dozens of aliases in their shell configuration.
                searchAliasesCard
                
                /// Output Message
                ///
                /// **Rationale:** Surfaces inline, localized success/error states directly below the action area instead of using intrusive global alerts.
                if !vm.outputMessage.isEmpty {
                    outputCard
                }
                
                /// Existing Aliases
                ///
                /// **Rationale:** Visually segregates read-only and managed aliases from the creation controls above.
                if vm.isLoading {
                    LoadingStateView("Loading aliases...")
                        .cardStyle()
                } else if vm.aliases.isEmpty {
                    emptyStateCard
                } else {
                    aliasesListCard
                }
                
                Spacer()
            }
            .padding(.vertical)
        }
        .navigationTitle("Aliases")
        .task {
            await vm.loadAliases()
        }
        .alert("Error", isPresented: $vm.showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(vm.errorMessage)
        }
    }
    
    // MARK: - Info Card
    
    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What are Aliases?")
                .font(.headline)
            
            SectionDivider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Aliases are shortcuts for long terminal commands. Instead of typing the full command every time, create a short alias!")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Examples:")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    
                    ExampleRow(alias: "ll", command: "ls -la", description: "Detailed file list")
                    ExampleRow(alias: "gs", command: "git status", description: "Quick Git status")
                    ExampleRow(alias: "update", command: "brew update && brew upgrade", description: "Update Homebrew")
                }
                .padding(.top, 4)
            }
        }
        .cardStyle()
    }
    
    // MARK: - Add Alias Card
    
    private var createAliasCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Alias")
                .font(.headline)
            
            SectionDivider()
            
            VStack(spacing: 12) {
                /// Alias Name
                ///
                /// **Gotchas:** Allowing spaces here will generate fundamentally broken shell configuration files.
                CompactInputField(label: "Alias Name", icon: "terminal",
                                  placeholder: "e.g., ll, gs, update", text: $vm.newAliasName)

                /// Command
                ///
                /// **Rationale:** Multi-line commands are not supported natively by the basic `alias` directive; this input restricts the user to a single string.
                CompactInputField(label: "Command", icon: "chevron.right",
                                  placeholder: "e.g., ls -la, git status", text: $vm.newAliasCommand)

                /// Add Button
                ///
                /// **Gotchas:** Leaving this button enabled when inputs are empty or invalid will trigger cryptic Bash syntax errors downstream.
                Button {
                    Task { await vm.addAlias() }
                } label: {
                    Label("Add Alias", systemImage: "plus.circle.fill")
                        .labelStyle(.matched)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.newAliasName.isEmpty || vm.newAliasCommand.isEmpty)
            }
        }
        .cardStyle()
    }
    
    private var searchAliasesCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.purple)
                Text("Search Aliases")
                    .font(.headline)
            }
            
            SectionDivider()

            VStack(spacing: 8) {
                HStack {
                    TextField("Search aliases...", text: $vm.searchQuery)
                        .textFieldStyle(.plain)
                    
                    if !vm.searchQuery.isEmpty {
                        Button {
                            vm.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .codePanel()
                
                SectionDivider()
            }
        }
        .cardStyle()
    }
    
    // MARK: - Output Card
    
    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    vm.clearOutput()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.matched)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            SectionDivider()
            
            ScrollView {
                Text(vm.outputMessage)
                    .font(.caption.monospaced())
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .scrollBounceBehavior(.basedOnSize) // ANTI_PATTERNS.md Rule 1
            .codePanel()
        }
        .cardStyle()
    }
    
    // MARK: - Empty State
    
    private var emptyStateCard: some View {
        EmptyStateView(
            icon: "tray",
            message: "No Aliases Found",
            detail: "Create your first alias above to get started!",
            iconSize: 48
        )
        .cardStyle()
    }
    
    // MARK: - Aliases List Card
    
    private var aliasesListCard: some View {
        /// Filter once per render instead of re-running the same predicate 4×
        ///
        /// **Rationale:** SwiftUI's aggressive re-rendering loop will lock the main thread if heavy string-matching predicates are evaluated on every pass.
        // inside body (ANTI_PATTERNS.md Rule 7).
        let query = vm.searchQuery
        let predicate: (AliasItem) -> Bool = { alias in
            query.isEmpty ||
            alias.name.localizedCaseInsensitiveContains(query) ||
            alias.command.localizedCaseInsensitiveContains(query)
        }
        let catalystFiltered = vm.catalystAliases.filter(predicate)
        let otherFiltered = vm.otherAliases.filter(predicate)

        return VStack(alignment: .leading, spacing: 16) {
            /// Catalyst Managed Aliases
            ///
            /// **Rationale:** Explicitly calling out Catalyst-managed aliases gives users confidence that they can safely edit or delete them via the GUI.
            if !catalystFiltered.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(.purple)
                        Text("Managed by Catalyst (\(vm.catalystAliases.count))")
                            .font(.headline)
                    }
                    
                    SectionDivider()
                    
                    LazyVStack(spacing: 0) {
                        ForEach(Array(catalystFiltered.enumerated()), id: \.element.id) { index, alias in
                            AliasRow(
                                alias: alias,
                                isAlternate: index % 2 == 1,
                                onDelete: {
                                    Task { await vm.deleteAlias(alias) }
                                }
                            )
                        }
                    }
                }
                .cardStyle()
            }
            
            /// Other Aliases
            ///
            /// **Gotchas:** Attempting to mutate unmanaged aliases (e.g. injected by Oh My Zsh) is structurally impossible because they are often buried inside complex loops or sourced files.
            if !otherFiltered.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "list.bullet")
                            .foregroundColor(.blue)
                        Text("Other Aliases (\(vm.otherAliases.count))")
                            .font(.headline)
                    }
                    
                    SectionDivider()
                    
                    LazyVStack(spacing: 0) {
                        ForEach(Array(otherFiltered.enumerated()), id: \.element.id) { index, alias in
                            AliasRow(
                                alias: alias,
                                isAlternate: index % 2 == 1,
                                onDelete: {
                                    Task { await vm.deleteAlias(alias) }
                                }
                            )
                        }
                    }
                }
                .cardStyle()
            }
            
            /// No Results
            ///
            /// **Rationale:** An empty state illustration prevents the user from assuming the list simply failed to load.
            if vm.filteredAliases.isEmpty && !vm.searchQuery.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    
                    Text("No aliases match '\(vm.searchQuery)'")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .cardStyle()
            }
        }
    }
}

// MARK: - Supporting Views
/// A styled row demonstrating a sample alias and its corresponding command.
///
/// ```swift
/// ExampleRow(alias: "ll", command: "ls -la", description: "Detailed file list")
/// ```
struct ExampleRow: View {
    let alias: String
    let command: String
    let description: String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(alias)
                .font(.caption.monospaced())
                .foregroundColor(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.purple.opacity(0.1))
                )
            
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(.secondary)
            
            Text(command)
                .font(.caption.monospaced())
                .foregroundColor(.secondary)
            
            Text("(\(description))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .italic()
        }
    }
}
/// A row representing a single saved alias, displaying its name, command, and a delete action.
///
/// ```swift
/// AliasRow(alias: myAlias, isAlternate: false) { delete() }
/// ```
struct AliasRow: View {
    let alias: AliasItem
    let isAlternate: Bool
    let onDelete: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(alias.name)
                        .font(.body.monospaced())
                        .foregroundColor(.primary)
                    
                    if alias.isCatalystManaged {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                            .foregroundColor(.purple)
                    }
                }
                
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    Text(alias.command)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash.fill")
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isAlternate ? Color(NSColor.controlAlternatingRowBackgroundColors[1]) : Color(NSColor.controlBackgroundColor))
    }
}
