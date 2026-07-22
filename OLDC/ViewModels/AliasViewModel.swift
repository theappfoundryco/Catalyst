import Foundation
import SwiftUI
import Combine

@MainActor
final class AliasViewModel: ObservableObject {
    // Recompute derived lists when their inputs change, not on every render (R3).
    @Published var aliases: [AliasItem] = [] { didSet { recomputeDerived() } }
    @Published var isLoading = false
    @Published var newAliasName = ""
    @Published var newAliasCommand = ""
    @Published var searchQuery = "" { didSet { recomputeFiltered() } }
    @Published var outputMessage = ""
    @Published var showingError = false
    @Published var errorMessage = ""

    @Published private(set) var filteredAliases: [AliasItem] = []
    @Published private(set) var catalystAliases: [AliasItem] = []
    @Published private(set) var otherAliases: [AliasItem] = []

    private let logger: Logger
    private let configManager = ShellConfigManager.shared

    init(logger: Logger) {
        self.logger = logger
    }

    private func recomputeDerived() {
        catalystAliases = aliases.filter { $0.isCatalystManaged }
        otherAliases = aliases.filter { !$0.isCatalystManaged }
        recomputeFiltered()
    }

    private func recomputeFiltered() {
        if searchQuery.isEmpty {
            filteredAliases = aliases.sorted { $0.name < $1.name }
        } else {
            filteredAliases = aliases.filter { alias in
                alias.name.localizedCaseInsensitiveContains(searchQuery) ||
                alias.command.localizedCaseInsensitiveContains(searchQuery)
            }.sorted { $0.name < $1.name }
        }
    }

    // MARK: - Load Aliases
    
    func loadAliases() async {
        isLoading = true
        logger.log("📂 Loading aliases...")
        
        var loadedAliases: [AliasItem] = []
        
        // 1. Load System Aliases from .zshrc
        if let mainContent = configManager.readMainConfig() {
            let systemAliases = parseAliases(from: mainContent, isManagedFile: false)
            loadedAliases.append(contentsOf: systemAliases)
        }
        
        // 2. Load Catalyst Aliases from .zshrc_catalyst
        if let catalystContent = configManager.readCatalystConfig() {
            let managedAliases = parseAliases(from: catalystContent, isManagedFile: true)
            loadedAliases.append(contentsOf: managedAliases)
        }
        
        // Deduplicate: If an alias exists in both, prefer the managed one (or just show both?)
        // For now, simpler to just list them. users might shadow system aliases.
        aliases = loadedAliases
        
        logger.log("✅ Loaded \(aliases.count) aliases total")
        isLoading = false
    }
    
    private func parseAliases(from content: String, isManagedFile: Bool) -> [AliasItem] {
        let lines = content.components(separatedBy: .newlines)
        var foundAliases: [AliasItem] = []
        var isCatalystBlock = false
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Check for CATALYST marker
            if trimmed.hasPrefix("# CATALYST_ALIAS:") {
                isCatalystBlock = true
                continue
            }
            
            // Parse alias line
            if trimmed.hasPrefix("alias ") {
                if let alias = parseAliasLine(trimmed) {
                    foundAliases.append(AliasItem(
                        name: alias.name,
                        command: alias.command,
                        // If it's in the managed file, it's managed. OR if it has the marker comments.
                        isCatalystManaged: isManagedFile || isCatalystBlock
                    ))
                }
                isCatalystBlock = false // Reset for next alias
            }
        }
        
        return foundAliases
    }
    
    private func parseAliasLine(_ line: String) -> (name: String, command: String)? {
        // Parse: alias name='command' | alias name="command" | alias name=command
        // Tighter than split-on-first-`=`+strip-one-quote-pair: it stops at the
        // closing quote (so a trailing inline comment like `alias x='y' # note`
        // doesn't leak into the command) and handles unquoted values.
        let aliasPrefix = "alias "
        guard line.hasPrefix(aliasPrefix) else { return nil }

        let remainder = Substring(line.dropFirst(aliasPrefix.count))
        guard let eq = remainder.firstIndex(of: "=") else { return nil }

        let name = remainder[..<eq].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let rest = remainder[remainder.index(after: eq)...]

        let command: String
        if let first = rest.first, first == "'" || first == "\"" {
            // Quoted: take everything up to the matching closing quote.
            let body = rest.dropFirst()
            if let close = body.firstIndex(of: first) {
                command = String(body[..<close])
            } else {
                command = String(body) // unterminated quote — take the rest
            }
        } else {
            // Unquoted: up to the first whitespace (drops any trailing comment).
            command = String(rest.prefix(while: { !$0.isWhitespace }))
        }

        return (name, command)
    }
    
    // MARK: - Add Alias
    
    func addAlias() async {
        let name = newAliasName.trimmingCharacters(in: .whitespaces)
        let command = newAliasCommand.trimmingCharacters(in: .whitespaces)
        
        // Validate
        guard !name.isEmpty else {
            showError("Alias name cannot be empty")
            return
        }
        
        guard !command.isEmpty else {
            showError("Command cannot be empty")
            return
        }
        
        guard AliasValidator.isValidAliasName(name) else {
            showError("Invalid alias name. Use only letters, numbers, underscores, and dashes. Must start with a letter.")
            return
        }
        
        // Check for duplicates
        if aliases.contains(where: { $0.name == name }) {
            showError("Alias '\(name)' already exists")
            return
        }
        
        logger.log("➕ Adding alias: \(name) = \(command)")
        outputMessage = "Adding alias '\(name)'...\n"
        
        // Store the command in single quotes. This preserves `$VAR`, backticks,
        // and `$1` literally in the alias body so they expand at *use* time — the
        // old double-quote + `\$`/`\``-escaping mangled exactly those and broke
        // legitimate aliases like `git push $1`. `singleQuote` escapes any embedded
        // single quote correctly.
        let quotedCommand = InputSanitizer.singleQuote(command)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let aliasBody = """
        # CATALYST_ADDED: \(timestamp)
        alias \(name)=\(quotedCommand)
        """

        do {
            // Stored as a sentinel-delimited managed block (id: alias-<name>).
            try configManager.writeManagedBlock(id: "alias-\(name)", content: aliasBody)

            outputMessage += "✅ Alias added to .zshrc_catalyst\n"
            outputMessage += "💡 Close and reopen Terminal to use '\(name)'\n"
            
            // Reload aliases
            await loadAliases()
            
            // Clear inputs
            newAliasName = ""
            newAliasCommand = ""
            
            logger.log("✅ Alias added successfully")
        } catch {
            outputMessage += "❌ Failed: \(error.localizedDescription)\n"
            logger.log("❌ Failed to add alias: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Delete Alias
    
    func deleteAlias(_ alias: AliasItem) async {
        guard alias.isCatalystManaged else {
            showError("Cannot delete system aliases. Only Catalyst-managed aliases can be removed.")
            return
        }
        
        logger.log("🗑️ Deleting alias: \(alias.name)")
        outputMessage = "Deleting alias '\(alias.name)'...\n"

        // Preferred path: remove the sentinel-delimited managed block.
        if configManager.removeManagedBlock(id: "alias-\(alias.name)") {
            outputMessage += "✅ Alias removed from configuration\n"
            outputMessage += "💡 Close and reopen Terminal to apply changes\n"
            await loadAliases()
            logger.log("✅ Alias deleted successfully")
            return
        }

        // Fallback for aliases written by older versions (pre-ManagedBlock):
        // strip the legacy `# CATALYST_ALIAS:` comment block + the alias line.
        guard let content = configManager.readCatalystConfig() else {
            showError("Could not read configuration")
            return
        }

        let lines = content.components(separatedBy: .newlines)
        var newLines: [String] = []
        var inTargetBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("# CATALYST_ALIAS: \(alias.name)") {
                inTargetBlock = true
                continue
            }

            if inTargetBlock {
                if trimmed.hasPrefix("alias \(alias.name)=") {
                    inTargetBlock = false
                    continue
                }
                if trimmed.hasPrefix("# CATALYST_") {
                    continue
                }
            } else {
                newLines.append(line)
            }
        }

        let newContent = newLines.joined(separator: "\n")

        do {
            try configManager.writeCatalystConfig(newContent)

            outputMessage += "✅ Alias removed from configuration\n"
            outputMessage += "💡 Close and reopen Terminal to apply changes\n"

            await loadAliases()
            logger.log("✅ Alias deleted successfully")
        } catch {
            outputMessage += "❌ Failed: \(error.localizedDescription)\n"
            logger.log("❌ Failed to delete alias: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Helper Functions

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
        logger.log("❌ \(message)")
    }
    
    func clearOutput() {
        outputMessage = ""
    }
}
