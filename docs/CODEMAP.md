# Code map

Where everything in Catalyst lives, how a command travels through the code, and why it is built the way it is. Written against `overnight/2026-11-21`, which holds `main` plus every open pull request from that night. Parts that are not on `main` yet are marked with their PR.

About 15,500 lines of Go (20,300 with tests) in 22 packages, two dependencies (`golang.org/x/term`, `golang.org/x/sys`), one static binary.

## The one-minute version

- **One binary, one list.** `catalyst` with no arguments opens a list on the terminal's separate screen (`internal/session`). With a command name, it runs that command and exits (`internal/cli`).
- **Read the machine the way a new terminal sees it.** `internal/host` asks a login shell for PATH and a few variables, then every check reads from that.
- **Doctor is a registry of small checks** (`internal/doctor/checks`, one file each) run at the same time, ending in one of four states and a score.
- **Every change goes one way:** shown first as data (`doctor.Fix`), then through the Trash (`internal/trash`) and the journal (`internal/journal`), so Undo can reverse it.
- **Every program runs one way:** `internal/run`, argv only, its own session, no stdin, a time limit, `LC_ALL=C`. Root steps use `run.Attached`, so sudo asks for the password on the terminal and Catalyst never sees it.
- **Every pixel is drawn one way:** `internal/ui`. No command prints on its own.
- **Parsers are plain functions over text**, so macOS parsing is tested on Linux and the other way round.

## How a command runs

```
cmd/catalyst/main.go            blank-imports internal/doctor/checks (their init() registers each check)
  └─ cli.Main(os.Args[1:])      internal/cli/cli.go
       ├─ newApp()              host.New() + state.New() + ui.New() + journal.New()
       └─ dispatch(args)        --no-color, --version, --help; no args at a terminal → a.session()
            └─ commands()       the table: name, usage, help, func(a *App, args) int
                 └─ cmdDoctor   internal/cli/doctor.go
                      ├─ a.E.LoadShell()            host.go: login shell → PATH, JAVA_HOME, NVM_DIR, ShellVars
                      ├─ doctor.Start(e, All())     doctor.go: one goroutine per check, each with a 45 s limit
                      ├─ showScan → Wait(i)         prints groups in fixed order as checks finish
                      ├─ doctor.Mute / Score / Count
                      ├─ state.Record + SaveSnapshot  health history, and the snapshot `changes` reads (#63)
                      └─ applyFixes                 only with --fix, each shown and asked
```

Bare `catalyst` instead calls `session.Run` with `homeItems` (the list), `header` (Kit, greeting, health dot) and a `Run` callback that calls `dispatch` again. Commands do not know whether they run in the list or in a shell, except through `a.inSession` and `a.outcome` (what keys and next steps the list should offer).

**Exit codes** (`internal/cli/cli.go`): 0 fine, 1 issues found, 2 usage error, 3 a check could not run.

## Packages

### `cmd/catalyst`
`main.go`: calls `cli.Main` and exits with its code. The blank import of `internal/doctor/checks` is what registers every check.

### `internal/cli`: the commands
One `App` (`cli.go`) carries the UI, the environment, the state store and the journal. Each command is a `cmdX(a *App, args []string) int`.

| File | What is in it |
|---|---|
| `cli.go` | The `App` type, the command table `commands()`, `dispatch`, the home list `homeItems()`, `emit` for `--json` |
| `doctor.go` | `doctor`: the scan display, the verdict line, `--fix`, `--all-safe` (#70), `--mute` and `--unmute` (#69), `--json` |
| `guide.go` | The guide behind each finding (Enter on a row): why it matters, where, numbered steps, keys. Per-platform steps: `firewallSteps`, `rootCmd` (#45) |
| `actions.go` | Shared keys and steps: edit a file, reveal, copy, `sudoReady` and `asRoot` (sudo through the terminal; run directly when already root, #45) |
| `helpers.go` | Helpers (Homebrew, smartmontools) and the first-run `setup`. `smartInstall` picks the distribution's package manager (#45) |
| `machine.go` | The machine screens: status details, disk, battery, net, ports, startup, ssh, path (`pathSource`, `NamesFolder` (#59), shadows), config |
| `status.go` | `status` and the home header, with the Platform and Packages rows (#45) |
| `sweep.go`, `clean.go`, `space.go`, `system.go` | The space commands' screens. `system.go` `reclaim` runs each area's way out: Trash, the owner's command, Settings, or sudo |
| `self.go` | `update`, `uninstall`, `legacy` (the old Mac app's leftovers) |
| `rcedit.go` | Editing a startup file safely: back up, edit, have the shell parse it, restore on failure |
| `why.go` (#60) | `why NAME`: every copy on PATH, the startup line that adds its folder, its manager, its architecture, whether it runs |
| `project.go` (#61) | `project [DIR]`: screen for `internal/project` |
| `report.go` (#62) | `report`: a Markdown summary, with `Scrub` taking out home, user and machine names |
| `changes.go` (#63) | `changes`: the daily snapshot (`snapshot`) and `Diff` in words |
| `completion.go` (#64) | `completion bash|zsh|fish`, written from the command table |

### `internal/host`: the machine
| File | What is in it |
|---|---|
| `host.go` | `Env`: OS, arch, home, shell, the `run.Runner`, `Look`, and the PATH a new terminal gets (`Entries`). `LoadShell` asks a login, interactive shell, with markers so startup-file chatter is ignored. `SafeTool` refuses Apple's stub programs. `Var` (#49) |
| `platform.go` (#45) | `Platform`: os-release with the `/usr/lib` fallback, family from `ID` then `ID_LIKE`, libc, init from `/proc/1/comm`, container and WSL signs, image-based systems, package managers (program and database both). `Install` gives the right install command per family, `Brew` says whether Homebrew can work here, `Service` gives systemctl or rc-service. Read once per run under a mutex, never stored |
| `exec.go` (#60) | `ExecKind`: what a program is built for, from its first bytes (ELF, Mach-O, universal, script) |
| `read.go` | Parsers: `df` on both systems, memory (`vm_stat`, `/proc/meminfo`), load, battery (`pmset`, `ioreg`, `/sys`), listeners (`lsof`, `ss`) |
| `more.go` | Uptime, memory pressure, heat, top processes, Wi-Fi, VPN tunnels, DNS, proxy |
| `items.go` | Startup items (launchd plists, systemd units), private key files found by content, SSH keys |
| `drive.go` | Drive health from `smartctl` |

### `internal/doctor` and `internal/doctor/checks`
`doctor.go` is the engine: `Result` (check, group, state, severity, title, hint, fix, muted), the four states (`pass`, `issue`, `skipped`, `error`), `Fix` kinds (`chmod` and `trash` can be undone; `run` cannot and is shown first; `manual` is for the person), `Register`, `Start`/`Wait`, `Score` (decay: critical 0.7, warning 0.9, note 0.98, so a bad machine and a terrible one do not both read 0), `Count`, `Mute` (#69).

Each check is one file that calls `d.Register` from `init`:

| Group | Checks (ID: file) |
|---|---|
| Your shell | `shell.syntax` shell_syntax, `shell.startup` shell_startup, `shell.path` path_entries, `shell.files` open_files (#55), `shell.rosetta` rosetta (#54) |
| Your tools | `tools.run` tools_run, `tools.build` build_tools (+ Xcode path and licence, #53), `tools.git` git_identity, `tools.gitsetup` git_setup (#56), `tools.python` python_setup, `tools.pip` pip_system (#58), `tools.node` node_setup, `tools.java` java_setup, `tools.brew` brew_setup, `tools.managers` version_managers (#51), `tools.network` network_env (#49) |
| Keys and secrets | `keys.ssh` ssh_perms, `keys.history` history_secrets, `keys.firewall` firewall |
| This machine | `machine.disk` disk_free, `machine.memory` memory_swap, `machine.docker` docker_state (+ why it cannot be reached, #52), `machine.startup` startup_items, `machine.linux` linux_system (+ restart_waiting, #50), `machine.caches` caches, `machine.watchers` file_watchers (#48), `machine.clock` clock_sync (#57) |

### `internal/run`: running programs
`Real.Run` and `RunIn` (#61, a folder to start in): `exec.CommandContext`, `Setsid` (its own session, so an interactive shell cannot freeze on SIGTTOU), no stdin (a hidden prompt fails instead of waiting), `WaitDelay` (a daemon holding the pipe cannot hang it), `LC_ALL=C`. `Fake` answers from a table keyed by the command line, which is how every check is tested. `Attached` gives a program the terminal, for sudo and installers only.

### `internal/session`: the list
`session.go`: the home list, the screen stack (Esc goes back to where a key came from), rows with keys (`Item`, `Action`, `Outcome`), live refresh, the one place Kit is drawn. `screen.go`: the alternate screen and raw mode. Keys are read with `select`, never by a background reader, which once stole keys from a command's own menu.

### Space: `internal/sweep`, `internal/clean`, `internal/space`, `internal/sysdata`, `internal/trash`
- **`sweep`** (build artifacts in projects): `Rules` is the table, one line per folder kind, with `Needs` (a marker beside it, patterns allowed since #65), `Inside`, `Cost`, `NeedsGit`. `Scan` walks, `git.go` asks git both `check-ignore` and `ls-files`, `Activity` takes the newest of git state and source files, `DirSize` counts each inode once. `Globals` are caches outside projects.
- **`clean`**: app caches and old logs that rebuild themselves, skipping open apps (`Running`).
- **`space`**: where the disk goes, with named landmarks and macOS's own volumes (`ParseAPFS`).
- **`sysdata`**: System Data area by area, each with a `Way`: Trash, Owner (the tool's own command, such as `go clean -modcache` (#66)), Settings, Root (sudo, such as `dnf autoremove` (#67)) or Locked.
- **`trash`**: moves to the system Trash by rename only (macOS and the freedesktop spec), so a move either happens or does not.

### State: `internal/journal`, `internal/state`, `internal/shellpath`
- **`journal`**: one JSON line per change, grouped by batch, read by `undo` and `log`.
- **`state`**: `config.json` (name, mascot, declined helpers, muted checks (#69)), health history (one per day, 90 days), snapshots (#63), the last sweep. Under the XDG folders.
- **`shellpath`**: the one marked PATH line Catalyst may add to a startup file, and its removal.

### `internal/project` (#61)
`Check` reads a repository: `Pins` (`.nvmrc`, `.node-version`, `.python-version`, `.ruby-version`, `mise.toml`, `.tool-versions`), versions asked from inside the folder so shims answer for it, `Matches`, the Go toolchain rule, lockfiles and `packageManager`, `.env` names only (`EnvKeys`), `core.hooksPath`.

### `internal/ui` and `internal/kit`
`ui.go`: colour (off in pipes and with `NO_COLOR`), width fitting (`Fit`, never cutting inside brackets), the result lines (`Ok`, `Note`, `Warn`, `Stop`, `Skip`, `Hint`), `Ask`. `menu.go`: the sweep and system pickers. `step.go`: spinners. `style.go`: bars and the health colours. `kit` draws Kit from sprites with half blocks.

### Outside `internal`
- `demo/`: the README images, from an invented machine (`make demo`). Never a real one.
- `scripts/`: `check-data-guard.sh`, `check-denylist.sh`, `check-personal.py` (the commit guards), `release-build.sh`, `release-notes.sh` (release notes from `feat:`, `fix:` and `security:` subjects), `distro-matrix.sh` (#45: every read-only command in one container image, as root and a user).
- `test/`: `get.sh` against a local server, including a bad checksum.
- `.github/workflows/`: `ci.yml` (leak scan, lint, tests on Ubuntu and macOS, five distributions as root and user) and `matrix.yml` (#47: 18 images, a real systemd, macOS Intel and Apple silicon, nightly).
- `get.sh`: the installer. Checks the checksum, installs to `~/.local/bin`, links `kit`, offers the PATH line.

## Rules, and where the code enforces them

| Rule | Where |
|---|---|
| A check that could not run is never a pass | the four states in `doctor.go`; `runOne` turns a panic or a timeout into `error` |
| One false alarm costs more than one miss | each check's thresholds, such as file watchers counting real use rather than the limit (#48), restart detection reading the tool's text, not its exit code (#50) |
| Never handle a password | `run.Attached` with sudo; `actions.go` `sudoReady` |
| No network unless asked | checks only read; the local proxy check connects to this machine only (#49); dnf runs cache-only (#50) |
| Removals are undoable or say so | `trash`, `journal`, `doctor.Fix` kinds, `sysdata.Way` |
| No secrets printed | `history_secrets` counts only; `project` reads `.env` names only; `report` scrubs names |
| Diagnose package managers, never wrap them | install commands are shown (`Platform.Install`), and run only for Helpers, on a yes |
| Kit only on the home screen | `session.go` draws it; `ui` turns it off in pipes, `--json`, `NO_COLOR` and narrow windows |

## How it is tested

- `make test`: every parser against recorded output from both systems, checks through `run.Fake`, sweep against real git repositories in temporary folders, the CLI with `ui.Plain`.
- `make check`: gofmt, vet, the data guard, the personal-value scan, gitleaks in the hooks.
- `scripts/distro-matrix.sh` in CI and locally, with the TUI driven on a pseudo-terminal with `pyte`.

## Questions you may be asked, and where the answer is

- **Why Go?** One static binary with no runtime to install, fast start (doctor takes about 1.4 s, mostly waiting on tools), easy cross-compiling to four archives (`scripts/release-build.sh`).
- **How do checks run at the same time without a slow tool holding everything up?** `doctor.Start` starts a goroutine per check; `runOne` has a 45 s limit and a `recover`; `showScan` prints in group order while waiting on each in turn.
- **How do you test macOS code on Linux?** The `run.Runner` interface: `run.Fake` replays recorded output, and parsers are pure functions (`host.ParseDFMac`, `ParseLsof`, `ParseOSReleaseFields`).
- **How does Catalyst know which distribution it is on?** `host.ReadPlatform`: os-release, then `FamilyOf(ID, ID_LIKE)`, then libc, init, container and package manager databases. It is cached in `Env.plat` behind `platMu`.
- **Why read PATH from a login shell?** A process's own PATH is rarely what a new terminal gets (an editor, a launchd job). `host.LoadShell` asks the shell itself, between markers.
- **What stops sweep from deleting someone's work?** Four tests in `sweep.Scan`: a marker file, not a symlink, git says ignored and tracks nothing inside, and 14 idle days by `Activity`.
- **How does undo work?** Every change writes a `journal.Entry` in a batch before or as it happens; `undo` reverses the last batch (rename back from the Trash, restore a mode, restore a startup file backup).
- **How is root handled?** `run.Attached("sudo", ...)` gives sudo the terminal. Catalyst never reads a password, and runs directly when it already is root (#45).
- **What did the platform work change?** `internal/host/platform.go`, and every place that assumed brew or apt: `build_tools.go`, `firewall.go`, `startup_items.go`, `linux_system.go`, `guide.go`, `helpers.go`.
