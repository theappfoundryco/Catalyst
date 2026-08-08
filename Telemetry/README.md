# Telemetry

**Catalyst sends two events, and only for users who switched them on.** No crash reporter, no
identifier derived from your machine, and nothing at all from a build made from this repository. If
you are auditing what Catalyst reports about you, this directory is the complete answer.

## The whole payload

| Event | When | Contents |
|---|---|---|
| `app_open` | Once per launch | No parameters. |
| `feature_opened` | When you open a screen | One parameter: the screen title, from a fixed list of 25. |
| `brew_installed` | Once per launch (user property) | A single `true`/`false`. |

That is everything. The screen title is not a free-text field — it comes from
`AppViewModel.Screen.telemetryName`, a `switch` over a 25-case enum compiled into the binary, so no
call site can widen it into a file path, a package name, or anything a user typed. Widening
`AppEvent` is a privacy-policy change requiring a version bump and re-consent, not an implementation
detail.

## What's here

| File | What it is |
|---|---|
| `Telemetry.swift` | The facade, and the only file that links the SDK. |
| `AppEvent.swift` | The catalog of events. Reading this file top to bottom is the audit. |
| `AppUserProperty.swift` | The catalog of user properties. One entry. |
| `TelemetryProfile.swift` | Derives the above from live app state. |
| `GoogleService-Info.plist` | **Gitignored. Not in this repo.** See below. |

## Opt-in, and what that actually means here

`Telemetry.isEnabled` reads an explicit opt-in from `ConfigStore` that defaults to **absent**, and
absent means off. The stored value is a tri-state `Bool?` on purpose: `nil` is "never asked",
`false` is "asked and declined". Collapsing those to a plain `Bool` would make a decline
indistinguishable from a fresh install and re-prompt every user who said no, on every launch.

Nothing is buffered while disabled and nothing is replayed if you later opt in. A session that ran
without consent leaves no trace, because there was nowhere for it to be kept.

Two consequences worth knowing before you touch this code:

- **`FIREBASE_ANALYTICS_COLLECTION_ENABLED` must stay `NO` in `Info.plist`.** Firebase begins
  collecting at `configure()` otherwise — i.e. before consent — and an opt-in that starts by
  collecting is not one. `Telemetry.start()` is the only thing that ever turns collection on.
- **Opting out takes effect immediately**, within the running session, via
  `Telemetry.setCollectionEnabled(false)`. A user who flips the switch and watches events continue
  until they quit has been ignored, whatever the config file says.

## Why the facade exists

Firebase Analytics and Crashlytics were both removed at v1.0. Analytics returned at v1.4 as an
opt-in feature; **Crashlytics did not return**, and `nonFatal`, `breadcrumb` and `setKey` remain
deliberately empty. v1.4 added usage analytics only.

The facade is one choke point rather than provider calls across ~170 files, because every one of
those call sites is somewhere a file path, a package name, or a home directory can be logged by
accident. One file means the question "what does Catalyst send?" always has a single-file answer.

## The ignored `GoogleService-Info.plist`

`.gitignore` carries a rule for `GoogleService-Info.plist`. **The file is not in a normal checkout,
and a build without it sends nothing** — which is the correct behaviour for an open-source build, not
a degraded one.

It's ignored because that filename is the fixed convention Firebase's tooling emits and Catalyst is a
**public** repository. Without the rule, one `git add -A` would publish the project's configuration
permanently, and git history is not something you can quietly walk back once a repo is public.

**The real file is held by CODEOWNERS and distributed out of band.** It is not in this repo, not in
the sibling `updates/` or `data/` repos, and not in any release artifact that isn't the signed app
bundle itself. `/Telemetry/` is a CODEOWNERS-protected path, so any PR touching this directory
requires review from a code owner before it can merge.

A Firebase plist is not secret in the cryptographic sense — a copy ships inside every client binary.
But it identifies a project and its quotas, and publishing one in a public repo invites abuse of
both. Treat it as configuration you don't hand out.

### How it reaches the app bundle — NOT via Copy Bundle Resources

**Do not add this file to the Xcode target.** It is the obvious move and it breaks the repository.
`project.pbxproj` is tracked, so a resource reference ships a pointer to a file no contributor has,
and Xcode hard-fails every fresh clone with `Build input file cannot be found`. This was tried and
measured: the build fails outright, it is not a warning.

A Run Script build phase doesn't work either. `ENABLE_USER_SCRIPT_SANDBOXING = YES` denies reads of
undeclared paths (`Sandbox: cp deny(1) file-read-data`), and declaring the plist as an input
reintroduces the missing-file error. Declaring the parent *directory* doesn't help — the sandbox
grants only exact declared paths.

So it is injected by `Scripts/cut_release.sh` after `xcodebuild -exportArchive`, and the app is
re-signed (`--force`, **not** `--deep` — nested Sparkle.framework is already correctly signed, and
hardened runtime plus entitlements must be reasserted or notarization rejects the bundle).

**Consequence: analytics exist only in official signed releases.** Dev builds and builds from a
public checkout have no config and send nothing. That is the intended property, not a gap. To test
locally, copy the plist into the built `.app` by hand:

```sh
cp Telemetry/GoogleService-Info.plist \
  "$(ls -d ~/Library/Developer/Xcode/DerivedData/Catalyst-*/Build/Products/Debug/Catalyst.app)/Contents/Resources/"
```

Before your first commit in this directory:

```sh
git check-ignore -v Telemetry/GoogleService-Info.plist
```

That must print the matching `.gitignore` line. If it prints nothing, stop and fix the ignore rule
before you stage anything.

## If you are changing the provider

Implement the bodies in `Telemetry.swift` and nothing else changes; the public signatures are the
contract. Three rules, all learned the hard way in this codebase:

1. **Nothing user-identifying, ever.** No file paths, no package names, no email, no hostname, and
   no device identifier. `Telemetry.setUser(id:)` is deprecated and empty: it used to pass
   `IOPlatformUUID`, a permanent machine-unique value that is personal data under GDPR, that §4 of
   the privacy policy promises Catalyst does not collect, and that a screen count has no use for.

2. **Telemetry must never be able to break launch.** The no-argument `FirebaseApp.configure()`
   **hard-crashes when its config plist is absent** — so shipping that form would turn "cloned the
   repo" into "app crashes on open". `start()` resolves `FirebaseOptions` by path and returns
   quietly when the file isn't there. **Test it by deleting the plist and launching.**

3. **The provider is loaded behind `#if canImport`.** The Swift compiles with or without the SDK
   linked, so a checkout that hasn't resolved packages still builds.

Finally, changing what is collected **changes what the project promises users.** The root
`README.md` describes the payload and carries an `analytics-opt-in` badge; the published privacy
policy (§6) enumerates every event. Both must change in the same PR, in public, in a commit anyone
can read, with a `LegalConfig.bundledPrivacyVersion` bump so existing users re-consent. Shipping a
wider payload while the policy still describes the old one is the one outcome this whole arrangement
exists to prevent.

See `docs/ARCHITECTURE.md` §49.6 and `docs/CODING_STANDARDS.md` 12.1 / 12.1b / 12.1c.
