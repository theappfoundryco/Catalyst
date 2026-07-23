/// Subview components extracted from CruftSweeperView for better modularity.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Start Scan View
/// The initial configuration view for the Cruft Sweeper, allowing selection of scan mode and targets.
///
/// ```swift
/// StartScanView(scanType: $type, skipGit: $skipGit, onStart: { print("Started") })
/// ```
struct StartScanView: View {
    @EnvironmentObject var vm: CruftSweeperViewModel
    @Binding var scanType: CruftSweeperContent.ScanType
    @Binding var skipGit: Bool
    let onStart: () -> Void
    
    // Local state for file importers
    @State private var showingExcludeImporter = false
    @State private var showingIncludeImporter = false
    // Targets are collapsed by default — they default to "all on", so most users
    // never need to open them; the header shows the selected count.
    @State private var targetsExpanded = false
    
    var body: some View {
        SmoothPageScroll {
            VStack(spacing: 24) {
                
                
                MasterHeaderView(
                    title: "Cruft Sweeper",
                    subtitle: "Reclaim disk space by clearing build artifacts and development clutter",
                    image: "trash.slash.fill",
                    color: .red
                )
                
                // 1. Unified Configuration Card
                VStack(alignment: .leading, spacing: 20) {
                    // Scan Mode Section
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Scan Mode")
                            .font(.headline)
                        SectionDivider()
                        
                        Picker("Scan Mode", selection: $scanType) {
                            Text("Quick Scan").tag(CruftSweeperContent.ScanType.quick)
                            Text("Deep Scan").tag(CruftSweeperContent.ScanType.deep)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(scanType.points, id: \.self) { point in
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
                    
                    // Targets — collapsible; rows mirror the Safety & Performance
                    // grammar below for absolute visual consistency.
                    InstantDisclosureGroup(
                        isExpanded: $targetsExpanded,
                        label: {
                            HStack(spacing: 8) {
                                Text("Targets")
                                    .font(.headline)
                                Text("· \(vm.targetFrameworks.count) of \(CruftType.allCases.count - 1) selected")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        },
                        content: {
                            let targetTypes = CruftType.allCases.filter { $0 != .unknown }
                            VStack(spacing: 16) {
                                SectionDivider().padding(.top, 8)
                                ForEach(Array(targetTypes.enumerated()), id: \.element) { index, type in
                                    TargetToggleRow(
                                        type: type,
                                        isOn: vm.targetFrameworks.contains(type)
                                    ) {
                                        if vm.targetFrameworks.contains(type) {
                                            vm.targetFrameworks.remove(type)
                                        } else {
                                            vm.targetFrameworks.insert(type)
                                        }
                                    }
                                    if index < targetTypes.count - 1 {
                                        SectionDivider()
                                    }
                                }
                            }
                        }
                    )

                    SectionDivider()

                    // Safety & Performance Header
                    Text("Safety & Performance")
                        .font(.headline)
                    
                    // Options List (Using Toggle Switches)
                    VStack(spacing: 16) {
                        // Skip Git
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundColor(.orange)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading) {
                                Text("Skip .git repositories")
                                    .font(.body)
                                Text("Prevent cleanup inside active git projects")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $skipGit)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        
                        SectionDivider()
                        
                        // Protect Active Projects
                        HStack {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundColor(.green)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading) {
                                Text("Protect Active Projects")
                                    .font(.body)
                                Text("Ignore items modified recently")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Picker("", selection: $vm.protectActiveProjects) {
                                Text("Off").tag(0)
                                Text("7 Days").tag(7)
                                Text("14 Days").tag(14)
                                Text("30 Days").tag(30)
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                        
                        SectionDivider()
                        
                        /// Scan Empty Folders
                        ///
                        /// **Rationale:** Provides granular control over the most aggressive scanning option, as many project frameworks (like Django) rely on empty `__init__.py` container directories.
                        HStack {
                            Image(systemName: "folder.badge.questionmark")
                                .foregroundColor(.blue)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading) {
                                Text("Scan Empty Folders")
                                    .font(.body)
                                Text("Find and delete empty directories")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $vm.deleteEmptyFolders)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        
                        SectionDivider()
                        
                        /// Low Priority Mode
                        ///
                        /// **Rationale:** Allows users to run heavy IO-bound cruft scans in the background without stuttering foreground applications.
                        HStack {
                            Image(systemName: "tortoise.fill")
                                .foregroundColor(.purple)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading) {
                                Text("Low Priority Mode")
                                    .font(.body)
                                Text("Run scan in background to prevent system lag")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $vm.lowPriorityMode)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                    }
                }
                .cardStyle()
                
                /// 3. Custom Execution & Exclusion Cards
                ///
                /// **Rationale:** Groups advanced path management separately from simple binary toggles.
                
                /// Included Folders (Custom Execution)
                ///
                /// **Rationale:** Allows users to forcefully scope the scanner to a single deeply-nested directory rather than sweeping the entire user space.
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Manual Scan Scope")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingIncludeImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .appButton(.plain)
                    }
                    SectionDivider()
                    
                    if vm.customCrawlPaths.isEmpty {
                        HStack {
                            Text("Scan default locations (Home/Desktop/Projects...)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                            Spacer()
                        }
                    } else {
                        ForEach(vm.customCrawlPaths, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.blue)
                                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    vm.customCrawlPaths.removeAll { $0 == url }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .appButton(.plain)
                            }
                        }
                    }
                }
                .cardStyle()
                .fileImporter(isPresented: $showingIncludeImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result {
                        /// Append unique
                        ///
                        /// **Gotchas:** Allowing duplicate paths in the inclusion list causes the scanner to process the same files twice, corrupting the reclaimed space metrics.
                        for url in urls {
                            if !vm.customCrawlPaths.contains(url) { vm.customCrawlPaths.append(url) }
                        }
                    }
                }
                
                /// Excluded Folders
                ///
                /// **Rationale:** Provides an explicit escape hatch for sensitive directories (e.g. `~/.ssh` or `~/Documents/Vault`) that should never be touched.
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Excluded Folders")
                            .font(.headline)
                        Spacer()
                        Button {
                            showingExcludeImporter = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .appButton(.plain)
                    }
                    SectionDivider()
                    
                    if vm.customExclusions.isEmpty {
                        Text("No custom exclusions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ForEach(vm.customExclusions, id: \.self) { url in
                            HStack {
                                Image(systemName: "folder.badge.minus")
                                    .foregroundColor(.red)
                                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    vm.removeExclusion(url)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .appButton(.plain)
                            }
                        }
                    }
                }
                .cardStyle()
                .fileImporter(isPresented: $showingExcludeImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                     if case .success(let urls) = result {
                         for url in urls { vm.addExclusion(url) }
                     }
                }
                
                /// Start Action
                ///
                /// **Rationale:** The primary CTA is positioned last so the user naturally reviews all configuration options before launching a destructive scan.
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
}

// MARK: - Target Toggle Row

/// A single artifact-type target, styled identically to the Safety & Performance
/// rows (colored icon + title + subtitle + trailing switch) for consistency.
///
/// ```swift
/// TargetToggleRow(type: .derivedData, isOn: true) { toggle() }
/// ```
struct TargetToggleRow: View {
    let type: CruftType
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: type.icon)
                .foregroundColor(type.color)
                .frame(width: 24)

            VStack(alignment: .leading) {
                Text(type.title)
                    .font(.body)
                Text(type.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(get: { isOn }, set: { _ in action() }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

// MARK: - Scanning View
/// A view displayed during an active Cruft Sweeper scan to show progress and current status.
///
/// ```swift
/// ScanningView()
/// ```
struct ScanningView: View {
    @EnvironmentObject var vm: CruftSweeperViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .symbolEffect(.bounce, options: .repeating)
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                Text(vm.scanStatus)
                    .font(.title2.bold())

                Text(vm.currentScanningPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
                    .id(vm.currentScanningPath)
            }

            VStack(spacing: 4) {
                Text("\(vm.filesScanned)")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText())
                Text("Files Analyzed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Material.thinMaterial)
            .cornerRadius(12)

            /// The total isn't known without a costly pre-count pass, so the bar is
            /// indeterminate; the live count above conveys progress.
            ///
            /// **Gotchas:** Attempting to force a determinate progress bar by running a pre-count pass doubles the disk IO cost and infuriates users waiting for the scan to start.
            ProgressView()
                .controlSize(.small)

            /// Abort Button
            ///
            /// **Rationale:** Ensures users can bail out of an IO-heavy scan if their fans spin up or they realize they missed an exclusion rule.
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

// MARK: - Results Dashboard
/// The final results view displaying found cruft, grouped by location, with actions to delete.
///
/// ```swift
/// ResultsDashboard(showDeleteConfirmation: $showDialog)
/// ```
struct ResultsDashboard: View {
    @EnvironmentObject var vm: CruftSweeperViewModel
    @Binding var showDeleteConfirmation: Bool

    @State private var showResetConfirmation = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SmoothPageScroll {
                VStack(spacing: 20) {

                    /// Summary — hero reclaim number, type breakdown, smart selection.
                    ///
                    /// **Rationale:** Front-loads the value proposition of the scan before asking the user to manually verify individual files.
                    CruftSummaryCard()

                    /// Detailed Results (Grouped by Location)
                    ///
                    /// **Rationale:** Grouping results geographically helps users contextualize the cruft (e.g., all `DerivedData` sits together).
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Detailed Results")
                                .font(.headline)

                            Spacer()

                            /// Check if any group is collapsed (to decide button state)
                            ///
                            /// **Rationale:** Keeps the global "Expand All" / "Collapse All" toggle perfectly synchronized with manual per-group toggles.
                            let anyCollapsed = vm.groupedCruft.contains { !$0.isExpanded }

                            Button {
                                vm.toggleAllGroups(expanded: anyCollapsed)
                            } label: {
                                Text(anyCollapsed ? "Expand All" : "Collapse All")
                                    .font(.caption.bold())
                            }
                            .appButton(.plain)
                        }

                        SectionDivider()

                        ForEach($vm.groupedCruft) { $group in
                            InstantDisclosureGroup(
                                isExpanded: $group.isExpanded,
                                label: {
                                    HStack {
                                        Image(systemName: "folder.fill")
                                            .foregroundColor(.blue)
                                        Text(group.name)
                                            .font(.subheadline.bold())
                                        Spacer()
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
                                    VStack(spacing: 0) {
                                        SectionDivider().padding(.vertical, 8)
                                        ForEach(group.items) { item in
                                            CruftItemRow(
                                                item: item,
                                                isSelected: vm.selectedIDs.contains(item.id),
                                                fractionOfMax: Double(item.size) / Double(vm.largestItemSize),
                                                onToggle: { vm.toggleSelection(item.id) }
                                            )
                                            .equatable()
                                            .padding(.vertical, 8)

                                            if item.id != group.items.last?.id {
                                                SectionDivider()
                                            }
                                        }
                                    }
                                }
                            )

                            if group.id != vm.groupedCruft.last?.id {
                                SectionDivider().padding(.vertical, 4)
                            }
                        }
                    }
                    .cardStyle()

                    /// Bottom padding for floating bar
                    ///
                    /// **Gotchas:** Omitting this padding causes the last few rows of results to become completely inaccessible behind the sticky action footer.
                    Color.clear.frame(height: 80)
                }
                .padding(.vertical)
            }

            /// Sticky Action Bar
            ///
            /// **Rationale:** Anchoring the execution button prevents users from having to scroll back to the top of a 2,000-item list to hit delete.
            if !vm.selectedIDs.isEmpty {
                VStack(spacing: 0) {
                    SectionDivider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(vm.selectedIDs.count) items selected")
                                .font(.headline)
                            Text("Total: \(vm.totalSelectedSize)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button {
                            showDeleteConfirmation = true
                        } label: {
                            Text("Delete Selected")
                                .frame(minWidth: 140)
                        }
                        .appButton(.destructiveProminent)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
        }
        .confirmationDialog(
            "Permanently Delete \(vm.selectedIDs.count) Items?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(vm.totalSelectedSize)", role: .destructive) {
                Task { await vm.deleteSelected() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("These files will be moved to Trash. This action cannot be easily undone via the app.")
        }
        .alert("Reset Scan?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                vm.reset()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will clear current results and take you back to the start screen.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showResetConfirmation = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .help("Reset Scan")
            }
        }
    }
}

// MARK: - Summary Card

/// Results hero: a single card leading with the reclaimable-space number, a
/// proportional per-type breakdown, and one-tap selection actions. Replaces the
/// old celebratory checkmark + two-number summary + duplicated heavyweights list.
private struct CruftSummaryCard: View {
    @EnvironmentObject var vm: CruftSweeperViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            /// Informative header (not a success celebration) — mirrors the
            /// status-header grammar used by UpdateResultsSummaryCard.
            ///
            /// **Rationale:** A sober, objective tone is necessary for a feature that permanently deletes data.
            HStack(spacing: 12) {
                Image(systemName: "trash.slash.fill")
                    .font(.title2)
                    .foregroundColor(.red)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Scan Complete")
                        .font(.headline)
                    Text("\(vm.foundCruft.count) items · \(vm.groupedCruft.count) locations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            SectionDivider()

            /// Hero reclaimable number.
            ///
            /// **Rationale:** The absolute byte count is the primary metric users care about when running a cleaning utility.
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(vm.totalFoundSizeFormatted)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            /// Type breakdown — proportional bar + legend, leveraging the shared
            /// per-type icons/colors.
            ///
            /// **Rationale:** Visualizing the breakdown explains *why* the disk is full without requiring users to parse raw numbers.
            if !vm.typeBreakdown.isEmpty {
                CruftBreakdownBar(segments: vm.typeBreakdown, total: vm.totalFoundSize)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(vm.typeBreakdown) { seg in
                        HStack(spacing: 8) {
                            Image(systemName: seg.type.icon)
                                .foregroundColor(seg.type.color)
                                .font(.caption)
                                .frame(width: 18)
                            Text(seg.type.title)
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
                hasSelection: !vm.selectedIDs.isEmpty,
                onSelectAll: { vm.selectAll() },
                onSelectSafe: { vm.selectSafe() },
                onClear: { vm.deselectAll() }
            )
        }
        .cardStyle()
    }
}

/// Macro-selection controls for the Cruft summary — the single source of truth for
/// the "Select All / Select Safe / Clear" action row.
///
/// Centralised so the row is defined once rather than hand-rolled inline, mirroring
/// how ``MaintenanceOperationRow`` centralises the Homebrew action buttons — and it
/// reuses the exact same button grammar via ``AppButtonKind``: `.appButton(.primary)`
/// + `.tint` for the two colored macro-selects (native prominent, so they carry real
/// depth), and `.appButton(.neutral)` for Clear. Colors are semantic per
/// `docs/CODING_STANDARDS.md` §4.13 — blue for "everything", green for the Safe
/// subset (matching Cruft's green Safe chip).
///
/// ```swift
/// SmartSelectionActions(
///     hasSelection: !vm.selectedIDs.isEmpty,
///     onSelectAll: { vm.selectAll() },
///     onSelectSafe: { vm.selectSafe() },
///     onClear: { vm.deselectAll() }
/// )
/// ```
struct SmartSelectionActions: View {
    let hasSelection: Bool
    let onSelectAll: () -> Void
    let onSelectSafe: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelectAll) {
                Label("Select All", systemImage: "checkmark.circle")
                    .font(.subheadline)
            }
            .appButton(.primary)
            .tint(.blue)

            Button(action: onSelectSafe) {
                Label("Select Safe", systemImage: "leaf")
                    .font(.subheadline)
            }
            .appButton(.primary)
            .tint(.green)

            if hasSelection {
                Button(action: onClear) {
                    Text("Clear")
                        .font(.subheadline)
                }
                .appButton(.neutral)
            }

            Spacer()
        }
    }
}

/// A single proportional bar splitting reclaimable space by artifact type.
private struct CruftBreakdownBar: View {
    let segments: [CruftSweeperViewModel.TypeSummary]
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments) { seg in
                    Rectangle()
                        .fill(seg.type.color)
                        .frame(width: max(2, geo.size.width * fraction(seg)))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

    /// Calculates the percentage of total storage consumed by a specific cruft category.
    /// - Parameter seg: The localized data model aggregating specific file types.
    /// - Returns: The calculated percentage representing spatial share.
    private func fraction(_ seg: CruftSweeperViewModel.TypeSummary) -> CGFloat {
        total > 0 ? CGFloat(Double(seg.size) / Double(total)) : 0
    }
}

// MARK: - Cruft Item Row
/// A row representing a single item of found cruft in the results dashboard.
///
/// ```swift
/// CruftItemRow(item: cruft, isSelected: true, fractionOfMax: 0.5) { toggle() }
/// ```
struct CruftItemRow: View, Equatable {
    let item: CruftItem
    let isSelected: Bool
    /// This item's size relative to the largest found item (0…1), for the size bar.
    let fractionOfMax: Double
    let onToggle: () -> Void

    /// Closure excluded: a row only changes visually with its item, selection, or
    /// bar proportion, so SwiftUI can skip re-rendering unchanged rows (R1-row).
    ///
    /// **Gotchas:** Passing an inline closure for selection handling forces SwiftUI to re-render all 5,000 list rows simultaneously every time a single checkbox is ticked, stalling the main thread.
    static func == (lhs: CruftItemRow, rhs: CruftItemRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.fractionOfMax == rhs.fractionOfMax
    }

    /// Heavyweight (≥500 MB) — the size number is emphasized so big wins stand out.
    private var isLarge: Bool { item.size >= 500 * 1024 * 1024 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .padding(.top, 4)

            Image(systemName: item.type.icon)
                .foregroundColor(item.type.color)
                .font(.title3)
                .frame(width: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.simpleName)
                        .font(.body.weight(.medium))

                    Spacer()

                    Text(item.formattedSize)
                        .font(.caption.monospacedDigit())
                        .foregroundColor(isLarge ? .orange : .primary)
                }

                /// Proportional size bar — biggest reclaim reads at a glance.
                ///
                /// **Rationale:** A subtle background fill bar draws the eye immediately to the largest offenders (like 5GB Xcode cache files).
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(item.type.color.opacity(0.8))
                            .frame(width: max(3, geo.size.width * CGFloat(fractionOfMax)))
                    }
                }
                .frame(height: 4)

                HStack(spacing: 8) {
                    Text(item.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    /// Safety chip — distinguishes auto-regenerated from costly.
                    ///
                    /// **Rationale:** Assuages user anxiety by explicitly marking caches that the system can trivially rebuild.
                    Text(item.type.safety.label)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(item.type.safety.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(item.type.safety.color.opacity(0.12)))
                        .help(item.type.safety.detail)

                    Text(item.dateModified, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggle()
        }
    }
}

// MARK: - Instant Disclosure Group

struct InstantDisclosureGroup<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    let label: Label
    let content: Content
    
    init(isExpanded: Binding<Bool>, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        self._isExpanded = isExpanded
        self.label = label()
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Button {
                /// Toggle without animation
                ///
                /// **Rationale:** Instantly updating the checkbox state feels snappier and prevents awkward transition states when rapidly checking multiple items.
                isExpanded.toggle()
            } label: {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(nil, value: isExpanded)
                    
                    label
                    
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .appButton(.plain)
            
            if isExpanded {
                content
                    /// Ensure no transition animation
                    ///
                    /// **Gotchas:** SwiftUI's default transition animations on list rows can cause visual stuttering during rapid multi-select operations.
                    .transition(.identity)
            }
        }
    }
}
