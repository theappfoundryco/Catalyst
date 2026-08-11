/// Subview components for Orphanage. Deliberately mirrors the Cruft Sweeper
/// grammar — `MasterHeaderView`, `SmoothPageScroll`, `SectionDivider`,
/// `InstantDisclosureGroup`, sticky action bar, `.appButton(…)` — so the feature
/// reads as part of the same tool rather than a bolted-on second one.

import SwiftUI

// MARK: - Display-only model extensions

/// Category accent colors. These live here rather than on `LeftoverCategory`
/// because `Models/OrphanModels.swift` stays Foundation-only (CODING_STANDARDS
/// 1.2 — a Model never imports SwiftUI).
extension LeftoverCategory {
    var color: Color {
        switch self {
        case .applicationSupport:  return .blue
        case .caches:              return .gray
        case .preferences:         return .purple
        case .logs:                return .secondary
        case .savedState:          return .teal
        case .httpStorages:        return .indigo
        case .webKit:              return .cyan
        case .containers:          return .orange
        case .groupContainers:     return .brown
        case .userLaunchAgent:     return .yellow
        case .systemLaunchAgent, .systemLaunchDaemon, .privilegedHelper: return .red
        case .receipt:             return .mint
        }
    }
}

/// Display-only colour for the confidence chip, kept out of `OrphanModels`
/// because a Model never imports SwiftUI (CODING_STANDARDS 1.2).
extension MatchConfidence {
    /// Chip color — green only for a bundle-id match.
    var color: Color {
        switch self {
        case .bundleID:      return .green
        case .vendorLineage: return .orange
        case .nameOnly:      return .red
        }
    }
}

// MARK: - Tab switcher

/// The Find / Recently Cleaned switcher.
///
/// **Rationale:** Lives directly beneath the page header rather than pinned above
/// it. Floating a segmented control over the top of the window broke the grammar
/// every other screen follows — header first, then controls — and made Orphanage
/// read as a different app from Cruft Sweeper sitting next to it.
///
/// Used on the start and quarantine screens only. The results screen has no header
/// to sit under — it leads with the summary card, matching Cruft Sweeper — so it
/// reaches Recently Cleaned from a toolbar button instead.
///
/// ```swift
/// OrphanageTabPicker(selection: $tab)
/// ```
struct OrphanageTabPicker: View {
    @Binding var selection: OrphanageContent.Tab

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(OrphanageContent.Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Start

/// The pre-scan configuration screen.
///
/// ```swift
/// OrphanStartView(tab: $tab, onStart: { vm.startScan() })
/// ```
struct OrphanStartView: View {
    @EnvironmentObject var vm: OrphanageViewModel
    @Binding var tab: OrphanageContent.Tab
    /// Starts the scan. Owned by the parent so the VM stays out of the view.
    let onStart: () -> Void

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                MasterHeaderView(
                    title: "Orphanage",
                    subtitle: "Find the caches, preferences and support files left behind by apps you've deleted",
                    image: "shippingbox.and.arrow.backward.fill",
                    color: .purple
                )

                OrphanageTabPicker(selection: $tab)
                    .padding(.horizontal)

                /// Unified configuration card, laid out exactly like Cruft
                /// Sweeper's: an outer 20pt stack of sections, each section a 16pt
                /// stack of `headline` → `SectionDivider` → content, and the option
                /// rows in their own 16pt stack divided row-by-row.
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("What this checks")
                            .font(.headline)
                        SectionDivider()

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Self.scanPoints, id: \.self) { point in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "circle.fill")
                                        .font(.system(size: 6))
                                        .padding(.top, 6)
                                        .foregroundColor(.secondary)
                                    Text(point)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    SectionDivider()

                    Text("Options")
                        .font(.headline)

                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.blue)
                                .frame(width: 24)

                            VStack(alignment: .leading) {
                                Text("Look for one app only")
                                    .font(.body)
                                Text("Leave blank to scan everything")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            TextField("App name", text: $vm.manualFilter)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }

                        SectionDivider()

                        HStack {
                            Image(systemName: "questionmark.circle.fill")
                                .foregroundColor(.orange)
                                .frame(width: 24)

                            VStack(alignment: .leading) {
                                Text("Include weak name-only matches")
                                    .font(.body)
                                Text("Mostly command-line tool caches and macOS system data — noisy, and none of it safe to remove blindly")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $vm.includeNameOnlyMatches)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }

                        SectionDivider()

                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.red)
                                .frame(width: 24)

                            VStack(alignment: .leading) {
                                Text("Include system-level items")
                                    .font(.body)
                                Text("Shown for review only — removing these needs admin rights")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $vm.includeSystemScope)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }
                .cardStyle()

                /// Primary CTA last, so the user reviews the options above first —
                /// and styled identically to Cruft Sweeper's "Start Scan".
                Button {
                    onStart()
                } label: {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Start Scan")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .appButton(.primary)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .padding(.vertical)
        }
    }

    /// Bullet copy for the "What this checks" section.
    private static let scanPoints = [
        "Application Support, Caches, Preferences, Logs and Saved State",
        "Containers and Group Containers for sandboxed / App Store apps",
        "Launch agents, and system daemons and helpers (review only)",
        "Cross-checks running apps, so an app launched from Downloads isn't flagged"
    ]
}

// MARK: - Scanning

/// Progress screen shown while a scan runs.
struct OrphanScanningView: View {
    @EnvironmentObject var vm: OrphanageViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "shippingbox.and.arrow.backward.fill")
                .font(.system(size: 48))
                .symbolEffect(.bounce, options: .repeating)
                .foregroundStyle(.purple)

            VStack(spacing: 8) {
                Text(vm.scanStatus)
                    .font(.title2.bold())

                Text(vm.progress.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
                    .id(vm.progress.path)
            }

            VStack(spacing: 4) {
                Text("\(vm.progress.examined)")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                Text("Entries Examined")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Material.thinMaterial)
            .cornerRadius(12)

            /// Indeterminate on purpose — a determinate bar would need a second
            /// full traversal just to compute the total (CODING_STANDARDS 8.6).
            ProgressView()
                .controlSize(.small)

            Button {
                vm.cancelScan()
            } label: {
                HStack {
                    Image(systemName: "stop.fill")
                    Text("Abort Scan")
                }
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.8))
                .cornerRadius(8)
            }
            .appButton(.plain)
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summary card

/// Results hero: status header, reclaimable-space number, per-category breakdown,
/// and the shared smart-selection row.
///
/// Structurally identical to `CruftSummaryCard` — same 16pt stack, same header
/// grammar, same 34pt monospaced hero, same `ProportionalBreakdownBar` + two-column
/// legend, same `SmartSelectionActions` footer. The two results screens sit one
/// sidebar row apart and must read as the same tool.
struct OrphanSummaryCard: View {
    @EnvironmentObject var vm: OrphanageViewModel

    var body: some View {
        /// Computed once — `body` must not recompute an O(n) reduction per render
        /// (ANTI_PATTERNS rule 7).
        let breakdown = vm.categoryBreakdown
        let total = vm.totalFoundSize

        VStack(alignment: .leading, spacing: 16) {
            /// Informative header, not a celebration — this screen removes data.
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .font(.title2)
                    .foregroundColor(.purple)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan Complete")
                        .font(.headline)
                    Text("\(vm.foundItems.count) items · \(vm.groups.count) apps")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            /// Missing Full Disk Access makes results incomplete, so it is stated
            /// before the number it undercuts. Uses `StatusBanner` — the single
            /// source of truth for tinted call-outs (CODING_STANDARDS 4.1b) — which
            /// also gives it the full-width chrome every other banner has.
            if let reason = vm.degradedReason {
                StatusBanner(icon: "exclamationmark.triangle.fill", tint: .orange, text: reason)
            }

            SectionDivider()

            /// Hero reclaimable number.
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vm.totalFoundSizeFormatted)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            /// Category breakdown — proportional bar + legend, reusing the shared
            /// per-category icons/colors.
            if !breakdown.isEmpty {
                ProportionalBreakdownBar(
                    segments: breakdown.map {
                        BreakdownSegment(id: $0.id, color: $0.category.color, size: $0.size)
                    },
                    total: total
                )

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(breakdown) { seg in
                        HStack(spacing: 8) {
                            Image(systemName: seg.category.icon)
                                .foregroundColor(seg.category.color)
                                .font(.caption)
                                .frame(width: 18)
                            Text(seg.category.title)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(seg.formattedSize)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SectionDivider()

            SmartSelectionActions(
                selectAllLabel: "Select All",
                selectAllIcon: "checkmark.circle",
                selectSafeLabel: "Select High Confidence",
                selectSafeIcon: "checkmark.shield",
                selectSafeHelp: "Selects only bundle-id matches with no backup- or data-looking folders.",
                hasSelection: !vm.selectedIDs.isEmpty,
                onSelectAll: { vm.selectAllActionable() },
                onSelectSafe: { vm.selectHighConfidence() },
                onClear: { vm.deselectAll() }
            )
        }
        .cardStyle()
    }
}

// MARK: - Detailed results

/// Every app group inside **one** card, mirroring Cruft Sweeper's "Detailed
/// Results" section exactly: 16pt stack, headline + Expand/Collapse All, a
/// `SectionDivider`, then one `InstantDisclosureGroup` per group separated by
/// dividers.
///
/// **Gotchas:** Previously each group drew its own `cardStyle()`. That produced a
/// stack of free-floating cards where Cruft shows a single grouped panel — the
/// most visible inconsistency between the two screens.
struct OrphanDetailedResultsCard: View {
    @EnvironmentObject var vm: OrphanageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Detailed Results")
                    .font(.headline)

                Spacer()

                /// Keeps the global toggle in sync with per-group state.
                let anyCollapsed = vm.groups.contains { !$0.isExpanded }

                Button {
                    vm.toggleAllGroups(expanded: anyCollapsed)
                } label: {
                    Text(anyCollapsed ? "Expand All" : "Collapse All")
                        .font(.caption.bold())
                }
                .appButton(.plain)
            }

            SectionDivider()

            ForEach($vm.groups) { $group in
                InstantDisclosureGroup(
                    isExpanded: $group.isExpanded,
                    label: {
                        HStack {
                            Image(systemName: "shippingbox.fill")
                                .foregroundColor(.purple)
                            Text(group.appName)
                                .font(.subheadline.bold())

                            ConfidenceChip(confidence: group.confidence)

                            if group.containsRisky {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                                    .help("Contains a backup- or data-looking folder. Check before removing.")
                            }

                            if group.containsSystemScope {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .help("Contains system-level items that need administrator rights.")
                            }

                            Spacer()

                            /// Size badge — identical chrome to Cruft's group badge.
                            Text(group.formattedSize)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(6)
                        }
                    },
                    content: {
                        /// Hoisted out of the row loop — recomputing per row is
                        /// waste once a group holds many items.
                        let lastItemID = group.items.last?.id
                        let maxSize = Double(max(vm.largestItemSize, 1))

                        /// `LazyVStack`, not `VStack`: `SmoothPageScroll` is a
                        /// `List` whose whole content is a SINGLE row, so List's
                        /// own virtualization does nothing here (ANTI_PATTERNS
                        /// rule 8).
                        LazyVStack(spacing: 0) {
                            SectionDivider().padding(.vertical, 8)
                            ForEach(group.items) { item in
                                OrphanItemRow(
                                    item: item,
                                    isSelected: vm.selectedIDs.contains(item.id),
                                    fractionOfMax: Double(item.size) / maxSize,
                                    children: vm.childrenByItem[item.id],
                                    onToggle: { vm.toggleSelection(item.id) },
                                    onRequestChildren: { Task { await vm.loadChildren(for: item) } }
                                )
                                .equatable()
                                .padding(.vertical, 8)

                                if item.id != lastItemID {
                                    SectionDivider()
                                }
                            }
                        }
                    }
                )

                if group.id != vm.groups.last?.id {
                    SectionDivider().padding(.vertical, 4)
                }
            }
        }
        .cardStyle()
    }
}

/// Small chip communicating how the orphan verdict was reached.
struct ConfidenceChip: View {
    /// The verdict strength to render. Its `detail` becomes the tooltip.
    let confidence: MatchConfidence

    var body: some View {
        Text(confidence.label)
            .font(.caption2.weight(.medium))
            .foregroundColor(confidence.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(confidence.color.opacity(0.12)))
            .help(confidence.detail)
    }
}

// MARK: - Item row

/// A single leftover path, with an optional one-level drill-down.
struct OrphanItemRow: View, Equatable {
    /// The leftover this row represents.
    let item: LeftoverItem
    /// Whether the user has checked it for removal.
    let isSelected: Bool
    /// Size relative to the largest found item (0…1), for the proportional bar.
    let fractionOfMax: Double
    /// Children once loaded; `nil` until the user expands.
    let children: [OrphanScanner.ChildEntry]?
    /// Called when the checkbox or the row body is tapped.
    let onToggle: () -> Void
    /// Called on first expansion, so children load lazily rather than at scan time.
    let onRequestChildren: () -> Void

    /// Local disclosure state — the drill-down is per-row and not worth a
    /// round-trip through the ViewModel.
    @State private var isExpanded = false

    /// Closures excluded so unchanged rows skip re-rendering (same reasoning as
    /// `CruftItemRow` — an inline closure would re-render every row on any tick).
    static func == (lhs: OrphanItemRow, rhs: OrphanItemRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.fractionOfMax == rhs.fractionOfMax
            && lhs.children == rhs.children
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .padding(.top, 4)
                    .disabled(!item.isActionable)
                    .help(item.isActionable ? "" : "Removing this needs administrator rights.")

                Image(systemName: item.category.icon)
                    .foregroundColor(item.category.color)
                    .font(.title3)
                    .frame(width: 24)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.simpleName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text(item.formattedSize)
                            .font(.caption.monospacedDigit())
                            .foregroundColor(item.size >= 500 * 1024 * 1024 ? .orange : .primary)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(item.category.color.opacity(0.8))
                                .frame(width: max(3, geo.size.width * CGFloat(fractionOfMax)))
                        }
                    }
                    .frame(height: 4)

                    HStack(spacing: 8) {
                        Text(item.category.title)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(item.category.color)

                        Text(item.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        if item.isRisky {
                            Label("Check contents", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.orange)
                                .help("The path contains a backup/data/vault-looking folder. Expand it before removing.")
                        }

                        Text(item.lastModified, style: .date)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(isExpanded ? "Hide contents" : "Show contents") {
                            isExpanded.toggle()
                            if isExpanded { onRequestChildren() }
                        }
                        .appButton(.plain)
                        .font(.caption)

                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        .appButton(.plain)
                        .font(.caption)
                    }
                }
            }
            /// Row-wide tap toggles selection, as in `CruftItemRow`. Scoped to this
            /// HStack so it never swallows taps meant for the buttons below.
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if isExpanded {
                OrphanChildTree(children: children)
                    .padding(.leading, 48)
                    .transition(.identity)
            }
        }
    }
}

/// One level of a leftover's contents, so the user can judge at the leaf rather
/// than trusting the top-level folder name.
struct OrphanChildTree: View {
    /// Loaded children, or `nil` while the fetch is still in flight.
    let children: [OrphanScanner.ChildEntry]?

    var body: some View {
        Group {
            if let children {
                if children.isEmpty {
                    Text("Empty")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(children.prefix(50)) { child in
                            HStack(spacing: 8) {
                                Image(systemName: child.isDirectory ? "folder.fill" : "doc.fill")
                                    .font(.caption2)
                                    .foregroundColor(child.isRisky ? .orange : .secondary)
                                Text(child.name)
                                    .font(.caption)
                                    .foregroundColor(child.isRisky ? .orange : .primary)
                                Spacer()
                                Text(child.lastModified, style: .date)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(child.formattedSize)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        if children.count > 50 {
                            Text("+ \(children.count - 50) more")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Confirm sheet

/// Final confirmation before anything moves — the full preview of what is about
/// to be staged, with type-to-confirm friction on large or bulk selections.
///
/// **Gotchas:** Presented from `OrphanageContent`'s body rather than from a
/// zero-size layer (ANTI_PATTERNS rule 14).
///
/// ```swift
/// .sheet(isPresented: $showConfirmSheet) {
///     OrphanConfirmSheet(isPresented: $showConfirmSheet)
///         .environmentObject(vm)
/// }
/// ```
struct OrphanConfirmSheet: View {
    @EnvironmentObject var vm: OrphanageViewModel
    /// Dismisses the sheet. Cleared before the async move starts, so the sheet
    /// never outlives the decision it was asking about.
    @Binding var isPresented: Bool

    /// What the user has typed into the confirmation field, for bulk removals.
    @State private var typed = ""

    /// The word a bulk selection must be typed to proceed.
    private static let confirmWord = "REMOVE"

    /// Whether the destructive button is enabled — always true for a small
    /// selection, and gated on the typed confirmation word for a bulk one.
    private var canProceed: Bool {
        guard vm.requiresTypeToConfirm else { return true }
        return typed.trimmingCharacters(in: .whitespaces).uppercased() == Self.confirmWord
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move \(vm.selectedItems.count) item\(vm.selectedItems.count == 1 ? "" : "s") to quarantine?")
                .font(.title3.bold())

            Text("\(vm.selectedSizeFormatted) will be reclaimed. Nothing is deleted now — items move to Catalyst's quarantine and can be restored for \(QuarantineRecord.gracePeriodDays) days.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SectionDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(vm.selectedItems) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.category.icon)
                                .font(.caption2)
                                .foregroundColor(item.category.color)
                            Text(item.simpleName)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(item.formattedSize)
                                .font(.caption2.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
                /// Clears the overlay scroller, which otherwise draws straight
                /// over the trailing size column.
                .padding(.trailing, 12)
            }
            .frame(maxHeight: 200)
            .scrollBounceBehavior(.basedOnSize)

            if vm.selectionContainsRisky {
                StatusBanner(
                    icon: "exclamationmark.triangle.fill",
                    tint: .orange,
                    text: "Some of these contain backup- or data-looking folders. Expand them and check before continuing."
                )
            }

            if vm.requiresTypeToConfirm {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is a large removal. Type \(Self.confirmWord) to continue.")
                        .font(.caption.weight(.medium))
                    TextField(Self.confirmWord, text: $typed)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .appButton(.neutral)
                Button("Move to Quarantine") {
                    isPresented = false
                    Task { await vm.quarantineSelected() }
                }
                .appButton(.destructiveProminent)
                .disabled(!canProceed)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

// MARK: - Quarantine

/// "Recently cleaned" — staged items with their countdown and a one-click restore.
struct OrphanQuarantineView: View {
    @EnvironmentObject var vm: OrphanageViewModel
    @Binding var tab: OrphanageContent.Tab

    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 20) {
                MasterHeaderView(
                    title: "Recently Cleaned",
                    subtitle: "Quarantined items are restorable for \(QuarantineRecord.gracePeriodDays) days",
                    image: "clock.arrow.circlepath",
                    color: .teal
                )

                OrphanageTabPicker(selection: $tab)
                    .padding(.horizontal)

                if vm.quarantined.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        message: "Nothing in quarantine",
                        detail: "Items you remove with Orphanage are staged here before permanent deletion.",
                        prominence: .standalone
                    )
                } else {
                    /// One grouped panel with divided rows — the same shape as
                    /// "Detailed Results", not a stack of free-floating cards.
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Quarantined Items")
                                .font(.headline)

                            Spacer()

                            Button {
                                Task { await vm.purgeExpired() }
                            } label: {
                                Text("Purge Expired")
                                    .font(.caption.bold())
                            }
                            .appButton(.plain)
                            .help("Permanently removes anything past its \(QuarantineRecord.gracePeriodDays)-day window, except items whose app has been reinstalled.")
                        }

                        SectionDivider()

                        let lastID = vm.quarantined.last?.id
                        LazyVStack(spacing: 0) {
                            ForEach(vm.quarantined) { record in
                                HStack(spacing: 12) {
                                    Image(systemName: record.category.icon)
                                        .foregroundColor(record.category.color)
                                        .font(.title3)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.appName)
                                            .font(.subheadline.bold())
                                        Text(record.originalPath)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(record.formattedSize)
                                            .font(.caption.monospacedDigit())
                                        Text(record.daysRemaining == 0
                                             ? "Ready to purge"
                                             : "\(record.daysRemaining) day\(record.daysRemaining == 1 ? "" : "s") left")
                                            .font(.caption2)
                                            .foregroundColor(record.daysRemaining <= 3 ? .orange : .secondary)
                                    }

                                    Button("Restore") {
                                        Task { await vm.restore(record) }
                                    }
                                    .appButton(.neutral)
                                }
                                .padding(.vertical, 8)

                                if record.id != lastID {
                                    SectionDivider()
                                }
                            }
                        }
                    }
                    .cardStyle()
                }
            }
            .padding(.vertical)
        }
        .task { await vm.loadQuarantine() }
    }
}
