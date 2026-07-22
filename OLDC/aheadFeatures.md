# Catalyst — Ahead / Deferred Features

Scoped but intentionally **not built yet**. Referenced as the "deferred backlog" from
`CatalystUnderstanding.md` and `Formrules.md`. Pull an item into `taskTracker.md` when it's
picked up.

**Everything below is v1.19 unless stated otherwise.**

**Currently live: v1.17. v1.18 is BUILT AND PENDING RELEASE** — the Worker is deployed and the
migration applied, but no notarized DMG has been cut, so nothing is in users' hands yet. v1.18
carries comped access (redeemable gift codes), non-GST invoicing with on-device PDF generation,
buyer details collected before checkout, and the §1 double-charge fix. v1.17 carried the
Python-scan race fix — **now confirmed at runtime**
(2026-07-20): `waiting out superseded scan` fires and gen N+1 begins only after gen N's
`TASK end`, with no overlapping `pip-probe start`. Shipped detail lives in `taskTracker.md` +
`Catalyst/about.json`.

---

## 1. Checkout: second payable link on a tier / currency CHANGE

The v1.18 fix reuses a pending `stupl:<user_id>` link, but ONLY when tier, currency and amount
all match the fresh quote. A genuine change — student verifies mid-flow, or a currency switch —
still mints a second link while the old one stays payable **at the old price**. Two links paid =
two `grants.ref` values = two grants.

The real invariant is **one perpetual grant per user**, which `grants.ref` (unique per LINK)
cannot express. A partial unique index on `grants(user_id)` would — but then a genuine double
payment is silently ignored and the user has paid twice for one licence. That needs a refund /
alert path, not an `INSERT OR IGNORE`. **Decide that before implementing.**

Link cancellation stays off the table: an unpaid link expires on its own, and `/entitlement`'s
self-heal READS it to recover a missed webhook.

`catalyst_worker/src/index.ts` → `licenseCreate`.

---

## 1b. Invoice `seq` gaps from a lost race

`issueInvoice` checks "does an invoice exist for this grant?" and INSERTs as two statements, so
the webhook and `/entitlement`'s self-heal can both pass the check and both allocate a number.
The UNIQUE index on `grant_id` lets one win; the loser now resolves to the winner's row rather
than throwing, but its allocated `seq` is spent and leaves a gap.

Harmless today (no duplicate invoice can exist) but it erodes what `seq` is FOR — proving no
invoice is missing when the public number is random. Fix by allocating the number inside the
same statement as the insert, or by recording burnt allocations. Low priority; note it before
anyone reads a gap as a lost invoice.

---

## 2. Checkout: no escape for 2 minutes

After tapping Buy, `PaywallView` strips Back (`if !authVM.checkoutStarted`, Formrules 12.35)
and offers only *Check now* / *Reopen checkout*. `resetCheckout()` — the only exit — appears
only after `startCheckoutPolling`'s ~2-minute window sets `checkoutTimedOut`. There's no app
behind the paywall either, so force-quitting is a reasonable thing to reach for.

**Fix:** show **Cancel** (local `resetCheckout()`) immediately. The original reason for
stripping Back was to stop a second *subscription* being created — that risk died with
subscriptions. Reword the timeout copy too; "go back and try again" only works once Back exists.

`Views/UserProfileView.swift` (`PaywallView` Back gate), `ViewModels/AuthViewModel.swift`.

---

## 3. USD pricing — PERMANENTLY DEFERRED until explicitly revived (2026-07-20)

> **Do not pick this up.** Deferred by decision, not by capacity. It stays parked until Shivang
> says otherwise — do not "helpfully" re-enable it because the plumbing looks ready.

**The app and Worker are ready. This is now purely a payments question.**

Everything that needed code shipped in v1.13: `licensePrice()` is currency-parameterised,
`/entitlement` returns `price_*_minor` + `currency`, and the app renders the symbol via
`NumberFormatter` from the server's currency — no `₹` literal survives anywhere. Enabling a
currency is config, not a release.

**Probed 2026-07-19 against live Razorpay:**

| Finding | Result |
|---|---|
| USD Payment Link creation | ✅ works (`$69` created fine) |
| $1 USD link | ❌ `Request not allowed due to restrictions` — **minimum-amount floor**, not a currency block |
| INR control | ✅ works |
| PayPal on the Payment Link page | ❌ **not offered** — Cards only |
| INR ₹1 real payment, end to end | ✅ verified on a live account |

**The open question, and it's the blocking one.** The dashboard states international
currencies can be collected *only* via PayPal and never in INR. But PayPal does not surface on
Payment Links (it's a Standard Checkout method), and the USD link instead offers **Cards** —
with RuPay/Maestro in the network list, which are domestic. So either that card rail genuinely
authorises international cards, or the button renders and declines at authorisation.

That second case is worse than a blocked link: a US buyer reaches a page that *looks* payable,
enters a card, and fails at the last step. It surfaces as an abandoned checkout, not an error.

**Next step (no code):** ask Razorpay support directly — *"on a USD Payment Link, will
international cards be authorised, given my account is international-via-PayPal-only?"*
Only if the answer is no does this become a real engineering task (move the USD path to
Standard Checkout: different client integration, and `payment.captured` instead of
`payment_link.paid`, so the grant branch would have to handle both).

**When it does get enabled:**

- Uncomment `PRICE_STANDARD_USD` / `PRICE_STUDENT_USD` in `wrangler.toml` (currently commented
  out — the `$69`/`$29` figures in there are placeholders, not chosen prices).
- Decide *when* to send `currency=USD`. Cloudflare hands the Worker `req.cf.country` free on
  the existing `/entitlement` call — no extra request, and far better than the app's
  `Locale.current.region`, which reports the region the user *set*, not where they are.
- **The app must echo back the currency it displayed** into `/license/create`. Today both
  endpoints resolve currency independently; same IP means the same answer almost always, and
  "almost" is exactly the case where the paywall says $69 and Razorpay charges ₹5,999.
- Zero-decimal currencies (JPY/KRW) would break the `/100` divisor and DO need an app release.

**Also carried:** minimum-amount floors differ per currency. The KV price override has no floor
check, so a too-low `wrangler kv key put` produces links that fail at creation, not at write.

---

## 4. KV price lookup is in the hot path — halves the free-tier ceiling

**The free tier binds on KV reads, not Workers requests, and nobody would guess that.**

`licensePrice()` does one `env.SESSIONS.get()` per tier, so every `/entitlement` call costs **2 KV
reads**. Workers free allows 100k requests/day but KV free allows only 100k **reads**/day — so KV
runs out first, at half the traffic. At ~8 entitlement calls per user per day (launch + foreground
+ the 4h poll) that's ~16 KV reads per user: a practical ceiling of about **6,000 DAU**, where the
request budget alone would have carried ~12,000.

**Fix:** keep the KV override but take it off the hot path — cache the resolved price in a
module-scope variable with a short TTL (30–60s), or read `[vars]` directly and re-check KV at most
once a minute. A price change would then land within a minute instead of instantly, which is
irrelevant: prices move on the order of months, and the app's own poll is 4h anyway.

**Do not** solve this by deleting the KV override and going vars-only — that turns every price
change back into a deploy, which was the whole point of P14.

Beyond the free tier this stops mattering much: Workers Paid is $5/mo (~40k DAU) and each further
10k users is ~$2–3/mo. This is a "stay free longer" optimisation, not a cost emergency.

`catalyst_worker/src/index.ts` → `licensePrice`.

---

## 5. Toolbar redesign

Grouping, icons, labels, overflow behaviour, consistency with the sidebar. Deferred twice now
(v1.13, and again across the 1.14–1.16 re-cuts) because those releases were already loaded.

---

## 7. Offline licence file — what makes "lifetime" honest

Catalyst validates entitlement against the Worker, so today a lifetime licence is really
"lifetime, as long as the server exists". If the service is ever sunset, every perpetual
customer is bricked — not what they paid for.

**Shape:** a signed, offline-verifiable blob (Ed25519, same key material as the entitlement
JWT) holding licence id, account email, tier, issue date; verified against the public key
already embedded in `AuthConfig.publicKeyPEMBody`.

**Doesn't have to ship as a feature.** The minimum viable version is a written commitment in
the Terms — *if we ever sunset the service, we ship a build that validates offline* — plus the
code being ready. The "Export licence" button can come whenever.

---

## 9. Snapshot restore — remaining pipeline work

The one-click *Install All* card shipped in v1.13, but prerequisites are still resolved as a
**separate step before** Restore rather than inside it.

- **Fold prereq installs INTO the pipeline** so Restore auto-bootstraps mid-run: CLT →
  Homebrew → formulae/casks → interpreters → pip → venvs → shortcuts/dotfiles, re-evaluating
  `blockedReason`/`alreadySatisfied` after each prereq so dependents unblock as the run
  proceeds. Already idempotent and resumable, so this is sequencing, not new state.
  **Open:** auto-install silently vs an explicit "install prerequisites and continue" confirm.
- **Reframe pending vs blocked.** Reserve `blocked` (orange, non-actionable) for genuinely
  unresolvable items — missing source path, unavailable formula, arch mismatch. Missing
  Homebrew/CLT/Python are *resolvable* → a distinct pending-prerequisite state that reads as
  informational, not a warning.
- **Collapse dependents.** Not 21 identical "Homebrew isn't installed" rows — "21 formulae will
  install after Homebrew."
- **Fix header counts.** Prerequisite-pending items shouldn't inflate "Blocked".
- **Auto venv reconstruction for PEP 668.** The Install Space picker resolves the immediate
  failure; the OS-recommended fix (rebuild into a venv) still isn't offered.

**Touch points:** `Services/SnapshotService.swift` (PLAN), `Models/SnapshotModels.swift` (a
prerequisite concept distinct from `blockedReason`), `SnapshotRestoreService` (sequenced APPLY),
`Views/SnapshotView.swift` + `ViewModels/SnapshotViewModel.swift`.

**Caveat:** the Dashboard installers mutate Dashboard UI state — prefer the underlying service
methods (or the extracted `PrerequisiteInstaller`) over calling `DashboardViewModel` directly.

---

## 10. Snapshot-restore safety guard — carried, worth an hour

A restore is capable of writing a 0-byte backup and dropping `brew shellenv` from `~/.zshrc`.
This cost the maintainer's own Mac its npm, CA bundle and `~/.zshrc` during v1.13 development.
Guard: refuse to write a backup that's smaller than the original, and refuse to write a profile
that lost a line matching `brew shellenv`.

---

## 11. Extend `Validators` to the remaining fields

`Helpers/Validators.swift` exists (v1.13) and holds the email rules, wired into sign-in and
student verification. New rules belong in a shared file, not inline on a view model.

- **v1.18 added a SECOND home:** `BillingValidators` in `Utilities/InputSanitizer.swift` (name,
  email, phone, address, city, postal, country, gift code). Two validator homes is one too
  many — fold `BillingValidators` into `Helpers/Validators.swift`, or move the email rules out
  to join it. Pick one and consolidate before a third appears.
- **Still inline:** the venv name rule lives on `VirtualEnvCreationViewModel`
  (`venvNameError` / `isVenvNameValid`, Formrules 12.27). Extract it.
- **Duplicated across the wire:** `BillingValidators` and the Worker's `billingProfile` POST
  gate encode the same required-field rules in two languages. Deliberate (the server is the
  guarantee, the app is the affordance) but they must be changed together.
- **Not yet routed through it:** package names (split name vs version-spec),
  `requirements.txt` paths, aliases, PATH entries, SmartShortcut/function names, SSH key
  name/comment, search bars.
- **Injection guards:** prefer `AsyncProcessRunner.run(executable:arguments:)` (array-args)
  over string interpolation; reject shell metachars where they can't legitimately appear.
- Unit tests (malicious + boundary inputs) and the Formrules Part 12 rule table.

**Caveat:** the academic-domain list is duplicated between `Validators` and the Worker's
`isAcademicEmail`, kept in sync by hand. The Worker's `STUDENT_EMAIL_DOMAINS` env var is
invisible to the app, so a custom domain there would be accepted client-side and rejected
server-side. Unset today; if it's ever used, have `/entitlement` return the list.

---

## 12. Refreshing-state banner (launch dead-time)

A thin auto-dismissing strip under the header ("Refreshing your environment…") to fill the
2–4s empty-dashboard gap on launch. Bind to the existing `isRefreshing`/`isLoading` flag with
a slide+fade transition. Low risk — passive observer of `@MainActor` state, no new concurrency.
**Guard against a stuck flag:** force-hide after ~8s and always flip the flag in a `defer`, or
the banner never dismisses.

---

## 13. Environment-health false negatives — noticed 2026-07-19, low priority

The maintainer's Mac has `which npm` → exit 0 but `npm root -g` / `npm config get cache` →
exit **127**, while `node -v` succeeds. Catalyst reports the Node card from a toolchain that's
half-broken and says nothing about it.

Not a Catalyst bug — the machine's npm shim is genuinely broken. But it's a case worth handling:
when a tool resolves on PATH yet fails to execute, that's more useful to surface as "npm is
present but not working" than to silently report whatever the probe returned.

---

## 14. Parked by decision (not backlog)

**Full-screen working view for import/diff — DECLINED.** Replacing the slim
`SnapshotImportBar` with Capture's full-window treatment. The non-blocking bar is preferred;
only the overlap bug was fixed in v1.13. Kept on record because it would reverse the
non-blocking behaviour — if revisited, keep cancellation available.

**Apply the zshrc for the user — PARKED BY REQUEST.** An app **cannot** `source` into
already-open shells; a child process can't mutate a sibling shell's env. If revisited: drop the
manual instruction, reassure ("new terminals use it automatically"), source the profile
internally for subsequent Catalyst child processes, and optionally offer "Open new Terminal".
Be explicit that existing windows can't be retroactively updated — don't imply magic.

---

## 15. Prior deferrals (carried, unchanged)

- Swift-6 `timeoutTask` concurrency warning.
- Account-per-Mac cap.
- `fullRefresh()` has no re-entrancy guard (low risk; guarded in practice by brew lock + busy
  flags).
- Migrate's `PythonManager` doesn't check Dashboard `isInstallingPython` (same guards;
  practically impossible to hit).

---

## 16. Razorpay customer prefill — DEAD, flag left in place

Razorpay rejected `customer.name` / `customer.contact` on this account with a bare
`SERVER_ERROR` (`source`/`step`/`reason` all `NA`), failing the whole Payment Link creation.
Every checkout was costing two API calls — a failing one, then the retry — and logging an error
on every sale.

`PREFILL_RAZORPAY_CUSTOMER = false` in `licenseCreate` disables the first attempt. The payload
builder and retry are intact: flip to `true` to re-enable in one character. **Cost while off:**
the buyer retypes their name and phone on Razorpay's hosted page, even though we already
collected both. Needs a Razorpay support answer on WHICH field it disliked before revisiting.

---

## 17. Untested paths carried into v1.19

Deferred deliberately on 2026-07-20 — practical to skip, not safe to forget.

- **Account-switch hygiene.** Sign out mid-flow with banners showing, sign in as another
  account, confirm nothing carries over. This class of leak has ALREADY bitten once (it's why
  `clearAccountState()` exists) and v1.18 added five new fields to it — `billingReady` is the
  dangerous one: left `true`, the paywall skips the details form and bills account B under
  account A's name and address.
- **Comp expiry lapse.** A capped comp reaching `expires_at` should drop to the locked gate.
  Server-driven (`expires_at > now`) so the logic is simple, but every capped comp reaches it —
  certain, not unlikely.
