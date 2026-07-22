import Foundation

/// A diagnostic module evaluating the underlying hardware and translation abstraction layers of the execution environment.
///
/// This checker identifies if the application is running via Rosetta 2 translation or if legacy Intel-specific Homebrew paths are being used on Apple Silicon.
struct ArchitectureDoctor: Doctor {
    var category: HealthCategory { .architecture }


    /// Executes the primary scanning routine validating environmental hardware translation and package manager allocations.
    ///
    /// **Flow:**
    /// 1. Queries `sysctl` for Apple Silicon indicators (`hw.optional.arm64`).
    /// 2. Checks translation flags indicating Rosetta 2 activity.
    /// 3. Cross-references the active Homebrew path to detect x86 prefixes on ARM chips.
    ///
    /// - Returns: An array of `HealthIssue` objects representing detected architectural conflicts or performance concerns.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        let isAppleSilicon = await checkForAppleSilicon()
        let isRosetta = await checkForRosetta()
        
        if isRosetta {
             issues.append(HealthIssue(
                category: .architecture,
                title: "App Running via Rosetta",
                description: "Catalyst is running in x86_64 compatibility mode on Apple Silicon. This reduces performance and causes binary compatibility issues.",
                severity: .critical,
                autoFixAvailable: false
            ))
        } else if isAppleSilicon {
            let brewPath = BrewPathManager.shared.brewPath
            if brewPath.hasPrefix("/usr/local") {
                 issues.append(HealthIssue(
                    category: .architecture,
                    title: "Legacy Homebrew Setup",
                    description: "You are attempting to use the Intel version of Homebrew (/usr/local) on an Apple Silicon Mac. This will cause architecture conflicts.",
                    severity: .warning,
                    autoFixAvailable: false
                ))
            }
        }
        
        return issues
    }
    
    /// Queries `sysctl` to determine if the host CPU is Apple Silicon (arm64).
    private func checkForAppleSilicon() async -> Bool {
        let res = try? await AsyncProcessRunner.shared.run(command: "sysctl -n hw.optional.arm64")
        return res?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
    
    /// Queries `sysctl` to determine if the active process is currently running under Rosetta 2 translation.
    private func checkForRosetta() async -> Bool {
        let res = try? await AsyncProcessRunner.shared.run(command: "sysctl -n sysctl.proc_translated")
        return res?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }
    
    /// Attempts to programmatically remediate architectural discrepancies.
    ///
    /// **Gotchas:**
    /// Architectural boundaries are immutable at runtime. Fixing them typically requires the user to reinstall binaries or switch terminal environments entirely.
    ///
    /// - Parameter issue: The specific architectural issue requested for remediation.
    /// - Returns: A boolean indicating whether the auto-fix was successful (always `false` for architectural issues).
    func fix(_ issue: HealthIssue) async -> Bool {
        return false
    }
}
