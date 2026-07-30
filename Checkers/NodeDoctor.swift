import Foundation

/// A diagnostic checker that identifies issues with local Node.js environment setups.
///
/// Ensures Node is accessible and identifies conflicts such as multiple version managers and global permission issues.
struct NodeDoctor: Doctor, AvailabilityCheckable {
    var category: HealthCategory { .node }


    /// Verifies the availability of the Node runtime.
    ///
    /// **Flow:**
    /// 1. Executes `node -v` inside an interactive login shell, matching user configurations.
    ///
    /// - Returns: A boolean indicating if the run command executes successfully.
    func checkAvailability() async -> Bool {
        do {
            let res = try await AsyncProcessRunner.shared.run(command: "node -v", useLoginShell: true)
            return res.succeeded
        } catch {
            return false
        }
    }
    
    /// Scans the local environment for conflicting version managers and permission boundaries.
    ///
    /// **Flow:**
    /// 1. Flags simultaneous inclusion of `nvm` and `brew node` binaries.
    /// 2. Queries `npm root -g` to find global boundaries.
    /// 3. Cross-references POSIX directory ownership to warn against `root`-owned generic repositories preventing safe installations.
    ///
    /// - Returns: An array of `HealthIssue` detailing active Node conflicts and permission warnings.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        var managers: [String] = []
        let nvmExists = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.nvm")
        if nvmExists { managers.append("nvm") }
        
        if BrewPathManager.shared.isInstalled {
            let brewNodeResult = try? await AsyncProcessRunner.shared.run(command: "\(BrewPathManager.shared.homebrewPrefix)/bin/brew list --formula | grep node")
            if let output = brewNodeResult?.stdout, !output.isEmpty {
                managers.append("Homebrew Node")
            }
        }
        
        if managers.count > 1 {
            issues.append(HealthIssue(
                category: .node,
                title: "Node Version Chaos",
                description: "You have generic Node installed via Brew AND nvm. This causes compilation errors.",
                severity: .warning,
                autoFixAvailable: false
            ))
        }
        
        /// `npm root -g` must run in a LOGIN shell (#10).
        ///
        /// **Gotchas:** `checkAvailability` probes `node -v` with `useLoginShell: true`
        /// while this call used a bare `zsh -c`. A bare shell sources no profile, so
        /// nvm/brew never reach PATH and npm exits 127 — on a machine where npm is
        /// perfectly fine. The asymmetry made the card silently report nothing.
        /// Both probes must use the same environment or the comparison is meaningless.
        do {
            let npmRootResult = try await AsyncProcessRunner.shared.run(command: "npm root -g", useLoginShell: true)

            if npmRootResult.succeeded {
                let globalPath = npmRootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let attrs = try FileManager.default.attributesOfItem(atPath: globalPath)
                if let ownerID = attrs[.ownerAccountID] as? Int, ownerID == 0 {
                     issues.append(HealthIssue(
                        category: .node,
                        title: "NPM Owned by Root",
                        description: "Your global node_modules are owned by root. You'll need 'sudo' for every install. This is dangerous.",
                        severity: .critical,
                        autoFixAvailable: true,
                        fixID: .fixNPMOwnership
                    ))
                }
            } else if let brokenIssue = await Self.presentButNotWorking(npmRootResult) {
                /// Resolves on PATH but won't execute — surface it rather than
                /// rendering the card from a half-broken toolchain and saying nothing.
                issues.append(brokenIssue)
            }
        } catch {
            /// Never swallow silently — a probe that couldn't even launch is itself
            /// a finding, and an empty `catch` is what hid #10 for two releases.
            issues.append(HealthIssue(
                category: .node,
                title: "Node Check Failed",
                description: "Could not probe the Node toolchain: \(error.localizedDescription)",
                severity: .warning,
                autoFixAvailable: false
            ))
        }

        return issues
    }

    /// Distinguishes "npm isn't installed" from "npm is installed but broken".
    ///
    /// A non-zero exit from `npm root -g` is ambiguous on its own. If the shell
    /// can still *resolve* npm on PATH (`command -v npm` → 0) while the binary
    /// fails to run (typically 127 from a stale nvm shim or a dangling Node
    /// symlink), that's a broken toolchain — not a missing one — and the user
    /// needs to be told, because every downstream npm reading is untrustworthy.
    ///
    /// - Parameter result: The failed `npm root -g` invocation.
    /// - Returns: A `HealthIssue` when npm resolves but can't execute, else `nil`.
    private static func presentButNotWorking(
        _ result: AsyncProcessRunner.ProcessResult
    ) async -> HealthIssue? {
        let looksUnexecutable = result.exitCode == 127
            || result.stderr.lowercased().contains("command not found")
            || result.stderr.lowercased().contains("no such file or directory")
        guard looksUnexecutable else { return nil }

        /// `command -v` is a shell builtin — no extra process, and unlike `which`
        /// it honours functions and aliases the way the user's shell actually would.
        let resolves = (try? await AsyncProcessRunner.shared.run(
            command: "command -v npm", useLoginShell: true))?.succeeded ?? false
        guard resolves else { return nil }

        return HealthIssue(
            category: .node,
            title: "npm is present but not working",
            description: "npm resolves on your PATH but fails to execute (exit \(result.exitCode)). "
                + "This is usually a stale nvm shim or a broken Node symlink — reinstall Node, "
                + "or run `nvm use --delete-prefix <version>` to repoint the shim.",
            severity: .critical,
            autoFixAvailable: false
        )
    }
    
    /// Attempts to apply fixes for identified Node environment issues.
    ///
    /// **Gotchas:**
    /// Altering standard global node `root` boundaries via `chown` causes security cascade failures and requires raw administrative passwords. Not currently fixable via non-sudo APIs.
    ///
    /// - Parameter issue: The health issue identified.
    /// - Returns: A boolean indicating if the automated fix was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .fixNPMOwnership {
            do {
                let npmRootResult = try await AsyncProcessRunner.shared.run(command: "npm root -g", useLoginShell: true)
                _ = npmRootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                
                return false
            } catch {
                return false
            }
        }
        return false
    }
}
