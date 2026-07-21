import SwiftUI

struct DrCatalystView: View {
    @ObservedObject var vm: DrCatalystViewModel
    @State private var isRefreshing = false
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Dr. Catalyst",
                    subtitle: "Deep system diagnostics and environment health check",
                    image: "stethoscope",
                    color: .purple // Using purple as primary from gradient
                )
                .padding(.top)
                
                // Dashboard Stats (Gauge + Info)
                dashboardHeader
                
                // Diagnostic Grid
                DiagnosticGrid(statuses: vm.doctorStatuses, issues: vm.issues, onRefresh: {
                    await vm.scan()
                })
                
                // Live Metrics Grid
                LiveMetricsGrid(vm: vm)
                
                // Charts and History
                if !vm.history.isEmpty {
                     HealthTrendChart(history: vm.history)
                }
                
                // STORAGE MATRIX
                if let report = vm.storageReport {
                    StorageDNAView(report: report)
                }
                
                // GhostBuster Section
                GhostBusterView(vm: vm.ghostBusterVM)
                
                // ISSUES STACK
                if vm.isScanning {
                    ContentUnavailableView("Scanning System...", systemImage: "magnifyingglass")
                } else {
                    // 1. Show Issues (Warnings/Info) FIRST
                    issueGroupsView
                    
                    // 2. Show "Healthy" block at the VERY BOTTOM
                    // Only if no CRITICAL issues exist (yellow warnings are fine)
                    if !vm.issues.contains(where: { $0.severity == .critical }) {
                        EnhancedHealthyStateView()
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Dr. Catalyst")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if isRefreshing || vm.isScanning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            isRefreshing = true
                            try? await Task.sleep(for: .seconds(1.5))
                            await vm.scan()
                            isRefreshing = false
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .onAppear {
            if vm.issues.isEmpty && vm.history.isEmpty && !vm.isScanning {
                Task {
                    await vm.scan()
                }
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var issueGroupsView: some View {
        // Single grouping pass instead of re-filtering vm.issues six times per body.
        let grouped = Dictionary(grouping: vm.issues, by: { $0.severity })
        let critical = grouped[.critical] ?? []
        let warning = grouped[.warning] ?? []
        let info = grouped[.info] ?? []
        return VStack(spacing: 24) {
            if !critical.isEmpty {
                IssueGroup(title: "CRITICAL", color: .red, issues: critical, onFix: vm.fix)
            }

            if !warning.isEmpty {
                IssueGroup(title: "WARNINGS", color: .orange, issues: warning, onFix: vm.fix)
            }

            if !info.isEmpty {
                IssueGroup(title: "INSIGHTS", color: .blue, issues: info, onFix: vm.fix)
            }
        }
    }
    
    private var dashboardHeader: some View {
        HStack(spacing: 0) {
            // 1. Vitality Gauge + Label
            VStack(spacing: 20) {
                Text("System Vitality")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Gauge(value: Double(vm.currentScore), in: 0...100) {
                    // Not shown when using .accessoryCircular
                } currentValueLabel: {
                    Text("\(vm.currentScore)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(vm.currentScore > 80 ? .green : (vm.currentScore > 50 ? .orange : .red))
                .scaleEffect(1.4)
            }
            .frame(maxWidth: .infinity)
            
            SectionDivider()
                .frame(height: 100)
            
            // 2. Issues Count
            StatColumnHeader(label: "Issues", value: "\(vm.issues.count)", subtext: vm.issues.isEmpty ? "All Clear" : "Found")
                .frame(maxWidth: .infinity)
            
            SectionDivider()
                .frame(height: 100)
            
            // 3. Scans
            StatColumnHeader(label: "Scans", value: "\(vm.history.count)", subtext: "Total")
                .frame(maxWidth: .infinity)
            
            SectionDivider()
                .frame(height: 100)
            
            // 4. Last Scan
            if let lastScan = vm.history.last?.date {
                StatColumnHeader(label: "Last Scan", value: lastScan.formatted(date: .omitted, time: .shortened), subtext: lastScan.formatted(date: .abbreviated, time: .omitted))
                    .frame(maxWidth: .infinity)
            } else {
                StatColumnHeader(label: "Last Scan", value: "Never", subtext: "Run Scan")
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 40)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
    }
    
    // Computeds
    var firewallStatus: String {
        if vm.issues.contains(where: { $0.title == "Strict Firewall Mode" }) { return "Strict" }
        return "Active"
    }
    
}

// MARK: - Issue Card

struct IssueCard: View {
    let issue: HealthIssue
    let onFix: () -> Void
    
    var severityColor: Color {
        switch issue.severity {
        case .critical: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(severityColor)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(issue.title)
                        .font(.headline)
                    Spacer()
                    Text(issue.category.rawValue)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }
                
                Text(issue.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                if issue.autoFixAvailable {
                    Button(action: onFix) {
                        Label("Fix Issue", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.small)
                }
            }
        }
        .cardStyle(padded: false)
    }
}
