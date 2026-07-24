import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// The Git Graph screen (Developer Workflow).
///
/// Choose a repository (folder picker or drag-and-drop), see a read-only **Repository
/// summary** card and a GPU-rendered **commit graph** — per-lane colors, decorated refs.
///
/// Layout notes:
/// - The loaded state is one plain `ScrollView` (the documented interactive-content
///   exception, `CODING_STANDARDS.md` 3.1). Content is pinned to full width to avoid the
///   left-squeeze bug, and both cards use `cardStyle(padded: false)` so their edges align.
/// - The graph renders **per row** (each row draws only its own lane segments), so a long
///   history never builds one giant canvas layer — the previous scroll-jank cause.
/// - The graph card's title + legend is a **pinned section header**: it sits at the top of
///   the card, sticks to the top while scrolling, and drops back into place on scroll-up.
///
/// ```swift
/// GitGraphView(vm: gitGraphViewModel)
/// ```
struct GitGraphView: View {
    @ObservedObject var vm: GitGraphViewModel

    // Graph geometry lives in GraphMetrics; lane width adapts to the window.

    /// Shared horizontal-scroll offset for the graph's left region (gutter + message).
    /// The author + hash columns are frozen and never use this.
    @State private var graphHOffset: CGFloat = 0

    @State private var showFilters = false

    /// Total reserved width of the frozen right columns (depends on which are shown).
    private var rightColumnWidth: CGFloat {
        GraphMetrics.rightWidth(showAuthor: vm.options.showAuthor, showHash: vm.options.showHash)
    }

    var body: some View {
        content
            .navigationTitle("Git Graph")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if case .loading = vm.state {
                        ProgressView().controlSize(.small)
                    } else if case .loaded = vm.state {
                        filtersButton
                        optionsMenu
                        Button { vm.chooseRepository() } label: {
                            Label("Open Another", systemImage: "folder.badge.plus")
                        }
                        Button { vm.reload() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Reload this repository")
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $vm.isDropTargeted) { providers in
                vm.handleDrop(providers: providers)
            }
            // Fetch-affecting options (scope / order / merges / limit) → re-read the graph.
            .onChange(of: vm.options.fetchSignature) {
                vm.applyOptions()
            }
            // Persist options (display + fetch) per repo.
            .onChange(of: vm.options) {
                vm.persistOptions()
            }
            // Click a commit → detail panel.
            .sheet(item: $vm.selectedCommit) { _ in
                CommitDetailSheet(vm: vm)
            }
    }

    /// Graph controls: scope + ordering + limit (re-fetch), density + columns (display).
    private var optionsMenu: some View {
        Menu {
            Picker("Scope", selection: $vm.options.scope) {
                ForEach(GraphOptions.Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Order", selection: $vm.options.order) {
                ForEach(GraphOptions.Order.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Hide merges", isOn: $vm.options.hideMerges)
            Toggle("First-parent only", isOn: $vm.options.firstParent)
            Picker("Max commits", selection: $vm.options.limit) {
                ForEach(GraphOptions.Limit.allCases) { Text($0.label).tag($0) }
            }

            Divider()

            Picker("Density", selection: $vm.options.density) {
                ForEach(GraphOptions.Density.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle("Show author", isOn: $vm.options.showAuthor)
            Toggle("Show hash", isOn: $vm.options.showHash)
            Toggle("Show refs", isOn: $vm.options.showRefs)
        } label: {
            Label("Options", systemImage: "slider.horizontal.3")
        }
        .help("Graph options")
    }

    /// Author / path / date filters — narrow which commits git returns.
    private var filtersButton: some View {
        Button {
            showFilters.toggle()
        } label: {
            Label("Filters", systemImage: vm.options.hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .help("Filter commits")
        .popover(isPresented: $showFilters, arrowEdge: .bottom) {
            FiltersPopover(options: $vm.options)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .empty:
            emptyState
        case .loading:
            LoadingStateView("Reading repository…")
        case .failed(let message):
            failedState(message)
        case .loaded(let summary):
            loadedState(summary)
        }
    }

    // MARK: - Header / shared

    private var header: some View {
        MasterHeaderView(
            title: "Git Graph",
            subtitle: "Visualize a repository's history",
            image: "point.3.filled.connected.trianglepath.dotted",
            color: .purple
        )
        // Fill width so the centered header never drifts between states / alignments.
        .frame(maxWidth: .infinity)
    }

    private var repositoryCardHeader: some View {
        HStack {
            Text("Repository")
                .font(.headline)
            Spacer()
            Text("None open")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Empty / failed (non-scrolling, fill the window)

    private var emptyState: some View {
        VStack(spacing: 24) {
            header
            VStack(alignment: .leading, spacing: 16) {
                repositoryCardHeader
                SectionDivider()
                GitRepoDropZone(isTargeted: vm.isDropTargeted) { vm.chooseRepository() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !vm.recentRepos.isEmpty {
                    SectionDivider()
                    recentReposList
                }
            }
            .cardStyle()
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// Recently-opened repositories — one click to reopen (with its saved options).
    private var recentReposList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(vm.recentRepos.prefix(6), id: \.self) { path in
                HStack(spacing: 8) {
                    Button { vm.load(repoPath: path) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                    .font(.body)
                                Text(path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .appButton(.plain)

                    Button { vm.removeRecent(path) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    .appButton(.plain)
                    .help("Remove from recents")
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// Renders an error layout when the underlying Git history cannot be parsed.
    /// - Parameter message: The human readable error message string.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func failedState(_ message: String) -> some View {
        VStack(spacing: 24) {
            header
            ErrorBanner(message: .constant(Optional(message)), title: "Couldn't open repository")
            VStack(alignment: .leading, spacing: 16) {
                repositoryCardHeader
                SectionDivider()
                GitRepoDropZone(isTargeted: vm.isDropTargeted) { vm.chooseRepository() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .cardStyle()
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Loaded (summary + graph)

    /// - Parameter summary: The mapped architectural diagram payload resolving graph layout.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func loadedState(_ summary: RepoSummary) -> some View {
        // One geometry source: the content width (minus the 16pt page padding on each
        // side) drives both the pinned scrollbar and the rows so they stay in sync.
        GeometryReader { geo in
            let availWidth = max(120, geo.size.width - 32)
            ScrollView {
                /// Spacing 0 so the pinned reference header abuts the commit rows (one card);
                /// gaps above the graph are added explicitly.
                ///
                /// **Rationale:** Prevents SwiftUI's default stack spacing from tearing the visual continuity of the git branches between the header and the scroll view.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    header
                        .padding(.bottom, 20)
                    RepoSummaryCard(summary: summary)
                        .padding(.bottom, 20)

                    if vm.isGraphLoading && vm.graph.isEmpty {
                        LoadingStateView("Building graph…")
                    } else if vm.graph.isEmpty {
                        EmptyStateView(
                            icon: "clock",
                            message: "No commits yet",
                            detail: "This repository has no commit history to graph.",
                            verticalPadding: 28
                        )
                        .cardStyle(.standard, padded: false)
                    } else {
                        Section {
                            graphRows(availWidth: availWidth)
                        } header: {
                            GraphReferenceHeader(
                                commitCount: vm.graph.nodes.count,
                                matchCount: vm.matchCount,
                                searchText: $vm.searchText,
                                isRefreshing: vm.isGraphLoading,
                                onRefresh: { vm.reloadGraph() },
                                availWidth: availWidth,
                                laneCount: vm.graph.laneCount,
                                rightWidth: rightColumnWidth,
                                hOffset: $graphHOffset
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
    }

    /// The lazily-rendered commit rows, styled as the bottom of the graph card.
    ///
    /// The gutter + message live in a horizontally-scrollable window (shared `graphHOffset`);
    /// author + hash are frozen on the right. Kept in a plain `LazyVStack` (no inner
    /// `GeometryReader`/scroll) so vertical row culling stays intact.
    /// - Parameter availWidth: The horizontal drawing boundary available for topological traces.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func graphRows(availWidth: CGFloat) -> some View {
        let opts = vm.options
        let rowHeight = opts.density.rowHeight
        let searching = !vm.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        let rightW = rightColumnWidth
        let laneCount = vm.graph.laneCount
        let laneW = GraphMetrics.laneWidth(available: availWidth, laneCount: laneCount, rightWidth: rightW)
        let gutter = GraphMetrics.gutter(laneWidth: laneW, laneCount: laneCount)
        let g = GraphMetrics.geometry(available: availWidth, gutter: gutter, rightWidth: rightW)
        let offset = min(max(0, graphHOffset), g.maxOffset)
        /// While searching, show ONLY matching commits (nothing to scroll past). Lane lines
        /// are dropped in this mode — a filtered list has no continuous graph to draw.
        ///
        /// **Gotchas:** Attempting to render branch lanes over a sparse, filtered list results in chaotic, criss-crossing lines that connect completely unrelated nodes.
        let nodes = searching ? vm.graph.nodes.filter { vm.matches($0.commit) } : vm.graph.nodes

        return LazyVStack(spacing: 0) {
            if searching && nodes.isEmpty {
                Text("No matching commits")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(nodes) { node in
                    CommitRowView(
                        commit: node.commit,
                        segments: searching ? [] : vm.graph.rowSegments[node.row],
                        nodeLane: node.lane,
                        layout: RowLayout(
                            gutterWidth: gutter,
                            laneWidth: laneW,
                            messageWidth: g.leftContent - gutter,
                            leftViewport: g.leftViewport,
                            rightWidth: rightW,
                            hOffset: offset,
                            rowHeight: rowHeight
                        ),
                        showAuthor: opts.showAuthor,
                        showHash: opts.showHash,
                        showRefs: opts.showRefs,
                        dimmed: false,
                        onSelect: { vm.select(node.commit) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphCardBottom()
    }
}

// MARK: - Drop zone (mirrors VirtualProjectDropZone)

private struct GitRepoDropZone: View {
    var isTargeted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundColor(isTargeted ? .accentColor : .secondary.opacity(0.2))
                    .background(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)

                VStack(spacing: 10) {
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "plus.viewfinder")
                        .font(.system(size: 30))
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary.opacity(0.8))

                    VStack(spacing: 4) {
                        Text(isTargeted ? "Drop to Open" : "Open a Repository")
                            .font(.headline)
                        Text("Drag a repo folder here or click to browse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .appButton(.plain)
    }
}

// MARK: - Repository summary card (Dr. Catalyst titled-header grammar)

private struct RepoSummaryCard: View {
    let summary: RepoSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            /// Titled header — matches DrCatalystCards (title + caption subtitle).
            ///
            /// **Rationale:** Maintains typographic consistency with the rest of the application dashboard.
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.name)
                        .font(.headline)
                    Text("Repository overview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if summary.isDirty {
                    Label("Uncommitted changes", systemImage: "pencil.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }

            VStack(spacing: 0) {
                row(icon: "arrow.triangle.branch", label: "Current Branch", value: summary.displayBranch)
                divider
                row(icon: "square.stack.3d.up", label: "Local Branches", value: "\(summary.localBranchCount)")
                divider
                row(icon: "tag", label: "Tags", value: "\(summary.tagCount)")
                divider
                row(icon: "circle.hexagongrid", label: "Commits", value: "\(summary.commitCount)")
                if let last = summary.lastCommitRelative {
                    divider
                    row(icon: "clock", label: "Last Commit", value: last)
                }
                if let ahead = summary.ahead, let behind = summary.behind {
                    divider
                    row(icon: "arrow.up.arrow.down", label: "Ahead / Behind", value: "\(ahead) ↑  \(behind) ↓")
                }
                if let remote = summary.remoteURL {
                    divider
                    row(icon: "link", label: "Remote", value: remote)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
        .cardStyle(.standard, padded: false)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.12))
            .frame(height: 1)
    }

    /// Standardizes label-value display formatting within the Git inspection popover.
    /// - Parameters:
    ///   - icon: The associated SF Symbol glyph.
    ///   - label: The textual category description.
    ///   - value: The configuration property or metric assigned.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func row(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Sticky reference header (title + legend), pins to the top of the graph card

private struct GraphReferenceHeader: View {
    let commitCount: Int
    let matchCount: Int
    @Binding var searchText: String
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let availWidth: CGFloat
    let laneCount: Int
    let rightWidth: CGFloat
    @Binding var hOffset: CGFloat

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var countLabel: String {
        isSearching ? "\(matchCount) of \(commitCount)" : "\(commitCount) commits"
    }
    private var geometry: (leftViewport: CGFloat, leftContent: CGFloat, maxOffset: CGFloat) {
        let laneW = GraphMetrics.laneWidth(available: availWidth, laneCount: laneCount, rightWidth: rightWidth)
        let gutter = GraphMetrics.gutter(laneWidth: laneW, laneCount: laneCount)
        return GraphMetrics.geometry(available: availWidth, gutter: gutter, rightWidth: rightWidth)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Commit History")
                        .font(.headline)
                    Text("Branches, merges & refs over time")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(countLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            /// Live search — dims non-matching commits (see CommitRowView).
            ///
            /// **Rationale:** In-place dimming provides instantaneous visual feedback without disorienting the user by fundamentally altering the graph layout.
            SearchBarView(placeholder: "Search message, author, or hash", text: $searchText)

            /// Legend (what each color / node / pill means) with the graph refresh action
            /// inline at the trailing end, sized to match the app's Install buttons.
            ///
            /// **Rationale:** Consolidates metadata into the peripheral footer, ensuring the commit history remains the hero element on screen.
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        LegendItem(swatch: .dot, tint: GitGraphPalette.lane(0), text: "Commit")
                        LegendItem(swatch: .ring, tint: .green, text: "HEAD")
                        LegendItem(swatch: .hollow, tint: GitGraphPalette.lane(1), text: "Merge")
                        LegendItem(swatch: .line, tint: GitGraphPalette.lane(2), text: "Branch lane")
                        LegendItem(swatch: .pill(icon: "arrow.triangle.branch"), tint: .purple, text: "Local")
                        LegendItem(swatch: .pill(icon: "cloud.fill"), tint: .blue, text: "Remote")
                        LegendItem(swatch: .pill(icon: "tag.fill"), tint: .yellow, text: "Tag")
                        LegendItem(swatch: .pill(icon: "arrowtriangle.right.fill"), tint: .green, text: "HEAD ref")
                    }
                    .padding(.vertical, 2)
                }

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 22)
                } else {
                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .appButton(.primary)
                    .help("Refresh graph")
                }
            }

            /// Horizontal scrollbar for the graph's left region — only when it overflows.
            /// Aligned under the message area; the frozen author/hash space stays clear.
            ///
            /// **Gotchas:** Allowing the horizontal scrollbar to bleed under the fixed columns creates a visual overlap that obscures the timestamp data.
            if geometry.maxOffset > 0 {
                HStack(spacing: 0) {
                    HGraphScrollBar(contentWidth: geometry.leftContent, offset: $hOffset)
                        .frame(width: geometry.leftViewport)
                    Spacer(minLength: 0)
                        .frame(width: rightWidth)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .graphCardTop()
    }
}

/// One legend entry: a small visual swatch + a label.
private struct LegendItem: View {
    /// A predefined color palette for rendering distinct topological branch lanes.
    enum Swatch {
        case dot, ring, hollow, line
        case pill(icon: String)
    }
    let swatch: Swatch
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            swatchView
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var swatchView: some View {
        switch swatch {
        case .dot:
            Circle().fill(tint).frame(width: 12, height: 12)
        case .ring:
            Circle().fill(tint).frame(width: 12, height: 12)
                .overlay(Circle().stroke(tint.opacity(0.45), lineWidth: 2).frame(width: 19, height: 19))
                .frame(width: 19, height: 19)
        case .hollow:
            Circle().stroke(tint, lineWidth: 2.5).frame(width: 12, height: 12)
        case .line:
            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 20, height: 4)
        case .pill(let icon):
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(tint.opacity(0.16)))
                .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 0.5))
        }
    }
}

// MARK: - Commit row (per-row gutter + content)

/// One commit row: a small gutter `Canvas` (its own lane segments + node) on the left,
/// then ref chips + subject + author + short hash. `Equatable` over plain values so
/// off-screen rows never re-render (`CODING_STANDARDS.md` 3.6).
/// Row geometry shared by every commit row (frozen-column layout + horizontal offset).
struct RowLayout: Equatable {
    let gutterWidth: CGFloat
    let laneWidth: CGFloat
    let messageWidth: CGFloat
    let leftViewport: CGFloat
    let rightWidth: CGFloat
    let hOffset: CGFloat
    let rowHeight: CGFloat
}

/// Renders a single Git commit node and its associated horizontal topology traces.
private struct CommitRowView: View, Equatable {
    let commit: GraphCommit
    let segments: [RowSegment]
    let nodeLane: Int
    let layout: RowLayout
    let showAuthor: Bool
    let showHash: Bool
    let showRefs: Bool
    let dimmed: Bool
    let onSelect: () -> Void

    static func == (lhs: CommitRowView, rhs: CommitRowView) -> Bool {
        lhs.commit == rhs.commit && lhs.segments == rhs.segments && lhs.nodeLane == rhs.nodeLane
            && lhs.layout == rhs.layout && lhs.showAuthor == rhs.showAuthor
            && lhs.showHash == rhs.showHash && lhs.showRefs == rhs.showRefs
            && lhs.dimmed == rhs.dimmed
    }

    var body: some View {
        HStack(spacing: 0) {
            /// LEFT — gutter + refs + subject, in a horizontally-scrollable clipped window.
            ///
            /// **Rationale:** Accommodates deep branch nesting and long commit messages without breaking the strict tabular layout.
            HStack(spacing: 0) {
                RowGutter(
                    segments: segments,
                    nodeLane: nodeLane,
                    isHead: commit.refs.contains { $0.kind == .head },
                    isMerge: commit.isMerge,
                    laneWidth: layout.laneWidth
                )
                .frame(width: layout.gutterWidth, height: layout.rowHeight)

                HStack(spacing: 8) {
                    if showRefs {
                        ForEach(commit.refs) { ref in
                            RefChip(ref: ref)
                        }
                    }
                    Text(commit.subject.isEmpty ? "(no message)" : commit.subject)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(width: layout.messageWidth, alignment: .leading)
                .padding(.leading, 2)
            }
            .frame(width: layout.gutterWidth + layout.messageWidth, alignment: .leading)
            .offset(x: -layout.hOffset)
            .frame(width: layout.leftViewport, alignment: .leading)
            .clipped()

            /// RIGHT — frozen author + hash (never scroll horizontally).
            ///
            /// **Rationale:** Pinning the metadata to the trailing edge ensures users can always attribute a commit regardless of how far right the branch tree extends.
            HStack(spacing: GraphMetrics.gap) {
                if showAuthor {
                    Text(commit.authorName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: GraphMetrics.authorWidth, alignment: .trailing)
                }
                if showHash {
                    Text(commit.shortHash)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary.opacity(0.8))
                        .frame(width: GraphMetrics.hashWidth, alignment: .trailing)
                }
            }
            .padding(.horizontal, GraphMetrics.sidePad)
            .frame(width: layout.rightWidth, alignment: .trailing)
        }
        .frame(height: layout.rowHeight)
        .opacity(dimmed ? 0.3 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

/// Draws one row's slice of the graph: its lane lines + this row's node.
private struct RowGutter: View {
    let segments: [RowSegment]
    let nodeLane: Int
    let isHead: Bool
    let isMerge: Bool
    let laneWidth: CGFloat
    private var leadPad: CGFloat { GraphMetrics.leadPad }
    /// Shrink nodes as lanes compress so dots don't overlap neighbouring lanes.
    ///
    /// **Gotchas:** Fixed-size nodes in highly compressed graph regions (e.g. 15+ concurrent branches) will bleed into adjacent lanes, creating illegible blobs.
    private var nodeRadius: CGFloat { min(GraphMetrics.nodeRadius, laneWidth * 0.4) }

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            /// Calculates the exact horizontal layout coordinate for a specified branch lane.
            /// - Parameter lane: The discrete structural track running vertically down the diagram.
            /// - Returns: The exact computed X-coordinate displacement.
            func x(_ lane: Int) -> CGFloat { leadPad + CGFloat(lane) * laneWidth + laneWidth / 2 }

            /// Lane lines through this row.
            ///
            /// **Rationale:** Segmented rendering ensures SwiftUI only draws vectors within the visible viewport, keeping CPU usage flat even on 10,000-commit repos.
            for seg in segments {
                let yTop = seg.startsAtNode ? h / 2 : 0
                let yBot = seg.endsAtNode ? h / 2 : h
                let xTop = x(seg.topLane)
                let xBot = x(seg.bottomLane)
                var path = Path()
                path.move(to: CGPoint(x: xTop, y: yTop))
                if abs(xTop - xBot) < 0.5 {
                    path.addLine(to: CGPoint(x: xBot, y: yBot))
                } else {
                    let midY = (yTop + yBot) / 2
                    path.addCurve(to: CGPoint(x: xBot, y: yBot),
                                  control1: CGPoint(x: xTop, y: midY),
                                  control2: CGPoint(x: xBot, y: midY))
                }
                ctx.stroke(path, with: .color(GitGraphPalette.lane(seg.colorIndex).opacity(0.85)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }

            /// This row's node.
            ///
            /// **Gotchas:** The node must be drawn AFTER the lane lines to ensure it obscures the underlying strokes and remains the focal point of the row.
            let nx = x(nodeLane)
            let ny = h / 2
            let laneColor = GitGraphPalette.lane(nodeLane)

            if isHead {
                let glow = CGRect(x: nx - nodeRadius - 3, y: ny - nodeRadius - 3,
                                  width: (nodeRadius + 3) * 2, height: (nodeRadius + 3) * 2)
                ctx.stroke(Circle().path(in: glow), with: .color(laneColor.opacity(0.45)), lineWidth: 2)
            }

            let dot = CGRect(x: nx - nodeRadius, y: ny - nodeRadius,
                             width: nodeRadius * 2, height: nodeRadius * 2)
            ctx.fill(Circle().path(in: dot), with: .color(laneColor))
            if isMerge {
                let inner = dot.insetBy(dx: nodeRadius * 0.5, dy: nodeRadius * 0.5)
                ctx.fill(Circle().path(in: inner), with: .color(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }
}

/// A small colored capsule for a branch / remote branch / tag / HEAD decoration.
private struct RefChip: View {
    let ref: GitRef

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(ref.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 0.5))
    }

    private var icon: String {
        switch ref.kind {
        case .head: return "arrowtriangle.right.fill"
        case .tag: return "tag.fill"
        case .remoteBranch: return "cloud.fill"
        case .branch: return "arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch ref.kind {
        case .head: return .green
        case .tag: return .yellow
        case .remoteBranch: return .blue
        case .branch: return .purple
        }
    }
}

// MARK: - Filters popover (phase 3)

/// Author / path / date-range filters. Edits stay local until "Apply", which writes the
/// options (triggering a single refetch). Dates accept any git date format.
private struct FiltersPopover: View {
    @Binding var options: GraphOptions
    @Environment(\.dismiss) private var dismiss

    @State private var author = ""
    @State private var path = ""
    @State private var since = ""
    @State private var until = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filter Commits")
                .font(.headline)

            field("Author contains", text: $author, placeholder: "e.g. John Doe")
            field("Path", text: $path, placeholder: "e.g. src/  or  README.md")
            HStack(spacing: 10) {
                field("Since", text: $since, placeholder: "2024-01-01")
                field("Until", text: $until, placeholder: "2 weeks ago")
            }
            Text("Dates accept git formats — “2024-01-01”, “2 weeks ago”, “yesterday”.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Clear") {
                    author = ""; path = ""; since = ""; until = ""
                    apply()
                }
                .disabled(author.isEmpty && path.isEmpty && since.isEmpty && until.isEmpty)
                Spacer()
                Button("Apply") {
                    apply()
                    dismiss()
                }
                .appButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            author = options.authorFilter
            path = options.pathFilter
            since = options.sinceFilter
            until = options.untilFilter
        }
    }

    /// Commits local preferences back to the Git graph view model.
    private func apply() {
        options.authorFilter = author.trimmingCharacters(in: .whitespaces)
        options.pathFilter = path.trimmingCharacters(in: .whitespaces)
        options.sinceFilter = since.trimmingCharacters(in: .whitespaces)
        options.untilFilter = until.trimmingCharacters(in: .whitespaces)
    }

    /// A specialized text input component used for configuring Git graph properties.
    /// - Parameters:
    ///   - label: The descriptive prompt mapped to the text entry block.
    ///   - text: The two-way interactive string bridge holding configuration state.
    ///   - placeholder: Ghost text rendering inside an empty block.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Commit detail sheet (phase 2)

/// Detail panel for a clicked commit: metadata, full message, and per-file change stats.
private struct CommitDetailSheet: View {
    @ObservedObject var vm: GitGraphViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(vm.selectedCommit?.subject.isEmpty == false ? vm.selectedCommit!.subject : "Commit")
                        .font(.headline)
                        .lineLimit(2)
                    if let hash = vm.selectedDetail?.shortHash ?? vm.selectedCommit?.shortHash {
                        Text(hash)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            SectionDivider()

            if vm.isDetailLoading && vm.selectedDetail == nil {
                LoadingStateView("Loading commit…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let d = vm.selectedDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            metaRow(icon: "person.fill", text: "\(d.authorName)  <\(d.authorEmail)>")
                            metaRow(icon: "clock", text: d.dateString)
                            HStack(spacing: 8) {
                                metaRow(icon: "number", text: d.hash)
                                Spacer()
                                Button { copyToPasteboard(d.hash) } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .appButton(.borderless)
                                .font(.caption)
                            }
                        }
                        .cardStyle()

                        if !d.message.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Message").font(.caption).foregroundStyle(.secondary)
                                Text(d.message)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .cardStyle()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(d.files.count) changed file\(d.files.count == 1 ? "" : "s")")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(d.files) { file in
                                HStack(spacing: 8) {
                                    Text(file.path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text("+\(file.added)").font(.caption.monospaced()).foregroundStyle(.green)
                                    Text("−\(file.removed)").font(.caption.monospaced()).foregroundStyle(.red)
                                }
                            }
                        }
                        .cardStyle()
                    }
                    .padding()
                }
            } else {
                EmptyStateView(icon: "exclamationmark.triangle",
                               message: "Couldn't load commit details")
                    .frame(maxWidth: .infinity, minHeight: 220)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 520)
    }

    /// Displays a single line of commit metadata within the inspection overlay.
    /// - Parameters:
    ///   - icon: The symbolic representation for the commit attribute.
    ///   - text: The associated detail string mapped to the icon.
    /// - Returns: The active presentation hierarchy for the detail view.
    private func metaRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Writes the designated text payload to the general system clipboard.
    /// - Parameter string: The textual payload intended for the general clipboard.
    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Palette + card-piece backgrounds

/// Stable per-lane color palette. Domain meaning-colors are reserved elsewhere; these are
/// decorative branch hues cycled round-robin (`CODING_STANDARDS.md` 4.15).
enum GitGraphPalette {
    static let laneColors: [Color] = [.purple, .blue, .green, .orange, .pink, .teal, .indigo, .red]
    /// Deterministically assigns a color swatch to a branch index using modulo arithmetic.
    /// - Parameter index: The relative position offset mapping to the lane track.
    /// - Returns: The standard swatch bound to the specified index.
    static func lane(_ index: Int) -> Color {
        laneColors[((index % laneColors.count) + laneColors.count) % laneColors.count]
    }
}

/// Fixed widths + geometry math for the frozen-column / horizontal-scroll layout.
enum GraphMetrics {
    static let authorWidth: CGFloat = 140
    static let hashWidth: CGFloat = 62
    static let gap: CGFloat = 10       // between author and hash
    static let sidePad: CGFloat = 12   // inside the right column, each side
    static let minMessage: CGFloat = 220

    static let leadPad: CGFloat = 16   // gutter left/right inset
    static let nodeRadius: CGFloat = 5
    static let minLane: CGFloat = 7    // thinnest a lane may compress to
    static let maxLane: CGFloat = 20   // comfortable lane width

    /// Total reserved width of the frozen right columns for the shown columns.
    /// - Parameters:
    ///   - showAuthor: Indicates if the text name property is enabled.
    ///   - showHash: Indicates if the abbreviated cryptographic commit identifier is enabled.
    /// - Returns: The computed dynamic pixel reserve.
    static func rightWidth(showAuthor: Bool, showHash: Bool) -> CGFloat {
        var w: CGFloat = 2 * sidePad
        if showAuthor { w += authorWidth }
        if showHash { w += hashWidth }
        if showAuthor && showHash { w += gap }
        return w
    }

    /// Lane width that adapts to the window: many lanes compress (down to `minLane`) so
    /// the gutter never dominates. Beyond the floor, the horizontal scroll takes over.
    /// - Parameters:
    ///   - available: The maximum horizontal bounds mapped to the view layout.
    ///   - laneCount: The overall complexity count of divergent topologies.
    ///   - rightWidth: The layout slice previously reserved for text attributes.
    /// - Returns: The standard geometric step size allocated to each track.
    static func laneWidth(available: CGFloat, laneCount: Int, rightWidth: CGFloat) -> CGFloat {
        guard laneCount > 0 else { return maxLane }
        let leftViewport = max(120, available - rightWidth)
        /// Gutter should take at most ~45% of the row (and never a huge fixed slab).
        ///
        /// **Gotchas:** Unbounded graph width on massively branching repos pushes the commit message entirely off-screen.
        let targetGutter = min(leftViewport * 0.45, 320)
        let usable = max(0, targetGutter - 2 * leadPad)
        return min(maxLane, max(minLane, usable / CGFloat(laneCount)))
    }

    /// Gutter width for a given (adaptive) lane width.
    /// - Parameters:
    ///   - laneWidth: The dynamic horizontal step allocated to tracks.
    ///   - laneCount: The sum total of divergent topologies.
    /// - Returns: The horizontal buffer isolating the graphical canvas from text elements.
    static func gutter(laneWidth: CGFloat, laneCount: Int) -> CGFloat {
        2 * leadPad + CGFloat(max(1, laneCount)) * laneWidth
    }

    /// Split the available width into the scrollable left viewport, the left content
    /// width (gutter + message), and how far it can scroll horizontally.
    /// - Parameters:
    ///   - available: The parent dimension defining layout logic.
    ///   - gutter: The isolating boundary between UI concepts.
    ///   - rightWidth: The static trailing frame housing metadata elements.
    static func geometry(available: CGFloat, gutter: CGFloat, rightWidth: CGFloat)
        -> (leftViewport: CGFloat, leftContent: CGFloat, maxOffset: CGFloat) {
        let leftViewport = max(120, available - rightWidth)
        let message = max(minMessage, leftViewport - gutter)
        let leftContent = gutter + message
        return (leftViewport, leftContent, max(0, leftContent - leftViewport))
    }
}

/// A native horizontal scrollbar that drives the shared `graphHOffset`. Its (transparent)
/// content is `contentWidth` wide; scrolling it reports the offset, which every row mirrors.
private struct HGraphScrollBar: View {
    let contentWidth: CGFloat
    @Binding var offset: CGFloat

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Color.clear
                .frame(width: contentWidth, height: 6)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HScrollOffsetKey.self,
                            value: -proxy.frame(in: .named("gitHBar")).minX
                        )
                    }
                )
        }
        .coordinateSpace(name: "gitHBar")
        .frame(height: 14)
        .onPreferenceChange(HScrollOffsetKey.self) { offset = $0 }
    }
}

/// A SwiftUI PreferenceKey used to track precise horizontal scroll view displacement.
private struct HScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    /// Applies the standard preference aggregation rule for horizontal scroll offsets.
    /// - Parameters:
    ///   - value: The aggregated accumulation of previous iteration returns.
    ///   - nextValue: The dynamic closure producing the active geometric attribute.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private extension View {
    /// Card styling for the top piece (the pinned reference header): opaque fill,
    /// top-rounded corners + hairline border. Matches `cardStyle()`'s chrome.
    /// - Returns: The active presentation hierarchy for the detail view.
    func graphCardTop() -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 12)
        return self
            .background(shape.fill(Color(NSColor.controlBackgroundColor)))
            /// compositingGroup() flattens child layers (e.g. Canvas) so clipShape can
            /// actually round the corners — without it those layers escape the clip.
            ///
            /// **Gotchas:** `Canvas` views in SwiftUI frequently ignore bounds clipping unless explicitly forced into an off-screen render pass via `compositingGroup`.
            .compositingGroup()
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    /// Card styling for the bottom piece (the commit rows): opaque fill, bottom-rounded
    /// corners + hairline border. Abuts the header to read as one continuous card.
    /// - Returns: The active presentation hierarchy for the detail view.
    func graphCardBottom() -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 12,
                                           bottomTrailingRadius: 12, topTrailingRadius: 0)
        return self
            .background(shape.fill(Color(NSColor.controlBackgroundColor)))
            /// Flatten the per-row Canvas layers so they're clipped to the rounded
            /// bottom corners instead of squaring off the edge while scrolling.
            ///
            /// **Gotchas:** Unflattened scroll views break visual continuity by allowing list items to render over the top of the container's rounded bezel.
            .compositingGroup()
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }
}
