import Foundation

/// A manager resolving shell profile scopes by dictating custom sourcing injections.
///
/// Ensures local configuration artifacts exist and properly link against native shell initializers.
///
/// ```swift
/// let manager = ShellConfigManager.shared
/// if !manager.hasManagedBlock(id: "my-block") {
///     try manager.writeManagedBlock(id: "my-block", content: "alias foo='bar'")
/// }
/// ```
final class ShellConfigManager {
    static let shared = ShellConfigManager()
    
    private let fm = FileManager.default
    private let logger = Logger.shared
    
    private var homeDir: URL {
        fm.homeDirectoryForCurrentUser
    }
    
    /// Returns the global shell profile URL mapped to the application instance execution context.
    var zshrcPath: URL {
        homeDir.appendingPathComponent(".zshrc")
    }
    
    /// Returns the application specific configuration extension URL target literal.
    var catalystConfigPath: URL {
        homeDir.appendingPathComponent(".zshrc_catalyst")
    }
    
    private init() {}
    
    /// Verifies that targeted configuration blocks are functionally nested into local profiles.
    ///
    /// - Returns: A boolean describing execution or state resolution outputs representing completion.
    func ensureCatalystSourced() -> Bool {
        if !fm.fileExists(atPath: catalystConfigPath.path) {
            do {
                try "".write(to: catalystConfigPath, atomically: true, encoding: .utf8)
            } catch {
                logger.log("❌ Failed to create Catalyst config: \(error.localizedDescription)")
                return false
            }
        }
        
        if !fm.fileExists(atPath: zshrcPath.path) {
            do {
                try "".write(to: zshrcPath, atomically: true, encoding: .utf8)
            } catch {
                logger.log("❌ Failed to create main shell config: \(error.localizedDescription)")
                return false
            }
        }
        
        do {
            var content = try String(contentsOf: zshrcPath, encoding: .utf8)
            let sourceLine = "[[ -f ~/.zshrc_catalyst ]] && source ~/.zshrc_catalyst"
            
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix(sourceLine) {
                return true
            }
            
            var lines = content.components(separatedBy: .newlines)
            lines.removeAll { $0.contains(".zshrc_catalyst") }
            
            content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            
            let newContent = content + "\n\n" + sourceLine + "\n"
            
            try newContent.write(to: zshrcPath, atomically: true, encoding: .utf8)
            logger.log("✅ Moved Catalyst source command to the bottom of main shell config")
            return true
            
        } catch {
            logger.log("❌ Failed to update main shell config: \(error.localizedDescription)")
            return false
        }
    }
    
    /// Acquires serialized static mappings encapsulated directly inside the localized configuration.
    ///
    /// - Returns: The extracted script structure, or `nil` on missing objects.
    func readCatalystConfig() -> String? {
        try? String(contentsOf: catalystConfigPath, encoding: .utf8)
    }
    
    /// Ingests primary system configuration scopes identifying core user settings and initializations.
    ///
    /// - Returns: A string object representing terminal configurations.
    func readMainConfig() -> String? {
        try? String(contentsOf: zshrcPath, encoding: .utf8)
    }
    
    /// Extends raw configuration string lines by terminating into existing application configurations.
    ///
    /// - Parameter content: The script block bound for deployment scope execution.
    /// - Throws: Any error corresponding to missing resources or lacking file handle assignments.
    func appendToCatalystConfig(_ content: String) throws {
         _ = ensureCatalystSourced()
        
        let handle = try FileHandle(forWritingTo: catalystConfigPath)
        defer { try? handle.close() }
        
        handle.seekToEndOfFile()
        if let data = content.data(using: .utf8) {
            handle.write(data)
        }
    }
    
    /// Injects replacement content entirely overriding structural legacy profile fragments natively.
    ///
    /// - Parameter content: An isolated string context meant to entirely encapsulate execution models.
    /// - Throws: Standard errors stemming from file permission or unavailable states.
    func writeCatalystConfig(_ content: String) throws {
        try content.write(to: catalystConfigPath, atomically: true, encoding: .utf8)
    }
    
    /// Triggers replication of active configurations generating restorable persistent historical clones.
    func backupCatalystConfig() {
        let backupURL = homeDir.appendingPathComponent(".zshrc_catalyst.backup")
        try? fm.removeItem(at: backupURL)
        try? fm.copyItem(at: catalystConfigPath, to: backupURL)
    }

    // MARK: - Managed Blocks
    ///
    /// A single, unambiguous convention for Catalyst-owned regions in
    /// `.zshrc_catalyst`, replacing the per-feature brace-counting (SmartShortcuts)
    /// and exact-format comment parsing (Aliases). Each block is delimited by:
    ///   # CATALYST_BEGIN <id>
    ///   ...content...
    ///   # CATALYST_END <id>
    ///
    /// **Rationale:** Guaranteeing deterministic extraction boundaries prevents Catalyst from ever accidentally truncating or destroying native user aliases in their `~/.zshrc`.

    /// `id` should be a stable, collision-free key (e.g. "alias-gp", "shortcut-django").
    ///
    /// **Gotchas:** Mutating IDs across versions inherently orphans old shell blocks, permanently polluting the user's rc file.

    /// - Parameter id: The designated section identifier mapping the block.
    /// - Returns: The exact bounding declaration prefix.
    private func beginMarker(_ id: String) -> String { "# CATALYST_BEGIN \(id)" }
    /// Computes the closing sentinel block required to track managed ZSH script configurations.
    /// - Parameter id: The designated section identifier mapping the block.
    /// - Returns: The exact bounding declaration suffix.
    private func endMarker(_ id: String) -> String { "# CATALYST_END \(id)" }

    /// Whether a managed block with the given id currently exists.
    ///
    /// - Parameter id: The predefined constant identifier (e.g. "alias-gp").
    /// - Returns: A binary boolean describing block discovery status.
    func hasManagedBlock(id: String) -> Bool {
        guard let content = readCatalystConfig() else { return false }
        return content.components(separatedBy: .newlines).contains(beginMarker(id))
    }

    /// Returns the inner content of a managed block, or `nil` if absent.
    ///
    /// - Parameter id: The exact identifying script constraint literal.
    /// - Returns: Reconstructed lines natively embedded without boundary metadata.
    func readManagedBlock(id: String) -> String? {
        guard let content = readCatalystConfig() else { return nil }
        let lines = content.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: beginMarker(id)),
              let end = lines.firstIndex(of: endMarker(id)),
              start < end else { return nil }
        return lines[(start + 1)..<end].joined(separator: "\n")
    }

    /// Removes a managed block by id. Returns true if a block was found and removed.
    ///
    /// - Parameter id: The precise target text chunk ID boundary string.
    /// - Returns: Flag capturing valid detection / excision cycles successfully running.
    @discardableResult
    func removeManagedBlock(id: String) -> Bool {
        guard let content = readCatalystConfig() else { return false }
        var lines = content.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(of: beginMarker(id)),
              let end = lines.firstIndex(of: endMarker(id)),
              start <= end else { return false }
        lines.removeSubrange(start...end)
        /// Collapse a possible double blank line left behind.
        ///
        /// **Rationale:** Maintains a pristine, visually readable shell configuration file when Catalyst features are dynamically toggled off.
        let newContent = lines.joined(separator: "\n")
        try? writeCatalystConfig(newContent)
        return true
    }

    /// Writes (or idempotently replaces) a sentinel-delimited managed block.
    ///
    /// - Parameters:
    ///   - id: Stable identifier for the block.
    ///   - content: The shell lines to place between the sentinels.
    /// - Throws: Missing configuration file bounds resulting in IO exceptions.
    func writeManagedBlock(id: String, content: String) throws {
        _ = ensureCatalystSourced()
        /// Replace any existing block with the same id (idempotent install).
        ///
        /// **Rationale:** Ensures Catalyst can safely re-inject updated bash/zsh functions across multiple app launches without duplicating source material.
        removeManagedBlock(id: id)

        var config = readCatalystConfig() ?? ""
        if !config.isEmpty && !config.hasSuffix("\n") { config += "\n" }

        let body = content.hasSuffix("\n") ? content : content + "\n"
        let block = "\n" + beginMarker(id) + "\n" + body + endMarker(id) + "\n"
        config += block
        try writeCatalystConfig(config)
    }
}
