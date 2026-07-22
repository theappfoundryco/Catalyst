import Foundation

/// An observational component measuring local Docker environment optimization values intelligently.
///
/// This checker scans for the presence of Docker and reports on resource drains like zombie containers and dangling images.
struct ContainerDoctor: Doctor, AvailabilityCheckable {
    var category: HealthCategory { .container }


    /// Checks fundamental Docker application execution bin availability locally.
    ///
    /// - Returns: A boolean indicating if a Docker installation is present on the system.
    func checkAvailability() async -> Bool {
        let dockerAppExists = FileManager.default.fileExists(atPath: "/Applications/Docker.app")
        let dockerBinExists = FileManager.default.fileExists(atPath: "/usr/local/bin/docker") || 
                              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/docker")
        
        return dockerAppExists || dockerBinExists
    }
    
    /// Primary execution routine that evaluates the local Docker daemon status, exited containers, and dangling images.
    ///
    /// **Flow:**
    /// 1. Confirms Docker app/CLI components exist on disk.
    /// 2. Pings the daemon (`docker info`) to verify active background readiness.
    /// 3. Queries counts for zombie containers and dangling metadata to identify cruft.
    ///
    /// - Returns: An array of `HealthIssue` representing Docker-related hygiene problems.
    func run() async -> [HealthIssue] {
        var issues: [HealthIssue] = []
        
        let dockerAppExists = FileManager.default.fileExists(atPath: "/Applications/Docker.app")
        let dockerBinExists = FileManager.default.fileExists(atPath: "/usr/local/bin/docker") || 
                              FileManager.default.fileExists(atPath: "/opt/homebrew/bin/docker")
        
        if !dockerAppExists && !dockerBinExists {
            return []
        }

        do {
            let info = try await AsyncProcessRunner.shared.run(command: "docker info --format '{{.ServerVersion}}'")
            if !info.succeeded {
                 issues.append(HealthIssue(
                    category: .container,
                    title: "Docker Not Running",
                    description: "Docker is installed but the daemon is not reachable.",
                    severity: .info,
                    autoFixAvailable: false
                ))
            } else {
                let zombies = try await AsyncProcessRunner.shared.run(command: "docker ps -a -f status=exited -q")
                let zombieCount = zombies.stdout.components(separatedBy: .newlines).filter({ !$0.isEmpty }).count
                
                if zombieCount > 5 {
                    issues.append(HealthIssue(
                       category: .container,
                       title: "Zombie Containers (\(zombieCount))",
                       description: "You have \(zombieCount) stopped containers taking up space.",
                       severity: .info,
                       autoFixAvailable: true,
                       fixID: .pruneZombieContainers
                   ))
                }
                
                let images = try await AsyncProcessRunner.shared.run(command: "docker images -f dangling=true -q")
                let imageCount = images.stdout.components(separatedBy: .newlines).filter({ !$0.isEmpty }).count
                
                if imageCount > 2 {
                    issues.append(HealthIssue(
                       category: .container,
                       title: "Dangling Images (\(imageCount))",
                       description: "Unused <none> images cluttering your disk.",
                       severity: .info,
                       autoFixAvailable: true,
                       fixID: .pruneDanglingImages
                   ))
                }
            }
        } catch {
        }
        
        return issues
    }
    
    /// Attempts to programmatically remediate Docker-related hygiene issues.
    ///
    /// **Gotchas:**
    /// The Docker daemon must be actively running and accessible without `sudo`.
    ///
    /// - Parameter issue: The Docker issue to resolve, such as zombie containers or dangling images.
    /// - Returns: A boolean indicating whether the prune operation was successful.
    func fix(_ issue: HealthIssue) async -> Bool {
        if issue.fixID == .pruneZombieContainers {
            let result = try? await AsyncProcessRunner.shared.run(command: "docker container prune -f")
            return result?.succeeded ?? false
        }
        if issue.fixID == .pruneDanglingImages {
             let result = try? await AsyncProcessRunner.shared.run(command: "docker image prune -f")
             return result?.succeeded ?? false
        }
        return false
    }
}
