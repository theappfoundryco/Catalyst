import Foundation

/// A diagnostic checker validating the user's primary shell configuration structures.
///
/// Ensures Catalyst is sourced appropriately and checks for syntax errors in dotfiles.
struct ShellIntegrityCheck: Doctor {
    var category: HealthCategory { .shell }
    private let logger = Logger.shared
    
    /// Inspects the primary zsh configuration for presence of the Catalyst hooks and valid syntax.
    ///
    /// - Returns: An array of `HealthIssue` denoting syntax errors or missing configurations.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let configManager = ShellConfigManager.shared
        
        if let zshrc = configManager.readMainConfig() {
            if !zshrc.contains(".zshrc_catalyst") {
                issues.append(HealthIssue(
                    category: .shell,
                    title: "Catalyst Config Not Sourced",
                    description: "Your ~/.zshrc file does not load the Catalyst configuration.",
                    severity: .critical,
                    autoFixAvailable: true,
                    fixID: .shellConfigNotSourced
                ))
            }
        } else {
            issues.append(HealthIssue(
                category: .shell,
                title: "Missing .zshrc",
                description: "You do not have a .zshrc file in your home directory.",
                severity: .warning,
                autoFixAvailable: true,
                fixID: .shellConfigNotSourced
            ))
        }
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: "zsh -n ~/.zshrc")
            if !result.succeeded {
                issues.append(HealthIssue(
                    category: .shell,
                    title: "Shell Syntax Errors",
                    description: "Your .zshrc file contains syntax errors: \(result.stderr)",
                    severity: .warning,
                    autoFixAvailable: false
                ))
            }
        } catch {
             issues.append(HealthIssue(
                category: .shell,
                title: "Syntax Check Failed",
                description: "Could not verify shell syntax: \(error.localizedDescription)",
                severity: .warning,
                autoFixAvailable: false
            ))
        }
        
        return issues
    }
    
    /// Resolves shell integrity issues by injecting required Catalyst configurations.
    ///
    /// - Parameter issue: The shell configuration failure.
    /// - Returns: A boolean tracking if the `.zshrc` hook injection succeeded.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .shellConfigNotSourced {
            return ShellConfigManager.shared.ensureCatalystSourced()
        }
        return false
    }
}
