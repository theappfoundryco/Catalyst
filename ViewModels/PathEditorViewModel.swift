import Foundation
import SwiftUI
import AppKit
import Combine

@MainActor
final class PathEditorViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case scanning
        case ready
    }

    @Published var state: State = .idle
    /// The original, on-disk PATH order (for "dirty" comparison and reset).
    @Published var original: [PathEntry] = []
    /// The user's working copy (reorderable / removable).
    @Published var working: [PathEntry] = []
    @Published var hasOverride: Bool = false
    @Published var statusMessage: String?

    private let service = PathEditorService.shared
    private let shell = ShellConfigManager.shared
    private let logger = Logger.shared

    var duplicateCount: Int { working.filter { $0.isDuplicate }.count }
    var deadCount: Int { working.filter { $0.isDead }.count }

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

    /// Parse the PATH list Catalyst previously saved to its managed block.
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

    func moveUp(_ entry: PathEntry) {
        guard let i = working.firstIndex(of: entry), i > 0 else { return }
        working.swapAt(i, i - 1)
        reanalyze()
        persist()
    }

    func moveDown(_ entry: PathEntry) {
        guard let i = working.firstIndex(of: entry), i < working.count - 1 else { return }
        working.swapAt(i, i + 1)
        reanalyze()
        persist()
    }

    func remove(_ entry: PathEntry) {
        working.removeAll { $0.id == entry.id }
        reanalyze()
        persist()
    }

    /// Drop dead dirs and later duplicates, preserving first-seen order.
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

    /// Recompute duplicate flags after reordering/removal (paths/order changed).
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

    /// Saves the current order to Catalyst's managed block. Auto-called after
    /// every edit, so there's no separate "apply" step and nothing to lose.
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

    /// Removes Catalyst's PATH override, restoring the system default ordering.
    func removeOverride() {
        shell.removeManagedBlock(id: PathEditorService.managedBlockID)
        hasOverride = false
        statusMessage = "Removed Catalyst's PATH override. Open a new terminal to refresh."
        logger.log("🛤️ Removed PATH override")
        Task { await scan() }
    }

    func reveal(_ entry: PathEntry) {
        guard entry.exists else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }
}
