/// Subview components extracted from DrCatalystView for better modularity.

import SwiftUI

// MARK: - Diagnostic Grid
/// A grid layout displaying multiple system diagnostic statuses.
///
/// ```swift
/// DiagnosticGrid(statuses: statuses, issues: issues) { await refresh() }
/// ```
struct DiagnosticGrid: View {
    let statuses: [DoctorStatus]
    let issues: [HealthIssue]
    let onRefresh: () async -> Void
    @State private var isRefreshing = false
    
    let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Diagnostic Log")
                        .font(.headline)
                    Text("System Health Checks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            isRefreshing = true
                            // Wait 1.5s first, THEN refresh
                            try? await Task.sleep(for: .seconds(1.5))
                            await onRefresh()
                            isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh Diagnostics")
                }
            }
            
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(statuses) { status in
                    DiagnosticStatusCard(status: status, issues: issues.filter { $0.category == status.category })
                        .zIndex(status.status.isPassed ? 0 : 1)
                }
            }
        }
        .cardStyle(padded: false)
    }
}

// MARK: - Diagnostic Status Card
/// A card representing the status of a specific diagnostic category.
///
/// ```swift
/// DiagnosticStatusCard(status: status, issues: categoryIssues)
/// ```
struct DiagnosticStatusCard: View {
    let status: DoctorStatus
    let issues: [HealthIssue]
    @State private var isHovering = false
    
    var statusIcon: String {
        switch status.status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .skipped: return "minus.circle.fill"
        case .notInstalled: return "circle.dashed"
        }
    }

    var statusColor: Color {
        switch status.status {
        case .passed: return .green
        case .failed: return .red
        case .skipped, .notInstalled: return .secondary
        }
    }

    var statusTitle: String {
        switch status.status {
        case .passed: return "All checks passed"
        case .failed(let count): return "\(count) issue\(count == 1 ? "" : "s") found"
        case .skipped: return "Check skipped"
        case .notInstalled: return "Not installed"
        }
    }

    var statusDetail: String? {
        switch status.status {
        case .passed:
            return "\(status.category.rawValue) is healthy."
        case .failed:
            let titles = issues.prefix(3).map { "• \($0.title)" }.joined(separator: "\n")
            let suffix = issues.count > 3 ? "\n…and \(issues.count - 3) more" : ""
            return titles + suffix
        case .skipped:
            return "Not applicable on this Mac."
        case .notInstalled:
            return "\(status.category.rawValue) tooling isn't present."
        }
    }

    /// A small, native-feeling info card shown above the row on hover.
    private var tooltipCard: some View {
        VStack(alignment: .leading, spacing: statusDetail == nil ? 0 : 5) {
            HStack(spacing: 7) {
                Image(systemName: statusIcon)
                    .font(.callout)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.callout.weight(.semibold))
            }
            if let detail = statusDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
    }
    
    var icon: String {
        switch status.category {
        case .shell: return "terminal.fill"
        case .path: return "signpost.right.and.left"
        case .tools: return "hammer.fill"
        case .permissions: return "hand.raised.fill"
        case .network: return "network"
        case .container: return "shippingbox.fill"
        case .disk: return "internaldrive.fill"
        case .security: return "lock.shield.fill"
        case .architecture: return "cpu"
        case .java: return "cup.and.saucer.fill"
        case .firewall: return "flame.fill"
        case .startup: return "clock.arrow.circlepath"
        case .node: return "hexagon.fill"
        case .memory: return "memorychip"
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
            
            Text(status.category.rawValue)
                .font(.caption)
                .lineLimit(1)
            
            Spacer()
            
            switch status.status {
            case .passed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .failed(let count):
                Text("\(count)")
                    .font(.caption.bold())
                    .padding(4)
                    .background(Color.red.opacity(0.1))
                    .foregroundColor(.red)
                    .cornerRadius(4)
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundColor(.secondary)
            case .notInstalled:
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
        // Native-feeling hover tooltip, floated cleanly above the row.
        // alignmentGuide pushes it fully above regardless of its height.
        .overlay(alignment: .top) {
            if isHovering {
                tooltipCard
                    .fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isHovering ? 100 : 0)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Enhanced Healthy State View
/// A celebratory view displayed when all Dr. Catalyst checks pass.
///
/// ```swift
/// EnhancedHealthyStateView()
/// ```
struct EnhancedHealthyStateView: View {
    @State private var pulse = false
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 120, height: 120)
                    .scaleEffect(pulse ? 1.2 : 1.0)
                    .opacity(pulse ? 0.0 : 0.5)
                    .animation(Animation.easeOut(duration: 2.5).repeatForever(autoreverses: false), value: pulse)
                
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.green)
                    .symbolEffect(.bounce, value: pulse)
            }
            .onAppear { pulse = true }
            
            VStack(spacing: 8) {
                Text("All Systems Operational")
                    .font(.title2.bold())
                
                Text("Your core development environment is secure.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color.green.opacity(0.05), Color.clear], startPoint: .top, endPoint: .bottom))
        )
    }
}

// MARK: - Ghost Buster View
/// A view dedicated to scanning for and terminating ghost processes holding network ports.
///
/// ```swift
/// GhostBusterView(vm: viewModel)
/// ```
struct GhostBusterView: View {
    @ObservedObject var vm: GhostBusterViewModel
    @State private var isRefreshing = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                        Text("Ghost Buster")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Active Port & Process Monitor")
                            .font(.caption)
                            .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if !vm.ghosts.isEmpty {
                    Button {
                        Task {
                            await vm.killAllGhosts()
                        }
                    } label: {
                        Label("Kill All", systemImage: "flame.fill")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                
                if vm.isScanning || isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            isRefreshing = true
                            // Wait 1.5s first, THEN scan
                            try? await Task.sleep(for: .seconds(1.5))
                            await vm.scan()
                            isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Rescan Ports")
                }
            }
            
            if vm.ghosts.isEmpty {
                // Empty State
                EmptyStateView(
                    icon: "checkmark.shield",
                    message: "No ghosts found",
                    detail: "All common ports are clear",
                    iconColor: .green.opacity(0.8)
                )
            } else {
                // Ghost List
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(vm.ghosts) { ghost in
                        GhostProcessCard(ghost: ghost) {
                            Task {
                                await vm.killProcess(ghost)
                            }
                        }
                    }
                }
            }
        }
        .cardStyle(padded: false)
        .onAppear {
            Task {
                await vm.scan()
            }
        }
    }
}

// MARK: - Ghost Process Card
/// A card displaying details of a single ghost process with a kill action.
///
/// ```swift
/// GhostProcessCard(ghost: process) { kill() }
/// ```
struct GhostProcessCard: View {
    let ghost: GhostProcess
    let onKill: () -> Void
    @State private var isHovering = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: ghost.icon)
                    .font(.title2)
                    .foregroundColor(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(Circle())
                
                Spacer()
                
                Text(String(ghost.port))
                    .font(.caption.monospaced())
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .foregroundColor(.blue)
                    .cornerRadius(4)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(ghost.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .help(ghost.name) // Full name in tooltip
                
                Text("PID: \(ghost.pid)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Button(action: onKill) {
                HStack {
                    Image(systemName: "xmark.circle.fill")
                    Text("Kill")
                }
                .font(.caption.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(isHovering ? Color.red : Color.red.opacity(0.1))
            .foregroundColor(isHovering ? .white : .red)
            .cornerRadius(6)
            .animation(.easeInOut(duration: 0.1), value: isHovering)
            .onHover { isHovering = $0 }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
        )
    }
}
