import Foundation
import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// User-tweakable graph controls (phase 1: scope + ordering + display).
///
/// Split conceptually into **fetch** options (change the `git log` invocation → require a
/// re-read: `fetchSignature`) and **display** options (view-only → instant re-render).
struct GraphOptions: Equatable, Codable {
    /// Which refs feed the graph.
    enum Scope: String, CaseIterable, Identifiable, Codable {
        case all = "All refs"
        case current = "Current branch"
        case local = "Local branches"
        var id: String { rawValue }
        /// The `git log` ref selector.
        var refArgument: String {
            switch self {
            case .all: return "--all"
            case .current: return "HEAD"
            case .local: return "--branches"
            }
        }
    }

    /// Commit ordering.
    enum Order: String, CaseIterable, Identifiable, Codable {
        case date = "Date"
        case topological = "Topological"
        var id: String { rawValue }
        var argument: String { self == .topological ? "--topo-order" : "--date-order" }
    }

    /// Row density → row height.
    enum Density: String, CaseIterable, Identifiable, Codable {
        case comfortable = "Comfortable"
        case compact = "Compact"
        case dense = "Dense"
        var id: String { rawValue }
        var rowHeight: CGFloat {
            switch self {
            case .comfortable: return 44
            case .compact: return 36
            case .dense: return 28
            }
        }
    }

    /// Maximum commits to read.
    enum Limit: Int, CaseIterable, Identifiable, Codable {
        case c250 = 250, c500 = 500, c1000 = 1000, c2000 = 2000
        var id: Int { rawValue }
        var label: String { "\(rawValue)" }
    }

    // Fetch options.
    var scope: Scope = .local   // local branches by default (fewer lanes than all refs)
    var order: Order = .date
    var hideMerges = false
    var firstParent = false     // follow only first parents — collapses merge spaghetti
    var limit: Limit = .c1000

    // Fetch filters (narrow the commits git returns). User text → sanitized in the service.
    var authorFilter = ""       // --author=
    var pathFilter = ""         // -- <path>
    var sinceFilter = ""        // --since= (git date, e.g. "2 weeks ago", "2024-01-01")
    var untilFilter = ""        // --until=

    // Display options.
    var density: Density = .comfortable
    var showAuthor = true
    var showHash = true
    var showRefs = true

    /// Whether any narrowing filter is active (drives the toolbar funnel indicator).
    var hasActiveFilters: Bool {
        firstParent
            || !authorFilter.isEmpty || !pathFilter.isEmpty
            || !sinceFilter.isEmpty || !untilFilter.isEmpty
    }

    /// Everything that requires re-reading from git. When this string changes, refetch.
    var fetchSignature: String {
        [scope.rawValue, order.rawValue, "\(hideMerges)", "\(firstParent)", "\(limit.rawValue)",
         authorFilter, pathFilter, sinceFilter, untilFilter].joined(separator: "|")
    }
}

/// Persisted git-graph state: recently-opened repos and each repo's saved options.
struct GitGraphPrefs: Codable {
    var recentPaths: [String] = []                    // most-recent first
    var optionsByPath: [String: GraphOptions] = [:]
}

/// UserDefaults-backed store for `GitGraphPrefs` (mirrors `InstallPreferences`' approach —
/// no file I/O or corruption handling needed for a small blob).
enum GitGraphPrefsStore {
    private static let key = "com.shivanggulati.catalyst.gitgraph.prefs"

    static func load() -> GitGraphPrefs {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(GitGraphPrefs.self, from: data) else {
            return GitGraphPrefs()
        }
        return prefs
    }

    static func save(_ prefs: GitGraphPrefs) {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Thin `@MainActor` view model for the Git Graph screen.
///
/// Owns the currently-loaded repository, its read-only summary, and the computed commit
/// graph. Heavy git work lives in `GitGraphService` (an actor, off the main thread) and
/// the graph is laid out by the pure `GitGraphLayoutEngine`; this VM only holds
/// `@Published` UI state and kicks off async loads (`Formrules.md` 1.3 — keep VMs thin).
@MainActor
final class GitGraphViewModel: ObservableObject {
    /// The load lifecycle for the current repository's summary.
    enum LoadState: Equatable {
        case empty
        case loading
        case loaded(RepoSummary)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .empty

    /// Absolute path of the repository currently loaded (or being loaded).
    @Published private(set) var repoPath: String?

    /// The laid-out commit graph for the current repo (empty until it loads).
    @Published private(set) var graph: GitGraphLayout = .empty

    /// Whether the commit graph is still being read/laid out (the summary shows first).
    @Published private(set) var isGraphLoading = false

    /// Drop-target highlight state for the drag-and-drop repo picker.
    @Published var isDropTargeted = false

    /// User graph controls (scope / ordering / display). Fetch-affecting changes are
    /// applied via `applyOptions()`; display-only changes just re-render.
    @Published var options = GraphOptions()

    /// Live search over the loaded commits (message / author / hash).
    @Published var searchText = ""

    /// The commit whose detail panel is open (nil = closed). Drives `.sheet(item:)`.
    @Published var selectedCommit: GraphCommit?

    /// Loaded detail for `selectedCommit`.
    @Published private(set) var selectedDetail: CommitDetails?

    /// Whether the detail is still being read.
    @Published private(set) var isDetailLoading = false

    /// Recently-opened repositories (most-recent first), persisted across launches.
    @Published private(set) var recentRepos: [String] = []

    private let service = GitGraphService.shared
    private let logger = Logger.shared
    private var prefs: GitGraphPrefs

    init() {
        let loaded = GitGraphPrefsStore.load()
        prefs = loaded
        recentRepos = loaded.recentPaths
    }

    /// Present a folder picker and load the chosen repository.
    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Repository"
        panel.message = "Choose a folder that contains a git repository."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(repoPath: url.path)
    }

    /// Load (or reload) a repository by path.
    ///
    /// Used by the folder picker, the drag-and-drop zone, and the recents list. The
    /// summary appears first; the graph is read and laid out immediately after so a large
    /// history never delays the summary card.
    func load(repoPath: String) {
        self.repoPath = repoPath
        // Set `.loading` BEFORE restoring options so the options-change observer (which
        // triggers a refetch only when `.loaded`) doesn't double-fetch here.
        state = .loading
        options = prefs.optionsByPath[repoPath] ?? GraphOptions()
        graph = .empty
        isGraphLoading = false
        Task {
            do {
                let summary = try await service.summary(for: repoPath)
                state = .loaded(summary)
                recordRecent(repoPath)

                isGraphLoading = true
                let commits = await service.commits(for: repoPath, options: options)
                graph = GitGraphLayoutEngine.layout(commits)
                isGraphLoading = false
            } catch {
                state = .failed(error.localizedDescription)
                isGraphLoading = false
                logger.log("⚠️ GitGraph load failed: \(error.localizedDescription)")
            }
        }
    }

    /// Add a repo to the front of the recents (deduped, capped) and persist.
    private func recordRecent(_ path: String) {
        var list = prefs.recentPaths.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        prefs.recentPaths = list
        recentRepos = list
        GitGraphPrefsStore.save(prefs)
    }

    /// Persist the current options for the loaded repo (called when options change).
    func persistOptions() {
        guard let repoPath else { return }
        prefs.optionsByPath[repoPath] = options
        GitGraphPrefsStore.save(prefs)
    }

    /// Remove a repo from the recents list.
    func removeRecent(_ path: String) {
        prefs.recentPaths.removeAll { $0 == path }
        prefs.optionsByPath[path] = nil
        recentRepos = prefs.recentPaths
        GitGraphPrefsStore.save(prefs)
    }

    /// Re-read the current repository (summary + graph), if one is loaded.
    func reload() {
        guard let repoPath else { return }
        load(repoPath: repoPath)
    }

    /// Re-read **only** the commit graph, leaving the summary card in place.
    ///
    /// Keeps the current graph on screen (so the reference row stays visible) while the
    /// refresh button shows a spinner, then swaps in the freshly-laid-out graph.
    func reloadGraph() {
        guard let repoPath, case .loaded = state else { return }
        isGraphLoading = true
        Task {
            let commits = await service.commits(for: repoPath, options: options)
            graph = GitGraphLayoutEngine.layout(commits)
            isGraphLoading = false
        }
    }

    /// Re-fetch the graph because a fetch-affecting option changed. No-op unless loaded.
    func applyOptions() {
        guard case .loaded = state else { return }
        reloadGraph()
    }

    /// Open the detail panel for a commit and load its details.
    func select(_ commit: GraphCommit) {
        guard let repoPath else { return }
        selectedCommit = commit
        selectedDetail = nil
        isDetailLoading = true
        Task {
            selectedDetail = await service.details(for: commit.hash, in: repoPath)
            isDetailLoading = false
        }
    }

    /// Whether a commit matches the current search text (empty search matches all).
    func matches(_ commit: GraphCommit) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return commit.subject.localizedCaseInsensitiveContains(q)
            || commit.authorName.localizedCaseInsensitiveContains(q)
            || commit.hash.localizedCaseInsensitiveContains(q)
    }

    /// Number of commits matching the current search (0 when search is empty).
    var matchCount: Int {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        return graph.nodes.reduce(0) { $0 + (matches($1.commit) ? 1 : 0) }
    }

    /// Handle a folder dropped onto the screen — resolves the URL and loads it.
    /// Mirrors `VirtualEnvironmentsViewModel.handleDrop`.
    func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return false }

        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { [weak self] data, error in
            guard let self, error == nil, let data else { return }
            var resolved: URL?
            if let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                resolved = url
            } else if let url = URL(dataRepresentation: data, relativeTo: nil) {
                resolved = url
            }
            guard let url = resolved else { return }
            Task { @MainActor in self.load(repoPath: url.standardized.path) }
        }
        return true
    }
}
