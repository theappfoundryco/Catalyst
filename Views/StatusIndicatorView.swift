import SwiftUI
import Combine

/// Status indicator bar shown at the bottom of the sidebar
///
/// ```swift
/// StatusIndicatorView(networkMonitor: networkMonitor)
/// ```
struct StatusIndicatorView: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject private var installPrefs = InstallPreferences.shared
    @State private var showingPopover = false

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(networkMonitor.status.color)
                    .frame(width: 8, height: 8)

                Text(networkMonitor.status.label)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Integrity/install-mode shield: green = Protected, red = an override.
                Image(systemName: installPrefs.isOverrideActive
                      ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundColor(installPrefs.isOverrideActive ? .red : .green)

                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
        .help(networkMonitor.status.tooltip)
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            StatusPopoverView(networkMonitor: networkMonitor)
        }
    }
}

/// Expanded status popover with detailed system information
///
/// ```swift
/// StatusPopoverView(networkMonitor: networkMonitor)
/// ```
struct StatusPopoverView: View {
    @ObservedObject var networkMonitor: NetworkMonitor
    @ObservedObject private var installPrefs = InstallPreferences.shared
    @State private var isRefreshing = false
    @State private var pendingMode: PipInstallMode = .protected
    @State private var showModeConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Status")
                .font(.headline)
            
            SectionDivider()
            
            // Network
            StatusRow(
                icon: "network",
                label: "Network",
                status: networkMonitor.status.label,
                color: networkMonitor.status.color
            )
            
            // Homebrew
            StatusRow(
                icon: "mug.fill",
                label: "Homebrew",
                status: networkMonitor.isBrewInstalled ? "Installed" : "Not Installed",
                color: networkMonitor.isBrewInstalled ? .green : .red
            )
            
            // Python
            StatusRow(
                icon: "terminal.fill",
                label: "Python",
                status: "\(networkMonitor.pythonVersionCount) version\(networkMonitor.pythonVersionCount == 1 ? "" : "s")",
                color: networkMonitor.pythonVersionCount > 0 ? .green : .secondary
            )
            
            // Background Tasks
            if let task = networkMonitor.activeBackgroundTask {
                StatusRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Background",
                    status: task,
                    color: .blue,
                    isAnimating: true
                )
            } else {
                StatusRow(
                    icon: "checkmark.circle",
                    label: "Background",
                    status: "No active tasks",
                    color: .secondary
                )
            }
            
            SectionDivider()

            // App-wide install mode (PEP 668 override). Switching away from Protected
            // requires explicit consent; reverting to Protected is immediate (CODING_STANDARDS 2.7).
            installModeSection

            SectionDivider()

            // Refresh button — sized to match the dashboard "Install" button
            // (regular control size, default font).
            Button {
                Task {
                    isRefreshing = true
                    // Deliberate 2.5s delay before the actual refresh.
                    try? await Task.sleep(for: .seconds(2.5))
                    await networkMonitor.forceCheck()
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                        .labelStyle(.matched)
                }
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
        }
        .padding()
        .frame(width: 250)
        .confirmationDialog("Override system integrity?",
                            isPresented: $showModeConfirm, titleVisibility: .visible) {
            Button("Enable \(pendingMode.title)", role: .destructive) {
                installPrefs.mode = pendingMode
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingMode.confirmMessage)
        }
    }

    /// App-wide install-mode selector (PEP 668). A green/red shield mirrors the sidebar
    /// indicator; the menu changes the mode with consent for overrides.
    private var installModeSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundColor(installPrefs.isOverrideActive ? .red : .green)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text("Install Mode")
                    .font(.subheadline)
                Text(installPrefs.mode.menuSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Menu {
                ForEach(PipInstallMode.allCases) { mode in
                    Button { selectMode(mode) } label: {
                        if mode == installPrefs.mode {
                            Label(mode.title, systemImage: "checkmark")
                        } else {
                            Text(mode.title)
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Apply a mode: Protected is immediate; any override asks for confirmation first.
    /// - Parameter mode: The target operational state representing the user selection.
    private func selectMode(_ mode: PipInstallMode) {
        if mode == .protected {
            installPrefs.mode = .protected
        } else if mode != installPrefs.mode {
            pendingMode = mode
            showModeConfirm = true
        }
    }
}

/// Individual status row in the popover
///
/// ```swift
/// StatusRow(icon: "network", label: "Network", status: "Online", color: .green)
/// ```
struct StatusRow: View {
    let icon: String
    let label: String
    let status: String
    let color: Color
    var isAnimating: Bool = false
    
    @State private var rotation: Double = 0
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 16)
                .rotationEffect(.degrees(rotation))
                .animation(
                    isAnimating
                        ? .linear(duration: 1).repeatForever(autoreverses: false)
                        : .default,
                    value: rotation
                )
            
            Text(label)
                .font(.subheadline)
            
            Spacer()
            
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            if isAnimating {
                rotation = 360
            }
        }
    }
}

#Preview {
    StatusIndicatorView(networkMonitor: NetworkMonitor())
        .frame(width: 200)
        .padding()
}
