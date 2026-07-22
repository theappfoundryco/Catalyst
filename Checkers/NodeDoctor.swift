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
        
        do {
            let npmRootResult = try await AsyncProcessRunner.shared.run(command: "npm root -g")
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
            }
        } catch {
        }
        
        return issues
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
                let npmRootResult = try await AsyncProcessRunner.shared.run(command: "npm root -g")
                _ = npmRootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                
                return false
            } catch {
                return false
            }
        }
        return false
    }
}
