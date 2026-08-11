import SwiftUI
import Combine

/// A view model coordinating Orphanage — finding files left behind by apps that
/// are no longer installed, and staging them for reversible removal.
///
/// Owns only presentation state. Discovery lives in `OrphanScanner`, execution in
/// `OrphanCleanupService`, and the matching/allowlist rules in `OrphanMatcher` —
/// mirroring the Cruft Sweeper decomposition (CODING_STANDARDS 1.3).
///
/// **Gotchas:**
/// - Progress events are coalesced to ~10 Hz. The scanner stats hundreds of
///   entries per second and publishing each one re-renders the whole screen.
///
/// ```swift
/// vm.startScan()
/// ```
@MainActor
final class OrphanageViewModel: ObservableObject {

    /// Live scan progress, published as one value so a burst of updates is a
    /// single `objectWillChange` rather than two.
    struct ScanProgress: Equatable {
        /// Filesystem entries stat-ed so far.
        var examined: Int = 0
        /// The path being examined, shown as the status line's tail.
        var path: String = ""
    }

    /// Summary of the most recent quarantine run, shown as a result banner.
    struct RunResult: Equatable {
        /// How many items reached the staging directory.
        var quarantinedCount: Int
        /// Localized total size moved.
        var reclaimed: String
        /// Human-readable reasons items were passed over (in use, reappeared).
        var skipped: [String]
        /// Human-readable reasons items could not be moved.
        var failed: [String]
    }

    // MARK: - Published state

    /// Every orphaned leftover found by the last scan.
    @Published private(set) var foundItems: [LeftoverItem] = []
    /// Those leftovers bucketed by owning app, for the grouped list.
    @Published var groups: [OrphanGroup] = []
    /// Whether a scan is currently running.
    @Published private(set) var isScanning = false
    /// Status line shown under the progress indicator.
    @Published private(set) var scanStatus: String = "Ready"
    /// Coalesced scan progress.
    @Published private(set) var progress = ScanProgress()
    /// Items the user has checked for removal. Nothing is ever pre-selected.
    @Published var selectedIDs: Set<UUID> = []
    /// Manual mode — restricts the scan to leftovers matching a remembered name.
    @Published var manualFilter: String = ""
    /// Set when Full Disk Access is missing and results are therefore incomplete.
    @Published private(set) var degradedReason: String?
    /// Currently quarantined items, newest first.
    @Published private(set) var quarantined: [QuarantineRecord] = []
    /// Outcome of the most recent quarantine run.
    @Published var lastResult: RunResult?
    /// Lazily loaded children per expanded item, for the drill-down tree.
    @Published private(set) var childrenByItem: [UUID: [OrphanScanner.ChildEntry]] = [:]
    /// Whether to also list read-only system-scope leftovers.
    @Published var includeSystemScope = true
    /// Whether to include weak, name-only matches. Off by default — see
    /// `OrphanScanner.ScanOptions.includeNameOnlyMatches`.
    @Published var includeNameOnlyMatches = false

    /// Largest single item, used to scale the per-row size bars.
    ///
    /// **Gotchas:** Deliberately *not* `@Published` and not computed in `body`.
    /// Cruft Sweeper learned this the hard way — a computed `max()` read by every
    /// visible row turns one layout pass into O(n²) with an n-element allocation
    /// per row (ANTI_PATTERNS rule 7). Recomputed once per scan instead.
    private(set) var largestItemSize: Int64 = 1

    // MARK: - Collaborators

    /// Discovery engine — streams `ScanEvent`s off the main actor.
    private let scanner = OrphanScanner()
    /// Execution engine — owns the staging directory, manifest and audit log.
    private let cleanup = OrphanCleanupService()
    /// The in-flight scan, retained so `cancelScan()` can tear it down.
    private var scanTask: Task<Void, Never>?

    /// Progress-publish throttle, matching `CruftSweeperViewModel` (~10 Hz).
    private var lastProgressFlush: TimeInterval = 0
    /// Minimum gap between progress publishes, in seconds.
    private let progressFlushInterval: TimeInterval = 0.1
    /// Newest examined count, held between flushes so none are lost.
    private var latestExamined = 0

    /// A selection this large demands type-to-confirm rather than one click.
    static let bulkByteThreshold: Int64 = 5 * 1024 * 1024 * 1024
    /// So does a selection with this many items.
    static let bulkCountThreshold = 25

    // MARK: - Scanning

    /// Runs a scan and streams results into the grouped list.
    ///
    /// **Flow:**
    /// 1. Build the installed-app reference set on the main actor
    ///    (`NSWorkspace` is main-actor bound), then hand the `Sendable` index to
    ///    the detached scan.
    /// 2. Map each event onto published state, throttling progress writes.
    /// 3. Group by owning app once the stream finishes.
    func startScan() {
        guard !isScanning else { return }

        isScanning = true
        foundItems.removeAll()
        groups.removeAll()
        selectedIDs.removeAll()
        childrenByItem.removeAll()
        degradedReason = nil
        lastResult = nil
        largestItemSize = 1
        progress = ScanProgress()
        latestExamined = 0
        lastProgressFlush = 0
        scanStatus = "Building the installed-app list…"

        let filter = manualFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = OrphanScanner.ScanOptions(
            index: InstalledAppScanner.buildIndex(),
            filter: filter.isEmpty ? nil : filter,
            includeSystemScope: includeSystemScope,
            includeNameOnlyMatches: includeNameOnlyMatches
        )

        scanStatus = "Scanning leftover locations…"

        scanTask = Task { [weak self] in
            guard let self else { return }

            for await event in self.scanner.scan(options: options) {
                switch event {
                case .progress(let examined, let path):
                    self.latestExamined = examined
                    if self.shouldFlushProgress() {
                        self.progress = ScanProgress(examined: examined, path: path)
                    }
                case .found(let item):
                    self.foundItems.append(item)
                case .systemPhase:
                    self.scanStatus = "Checking system-level items…"
                case .degraded(let reason):
                    self.degradedReason = reason
                }
            }

            if Task.isCancelled { return }

            self.regroup()
            self.isScanning = false
            self.scanStatus = self.foundItems.isEmpty ? "No leftovers found" : "Scan complete"
            self.progress = ScanProgress(examined: self.latestExamined, path: "")
        }
    }

    /// Whether enough time has elapsed to publish another progress update.
    private func shouldFlushProgress() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastProgressFlush >= progressFlushInterval else { return false }
        lastProgressFlush = now
        return true
    }

    /// Stops an in-flight scan and clears results.
    func cancelScan() {
        Logger.shared.log("⏹ Orphanage: scan cancelled")
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanStatus = "Ready"
        foundItems.removeAll()
        groups.removeAll()
        selectedIDs.removeAll()
    }

    /// Buckets found items by owning app, largest group first.
    private func regroup() {
        var byApp: [String: [LeftoverItem]] = [:]
        for item in foundItems {
            byApp[item.appName, default: []].append(item)
        }
        groups = byApp
            .map { OrphanGroup(appName: $0.key, items: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.totalSize > $1.totalSize }
        largestItemSize = max(foundItems.lazy.map(\.size).max() ?? 1, 1)
    }

    // MARK: - Drill-down

    /// Loads one level of children for an item the user expanded.
    ///
    /// Cached per item so re-expanding a row costs nothing, and computed off the
    /// main actor because a directory listing plus size walk is real I/O.
    func loadChildren(for item: LeftoverItem) async {
        guard childrenByItem[item.id] == nil else { return }
        let url = item.url
        let entries = await Task.detached(priority: .userInitiated) {
            OrphanScanner.children(of: url)
        }.value
        childrenByItem[item.id] = entries
    }

    // MARK: - Selection

    /// Toggles one item's selection.
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    /// Selects or clears every actionable item in a group.
    func toggleGroup(_ group: OrphanGroup) {
        let ids = group.items.filter(\.isActionable).map(\.id)
        let allSelected = ids.allSatisfy { selectedIDs.contains($0) }
        for id in ids {
            if allSelected { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
        }
    }

    /// Selects only bundle-id matches that carry no apparent user data.
    ///
    /// **Rationale:** Name-only matches and anything with a `backup`/`data`/`vault`
    /// component are exactly the cases a bulk action should not sweep up, so this
    /// deliberately leaves them for a manual decision.
    func selectHighConfidence() {
        selectedIDs = Set(
            foundItems
                .filter { $0.isActionable && $0.confidence.isBulkSelectable && !$0.isRisky }
                .map(\.id)
        )
    }

    /// Selects every actionable item.
    ///
    /// **Gotchas:** System-scope items are excluded because they cannot be
    /// removed in Phase 1 — putting them in the selection would inflate the
    /// sticky bar's count and size with work that will silently be skipped.
    func selectAllActionable() {
        selectedIDs = Set(foundItems.filter(\.isActionable).map(\.id))
    }

    /// Clears the selection.
    func deselectAll() { selectedIDs.removeAll() }

    /// Expands or collapses every group at once.
    ///
    /// **Gotchas:** Mutates a local copy and assigns once. Writing `groups[i]` in
    /// a loop fires `objectWillChange` per iteration and churns copy-on-write
    /// bookkeeping across the whole array right before the expensive layout pass
    /// (the same fix `CruftSweeperViewModel.toggleAllGroups` carries).
    func toggleAllGroups(expanded: Bool) {
        guard !groups.isEmpty else { return }
        var updated = groups
        for index in updated.indices {
            updated[index].isExpanded = expanded
        }
        groups = updated
    }

    /// The items currently checked.
    var selectedItems: [LeftoverItem] {
        foundItems.filter { selectedIDs.contains($0.id) }
    }

    /// Combined size of the selection.
    var selectedSize: Int64 {
        selectedItems.reduce(0) { $0 + $1.size }
    }

    /// Localized combined size of the selection.
    var selectedSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: selectedSize, countStyle: .file)
    }

    /// Sum of all discovered sizes.
    var totalFoundSize: Int64 {
        foundItems.reduce(0) { $0 + $1.size }
    }

    /// Total size of everything found.
    var totalFoundSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalFoundSize, countStyle: .file)
    }

    // MARK: - Summary derivations (results screen)

    /// One reclaimable-space row per leftover category, largest first — powers the
    /// proportional breakdown bar and its legend, mirroring
    /// `CruftSweeperViewModel.TypeSummary`.
    struct CategorySummary: Identifiable {
        /// The leftover category this row totals.
        let category: LeftoverCategory
        /// Combined byte size across the category.
        let size: Int64
        /// How many items make up that size.
        let count: Int
        /// Stable identity — one row per category, so the raw value suffices.
        var id: String { category.rawValue }
        /// Localized byte size for the legend.
        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    /// Per-category totals, largest first.
    ///
    /// **Gotchas:** Zero-byte categories are omitted. Orphanage routinely finds
    /// empty plists and stub directories, which Cruft Sweeper never does — leaving
    /// them in produced a legend with four "Zero KB" rows and bar slices held open
    /// at the 2pt minimum, quietly distorting the proportions. This bar answers
    /// "where did the space go", and a category holding no space is not an answer.
    /// The items themselves still appear in the results list and in the header
    /// count; only the space breakdown skips them.
    var categoryBreakdown: [CategorySummary] {
        var acc: [LeftoverCategory: (size: Int64, count: Int)] = [:]
        for item in foundItems {
            let entry = acc[item.category] ?? (0, 0)
            acc[item.category] = (entry.size + item.size, entry.count + 1)
        }
        return acc.filter { $0.value.size > 0 }
            .map { CategorySummary(category: $0.key, size: $0.value.size, count: $0.value.count) }
            .sorted { $0.size > $1.size }
    }

    /// Whether the selection is large enough to demand type-to-confirm.
    var requiresTypeToConfirm: Bool {
        selectedSize > Self.bulkByteThreshold || selectedItems.count > Self.bulkCountThreshold
    }

    /// Whether the selection includes anything that looks data-bearing.
    var selectionContainsRisky: Bool {
        selectedItems.contains { $0.isRisky }
    }

    // MARK: - Execution

    /// Moves the selection into quarantine.
    ///
    /// **Gotchas:** The installed-app index is rebuilt *here*, not reused from the
    /// scan. Minutes may have passed and the user may have reinstalled the app in
    /// between; `OrphanCleanupService` re-checks every item against this fresh
    /// index and skips any whose owner reappeared.
    func quarantineSelected() async {
        let targets = selectedItems.filter(\.isActionable)
        guard !targets.isEmpty else { return }

        scanStatus = "Moving \(targets.count) item(s) to quarantine…"
        let index = InstalledAppScanner.buildIndex()
        let outcome = await cleanup.quarantine(targets, index: index)

        let movedPaths = Set(outcome.quarantined.map(\.originalPath))
        foundItems.removeAll { movedPaths.contains($0.path) }
        selectedIDs.removeAll()
        regroup()

        lastResult = RunResult(
            quarantinedCount: outcome.quarantined.count,
            reclaimed: ByteCountFormatter.string(
                fromByteCount: outcome.reclaimedBytes, countStyle: .file
            ),
            skipped: outcome.skipped.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent) — \($0.reason)" },
            failed: outcome.failed.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent) — \($0.reason)" }
        )
        scanStatus = foundItems.isEmpty ? "No leftovers found" : "Scan complete"
        await loadQuarantine()
    }

    // MARK: - Quarantine management

    /// Reads the staged-item manifest into `quarantined`.
    func loadQuarantine() async {
        let records = await cleanup.loadManifest()
        quarantined = records.sorted { $0.quarantinedAt > $1.quarantinedAt }
    }

    /// Restores one quarantined item to its original path.
    func restore(_ record: QuarantineRecord) async {
        let restored = await cleanup.restore(record)
        if !restored {
            Logger.shared.log("⚠️ Orphanage: restore did not complete for \(record.appName)")
        }
        await loadQuarantine()
    }

    /// Purges anything past its grace period, holding back items whose app came
    /// back and surfacing those for restore instead.
    func purgeExpired() async {
        let index = InstalledAppScanner.buildIndex()
        let heldBack = await cleanup.purgeExpired(index: index)
        await loadQuarantine()
        if !heldBack.isEmpty {
            lastResult = RunResult(
                quarantinedCount: 0,
                reclaimed: "0 bytes",
                skipped: heldBack.map { "\($0.appName) — reinstalled, kept for restore" },
                failed: []
            )
        }
    }

    /// Reads the audit log for the history view.
    func auditLog() async -> [OrphanAuditEntry] {
        await cleanup.loadAuditLog().reversed()
    }
}
