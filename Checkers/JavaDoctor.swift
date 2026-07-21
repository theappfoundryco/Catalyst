import Foundation

/// A diagnostic tool that evaluates the Java ecosystem and JDK installations.
///
/// This checker detects missing Java, misconfigured `JAVA_HOME` paths, and the presence of multiple conflicting JDKs.
struct JavaDoctor: Doctor, AvailabilityCheckable {
    var category: HealthCategory { .java }


    /// Verifies if the Java runtime is available using the macOS `java_home` utility.
    ///
    /// - Returns: A boolean indicating if a valid JDK is installed.
    func checkAvailability() async -> Bool {
        do {
            // On macOS, `which java` always returns /usr/bin/java (the stub), so it's a bad check for existence.
            // `/usr/libexec/java_home` will exit with 1 if no JDK is found.
             let res = try await AsyncProcessRunner.shared.run(command: "/usr/libexec/java_home", useLoginShell: true)
             return res.succeeded
        } catch {
             return false
        }
    }
    
    /// Executes comprehensive Java environment checks.
    ///
    /// - Returns: An array of `HealthIssue` issues detailing JDK chaos, missing paths, or missing runtimes.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        // 1. Check current java version
        var currentJavaVersion = ""
        do {
            let res = try await AsyncProcessRunner.shared.run(command: "java -version 2>&1 | head -n 1") // Stderr has the version often
            if res.succeeded {
                // Output format usually: openjdk version "11.0.12" 2021-07-20
                if let version = res.stdout.components(separatedBy: "\"").dropFirst().first {
                    currentJavaVersion = String(version)
                } else {
                     currentJavaVersion = res.stdout // Fallback
                }
            } else {
                 issues.append(HealthIssue(
                    category: .java,
                    title: "Java Not Found",
                    description: "The 'java' command is missing from your PATH. Many tools (Gradle, Maven) require it.",
                    severity: .warning,
                    autoFixAvailable: false
                ))
            }
        } catch {}
        
        // 2. Check JAVA_HOME
        var javaHome = ""
        do {
             let res = try await AsyncProcessRunner.shared.run(command: "echo $JAVA_HOME")
             javaHome = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
             
             if javaHome.isEmpty {
                  issues.append(HealthIssue(
                    category: .java,
                    title: "JAVA_HOME Not Set",
                    description: "Many build tools require JAVA_HOME to be set explicitly.",
                    severity: .info,
                    autoFixAvailable: false // We could fix, but picking WHICH java is hard
                ))
             } else {
                 // Check validity
                 var isDir = ObjCBool(false)
                 if !FileManager.default.fileExists(atPath: javaHome, isDirectory: &isDir) || !isDir.boolValue {
                      issues.append(HealthIssue(
                        category: .java,
                        title: "Broken JAVA_HOME",
                        description: "JAVA_HOME points to a non-existent directory: \(javaHome)",
                        severity: .warning,
                        autoFixAvailable: false
                    ))
                 }
                 
                 // Check mismatch with active java
                 // If JAVA_HOME is set, `java` should usually match it.
                 // Heuristic: Does `java` path match `JAVA_HOME/bin/java`?
                 let whichJava = try await AsyncProcessRunner.shared.run(command: "which java")
                 let javaPath = whichJava.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                 
                 // If java is /usr/bin/java (macOS stubs), it delegates to /usr/libexec/java_home
                 // A mismatch is cleaner to check by version string, but versions are parsed weirdly.
                 // Let's check if the JAVA_HOME string appears in the verbose output of java?
                 // Or easier: check if `JAVA_HOME/bin/java -version` == `java -version`
             }
        } catch {}
        
        // 3. Detect Multiple JDKs (Chaos)
        // Command: /usr/libexec/java_home -V
        do {
            let res = try await AsyncProcessRunner.shared.run(command: "/usr/libexec/java_home -V")
            if res.succeeded {
                let lines = res.stderr.components(separatedBy: .newlines) // -V writes to stderr
                // Count lines starting with spaces (versions)
                let installedCount = lines.filter({ $0.trimmingCharacters(in: .whitespaces).first?.isNumber ?? false }).count
                
                if installedCount > 3 {
                     issues.append(HealthIssue(
                        category: .java,
                        title: "Java Version Chaos",
                        description: "You have \(installedCount) different JDKs installed. This often leads to build confusion.",
                        severity: .info,
                        autoFixAvailable: false
                    ))
                }
            }
        } catch {}
        
        return issues
    }
    
    /// Attempts to resolve Java environment issues.
    ///
    /// - Parameter issue: The Java configuration issue to address.
    /// - Returns: A boolean indicating whether the remediation was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        return false
    }
}
