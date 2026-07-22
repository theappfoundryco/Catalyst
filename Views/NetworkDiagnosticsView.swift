import SwiftUI
/// A view for running and analyzing network diagnostics, including ping, DNS resolution, and active ports.
///
/// ```swift
/// NetworkDiagnosticsView(vm: networkViewModel)
/// ```
struct NetworkDiagnosticsView: View {
    @ObservedObject var vm: NetworkDiagnosticsViewModel

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Network Diagnostics",
                    subtitle: "Connectivity, DNS & Listening Ports",
                    image: "network",
                    color: .teal
                )

                controlBar

                switch vm.state {
                case .idle:
                    readyView
                case .running where vm.report == nil:
                    runningView
                default:
                    if let report = vm.report {
                        reportContent(report)
                    } else {
                        runningView
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Network Diagnostics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.state == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        vm.reset()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reset diagnostics")
                    .disabled(vm.report == nil && vm.state == .idle)
                }
            }
        }
    }

    // MARK: - Control bar (targets + run)

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Diagnostic Targets").font(.headline)

            SectionDivider()

            Text("Ping a host to measure reachability and latency, and resolve a domain to test DNS. Running also reports your active network interface and which apps are listening on TCP ports.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 12) {
                CompactInputField(label: "Ping host", icon: "dot.radiowaves.left.and.right",
                                  placeholder: "e.g. 1.1.1.1", text: $vm.pingHost)

                CompactInputField(label: "DNS lookup", icon: "globe",
                                  placeholder: "e.g. github.com", text: $vm.dnsHost)
            }

            HStack {
                Spacer()
                Button {
                    Task { await vm.run() }
                } label: {
                    if vm.state == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Label("Run Diagnostics", systemImage: "bolt.fill")
                            .labelStyle(.matched)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(vm.state == .running)
            }
        }
        .cardStyle()
    }

    // MARK: - Report

    @ViewBuilder
    /// - Parameter report: The generated diagnostic payload tracking connection metrics.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func reportContent(_ report: NetworkDiagnosticsReport) -> some View {
        VStack(spacing: 24) {
            /// Top metrics
            ///
            /// **Rationale:** Hero placement provides an immediate pulse on the active connection without forcing the user to scroll through routing tables.
            LazyVGrid(columns: metricColumns, spacing: 16) {
                MetricTile(
                    icon: report.internetPing.reachable ? "wifi" : "wifi.slash",
                    title: "Internet",
                    value: report.internetPing.reachable ? report.internetPing.latencyLabel : "Offline",
                    subtitle: report.internetPing.reachable
                        ? "\(Int(report.internetPing.packetLossPercent ?? 0))% loss · \(report.internetPing.host)"
                        : "No reply from \(report.internetPing.host)",
                    color: report.internetPing.reachable ? latencyColor(report.internetPing.avgLatencyMs) : .red
                )

                MetricTile(
                    icon: "arrow.triangle.2.circlepath",
                    title: "DNS",
                    value: report.dns.succeeded ? report.dns.queryLabel : "Failed",
                    subtitle: report.dns.succeeded
                        ? "\(report.dns.resolvedIPs.count) record(s) · \(report.dns.host)"
                        : "Could not resolve \(report.dns.host)",
                    color: report.dns.succeeded ? .blue : .red
                )

                if let gw = report.gatewayPing {
                    MetricTile(
                        icon: "house.fill",
                        title: "Gateway",
                        value: gw.reachable ? gw.latencyLabel : "Unreachable",
                        subtitle: report.interfaceInfo?.gateway ?? gw.host,
                        color: gw.reachable ? latencyColor(gw.avgLatencyMs) : .orange
                    )
                } else {
                    MetricTile(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Ports",
                        value: "\(report.listeningPorts.count)",
                        subtitle: "TCP listening",
                        color: .purple
                    )
                }
            }
            .padding(.horizontal)

            if let iface = report.interfaceInfo {
                interfaceCard(iface, ports: report.listeningPorts.count)
            }

            dnsCard(report.dns)

            portsCard(report.listeningPorts)
        }
    }

    // MARK: - Interface card

    /// - Parameters:
    ///   - iface: The designated hardware routing path mapped to IP strings.
    ///   - ports: The count of total active listening sockets bound to the interface.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func interfaceCard(_ iface: NetworkInterfaceInfo, ports: Int) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader("Active Connection", subtitle: "Default Route Interface", icon: "point.3.connected.trianglepath.dotted")
            HStack(spacing: 0) {
                infoCell("Interface", iface.interface, "cable.connector")
                SectionDivider().frame(height: 40)
                infoCell("Local IP", iface.localIP, "laptopcomputer")
                SectionDivider().frame(height: 40)
                infoCell("Gateway", iface.gateway, "house")
                SectionDivider().frame(height: 40)
                infoCell("Listening", "\(ports) ports", "antenna.radiowaves.left.and.right")
            }
        }
        .cardStyle()
    }

    // MARK: - DNS card

    /// - Parameter dns: The extracted resolution configuration and external server pings.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func dnsCard(_ dns: DNSResult) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeader("DNS Resolution", subtitle: dns.host, icon: "globe")

            if dns.succeeded {
                FlowChips(items: dns.resolvedIPs, color: .blue)
            } else {
                Text("No A/AAAA records resolved.")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }

            if !dns.servers.isEmpty {
                SectionDivider()
                Text("System Resolvers")
                    .font(.caption).fontWeight(.medium).foregroundColor(.secondary)
                FlowChips(items: dns.servers, color: .teal)
            }
        }
        .cardStyle()
    }

    // MARK: - Ports card

    /// - Parameter ports: An array enumerating globally listening application sockets.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func portsCard(_ ports: [ListeningPort]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Listening Ports", subtitle: "\(ports.count) open TCP sockets", icon: "lock.open.rotation")

            if ports.isEmpty {
                Text("No listening TCP ports detected.")
                    .font(.subheadline).foregroundColor(.secondary)
            } else {
                ForEach(ports) { port in
                    HStack(spacing: 12) {
                        Text(":\(port.port)")
                            .font(.system(.body, design: .monospaced)).fontWeight(.bold)
                            .foregroundColor(.purple)
                            .frame(width: 70, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(port.process).font(.subheadline).fontWeight(.semibold)
                            Text("PID \(port.pid) · \(port.proto)")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    if port.id != ports.last?.id { SectionDivider() }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Shared bits

    /// - Parameters:
    ///   - title: The primary display title of the diagnostic card.
    ///   - subtitle: An optional context string beneath the primary header.
    ///   - icon: The associated SF Symbol glyph.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func cardHeader(_ title: String, subtitle: String, icon: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    /// Renders a single diagnostic property alongside a contextual system icon.
    /// - Parameters:
    ///   - label: The descriptive classification mapped to the value.
    ///   - value: The actual configuration property.
    ///   - icon: The corresponding visual representation.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func infoCell(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(.secondary)
            Text(value).font(.system(.subheadline, design: .rounded)).fontWeight(.semibold).lineLimit(1)
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Maps connection latency in milliseconds to a semantic warning color.
    /// - Parameter ms: The measured round-trip time in milliseconds.
    /// - Returns: A mapped standard layout color.
    private func latencyColor(_ ms: Double?) -> Color {
        guard let ms else { return .secondary }
        switch ms {
        case ..<40: return .green
        case ..<120: return .orange
        default: return .red
        }
    }

    private var readyView: some View {
        /// Illustrative empty state only — the single Run button lives in the
        /// "Diagnostic Targets" card above (deduped).
        ///
        /// **Gotchas:** Adding a secondary "Run Diagnostics" button here creates confusing focus-state conflicts for keyboard navigation users.
        VStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 52))
                .foregroundStyle(LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("No results yet").font(.headline)
            Text("Set your targets above, then press Run Diagnostics.")
                .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .padding(50).frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor)).cornerRadius(16)
        .padding(.horizontal)
    }

    private var runningView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Probing network…").font(.headline)
        }
        .padding(40).frame(maxWidth: .infinity)
        .padding(.horizontal)
    }
}

// MARK: - Metric tile
/// A compact metric tile used in the Network Diagnostics report to show high-level status.
///
/// ```swift
/// MetricTile(icon: "wifi", title: "Internet", value: "12ms", subtitle: "0% loss", color: .green)
/// ```
private struct MetricTile: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 38, height: 38)
                Image(systemName: icon).foregroundColor(color).font(.system(size: 18, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(value).font(.system(.headline, design: .rounded)).fontWeight(.bold)
                Text(subtitle).font(.caption2).foregroundColor(.secondary).lineLimit(2)
            }
            Text(title).font(.caption).fontWeight(.medium).foregroundColor(color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .rasterizedCard()
    }
}

// MARK: - Wrapping chips
/// A layout helper that flows text chips (e.g., IP addresses) gracefully onto multiple lines.
///
/// ```swift
/// FlowChips(items: ["1.1.1.1", "1.0.0.1"], color: .blue)
/// ```
private struct FlowChips: View {
    let items: [String]
    let color: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(color.opacity(0.12))
                    .foregroundColor(color)
                    .cornerRadius(6)
                    .lineLimit(1)
            }
        }
    }
}
