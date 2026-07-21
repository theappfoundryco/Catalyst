import Foundation

/// A data structure encapsulating the identity and core characteristics of a recognized codebase repository.
struct ProjectMetadata {
    /// The localized folder name holding the project contents.
    let name: String
    /// The absolute file path referencing the root of the project structure.
    let path: URL
    /// Identifies whether the project utilizes a standard `requirements.txt` file.
    let hasRequirementsTxt: Bool
    /// Identifies whether the project establishes dependencies strictly via a `Pipfile`.
    let hasPipfile: Bool
    /// Identifies whether the project establishes dependencies natively via `pyproject.toml`.
    let hasPyProjectToml: Bool
    /// Identifies whether the repository leans on standard `setup.py` module distribution strategies.
    let hasSetupPy: Bool
    /// The version constraint indicated inside `.python-version` or `runtime.txt`.
    let recommendedPythonVersion: String?
    /// An aggregated array of identified package distributions specified in the environment schema.
    let detectedDependencies: [String]
    
    /// Indicates whether the specified directory is successfully tracking commits using Git.
    let isGitRepo: Bool
    /// Determines whether the repository provides an active `.gitignore` schema.
    let hasGitignore: Bool
    /// Evaluates if typical virtual environment folders are masked successfully from index inclusion.
    let isVenvIgnored: Bool
    /// Static, one-shot Git facts (branch, counts, remote). `nil` when not a repo.
    let gitInfo: GitRepoInfo?

    /// Evaluates whether the identified repository lacks any established dependency tracking files.
    var isEmpty: Bool {
        !hasRequirementsTxt && !hasPipfile && !hasPyProjectToml && !hasSetupPy
    }
}

/// One-off, static snapshot of a Git repository captured at scan time. Deliberately
/// limited to fixed facts (no PRs, working-tree changes, or commit history), so the
/// import sheet can show them without any live/refreshing state.
struct GitRepoInfo {
    /// Checked-out branch name, or `nil` when in detached-HEAD state.
    let currentBranch: String?
    /// Number of local branches.
    let localBranchCount: Int
    /// Number of tags.
    let tagCount: Int
    /// `origin` fetch URL, if a remote is configured.
    let remoteURL: String?
}

/// A directory traversal service extracting configuration metadata and environmental hints from codebase roots.
actor ProjectScannerService {
    static let shared = ProjectScannerService()
    private let logger = Logger.shared
    
    private init() {}
    
    /// Executes a static analysis sequence across the indicated path to infer build mechanics and python specifications.
    ///
    /// - Parameter url: The absolute URL locating the target project root.
    /// - Returns: A `ProjectMetadata` payload describing dependency and runtime architectures.
    func scan(url: URL) async -> ProjectMetadata {
        logger.log("🔍 Scanning project at \(url.path)")
        
        let fileManager = FileManager.default
        
        let hasReqs = fileManager.fileExists(atPath: url.appendingPathComponent("requirements.txt").path)
        let hasPipfile = fileManager.fileExists(atPath: url.appendingPathComponent("Pipfile").path)
        let hasPyProject = fileManager.fileExists(atPath: url.appendingPathComponent("pyproject.toml").path)
        let hasSetup = fileManager.fileExists(atPath: url.appendingPathComponent("setup.py").path)
        
        let isGitRepo = fileManager.fileExists(atPath: url.appendingPathComponent(".git").path)
        let gitignorePath = url.appendingPathComponent(".gitignore")
        let hasGitignore = fileManager.fileExists(atPath: gitignorePath.path)
        
        var isVenvIgnored = false
        if hasGitignore, let content = try? String(contentsOf: gitignorePath, encoding: .utf8) {
            isVenvIgnored = content.contains(".venv") || content.contains("venv")
        }
        
        var pythonVersion: String? = nil
        
        let pyVersionUrl = url.appendingPathComponent(".python-version")
        if let content = try? String(contentsOf: pyVersionUrl, encoding: .utf8) {
            pythonVersion = content.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.log("📄 Found .python-version: \(pythonVersion ?? "")")
        }
        
        if pythonVersion == nil {
            let runtimeUrl = url.appendingPathComponent("runtime.txt")
            if let content = try? String(contentsOf: runtimeUrl, encoding: .utf8) {
                let raw = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.starts(with: "python-") {
                    pythonVersion = String(raw.dropFirst(7))
                }
            }
        }
        
        let gitInfo = isGitRepo ? await gatherGitInfo(at: url) : nil

        return ProjectMetadata(
            name: url.lastPathComponent,
            path: url,
            hasRequirementsTxt: hasReqs,
            hasPipfile: hasPipfile,
            hasPyProjectToml: hasPyProject,
            hasSetupPy: hasSetup,
            recommendedPythonVersion: pythonVersion,
            detectedDependencies: [],
            isGitRepo: isGitRepo,
            hasGitignore: hasGitignore,
            isVenvIgnored: isVenvIgnored,
            gitInfo: gitInfo
        )
    }

    /// Collect fixed Git facts in one pass. Each subcommand is best-effort; a
    /// missing/failed value simply falls back to a sensible default so a brand
    /// new repo (no commits, no remote) still scans cleanly.
    private func gatherGitInfo(at url: URL) async -> GitRepoInfo {
        func git(_ args: String) async -> String? {
            let command = "git -C \(InputSanitizer.singleQuote(url.path)) \(args) 2>/dev/null"
            guard let result = try? await AsyncProcessRunner.shared.run(command: command),
                  result.succeeded else { return nil }
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        }

        let branchRaw = await git("rev-parse --abbrev-ref HEAD")
        let currentBranch = (branchRaw == "HEAD") ? nil : branchRaw  // "HEAD" == detached

        let localBranchCount = await git("branch --list")
            .map { $0.split(separator: "\n").filter { !$0.isEmpty }.count } ?? 0
        let tagCount = await git("tag")
            .map { $0.split(separator: "\n").filter { !$0.isEmpty }.count } ?? 0
        let remoteURL = await git("config --get remote.origin.url")

        logger.log("🌿 Git: branch=\(currentBranch ?? "detached"), branches=\(localBranchCount), tags=\(tagCount)")

        return GitRepoInfo(
            currentBranch: currentBranch,
            localBranchCount: localBranchCount,
            tagCount: tagCount,
            remoteURL: remoteURL
        )
    }
}
