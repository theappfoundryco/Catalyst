import SwiftUI
/// A view for managing user login items and launch agents, and inspecting system daemons.
///
/// ```swift
/// LoginItemsView(vm: loginItemsViewModel)
/// ```
struct LoginItemsView: View {
    @ObservedObject var vm: LoginItemsViewModel

    @State private var pendingRemoval: RemovalTarget?

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Startup Items",
                    subtitle: "Login Items & Launch Agents",
                    image: "power",
                    color: .orange
                )

                BannerView(.tip, message: "Only your user Launch Agents can be toggled or removed here. System agents and daemons are shown read-only — reveal them in Finder to inspect.")

                switch vm.state {
                case .idle:
                    readyView
                case .scanning where vm.report == nil:
                    scanningView
                default:
                    if let report = vm.report {
                        reportContent(report)
                    } else {
                        scanningView
                    }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Startup Items")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.state == .scanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await vm.scan() } } label: {
                        Label("Re-Scan", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { if vm.state == .idle { await vm.scan() } }
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let target = pendingRemoval { Task { await target.perform(vm) } }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval?.message ?? "")
        }
    }

    // MARK: - Report

    @ViewBuilder
    /// - Parameter report: The compiled structural report outlining daemon metadata.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func reportContent(_ report: LoginItemsReport) -> some View {
        VStack(spacing: 24) {
            LazyVGrid(columns: metricColumns, spacing: 16) {
                StartupMetricTile(icon: "person.crop.circle", title: "Login Items",
                                  value: "\(report.loginItems.count)", color: .blue)
                StartupMetricTile(icon: "gearshape.2.fill", title: "User Agents",
                                  value: "\(report.userAgents.count)", color: .orange)
                StartupMetricTile(icon: "lock.shield", title: "System Jobs",
                                  value: "\(report.systemAgents.count)", color: .purple)
            }
            .padding(.horizontal)

            if !report.loginItems.isEmpty {
                section(title: "Login Items", subtitle: "Open at login (System Events)", icon: "person.crop.circle") {
                    ForEach(report.loginItems) { item in
                        loginItemRow(item)
                        if item.id != report.loginItems.last?.id { SectionDivider() }
                    }
                }
            }

            section(title: "User Launch Agents", subtitle: "~/Library/LaunchAgents · manageable", icon: "gearshape.2.fill") {
                if report.userAgents.isEmpty {
                    Text("No user launch agents found.").font(.subheadline).foregroundColor(.secondary)
                } else {
                    ForEach(report.userAgents) { agent in
                        agentRow(agent, manageable: true)
                        if agent.id != report.userAgents.last?.id { SectionDivider() }
                    }
                }
            }

            if !report.systemAgents.isEmpty {
                section(title: "System Agents & Daemons", subtitle: "/Library · read-only", icon: "lock.shield") {
                    ForEach(report.systemAgents) { agent in
                        agentRow(agent, manageable: false)
                        if agent.id != report.systemAgents.last?.id { SectionDivider() }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    /// - Parameter item: The structured payload capturing active daemon state.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func loginItemRow(_ item: LoginItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "app.fill").foregroundColor(.blue).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline).fontWeight(.semibold)
                if !item.path.isEmpty {
                    Text(item.path).font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if item.hidden {
                Text("Hidden").font(.caption2).foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12)).cornerRadius(4)
            }
            if vm.busyItemID == item.id {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    pendingRemoval = .loginItem(item)
                } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .appButton(.borderless)
                .help("Remove from login items")
            }
        }
        .padding(.vertical, 6)
    }

    /// Visualizes a single background launch daemon and its current execution state.
    /// - Parameters:
    ///   - agent: The structured payload capturing the XML launch daemon.
    ///   - manageable: Determines if administrative privileges currently allow toggling.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func agentRow(_ agent: LaunchAgentItem, manageable: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(agent.isLoaded ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.label).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                Text(agent.program).font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer()

            Text(agent.scope.label)
                .font(.caption2).foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1)).cornerRadius(4)

            if vm.busyItemID == agent.id {
                ProgressView().controlSize(.small)
            } else if manageable {
                Toggle("", isOn: Binding(
                    get: { agent.isLoaded },
                    set: { _ in Task { await vm.toggleAgent(agent) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                Button {
                    pendingRemoval = .agent(agent)
                } label: {
                    Image(systemName: "trash").foregroundColor(.red)
                }
                .appButton(.borderless)
                .help("Unload and move plist to Trash")
            } else {
                Button {
                    vm.reveal(path: agent.plistPath)
                } label: {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                }
                .appButton(.borderless)
                .help("Reveal in Finder")
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Section container

    @ViewBuilder
    private func section<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            content()
        }
        .cardStyle()
    }

    // MARK: - Empty / loading

    private var readyView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Loading startup items…").font(.headline)
        }.padding(40).frame(maxWidth: .infinity).padding(.horizontal)
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning startup items…").font(.headline)
        }.padding(40).frame(maxWidth: .infinity).padding(.horizontal)
    }
}

// MARK: - Removal confirmation target

private enum RemovalTarget {
    case agent(LaunchAgentItem)
    case loginItem(LoginItem)

    var title: String { "Remove Startup Item?" }

    var message: String {
        switch self {
        case .agent(let a): return "“\(a.label)” will be unloaded and its plist moved to the Trash."
        case .loginItem(let i): return "“\(i.name)” will be removed from your login items."
        }
    }

    @MainActor
    /// Executes a standardized state transition for the underlying view model.
    /// - Parameter vm: The active view model instance driving interface mutations.
    func perform(_ vm: LoginItemsViewModel) async {
        switch self {
        case .agent(let a): await vm.removeAgent(a)
        case .loginItem(let i): await vm.removeLoginItem(i)
        }
    }
}

// MARK: - Metric tile
/// A metric tile displaying an icon, title, and count for startup item categories.
///
/// ```swift
/// StartupMetricTile(icon: "gearshape.2.fill", title: "User Agents", value: "5", color: .orange)
/// ```
private struct StartupMetricTile: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12)).frame(width: 38, height: 38)
                Image(systemName: icon).foregroundColor(color).font(.system(size: 18, weight: .semibold))
            }
            Text(value).font(.system(.title2, design: .rounded)).fontWeight(.bold)
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
