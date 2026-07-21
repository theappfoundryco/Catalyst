import SwiftUI

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
                    
                    // Command History List
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Command History")
                            .font(.headline)
                        
                        SectionDivider()
                        
                        VStack(spacing: 8) {
                            SearchBarView(placeholder: "Search commands...", text: $searchText)
                            
                            SectionDivider()
                        }
                        
                        if let error = vm.errorMessage {
                            // Error State
                            EmptyStateView(
                                icon: "exclamationmark.triangle",
                                message: error,
                                iconColor: .orange,
                                verticalPadding: 30
                            )
                        } else if filteredCommands.isEmpty {
                            // Empty State
                            EmptyStateView(
                                icon: "clock",
                                message: searchText.isEmpty ? "No commands found" : "No matching commands",
                                verticalPadding: 30
                            )
                        } else {
                            // Commands List
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
        // Local UI feedback: flash "Copied" + green tick for 2s, then revert.
        @State private var copied = false

        var body: some View {
            HStack(spacing: 12) {
                // Index badge
                Text("#\(command.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .leading)
                
                // Command text
                Text(command.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Action buttons
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
                            .font(.caption)
                            .foregroundStyle(copied ? Color.green : Color.primary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .animation(.easeInOut(duration: 0.15), value: copied)
                    
                    Button {
                        onRun()
                    } label: {
                        Label("Run", systemImage: "terminal")
                            .labelStyle(.matched)
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

