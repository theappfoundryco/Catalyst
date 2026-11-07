# HANDOFF

Where the project stands, how it is put together, how to run the tests, and what has not been verified yet. Read it before you start, and update it when you finish something.

## What this is

A single-binary command line tool that diagnoses and cleans dev environments on macOS and Linux. It replaces the Catalyst Mac app (Swift, SwiftUI), whose history was deliberately not carried over. Version 0.1.0 is the first release of this tool, and the public history starts there.

## Architecture map

```
cmd/catalyst/         entry point
internal/cli/         the commands: doctor, sweep, undo, log, status, disk, battery, net, ports, startup, ssh, path, config, legacy, update, uninstall
internal/ui/          everything about how output looks: colour, step, menu, banner, bars, plain mode
internal/kit/         Kit's sprites and half-block drawing
internal/session/     bare `catalyst`: the home list on the terminal's separate screen, scrolling results, the only place Kit is drawn
internal/run/         runs programs: argv only, own session, no stdin, time limit, fixed locale. Fake for tests
internal/host/        the machine: env from a login shell, plus parsers for df, vm_stat, pmset, lsof, ss, smartctl and more
internal/doctor/      engine: runs checks at once, four result states, score
internal/doctor/checks/   one file per check
internal/sweep/       rules table, walker, git safety, real sizes
internal/clean/       app caches and logs outside projects, open-app detection, admin areas explained
internal/space/       where the disk goes: home, apps, macOS's own volumes, named landmarks
internal/trash/       moves to the system Trash, by rename only (macOS and the freedesktop spec)
internal/journal/     records every change, for undo and log
internal/state/       settings and health history, under the XDG folders
internal/shellpath/   one marked PATH line in a startup file, removable
demo/                 records README images from an invented machine
test/                 get.sh against a local server
get.sh                the one-line installer
scripts/              guards, release build, release notes
```

Ideas that hold it together:

- **One way to change anything.** Fixes are data, so the preview cannot disagree with what runs. Removals go through `internal/trash`, and every change through the journal.
- **One way to run anything.** `internal/run`. See the running-programs section of the anti-patterns.
- **One way to draw anything.** `internal/ui`. No command prints on its own.
- **Parsers are plain functions over text**, so both systems test anywhere.
- **One list, no prompt.** Bare `catalyst` is arrows and Enter only. Rows are rebuilt after every command, so Undo can say what it would reverse, or sit dimmed and skipped when there is nothing. Anything with arguments belongs in the shell. Commands reach the home screen through `App.reaction`, and offer next steps through `session.Outcome`.
- **Two dependencies**, both from the Go project.

Files on a person's machine: the program in `~/.local/bin`, `~/.local/state/catalyst` (health history, journal, last sweep), `~/.config/catalyst/config.json`, and at most one marked line in a shell startup file.

## Run the tests

```bash
make test     # everything: recorded output, real git repositories, temporary folders. Touches nothing real
make check    # format, vet, data guard, personal values
make build    # ./catalyst
make demo     # re-record the README images (see demo/shots.py; review them first)
```

## Cut a release

```bash
# on main, after the change is merged
git switch main && git pull --ff-only origin main
git log --oneline "$(git describe --tags --abbrev=0)"..HEAD   # read every subject: these are the release notes
git tag v0.2.0 && git push origin v0.2.0
```

The tag starts `.github/workflows/release.yml`, which tests, builds four archives and `SHA256SUMS`, and publishes the GitHub Release. `get.sh` and `catalyst update` both follow the newest release. If Actions is ever down: `scripts/release-build.sh v0.2.0`, then `gh release create` by hand.

## What has been verified

As of 0.1.0, built and run on Apple silicon macOS 15 and ARM64 Linux containers:

- The full test suite on macOS, and on Linux as both a normal user and root.
- Every read-only command on a real Mac, and on Debian, Fedora, Alpine and Ubuntu containers with almost nothing installed. `doctor` found real problems on the Mac.
- A real sweep, `log`, `undo` and `path add` and `remove` as a normal user in an Ubuntu container, against real git repositories: it took only the idle ignored folder and left a tracked `build/` and an active project alone. The freedesktop Trash layout was checked by eye.
- The home list, `More`, the keys under each result, the sweep menu and questions, driven on a real pseudo-terminal at 30 by 10, 50 by 20, 88 by 24, 100 by 30 and 120 by 12. Keys reach a menu opened from the list.
- `get.sh` piped into `sh` on a real pseudo-terminal: it asks about PATH, clears the window, opens the list, takes the keyboard, and returns to the shell with its last note.
- A real sweep, undo from the key under its result, and sweep again as a normal user in an Ubuntu container, driven through the list.
- A real clean in an Ubuntu container: moved to the Trash, emptied from it on request, space freed, and Undo stopped offering what was emptied.
- Stopping a real port from the chooser in an Ubuntu container: asked first, stopped with TERM, the list shrank.
- `space` and `clean --dry-run` read-only on a real Mac. The separate screen opening and closing, checked in the raw output, including a Ctrl-C while a question waits.
- A rename into and out of `~/.Trash` on a Mac whose terminal has no Full Disk Access.
- `get.sh` against a local server, including refusing a bad or missing checksum.

## What has not been verified

- **Intel Macs and x86 Linux.** The archives build, but the checks have run only on Apple silicon and ARM64 Linux containers.
- **A real systemd machine, and a real laptop on Linux.** Containers have no systemd, so failed units, user services and Linux batteries are covered by recorded output only.
- **`smartctl`.** Parsed from recorded output. Not installed on the development Mac.
- **The startup commands.** `startup disable` and `enable` have not been run for real, on purpose: they change a real machine.
- **`catalyst legacy` on a Mac with the old app installed.** The zshrc edit is tested. The Keychain and app paths have not run against a real install.
- **Other volumes.** Trash on an external disk (`.Trashes`, `.Trash-UID`) is written to the spec but has not run on a real second disk.
- **Fish and bash as the login shell.** zsh and sh have run. Fish has not.
- **Notarized macOS downloads.** Not done. `curl` and Homebrew do not quarantine, so `get.sh` is fine. A DMG or browser download would need it.

## Known gaps and open work

- No Homebrew tap yet. Add `theappfoundryco/homebrew-tap` and a formula when there is a reason to.
- Login items on macOS are not listed, because reading them either opens a permission prompt or needs root. `catalyst startup` points at System Settings.
- WSL2 is refused politely by `get.sh`. Windows is out of scope.
- The list takes no arguments, so `startup disable`, `path add` and `sweep --deep` are shell only.
- `clean` on a real Mac has only run as `--dry-run`, by design: it would change the maintainer's machine. Its Mac rules are tested with recorded `lsappinfo` output.
- `doctor --fix` applies one fix at a time on purpose. A "fix everything safe" mode could come later.
- Snapshot and migrate from the Mac app is parked. Brewfile, chezmoi and mise cover it well.

## Good first things

Run `catalyst doctor` on your own machine and write down everything that surprises you, especially anything wrong. A wrong result, with the raw tool output, is the most useful issue there is. Then pick a check idea from the issues, or a Linux distro difference you can test and nobody else can.
