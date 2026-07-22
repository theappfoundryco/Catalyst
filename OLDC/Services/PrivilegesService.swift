import Foundation

/// Defines standard error outcomes resulting from elevated privilege requests.
enum PrivilegeError: Error {
    /// The authorization prompt was declined or aborted by the user.
    case cancelled
    /// The authorization prompt failed due to misconfiguration or local restrictions.
    case failed(String)
    /// The elevated action executed but returned a non-zero exit status.
    case scriptError(Int32)
}

/// A service layer handling the execution of shell commands requiring root access.
///
/// `PrivilegesService` wraps `osascript` to prompt for system administrator credentials
/// and executes sensitive commands securely, such as modifying package paths or installing core toolchains.
final class PrivilegesService {
    private let logger: Logger

    /// In-memory copy of the admin password for the current session. The
    /// durable copy lives in the on-device Keychain (`AdminCredentialStore`),
    /// so the user authenticates once, ever — not once per launch. Cleared,
    /// along with the Keychain item, by `invalidateCredentials()`.
    private var cachedPassword: String?

    /// Serializes credential acquisition so two concurrent privileged actions
    /// can't each pop a password dialog on first use.
    private let credentialGate = NSLock()

    /// Initializes the privileged execution layer.
    ///
    /// - Parameter logger: The global logging subsystem.
    init(logger: Logger) {
        self.logger = logger
    }

    /// Forgets the admin credential — both the in-memory copy and the durable
    /// Keychain item. Call after a known password change (the stored one no
    /// longer works). The next privileged action will prompt again and re-store.
    func invalidateCredentials() {
        credentialGate.lock()
        cachedPassword = nil
        credentialGate.unlock()
        AdminCredentialStore.clear()
        logger.log("🔐 Cleared stored admin credential")
    }

    /// Whether a credential is available without prompting (in memory this
    /// session, or persisted on-device from a previous launch).
    var hasCachedCredential: Bool {
        credentialGate.lock(); defer { credentialGate.unlock() }
        return cachedPassword != nil || AdminCredentialStore.load() != nil
    }

    /// When enabled (and the SMAppService helper is installed), privileged
    /// commands run through the helper over XPC with **no password prompt at
    /// all**, even across launches. Leave `false` until the helper target is
    /// built and registered (see `PrivilegedHelper/README.md`); the app then
    /// falls back to the per-launch password cache below.
    var preferPrivilegedHelper = false
    
    /// Assesses whether a given path is considered safe to delete with elevated privileges.
    ///
    /// - Parameter path: The raw file path literal.
    /// - Returns: A boolean asserting if the path bounds sit inside predefined secure regions.
    func validateSafeToDeletePath(_ path: String) -> Bool {
        let nsPath = path as NSString
        let expandedPath = nsPath.expandingTildeInPath
        
        guard !expandedPath.isEmpty, expandedPath != "/" else { return false }
        
        let safeAreas = [
            "/opt/homebrew",
            "/usr/local/Cellar",
            "/usr/local/Caskroom",
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/share/virtualenvs",
            FileManager.default.homeDirectoryForCurrentUser.path + "/.virtualenvs",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Caches/Homebrew",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/Homebrew"
        ]

        let blockedPrefixes = [
            "/System",
            "/usr/bin",
            "/usr/sbin",
            "/bin",
            "/sbin",
            "/Library",
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Library",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Documents",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Desktop",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Downloads"
        ]

        // Allowlist wins: explicit safe areas are permitted even when nested
        // under a broader blocked prefix (e.g. ~/Library/Caches/Homebrew).
        for area in safeAreas {
            if expandedPath == area || expandedPath.hasPrefix(area + "/") {
                return true
            }
        }

        // Otherwise reject anything inside a protected location.
        for blocked in blockedPrefixes {
            if expandedPath == blocked || expandedPath.hasPrefix(blocked + "/") {
                logger.log("⚠️ Path rejected (protected location): \(expandedPath)")
                return false
            }
        }

        logger.log("⚠️ Path rejected for deletion: \(expandedPath)")
        return false
    }
    
    /// Executes a bash command under elevated root privileges.
    ///
    /// The admin password is requested **once per app launch** via a secure
    /// dialog, validated, and cached in memory; every later call reuses it and
    /// runs silently. If the cached credential is ever rejected (e.g. the
    /// password changed), it's cleared and the user is prompted once more.
    ///
    /// - Parameter command: The bash command string to execute under escalated permissions.
    /// - Returns: A tuple encompassing the execution success metric and the output buffer.
    /// - Throws: A `PrivilegeError` encoding the cancellation or failure root cause.
    func runWithPrivileges(command: String) async throws -> (success: Bool, output: String) {
        // Preferred path: a registered privileged helper runs the command over
        // XPC with no prompt. Falls through to the password flow if it's off or
        // not installed.
        if preferPrivilegedHelper, PrivilegedHelperManager.shared.isInstalled {
            do {
                let (code, output) = try await PrivilegedHelperManager.shared.runShell(command)
                if code == 0 {
                    logger.log("✅ Command executed via privileged helper")
                    return (true, output)
                } else {
                    logger.log("❌ Helper command failed with exit code \(code)")
                    throw PrivilegeError.scriptError(code)
                }
            } catch let error as PrivilegeError {
                throw error
            } catch {
                logger.log("⚠️ Helper unavailable (\(error.localizedDescription)); falling back to password prompt")
            }
        }

        let password = try await ensureCredential()

        var result = try await runSudo(command: command, password: password)

        // A stale/rejected credential: forget it, prompt once, and retry.
        if result.authFailed {
            logger.log("🔐 Cached credential rejected — re-requesting")
            invalidateCredentials()
            let fresh = try await ensureCredential()
            result = try await runSudo(command: command, password: fresh)
            if result.authFailed { throw PrivilegeError.failed("Authentication failed.") }
        }

        if result.success {
            logger.log("✅ Command executed successfully")
            return (true, result.output)
        } else {
            logger.log("❌ Command failed with exit code \(result.exitCode)")
            throw PrivilegeError.scriptError(result.exitCode)
        }
    }

    // MARK: - Credential acquisition & caching

    /// Returns the admin password without prompting when possible: first from
    /// this session's memory, then from the on-device Keychain (a prior launch).
    /// Only if neither exists does it prompt, validate, and persist. Retries the
    /// dialog up to 3 times on an incorrect entry.
    private func ensureCredential() async throws -> String {
        credentialGate.lock()
        let existing = cachedPassword
        credentialGate.unlock()
        if let existing { return existing }

        // Persisted from a previous launch — reuse silently. If it's stale, the
        // caller's authFailed path clears it (via invalidateCredentials) and
        // routes back here to prompt fresh.
        if let stored = AdminCredentialStore.load() {
            credentialGate.lock()
            cachedPassword = stored
            credentialGate.unlock()
            logger.log("🔐 Loaded admin credential from Keychain")
            return stored
        }

        for attempt in 1...3 {
            let pw = try await promptForPassword(retry: attempt > 1)   // throws .cancelled on Cancel
            if await passwordIsValid(pw) {
                credentialGate.lock()
                cachedPassword = pw
                credentialGate.unlock()
                AdminCredentialStore.save(pw)
                logger.log("🔐 Admin credential validated and stored on-device")
                return pw
            }
        }
        throw PrivilegeError.failed("Incorrect password.")
    }

    /// Presents the secure password dialog and returns the entered text.
    private func promptForPassword(retry: Bool) async throws -> String {
        let message = retry
            ? "That password didn't work. Please try again."
            : "Catalyst wants to make changes. Type your password to allow this.\\n\\nStored securely in your Mac's Keychain, on this device only — you won't be asked again."
        let script = """
        tell application (path to frontmost application as text)
            set dialogResult to display dialog "\(message)" default answer "" with hidden answer buttons {"Cancel", "OK"} default button "OK" with title "System Authentication" with icon POSIX file "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/LockedIcon.icns"
            set userPassword to text returned of dialogResult
        end tell
        return userPassword
        """

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    // Non-zero from osascript here means the user pressed Cancel.
                    continuation.resume(throwing: PrivilegeError.cancelled)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: PrivilegeError.failed(error.localizedDescription))
            }
        }
    }

    /// Validates a password by priming sudo's timestamp (`sudo -S -v`).
    private func passwordIsValid(_ password: String) async -> Bool {
        guard let result = try? await runSudo(command: "-v", password: password, validateOnly: true) else {
            return false
        }
        return result.success && !result.authFailed
    }

    private struct SudoResult { let success: Bool; let output: String; let exitCode: Int32; let authFailed: Bool }

    /// Runs `sudo -S` with the password piped on stdin (no GUI dialog, no
    /// password embedded in any script source). When `validateOnly` is true the
    /// arguments are passed straight to sudo (used for `-v`).
    private func runSudo(command: String, password: String, validateOnly: Bool = false) async throws -> SudoResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = validateOnly
                ? ["-S", "-p", "", "-v"]
                : ["-S", "-p", "", "/bin/sh", "-c", command]

            // Pin a stable locale so sudo's auth-failure messages are always the English strings
            // the `authFailed` detection below matches. Without this, a localized Mac emits
            // translated errors, `authFailed` stays false, and the stale-password re-prompt
            // (e.g. after the user changes their macOS password) silently never fires.
            var env = ProcessInfo.processInfo.environment
            env["LC_ALL"] = "C"
            process.environment = env

            let inPipe = Pipe()
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardInput = inPipe
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let lowerErr = err.lowercased()
                let authFailed = lowerErr.contains("incorrect password")
                    || lowerErr.contains("sorry, try again")
                    || lowerErr.contains("no password was provided")
                    || lowerErr.contains("a password is required")
                continuation.resume(returning: SudoResult(
                    success: proc.terminationStatus == 0,
                    output: out.isEmpty ? err : out,
                    exitCode: proc.terminationStatus,
                    authFailed: authFailed
                ))
            }

            do {
                try process.run()
                let handle = inPipe.fileHandleForWriting
                if let data = (password + "\n").data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } catch {
                continuation.resume(throwing: PrivilegeError.failed(error.localizedDescription))
            }
        }
    }
    
    /// Executes the standard Homebrew install routine binding the target package locally.
    ///
    /// - Parameters:
    ///   - formula: The exact Homebrew package formula string name.
    ///   - logHandler: A closure to handle streaming log outputs during the installation.
    /// - Returns: A tuple carrying standard termination state identifiers and error descriptors.
    func installBrewFormula(_ formula: String, logHandler: @escaping (String) -> Void) async throws -> (success: Bool, exitCode: Int32, message: String?) {
        guard let sanitizedFormula = InputSanitizer.sanitizePackageName(formula) else {
            logger.log("❌ Invalid formula name: \(formula)")
            return (false, -1, "Invalid formula name")
        }
        
        logger.log("📦 Installing formula: \(sanitizedFormula)")
        logHandler("Installing \(sanitizedFormula)...")
        
        let command = """
        export PATH=\(InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/bin")):/usr/bin:/bin:/usr/sbin:/sbin
        export HOME="$HOME"
        export USER="$(id -un)"
        export LOGNAME="$USER"
        export SHELL="/bin/zsh"
        export HOMEBREW_NO_AUTO_UPDATE=1
        export HOMEBREW_NO_ENV_HINTS=1
        
        \(InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)) install \(InputSanitizer.singleQuote(sanitizedFormula)) 2>&1
        """
        
        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { output in
                output.components(separatedBy: .newlines).forEach { line in
                    if !line.isEmpty {
                        logHandler(line)
                    }
                }
            }
            
            if exitCode == 0 {
                logger.log("✅ Formula installed successfully")
                return (true, 0, "Installation completed")
            } else {
                logger.log("❌ Installation failed with exit code \(exitCode)")
                return (false, exitCode, "Installation failed with code \(exitCode)")
            }
        } catch {
            logger.log("❌ Installation error: \(error.localizedDescription)")
            return (false, -1, error.localizedDescription)
        }
    }
    
    /// Initiates the global Homebrew installation process by redirecting execution into an interactive terminal instance.
    ///
    /// - Parameter logHandler: A closure rendering structural guidance prompts.
    func installHomebrew(logHandler: @escaping (String) -> Void) async throws {
        logger.log("📦 Installing Homebrew...")
        logHandler("📦 Opening Terminal to install Homebrew...")
        logHandler("⚠️ You will be prompted for your password in Terminal")
        logHandler("⚠️ Please wait for installation to complete before closing Terminal")
        
        return try await withCheckedThrowingContinuation { continuation in
            let installCommand = "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
            
            Task { @MainActor in
                TerminalService.shared.runInteractiveCommand(installCommand)
                
                self.logger.log("✅ Homebrew installation connection successful")
                logHandler("✅ Installation script launched in Terminal")
                logHandler("💡 Check Terminal window for progress")
                logHandler("💡 Return here after installation completes")
                continuation.resume()
            }
        }
    }
    
    /// Unhooks standard package linkage mappings, isolating and entirely scrubbing the component out of local disk allocations.
    ///
    /// - Parameters:
    ///   - formula: The exact Homebrew package formula string name.
    ///   - logHandler: A closure to handle streaming log outputs during the uninstallation.
    /// - Returns: A tuple detailing the exit status and any resulting error messages.
    func uninstallBrewFormula(_ formula: String, logHandler: @escaping (String) -> Void = { _ in }) async throws -> (success: Bool, exitCode: Int32, message: String?) {
        guard let sanitizedFormula = InputSanitizer.sanitizePackageName(formula) else {
            logger.log("❌ Invalid formula name: \(formula)")
            return (false, -1, "Invalid formula name")
        }
        
        logger.log("🗑️ Uninstalling formula: \(sanitizedFormula)")
        logHandler("Uninstalling \(sanitizedFormula)...")

        let command = "export PATH=\(InputSanitizer.singleQuote(BrewPathManager.shared.homebrewPrefix + "/bin")):\"$PATH\" && \(InputSanitizer.singleQuote(BrewPathManager.shared.brewPath)) uninstall --ignore-dependencies \(InputSanitizer.singleQuote(sanitizedFormula)) 2>&1"

        do {
            let exitCode = try await AsyncProcessRunner.shared.runWithStreaming(command: command) { output in
                 output.components(separatedBy: .newlines).forEach { line in
                     if !line.isEmpty { logHandler(line) }
                 }
            }

            if exitCode == 0 {
                logger.log("✅ Formula uninstalled successfully")
                return (true, 0, "Uninstalled successfully")
            } else {
                logger.log("❌ Uninstall failed with exit code \(exitCode)")
                return (false, exitCode, "Uninstall failed with code \(exitCode)")
            }
        } catch {
            logger.log("❌ Uninstall error: \(error.localizedDescription)")
            return (false, -1, error.localizedDescription)
        }
    }

    /// Attempts to safely eradicate files and folders matching the targeted absolute paths utilizing root privileges.
    ///
    /// - Parameter paths: An array of string literals containing localized absolute paths targeting deletion.
    /// - Throws: An error on failure to run the removal command.
    func removeFiles(at paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        
        logger.log("🗑️ Removing \(paths.count) items with admin privileges...")
        
        let safePaths = paths.filter { validateSafeToDeletePath($0) }
        
        guard !safePaths.isEmpty else {
            logger.log("⚠️ All paths were rejected by safety check")
            return
        }
        
        if safePaths.count < paths.count {
            logger.log("⚠️ \(paths.count - safePaths.count) path(s) were rejected by safety check")
        }
        
        // Shell-quote each path exactly once via the singleQuote helper. The
        // inner single-quote layer makes the path safe for the shell; the
        // AppleScript-source escaping inside runWithPrivileges is a separate
        // layer (it targets the osascript string literal, not the shell), so
        // the two do not redundantly stack.
        let rmCommands = safePaths
            .map { "rm -rf \(InputSanitizer.singleQuote($0))" }
            .joined(separator: " && ")
        
        do {
            let (success, _) = try await runWithPrivileges(command: rmCommands)
            if success {
                logger.log("✅ Removed all items successfully")
                for path in paths {
                    logger.log("  ✓ \(path)")
                }
            } else {
                logger.log("⚠️ Some items may not have been removed")
            }
        } catch {
            logger.log("❌ Error during removal: \(error.localizedDescription)")
            throw error
        }
    }
}
