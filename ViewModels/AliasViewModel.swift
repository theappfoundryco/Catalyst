import Foundation
import SwiftUI
import Combine

/// A view model responsible for managing user-defined and Catalyst-managed shell aliases.
///
/// `AliasViewModel` parses both the primary `.zshrc` (for system aliases) and `.zshrc_catalyst`
/// (for managed aliases). It strictly enforces that only Catalyst-managed aliases can be deleted
/// via the UI to prevent destructive modifications to the user's personal shell configuration.
///
/// **Caveats:**
/// - Aliases are loaded by manual parsing rather than shell evaluation, meaning complex multi-line
///   functions or highly dynamic aliases might not parse identically to Zsh's internal parser.
///
/// ```swift
/// @StateObject private var aliasVM = AliasViewModel(logger: .shared)
/// // ...
/// await aliasVM.loadAliases()
/// ```
@MainActor
final class AliasViewModel: ObservableObject {
    // Recompute derived lists when their inputs change, not on every render (R3).
    /// The aggregate list of all detected aliases (system + managed).
    @Published var aliases: [AliasItem] = [] { didSet { recomputeDerived() } }
    /// Indicates if aliases are currently being read from disk.
    @Published var isLoading = false
    /// The proposed name for a new alias being created.
    @Published var newAliasName = ""
    /// The proposed shell command for a new alias being created.
    @Published var newAliasCommand = ""
    /// The current search query used to filter the displayed aliases.
    @Published var searchQuery = "" { didSet { recomputeFiltered() } }
    /// Status output detailing the result of an alias addition or deletion.
    @Published var outputMessage = ""
    /// Flag indicating whether an error alert should be presented.
    @Published var showingError = false
    /// The message to display inside the error alert.
    @Published var errorMessage = ""

    /// Aliases matching the current `searchQuery`, alphabetically sorted.
    @Published private(set) var filteredAliases: [AliasItem] = []
    /// A derived list of aliases specifically managed by Catalyst.
    @Published private(set) var catalystAliases: [AliasItem] = []
    /// A derived list of standard user aliases from the primary config.
    @Published private(set) var otherAliases: [AliasItem] = []

    private let logger: Logger
    private let configManager = ShellConfigManager.shared

    /// Initializes the ``AliasViewModel`` with injected dependencies.
    ///
    /// - Parameter logger: The shared ``Logger`` instance for terminal output.
    init(logger: Logger) {
        self.logger = logger
    }

    /// Segregates the raw ``aliases`` list into managed and unmanaged (system) buckets.
    ///
    /// **Rationale:**
    /// This is isolated from the `loadAliases()` fetch so that adding/deleting instantly triggers a sort and filter
    /// without re-parsing the file system. 
    private func recomputeDerived() {
        catalystAliases = aliases.filter { $0.isCatalystManaged }
        otherAliases = aliases.filter { !$0.isCatalystManaged }
        recomputeFiltered()
    }

    /// Applies the current ``searchQuery`` to the full alias list and alphabetically sorts the remainder.
    ///
    /// **Gotchas:**
    /// - Both the alias `name` and the alias `command` body are evaluated in the case-insensitive search.
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
    
    /// Reads and parses both system and Catalyst-managed aliases from the filesystem.
    ///
    /// **Flow:**
    /// 1. Reads the primary config (`~/.zshrc`) via ``ShellConfigManager``.
    /// 2. Reads the secondary managed config (`~/.zshrc_catalyst`).
    /// 3. Joins the sets without overriding shadows, presenting both to the user.
    ///
    /// **Gotchas:**
    /// - This method performs duplicate conflict resolution visually but does not actively delete
    ///   shadowed aliases. Managed aliases are determined by their file origin or sentinel comment block.
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
    
    /// Line-by-line parser for extracting shell aliases from raw text.
    ///
    /// **Caveats:**
    /// - It relies on `# CATALYST_ALIAS:` markers for legacy tracking and uses the `isManagedFile` boolean to blanket-mark
    ///   files like `.zshrc_catalyst`.
    ///
    /// - Parameters:
    ///   - content: The raw multiline string read from disk.
    ///   - isManagedFile: If true, every alias discovered in this payload is flagged as `isCatalystManaged`.
    /// - Returns: An array of ``AliasItem`` instances mapped from the file.
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
    
    /// Strictly evaluates a single text line to identify and extract an `alias name=command` pair.
    ///
    /// **Rationale:**
    /// Tighter than a naive split-on-first-`=` followed by stripping one quote pair. It manually evaluates
    /// the closing quote (so a trailing inline comment like `alias x='y' # note` doesn't leak into the body).
    ///
    /// - Parameter line: A single raw string from the config file.
    /// - Returns: A tuple containing the `name` and `command`, or `nil` if the line does not match standard alias syntax.
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
    
    /// Validates and appends a new alias to the `.zshrc_catalyst` file as a managed block.
    ///
    /// **Flow:**
    /// 1. Validates the name against strict character requirements.
    /// 2. Rejects duplicates natively.
    /// 3. Wraps the command in strict single quotes.
    /// 4. Flushes the block to disk via ``ShellConfigManager/writeManagedBlock(id:content:)``.
    ///
    /// - Important: The command is intentionally wrapped in single quotes using ``InputSanitizer/singleQuote``
    ///   to preserve shell variables (`$VAR`, `$1`) and backticks until execution time. The old double-quote approach mangled legitimate aliases.
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
    
    /// Removes a Catalyst-managed alias from `.zshrc_catalyst`.
    ///
    /// **Flow:**
    /// 1. Attempts removal via the modern ``ShellConfigManager/removeManagedBlock(id:)``.
    /// 2. If it fails, falls back to manual string parsing for legacy `# CATALYST_ALIAS:` blocks.
    ///
    /// **Gotchas:**
    /// - This function refuses to delete aliases where `isCatalystManaged` is false to protect user integrity.
    ///
    /// - Parameter alias: The ``AliasItem`` to remove.
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

    /// Sets the UI error bindings and logs to the console simultaneously.
    ///
    /// - Parameter message: The human-readable string to display.
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
        logger.log("❌ \(message)")
    }
    
    /// Clears the success/status output message area immediately.
    func clearOutput() {
        outputMessage = ""
    }
}
