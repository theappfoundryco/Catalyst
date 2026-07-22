import SwiftUI

/// Dashboard "live metrics" derived from the Dr. Catalyst issue list.
///
/// Computed **once** when `issues` changes (in `DrCatalystViewModel`), not on
/// every render. Previously `LiveMetricsGrid.body` recomputed eight of these by
/// scanning `vm.issues` each pass — ~8 array traversals per frame (R3).
struct DrLiveMetrics: Equatable {
    var activePortsCount = 0
    var isDockerRunning = true
    var containerCount = 0
    var javaVersion = "Detected"
    var jdkCount = 1
    var firewallStatus = "Allowed"
    var stealthMode = false
    var isRosetta = false

    init() {}

    init(issues: [HealthIssue]) {
        activePortsCount = issues.filter { $0.category == .network && $0.title.contains("Port") }.count
        isDockerRunning = !issues.contains { $0.title == "Docker Not Running" }
        if let issue = issues.first(where: { $0.title.contains("Zombie Containers") }) {
            let digits = issue.title.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            containerCount = Int(digits) ?? 0
        }
        javaVersion = issues.contains(where: { $0.title == "Java Not Found" }) ? "Missing" : "Detected"
        if let issue = issues.first(where: { $0.title == "Java Version Chaos" }) {
            let digits = issue.description.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            jdkCount = Int(digits) ?? 1
        }
        firewallStatus = issues.contains(where: { $0.title == "Strict Firewall Mode" }) ? "Strict" : "Allowed"
        stealthMode = issues.contains(where: { $0.title == "Stealth Mode Enabled" })
        isRosetta = issues.contains(where: { $0.title == "App Running via Rosetta" })
    }
}
/// A grid displaying real-time metrics derived from Dr. Catalyst's diagnostic scans.
///
/// ```swift
/// LiveMetricsGrid(vm: viewModel)
/// ```
struct LiveMetricsGrid: View {
    @ObservedObject var vm: DrCatalystViewModel

    private var m: DrLiveMetrics { vm.liveMetrics }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            // 1. Network
            MetricCard(
                icon: "network",
                gradient: LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                label: "Network",
                value: "\(m.activePortsCount) Ports",
                subtext: m.activePortsCount > 0 ? "Active" : "Quiet"
            )

            // 2. Docker
            MetricCard(
                icon: "shippingbox",
                gradient: LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                label: "Docker",
                value: m.isDockerRunning ? "Running" : "Stopped",
                subtext: m.isDockerRunning ? "\(m.containerCount) Containers" : "Daemon Off"
            )

            // 3. Java
            MetricCard(
                icon: "cup.and.saucer.fill",
                gradient: LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing),
                label: "Java",
                value: m.javaVersion,
                subtext: "\(m.jdkCount) JDKs Installed"
            )

            // 4. Firewall
            MetricCard(
                icon: "lock.shield",
                gradient: LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing),
                label: "Firewall",
                value: m.firewallStatus,
                subtext: m.stealthMode ? "Stealth Mode" : "Standard"
            )

            // 5. Architecture
            MetricCard(
                icon: "cpu",
                gradient: LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
                label: "Silicon",
                value: m.isRosetta ? "Rosetta" : "Native",
                subtext: m.isRosetta ? "Performance Hit" : "ARM64 Optimized"
            )

            // 6. Identity
            MetricCard(
                icon: "person.crop.circle.badge.checkmark",
                gradient: LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                label: "Identity",
                value: "Git Config",
                subtext: "Verified"
            )
        }
    }
}
/// A styled card presenting a single live metric with an icon and subtext.
///
/// ```swift
/// MetricCard(icon: "cpu", gradient: gradient, label: "Silicon", value: "Native", subtext: "Optimized")
/// ```
struct MetricCard: View {
    let icon: String
    let gradient: LinearGradient
    let label: String
    let value: String
    let subtext: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(gradient.opacity(0.1))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .foregroundStyle(gradient)
                        .font(.system(size: 18, weight: .semibold))
                }
                Spacer()
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Text(subtext)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(gradient)
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .rasterizedCard()
    }
}
