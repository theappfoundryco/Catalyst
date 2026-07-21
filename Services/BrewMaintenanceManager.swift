import Foundation

/// Homebrew cache/cellar/update summary shown on the dashboard. Moved out of
/// `DashboardViewModel` so both the VM and `BrewMaintenanceManager` can use it
/// without qualification (the View reads it via `vm.brewSystemStats`, never by
/// the qualified type name).
struct BrewSystemStats {
    let cacheSize: String
    let cellarSize: String
    let cleanableSize: String
    let lastUpdate: String
}

/// Owns the Homebrew lifecycle + maintenance work previously inlined in
/// `DashboardViewModel` (R1 / P2 god-VM decomposition, step 3): installing and
/// uninstalling Homebrew, the update/upgrade/cleanup/doctor/link commands,
/// system stats, and unlinked-keg parsing.
///
/// Streaming maintenance commands take an `onOutput` callback so the live
/// console (`@Published` on the VM) stays where the View binds it — this manager
/// holds no view state. `@MainActor` matches the VM's isolation.
@MainActor
final class BrewMaintenanceManager {
    private let privileges: PrivilegesService
    private let logger: Logger

    init(privileges: PrivilegesService, logger: Logger) {
        self.privileges = privileges
        self.logger = logger
    }

    // MARK: - Install / uninstall

    /// Full in-app Homebrew install: download the script, prompt for the admin
    /// password, run the installer as the current user via `SUDO_ASKPASS`
    /// (credential passed in-memory, never written to disk), then run
    /// `brew doctor` and auto-repair any unlinked kegs. Returns `true` on a
    /// successful install. The VM owns the busy flag, output/keg resets, and the
    /// post-install global refresh.
    func installHomebrew() async -> Bool {
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       📦 HOMEBREW INSTALLATION", category: .terminal)
        logger.log("═══════════════════════════════════════\n", category: .terminal)
        logger.log("📦 Starting Homebrew installation in-app...")

        // Step 1: Download the Homebrew install script (no privileges needed)
        let scriptPath = "/tmp/homebrew_install.sh"
        logger.log("⬇️ Downloading Homebrew installer...")

        do {
            let downloadResult = try await AsyncProcessRunner.shared.run(
                command: "curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o \(scriptPath) && chmod +x \(scriptPath)"
            )
            guard downloadResult.succeeded else {
                logger.log("❌ Installer download failed: \(downloadResult.combinedOutput)")
                return false
            }
        } catch {
            logger.log("❌ Installer download error: \(error.localizedDescription)")
            return false
        }

        // Step 2: Prompt for admin password and cache sudo credentials.
        // Homebrew's install script REFUSES to run as root ("Don't run this as
        // root!"). We must run as the current user, but pre-supply sudo so the
        // script's internal sudo calls succeed without a TTY prompt.
        logger.log("🔐 Prompting for admin password...")

        let passwordScript = """
        tell application (path to frontmost application as text)
            display dialog "Catalyst wants to make changes. Type your password to allow this.\\n\\nCatalyst requires authentication to install Homebrew." default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with title "System Authentication" with icon POSIX file "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/LockedIcon.icns"
            text returned of result
        end tell
        """

        let password: String
        do {
            password = try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", passwordScript]
                let pipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = pipe
                process.standardError = errPipe

                process.terminationHandler = { proc in
                    if proc.terminationStatus != 0 {
                        continuation.resume(throwing: PrivilegeError.cancelled)
                        return
                    }
                    let result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: result)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            guard !password.isEmpty else {
                logger.log("❌ Empty password")
                try? FileManager.default.removeItem(atPath: scriptPath)
                return false
            }
        } catch is PrivilegeError {
            logger.log("⚠️ User cancelled Homebrew installation")
            try? FileManager.default.removeItem(atPath: scriptPath)
            return false
        } catch {
            logger.log("❌ Password prompt error: \(error.localizedDescription)")
            try? FileManager.default.removeItem(atPath: scriptPath)
            return false
        }

        // Create a temporary askpass script for sudo. The script contains NO
        // secret — it echoes a password supplied at run time via an in-memory
        // environment variable, so the credential is never written to disk.
        let askPassPath = "/tmp/catalyst_askpass.sh"
        let askPassContent = """
        #!/bin/bash
        printf '%s\\n' "$CATALYST_BREW_SUDO_PW"
        """

        do {
            try askPassContent.write(toFile: askPassPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askPassPath)
        } catch {
            logger.log("❌ Failed to create askpass script: \(error.localizedDescription)")
            try? FileManager.default.removeItem(atPath: scriptPath)
            return false
        }

        // Step 3: Run the installer as current user (NOT root) with SUDO_ASKPASS.
        // Homebrew sees SUDO_ASKPASS and automatically uses `sudo -A`.
        logger.log("📦 Running Homebrew installer as current user via SUDO_ASKPASS...")

        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(
                command: "export SUDO_ASKPASS=\(InputSanitizer.singleQuote(askPassPath)) && NONINTERACTIVE=1 /bin/bash \(InputSanitizer.singleQuote(scriptPath))",
                environment: ["CATALYST_BREW_SUDO_PW": password]
            ) { text in
                self.logger.log(text, category: .terminal)
            }

            // Clean up credentials immediately
            try? FileManager.default.removeItem(atPath: askPassPath)
            try? FileManager.default.removeItem(atPath: scriptPath)

            if exitCode != 0 {
                logger.log("❌ Homebrew installation failed (exit: \(exitCode))")
                return false
            }

            logger.log("✅ Homebrew installed successfully")
        } catch {
            // Clean up credentials immediately
            try? FileManager.default.removeItem(atPath: askPassPath)
            try? FileManager.default.removeItem(atPath: scriptPath)

            logger.log("❌ Homebrew installation failed: \(error.localizedDescription)")
            return false
        }

        // Wait for filesystem to sync
        try? await Task.sleep(for: .seconds(2))

        // Post-install: run brew doctor to check for broken links
        logger.log("🩺 Running post-install brew doctor...")

        var doctorOutput = ""
        var unlinkedKegs: [String] = []
        do {
            let _ = try await AsyncProcessRunner.shared.runWithStreaming(
                command: brewCommand("doctor")
            ) { text in
                doctorOutput += text
            }
            unlinkedKegs = parseUnlinkedKegs(from: doctorOutput)
        } catch {
            logger.log("⚠️ brew doctor failed: \(error.localizedDescription)")
        }

        // Auto-repair broken links if found
        if !unlinkedKegs.isEmpty {
            let kegsToLink = unlinkedKegs.joined(separator: " ")
            logger.log("🔗 Auto-repairing unlinked kegs: \(kegsToLink)")

            do {
                let _ = try await AsyncProcessRunner.shared.runWithStreaming(
                    command: brewCommand("link --overwrite \(kegsToLink)")
                ) { text in
                    self.logger.log(text, category: .terminal)
                }
                logger.log("✅ Broken links repaired automatically")
            } catch {
                logger.log("⚠️ Failed to repair some links: \(error.localizedDescription)")
            }
        }

        // Cleanup temp script
        try? FileManager.default.removeItem(atPath: scriptPath)
        return true
    }

    /// Remove Homebrew's installed tree through the privileged, allowlisted
    /// delete path. The VM owns the busy flag and refresh.
    func uninstallHomebrew() async {
        logger.log("🗑️ Uninstalling Homebrew...")

        let prefix = BrewPathManager.shared.homebrewPrefix
        let paths = [
            "\(prefix)/AGENTS.md",
            "\(prefix)/bin/",
            "\(prefix)/etc/",
            "\(prefix)/lib/",
            "\(prefix)/share/",
            "\(prefix)/var/"
        ]

        do {
            try await privileges.removeFiles(at: paths)
            logger.log("✅ Homebrew uninstallation complete")
        } catch {
            logger.log("❌ Uninstall error: \(error.localizedDescription)")
        }
    }

    // MARK: - Maintenance commands

    func update(onOutput: @escaping (String) -> Void) async {
        banner("🔄 HOMEBREW UPDATE")
        logger.log("🔄 Updating Homebrew...")
        await runBrewCommand(brewCommand("update"), onOutput: onOutput)
    }

    func upgradeAll(onOutput: @escaping (String) -> Void) async {
        banner("⬆️ HOMEBREW UPGRADE ALL")
        logger.log("⬆️ Upgrading all packages...")
        await runBrewCommand(brewCommand("upgrade"), onOutput: onOutput)
    }

    func cleanup(onOutput: @escaping (String) -> Void) async {
        banner("🧹 HOMEBREW CLEANUP")
        logger.log("🧹 Cleaning up...")
        await runBrewCommand(brewCommand("cleanup -s"), onOutput: onOutput)
    }

    func doctor(onOutput: @escaping (String) -> Void) async {
        banner("🩺 HOMEBREW DOCTOR")
        logger.log("🩺 Running doctor...")
        await runBrewCommand(brewCommand("doctor"), onOutput: onOutput)
    }

    func link(kegs: [String], onOutput: @escaping (String) -> Void) async {
        banner("🔗 LINKING PACKAGES")
        let kegsToLink = kegs.joined(separator: " ")
        logger.log("🔗 Linking: \(kegsToLink)...")
        // --overwrite forces the link including any conflicting symlinks.
        await runBrewCommand(brewCommand("link --overwrite \(kegsToLink)"), onOutput: onOutput)
    }

    // MARK: - Stats

    func loadStats() async -> BrewSystemStats {
        logger.log("📊 Loading system stats...")

        let cacheSize = await directorySize("/Library/Caches/Homebrew")
        let cellarSize = await directorySize(BrewPathManager.shared.cellarPath)
        let lastUpdate = await lastUpdateTime()

        return BrewSystemStats(
            cacheSize: cacheSize,
            cellarSize: cellarSize,
            cleanableSize: "Run cleanup to check",
            lastUpdate: lastUpdate
        )
    }

    // MARK: - Keg parsing

    /// Parse `brew doctor` output for unlinked kegs.
    func parseUnlinkedKegs(from output: String) -> [String] {
        guard output.contains("Warning: You have unlinked kegs") else { return [] }

        let lines = output.components(separatedBy: .newlines)
        var isCapturing = false
        var capturedKegs: [String] = []

        for line in lines {
            if line.contains("Warning: You have unlinked kegs") {
                isCapturing = true
                continue
            }

            if isCapturing {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.isEmpty { continue }
                if line.starts(with: "Warning:") || line.starts(with: "Error:") { break }
                if trimmed.contains("Operation completed") || trimmed.contains("✅") { break }
                if trimmed.contains(" ") || trimmed.contains("Run `brew link`") || trimmed.contains("unlinked kegs") { continue }

                capturedKegs.append(trimmed)
            }
        }

        if !capturedKegs.isEmpty {
            logger.log("⚠️ Detected unlinked kegs: \(capturedKegs.joined(separator: ", "))")
        }
        return capturedKegs
    }

    // MARK: - Internals

    /// Build a `brew <subcommand>` invocation with the resolved Homebrew prefix
    /// prepended to PATH.
    private func brewCommand(_ subcommand: String) async -> String {
        "export PATH=\"\(BrewPathManager.shared.homebrewPrefix)/bin:$PATH\" && \(BrewPathManager.shared.brewPath) \(subcommand)"
    }

    private func banner(_ title: String) {
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
        logger.log("       \(title)", category: .terminal)
        logger.log("\n\n═══════════════════════════════════════", category: .terminal)
    }

    /// Run a streamed brew command, forwarding each chunk to `onOutput` and
    /// appending a terminal success/failure annotation. `brew doctor` warnings
    /// are treated as success.
    private func runBrewCommand(_ command: String, onOutput: @escaping (String) -> Void) async {
        var accumulated = ""
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { text in
                accumulated += text
                onOutput(text)
            }

            let isBrewDoctor = command.contains("brew doctor")
            let hasWarningsOnly = accumulated.contains("Please note that these warnings are just used to help")

            if exitCode == 0 || (isBrewDoctor && hasWarningsOnly) {
                logger.log("✅ Command completed successfully")
                onOutput("\n\n✅ Operation completed successfully")
            } else {
                logger.log("❌ Command failed with exit code \(exitCode)")
                onOutput("\n\n❌ Operation failed (exit code: \(exitCode))")
            }
        } catch {
            logger.log("❌ Error: \(error.localizedDescription)")
            onOutput("\n\n❌ Error: \(error.localizedDescription)")
        }
    }

    private func directorySize(_ path: String) async -> String {
        return await Task.detached {
            let command = "du -sh \(InputSanitizer.singleQuote(path)) 2>/dev/null | awk '{print $1}'"
            do {
                let result = try await AsyncProcessRunner.shared.run(command: command)
                let size = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !size.isEmpty { return size }
            } catch {
                self.logger.log("Failed to get size for \(path): \(error.localizedDescription)")
            }
            return "N/A"
        }.value
    }

    private func lastUpdateTime() async -> String {
        let command = "stat -f '%Sm' -t '%Y-%m-%d %H:%M' \(InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/.git/FETCH_HEAD")) 2>/dev/null"
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            let time = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !time.isEmpty { return time }
        } catch {
            logger.log("Failed to get last update time: \(error.localizedDescription)")
        }
        return "Unknown"
    }
}
