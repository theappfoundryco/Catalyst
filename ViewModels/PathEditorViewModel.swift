import Foundation
import SwiftUI
import AppKit
import Combine

/// A view model governing the `PATH` environment variable editor.
///
/// It coordinates reading the user's current shell `PATH`, detecting broken or duplicate
/// entries, and saving a curated override back to the shell configuration file (e.g. `~/.zshrc`)
/// via Catalyst's managed block system.
///
/// **Caveats:**
/// - Edits made here *override* the system defaults for new terminal sessions.
/// - The `original` and `working` arrays must be kept in sync; `original` serves as the diff baseline.
///
/// ```swift
/// @StateObject var vm = PathEditorViewModel()
/// await vm.scan()
/// vm.clean()
/// ```
@MainActor
final class PathEditorViewModel: ObservableObject {
    /// The lifecycle state of the path editor scan.
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    /// Current scanning state.
    @Published var state: State = .idle
    /// The original, on-disk PATH order (for "dirty" comparison and reset).
    @Published var original: [PathEntry] = []
    /// The user's working copy (reorderable / removable).
    @Published var working: [PathEntry] = []
    /// Indicates whether a Catalyst-managed PATH override currently exists in the shell config.
    @Published var hasOverride: Bool = false
    /// Ephemeral status messaging shown in the UI after save/delete operations.
    @Published var statusMessage: String?

    private let service = PathEditorService.shared
    private let shell = ShellConfigManager.shared
    private let logger = Logger.shared

    /// The count of duplicated PATH entries currently in the working set.
    var duplicateCount: Int { working.filter { $0.isDuplicate }.count }
    /// The count of dead (non-existent/unresolvable) PATH entries currently in the working set.
    var deadCount: Int { working.filter { $0.isDead }.count }

    /// Scans the environment for `PATH` entries and detects existing overrides.
    ///
    /// **Flow:**
    /// 1. Checks ``ShellConfigManager`` for an existing managed block block (`Catalyst_PathEditor`).
    /// 2. If present, it parses the *saved* path sequence so edits you previously made don't reset.
    /// 3. If absent, it queries the live environment (`$PATH`).
    /// 4. Loads both into `original` and `working` arrays.
    func scan() async {
        if original.isEmpty { state = .scanning }
        hasOverride = shell.hasManagedBlock(id: PathEditorService.managedBlockID)

        // If Catalyst has already saved a curated order, show THAT — not the live
        // session env — so edits you saved never "come back" on a re-scan.
        if hasOverride, let saved = savedPathEntries() {
            original = saved
            working = saved
        } else {
            let report = await service.scan()
            original = report.entries
            working = report.entries
        }
        state = .ready
        logger.log("🛤️ PATH scan: \(working.count) entries, \(duplicateCount) dupes, \(deadCount) dead (override: \(hasOverride))")
    }

    /// Parse the `PATH` list Catalyst previously saved to its managed block.
    ///
    /// - Returns: A decoded array of ``PathEntry`` objects if parsing succeeds, otherwise `nil`.
    private func savedPathEntries() -> [PathEntry]? {
        guard let content = shell.readManagedBlock(id: PathEditorService.managedBlockID),
              let start = content.firstIndex(of: "\""),
              let end = content.lastIndex(of: "\""), start < end else { return nil }
        let inner = String(content[content.index(after: start)..<end])
        let paths = inner.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        guard !paths.isEmpty else { return nil }
        return service.analyze(paths)
    }

    // MARK: - Editing (working copy)

    /// Shifts a path entry one position higher in the priority list.
    /// Auto-saves the result immediately.
    ///
    /// - Parameter entry: The ``PathEntry`` to bump.
    func moveUp(_ entry: PathEntry) {
        guard let i = working.firstIndex(of: entry), i > 0 else { return }
        working.swapAt(i, i - 1)
        reanalyze()
        persist()
    }

    /// Shifts a path entry one position lower in the priority list.
    /// Auto-saves the result immediately.
    ///
    /// - Parameter entry: The ``PathEntry`` to demote.
    func moveDown(_ entry: PathEntry) {
        guard let i = working.firstIndex(of: entry), i < working.count - 1 else { return }
        working.swapAt(i, i + 1)
        reanalyze()
        persist()
    }

    /// Deletes a path entry from the working set and auto-saves the result.
    ///
    /// - Parameter entry: The ``PathEntry`` to remove.
    func remove(_ entry: PathEntry) {
        working.removeAll { $0.id == entry.id }
        reanalyze()
        persist()
    }

    /// Sweeps the working list to drop dead directories and later duplicates.
    ///
    /// **Rationale:**
    /// Preserves the *first-seen* order (which is how the shell prioritizes resolution).
    /// Saves automatically after mutation.
    func clean() {
        var seen = Set<String>()
        working = working.filter { entry in
            let normalized = (entry.path as NSString).standardizingPath
            if entry.isDead { return false }
            if seen.contains(normalized) { return false }
            seen.insert(normalized)
            return true
        }
        reanalyze()
        persist()
    }

    /// Recomputes duplicate flags after reordering or removal.
    ///
    /// **Gotchas:**
    /// Maps over the newly minted array and forcefully copies the `.id` from the old state
    /// over to the new items. This ensures SwiftUI's `ForEach` list animations don't break during swaps.
    private func reanalyze() {
        let paths = working.map(\.path)
        let fresh = service.analyze(paths)
        // Preserve stable ids where possible for smooth list animations.
        working = zip(working, fresh).map { old, new in
            PathEntry(id: old.id, path: new.path, exists: new.exists,
                      isDirectory: new.isDirectory, isDuplicate: new.isDuplicate)
        }
    }

    // MARK: - Persistence

    /// Saves the current order to Catalyst's managed block.
    ///
    /// **Rationale:**
    /// Automatically called after every edit (`clean()`, `remove()`, `moveUp()`). There is no separate "Apply"
    /// button, minimizing the risk of lost work. Updates ``original`` to match ``working`` on success.
    private func persist() {
        let joined = working.map(\.path).joined(separator: ":")
        let line = "export PATH=\"\(joined)\""
        do {
            try shell.writeManagedBlock(id: PathEditorService.managedBlockID, content: line)
            hasOverride = true
            original = working
            statusMessage = "Saved — new terminal windows will use this order."
            logger.log("🛤️ Saved curated PATH (\(working.count) entries)")
        } catch {
            statusMessage = "Couldn't save: \(error.localizedDescription)"
            logger.log("❌ Failed to save PATH: \(error.localizedDescription)")
        }
    }

    /// Removes Catalyst's `PATH` override from `~/.zshrc` (or equivalent), restoring the system default.
    func removeOverride() {
        shell.removeManagedBlock(id: PathEditorService.managedBlockID)
        hasOverride = false
        statusMessage = "Removed Catalyst's PATH override. Open a new terminal to refresh."
        logger.log("🛤️ Removed PATH override")
        Task { await scan() }
    }

    /// Opens the specified valid directory in the macOS Finder.
    ///
    /// - Parameter entry: The path configuration to reveal.
    func reveal(_ entry: PathEntry) {
        guard entry.exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }
}
