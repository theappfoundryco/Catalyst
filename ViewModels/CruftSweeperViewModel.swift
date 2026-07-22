import SwiftUI
import Combine

/// A view model that coordinates the Cruft Sweeper system cleanup utility.
///
/// `CruftSweeperViewModel` wraps the isolated `CruftScanner` file system engine. It maps
/// the scanner's async stream into throttle-controlled `@Published` properties to prevent UI
/// rendering bottlenecks when chewing through tens of thousands of files on disk.
///
/// **Gotchas:**
/// - It coalesces progress events (`filesScanned`) to a max of ~10Hz because `SwiftUI` cannot
///   handle high-frequency updates from thousands of fast SSD stat calls.
///
/// ```swift
/// vm.startScan(deep: true)
/// ```
@MainActor
final class CruftSweeperViewModel: ObservableObject {
    // State
    /// The flattened, deduplicated array of all discovered cruft items.
    @Published var foundCruft: [CruftItem] = []
    /// Indicates if the background scanner is currently active.
    @Published var isScanning = false
    /// The user-facing status label (e.g., "Checking Xcode DerivedData...").
    @Published var scanStatus: String = "Ready"
    /// The running count of scanned files (throttled).
    @Published var filesScanned: Int = 0
    /// The raw path currently being processed (throttled).
    @Published var currentScanningPath: String = ""
    /// The set of item IDs currently marked for deletion.
    @Published var selectedIDs: Set<UUID> = []

    // Phase 2: User Options
    // Phase 2: User Options
    /// The specific categories of cruft to look for.
    @Published var targetFrameworks: Set<CruftType> = [.nodeModules, .venv, .derivedData, .cache, .build, .target, .gradle, .mvnTarget]
    /// Directories completely excluded from the scan.
    @Published var customExclusions: [URL] = []
    /// Specific folders to scan instead of the entire Home directory.
    @Published var customCrawlPaths: [URL] = [] // New: Specific folders to scan instead of Home
    /// Reduces CPU priority (`.background`) to avoid hogging the system on massive drives.
    @Published var lowPriorityMode: Bool = false
    /// Protects artifacts younger than this many days (0 = disabled).
    @Published var protectActiveProjects: Int = 0 // 0 = Off, 7 = 7 days, 30 = 30 days
    /// Whether to prune the parent folder if it becomes empty post-deletion.
    @Published var deleteEmptyFolders: Bool = false

    // Grouping
    /// Display-ready groupings of the `foundCruft`, organized logically by root location.
    @Published var groupedCruft: [LocationGroup] = []

    // Task Management
    private var scanTask: Task<Void, Never>?

    // Progress-publish throttling (R2): the scanner emits a progress event every
    // 500 files, which on a fast SSD fires dozens of times/sec. Publishing each
    // one re-renders the whole CruftSweeperView. We coalesce the @Published
    // progress writes to ~10/sec and flush the true final count on completion.
    private var lastProgressFlush: TimeInterval = 0
    private var latestScannedCount: Int = 0
    private let progressFlushInterval: TimeInterval = 0.1 // ~10 Hz

    /// Determines if enough time has passed to safely publish a new progress event.
    ///
    /// **Rationale:**
    /// Throttles UI updates to ~10 Hz to prevent SwiftUI from choking on rapid `@Published` mutations.
    ///
    /// - Returns: `true` if the UI should be updated with the latest count.
    private func shouldFlushProgress() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastProgressFlush >= progressFlushInterval {
            lastProgressFlush = now
            return true
        }
        return false
    }

    /// Pure filesystem algorithms + the streaming scan engine, extracted out of
    /// this VM (R1). This VM now just snapshots options, consumes the scanner's
    /// event stream, and maps events onto its `@Published` state.
    private let scanner = CruftScanner()

    // MARK: - Actions
    
    /// Expands or collapses all location groups in the UI simultaneously.
    ///
    /// - Parameter expanded: `true` to expand all, `false` to collapse all.
    func toggleAllGroups(expanded: Bool) {
        for index in groupedCruft.indices {
            groupedCruft[index].isExpanded = expanded
        }
    }

    // MARK: - Scanning
    
    /// Initiates a background scan using ``CruftScanner``.
    ///
    /// **Flow:**
    /// 1. Resets all local state variables and arrays.
    /// 2. Assembles ``CruftScanner/ScanOptions`` from the user's UI selections.
    /// 3. Spawns a background ``Task`` to consume the asynchronous event stream from the scanner.
    /// 4. Maps `.progress` and `.found` events back to the MainActor state, employing throttling to protect the runloop.
    /// 5. Finalizes and groups the results upon completion.
    ///
    /// - Parameters:
    ///   - deep: If true, extends the scan to more invasive directories.
    ///   - skipGit: If true, stops the scanner from entering `.git` directories.
    func startScan(deep: Bool = false, skipGit: Bool = false) {
        guard !isScanning else { return }

        // RESET STATE
        isScanning = true
        foundCruft.removeAll()
        selectedIDs.removeAll()
        groupedCruft.removeAll()
        filesScanned = 0
        scanStatus = "Scanning..."
        lastProgressFlush = 0
        latestScannedCount = 0

        let priority: TaskPriority = lowPriorityMode ? .background : .userInitiated
        let options = CruftScanner.ScanOptions(
            roots: scanner.searchRoots(deep: deep, customCrawlPaths: customCrawlPaths),
            systemExclusions: deep ? ["Library", "Music", "Pictures", "Movies", "Public", "Applications"] : [],
            skipGit: skipGit,
            customExclusions: customExclusions,
            targetFrameworks: targetFrameworks,
            protectionDays: protectActiveProjects,
            shouldDeleteEmpty: deleteEmptyFolders
        )

        // Consume the scanner's event stream on the MainActor, applying each
        // event to @Published state. The heavy filesystem work runs on a
        // background task owned by the stream; cancelling `scanTask` tears it
        // down (via the stream's onTermination).
        scanTask = Task { [weak self] in
            guard let self else { return }

            for await event in self.scanner.scan(options: options, priority: priority) {
                switch event {
                case .progress(let scanned, let path):
                    // Always record the latest count (cheap, non-published) so the
                    // finalize block can flush an accurate filesScanned; only push
                    // to @Published at most ~10/sec to avoid whole-view re-renders.
                    self.latestScannedCount = scanned
                    if self.shouldFlushProgress() {
                        self.filesScanned = scanned
                        self.currentScanningPath = path
                    }
                case .found(let item):
                    self.foundCruft.append(item)
                case .derivedDataPhase:
                    self.scanStatus = "Checking Xcode DerivedData..."
                }
            }

            // If we were cancelled, `cancelScan()` already reset state.
            if Task.isCancelled { return }

            // Finalize — flush the true final count that throttling may have skipped.
            self.processResults()
            self.isScanning = false
            self.scanStatus = "Scan Complete"
            self.filesScanned = self.latestScannedCount
            self.currentScanningPath = ""
        }
    }

    // MARK: - Result Processing and Grouping
    /// Coalesces the raw unorganized cruft items into structured UI groups.
    ///
    /// **Rationale:**
    /// Offloads the grouping logic back to the `scanner` engine so the ViewModel remains focused on state.
    private func processResults() {
        let result = scanner.groupResults(foundCruft)
        self.foundCruft = result.deduped
        self.groupedCruft = result.groups
    }

    // MARK: - Actions
    
    /// Immediately halts the background task and resets the UI.
    ///
    /// **Gotchas:**
    /// - Cancelling the ``scanTask`` automatically terminates the underlying `AsyncStream` inside ``CruftScanner``.
    func cancelScan() {
        Logger.shared.log("⏹ Cancelling scan...")
        scanTask?.cancel()
        scanTask = nil
        reset()
    }

    /// Clears all results, selection sets, and progress counters.
    func reset() {
        foundCruft.removeAll()
        groupedCruft.removeAll()
        selectedIDs.removeAll()
        filesScanned = 0
        scanStatus = "Ready"
        isScanning = false
    }

    /// Marks all items in the current result set for deletion.
    /// Maps the exact `UUID`s into ``selectedIDs``.
    func selectAll() {
        selectedIDs = Set(foundCruft.map { $0.id })
    }

    /// Selects only artifacts that regenerate automatically (caches, DerivedData).
    ///
    /// **Rationale:**
    /// Allows a one-tap cleanup to reclaim the safe bulk without touching things that cost a rebuild or reinstall to restore (e.g., node_modules).
    func selectSafe() {
        selectedIDs = Set(foundCruft.filter { $0.type.safety == .safe }.map { $0.id })
    }

    /// Deselects everything by emptying the ``selectedIDs`` set.
    func deselectAll() {
        selectedIDs.removeAll()
    }

    /// Toggles the selection state for a specific item ID.
    ///
    /// - Parameter id: The `UUID` of the item to toggle.
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    /// Highlights only items that were last modified more than `days` ago.
    ///
    /// - Parameter days: The age threshold in days.
    func selectItemsOlderThan(days: Int) {
        let deadline = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let oldItems = foundCruft.filter { $0.dateModified < deadline }
        for item in oldItems {
            selectedIDs.insert(item.id)
        }
    }

    /// Issues a permanent deletion (trash) for all currently selected items.
    ///
    /// **Flow:**
    /// 1. Filters the dataset to find items matching ``selectedIDs``.
    /// 2. Offloads the deletion loop to a detached task calling ``CruftScanner/trash(_:)``.
    /// 3. Cleans up the MainActor state and regroups the remaining items.
    func deleteSelected() async {
        let targets = foundCruft.filter { selectedIDs.contains($0.id) }
        let scanner = self.scanner
        await Task.detached {
            scanner.trash(targets)
        }.value

        // Refresh
        await MainActor.run {
            self.foundCruft.removeAll { self.selectedIDs.contains($0.id) }
            self.selectedIDs.removeAll()
            self.processResults()
        }
    }

    /// Adds a path to the custom exclusion list so it's skipped in future scans.
    ///
    /// - Parameter url: The folder to exclude.
    func addExclusion(_ url: URL) {
        customExclusions.append(url)
    }

    /// Removes a previously added exclusion path.
    ///
    /// - Parameter url: The folder to remove from the exclusion list.
    func removeExclusion(_ url: URL) {
        customExclusions.removeAll { $0 == url }
    }

    /// Sum of file sizes for currently checked items, formatted for display.
    var totalSelectedSize: String {
        let size = foundCruft.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: - Summary derivations (results screen)

    /// One reclaimable-space row per artifact type, largest first — powers the
    /// summary breakdown bar and legend.
    struct TypeSummary: Identifiable {
        let type: CruftType
        let size: Int64
        let count: Int
        var id: String { type.rawValue }
        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }

    var typeBreakdown: [TypeSummary] {
        var acc: [CruftType: (size: Int64, count: Int)] = [:]
        for item in foundCruft {
            let entry = acc[item.type] ?? (0, 0)
            acc[item.type] = (entry.size + item.size, entry.count + 1)
        }
        return acc.map { TypeSummary(type: $0.key, size: $0.value.size, count: $0.value.count) }
            .sorted { $0.size > $1.size }
    }

    /// Sum of all discovered file sizes.
    var totalFoundSize: Int64 {
        foundCruft.reduce(0) { $0 + $1.size }
    }

    /// Formatted sum of all discovered file sizes.
    var totalFoundSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalFoundSize, countStyle: .file)
    }

    /// Largest single item's size, used to scale the per-row size bars. Floored
    /// at 1 to avoid division by zero.
    var largestItemSize: Int64 {
        max(foundCruft.map { $0.size }.max() ?? 1, 1)
    }
}
