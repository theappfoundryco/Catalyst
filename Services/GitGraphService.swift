import Foundation

/// A read-only, point-in-time summary of a local git repository.
///
/// Every field is **best-effort**: a missing or failed subcommand falls back to a
/// sensible default, so a brand-new repo (no commits, no remote, no upstream) still
/// summarizes cleanly. Mirrors the fact-gathering style of
/// `ProjectScannerService.GitRepoInfo`, extended with graph-relevant counts. Purely a
/// value type so it can cross the actor boundary to the `@MainActor` VM.
struct RepoSummary: Sendable, Equatable {
    /// Absolute path to the repository work-tree root.
    let path: String
    /// Last path component — used as the display name.
    let name: String
    /// Checked-out branch, or `nil` in detached-HEAD state.
    let currentBranch: String?
    /// Number of local branches.
    let localBranchCount: Int
    /// Number of tags.
    let tagCount: Int
    /// `origin` fetch URL, if a remote is configured.
    let remoteURL: String?
    /// Total commits reachable from all refs.
    let commitCount: Int
    /// Relative time of the most recent commit (e.g. "3 days ago"), if any.
    let lastCommitRelative: String?
    /// Commits ahead of the upstream; `nil` when no upstream is configured.
    let ahead: Int?
    /// Commits behind the upstream; `nil` when no upstream is configured.
    let behind: Int?
    /// Whether the work tree has uncommitted changes.
    let isDirty: Bool

    /// Branch name for display, resolving detached HEAD to a readable label.
    var displayBranch: String { currentBranch ?? "Detached HEAD" }
}

/// Errors surfaced while validating or loading a repository.
enum GitGraphError: LocalizedError, Sendable {
    case notARepository(String)

    var errorDescription: String? {
        switch self {
        case .notARepository(let path):
            return "\u{201C}\(URL(fileURLWithPath: path).lastPathComponent)\u{201D} is not a git repository."
        }
    }
}

/// A decoration on a commit — a branch, remote-tracking branch, tag, or HEAD.
struct GitRef: Sendable, Equatable, Identifiable {
    /// Identifies the topological significance of a graph node.
    enum Kind: Sendable { case head, branch, remoteBranch, tag }
    let name: String
    let kind: Kind
    var id: String { "\(kind)-\(name)" }
}

/// A single commit parsed from `git log`, with its parent edges and ref decorations.
/// A pure value type so it can cross the actor boundary to the `@MainActor` VM and the
/// pure layout engine.
struct GraphCommit: Sendable, Identifiable, Equatable {
    let hash: String
    let parents: [String]
    let authorName: String
    let authorEmail: String
    let date: Date
    let subject: String
    let refs: [GitRef]

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
}

/// Full detail for one commit (message + per-file change stats), for the detail panel.
struct CommitDetails: Sendable, Equatable {
    let hash: String
    let authorName: String
    let authorEmail: String
    let dateString: String
    let message: String
    let files: [FileChange]

    var shortHash: String { String(hash.prefix(10)) }

    /// Represents a single tracked file modification within a commit.
struct FileChange: Sendable, Equatable, Identifiable {
        let path: String
        let added: Int
        let removed: Int
        var id: String { path }
    }
}

/// Read-only git introspection for the Git Graph screen.
///
/// **Safety.** Every call is routed through `AsyncProcessRunner` off the main thread,
/// the repo path is single-quoted via `InputSanitizer`, and success is judged on exit
/// codes — never by string-scraping (`CODING_STANDARDS.md` 2.1–2.4). Nothing here writes to
/// the repository; it only reads (`log` / `rev-parse` / `rev-list` / `config` /
/// `status`), so it needs no privilege tier and no break-system-packages handling.
///
/// ```swift
/// let summary = try await GitGraphService.shared.summary(for: "/path/to/repo")
/// print("Commits: \(summary.commitCount)")
/// ```
actor GitGraphService {
    static let shared = GitGraphService()
    private let logger = Logger.shared
    private init() {}

    /// Extra git flags applied to every invocation.
    ///
    /// `core.fsmonitor=false` is critical: when a repo has fsmonitor enabled, `git`
    /// spawns a background `fsmonitor--daemon` that **inherits and holds our stdout
    /// pipe open**, so reading it to EOF never returns and the whole read hangs. `gc.auto=0`
    /// stops an invocation from kicking off background gc. Both keep probes fast and finite.
    private static let safeFlags = "-c core.fsmonitor=false -c gc.auto=0"

    /// Run a git subcommand inside `repoPath`, best-effort and time-bounded.
    ///
    /// Returns trimmed stdout, or `nil` when the command fails, is empty, or exceeds
    /// `timeoutSeconds`. `</dev/null` prevents git from ever blocking on input (e.g. a
    /// credential prompt); `2>/dev/null` swallows diagnostics; the timeout guarantees a
    /// single slow/stuck call can never hang the summary.
    /// - Parameters:
    ///   - args: The execution flags sent to the binary.
    ///   - repoPath: The targeted filesystem root defining the working directory.
    ///   - timeoutSeconds: The restrictive bound defining an execution limit.
    /// - Returns: The textual standard output block, or nil upon catastrophic failure.
    private func git(_ args: String, in repoPath: String, timeoutSeconds: Double = 6) async -> String? {
        let command = "git \(Self.safeFlags) -C \(InputSanitizer.singleQuote(repoPath)) \(args) </dev/null 2>/dev/null"
        return await Self.withTimeout(timeoutSeconds) {
            guard let result = try? await AsyncProcessRunner.shared.run(command: command),
                  result.succeeded else { return nil }
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return out.isEmpty ? nil : out
        }
    }

    /// Race an async string-producing operation against a timeout; returns `nil` if it
    /// doesn't finish in time. Cancels the loser. This is the safety net for a git call
    /// whose stdout pipe is held open by a lingering daemon — the read may never return,
    /// but the summary proceeds regardless.
    /// - Parameters:
    ///   - seconds: The requested duration before timeout termination.
    ///   - operation: The autonomous workload submitted to concurrency.
    /// - Returns: The resultant execution payload, or nil on exhaustion.
    private static func withTimeout(_ seconds: Double, _ operation: @escaping @Sendable () async -> String?) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    /// `true` when `path` is inside a git work tree.
    ///
    /// - Parameter path: The absolute directory path to verify.
    /// - Returns: True if `git rev-parse --is-inside-work-tree` confirms the location.
    func isRepository(_ path: String) async -> Bool {
        await git("rev-parse --is-inside-work-tree", in: path) == "true"
    }

    /// Build a read-only summary of the repository at `path`.
    ///
    /// **Flow:**
    /// 1. Validates the target is a repository, throwing if not.
    /// 2. Detaches 8 concurrent `git` probes (branch name, counts, dirty status, etc).
    /// 3. Awaits and maps the raw outputs into the structured `RepoSummary`.
    ///
    /// - Parameter path: Absolute path to the git workspace.
    /// - Throws: `GitGraphError.notARepository` when `path` is not a git work tree.
    /// - Returns: A hydrated ``RepoSummary``.
    func summary(for path: String) async throws -> RepoSummary {
        guard await isRepository(path) else {
            throw GitGraphError.notARepository(path)
        }

        /// Run every probe concurrently — total time is the slowest single call (each
        /// itself bounded by `git`'s timeout), not the sum. `status --porcelain` walks the
        /// whole work tree, so it gets a longer budget.
        ///
        /// **Rationale:** Asynchronous dispatch prevents UI thread starvation when rendering giant repositories like the Linux kernel.
        async let branchRawT = git("rev-parse --abbrev-ref HEAD", in: path)
        async let branchListT = git("branch --list", in: path)
        async let tagListT = git("tag", in: path)
        async let remoteURLT = git("config --get remote.origin.url", in: path)
        async let commitCountT = git("rev-list --all --count", in: path)
        async let lastRelT = git("log -1 --format=%cr", in: path)
        async let upstreamT = git("rev-list --left-right --count @{upstream}...HEAD", in: path)
        async let dirtyT = git("status --porcelain", in: path, timeoutSeconds: 10)

        let branchRaw = await branchRawT
        let currentBranch = (branchRaw == "HEAD") ? nil : branchRaw  // "HEAD" == detached

        let localBranchCount = (await branchListT)
            .map { $0.split(separator: "\n").filter { !$0.isEmpty }.count } ?? 0
        let tagCount = (await tagListT)
            .map { $0.split(separator: "\n").filter { !$0.isEmpty }.count } ?? 0
        let remoteURL = await remoteURLT

        let commitCount = (await commitCountT).flatMap { Int($0) } ?? 0
        let lastCommitRelative = await lastRelT

        /// Ahead/behind vs upstream — only when an upstream is configured.
        /// `--left-right --count A...HEAD` prints "<behind>\t<ahead>".
        ///
        /// **Gotchas:** Committing to an orphaned branch without an upstream causes the `...` operator to throw a fatal error; checking for upstream presence is strictly required.
        var ahead: Int? = nil
        var behind: Int? = nil
        if let counts = await upstreamT {
            let parts = counts.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .compactMap { Int($0) }
            if parts.count == 2 {
                behind = parts[0]
                ahead = parts[1]
            }
        }

        /// `status --porcelain` is empty (→ nil here) when the tree is clean.
        ///
        /// **Rationale:** Relying on the porcelain format guarantees a stable ABI output that won't suddenly break when a user updates their local Git version.
        let isDirty = await dirtyT != nil

        logger.log("🌿 GitGraph: \(URL(fileURLWithPath: path).lastPathComponent) branch=\(currentBranch ?? "detached") commits=\(commitCount) dirty=\(isDirty)")

        return RepoSummary(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            currentBranch: currentBranch,
            localBranchCount: localBranchCount,
            tagCount: tagCount,
            remoteURL: remoteURL,
            commitCount: commitCount,
            lastCommitRelative: lastCommitRelative,
            ahead: ahead,
            behind: behind,
            isDirty: isDirty
        )
    }

    // MARK: - Commit history (for the graph)

    /// Field separator emitted by `git log` (`%x1f`, ASCII unit separator). Chosen
    /// because git never emits it inside commit content, so parsing is unambiguous.
    private static let fieldSep = "\u{1f}"

    /// Read up to `limit` commits across **all** refs, in `--date-order`, for the graph.
    ///
    /// Returns `[]` on any failure (empty repo, no commits) rather than throwing, so the
    /// summary card can still show. Parsing is delimiter-based, never `--graph` ASCII.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the git workspace.
    ///   - options: Configuration governing scope, filters, and limits.
    /// - Returns: A parsed array of ``GraphCommit`` models.
    func commits(for path: String, options: GraphOptions) async -> [GraphCommit] {
        let fmt = ["%H", "%P", "%an", "%ae", "%ct", "%D", "%s"].joined(separator: "%x1f")

        /// Build the log invocation. Scope/order/merge/first-parent are safe literals;
        /// every user-supplied filter is single-quoted before it reaches the shell (2.2).
        ///
        /// **Gotchas:** Passing raw commit hashes without strict shell quoting allows malicious branch names to exploit the `AsyncProcessRunner` via command injection.
        var args = "log \(options.scope.refArgument) \(options.order.argument)"
        if options.hideMerges { args += " --no-merges" }
        if options.firstParent { args += " --first-parent" }
        if !options.authorFilter.isEmpty {
            args += " --author=\(InputSanitizer.singleQuote(options.authorFilter))"
        }
        if !options.sinceFilter.isEmpty {
            args += " --since=\(InputSanitizer.singleQuote(options.sinceFilter))"
        }
        if !options.untilFilter.isEmpty {
            args += " --until=\(InputSanitizer.singleQuote(options.untilFilter))"
        }
        args += " --max-count=\(options.limit.rawValue) --pretty=format:'\(fmt)'"
        if !options.pathFilter.isEmpty {
            args += " -- \(InputSanitizer.singleQuote(options.pathFilter))"
        }
        let command = "git \(Self.safeFlags) -C \(InputSanitizer.singleQuote(path)) \(args) </dev/null 2>/dev/null"
        /// Time-bounded (a huge history could be slow) and fsmonitor-safe like `git()`.
        ///
        /// **Rationale:** Enforces an absolute upper bound on log iteration so the Catalyst background scanner doesn't lock up memory indefinitely.
        let raw = await Self.withTimeout(20) {
            guard let result = try? await AsyncProcessRunner.shared.run(command: command),
                  result.succeeded else { return nil }
            return result.stdout
        }
        guard let raw, !raw.isEmpty else { return [] }
        return Self.parseLog(raw)
    }

    /// Full detail for one commit: metadata + message + per-file numstat. Read-only,
    /// time-bounded, fsmonitor-safe. Returns `nil` if the commit can't be read.
    ///
    /// - Parameters:
    ///   - hash: The full or abbreviated git commit SHA.
    ///   - path: Absolute path to the git workspace.
    /// - Returns: A populated ``CommitDetails`` struct or `nil` on probe timeout/failure.
    func details(for hash: String, in path: String) async -> CommitDetails? {
        let quoted = InputSanitizer.singleQuote(path)
        let h = InputSanitizer.singleQuote(hash)

        /// Metadata + full body. `%B` (raw body, multi-line) is last so it can't collide
        /// with the field separator.
        ///
        /// **Gotchas:** If the raw body appears anywhere except the final token, its embedded newlines will instantly shatter the strict line-based CSV parser.
        let metaFmt = ["%H", "%an", "%ae", "%ad", "%B"].joined(separator: "%x1f")
        let metaCmd = "git \(Self.safeFlags) -C \(quoted) show -s --date=format:'%Y-%m-%d %H:%M' --format='\(metaFmt)' \(h) </dev/null 2>/dev/null"
        guard let metaRaw = await Self.withTimeout(8, {
            guard let r = try? await AsyncProcessRunner.shared.run(command: metaCmd), r.succeeded else { return nil }
            return r.stdout
        }), !metaRaw.isEmpty else { return nil }

        let f = metaRaw.components(separatedBy: Self.fieldSep)
        guard f.count >= 5 else { return nil }
        let message = f[4].trimmingCharacters(in: .whitespacesAndNewlines)

        /// Per-file change counts: "<added>\t<removed>\t<path>" (added/removed = "-" for binary).
        ///
        /// **Rationale:** Pre-filtering binary diffs natively via Git's numstat prevents Catalyst from trying to allocate massive string buffers for compiled frameworks.
        let statCmd = "git \(Self.safeFlags) -C \(quoted) show --numstat --format='' \(h) </dev/null 2>/dev/null"
        let statRaw = await Self.withTimeout(10, {
            guard let r = try? await AsyncProcessRunner.shared.run(command: statCmd), r.succeeded else { return nil }
            return r.stdout
        }) ?? ""

        var files: [CommitDetails.FileChange] = []
        for line in statRaw.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            files.append(.init(
                path: parts[2...].joined(separator: "\t"),
                added: Int(parts[0]) ?? 0,
                removed: Int(parts[1]) ?? 0
            ))
        }

        return CommitDetails(hash: f[0], authorName: f[1], authorEmail: f[2],
                             dateString: f[3], message: message, files: files)
    }

    /// Parse the delimited `git log` output into commits. `nonisolated` + `static` so it
    /// is trivially unit-testable without the actor.
    ///
    /// - Parameter raw: The raw multi-line stdout from git.
    /// - Returns: Structured `GraphCommit` objects.
    static func parseLog(_ raw: String) -> [GraphCommit] {
        raw.split(separator: "\n", omittingEmptySubsequences: true).compactMap { lineSub in
            let fields = String(lineSub).components(separatedBy: fieldSep)
            guard fields.count >= 7 else { return nil }
            let parents = fields[1].split(separator: " ").map(String.init)
            let epoch = TimeInterval(fields[4]) ?? 0
            return GraphCommit(
                hash: fields[0],
                parents: parents,
                authorName: fields[2],
                authorEmail: fields[3],
                date: Date(timeIntervalSince1970: epoch),
                subject: fields[6],
                refs: parseRefs(fields[5])
            )
        }
    }

    /// Parse git's `%D` decoration string (e.g. "HEAD -> main, origin/main, tag: v1").
    ///
    /// - Parameter decoration: The raw comma-separated `%D` fragment.
    /// - Returns: Typed ``GitRef`` objects modeling tags and branches.
    static func parseRefs(_ decoration: String) -> [GitRef] {
        let trimmed = decoration.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var refs: [GitRef] = []
        for tokenRaw in trimmed.components(separatedBy: ",") {
            let token = tokenRaw.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if token.hasPrefix("HEAD -> ") {
                refs.append(GitRef(name: String(token.dropFirst("HEAD -> ".count)), kind: .head))
            } else if token == "HEAD" {
                refs.append(GitRef(name: "HEAD", kind: .head))
            } else if token.hasPrefix("tag: ") {
                refs.append(GitRef(name: String(token.dropFirst("tag: ".count)), kind: .tag))
            } else if token.contains("/") {
                refs.append(GitRef(name: token, kind: .remoteBranch))
            } else {
                refs.append(GitRef(name: token, kind: .branch))
            }
        }
        return refs
    }
}
