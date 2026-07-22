import SwiftUI
import Combine
import UniformTypeIdentifiers
/// A view for inspecting, searching, and exporting terminal output and system diagnostics logs.
///
/// ```swift
/// LogsView(vm: logsViewModel)
/// ```
struct LogsView: View {
    @ObservedObject var vm: LogsViewModel
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 24) {
                // Tab Selector
                Picker("", selection: $vm.selectedTab) {
                    Label("Terminal Output", systemImage: "terminal.fill").tag(0)
                    Label("System Diagnostics", systemImage: "gearshape.fill").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                
                // Dynamic Height Calculation
                // Total vertical padding/spacing overhead approx 150px
                let availableHeight = max(300, geometry.size.height - 230)
                
                // Log Content Card
                switch vm.selectedTab {
                case 0:
                    logCard(
                        title: "Terminal Output",
                        icon: "terminal.fill",
                        logs: vm.terminalLogs,
                        autoScroll: $vm.terminalAutoScroll,
                        emptyMessage: "No terminal output yet",
                        scrollId: "terminal-bottom",
                        height: availableHeight,
                        onClear: { vm.clearTerminalLogs() }
                    )
                default:
                    logCard(
                        title: "System Diagnostics",
                        icon: "gearshape.fill",
                        logs: vm.debugLogs,
                        autoScroll: $vm.debugAutoScroll,
                        emptyMessage: "No diagnostic logs yet",
                        scrollId: "debug-bottom",
                        height: availableHeight,
                        onClear: { vm.clearDebugLogs() }
                    )
                }
                
            }
            .padding(.vertical)
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    Text("Export:")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    exportSelector
                    
                    Button {
                        vm.exportAllLogs()
                    } label: {
                        Label(
                            vm.exportType == .both ? "Export All" :
                            "Export \(vm.exportType.rawValue)",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
                .cardStyle(.compact, padded: false)
            }
        }
    }
    
    /// Native-style segmented control: bordered track, thin separators between
    /// options (hidden next to the selected one, like AppKit), and an accent-filled
    /// selected segment so it's obvious these are pick-one options.
    private var exportSelector: some View {
        let cases = LogsViewModel.ExportType.allCases
        return HStack(spacing: 0) {
            ForEach(Array(cases.enumerated()), id: \.element) { index, type in
                let isSelected = vm.exportType == type

                Button {
                    vm.exportType = type
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: exportIcon(for: type))
                        Text(type.rawValue)
                    }
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Separator between two adjacent, unselected segments (AppKit-style).
                if index < cases.count - 1 {
                    Divider()
                        .frame(height: 14)
                        .opacity((isSelected || vm.exportType == cases[index + 1]) ? 0 : 0.4)
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(width: 280)
        .animation(.easeInOut(duration: 0.15), value: vm.exportType)
    }

    /// Resolves the SF Symbol associated with the chosen log export format.
    /// - Parameter type: The selected serialization layout targeted for disk export.
    /// - Returns: The corresponding SF Symbol identifier string.
    private func exportIcon(for type: LogsViewModel.ExportType) -> String {
        switch type.rawValue {
        case "Terminal": return "terminal"
        case "System":   return "gearshape"
        default:         return "square.on.square" // Both
        }
    }

    // MARK: - Log Card
    
    private func logCard(
        title: String,
        icon: String,
        logs: String,
        autoScroll: Binding<Bool>,
        emptyMessage: String,
        scrollId: String,
        height: CGFloat,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
            
            SectionDivider()
            
            // Controls
            HStack {
                Toggle(isOn: autoScroll) {
                    Label("Auto-scroll", systemImage: "arrow.down.to.line")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                
                Spacer()
                
                Button {
                    onClear()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .labelStyle(.matched)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
                Button {
                    vm.copyToClipboard(logs, type: title)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.matched)
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            
            SectionDivider()
            
            // Log Content
            ScrollViewReader { proxy in
                ScrollView {
                    if logs.isEmpty {
                        EmptyStateView(
                            icon: icon,
                            message: emptyMessage,
                            detail: "Activity will appear here as you use the app",
                            iconSize: 24,
                            verticalPadding: 20
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: height - 60) // Center in available space
                    } else {
                        // A `LazyVStack` around a single `Text` virtualizes nothing
                        // and just adds layout overhead — render the Text directly (R2/R6).
                        Text(logs)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .id(scrollId)
                    }
                }
                .frame(height: height) // Dynamic Height
                .codePanel()
                .onChange(of: logs) { _, _ in
                    if autoScroll.wrappedValue {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(scrollId, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }
}
