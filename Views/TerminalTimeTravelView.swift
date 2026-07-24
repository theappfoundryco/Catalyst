import SwiftUI
/// A view for browsing, searching, and restoring terminal command history.
///
/// ```swift
/// TerminalTimeTravelView(vm: timeTravelViewModel)
/// ```
struct TerminalTimeTravelView: View {
    @ObservedObject var vm: TerminalTimeTravelViewModel
    @State private var searchText = ""
    
    var filteredCommands: [TerminalTimeTravelViewModel.HistoryCommand] {
        if searchText.isEmpty {
            return vm.commands
        }
        return vm.commands.filter { $0.command.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        GeometryReader { geometry in
            SmoothPageScroll {
                VStack(spacing: 24) {
                    
                MasterHeaderView(
                    title: "Terminal Time Travel",
                    subtitle: "Restore your terminal history",
                    image: "clock.arrow.circlepath",
                    color: .orange
                )
                    
                    tipBanner
                    
                    /// Command History List
                    ///
                    /// **Rationale:** Grouping historical commands geographically prevents UI clutter and keeps the execution surface strictly separated from the reference surface.
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Command History")
                            .font(.headline)
                        
                        SectionDivider()
                        
                        VStack(spacing: 8) {
                            SearchBarView(placeholder: "Search commands...", text: $searchText)
                            
                            SectionDivider()
                        }
                        
                        if let error = vm.errorMessage {
                            /// Error State
                            ///
                            /// **Rationale:** Explicit error boundaries within the history container prevent a corrupted bash_history file from crashing the entire terminal view.
                            EmptyStateView(
                                icon: "exclamationmark.triangle",
                                message: error,
                                iconColor: .orange,
                                verticalPadding: 30
                            )
                        } else if filteredCommands.isEmpty {
                            /// Empty State
                            ///
                            /// **Rationale:** Proactively explaining why the history list is empty (e.g. fresh installation) prevents users from thinking the shell parser is broken.
                            EmptyStateView(
                                icon: "clock",
                                message: searchText.isEmpty ? "No commands found" : "No matching commands",
                                verticalPadding: 30
                            )
                        } else {
                            /// Commands List
                            ///
                            /// **Gotchas:** Attempting to render an unbounded lazy list of 10,000 `.bash_history` commands will consume gigabytes of RAM; pagination or strict truncation is required.
                            LazyVStack(spacing: 0) {
                                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                    CommandRow(
                                        command: command,
                                        onCopy: { vm.copyToClipboard(command.command) },
                                        onRun: { vm.runInTerminal(command.command) }
                                    )
                                    
                                    if index < filteredCommands.count - 1 {
                                        SectionDivider()
                                            .padding(.leading, 40)
                                    }
                                }
                            }
                        }
                    }
                    .cardStyle()
                    
                    Spacer()
                }
                .padding(.vertical)
                .frame(minHeight: geometry.size.height)
            }
        }
        .navigationTitle("Terminal Time Travel")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshToolbarContent(
                    isLoading: vm.isRefreshing,
                    action: { await vm.refresh(forceRefresh: true) }
                )
            }
        }
    }
    
    private var tipBanner: some View {
        BannerView(
            .tip,
            message: "Your terminal history may contain sensitive commands, passwords, or API keys. Be discreet when sharing this information!"
        )
    }


    // MARK: - Command Row
    
    struct CommandRow: View {
        let command: TerminalTimeTravelViewModel.HistoryCommand
        let onCopy: () -> Void
        let onRun: () -> Void
        /// Local UI feedback: flash "Copied" + green tick for 2s, then revert.
        ///
        /// **Rationale:** Transient visual feedback confirms a successful pasteboard operation without requiring a persistent, screen-cluttering toast notification.
        @State private var copied = false

        var body: some View {
            HStack(spacing: 12) {
                /// Index badge
                ///
                /// **Rationale:** Providing the absolute command index allows power users to easily cross-reference the UI row with their raw `~/.zsh_history` file.
                Text("#\(command.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
                
                /// Command text
                ///
                /// **Rationale:** Monospaced typography is mandatory here because variable-width fonts destroy the alignment of complex piped bash commands.
                Text(command.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)
                
                Spacer()
                
                /// Action buttons
                ///
                /// **Gotchas:** Placing destructive actions (like delete) adjacent to the copy button guarantees accidental data loss when the user misclicks.
                HStack(spacing: 6) {
                    Button {
                        onCopy()
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.matched)
                            .foregroundStyle(copied ? Color.green : Color.primary)
                    }
                    .appButton(.secondary)
                    .animation(.easeInOut(duration: 0.15), value: copied)
                    
                    Button {
                        onRun()
                    } label: {
                        Label("Run", systemImage: "terminal")
                            .labelStyle(.matched)
                    }
                    .appButton(.primary)
                    .tint(.green)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

