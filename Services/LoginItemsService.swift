import Foundation

// MARK: - Models

/// Where a launchd job lives — which governs whether we can touch it without root.
enum LaunchAgentScope: String, Sendable {
    case userAgent      // ~/Library/LaunchAgents  (manageable, no privileges)
    case systemAgent    // /Library/LaunchAgents   (read-only here)
    case systemDaemon   // /Library/LaunchDaemons  (read-only here)

    var label: String {
        switch self {
        case .userAgent: return "User Agent"
        case .systemAgent: return "System Agent"
        case .systemDaemon: return "System Daemon"
        }
    }

    /// Only user agents are safe to toggle/remove without admin rights.
    var isManageable: Bool { self == .userAgent }
}

/// A launchd job defined by a `.plist` in one of the LaunchAgents/Daemons dirs.
struct LaunchAgentItem: Identifiable, Sendable {
    var id: String { plistPath }
    let label: String
    let plistPath: String
    /// The executable (`Program` or first `ProgramArguments` entry).
    let program: String
    let scope: LaunchAgentScope
    /// Whether launchd currently has the job loaded.
    let isLoaded: Bool
    /// Whether the job is configured to run at load.
    let runAtLoad: Bool

    /// Filename without extension, handy when the Label is generic.
    var fileName: String {
        (plistPath as NSString).lastPathComponent
    }
}

/// A classic macOS "Open at Login" item (System Events).
struct LoginItem: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let path: String
    let hidden: Bool
}

/// Aggregate snapshot for the Login Items screen.
struct LoginItemsReport: Sendable {
    let scanDate: Date
    let loginItems: [LoginItem]
    let agents: [LaunchAgentItem]

    var userAgents: [LaunchAgentItem] { agents.filter { $0.scope == .userAgent } }
    var systemAgents: [LaunchAgentItem] { agents.filter { $0.scope != .userAgent } }
}

/// Inspects and (for user-scope items) manages what launches at startup:
/// launchd agents/daemons and classic login items. Read operations parse plists
/// directly; mutations shell out to `launchctl` / `osascript`. No admin rights —
/// system-scope jobs are surfaced read-only.
final class LoginItemsService: Sendable {

    static let shared = LoginItemsService()
    private init() {}

    private let runner = AsyncProcessRunner.shared
    private let launchctlPath = "/bin/launchctl"
    private let osascriptPath = "/usr/bin/osascript"

    // MARK: - Scan

    func scan() async -> LoginItemsReport {
        async let agentsTask = scanAgents()
        async let loginTask = scanLoginItems()
        return LoginItemsReport(
            scanDate: Date(),
            loginItems: await loginTask,
            agents: await agentsTask
        )
    }

    private func scanAgents() async -> [LaunchAgentItem] {
        let loaded = await loadedLabels()
        let dirs: [(String, LaunchAgentScope)] = [
            (NSHomeDirectory() + "/Library/LaunchAgents", .userAgent),
            ("/Library/LaunchAgents", .systemAgent),
            ("/Library/LaunchDaemons", .systemDaemon)
        ]
        var items: [LaunchAgentItem] = []
        for (dir, scope) in dirs {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in contents where name.hasSuffix(".plist") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if let item = parseAgent(at: url, scope: scope, loaded: loaded) {
                    items.append(item)
                }
            }
        }
        return items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private func parseAgent(at url: URL, scope: LaunchAgentScope, loaded: Set<String>) -> LaunchAgentItem? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        var program = plist["Program"] as? String
        if program == nil, let args = plist["ProgramArguments"] as? [String] {
            program = args.first
        }
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        return LaunchAgentItem(
            label: label,
            plistPath: url.path,
            program: program ?? "—",
            scope: scope,
            isLoaded: loaded.contains(label),
            runAtLoad: runAtLoad
        )
    }

    /// The set of labels launchd currently has loaded (`launchctl list`).
    private func loadedLabels() async -> Set<String> {
        do {
            let result = try await runner.run(executable: launchctlPath, arguments: ["list"], timeoutSeconds: 6)
            var labels = Set<String>()
            for line in result.stdout.components(separatedBy: .newlines).dropFirst() {
                // Columns: PID  Status  Label  (tab-separated)
                let cols = line.split(separator: "\t")
                if let last = cols.last {
                    let label = last.trimmingCharacters(in: .whitespaces)
                    if !label.isEmpty { labels.insert(label) }
                }
            }
            return labels
        } catch {
            return []
        }
    }

    private func scanLoginItems() async -> [LoginItem] {
        // Names + paths + hidden flags from System Events. Returns empty (rather
        // than throwing) if Automation permission is denied or none are set.
        async let names = osaList(property: "name")
        async let paths = osaList(property: "path")
        async let hiddens = osaList(property: "hidden")

        let n = await names, p = await paths, h = await hiddens
        guard !n.isEmpty else { return [] }
        var items: [LoginItem] = []
        for (i, name) in n.enumerated() {
            let path = i < p.count ? p[i] : ""
            let hidden = i < h.count ? (h[i].lowercased() == "true") : false
            items.append(LoginItem(name: name, path: path, hidden: hidden))
        }
        return items
    }

    private func osaList(property: String) async -> [String] {
        let script = "tell application \"System Events\" to get the \(property) of every login item"
        do {
            let result = try await runner.run(executable: osascriptPath, arguments: ["-e", script], timeoutSeconds: 6)
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !out.isEmpty else { return [] }
            return out.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
        } catch {
            return []
        }
    }

    // MARK: - Mutations (user scope only)

    /// Loads/unloads a user agent with `-w` so the enabled state persists.
    func setAgentEnabled(_ agent: LaunchAgentItem, enabled: Bool) async -> Bool {
        guard agent.scope.isManageable else { return false }
        let sub = enabled ? "load" : "unload"
        do {
            let r = try await runner.run(executable: launchctlPath, arguments: [sub, "-w", agent.plistPath], timeoutSeconds: 8)
            return r.succeeded
        } catch {
            return false
        }
    }

    /// Unloads (best-effort) then moves the agent's plist to the Trash.
    func removeAgent(_ agent: LaunchAgentItem) async -> Bool {
        guard agent.scope.isManageable else { return false }
        _ = try? await runner.run(executable: launchctlPath, arguments: ["unload", "-w", agent.plistPath], timeoutSeconds: 8)
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: agent.plistPath), resultingItemURL: nil)
            return true
        } catch {
            Logger.shared.log("⚠️ Failed to remove agent \(agent.label): \(error.localizedDescription)")
            return false
        }
    }

    /// Removes a classic login item via System Events.
    func removeLoginItem(_ item: LoginItem) async -> Bool {
        let safeName = item.name.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"System Events\" to delete login item \"\(safeName)\""
        do {
            let r = try await runner.run(executable: osascriptPath, arguments: ["-e", script], timeoutSeconds: 8)
            return r.succeeded
        } catch {
            return false
        }
    }
}
