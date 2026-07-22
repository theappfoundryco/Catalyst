import Foundation

/// A single entry in the `$PATH` list, with health flags.
struct PathEntry: Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String
    /// The directory exists on disk.
    let exists: Bool
    /// A directory (not a file) — PATH entries should be directories.
    let isDirectory: Bool
    /// An earlier entry already pointed at the same resolved path.
    let isDuplicate: Bool

    /// Dead = missing or not a directory. Safe to drop.
    var isDead: Bool { !exists || !isDirectory }

    init(id: UUID = UUID(), path: String, exists: Bool, isDirectory: Bool, isDuplicate: Bool) {
        self.id = id
        self.path = path
        self.exists = exists
        self.isDirectory = isDirectory
        self.isDuplicate = isDuplicate
    }
}

/// Aggregated environment trace capturing current configuration and metadata constraints.
struct PathReport: Sendable {
    let entries: [PathEntry]
    var duplicateCount: Int { entries.filter { $0.isDuplicate }.count }
    var deadCount: Int { entries.filter { $0.isDead }.count }
}

/// Reads and analyzes the user's effective `$PATH`. Reading uses a login shell
/// so it reflects what the user's terminals actually see; analysis is pure
/// FileManager. Persistence (writing a curated PATH) is handled by the VM via
/// `ShellConfigManager`, keeping shell-config mutation on the main actor.
///
/// ```swift
/// let report = await PathEditorService.shared.scan()
/// print("Found \(report.entries.count) PATH entries")
/// ```
final class PathEditorService: Sendable {

    static let shared = PathEditorService()
    private init() {}

    private let runner = AsyncProcessRunner.shared

    /// The block id used for the Catalyst-managed PATH override.
    static let managedBlockID = "path-order"

    /// Orchestrates a high-level scan mapping the default `$PATH` out of a login shell.
    ///
    /// - Returns: A fully constructed ``PathReport`` categorizing all path chunks.
    func scan() async -> PathReport {
        PathReport(entries: analyze(await readPath()))
    }

    /// Reads the effective `$PATH` from a login shell, split into entries.
    ///
    /// **Gotchas:**
    /// It's critical this specifies `useLoginShell: true` in the process runner; otherwise `printf` pulls from an incomplete non-interactive environment profile.
    ///
    /// - Returns: An array of unverified path string fragments.
    func readPath() async -> [String] {
        do {
            let r = try await runner.run(command: "printf '%s' \"$PATH\"", useLoginShell: true)
            let raw = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    /// Flags each entry: existence, directory-ness, and duplicates (by resolved path).
    ///
    /// - Parameter paths: The sequence of unvalidated string paths.
    /// - Returns: A mapped array of comprehensive ``PathEntry`` entities.
    func analyze(_ paths: [String]) -> [PathEntry] {
        var seen = Set<String>()
        return paths.map { p in
            let normalized = (p as NSString).standardizingPath
            let isDuplicate = seen.contains(normalized)
            seen.insert(normalized)

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
            return PathEntry(path: p, exists: exists, isDirectory: isDir.boolValue, isDuplicate: isDuplicate)
        }
    }
}
