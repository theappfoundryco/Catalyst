import Foundation

/// A diagnostic checker that validates the local Git configuration.
///
/// This component ensures Git is installed, accessible, and correctly configured with a user identity.
struct GitDoctor: Doctor {
    /// Spans .tools and .security; runs unconditionally (not AvailabilityCheckable).
    ///
    /// **Rationale:** Git is so fundamental to developer workflows that skipping its validation cascades into cryptic failures across unrelated system scans.
    var category: HealthCategory { .tools }


    /// Verifies if Git is installed without triggering the macOS Xcode Command Line Tools prompt.
    ///
    /// **Flow:**
    /// 1. Scans common Homebrew binary paths (`/opt/homebrew`, `/usr/local`).
    /// 2. Validates the existence of the macOS Developer tools directory `/Library/Developer/CommandLineTools`.
    ///
    /// - Returns: A boolean indicating if Git is safely available for execution.
    func checkAvailability() async -> Bool {
        do {
            /// "which git" returns /usr/bin/git (stub).
            /// "git --version" triggers prompt if missing.
            /// "xcrun -f git" checks if valid developer directory exists?
            /// Safer: Check if Xcode CLI tools path exists OR if Homebrew git exists.
            ///
            /// **Gotchas:** Apple embeds a binary stub at `/usr/bin/git` that inherently triggers a blocking GUI installation prompt when invoked if tools are missing.
            
            /// 1. Check Homebrew Git (preferred usually)
            ///
            /// **Rationale:** Homebrew Git natively integrates with keychain managers far better than Apple's isolated Command Line Tools git.
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/git") { return true }
            if FileManager.default.fileExists(atPath: "/usr/local/bin/git") { return true }
            
            /// 2. Check System Git (via valid Xcode CLI tools)
            /// If /Library/Developer/CommandLineTools exists, the stub usually works.
            ///
            /// **Rationale:** Safely confirming the static directory bypasses the stub executable, guaranteeing presence without triggering UI dialogs.
            let cliToolsExist = FileManager.default.fileExists(atPath: "/Library/Developer/CommandLineTools")
            if cliToolsExist {
                /// Double check by running a safe command?
                /// `git --version` is generally safe IF tools are installed.
                /// If not installed, it prompts.
                /// We rely on the directory existence as "Not Installed" vs "Installed" proxy.
                ///
                /// **Rationale:** Apple's binary shim bypasses CLI prompts only if the backing `.app` structure is fully instantiated on disk.
                return true
            }
            
            return false
        } catch {
            return false
        }
    }
    
    /// Executes the primary Git health checks, evaluating installation and identity configuration.
    ///
    /// **Flow:**
    /// 1. Guards against missing installations via `checkAvailability()`.
    /// 2. Validates basic execution by calling `git --version` in a login shell.
    /// 3. Inspects `git config --global user.email` for unconfigured or placeholder addresses.
    ///
    /// - Returns: An array of `HealthIssue` identifying missing installations or unset user emails.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        /// 1. Safe Existence Check (Avoids Stub Prompt)
        ///
        /// **Gotchas:** Invoking `git` before guaranteeing presence risks permanently hanging the background scan while macOS waits for GUI input.
        if !(await checkAvailability()) {
            issues.append(HealthIssue(
                category: .tools,
                title: "Git Not Found",
                description: "Git is not accessible. Please install it via 'xcode-select --install' or Homebrew.",
                severity: .critical,
                autoFixAvailable: false // Usually fixed by xcode install
            ))
            return issues
        }
        
        /// 2. Check Git Version / Usability (Now safe to run)
        ///
        /// **Rationale:** Resolving the standard output stream proves execution path integrity against corrupted environment `$PATH` overrides.
        do {
            let git = try await AsyncProcessRunner.shared.run(command: "git --version", useLoginShell: true)
            if !git.succeeded {
                issues.append(HealthIssue(
                    category: .tools,
                    title: "Git Error",
                    description: "Git is installed but validation failed: \(git.stderr)",
                    severity: .warning,
                    autoFixAvailable: false
                ))
            }
            /// 3. Git Identity Check (Security)
            ///
            /// **Rationale:** Global identity validates that the workspace correctly sources authentication flows without falling back to local-only scopes.
            do {
                let email = try await AsyncProcessRunner.shared.run(command: "git config --global user.email", useLoginShell: true)
                let emailStr = email.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                
                if emailStr.isEmpty {
                    issues.append(HealthIssue(
                        category: .security,
                        title: "Git Identity Missing",
                        description: "Global 'user.email' is not set. Commits will fail or use hostname.",
                        severity: .warning,
                        autoFixAvailable: false
                    ))
                } else if emailStr.contains("example.com") {
                    issues.append(HealthIssue(
                        category: .security,
                        title: "Git Identity Default",
                        description: "You are using a placeholder email (\(emailStr)).",
                        severity: .info,
                        autoFixAvailable: false
                    ))
                }
            } catch {}
            
        } catch {
            issues.append(HealthIssue(
                category: .tools,
                title: "Git Check Internals Failed",
                description: "Could not execute Git check: \(error.localizedDescription)",
                severity: .warning,
                autoFixAvailable: false
            ))
        }
        
        return issues
    }
    /// Attempts to resolve Git configuration issues.
    ///
    /// **Gotchas:**
    /// Missing developer tools cannot be fully resolved programmatically without invoking interactive graphical installers (`xcode-select --install`).
    ///
    /// - Parameter issue: The specific Git issue to fix.
    /// - Returns: A boolean indicating whether the auto-fix succeeded (usually `false` as Git requires manual setup).
    func fix(_ issue: HealthIssue) async -> Bool {
        return false // Git fixes generally require user intervention (install tools)
    }
}
