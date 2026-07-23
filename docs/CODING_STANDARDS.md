# Catalyst — Coding Standards

**The single source of truth for how to build Catalyst further.** If you're adding
a screen, a service, a shell call, or a card, the answer to "how do we do that
here?" is in this file. Read it before writing code; update it when you learn a
new gotcha.

Catalyst is a **native macOS** SwiftUI app (MVVM + service layer) that gives
developers GUI control over their Mac dev environment. It is **not** iOS — some
rules here exist specifically because macOS (`NSScrollView`, hover, `AppKit`
bridging, `sudo`) behaves differently.

Companion docs: architecture overview → `ARCHITECTURE.md`;
scroll-smoothness deep-dive → `ANTI_PATTERNS.md`; release runbook → `RELEASING.md`.

> **How to use this file.** These are conventions this codebase actually holds to, and most
> of them exist because something broke. A rule that reads as fussy usually cost someone a
> session. Read Part 12 before your first non-trivial change; it's the list of things that
> looked correct, shipped, and were wrong.
>
> Rules were pruned at v1.0 when accounts, payments and the backend were removed. Where a
> deleted rule carried a lesson that outlived its subject, the lesson was rewritten to stand
> on its own — a rule that only makes sense next to code you can't read is worse than no rule.

---

## Part 1 — Architecture & module layout

1.1 **One screen = one View + one `@MainActor` ViewModel.** Register it in
`AppViewModel.Screen`, construct the VM in `AppViewModel.init` (manual DI — no
framework), and add a `case` to both the sidebar list and the detail `switch` in
`ContentView`.

1.2 **Layers depend downward:** Views → ViewModels → Services → Utilities/Models.
Never call up. A View never runs a shell; a Model never imports SwiftUI.

1.3 **Keep ViewModels thin.** When a VM crosses ~12 `@Published` or grows past a
few hundred lines, extract logic to a `Services/` (`@MainActor class` if stateful
and VM-driven) or `Utilities/` (`Sendable struct` if pure/background) type. Stream
output back via an `onOutput` callback so the console stays VM-owned. The five
god-VMs (Dashboard, CruftSweeper, VirtualEnvCreation, SmartShortcuts,
PopularPackages) are already decomposed — mirror that pattern, don't regress it.

1.4 **Wire new global-state-changing actions into `AppViewModel.fullRefresh()`**
so an install/uninstall anywhere refreshes the whole app consistently.

1.5 **New diagnostic = a new `Doctor`** in `Checkers/` conforming to the `Doctor`
protocol (`run`/`fix`/optional `checkAvailability`), registered in
`HealthCheckService`, with a `HealthCategory` case and a stable `fixID` (route
fixes on `fixID`, never on the issue title).

---

## Part 2 — Shell execution & safety (non-negotiable)

This is the app's spine. Every shell interaction goes through one of three tiers.

2.1 **Never run a shell inline.** Route through:
- `AsyncProcessRunner` (actor) — non-privileged reads/writes, off the main thread.
  Prefer the **array-args** path `run(executable:arguments:)` / `runBrew(...)`
  (no shell, no quoting) over command strings.
- `PrivilegesService` — root actions via `osascript`→`sudo -S`. The single most
  sensitive path; any change needs extra review + tests.
- `TerminalService` — interactive/visible hand-off to Terminal.app (e.g. the brew
  install script). Rejects newlines/control chars.

2.2 **Sanitize everything that reaches a shell.** Package names →
`InputSanitizer.sanitizePackageName` (ASCII allowlist). Paths/args → `singleQuote`
(one quoting layer — `shellEscape` is now `private`; do not reintroduce bare
call sites).

2.3 **Gate every destructive delete** through `validateSafeToDeletePath`
(allowlist-first). Prefer `trashItem` (recoverable) over `removeItem`. Hard-skip
`.ssh`, `.Trash`, `.git`.

2.4 **Decide success on exit codes, never by string-scraping** stdout.

2.5 **Resolve Homebrew paths via `BrewPathManager`** (Apple Silicon vs Intel);
never hardcode `/opt/homebrew` or `/usr/local`. Note `homebrewPrefix`/`brewPath`
are **`async`** — access only from `async` contexts.

2.6 **Never write secrets to disk.** The sudo password is passed in-memory
(`CATALYST_BREW_SUDO_PW` / stdin to `sudo -S`), never embedded in a script.

2.7 **pip installs on an externally-managed Python (3.12+) obey the global install
mode.** Homebrew/system Python 3.12+ mark themselves externally managed (PEP 668)
and refuse writes without `--break-system-packages`. Catalyst exposes this as ONE
global, persisted setting — `InstallPreferences.shared.mode` (`.protected` /
`.userSpace` / `.systemWide`, in `Helpers/InstallPreferences.swift`,
UserDefaults-backed). Rules:
- **Build every pip command's flag via `InstallPreferences.pipFlags(forPythonVersion:)`**
  — a thread-safe `static` (reads UserDefaults) so off-`@MainActor` command builders
  can call it. It returns `""` for Python <3.12 *or* `.protected` mode, else the
  mode's flag; append it to the command string. **Never hardcode
  `--break-system-packages`.** Injected sites: `OutdatedPIPViewModel`,
  `PIPPackagesInstallViewModel`, `RequirementsViewModel` (`-r` + per-package retry),
  `PythonManager` (pip self-upgrade), `ShortcutInstaller`, `PackageInstaller`,
  `PopularPackagesViewModel`.
- **The 3.12+ boundary is `VersionComparator.requiresBreakSystemPackages(pythonVersion:)`
  — the single source of truth.** Don't re-derive "is externally managed" elsewhere.
- **Virtual environments are NEVER given the flag** (a venv isn't externally
  managed) and are NEVER gated. Pass the venv's own interpreter version; `pipFlags`
  returns `""` for it.
- **Switching away from `.protected` is destructive → confirm it** (a
  `confirmationDialog`); reverting to `.protected` is safe and immediate, everywhere.
  The **app-wide** control + indicator live in the sidebar status bar/popover
  (`StatusIndicatorView` shield — green Protected / red override — + `StatusPopoverView`
  menu), **not** a standalone sidebar banner (that was removed 2026-07). The
  per-interpreter control still lives in `SelectPythonVersionDropdown`.

2.8 **Capturing user config that can hold secrets → scrub before it leaves the Mac,
back up before you overwrite.** Snapshot & Migrate (§47) exports the full `~/.zshrc`,
so it runs through **`ShellSecretScrubber`** first: only `NAME=…`/`export NAME=…`
lines whose name looks secret (`*KEY*`/`*TOKEN*`/`*SECRET*`/`*PASSWORD*`/`AUTH`/
`PRIVATE`/…) or whose value is an obvious token (`ghp_`, `sk-`, `AKIA`, `xoxb-`, JWT
`eyJ`, PEM headers) are redacted to a placeholder; PATH-like names are allowlisted and
`$`-refs left alone. Record the redacted names and **warn the user**. **Never export
passwords, tokens, SSH private keys, or `.env` files** — capture is allowlist-only.
When a restore overwrites a user-owned file (e.g. `~/.zshrc`), **back it up first**
(`~/.zshrc.catalyst-backup-<timestamp>`) and refuse to proceed if the backup fails;
prefer a non-executing validation (`zsh -n`) over sourcing an arbitrary profile. An app
cannot `source` into the user's live shell — say "open a new terminal" instead of
faking it.

2.9 **Read-only git must be fsmonitor-safe, stdin-closed, and timeout-bounded.** A repo
with `core.fsmonitor` enabled forks a persistent `fsmonitor--daemon` that **inherits and
holds our stdout pipe open**, so reading to EOF never returns — a silent infinite hang
(it stuck "Reading repository…" for minutes). Every Git Graph git call therefore passes
**`-c core.fsmonitor=false -c gc.auto=0`**, **`</dev/null`** (git can never block on a
prompt), and runs through **`GitGraphService.withTimeout`** (races the read against a
sleep, returns `nil` on timeout). Path + every user-typed filter are `singleQuote`d.
Prefer this shape for any new git reader (`GitGraphService.git(...)` is the template).

2.10 **Never log secrets or credentials — anywhere, in any tier.** `Logger.shared` writes to
`app.log` on disk **and** streams to the user-visible Logs screen, so a logged secret is a
persisted leak (this is 2.6 — "never write secrets to disk" — applied to logging). Never
interpolate into a log/`print`: the sudo password, the snapshot passphrase, API keys, tokens,
or anything matching `*KEY*`/`*TOKEN*`/`*SECRET*`. Log **non-sensitive facts only** — exit
codes, counts, sanitized names, error *categories* (not raw bodies that may embed a token).
The app already obeys this: `AsyncProcessRunner` logs no command
strings, `PrivilegesService` logs credential *events* ("Loaded admin credential"), never the
value. Route app output through `Logger` (not raw `print`/`NSLog`); a debug-only `print` must
be `#if DEBUG`-gated so it's stripped from release. **Backend (Worker/Vercel):** any
credential echo (e.g. a dev magic link / `dev_code`) is **dev-gated** — guard every such
`console.*` with `env.ENVIRONMENT !== "production"`, and never `console.log` a raw response
body that could carry a token. Log errors as messages, not secrets.

---

## Part 3 — Scroll smoothness (macOS-specific)

Full rationale in `ANTI_PATTERNS.md`. The short version:

3.1 **Every page scroll uses `SmoothPageScroll`, not a bare `ScrollView`.**
`SmoothPageScroll` (in `Helpers/CardStyleExtensionView.swift`) is a `List`-backed
container (`NSScrollView` momentum + row recycling). A plain `ScrollView { VStack }`
scrolls in a steppy/jerky way on macOS, worst in Release + large windows. Pattern:
```swift
var body: some View {
    SmoothPageScroll {
        VStack(spacing: 24) { /* cards */ }
            .padding(.vertical)
    }
    .navigationTitle("…")
}
```
**Exception:** a screen with `NavigationLink`s or interactive `Link`s as primary
content (e.g. SmartShortcuts, About) uses a plain `ScrollView`, not
`SmoothPageScroll` — `SmoothPageScroll` wraps the whole page in one `List` row,
so a link tap highlights the entire page blue. Use the `List`-backed engine only
for non-navigating card content. Also: **every screen must be inside a scroll
container** — a bare `VStack` detail (About, before this) lets tall content grow
the window past the screen and shove the sidebar's bottom status off.

3.2 **Never nest a vertical `ScrollView` inside the page scroll** (`ANTI_PATTERNS.md`
Rule 1 — the #1 jank cause). Horizontal inner scrolls are fine (different axis).
Known offenders still to fix: `OutputConsoleView`, install/search-result lists,
Alias/Requirements previews. `LogsView`'s single `ScrollViewReader` scroll is the
correct exception.

3.3 **No `.shadow`, `Material`, `.blur`, or `Divider()` (hairline) on scrolling
content.** Use `cardStyle()`'s opaque fill + hairline `strokeBorder`, and
`SectionDivider` for separators. Shadows/materials on **pinned, non-scrolling**
overlays (tooltips, HUDs) are fine.

3.4 **No `.scaleEffect`/spring on hover in scrolling rows.** As the cursor sweeps
during scroll, hover fires per-frame and forces relayout. Use a cheap
opacity/background swap with a short `.easeInOut`, not `.spring()`/`withAnimation`.

3.5 **No expensive work in `body`** — no `.sorted`/`.filter`/`.enumerated`
recomputed inline (especially twice). Compute once (`let` at the top of `body`, or
a `private(set)` on the VM sorted in `didSet`).

3.6 **Big lists stay lazy; rows stay cheap.** `LazyVStack`/`LazyVGrid` for any
collection; leaf rows are `Equatable` and take **plain values + closures**, not
the whole `@ObservedObject` VM.

3.7 **Isolate streaming/high-frequency state.** Streamed command output lives in a
tiny `ConsoleOutput` (`ObservableObject`) observed only by the leaf console view,
with coalesced appends — never read its `.text` in the parent `body`.

3.8 **Don't use `.drawingGroup()` on live/interactive cards** (`PerfFlags.rasterizeScrollCards`
stays `false`). It re-rasterizes on any child change and softens text.

3.9 **Navigation modifiers go OUTSIDE `SmoothPageScroll`, never inside its
content.** `SmoothPageScroll` is a `List` (lazy container). Attach
`.navigationTitle`, `.toolbar`, and especially **`.navigationDestination`** to the
`SmoothPageScroll` itself (or a non-lazy parent like a `GeometryReader`), not to
the inner `VStack`. SwiftUI **ignores `navigationDestination` inside a lazy
container** (the detail link silently does nothing), and a `.toolbar` inside it
realizes only intermittently (the window toolbar flickers in and out). Pattern:
```swift
SmoothPageScroll {
    VStack(spacing: 24) { /* content */ }.padding(.vertical)
}
.navigationTitle("…")
.toolbar { … }
.navigationDestination(for: String.self) { … }   // outside the List
```

3.10 **Frozen columns + horizontal scroll without breaking vertical laziness (Git
Graph).** Don't nest the vertical list inside a horizontal `ScrollView` — that realizes
every row (kills culling, 3.2/3.6). Instead: keep rows in a plain `LazyVStack`, compute
one geometry from a single `GeometryReader` at the container level, and apply a **shared
horizontal offset** per row (`content.frame(width: leftContent).offset(x: -hOffset)
.frame(width: leftViewport).clipped()`). Freeze the right columns (author/hash) outside
that clip. Drive `hOffset` from a native scrollbar via a `PreferenceKey`. Render the
graph **per row** (each row draws its own small `Canvas` gutter slice from
`GitGraphLayout.rowSegments`), never one tall `Canvas`. Lane width **adapts** to the
window (`GraphMetrics.laneWidth`, floor ~7 pt) before the scroll engages; shrink node
radius with it. To round a card wrapping per-row `Canvas` layers, apply
**`.compositingGroup()` before `.clipShape`** — `Canvas` layers otherwise escape the clip
and square the corners. A pinned **section header** (`pinnedViews: [.sectionHeaders]`,
`spacing: 0` so it abuts the rows) is the way to keep a legend/toolbar stuck to the top.

---

## Part 4 — UI & components (consistency)

4.1 **Cards use `cardStyle()`** — the single source of truth for card chrome
(padding, opaque fill, hairline border). Don't re-roll backgrounds. Use
`cardStyle(.compact)` for inline chips, `codePanel()` for recessed code/log areas.

4.1b **Status banners use `StatusBanner` / `.statusBannerChrome(tint:)`** (both in
`Helpers/CardStyleExtensionView.swift`) — the single source of truth for the tinted,
bordered inline call-outs (tint fill @0.12 + hairline border @0.28, radius 12). Use
`StatusBanner(icon:tint:text:)` for a simple icon + message; apply `.statusBannerChrome(tint:)`
directly when the banner body needs a spinner or dismiss button. Don't hand-roll a tinted
RoundedRectangle for a banner — every call-out in the app must match.

4.2 **A button's SF Symbol must NEVER be a different color from its (white) title.**
`ContentView` sets **`.symbolRenderingMode(.monochrome)`** once on the detail
`NavigationStack`, which collapses multicolor/hierarchical palettes to one color and
handles most cases — but it does NOT stop macOS from accent-tinting the glyph **blue**
on `.bordered`/tinted controls while the title stays white. Neither `.tint(.primary)`
nor a foreground override reliably beats that. So the bordered roles (`.neutral`,
`.secondary`) render through **`NeutralActionButtonStyle`** (`MatchedLabelStyle.swift`),
which forces the whole label to one color on a neutral surface — icon == title,
always. Prominent roles (`.borderedProminent`) already render a white glyph on the
fill, so they match by construction. This does NOT touch the sidebar (keeps its
colored icons) and preserves explicit `.foregroundColor`/gradient on icons. Use
`.symbolRenderingMode(.hierarchical/.palette/.multicolor)` **locally** on the rare
icon that genuinely needs color depth.

4.2a **Every button routes through the centralised `.appButton(_:)` — never
`.buttonStyle(_:)` directly.** `Helpers/AppButtonStyle.swift` is the single source of
truth: it maps each semantic ``AppButtonKind`` to its concrete style, so the whole
app is consistent and can be restyled from one file. Prominent roles use native
`.borderedProminent`; the bordered roles use `NeutralActionButtonStyle` so their icon
always matches the title (§4.2). Pick a button by role, not by appearance:

- `.primary` — main call-to-action (prominent, filled). Add a call-site `.tint(_:)`
  to color it (e.g. Homebrew's per-operation blue/green/orange/red, Cruft's blue
  "Select All" / green "Select Safe").
- `.destructive` / `.destructiveProminent` — prominent solid red (Delete, Remove,
  Uninstall), at row and card-CTA scale. Same depth as `.primary`, only the color
  differs — never a flat red surface.
- `.neutral` — bordered secondary (Cancel, Clear, Choose…, Retry). Via
  `NeutralActionButtonStyle`, so an icon+title label never shows a mismatched glyph (§4.2).
- `.secondary` — compact secondary (Copy, Reveal, row actions); shares `.neutral`'s
  bordered, icon-matching treatment.
- `.plain` — bare icon buttons and tappable rows.
- `.borderless` — inline, link-like affordances (toolbar glyphs, "Move up").
- `.link` — a text hyperlink (accent-colored, no chrome).

Per-button variation (`.tint`, `.controlSize`, full-width framing) stays at the call
site and composes on top of the role. The only file allowed to call `.buttonStyle(_:)`
is `AppButtonStyle.swift` itself.

4.3 **Icons are `.fill` variants** (Catalyst house style). Sidebar + card icons
use the filled SF Symbol.

4.4 **Colors from semantic system values** — `Color(NSColor.controlBackgroundColor)`,
`.secondarySystemGroupedBackground`, etc. — so light/dark and accent stay correct.
The app is forced dark (`preferredColorScheme(.dark)`), but don't hardcode hex.

4.5 **Reusable inputs:** `CompactInputField` for typed fields, `SearchBarView` for
search (now shares `CompactInputField`'s exact look — **all text entry uses one
field style**), `EmptyStateView`/`LoadingStateView` for empty/loading, `ErrorBanner`
for failures, `SectionDivider` for separators, `MasterHeaderView` for page headers.
Reach for these before inventing a new one.

4.6 **Actions live in a described card, not a bare action bar or jargon banner.**
The house pattern (see `DashboardCards`, `AliasView`, and now PATH Editor /
Network Diagnostics): a card with a headline **title**, a `SectionDivider`, a
one-line **plain-language description of what the action does**, and the action
**button inline** (usually trailing). Don't surface implementation jargon (file
paths like `~/.zshrc_catalyst`) in a banner — fold it into a card description.
Button `Label`s here use `.labelStyle(.matched)` so the icon matches the title.

4.7 **Prefer immediate/auto-save over hidden staged edits.** A "make an edit →
nothing happens until you find the Apply button" flow is a footgun (PATH Editor
had this — deletes appeared to "come back" on re-scan). Auto-save edits and give
immediate feedback. When what's persisted differs from the live view (e.g. PATH
changes apply to *new* terminals, and a re-scan should show the *saved* order, not
the stale session env), say so in the card description and make the view reflect
the saved state.

4.8 **Contextual action-gating, not blanket disabling.** Disable an install/update
button only in the genuinely-futile state — Python 3.12+ with install mode
`.protected` (`requiresBreakSystemPackages(version) && mode == .protected`), where
pip would refuse to write. There, disable **and** show an inline reason pointing at
the Install-mode control; choosing an override re-enables it. `@ObservedObject` the
`InstallPreferences.shared` singleton in the view so the button re-enables
reactively when the mode flips. Requirements' "Install All" is gated strictly for
≥3.12 this way (`isInstallDisabled` / `isBlockedByProtectedMode`). Never gate
virtual-environment creation.

4.9 **Modular info via `InfoDot` + one shared sheet.** All explainer copy lives once
in `Helpers/AppInfoCenter.swift` (`InfoTopic`). Drop an `InfoDot(topic:)` (ⓘ)
anywhere; it shows a quick popover, and "Learn more" deep-links into the single
app-wide `AppInfoSheet` (presented at the `ContentView` root via
`InfoCenter.shared.present(_:)`). Don't scatter bespoke help sheets — add a topic
and reuse the dot.

4.10 **Results/summary cards use the status-header grammar; never duplicate the
status icon.** A results card leads with ONE status HStack: a single status icon
(`.title2` — green check / orange triangle) + title (`.headline`) + inline counts
(`.caption .secondary`). The counts row must NOT repeat a second green checkmark —
the icon lives in the header only. This was a recurring bug; the canonical shape is
`UpdateResultsSummaryCard`.

4.11 **No false "success" celebration on a review/worklist screen.** A scan that
surfaces work-to-do opens on an informative header (item/location counts + the
headline number), not a giant green ✓ "Complete!". Lead with the actionable number
(e.g. reclaimable space), a proportional breakdown, and smart-selection actions —
see Cruft Sweeper's `CruftSummaryCard`.

4.12 **Config toggle sections are rows, not tile grids.** A set of toggles uses the
`Safety & Performance` row grammar — colored `.fill` icon (24pt frame) + title
(`.body`) + one-line subtitle (`.caption .secondary`) + trailing `.switch`, with
`SectionDivider` between rows. Don't invent bespoke selectable tiles (the old
neon-bordered Cruft "Targets" grid was replaced by `TargetToggleRow`). Collapse a
long, set-and-forget section behind `InstantDisclosureGroup` with a
"Name · N of M selected" header.

4.13 **Convey magnitude and consequence in quantitative rows.** For size/impact
lists, add a proportional bar (scaled to the largest item) and a semantic chip
(e.g. Cruft's green "Safe" / orange "Rebuild" from `CruftType.safety`) instead of a
wall of equal-weight rows. Keep the row `Equatable` over plain values (3.6); when a
fraction/proportion feeds the row, include it in `==`.

4.14 **Selection/commit screens pin their action in a sticky footer bar — one shared
grammar.** The bar is `SectionDivider` then a padded `HStack` on
`Color(NSColor.controlBackgroundColor)`: a `.headline` count/title + `.caption`
`.secondary` subtitle on the left, actions pinned right; the prominent button is a
**semibold `Text`** with **`.frame(minWidth: 140)`**, `.appButton(.primary)`,
`.controlSize(.large)`, secondary buttons semibold on `.appButton(.neutral)`. **Show it only
when there's something to act on** (Cruft: `!selectedIDs.isEmpty`; Snapshot preview:
`actionableCount > 0`). Cruft Sweeper's delete bar is canonical; Snapshot & Migrate
reuses the exact same look via the shared **`SnapshotFooterBar`** (capture-export,
restore-preview, restore-status all route through it). Don't hand-roll a one-off action
bar — reuse the shell so every footer matches.

4.15 **A directional flow keeps ONE accent color end-to-end.** When a feature has
opposite directions, give each its own accent and carry it through the whole flow —
landing card, working spinner (`SnapshotViewModel.workingTint`), header, stat badges,
and footer button. Snapshot & Migrate: **capture/export = green, import/restore = blue**
(matching the two landing cards). This is separate from **domain** colors, which stay
meaning-bearing regardless of flow (Homebrew orange, shell/git purple,
python/pip/projects blue); on a decorative surface (landing chips) render domains
monochrome so the flow's single accent reads cleanly.

---

## Part 5 — Remote content & data contracts

5.1 **There is no backend — only read-only static JSON** on GitHub Pages
(`data.theappfoundry.co/catalyst/public/...`), authored in the **`theappfoundryco/data`**
repo. Nothing accepts a write and no request identifies a user. The app degrades gracefully offline via `NetworkMonitor`; remote reads are
cached per `CacheTTL` (max-safe: shortcuts/brew 7d, popular/python/about 30d, pypi
shard 48h — refresh button busts, stale-on-error covers offline), Python detection
caches 5min.

5.2 **No markdown rendering in the app.** (Decision, 2026-07.) Remote detail
content is delivered as **structured JSON** and rendered by native reusable
components. For SmartShortcuts: `ShortcutContent` → `ShortcutContentView`
(overview / usage / steps / parameters / examples / sample-output / notes cards).
Do not add MarkdownUI or any markdown renderer back.

5.3 **Never reveal the shell code.** (Decision, 2026-07.) `shell_code` stays in
the payload for the installer but is **never surfaced in the UI** — no "Code"
section, and code fences are stripped from notes.

5.4 **Data-contract changes are two-sided.** If you change a Codable model, update
the generator/migrator in the `theappfoundryco/data` repo (`tools/`) to match, and vice-versa. Decode
tolerantly (missing keys → empty defaults) so partial/older payloads never crash.
The PyPI "hot shards" contract: app requests `pypi/<first-2-lowercase-chars>.json`
and decodes `[{ "name", "fetched_at" }]`; the generator must bucket the same way.
(Known bug: `PIPPackagesViewModel` still decodes the shard as `[String]` — flagged
in-code, fix to `[PackageItem]`.)

5.5 **All remote reads go through one cached caller.** Fetch remote JSON via
**`NetworkConfig.fetchJSON(from:as:ttl:)`** — never call `apiSession.data(from:)`
+ `JSONDecoder` inline. It delegates to `RemoteCache` (disk-backed): a payload
younger than `ttl` is served without a network hit, stale is refetched, and on a
network error a stale copy is returned (offline-safe). Stale timeouts live in one
place — the **`CacheTTL`** enum — so tuning cost/freshness is a one-file edit.
Pass `CacheTTL.never` to bypass caching. (The `NetworkMonitor` liveness ping and
direct-to-PyPI version checks are intentionally *not* cached.)

---

## Part 6 — Persistence & networking

6.1 **Persistence is JSON under `~/Library/Application Support/com.shivanggulati.catalyst/`**
with corruption fallback (back up the bad file, start fresh). Reuse `ConfigStore`/
`ProjectStore`/`HealthHistoryStore` patterns. Prefer tolerant per-element decode
(`Lossy<T>`) so one bad record doesn't discard the store.

6.2 **All `URLSession` goes through `NetworkConfig`** (tuned 15s API / 120s
download sessions), not `URLSession.shared`.

6.3 **Models are `Codable`/`Sendable`/`Identifiable`** value types. Take
concurrency correctness seriously (actors, `@MainActor`, detached tasks for
synchronous I/O like `FileManager` traversal).

6.4 **Small per-key state → a `UserDefaults` JSON blob, not a file store.** For a tiny,
losable preference bundle (e.g. Git Graph's recent repos + per-repo `GraphOptions`, or
`InstallPreferences`' mode) encode a `Codable` blob into `UserDefaults` — no file I/O,
no corruption fallback, no new-file pbxproj registration. Reserve `ConfigStore`-style
JSON files under App Support for larger/structured stores (6.1). Pattern:
`GitGraphPrefsStore` (`load()`/`save()` around a `JSONEncoder` + one defaults key).

6.5 **The launch splash must NEVER gate on detection.** `AppViewModel.startupChecks`
runs `fullRefresh()` in a background `Task` and flips `isAppReady` after the 1.5 s
animation floor — nothing else. Gating on the full detection sweep meant any one slow or
stuck probe (brew `du`, a git CLT prompt, a hung fetch) trapped the user on the launch
screen (it happened repeatedly). Every result is `@Published`, so the UI fills in as
each check finishes.

6.6 **Keychain on macOS: check the `OSStatus`, and mind `kSecUseDataProtectionKeychain`.**
Catalyst no longer has accounts, so nothing secret is stored — but the trap that cost a
session here is general and applies to anything that ever writes to the Keychain (the
snapshot passphrase flow is one keystroke away from it). Do NOT set
`kSecUseDataProtectionKeychain` on an unsigned build: on macOS that keychain requires a
code-signing entitlement (`keychain-access-groups` / `application-identifier`) an ad-hoc
build lacks, so `SecItemAdd` fails `errSecMissingEntitlement` **silently** and nothing
persists. The symptom is not an error — it's state that vanishes every launch. Always check
the `SecItemAdd` `OSStatus` rather than assuming success.

6.7 **Window chrome — never cover the native titlebar (rewritten 2026-07-14).** The
old approach (full-window SwiftUI overlays with `.ignoresSafeArea()` for the launch
splash + auth gate, a custom `TrafficLights` view, and a `WindowChromeFix`
`NSViewRepresentable` that re-asserted the buttons on a timer) was **deleted**. It caused
the native traffic lights to vanish, jump around (the `WindowChromeFix` retry schedule
re-flowed the titlebar every tick), and load ~1 s late. **Rule: use the real macOS window
chrome directly; never paint over the titlebar.**
- **Don't** `.ignoresSafeArea()` on any view that should sit *below* the titlebar. Overlays
  that cover the titlebar hide the traffic lights and force chrome hacks.
- **Don't** `.windowStyle(.hiddenTitleBar)` — it removes the reserved titlebar height, so
  the sidebar/content slides up under the buttons (tried 2026-07-14, broke layout).
- **Don't** `.windowResizability(.contentMinSize)` to "fix" maximize — it disables native
  full-screen (green button shows **"+" / zoom** instead of the diagonal arrows). Let a
  toolbar-less window fill via its own `.frame(maxWidth:.infinity, maxHeight:.infinity)`
  instead.
- **A centered card/panel that fills the window must be an `.overlay` on the flexible
  background, NOT a `ZStack` sibling of it (fixed & explained 2026-07-14).** A `ZStack`'s
  minimum size is the **max** of its children's minimums, so a tall card becomes the
  **window's minimum height**. If that min exceeds the screen's usable height
  (`NSScreen.visibleFrame`, e.g. ~875pt on a 14" MBP), macOS stamps
  `NSWindowCollectionBehaviorFullScreenNone` on the window and **keeps re-stamping it every
  layout** → the green button shows **"+" / zoom**, vertical resize is locked, and any
  external `collectionBehavior` fix is instantly reverted. This is exactly what bit the
  now-deleted sign-in gate (card min-height was ~1015pt > 875pt). **Rule:** size the window from a
  flexible `Color`/background and put the card in `.overlay(alignment: .center) { … }` — an
  overlay is sized to its base and never expands it, so the card can't set the window's floor.
  ```swift
  Color(NSColor.windowBackgroundColor)
      .overlay(alignment: .center) { card.frame(maxWidth: 420)… }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  ```
  Then SwiftUI enables native full-screen **itself** (`collectionBehavior` becomes
  `.primary | .fullScreenPrimary`) — **no** `NSWindow.collectionBehavior` poking, no timer.
  Do **not** try to fix this by mutating `collectionBehavior` from an `NSViewRepresentable`:
  SwiftUI re-computes and re-applies `.fullScreenNone` on the next layout as long as the
  content min-height is too tall. Fix the min-height, not the window. *(Full root-cause
  writeup + the measurements that pinned it: goLive 2026-07-14 changelog, "RESOLVED — the
  green + full-screen gotcha".)*
- **Structure (current):** `ContentView` renders the full `NavigationSplitView` app
  immediately — there is no root branch and no gate. The app is free and unauthenticated, so
  nothing stands between launch and the sidebar.
- If you ever add a **toolbar-less** window, note it gets macOS's **compact** titlebar. To
  match the app's taller unified titlebar, attach an **empty toolbar** — `.toolbar {
  ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) } }` — which
  reserves the height without showing controls.
- The launch **splash was removed entirely** (`LaunchScreenView` still exists but is unused
  — deleting the file would break the pbxproj reference; strip it from the target in Xcode
  to fully remove). The window appears already framed and loads content in place, like a
  normal native macOS app. The brief token-check flash is now the neutral `.checking`
  spinner ("Checking your access…") in the plain window, not a splash or a login form.

6.8 **Bundled avatars are full-bleed PNGs, not PDFs.** cairosvg's `svg2pdf` leaves a
transparent margin (content fills only ~90% of the page), so a circular clip shows a dark
ring. Render the SVGs to PNG (`svg2png`, 256 px) into `Assets.xcassets/Avatars/` and use
`AvatarView` (`.scaledToFill()`, no padding). Asset-catalog images need no pbxproj entries.

---

## Part 7 — Known gotchas / watch-outs

7.1 **Computed-bridge consoles.** Several VMs expose `installationOutput`/`output`
as a computed bridge to a `ConsoleOutput`. If an install screen shows no output,
check the `ConsoleOutputView(console:)` wiring, not the string.

7.2 **`PrivilegedHelper/` is NOT in the build** by design (separate helper target
you haven't created). Don't add its files to the app target — duplicate `main`.

7.3 **`installError` is a summary; the console/Logs keep the full failure text.**
Don't remove the console writes when you set the banner.

7.4 **`AsyncProcessRunner` array-args vs command-string** — prefer array-args for
anything with user input; only the legacy command-string sites route through
`singleQuote`.

7.5 **Empty `catch {}` in `Checkers/`** are intentional best-effort probes, but
they hide real failures — add logging if you touch one.

7.6 **Single-char search returns nothing** — PyPI shards are 2-char minimum;
require ≥2 chars before hitting the shard endpoint.

---

## Part 8 — Domain rules: package status & filesystem scanning

Behavioral rules for the two areas most prone to *plausible-but-wrong* logic —
package "outdated" status and disk scanning. Both silently over-report if you cut
corners.

8.1 **pip "outdated" must match pip's own resolver, not PyPI's absolute latest.**
Scan with `<python> -m pip list --outdated --format=json` (it honors
`Requires-Python`, so it won't offer a release the interpreter can't install).
**Never** derive "outdated" from the PyPI `info.version` field — that ignores
`Requires-Python` and produced false positives (e.g. numpy 2.5 offered on Python
3.11). Decode a tolerant `{name, version, latest_version}`.

8.2 **Classify an upgrade outcome three ways: success / held-back / failed.** After
attempting an upgrade, verify truth with a fresh check. If the package is still
outdated but pip reported "already satisfied" with no hard error, it's **held
back** (a newer version exists but isn't installable in this environment) — surface
it **amber with a reason**, distinct from a red **failed**. The `OutdatedUpdating`
protocol carries `heldBackPackages` / `heldBackReasons`; `OutdatedPackageRow` and
`UpdateResultsSummaryCard` render the amber state. Held-back is usually resolved by
the install-mode override (2.7), not a retry — say so, don't just offer "Retry".

8.3 **Filesystem scanners identify artifacts by MARKER, not by name.** A folder
merely *named* `node_modules` / `.gradle` / `venv` / `target` / `build` is cruft
only when a sibling project marker confirms it (`package.json`/lockfile; a Gradle
build script; `pyvenv.cfg`; `Cargo.toml`/`pom.xml`; `build.gradle`/`Makefile`).
Name-only matching flagged artifacts owned by installed apps and IDE extensions —
deleting those breaks the user's tools. See `CruftScanner.scout`.

8.4 **Home/deep scans skip hidden app-home dirs.** Exclude every top-level hidden
directory (`.vscode`, `.npm`, `.cursor`, `.antigravity-ide`, `.config`, …) from scan
roots — they're app caches/config, not user projects, and were the main source of
dangerous false positives.

8.5 **Apply protection/age filters uniformly across ALL scan phases.** A filter the
user enables ("Protect Active Projects") must cover *every* code path that yields
deletable items — including special-cased ones like the top-level Xcode DerivedData
pass, which previously ignored it. Separate globally-shared caches (Xcode
`ModuleCache`/`CompilationCache`, via `CruftScanner.isSharedXcodeCache`) from
per-project output: shared caches are never age-gated and must not be mislabeled as
project junk.

8.6 **One filesystem traversal, not two.** Don't pre-walk the tree just to compute a
determinate progress total — the pre-count descends into the very
`node_modules`/DerivedData subtrees the real scan prunes (via `skipDescendants`),
~doubling cost. Show a live "items analyzed" counter with an **indeterminate** bar
instead. Heavy FS work runs on a detached task and streams events to the
`@MainActor` VM; coalesce `@Published` progress writes to ~10 Hz so a burst of
events doesn't re-render the whole view.

---

## Part 9 — Adding a file to the Xcode project (registration ritual)

Hand-editing `project.pbxproj` is the **highest-risk surface** in this repo. Every
new `.swift` file needs **4 entries** (PBXBuildFile, PBXFileReference, a
`PBXGroup` children entry, and a `PBXSourcesBuildPhase` entry) with a synthetic
ID. Used ID prefixes so far: feature files `DD/EE/FF/AB/AC/AD/BA–BE`, structural
`CA–CN`. **Next free prefix: `CO`.** (`CM` and `CN` were the auth/entitlement and user-profile
files; both were deleted at v1.0, so those prefixes are retired rather than reused — reusing a
prefix makes `git log -S` on an ID ambiguous across eras.) Asset-catalog images need **no**
pbxproj entries.

The CatalystSnapshot feature files (`Models/SnapshotModels.swift`,
`Services/SnapshotService.swift`, `ViewModels/SnapshotViewModel.swift`,
`Views/SnapshotView.swift`) are registered under the `CK` prefix
(`CK…A/B/C/D` for the four files) across all 4 sections. The Git Graph feature files
(`Utilities/GitGraphLayout.swift`, `Services/GitGraphService.swift`,
`ViewModels/GitGraphViewModel.swift`, `Views/GitGraphView.swift`) are registered under
the `CL` prefix (`CL…A`=Utilities layout engine, `B`=Services, `C`=ViewModels,
`D`=Views; no separate Models file — value types live in the service/VM).

**Registration status (current):** `Helpers/InstallPreferences.swift` and
`Helpers/AppInfoCenter.swift` (the install-mode + modular-info system) are
registered in all 4 sections under a distinct
`CA7A1111000000000000AA01–AA04` block — mirror that block if you extend it; the
`CK` feature-file prefix is still free for the next new file. `Helpers/MatchedLabelStyle.swift`
and `Helpers/ShortcutContentView.swift` are in the target, as are the Cruft
Sweeper files (`Services/CruftScanner.swift`, `Models/CruftModels.swift`,
`Views/Components/CruftSweeperCards.swift`). The cache types (`CacheTTL`,
`RemoteCache`) live in `Utilities/NetworkConfig.swift` (already registered) to
avoid a new-file registration. Remaining cleanup: **remove the now-unused `MarkdownUI` SPM package**.

> Lesson: prefer adding new types to an already-registered file when the pbxproj
> isn't syncing new files, rather than fighting registration.

If Xcode shows a red (missing) file after a pull, re-add via the file inspector —
the file is on disk; only the project link is off.

---

## PR checklist (paste into review)

- [ ] Page scroll is `SmoothPageScroll`, not a bare `ScrollView`.
- [ ] No vertical `ScrollView` nested inside the page scroll (Rule 3.2).
- [ ] No `.shadow`/`Material`/`.blur`/`Divider()` on scrolling content (3.3).
- [ ] No `.scaleEffect`/spring hover in scrolling rows (3.4).
- [ ] No `.sorted`/`.filter`/`.enumerated` recomputed in `body` (3.5).
- [ ] New lists lazy; rows `Equatable` + plain values (3.6).
- [ ] Streaming state isolated in `ConsoleOutput` (3.7).
- [ ] Cards use `cardStyle()`; button `Label`s use `.labelStyle(.matched)` (4.1–4.2).
- [ ] Icons are `.fill` variants (4.3).
- [ ] Results/summary cards use the single-status-icon header — no duplicate checkmark (4.10); no false "success" celebration on a worklist screen (4.11).
- [ ] Config toggles are rows (not tiles), collapsed via `InstantDisclosureGroup` where long (4.12).
- [ ] Sticky commit/selection footer reuses the shared bar grammar (`SnapshotFooterBar`/Cruft), shown only when there's a selection; prominent button semibold + `minWidth: 140` (4.14). A directional flow keeps one accent end-to-end — capture/export green, import/restore blue (4.15).
- [ ] Config that can hold secrets is scrubbed before export; user-file overwrites are backed up first; nothing sources into the live shell (2.8).
- [ ] No secret/credential logged (sudo password, snapshot passphrase, token, `*_SECRET`); app output via `Logger` not raw `print`, debug prints `#if DEBUG`-gated (2.10).
- [ ] pip flag comes from `InstallPreferences.pipFlags(forPythonVersion:)`; venvs never flagged/gated (2.7); action-gating is contextual, not blanket (4.8).
- [ ] Every shell call is sanitized + routed through a tier; deletes gated (Part 2).
- [ ] Success decided on exit code, not string scraping (2.4).
- [ ] pip "outdated" via `pip list --outdated`; outcomes classified success/held-back/failed (8.1–8.2).
- [ ] FS scanners are marker-guarded, skip hidden app dirs, apply protection uniformly, single-pass (8.3–8.6).
- [ ] No markdown renderer; remote detail is structured + native (5.2). Code never revealed (5.3).
- [ ] New git readers are fsmonitor-safe + `</dev/null` + timeout-bounded; filters `singleQuote`d (2.9).
- [ ] Frozen-column/horizontal-scroll keeps the `LazyVStack` lazy; per-row `Canvas`; `.compositingGroup()` before `.clipShape` (3.10).
- [ ] The launch splash doesn't wait on detection (6.5). Small per-key state uses a `UserDefaults` blob (6.4).
- [ ] New files registered in `.pbxproj` (Part 9).

---

*Living document — when you hit a new macOS gotcha or make a cross-cutting
decision, add a rule here so the next session inherits it.*

---

## Part 12 — Telemetry, packaging & hard-won invariants

Rules removed at v1.0 covered accounts, entitlement, payments, invoicing and the Cloudflare
backend. Those systems no longer exist. Where a dead rule carried a lesson that outlives its
subject, the lesson was kept and rewritten to stand on its own — a rule that only makes sense
alongside deleted code is worse than no rule.

- **12.1 Telemetry facade.** `Telemetry/Telemetry.swift` is the ONLY place a provider may be wired in; everywhere else calls `Telemetry.log(_:)`, `.set(_:)`, `.setUser`, `.nonFatal`, `.breadcrumb`. Today every method is a no-op outside DEBUG — Catalyst sends nothing. Keep it that way unless there's a deliberate decision otherwise, and if there is, it changes in this one file. New events go in `AppEvent`, new segmentation in `AppUserProperty`, derivation in `TelemetryProfile`. **Never log anything user-identifying** — no file paths, package names, hostnames or email. `AppEvent` deliberately carries only a screen title.
- **12.1b Telemetry must never be able to break launch.** The previous provider (Firebase) called `FirebaseApp.configure()` from `start()`, which hard-crashes when its config plist is absent — so *deleting a config file* would have killed the app on open rather than quietly disabling analytics. Anything optional that runs at startup must fail as a no-op.
- **12.5 macOS signing.** Don't pin the app to a manual `Developer ID` identity or an ad-hoc `[sdk=macosx*] = "-"` override in build settings — keep automatic (Apple Development + team); the archive/export step re-signs Developer ID. Mixed team IDs + Hardened Runtime = launch SIGABRT.
- **12.6 pbxproj ritual.** New Swift files follow Part 9. Prefer adding a type to an already-registered file over creating a new one — a new file needs four separate pbxproj entries, and getting one wrong fails at link time with a confusing error. Removing a whole *target* is far worse: see 12.47.
- **12.9 Status banners.** See §4.1b — use `StatusBanner` / `.statusBannerChrome(tint:)`; don't hand-roll banner chrome.
- **12.10 Update check-on-open.** Keep `UpdaterController.checkOnLaunch()` wired from the root `.task` — Sparkle's scheduler alone does NOT reliably check on launch (it waits `SUScheduledCheckInterval` and defers the first check after install), so the badge won't appear on open without it. Always guard an explicit check with `updater.canCheckForUpdates` to avoid a `sessionInProgress` collision. Don't "simplify" back to scheduler-only. Testing needs an installed build **older** than the feed's top item — a dev/Xcode build shows nothing.
- **12.11 Sparkle auto-download must be set explicitly.** Info.plist has BOTH `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`, but setting `SUEnableAutomaticChecks` makes Sparkle **skip the opt-in prompt that is the only thing that applies `SUAutomaticallyUpdate` to the runtime `automaticallyDownloadsUpdates`** — so it stays `NO` and updates are found but never downloaded (badge stuck on "Update available"). `UpdaterController.init` therefore sets `automaticallyChecksForUpdates` and `automaticallyDownloadsUpdates` explicitly. Don't remove these.
- **12.11b The update badge has no release-notes affordance (2026-07-21).** `available` and `downloading` are plain status rows with nothing to click; only `readyToRelaunch` is a button. An earlier version put an `info.circle` on every state that opened a notes sheet, which made a passive status row look like it needed attention. What changed in a release belongs on the release page, not in a sidebar popover.
- **12.12 First detection runs once, from `startupChecks()`.** `AppViewModel` kicks off `fullRefresh()` exactly once per launch behind the `didRunInitialDetection` guard. This used to be triggered by entitlement resolving to `.entitled`; with no sign-in gate there is nothing to wait for. Keep the guard — it's what makes a second call harmless rather than a duplicate shell-probe burst.
- **12.17 Shell concurrency: never block the cooperative pool; no bounded throttle over blocking work (cost a full session).** `AsyncProcessRunner.readToEnd` drains pipes on a **libdispatch** queue (`DispatchQueue.global().async` + `withCheckedContinuation`), NEVER `Task.detached` — `Task.detached` runs on the Swift cooperative pool (width ≈ core count), and a blocking `readToEnd` there exhausts the pool so *nothing* async runs, not even timeout tasks. The old `AsyncConcurrencyLimiter(6)` was **deleted**: it existed only to cap those blocking reads (moot after the libdispatch move) and could **starve** a probe at `acquire()` forever — a parked call never spawns, so a process-timeout can't rescue it; the tell in logs is a `🐛 sh REQUEST` with no `PERMIT`. Don't reintroduce a permit-throttle over process spawns. `run(command:)` has an opt-in `timeoutSeconds` (SIGTERM→SIGKILL) for genuinely hung *children*; detection probes pass `10`.
- **12.18 Single-flight coalescing: no `await` between check and set.** In `PythonService.detectPythons`, nothing may suspend between `if let inFlightScan { … }` and `inFlightScan = task`. A suspension (we had one via the `async` `homebrewPrefix` interpolated into a log line) lets concurrent `@MainActor` callers all pass the check → a scan stampede.
- **12.18b Invalidating a cache must not free the in-flight slot.** The same stampede through the opposite door. `invalidateCache()` used to do `inFlightScan = nil` alongside the generation bump, reasoning that a running scan shouldn't be cancelled since callers await it. But nilling the slot makes it look *free* while the scan is still spawning subprocesses, so the next caller starts a SECOND concurrent scan. **Rule:** a generation bump alone retires a scan — the guard in the completion block already stops it publishing a stale result. Leave the task parked; the next caller waits it out (`🐛 py waiting out superseded scan`) and then starts fresh. Neither cancel nor drop. Corollary: the `defer` that clears the slot must compare the **slot's own stored generation**, not `scanGeneration` — after an invalidate those differ, so a `scanGeneration` comparison skips cleanup and strands every later caller on a finished task. *(The launch-time trigger that originally exposed this — entitlement landing mid-scan — is gone, but any caller of `invalidateCache()` during a live scan reproduces it. Do not simplify this away on the grounds that the original trigger no longer exists.)*
- **12.19 Debug logging is `#if DEBUG` only.** High-volume `🐛` tracing goes through `Logger.debugLog(_:)` (an `@autoclosure` wrapped in `#if DEBUG`) so it's free in Release. Don't add raw ungated `logger.log("🐛…")`. `cut_release.sh` **fails fast** if the Release config has `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.
- **12.20 Versioned legal consent.** The blocking Privacy/Terms sheet + acceptance state is `LegalConsentViewModel`/`ConfigStore`; the "current" version is `cached ?? bundled`, cached from the static `theappfoundry.co/legal/catalyst.json` (14-day TTL). Keep bundled `LegalConfig.*Version` in sync when you publish new docs. Present the sheet on its **own** view node (`.background(Color.clear.sheet(item:))`) — never a 2nd `.sheet` on a view that already has one. With no sign-in there is no consent checkbox, so the blocking sheet is the only path and must catch everyone.
- **12.21 zshrc edits go through managed blocks only.** Anything modifying the user's shell (Default-Python card, Aliases, Shortcuts) writes a sentinel-delimited block in `~/.zshrc_catalyst` via `ShellConfigManager.writeManagedBlock`/`removeManagedBlock`, found by marker, never by line number. **Never edit `~/.zshrc` directly** beyond the existing `source` line. Verify targets exist before writing, `zsh -n` after, roll back on parse failure.
- **12.22 Package-name comparison is PEP 503-canonical.** When diffing installed vs snapshot pip packages, canonicalize names (lowercase + collapse `[-_.]+`→`-`) on both sides. Raw compare treats `importlib_resources` and `importlib-resources` as different → a phantom "N to install" whose restore is a no-op.
- **12.23 Snapshot files get a stamped icon on export.** `SnapshotViewModel.export` calls `NSWorkspace.setIcon(_:forFile:)` with `CatalystSnapshotDoc.icns` — Launch Services won't reliably apply the `CFBundleTypeIconFile` type icon to a freshly-written file. Needs `import AppKit`.
- **12.26 Reusable UI helpers go in an already-registered file.** New small views belong in an existing file under `Views/`, NOT a new file outside the synchronized `Catalyst/` group — a new file elsewhere needs a manual pbxproj entry (§9).
- **12.27 Input validation is PARTIAL — venv name only.** The **New Environment** name field is gated on `VirtualEnvCreationViewModel.venvNameError`: trim → non-empty → ≤64 chars → `^\.?[A-Za-z0-9][A-Za-z0-9_-]*$` (optional single leading dot so `.venv` is valid; NO internal dots). Rejects `.venv.venv`, `..`, `../`, `foo/bar`, empty; shows an inline reason and disables **Create** until valid. Don't drop the leading-dot allowance and don't loosen to allow internal dots. Every OTHER field is ungated. *(The shared `Validators` utility was deleted at v1.0 — it only served account and billing fields. When you gate a second field, extract the rule then; don't copy it per-VM.)*
- **12.28 Sending Apple events to Terminal needs BOTH the entitlement and the usage string.** `TerminalService` runs commands via `NSAppleScript` "do script". Under Hardened Runtime (not sandboxed) this requires `com.apple.security.automation.apple-events` in `Catalyst.entitlements` AND `NSAppleEventsUsageDescription` in `Info.plist` — missing either → error **-1743**, commands silently don't run, and the app never appears under System Settings → Automation. `executeAppleScript` detects -1743 and opens the Automation pane (macOS won't re-prompt once denied). It's a signing-level change: a notarized build must be re-signed with the updated entitlements. Test with `tccutil reset AppleEvents com.shivanggulati.catalyst`.
- **12.31 SmartShortcuts refresh must bust BOTH cache layers.** A published add/remove only shows after `clearShortcutsCaches()` clears the 7-day `RemoteCache` copy of `index.json` (targeted `RemoteCache.clear(url)`, leaving the brew/pypi catalogs) AND the 14-day UserDefaults `shortcuts_cache` + timestamp. Merely resetting `hasLoadedOnce` does nothing. The app reads from `data.theappfoundry.co`, so a removed shortcut also needs that repo pushed; a stale list + 404 detail = "list shows it, detail blank."
- **12.32 Never `terminate()` an unlaunched process.** In `AsyncProcessRunner`, every `process.terminate()` (including the `withTaskCancellationHandler` `onCancel`) must be guarded by `if process.isRunning`. Cancellation can land before `process.run()` → `NSInvalidArgumentException: task not launched` → hard crash. Intermittent by nature, so easy to "fix by rebuild" and miss.
- **12.33 Pin `LC_ALL=C` on the sudo process.** `PrivilegesService.runSudo` sets `LC_ALL=C` so sudo's auth-failure strings stay the English ones `authFailed` matches. Without it, a localized Mac emits translated errors, `authFailed` stays false, and the stale-password re-prompt silently never fires — a privileged command just "fails".
- **12.36 `about.json` must carry a block for the shipping version.** Bundled in-app (synchronized `Catalyst/` group), keyed `versions[appVersion] ?? versions[latest]` — a missing entry for the shipping version falls back to hardcoded copy. Add the block whenever you bump `MARKETING_VERSION`.
- **12.37 One input control, one reveal affordance — and `contentShape` alone does not focus.** `CompactInputField` carries the trailing eye toggle on `isSecure` fields; never bolt a `SecureField` + `.roundedBorder` onto a screen instead. Two traps: (a) SwiftUI treats `SecureField` and `TextField` as **different view types**, so toggling reveal destroys and recreates the field and drops focus — hold it with a stable `.id()` keyed to *this* field (never a shared constant) and re-assert `isFocused` after the toggle; (b) `.contentShape(Rectangle())` makes a region hit-testable but **does not focus it**, so the field consumed trailing-blank-area clicks and discarded them. A `TextField` with no explicit width greedily fills its row, so the dead zone was the entire right-hand side. Fix: `.onTapGesture { isFocused = true }` on the field itself **and** on the padded container. Reveal state is `@State`-local and always starts masked.
- **12.38 Encrypted snapshot secrets: authenticated, optional, and decoupled.** Secrets ride in `CatalystSnapshot.secrets` sealed with PBKDF2-HMAC-SHA256 (210k rounds, per-snapshot salt) → AES-GCM; **only that blob is encrypted** so the rest of the snapshot stays inspectable. The shell scrubber is the source of truth — it already knows which values it stripped. Because AES-GCM is authenticated, "is this passphrase right?" is a **definitive** check, which is what makes a Validate button honest. Every failure mode (no passphrase / wrong passphrase / no placeholders) is `.skipped`, **never `.failed`** — one forgotten passphrase must not turn 200 unrelated restore rows red. The apply step lives in `SnapshotSecretsService`, deliberately **outside** the restore pipeline: it needs only ciphertext + passphrase + placeholder lines, so gating it behind the whole Migrate journey was an artificial dependency. It rewrites only lines still holding the exact placeholder → idempotent and retryable forever. The passphrase is never stored, logged or hinted; there is no recovery path, and the UI says so plainly.
- **12.39 `sorted(by:)` is not stable in Swift.** The restore pipeline orders actions by `SnapshotSectionKind.restoreOrder`; equal keys were left to chance. Ties must break on the original index — `shell.profile` overwrites `~/.zshrc` wholesale and MUST precede `shell.secrets`, which fills placeholders in that freshly-written file. Any time within-group order carries meaning, make the tie-break explicit.
- **12.40 Snapshot paths that embed a Homebrew prefix must be rebuilt, not replayed.** The `python-default` managed block hard-codes an absolute `…/opt/python@X.Y/libexec/bin`. Carried verbatim, an Intel snapshot (`/usr/local`) restored onto Apple silicon (`/opt/homebrew`) pins PATH at a directory that doesn't exist. Store the **bare version** and rebuild the line from the *target* Mac's prefix at restore, refusing to write if that interpreter isn't present. Rule: a snapshot may carry versions and names; it must not carry machine-specific absolute paths.
- **12.41 Prefer removing a failure mode over building machinery to recover from it.** Generalised from a deleted rule, because it keeps applying. Faced with "a user's identity could expire and lock them out of something permanent", the planned fix was a recovery-email feature: two columns, two endpoints, and a multi-key lookup — all existing purely to survive a state we could simply decline to create. Declining to create it was three lines. Ask whether the bad state has to be reachable at all before designing the escape hatch.
- **12.42 Anything decorative in a critical path must fail as a no-op.** Generalised from the Razorpay prefill, which broke checkout three separate times — a missing table, then a spaced phone number, then a bare `SERVER_ERROR` — each time because a *convenience* was allowed to throw inside the path that took people's money. Wrap it, default it, and make sure the primary operation completes when the nicety fails. Same reasoning now guards telemetry (12.1b) and the appcast fetch.
- **12.43 Poll intervals are a cost curve, not a preference.** A 60s entitlement poll worked out at ~480 requests/user/day and alone capped the product at roughly 200 daily active users on a free tier. Two things learned, both still relevant to any polling this app adds: the savings curve flattens fast (60s→15min captures ~93% of the reduction; 1h→6h differs by under 7 requests/user/day), and **anything past ~8h silently never fires**, because few people keep a Mac app open that long continuously — which deletes the backstop while leaving code that claims to provide one. Pick an interval that still fires.
- **12.44 A URL compiled into a shipped build is permanent — put a domain you own in front of it (2026-07-21).** `SUFeedURL` and `NetworkConfig.baseURL` live in builds that sit on machines for years and cannot be changed retroactively. Catalyst was stranded twice by vendor URLs: a Cloudflare Pages project and a Worker, both deleted, which silently emptied every catalog screen and would have killed auto-update outright — silently, because Sparkle reads an unreachable feed as "no update available". Both now point at custom domains (`data.` / `updates.theappfoundry.co`) CNAME'd to GitHub Pages, so the host can change forever without breaking an install. Never ship a `*.pages.dev`, `*.workers.dev` or `*.github.io` URL in a binary.
- **12.45 Endpoints are composed from ONE constant, and tests must not restate it.** Every path derives from `NetworkConfig.APIEndpoint.baseURL`. `NetworkConfigTests` used to pin each URL to a literal host that had already been replaced twice — a test that restates the value it checks verifies nothing and just has to be edited in lockstep. Assert composition, not the host.
- **12.46 The liveness probe must share an origin with the content.** `healthURL` points at the data host, not somewhere else. The question it answers is "can Catalyst reach its content?" — probing a different origin reports healthy while every catalog screen sits empty.
- **12.49 To ask \"is this a git repo?\", ask git — never `[ -d .git ]` (2026-07-21).** `cut_release.sh` rejected a perfectly good `updates/` clone because it tested for a `.git` **directory**. `.git` is a FILE holding a gitdir pointer whenever the repo is a worktree or submodule, and some filesystem mounts don't expose it at all. Use `git -C "$dir" rev-parse --show-toplevel` and compare the result to `$dir` — the comparison matters as much as the query, because a bare `rev-parse` run inside a non-repo walks UP the tree, finds the *parent* repo's `.git`, and reports success for a directory that was never cloned. Generalises: when a tool can answer a question about its own state, asking the filesystem to infer it is guessing.
- **12.50 Publish before you polish, and never let a cosmetic step abort a release (2026-07-21).** `cut_release.sh` ran `sync_release_notes.sh` (which only refreshes GitHub Release bodies) BEFORE pushing the appcast. That script lacked the executable bit — and git had recorded it as `100644`, so every clone would inherit the fault — so invoking it directly gave permission-denied, `set -e` killed the run, and the push never happened. The result was a published Release with no matching appcast entry: **invisible to every install, and completely silent**, because Sparkle reads a feed that lists no newer version as "no update available". It shipped that way twice before anyone noticed, and only a `log stream` showing a successful 200 with no download revealed it. Three fixes, all of them general: (a) do the step that *matters* first, so a later failure degrades rather than blocks; (b) invoke helper scripts as `bash path/to/script`, never relying on a permission bit that a clone, zip, or copy can drop; (c) if you do rely on the bit, set it in git with `git update-index --chmod=+x` — chmod alone only fixes your machine.
- **12.48 An unmatched glob stays literal — guard it, and quote what you iterate (2026-07-21).** `cut_release.sh` listed published versions with `for d in "$REL_DIR"/Versions/*/`. With the sibling metadata repo not cloned, the glob matched nothing and bash left it **literal**, `basename` reduced it to `*`, and the caller's unquoted `for v in $preds` expanded that against the working directory — so "no predecessors" became "deprecate every folder in the repo", and the dry run cheerfully listed `README.md` and `LICENSE` as versions to deprecate. Two fixes, both needed: `[ -d "$d" ] || continue` inside the loop, and never iterate an unquoted variable that could hold a glob character. Related: the script now checks the sibling `updates` repo exists *before* building, because finding out after notarization means a published Release with no appcast — invisible to users, since Sparkle reads an unreachable feed as "no update available".
- **12.47 Removing an Xcode *target* is not like removing files (2026-07-21).** Deleting the test target took three attempts and corrupted `project.pbxproj` twice. What bites: (a) the `pbxproj` Python library has no `remove_target`, and hand-removing objects makes its serializer throw **mid-write**, truncating the file — back it up first; (b) deleting lines by object id also removes the opening line of the nested `TargetAttributes` block and orphans its closing brace; (c) once the last `PBXContainerItemProxy`/`PBXTargetDependency` is gone, their `Begin`/`End` section markers sit empty with nothing between, which the parser rejects outright. Verify after: braces balance, the project parses, the app target still lists every source file, and the scheme XML is valid.
- **12.51 Catalyst ships a DMG, not a zip — and the switch is per-version, never retroactive (2026-07-22).** Shivang's call: distribute a `.dmg` (app beside an `/Applications` alias) so the install is a drag into Applications, not "run it from Downloads". This isn't cosmetic — a quarantined app launched from Downloads without being moved triggers Gatekeeper **app-translocation** (a random read-only path), which breaks Sparkle's in-place self-update. It reverses the earlier "single zip, no DMG" decision; DMG-only is still ONE artifact, so the double-notarization objection to zip+dmg doesn't apply. **The trap:** `make_appcast.py` regenerates the *entire cumulative* feed each release, so a blanket `.dmg` extension would rewrite every historical enclosure to a DMG that was never built — 404ing old installs' upgrades, silently (Sparkle reads an unreachable enclosure as "no update available"). The fix is per-version: `cut_release.sh` writes `ASSET=Catalyst-<v>.dmg` into that release's `meta.env`, and `make_appcast.py` reads `ASSET` per version, **defaulting to `Catalyst-<v>.zip` when absent** — so versions cut before this change keep their real `.zip` asset and its EdDSA signature. Never retro-fill an old `meta.env` with `.dmg`, and never hardcode the extension back into the download template.
- **12.52 Invalidate caches BEFORE fan-out, never inside one of the racers (2026-07-22).** The intermittent "hung launch": `fullRefresh()` spawned ~11 child tasks, and `runDetection(force:true)` called `pythonService.invalidateCache()` from *inside* the group — racing the other children. Whenever another VM's `detectPythons()` scheduled first (in practice: most launches), its scan started at gen 0, the invalidate then retired it at birth, and per 12.18b every caller correctly queued behind a doomed scan whose result was discarded — doubling launch work always, and hanging the dashboard for tens of seconds when launch subprocess contention slowed the wasted scan. At launch the cache is empty, so the invalidate's ONLY effect was the harmful generation bump. **Rule:** any "refresh = invalidate + parallel reload" flow must run the invalidation synchronously (same actor, no suspension) before the first child task spawns — `fullRefresh()` now does this and passes plain `runDetection()`. The 12.18/12.18b machinery is the backstop for mid-flight invalidations, not a license to create them at fan-out time. Related fix, same day: `scanForPythons` probes interpreters concurrently (bounded by candidate count, ≤2 sequential subprocesses each) instead of serially, so one slow interpreter no longer holds the scan for the sum of the 10s timeouts. That bounded per-scan fan-out is NOT the cross-scan stampede 12.18 prevents — don't "fix" it back to serial, and don't add a permit-throttle over it (12.17).
- **12.53 Child processes must never be able to prompt, and long runs must stream (2026-07-22).** The "package update taking forever, app doing nothing" report. Three compounding causes in the pip/brew update flows: (a) children inherited the app's stdin, so anything that decided to prompt — pip keyring/credentials, cask sudo, git credential helpers — waited forever on input a GUI app can never deliver, with zero output and no timeout; (b) upgrades ran through the buffered `run(command:)`, which returns output only at exit, so even a healthy multi-minute `brew upgrade`/wheel build looked identical to a hang; (c) per-package verification re-ran the FULL outdated sweep (`pip list --outdated` = network, 10-30s; full-tree `brew outdated` = seconds) after every package in a batch. **Rules:** every `AsyncProcessRunner` path sets `standardInput = FileHandle.nullDevice` — keep it (privileged flows don't use runner stdin: sudo goes via `SUDO_ASKPASS` or PrivilegesService's own piped Process); pass `--no-input` to pip installs and `NONINTERACTIVE=1` + `HOMEBREW_NO_AUTO_UPDATE=1` to brew upgrades; anything that can run >~10s goes through `runWithStreaming` into the terminal log; verify narrowly — `pip show <pkg>` + `VersionComparator` against the scan's `newVersion` (local, instant), `brew outdated --json <pkg>` (scoped) — and leave the one full rescan to the end-of-batch hook.