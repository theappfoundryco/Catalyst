# Catalyst — Task Tracker

Prioritized work queue derived from the Pass 1–8 code sweep (`toDo.md`). Each item links back to its source pass/section. Work top-down: **P0 → P4**.

Legend: `[P#-N]` = source reference. Check items off as completed.

---

## ✅ Session 2026-07-20 (v1.18: COMPED ACCESS + NON-GST INVOICING)

**NOT YET RELEASED.** Worker deployed, migration `0002` applied to remote D1, and the flows
below verified end-to-end with real purchases (standard + student) at ₹1 test pricing; prices
restored to ₹5,999 / ₹2,499. No notarized DMG cut yet — v1.17 is still what users have.

### Comped access (redeemable gift codes)
- [x] `gift_codes` / `gift_redemptions` tables. Grant length lives ONLY in `days`, a strict
  multiple of 15 enforced in THREE places — schema `CHECK`, Worker constant, mint script.
- [x] `POST /gift/redeem`. Capacity check + increment are ONE atomic
  `UPDATE … RETURNING`; per-user dedupe rides the `(code, user_id)` primary key; the counter is
  released on collision so a multi-use code can't silently shrink.
- [x] "No such code" and "code exhausted" return the SAME error — distinguishing them is a free
  enumeration oracle over a short alphabet.
- [x] Redeeming early EXTENDS from the current expiry, never from today.
- [x] Interleaved-flow guard: redeeming is refused while a payment link is payable
  (`checkout_in_progress`, code stays unspent); if that link is already `paid`, it self-heals
  the licence instead.
- [x] `Scripts/mint_gift_codes.py` — emits SQL for review rather than executing it. Bare
  invocation prints a tutorial.
- [x] App: `Pro · Complimentary · N days left` badge, non-dismissible expiry banner inside a
  15-day window (one grant unit), `comp_expires_at` on `/entitlement` (null = perpetual comp,
  a REAL state).
- [x] Fixed: `isPerpetual` was `subscriptionId == nil`, so a capped comp rendered
  "Validity / Lifetime" over access that lapses.
- [x] Fixed: `renewalValue` read `entitlementEnd` (= `max(trial, grant)`), printing a trial's
  date as the comp's expiry.
- [x] Fixed: `redeemGiftCode` called `recheckEntitlement()`, which early-returns unless
  `state.isEntitled` — so from a LOCKED paywall it granted server-side and left the user
  blocked. Now `resolveEntitlement`.

### Invoicing (non-GST)
- [x] `invoices` / `billing_profiles` / `invoice_counters`. Buyer + learner columns are
  SNAPSHOTS at issue time — an issued invoice must not change when a profile is edited later.
- [x] `TAFC-INV<YYYY>-<6 random>` public number + never-rendered monotonic `seq` (Formrules
  12.45).
- [x] Issuance folded INTO `grantPerpetual`, so all three mint paths invoice. Previously only
  the webhook did — a customer whose webhook was missed got a licence via the self-heal and no
  document, which is exactly what that path exists for.
- [x] `grantPerpetual` re-reads the grant by `ref` instead of assuming its generated id won —
  under a retry the `INSERT OR IGNORE` is a no-op and a different row holds the licence.
- [x] Comps are never invoiced. Nothing was paid.
- [x] Buyer details collected BEFORE checkout; server-side gate mirrors `BillingValidators`.
- [x] On-device PDF via `ImageRenderer` + `CGDataConsumer` — real vector, selectable text.
  Pinned `.light` so Dark Mode can't export white-on-white; fetch happens off-main because
  `ImageRenderer` is `@MainActor`.
- [x] Both logos are vector PDF assets. The supplied `catalyst_logo.svg` was a base64 PNG in an
  SVG envelope (0 paths) and rotated 90° CCW once extracted — the SVG carried a
  `matrix(0, .2559, -.2559, 0, …)` rotation that raw extraction dropped. Re-traced to real
  paths, IoU 0.9969 vs original.

### Fixes carried
- [x] §1 double-charge window — `licenseCreate` reuses a payable `stupl:` link.
- [x] `TAPC` → `TAFC` for NEW ids only (Formrules 12.43).
- [x] URLSession bounded (15s/30s). `.ephemeral` defaults to 60s + **7 days**, so redeem /
  save-billing / fetch-invoice could hang a control for a minute-plus.
- [x] Invoice PDF write moved off the main actor.
- [x] `issueInvoice` race: the loser resolves to the winner's row instead of throwing.
- [x] Razorpay prefill disabled behind `PREFILL_RAZORPAY_CUSTOMER` — rejected with a bare
  `SERVER_ERROR`, was costing two API calls and an error log per sale.
- [x] All three sheets scroll via `.scrollBounceBehavior(.basedOnSize)`; gate card fixed at
  540×660 and centred (toAvoid Rules 12–13).
- [x] Restore-purchases copy no longer says "No active subscription found" — wrong twice over.
- [x] Spam-folder hint added inside `OTPCodeField`, so every code screen gets it.
- [x] v1.17 Python-scan race fix **confirmed at runtime**.

---

## ✅ Session 2026-07-19 (v1.13: PERPETUAL LICENSING — subscriptions removed)

> **Version note.** This work shipped as **v1.13** and was re-cut through 1.14 / 1.15 / 1.16 —
> same feature set, rebuilt, identical release notes. v1.17 carried the Python-scan race fix and
> doubled as a check on the Sparkle update path after a stale v1.10 install failed to
> self-update. That check passed: a 1.16 install picked up 1.17 in about a second.
> **v1.17 is what users have. v1.18 is built but unreleased** (see the session above). New work resumes at **v1.19**.

**Shipped 2026-07-19.** Worker deployed, app builds, verified end-to-end with real purchases at production prices (standard + student). No longer unbuilt.

- [x] **Catalyst is now sold ONCE.** Perpetual licence, lifetime updates, no renewal, nothing to
  cancel. A purchase writes a `grants` row with a far-future sentinel expiry (`PERPETUAL_EXPIRY`),
  so every existing `expires_at > now` entitlement query works unchanged — no migration.
  ₹5,999 standard / ₹2,499 student (58%, computed not hardcoded).
- [x] **Subscriptions DELETED, not just unrouted.** `subscribeCreate`, `subscribeCancel`,
  `reconcileSubscription`, `userIdForSub`, `planInterval`, the entitlement read path, the webhook
  `subscription.*` branch, the dead `isEntitled` query, and all four `RAZORPAY_PLAN_*` vars.
  `/subscribe/{create,cancel}` → **410** with a pointer; `/subscribe/student/create` forwards.
  Verified no live row granted Pro before removing. Worker 1,013 lines, zero `FROM subscriptions`.
- [x] **Server-driven pricing** — `PRICE_<TIER>_<CURRENCY>` in `wrangler.toml` is both the charged
  amount and what `/entitlement` reports, piggy-backed on an existing call (**zero** extra
  requests). `licensePrice()` is strict: a non-numeric value is "unconfigured", which is the direct
  fix for the old `plan_REPLACE_ME` bug where a truthy placeholder sailed past `if (!planId)`.
  No re-check on the buy tap — built, then removed: prices move on a deploy, not mid-session,
  so it cost a round trip per purchase to guard a negligible window. Formrules 12.42.
- [x] **Academic emails can't be a primary account email** (Formrules 12.41) — superseded a planned
  recovery-email feature. Also deleted the `isAcademicEmail(primaryEmail)` eligibility shortcut.
- [x] **Licence ids short by construction** — `TAPCL…`/`TAPCS…` via `refId`, ambiguity-free
  alphabet. Reverted an earlier mistake of middle-eliding a 32-char id in the UI. Formrules 12.43.
- [x] **`clearAccountState()`** — sign-out leaked student-verify, checkout (incl. a live
  `checkoutURL`) and banner state into the next account. Formrules 12.44.
- [x] **Poll 60s → 4h + Razorpay reconcile cached 1h** — the 60s poll alone capped the product at
  ~200 DAU on Cloudflare's free tier. Formrules 12.45.
- [x] **`Helpers/Validators.swift`** (the `goLive.md §9` extraction) + **`Helpers/OTPCodeField.swift`**
  (six boxes over ONE hidden field, so paste/backspace/undo survive).
- [x] **Paywall correctness** — refreshes terms on appear (`refreshPurchaseTerms`, not
  `recheckEntitlement`, which early-returns on the locked screen); server error codes mapped to
  specific messages instead of "please try again"; student hero replaces the standard price rather
  than sitting beside it.
- [x] **Website + legal** — `pricing.astro`, `refunds.astro` (v2.0), `terms.astro` §9/§10 +
  definitions, `privacy.astro`, `consts.ts`. **§9 now carries a service-continuity clause**
  (offline-validating build if the service is sunset) — that is a real promise, read it.
- [x] `about.json` stamped `2026-07-19`; `notes.html` regenerated FROM `about.json` so they can't drift.

**Files added:** `Helpers/SnapshotCrypto.swift`, `Helpers/Validators.swift`,
`Helpers/OTPCodeField.swift`, `Services/SnapshotSecretsService.swift`,
`Views/Components/SnapshotSecretsCards.swift` — all registered in `project.pbxproj` (those groups
are explicitly listed, NOT file-system synchronized; a new file there is invisible otherwise).

---

## ✅ Session 2026-07-18b (v1.13: secrets encryption, logs, restore perf, import bar)

*(Built and shipped as part of v1.13 — see the 2026-07-19 session above.)*

- [x] **Encrypted API secrets in the snapshot** (aheadFeatures queued #1). New
  `Helpers/SnapshotCrypto.swift`: PBKDF2-HMAC-SHA256 (210k rounds, random 16-byte salt per
  snapshot) → AES-GCM. `ShellSecretScrubber` now also returns the ORIGINAL values it redacted;
  those go straight to `seal` when the user supplies a passphrase and are dropped otherwise, so
  they can never be encoded in the clear. New optional `CatalystSnapshot.secrets`
  (`EncryptedSecrets`) + schema bump to **2** (tolerant decode both directions). Restore adds a
  `shell.secrets` action that refills the scrubber's placeholders in `~/.zshrc`. **Every failure
  mode is `.skipped`, never `.failed`** — no passphrase, wrong passphrase, or no placeholders
  left; the rest of the restore is completely unaffected. Passphrase is never persisted, logged,
  or hinted, and is cleared from the VM right after use. UI: opt-in card + `SecureField` on the
  capture sheet (asked at the moment Capture is clicked), passphrase card on the restore plan
  **with an explicit Validate button**, plus a standalone unlock path — all extracted to
  `Views/Components/SnapshotSecretsCards.swift` (`SnapshotSecretsSealCard` /
  `SnapshotSecretsUnlockCard`), binding-only and stateless, reusing `CompactInputField`
  (the app's single input control, `isSecure: true`) rather than a bespoke `SecureField` +
  `.roundedBorder`. Registered in `project.pbxproj` alongside `Helpers/SnapshotCrypto.swift`.
- [x] **Secrets: validate-before-restore + standalone unlock.** Three follow-ups after review:
  (a) the capture passphrase moved from a landing card into a **sheet on the Capture click** —
  the card was trivially scrolled past, so people captured without knowing the option existed;
  (b) a **Validate** button on the Migrate card checks the passphrase *without* restoring.
  Because AES-GCM is authenticated this is a definitive yes/no, not a heuristic — it runs off-main
  (PBKDF2 ~0.2s) and a stale in-flight result can't overwrite a newer edit;
  (c) the secrets step was pulled OUT of the restore pipeline into
  `Services/SnapshotSecretsService.swift` — it needs only ciphertext + passphrase + placeholder
  lines, so gating it behind the whole Migrate journey was an artificial dependency.
  `SnapshotRestoreService` now delegates to it, and the same executor backs a standalone
  **"Unlock from Snapshot…"** flow (pick file → validate → apply; no import, diff, or restore) and
  an **Apply Secrets** button on the finished status screen. Because the step only rewrites lines
  still holding the exact placeholder, it's idempotent and retryable forever; a failed attempt
  leaves the placeholders intact by design. A `SnapshotSecretsPendingCard` appears on the landing
  whenever `~/.zshrc` still has placeholders, so the app surfaces the unfinished work instead of
  relying on the user to remember. **Constraint made explicit in the copy:** the ciphertext lives
  in the snapshot file, so recovery needs that file — the skip path now says to keep it.
- [x] **Snapshot & Migrate logs reach LogsView** (queued #2). New `SnapshotLogForwarder` in the
  VM mirrors streamed restore output into `Logger` on `.terminal`, buffered to **whole lines** so
  the ~0.1s partial chunks don't shred one console line across many timestamped entries.
  Capture / export / import / restore-done lines moved to `.terminal` too (they were `.debug`,
  which is why the Terminal Output tab looked empty for migrations).
- [x] **Restore UI hang** (queued #3). Three causes, all fixed:
  (a) `actionableCount` / `satisfiedCount` / `blockedCount` / `runTotal` / `runDone` were computed
  properties each running an **allocating** `filter` over every action, read on every body
  evaluation — now cached, recomputed in one non-allocating pass in `actions.didSet`;
  (b) `onUpdate` did a linear `firstIndex(where:)` per update — now a `[UUID: Int]` map with a
  self-healing verify-and-rebuild fallback (a re-plan yields new ids at the same count);
  (c) pip's per-package sub-status pushed a republish per package — in-flight `.running` message
  updates are now throttled to 200ms. Terminal states always publish immediately, so the progress
  bar stays honest. No-op mutations are also skipped.
- [x] **Import bar overlap fixed; bar KEPT** (queued #4 — full-screen view declined by user).
  The bar was `.overlay(alignment: .top)` on the whole screen, which anchors it under the title
  bar and floats it *over* whatever is behind — hence it covering the first Migrate card. It's now
  a **layout sibling** in a `VStack`, so it occupies its own row and pushes content down instead.
  Import stays non-blocking; the full-window working view remains reserved for capture. The label
  now advances "Reading snapshot…" → "Diffing this Mac…" as the phases progress.
- [x] **Discard button height** (queued #5). `SecondaryActionButtonStyle` is a custom style with
  fixed padding and **ignores `controlSize`**, so `.controlSize(.large)` did nothing and Discard
  rendered shorter than Export. The three Snapshot footer secondaries (Discard, Cancel, Back to
  Preview) now use `.bordered` — an AppKit style that honours `.large`, so it matches
  `.borderedProminent` by construction rather than a hand-tuned frame height.
- [x] **Default Python IS now snapshotted** (queued #6). It was only ever captured incidentally,
  as raw text inside the `python-default` managed block — which hard-codes the SOURCE Mac's
  Homebrew prefix. Restoring an Intel snapshot (`/usr/local`) onto Apple silicon (`/opt/homebrew`)
  would have pinned PATH at a non-existent directory. Added explicit
  `CatalystSnapshot.defaultPython` (bare major.minor, never a path); `executeShell` now **rebuilds**
  that block from this Mac's prefix and refuses to write it if the interpreter isn't actually
  present (same guard as `PythonDefaultManager.apply`). A user-set default outside Catalyst is
  deliberately still not captured — we don't own that line.
- [x] **Restore ordering made deterministic.** `sorted(by:)` is **not stable** in Swift, so the
  within-kind order was never guaranteed. Now ties break on the original index — required, because
  `shell.profile` overwrites `~/.zshrc` and must run before `shell.secrets` fills its placeholders.
- [x] **Eye reveal on secure fields + a real focus fix.** Added to `CompactInputField` (the
  app's single input control) so every `isSecure` field gets it, not just the passphrase ones —
  the first cut hand-rolled a `SecureField` in the snapshot cards, which broke the one-field-style
  rule. Toggling reveal swaps `SecureField`↔`TextField` (different view types → focus loss),
  held with a per-field stable `.id()`. Separately found a **pre-existing global bug**:
  `.contentShape(Rectangle())` made the field's blank trailing area hit-testable but nothing
  focused it, so those clicks were consumed and discarded and no caret appeared. Only visible in
  no-width call sites (SSH Key, Alias, snapshot passphrase) where the `TextField` fills the row;
  fixed-width ones (Network Diagnostics) were masked by a `Spacer`. Fixed on both the field and
  its container. Formrules 12.37.
- [x] **Docs.** `about.json` v1.13 rewritten (15 highlights, leads with encrypted secrets;
  `release_date` still `""` — stamp at ship). `aheadFeatures.md` restructured into Part 1
  (shipped-in-v1.13 record) + Part 2 (real backlog), 323 → 257 lines, with the auto-venv-for-PEP-668
  item rescued from a parenthetical. `CatalystUnderstanding.md` §47 corrected — it claimed
  "secrets are never exported", which is no longer true. Formrules 12.37–12.40 added.
- [x] `Helpers/SnapshotCrypto.swift` registered in `project.pbxproj` (Helpers group is explicitly
  listed, not file-system synchronized — a new file there is invisible to the build otherwise).

**Deferred:** toolbar redesign (queued #7) and everything else outstanding now sits under
**v1.18** in `aheadFeatures.md` — that file was flattened on 2026-07-19 so there is one
destination for deferred work instead of three version buckets.

---

## ✅ Session 2026-07-19 (late): launch race + pricing hardening

- [x] **Python scan stampede via `invalidateCache()`.** The single-flight guard was defeated by
  cache invalidation: `invalidateCache()` nilled `inFlightScan` while the scan was still running,
  so the next caller saw a free slot and started a second concurrent scan. Reproduced from a launch
  trace — entitlement arrives ~1s in, gen 0 was mid-probe, and both generations then re-probed every
  interpreter (`python3.11` twice while gen 0 was still on `3.13`/`3.14`). Fix: bump the generation
  only, leave the task parked, and make the next caller **wait it out** before starting fresh
  (`🐛 py waiting out superseded scan`). Also corrected the `defer` cleanup, which compared
  `scanGeneration` instead of the slot's stored generation and so skipped cleanup after any
  invalidate — latent under the old code, stranding under the new. Formrules **12.18b**.
- [x] **`/entitlement` back-compat for v1.13.** `price_standard_inr` / `price_student_inr` restored
  alongside the currency-agnostic `*_minor` fields, populated **only when the quote is INR** so an
  old client can never be shown a USD amount under a rupee sign. Without them a v1.13 client falls
  back to its hardcoded constants — invisible while the price matches, silently wrong the moment a
  KV price change lands. Removable once nobody runs a build older than **v1.13** (the release that
  introduced `*_minor`); marked as such in the source.
- [x] **USD probed against live Razorpay, then deliberately left off.** USD Payment Links create
  fine at $69 ($1 is rejected by a minimum-amount floor, which is what the first probe actually hit).
  But PayPal — the account's only international rail — does **not** appear on Payment Links, and the
  Cards option that does appear has unverified international authorisation. `wrangler.toml`'s USD
  vars are commented back out with the reasoning inline. See `aheadFeatures.md` §3.
- [x] **Docs flattened.** `aheadFeatures.md` dropped its "shipped in v1.13" half (that record lives
  here and in `about.json`) and consolidated the old v1.14/v1.15 buckets into a single **v1.18**
  list (v1.17 carried only the race fix and the Sparkle verification).

- [x] **Stale worker comments corrected.** The P4 block claimed "pre-existing subscription rows
  still grant Pro… and one such row is live" — false on both counts, and exactly the kind of note
  that gets trusted mid-incident. Also `isEntitled` ("via an active subscription OR…") and the
  webhook doc-comment ("flip the subscription row"). Code was already correct; only the comments
  described a world that no longer exists.

**Verified by hand:** app launches and renders cleanly, no interleaved scans in the trace, and a
real ₹1 checkout completed end-to-end on a live account. Worker typechecks clean; zero
`FROM subscriptions`; price resolution has exactly two call sites and both use `licensePrice()`.

**Since verified:** the Swift changes built and shipped in **v1.17**, and the Sparkle update path
was confirmed working (1.16 → 1.17 in about a second on a real install).

**Sparkle false alarm, recorded so it isn't re-investigated.** A v1.10 install showing "Update
available" that never downloaded was NOT a server or appcast fault — assets, `length`, signature,
`SUPublicEDKey` and `SUFeedURL` all verified correct and unchanged since v1.0. A freshly built,
notarized, properly installed v1.10 updated instantly. Most likely a code-signing identity mismatch
(Sparkle refuses to replace an app signed by a different identity, so a local Xcode build silently
declines a Developer ID update) or App Translocation. **Consequence:** a dev-built install is not a
valid test of the update path — rehearse upgrades from the notarized DMG only.

**Verify in Xcode:** capture with a passphrase → confirm `snapshot.json` shows only ciphertext →
restore on another Mac with the right passphrase (values return), a wrong one (row reads
"skipped", everything else succeeds), and none at all. Import a large snapshot and watch for the
import bar sitting ABOVE the first card, not over it. Run a big restore and confirm the stutter
is gone and Logs → Terminal Output fills. Compare Discard vs Export heights. Toggle a
Catalyst-set default Python, capture, restore on the other architecture.

---

## ✅ Session 2026-07-18 (v1.13: snapshot restore hardening, Python-view refresh)

- [x] **Python uninstall refreshes all Python views.** `PythonManager.uninstall` posts
  `.catalystPythonInventoryChanged`; Virtual Environments, PIP Packages, and Outdated PIP each
  observe it (token stored + removed in `deinit`). Dashboard already self-refreshes after its
  own uninstall, so its observer is **intentionally omitted** to avoid a concurrent
  `runDetection`. (aheadFeatures → CleanUps)
- [x] **Snapshot restore — PEP 668 via an Install Space row.** New picker card at the top of
  Migrate (shown when the plan has pip actions) binds the global `InstallPreferences.mode`.
  `executePip` respects it: User space / System-wide install with the matching flag; **Protected +
  externally-managed (3.12+) → `.skipped`** with a "pick a space to restore these" message, instead
  of the raw `externally-managed-environment` red-fail (the 3.14 case in the field report).
- [x] **Snapshot restore — per-package continue-on-error.** Tries the batch `pip install -r`
  first (fast, full resolution); on failure (e.g. `tomlkit` vs `gradio` → ResolutionImpossible)
  degrades to per-package installs so one bad pin can't sink the other 130. Reports `.partial`.
  Cancellation is now honoured mid-pip (per-package `shouldContinue`).
- [x] **Typed restore status + determinate progress.** New `RestoreStatus.partial` +
  `RestoreSummary.partial`/`isClean`; the Status screen shows a real "N of M" step bar (no fake
  time ETA) and a distinct amber "partial" row/summary instead of a blanket red "failed".
- [x] **Migrate "Install All" prerequisites (one-click fresh-Mac setup).** A **Set Up
  Prerequisites** card detects missing CLT / Homebrew / needed Python (`SnapshotUtil` +
  `BrewPathManager` + `LocalEnvironment`) and installs them in dependency order via an injected
  `PrerequisiteInstaller` — wired in `AppViewModel` to the Dashboard's `installHomebrew` /
  `installCommandLineTools` + a fresh `PythonManager`. Afterwards: `pythonService.invalidateCache()`
  → `fullRefresh()` → re-plan, so blocked rows unblock and the card disappears (auto-reload). CLT
  hands off to Apple's dialog (can't be awaited). Per-row blocked copy now points at "Install All."
- [x] **Diff-phase hang fixed.** The PLAN probes (`pip list`, `brew list`, `brew tap`) had **no
  timeout**, so one wedged probe hung "diffing this Mac." Added timeouts (pip 30s, brew 25s, tap
  20s) → a wedged probe degrades to empty instead of hanging.
- [x] **About: tagline now surfaced.** `VersionInfo.tagline` was decoded but never rendered —
  blended under "What's New" (accented, sets the release theme); the Released row hides when the
  date is blank.
- [x] **`about.json` → 1.13** notes (Install All, Install Space, per-package, progress, Python
  refresh, hang fix); `latest` bumped (release_date stamped at ship).
- [x] **UI polish (field-tested):** (a) About "What's New in X — <tagline> ✨" now one heading
  line (tagline accented, sparkle) instead of a link-looking row; Released row hidden when date
  blank. (b) Install All: 2s filesystem-settle after Python installs before the rescan/re-plan, so
  freshly-linked interpreters are actually picked up (was showing "missing" after install). (c)
  Install Space is now live — externally-managed pip rows show a "Protected — will skip" note and
  **the toggle is replaced by a "will skip" label** on Protected, flipping instantly as the picker
  changes. (d) Snapshot **import** now shows a slim non-blocking top loading bar (eases to 100%
  over 10s, dismissed on completion) instead of the full-window working view.
- [ ] **Deferred to next pass:** fold prerequisite installs into the Restore pipeline itself
  (auto-bootstrap mid-run), the **pending-vs-blocked** row reframe + collapse dependents + unblock
  banner + corrected header counts (`aheadFeatures.md`). `source ~/.zshrc` application parked by
  request. *(Built and shipped in v1.13, 2026-07-19.)*

---

## ✅ Session 2026-07-17 → 07-18 (auth gates, automation, shortcuts, hardening)

- [x] **Golden-ticket "one free trial per Mac" gate.** Surfaced `403 device_already_trialed`
  (was `try?`-swallowed); persisted per-Mac; new `.deviceTrialed` `LockKind` with friendly copy.
  Former-subscriber gate outranks it. (Formrules 12.30)
- [x] **`former_subscriber` = paid states only.** Abandoned `created` checkout no longer
  triggers a false "Welcome back." Worker `/entitlement`. (Formrules 12.29; needs `wrangler deploy`)
- [x] **Paywall Back stripped once checkout starts** + "Reopen checkout" cached-URL path. (12.35)
- [x] **Grant IDs branded `TAPC<hex>`.** (12.34, worker)
- [x] **Terminal automation fixed (-1743).** Added `com.apple.security.automation.apple-events`
  entitlement + `NSAppleEventsUsageDescription`; -1743 opens the Automation pane. (12.28, re-sign)
- [x] **`runSudo` locale pin `LC_ALL=C`** — stale-password re-prompt works on localized Macs. (12.33)
- [x] **`AsyncProcessRunner` onCancel crash fixed** — guard `terminate()` with `isRunning`. (12.32)
- [x] **SmartShortcuts force-refresh busts caches** — `RemoteCache.clear(url)` + UserDefaults
  snapshot; removed shortcuts no longer linger. (12.31)
- [x] **Shortcuts data:** removed 11 duplicates of native features, added 7 new; `about.json`
  bundled + 1.12 notes; detail view redesigned (hero + one content card, name-aware usage,
  `CompactInputField`, install log removed, copy button by the text). (12.36)
- [x] **Text-field click target** — full bordered area focuses (`CompactInputField` hit region). (12.36)
- [x] **Avatar assets:** deleted 100 orphan `.pdf` "unassigned child" warnings (Assets use PNG).
- [x] **Shortcut card icon** 32→22 pt in the 50 pt circle (was oversized).
- [x] **venv name validation** — `VirtualEnvCreationSheet`/VM gate + inline message. (12.27)
- [ ] **Deferred:** subscription invoices (`aheadFeatures.md`); app-wide `Validators` rollout
  (only venv done, `aheadFeatures.md` + goLive §9); refreshing-state banner; Swift-6 `timeoutTask`
  capture warning; account-per-Mac cap (intentional non-limit).

---

## ✅ Session 2026-07-02 (see `HANDOFF.md` for detail)

- [x] **App-wide scroll jank fixed** — `SmoothPageScroll` (List/`NSScrollView`-backed)
  swapped into all ~21 screens + Dashboard; animated hover + per-`body` filters
  removed. New standard in `Formrules.md` Part 3.
- [x] **Button icon color mismatch** — reusable `MatchedLabelStyle` (`.labelStyle(.matched)`)
  applied to Scan/Copy/Run/Select buttons. (Sweep remaining `Label` buttons.)
- [x] **Markdown → native structured content** — `markdown_content` replaced by
  `ShortcutContent` + `ShortcutContentView`; MarkdownUI dropped; shell code no
  longer revealed. Cloudflare `migrate_shortcuts.py` ran (25 files).
- [x] **`generate_packages.py` reviewed** — matches app hot-shard contract; minor
  non-breaking flags only (not patched, awaiting go).
- [ ] **Deferred:** nested-scroll offenders (`toAvoid.md` Rule 1); pbxproj-register
  the 2 new files + remove MarkdownUI SPM; review migration-flagged shortcut files.
  (Update: the 2 files are registered; MarkdownUI appears already removed — only a
  descriptive comment remains in `ShortcutContentView.swift`, no package reference.)

---

## ✅ Session 2026-07-04 (see `CatalystUnderstanding.md` §27 + §20, `Formrules.md` for detail)

- [x] **Install-mode / break-system-packages consent system.** Global, persisted
  `InstallPreferences.mode` (Protected / User space / System-wide) overriding PEP 668
  on Python ≥3.12. Every pip site builds its flag via
  `InstallPreferences.pipFlags(forPythonVersion:)` (thread-safe; returns `""` for <3.12
  or Protected). Consent gates: confirmation dialog on enabling an override, red
  sidebar integrity indicator, contextual (not blanket) action-gating, venvs never
  flagged/gated. Modular `InfoDot` + shared `AppInfoSheet` (`AppInfoCenter`) carry the
  explainer copy. New files `Helpers/InstallPreferences.swift` + `AppInfoCenter.swift`
  registered (`CA7A1111…AA01–AA04`). New rules `Formrules.md` 2.7 + 4.8–4.13.
- [x] **Cruft Sweeper P0–P4 overhaul (safety + trust + UI + perf).**
  - *Safety:* marker-guarded detection (a `node_modules`/`.gradle`/`venv` needs a
    sibling project marker); Deep scan skips hidden app-home dirs (`.vscode`/`.npm`/…);
    protection window now also covers Xcode DerivedData; shared Xcode caches split
    from per-project output.
  - *UI (absolute consistency):* results screen leads with a reclaim-hero + per-type
    breakdown + per-row size bars + Safe/Rebuild safety chips; Targets grid → rows
    matching Safety & Performance, collapsed behind `InstantDisclosureGroup`; venv
    "ant" icon fixed; de-duplicated Heavyweights; no false "Scan Complete ✓"
    celebration.
  - *Perf:* removed the double filesystem walk (dropped the prescan pass) →
    indeterminate progress + live count. Dead `heavyweights`/`largeFileThreshold`
    pruned. New `Formrules.md` Part 8 (scanning + package-status semantics).
- [x] **Requirements install button gated strictly for ≥3.12** (contextual: disabled
  only when `requiresBreakSystemPackages && mode == .protected`, inline reason).
- [x] **Bundle identifier → `com.shivanggulati.catalyst`.** Renamed across all 4
  pbxproj targets, the PrivilegedHelper XPC/code-sign identity (plist file renamed +
  `SMAuthorizedClients`/`SecRequirement`), storage paths, dispatch labels, and docs
  (26 sites / 17 files). Builds + signs clean. ⚠️ old `com.sg.catalyst/` Application
  Support data is now orphaned — see the elevated storage-layout item under P3.
- [x] **Docs consolidated.** `understanding.md` merged into `CatalystUnderstanding.md`
  as the canonical, website-grade reference (full per-feature + safety/consent detail).

---

## P0 — Ship-blockers (security & data loss)

Fix before any release. Each is either an injection, a secret-handling flaw, or silent data loss.

- [x] **Command injection in pip update.** ✅ Fixed — `updatePipPackage` now guards on `sanitizePackageName` and `shellEscape`s the Python path before interpolation. `[P3-5]`
- [x] **Command injection in brew update.** ✅ Fixed — `updatePackage` now guards on `sanitizePackageName` and `shellEscape`s brew prefix/path. `[P3-6]`
- [x] **Homebrew install writes password to disk.** ✅ Fixed — askpass script no longer contains the secret; password is passed in-memory via the new `runWithStreaming(environment:)` overload (`CATALYST_BREW_SUDO_PW`). `[P1-1, P7-14]`
- [x] **DiskHygieneDoctor silently deletes DerivedData and lies.** ✅ Fixed — `removeItem` now in `do/catch`, returns the real success/failure and logs on error. (Confirmation-gating left as a UI follow-up.) `[P4-7]`
- [x] **Cruft Sweeper `deleteSelected` is fire-and-forget.** ✅ Fixed — added `.value` so deletion completes before the UI refresh. `[P6-12]`
- [x] **PrivilegesService leftover allow-rule.** ✅ Fixed — `/homebrew`+`/AGENTS.md` special case deleted. `[P7-14]`
- [x] **PrivilegesService dead blocklist loop.** ✅ Fixed — `validateSafeToDeletePath` rewritten as allowlist-first, then blocklist now `return false`s (with stricter exact/segment matching). `[P7-14]`

## P1 — Correctness bugs (app misleads or breaks the user)

User sees wrong data, or a destructive/important action misbehaves.

- [x] **`--ignore-dependencies` on formula uninstall.** ✅ Fixed — `uninstallBrewFormula` runs `brew uses --installed` first; aborts + sets `lastUninstallWarning` if dependents exist. Flag dropped. `[P2-4]`
- [x] **SSD parser is NVMe-only but accepts SATA output.** ✅ Fixed — `scan` requires NVMe markers; rejects SATA/ATA/USB-bridge output with a clear message. `[P8-18]`
- [x] **`removeFiles` double-escapes paths.** ✅ Addressed — routed through `singleQuote` (one shell-quote layer). NB: the corruption doesn't reproduce — `runWithPrivileges`'s `\`/`"` escaping targets the AppleScript *source* literal, not the shell, so layers don't stack (traced through osascript→`quoted form of`→`sh -c`). `[P7-14]`
- [x] **"Clear logs" doesn't clear.** ✅ Fixed — added `Logger.clear(category:)` (+`clearLogFile()`); `LogsViewModel.clear*` empties the buffer so it sticks on re-entry. `[P8-19]`
- [x] **pip/brew success decided by string-scraping.** ✅ Fixed — pip uninstall now decides on exit code (brew paths already did). `[P2-3, P3, P5-10, P8-18]`
- [x] **Optimistic list updates drift from reality.** ✅ Fixed — pip + brew install/uninstall re-query the real installed set instead of mutating in place. `[P2-3]`
- [x] **Cruft Sweeper: 4 lifters on one `AsyncStream`.** ✅ Fixed — single consumer drains the stream, fans out to a bounded (4-wide) `TaskGroup`. `[P6-12]`
- [x] **GhostBuster PID-reuse race.** ✅ Fixed — `killWithRetry(ghost:)` re-verifies PID→command+port via `lsof` before any signal. `[P4-8]`
- [x] **"Protect active projects" measures wrong timestamp.** ✅ Fixed — `projectActivityDate` uses `.git/index`/`HEAD` then newest non-cruft immediate child, not the cruft folder's mtime. `[P6-12]`
- [x] **`deleteEmptyFolders` is inverted/inert.** ✅ Fixed — inverted guard: OFF skips zero-byte items, ON keeps them. `[P6-12]`
- [x] **SSH perm checks use decimal magic numbers + exact equality.** ✅ Fixed — mask `& 0o777`, compare `0o700`/`0o600`. `[P4-7]`
- [x] **ConflictDoctor NPM check is Intel-only.** ✅ Fixed — uses `BrewPathManager` prefix (+both bin paths), login-shell npm/`$NVM_DIR`, also detects `~/.nvm`. `[P4-7]`
- [x] **`extractValue` substring key match picks wrong line** (SSD). ✅ Fixed — anchors on exact field name left of the first colon. `[P8-18]`
- [x] **`|| true` masks smartctl exit code.** ✅ Fixed — captures real exit via marker line; mask `0x03` = unreadable → reject. `[P8-18]`
- [x] **StorageDoctor volume math fragile / divide-by-zero.** ✅ Fixed — uses `volumeAvailableCapacityForImportantUsageKey` + total capacity; guards the divisor. `[P4-7]`
- [x] **Brew update case-sensitive verify.** ✅ Fixed — `verifyUpdate` compares case-insensitively. `[P3-6]`

## P2 — Foundational refactors (highest leverage)

These collapse whole classes of the bugs above. Do P0/P1 first, then these to prevent recurrence.

- [~] **Add array-args exec path to `AsyncProcessRunner`.** ✅ Added `run(executable:arguments:environment:timeoutSeconds:)` + `runBrew(...)` (no shell, no quoting). On array-args: the two main package VMs + all package *listing* (via `InstalledPackagesService`). Remaining command-string sites (Outdated/Requirements/Popular/Install VMs/Dashboard/PythonService) were made safe by routing through `singleQuote` (and `shellEscape` is now private), so the injection/escaping risk is centralized — but converting those to true array-args is still a worthwhile follow-up. `[P7-13]`
- [x] **Add timeout + cancellation to `AsyncProcessRunner`.** ✅ Done — shared `executeProcess` core uses `withTaskCancellationHandler` (kills child on cancel) + optional timeout with SIGTERM→SIGKILL escalation. `[P7-13]`
- [x] **Define a `Doctor` protocol.** ✅ Done — `protocol Doctor` (+`AvailabilityCheckable`) in `HealthCheckModels`; all 16 checkers conform; `HealthCheckService` now holds one `[Doctor]` array and derives the scan loop + status + fix routing from it. Removed the 16 properties, the flat-map, the availability special-case, and the 14-case switch. `[P4-7]`
- [x] **Stable `fixID` on `HealthIssue`.** ✅ Done — added `HealthFix` enum + `fixID` (defaulted, so existing inits still compile); every checker's `fix` routes on `fixID` not title; `.security` double-dispatch removed (service tries each doctor, owner returns true). `[P4-7]`
- [x] **Extract `InstalledPackagesService`.** ✅ Done — new `Services/InstalledPackagesService.swift` (array-args pip/formulae/cask listing with versions); `PIPPackagesViewModel`, `BrewFormulaeCaskViewModel`, `PopularPackagesViewModel` all delegate to it. `[P2, P5-9]`
- [x] **Build one `ManagedBlock` manager for `.zshrc_catalyst`.** ✅ Done — `ShellConfigManager` gained `writeManagedBlock`/`readManagedBlock`/`removeManagedBlock`/`hasManagedBlock` with `# CATALYST_BEGIN/END <id>` sentinels; Aliases and SmartShortcuts now write/remove via it (legacy brace-count/comment parsers kept as a removal fallback for pre-existing entries). `[P5-10, P5-11]`
- [x] **Make `shellEscape` private; route all callers through `singleQuote`.** ✅ Done — all ~28 bare call sites converted to `singleQuote` (incl. double-quote `export PATH="…"` fragments rewritten as `singleQuote(prefix + "/bin")`); `shellEscape` is now `private static`; tests retargeted to `singleQuote`. `[P2, P7-15]`
- [x] **Migrate all `URLSession.shared` call sites to `NetworkConfig`.** ✅ Done — pip search, brew search/casks, PyPI fetch, SmartShortcuts detail, pip-install search → `NetworkConfig.apiSession`. Left `NetworkMonitor`'s reachability probes (intentional). Dashboard pip-version uses `JSONSerialization`, not `URLSession.shared` — separate typed-fetch cleanup. `[P1, P2, P3, P5, P8-20]`
- [x] **Split the ~990-line `DashboardViewModel`.** ✅ Done — extracted `DetectionService` (tool-presence probes), `PythonManager` (install/uninstall/link, pip, version fetches), and `BrewMaintenanceManager` (Homebrew install/uninstall + update/upgrade/cleanup/doctor/link, stats, keg parsing) as three `@MainActor` services. VM dropped from ~985 → 428 lines and is now a thin orchestrator (keeps `@Published` state, busy flags, console bridge, cache invalidation, `onGlobalRefresh`). No View changes — every `@Published` property and the `BrewSystemStats` shape stayed put (struct moved to top-level). Each manager registered in `.pbxproj` (synthetic IDs `CA`/`CB`/`CC`). Maintenance streaming commands take an `onOutput` callback so the console stays VM-owned. `[P1-1]`
- [x] **Dedup the two Outdated VMs (~70% identical).** ✅ Done — `@MainActor protocol OutdatedUpdating` + extension provides `formattedLastScanDate`, `resetUpdateResults`, `hasNetworkConnection`, `updateFiltered`; both VMs conform and keep only the pip-vs-brew `updatePackage`/`rescanAfterUpdates` (the rescan hook standardizes the update-then-rescan difference). `[P3]`
- [x] **Model detection as an enum, not display strings.** ✅ Done — added `DetectionState` enum; `DashboardViewModel` now sets `brewState`/`commandLineToolsState` alongside the display strings; `AppViewModel.fullRefresh` compares `brewState == .installed` instead of `brewStatus == "Installed"`. (Additive — display strings kept for the View; full state-driven display can come with the deferred VM split.) `[P1-1]`
- [x] **Native set-diff in venv `verifyInstallation`.** ✅ Done — replaced the `comm -23` zsh process-substitution pipeline with a native `Set` diff (`requirementNames` + array-args `pip freeze`). `[P1-2]`
- [x] **Capture package versions.** ✅ Done — `brew list --versions` / `pip list --format=freeze` now populate `InstalledPackage.version` in the pip & brew listing VMs (was always nil). `[P2-3, P2-4, P5-9]`

## P3 — Robustness & code quality

Lower-risk cleanups; schedule opportunistically alongside nearby P2 work.

- [x] **Dr. Catalyst score is uncalibrated/saturates.** ✅ `calculateScore` now multiplicative decay (0.7^crit · 0.9^warn · 0.98^info × 100) — degrades smoothly, asymptotes toward 0, stays meaningful at the bad end. `[P4-7]`
- [x] **History polluted by re-scan-after-fix.** ✅ `saveSnapshot` debounced to one snapshot per calendar day (same day → update in place). `[P4-7]`
- [x] **GhostBuster substring allow/blocklist.** ✅ `commandTokens` tokenizes the basename; allow/block match whole tokens (fixes "dock"→"docker", "go"→"google-…"). `[P4-8]`
- [x] **GhostBuster kill-all vs single-kill inconsistency + privilege path.** ✅ kill-all now removes only verified kills (like single-kill); clearer "needs elevated privileges" message on give-up. (Full sudo-kill routing = P4 feature.) `[P4-8]`
- [x] **SSD `detectBootDisk` regex brittle.** ✅ Parses `diskutil info -plist` → APFS physical store / parent whole disk; `wholeDisk(from:)` anchors on `diskN`. `[P8-18]`
- [x] **SSD `healthScore` ad-hoc / double-penalizes.** ✅ Documented additive-penalty budget with clamped inputs (wear 40 / spare 25 / media 20 / log 10 / temp 10 / shutdowns 10). `[P8-18]`
- [x] **Aliases over-escaping breaks `$`/backtick aliases.** ✅ Single-quote storage via `singleQuote` — preserves `$VAR`/backticks/`$1` for use-time expansion. `[P5-11]`
- [x] **Naive alias parser.** ✅ `parseAliasLine` now stops at the closing quote (ignores trailing inline comments) and handles unquoted values. `[P5-11]`
- [x] **SmartShortcuts: `functionExists` / `replaceFirstOccurrence` / two Python detectors.** ✅ Declaration-anchored `functionExists`; first-line-only rename; `getPythonWithPip` routes through injected `PythonService`. `[P5-10]`
- [ ] **Unify caching policy.** ⏸️ **DEFERRED (structural).** UserDefaults-no-expiry vs 24h TTL vs in-memory — a cross-cutting design decision; do as one coherent change. `[P5-9]`
- [ ] **Define one on-disk storage layout.** ⏸️ **DEFERRED — now ELEVATED (post-rename).** Three-way split: most stores use `…/com.shivanggulati.catalyst`, `SSDHealthService` uses `…/Catalyst`, plus `UserDefaults`. The 2026-07-04 bundle-id rename orphaned any data under the old `…/com.sg.catalyst` folder (stores fresh-start, so no crash, but it's real). Unify onto one root + add a one-time migration as a single change. `[P8, P8-18]`
- [~] **Logger.** ✅ `stat`-per-line → size-check every 100 writes; dead `getAllLogs` (lexical sort) removed. *Left:* unify the 1000-entries-vs-500KB truncation policy + move `NSSavePanel` out of the VM (MVVM nicety). `[P8-19]`
- [ ] **`NetworkMonitor` instead of shelling `curl`/pinging PyPI.** ⏸️ **DEFERRED (DI).** `NetworkMonitor` is injected, not a singleton; the shared `OutdatedUpdating.hasNetworkConnection` would need it threaded through DI. `[P3-5, P3-6]`
- [~] **Replace cosmetic `Task.sleep` waits.** ✅ Removed the venv `refreshWithDelay` 1.5s. *Left:* the Dashboard post-install 2s waits — they guard a real filesystem-sync race; need polling, not blind removal. `[P1-1, P1-2]`
- [x] **Schema versioning for `ProjectStore`.** ✅ Tolerant per-element decode (`Lossy<Project>`) — one bad record no longer discards the whole store. `[P1-2]`
- [x] **Collapse duplicate keg-parsing; hoist duplicated `BrewItem` struct.** ✅ `updateBrewUnlinkedKegs` reuses `parseUnlinkedKegs`; `BrewItem` hoisted to one `BrewCatalogItem`. `[P1-1, P2-4]`
- [~] **Cruft Sweeper.** ✅ Options snapshotted once; `venv`/`node_modules`/`.gradle` now marker-guarded; hidden app-dirs excluded; protection covers DerivedData; shared caches split; single-pass scan; results/config UI reworked (see Session 2026-07-04). Progress→100% cosmetics now **moot** (indeterminate bar). *Left:* dead `CruftType.unknown`; custom-path grouping. `[P6-12]`
- [x] **Surface install/uninstall failures in UI** (error banner, not just logs). ✅ Done — reusable dismissible `Helpers/ErrorBanner.swift` (ID `CJ`) bound to a VM `@Published var installError: String?`, set on install-failure branches and rendered above the console. Wired across **all** install surfaces: Popular Packages, Install pip, Install Formulae/Casks (both tabs), requirements.txt Installer, Dashboard (Homebrew + Python install — where output otherwise only reaches Logs), and SmartShortcuts (maps `InstallOutcome` failure cases). Name-conflict keeps its dedicated UI. `[P1-1, P2-4]`
- [x] **SSD mask serial at persistence; dead `storageDoctor`; SecurityDoctor only `id_rsa`/`zsh_history`.** ✅ `DriveInfo.encode` persists the masked serial; `storageDoctor` prop removed (during P2-arch); SecurityDoctor now checks all `id_*` RSA keys + scans `~/.bash_history` too. `[P8-18, P4-7]`
- [x] **Remove `OutdatedBrewViewModel` redundant detached `isBrewAvailable` init (race).** ✅ Removed; resolved synchronously at scan/reset. `[P3-6]`

## P4 — Feature ideas

### New high-value (not yet in app — strongest fit, lowest cost)

- [ ] **Port killer** — "what's on :3000?" → show process, one-click kill (`lsof -i`). Devs hit this daily.
- [ ] **CatalystSnapshot** 🚀 (master feature — **planned**, full design in `CatalystSnapshot-Plan.md`) — capture the whole dev env (Homebrew via Brewfile, Python interpreters + pip, Catalyst alias/PATH managed blocks, SmartShortcuts, git identity, tracked venv projects) into a portable `.catalystsnapshot` file and restore it on a new Mac. Diff-then-restore engine (idempotent, resumable, dry-run, gated). Reuses existing services; secrets never exported. **Supersedes** the old "machine profile export/import" item and folds in "Dotfile backup" + "Bootstrap this Mac". 5 open product decisions in the plan doc §7.
- [x] **Battery Health module** — ✅ New "Battery Health" tab (Disk Vitals card layout): health gauge (max capacity %), cycle count, condition, charge, temperature, full/design mAh, time remaining. `ioreg`+`pmset`, no new dep; desktops show no-battery state. *(Needs Xcode compile on Mac.)*
- [x] **Visual PATH / env editor** — ✅ New "PATH Editor" tab (Developer Workflow): inspects effective `$PATH`, flags duplicates/dead dirs, reorder (up/down), remove, one-click Clean, Apply curated order via `ShellConfigManager` managed block (removable override). `PathEditorService`/`ViewModel`/`View`. *(Needs Xcode compile on Mac.)*
- [ ] **Vulnerability scan** — `pip-audit` / `brew audit` against installed packages; surface CVEs. (Pairs with P3-2 "security-only filter".)
- [ ] **Dependency explorer** — "why is this installed?" via `brew uses`/`brew deps`, `pip show`; + orphan cleanup (`brew leaves`/`autoremove`).
- [x] **Login items & launch-agents manager** — ✅ New "Startup Items" tab: classic login items (remove), user LaunchAgents (toggle load/unload + trash plist), system agents/daemons read-only (reveal in Finder). `LoginItemsService`/`ViewModel`/`View`. *(Needs Xcode compile on Mac.)*
- [x] **Menu-bar mode** — ✅ `MenuBarExtra` (.window style) in `CatalystApp` + `MenuBarContentView`: health score ring, critical/warning/outdated counts, quick actions (Open, Run Health Scan, Check Updates, Quit). *(Needs Xcode compile on Mac.)*

### Auth / password UX

- [x] **Ask for password once per launch** — ✅ `PrivilegesService` now prompts once, validates via `sudo -S -v`, caches the credential in memory, and runs all later actions silently through `sudo -S` (password on stdin, never embedded in a script). Re-prompts only if the cached credential is rejected; `invalidateCredentials()` available. *(Needs Xcode compile on Mac.)*
- [~] **Ask once *ever* (SMAppService helper)** — 🚧 Scaffolded. App-side `CatalystHelperProtocol` + `PrivilegedHelperManager` are in the target; `PrivilegesService.preferPrivilegedHelper` routes root actions over XPC when enabled (off by default, auto-falls back). Helper target sources + plists live in `PrivilegedHelper/` (not yet a build target). **Finish via `PrivilegedHelper/README.md`**: add the CatalystHelper command-line target, embed the launchd plist, sign both with team 6957JGQD3R, then `install()` + set `preferPrivilegedHelper = true`.

### App-wide consistency

- [x] **One modular input field** — ✅ New `Helpers/CompactInputField.swift` is the single source of truth for typing areas; Alias (name/command), SSH (file/comment/passphrase), and Network (ping/DNS host) all use it. Section cards across new views converted to shared `.cardStyle()`.
- [ ] **Disk-by-package view** — rank installed packages by size (complements Cruft Sweeper).
- [x] **SSH key manager** — ✅ New "SSH Keys" tab: lists key pairs (type/bits/fingerprint/comment), copy public key to clipboard, generate (Ed25519/RSA-4096, name/comment/passphrase), reveal in Finder, fix dir(700)/key(600) perms. `SSHKeyService`/`ViewModel`/`View`. *(Needs Xcode compile on Mac.)*
- [ ] **Dotfile backup** — version `.zshrc`/`.gitconfig` before the app edits them.
- [x] **Network diagnostics** — DNS, latency/speed, listening ports. ✅ New `NetworkDiagnosticsService`/`ViewModel`/`View` + "Network Diagnostics" sidebar tab: internet+gateway ping latency/loss, DNS resolve + system resolvers, active interface (IP/gateway), listening TCP ports. *(Needs Xcode compile on Mac.)*
- [x] **Storage in Disk Vitals** — `StorageInfo` model + full-width `StorageVitalsCard` (usage bar, used/free/total, raw NVM capacity). Re-scan once to populate. *(Needs Xcode compile on Mac.)*

### From the sweep (existing feature backlog)

- [ ] **"Bootstrap this Mac"** — one button: CLT → Homebrew → Python → link, with progress. `[P1-1]`
- [ ] **Default-Python switcher** (pyenv-style global). `[P1-1]`
- [ ] **Toolchain parity** — Node/nvm, Ruby, Java status. `[P1-1]`
- [ ] **More venv backends** — uv, Poetry, Pipenv, conda (auto-detected). `[P1-2]`
- [ ] **Editor integration** — write `.vscode/settings.json` interpreter path. `[P1-2]`
- [ ] **Per-project package panel** + freeze to `requirements.txt`. `[P1-2]`
- [ ] **Broken-venv detection & one-click rebuild.** `[P1-2]`
- [ ] **Orphaned-venv cleanup** → hand to Cruft Sweeper. `[P1-2]`
- [ ] **Inline version + outdated badge; multi-select bulk uninstall; package detail panel.** `[P2-4]`
- [ ] **Pin/hold packages; changelog links; security-only filter; scheduled background scan.** `[P3]`
- [ ] **Dr. Catalyst: "Fix all auto-fixable" (batched re-scan); per-issue "explain/show command"; snooze/ignore issues; menu-bar score badge.** `[P4-8]`
- [ ] **GhostBuster: show full command line + cwd + uptime; remember "always allow/ignore".** `[P4-8]`
- [~] **Cruft Sweeper features.** ✅ "Rebuildable" reassurance labels (Safe/Rebuild chips) shipped 2026-07-04. *Left:* size+count preview with undo hint; saved scan profiles; scheduled sweep. `[P6-12]`

---

### Keep (don't regress)

- [ ] Cruft Sweeper uses `trashItem` (recoverable), hard-skips `.ssh`/`.Trash`/`.git`. `[P6-12]`
- [ ] `NetworkConfig`, `BrewPathManager`, `TerminalService`, About + Popular Packages VMs are the clean references to converge on. `[P7-17, P5-9, P8-20]`
