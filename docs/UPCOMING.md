# Catalyst — Ahead / Deferred Features

Scoped but intentionally **not built yet**. Referenced as the "deferred backlog" from
`CatalystUnderstanding.md` and `CODING_STANDARDS.md`. Pull an item into `taskTracker.md` when it's
picked up.

**Everything below is targeted for post-v1.2 (Open Source Release) unless stated otherwise.**

**Currently live: v1.2 (Open Source Release).** All proprietary checkout, billing, and licensing flows have been stripped out as the project is now free and open source.

---

## 1. Snapshot restore — remaining pipeline work

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

## 2. Snapshot-restore safety guard — carried, worth an hour

A restore is capable of writing a 0-byte backup and dropping `brew shellenv` from `~/.zshrc`.
This cost the maintainer's own Mac its npm, CA bundle and `~/.zshrc` during v1.13 development.
Guard: refuse to write a backup that's smaller than the original, and refuse to write a profile
that lost a line matching `brew shellenv`.

---

## 3. Extend `Validators` to the remaining fields

`Helpers/Validators.swift` exists (v1.13). New rules belong in a shared file, not inline on a view model.

- **Still inline:** the venv name rule lives on `VirtualEnvCreationViewModel`
  (`venvNameError` / `isVenvNameValid`, CODING_STANDARDS 12.27). Extract it.
- **Not yet routed through it:** package names (split name vs version-spec),
  `requirements.txt` paths, aliases, PATH entries, SmartShortcut/function names, SSH key
  name/comment, search bars.
- **Injection guards:** prefer `AsyncProcessRunner.run(executable:arguments:)` (array-args)
  over string interpolation; reject shell metachars where they can't legitimately appear.
- Unit tests (malicious + boundary inputs) and the CODING_STANDARDS Part 12 rule table.

---

## 4. Refreshing-state banner (launch dead-time)

A thin auto-dismissing strip under the header ("Refreshing your environment…") to fill the
2–4s empty-dashboard gap on launch. Bind to the existing `isRefreshing`/`isLoading` flag with
a slide+fade transition. Low risk — passive observer of `@MainActor` state, no new concurrency.
**Guard against a stuck flag:** force-hide after ~8s and always flip the flag in a `defer`, or
the banner never dismisses.

---

## 5. Environment-health false negatives — low priority

The maintainer's Mac has `which npm` → exit 0 but `npm root -g` / `npm config get cache` →
exit **127**, while `node -v` succeeds. Catalyst reports the Node card from a toolchain that's
half-broken and says nothing about it.

Not a Catalyst bug — the machine's npm shim is genuinely broken. But it's a case worth handling:
when a tool resolves on PATH yet fails to execute, that's more useful to surface as "npm is
present but not working" than to silently report whatever the probe returned.

---

## 6. Parked by decision (not backlog)

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

## 7. Prior deferrals (carried, unchanged)

- Swift-6 `timeoutTask` concurrency warning.
- `fullRefresh()` has no re-entrancy guard (low risk; guarded in practice by brew lock + busy
  flags).
- Migrate's `PythonManager` doesn't check Dashboard `isInstallingPython` (same guards;
  practically impossible to hit).
