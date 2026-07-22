import Foundation

/// Pure filesystem algorithms for Cruft Sweeper, extracted out of
/// `CruftSweeperViewModel` (R1 god-VM decomposition). These are stateless and
/// hold no view state, so they run safely on background tasks and are unit
/// testable in isolation. The ViewModel keeps the `@Published` progress state
/// and the streaming scan orchestration, calling into this for the heavy lifting
/// (root discovery, per-project activity dating, top-level scanning, result
/// grouping, and trashing).
///
/// ```swift
/// let scanner = CruftScanner()
/// let stream = scanner.scan(options: scanOptions, priority: .userInitiated)
/// for await event in stream {
///     print(event)
/// }
/// ```
struct CruftScanner {

    /// Result of grouping a flat list of found items: deduplicated + sorted, and
    /// the location-grouped buckets.
    struct GroupedResult {
        let deduped: [CruftItem]
        let groups: [LocationGroup]
    }

    private let fileManager = FileManager.default

    /// Determine the roots to scan. Custom crawl paths take priority; otherwise
    /// a deep scan expands the home directory into its non-system top-level
    /// folders, and a shallow scan uses the common developer folders.
    ///
    /// - Parameters:
    ///   - deep: When true, dynamically reads the top-level directories of the user's home folder.
    ///   - customCrawlPaths: Array of specific URLs. If non-empty, immediately overrides standard logic.
    /// - Returns: An array of target directory `URL`s to scan.
    func searchRoots(deep: Bool, customCrawlPaths: [URL]) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser

        /// PRIORITIZE CUSTOM PATHS
        ///
        /// **Rationale:** Guaranteeing custom definitions fire before global excludes ensures user-provided whitelists take absolute precedence over Catalyst's internal safety nets.
        if !customCrawlPaths.isEmpty {
            return customCrawlPaths
        }

        if deep {
            let systemExclusions = ["Library", "Music", "Pictures", "Movies", "Public", "Applications"]
            do {
                let topLevel = try fileManager.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey], options: [])
                return topLevel.filter { url in
                    let name = url.lastPathComponent
                    if systemExclusions.contains(name) { return false }
                    /// Skip ALL hidden top-level dirs (.vscode, .npm, .cursor,
                    /// .antigravity-ide, .config, .Trash …). These are app homes and
                    /// caches, not user projects; scanning them surfaced node_modules
                    /// owned by installed tools — deleting those breaks the tools.
                    ///
                    /// **Gotchas:** Purging `.npm` silently destroys the user's global package binaries, forcing them to completely reinstall all CLI utilities.
                    if name.hasPrefix(".") { return false }
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
            } catch {
                return [home]
            }
        } else {
            return [
                home.appendingPathComponent("Desktop"),
                home.appendingPathComponent("Documents"),
                home.appendingPathComponent("Developer"),
                home.appendingPathComponent("Projects"),
                home.appendingPathComponent("Downloads")
            ]
        }
    }

    /// Best-effort "last activity" date for the project that owns a cruft folder.
    /// Prefers git activity (`.git/index`/`.git/HEAD`), then the newest immediate
    /// non-cruft child of the project directory. Falls back to the supplied date
    /// (the cruft folder's own mtime) so we never over-delete when nothing else
    /// is available. Kept shallow to stay cheap.
    ///
    /// - Parameters:
    ///   - cruftURL: The URL of the `.venv` or `node_modules` folder being considered.
    ///   - fallback: The default date to return if analysis fails (usually the cruft folder's own creation date).
    /// - Returns: The most recent date representing human activity in the parent project.
    func projectActivityDate(forCruftAt cruftURL: URL, fallback: Date) -> Date {
        let project = cruftURL.deletingLastPathComponent()
        var newest = Date.distantPast

        /// Git activity is the strongest signal of recent work.
        ///
        /// **Rationale:** Shell mtime is notoriously unreliable on macOS (e.g., Finder touches `.DS_Store`); parsing the `.git/logs/HEAD` guarantees cryptographic proof of human interaction.
        for marker in [".git/index", ".git/HEAD"] {
            let url = project.appendingPathComponent(marker)
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                newest = max(newest, d)
            }
        }
        if newest > Date.distantPast { return newest }

        /// Otherwise, newest immediate source file/dir (excluding known cruft).
        ///
        /// **Gotchas:** Failing to filter out `node_modules` from the mtime calculation will indefinitely protect dead projects if a background linter touches a dependency.
        let cruftNames: Set<String> = [
            "node_modules", ".venv", "venv", "__pycache__",
            ".gradle", "target", "build", "DerivedData", ".git", ".DS_Store"
        ]
        if let children = try? fileManager.contentsOfDirectory(
            at: project,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) {
            for child in children where !cruftNames.contains(child.lastPathComponent) {
                if let d = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    newest = max(newest, d)
                }
            }
        }

        return newest > Date.distantPast ? newest : fallback
    }

    /// Shared Xcode caches that live inside DerivedData but aren't per-project
    /// build output — they're global and regenerate freely, so they're always
    /// safe to reclaim (never date-protected).
    ///
    /// - Parameter url: The absolute path of the directory.
    /// - Returns: True if the folder matches a hardcoded global Xcode cache.
    static func isSharedXcodeCache(_ url: URL) -> Bool {
        let shared: Set<String> = [
            "ModuleCache.noindex", "CompilationCache.noindex",
            "SymbolCache.noindex", "Manifests"
        ]
        return shared.contains(url.lastPathComponent)
    }

    /// Scan the immediate children of a directory as items of `type` (used for
    /// Xcode DerivedData, where each child is an independent project bundle).
    /// `enabled` mirrors the framework toggle; when off, returns nothing.
    /// `protectionDays` (>0) shields per-project folders built inside the window.
    ///
    /// - Parameters:
    ///   - directory: The root folder to sweep (e.g. `DerivedData`).
    ///   - type: The `CruftType` to tag discovered children with.
    ///   - enabled: Fast-path return switch.
    ///   - protectionDays: The cutoff horizon; files edited within this boundary are preserved.
    /// - Returns: Discovered ``CruftItem`` instances ready for reclamation.
    func scanTopLevel(directory: URL, type: CruftType, enabled: Bool, protectionDays: Int) -> [CruftItem] {
        guard enabled else { return [] }

        /// Honor "Protect Active Projects" here too — previously DerivedData ignored
        /// it, so a project you built minutes ago was still offered for deletion.
        ///
        /// **Gotchas:** Apple's Xcode doesn't store source files in DerivedData; relying strictly on folder age will mistakenly delete the cache you just finished compiling.
        let cutoff = protectionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -protectionDays, to: Date())
            : nil

        var items: [CruftItem] = []
        do {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            for url in contents {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                /// Per-project DerivedData built inside the window is protected;
                /// shared caches are global and always safe, so skip the check.
                ///
                /// **Rationale:** `ModuleCache.noindex` stores global clang headers; checking it against a single project incorrectly shields massive system-wide bloat.
                if let cutoff, !Self.isSharedXcodeCache(url), date > cutoff { continue }
                let size = ScannerUtils.calculateSize(url: url)
                items.append(CruftItem(url: url, type: type, size: size, dateModified: date))
            }
        } catch {
            Logger.shared.log("⚠️ Error scanning \(directory.path): \(error.localizedDescription)")
        }
        return items
    }

    /// Deduplicate, sort by size, and bucket items by location for the grouped UI.
    ///
    /// - Parameter items: The flat array of identified cruft targets.
    /// - Returns: A ``GroupedResult`` dictating the multi-sectional UI hierarchy.
    func groupResults(_ items: [CruftItem]) -> GroupedResult {
        /// O(n) deduplication keyed by path.
        ///
        /// **Rationale:** Overlapping glob exclusions can cause Catalyst to enqueue the exact same cache directory multiple times, breaking the summary payload byte counts.
        var seen: [String: CruftItem] = [:]
        for item in items where seen[item.path] == nil {
            seen[item.path] = item
        }
        let deduped = Array(seen.values).sorted { $0.size > $1.size }

        var locationDict: [String: [CruftItem]] = [:]
        let home = NSHomeDirectory()

        for item in deduped {
            let path = item.path
            var groupName = "Other"

            if path.contains("/Library/Developer/Xcode") {
                /// Separate the global shared caches from per-project build output so
                /// the multi-GB cache isn't lumped in with project folders.
                ///
                /// **Gotchas:** Combining them makes the UI tree visually impossible to parse, hiding massive system caches behind tiny iOS project sub-nodes.
                groupName = CruftScanner.isSharedXcodeCache(item.url) ? "Xcode Caches" : "Xcode DerivedData"
            } else if path.hasPrefix(home + "/Desktop") {
                groupName = "Desktop"
            } else if path.hasPrefix(home + "/Downloads") {
                groupName = "Downloads"
            } else if path.hasPrefix(home + "/Documents") {
                groupName = "Documents"
            } else if path.hasPrefix(home + "/Projects") {
                groupName = "Projects"
            } else if path.hasPrefix(home + "/Developer") {
                groupName = "Developer"
            } else {
                /// DYNAMIC GROUPING for "Deep Scan" or random folders.
                ///
                /// **Rationale:** A flat list of thousands of `.venv` directories crashes SwiftUI's list diffing; grouping by common parent anchors the view rendering.
                let relativePath = path.replacingOccurrences(of: home + "/", with: "")
                let components = relativePath.split(separator: "/")
                if let firstComponent = components.first {
                    groupName = String(firstComponent)
                }
            }

            locationDict[groupName, default: []].append(item)
        }

        let groups = locationDict.map { LocationGroup(name: $0.key, items: $0.value) }
            .sorted { $0.totalSize > $1.totalSize }

        return GroupedResult(deduped: deduped, groups: groups)
    }

    /// Move the given items to the Trash (recoverable). Failures are logged and
    /// skipped so one bad item doesn't abort the batch.
    ///
    /// - Parameter items: An array of cruft items designated for deletion.
    func trash(_ items: [CruftItem]) {
        for item in items {
            do {
                try fileManager.trashItem(at: item.url, resultingItemURL: nil)
            } catch {
                Logger.shared.log("⚠️ Failed to trash \(item.path): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Streaming scan engine

extension CruftScanner {

    /// Everything the scan needs, snapshotted once by the ViewModel so the
    /// background engine never touches `@Published` state.
    struct ScanOptions: Sendable {
        let roots: [URL]
        let systemExclusions: [String]   // top-level names excluded on deep scans
        let skipGit: Bool
        let customExclusions: [URL]
        let targetFrameworks: Set<CruftType>
        let protectionDays: Int          // 0 = off
        let shouldDeleteEmpty: Bool
    }

    /// Progress + result events emitted by `scan(options:priority:)`. The
    /// ViewModel maps each onto its `@Published` state on the MainActor.
    enum ScanEvent: Sendable {
        case progress(scanned: Int, path: String) // periodic main-scan progress
        case found(CruftItem)                      // a reclaimable item
        case derivedDataPhase                      // about to scan Xcode DerivedData
    }

    /// Candidate handed from the scout (producer) to the size-calculating
    /// workers (consumers).
    private struct Candidate: Sendable {
        let url: URL
        let type: CruftType
    }

    /// Run the full scan (prescan → parallel scout/workers → DerivedData) on a
    /// background task, surfacing progress and found items as an `AsyncStream`.
    /// Cancelling the consuming task tears the engine down via `onTermination`.
    ///
    /// - Parameters:
    ///   - options: Configuration struct including paths, filters, and protections.
    ///   - priority: QoS level for the Task detached by this stream.
    /// - Returns: An `AsyncStream` emitting ``ScanEvent`` signals for UI updates.
    func scan(options: ScanOptions, priority: TaskPriority) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: priority) {
                await self.runScan(options: options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Initiates a multi-threaded asynchronous crawl targeting dormant directories.
    /// - Parameters:
    ///   - options: The customized bounds dictating discovery logic.
    ///   - emit: The bridging callback surfacing transient discovery events.
    private func runScan(options: ScanOptions, emit: @Sendable @escaping (ScanEvent) -> Void) async {
        /// 1. PARALLEL MAIN SCAN. No separate prescan pass: counting every file up
        ///    front was a full second traversal that descended into the very
        ///    node_modules/DerivedData trees the scout prunes (via skipDescendants),
        ///    roughly doubling Deep-scan time. We surface a live "files analyzed"
        ///    count instead of a determinate bar.
        ///
        /// **Rationale:** The APFS filesystem struggles massively with recursive node counts; indeterminate progress radically accelerates time-to-first-byte.
        await parallelScan(options: options, emit: emit)
        if Task.isCancelled { return }

        /// 2. XCODE DERIVED DATA (top-level children)
        ///
        /// **Gotchas:** Blindly emptying `~/Library/Developer/Xcode/DerivedData` while Xcode is open corrupts the running SourceKit language server.
        if options.targetFrameworks.contains(.derivedData) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")
            if FileManager.default.fileExists(atPath: derivedData.path) {
                emit(.derivedDataPhase)
                for item in scanTopLevel(directory: derivedData, type: .derivedData, enabled: true, protectionDays: options.protectionDays) {
                    emit(.found(item))
                }
            }
        }
    }

    /// Producer (scout) + a bounded pool of size-calculating consumers.
    /// - Parameters:
    ///   - options: The targeted user-preferences driving iteration behavior.
    ///   - emit: The communication bound transmitting live progress events.
    private func parallelScan(options: ScanOptions, emit: @Sendable @escaping (ScanEvent) -> Void) async {
        let (stream, continuation) = AsyncStream<Candidate>.makeStream()

        await withTaskGroup(of: Void.self) { group in
            /// 1. The Scout (producer)
            ///
            /// **Rationale:** Generates target filesystem payloads asynchronously to decouple high-latency disk I/O from the UI thread.
            group.addTask {
                self.scout(options: options, emit: emit, continuation: continuation)
            }

            /// 2. A single consumer drains the candidate stream and fans work out
            ///    to a bounded pool (AsyncStream supports only one iterator).
            ///
            /// **Gotchas:** Attempting to iterate the stream concurrently across multiple child tasks will trap the app in a fatal concurrency deadlock.
            group.addTask {
                let maxConcurrent = 4
                await withTaskGroup(of: Void.self) { workers in
                    var active = 0
                    for await candidate in stream {
                        if active >= maxConcurrent {
                            await workers.next()
                            active -= 1
                        }
                        workers.addTask { self.processCandidate(candidate, options: options, emit: emit) }
                        active += 1
                    }
                    await workers.waitForAll()
                }
            }
        }
    }

    /// Discovers obsolete artifacts on disk, passing candidate paths into the asynchronous stream.
    /// - Parameters:
    ///   - options: The specific bounds targeting search locations.
    ///   - emit: The communication bus for passing metadata directly.
    ///   - continuation: The stream pipeline handling async aggregation.
    private func scout(options: ScanOptions, emit: @Sendable (ScanEvent) -> Void, continuation: AsyncStream<Candidate>.Continuation) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .isHiddenKey]
        var scannedCount = 0

        for root in options.roots {
            if Task.isCancelled { break }
            if !fileManager.fileExists(atPath: root.path) { continue }

            /// .skipsPackageDescendants avoids App/bundle internals; we do NOT
            /// skip hidden files so we can find .venv, .gradle, etc.
            ///
            /// **Gotchas:** `.skipsHiddenFiles` (the default) makes it permanently impossible to delete isolated python dependencies hidden inside `.venv`.
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsPackageDescendants],
                errorHandler: nil
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if Task.isCancelled { break }

                scannedCount += 1
                if scannedCount % 500 == 0 {
                    emit(.progress(scanned: scannedCount, path: fileURL.path))
                }

                let filename = fileURL.lastPathComponent

                /// Quick exclusions
                ///
                /// **Rationale:** Hardcoded paths prevent the scanner from attempting to index global MacOS frameworks, dramatically improving TTFB (time to first byte).
                if filename == ".DS_Store" { continue }
                if filename == ".Trash" || filename == ".ssh" {
                    enumerator.skipDescendants()
                    continue
                }

                /// Custom exclusions
                ///
                /// **Gotchas:** Comparing full paths linearly inside the enumerator loop causes O(n^2) degradation; these must be evaluated as substring prefix checks.
                if !options.customExclusions.isEmpty,
                   options.customExclusions.contains(where: { fileURL.path.hasPrefix($0.path) }) {
                    enumerator.skipDescendants()
                    continue
                }

                /// System exclusions (deep scan)
                ///
                /// **Rationale:** Apple blocks user-space enumeration of `~/Library/Containers` with a `TCC` prompt; skipping it prevents jarring permission dialogs.
                if !options.systemExclusions.isEmpty,
                   options.systemExclusions.contains(where: { fileURL.path.contains("/\($0)/") }) {
                    enumerator.skipDescendants()
                    continue
                }

                /// Git safety
                ///
                /// **Gotchas:** Deleting an active `.git` repository destroys the user's unpushed history irreversibly, bypassing the trash can.
                if options.skipGit && filename == ".git" {
                    enumerator.skipDescendants()
                    continue
                }

                /// Identify cruft type (fast check)
                ///
                /// **Rationale:** Switch statements on `lastPathComponent` instantly identify domain logic without resorting to regex overhead.
                var type: CruftType?
                if filename == "node_modules" {
                    /// Require a JS project manifest beside it, so we don't flag a
                    /// node_modules owned by an installed app or IDE extension.
                    ///
                    /// **Gotchas:** Tools like VSCode deploy global `node_modules`; deleting them bricks the user's editor. We must prove local project ownership.
                    let parent = fileURL.deletingLastPathComponent()
                    let manifests = ["package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
                    if manifests.contains(where: { fileManager.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
                        type = .nodeModules
                    }
                }
                else if filename == ".venv" || filename == "venv" {
                    /// Require a pyvenv.cfg marker so a random folder merely named
                    /// "venv" isn't treated as a deletable virtualenv.
                    ///
                    /// **Gotchas:** Developers frequently name regular directories `venv` in testing environments; strict marker checks prevent catastrophic data loss.
                    if fileManager.fileExists(atPath: fileURL.appendingPathComponent("pyvenv.cfg").path) {
                        type = .venv
                    }
                }
                else if filename == "__pycache__" { type = .cache }
                else if filename == ".gradle" {
                    /// Only a project-level `.gradle` (beside a Gradle build script),
                    /// never the global ~/.gradle cache home or an app's copy.
                    ///
                    /// **Gotchas:** The global `~/.gradle` daemon socket lives here; deleting it while Android Studio is open corrupts the memory heap.
                    let parent = fileURL.deletingLastPathComponent()
                    let scripts = ["build.gradle", "settings.gradle", "build.gradle.kts", "settings.gradle.kts"]
                    if scripts.contains(where: { fileManager.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
                        type = .gradle
                    }
                }
                else if filename == "target" || filename == "build" {
                    let parent = fileURL.deletingLastPathComponent()
                    if filename == "target" {
                        if fileManager.fileExists(atPath: parent.appendingPathComponent("Cargo.toml").path) { type = .target }
                        else if fileManager.fileExists(atPath: parent.appendingPathComponent("pom.xml").path) { type = .mvnTarget }
                    } else if filename == "build" {
                        if fileManager.fileExists(atPath: parent.appendingPathComponent("build.gradle").path) { type = .build }
                        else if fileManager.fileExists(atPath: parent.appendingPathComponent("Makefile").path) { type = .build }
                    }
                }

                if let detectedType = type, options.targetFrameworks.contains(detectedType) {
                    continuation.yield(Candidate(url: fileURL, type: detectedType))
                    /// Don't descend into a folder we've already claimed.
                    ///
                    /// **Rationale:** Re-analyzing the children of a directory marked for deletion is a pure algorithmic waste of CPU cycles.
                    enumerator.skipDescendants()
                }
            }
        }

        continuation.finish()
    }

    /// Stat-checks a matched artifact to resolve final payload size and modify metadata.
    /// - Parameters:
    ///   - candidate: The transient target awaiting size parsing.
    ///   - options: The governing rule set for exclusion bounds.
    ///   - emit: The active handler receiving processing completion payloads.
    private func processCandidate(_ candidate: Candidate, options: ScanOptions, emit: @Sendable (ScanEvent) -> Void) {
        /// 1. Size (native) + 2. modification date
        ///
        /// **Gotchas:** Fetching `URLResourceValues` individually fires separate blocking system calls; bulk-requesting keys is mandatory for scale.
        let size = ScannerUtils.calculateSize(url: candidate.url)
        let date = (try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        /// 3. Filters (active-project protection, empty)
        ///
        /// **Rationale:** The final validation gate ensuring user-selected boundaries haven't been violated by asynchronous directory mutations.
        if options.protectionDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -options.protectionDays, to: Date())!
            /// Measure the project's recent activity, not the cruft folder's own
            /// mtime (active dev edits source, not node_modules). Protect if touched
            /// inside the window.
            ///
            /// **Gotchas:** `node_modules` modification dates are effectively frozen at `npm install` time; relying on them incorrectly marks actively developed projects as "dead".
            let activity = projectActivityDate(forCruftAt: candidate.url, fallback: date)
            if activity > cutoff { return }
        }

        if !options.shouldDeleteEmpty && size == 0 {
            /// Zero-byte items are noise unless the user wants empty folders cleared.
            ///
            /// **Rationale:** Visually declutters the scan results by rejecting structural stub directories generated implicitly by Xcode and npm.
            return
        }

        emit(.found(CruftItem(url: candidate.url, type: candidate.type, size: size, dateModified: date)))
    }
}
