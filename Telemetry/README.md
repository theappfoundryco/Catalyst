# Telemetry

**Catalyst sends nothing.** No analytics SDK is linked, no crash reporter, no identifier, no
network call originates here. If you are auditing what Catalyst reports about you, this
directory is the complete answer, and the answer is "nothing".

This file explains why the directory still exists, and what the ignored config file is for.

## What's here

| File | What it is |
|---|---|
| `Telemetry.swift` | The facade. Every method is a no-op outside DEBUG. The one place a provider would ever be wired in. |
| `AppEvent.swift` | The catalog of events that *would* be worth recording. Carries a screen title and nothing else, deliberately. |
| `AppUserProperty.swift` | The catalog of user properties a provider would set. |
| `TelemetryProfile.swift` | Groups the above into the shape a provider would consume. |
| `GoogleService-Info.plist` | **Gitignored. Not in this repo.** See below. |

## Why the facade survives with nothing behind it

Firebase Analytics and Crashlytics were removed at v1.0. A closed-source Google SDK inside a
GPLv3 app whose pitch is auditability was a contradiction, and the README's claim that no
request carries anything about you could not stand alongside it.

Deleting the facade as well would have been worse. It would scatter `#if` checks and provider
calls back across ~170 files the day telemetry is ever wanted again, and every one of those call
sites is somewhere a file path, a package name, or a home directory can be logged by accident.
One choke point means the question "what does Catalyst send?" always has a single-file answer —
whether that answer is "nothing" or not.

The call sites that remain (`AppViewModel`, `CatalystApp`) are documentation of what would be
worth knowing — which screens get opened — without any of it leaving the machine.

See `docs/ARCHITECTURE.md` §49.6 and `docs/CODING_STANDARDS.md` 12.1 / 12.1b.

## The ignored `GoogleService-Info.plist`

`.gitignore` carries a rule for `GoogleService-Info.plist`. **This is a standing guard, not
evidence that a provider is active.** The file does not exist in a normal checkout and nothing
reads it.

It's there because that filename is the fixed convention Firebase's tooling emits, and Catalyst
is a **public** repository. Without the rule, the first `git add -A` after anyone wired up a
provider would publish the project's configuration permanently — and git history is not
something you can quietly walk back once a repo is public.

**If a real file ever exists, it is held by CODEOWNERS and distributed out of band.** It is not
in this repo, not in the sibling `updates/` or `data/` repos, and not in any release artifact
that isn't the signed app bundle itself. `/Telemetry/` is a CODEOWNERS-protected path, so any PR
touching this directory requires review from a code owner before it can merge.

A Firebase plist is not secret in the cryptographic sense — a copy ships inside every client
binary. But it identifies a project and its quotas, and publishing one in a public repo invites
abuse of both. Treat it as configuration you don't hand out, in the same class as an API
endpoint you'd rather not see scraped.

## If you are wiring up a provider

Implement the bodies in `Telemetry.swift` and nothing else changes; the public signatures are
the contract. Two rules, both learned the hard way in this codebase:

1. **Nothing user-identifying, ever.** No file paths, no package names, no email, no hostname.
   `AppEvent` deliberately carries only a screen title for exactly this reason. If you find
   yourself widening it, that's the decision to surface, not an implementation detail.

2. **Telemetry must never be able to break launch.** The previous provider called
   `FirebaseApp.configure()` from `start()`, which **hard-crashes when its config plist is
   absent** — so removing the config file would have killed the app on open rather than quietly
   disabling analytics. Whatever goes here must fail as a no-op. Test it by deleting the plist
   and launching.

Then, before your first commit:

```sh
git check-ignore -v Telemetry/GoogleService-Info.plist
```

That must print the matching `.gitignore` line. If it prints nothing, stop and fix the ignore
rule before you stage anything.

Finally, wiring up a provider **changes what the README promises users.** The root `README.md`
states plainly that Catalyst sends nothing, and carries an `analytics-none` badge. Both must
change in the same PR, in public, in a commit anyone can read. Shipping analytics while the
README still claims none is the one outcome this whole arrangement exists to prevent.
