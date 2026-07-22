# ANTI_PATTERNS.md — Catalyst UI Smoothness Rules

**Single source of truth for keeping scrolling smooth (no jerk) while preserving the current look.**

Every rule below has the same shape: the pattern to avoid, *why* it janks on macOS, the **look-preserving fix** (the app should look identical after applying it), and the current offenders found in an audit of `Views/`.

The guiding principle: **never put a scrollable, redrawing, or blur/shadow surface inside the page scroll.** macOS scrolling is driven by `NSScrollView`. Anything that fights it for scroll events, or forces an offscreen render pass per frame, produces the "sticky then jump" feel.

---

## Rule 1 — Never nest a vertical `ScrollView` inside the page `ScrollView` (highest priority)

**Avoid:**
```swift
ScrollView {                       // page scroll
    VStack {
        SomeCard()
        ScrollView {               // ❌ inner vertical scroll
            Text(output)
        }
        .frame(maxHeight: 200)
    }
}
```

**Why it janks:** two vertical `NSScrollView`s stack. When the cursor is over the inner one it captures the scroll wheel; at the inner edge the momentum does **not** hand off cleanly to the page, so the page sticks and then jumps. This is the single biggest cause of the jerk on the Dashboard.

**Look-preserving fix — pick one, the pixels stay the same:**

- **Preferred (inline content like logs / file previews):** drop the inner `ScrollView`, cap the height, and let overflow flow into the page scroll:
  ```swift
  Text(output)
      .font(.caption.monospaced())
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(maxHeight: 200, alignment: .top)   // same visual box, no inner scroll
      .clipped()
      .codePanel()
  ```
  If the user must scroll a very long log independently, make that screen's body **non-scrolling** and give the log the only scroll, rather than nesting.

- **If the inner scroll is truly required** (e.g. a long search-results list that must scroll separately from a fixed header): make the **outer** container non-scrolling for that screen so there is exactly one vertical scroll on screen. Two scrolls visible at once is the thing to eliminate, not the inner scroll specifically.

- **Horizontal inner scroll is fine.** `ScrollView(.horizontal)` inside a vertical page scroll does **not** conflict (different axis). `StorageDNAView` and `SmartShortcutsView` already do this correctly — leave them.

**Current offenders (vertical-in-vertical):**
- `OutputConsoleView.swift:56` — the shared install/output console (used by Dashboard, FormulaeCaskInstall, etc.). Fixing this one fixes the most screens.
- `Helpers/CardStyleExtensionView.swift` `codePanel()` — wraps a `ScrollView` at every call site.
- `PIPPackagesInstallView.swift:66` — search results, `maxHeight: 400`.
- `FormulaeCaskInstallView.swift:103` and `:169` — formula/cask search results, `maxHeight: 400`.
- `AliasView.swift:182` — output, `maxHeight: 200`.
- `RequirementsView.swift:76` — file preview, `maxHeight: 150`; `:216` — output.
- `DashboardView.swift` — inherits it via `ConsoleOutputView` → `OutputConsoleView`.

> `LogsView.swift:137` uses a single full-screen `ScrollView` + `ScrollViewReader` for auto-scroll-to-bottom — that's the *correct* pattern (one scroll, owns the screen). Don't change it.

---

## Rule 2 — No `Spacer()` as a direct child of a `VStack` inside a `ScrollView`

**Avoid:**
```swift
ScrollView {
    VStack {
        Card1(); Card2()
        Spacer()      // ❌ undefined height inside unbounded scroll content
    }
}
```

**Why it janks:** scroll content has unbounded height, so a `Spacer` has no defined size. It does nothing useful and can trigger ambiguous/extra layout passes.

**Look-preserving fix:** delete the `Spacer()`. If you wanted trailing breathing room, use `.padding(.bottom, 24)` on the `VStack` — visually identical.

**Note:** `Spacer()` inside an **`HStack`** (to push a trailing label/button right) is correct and common in these files — leave those. Only the vertical-scroll-child case is the problem.

**Current offenders:** `DashboardView.swift:44`. (Audit each `Spacer()` hit: keep HStack ones, remove VStack-in-ScrollView ones.)

---

## Rule 3 — No shadows on scrolling content

**Avoid:** `.shadow(...)` on cards/rows that live inside the page scroll.

**Why it janks:** a drop shadow forces an **offscreen render pass every frame** while the layer moves. This was already the documented cause of dashboard jank (see the `R5` comment in `CardStyleExtensionView.swift`).

**Look-preserving fix:** the app already replaced card shadows with a hairline opaque border in `cardStyle()`:
```swift
.overlay(RoundedRectangle(cornerRadius: 12)
    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
```
Keep card edges defined with a border, not a shadow. **Use `cardStyle()` for every card** instead of re-rolling backgrounds, so this stays consistent.

**Audit hits to review:** `Components/DrCatalystCards.swift:159` (`.shadow(radius: 10)`) and `Components/StorageDNAView.swift` shadow. These are acceptable **only if** they're on a popover/overlay/hover element that is *not* scrolling. If they're on a card inside the page scroll, replace with the border pattern.

---

## Rule 4 — No translucent `Material` / `.blur` on scrolling content

**Avoid:** `.background(Material.thinMaterial)`, `.ultraThinMaterial`, `.blur(radius:)` on anything inside the page scroll.

**Why it janks:** translucent materials and blurs sample what's behind them and must re-composite every frame as the content moves — expensive on every scroll tick.

**Look-preserving fix:** use a solid `Color(NSColor.controlBackgroundColor)` (or `windowBackgroundColor`) fill, which reads almost identically against the app's background, with no per-frame compositing. Reserve materials/blur for **static, non-scrolling** chrome (launch screen, sheet backdrops, popovers).

**Audit hits to review:** `Components/CruftSweeperCards.swift:402` (`Material.thinMaterial`), `Components/DrCatalystCards.swift:157` (`Material.thickMaterial`). Fine if on a fixed header/overlay; replace if inside scrolling list content. (`LaunchScreen`/`gearlaunch`/`flameLaunch` blurs are fine — they never scroll. Note: `LaunchScreenView` is **unused** as of 2026-07-14, splash removed.)

---

## Rule 4b — Never cover the native window titlebar (2026-07-14)

**Don't** put a full-window SwiftUI view with `.ignoresSafeArea()` over the titlebar (old launch splash / auth gate did this). It hides the native traffic-light buttons and forces chrome hacks — a custom `TrafficLights` view + a `WindowChromeFix` `NSViewRepresentable` that re-asserts the buttons on a timer, which **re-flows the titlebar every tick and makes the buttons jump/lag**. Both were deleted.

**Also don't:** `.windowStyle(.hiddenTitleBar)` (removes reserved titlebar height → content slides under the buttons); `.windowResizability(.contentMinSize)` (disables native full-screen → green button shows "+"/zoom).

**Do:** use the real chrome directly. Keep views below the titlebar (no top `.ignoresSafeArea()`). For a toolbar-less window that must fill/zoom, use `.frame(maxWidth:.infinity, maxHeight:.infinity)` on its content and an **empty toolbar** (`ToolbarItem(.principal){ Color.clear }`) to get the taller unified titlebar. Full rationale in CODING_STANDARDS §6.7.

---

## Rule 5 — No continuously-repeating animations on scrolling content

**Avoid:** `.animation(... .repeatForever(...), value:)` on elements that sit inside the page scroll.

**Why it janks:** a forever-pulsing/rotating element invalidates and redraws every frame *while you're also scrolling*, competing for the same main-thread frame budget.

**Look-preserving fix:** keep looping animations only on **non-scrolling** views (launch screen, a fixed status badge). If a pulsing element must live in a scroll, gate it: pause the animation while scrolling, or use a one-shot/`.easeInOut` transition instead of `repeatForever`.

**Audit hits to review:** `Components/DrCatalystCards.swift:188` (`repeatForever` pulse). Confirm it's not inside the scrolled card list. Launch-screen loops are fine.

---

## Rule 6 — Don't drive implicit `.animation(value:)` off data that changes during scroll

**Avoid:** attaching `.animation(.spring/.easeInOut, value: someVMState)` to list rows when `someVMState` can change while scrolling (hover, progress, selection).

**Why it janks:** each change kicks off an animation transaction mid-scroll, layering animation work onto scroll work.

**Look-preserving fix:** scope animations tightly with `withAnimation { }` around the *specific* state mutation, or disable animation for scroll-affected properties with `.animation(nil, value:)` (`CruftSweeperCards.swift:747` already does this correctly). Hover-driven springs (`StorageDNAView`) are fine because they only fire on deliberate hover, not on every scroll frame — but keep them off large lists.

---

## Rule 7 — No expensive computation inside `body`

**Avoid:** `.sorted`, `.filter`, `.enumerated`, or other O(n) work computed inline in `body` (especially recomputed multiple times):
```swift
if !vm.items.filter({ ... }).isEmpty {     // ❌ filtered here
    ForEach(vm.items.filter({ ... })) { ... } // ❌ and again here
}
```

**Why it janks:** `body` can re-evaluate frequently; every evaluation redoes the work. It doesn't move the scroll directly but inflates each render, and stacked with a re-rendering god-VM it shows up as stutter.

**Look-preserving fix:** compute once. The codebase already does this well — mirror it:
- Sort in the model's `didSet` and expose a `private(set)` result (`DashboardViewModel.sortedInstalledPythons`, the `R3` pattern).
- For filtered lists, expose a single computed `var filtered...` on the VM, or a `let` at the top of `body`, and reuse it.

**Current offenders:** `AliasView.swift` recomputes the same `catalystAliases.filter {…}` / `otherAliases.filter {…}` 4× per render (lines ~212, 228, 247, 263). Hoist each into one computed property on the VM.

---

## Rule 8 — Keep big lists lazy and rows cheap (already mostly done — don't regress)

**Do:** use `LazyVStack` / `LazyVGrid` for any list driven by a collection, and make rows `Equatable` leaf views that take **plain values + closures**, not the whole `@ObservedObject` VM.

**Why:** lazy containers only build visible rows; `Equatable` rows let SwiftUI skip re-rendering rows whose inputs didn't change when an unrelated part of the screen updates.

**Status:** already applied broadly — `PythonInstallationRow` and `MaintenanceOperationRow` are `Equatable` (`R1-row`), and lists across the app use `LazyVStack`/`LazyVGrid`. **The rule here is "don't regress":** when adding a list, use `LazyVStack`, and don't pass the god VM into a row — pass the fields it needs.

---

## Rule 9 — Isolate streaming/high-frequency state so it doesn't re-render the whole screen

**Avoid:** a `@Published` property that updates many times per second (streamed command output, timers) read by the screen's top-level `body`.

**Why it janks:** the process runner flushes output ~every 0.1s; if the whole screen observes that string, every chunk re-renders the entire screen — including while you scroll.

**Look-preserving fix:** the `ConsoleOutput` pattern (`Helpers/ConsoleOutput.swift`, `R2`) — move the hot property into a tiny `ObservableObject` observed **only** by the leaf view, and coalesce appends (~120ms). Pass the stable object down; never read its `.text` in the parent. Reuse `ConsoleOutput` for any new streaming surface.

---

## Rule 10 — Don't use `.drawingGroup()` (`rasterizedCard()`) on live/animated/interactive cards

**Avoid:** `.drawingGroup()` (here: `rasterizedCard()` with `PerfFlags.rasterizeScrollCards = true`) on cards that contain gradients that update, live metrics, animated gauges, or interactive controls.

**Why it janks:** `.drawingGroup()` flattens the subtree into an **offscreen GPU texture**. That texture is **regenerated whenever any child changes** — so on a live-metrics grid or an animated gauge it re-rasterizes continuously, which reads as persistent scroll lag (and softens text / can break popover anchoring and focus rings). The flag was an unproven "subjective smoothness" experiment whose own note says *Instruments showed no hitches*.

**Look-preserving fix:** keep `PerfFlags.rasterizeScrollCards = false` (now the default). The normal layered renderer composites the gradient/stroke sublayers directly and scrolls fine. Only consider `drawingGroup()` on a **completely static, non-interactive** subtree, and A/B it with Instruments before shipping.

**Current state:** flag flipped to `false`. The five call sites (`LiveMetricsGrid`, `SSDHealthCards`, `NetworkDiagnosticsView`, `LoginItemsView`, `PathEditorView`) now render normally.

---

## PR checklist (paste into review)

- [ ] No vertical `ScrollView` nested inside another vertical `ScrollView` (Rule 1).
- [ ] No `Spacer()` directly in a `VStack` that's inside a `ScrollView` (Rule 2).
- [ ] No `.shadow` on cards/rows in the page scroll — use `cardStyle()`'s border (Rule 3).
- [ ] No `Material`/`.blur` on scrolling content (Rule 4).
- [ ] No `repeatForever` animation inside scrolling content (Rule 5).
- [ ] No `.sorted`/`.filter`/`.enumerated` recomputed in `body` (Rule 7).
- [ ] New lists use `LazyVStack`/`LazyVGrid`; rows are `Equatable` and take plain values (Rule 8).
- [ ] Streaming/timer state isolated in its own `ObservableObject` (Rule 9).

---

## Quick reference: what's already correct (leave it alone)

- `cardStyle()` border-instead-of-shadow (`R5`).
- `ConsoleOutput` isolated + coalesced streaming (`R2`).
- `Equatable` leaf rows taking plain values (`R1-row`).
- Model-side sorting via `didSet` (`R3`).
- `LazyVStack`/`LazyVGrid` for collections app-wide.
- `LogsView` single-scroll + `ScrollViewReader`.
- Horizontal inner scrolls in `StorageDNAView` / `SmartShortcutsView`.
- `.animation(nil, value:)` to suppress unwanted animation (`CruftSweeperCards:747`).

---

## Scroll performance — gradients as a fill on text/SF Symbols (2026-07)

`ShortcutCard` used a `LinearGradient` as `.foregroundStyle(...)` on an SF Symbol AND on text (the category badge), plus two gradient shape fills — 4 gradients per card. In a `LazyVGrid` this made scrolling stutter badly: **gradient-filled text/symbols force per-frame offscreen rasterization**. Fix was a single solid accent `Color`. Rule: on rows/cards that live inside a lazy scroll container, don't fill **text or SF Symbols** with a gradient/material — use a solid color. Gradients on large static shapes are fine.

---

## Rule 12 — Don't use `ViewThatFits` to make a sheet "scroll only when needed" (2026-07-20)

**Avoid:**
```swift
ViewThatFits(in: .vertical) {          // ❌ re-decides on every height change
    profileContent
    ScrollView { profileContent }
}
```

**Use instead** (already the convention at 12+ sites in this repo):
```swift
GeometryReader { geo in
    ScrollView(.vertical) {
        profileContent.frame(minHeight: geo.size.height - inset * 2)
    }
    .scrollBounceBehavior(.basedOnSize)   // no bounce when it fits
}
```

**Why it breaks:** `ViewThatFits` re-runs its fit decision whenever the content's height
changes. On any screen whose height is driven by `@Published` state — banners appearing and
disappearing, a details card growing a row — that becomes a feedback loop under an `.animation`
on the same container: mutate state → resize → re-decide branch → re-render → mutate. It
surfaced as `AttributeGraph: cycle detected through attribute NNNN` when redeeming a gift code.

`.scrollBounceBehavior(.basedOnSize)` gives the same "feels static when it fits" result with no
branch to re-evaluate, and `minHeight: geo.size.height` preserves bottom-pinned `Spacer`
layouts. Two candidates also means the markup exists twice unless you extract it — one more way
for the branches to drift.

**Related, and the reason this rule exists at all:** wrapping a card in a `ScrollView` when its
*content* already scrolls produces two scrollbars — that's Rule 1, hit here by putting
`PaywallView` (which owns a ScrollView) inside the gate card's. Only one view in a hierarchy
owns vertical scrolling.

---

## Rule 13 — Leave room for the focus ring inside any `ScrollView` (2026-07-20)

**Symptom:** the blue focus ring on a `TextField` looks shaved on one edge.

**Cause:** AppKit draws the focus ring *outside* the control's frame, and `ScrollView` clips to
its bounds. A field flush against the scroll edge loses part of its ring.

**Fix:** inset the scroll *content* by `AuthGateView.focusRingInset` (4pt) and subtract
`inset * 2` from any `minHeight` so the padding doesn't turn a fitting layout into a scrolling
one. Where the container already has horizontal padding, move 4pt of it inside the clip
boundary (`.padding(.horizontal, 22 - inset)`) rather than adding to it — the visual margin
stays identical.
