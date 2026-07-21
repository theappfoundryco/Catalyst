import SwiftUI
import Combine

@MainActor
final class CruftSweeperViewModel: ObservableObject {
    // State
    @Published var foundCruft: [CruftItem] = []
    @Published var isScanning = false
    @Published var scanStatus: String = "Ready"
    @Published var filesScanned: Int = 0
    @Published var currentScanningPath: String = ""
    @Published var selectedIDs: Set<UUID> = []

    // Phase 2: User Options
    @Published var targetFrameworks: Set<CruftType> = [.nodeModules, .venv, .derivedData, .cache, .build, .target, .gradle, .mvnTarget]
    @Published var customExclusions: [URL] = []
    @Published var customCrawlPaths: [URL] = [] // New: Specific folders to scan instead of Home
    @Published var lowPriorityMode: Bool = false
    @Published var protectActiveProjects: Int = 0 // 0 = Off, 7 = 7 days, 30 = 30 days
    @Published var deleteEmptyFolders: Bool = false

    // Grouping
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
    func toggleAllGroups(expanded: Bool) {
        for index in groupedCruft.indices {
            groupedCruft[index].isExpanded = expanded
        }
    }

    // MARK: - Scanning

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
    private func processResults() {
        let result = scanner.groupResults(foundCruft)
        self.foundCruft = result.deduped
        self.groupedCruft = result.groups
    }

    // MARK: - Actions

    func cancelScan() {
        Logger.shared.log("⏹ Cancelling scan...")
        scanTask?.cancel()
        scanTask = nil
        reset()
    }

    func reset() {
        foundCruft.removeAll()
        groupedCruft.removeAll()
        selectedIDs.removeAll()
        filesScanned = 0
        scanStatus = "Ready"
        isScanning = false
    }

    func selectAll() {
        selectedIDs = Set(foundCruft.map { $0.id })
    }

    /// Select only artifacts that regenerate automatically (caches, DerivedData),
    /// so a one-tap cleanup reclaims the safe bulk without touching things that
    /// cost a rebuild/reinstall to restore.
    func selectSafe() {
        selectedIDs = Set(foundCruft.filter { $0.type.safety == .safe }.map { $0.id })
    }

    func deselectAll() {
        selectedIDs.removeAll()
    }

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func selectItemsOlderThan(days: Int) {
        let deadline = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        let oldItems = foundCruft.filter { $0.dateModified < deadline }
        for item in oldItems {
            selectedIDs.insert(item.id)
        }
    }

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

    func addExclusion(_ url: URL) {
        customExclusions.append(url)
    }

    func removeExclusion(_ url: URL) {
        customExclusions.removeAll { $0 == url }
    }

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

    var totalFoundSize: Int64 {
        foundCruft.reduce(0) { $0 + $1.size }
    }

    var totalFoundSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: totalFoundSize, countStyle: .file)
    }

    /// Largest single item's size, used to scale the per-row size bars. Floored
    /// at 1 to avoid division by zero.
    var largestItemSize: Int64 {
        max(foundCruft.map { $0.size }.max() ?? 1, 1)
    }
}
