import SwiftUI

/// The Orphanage screen — finds and safely stages files left behind by apps that
/// are no longer installed.
///
/// ```swift
/// OrphanageView(vm: appVM.orphanageViewModel)
/// ```
struct OrphanageView: View {
    /// The screen's view model, owned by `AppViewModel` and injected into the
    /// subtree as an `EnvironmentObject` by the body.
    let vm: OrphanageViewModel

    var body: some View {
        OrphanageContent(vm: vm)
            .environmentObject(vm)
            .navigationTitle("Orphanage")
    }
}

/// Internal content view, observing the view model and owning the local
/// scan/quarantine tab state.
struct OrphanageContent: View {
    @ObservedObject var vm: OrphanageViewModel

    /// Which half of the feature is showing.
    enum Tab: String, CaseIterable, Identifiable {
        /// Find leftovers — the start screen, progress, and results.
        case scan
        /// Recently cleaned — staged items and their restore countdown.
        case quarantine

        /// Stable identity, mapping to the raw value.
        var id: String { rawValue }
        /// Label shown on the picker segment and in the toolbar tooltip.
        var title: String {
            switch self {
            case .scan:       return "Find Leftovers"
            case .quarantine: return "Recently Cleaned"
            }
        }
    }

    /// Which half of the feature is on screen.
    @State private var tab: Tab = .scan
    /// Drives the pre-removal preview sheet.
    @State private var showConfirmSheet = false
    /// Drives the "Reset Scan?" alert, so results are never discarded by accident.
    @State private var showResetConfirmation = false

    var body: some View {
        Group {
            switch tab {
            case .scan:
                scanTab
            case .quarantine:
                OrphanQuarantineView(tab: $tab)
            }
        }
        /// Attached to the content, not to a zero-size layer — ANTI_PATTERNS rule 14.
        .sheet(isPresented: $showConfirmSheet) {
            OrphanConfirmSheet(isPresented: $showConfirmSheet)
                .environmentObject(vm)
        }
    }

    /// The scan half: start screen → progress → grouped results.
    @ViewBuilder
    private var scanTab: some View {
        if vm.isScanning {
            OrphanScanningView()
        } else if vm.groups.isEmpty {
            OrphanStartView(tab: $tab, onStart: { vm.startScan() })
        } else {
            resultsView
        }
    }

    /// Grouped results with a sticky action bar.
    private var resultsView: some View {
        ZStack(alignment: .bottom) {
            SmoothPageScroll {
                VStack(spacing: 20) {
                    /// No tab picker here. The results screen leads with the
                    /// summary card, matching Cruft Sweeper — a segmented control
                    /// above it would be the only one of its kind on a results
                    /// page. Recently Cleaned is reachable from the toolbar
                    /// instead, so the tab is not stranded behind a reset.
                    OrphanSummaryCard()

                    if let result = vm.lastResult {
                        OrphanRunResultCard(result: result, onDismiss: { vm.lastResult = nil })
                    }

                    OrphanDetailedResultsCard()

                    /// Clearance for the sticky bar, so the last group stays reachable.
                    Color.clear.frame(height: 80)
                }
                .padding(.vertical)
            }

            if !vm.selectedIDs.isEmpty {
                VStack(spacing: 0) {
                    SectionDivider()
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(vm.selectedIDs.count) item\(vm.selectedIDs.count == 1 ? "" : "s") selected")
                                .font(.headline)
                            Text("Total: \(vm.selectedSizeFormatted)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button {
                            showConfirmSheet = true
                        } label: {
                            Text("Review & Remove")
                                .frame(minWidth: 140)
                        }
                        .appButton(.destructiveProminent)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
        }
        .alert("Reset Scan?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                vm.cancelScan()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will clear current results and take you back to the start screen.")
        }
        .toolbar {
            /// Replaces the segmented picker on this screen. Without it the only
            /// route to Recently Cleaned would be Reset Scan, which discards the
            /// results the user just paid for.
            ToolbarItem(placement: .primaryAction) {
                Button {
                    tab = .quarantine
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Recently Cleaned")
            }

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

/// Post-run summary of what moved, what was skipped, and what failed.
///
/// Deliberately built to `UpdateResultsSummaryCard`'s grammar — 16pt stack,
/// `.title2` status icon, headline title over a `.caption` secondary count line,
/// a dismiss `xmark.circle.fill`, then a `SectionDivider` before the detail —
/// because it occupies the same "here is what just happened" slot on the page.
struct OrphanRunResultCard: View {
    /// What the last quarantine run produced.
    let result: OrphanageViewModel.RunResult
    /// Clears the result so the card disappears.
    let onDismiss: () -> Void

    /// Nothing failed and nothing needed skipping.
    private var allClear: Bool { result.failed.isEmpty && result.skipped.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: allClear ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(allClear ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.quarantinedCount > 0 ? "Moved to Quarantine" : "Nothing Was Moved")
                        .font(.headline)

                    /// Counts only — the status icon above already carries the tone.
                    HStack(spacing: 6) {
                        Text("\(result.quarantinedCount) moved · \(result.reclaimed) reclaimed")
                        if !result.skipped.isEmpty {
                            Text("·")
                            Text("\(result.skipped.count) skipped")
                                .foregroundColor(.orange)
                        }
                        if !result.failed.isEmpty {
                            Text("·")
                            Text("\(result.failed.count) failed")
                                .foregroundColor(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .appButton(.plain)
            }

            if !allClear {
                SectionDivider()
            }

            if !result.skipped.isEmpty {
                detailList(
                    title: "Skipped (\(result.skipped.count))",
                    lines: result.skipped,
                    tint: .orange
                )
            }

            if !result.failed.isEmpty {
                detailList(
                    title: "Failed (\(result.failed.count))",
                    lines: result.failed,
                    tint: .red
                )
            }
        }
        .cardStyle()
    }

    /// One titled group of reason lines, matching the held-back list's shape in
    /// `UpdateResultsSummaryCard`.
    private func detailList(title: String, lines: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(tint)

            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(tint)
                        .font(.caption)
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
