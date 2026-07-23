# Catalyst — The Complete Understanding & Reference

> **What this document is.** The single canonical reference for Catalyst — the
> source of truth for how the app works, feature by feature, and how it is built.
> It serves three audiences at once:
> 1. **New developers / LLMs** decoding the codebase before changing it.
> 2. **The documentation website** — this is the content the Catalyst docs site is
>    designed from, so every feature is described in full, including the safety and
>    consent mechanisms behind it.
> 3. **Reviewers** verifying that a change respects the app's guarantees.
>
> **Companion docs:** enforced coding ground rules → `CODING_STANDARDS.md` ·
> scroll-smoothness deep-dive → `ANTI_PATTERNS.md` · release runbook → `RELEASING.md`.
>
> **Status.** This describes the current build. Catalyst was a paid app until v1.0; the
> accounts, entitlement, payments, invoicing and backend that went with it were removed, and
> so were the sections describing them. §49.14 records what changed and why. Where a deleted
> system taught something durable, the lesson lives in `CODING_STANDARDS.md` Part 12.
>
> **How to read it.** Part I is the product overview. **Part II is the full feature
> reference** (the heart of the doc — read this to understand what Catalyst does and
> the guarantees each feature makes). Parts III–XII are the engineering internals.
> Use §0 to jump.

---

## 0. Table of contents

- **Part I — The product**
  - §1 The central idea · §2 At a glance
- **Part II — Feature reference (every screen, in detail)**
  - §3 Dashboard · §4 Virtual Environments · §5 pip Packages · §6 Formulae/Casks ·
    §7 pip Updates · §8 Formulae/Casks Updates · §9 Install pip Packages ·
    §10 Install Formulae/Casks · §11 requirements.txt Installer · §12 Popular
    Packages · §13 SmartShortcuts · §14 Aliases · §15 Terminal Time Travel ·
    §16 PATH Editor · **§16b Git Graph** · §17 Dr. Catalyst · §18 Disk Vitals ·
    §19 Battery Health · §20 Cruft Sweeper · §21 Network Diagnostics · §22 Startup
    Items · §23 SSH Keys · §24 Logs · §25 About · §26 Menu-bar mode ·
    **§S Snapshot & Migrate (Migration)**
  - §27 **The install-mode / break-system-packages consent system** (cross-cutting)
- **Part III — How it's built**
  - §28 Architecture & layers · §29 Composition root & lifecycle · §30 File map
- **Part IV — Execution & safety**
  - §31 The three execution tiers · §32 Sanitization · §33 Safe deletion ·
    §34 Brew path resolution
- **Part V — Internals**
  - §35 Concurrency & data flow · §36 Networking & caching · §37 Persistence ·
    §38 Logging · §39 The UI design system
- **Part VI — Working on Catalyst**
  - §40 Recipe: add a screen · §41 Recipe: add a Doctor · §42 Xcode registration
    ritual · §43 Testing · §44 Reverse index · §45 Glossary · §46 Gotchas
- **Part VII — Roadmap**
  - §47 CatalystSnapshot (shipped v1 — deep dive) · §48 Git Graph (shipped v1 — deep dive)

---

# Part I — The product

## 1. The central idea

**Catalyst is a native macOS control panel that gives developers GUI-level power
over their Mac's developer environment — turning long, error-prone terminal
workflows into a few clicks.**

Setting up and maintaining a Mac for development means living in the terminal:
installing Homebrew formulae and casks, juggling Python versions and pip packages,
creating virtual environments, editing `~/.zshrc` aliases, hunting zombie processes
hogging ports, diagnosing why `git` or `node` is broken, freeing disk space, and
checking drive/battery health. Each is doable from the command line — but only if
you remember the exact incantations, and only if you get the flags right.

Catalyst wraps all of it in a clean, dark-themed SwiftUI interface that gives the
user three things:

- **Visibility** — live system status, health scores, disk maps, battery/SSD vitals.
- **Control** — one-click install / uninstall / update across package managers.
- **Guided maintenance** — a "doctor" that scans, scores, and auto-fixes environment
  problems, plus sweepers and cleaners.

…without touching a terminal unless they want to — and **without ever doing
something destructive or system-altering without explicit, informed consent.**

Every feature is a variation on one loop:

```
User intent (a click)
   → ViewModel builds a safe, sanitized command
      → an Execution tier runs it off the main thread
         → output streams back / an exit code is checked
            → @Published state updates → SwiftUI re-renders
               → (optionally) a global refresh re-syncs the whole app
```

The app's real value and real risk both live in the middle step: **running shell
commands on the user's behalf, safely.** That is why the execution layer (Part IV)
is the most carefully guarded part of the codebase, and why several features expose
explicit consent gates (most notably the break-system-packages flow, §27).

Product framing: **"Mission control for your Mac dev environment."**

## 2. At a glance

| Property | Value |
|---|---|
| Platform | macOS (native, AppKit-bridged where needed). **Not iOS.** |
| Language / UI | Swift + SwiftUI |
| Architecture | MVVM + a service layer; manual dependency injection |
| Entry point | `Catalyst/CatalystApp.swift` (`@main`) |
| Composition root | `ViewModels/AppViewModel.swift` |
| Bundle ID | `com.shivanggulati.catalyst` |
| Deployment target | macOS 14.6 (app target) |
| Version | 1.0 (build 1) |
| Persistence namespace | `~/Library/Application Support/com.shivanggulati.catalyst/` (same as the bundle ID) |
| Color scheme | Forced dark (`preferredColorScheme(.dark)`) |
| Backend | None. Two GitHub Pages sites of read-only static JSON — catalogs at `data.theappfoundry.co/catalyst`, update feed at `updates.theappfoundry.co/catalyst` (§36) |
| Screens | 25, grouped into 9 sidebar sections (incl. **Developer Workflow → Git Graph**, §16b, and **Migration → Snapshot & Migrate**, §S) |
| Diagnostics | 16 concurrent "Doctor" checkers + a separate StorageDoctor |
| Windows | Main `WindowGroup` + a `MenuBarExtra` (menu-bar mode) |
| Source files | ~167 app Swift files |
| Tests | None — the XCTest target was removed at v1.0 (§43) |

---

# Part II — Feature reference

Each feature below documents **what it does**, **how it works** (the backing code),
and **the safety/consent guarantees** it makes. Every screen is one SwiftUI View +
one `@MainActor` ViewModel, wired through `AppViewModel.Screen` and rendered by the
`ContentView` sidebar + detail split. The sidebar groups are shown as headings.

## Project Management

### 3. Dashboard
**What it does.** The home screen and mission-control surface. Shows live system
metrics, Homebrew and Python install status, a health-score summary (from Dr.
Catalyst), and is the entry point for the app-wide refresh.

**How it works.** `DashboardView` + `DashboardViewModel` (the largest VM). It reads
`BrewService`, `PythonService`, `PrivilegesService`, and health data, and owns the
`onGlobalRefresh` hook that `AppViewModel` wires to `fullRefresh()`. `LiveMetricsGrid`
and `DashboardCards` render the metric tiles. Any install/uninstall performed
elsewhere routes a refresh back through the Dashboard so the whole app re-syncs.

**Safety/consent.** Read-only surface; the actions it triggers (refresh, navigation)
are non-destructive.

### 4. Virtual Environments
**What it does.** Create and manage Python virtual environments (venvs) and track
project folders that contain them.

**How it works.** `VirtualEnvironmentsView` + `VirtualEnvironmentsViewModel`, with a
`VirtualEnvCreationSheet` + `VirtualEnvCreationViewModel` for creation. `VenvBuilder`
creates the venv; `ProjectScannerService` scans a chosen folder for project markers
(`requirements.txt`, `Pipfile`, `pyproject.toml`, `setup.py`, `.python-version`) and
**one-off git repo details** (current branch, local branch count, tag count, remote
URL) surfaced in the creation sheet. Tracked projects persist via `ProjectStore`
(`projects.json`).

**Safety/consent.** **Virtual environments are never externally managed**, so pip
inside a venv is *never* given the `--break-system-packages` flag and venv-related
actions are **never gated** by install mode (§27). Creating a venv is additive and
non-destructive.

## Manage Existing Packages

### 5. pip Packages
**What it does.** List, inspect, and uninstall installed pip packages, per detected
Python interpreter.

**How it works.** `PIPPackagesView` + `PIPPackagesViewModel`, backed by
`PythonService` (interpreter detection) and `InstalledPackagesService`. The Python
selector (`SelectPythonVersionDropdown`) chooses which interpreter's site-packages to
inspect. `PythonService.scanForPythons` scans `<brewPrefix>/bin` and accepts **only real
interpreter names** via regex `^python(3(\.[0-9]+)?)?$` (`python`, `python3`, `python3.12`) —
this excludes pyenv/build helpers like `python-build`/`python-config`, whose `--version` reports
the *tool's* version and was previously leaking a bogus "2.x" interpreter into the dashboard (fix 2026-07).

**Safety/consent.** Uninstall is a mutating action confirmed in the UI; package names
are sanitized before reaching pip (§32).

### 6. Formulae / Casks (installed)
**What it does.** List and manage installed Homebrew formulae and casks.

**How it works.** `BrewFormulaeCaskView` + `BrewFormulaeCaskViewModel` over
`BrewService`. Brew paths are resolved by `BrewPathManager` (Apple Silicon vs Intel),
never hardcoded.

**Safety/consent.** Uninstall confirmations; some brew operations may require the
elevated tier (§31b).

## Update Existing Packages

### 7. pip Updates
**What it does.** Find outdated pip packages for a chosen interpreter and update them,
one by one, with live per-package progress and an end-of-run summary.

**How it works.** `OutdatedPIPView` + `OutdatedPIPViewModel`. **The scan uses
`<python> -m pip list --outdated --format=json`** — which honors `Requires-Python`,
so it only offers releases the interpreter can actually install. (It deliberately
does *not* use PyPI's absolute `info.version`, which ignores `Requires-Python` and
caused false positives like offering numpy 2.5 on Python 3.11.) Each upgrade appends
its pip flags from the install-mode system (§27).

**The three-way outcome model.** After each attempted upgrade the VM verifies the
truth with a fresh check and classifies the result:
- **Success** (green) — the package moved to the new version.
- **Held back** (amber, with a reason) — a newer version exists but isn't installable
  in this environment (pip reported "already satisfied" with no hard error). This is
  usually resolved by an install-mode override (§27), *not* a retry.
- **Failed** (red) — a real error; offered for retry, sorted to the top.

`OutdatedPackageRow` renders these states; `UpdateResultsSummaryCard` summarizes the
run with a single status header (no duplicate checkmarks).

**Safety/consent.** Upgrades that would write into an externally-managed Python are
governed by the install-mode consent system (§27).

### 8. Formulae / Casks Updates
**What it does.** Find and update outdated Homebrew packages, with the same
per-package progress + failed-list workflow as pip.

**How it works.** `OutdatedBrewView` + `OutdatedBrewViewModel` over `BrewService` /
`BrewMaintenanceManager`. Shares the `OutdatedPackageRow` / `UpdateResultsSummaryCard`
grammar with pip updates.

**Safety/consent.** Success is judged on exit codes, not scraped strings (§31f).

## Install New Packages

### 9. Install pip Packages
**What it does.** Search for and install pip packages into a chosen interpreter.

**How it works.** `PIPPackagesInstallView` + `PIPPackagesInstallViewModel`. Search
hits PyPI "hot shards" (`pypi/<first-2-lowercase-chars>.json`) — **a minimum of 2
characters is required** before the shard endpoint is queried. Install streams output
live via `ConsoleOutput`. The pip flags come from `InstallPreferences.pipFlags(...)`
(§27).

**Safety/consent.** Package names are sanitized (§32); installing into a 3.12+ system
Python is governed by the install-mode consent system (§27).

### 10. Install Formulae / Casks
**What it does.** Search and install Homebrew formulae and casks from a catalog.

**How it works.** `FormulaeCaskInstallView` + `FormulaeCaskInstallViewModel`. The
installable catalog is fetched from the backend (`brew/homebrew_formulae.json`,
`brew/homebrew_casks.json`) through the cached fetch layer (§36). Installs run through
`BrewService` / the elevated tier where needed.

**Safety/consent.** Confirmations for install; exit-code success.

### 11. requirements.txt Installer
**What it does.** Bulk-install every package from a `requirements.txt` into a chosen
interpreter, then verify what actually landed.

**How it works.** `RequirementsView` + `RequirementsViewModel`. `RequirementsParser`
parses the file; the install runs `pip install -r <file>` (with install-mode flags,
§27) streaming to the console, then verifies with `pip list --format=freeze` and
splits packages into **successful** vs **failed**, offering per-package retry and an
"export failed list" action.

**Safety/consent (break-system-packages gate).** The "Install All Packages" button is
**gated strictly for Python ≥3.12**: on an externally-managed interpreter, if install
mode is `.protected` (the safe default), the button is **disabled** with an inline
reason pointing the user to the Install-mode control — because pip would refuse to
write and nothing good would happen. Choosing an override (§27) re-enables it
immediately. The view observes `InstallPreferences.shared`, so the button reacts the
instant the mode changes. For Python <3.12 the button is always enabled.

## Discover New

### 12. Popular Packages
**What it does.** Browse a curated set of popular packages and install them in one
click.

**How it works.** `PopularPackagesView` + `PopularPackagesViewModel`, list served from
the backend (`popular/*.json`, cached). Installs go through `PackageInstaller`, which
takes a `pythonVersion:` and appends the install-mode flags (§27).

**Safety/consent.** Same install-mode governance as other pip installs.

## Developer Workflow

### 13. SmartShortcuts
**What it does.** A catalog of one-click "recipes" that set up a dev environment
(e.g. a language toolchain + its common packages), with dependency-aware install.

**How it works.** `SmartShortcutsView` (+ `ShortcutCard`, `ShortcutDetailView`) +
`SmartShortcutsViewModel`. The catalog is fetched from the backend (`shortcuts/`
index + per-shortcut detail JSON) and **cached 7 days**. Each shortcut bundles brew/pip
dependencies plus a command script; `ShortcutInstaller` installs the dependencies in
order (pip steps honoring install-mode flags, §27). Detail content is delivered as
**structured JSON rendered by native components** (`ShortcutContentView`) — the app
renders no markdown.

**Safety/consent.** The shortcut's underlying `shell_code` is kept in the payload for
the installer but is **never surfaced in the UI** (no "Code" section; code fences are
stripped from notes) — a deliberate decision so users aren't handed raw shell to
paste.

### 14. Aliases
**What it does.** Read, create, and delete shell aliases from a GUI.

**How it works.** `AliasView` + `AliasViewModel` over `ShellConfigManager`. Catalyst
manages **its own block** in `~/.zshrc_catalyst`, which is sourced from `~/.zshrc`, so
it can cleanly distinguish Catalyst-managed aliases from the user's own and never
clobber hand-written config.

**Safety/consent.** Edits are scoped to the managed block; the file-path detail is
folded into the card description rather than surfaced as raw jargon.

### 15. Terminal Time Travel
**What it does.** Browse and re-run past shell commands from history.

**How it works.** `TerminalTimeTravelView` + `TerminalTimeTravelViewModel` parse the
zsh/bash history files and present a browsable, searchable list.

**Safety/consent.** Re-running a command is an explicit user action; history is read
locally.

### 16. PATH Editor
**What it does.** Inspect and reorder/edit the shell `PATH`.

**How it works.** `PathEditorView` + `PathEditorViewModel` over `PathEditorService`.

**Safety/consent.** Edits **auto-save** (no hidden "staged edits → find the Apply
button" footgun). Because `PATH` changes apply to *new* terminals, the card
description says so and a re-scan reflects the *saved* order, not the stale session
env — so a delete never appears to "come back."

### 16b. Git Graph
**What it does.** Point Catalyst at a local git repository and see its history as a
live, GPU-rendered commit graph — per-branch lane colors, decorated refs, a
read-only repository summary, click-through commit detail, and tweakable scope /
ordering / filters. A **read-only viewer** (no history rewriting in v1).

**How it works.** `GitGraphView` + `GitGraphViewModel` over the `GitGraphService`
actor and the pure `GitGraphLayoutEngine`. Repo discovery is **always user-initiated**
(folder picker, drag-and-drop, or the persisted **Recent repos** list — six shown) —
there is **no whole-disk crawl** for `.git`. On load the summary card appears first
(reusing the `VirtualEnvCreationSheet` git detail-row grammar), then the graph is read
and laid out. Full engineering detail is in **§48**.

- **Rendering.** History comes from a delimited `git log --pretty` (never `--graph`
  ASCII). `GitGraphLayoutEngine` (pure `Sendable`, unit-testable) assigns lanes and
  emits per-row segments so each commit row draws only its own gutter slice in a tiny
  `Canvas` — the graph stays fully lazy for thousands of commits. **Lane width adapts
  to the window** (compresses to a floor as lanes multiply); beyond the floor a shared
  horizontal scroll engages, with the **author + hash columns frozen** on the right.
- **Controls.** A sticky reference header (title + legend of every color/node/pill)
  pins to the top while scrolling. Options menu: scope (All refs / Current branch /
  **Local branches**, the default) · order (date / topological) · hide merges ·
  first-parent · max commits · density · show author/hash/refs. A filters popover:
  author / path / since / until (git date formats). Live search **hides** non-matching
  commits (matches-only list). Options + recent repos persist per-repo.

**Safety/consent.** Read-only: only `git log` / `rev-parse` / `rev-list` / `config` /
`status` / `show`. Every call is single-quoted, `fsmonitor`-disabled, `</dev/null`-fed,
and hard-timeout-bounded (§48) — no git call can hang the UI. User-typed filters are
`singleQuote`d before reaching the shell. Nothing writes to the repo.

## Health & Maintenance

### 17. Dr. Catalyst
**What it does.** The diagnostics engine: scans the whole dev environment, scores its
health out of 100, groups issues by category, and offers one-click auto-fixes.
Includes two sub-tools: **GhostBuster** (port-holding process finder) and a **storage
report**.

**How it works (summary).** `HealthCheckService` runs **16 Doctor checkers**
concurrently, aggregates a weighted score, and routes fixes on a stable `fixID`;
history is charted over time. The full mechanics — the doctor list, the `Doctor`
protocol, scoring weights, categories, fix routing, and the GhostBuster/StorageDoctor
sub-tools — are in the **Dr. Catalyst deep-dive (§17▸, at the end of Part V)**.

**Safety/consent.** Auto-fixes are explicit, per-issue actions. GhostBuster uses a
strict allowlist/blocklist so it never offers to kill a critical process (full detail
in §17▸).

### 18. Disk Vitals (SSD Health)
**What it does.** Show real SMART health data for the drive — parsed and visualized,
not just raw numbers.

**How it works.** `SSDHealthView` (+ `SSDHealthCards`) + `SSDHealthViewModel` over
`SSDHealthService`, which shells out to `smartctl` (from `smartmontools`).

**Safety/consent.** If `smartmontools` is missing, Catalyst offers to **install the
dependency through Homebrew** — an explicit, consented install, not a silent one.
Reading SMART data is non-destructive.

### 19. Battery Health
**What it does.** Report battery vitals (capacity, cycle count, condition).

**How it works.** `BatteryHealthView` + `BatteryHealthViewModel` over
`BatteryHealthService` (reads macOS power/battery data).

**Safety/consent.** Read-only.

### 20. Cruft Sweeper
**What it does.** Reclaim disk space by finding deletable build artifacts —
`node_modules`, `.venv`, Xcode `DerivedData`, `__pycache__`, `build/`, Rust `target/`,
`.gradle`, Maven `target/` — grouping them by location and letting the user delete in
bulk (to Trash).

**How it works.** `CruftSweeperView` (+ `CruftSweeperCards`) + `CruftSweeperViewModel`
drive `CruftScanner`, a pure/`Sendable` streaming scan engine that runs on a detached
task and emits results as an `AsyncStream<ScanEvent>` (§35). Two scan modes: **Quick**
(a few common dev folders) and **Deep** (the whole home folder). Results present a
reclaimable-space hero number, a per-type breakdown bar, per-row **size bars** and
**safety chips**, and smart-selection actions ("Select All", "Select Safe").

**Safety/consent — this is a high-stakes feature, so it has several guards:**
- **Marker-guarded detection.** A folder is only flagged when a sibling project
  marker confirms it (`package.json`/lockfile for `node_modules`; a Gradle build
  script for `.gradle`; `pyvenv.cfg` for a venv; `Cargo.toml`/`pom.xml` for `target`;
  `build.gradle`/`Makefile` for `build`). Name-only matching previously flagged
  artifacts owned by installed apps/IDE extensions — deleting those breaks the user's
  tools, so it's forbidden.
- **Hidden app-home dirs are excluded** from Deep-scan roots (`.vscode`, `.npm`,
  `.cursor`, `.antigravity-ide`, `.config`, …) — they're app caches/config, not user
  projects.
- **"Protect Active Projects"** (off / 7 / 14 / 30 days) shields anything recently
  built — applied uniformly, including to Xcode DerivedData.
- **Shared Xcode caches** (`ModuleCache`/`CompilationCache`) are separated from
  per-project output and labeled "Xcode Caches" so a multi-GB global cache isn't
  mistaken for project junk.
- **Safety chips** mark each item **green "Safe"** (regenerates automatically:
  caches, DerivedData) vs **orange "Rebuild"** (costs a rebuild/reinstall to restore:
  node_modules, venv, build outputs). "Select Safe" one-taps only the green tier.
- **Deletion goes to Trash** (recoverable via `FileManager.trashItem`), gated behind
  an explicit confirmation dialog showing the count and total size. `.ssh`, `.Trash`,
  and `.git` are hard-skipped.

### 21. Network Diagnostics
**What it does.** Run outbound-connectivity / DNS / reachability diagnostics.

**How it works.** `NetworkDiagnosticsView` + `NetworkDiagnosticsViewModel` over
`NetworkDiagnosticsService`.

**Safety/consent.** Read-only probes.

### 22. Startup Items (Login Items)
**What it does.** Show and manage what launches at login / as startup services.

**How it works.** `LoginItemsView` + `LoginItemsViewModel` over `LoginItemsService`.

**Safety/consent.** Disabling a startup item is an explicit, reversible user action.

### 23. SSH Keys
**What it does.** Inspect SSH keys, copy public keys, reveal them in Finder, and fix
key/dir permissions.

**How it works.** `SSHKeyView` + `SSHKeyViewModel` over `SSHKeyService`. Uses the
neutral `.appButton(.secondary)` role for Copy/Reveal/Fix-Perms (see
`Helpers/AppButtonStyle.swift`).

**Safety/consent.** **Private keys are never displayed or copied** — only public keys
and permission fixes. The `.ssh` directory is one of the hard-skipped paths for any
deletion.

### 24. Logs
**What it does.** Live view of the app's own terminal/debug log streams.

**How it works.** `LogsView` + `LogsViewModel` subscribe to `Logger`'s Combine
publishers (`terminalPublisher`, `debugPublisher`). Uses a single `ScrollViewReader`
(the one sanctioned nested-scroll exception).

**Safety/consent.** Read-only.

## Help & Info

### 25. About
**What it does.** App info, version, credits, and the "What's new in <version>" card.

**How it works.** `AboutView` + `AboutViewModel`, content from a **bundled** `about.json` shipped in the app Resources (in the synchronized `Catalyst/` group → auto-registers), **not fetched remotely** (the old `NetworkConfig.aboutURL` was removed, 2026-07-17b). So the what's-new always matches the installed build and works offline; `AboutViewModel` reads `Bundle.main.url(forResource:"about",withExtension:"json")`, looks up `versions[appVersion] ?? versions[latest]`, with a built-in fallback card. The action buttons (Website/Support/Feedback/Bug/Feature/Developer) use fixed `theappfoundry.co/catalyst/<slug>` redirect URLs (version+email appended), so they're always shown — no longer gated on the fetched JSON. **Keep `Catalyst/about.json` updated each release** (add the new version's entry + bump `latest`), same cadence as `notes.html`.

### 26. Menu-bar mode
**What it does.** A lightweight popover — health score, outdated count, quick actions
— reachable without opening the main window.

**How it works.** A second SwiftUI `Scene`, `MenuBarExtra`, renders
`MenuBarContentView(appVM:)`, sharing the same `AppViewModel`.

## Migration

### §S. Snapshot & Migrate (CatalystSnapshot)
**What it does.** Captures this Mac's dev environment into one portable
`.catalystsnapshot` file, then reproduces it on a new/clean Mac — Homebrew, Python +
pip, the **full `~/.zshrc`** + Catalyst-managed shell blocks, SmartShortcuts, git
identity, and tracked venv projects.

**How it works.** `SnapshotView` + `SnapshotViewModel` over `SnapshotService`
(capture/diff/restore) — full engineering detail in **§47**. The screen has two
color-coded flows that mirror the two landing cards: **capture/export is green**,
**import/restore is blue** (see CODING_STANDARDS 4.15). Capture → a green "Snapshot Ready"
review with a machine + stat-badge summary and a sticky **export footer**; import →
a **preview** (grouped, toggleable diff) then a separate **status** screen, both
using the shared sticky footer bar (CODING_STANDARDS 4.14). Restore installs directly
(no dry-run) — per item, exit-code-gated, resumable.

**Safety/consent.** **Secrets are never exported.** The full `~/.zshrc` is
**secret-scrubbed** at capture (`ShellSecretScrubber`, CODING_STANDARDS 2.8): obvious
`export KEY=…`/token assignments become placeholders and are listed in a capture
warning; PATH-like names are allowlisted. Restoring the profile **backs up the
target's existing `~/.zshrc` first** (and refuses to overwrite without a backup),
then syntax-checks with `zsh -n`. git is read from `~/.gitconfig` as text (no shell
→ no Command-Line-Tools prompt). pip restores honor PEP 668 via
`InstallPreferences.pipFlags`; venvs are never flagged.

---

## 27. The install-mode / break-system-packages consent system

This cross-cutting subsystem is central to how Catalyst handles installs safely, so
it is documented in full.

### The problem
Homebrew and recent system Pythons (**3.12+**) mark their environment **"externally
managed"** (PEP 668, via an `EXTERNALLY-MANAGED` marker). pip then **refuses** to
install or upgrade into that interpreter unless you pass `--break-system-packages` —
a flag that, as the name says, can overwrite or downgrade packages the OS/Homebrew
own and break other tools. Catalyst must neither silently break the user's system nor
silently fail every install on modern Python.

### The solution: one global, consented setting
Catalyst exposes a single global **install mode** rather than scattering flags:

| Mode | Flag added on 3.12+ | Meaning |
|---|---|---|
| **Protected** (default) | *(none)* | Respect system integrity. Installs into system Python may be refused — nothing risky happens. |
| **User space** | `--break-system-packages --user` | Install into your personal user site instead of the system directory. Safer, but Homebrew's Python may reject `--user`. |
| **System-wide** | `--break-system-packages` | Write directly into the OS-managed Python. Highest reach, highest risk. |

State lives in `InstallPreferences.shared.mode` (`Helpers/InstallPreferences.swift`),
persisted in **`UserDefaults`**.

### How every install respects it
- Every pip command's flag is built by **`InstallPreferences.pipFlags(forPythonVersion:)`**
  — a thread-safe `static` (reads UserDefaults) usable off the main actor. It returns
  `""` for Python **<3.12** *or* **Protected** mode, else the mode's flag. **No site
  hardcodes `--break-system-packages`.** It is injected at every pip site: pip
  updates, install pip packages, requirements (`-r` + per-package retry), the pip
  self-upgrade in `PythonManager`, `ShortcutInstaller`, `PackageInstaller`, and
  Popular Packages.
- The 3.12+ boundary is the single source of truth
  `VersionComparator.requiresBreakSystemPackages(pythonVersion:)` — never re-derived
  elsewhere.
- **Virtual environments are never flagged and never gated** — a venv isn't
  externally managed, so `pipFlags` returns `""` for it.

### Consent, transparency, and reversibility (the UX contract)
- **Two places set the mode, both consented.** The per-interpreter control lives in the
  modular Python selector (`SelectPythonVersionDropdown`, only for Python ≥3.12, showing
  the mode picker + the exact appended flag + a risk-colored banner). The **app-wide**
  control lives in the **sidebar status popover** (`StatusPopoverView`, between the
  background-task divider and Refresh) — a menu with a green/red shield.
- **Turning an override ON requires explicit consent** — a `confirmationDialog`
  ("Override system integrity?") spells out the consequence before it takes effect.
  **Turning it back to Protected is safe and immediate** (no confirmation).
- **A global indicator** sits in the sidebar status bar (`StatusIndicatorView`): a
  green `checkmark.shield.fill` when Protected, red `exclamationmark.shield.fill` while
  any override is active (the old standalone red sidebar chip was removed 2026-07 —
  the shield + popover control replaced it).
- **Contextual gating, not blanket disabling.** Action buttons are disabled only in
  the genuinely-futile state — 3.12+ **and** Protected — where pip would refuse to
  write. There, the button is disabled with an inline reason pointing to the
  Install-mode control; choosing an override re-enables it reactively (views
  `@ObservedObject` the singleton). Requirements' "Install All" is gated strictly for
  ≥3.12 this way.
- **Everything is explained in one place.** The full copy (what install modes are,
  what PEP 668 is, the risks, how to revert) lives in `AppInfoCenter` and is surfaced
  anywhere via an `InfoDot(topic:)` (ⓘ) → the single shared `AppInfoSheet`.

**In one sentence:** Catalyst will never break your system Python without you
choosing to, in an informed, transparent, reversible way — and it makes the safe
default (Protected) obvious while telling you exactly why an install is held back.

---

# Part III — How it's built

## 28. Architecture & layers

A disciplined **MVVM** app. **Each top-level folder is a layer, and layers depend
strictly downward.** A View never runs a shell; a Model never imports SwiftUI.

```
Views  ─────────▶  ViewModels  ─────────▶  Services  ─────────▶  Utilities / Models
(SwiftUI,          (@MainActor             (business logic:        (process exec,
 @MainActor)        ObservableObject,       brew, python, health,   sanitization,
                    one per screen)         ssd, network, …)        paths, versions,
                                                                    Codable data)
     ▲                                                                     │
     └──────────── never call up; data flows down, events bubble via closures ─┘
```

Enforced by `CODING_STANDARDS.md` Part 1:
- **One screen = one View + one `@MainActor` ViewModel.**
- **ViewModels stay thin.** When a VM approaches ~12 `@Published` or a few hundred
  lines, extract logic into a `Services/` type (`@MainActor class` if stateful) or a
  `Utilities/` type (`Sendable struct` if pure/background). The five historically
  "god" VMs (Dashboard, CruftSweeper, VirtualEnvCreation, SmartShortcuts,
  PopularPackages) are already decomposed — mirror that, don't regress it.
- **Streaming output stays VM-owned** via an `onOutput`/callback so the console can
  isolate high-frequency updates (§35).

## 29. Composition root & lifecycle

Everything is wired in **`AppViewModel`** — one `@MainActor ObservableObject`, no DI
framework, so the whole dependency graph reads in one file.

**`AppViewModel.init()`, in order:**
1. Builds shared services with manual DI:
   `PrivilegesService(logger:)` → `BrewService(logger:privileges:)` →
   `PythonService(logger:config:privileges:)`. `logger`/`config` are singletons
   (`Logger.shared`, `ConfigStore.shared`).
2. Constructs **every screen's ViewModel**, injecting only what it needs. (This is
   where you register a new screen's VM.)
3. Wires the **global refresh hook**: `dashboardViewModel.onGlobalRefresh` → back into
   `fullRefresh()`.

**`Screen` enum + `currentScreen`** drive the `NavigationSplitView`: the sidebar sets
`currentScreen`; the detail `switch` renders the matching View + VM.

**`fullRefresh()`** runs every VM's startup/detection concurrently in a
`withTaskGroup`, then updates `NetworkMonitor`'s system status. Any global-state
change (install/uninstall) should funnel through here.

**Launch sequence (splash removed 2026-07-14):**
```
@main CatalystApp
  → @StateObject AppViewModel()             // builds services + all VMs
  → ContentView().preferredColorScheme(.dark).environmentObject(appVM)
  → .task { await appVM.startupChecks() }
        → logsViewModel.startup()           // begin streaming logs
        → Task { fullRefresh() }            // detection runs IN THE BACKGROUND
  → ContentView renders NavigationSplitView immediately (sidebar + toolbar + content)
        no gate, no branch — the app is free and unauthenticated
  + MenuBarExtra → MenuBarContentView(appVM) // second scene, shares the VM
```
**There is no launch splash anymore.** The old `LaunchScreenView` overlay (held 1.5 s on an
`isAppReady` spring) was removed — it covered the titlebar and spawned the window-chrome
hacks (see CODING_STANDARDS §6.7). The window now appears already framed and fills content in
place. `isAppReady` is no longer used to gate any UI. The only launch "wait" a user sees is
the neutral `.checking` spinner ("Checking your access…") while the saved token is verified,
shown in the plain sign-in window (no sidebar). `LaunchScreenView.swift` still exists but is
**unused** (deleting it would break the pbxproj reference; strip from the Xcode target to
fully remove). Detection still runs in a background `Task` — every result is `@Published`, so
the dashboard fills in as each check finishes; it must **never** block rendering (§46).

## 30. File map

The navigation backbone — every folder and the role of each file.

**`Catalyst/`** — `CatalystApp.swift` (`@main`), `Info.plist`, `Assets.xcassets`.

**`Views/`** — the app shell + 24 screens: `ContentView` (sidebar + detail switch,
override indicator, shared `AppInfoSheet`, `.symbolRenderingMode(.monochrome)`, root
`LaunchScreenView` (**unused since 2026-07-14 — splash removed**),
`MenuBarContentView`, `StatusIndicatorView`, and one view per
feature (§3–§S, incl. `SnapshotView`). `Views/Components/` holds reusable composites:
`DashboardCards`, `LiveMetricsGrid`, `DrCatalystCards`, `IssueGroup`,
`HealthTrendChart`, `VitalityGauge`, `SSDHealthCards`, `StorageDNAView`,
`CruftSweeperCards`, `OutdatedPackageRow`. `SnapshotView` keeps its own in-file
components — the shared sticky `SnapshotFooterBar`, the two landing cards, and a
minimal `FlowLayout` for the domain chips.

**`ViewModels/`** — `AppViewModel` (composition root) + one per screen (incl.
`SnapshotViewModel`, `GitGraphViewModel` — the latter also holds the `GraphOptions`
value type + the `GitGraphPrefs`/`GitGraphPrefsStore` per-repo persistence);
`GhostBusterViewModel` and `VirtualEnvCreationViewModel` are sub-VMs.

**`Services/`** — execution/privilege (`PrivilegesService`, `TerminalService`,
`PrivilegedHelperManager` + `CatalystHelperProtocol`), package managers
(`BrewService`, `BrewMaintenanceManager`, `InstalledPackagesService`,
`PackageInstaller`, `PackageItem`), Python (`PythonService`, `PythonManager`,
`VenvBuilder`, `ProjectScannerService`), health (`HealthCheckService`,
`HealthHistoryStore`), system probes (`SSDHealthService`, `BatteryHealthService`,
`NetworkDiagnosticsService`, `NetworkMonitor`, `LoginItemsService`,
`DetectionService`, `PathEditorService`, `SSHKeyService`, `ShellConfigManager`,
`ShortcutInstaller`), scanning (`CruftScanner`), and migration
(`SnapshotService.swift` — `SnapshotArchiver` [zip via `/usr/bin/ditto`],
`SnapshotCaptureService`, `SnapshotDiffer`, `SnapshotRestoreService`,
`SnapshotResumeStore`, `ShellSecretScrubber`, `GitConfigFile`), and Git Graph
(`GitGraphService.swift` — the read-only `RepoSummary` / `GraphCommit` / `GitRef` /
`CommitDetails` models + the `fsmonitor`-safe, timeout-bounded git readers, §48).

**`Checkers/`** — the 16 Doctors + `StorageDoctor` (§17).

**`Models/`** — `Codable`/`Sendable`/`Identifiable` value types: `AliasModels`,
`AppInfo`, `CruftModels`, `HealthCheckModels`, `InstalledPackage`, `PackageType`,
`Project`, `PythonInstallation`, `AvailableVersion` (brew-discovered installable Python; in
`PythonVersionsResponse.swift`), `SSDHealthModels`,
`SmartShortcutsModels`, `SnapshotModels` (the `.catalystsnapshot` contracts —
`CatalystSnapshot`, `ShellSnapshot` with the scrubbed `mainProfile`, `RestoreAction`,
all tolerant-decoded).

**`Utilities/`** — `AsyncProcessRunner`, `InputSanitizer`, `BrewPathManager`,
`NetworkConfig` (endpoints + `fetchJSON` + `CacheTTL` + `RemoteCache`),
`VersionComparator`, `RequirementsParser`, `ScannerUtils`, `GitGraphLayout` (the pure
`Sendable` lane-assignment engine + `GraphNode`/`GraphEdge`/`RowSegment`/`GitGraphLayout`).

**`Helpers/`** — the shared UI library + cross-cutting singletons:
`CardStyleExtensionView` (`cardStyle()`, `codePanel()`, `SmoothPageScroll`),
`SectionDivider`, `MasterHeaderView`, `CompactInputField`, `SearchBarView`,
`EmptyStateView`, `LoadingStateView`, `ErrorBanner`, `BannerView`, `MatchedLabelStyle`,
`ConsoleOutput` + `OutputConsoleView`, `UpdateResultsSummaryCard`,
`ResultDisclosureGroup`, `PackageComponents`, `StatComponents`,
`SelectPythonVersionDropdown`, `InstallPreferences` (§27), `AppInfoCenter` (the
`InfoDot`/`AppInfoSheet` system), `RefreshToolbarContent`, `PrerequisiteGateView`,
`PerfFlags`, `ShortcutContentView`.

**`Persistence/`** — `ConfigStore`, `ProjectStore`. **Root** — `Logger.swift`,
`install.sh`, docs.

---

# Part IV — Execution & safety

Catalyst's job is to run shell commands for the user, so this layer is the most
carefully guarded. **Never run a shell inline** (`CODING_STANDARDS.md` Part 2).

## 31. The three execution tiers

### 31a. `AsyncProcessRunner` (Utilities) — the workhorse, non-privileged
A Swift **`actor`** (shared singleton) that runs processes off the main thread and
returns `ProcessResult { stdout, stderr, exitCode; var succeeded { exitCode == 0 } }`.
Entry points:
- `run(executable:arguments:)` — **array-args, no shell, no quoting.** *Preferred* for
  anything with user input.
- `runBrew(arguments:timeoutSeconds:)` — array-args brew convenience.
- `run(command:useLoginShell:)` — legacy command-string via `/bin/zsh -c`; only for
  sites that route through `singleQuote`.
- `runWithStreaming(command:onOutput:)` — real-time line streaming to the UI (installs),
  flushed ~0.1 s; `onOutput` fires on the main actor.
- `runWithBrewPath(command:)` — prepends the resolved Homebrew prefix to `PATH`.

### 31b. `PrivilegesService` (Services) — elevated/root
Wraps `osascript` to show a native password dialog, then pipes the password to
`sudo -S`. The **single most sensitive path** — any change needs extra review + tests.
`runWithPrivileges(command:)` is the core bridge; `installBrewFormula` /
`uninstallBrewFormula` are streamed brew operations; `removeFiles(at:)` is **gated by
`validateSafeToDeletePath`** (§33). **Secrets are never written to disk** — the
password is in-memory (`CATALYST_BREW_SUDO_PW` / stdin to `sudo -S`), never embedded
in a script.

### 31c. `TerminalService` (Services) — visible/interactive hand-off
A `@MainActor` singleton that uses AppleScript to open a command in the user's
**visible Terminal.app** — used when the user must watch/respond (chiefly the Homebrew
install script). Rejects newlines/control chars as an injection guard.

### 31f. Non-negotiables
- **Decide success on exit codes, never by string-scraping stdout.**
- **Gate every destructive delete** (§33); prefer `trashItem` over `removeItem`;
  hard-skip `.ssh`/`.Trash`/`.git`.
- **Sanitize + route every call through a tier.**

## 32. Sanitization — `InputSanitizer`
Everything reaching a shell passes through here. Package names →
`sanitizePackageName` (ASCII allowlist regex `^[a-zA-Z0-9][a-zA-Z0-9._@-]*$`, strips
control/zero-width chars, caps length). Paths/args → `singleQuote` (one quoting layer;
`shellEscape` is now `private` — do not reintroduce bare call sites). Prefer the
array-args runner path over command strings for anything with user input.

## 33. Safe deletion — `validateSafeToDeletePath`
Every destructive delete is allowlist-gated: only Homebrew/Cellar/Caskroom/virtualenv/
cache/log dirs are deletable; `/System`, `/Library`, and home Documents/Desktop/
Downloads are blocked. `.ssh`, `.Trash`, `.git` are hard-skipped everywhere. Prefer
`FileManager.trashItem` (recoverable) over `removeItem`. Cruft Sweeper (§20) layers
additional marker/hidden-dir/protection guards on top.

## 34. Brew path resolution — `BrewPathManager`
Detects Apple Silicon vs Intel and resolves the correct brew prefix/binary
(`/opt/homebrew` vs `/usr/local`), lazily + thread-safely. **Never hardcode brew
paths.** `homebrewPrefix`/`brewPath` are **`async`** — call only from async contexts.

---

# Part V — Internals

## 35. Concurrency & data flow

- **`@MainActor`** for everything UI-facing (all VMs, UI singletons, stores).
- **Actors** for shared mutable engines (`AsyncProcessRunner`; `RemoteCache`
  serializes disk access).
- **Detached tasks for synchronous I/O.** `FileManager` traversal is synchronous, so
  Cruft/Storage scans run on `Task.detached`, streaming back to the `@MainActor` VM.
- **`AsyncStream` + events.** `CruftScanner.scan(options:priority:)` returns an
  `AsyncStream<ScanEvent>`; the VM maps each event onto `@Published` state. Cancelling
  the consumer tears down the engine via `onTermination`.
- **Coalesced high-frequency state.** `ConsoleOutput` (a tiny `ObservableObject`)
  holds streamed command text, observed only by the leaf `OutputConsoleView` — never
  read its `.text` in a parent `body`; VMs bridge it via a computed
  `installationOutput`. Progress ticks are throttled (~10 Hz) to avoid whole-view
  re-renders.
- **Leaf rows are `Equatable` + take plain values**, not the whole VM.

**Worked example — install a pip package:**
```
PIPPackagesInstallView (button)
  → PIPPackagesInstallViewModel.install()
      → InputSanitizer.sanitizePackageName(name)
      → flags = InstallPreferences.pipFlags(forPythonVersion: python.version)   // §27
      → command = "<python> -m pip install <name> <flags>"
      → AsyncProcessRunner.runWithStreaming(command:) { chunk in
             self.installationOutput += chunk        // → ConsoleOutput, coalesced
         }
      → decide success on exitCode                   // not string scraping
      → update @Published state; optionally fullRefresh()
```

## 36. Networking & caching

Backend = **read-only static JSON** on Cloudflare Pages
(`https://data.theappfoundry.co/public/...`), authored in the separate
`theappfoundryco/data` repo. `NetworkConfig` centralizes it.

- **Endpoints:** `shortcuts/` (index + detail), `brew/homebrew_formulae.json`,
  `brew/homebrew_casks.json`, `pypi/<2-char>.json` (hot shards), `popular/*.json`,
  `about.json`. PyPI's own `pypi.org/pypi/pip/json` gives pip's latest version.
  **`python_versions.json` was removed (2026-07):** installable Python versions now come
  **live from Homebrew** — `PythonManager.fetchAvailableVersions` runs `brew search
  /^python@x.y$/` then `brew info --json=v2` for the deprecation flag (structured, not
  scraped), filters out installed major.minors, marks deprecated ones in the picker, and
  recommends the highest non-deprecated. No backend file to maintain; gated on brew present.
- **Sessions:** two tuned `URLSession`s — `apiSession` (~15 s), `downloadSession`
  (~120 s). Never `URLSession.shared`.
- **One cached caller:** `NetworkConfig.fetchJSON(from:as:ttl:)`, backed by
  `RemoteCache` (disk). Fresh-within-`ttl` served without a hit; stale refetched; on
  network error the last cached copy is returned (offline-safe). TTLs live in
  `CacheTTL`, set to **max-safe** values (the refresh button busts the cache and
  stale-on-error covers offline, so TTL tracks how often each payload actually changes):
  shortcuts + brew catalog **7 days**, popular + python versions + about **30 days**,
  pypi shard **48 h** (kept shortest — most "live"); `.never` bypasses. The liveness
  ping and direct-to-PyPI checks aren't
  cached.
- **Offline / liveness:** `NetworkMonitor` surfaces a colored status
  (`connected`/`reconnecting`/`offline`/`checking`) in the sidebar
  (`StatusIndicatorView`). The 30 s ping hits `NetworkConfig.APIEndpoint.healthURL` — a tiny
  static `health.json` on the same origin as the catalogs.
- **Two-sided contract:** a `Codable` change requires a matching change in the
  `theappfoundryco/data` repo (and its `tools/` generators); decode tolerantly (missing keys →
  empty defaults). No markdown is rendered
  in-app; shell code is never surfaced.

**There is no API tier.** Catalyst had one until v1.0 — a Cloudflare Worker with D1 and KV
behind it, serving email-OTP sign-in, device binding, signed entitlement JWTs, trials, gift
codes, invoicing and Razorpay payments. All of it was deleted when the app became free. The
app now makes exactly two kinds of request, both GETs for static files:

| What | Where |
|---|---|
| Read-only catalogs | `data.theappfoundry.co/catalyst/public/...` |
| Sparkle update feed | `updates.theappfoundry.co/catalyst/appcast.xml` |

Both are GitHub Pages sites behind custom domains, served from the `theappfoundryco/data` and
`theappfoundryco/updates` repos. Nothing accepts a write. No request carries an identifier, and
the app links no analytics or crash-reporting SDK (§49.6).

**Why custom domains and not `*.github.io`.** `SUFeedURL` and `NetworkConfig.baseURL` are
compiled into builds that live on machines for years and can't be changed retroactively. Both
of Catalyst's previous hosts — a Cloudflare Pages project and a Worker — were deleted, which
emptied every catalog screen and would have killed auto-update *silently*, because Sparkle
reads an unreachable feed as "no update available". A CNAME can be repointed forever.
(CODING_STANDARDS 12.44.)

**Liveness.** `NetworkMonitor` probes `data.theappfoundry.co/catalyst/health.json` — the same
origin as the catalogs, deliberately, so it can't report healthy while content is unreachable.

**App auto-updates (Sparkle) — LIVE.** The feed is served from
`updates.theappfoundry.co/catalyst/appcast.xml` — GitHub Pages on the `theappfoundryco/updates`
repo, behind a custom domain. Binaries are GitHub Release assets on this repo
(`theappfoundryco/Catalyst`); the appcast only points at those download URLs. Full runbook in **`RELEASING.md`**; app-side UX in §49.7. **Two independent signatures, one source of truth, one
scripted release:**
- **Apple Developer ID codesign + notarization** — lets Gatekeeper run the app/update (Apple
  Developer account; non-negotiable on modern macOS).
- **Sparkle EdDSA signature** — lets Sparkle trust the feed. **Public key** in `Info.plist`
  (`SUPublicEDKey`); **private key** in the login Keychain, never in the app or repo. Losing it
  means no existing install can ever verify an update again — back it up.
- **Source of truth:** the `.zip` is a GitHub Release asset on this repo; its `notes.html` and
  cached-signature `meta.env` live in `updates/catalyst/Versions/<version>/`. The zip is NOT
  committed anywhere — `build/` is gitignored. `SUFeedURL` → `updates.theappfoundry.co` → the
  appcast generated into the `updates` repo.
- **Release flow:** `./Scripts/cut_release.sh` — preflight (asserts Release config, hardened
  runtime, no DEBUG, real signing) → build → export (Developer ID) → notarize → staple → re-zip →
  `sign_update` → `Scripts/make_appcast.py` regenerates the cumulative `appcast.xml` **into
  `updates/catalyst/`** → `gh release create` on this repo → commit + push `updates`. That last
  push is what actually makes an update reachable: a Release without a matching appcast push is
  invisible to every install, and fails silently. **Version-only:** bump
  `MARKETING_VERSION`, and add its block to `about.json` (CODING_STANDARDS 12.36).

## 37. Persistence

JSON under `~/Library/Application Support/com.shivanggulati.catalyst/` with **corruption
fallback** (back up the bad file, start fresh); prefer tolerant per-element decode.
- `ConfigStore` (`config.json`) — brew-update timestamp, Python versions, pip map.
- `ProjectStore` (`projects.json`) — tracked venv projects.
- `HealthHistoryStore` — health snapshots for trend charts.
- `InstallPreferences` — the one **`UserDefaults`** setting: the global install mode
  (§27).
- `GitGraphPrefs` / `GitGraphPrefsStore` — a **`UserDefaults`** JSON blob: Git Graph's
  recent repos + per-repo `GraphOptions` (§48). Small-blob pattern (no file/corruption
  handling) — mirror `InstallPreferences`, not `ConfigStore`, for tiny per-key state.
- `Logger` — `app.log` (rotation: 10 MB, 3 backups) + live Combine publishers.

## 38. Logging
`Logger.shared` writes `app.log` (rotated) and exposes `terminalPublisher` /
`debugPublisher` Combine streams that feed the Logs screen (§24) live. Command output
is also logged with a `.terminal` category as it streams.

**No secrets in logs (guarantee).** Because `app.log` is on disk *and* the Logs screen is
user-visible, a logged secret is a persisted leak — so nothing sensitive is ever logged
(CODING_STANDARDS 2.10). `AsyncProcessRunner` logs no command strings;
`PrivilegesService` logs credential *events*, never the sudo password. App output routes
through `Logger`, not raw `print` (the lone debug `print` in `ConfigStore` is `#if
DEBUG`-gated). On the backend, credential echoes are **dev-gated**: the Worker only
`console.log`s a `dev_code`/magic link when `ENVIRONMENT !== "production"`, and the OTP is
sent via the Vercel fn rather than logged (§36).

## 39. The UI design system

A shared component vocabulary — **reach for these before inventing anything**, and
match the grammar exactly (`CODING_STANDARDS.md` Parts 3–4). This section doubles as the
design reference for the docs website.

- **Cards:** `cardStyle()` — the single source of truth for card chrome (16 pt
  padding, opaque `controlBackgroundColor` fill, hairline `strokeBorder`, 12 pt
  radius; a border, not a shadow, to avoid scroll jank). `cardStyle(.compact)` for
  inline chips; `codePanel()` for recessed code/log areas.
- **Page scroll:** `SmoothPageScroll` (a `List`-backed container giving native
  momentum) for every page — a bare `ScrollView { VStack }` scrolls jerkily on macOS.
  Exception: link-primary screens use a plain `ScrollView`. Navigation modifiers go
  **outside** `SmoothPageScroll`.
- **Separators:** `SectionDivider` (opaque 2 pt), never `Divider()` on scrolling
  content (a hairline shimmers during sub-pixel scroll).
- **No `.shadow`/`Material`/`.blur`** on scrolling content.
- **Headers / banners / states:** `MasterHeaderView` (gradient icon + title +
  subtitle page header), `BannerView` (`.info`/`.warning`/`.tip`/`.critical`,
  `.standard`/`.compact`), `ErrorBanner`, `EmptyStateView`, `LoadingStateView`.
- **Inputs:** `CompactInputField` / `SearchBarView` — one field style app-wide.
  Secure fields carry a built-in eye reveal toggle (`allowReveal`); never hand-roll a
  `SecureField`. Note `.contentShape` makes a region hit-testable but does NOT focus it —
  both the field and its padded container need `.onTapGesture` (CODING_STANDARDS 12.37).
- **Buttons/icons:** every button routes through the centralised `.appButton(_:)`
  (`Helpers/AppButtonStyle.swift`) — the single source of truth mapping each semantic
  role to a concrete style; `.buttonStyle(_:)` is never called directly outside that file
  (CODING_STANDARDS 4.2a). Roles: `.primary` (prominent, tint at call site),
  `.destructive`/`.destructiveProminent` (prominent red), `.neutral`/`.secondary`
  (bordered via `NeutralActionButtonStyle`, which forces icon==title so no glyph goes
  accent-blue — see §4.2), `.plain`/`.borderless`/`.link` (chrome-free). `ContentView`'s
  detail-stack `.symbolRenderingMode(.monochrome)` and `.labelStyle(.matched)` handle the
  remaining palette/layout cases.
- **Results grammar:** results/summary cards lead with ONE status icon + title +
  inline counts (`UpdateResultsSummaryCard`) — never a duplicate checkmark, never a
  false "success" celebration on a worklist screen (lead with the actionable number,
  e.g. Cruft's reclaimable space). Config toggle sections are rows (colored `.fill`
  icon + title + subtitle + `.switch`), not tile grids; collapse long ones behind
  `InstantDisclosureGroup`.
- **Sticky action footer:** a selection/commit screen pins its primary action in a
  footer bar — `SectionDivider` then a padded `HStack` on
  `Color(NSColor.controlBackgroundColor)`, with a `.headline` count + `.caption`
  `.secondary` subtitle on the left and the action pinned right; the prominent button
  is a semibold `Text` with `.frame(minWidth: 140)`, `.buttonStyle(.borderedProminent)`,
  `.controlSize(.large)`. It appears **only when there's something to act on**. Cruft
  Sweeper's delete bar is the canonical shape; Snapshot & Migrate reuses the exact
  grammar via the shared `SnapshotFooterBar` (CODING_STANDARDS 4.14).
- **Per-flow accent color:** a directional flow keeps ONE accent throughout —
  **green** for capture/export/backup, **blue** for import/restore — so its landing
  card, working spinner, header, badges, and footer button all agree (Snapshot &
  Migrate). Domain-row colors are separate and meaning-bearing (Homebrew orange,
  shell/git purple, python/pip/projects blue). (CODING_STANDARDS 4.15.)
- **Magnitude + consequence in rows:** proportional size bars + semantic chips (e.g.
  Cruft's Safe/Rebuild) over walls of equal-weight rows.
- **Modular help:** `InfoDot(topic:)` (ⓘ) + one shared `AppInfoSheet` (`AppInfoCenter`);
  all explainer copy lives once, deep-linked from anywhere.
- **Colors** come from semantic system values (`Color(NSColor.controlBackgroundColor)`,
  etc.); the app is forced dark but never hardcodes hex.

### 17▸ Dr. Catalyst — the diagnostics engine (deep dive)

**Orchestration.** `HealthCheckService` (singleton) holds a `private let doctors:
[Doctor]` array of **16** checkers and runs them **concurrently** (`runFullScan()`),
availability-gating conditional tools; it also routes fixes (`fix(issue:)`).

**The 16 doctors:** `ShellIntegrityCheck`, `PathSanityCheck`, `ToolChainCheck`,
`PermissionsCheck`, `NetworkDoctor`, `DiskHygieneDoctor`, `ConflictDoctor`,
`GitDoctor`, `SecurityDoctor`, `ArchitectureDoctor`, `FirewallDoctor`,
`StartupDoctor`, `MemoryDoctor`, `ContainerDoctor` (conditional), `JavaDoctor`
(conditional), `NodeDoctor` (conditional). `StorageDoctor` exists but is **not** in
this array — it powers the standalone storage report.

**The `Doctor` protocol** (`Models/HealthCheckModels.swift`):
```swift
protocol Doctor {
    func run() async -> [HealthIssue]
    func fix(_ issue: HealthIssue) async -> Bool     // default: false (no-op)
}
// Conditional tools additionally: func checkAvailability() async -> Bool
```
Conditional doctors report `.notInstalled` rather than failing when the tool is
absent.

**Scoring.** Each `HealthIssue` carries a `HealthSeverity` weighted **critical = 20,
warning = 5, info = 1**, aggregated into a **score out of 100**. Per-category results
are a `DoctorStatus`: `passed` / `failed(count:)` / `skipped` / `notInstalled(String?)`.

**Categories** (`HealthCategory`, `CaseIterable`): Shell Integrity, Path
Configuration, Developer Tools, File Permissions, Network Config, Docker/Containers,
Disk Hygiene, Security/Identity, Architecture/Silicon, Java Environment,
Firewall/Network, Startup Profiler, Node.js/NPM, Memory & Performance.

**Stable fix routing.** Fixes route on a stable **`fixID`** (e.g. `clearDerivedData`,
`fixSSHKeyPermissions`, `strictFirewallMode`, `pruneDanglingImages`), **never on the
issue title** — copy changes don't break remediation. `DrCatalystViewModel.fix(issue:)`
routes back to the owning doctor, then re-scans.

**History & trends.** `HealthHistoryStore` persists snapshots; charted via
`HealthTrendChart` + `VitalityGauge`.

**Sub-features:**
- **GhostBuster** (`GhostBusterViewModel`) — finds dev processes holding ports.
  Guarded by a strict **allowlist** of dev keywords (python/node/docker/postgres/
  vite/uvicorn/jupyter/ollama…) and a **blocklist** of critical processes (launchd,
  Finder, Xcode, Catalyst itself), so it **never offers to kill something dangerous**.
  Killing a process is an explicit user action.
- **StorageDoctor** — builds a `StorageReport` (visualized as `StorageDNAView`), run
  detached because the traversal is synchronous.

---

# Part VI — Working on Catalyst

## 40. Recipe: add a screen
1. **Logic first (if needed):** `Services/` (`@MainActor class` if stateful) or
   `Utilities/` (`Sendable struct` if pure). Never run shells inline — use a tier.
2. **ViewModel:** `@MainActor final class FooViewModel: ObservableObject`; thin;
   `@Published` state + async actions; services via `init` injection.
3. **View:** wrap in `SmoothPageScroll` (unless link-primary); use `cardStyle()`,
   `MasterHeaderView`, `SectionDivider`, `BannerView` — no bespoke chrome.
4. **Register:** add a `AppViewModel.Screen` case; construct the VM in
   `AppViewModel.init`; add a sidebar `NavigationLink(value:)` and a detail `switch`
   case in `ContentView`.
5. **Global refresh:** if actions change global state, add startup/reset to
   `fullRefresh()`.
6. **Register the file(s) in `project.pbxproj`** (§42). Build.

## 41. Recipe: add a Doctor
1. `Checkers/FooDoctor.swift` conforming to `Doctor` (`run()` → `[HealthIssue]`;
   optional `fix(_:)`; optional `checkAvailability()` → `.notInstalled` when absent).
2. Stable `fixID` + a `HealthSeverity` per issue; route fixes on `fixID`.
3. New `HealthCategory` case if needed.
4. Register the instance in `HealthCheckService.doctors`.
5. Register the file in `project.pbxproj` (§42). Build.

## 42. Xcode registration ritual (highest-risk surface)
`Helpers/` and several groups use **classic (non-synchronized) Xcode groups**, so a
new `.swift` file is **not** auto-compiled — hand-edit
`Catalyst.xcodeproj/project.pbxproj` with **4 entries** (`PBXBuildFile`,
`PBXFileReference`, a `PBXGroup` children entry, a `PBXSourcesBuildPhase` entry), each
with a synthetic ID. Used prefixes: feature `DD/EE/FF/AB/AC/AD/BA–BE`, structural
`CA–CL`; the install-mode + info system uses `CA7A1111000000000000AA01–AA04`;
the CatalystSnapshot files use the `CK` prefix; the **Git Graph** files use the `CL`
prefix (`CL…A` GitGraphLayout · `B` GitGraphService · `C` GitGraphViewModel · `D`
GitGraphView). The `CM` and `CN` prefixes belonged to the auth/entitlement and user-profile
files, all deleted at v1.0; they are retired rather than reused, so searching an ID by prefix
stays unambiguous across eras. (Asset-catalog imagesets need **no**
pbxproj entries — asset catalogs are folder-based.)
**Next free feature prefix: `CO`.** Symptom of a missing registration: "cannot find X
in scope" though the file exists. Lesson: when registration fights you, add a new type
to an already-registered file instead of a new file. Build command:
`xcodebuild -project Catalyst.xcodeproj -scheme Catalyst -destination 'platform=macOS' build`.

## 43. Testing
There is no test target. The XCTest suite that covered the utility/service layer
(`InputSanitizer`, `PrivilegesService`, `AsyncProcessRunner`, `BrewPathManager`,
`VersionComparator`, `NetworkConfig`, models, and destructive-path safety) was removed at v1.0.

If tests come back, that is where they belong. The highest-stakes code in Catalyst is shell
execution and file deletion — it uninstalls packages, edits shell config, and runs privileged
operations against a real machine. Those paths are the ones worth pinning down, and they are
also the ones a contributor is least able to verify by clicking around.

## 44. Reverse index — "I want to change X, where do I look?"

| I want to… | Look at |
|---|---|
| Add/rename a screen | `AppViewModel` (Screen enum + init), `ContentView` |
| Change how a shell command runs | `Utilities/AsyncProcessRunner`; root → `Services/PrivilegesService` |
| Add a command-injection guard | `Utilities/InputSanitizer` |
| Fix a brew path issue | `Utilities/BrewPathManager` |
| Change pip behavior on 3.12+ / break-system-packages | `Helpers/InstallPreferences` + `Utilities/VersionComparator` (§27) |
| Add/adjust a health check | `Checkers/…Doctor`, `Services/HealthCheckService`, `Models/HealthCheckModels` |
| Change disk-cruft scanning | `Services/CruftScanner`, `Models/CruftModels`, `ViewModels/CruftSweeperViewModel` |
| Change snapshot capture/restore, or shell secret-scrub | `Services/SnapshotService` (`SnapshotCaptureService`/`SnapshotDiffer`/`SnapshotRestoreService`/`ShellSecretScrubber`), `Models/SnapshotModels`, `ViewModels/SnapshotViewModel` (§47) |
| Change the git graph / lane layout / commit reads | `Views/GitGraphView`, `ViewModels/GitGraphViewModel` (+ `GraphOptions`/`GitGraphPrefs`), `Services/GitGraphService`, `Utilities/GitGraphLayout` (§48) |
| Change the app-wide integrity/install-mode indicator or control | `Views/StatusIndicatorView` (shield + `StatusPopoverView` menu), `Helpers/InstallPreferences` (§27) |
| Restyle the sticky action footer | `SnapshotFooterBar` in `Views/SnapshotView` / the bar in `CruftSweeperCards` (CODING_STANDARDS 4.14) |
| Add a backend endpoint / cache TTL | `Utilities/NetworkConfig` (API + `CacheTTL`) |
| Change persisted config | `Persistence/ConfigStore` (or `ProjectStore` / `UserDefaults` for install mode) |
| Restyle a card / banner / button | `Helpers/CardStyleExtensionView`, `BannerView`, `MatchedLabelStyle` |
| Change streamed console output | `Helpers/ConsoleOutput` + `OutputConsoleView` |
| Change launch / menu-bar behavior | `Catalyst/CatalystApp`, `Views/LaunchScreenView`, `Views/MenuBarContentView` |
| Add explainer/help copy | `Helpers/AppInfoCenter` (add an `InfoTopic`) |
| Add global refresh on an action | `AppViewModel.fullRefresh()` + `onGlobalRefresh` |

## 45. Glossary of load-bearing types
- **`AppViewModel`** — composition root; owns all services + VMs, `currentScreen`,
  `fullRefresh()`.
- **`AsyncProcessRunner`** — actor; runs processes off-main; `ProcessResult`
  (`stdout`/`stderr`/`exitCode`/`succeeded`).
- **`PrivilegesService`** — root via `sudo -S`; `validateSafeToDeletePath`.
- **`TerminalService`** — visible Terminal.app hand-off.
- **`InputSanitizer`** — `sanitizePackageName`, `singleQuote`.
- **`BrewPathManager`** — Apple-Silicon-vs-Intel brew prefix (async).
- **`InstallPreferences` / `PipInstallMode`** — global break-system-packages consent;
  `pipFlags(forPythonVersion:)` (§27).
- **`VersionComparator`** — version compare; `requiresBreakSystemPackages` (3.12+).
- **`Doctor` / `HealthCheckService` / `HealthIssue` / `HealthSeverity` /
  `HealthCategory` / `DoctorStatus`** — the diagnostics model (weights 20/5/1; stable
  `fixID`).
- **`CruftScanner` / `CruftItem` / `CruftType`** — the streaming disk-scan engine +
  its data (marker-guarded detection, Safe/Rebuild safety tiers).
- **`NetworkConfig` / `RemoteCache` / `CacheTTL`** — endpoints + cached fetch.
- **`ConsoleOutput`** — isolated high-frequency streamed text.
- **`ConfigStore` / `ProjectStore` / `HealthHistoryStore`** — JSON persistence.
- **`SmoothPageScroll` / `cardStyle()` / `BannerView` / `MasterHeaderView` /
  `SectionDivider` / `UpdateResultsSummaryCard`** — the shared UI primitives.
- **`GitGraphService` / `GitGraphLayoutEngine` / `GraphOptions` / `GitGraphPrefs`** —
  the Git Graph readers (fsmonitor-safe, timeout-bounded), the pure lane engine, the
  per-repo options + recents persistence (§48).

## 46. Footguns & gotchas
- **`PrivilegedHelper/` is NOT in the build** by design (separate helper target).
  Don't add its files to the app target — duplicate `main`.
- **Computed-bridge consoles.** If an install screen shows no output, check the
  `OutputConsoleView(console:)` wiring, not the string.
- **`installError` is a summary;** the console/Logs keep the full failure text — don't
  remove the console writes when you set the banner.
- **Single-char search returns nothing** — PyPI shards are 2-char minimum.
- **Empty `catch {}` in `Checkers/`** are intentional best-effort probes but hide real
  failures — add logging if you touch one.
- **`pip list --outdated`, not PyPI `info.version`** (the latter ignores
  `Requires-Python` and over-reports).
- **Filesystem scanners identify by MARKER, not name** (a `node_modules`/`venv`/
  `.gradle` needs a sibling project marker; see `CODING_STANDARDS.md` 8.3).
- **Brew paths are `async`** — access only from async contexts.
- **The data repo is a two-sided contract** — a `Codable` change needs a matching change in
  `theappfoundryco/data`.
- **The splash never waits on detection.** `startupChecks` runs `fullRefresh()` in a
  background `Task` and reveals the app after the 1.5 s floor; anything else can trap
  users on the launch screen (§29).
- **git can hang forever on fsmonitor.** A repo with `core.fsmonitor` enabled spawns a
  persistent `fsmonitor--daemon` that inherits and holds our stdout pipe open, so
  reading it to EOF never returns. All Git Graph git calls pass
  `-c core.fsmonitor=false`, `</dev/null`, and a hard timeout (§48).
- **`Canvas` layers escape `.clipShape`.** To round the corners of a card containing
  per-row `Canvas` gutters, apply `.compositingGroup()` before `.clipShape` (§48).

---

# Part VII — Roadmap

## 47. CatalystSnapshot (shipped v1)
Capture the whole dev environment into a portable `.catalystsnapshot` file and restore
it on a new Mac. Sidebar → *Migration → Snapshot & Migrate*
(`AppViewModel.Screen.snapshot`). A **diff-then-restore** engine: idempotent,
resumable, per-item, exit-code-gated. Reuses the existing service layer almost
entirely. Original design + decisions: `CatalystSnapshot-Plan.md`.

**Secrets (changed in v1.13 — this used to read "secrets are never exported").**
The default is still that nothing sensitive leaves the Mac: the shell scrubber
redacts secret-looking values and they are simply dropped. **Opt in** at capture
(sheet on the Capture click) and those same values are instead sealed into
`CatalystSnapshot.secrets` — PBKDF2-HMAC-SHA256 (210k rounds, per-snapshot salt) →
AES-GCM, **only that blob encrypted**, rest of the file still inspectable. The
passphrase is never stored, logged, hinted, or recoverable. Wrong/absent passphrase
is always `.skipped`, never `.failed`. See CODING_STANDARDS 12.38.

**Files.** `Models/SnapshotModels.swift`, `Services/SnapshotService.swift`,
`ViewModels/SnapshotViewModel.swift`, `Views/SnapshotView.swift` (all four registered
under the `CK` pbxproj prefix), plus v1.13's `Helpers/SnapshotCrypto.swift`,
`Services/SnapshotSecretsService.swift`, and
`Views/Components/SnapshotSecretsCards.swift`. The secrets *apply* step lives in
`SnapshotSecretsService`, deliberately outside the restore pipeline, so it's reachable
from Migrate, from the finished status screen, and from a standalone unlock sheet.

**The `.catalystsnapshot` file.** A zip (via `/usr/bin/ditto`) written/read by
`SnapshotArchiver`, containing a tolerant-decoded `snapshot.json` (`CatalystSnapshot`)
plus a convenience `Brewfile` + `requirements.txt`. Every section decodes tolerantly
(missing/renamed → empty, never a hard failure), so newer files load in older builds.

**What it captures** (`SnapshotCaptureService`, concurrent `async let`):
- **Homebrew** — taps + `leaves` + casks.
- **Python** — brew/pyenv/system interpreters + per-interpreter `pip freeze`.
- **Shell** — the `~/.zshrc_catalyst` managed blocks **and the full `~/.zshrc`**
  (`ShellSnapshot.mainProfile`), the latter **secret-scrubbed** (see below).
- **SmartShortcuts** inventory, **git** identity/aliases (read from `~/.gitconfig` as
  text — no shell, no Command-Line-Tools install prompt), and tracked **venv projects**
  (with captured `requirements.txt`).

**Secret scrubbing (`ShellSecretScrubber`).** The full `~/.zshrc` migrates its
structure (PATH, functions, theme, sourcing) without leaking credentials. The scrubber
only rewrites `NAME=…` / `export NAME=…` lines whose **name** looks secret
(`*KEY*`/`*TOKEN*`/`*SECRET*`/`*PASSWORD*`/`AUTH`/`PRIVATE`/…) or whose **value** is an
obvious token (`ghp_`, `sk-`, `AKIA`, `xoxb-`, JWT `eyJ`, PEM headers); PATH-like names
are allowlisted and `$`-references/empties are left alone. Redacted values become a
`<redacted by Catalyst — set this on your new Mac>` placeholder, the variable names are
recorded in `ShellSnapshot.redactedKeys`, and a **capture warning** lists them. (User
decision, 2026-07: auto-redact & warn.)

**Diff/plan (`SnapshotDiffer`).** Produces ordered, per-item `RestoreAction`s; already
-satisfied items are marked (idempotent skip) and can't-run-yet items carry a
`blockedReason`. The full-profile action `shell.profile` is **pre-selected on a clean
Mac but opt-in when a real `~/.zshrc` already exists** (never silently clobbers a
populated file).

**Restore (`SnapshotRestoreService`).** Runs the plan in dependency order, per item,
**deciding success on exit codes** (one failure never aborts the batch), streaming to
an isolated `ConsoleOutput`, honoring cancellation, and skipping keys already applied
in a prior run (`SnapshotResumeStore`, JSON in App Support → **resumable**). PEP-668
-aware via `InstallPreferences.pipFlags`; venvs never flagged. **There is no dry-run** —
restore installs directly (removed 2026-07). Restoring `shell.profile` **backs up the
target's existing `~/.zshrc`** to `~/.zshrc.catalyst-backup-<timestamp>` (and refuses
to overwrite if the backup fails), writes the imported profile, re-ensures the Catalyst
`source` line, then **syntax-checks with `zsh -n`** (no execution → no side effects).
Note: an app can't `source` into the user's live shell — the profile applies in new
terminals; the UI says so.

**UI (`SnapshotView` + `SnapshotViewModel`).** A top-level `Group` switches between
Landing → Working → Capture-ready → Restore-plan. Two **color-coded flows** (CODING_STANDARDS
4.15): **capture/export green, import/restore blue** — the VM's `workingTint` even
tints the shared scanning spinner per flow. The **landing** has two large illustrated
cards (gradient badge + tagline + a monochrome `FlowLayout` chip strip of the domains it
moves) and a one-line privacy footnote. **Capture-ready** ("Snapshot Ready", green) is a
machine + stat-badge summary (Categories/Items/Warnings), a per-category inventory with
blurbs, a warnings "Heads Up" card, and a sticky **export footer**. **Restore** splits
into a **preview** (grouped, toggleable diff via `InstantDisclosureGroup`) and a separate
**status** screen (progress + `RestoreSummaryCard` + console), both anchored by the
shared `SnapshotFooterBar` (CODING_STANDARDS 4.14) — a single blue **Restore N** button that
appears only when items are selected.

**Document icon.** `.catalystsnapshot` files show the full app icon via a custom
`Catalyst/CatalystSnapshotDoc.icns` (auto-bundled from the synchronized `Catalyst/`
folder), declared through `UTExportedTypeDeclarations` + `CFBundleDocumentTypes`
(`CFBundleTypeIconFile`) in `Info.plist`.

**Deferred** (per the plan): dotfiles beyond `~/.zshrc`, SSH **public** keys, and
toolchains remain v1.1/v2.

---

## 48. Git Graph (shipped v1)
A read-only, GPU-rendered commit-graph viewer for local repos. Sidebar → *Developer
Workflow → Git Graph* (`AppViewModel.Screen.gitGraph`). Original design + decisions:
`GitGraph-Plan.md`. Deferred items live in `UPCOMING.md`.

**Files** (pbxproj prefix `CL`). `Utilities/GitGraphLayout.swift` (`CL…A`, the pure
engine), `Services/GitGraphService.swift` (`CL…B`), `ViewModels/GitGraphViewModel.swift`
(`CL…C`, also home to `GraphOptions` + `GitGraphPrefs`/`GitGraphPrefsStore`),
`Views/GitGraphView.swift` (`CL…D`). No separate Models file — the value types live in
the service.

**Reading git (safety spine).** All facts come from **read-only** git: `rev-parse`,
`branch`/`tag`, `config`, `rev-list`, `log`, `status`, `show`. Three defenses make a
probe impossible to hang the UI on (learned the hard way — a repo with `core.fsmonitor`
spawns an `fsmonitor--daemon` that holds our stdout pipe open forever):
`-c core.fsmonitor=false -c gc.auto=0`, `</dev/null`, and a **hard timeout** via
`GitGraphService.withTimeout` (races the read against a sleep). The repo path and every
user-typed filter are `InputSanitizer.singleQuote`d. The summary's eight probes run
concurrently (`async let`).

**Layout engine (`GitGraphLayoutEngine`).** Pure, `Sendable`, unit-testable. Input is
commits newest-first (`--date-order`); it assigns lanes (reusing freed lanes so counts
stay minimal), emits `GraphNode`s (row + lane) and **`RowSegment`s per row** — the lane
lines passing through that row. Rendering per-row (not one giant `Canvas`) keeps the
graph fully lazy: each `CommitRowView` draws only its own gutter slice, so a
1,000-commit history never builds a 40,000-pt canvas layer.

**Adaptive width + frozen columns.** `GraphMetrics.laneWidth` compresses lanes (to a
~7 pt floor) so the gutter never dominates the window; node dots shrink with the lanes.
When even the floor overflows, a **shared horizontal offset** (`graphHOffset`) scrolls
the gutter + message region — driven by a native scrollbar in the pinned header via a
`PreferenceKey`, mirrored by every row (clip + `.offset`), so vertical `LazyVStack`
culling is preserved. The **author + hash columns are frozen** on the right and never
scroll. One `GeometryReader` at the loaded-state level feeds a single width to both the
scrollbar and the rows so they stay in sync.

**Controls (`GraphOptions`, persisted per repo).** Fetch options (refetch on change via
`fetchSignature`): scope (All refs / Current branch / **Local branches** default) ·
order (date / topological) · hide merges · first-parent · max commits · filters
(author / path / since / until). Display options (instant): density · show
author/hash/refs. Live **search hides** non-matching commits (matches-only list; lane
lines dropped in that mode). The **sticky reference header** (a pinned section header)
carries the title, legend, graph-only refresh button, search field, and the horizontal
scrollbar; its rounded card corners work because the per-row `Canvas` layers are flattened
with `.compositingGroup()` before `.clipShape`.

**Detail panel.** Clicking a row opens `CommitDetailSheet`: full message, author/email,
date, copyable hash, and per-file `+added / −removed` from `git show --numstat`.

**Persistence (`GitGraphPrefs` / `GitGraphPrefsStore`).** A `UserDefaults` JSON blob:
recent repos (most-recent first, capped 12, shown on the empty state) + each repo's saved
`GraphOptions`. Reopening a repo restores its view; unseen repos get fresh defaults.

**Discovery.** Always user-initiated — folder picker, drag-and-drop, or the recents list.
**No whole-disk crawl** for `.git` (consistent with the app's consent-first stance).

---

*Living document — this is the canonical reference and the source for the docs
website. When a feature, guarantee, doctor, endpoint, or cross-cutting decision
changes, update the matching section here so the next developer, the next LLM, and the
website all inherit the truth. Keep §2 (facts), Part II (features), §30 (file map),
§17▸ (doctors), §36 (endpoints), and Part VII (§47–§48 shipped features) in sync with
the source as it evolves. Deferred work lives in `UPCOMING.md`.*

---

# §49 — Telemetry, consent & distribution

Extends §36.

## 49. Design notes — the decisions worth keeping

Numbering is historical; gaps are sections deleted at v1.0 (entitlement, reconciliation,
cancel/resubscribe, rate limiting, the student-discount grants model, the Razorpay website
surface, and single-seat device binding). They described a paid product that no longer exists.

## 49.6 Telemetry — the facade
`Telemetry/Telemetry.swift` is the single choke point where an analytics or crash provider would be wired in. **Nothing is wired in.** Every method is a no-op outside DEBUG, no SDK is linked, and no identifier exists. Firebase Analytics + Crashlytics were removed at v1.0: a closed-source Google SDK inside a GPL app whose pitch is auditability was a contradiction, and the README's claim that no request carries anything about you could not stand alongside it. The facade survives deliberately — one file that answers "what does Catalyst report about me?" is easier to audit, and much harder to get wrong, than provider calls scattered across 170 files. `AppEvent` and `AppUserProperty` remain as the catalog any future provider would use. See CODING_STANDARDS 12.1 / 12.1b.

## 49.7 Sparkle auto-update (app side)
`UpdaterController` (in `CatalystApp.swift` — avoids a new pbxproj entry) is now an `ObservableObject` wrapping `SPUStandardUpdaterController` and acting as both `SPUUpdaterDelegate` and `SPUStandardUserDriverDelegate` (all method signatures verified against the Sparkle 2.x headers). `startingUpdater: true` schedules Sparkle's **own** hourly background checks. **Check-on-open (2026-07-14c):** the root `.task` calls `UpdaterController.shared.checkOnLaunch()`, which forces one background check ~3s after launch *guarded by `updater.canCheckForUpdates`* (false while a Sparkle session is already running → no `sessionInProgress` collision). This was added because relying on Sparkle's scheduler alone meant "open the app" frequently checked **nothing** — Sparkle only launch-checks once `SUScheduledCheckInterval` (1h) has elapsed since the last check and defers the first check after a fresh install, so the badge often didn't appear on open (diagnosed via `log stream` showing zero Sparkle activity on launch, feed confirmed correct server-side). `checkInBackground()` remains as a manual trigger. On find, `didFindValidUpdate` lights the badge immediately; auto-download then drives it to "Relaunch to update". `Info.plist`: `SUFeedURL` → `updates.theappfoundry.co/catalyst/appcast.xml`, `SUPublicEDKey`, `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` (silent background download), `SUScheduledCheckInterval = 3600` (hourly).

**Custom gentle UX (Claude-app style).** Instead of Sparkle's own windows, updates download silently and surface a sidebar badge — `SidebarUpdateBadge` (live wrapper) → `UpdateBadgeView` (pure visual, driven by an explicit `UpdatePhase`: `.available` / `.downloading` / `.readyToRelaunch`; both in `ContentView.swift`, `#Preview`-covered). The badge is a plain icon + one line of text (no version line, no animation); there is deliberately no release-notes affordance — `available` and `downloading` are passive status rows and only `readyToRelaunch` is tappable (CODING_STANDARDS 12.11b). Key hook: `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` fires the instant the silent download completes — we stash the block, show **"Relaunch to update"**, and return `true`; tapping the badge calls the block → installs + relaunches with **no Sparkle window** (falls back to `checkForUpdates()` if unavailable). `supportsGentleScheduledUpdateReminders` + `standardUserDriverShouldHandleShowingScheduledUpdate → false` suppress Sparkle's own popup. **Gotcha:** the visible reminder is deferred in auto-download mode (Sparkle's `SUScheduledImpatientCheckInterval`), so the badge is driven off the lifecycle callbacks above, not the gentle-reminder show callback.

**Distribution — see RELEASING.md.** The `.zip` is a GitHub Release asset on **`theappfoundryco/Catalyst`**; the appcast and each version's `notes.html` + `meta.env` live in **`theappfoundryco/updates`** under `catalyst/`, served from `updates.theappfoundry.co`. **Version-only:** bump `MARKETING_VERSION` only — `CURRENT_PROJECT_VERSION = $(MARKETING_VERSION)` makes `CFBundleVersion` track it, and `sparkle:version` = the marketing version (Sparkle's comparator orders 1.1 > 1.0). Signing note: the target must NOT pin `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` (ad-hoc) — it made the app ad-hoc while Sparkle.framework was team-signed and Hardened Runtime aborted with "different Team IDs". Use Apple Development + the team.

## 49.10 Legal consent — versioned Privacy/Terms re-consent (2026-07-17)
**What/why.** Legal docs change; when they do, every user must re-accept. A **blocking, non-dismissable** sheet gates the app until accepted; acceptance is stored **per-Mac** and survives force-quit/relaunch; a **14-day** check catches new versions.

**Files.** `Catalyst/LegalConsent.swift` (in the synchronized `Catalyst/` group → auto-registers, no pbxproj entry) holds `LegalConfig`, `LegalVersions`, `LegalConsentRequirement`, `LegalConsentViewModel` (`@MainActor`), and `LegalConsentSheet`. Storage fields live in `ConfigStore` (`acceptedPrivacyVersion`, `acceptedTermsVersion`, `cachedPrivacyVersion`, `cachedTermsVersion`, `lastLegalCheckISO`, `legalAcceptedAtISO`) + `recordLegalAcceptance` / `recordLegalRemote` accessors. `AppViewModel` owns `legalViewModel` and mirrors `$requirement → legalRequirement`. `ContentView` presents the sheet.

**Version source (Vercel, static — NOT Worker/Pages).** `refreshIfDue()` (every 14 days) GETs `https://theappfoundry.co/legal/catalyst.json` (`public/legal/catalyst.json` in the `theappfoundryco` repo). It is **deliberately not under `/catalyst/*`**, so the Vercel Edge Middleware never runs for it → **1 Edge Request, 0 Edge-Config reads**. Hobby caps: **1,000,000 Edge Requests/mo, 100,000 Edge-Config reads/mo**. (The middleware-backed bug/feature/support redirect links read Edge Config on every hit, so they burn *both* budgets — Edge-Config reads (100k) is the tighter ceiling for those, not the legal check.)

**Truth model.** `current = cached ?? bundled` per doc. The remote manifest (cached) is the source of truth; `LegalConfig.bundled*Version` is only the offline/first-run fallback. Re-consent when `accepted != current` (exact match, per doc). **Override lever:** bumping `bundled*Version` alone only re-prompts devices that have never fetched the manifest — for everyone else the cached value wins. Both docs currently **v1.1** (manifest + bundled kept in sync).

**Flow.** With no sign-in there is no consent checkbox, so the blocking sheet is the ONLY path and catches everyone: fresh installs, existing installs with nothing stored, and later version bumps alike. Copy adapts: "We've updated…" vs "Please review…", and only the doc(s) that changed. Force-quit mid-sheet → recomputed from persisted state on next launch, so it re-appears.

**Gotchas (both bit us).** ① `@Published`/`ObservableObject` need an explicit `import Combine` — SwiftUI didn't re-export it. ② Two `.sheet` modifiers on one view is unsupported ("Publishing changes from within view updates" + thrash); the legal sheet is hosted on its **own node** via `.background(Color.clear.sheet(item: $appVM.legalRequirement))`, separate from the `infoCenter` sheet on the `NavigationSplitView`. `LegalConsentRequirement` is `Identifiable` with a **stable** id (not `UUID()`) so the item-sheet doesn't churn.

## 49.11 Default Python Version card — surgical `~/.zshrc_catalyst` editing (2026-07-17)
**What.** A dashboard card (`DefaultPythonCard` in `DashboardCards.swift`, driven by `Catalyst/PythonDefaultManager.swift`, owned by `DashboardViewModel`) that sets the default `python`/`python3`/`pip` for **new shells**.

**Mechanism.** Writes one line — `export PATH="<prefix>/opt/python@X.Y/libexec/bin:$PATH"` — inside a **marker-delimited managed block** (`# CATALYST_BEGIN python-default` … `# CATALYST_END`) in **`~/.zshrc_catalyst`**, via `ShellConfigManager.writeManagedBlock`/`removeManagedBlock` (same convention as Aliases/Shortcuts). Blocks are found by **sentinel search, not line number** → reordering-proof. **`~/.zshrc` is never edited** beyond the one pre-existing `source ~/.zshrc_catalyst` line. Since `.zshrc_catalyst` is sourced last, our block wins PATH precedence.

**Intel vs Apple Silicon.** The **only** difference is the Homebrew prefix — `/opt/homebrew` (Silicon) vs `/usr/local` (Intel) — resolved at runtime by `BrewPathManager` (correct even under Rosetta, where an Intel brew lives under `/usr/local` on an ARM Mac). The `python@X.Y` formula name and the `…/opt/python@X.Y/libexec/bin` layout are identical on both.

**Safety.** Before writing: verify `…/libexec/bin/python3` exists (never write a PATH to a missing dir). After writing: `backupCatalystConfig()`, then `zsh -n <file>` syntax-check and **roll the block back** if it won't parse. Detection reads both files **read-only**: our block first, else an external default pinned in `~/.zshrc` (best-effort regex; surfaced in the current-default row, never edited). Reset removes only our block → whatever the user had resurfaces (no orphaned commented lines).

## 49.12 AsyncProcessRunner concurrency model — the launch-hang lesson (2026-07-17)
**Two-line rule.** (1) **Never block a Swift cooperative-pool thread.** Pipe draining in `run(command:)` uses `readToEnd` on a **libdispatch** queue (`DispatchQueue.global().async` + `withCheckedContinuation`), *not* `Task.detached` — the cooperative pool (width ≈ core count) must never be blocked on I/O, or *nothing* async can run (including timeout tasks). (2) **No bounded permit-throttle over blocking work.** The old `AsyncConcurrencyLimiter(6)` was **removed** — its only job was to cap concurrent blocking reads (obsolete after (1)), and it could **starve** a probe at `acquire()` forever (a parked call never spawns, so a process-timeout can't rescue it).

**The bug (so it's never re-debugged).** Launch froze intermittently: `🔍 Starting detection…` with no `✅ Detection complete` → `isDetecting` stuck → spinner forever. Debug trace showed a `🐛 sh REQUEST` with no matching `PERMIT` = parked at `acquire()`. Removing the limiter (both root causes stacked) fixed it; validated across repeated force-quit/relaunch. **Defense-in-depth:** `run(command:)` has an opt-in `timeoutSeconds` (SIGTERM→SIGKILL); detection's `--version`/`pip --version` probes pass `10`.

**Coalescing invariant.** `PythonService.detectPythons()` single-flights via `inFlightScan` + `scanGeneration`. **Never `await` between the `if let inFlightScan` check and the `inFlightScan = task` assignment** — a suspension there (we had one via the `async` `homebrewPrefix` in a log line) lets concurrent `@MainActor` callers all pass the check → a scan stampede.

**Debug tracing.** `Logger.debugLog(_:)` (autoclosure, `#if DEBUG`) drives the `🐛` `REQUEST/PERMIT`(historical)/`START/SPAWN/READ/DONE` logs in `AsyncProcessRunner` + per-probe/per-batch markers in `PythonService`/`DashboardViewModel`. **Zero cost in Release** (autoclosure isn't evaluated). Reading a hung log: last `🐛` before the stall = the wedged step; `START` without `SPAWN`/`DONE` = a wedged child (timeout catches it now).

## 49.14 Going free and open source (2026-07-21)
At v1.0 Catalyst became free and open source under the **GPLv3** (`theappfoundryco/Catalyst`), removing the paid system that preceded it.

What that removed, in one pass: ~3,600 Swift lines across `AuthService`, `AuthViewModel`, `AuthGateView` and `UserProfileView`; a 1,688-line Cloudflare Worker with 25 routes, D1 and KV; gift codes, invoicing, billing profiles, payments, trials and single-seat device binding; the Firebase SDK; and the XCTest target.

What it left: an app with no accounts, no server, no analytics and no gate — `ContentView` renders the sidebar immediately on launch. The only network reads are static files (§36).

**The pre-v1.0 history is not in this repo.** It lives in the original private repository. This repo starts at v1.0 with a fresh initial commit, so `git log` will not explain why a deleted system worked the way it did — CODING_STANDARDS Part 12 is where those lessons were preserved.
