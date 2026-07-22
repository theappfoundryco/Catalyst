import Foundation

/// A diagnostic checker designed to identify path overlap and executable shadowing issues.
///
/// `ConflictDoctor` probes standard binary pathways to detect environments where multiple package managers overlap logically.
struct ConflictDoctor: Doctor {
    /// Emits .path issues (NPM shadowing); shares the category with PathSanityCheck.
    ///
    /// **Rationale:** Aggregating NPM and Path issues under a single UI category prevents dashboard clutter.
    var category: HealthCategory { .path }


    /// Evaluates executable resolution paths to identify shadowing issues affecting global commands.
    ///
    /// **Flow:**
    /// 1. Runs `which npm` within an interactive login shell context.
    /// 2. Checks if the resolution resolves to a global package manager instead of a localized node environment manager (NVM).
    /// 3. Verifies NVM presence dynamically before emitting overlapping path warnings.
    ///
    /// - Returns: An array of `HealthIssue` representing shadowing configuration conflicts, such as NVM overlapping with Brew NPM.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        do {
            /// Resolve npm in a login shell so PATH/profile match the user's
            /// real environment (a non-login shell often has neither NVM nor the
            /// full PATH).
            ///
            /// **Rationale:** Bypassing the login shell natively strips `.bashrc` or `.zshrc` exports, breaking environment managers.
            /// **Gotchas:** This spawns an interactive TTY inherently slower than a direct binary execution.
            let whichNpm = try await AsyncProcessRunner.shared.run(command: "which npm", useLoginShell: true)
            let path = whichNpm.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            /// Brew npm lives at the resolved prefix — /opt/homebrew on Apple
            /// Silicon, /usr/local on Intel. Hard-coding /usr/local meant this
            /// never fired on M-series Macs.
            ///
            /// **Gotchas:** System architectures natively route binary linkage differently; static paths inherently fail across CPU architectures.
            let brewNpm = BrewPathManager.shared.homebrewPrefix + "/bin/npm"
            let isBrewOrSystemNpm = path == brewNpm
                || path == "/usr/local/bin/npm"
                || path == "/opt/homebrew/bin/npm"

            if isBrewOrSystemNpm {
                /// NVM presence: $NVM_DIR in a login shell, or a ~/.nvm directory.
                ///
                /// **Rationale:** Confirms overlap by identifying a dual-installed node manager actively fighting the homebrew environment.
                let nvmCheck = try await AsyncProcessRunner.shared.run(command: "echo $NVM_DIR", useLoginShell: true)
                let nvmDirSet = !nvmCheck.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let nvmInstalled = FileManager.default.fileExists(
                    atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nvm").path
                )
                if nvmDirSet || nvmInstalled {
                     issues.append(HealthIssue(
                        category: .path,
                        title: "NPM Shadowing",
                        description: "You have NVM installed, but 'npm' resolves to a system/brew path (\(path)).",
                        severity: .warning,
                        autoFixAvailable: false
                    ))
                }
            }
        } catch {}
        
        return issues
    }
    
    /// Triggers automated resolutions mapping directly onto identified shadowing properties reliably.
    ///
    /// - Parameter issue: The shadowing issue to be fixed.
    /// - Returns: A boolean indicating if the fix was successful (currently always `false` for conflict issues).
    func fix(_ issue: HealthIssue) async -> Bool { false }
}
