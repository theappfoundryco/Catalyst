import Foundation

/// Install/uninstall engine for SmartShortcuts, extracted out of
/// `SmartShortcutsViewModel` (R1). Stateless: it performs the dependency
/// installs, shell-config writes, and removals, streaming human-readable lines
/// through an `onOutput` callback and returning a plain outcome. The ViewModel
/// keeps its `@Published` state (install flag, console, installed map) and
/// records the result.
///
/// ```swift
/// let installer = ShortcutInstaller(pythonService: pyService, logger: logger)
/// let outcome = await installer.install(detail, shortcutId: "id", customName: "my_func") { line in
///     print(line)
/// }
/// ```
struct ShortcutInstaller {

    /// Represents the result state of an Apple Shortcut installation attempt.
enum InstallOutcome {
        case success(InstalledShortcut)
        case invalidName
        case nameConflict
        case dependencyFailed
        case shellConfigFailed
        case writeFailed(String)
    }

    private let pythonService: PythonService
    private let logger: Logger

    init(pythonService: PythonService, logger: Logger) {
        self.pythonService = pythonService
        self.logger = logger
    }

    // MARK: - Install

    /// - Parameters:
    ///   - detail: The explicit definition block for Apple scripts.
    ///   - shortcutId: The internal programmatic reference for tracking.
    ///   - customName: The optional end-user localization alias.
    ///   - onOutput: The active conduit forwarding execution updates to the view.
    /// - Returns: The validated completion state, encapsulating errors.
    func install(_ detail: ShortcutDetail, shortcutId: String, customName: String, onOutput: @escaping (String) -> Void) async -> InstallOutcome {
        /// Terminal logging header
        ///
        /// **Rationale:** Ensures CLI diagnostic output provides an immediate visual anchor when users pipe Catalyst install logs to a file.
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       ⚡ SMARTSHORTCUT INSTALLATION", category: .terminal)
        logger.log("       Shortcut: \(detail.original_name)", category: .terminal)
        logger.log("       Function: \(customName)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)

        logger.log("📦 Installing shortcut: \(shortcutId) as '\(customName)'")
        onOutput("🔧 Installing \(detail.original_name) as '\(customName)'...\n")

        /// 1. Validate custom name
        ///
        /// **Rationale:** Prevents shell injection by strictly validating the user-provided alias name before generating the `zsh` function block.
        guard isValidFunctionName(customName) else {
            onOutput("❌ Invalid function name. Use only letters, numbers, dashes, underscores.\n")
            return .invalidName
        }

        /// 2. Check for conflicts
        ///
        /// **Gotchas:** Skipping the conflict check allows the installer to silently overwrite native macOS built-ins like `ls` or `cd`, breaking the user's terminal environment.
        if functionExists(customName) {
            onOutput("❌ Function '\(customName)' already exists in shell config\n")
            return .nameConflict
        }

        onOutput("✅ Name validation passed\n")

        /// 3. Install dependencies
        ///
        /// **Rationale:** Asynchronously pre-warms the environment by resolving external dependencies before writing the executable script, ensuring instantaneous first runs.
        if !detail.dependencies.brew.isEmpty || !detail.dependencies.pip.isEmpty {
            onOutput("📦 Installing dependencies...\n")

            /// Homebrew packages
            ///
            /// **Rationale:** Scopes native binary dependencies explicitly to the Homebrew prefix to avoid conflicts with macOS system libraries.
            for pkg in detail.dependencies.brew {
                guard let sanitizedPkg = InputSanitizer.sanitizePackageName(pkg) else {
                    onOutput("  ❌ Invalid package name: \(pkg)\n")
                    return .dependencyFailed
                }

                onOutput("  🍺 Installing \(sanitizedPkg)...\n")
                logger.log("Installing Homebrew package: \(sanitizedPkg)")

                let brewResult = await runShellCommand("\(BrewPathManager.shared.brewPath) install '\(sanitizedPkg)'")

                if brewResult.contains("it's just not linked") || brewResult.contains("just not linked") {
                    onOutput("  🔗 \(sanitizedPkg) installed but not linked, linking now...\n")
                    _ = await runShellCommand("\(BrewPathManager.shared.brewPath) link '\(sanitizedPkg)'")
                    onOutput("  ✅ \(sanitizedPkg) linked\n")
                } else if brewResult.contains("already installed") {
                    onOutput("  ✓ \(sanitizedPkg) already installed\n")
                } else if brewResult.contains("Error") || brewResult.contains("error") {
                    onOutput("  ❌ Failed to install \(sanitizedPkg)\n")
                    return .dependencyFailed
                } else {
                    onOutput("  ✅ \(sanitizedPkg) installed successfully\n")
                }
            }

            /// pip packages
            ///
            /// **Gotchas:** Globally installing Python dependencies via `pip` outside of a virtual environment violates PEP 668 on modern macOS, triggering a fatal `externally-managed-environment` error.
            for pkg in detail.dependencies.pip {
                guard let sanitizedPkg = InputSanitizer.sanitizePackageName(pkg) else {
                    onOutput("  ❌ Invalid package name: \(pkg)\n")
                    return .dependencyFailed
                }

                onOutput("  🐍 Installing \(sanitizedPkg)...\n")

                guard let python = await getPythonWithPip() else {
                    onOutput("  ❌ No Python with pip found\n")
                    return .dependencyFailed
                }

                let flags = InstallPreferences.pipFlags(forPythonVersion: nil)
                let pipResult = await runShellCommand("\(InputSanitizer.singleQuote(python)) -m pip install \(InputSanitizer.singleQuote(sanitizedPkg)) \(flags)")

                if pipResult.contains("already satisfied") || pipResult.contains("Successfully installed") {
                    onOutput("  ✅ \(sanitizedPkg) installed successfully\n")
                } else if pipResult.contains("error") || pipResult.contains("ERROR") {
                    onOutput("  ❌ Failed to install \(sanitizedPkg)\n")
                    return .dependencyFailed
                } else {
                    onOutput("  ✅ \(sanitizedPkg) installed\n")
                }
            }

            onOutput("✅ All dependencies installed\n\n")
        }

        /// 4. Ensure catalyst file is sourced
        ///
        /// **Gotchas:** If the `source ~/.zshrc_catalyst` line is missing, the newly installed shortcut function will silently fail to load into new shell sessions.
        onOutput("⚙️ Configuring shell environment...\n")
        if ensureCatalystSourced() == false {
            onOutput("❌ Failed to configure shell environment\n")
            return .shellConfigFailed
        }

        /// 5. Append function to .zshrc_catalyst (sentinel-delimited managed block)
        ///
        /// **Rationale:** Anchoring the block with a unique UUID sentinel ensures Catalyst can deterministically find and overwrite its own shortcuts later without parsing arbitrary Bash syntax.
        onOutput("✍️ Writing to shell configuration...\n")

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let functionBody = """
        # CATALYST_VERSION: \(detail.version)
        # CATALYST_INSTALLED: \(timestamp)
        # CATALYST_NAME: \(customName)
        \(replaceFirstOccurrence(in: detail.shell_code, of: detail.original_name, with: customName))
        """

        do {
            try ShellConfigManager.shared.writeManagedBlock(id: "shortcut-\(shortcutId)", content: functionBody)
            onOutput("✅ Function written to configuration\n")
        } catch {
            onOutput("❌ Failed to write: \(error.localizedDescription)\n")
            return .writeFailed(error.localizedDescription)
        }

        /// 6. Note about sourcing
        ///
        /// **Gotchas:** Terminal sessions must execute `source ~/.zshrc` explicitly; relying on the UI to communicate this prevents users from filing "command not found" bug reports.
        onOutput("💡 Note: Close and reopen your terminal to use the new function\n")

        let installed = InstalledShortcut(
            id: shortcutId,
            custom_name: customName,
            installed_at: timestamp,
            version: detail.version
        )

        onOutput("✅ Installation complete!\n")
        onOutput("💡 Function '\(customName)' is now available in your terminal\n")
        logger.log("✅ Shortcut installed: \(customName)")

        return .success(installed)
    }

    // MARK: - Uninstall

    /// Remove a shortcut's shell-config block. Returns `true` if the caller
    /// should proceed to drop the shortcut from persistence; `false` only when a
    /// legacy config rewrite fails (matching prior early-return behavior).
    ///
    /// - Parameters:
    ///   - shortcutId: The explicit canonical shortcut ID defining a block.
    ///   - onOutput: Streaming hook relaying log context sequentially back to caller VMs.
    /// - Returns: State evaluating script removal pipeline blockages.
    func uninstall(shortcutId: String, onOutput: (String) -> Void) -> Bool {
        onOutput("🗑️ Uninstalling shortcut...\n")

        /// Preferred path: remove the sentinel-delimited managed block.
        ///
        /// **Rationale:** Directly wiping the contiguous block bounded by the UUID sentinel guarantees complete removal of the function and its metadata without collateral damage.
        if ShellConfigManager.shared.removeManagedBlock(id: "shortcut-\(shortcutId)") {
            onOutput("✅ Removed from configuration\n")
        } else if let content = ShellConfigManager.shared.readCatalystConfig() {
            /// Fallback for shortcuts installed by older versions: brace-count from
            /// the legacy `# CATALYST_ID:` marker to the closing brace.
            ///
            /// **Gotchas:** Legacy shortcuts lack closing sentinels; failing to execute a syntax-aware brace count causes greedy deletions that erase adjacent user functions.
            let lines = content.components(separatedBy: .newlines)
            var newLines: [String] = []
            var inCatalystBlock = false
            var foundBlock = false
            var braceCount = 0

            for line in lines {
                if line.contains("# CATALYST_ID: \(shortcutId)") {
                    inCatalystBlock = true
                    foundBlock = true
                    braceCount = 0
                    continue
                }

                if inCatalystBlock {
                    braceCount += line.components(separatedBy: "{").count - 1
                    braceCount -= line.components(separatedBy: "}").count - 1

                    if braceCount <= 0 && line.contains("}") {
                        inCatalystBlock = false
                        continue
                    }
                    continue
                }

                newLines.append(line)
            }

            if !foundBlock {
                onOutput("⚠️ Function not found in configuration\n")
            } else {
                do {
                    try ShellConfigManager.shared.writeCatalystConfig(newLines.joined(separator: "\n"))
                    onOutput("✅ Removed from configuration\n")
                } catch {
                    onOutput("❌ Failed to update configuration: \(error.localizedDescription)\n")
                    return false
                }
            }
        } else {
            onOutput("⚠️ Function not found in configuration\n")
        }

        return true
    }

    // MARK: - Private helpers

    /// - Parameter name: The intended shortcut function.
    /// - Returns: True if matching POSIX standards for shell definitions.
    private func isValidFunctionName(_ name: String) -> Bool {
        let pattern = "^[a-zA-Z0-9_-]+$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Checks if a shell function is already declared within a sourced profile.
    /// - Parameter name: The programmatic alias target.
    /// - Returns: True if the current `zshrc` explicitly scopes the name.
    private func functionExists(_ name: String) -> Bool {
        guard let content = ShellConfigManager.shared.readCatalystConfig() else {
            return false
        }
        /// Parse actual function declarations (anchored at line start) rather than
        /// substring-matching, so name "ls" doesn't match inside "tools()".
        ///
        /// **Gotchas:** A naive regex `.*ls.*` blindly renames any function containing the letters "ls", breaking totally unrelated shell utilities.
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            ///  name() { … }   |   name () { … }
            ///  function name [()] { … }
            ///
            /// **Rationale:** Zsh allows multiple syntactic forms for function declarations; exhaustive regex matching handles both POSIX and bash-style syntax natively.
            if line.hasPrefix("\(name)(") || line.hasPrefix("\(name) (") { return true }
            ///  function name [()] { … }
            if line.hasPrefix("function \(name)") {
                let rest = line.dropFirst("function \(name)".count)
                if rest.isEmpty { return true }
                if let c = rest.first, c == " " || c == "(" || c == "{" { return true }
            }
        }
        return false
    }

    /// Swaps only the first matched substring to preserve duplicate adjacent commands.
    /// - Parameters:
    ///   - string: The foundational text block to mutate.
    ///   - target: The precise literal match target.
    ///   - replacement: The payload mapped to the substituted index.
    /// - Returns: The adjusted source string, modified minimally.
    private func replaceFirstOccurrence(in string: String, of target: String, with replacement: String) -> String {
        /// Rename the function declaration on the FIRST line only.
        ///
        /// **Gotchas:** Applying the regex replacement globally to the block mutates internal string literals or variable assignments that happen to share the function's name.
        var lines = string.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return string }
        lines[0] = lines[0].replacingOccurrences(of: "\(target)()", with: "\(replacement)()")
        return lines.joined(separator: "\n")
    }

    /// Discovers the first available Python binary that also has the pip module installed.
    /// - Returns: The absolute path designating a compliant binary, or nil.
    private func getPythonWithPip() async -> String? {
        /// One source of truth for Python detection.
        ///
        /// **Rationale:** Funneling all Python version resolutions through the central manager ensures the shortcut installer uses the globally cached path matrix rather than redundantly invoking subprocesses.
        let pythons = (try? await pythonService.detectPythons()) ?? []
        return pythons.first(where: { $0.pipAvailable })?.path.path
    }

    /// Executes an arbitrary shell string synchronously, returning stdout.
    /// - Parameter command: The literal shell representation.
    /// - Returns: The complete stdout accumulation.
    private func runShellCommand(_ command: String) async -> String {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            return result.combinedOutput
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    /// Ensures the primary shell profile includes the Catalyst alias block.
    /// - Returns: True if the master shell loader is securely referenced.
    private func ensureCatalystSourced() -> Bool {
        ShellConfigManager.shared.ensureCatalystSourced()
    }
}
