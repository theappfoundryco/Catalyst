import Foundation

/// Pure filesystem algorithms for Cruft Sweeper, extracted out of
/// `CruftSweeperViewModel` (R1 god-VM decomposition). These are stateless and
/// hold no view state, so they run safely on background tasks and are unit
/// testable in isolation. The ViewModel keeps the `@Published` progress state
/// and the streaming scan orchestration, calling into this for the heavy lifting
/// (root discovery, per-project activity dating, top-level scanning, result
/// grouping, and trashing).
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
    func searchRoots(deep: Bool, customCrawlPaths: [URL]) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser

        // PRIORITIZE CUSTOM PATHS
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
                    // Skip ALL hidden top-level dirs (.vscode, .npm, .cursor,
                    // .antigravity-ide, .config, .Trash …). These are app homes and
                    // caches, not user projects; scanning them surfaced node_modules
                    // owned by installed tools — deleting those breaks the tools.
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
    func projectActivityDate(forCruftAt cruftURL: URL, fallback: Date) -> Date {
        let project = cruftURL.deletingLastPathComponent()
        var newest = Date.distantPast

        // Git activity is the strongest signal of recent work.
        for marker in [".git/index", ".git/HEAD"] {
            let url = project.appendingPathComponent(marker)
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                newest = max(newest, d)
            }
        }
        if newest > Date.distantPast { return newest }

        // Otherwise, newest immediate source file/dir (excluding known cruft).
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
    func scanTopLevel(directory: URL, type: CruftType, enabled: Bool, protectionDays: Int) -> [CruftItem] {
        guard enabled else { return [] }

        // Honor "Protect Active Projects" here too — previously DerivedData ignored
        // it, so a project you built minutes ago was still offered for deletion.
        let cutoff = protectionDays > 0
            ? Calendar.current.date(byAdding: .day, value: -protectionDays, to: Date())
            : nil

        var items: [CruftItem] = []
        do {
            let contents = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
            for url in contents {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                // Per-project DerivedData built inside the window is protected;
                // shared caches are global and always safe, so skip the check.
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
    func groupResults(_ items: [CruftItem]) -> GroupedResult {
        // O(n) deduplication keyed by path.
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
                // Separate the global shared caches from per-project build output so
                // the multi-GB cache isn't lumped in with project folders.
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
                // DYNAMIC GROUPING for "Deep Scan" or random folders.
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
    func scan(options: ScanOptions, priority: TaskPriority) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: priority) {
                await self.runScan(options: options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runScan(options: ScanOptions, emit: @Sendable @escaping (ScanEvent) -> Void) async {
        // 1. PARALLEL MAIN SCAN. No separate prescan pass: counting every file up
        //    front was a full second traversal that descended into the very
        //    node_modules/DerivedData trees the scout prunes (via skipDescendants),
        //    roughly doubling Deep-scan time. We surface a live "files analyzed"
        //    count instead of a determinate bar.
        await parallelScan(options: options, emit: emit)
        if Task.isCancelled { return }

        // 2. XCODE DERIVED DATA (top-level children)
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
    private func parallelScan(options: ScanOptions, emit: @Sendable @escaping (ScanEvent) -> Void) async {
        let (stream, continuation) = AsyncStream<Candidate>.makeStream()

        await withTaskGroup(of: Void.self) { group in
            // 1. The Scout (producer)
            group.addTask {
                self.scout(options: options, emit: emit, continuation: continuation)
            }

            // 2. A single consumer drains the candidate stream and fans work out
            //    to a bounded pool (AsyncStream supports only one iterator).
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

    private func scout(options: ScanOptions, emit: @Sendable (ScanEvent) -> Void, continuation: AsyncStream<Candidate>.Continuation) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .isHiddenKey]
        var scannedCount = 0

        for root in options.roots {
            if Task.isCancelled { break }
            if !fileManager.fileExists(atPath: root.path) { continue }

            // .skipsPackageDescendants avoids App/bundle internals; we do NOT
            // skip hidden files so we can find .venv, .gradle, etc.
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

                // Quick exclusions
                if filename == ".DS_Store" { continue }
                if filename == ".Trash" || filename == ".ssh" {
                    enumerator.skipDescendants()
                    continue
                }

                // Custom exclusions
                if !options.customExclusions.isEmpty,
                   options.customExclusions.contains(where: { fileURL.path.hasPrefix($0.path) }) {
                    enumerator.skipDescendants()
                    continue
                }

                // System exclusions (deep scan)
                if !options.systemExclusions.isEmpty,
                   options.systemExclusions.contains(where: { fileURL.path.contains("/\($0)/") }) {
                    enumerator.skipDescendants()
                    continue
                }

                // Git safety
                if options.skipGit && filename == ".git" {
                    enumerator.skipDescendants()
                    continue
                }

                // Identify cruft type (fast check)
                var type: CruftType?
                if filename == "node_modules" {
                    // Require a JS project manifest beside it, so we don't flag a
                    // node_modules owned by an installed app or IDE extension.
                    let parent = fileURL.deletingLastPathComponent()
                    let manifests = ["package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
                    if manifests.contains(where: { fileManager.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
                        type = .nodeModules
                    }
                }
                else if filename == ".venv" || filename == "venv" {
                    // Require a pyvenv.cfg marker so a random folder merely named
                    // "venv" isn't treated as a deletable virtualenv.
                    if fileManager.fileExists(atPath: fileURL.appendingPathComponent("pyvenv.cfg").path) {
                        type = .venv
                    }
                }
                else if filename == "__pycache__" { type = .cache }
                else if filename == ".gradle" {
                    // Only a project-level `.gradle` (beside a Gradle build script),
                    // never the global ~/.gradle cache home or an app's copy.
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
                    // Don't descend into a folder we've already claimed.
                    enumerator.skipDescendants()
                }
            }
        }

        continuation.finish()
    }

    private func processCandidate(_ candidate: Candidate, options: ScanOptions, emit: @Sendable (ScanEvent) -> Void) {
        // 1. Size (native) + 2. modification date
        let size = ScannerUtils.calculateSize(url: candidate.url)
        let date = (try? candidate.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        // 3. Filters (active-project protection, empty)
        if options.protectionDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -options.protectionDays, to: Date())!
            // Measure the project's recent activity, not the cruft folder's own
            // mtime (active dev edits source, not node_modules). Protect if touched
            // inside the window.
            let activity = projectActivityDate(forCruftAt: candidate.url, fallback: date)
            if activity > cutoff { return }
        }

        if !options.shouldDeleteEmpty && size == 0 {
            // Zero-byte items are noise unless the user wants empty folders cleared.
            return
        }

        emit(.found(CruftItem(url: candidate.url, type: candidate.type, size: size, dateModified: date)))
    }
}
