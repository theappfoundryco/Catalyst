import Foundation

/// Install/uninstall engine for SmartShortcuts, extracted out of
/// `SmartShortcutsViewModel` (R1). Stateless: it performs the dependency
/// installs, shell-config writes, and removals, streaming human-readable lines
/// through an `onOutput` callback and returning a plain outcome. The ViewModel
/// keeps its `@Published` state (install flag, console, installed map) and
/// records the result.
struct ShortcutInstaller {

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

    func install(_ detail: ShortcutDetail, shortcutId: String, customName: String, onOutput: @escaping (String) -> Void) async -> InstallOutcome {
        // Terminal logging header
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       ⚡ SMARTSHORTCUT INSTALLATION", category: .terminal)
        logger.log("       Shortcut: \(detail.original_name)", category: .terminal)
        logger.log("       Function: \(customName)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)

        logger.log("📦 Installing shortcut: \(shortcutId) as '\(customName)'")
        onOutput("🔧 Installing \(detail.original_name) as '\(customName)'...\n")

        // 1. Validate custom name
        guard isValidFunctionName(customName) else {
            onOutput("❌ Invalid function name. Use only letters, numbers, dashes, underscores.\n")
            return .invalidName
        }

        // 2. Check for conflicts
        if functionExists(customName) {
            onOutput("❌ Function '\(customName)' already exists in shell config\n")
            return .nameConflict
        }

        onOutput("✅ Name validation passed\n")

        // 3. Install dependencies
        if !detail.dependencies.brew.isEmpty || !detail.dependencies.pip.isEmpty {
            onOutput("📦 Installing dependencies...\n")

            // Homebrew packages
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

            // pip packages
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

        // 4. Ensure catalyst file is sourced
        onOutput("⚙️ Configuring shell environment...\n")
        if ensureCatalystSourced() == false {
            onOutput("❌ Failed to configure shell environment\n")
            return .shellConfigFailed
        }

        // 5. Append function to .zshrc_catalyst (sentinel-delimited managed block)
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

        // 6. Note about sourcing
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
    func uninstall(shortcutId: String, onOutput: (String) -> Void) -> Bool {
        onOutput("🗑️ Uninstalling shortcut...\n")

        // Preferred path: remove the sentinel-delimited managed block.
        if ShellConfigManager.shared.removeManagedBlock(id: "shortcut-\(shortcutId)") {
            onOutput("✅ Removed from configuration\n")
        } else if let content = ShellConfigManager.shared.readCatalystConfig() {
            // Fallback for shortcuts installed by older versions: brace-count from
            // the legacy `# CATALYST_ID:` marker to the closing brace.
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

    private func isValidFunctionName(_ name: String) -> Bool {
        let pattern = "^[a-zA-Z0-9_-]+$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    private func functionExists(_ name: String) -> Bool {
        guard let content = ShellConfigManager.shared.readCatalystConfig() else {
            return false
        }
        // Parse actual function declarations (anchored at line start) rather than
        // substring-matching, so name "ls" doesn't match inside "tools()".
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            //  name() { … }   |   name () { … }
            if line.hasPrefix("\(name)(") || line.hasPrefix("\(name) (") { return true }
            //  function name [()] { … }
            if line.hasPrefix("function \(name)") {
                let rest = line.dropFirst("function \(name)".count)
                if rest.isEmpty { return true }
                if let c = rest.first, c == " " || c == "(" || c == "{" { return true }
            }
        }
        return false
    }

    private func replaceFirstOccurrence(in string: String, of target: String, with replacement: String) -> String {
        // Rename the function declaration on the FIRST line only.
        var lines = string.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return string }
        lines[0] = lines[0].replacingOccurrences(of: "\(target)()", with: "\(replacement)()")
        return lines.joined(separator: "\n")
    }

    private func getPythonWithPip() async -> String? {
        // One source of truth for Python detection.
        let pythons = (try? await pythonService.detectPythons()) ?? []
        return pythons.first(where: { $0.pipAvailable })?.path.path
    }

    private func runShellCommand(_ command: String) async -> String {
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            return result.combinedOutput
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }

    private func ensureCatalystSourced() -> Bool {
        ShellConfigManager.shared.ensureCatalystSourced()
    }
}
