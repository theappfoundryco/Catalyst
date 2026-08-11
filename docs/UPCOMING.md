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

## 2. ~~Snapshot-restore safety guard~~ — SHIPPED 2026-07-30 (issue #13)

Implemented in `SnapshotRestoreService.restoreMainProfile`: refuses to shrink the profile,
refuses to drop `brew shellenv`, verifies the backup's byte count before overwriting, and rolls
back automatically when the write fails or `zsh -n` rejects the result.
`ShellConfigManager.backupCatalystConfig()` is now copy-to-temp → verify → `replaceItemAt`
instead of remove-then-copy. Kept here as a pointer; delete once merged.

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

## 5. ~~Environment-health false negatives~~ — SHIPPED 2026-07-30 (issue #10)

`NodeDoctor.presentButNotWorking(_:)` now raises a critical issue when `command -v npm` succeeds
but the binary exits 127. The underlying cause turned out to be partly ours: `checkAvailability`
probed with `useLoginShell: true` while `run()` used a bare `zsh -c`, which sources no profile —
so npm was reported broken on machines where it was fine. Both probes now use a login shell, and
the empty `catch {}` that hid the whole thing reports instead.

**Still open, generalised:** the same resolves-but-fails-to-execute probe would be worth extracting
into a shared `ToolProbe` helper. The pattern is duplicated across `NodeDoctor`, `ConflictDoctor`,
`GitDoctor` and `JavaDoctor`, and seven more empty `catch {}` blocks remain in `Checkers/` — see
`cache/HANG-SWEEP-2026-07-30.md` §7.

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

## 6b. Dry-run preview for Snapshot restore — SCOPED 2026-08-08 (issue #27, milestone v1.5)

v1.4 added a confirmation naming the sections a restore will write, and escalating its wording
when the shell profile is among them. That says *what* will be touched; it still doesn't show
*what will change*.

Wanted: a **Dry run** action beside Restore that executes nothing and renders the plan — every
action that would run, grouped by section in `restoreOrder`, each with its exact command, and for
`~/.zshrc` a real **diff** of current vs incoming, since that is the only destructive write in
the flow. Skipped items should show their reason.

Smaller than it looks: `RestoreAction.commandPreview` is already populated and documented as
"the exact command shown in dry-run"; `alreadySatisfied` / `blockedReason` already carry the skip
reasons; `SnapshotViewModel.pendingKinds` already computes the affected sections. Even
`SnapshotView.previewBar`'s own doc comment already says "choose items, then Dry run or Restore"
— the affordance was designed and never built, and that comment is currently stale. The missing
pieces are a shell-profile diff renderer and a preview sheet.

## 6c. Orphanage Phase 2 — system-scope removal (blocked on the privileged helper)

Phase 1 shipped user-scope only: everything under `~/Library` is scanned, matched and
quarantined without any elevated rights. System-scope items are **detected and displayed
read-only** (`LeftoverCategory.isUserRemovable == false`), which is as far as it can go today.

**The blocker is not Orphanage.** `PrivilegedHelper/` has `main.swift`,
`CatalystHelperTool.swift` and the launchd plist on disk, and `PrivilegedHelperManager` +
`CatalystHelperProtocol` are already in the app target — but `project.pbxproj` has **no
`CatalystHelper` target**, so `SMAppService.daemon(plistName:)` fails at runtime. Per
`PrivilegedHelper/README.md` the target has to be created in the Xcode GUI, and 12.47 records
that hand-editing `pbxproj` to add or remove a *target* corrupted the project twice. So step
one is GUI work, not code.

Once the helper exists, Phase 2 is:
- `/Library/LaunchDaemons` + `/Library/LaunchAgents`: `launchctl bootout system/<label>` then
  quarantine the plist through the helper. `OrphanCleanupService.unloadAgent` already does the
  `gui/<uid>/<label>` half for user agents — mirror it for system scope.
- `/Library/PrivilegedHelperTools`: **verify the code signature against the vendor it claims**
  before offering removal; anything unsigned or mismatched goes to manual review, never into a
  one-click sweep.
- `pkgutil --forget <package-id>` after a quarantine commits (root-only), plus surfacing
  receipts whose payload is gone. Note receipts are useless as a completeness check for
  MAS-installed apps — those use Containers and never appear in `pkgutil`.
- Route every one of these through the helper's XPC interface. **Never `sudo` shell-out** (2.1).

**Also deferred:** the 30-day purge only runs when the user opens the screen and taps *Purge
Expired*. A background sweep on launch would need `AppViewModel.fullRefresh()` wiring (1.4) and
a decision about purging without the user present — which, for a feature whose entire premise is
recoverability, deserves an explicit opt-in rather than a default.

---

## 7. Prior deferrals (carried, unchanged)

- Swift-6 `timeoutTask` concurrency warning.
- `fullRefresh()` has no re-entrancy guard (low risk; guarded in practice by brew lock + busy
  flags).
- Migrate's `PythonManager` doesn't check Dashboard `isInstallingPython` (same guards;
  practically impossible to hit).
