import Foundation
import AppKit

/// Discovery half of Orphanage: builds the installed-app reference set, then
/// walks the known leftover locations and streams back everything no living app
/// claims.
///
/// Mirrors `CruftScanner`'s shape — a `Sendable` struct with an `AsyncStream`
/// engine, so the heavy filesystem work runs detached and the ViewModel only maps
/// events onto `@Published` state (CODING_STANDARDS 8.6).
///
/// ```swift
/// let index = await InstalledAppScanner.buildIndex()
/// for await event in OrphanScanner().scan(options: .init(index: index, filter: nil)) {
///     print(event)
/// }
/// ```

// MARK: - Installed apps

/// Builds the "still installed" reference set.
///
/// **Gotchas:** `/Applications` alone is not the whole truth. An app can run from
/// `~/Downloads`, an external volume, or a Homebrew cask path, and would then be
/// wrongly treated as uninstalled. `NSWorkspace.runningApplications` closes that
/// gap, which is why this type is `@MainActor` — that API is main-actor bound.
@MainActor
enum InstalledAppScanner {

    /// Directories searched for `.app` bundles, one level deep (so
    /// `/Applications/Utilities/Terminal.app` is found).
    private static func searchRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications")
        ]
    }

    /// Enumerates installed and running apps into a `Sendable` index safe to hand
    /// to the detached scan.
    ///
    /// - Returns: Bundle identifiers, display names, and vendor lineage tokens.
    static func buildIndex() -> InstalledAppIndex {
        var bundleIDs: Set<String> = []
        var names: Set<String> = []

        for root in searchRoots() {
            collectApps(in: root, depth: 0, bundleIDs: &bundleIDs, names: &names)
        }

        /// Anything currently running counts as installed regardless of location.
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { bundleIDs.insert(id.lowercased()) }
            if let name = app.localizedName { names.insert(name.lowercased()) }
        }

        /// Lineage tokens let an upgraded app (iMazing 2 → 3) keep claiming the
        /// older version's leftovers.
        var lineage = Set(bundleIDs.map { OrphanMatcher.lineageToken(from: $0) })
        lineage.formUnion(names.map { $0.replacingOccurrences(of: " ", with: "") })
        lineage.remove("")

        return InstalledAppIndex(bundleIDs: bundleIDs, names: names, lineageTokens: lineage)
    }

    /// Recursively gathers `.app` bundles, descending at most one folder level.
    private static func collectApps(
        in directory: URL,
        depth: Int,
        bundleIDs: inout Set<String>,
        names: inout Set<String>
    ) {
        guard depth <= 1,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              )
        else { return }

        for url in contents {
            if url.pathExtension == "app" {
                if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                    bundleIDs.insert(id.lowercased())
                }
                names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                collectApps(in: url, depth: depth + 1, bundleIDs: &bundleIDs, names: &names)
            }
        }
    }
}

// MARK: - Leftover scanning

/// Walks the known leftover locations and reports unclaimed entries.
struct OrphanScanner: Sendable {

    /// Everything the scan needs, snapshotted once so the background engine never
    /// reads `@Published` state.
    struct ScanOptions: Sendable {
        /// The reference set of currently installed apps.
        let index: InstalledAppIndex
        /// Manual mode — when set, only leftovers whose name contains this token
        /// (case-insensitive) are reported.
        let filter: String?
        /// Whether to also enumerate read-only system-scope locations.
        let includeSystemScope: Bool
        /// Whether to report name-only matches.
        ///
        /// **Gotchas:** Off by default, and it should stay that way. A dry run
        /// against a real Mac produced 66 name-only "orphans" of which nearly all
        /// were live tooling or Apple system data — `typescript`, `node-gyp`,
        /// `Jedi`, `GeoServices`. Anything without a bundle id cannot be matched
        /// against `/Applications` with any confidence, so surfacing those by
        /// default would make the feature's first impression a list of things the
        /// user must not delete.
        let includeNameOnlyMatches: Bool
    }

    /// Progress and result events emitted by ``scan(options:)``.
    enum ScanEvent: Sendable {
        /// Periodic progress: entries examined so far, and the current path.
        case progress(examined: Int, path: String)
        /// A leftover with no living owner.
        case found(LeftoverItem)
        /// Entering the read-only system-scope phase.
        case systemPhase
        /// Full Disk Access is missing, so container/sandbox data is invisible.
        case degraded(reason: String)
    }

    /// Owns the ownership verdict for a path component — the safety core.
    private let matcher = OrphanMatcher()

    /// Whether Catalyst can read TCC-protected locations.
    ///
    /// **Gotchas:** Without Full Disk Access, `~/Library/Containers` reads return
    /// an **empty list rather than an error** — which reads as "no leftovers
    /// found", the most dangerous false negative this feature can produce. The
    /// scan therefore probes explicitly and reports `.degraded` instead of
    /// silently under-reporting.
    static func hasFullDiskAccess() -> Bool {
        let probe = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        return FileManager.default.isReadableFile(atPath: probe.path)
    }

    /// Runs the scan on a detached task, streaming events back.
    ///
    /// - Parameter options: The snapshotted reference set and filters.
    /// - Returns: An `AsyncStream` of ``ScanEvent`` values.
    func scan(options: ScanOptions) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await self.run(options: options) { continuation.yield($0) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Scan body: user-scope roots, then optionally the read-only system roots.
    private func run(options: ScanOptions, emit: @Sendable @escaping (ScanEvent) -> Void) async {
        if !Self.hasFullDiskAccess() {
            emit(.degraded(reason: "Full Disk Access is off — sandboxed app data (Containers) can't be read, so results are incomplete."))
        }

        var examined = 0

        for root in OrphanPathValidator.allowedRoots() {
            if Task.isCancelled { return }
            scanRoot(root, options: options, examined: &examined, emit: emit)
        }

        guard options.includeSystemScope, !Task.isCancelled else { return }
        emit(.systemPhase)
        for root in OrphanPathValidator.systemRoots {
            if Task.isCancelled { return }
            scanSystemRoot(root, options: options, examined: &examined, emit: emit)
        }
    }

    /// Examines the direct children of one allowed root.
    ///
    /// **Rationale:** Only direct children are considered, matching
    /// `OrphanPathValidator.isEligible`. Deeper classification (the iMazing
    /// `Backups/…/Temp` case) is a drill-down concern handled by
    /// ``children(of:)`` when the user expands a row, not something to walk
    /// eagerly for every app on the Mac.
    private func scanRoot(
        _ root: URL,
        options: ScanOptions,
        examined: inout Int,
        emit: @Sendable (ScanEvent) -> Void
    ) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: []
        ) else { return }

        let category = Self.category(forRoot: root)

        for url in contents {
            if Task.isCancelled { return }
            examined += 1
            if examined % 25 == 0 { emit(.progress(examined: examined, path: url.path)) }

            let component = url.lastPathComponent
            if component == ".DS_Store" { continue }

            /// The allowlist gate runs before anything else touches the path.
            guard OrphanPathValidator.isEligible(url) else { continue }

            if let filter = options.filter,
               !component.localizedCaseInsensitiveContains(filter) { continue }

            guard case .orphaned(let confidence) = matcher.classify(
                component: component, against: options.index
            ) else { continue }

            if confidence == .nameOnly && !options.includeNameOnlyMatches { continue }

            let size = ScannerUtils.calculateSize(url: url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()

            emit(.found(LeftoverItem(
                url: url,
                category: category,
                size: size,
                lastModified: modified,
                bundleID: OrphanMatcher.bundleID(fromComponent: component),
                appName: OrphanMatcher.displayName(fromComponent: component),
                confidence: confidence
            )))
        }
    }

    /// Enumerates a system-scope root. Results are reported for visibility only —
    /// `LeftoverCategory.isUserRemovable` is `false` for all of these.
    private func scanSystemRoot(
        _ root: URL,
        options: ScanOptions,
        examined: inout Int,
        emit: @Sendable (ScanEvent) -> Void
    ) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let category = Self.category(forRoot: root)

        for url in contents {
            if Task.isCancelled { return }
            examined += 1
            if examined % 25 == 0 { emit(.progress(examined: examined, path: url.path)) }

            let component = url.deletingPathExtension().lastPathComponent
            if let filter = options.filter,
               !component.localizedCaseInsensitiveContains(filter) { continue }

            /// Apple's own daemons are excluded by the same bundle-prefix rule the
            /// validator uses, so they never reach the list.
            guard OrphanMatcher.bundleID(fromComponent: component)?.hasPrefix("com.apple.") != true else {
                continue
            }

            guard case .orphaned(let confidence) = matcher.classify(
                component: component, against: options.index
            ) else { continue }

            if confidence == .nameOnly && !options.includeNameOnlyMatches { continue }

            let size = ScannerUtils.calculateSize(url: url)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()

            emit(.found(LeftoverItem(
                url: url,
                category: category,
                size: size,
                lastModified: modified,
                bundleID: OrphanMatcher.bundleID(fromComponent: component),
                appName: OrphanMatcher.displayName(fromComponent: component),
                confidence: confidence
            )))
        }
    }

    /// Maps a scan root to the category its children belong to.
    private static func category(forRoot root: URL) -> LeftoverCategory {
        switch root.lastPathComponent {
        case "Application Support":     return .applicationSupport
        case "Caches":                  return .caches
        case "Preferences":             return .preferences
        case "Logs":                    return .logs
        case "Saved Application State": return .savedState
        case "HTTPStorages":            return .httpStorages
        case "WebKit":                  return .webKit
        case "Containers":              return .containers
        case "Group Containers":        return .groupContainers
        case "LaunchDaemons":           return .systemLaunchDaemon
        case "PrivilegedHelperTools":   return .privilegedHelper
        case "LaunchAgents":
            return root.path.hasPrefix("/Library") ? .systemLaunchAgent : .userLaunchAgent
        default:
            return .applicationSupport
        }
    }

    // MARK: - Drill-down

    /// One level of children under a leftover, for the expand-to-preview tree.
    struct ChildEntry: Identifiable, Sendable, Equatable {
        /// Stable identity for SwiftUI diffing.
        let id: UUID
        /// Absolute location of the child.
        let url: URL
        /// Byte size, recursive for directories.
        let size: Int64
        /// Filesystem modification date.
        let lastModified: Date
        /// Whether the child is itself a directory.
        let isDirectory: Bool

        /// Basename shown in the tree.
        var name: String { url.lastPathComponent }
        /// Localized size.
        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        /// Whether this specific child looks data-bearing.
        var isRisky: Bool {
            LeftoverItem.riskyKeywords.contains(name.lowercased())
        }
    }

    /// Lists the immediate children of a leftover so the user can judge at the
    /// leaf level rather than trusting the top-level folder name.
    ///
    /// **Rationale:** Spec case — `Application Support/iMazing/Backups/…/Temp` is
    /// disposable while its `Backups` parent may hold real device backups. Only
    /// one level is read per call; the view requests deeper levels on demand, so
    /// expanding a tree never costs a full recursive walk up front.
    ///
    /// - Parameter url: The directory to list.
    /// - Returns: Immediate children, largest first. Symlinks are omitted.
    static func children(of url: URL) -> [ChildEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey
            ],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents.compactMap { child -> ChildEntry? in
            let values = try? child.resourceValues(forKeys: [
                .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey
            ])
            if values?.isSymbolicLink == true { return nil }
            let isDirectory = values?.isDirectory ?? false
            return ChildEntry(
                id: UUID(),
                url: child,
                size: isDirectory ? ScannerUtils.calculateSize(url: child) : Int64(
                    (try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                ),
                lastModified: values?.contentModificationDate ?? Date(),
                isDirectory: isDirectory
            )
        }
        .sorted { $0.size > $1.size }
    }
}
