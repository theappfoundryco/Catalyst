import Foundation

/// A diagnostic check determining the presence and validity of Apple's core compiling tools.
///
/// Ensures the Xcode Command Line Tools are correctly installed and accessible by local build pipelines.
struct ToolChainCheck: Doctor {
    var category: HealthCategory { .tools }


    /// Evaluates the `xcode-select` paths and fallback directory structures to confirm installation.
    ///
    /// - Returns: An array of `HealthIssue` if the command line tools are missing or damaged.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        do {
            let xcode = try await AsyncProcessRunner.shared.run(command: "xcode-select -p")
            if !xcode.succeeded {
                let cltPath = "/Library/Developer/CommandLineTools"
                let xcodePath = "/Applications/Xcode.app/Contents/Developer"
                
                let cltExists = FileManager.default.fileExists(atPath: cltPath)
                let xcodeExists = FileManager.default.fileExists(atPath: xcodePath)
                
                if !cltExists && !xcodeExists {
                    issues.append(HealthIssue(
                        category: .tools,
                        title: "Missing Xcode Tools",
                        description: "Xcode Command Line Tools are required for compiling many Python packages.",
                        severity: .critical,
                        autoFixAvailable: true,
                        fixID: .missingXcodeTools
                    ))
                }
            }
        } catch {
             issues.append(HealthIssue(
                category: .tools,
                title: "Xcode Check Failed",
                description: "Could not check Xcode status: \(error.localizedDescription)",
                severity: .warning,
                autoFixAvailable: false
            ))
        }
        
        return issues
    }
    
    /// Triggers the native macOS Command Line Tools installation dialog if tools are missing.
    ///
    /// - Parameter issue: The toolchain absence incident to resolve.
    /// - Returns: A boolean indicating if the automated installation sequence started successfully.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .missingXcodeTools {
            do {
                let result = try await AsyncProcessRunner.shared.run(command: "xcode-select --install")
                return result.succeeded || result.stderr.contains("already installed")
            } catch {
                return false
            }
        }
        return false
    }
}
