import Foundation
import Combine
import SwiftUI

struct GhostProcess: Identifiable, Equatable, Sendable {
    let id = UUID()
    let pid: Int
    let name: String
    let port: Int
    let icon: String // Emoji or SF Symbol
    
    // Helper to get a nice display name
    var displayName: String {
        name.isEmpty || name == "Unknown" ? "Process \(pid)" : name
    }
}

@MainActor
final class GhostBusterViewModel: ObservableObject {
    @Published var ghosts: [GhostProcess] = []
    @Published var isScanning = false
    @Published var lastScanTime: Date?
    
    // Safety First: Absolute blocklist for critical system/app components
    private let blockedProcesses = [
        "ControlCenter", "loginwindow", "launchd", "dock", "Finder",
        "Antigravity", "Catalyst", "Xcode", "Simulator", "SourceKitService",
        "gopls", "dart", "language-server", "copilot-agent", "ssh-agent"
    ]
    
    // Strict Allowlist: Only show processes matching these keywords
    private let allowedDevKeywords = [
        "python", "node", "java", "ruby", "go", "php",             // Runtimes
        "docker", "postgres", "redis", "mongo", "mysql", "mariadb", // Infrastructure
        "http-server", "live-server", "uvicorn", "gunicorn",        // Servers
        "jupyter", "notebook", "gradio", "streamlit",               // Data Science
        "react", "vite", "next", "nuxt", "angular", "vue",          // Frontend CLI
        "ollama", "llm", "rails", "spring", "flask", "django"       // Frameworks/AI
    ]
    
    private let logger = Logger.shared

    /// Lowercased alphanumeric tokens of a command's basename, for whole-token
    /// allow/blocklist matching (e.g. "com.docker.backend" → {com, docker, backend},
    /// "google-chrome-helper" → {google, chrome, helper}).
    static func commandTokens(_ command: String) -> Set<String> {
        let base = (command as NSString).lastPathComponent.lowercased()
        return Set(base.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    func scan() async {
        isScanning = true
        var foundGhosts: [GhostProcess] = []
        
        logger.log("👻 Ghost Buster: Smart Scanning all ports via lsof -F...")
        
        do {
            // Run lsof with -F for machine-readable output
            // p = PID, c = command, n = name (port)
            let result = try await AsyncProcessRunner.shared.run(command: "lsof -nP -iTCP -sTCP:LISTEN -F cpn +c 0")
            
            if result.succeeded {
                let lines = result.stdout.components(separatedBy: .newlines)
                
                var currentPID: Int?
                var currentCommand: String?
                
                for line in lines {
                    guard let firstChar = line.first else { continue }
                    let content = String(line.dropFirst())
                    
                    switch firstChar {
                    case "p":
                        // New Process Block
                        currentPID = Int(content)
                        currentCommand = nil // Reset command for new PID
                        
                    case "c":
                        // Command Name
                        currentCommand = content
                        
                    case "n":
                        // Port/Address Info (e.g. *:8000 or 127.0.0.1:8000)
                        guard let pid = currentPID, let cmd = currentCommand else { continue }
                        
                        // Parse port from "n*:8000" -> content="*:8000"
                        let portString = content.components(separatedBy: ":").last ?? ""
                        if let port = Int(portString) {
                            
                            // Tokenize the command basename so matches are on whole
                            // tokens, not loose substrings. Substring matching made
                            // "dock" block "docker", "go"/"mongo" allow
                            // "google-chrome-helper", and "Catalyst" block anything
                            // containing that text. Token match fixes both directions.
                            let cmdTokens = Self.commandTokens(cmd)

                            // 1. Check Blocklist (for safety)
                            if blockedProcesses.contains(where: { cmdTokens.contains($0.lowercased()) }) { continue }

                            // 2. Check Allowlist (Strict Mode)
                            let isDevProcess = allowedDevKeywords.contains(where: { cmdTokens.contains($0) })
                            
                            // Also allow generic "main" or "server" if on a targeted common port
                            // (e.g. a compiled Go binary named "server" running on 8080)
                            let isCommonDevPort = [3000, 8000, 8080, 5000].contains(port)
                            
                            if !isDevProcess && !isCommonDevPort { continue }
                            
                            // Deduplicate
                            if foundGhosts.contains(where: { $0.pid == pid && $0.port == port }) { continue }
                            
                            let ghost = GhostProcess(
                                pid: pid,
                                name: cmd,
                                port: port,
                                icon: determineIcon(for: cmd, port: port)
                            )
                            foundGhosts.append(ghost)
                        }
                        
                    default:
                        break
                    }
                }
            }
        } catch {
            logger.log("❌ Smart Scan failed: \(error.localizedDescription)")
        }
        
        self.ghosts = foundGhosts.sorted { $0.port < $1.port }
        self.lastScanTime = Date()
        self.isScanning = false
        
        if ghosts.isEmpty {
            logger.log("👻 Ghost Buster: No ghosts found.")
        } else {
            logger.log("👻 Ghost Buster: Found \(ghosts.count) active processes.")
        }
    }
    
    // Legacy single port check removed

    
    func killProcess(_ process: GhostProcess) async {
        logger.log("👻 Killing process \(process.pid) (\(process.name))...")
        
        let success = await killWithRetry(ghost: process)
        
        if success {
            logger.log("✅ Killed process \(process.pid)")
            withAnimation {
                self.ghosts.removeAll { $0.id == process.id }
            }
        } else {
            logger.log("❌ Failed to kill process \(process.pid)")
        }
        
        // Brief delay before re-scan to allow system to reclaim ports
        try? await Task.sleep(for: .milliseconds(500))
        await scan()
    }
    
    func killAllGhosts() async {
        guard !ghosts.isEmpty else { return }
        logger.log("👻 Nucleating all ghosts...")
        
        // Create a copy to iterate safely
        let targets = ghosts

        // Parallel kill, collecting which ones were *verified* killed.
        let killedIDs: [UUID] = await withTaskGroup(of: (UUID, Bool).self) { group in
            for ghost in targets {
                group.addTask { (ghost.id, await self.killWithRetry(ghost: ghost)) }
            }
            var killed: [UUID] = []
            for await (id, success) in group where success { killed.append(id) }
            return killed
        }

        // Remove only verified kills — consistent with single-kill (no optimistic
        // wipe that makes failed kills momentarily vanish and reappear).
        withAnimation {
            self.ghosts.removeAll { killedIDs.contains($0.id) }
        }

        logger.log("✅ Ghost Buster: killed \(killedIDs.count)/\(targets.count).")

        // Verification scan reconciles any that survived (e.g. root-owned).
        try? await Task.sleep(for: .seconds(1))
        await scan()
    }
    
    /// Confirms the PID still maps to the command+port we scanned, guarding
    /// against PID reuse between scan and kill. The OS can recycle a PID on a
    /// busy machine, so killing a cached PID blindly risks signalling an
    /// unrelated (possibly important) process.
    private func pidStillMatches(_ ghost: GhostProcess) async -> Bool {
        do {
            let result = try await AsyncProcessRunner.shared.run(
                command: "lsof -nP -iTCP:\(ghost.port) -sTCP:LISTEN -a -p \(ghost.pid) -F cpn +c 0"
            )
            guard result.succeeded else { return false }
            let lines = result.stdout.components(separatedBy: .newlines)
            let pidMatches = lines.contains("p\(ghost.pid)")
            let cmdMatches = lines.contains { $0.hasPrefix("c") && String($0.dropFirst()) == ghost.name }
            return pidMatches && cmdMatches
        } catch {
            return false
        }
    }

    private func killWithRetry(ghost: GhostProcess, retries: Int = 3) async -> Bool {
        let pid = ghost.pid
        guard pid > 0 else {
            logger.log("⚠️ Invalid PID: \(pid), skipping kill")
            return false
        }

        // Re-verify the target right before killing. If the PID no longer maps
        // to the same process/port, it was likely recycled — do not kill.
        guard await pidStillMatches(ghost) else {
            logger.log("⚠️ PID \(pid) no longer matches \(ghost.name):\(ghost.port) — skipping (possible PID reuse).")
            return false
        }

        for attempt in 1...retries {
            // Try SIGTERM first (15), then SIGKILL (9)
            let signal = attempt == 1 ? "-15" : "-9"
            do {
                let result = try await AsyncProcessRunner.shared.run(command: "kill \(signal) \(pid)")
                
                // Verify if it's gone
                if result.succeeded {
                    // Check if still exists
                    let check = try await AsyncProcessRunner.shared.run(command: "ps -p \(pid)")
                    if !check.succeeded {
                        return true // Gone
                    }
                }
            } catch {
                logger.log("⚠️ Attempt \(attempt) failed for PID \(pid): \(error.localizedDescription)")
            }
            // Wait a bit before retry/forcing
            try? await Task.sleep(for: .milliseconds(200))
        }
        // Survived SIGTERM+SIGKILL — almost always a root-owned listener that
        // needs elevated rights. (Routing through PrivilegesService is a P4 idea.)
        logger.log("❌ Could not kill \(ghost.name) (PID \(pid)) — it may be running as root and require elevated privileges.")
        return false
    }
    
    private func determineIcon(for name: String, port: Int) -> String {
        let n = name.lowercased()
        if n.contains("node") { return "hexagon.fill" } // Node
        if n.contains("python") { return "ladybug.fill" } // Python
        if n.contains("java") { return "cup.and.saucer.fill" } // Java
        if n.contains("ruby") { return "diamond.fill" } // Ruby
        if n.contains("docker") || n.contains("com.docker") { return "shippingbox.fill" } // Docker
        if n.contains("postgres") { return "cylinder.split.1x2.fill" } // Postgres
        if n.contains("redis") { return "server.rack" } // Redis
        if n.contains("mongo") { return "leaf.fill" } // Mongo
        if n.contains("ollama") { return "brain.head.profile" } // Ollama
        return "gearshape.fill" // Generic
    }
}
