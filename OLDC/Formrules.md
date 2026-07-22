# Catalyst — Ground Rules ("Formrules")

**The single source of truth for how to build Catalyst further.** If you're adding
a screen, a service, a shell call, or a card, the answer to "how do we do that
here?" is in this file. Read it before writing code; update it when you learn a
new gotcha.

Catalyst is a **native macOS** SwiftUI app (MVVM + service layer) that gives
developers GUI control over their Mac dev environment. It is **not** iOS — some
rules here exist specifically because macOS (`NSScrollView`, hover, `AppKit`
bridging, `sudo`) behaves differently.

Companion docs: architecture overview → `CatalystUnderstanding.md`; session
status + backlog → `HANDOFF.md`; prioritized queue → `taskTracker.md`; the raw
audit → `toDo.md`; scroll-smoothness deep-dive → `toAvoid.md`; deferred/planned
backlog → `aheadFeatures.md`.

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
interpolate into a log/`print`: the sudo password, OTP codes, magic links, refresh/session
tokens, entitlement JWTs, API keys, or `*_SECRET`s. Log **non-sensitive facts only** — exit
codes, counts, sanitized names, error *categories* (not raw bodies that may embed a token).
The app already obeys this: `AuthService` logs nothing, `AsyncProcessRunner` logs no command
strings, `PrivilegesService` logs credential *events* ("Loaded admin credential"), never the
value. Route app output through `Logger` (not raw `print`/`NSLog`); a debug-only `print` must
be `#if DEBUG`-gated so it's stripped from release. **Backend (Worker/Vercel):** any
credential echo (e.g. a dev magic link / `dev_code`) is **dev-gated** — guard every such
`console.*` with `env.ENVIRONMENT !== "production"`, and never `console.log` a raw response
body that could carry a token. Log errors as messages, not secrets.

---

## Part 3 — Scroll smoothness (macOS-specific)

Full rationale in `toAvoid.md`. The short version:

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

3.2 **Never nest a vertical `ScrollView` inside the page scroll** (`toAvoid.md`
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
`StatusBanner(icon:tint:text:)` for a simple icon + message (e.g. sign-in errors in
`AuthGateView`); apply `.statusBannerChrome(tint:)` directly when the banner body needs
a spinner or dismiss button (e.g. the profile sheet's manage banner). Don't hand-roll a
tinted RoundedRectangle for a banner — the sign-in window and the profile sheet must match.

4.2 **Icon/title color match is handled app-wide — don't fight it.** macOS
otherwise renders some button SF Symbols in their own multicolor/accent palette,
giving a mismatched "random" icon color next to the title. The detail area sets
**`.symbolRenderingMode(.monochrome)`** once (in `ContentView`, on the detail
`NavigationStack`), so every screen's button icons follow their label color
automatically — including future buttons. This does NOT touch the sidebar (keeps
its colored icons) and preserves explicit `.foregroundColor`/gradient on icons.
Use `.symbolRenderingMode(.hierarchical/.palette/.multicolor)` **locally** on the
rare icon that genuinely needs color depth. `Helpers/MatchedLabelStyle.swift`
(`.labelStyle(.matched)`) remains for buttons that also need forced icon+title
layout, but is no longer required just for color matching.

**Exception — `.bordered` + `.tint(.primary)` does NOT reliably match.** On a
`.bordered` button, macOS still accent-tints the glyph (blue) while the title
stays neutral, and `.tint(.primary)` won't override it. For neutral secondary
actions (Copy, Reveal, row actions) use **`.buttonStyle(.secondaryAction)`**
(`SecondaryActionButtonStyle` in `MatchedLabelStyle.swift`) — a custom style on a
neutral surface that forces icon == title in ONE color. Button color reflects the
button's role: `.secondaryAction` (neutral) for secondary, `.borderedProminent`
for primary, `.bordered` + `.tint(.red)` + `.labelStyle(.matched)` for
destructive. Applied in `SSHKeyView` (Copy Public Key / Reveal / Fix Perms).

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
**semibold `Text`** with **`.frame(minWidth: 140)`**, `.buttonStyle(.borderedProminent)`,
`.controlSize(.large)`, secondary buttons semibold on `.secondaryAction`. **Show it only
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

5.1 **Backend is read-only static JSON** on Cloudflare Pages
(`catalyst-3aj.pages.dev`), generated/authored in the **`catalyst_pages`**
repo. The app degrades gracefully offline via `NetworkMonitor`; remote reads are
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
the `catalyst_pages` generator/migrator to match, and vice-versa. Decode
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

6.6 **Auth/entitlement — the app trusts NOTHING local; verify the server-signed JWT.** The
backend (`catalyst-api` Worker + D1 + KV) is the source of truth; the app only caches a
short-lived, **Ed25519-signed** entitlement JWT and verifies it with the embedded public
key (`AuthConfig.publicKeyPEMBody`, CryptoKit). Rules: never decide plan/trial locally;
compute everything from server time; store the refresh token in the **macOS login Keychain**
(never a source of truth — the user can wipe it). **Do NOT set `kSecUseDataProtectionKeychain`
on the unsigned build** — on macOS that keychain needs a code-signing entitlement
(`keychain-access-groups`/`application-identifier`) an ad-hoc build lacks, so `SecItemAdd`
fails `errSecMissingEntitlement` **silently** and the session never persists (symptom:
re-prompts for the code every launch). Always check the `SecItemAdd` `OSStatus`. Revisit once
signed/notarized (P9). Trial + entitlement are keyed
on verified email + `IOPlatformUUID`. **Sign-in is in-app email OTP** (`email/start` →
6-digit code → `email/verify`) — NOT device-code/magic-link (that confused the desktop UX,
removed from the app 2026-07). The **whole app is gated** by `AuthGateView` in `ContentView`
(overlay after the splash) until `AuthViewModel.state == .entitled` (mirror it to
`AppViewModel.isEntitled` so the toolbar can react); signing in auto-starts the trial.
Offline: fall back to the cached signed JWT until its `exp`, then reconnect. Any new backend
call follows `AuthService`'s shape (short JWT `exp`, refresh token, HMAC-verified webhooks
server-side, no secret in the app).

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
  sign-in gate (card min-height was ~1015pt > 875pt). **Rule:** size the window from a
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
- **Structure (current):** `ContentView` branches at the **root** on `appVM.isEntitled`
  (mirrors `authViewModel.state.isEntitled` via Combine). Entitled → the full
  `NavigationSplitView` app (sidebar + toolbar). Not entitled → a **plain sign-in window**
  (`AuthGateView`, no sidebar, no `NavigationSplitView`). No overlay, no z-order fight.
- A toolbar-less window (the sign-in branch) gets macOS's **compact** titlebar. To match
  the app's taller unified titlebar, attach an **empty toolbar** — `.toolbar { ToolbarItem(
  placement: .principal) { Color.clear.frame(width: 1, height: 1) } }` — which reserves the
  height without showing controls.
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
`CA–CN`. **Next free prefix: `CO`.** (`CM` = the auth/entitlement files:
`Services/AuthService.swift` B, `ViewModels/AuthViewModel.swift` C, `Views/AuthGateView.swift` D.
`CN` = `Views/UserProfileView.swift` D — the UserView + avatars.) Asset-catalog images
(`Assets.xcassets/Avatars/`, the 100 bottts-neutral vector PDFs) need **no** pbxproj entries.

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
avoid a new-file registration — the now-empty `Utilities/RemoteCache.swift` can be
deleted. Remaining cleanup: **remove the now-unused `MarkdownUI` SPM package**.

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
- [ ] No secret/credential logged (password, OTP, magic link, token, JWT, `*_SECRET`); app output via `Logger` not raw `print`, debug prints `#if DEBUG`-gated; backend credential echoes dev-gated (2.10).
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

## Part 12 — Telemetry, entitlement & packaging invariants (2026-07)

- **12.1 Firebase facade.** ONLY `Telemetry/Telemetry.swift` may `import FirebaseAnalytics`/`FirebaseCrashlytics`. Everywhere else calls `Telemetry.log(_:)`, `Telemetry.set(_:)`, `Telemetry.setUser`, `Telemetry.nonFatal`. New events go in `AppEvent`; new segmentation in `AppUserProperty`; derivation in `TelemetryProfile`. Never log PII — the analytics user id is the device UUID, never the email.
- **12.2 Entitlement is server-only.** The app decides plan/trial/expiry/`willCancel`/interval solely from the signed JWT + `/entitlement` response. Never infer entitlement locally. Reconciliation & webhooks are server-side.
- **12.3 One academic email → one account.** When touching student verification or sign-in, preserve the reuse invariant (UNIQUE `student_email` + the cross-checks in `studentVerifyConfirm`/`emailStart`/`emailVerify`).
- **12.4 Surfacing server errors.** Non-2xx responses carry `{"error":"code"}`; `AuthService.request` throws `AuthError.server(code:)`. Map user-facing codes (e.g. `email_reserved_student`, `rate_limited`) to friendly text in the VM — don't show a generic error for a known code.
- **12.5 macOS signing.** Don't pin the app to a manual `Developer ID` identity or an ad-hoc `[sdk=macosx*] = "-"` override in build settings — keep automatic (Apple Development + team); the archive/export step re-signs Developer ID. Mixed team IDs + Hardened Runtime = launch SIGABRT.
- **12.6 pbxproj ritual reminder.** New Swift files still follow Part 9; when possible add types to an already-registered file (we put `UpdaterController` in `CatalystApp.swift`, `PaywallView` in `UserProfileView.swift`). The `Telemetry/` files are new — they must be added to the target in Xcode.
- **12.7 D1 schema changes ship a migration.** `catalyst_worker/schema.sql` is only the fresh-install shape. To change a live table, add a numbered `catalyst_worker/migrations/NNNN_name.sql` (`ALTER TABLE …`) and apply it with `npx wrangler d1 execute catalyst-db --remote --file=…` **before/at** the deploy that reads the new shape (also `--local` for the dev DB). Deploying code that reads a not-yet-added column throws `D1_ERROR: no such column` → a 500 that shows up in-app as a generic error (e.g. OTP "invalid or expired" on a correct code). Update both `schema.sql` (for new DBs) and the migration (for the live DB). See CatalystUnderstanding §49.9.
- **12.8 One account = one active Mac (single-seat).** When touching auth/entitlement, preserve the device-binding guard: `users.active_device_id` is the seat; `/auth/email/verify` binds/blocks, `/auth/device/release` moves it (capped 2 per 90 days), `/auth/signout` revokes the token but keeps the seat, `/entitlement` evicts a released device (`401 device_released`). Don't add a new path that mints an app refresh token without going through the seat check. Full design: CatalystUnderstanding §49.9.
- **12.9 Status banners.** See §4.1b — sign-in and in-app status banners both use `StatusBanner` / `.statusBannerChrome(tint:)`; don't hand-roll banner chrome.
- **12.10 Update check-on-open.** Keep `UpdaterController.checkOnLaunch()` wired from the root `.task` — Sparkle's scheduler alone does NOT reliably check on launch (it waits `SUScheduledCheckInterval` and defers the first check after install), so the badge won't appear on open without it. Always guard an explicit check with `updater.canCheckForUpdates` to avoid the `sessionInProgress` collision. Don't "simplify" back to scheduler-only. Testing needs an installed build **older** than the feed's top item (a dev/Xcode build or an at-latest build shows nothing). See CatalystUnderstanding §49.7, RELEASING.md.
- **12.11 Sparkle auto-download must be set explicitly.** Info.plist has BOTH `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate`, but setting `SUEnableAutomaticChecks` makes Sparkle **skip the opt-in prompt that is the only thing that applies `SUAutomaticallyUpdate` to the runtime `automaticallyDownloadsUpdates`** — so it stays `NO` and updates are found but never downloaded (badge stuck on "Update available"). `UpdaterController.init` therefore sets `updater.automaticallyChecksForUpdates = true` + `automaticallyDownloadsUpdates = true` explicitly. Don't remove these. (2026-07-16; verified vs the SPUUpdater API reference.)
- **12.12 Detection is gated on entitlement.** `AppViewModel` runs the first `fullRefresh()` exactly once, from the `$state` sink when auth becomes `.entitled` (`didRunInitialDetection` guard) — NOT from `startupChecks()`. Never restore an unconditional launch-time `fullRefresh()`: it floods the shell runner behind the sign-in gate and, with the post-login re-detect, adds needless load. (2026-07-16.) **⚠️ Superseded (2026-07-17):** the `AsyncConcurrencyLimiter(6)` mentioned here was **REMOVED** — see 12.17. Cooperative-pool starvation is now prevented at the source (libdispatch pipe reads), not by throttling.
- **12.13 Live entitlement re-check.** `AuthViewModel.startEntitlementMonitor()` (~60s while entitled) + the `ContentView` `scenePhase == .active` trigger re-fetch entitlement, each bounded ≤8s (`AuthViewModel.withTimeout`), falling back to the cached JWT offline. On `AuthError.deviceReleased` (a distinct 401 from `/entitlement`) the app signs out locally with a specific reason. Don't make these unbounded or block the UI on them. (2026-07-16.)
- **12.14 Offline clock-rollback guard.** `AuthService` keeps a monotonic server-clock floor (max JWT `iat`, in the Keychain) and `cachedEntitlement()` rejects the cached token if local time is behind it beyond a 10-min skew. Don't weaken the cached-JWT offline path back to a pure `exp`-vs-local-clock check. (2026-07-16.)

- **12.15 Razorpay payments — the invariants that cost hours (2026-07-16).** *(Points (b), (c), (d) and (f) are HISTORICAL — subscriptions and Razorpay plans were removed in v1.13; there are no plan ids, and prices are no longer hardcoded in the app. (a) and (e) still apply to the one-time Payment Link flow.)* (a) **A Live-mode webhook to `POST /webhook/razorpay` is mandatory** — without it, paid subs stay `status='created'` forever (activation is webhook-driven, or a later `reconcileSubscription` live-GET). Its secret must **byte-match** `RAZORPAY_WEBHOOK_SECRET`; a mismatch is a silent `bad_signature` 400. Webhooks are mode-specific. (b) **Keys and plan_ids must be the same mode** (`rzp_test_`/`rzp_live_`); cross-mode → "plan not found" 502 → app "Couldn't start checkout." (c) **Plans are immutable** (no edit/delete) — create a new one and repoint the `RAZORPAY_PLAN_*` `[vars]` + deploy. (d) **Plan billing period must match its var slot** — `subscribeCreate` sends `total_count=120` for monthly / `10` for yearly; a yearly plan in the monthly slot → 120 years → 400. (e) **Payment links ≠ subscriptions** (only the student path handles `payment_link.paid`); **dashboard-created subs lack `notes.user_id`** so they can't be attributed — always test through the app's paywall. (f) **Prices are hardcoded in `UserProfileView.money`** (₹299/₹2999, $8/$59) — live plan amounts must match or the app needs a rebuild.
- **12.16 Entitlement honors the paid period.** `/entitlement` grants Pro for `status ∈ {active, cancelled, completed} && current_period_end > now` (not `active`-only) so a cancelled/mandate-revoked sub keeps Pro until the paid period ends (`willCancel=true`); `past_due` is intentionally excluded. Don't revert to `active`-only — it strips Pro from users who already paid for the period. (2026-07-16.)
- **12.17 Shell concurrency: never block the cooperative pool; no bounded throttle over blocking work (2026-07-17 — cost a full session).** `AsyncProcessRunner.readToEnd` drains pipes on a **libdispatch** queue (`DispatchQueue.global().async` + `withCheckedContinuation`), NEVER `Task.detached` — `Task.detached` runs on the Swift cooperative pool (width ≈ core count), and a blocking `readToEnd` there exhausts the pool so *nothing* async runs (not even timeout tasks). The old `AsyncConcurrencyLimiter(6)` was **deleted**: it only existed to cap those blocking reads (moot after the libdispatch move) and could **starve** a probe at `acquire()` forever (a parked call never spawns → a process-timeout can't rescue it; the tell in logs is a `🐛 sh REQUEST` with no `PERMIT`). Don't reintroduce a permit-throttle over process spawns. `run(command:)` has an opt-in `timeoutSeconds` (SIGTERM→SIGKILL) for genuinely hung *children* — detection probes pass `10`. Full triage: CatalystUnderstanding §49.12, goLive 2026-07-17.
- **12.18 Single-flight coalescing: no `await` between check and set.** In `PythonService.detectPythons`, nothing may suspend between `if let inFlightScan { … }` and `inFlightScan = task`. A suspension (we had one via the `async` `homebrewPrefix` interpolated in a log line) lets concurrent `@MainActor` callers all pass the check → a scan stampede (multiple `starting NEW scan` for one generation).
- **12.18b Invalidating a cache must not free the in-flight slot (2026-07-19).** Companion to 12.18, and the same stampede reached by the opposite door. `PythonService.invalidateCache()` used to do `inFlightScan = nil` alongside the generation bump, on the reasoning that the running scan shouldn't be cancelled (callers are awaiting it). But nilling the slot makes it look *free* while the scan is still spawning subprocesses, so the next caller starts a SECOND concurrent scan. At launch this fires reliably: entitlement lands ~1s in and invalidates mid-scan, so gen 0 and gen 1 overlap and every interpreter is probed twice. **Rule:** a generation bump alone retires a scan — the guard in the completion block already stops it publishing a stale result. Leave the task parked in the slot; the next caller must *wait it out* (`🐛 py waiting out superseded scan`) and then start fresh. Neither cancel nor drop. Corollary: the `defer` that clears the slot must compare the **slot's own stored generation**, not `scanGeneration` — after an invalidate those differ, so a `scanGeneration` comparison skips cleanup and strands every later caller on a task that already finished.
- **12.19 Debug logging is `#if DEBUG` only.** High-volume `🐛` tracing goes through `Logger.debugLog(_:)` (an `@autoclosure` wrapped in `#if DEBUG`) so it's free in Release. Don't add raw ungated `logger.log("🐛…")`. `cut_release.sh` **fails fast** if the Release config has `DEBUG` in `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (first check, before notes/build) — see RELEASING.md / `preflight_release.sh`.
- **12.20 Versioned legal consent.** The blocking Privacy/Terms sheet + acceptance state is `LegalConsentViewModel`/`ConfigStore`; the "current" version is `cached ?? bundled` where cached comes from the **static** `theappfoundry.co/legal/catalyst.json` (NOT under `/catalyst/*` → no Edge Middleware, 0 Edge-Config reads; 14-day TTL). Keep bundled `LegalConfig.*Version` in sync with the manifest when you publish new docs. Present the sheet on its **own** view node (`.background(Color.clear.sheet(item:))`) — never a 2nd `.sheet` on a view that already has one. `import Combine` is required for `@Published`. Full design: CatalystUnderstanding §49.10.
- **12.21 zshrc edits go through managed blocks only.** Anything that modifies the user's shell (Default-Python card, Aliases, Shortcuts) writes a sentinel-delimited block in `~/.zshrc_catalyst` via `ShellConfigManager.writeManagedBlock`/`removeManagedBlock` (found by marker, not line number). **Never edit `~/.zshrc` directly** beyond the existing `source` line. Verify targets exist before writing, `zsh -n` after, roll back on parse failure. Homebrew prefix is the only Intel/Silicon difference (`BrewPathManager`, runtime-resolved). CatalystUnderstanding §49.11.
- **12.22 Package-name comparison is PEP 503-canonical.** When diffing installed vs snapshot pip packages (`SnapshotService.pipPlan`) or similar, canonicalize names (`lowercase` + collapse `[-_.]+`→`-`) on both sides. Raw compare treats `importlib_resources` vs `importlib-resources` as different → phantom "N to install" whose restore is a no-op.
- **12.23 Snapshot files get a stamped icon on export.** `SnapshotViewModel.export` calls `NSWorkspace.setIcon(_:forFile:)` with `CatalystSnapshotDoc.icns` — Launch Services won't reliably apply the `CFBundleTypeIconFile` type icon to a freshly-written file. Needs `import AppKit`.
- **12.24 Surface entitlement IDs on the SAME `> now` guard — no parallel date check (2026-07-17b).** `subscription_id` is gated by a `subHonored` flag set **inside** the `status ∈ {active,cancelled,completed} && current_period_end > now` branch (so a **cancelled-but-still-Pro** sub shows its ID — don't revert to `subStatus === "active"`, that hid the ID from users who cancelled but paid through the period). `grant_id` comes from a query filtered `WHERE expires_at > now`. Never add a separate date comparison for display — reuse the branch that grants Pro, so an ID can't outlive its entitlement. App reads `AuthViewModel.subscriptionId`/`grantId`; both are **nil offline** (live-response-only). CatalystUnderstanding §49.1.
- **12.25 OTP email provider is pluggable in ONE file; flip it with `EMAIL_PROVIDER`; SES is per-region.** `send-otp.js` `getMailer()` chooses SES vs Gmail via the **`EMAIL_PROVIDER` Vercel env var** (`ses` | `gmail` | `auto`; `auto` = SES if configured, else Gmail) — flip in the dashboard + redeploy, **no app/Worker/website change**. Use **587 + STARTTLS** for SES (secure:false + requireTLS), not 465 (implicit TLS can stall on serverless egress → an opaque platform 502); always set `connectionTimeout`/`greetingTimeout`/`socketTimeout` so a hang fails fast (and is logged as `send-otp failed (provider): …`) instead of timing out the function. SES identity is verified in **`eu-north-1`**; the SMTP host, SMTP credentials, and `SES_FROM` must all be that region/domain (`no-reply@theappfoundry.co`). Deliverability needs DKIM **+ custom MAIL FROM (SPF) + DMARC** all PASS. **Never put real creds in `.env.example`** (it's tracked via `!.env.example`) — placeholders only; real values go in Vercel + gitignored `.env`. CatalystUnderstanding §36.
- **12.26 Reusable UI helpers go in an already-registered file.** New small views (e.g. `CopyButton` in `UserProfileView.swift`) belong in an existing file under `Views/` etc., NOT a new file outside the synchronized `Catalyst/` group — a new file elsewhere needs a manual pbxproj entry (§9). `CopyButton` uses `NSPasteboard` (`import AppKit`) and flashes a green checkmark for 2 s via a `Task { sleep; copied = false }` on the MainActor.

- **12.27 Input validation is PARTIAL — venv name only (2026-07-18).** The **New Environment** name field is gated on `VirtualEnvCreationViewModel.venvNameError` / `isVenvNameValid`: trim → non-empty → ≤64 chars → `^\.?[A-Za-z0-9][A-Za-z0-9_-]*$` (optional single leading dot so `.venv` is valid; alphanumeric start; NO internal dots/separators). Rejects `.venv.venv`, `..`, `../`, `foo/bar`, empty; shows an inline orange reason and disables **Create** until valid. Don't drop the leading-dot allowance (breaks the `.venv` default) and don't loosen to allow internal dots (re-opens `.venv.venv`). Every OTHER field is still ungated — the single `Validators` utility + full rollout is deferred (goLive §9, `aheadFeatures.md`). When you add fields, extract this rule; don't copy it per-VM.
- **12.28 Sending Apple events to Terminal needs BOTH the entitlement and the usage string (2026-07-18).** `TerminalService` runs commands via `NSAppleScript` "do script" to Terminal. Under Hardened Runtime (app is NOT sandboxed) this requires `com.apple.security.automation.apple-events` in `Catalyst.entitlements` AND `NSAppleEventsUsageDescription` in `Info.plist` — missing either → error **-1743** ("Not authorized"), commands silently don't run, and the app never appears under System Settings → Automation. `executeAppleScript` detects -1743 and opens the Automation pane (macOS won't re-prompt once denied). It's a signing-level change: the notarized/DMG build must be re-signed with the updated entitlements. Test with `tccutil reset AppleEvents com.shivanggulati.catalyst`.
- **12.29 `former_subscriber` counts PAID states only (2026-07-18).** In `/entitlement`, `formerSubscriber = !!sub && subStatus ∈ {active,cancelled,completed,past_due,halted}` — a bare `created`/`authenticated`/`pending` row (checkout started, never charged) is NOT a former subscriber. Reverting to `!!sub` makes an abandoned checkout falsely greet a brand-new account with "Welcome back — your subscription has ended." Use the reconciled `subStatus`, not raw `sub.status`.
- **12.30 One free trial per Mac — device-trialed gate (2026-07-18).** Trial is hardware-bound (`devices.trialed`); `/trial/start` returns `403 device_already_trialed`. `AuthService.startTrial` returns that as a Bool; `AuthViewModel` persists it per-Mac (`UserDefaults "trial.deviceAlreadyUsed"`) and picks the `.deviceTrialed` `LockKind` → the golden-ticket "One free trial per Mac" gate. **Precedence:** a real former subscriber (12.29) outranks device-trialed, which outranks plain trial-ended. Don't swallow the 403 again (it was `try?`-ignored before) — that's what made a never-trialed account read "Your free trial has ended."
- **12.31 SmartShortcuts refresh must bust BOTH cache layers (2026-07-18).** A published add/remove only shows after `SmartShortcutsViewModel.clearShortcutsCaches()` clears the 7-day `RemoteCache` copy of `index.json` (`RemoteCache.clear(url)` — targeted, leaves brew/pypi catalogs) AND the 14-day UserDefaults `shortcuts_cache` (+ its timestamp). `refresh()`/`forceReload()` both call it. Merely resetting `hasLoadedOnce` does nothing — `fetchJSON(ttl:)` still serves the stale disk copy, and the UserDefaults snapshot is loaded on launch with `hasLoadedOnce=true` (skips refetch). The app reads from deployed CF Pages (`catalyst-3aj.pages.dev`), so a removed shortcut also needs the Pages deploy; a stale list + 404 detail = "list shows it, detail blank."
- **12.32 Never `terminate()` an unlaunched process (2026-07-18).** In `AsyncProcessRunner`, every `process.terminate()` (including the `withTaskCancellationHandler` `onCancel`) must be guarded by `if process.isRunning`. Task cancellation can land before `process.run()` (e.g. a shortcuts search cancels an in-flight probe) → `NSInvalidArgumentException: task not launched` → hard crash. Intermittent by nature (race window), so easy to "fix by rebuild" and miss.
- **12.33 Pin `LC_ALL=C` on the sudo process (2026-07-18).** `PrivilegesService.runSudo` sets `LC_ALL=C` so sudo's auth-failure strings stay the English ones the `authFailed` detection matches. Without it, a localized Mac emits translated errors, `authFailed` stays false, and the stale-password re-prompt (after a macOS password change) silently never fires — a privileged command just "fails."
- **12.34 Internal grant IDs are branded `TAPC<hex>` (2026-07-17; prefix renamed to `TAFC` on 2026-07-20 — see 12.43).** `grantStudentYear` binds `` `TAPC${randomToken(16)}` `` as the grant `id` (a display/support handle only — nothing parses it). Distinct from Razorpay `sub_…`; the subscription id is unchanged across renewals (only `pay_…`/`inv_…` change per cycle).
- **12.35 The paywall Back control is stripped once checkout starts (2026-07-17).** `PaywallView` hides its top-left Back chevron when `authVM.checkoutStarted`, and the `pending` view offers only "Reopen checkout" (cached `checkoutURL`, never a 2nd `subscribeCreate`) until the poll times out. A protective layer against abandoning / double-starting an in-flight subscription. Keep the header row a fixed height so layout doesn't jump.
- **12.36 Shortcut detail: one field control, one content card, name-aware usage (2026-07-18).** The custom-name field uses the canonical `CompactInputField` (now with optional `onSubmit`; full-frame hit region so a click anywhere in the border focuses it — a bare `.plain` field only accepts hits on its glyphs). `ShortcutContentView` renders one consolidated card and rewrites the default function name → the chosen/installed name in usage/examples/sample-output (`applyingName`, word-boundary regex). `about.json` is bundled in-app (synchronized `Catalyst/` group), keyed `versions[appVersion] ?? versions[latest]` — a missing entry for the shipping version falls back to hardcoded copy, so add the version's block when you bump `MARKETING_VERSION`.
- **12.37 One input control, one reveal affordance — and `contentShape` alone does not focus (2026-07-18).** `CompactInputField` gains a trailing eye toggle on `isSecure` fields (`allowReveal`, default true), so every secure field in the app gets it — never bolt a `SecureField` + `.roundedBorder` onto a screen instead (that was the first cut of the snapshot passphrase UI and it broke the one-field-style rule, 4.5). Two traps: (a) SwiftUI treats `SecureField` and `TextField` as **different view types**, so toggling reveal destroys and recreates the field and drops focus — hold it with a stable `.id()` keyed to *this* field (never a shared constant: two sibling passphrase fields must not collide) and re-assert `isFocused` after the toggle; (b) 12.36's "full-frame hit region" claim was only half-true — `.contentShape(Rectangle())` makes a region **hit-testable but does not focus it**, so the field *consumed* trailing-blank-area clicks and discarded them, and the outer `.onTapGesture` never saw them. A `TextField` with no explicit `width` greedily fills its row, so the dead zone was the entire right-hand side — visible in the no-width call sites (SSH Key, Alias, snapshot passphrase) and hidden in the fixed-width ones (Network Diagnostics), where a `Spacer` catches the tap. Fix: `.onTapGesture { isFocused = true }` on the field itself **and** on the padded container. Reveal state is `@State`-local and always starts masked — never hoisted, never persisted.
- **12.38 Encrypted snapshot secrets: authenticated, optional, and decoupled (2026-07-18).** Secrets ride in `CatalystSnapshot.secrets` sealed with PBKDF2-HMAC-SHA256 (210k rounds, per-snapshot salt) → AES-GCM; **only that blob is encrypted** so the rest of the snapshot stays inspectable. The shell scrubber is the source of truth — it already knows which values it stripped, so nothing new has to go hunting for credentials. Because AES-GCM is authenticated, "is this passphrase right?" is a **definitive** check, not a heuristic: that's what makes a Validate button honest. Every failure mode (`no passphrase` / `wrong passphrase` / `no placeholders`) is `.skipped`, **never `.failed`** — one forgotten passphrase must not turn 200 unrelated restore rows red. The apply step lives in `SnapshotSecretsService`, deliberately **outside** the restore pipeline: it needs only ciphertext + passphrase + placeholder lines, so gating it behind the whole Migrate journey was an artificial dependency. It rewrites only lines still holding the exact placeholder → idempotent, retryable forever, and never clobbers a value the user already set. Passphrase is never stored, logged, or hinted; there is no recovery path and no fallback key, and the UI says so plainly.
- **12.39 `sorted(by:)` is not stable in Swift (2026-07-18).** The restore pipeline orders actions by `SnapshotSectionKind.restoreOrder`; equal keys were left to chance. Ties must break on the original index (`enumerated().sorted { … a == b ? l.offset < r.offset : a < b }`) — `shell.profile` overwrites `~/.zshrc` wholesale and MUST precede `shell.secrets`, which fills placeholders in that freshly-written file. Any time within-group order carries meaning, make the tie-break explicit.
- **12.40 Snapshot paths that embed a Homebrew prefix must be rebuilt, not replayed (2026-07-18).** The `python-default` managed block hard-codes an absolute `…/opt/python@X.Y/libexec/bin`. Carried verbatim, an Intel snapshot (`/usr/local`) restored onto Apple silicon (`/opt/homebrew`) pins PATH at a directory that doesn't exist. Store the **bare version** (`CatalystSnapshot.defaultPython`, major.minor) and rebuild the line from the *target* Mac's prefix at restore, refusing to write if that interpreter isn't actually present (same guard as `PythonDefaultManager.apply`). Rule: a snapshot may carry versions and names; it must not carry machine-specific absolute paths.
- **12.41 A lifetime licence may not be rooted in an expiring identity (2026-07-19).** Sign-in is an OTP to `users.email`, so an academic primary address would lock the owner out of a perpetual licence months after graduation — the entitlement outlives the mailbox. `emailStart` rejects a NEW academic primary (`academic_email_not_primary`); existing ones are grandfathered (the check only fires when no user row exists), so the rule against lockouts can't itself lock anyone out. Academic addresses remain fully supported as `student_email` — a credential that is verified, expires yearly and is re-verifiable, which is the role they suit. **This deliberately replaced a planned "recovery email" feature:** two columns, two endpoints and a multi-key sign-in lookup, all existing purely to survive a state we can decline to create. Prefer removing the failure mode over building machinery to recover from it. It also deleted `studentEligibleFor`'s `isAcademicEmail(primaryEmail) → true` shortcut, which granted the discount forever with no verification date — the one eligibility path with no deadline, and therefore impossible to render an honest countdown for.
- **12.42 Prices are server-driven and re-checked at the moment of purchase (2026-07-19).** `/entitlement` returns live prices from the same `licensePrice()` the checkout uses, so displayed and charged amounts cannot diverge, and a price change is a `wrangler deploy` rather than an app release. It rides an existing call — the app already hits `/entitlement` on launch, foreground and the 4h backstop — so this costs ZERO additional requests; a separate `/pricing` endpoint would have doubled request volume for nothing. Client-side constants survive only as an OFFLINE fallback. The paywall resolves prices on appear (`refreshPurchaseTerms`). A re-check on the buy tap was built and then **deliberately removed**: prices change on a `wrangler deploy` — months apart, not minutes — so it spent a round trip on every purchase to guard a window that narrow, and in the freak case it fires the user simply pays the price the server would have quoted anyway. Correctness here comes from the server computing the charge, not from the client re-verifying it.
- **12.43 A support handle is generated short, never displayed short (2026-07-19; corrected 2026-07-20).** Licence ids are `TAFCL…`/`TAFCS…` — a fixed product namespace (`TAFC` = The App Foundry · Catalyst), a type letter, then 8 chars from `refId()`'s alphabet, so they survive being read aloud or retyped from a screenshot. Middle-eliding a long id in the UI is the WRONG fix: it hides exactly the characters a payment dispute turns on, and the visible form stops matching what Copy yields. If an identifier doesn't fit, shorten it at the source. Type lives in the id so support can tell a bought licence from a comped grant (`TAFCG…`) without a DB lookup.
  - **Two corrections to the original wording.** (a) The prefix was `TAPC` until 2026-07-20 — a typo, renamed to `TAFC` for NEW ids only. Every `TAPCL…`/`TAPCS…` already issued **stays as it is**, because an id is immutable and users hold receipts bearing it; anything matching on a licence id must accept BOTH prefixes indefinitely. (b) This rule claimed the alphabet excludes `I/L/O/U` and `0/1`. It does not. The real alphabet is `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` — `I` and `O` are excluded, `L` and `U` are **present**. That matters: `L` is also a type letter, so a variable-width type code would be ambiguous (`TAFCG` + a tail starting `L` reads like `TAFCGL`). Type codes stay ONE character for exactly this reason.
- **12.44 Duration belongs in the DB, never in the id (2026-07-20).** A comped grant is `TAFCG…` whether it runs 15 days or forever; `grants.expires_at` is the sole source of truth for length. Encoding duration into the identifier was considered and rejected — an id is an immutable support handle while a comp can be extended, so a `…GL…` ("limited") id becomes a lie the moment someone extends it. Same reasoning forbids putting status, tier-price or currency in an id.
- **12.45 Invoice numbers are random in public, sequential in private (2026-07-20).** The visible number is `TAFC-INV<YYYY>-<6 random>` (product decision), uniqueness enforced by the PRIMARY KEY with retry — 8 collisions in a row means the RNG is degenerate, so it throws rather than risking a duplicate financial record. `invoices.seq` stores a monotonic per-year counter that is **never rendered**: with random public numbers there is no series to check for gaps, so `seq` is the only thing that can ever prove no invoice is missing. It must be captured from invoice #1 because it cannot be reconstructed later. Allocate it with `INSERT … VALUES (fy, 1) ON CONFLICT DO UPDATE SET seq = seq + 1 RETURNING seq` — `SELECT MAX(seq)` then INSERT is a read-modify-write and hands two concurrent Workers the same number.
- **12.46 A prefill convenience must never be able to block a sale (2026-07-20).** `licenseCreate` reads `billing_profiles` to pre-fill Razorpay's customer fields. That lookup is wrapped in try/catch, the phone is normalised through `razorpayContact()` (omitted entirely if unusable), and a failed link creation retries once with the optional fields stripped. Each of those three guards was added *after* the un-guarded version broke checkout in production: a missing table, then a spaced phone number, then a bare `SERVER_ERROR`. The rule generalises — anything decorative sitting in a payment path needs its own failure to be a no-op.
- **12.44 A long-lived view model must wipe per-ACCOUNT state on sign-out (2026-07-19).** `AuthViewModel` survives sign-out and is reused by whoever signs in next on that Mac. `signOut()` cleared five fields and left the rest, so a previous account's `studentVerifyError` greeted a freshly signed-in user as though it were theirs — and a stale `checkoutURL` could have handed them another account's Razorpay payment link. All of it now goes through `clearAccountState()`, called from both `signOut()` and `signOutAfterEviction()` (the eviction path matters MORE — the seat was taken by someone else, so the next user is likely a different person). Rule: if a `@Published` property describes the signed-in ACCOUNT rather than the app, it belongs in that function.
- **12.45 Poll intervals are a cost curve, not a preference (2026-07-19).** The entitlement monitor ran every 60s while the app was open — ~480 requests/user/day, which alone capped the product at roughly 200 daily active users on Cloudflare's free tier. `reconcileSubscription` compounded it by firing an outbound Razorpay call on EVERY entitlement request (~1,440/subscriber/day) to self-heal a webhook that rarely fails. Now 4h + a 1h KV throttle on the reconcile. Two things learned: the savings curve flattens fast (60s→15min captures ~93%; 1h→6h differs by <7 requests/user/day), and **anything past ~8h silently never fires at all**, because few people keep a Mac app open that long continuously — which deletes the backstop while leaving code that claims to provide it. Pick an interval that still fires; don't stretch one until it stops mattering.
