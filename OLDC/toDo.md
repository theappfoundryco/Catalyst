> **Status (2026-05-31):** All 7 **P0** ship-blockers resolved in code — see `taskTracker.md` for the checklist and per-fix notes. Affected files: `OutdatedPIPViewModel`, `OutdatedBrewViewModel`, `DashboardViewModel`, `AsyncProcessRunner`, `DiskHygieneDoctor`, `CruftSweeperViewModel`, `PrivilegesService`.
>
> **Status (2026-06-12):** All 16 **P1** correctness bugs resolved in code — see `taskTracker.md` for per-fix notes. Affected files: `BrewFormulaeCaskViewModel`, `OutdatedBrewViewModel`, `SSDHealthService`, `PrivilegesService`, `Logger` + `LogsViewModel`, `PIPPackagesViewModel`, `CruftSweeperViewModel`, `GhostBusterViewModel`, `SecurityDoctor`, `ConflictDoctor`, `StorageDoctor`. **Not yet built on macOS** — no Swift toolchain in this environment, so changes are compiler-unverified; a real `xcodebuild` is still needed.
>
> **Status (2026-06-12, P2 batch 1 — foundational enablers):** Done: array-args exec path + timeout/cancellation in `AsyncProcessRunner` (migrated the two main package VMs); capture pip/brew versions; native venv set-diff; `URLSession.shared`→`NetworkConfig`. Deferred (need a build / bigger surface): make `shellEscape` private (≈30 call sites, some double-quote context — documented for now). Affected files: `AsyncProcessRunner`, `BrewFormulaeCaskViewModel`, `PIPPackagesViewModel`, `VirtualEnvCreationViewModel`, `InputSanitizer`, + URLSession migrations across 6 VMs. Compiler-unverified.
>
> **Status (2026-06-12, P2 batch 2 — architecture-heavy):** Done: **Doctor protocol + `fixID`** — `protocol Doctor`/`AvailabilityCheckable` + `HealthFix` enum in `HealthCheckModels`; all 16 checkers conform; `HealthCheckService` rewritten around one `[Doctor]` array (scan loop, per-category status, and fix routing all derived from it); `.security` double-dispatch gone; dead `storageDoctor` prop removed from `DrCatalystViewModel`. **Dedup Outdated VMs** — `protocol OutdatedUpdating` + extension; `OutdatedPIPViewModel`/`OutdatedBrewViewModel` keep only pip/brew specifics. **Deferred: split `DashboardViewModel`** (needs a compiler + Xcode project changes — see taskTracker). Affected files: `HealthCheckModels`, `HealthCheckService`, all 16 `Checkers/*`, `DrCatalystViewModel`, `OutdatedPIPViewModel`, `OutdatedBrewViewModel`. Compiler-unverified — the `@MainActor protocol`/existential-array patterns especially want a real build.
>
> **Status (2026-06-12, P3 — robustness & code quality):** Done (13): Dr. Catalyst score curve + history daily-debounce; GhostBuster token allow/blocklist + verified kill-all; SSD plist boot-disk + calibrated healthScore + persisted-masked serial; SecurityDoctor all-RSA-keys + bash history; alias single-quote storage + tighter parser; SmartShortcuts decl-anchored `functionExists` + first-line rename + `PythonService` routing; Logger `stat`-throttle + dead `getAllLogs` removed; `ProjectStore` tolerant decode; keg-parse dedup + `BrewItem` hoist; venv `refreshWithDelay` delay removed; Cruft option-snapshot + `pyvenv.cfg` marker; `OutdatedBrew` init race removed. **Deferred/structural (4):** unify caching policy, single storage layout, `NetworkMonitor` swap (DI), surface-failures-in-UI (broad UI). **Partial leftovers:** Logger truncation-policy + NSSavePanel-in-VM; Dashboard 2s FS-sync waits; Cruft cosmetics (`CruftType.unknown`, progress-100%, custom-path grouping). Affected files: `HealthHistoryStore`, `GhostBusterViewModel`, `SSDHealthModels`, `SSDHealthService`, `SecurityDoctor`, `AliasViewModel`, `SmartShortcutsViewModel`+`AppViewModel`, `Logger`, `ProjectStore`, `BrewFormulaeCaskViewModel`, `OutdatedBrewViewModel`, `VirtualEnvironmentsViewModel`, `CruftSweeperViewModel`, `DashboardViewModel`. Compiler-unverified.
>
> **Status (2026-06-12, P2 batch 3 — remaining open items):** Done: **`DetectionState` enum** (Dashboard sets `brewState`/`commandLineToolsState`; `AppViewModel` compares the enum, not `brewStatus == "Installed"`); **`ManagedBlock`** in `ShellConfigManager` (`# CATALYST_BEGIN/END <id>` sentinels) wired into Aliases + SmartShortcuts (legacy parsers kept as removal fallback); **`InstalledPackagesService`** (new file) dedups pip/formulae/cask listing across 3 VMs; **`shellEscape` made `private`** — all ~28 bare call sites routed through `singleQuote` (double-quote `export PATH` fragments rewritten as `singleQuote(prefix + "/bin")`), tests retargeted. Only remaining P2 item: the deferred `DashboardViewModel` split. Affected files: `DashboardViewModel`, `AppViewModel`, `ShellConfigManager`, `AliasViewModel`, `SmartShortcutsViewModel`, `InstalledPackagesService` (new), `PIPPackagesViewModel`, `BrewFormulaeCaskViewModel`, `PopularPackagesViewModel`, `OutdatedPIPViewModel`, `OutdatedBrewViewModel`, `PIPPackagesInstallViewModel`, `FormulaeCaskInstallViewModel`, `RequirementsViewModel`, `PythonService`, `PrivilegesService`, `AsyncProcessRunner`, `InputSanitizer`, + tests. **Compiler-unverified — needs `xcodebuild`. NB: `InstalledPackagesService.swift` is a new file; with Xcode 16 synchronized groups it should auto-join the target, but confirm it's in the build.**

# Pass - 1

Code sweep findings, two views at a time per the nav bar. Each item is a candidate improvement; not yet prioritized.

## 1. Dashboard (`DashboardViewModel`)

### Critical
- [ ] **Homebrew install writes the user's password to disk.** In `installHomebrew()` the plaintext password is written to `/tmp/catalyst_askpass.sh` (heredoc) and `SUDO_ASKPASS` points sudo at it. Even with `0o700`, the secret hits disk in `/tmp`; if the process dies before the `removeItem` cleanup, it lingers. Fix: feed the password to `sudo -S` over an in-memory pipe (no file), or if askpass is unavoidable, create it in the app's sandboxed container with unique (`mkstemp`-style) naming and guarantee deletion via `defer`. Add a regression test in `PrivilegesServiceTests`/`DestructiveTests`.

### Code improvements
- [ ] **Split the ~990-line god object.** It owns detection, Python install/uninstall, Homebrew install/uninstall, brew maintenance (update/upgrade/cleanup/doctor/link), and pip upgrade/repair. Extract `DetectionService`, `PythonManager`, `BrewMaintenanceManager`; leave the VM as a thin coordinator. Highest-leverage refactor in the app.
- [ ] **Stop using display strings as state.** `brewStatus == "Installed"` is compared in `AppViewModel.fullRefresh`. Model detection as an enum (`DetectionState { case installed, notInstalled, unknown }`) with a separate display string.
- [ ] **Collapse duplicate keg-parsing.** `parseUnlinkedKegs(from:)` and `updateBrewUnlinkedKegs(from:)` are near-identical. Merge into one. Both are brittle string-scrapes of `brew doctor` output that break if brew rewords warnings.
- [ ] **Consistent networking.** `checkLatestPipVersion()` hand-rolls `JSONSerialization`; the rest of the app uses typed `NetworkConfig.fetchJSON`. Make it consistent.
- [ ] **Replace `Task.sleep(2s)` "wait for filesystem to sync"** after install with polling for the expected binary.
- [ ] **Surface failures in the UI.** Install/uninstall errors only hit the log; a non-developer won't open Logs. Add an error-state published property for the View to show as a banner.

### Feature ideas
- [ ] **"Bootstrap this Mac"** — one button sequencing CLT → Homebrew → recommended Python → link, with progress. Pieces already exist; just orchestrate.
- [ ] **Machine snapshot** — export/import a manifest (Brewfile + Python versions + pip lists, already tracked in `ConfigStore`) to reproduce an environment on a new Mac. → **now planned as CatalystSnapshot; full design in `CatalystSnapshot-Plan.md`** (also absorbs "Bootstrap this Mac" above).
- [ ] **Default-Python switcher** — pyenv-style global selector when multiple Pythons are installed (conflict detection already exists via `isSystemPythonConflict`).
- [ ] **Toolchain parity** — add Node/nvm, Ruby, Java version status (lean on existing `NodeDoctor`/`JavaDoctor`).

## 2. Virtual Environments (`VirtualEnvironmentsViewModel` + `VirtualEnvCreationViewModel`)

### Code improvements
- [ ] **Drop the raw `comm -23` shell pipeline in `verifyInstallation`.** It diffs requirements vs. `pip freeze` via process substitution (works only because the runner uses zsh) and is commented "Exact user script logic verbatim." The Swift helpers `parsePackageNames` and `normalizePackageName` already exist (unused) and do exactly this. Do the set-diff natively — testable, portable, won't silently break. Cleanest win here.
- [ ] **Standardize venv pip invocation.** Creation uses `python3 -m pip`; `retryFailedPackages` uses `venvPath + "/bin/pip"`. Use `python -m pip` everywhere.
- [ ] **Escape the path in `openInTerminal`.** It interpolates `cd '\(project.path)'` raw while the rest of the file uses `InputSanitizer.singleQuote`. A path with a quote breaks (or worse). Use the sanitizer.
- [ ] **Add schema versioning to `ProjectStore`.** No version field; adding a `Project` field later risks failing the decode of existing stores. Add tolerant decoding / version now.
- [ ] `refreshWithDelay`'s artificial 1.5s sleep is purely cosmetic (noted, not blocking).

### Feature ideas
- [ ] **Support more than `python -m venv`** — `uv`, Poetry, Pipenv, conda. Detect the project's tool (`ProjectScannerService` already reads `Pipfile`/`pyproject.toml`) and create with the match.
- [ ] **Editor integration** — optionally write `.vscode/settings.json` pointing `python.defaultInterpreterPath` at the new venv.
- [ ] **Per-project package panel** — view installed packages, `pip freeze` back to `requirements.txt`, update deps, in-app.
- [ ] **Broken-venv detection & rebuild** — when the underlying Python is upgraded/removed, flag it and offer one-click rebuild (ties into Dr. Catalyst).
- [ ] **Orphaned-venv cleanup** — surface venvs whose project folder is gone (`missingProjectIDs` already computed) and hand to Cruft Sweeper.

# Pass - 2

"Manage Existing Packages" section.

## 3. pip Packages (`PIPPackagesViewModel`)

### Code improvements
- [ ] **Version is thrown away.** Everything is `InstalledPackage(name:, version: nil)`. `pip list --format=freeze` returns `name==version`, but the code splits on `=` and keeps only the name. The model has a `version` field that's always nil. Capture it — free data, and it unlocks the "outdated" badge.
- [ ] **Optimistic list updates drift from reality.** Install/uninstall mutate `installedPipPackages` in place (with `version: nil`) and never re-query. "Requirement already satisfied" (exit 0, no change) or partial failures make the UI lie until a full refresh.
- [ ] **Uninstall success is string-scraping.** `stdout.contains("Successfully uninstalled")` is brittle across pip versions/locales. Confirm with exit code + a follow-up `pip show` returning empty.
- [ ] **Search is shard-limited.** Loads only the `pypi/<first-2-chars>.json` shard and substring-filters within it, so a query appearing mid-name in a package starting with different letters won't surface. Document or move to a real index.
- [ ] **Inconsistent networking** (same theme as Pass 1): search uses `URLSession.shared.data(from:)` instead of the configured `NetworkConfig` session / typed fetch.
- [ ] **Style inconsistency:** install uses safe array-args (`runCommandWithStatus`), uninstall builds a raw string command. Pick one.

## 4. Formulae / Casks (`BrewFormulaeCaskViewModel`)

### Code improvements
- [ ] **`--ignore-dependencies` on formula uninstall is dangerous.** Silently removes a formula others depend on, breaking them. Riskiest item here for a non-expert-facing app. Run `brew uses --installed <formula>` first and warn, or drop the flag by default.
- [ ] **Installs show nothing while running.** `runCommandWithStatus` swallows all output, so a large cask install looks frozen (unlike Dashboard, which streams). Stream to the log/console or show progress.
- [ ] **Version is dropped again** — `brew list --versions` would give it; currently always nil. Display names are also force-lowercased, losing brew's original casing.
- [ ] **Duplicated `struct BrewItem`** defined identically inside both `loadBrewFormulae` and `loadBrewCasks` — hoist it out.
- [ ] **Same networking inconsistency** — raw `URLSession.shared` instead of `NetworkConfig`.

### Cross-cutting (both)
- [ ] The `"'\(InputSanitizer.shellEscape(x))'"` pattern is correct but re-implements the existing `InputSanitizer.singleQuote(x)` helper by hand in several spots — standardize on the helper.

### Feature ideas (both)
- [ ] Inline version + outdated badge (merges these with the Updates views).
- [ ] Multi-select bulk uninstall.
- [ ] Package detail panel: description, homepage, dependencies, on-disk size (`brew info` / `pip show`), and "what depends on this."
- [ ] **Orphan cleanup** — `brew leaves` / `brew autoremove` to find safely-removable packages; size-sorted list.
- [ ] Export installed sets as Brewfile / requirements.txt (feeds the Pass-1 "machine snapshot" idea).
- [ ] pip: show which Python/venv each package belongs to (currently only the selected interpreter).

# Pass - 3

"Update Existing Packages" section.

## 5. pip Updates (`OutdatedPIPViewModel`)

### Critical
- [ ] **Command injection in `updatePipPackage`.** The actual upgrade builds `"\(pythonPath) -m pip install --upgrade \(name)"` with BOTH values interpolated raw — no `shellEscape`, no `sanitizePackageName` (line ~351). Everywhere else in the file escapes; this one path doesn't. A crafted package name or a Python path with a space/quote breaks or executes arbitrary shell. Sanitize the name and quote the path (or move to array-args), and add a regression test.

### Code improvements
- [ ] **Reinvents `pip list --outdated` at huge cost.** `getOutdatedPip()` does `pip list --format=json`, then fires one HTTPS call to PyPI *per installed package* (`fetchLatestVersionFromPyPI`), then runs `pip install --upgrade --dry-run` *per candidate*. That's N network round-trips + M subprocess spawns to compute something pip already gives in **one** local call. The correct one-shot version — `checkPythonForOutdated()` using `pip list --outdated --format=json` — already exists in the file but is **dead code, never called**. Switch to it; delete the hand-rolled path.
- [ ] **Naive version comparison.** `isVersion(_:olderThan:)` uses `String.compare(options: .numeric)`, which doesn't understand PEP 440 (pre-release/post/dev/epoch, e.g. `1.0rc1`, `1.0.post1`). pip's own `--outdated` respects PEP 440 — another reason to use it.
- [ ] **Brittle `--dry-run` conflict scrape.** Safety is decided by substring-matching "incompatible" / "requires"+"but" in output. Locale- and version-fragile, and doubles the subprocess count. Drop with the rewrite above.
- [ ] **Network check shells out per update.** `hasNetworkConnection()` runs `curl ... https://pypi.org` on every update call. `NetworkMonitor` (NWPathMonitor) already exists — use it instead of spawning curl.
- [ ] **Inconsistent networking.** `fetchLatestVersionFromPyPI` uses `URLSession.shared` (no `NetworkConfig`) and interpolates the package name into the URL without percent-encoding. Same theme as Passes 1–2.
- [ ] **Expensive re-scan after update.** `updateFiltered` calls the full `checkForPipUpdates()` again at the end — i.e. re-runs the whole N-PyPI-call scan. Brew's equivalent does *not* re-scan (see below) — pick one behavior.

## 6. Formulae / Casks Updates (`OutdatedBrewViewModel`)

### Critical
- [ ] **Command injection in `updatePackage`.** `brew upgrade \(name)` (and `--cask \(name)`) interpolates the package name raw into the shell string (lines ~165/167); `brewPath`/`homebrewPrefix` are unquoted too. Sanitize/quote like the rest of the codebase.

### Code improvements
- [ ] **Wrong-host network check.** `hasNetworkConnection()` pings `https://pypi.org` to gate *Homebrew* updates — brew doesn't use PyPI. Use `NetworkMonitor`, or at least check a brew/GitHub host.
- [ ] **Racy `isBrewAvailable`.** Set once in `init` via a detached `Task` and again synchronously in `checkForBrewUpdates`. The init Task is redundant and can race. Drop it; resolve lazily.
- [ ] **Case-sensitive verify.** `verifyUpdate` matches `$0.name == name` exactly, unlike the pip side which normalizes. Brew casing mismatches would mark a successful update as failed.

### Cross-cutting (both Update VMs)
- [ ] **The two VMs are ~70% duplicate.** `OutdatedPackage`, `formattedLastScanDate`, `reset()`, `resetUpdateResults()`, `hasNetworkConnection()`, `runCommand`, and the success/failed-tracking + `updateFiltered` loop are near-identical. Extract a shared base class or protocol; keep only the package-source specifics (pip vs brew) per subclass.
- [ ] **Standardize update-then-rescan behavior** across both (pip re-scans, brew doesn't).
- [ ] **`runCommand` builds raw strings** — move to array-args like the install paths elsewhere.

### Feature ideas
- [ ] **Pin / hold packages** — let the user exclude specific packages from "Update All" (brew `pin`, pip constraints).
- [ ] **Changelog / release-notes link** per outdated row (PyPI release page, brew formula page).
- [ ] **Security-only filter** — surface updates that close known CVEs first.
- [ ] **Scheduled background scan** — periodic outdated check with a badge/notification, instead of manual scans.

# Pass - 4

"Dr. Catalyst" — the health-check engine (`HealthCheckService` + 16 `Checkers/*Doctor`), scoring/history, GhostBuster, StorageDoctor.

## 7. Health-check engine (`HealthCheckService`, `HealthCheckModels`, `DrCatalystViewModel`)

### Architecture (highest-leverage)
- [ ] **No `Doctor` protocol — the engine is hand-wired in four places.** Each checker is an independent struct/class with its own ad-hoc `run()`/`fix()`; there is no shared protocol. Consequence: `HealthCheckService` hard-codes 16 stored properties, a 13-way `async let` flat-map, a special-cased availability branch for Container/Java/Node, and a 14-case `fix` switch. Adding one doctor means editing all of these and keeping them in sync. Define `protocol Doctor { var category: HealthCategory { get }; func run() async -> [HealthIssue]; func fix(_:) async -> Bool }` (plus an `AvailabilityCheckable` refinement), hold them in one `[Doctor]` array, and derive both the scan loop and `fix` routing from it. Single biggest structural win in this subsystem.
- [ ] **Auto-fix is routed by matching the display title.** `fix()` inside each checker branches on `issue.title` — `== "Catalyst Config Not Sourced"`, `== "Unsafe SSH Permissions"`, `.contains("DerivedData")`. But the title is also the user-facing string and sometimes carries interpolated data (`"Large DerivedData (\(size.formatted))"`), which is exactly why DiskHygieneDoctor must use `.contains`. Rewording or localizing any title silently breaks its auto-fix. Give `HealthIssue` a stable `fixID` (enum) separate from the display title and route on that.
- [ ] **`.security` double-dispatch hack.** `HealthCheckService.fix` for `.security` calls `gitDoctor.fix(issue)` first, then falls through to `securityDoctor.fix(issue)`, because GitDoctor also emits `.security` issues. Two doctors silently share one category and are disambiguated by "try one, then the other." A `fixID`/owner reference (above) removes the guesswork.
- [ ] **`fix` switch has a `default: return false` over an exhaustive enum.** A newly added `HealthCategory` compiles fine and silently becomes unfixable. Make the switch exhaustive so new categories force a decision.
- [ ] **Container/Java/Node are special-cased out of the status loop.** `runFullScan` skips them in the `HealthCategory.allCases` loop and appends their statuses manually (lines ~70–84). Easy to desync. Folds away once availability is part of the `Doctor` protocol.
- [ ] **Dead `storageDoctor` property in `DrCatalystViewModel`.** Line ~19 stores a `StorageDoctor()` that's never used; `scan()` creates a fresh `StorageDoctor()` inside the detached task instead. Remove one.

### Scoring & history
- [ ] **Score saturates and is uncalibrated.** Penalty model is critical=20 / warning=5 / info=1, `score = max(0, 100 - penalty)`. Five criticals = 0, and two very different machines both read "0" with no further resolution. No per-category weighting. Consider a normalized/curved score so the number stays meaningful at the bad end.
- [ ] **History is polluted by re-scan-after-fix.** `saveSnapshot` appends on *every* `scan()`, and `DrCatalystViewModel.fix` calls `scan()` after each fix. Fixing five issues one-by-one writes ~five snapshots minutes apart, and the 30-entry cap then evicts genuine older daily data, making the trend chart noisy and short-lived. Debounce (one snapshot per day, or only on score change) and/or key history by day.

### Per-checker bugs
- [ ] **DiskHygieneDoctor "fix" silently deletes DerivedData and lies about it.** `fix` does `try? FileManager.default.removeItem(at: derivedData)` then unconditionally `return true` — a failed delete reports success (re-scan then shows it still large). It's also a destructive wipe triggered straight from a "fix" button with no confirmation and no `PrivilegesService`. Check the throw, return real status, and gate destructive fixes behind a confirm.
- [ ] **SSH permission checks use opaque decimal magic numbers.** SecurityDoctor compares `permissions != 448` (0o700) and `!= 384` (0o600) with exact equality. Any extra mode bits (sticky/setgid) make a correctly-secured dir read as "unsafe." Mask with `& 0o777` and compare against `0o700`/`0o600` octal literals.
- [ ] **SecurityDoctor key-strength check only looks at `id_rsa`.** Line ~72 matches `lastPathComponent == "id_rsa"`; differently-named RSA keys are never checked. Also only `~/.zsh_history` is scanned for secrets (bash users skipped).
- [ ] **ConflictDoctor's NPM-shadowing check is Intel-only and login-shell-dependent.** It fires only when `which npm == "/usr/local/bin/npm"` — Apple Silicon brew lives at `/opt/homebrew/bin/npm`, so this never triggers on M-series. And `echo $NVM_DIR` in a non-login shell is often empty regardless. Use `BrewPathManager` prefixes and source the user's profile.
- [ ] **Inconsistent path quoting across checkers** (same theme as Passes 1–3). StorageDoctor/SecurityDoctor use `InputSanitizer.singleQuote`; DiskHygieneDoctor hand-builds `du -s -k '\(path)'`. Several commands rely on shell `~`/`$VAR` expansion (`zsh -n ~/.zshrc`, `chmod 700 ~/.ssh`) inside the string rather than resolved paths.

### StorageDoctor
- [ ] **Volume math is fragile on APFS.** `total`/`free` come from `attributesOfFileSystem(NSHomeDirectory())` `.systemSize`/`.systemFreeSize`, which ignore APFS purgeable space and report the whole volume; `percentUsed = used/total` divides by zero if the attrs call fails (total = 0). Use `URL.resourceValues(.volumeAvailableCapacityForImportantUsageKey)` and guard the divisor.
- [ ] **Category sizes via `du -sk` won't reconcile with the used bar.** `du` (apparent/linked-aware) counts differently from the volume math, so the category sum can exceed displayed "used." Fine for a relative breakdown — document it as approximate.

## 8. GhostBuster (`GhostBusterViewModel`)

### Code improvements
- [ ] **Allow/blocklist use loose substring matching on the command name.** `blockedProcesses.contains { cmd.contains($0) }` and `allowedDevKeywords.contains { lowerCmd.contains($0) }`. So "dock" protects any command containing it, "Catalyst" blocks anything with that substring, and allowlist "go"/"mongo" matches unrelated binaries (`google-chrome-helper`). Both false-allows and false-blocks. Tighten to token/exact matching on the process basename.
- [ ] **PID-reuse race between scan and kill.** Ghosts cache a `pid` at scan time; `killProcess`/`killAllGhosts` later `kill <pid>` with no re-check that the PID still maps to the same process. On a busy machine the OS can recycle the PID. Re-verify (e.g. by command name/port) immediately before killing.
- [ ] **`killAllGhosts` clears the list optimistically; per-process path doesn't.** Single-kill removes only on verified success, but kill-all wipes the whole list then re-scans — failed kills momentarily vanish and reappear. Make the two paths consistent (remove on verified success).
- [ ] **No privilege escalation path.** `killWithRetry` tries SIGTERM then SIGKILL 3× and gives up; a root-owned listener silently fails all attempts with a generic "Failed to kill." Either detect non-owned PIDs and route through `PrivilegesService`, or message the user clearly that elevated rights are needed.

### Feature ideas (Dr. Catalyst overall)
- [ ] **One-click "Fix all auto-fixable"** with a single batched re-scan at the end (instead of a full re-scan per fix — ties to the history-pollution item).
- [ ] **Per-issue "Explain / show command"** disclosure so a cautious user can see exactly what a fix will run before clicking.
- [ ] **Schedule periodic background scans** with a menu-bar badge when the score drops (pairs with the Pass-3 scheduled-scan idea).
- [ ] **Snooze / ignore** specific issues (e.g. an intentionally weak key on a throwaway VM) so they stop dragging the score.
- [ ] **GhostBuster: show full command line + working dir + uptime** per process, and remember user "always allow/ignore" choices.

# Pass - 5

"Discover / Configure" views — Popular Packages, SmartShortcuts, Aliases. These three share shell-config and installed-package plumbing.

## 9. Popular Packages (`PopularPackagesViewModel`)

This is the **cleanest VM in the app** — it uses `NetworkConfig.apiSession` (not raw `URLSession.shared`), sanitizes names, escapes paths, and streams install output. Use it as the reference the other package VMs should converge on. Remaining nits:

### Code improvements
- [ ] **Installed-package listing is duplicated a third time.** `getInstalledPip` / `getInstalledFormulae` / `getInstalledCasks` here are near-copies of the same logic in `PIPPackagesViewModel` and `BrewFormulaeCaskViewModel`. Extract one `InstalledPackagesService` and have all three VMs depend on it.
- [ ] **Version dropped again.** `getInstalledPip` splits `pip list --format=freeze` on `=` and keeps only the name (same loss flagged in Pass 3); `PopularPackage` itself only carries `downloads`, never an installed version.
- [ ] **Inconsistent caching strategy across VMs.** Popular packages are cached in `UserDefaults` with **no expiry**, while SmartShortcuts uses a 24h TTL and the brew/pip VMs use in-memory caches. Pick one caching policy.
- [ ] **Install builds a command string by hand** (`'\(pythonPath)' -m pip install '\(sanitizedName)'`) — move to array-args like elsewhere (shared theme).

## 10. SmartShortcuts (`SmartShortcutsViewModel`)

### Critical / security
- [ ] **Remote shell code is written into the user's startup file.** `installShortcut` fetches `\(baseURL)/\(shortcutId).json`, takes its `shell_code`, and appends it to `~/.zshrc_catalyst` — i.e. backend-served shell runs in every future login shell. That's an inherent remote-code surface. At minimum: show the exact code for review before install (confirm the detail view does), and consider signing/integrity-checking the catalog. Flagging explicitly because it's the highest-trust operation in the app.

### Code improvements
- [ ] **Dependency success/failure is decided by scraping output strings.** Brew/pip results are classified with `.contains("already installed")`, `.contains("Error")`, `.contains("already satisfied")`, etc. Locale- and version-fragile, and a package whose own output legitimately contains "error" aborts the install. Use exit codes (the runner already exposes `succeeded`/`exitCode`).
- [ ] **`brewPath` not escaped in the dependency install.** `"\(BrewPathManager.shared.brewPath) install '\(pkg)'"` quotes the package but interpolates the brew path raw (the package name is sanitized; the path isn't). Use `InputSanitizer.singleQuote`.
- [ ] **Uninstall uses brace-counting to find the function end.** It removes lines after `# CATALYST_ID:` by balancing `{`/`}`, which breaks on braces inside strings/heredocs/comments or one-line functions — can delete too much or leave a dangling block. Install should emit a `# CATALYST_END: <id>` sentinel and uninstall should delete strictly between markers.
- [ ] **`functionExists` is a substring match.** `content.contains("\(name)()")` false-positives (name `ls` matches `tools()`); parse declarations instead.
- [ ] **`replaceFirstOccurrence` can over-replace.** It does `string.replacingOccurrences(of: firstLine, ...)`, so if the first line's text recurs later in the snippet it's replaced everywhere. Operate on the first line by range.
- [ ] **Two parallel Python/pip detectors.** `getPythonWithPip` hardcodes `{brewPrefix}/bin/python3` and `/usr/bin/python3` and the prereq check shells `python3 -m pip --version`, both bypassing the app's `PythonService`. Route through `PythonService` for one source of truth.
- [ ] **`loadDetail` uses `URLSession.shared`** while `loadShortcuts` uses `NetworkConfig.apiSession` — inconsistent within the same file.

## 11. Aliases (`AliasViewModel`)

### Code improvements
- [ ] **Over-escaping breaks legitimate aliases.** `addAlias` escapes `$` (and backtick) before writing `alias x="..."`, so `alias gp="git push $1"` or one referencing `$HOME` is stored as `\$HOME` and won't expand when used. Safety vs. function trade-off — for aliases the user explicitly authored, escaping `$`/backtick defeats the purpose. Consider single-quote storage with proper single-quote handling, or let the user opt into literal vs. expanded.
- [ ] **Naive alias parser.** `parseAliasLine` splits on the first `=` and strips one surrounding quote pair. It mishandles inline comments (`alias x='y' # note` → command `y' # note`), unquoted values, and multiple aliases per line. Tighten the parser (or use a small tokenizer).
- [ ] **Delete depends on exact block format.** Removal keys off `# CATALYST_ALIAS: <name>` immediately followed by `alias <name>=`; the code comment itself admits it "assume[s] standard format." Hand-edited configs can orphan metadata comments or miss the alias. Same fix as SmartShortcuts: explicit BEGIN/END sentinels.
- [ ] **No edit path** — changing an alias means delete + re-add. Add in-place edit.

### Cross-cutting (Passes 5)
- [ ] **One managed-block manager for `.zshrc_catalyst`.** SmartShortcuts and Aliases each hand-roll their own block reader/parser/writer over the same file with different, fragile conventions. Build a single `ManagedBlock` reader/writer with explicit `# CATALYST_BEGIN/END <id>` sentinels and reuse it for functions and aliases.
- [ ] **One `InstalledPackagesService`** (see item 9) shared across all package VMs.
- [ ] **Stop classifying command success by output text** anywhere — standardize on exit codes (recurring across Passes 2, 3, 4, 5).

# Pass - 6

"Cruft Sweeper" (`CruftSweeperViewModel`) — recursive scanner for `node_modules`, venvs, build dirs, caches, etc. Well-architected overall (cancellable, producer/consumer parallelism, trashes rather than hard-deletes). Findings below.

## 12. Cruft Sweeper (`CruftSweeperViewModel`)

### Critical / correctness
- [ ] **`deleteSelected` is fire-and-forget — the UI updates before files are trashed.** It calls `await Task.detached { ... trashItem ... }` **without `.value`**, so `await` doesn't actually wait for the detached task; control falls straight through to the `MainActor.run` that removes items from the list. The list is cleared before (and regardless of whether) the trash succeeds — a failed trash leaves the item gone from the UI but still on disk. Add `.value` (or restructure) so the refresh runs after deletion completes and reflects real results.
- [ ] **Four lifters consume one `AsyncStream` concurrently.** `executeParallelScan` spawns 4 tasks that each `for await candidate in stream` over the *same* stream. `AsyncStream` is designed for a single consumer; multiple concurrent iterators are not a contract it guarantees and can drop or mis-deliver elements (it happens to work because of the internal buffer). Use a proper multi-consumer queue, or have one consumer fan out to a `TaskGroup` of size-calculators.

### Code improvements
- [ ] **"Protect active projects" measures the wrong timestamp.** `protectActiveProjects` compares the *cruft folder's* own `contentModificationDate` (e.g. `node_modules` mtime) against the cutoff. Active development edits source files, not `node_modules`, so an active project's deps can look "old" and get deleted, while a dead project whose deps were touched recently is protected. Measure the parent project's recent source activity (newest non-cruft file, or `.git` HEAD date) instead.
- [ ] **`deleteEmptyFolders` is inverted / inert.** When the toggle is ON, `processCandidate` does `if shouldDeleteEmpty && size == 0 { return }` — i.e. it *excludes* empty items rather than enabling their deletion, and no empty-folder deletion is implemented anywhere. Either rename the option to match the skip behavior or implement the feature it advertises.
- [ ] **Progress bar can't reach 100% organically.** Prescan counts every file; the main scan calls `enumerator.skipDescendants()` on every match, so it visits far fewer files than prescan counted, and `filesScanned += 500` only ticks on exact 500-boundaries (final partial batch never counted). Progress is then force-set to 1.0 at the end. Either count comparably in both phases or switch to an indeterminate/heuristic indicator.
- [ ] **Per-candidate MainActor hops for static options.** `processCandidate` reads `protectActiveProjects` and `deleteEmptyFolders` via `await MainActor.run` for *every* candidate. Snapshot these (and `targetFrameworks`) once at scan start and pass them in.
- [ ] **`venv` flagged purely by folder name.** Unlike `target`/`build` (which require sibling `Cargo.toml`/`pom.xml`/`build.gradle`/`Makefile` markers), any directory literally named `venv`/`.venv` is treated as a venv with no `pyvenv.cfg` check. Add a marker check for symmetry/safety.
- [ ] **`CruftType.unknown` is dead.** The scout never yields `.unknown`; remove it or wire up an "Other large dir" path.
- [ ] **Custom-path grouping is off.** `processResults` strips `home + "/"` to derive a group name; for `customCrawlPaths` outside home the prefix doesn't match and grouping degrades. Group by the chosen crawl root for custom paths.

### Positives (keep)
- [ ] Uses `trashItem` (recoverable) rather than `removeItem` — good; preserve this.
- [ ] Hard-skips `.ssh`, `.Trash`, and (optionally) `.git` — good safety defaults.

### Feature ideas
- [ ] **Size + count preview before trashing** with an undo hint ("Moved 12 items, 8.4 GB to Trash — Undo").
- [ ] **Saved scan profiles** (e.g. "Xcode only", "Node projects on Desktop") combining roots + frameworks + protection window.
- [ ] **Schedule a periodic sweep** (pairs with the scheduled-scan ideas in Passes 3–4).
- [ ] **"Rebuildable" reassurance** — note next to each type that it regenerates (`npm install`, `cargo build`, etc.) to lower delete anxiety.

# Pass - 7

Shared services / utilities layer — the foundation every VM sits on: `AsyncProcessRunner`, `PrivilegesService`, `InputSanitizer`, `ShellConfigManager`, `BrewPathManager`, `TerminalService`, `NetworkConfig`. Fixing things here fixes whole classes of bugs flagged in earlier passes.

## 13. AsyncProcessRunner (`Utilities/AsyncProcessRunner.swift`)

### Critical / architecture
- [ ] **No array-args exec path — the root cause of every escaping/injection finding in the sweep.** The actor only exposes `run(command:)`, which runs `/bin/zsh -c <string>`. Because there's only a string interface, every call site has to hand-build and hand-escape a shell line, and the ones that forget (Pass 3 pip/brew upgrade, Pass 5 brew path) become injection bugs. Add a `run(executable:args:[String])` that sets `process.arguments` directly (no shell, no quoting) and migrate package install/upgrade/uninstall/list calls to it. **Highest-leverage fix in the codebase.**
- [ ] **No timeout or cancellation.** A hung child process (network-stalled `brew`, a `sudo` waiting on stdin) blocks the awaiting Task forever. There's no `withTaskCancellationHandler`, so cancelling the Swift Task does not terminate the child — the process keeps running and the continuation never resumes. Add a timeout that calls `process.terminate()` (then `interrupt`/SIGKILL escalation) and wire cancellation to kill the child.

### Code improvements
- [ ] **`runWithStreaming` may not actually stream.** It drives output with `Timer.scheduledTimer`, which requires a live RunLoop on the calling thread; off the main thread the timer may never fire, so buffered output only flushes at process termination — defeating the purpose of streaming. Use the pipe's `readabilityHandler` (or `bytes` async sequence) instead of a Timer.

## 14. PrivilegesService (`Services/PrivilegesService.swift`)

### Critical / security
- [ ] **`validateSafeToDeletePath`'s blocklist loop is dead code.** The `blockedPrefixes` loop (≈lines 51–55) only `break`s — it never returns/throws — so it enforces nothing. Real safety rests entirely on the `safeAreas` allowlist (deny-by-default), which is fine, but the dead loop reads as protection that isn't there. Remove it or make it actually reject.
- [ ] **Leftover special-case returns `true` for `/homebrew` + `/AGENTS.md` paths** (≈line 73). Looks like debug residue; it's an unintended allow rule in a security-sensitive validator. Delete it.
- [ ] **Password transits the child process's argv.** `runWithPrivileges` pipes the password into `sudo -S` via an osascript-built `sh -c` line, so during execution the password is visible to `ps`/`/proc` for any local user. Better than the Pass-1 plaintext-file approach, but still weak. Prefer passing the secret on stdin to `sudo -S` without it ever appearing in an argument vector, or use an authorization framework path.

### Code improvements
- [ ] **`removeFiles` double-escapes paths.** It builds `rm -rf '\(shellEscape(path))'` and then hands that to `runWithPrivileges`, which escapes `\` and `"` *again*. Paths containing single quotes get corrupted (and may delete the wrong thing or fail). Escape exactly once — ideally via array-args `rm` once the new exec path (item 13) exists.
- [ ] **Two Homebrew install paths, one safe and one not.** `installHomebrew` here (≈line 193) uses `TerminalService` (visible, no password capture) — this is the safe one. `DashboardViewModel`'s install (Pass 1) writes the password to `/tmp/catalyst_askpass.sh`. Delete the unsafe path and route Dashboard's "Install Homebrew" button to this service.

## 15. InputSanitizer (`Utilities/InputSanitizer.swift`)

### Code improvements
- [ ] **`shellEscape` is safe only inside single quotes, but is callable bare.** `shellEscape(s)` does `'` → `'\''`, which is correct only when the result is wrapped in `'...'`. Several call sites interpolate it *unwrapped*, which is unsafe. Make `shellEscape` private and force everyone through `singleQuote(s)` (which wraps). This collapses the recurring "hand-rolled escaping" finding from Passes 2–5.
- [ ] **`sanitizePackageName` rejects valid installs.** The regex `^[a-zA-Z0-9][a-zA-Z0-9._@-]*$` forbids `==`, `>=`, `+`, `:`, `/`, so version pins (`requests==2.31`), extras, and VCS/URL installs are silently rejected. Either widen the allowed set for the pip case or validate name and version-spec separately.
- [ ] **`validateSafePath` is over-broad.** Blocking `$ ( ) < > &` rejects legitimate paths/filenames containing those characters. With proper single-quote wrapping (item above) these are harmless. Loosen once quoting is centralized.

## 16. ShellConfigManager (`Services/ShellConfigManager.swift`)

### Code improvements
- [ ] **No shared managed-block primitive.** This exposes raw `append/write/readCatalystConfig`, and SmartShortcuts + Aliases each build their own fragile parser on top (Pass 5). Add `ManagedBlock` read/write/delete here with explicit `# CATALYST_BEGIN/END <id>` sentinels and have both features use it. Single home for the convention.
- [ ] **No file locking — concurrent writes can race.** Adding a shortcut and an alias at the same time both read-modify-write `.zshrc_catalyst` with no coordination; last writer wins and can drop the other's block. Serialize writes (an actor or a write queue).
- [ ] **Single-slot backup.** `backupCatalystConfig` keeps only one `.backup`, so a second operation overwrites the only recovery copy. Keep a small rotation (timestamped, capped).
- [ ] **`ensureCatalystSourced` rewrites `.zshrc` by substring match.** It removes any line containing `.zshrc_catalyst` and re-appends the source line; a user comment mentioning the file, or a custom guard, would be clobbered. Match the exact managed source line only.

## 17. Largely clean (converge on these)

- [ ] **`NetworkConfig` is the networking standard.** Typed `fetchJSON<T>`, tuned `apiSession`/`downloadSession`, `NetworkError` enum, single `baseURL`. Migrate every remaining `URLSession.shared` call site (Passes 1–3, 5) onto it. No changes needed to the file itself.
- [ ] **`BrewPathManager`** — solid (async init + `ensureInitialized`, NSLock, Apple-Silicon/Intel resolution). Minor: `getInstalledPythons` regex is fine; nothing actionable.
- [ ] **`TerminalService`** — reasonable; rejects newlines/control chars before building the AppleScript. Keep as the user-visible execution path (and the Homebrew-install path, item 14).

# Pass - 8

Supporting views & infrastructure — SSD Health (Disk Vitals), Logs, About, and the `Logger`. SSD Health is the substantive one; About is clean; Logs has a real "clear doesn't clear" bug.

## 18. SSD Health / Disk Vitals (`SSDHealthService`, `SSDHealthModels`, `SSDHealthViewModel`, `SSDHealthView`)

### Critical / correctness
- [ ] **Parser is NVMe-only but the validity gate also accepts SATA output.** `parseSmartctlOutput` keys off NVMe field names (`Data Units Read`, `Available Spare`, `Percentage Used`, `Number of Namespaces`). But `scan` accepts output if it contains *either* `SMART overall-health` *or* `START OF SMART DATA SECTION` (the latter is the SATA/ATA format). A SATA SSD or USB-bridge drive passes the gate, then every NVMe key misses and the report is silently all-zeros (100°C → 0, 0% wear, etc.), shown to the user as real data. Either branch on bus type and parse the ATA attribute table separately, or explicitly reject non-NVMe output with a clear message.
- [ ] **`extractValue` uses substring key matching — wrong line wins.** It returns the first line where `line.contains(key)`, so `key: "Temperature"` can match `Warning Comp. Temperature` or `Temperature Sensor 1`, and a short key can match a longer label. Anchor on the field name (exact left-of-colon match) instead of `contains`.
- [ ] **`|| true` masks smartctl's exit code.** The scan command ends in `|| true`, so a genuine failure (permission denied, device busy, unsupported) returns success and is then judged solely by scraping output text — the same success-by-text anti-pattern flagged across Passes 2–5. Keep the real exit code and branch on it.

### Code improvements
- [ ] **`healthScore` is ad-hoc and double-penalizes.** `score -= min(percentageUsed, 100)` alone can zero the score from wear while `availableSpare` is also subtracted; `percentageUsed` can legitimately exceed 100 on SMART. A drive at 100% rated wear that's otherwise fine reads as 0/100. Define an explicit, documented weighting (and clamp inputs) rather than stacked subtractions.
- [ ] **`detectBootDisk` base-disk regex is brittle.** `replacingOccurrences(of: "s\\d+$", ...)` strips only the trailing `sN`; APFS synthesized devices (`/dev/disk3s1s1`) and container members aren't reliably reduced to the physical device. Use `diskutil info -plist` / parse the APFS container's physical store instead of regex on the device node.
- [ ] **Real serial number is persisted in plaintext cache.** `maskedSerial` only masks the UI; `ssd_health_cache.json` stores the full `serialNumber`. If masking is a privacy goal, mask (or omit) at persistence time too.
- [ ] **Two different Application Support subfolders.** SSD cache lives in `…/Application Support/Catalyst/`, while `Logger` writes `…/Application Support/com.shivanggulati.catalyst/`. Pick one app-support root for all on-disk state.
- [ ] **Boot-disk detection via `diskutil | grep | awk`** — a shell pipeline string; fine functionally but another raw-command call to fold into the array-args runner (Pass 7 item 13).
- [ ] **Every scan re-prompts for admin password** (PrivilegesService) — ties to the Pass-14 password-via-argv weakness; worth resolving there once.

## 19. Logs (`LogsViewModel`, `LogsView`, `Logger`)

### Correctness
- [ ] **"Clear" doesn't actually clear.** `clearTerminalLogs`/`clearDebugLogs` only reset the view-model's `String` copies; the `Logger`'s in-memory buffers and `app.log` file are untouched. Re-entering the view (or `startup()` reloading from the buffer) repopulates everything, so the button looks broken. Add a `Logger.clear(category:)` that empties the buffer (and optionally truncates the file) and call it.
- [ ] **`Logger.getAllLogs()` sorts by formatted-string timestamp.** It merges the two buffers and `.sorted()`s them lexically, but the timestamp format is `"MMM dd, yyyy h:mm:ss a"` — alphabetical sort ≠ chronological (e.g. "Apr" precedes "Jan"). The merged/sorted output is mis-ordered. If still used, sort by a real `Date`; if dead, remove it.

### Code improvements
- [ ] **Two divergent truncation policies.** `Logger` caps each buffer at 1000 entries; `LogsViewModel.appendLog` independently caps the view string at 500 KB and drops the front. The view and the underlying buffer can show different windows of history. Pick one source-of-truth retention policy.
- [ ] **`stat` on every log line.** `writeToFile` calls `attributesOfItem` to check size before each append. For chatty terminal output that's a syscall per line; check size periodically (every N writes or by tracking bytes written).
- [ ] **`NSSavePanel` lives in the view-model.** `exportAllLogs` drives AppKit UI directly from `LogsViewModel` — minor MVVM leak; move panel presentation to the view and pass back the chosen URL.
- [ ] **Combine `send` happens inside `bufferQueue.async`.** Subjects are fired from the background buffer queue; subscribers correctly `.receive(on: .main)`, so it works, but emitting from the same queue that mutates the buffer couples ordering to that queue. Document or isolate.

## 20. About (`AboutViewModel`, `AboutView`) — clean

- [ ] **Reference for networked VMs.** Uses `NetworkConfig.fetchJSON` with a graceful hardcoded fallback — exactly the pattern Passes 1–3/5 should adopt. Nits only: the fallback's `releaseDate` ("2026-02-15") and highlights are frozen and will drift from the real release; and the links-divider logic indexes `availableLinks` but only renders entries with a valid `URL`, so an invalid URL skips a row yet its divider accounting can misalign. Both minor.

## Cross-cutting (confirmed again this pass)
- [ ] **Success-by-text recurs in SSD scanning too** — standardize on exit codes everywhere (now seen in Passes 2, 3, 4, 5, 8).
- [ ] **On-disk state is scattered** across `Application Support/Catalyst`, `Application Support/com.shivanggulati.catalyst`, and `UserDefaults` (popular-packages cache, etc.). Define one storage layout.

# Pass - 5 (Performance) — SwiftUI Re-render & Rendering Audit

> **Audit only — no fixes applied yet (2026-06-12).** Findings below; we fix in a later pass with a before/after diff per change and no business-logic edits. Naming note: the original code sweep already used "Pass 1–8"; this performance audit is labelled "Pass - 5 (Performance)" per request — renumber if it's confusing.
>
> **The core fact this audit rests on:** an `ObservableObject` has exactly one `objectWillChange` publisher. Mutating **any** `@Published` property on it invalidates **every** SwiftUI view that holds it via `@ObservedObject`/`@StateObject`/`@EnvironmentObject` — SwiftUI then re-runs those views' `body`. It does not matter that a view only reads one property; it re-renders on every property's change. So a 34-`@Published` god view-model that is passed wholesale into a dozen subviews means one streaming-log append re-renders the entire screen.
>
> **UI-consistency guarantee for the fix pass:** the visual swaps below (Divider → 1px `Color`/`Rectangle`, removing `.shadow`, `Material` blur → solid `controlBackgroundColor`) keep corner radius, padding, fills, and spacing identical — the app should look the same minus shadows/blur (user has explicitly OK'd dropping those two, as they were the iOS-app culprits too).

## R1 — God-object view models observed wholesale *(dominant cause; structural)*

Every screen has one large `@MainActor ObservableObject` injected into all of its subviews as `@ObservedObject`. Any single `@Published` mutation re-renders the whole screen.

- [ ] **`DashboardViewModel` (34 `@Published`)** is passed as the same `vm` into `SystemStatusCard`, `InstalledPythonsCard`, `InstallPythonCard`, `UninstallCard`, `BrewMaintenanceCard`, and each `PythonInstallationRow` (`Views/DashboardView.swift`, `Views/Components/DashboardCards.swift`). A change to `brewInstallOutput`, `isBrewUpdating`, `repairingPipFor`, `upgradingPipFor`, `brewSystemStats`, etc. re-runs **all** of those bodies. **Fix (structural):** the deferred VM split (`DetectionService`/`PythonManager`/`BrewMaintenanceManager`) — each subview observes only its own small object. Until then, see R2/R3 for the safe, high-value isolations.
- [ ] **Same shape on every screen** — `CruftSweeperViewModel` (17), `PopularPackagesViewModel` (14), `SmartShortcutsViewModel` (13), `FormulaeCaskInstallViewModel` (12), `RequirementsViewModel` (11), `OutdatedPIP/Brew` (11/10), `BrewFormulaeCaskViewModel` (11) — all injected whole into their views. **Fix principle:** (a) leaf rows must not observe the screen VM (see R1-row); (b) high-churn substate gets its own observable (R2); (c) derived collections precomputed, not in `body` (R3).
- [x] **R1-row: leaf rows take the whole VM.** ✅ APPLIED. Dashboard/Cruft rows done previously (`PythonInstallationRow`, `MaintenanceOperationRow`, `CruftItemRow`). 2026-06-13: the **package/outdated list rows** that already took plain values but were missing the body-skip optimization are now `Equatable` with a custom `==` (closure ignored) + `.equatable()` at every call site — `OutdatedPackageRow` (OutdatedPIP/Brew), `PopularPackageRow` (Popular), `InstalledPackageRow` (PIP install list + both Formulae/Cask tabs). These rows now skip `body` when an unrelated `@Published` on the parent screen VM changes. (Pure-value child views are diffed by `Equatable`, not invalidated by the parent's object.)

## R2 — High-frequency streaming `@Published` appends on a screen-wide VM *(◧ PARTIALLY APPLIED 2026-06-12)*

Streaming command output is appended chunk-by-chunk (the runner flushes ~every 0.1s) directly onto the screen's god-VM, so the **entire screen** (including big searchable catalog lists) re-renders on every chunk.

- [x] **Install consoles** — ✅ APPLIED 2026-06-12. Added `Helpers/ConsoleOutput.swift` + `ConsoleOutputView`. Migrated all six consoles via a **computed bridge** (`var installationOutput { get { console.text } set { console.set(newValue) } }`) so the output string is no longer `@Published` on the screen VM — the parent stops re-rendering per chunk; only the small `ConsoleOutputView` (which observes `console`) updates. Done for `PIPPackagesInstallViewModel`, `PopularPackagesViewModel`, `RequirementsViewModel`, `SmartShortcutsViewModel`, `FormulaeCaskInstallViewModel`, and `DashboardViewModel.brewInstallOutput`. The bridge is **immediate (not coalesced)**, which deliberately preserves the in-flight `.contains(…)` link-detection (FormulaeCask) and `updateBrewUnlinkedKegs(from:)` / warnings checks (Dashboard). Views switched to `ConsoleOutputView(console: vm.console)` and the `if !vm.x.isEmpty` parent gates removed (the wrapper self-hides). *(`doctorOutput` left as-is — separate property; convert opportunistically.)*
- [x] **Logs** — ✅ `LogsViewModel` now **coalesces** appends (pending buffer + ~120ms flush) so a burst is one `@Published` mutation, not N; clear() flushes the buffer. Dropped the pointless single-child `LazyVStack` in `LogsView` (renders the `Text` directly). Tail already capped at 500KB.
- [x] **Cruft scan progress** — ✅ APPLIED 2026-06-13. The `AsyncStream` engine move did **not** fix this (correcting the HANDOFF "moot" note): `CruftScanner` emits `.progress` every 500 files (count-based, not time-based), and the VM mapped each to three `@Published` writes → dozens of whole-view re-renders/sec on a fast SSD. Now coalesced to ~10/sec via `shouldFlushProgress()` in the scan event loop; `latestScannedCount` records every tick (plain var) and the finalize block flushes the true final `filesScanned`. `.prescanProgress` throttled too. No business-logic change.
- [x] **NetworkMonitor redundant publishes** — ✅ `setStatus(_:)` + guarded `updateSystemStatus` only assign `@Published` on real change, so the 30s connectivity poll no longer re-renders the always-visible sidebar each cycle when nothing changed.

## R3 — Computed properties doing real work inside `body` (run every render) *(✅ APPLIED 2026-06-12)*

- [x] **`LiveMetricsGrid`** ✅ Eight `vm.issues`-scanning vars moved into a `DrLiveMetrics` struct computed once in `DrCatalystViewModel.recomputeDerived()` (on `issues` `didSet`); the grid now reads `vm.liveMetrics.*`.
- [x] **`InstalledPythonsCard` sorts in `body`** ✅ `DashboardViewModel` exposes `sortedInstalledPythons`, sorted in `installedPythons.didSet`; both card sites read it (no `.sorted{}` in `body`).
- [x] **Filter/sort computed props** ✅ `AliasViewModel.filteredAliases/catalystAliases/otherAliases` and `SmartShortcutsViewModel.filteredShortcuts/categories` are now stored `@Published private(set)`, recomputed on their driving `didSet`s (aliases/search/category). `DrCatalystViewModel.criticalCount/warningCount/infoCount` likewise stored + recomputed on `issues` change. *(View-side `DrCatalystView.criticalIssues/warningIssues/infoIssues` display groupings left as-is — separate from the counts.)*

## R4 — Per-call `DateFormatter` allocation *(✅ APPLIED 2026-06-12)*

- [x] **`OutdatedUpdating.formattedLastScanDate`** ✅ Now uses a file-scope cached `static let` formatter (`OutdatedScanDateFormat`) instead of allocating a `DateFormatter()` per access. (The two `ISO8601DateFormatter()` write-path allocations remain — low-frequency, fix opportunistically.)

## R5 — Heavy view primitives re-rendered frequently *(✅ APPLIED 2026-06-12)*

> **R5 is done in code** (compiler-unverified — needs `xcodebuild`; new file `Helpers/SectionDivider.swift` should auto-join via the Xcode-16 synchronized group, confirm if a "cannot find SectionDivider" error appears). Visual intent: identical layout/spacing/fills; cards lose drop shadows but gain a hairline opaque border so edges stay defined; two **pinned overlays** keep their material+shadow (Metapace's exemption).

- [x] **`Divider()` everywhere → `SectionDivider`.** ✅ Added `Helpers/SectionDivider.swift` (your 2pt opaque `Rectangle` in `Color(NSColor.separatorColor)`, `.accessibilityHidden`). Replaced **all `Divider()` in 26 view/helper files** with `SectionDivider()` (0 left). Sidebar `List` was already `Divider`-free, untouched. *(2pt opaque, not 1px — per Metapace Rule 33.)*
- [x] **`.shadow()` removed.** ✅ Dropped the app-wide `cardStyle(.standard)` shadow and **replaced it with a hairline opaque border** (`strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)`) so cards keep edge definition (Metapace Rule 31). Removed all explicit card shadows (`MetricCard`, `SSDHealthCards`, `DrCatalystCards` card, `CruftSweeperCards`, `StorageDNAView`, `ShortcutCard`, `AboutView`, `SSDHealthView`). **Kept** the Dr. Catalyst hover-**tooltip** `shadow(radius:10)` — a pinned overlay, exempt.
- [x] **`Material` blur → solid.** ✅ Replaced `Material.regular`/`regularMaterial` on **scrolling** cards (`LiveMetricsGrid`, `SSDHealthCards`, `CruftSweeperCards` footer bar) with `Color(NSColor.controlBackgroundColor)`. **Kept** the two **pinned overlays**: Dr. Catalyst tooltip `thickMaterial` and the Cruft **scan HUD** `thinMaterial` (non-scrolling, exempt).

## R6 — Misc

- [ ] **`LazyVStack` with a single child** (LogsView) — provides no virtualization; either render plainly or actually chunk the log. (Folds into R2.)
- [x] **`@Published` used for non-UI cache state** — ✅ AUDITED 2026-06-13. Swept every VM's `@Published`. Only two never reach a View: `DashboardViewModel.brewState` / `commandLineToolsState` (read solely by `AppViewModel.fullRefresh` logic; no View, no `$`-subscription) → demoted to plain `var`, so detection no longer fires a redundant Dashboard-wide `objectWillChange` (the sibling `*Status` strings still drive the visible update). All other Sets/dicts checked **do** drive UI indirectly and were correctly left `@Published`: `installedShortcuts`→`isInstalled`/`getCustomName` (SmartShortcutsView), `missingProjectIDs`→`isProjectMissing` (VirtualEnvironmentsView), `installedPip/Formulae/Casks`→`isInstalled` (Popular/Install views), `processingPackages`→row `isProcessing`, `selectedIDs`/`targetFrameworks`/`selectedVersionsToUninstall`→selection UI, `lastScanDate`/`lastScanTime`→`formattedLastScanDate`.

## Suggested fix order (highest leverage first)
1. **R5** (Divider/shadow/Material) — purely cosmetic-neutral, app-wide, zero business-logic risk, big paint-cost win. Do via `cardStyle`/a shared hairline helper so it's a handful of central edits.
2. **R2** (isolate streaming consoles + log into a small `ConsoleOutput` observable; coalesce) — kills the worst per-chunk whole-screen re-renders.
3. **R3 + R4** (precompute derived collections; cached formatter) — removes per-render CPU.
4. **R1-row** (stop leaf rows observing the screen VM; pass values).
5. **R1 structural** (god-VM decomposition) — tracked with the deferred `DashboardViewModel` split; do with a compiler.

## Structural items flagged (not to be done silently)
- [ ] **Decompose the god view models** (Dashboard first, then the other ≥12-`@Published` screens) into per-section observables. This is the real cure for R1 and overlaps the already-deferred `DashboardViewModel` split — needs a build in the loop.
- [ ] **Console/log streaming architecture** — introducing a shared `ConsoleOutput` observable is a small structural change touching every install screen + Logs; worth doing as one coherent change rather than ad hoc.

---

## Reconciliation with the Metapace "Form Rules" (iOS) — `Formrules.md`

Cross-checked our audit against the battle-tested Metapace rule set. Its **Part 8 (Dismissal & Performance, Rules 30–37 + anti-patterns 19–26)** is platform-agnostic SwiftUI and transfers 1:1 to this macOS app (macOS trackpad/inertial scrolling has the same sub-pixel shimmer, per-frame material re-blur, and shadow re-rasterization). Parts 2/3/7 and the Phase-4 IAP rules are iOS-specific (`NavigationStack`/`fullScreenCover` nesting, `beginBackgroundTask`/background `URLSession`, `UIScrollView` keyboard) and **do not apply** to our `NavigationSplitView` + `NSColor` macOS app.

**Rule → our finding mapping (transfers to macOS):**

| Metapace rule | Our finding | Status in audit |
|:--|:--|:--|
| 31 — no `.shadow` on scrolling cards | R5 shadow (cardStyle + per-card) | covered |
| 32 — no material/blur over scrolling content | R5 Material (5 component files) | covered |
| 33 — no 1px hairlines as separators (use 2pt opaque) | R5 Divider | **corrected** (2pt opaque, not 1px) |
| 34 — cache expensive per-`body` computed values | R3 (LiveMetricsGrid, sort-in-body, filtered/count props) | covered |
| 34 note — don't full-`sorted{}.first` for one element (use `max/min(by:)`) | R7 (new) | **added — no current violations, kept as a guard rule** |
| 35 — never allocate `DateFormatter` per call/row | R4 | covered |
| 36 — `LazyVStack`/`List` for growing lists | R8 (new) | **added** |

**New findings surfaced by the reconciliation:**

- [ ] **R7 — `sorted{}.first/.last` for a single element.** Metapace Rule 34-note: a full `.sorted()` just to grab one element allocates a whole array each call; use `max(by:)`/`min(by:)` (O(n), no alloc). **Grep result: no current violations** in Catalyst (the only `.sorted()` uses render the whole ordered list, which is legitimate). Kept as a standing guard for the fix pass and new code.
- [x] **R8 — growing `ForEach` in a plain `VStack`.** ✅ APPLIED 2026-06-12. Wrapped the growing lists in `LazyVStack`: **`VirtualEnvironmentsView`** (projects), **`RequirementsView`** (failed-packages list), **`VirtualEnvCreationSheet`** (failed + successful package lists). Bounded sets (`AboutView`/`ShortcutDetailView`/installed-Python picker) left as plain `VStack` per Rule 36.
- [ ] **R7b — hairline `lineWidth: 1` strokes (17 sites).** Reconciling Rules 31 vs 33: a 1px **card-outline border** is *fine* (Metapace Rule 31 explicitly recommends it as the shadow replacement — `.stroke(Color.primary.opacity(0.10), lineWidth: 1)` + opaque fill). Only 1px used as a **primary horizontal separator** shimmers. So our existing `lineWidth: 1` card outlines (`cardStyle` compact, `BannerView`, `MetricCard`, `DrCatalystCards`, `SSDHealthCards`) **stay** — and in fact become the visual replacement for the shadows we remove in R5. Action: when removing the `cardStyle` standard shadow, add the same hairline opaque border so cards keep their edge definition.
- [ ] **R9 — continuously-repeating animations on scrollable cards.** `DrCatalystCards:188` runs an `.easeOut(...).repeatForever` pulse and `:163` a transition; `StorageDNAView`/`SSDHealthCards` have value-driven animations. A `repeatForever` animation on a card living in a `ScrollView` keeps a render loop alive. **Low priority** — verify it's only on a single non-list hero element (the vitality pulse), not multiplied across rows; gate with `.animation(nil)` when off-screen if needed. (Launch-screen animations are exempt — that view isn't scrolling.)

**Process note for the fix pass (adopted from Metapace's doc style):** when we fix, each change ships with a before/after diff, touches no business logic, and we centralize the cosmetic swaps (shadow/divider/material) into the single `cardStyle`/`CatalystDivider` sources of truth so it's a handful of edits, not a scatter — mirroring how Metapace put `SectionDivider`/`AppDateFormatters`/`AppCard` in one place.
