import SwiftUI
/// A view for managing the system `$PATH` environment variable, allowing users to reorder, clean up, and remove entries.
///
/// ```swift
/// PathEditorView(vm: pathEditorViewModel)
/// ```
struct PathEditorView: View {
    @ObservedObject var vm: PathEditorViewModel

    private let metricColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "PATH Editor",
                    subtitle: "Inspect, Clean & Reorder Your $PATH",
                    image: "arrow.left.arrow.right.square.fill",
                    color: .pink
                )

                switch vm.state {
                case .idle, .scanning where vm.original.isEmpty:
                    scanningView
                default:
                    content
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("PATH Editor")
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
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 24) {
            LazyVGrid(columns: metricColumns, spacing: 16) {
                PathMetricTile(icon: "list.number", title: "Entries", value: "\(vm.working.count)", color: .pink)
                PathMetricTile(icon: "doc.on.doc", title: "Duplicates", value: "\(vm.duplicateCount)",
                               color: vm.duplicateCount > 0 ? .orange : .green)
                PathMetricTile(icon: "xmark.bin", title: "Dead Dirs", value: "\(vm.deadCount)",
                               color: vm.deadCount > 0 ? .red : .green)
            }
            .padding(.horizontal)

            if vm.deadCount > 0 || vm.duplicateCount > 0 {
                cleanupCard
            }

            entriesCard

            if vm.hasOverride {
                restoreCard
            }
        }
    }

    // MARK: - Cleanup card

    private var cleanupCard: some View {
        let issues = vm.deadCount + vm.duplicateCount
        return VStack(alignment: .leading, spacing: 12) {
            Text("Tidy Up").font(.headline)
            SectionDivider()
            Text("Remove broken (missing) directories and duplicate entries in one step. Your changes save automatically.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Spacer()
                Button { vm.clean() } label: {
                    Label("Clean Up \(issues) Issue\(issues == 1 ? "" : "s")", systemImage: "wand.and.sparkles")
                        .labelStyle(.matched)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }
        }
        .cardStyle()
    }

    // MARK: - Saved-order / restore card

    private var restoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved Order").font(.headline)
            SectionDivider()
            Text("Catalyst saved your PATH order so newly opened terminal windows use it. Restore the default to hand ordering back to your system.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if let msg = vm.statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(role: .destructive) { vm.removeOverride() } label: {
                    Label("Restore Default", systemImage: "arrow.uturn.backward")
                        .labelStyle(.matched)
                }
                .buttonStyle(.bordered)
            }
        }
        .cardStyle()
    }

    private var entriesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PATH Entries").font(.headline)
                    Text("Directories are searched top → bottom").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.left.arrow.right.square.fill")
                    .font(.title2)
                    .foregroundStyle(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }

            Text("Reorder with the arrows or remove with the trash — changes save automatically and apply to newly opened terminals. This list shows your current session.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            SectionDivider()

            ForEach(Array(vm.working.enumerated()), id: \.element.id) { index, entry in
                entryRow(entry, index: index)
                if entry.id != vm.working.last?.id { SectionDivider() }
            }
        }
        .cardStyle()
    }

    /// Renders a single PATH configuration directory and its associated validation state.
    /// - Parameters:
    ///   - entry: The structured configuration detailing the directory route.
    ///   - index: The numerical stack hierarchy denoting priority.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func entryRow(_ entry: PathEntry, index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .trailing)

            Circle()
                .fill(entry.isDead ? Color.red : (entry.isDuplicate ? Color.orange : Color.green))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                if entry.isDead || entry.isDuplicate {
                    HStack(spacing: 6) {
                        if !entry.exists { tag("Missing", .red) }
                        else if !entry.isDirectory { tag("Not a dir", .red) }
                        if entry.isDuplicate { tag("Duplicate", .orange) }
                    }
                }
            }

            Spacer()

            Button { vm.moveUp(entry) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(index == 0).help("Move up")
            Button { vm.moveDown(entry) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(index == vm.working.count - 1).help("Move down")
            Button { vm.reveal(entry) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless).disabled(!entry.exists).help("Reveal in Finder")
            Button { vm.remove(entry) } label: { Image(systemName: "trash").foregroundColor(.red) }
                .buttonStyle(.borderless).help("Remove from list")
        }
        .padding(.vertical, 6)
    }

    /// A stylized visual badge indicating contextual attributes of a PATH entry.
    /// - Parameters:
    ///   - text: The primary string label for the tag.
    ///   - color: The designated semantic hue for background filling.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.semibold)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15)).foregroundColor(color).cornerRadius(4)
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Reading $PATH…").font(.headline)
        }.padding(40).frame(maxWidth: .infinity).padding(.horizontal)
    }
}
/// A summary metric tile used in the PATH Editor.
///
/// ```swift
/// PathMetricTile(icon: "doc.on.doc", title: "Duplicates", value: "2", color: .orange)
/// ```
private struct PathMetricTile: View {
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
