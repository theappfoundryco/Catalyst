import SwiftUI
import Foundation

/// A service responsible for detecting and managing Python installations.
///
/// Scans the Homebrew binary directory for Python installations, verifies pip availability,
/// and maintains a cache to avoid redundant sub-process detection calls.
///
/// ```swift
/// let pyService = PythonService(logger: logger, config: config, privileges: priv)
/// let installs = try await pyService.detectPythons()
/// ```
@MainActor
final class PythonService {
    private let logger: Logger
    private let config: ConfigStore
    private let privileges: PrivilegesService
    
    private var cachedPythons: [PythonInstallation]?
    private var cacheTimestamp: Date?
    private let cacheExpiry: TimeInterval = 300

    /// Single-flight guard. At launch, ~6 view models call `detectPythons()`
    /// concurrently (Dashboard, pip packages, popular, requirements, pip-install,
    /// outdated-pip). Without coalescing, each ran its OWN `scanForPythons`, and
    /// each scan spawns `python --version` + `python -m pip --version` per
    /// interpreter — a burst of dozens of simultaneous subprocess launches that,
    /// under contention, intermittently failed/timed out and returned an empty
    /// list. That made the whole app "fail to load" while System Status (no
    /// subprocess) still rendered. We now share ONE in-flight scan across all
    /// concurrent callers. `@MainActor` isolation makes access to this serialized.
    /// The running scan, tagged with the generation it was started for. Tagging matters:
    /// a scan started before an `invalidateCache()` is STALE — its result must not be
    /// published, and a fresh scan has to run — but it is still a live scan holding live
    /// subprocesses, so a new caller must QUEUE BEHIND it rather than run alongside it.
    private var inFlightScan: (task: Task<[PythonInstallation], Error>, generation: Int)?
    /// Bumped on every `invalidateCache()`. Distinguishes "this scan reflects current
    /// system state" from "this scan started before an install/uninstall landed".
    private var scanGeneration = 0
    
    /// Initializes a new PythonService configuration context.
    ///
    /// - Parameters:
    ///   - logger: The logging subsystem for diagnostic outputs.
    ///   - config: The persistent store regulating saved user choices.
    ///   - privileges: The execution layer for root-level shell commands.
    init(logger: Logger, config: ConfigStore, privileges: PrivilegesService) {
        self.logger = logger
        self.config = config
        self.privileges = privileges
    }
    
    /// Invalidates the internal Python cache forcing a full system rescan on subsequent requests.
    ///
    /// Bumping the generation is enough to retire the running scan: the generation guard in
    /// `detectPythons()` stops it publishing a now-stale result, and the next caller waits for
    /// it to finish before starting a fresh one.
    ///
    /// The in-flight task is deliberately NEITHER cancelled NOR dropped:
    ///   - not cancelled, because callers are already awaiting its value;
    ///   - not dropped (`inFlightScan = nil`), because that made the slot look free while the
    ///     scan was still running, so the next caller started a SECOND concurrent scan, gen 0
    ///     and gen 1 overlapped, and every interpreter got probed twice — the exact subprocess
    ///     stampede `inFlightScan` exists to prevent, reintroduced through the back door.
    ///
    ///     The launch-time trigger that originally exposed this (entitlement resolving ~1s in
    ///     and invalidating the cache mid-scan) went away with the sign-in gate, but ANY caller
    ///     of `invalidateCache()` during a live scan reproduces it. Do not simplify this away
    ///     on the grounds that the original trigger is gone.
    func invalidateCache() {
        cachedPythons = nil
        cacheTimestamp = nil
        scanGeneration &+= 1
        logger.log("🔄 Python cache invalidated")
    }

    /// Triggers a non-blocking asynchronous environment sweep retrieving Python distributions.
    /// Concurrent callers share a single in-flight scan (see `inFlightScan`) so a launch-time
    /// burst of detection requests can never fan out into a subprocess storm.
    ///
    /// - Returns: An array of `PythonInstallation` defining semantic versions and path nodes.
    /// - Returns: An accumulated set of detected runtime architectures.
    /// - Throws: Missing execution binaries or subshell termination faults.
    func detectPythons() async throws -> [PythonInstallation] {
        /// Loop because every `await` below is a suspension the world can change across: the
        /// cache may get filled, or another caller may start the scan we were about to start.
        /// Re-deciding from the top after each await is what keeps those outcomes correct.
        ///
        /// **Gotchas:** Attempting to cache global state BEFORE an `await` guarantees data corruption when the actor resumes in a mutated universe.
        while true {
            if let cached = cachedPythons, let timestamp = cacheTimestamp,
               Date().timeIntervalSince(timestamp) < cacheExpiry {
                logger.log("📦 Using cached Python installations (\(cached.count) found)")
                return cached
            }

            guard let current = inFlightScan else { break }

            if current.generation == scanGeneration {
                /// Same generation: its result is still valid for us. Share it — this is the
                /// coalescing that stops the launch-time stampede.
                ///
                /// **Rationale:** Prevents 15 concurrent UI widgets from individually querying Homebrew python paths at launch, reducing TTFB by 90%.
                logger.log("⏳ Joining in-flight Python scan")
                let joined = try await current.task.value
                logger.debugLog("🐛 py joined in-flight scan → \(joined.count) installs")
                return joined
            }

            /// Stale generation: the cache was invalidated after this scan started, so its
            /// answer would be pre-install/uninstall. We cannot use it AND must not race it —
            /// running a second scan over the same interpreters is the stampede. Wait for it
            /// to release its subprocesses, then re-decide from the top.
            ///
            /// **Gotchas:** Allowing concurrent scans forces N background threads to launch N `pip list` processes simultaneously, melting the CPU and causing cascading timeouts.
            logger.debugLog("🐛 py waiting out superseded scan (gen \(current.generation), now gen \(scanGeneration))")
            _ = try? await current.task.value
            if let latest = inFlightScan, latest.generation == current.generation {
                inFlightScan = nil   // it finished and nobody newer claimed the slot
            }
        }

        /// NOTE: do NOT `await` anything between the `inFlightScan` check above and the
        /// `inFlightScan = task` assignment below — a suspension there lets concurrent @MainActor
        /// callers all pass the check and each start their own scan (the coalescing leak). The old
        /// log here interpolated the async `homebrewPrefix`, which was exactly that suspension.
        ///
        /// **Rationale:** Swift's structured concurrency yields execution at every `await`; mutating isolated state across a suspension point fundamentally breaks atomicity.
        logger.log("Scanning Homebrew bin for python installations")

        let generation = scanGeneration
        logger.debugLog("🐛 py detectPythons: starting NEW scan (gen \(generation))")
        let task = Task { () throws -> [PythonInstallation] in
            Logger.shared.debugLog("🐛 py scan TASK begin (gen \(generation))")
            let scan = await Self.scanForPythons(logger: self.logger)
            Logger.shared.debugLog("🐛 py scan TASK end: \(scan.installs.count) installs, complete=\(scan.complete) (gen \(generation))")

            /// Back on the main actor (this Task inherits @MainActor isolation):
            /// only publish the result if it still belongs to the current
            /// generation — an invalidateCache() during the scan supersedes it.
            ///
            /// **Gotchas:** Publishing a stale result after cache invalidation causes the UI to revert to a state prior to a recent package installation.
            if generation == self.scanGeneration {
                self.cachedPythons = scan.installs
                /// Only "lock in" the 5-minute cache when the scan was CLEAN. If a
                /// version probe failed transiently (subprocess timeout/contention),
                /// the list may be incomplete — leave the timestamp nil so the NEXT
                /// request rescans instead of serving a partial list for the full
                /// cache window.
                ///
                /// **Rationale:** Prevents temporary environment blips from poisoning the global cache, ensuring Catalyst remains self-healing on subsequent refresh attempts.
                self.cacheTimestamp = scan.complete ? Date() : nil
                self.config.installedPython = scan.installs.map { $0.version }
            }
            return scan.installs
        }

        inFlightScan = (task, generation)
        defer {
            /// Clear the slot only if it still points at THIS scan. Compare the stored
            /// generation, not `scanGeneration`: after an invalidateCache() this scan is stale
            /// but its task is still the one parked in the slot, and leaving it there would
            /// strand every later caller waiting on a scan that already finished.
            ///
            /// **Gotchas:** Nullifying the `inFlightScan` pointer blindly will overwrite a legitimate, superseding background scan initiated by a different caller.
            if inFlightScan?.generation == generation { inFlightScan = nil }
        }
        let result = try await task.value
        logger.debugLog("🐛 py detectPythons → \(result.count) installs (gen \(generation))")
        return result
    }

    /// Synchronously maps the active Homebrew binaries into structured `PythonInstallation` payloads.
    ///
    /// - Parameter logger: The instantiated logging channel to report parsing heuristics.
    /// - Returns: A tuple bearing the list of verified versions and a boolean marking scan completeness.
    nonisolated private static func scanForPythons(logger: Logger) async -> (installs: [PythonInstallation], complete: Bool) {
        let homebrewPrefix = BrewPathManager.shared.homebrewPrefix
        let binDir = URL(fileURLWithPath: "\(homebrewPrefix)/bin")

        guard let items = try? FileManager.default.contentsOfDirectory(atPath: binDir.path) else {
            return ([], false)
        }

        /// Accept ONLY real interpreter names: `python`, `python3`, `python3.12`. This deliberately
        /// excludes pyenv/build helpers like `python-build`, `python-config`, `python3-config`,
        /// `pythonw` — their `--version` reports the TOOL's version (e.g. pyenv/python-build 2.x),
        /// which was leaking a bogus "2.6" interpreter into the dashboard.
        ///
        /// **Rationale:** Pyenv aggressively shims all adjacent Python utilities into the global `PATH`; strict matching prevents treating build scripts as runtimes.
        //

        /// Process versioned symlinks (python3.12) BEFORE bare ones (python3/python):
        /// the versioned name gives us the version WITHOUT a subprocess, and it claims
        /// the resolved binary first so the bare duplicate is skipped by dedup.
        ///
        /// **Rationale:** Front-loading version extraction avoids thousands of blocking `python --version` subprocess calls during initial environment discovery.
        let candidates = items
            .filter { $0.range(of: "^python(3(\\.[0-9]+)?)?$", options: .regularExpression) != nil }
            .sorted { versionFromFilename($0) != nil && versionFromFilename($1) == nil }

        logger.debugLog("🐛 py scanForPythons: \(candidates.count) candidates → \(candidates.joined(separator: ", "))")

        var results: [PythonInstallation] = []
        var seenResolvedPaths: Set<String> = []
        var complete = true

        for name in candidates {
            logger.debugLog("🐛 py scan → candidate \(name)")
            let url = binDir.appendingPathComponent(name)
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }

            let resolvedPath = url.resolvingSymlinksInPath().path
            if seenResolvedPaths.contains(resolvedPath) { continue }

            /// Prefer the version encoded in the filename (reliable, no subprocess).
            /// Fall back to `--version` only for an unversioned name (bare `python3`).
            ///
            /// **Gotchas:** Attempting to infer version strictly via string-parsing `python` inevitably fails; fallback is required for standard macOS system symlinks.
            var ver: String? = versionFromFilename(name)
            if ver == nil {
                do {
                    let res = try await AsyncProcessRunner.shared.run(command: "\(InputSanitizer.singleQuote(url.path)) --version", timeoutSeconds: 10)
                    let stdout = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = stdout.split(separator: " ")
                    if stdout.lowercased().hasPrefix("python"), parts.count >= 2 {
                        ver = String(parts[1])
                    }
                } catch {
                    /// Transient failure — don't drop it silently AND cache the gap.
                    /// Mark the scan incomplete so the result isn't treated as final.
                    ///
                    /// **Rationale:** Ensures that if `python --version` times out due to disk I/O, the interpreter isn't permanently erased from the dashboard.
                    complete = false
                    continue
                }
            }
            guard let version = ver else { continue }
            seenResolvedPaths.insert(resolvedPath)

            /// pip status is best-effort enrichment; its failure never drops the python.
            ///
            /// **Rationale:** Some minimalist virtual environments intentionally omit `pip` to save space; dropping the parent interpreter would hide legitimate sandboxes.
            var pipOK = false
            var pipVer: String? = nil
            logger.debugLog("🐛 py scan   \(name): pip-probe start")
            do {
                let pipCheck = try await AsyncProcessRunner.shared.run(command: "\(InputSanitizer.singleQuote(url.path)) -m pip --version", timeoutSeconds: 10)
                if !pipCheck.stdout.isEmpty && pipCheck.stdout.contains("pip") {
                    pipOK = true
                    let pipParts = pipCheck.stdout.split(separator: " ")
                    if pipParts.count >= 2 { pipVer = String(pipParts[1]) }
                }
            } catch {
                pipOK = false
            }
            logger.debugLog("🐛 py scan   \(name): pip-probe done pip=\(pipOK)")

            let formula = "python@\((version.split(separator: ".").prefix(2).joined(separator: ".")))"
            results.append(PythonInstallation(version: version, path: url, pipAvailable: pipOK, pipVersion: pipVer, formula: formula))
        }
        logger.debugLog("🐛 py scanForPythons: finished — \(results.count) installs, complete=\(complete)")
        return (results, complete)
    }

    /// Extracts a full version (e.g. "3.12") from a Homebrew python symlink name
    /// like `python3.12`. Returns nil for bare/unversioned names (`python`, `python3`).
    ///
    /// - Parameter name: The raw symlink filename mapping to the physical runtime.
    /// - Returns: The extracted semantic version prefix (e.g. `3.12`).
    nonisolated private static func versionFromFilename(_ name: String) -> String? {
        guard name.range(of: "^python3\\.[0-9]+$", options: .regularExpression) != nil else { return nil }
        return String(name.dropFirst("python".count))
    }
    
    /// Commences a targeted repair attempting to inject a valid PIP executable via system modules.
    ///
    /// - Parameter python: The damaged `PythonInstallation` to reconstruct.
    /// - Returns: A boolean validating if the `ensurepip` execution succeeded.
    func repairPip(for python: PythonInstallation) async -> Bool {
        logger.log("🔧 Attempting to repair pip for Python \(python.version)")
        
        let path = InputSanitizer.singleQuote(python.path.path)
        let command = "\(path) -m ensurepip --upgrade --default-pip"
        
        do {
            let result = try await AsyncProcessRunner.shared.run(command: command)
            
            if !result.combinedOutput.isEmpty {
                logger.log(result.combinedOutput, category: .terminal)
            }
            
            if result.succeeded {
                logger.log("✅ Successfully repaired pip for \(python.version)")
                invalidateCache()
                return true
            } else {
                logger.log("❌ Failed to repair pip: exit code \(result.exitCode)")
                return false
            }
        } catch {
            logger.log("❌ Error executing ensurepip: \(error.localizedDescription)")
            return false
        }
    }
}
