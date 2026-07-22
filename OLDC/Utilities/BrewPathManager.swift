import Foundation

/// Centralized manager for determining and providing Homebrew installation paths.
///
/// `BrewPathManager` resolves the correct binary and prefix paths for Homebrew,
/// abstracting differences between Apple Silicon and Intel-based Mac architectures.
final class BrewPathManager: @unchecked Sendable {
    /// The shared singleton instance.
    static let shared = BrewPathManager()
    
    private var _brewPath: String
    private var _homebrewPrefix: String
    private let lock = NSLock()
    
    private var initTask: Task<Void, Never>?
    
    /// The detected path to the Homebrew binary executable.
    var brewPath: String {
        get async {
            await ensureInitialized()
            return lock.withLock { _brewPath }
        }
    }
    
    /// The root prefix directory of the Homebrew installation.
    var homebrewPrefix: String {
        get async {
            await ensureInitialized()
            return lock.withLock { _homebrewPrefix }
        }
    }
    
    /// The hardware architecture of the host machine.
    let architecture: Architecture
    
    /// Represents the hardware architecture type.
    enum Architecture {
        /// Apple Silicon (ARM64) architecture.
        case appleSilicon
        /// Intel (x86_64) architecture.
        case intel
        /// An unknown or undetermined architecture.
        case unknown
    }
    
    private init() {
        #if arch(arm64)
        self.architecture = .appleSilicon
        #elseif arch(x86_64)
        self.architecture = .intel
        #else
        self.architecture = .unknown
        #endif
        
        let defaultPrefix: String
        let defaultBrewPath: String
        
        switch self.architecture {
        case .appleSilicon:
            defaultPrefix = "/opt/homebrew"
            defaultBrewPath = "/opt/homebrew/bin/brew"
        case .intel:
            defaultPrefix = "/usr/local"
            defaultBrewPath = "/usr/local/bin/brew"
        case .unknown:
            defaultPrefix = "/opt/homebrew"
            defaultBrewPath = "/opt/homebrew/bin/brew"
        }
        
        self._homebrewPrefix = defaultPrefix
        self._brewPath = defaultBrewPath
        
        self.initTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.resolveBrewPathAsync()
        }
    }
    
    deinit {
        initTask?.cancel()
    }
    
    /// Ensures that asynchronous path resolution forms are complete.
    func ensureInitialized() async {
        _ = await initTask?.result
    }
    
    private func resolveBrewPathAsync() async {
        let standardPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        
        for path in standardPaths {
            if FileManager.default.fileExists(atPath: path) {
                self.updatePaths(brewPath: path)
                return
            }
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["brew"]
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    self.updatePaths(brewPath: output)
                }
            }
        } catch {
        }
    }
    
    private func updatePaths(brewPath: String) {
        lock.lock()
        defer { lock.unlock() }
        
        self._brewPath = brewPath
        let url = URL(fileURLWithPath: brewPath)
        self._homebrewPrefix = url.deletingLastPathComponent().deletingLastPathComponent().path
    }
    
    /// Resolves the absolute path for a specific Homebrew binary.
    ///
    /// - Parameter binary: The name of the binary.
    /// - Returns: The absolute path string.
    func binPath(_ binary: String) async -> String {
        return "\(await homebrewPrefix)/bin/\(binary)"
    }
    
    /// The path to the Homebrew Cellar directory.
    var cellarPath: String {
        get async {
            return "\(await homebrewPrefix)/Cellar"
        }
    }
    
    /// The path to the Homebrew Caskroom directory.
    var caskroomPath: String {
        get async {
            return "\(await homebrewPrefix)/Caskroom"
        }
    }
    
    /// The path to the Homebrew cache directory.
    var cachePath: String {
        return "\(NSHomeDirectory())/Library/Caches/Homebrew"
    }
    
    /// A Boolean value indicating whether Homebrew is installed.
    var isInstalled: Bool {
        get async {
            FileManager.default.fileExists(atPath: await brewPath)
        }
    }
    
    /// A human-readable description of the system architecture.
    var architectureDescription: String {
        switch architecture {
        case .appleSilicon:
            return "Apple Silicon (ARM64)"
        case .intel:
            return "Intel (x86_64)"
        case .unknown:
            return "Unknown"
        }
    }
    
    /// Represents a valid Python executable installed by Homebrew.
    struct BrewPython: Identifiable, Hashable {
        /// A unique identifier for the instance.
        let id = UUID()
        /// The decoded Python semantic version string.
        let version: String
        /// The absolute executable path.
        let path: String
        
        /// A formatted string suitable for UI display.
        var displayName: String {
            "Python \(version) (Homebrew)"
        }
    }
    
    /// Scans the resolved Homebrew binary directory for installed Python runtimes.
    ///
    /// - Returns: An array of `BrewPython` instances.
    func getInstalledPythons() async -> [BrewPython] {
        await ensureInitialized()
        
        let prefix = lock.withLock { _homebrewPrefix }
        
        return await Task.detached(priority: .userInitiated) {
            let binURL = URL(fileURLWithPath: "\(prefix)/bin")
            var pythons: [BrewPython] = []
            
            do {
                let files = try FileManager.default.contentsOfDirectory(at: binURL, includingPropertiesForKeys: nil)
                let regex = try NSRegularExpression(pattern: "^python3\\.\\d+$")
                
                for file in files {
                    let filename = file.lastPathComponent
                    let range = NSRange(location: 0, length: filename.utf16.count)
                    
                    if regex.firstMatch(in: filename, options: [], range: range) != nil {
                        let version = filename.replacingOccurrences(of: "python", with: "")
                        pythons.append(BrewPython(version: version, path: file.path))
                    }
                }
            } catch {
                Logger.shared.log("⚠️ Error scanning for Brew Pythons: \(error.localizedDescription)")
            }
            
            return pythons.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        }.value
    }
}

fileprivate extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
