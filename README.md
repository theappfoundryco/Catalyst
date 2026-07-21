<div align="center">

# Catalyst

**Mission control for a Mac development environment.**

Manage Python and Homebrew, keep an eye on the machine, and clean up after both —
without memorising another set of terminal incantations.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014.6%2B-lightgrey.svg)](#requirements)
[![Latest release](https://img.shields.io/github/v/release/theappfoundryco/Catalyst?label=release)](https://github.com/theappfoundryco/Catalyst/releases/latest)

[Download](https://github.com/theappfoundryco/Catalyst/releases/latest) ·
[Report a bug](https://github.com/theappfoundryco/Catalyst/issues/new?template=bug_report.yml) ·
[Request a feature](https://github.com/theappfoundryco/Catalyst/issues/new?template=feature_request.yml)

</div>

---

Catalyst is a native macOS app, written in SwiftUI. It has no account, no subscription, and no
server. It was a paid product until v1.0; it is now free and open source under the GPLv3.

## Features

**Packages and environments**

| | |
|---|---|
| **Virtual environments** | Create, inspect, and remove venvs without touching a terminal |
| **pip packages** | Installed and outdated lists, one-click upgrades, bulk install from `requirements.txt` |
| **Homebrew** | The same for formulae and casks |
| **Popular packages** | A curated starting point when setting up a new machine |

**Developer workflow**

| | |
|---|---|
| **SmartShortcuts** | Curated shell functions, installed and managed through a UI that validates before writing |
| **Aliases** | Add, edit, and remove shell aliases safely |
| **PATH editor** | See what's actually on your `PATH`, in order, and fix it |
| **Git graph** | A readable commit graph for any local repository |
| **Terminal time travel** | Search and re-run anything from your shell history |
| **SSH keys** | Inventory what's on the machine, and spot bad permissions |

**Health and maintenance**

| | |
|---|---|
| **Dr. Catalyst** | One sweep across the whole environment, with plain-language findings |
| **Cruft Sweeper** | Find and remove build artifacts, caches, and orphaned dependencies |
| **Vitals** | Disk and battery health, network diagnostics, startup items |
| **Snapshot & migrate** | Capture an entire setup and rebuild it on another Mac |

## Requirements

macOS 14.6 or later. Universal binary (Apple silicon and Intel).

## Install

Download the latest signed and notarized build from
[Releases](https://github.com/theappfoundryco/Catalyst/releases/latest), unzip it, and
drag `Catalyst.app` to `/Applications`.

Updates arrive in-app via [Sparkle](https://sparkle-project.org) — Catalyst downloads them in
the background and shows a *Relaunch to update* badge in the sidebar.

## Building from source

```sh
git clone https://github.com/theappfoundryco/Catalyst.git
cd Catalyst
open Catalyst.xcodeproj
```

Build and run. There is no backend to stand up, no API key to obtain, and no configuration
step. Sparkle is the only dependency, resolved automatically via SPM.

A privileged helper tool handles the few operations that require elevation. It is installed on
first use with your explicit approval, and its source is in [`PrivilegedHelper/`](PrivilegedHelper).

## Privacy

**Catalyst sends nothing.** There is no analytics SDK, no crash reporter, no account, and no
identifier. Firebase Analytics and Crashlytics were removed at v1.0.

The app makes exactly two kinds of network request, both `GET`s for static files you can open
in a browser yourself:

| Request | Purpose |
|---|---|
| `data.theappfoundry.co/catalyst/…` | Package catalogs shown in the app |
| `updates.theappfoundry.co/catalyst/appcast.xml` | Sparkle update feed |

[`Telemetry/Telemetry.swift`](Telemetry/Telemetry.swift) remains as a single choke point where
a provider *could* be wired in; every method in it is a no-op outside debug builds. It's kept
deliberately — one file that answers "what does Catalyst report about me?" is easier to audit,
and harder to get wrong, than provider calls scattered across 170 files. If that ever changes,
it changes there, in public, in a commit you can read.

## Architecture

```
Catalyst/          App entry, Info.plist, legal consent
Views/             SwiftUI screens
ViewModels/        Screen state and orchestration
Services/          Shell execution, brew, pip, git, snapshot, privileges
Checkers/          Dr. Catalyst diagnostic modules
Utilities/         Process runner, input sanitising, networking
PrivilegedHelper/  Privileged helper tool (XPC)
Scripts/           Release tooling
docs/              Architecture, conventions, and the release runbook
```

Deeper documentation lives in [`docs/`](docs):

| Document | What it covers |
|---|---|
| [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) | How the pieces fit together, plus a full feature reference |
| [`Formrules.md`](docs/Formrules.md) | Conventions and invariants this codebase holds to |
| [`toAvoid.md`](docs/toAvoid.md) | Specific mistakes made here before, and what to do instead |
| [`RELEASING.md`](docs/RELEASING.md) | Release and hosting runbook |

[`toAvoid.md`](docs/toAvoid.md) is worth reading before your first change. It's a list of things
that looked correct, shipped, and broke — each with the rule that came out of it.

Code comments cite these by name — `// Formrules 12.27`, `// toAvoid Rule 1` — so when you hit
one while reading, that's the file it means.

## Contributing

Issues and pull requests are welcome. For anything substantial, open an issue first describing
what you'd like to do — it saves you building something that conflicts with work in flight.

Two things to know:

1. **This codebase documents *why*, not *what*.** Comments explaining a non-obvious decision, a
   race that was fixed, or a trap already fallen into are load-bearing. Please write them in the
   same spirit, and don't delete one without understanding what it protected.
2. **Catalyst runs against a real machine.** It uninstalls packages, edits shell config, and
   performs privileged operations. "It builds" is not testing — say what you actually ran.

## License

[GNU General Public License v3.0](LICENSE).

You can use, study, modify, and redistribute Catalyst. If you distribute a modified version, it
has to stay under the GPL with its source available. What was built in the open stays open.

<div align="center">
<sub>Built by <a href="https://theappfoundry.co">The App Foundry</a></sub>
</div>
