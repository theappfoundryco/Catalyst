# Contributing

Improvements from people who fix dev machines for a living, or just their own, are welcome. Small, focused pull requests are the easiest to review and the fastest to merge. If you are not sure something fits, open a [discussion](https://github.com/theappfoundryco/catalyst/discussions) first. Be kind: this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Good first pull requests

- **A check.** One file in `internal/doctor/checks`, with a test. See [docs/ADDING_A_CHECK.md](docs/ADDING_A_CHECK.md).
- **A sweep rule.** One line in the table in `internal/sweep/sweep.go`.
- **A Kit mood.** A new grid in `internal/kit/sprites.go`.
- **A test from your machine.** If a check got your system wrong, the raw output of the tool it reads makes a perfect test case.

## Set up

You need Go and git. Nothing else, and nothing touches your real setup: tests use recorded output and temporary folders.

```bash
git clone https://github.com/<your-username>/catalyst.git   # your fork
cd catalyst
make hooks     # once; also: brew install gitleaks
make test
```

## Flow

1. Fork this repository on GitHub and clone your fork.
2. Run `make hooks` once. Every commit is then checked for env files, keys, emails and public IP addresses.
3. Make a branch: `git switch -c fix/short-name`. Never push to `main`.
4. Make the change, then run `make check` and `make test`.
5. Push to your fork and open a pull request into `main`. CI runs the same checks on macOS and several Linux systems, and the maintainer reviews every change.

## Commits and pull requests

- One task per branch, kept small.
- Commit messages and PR titles start with a prefix: `feat:` for something new, `fix:` for a bug, `security:` for a security fix, and `docs:`, `refactor:`, `test:`, `ci:` or `chore:` for the rest. Then a short sentence in the imperative.
- These sentences are the release notes. Security, New and Fixed come straight from them. The other prefixes are left out. So write the sentence for the person using Catalyst: `fix: stop reporting a stub java as installed on a new Mac`, not `fix: java bug`.
- Do not add `Co-Authored-By` lines or tool attribution to commits or PR descriptions.
- Fill in the pull request template. Say what you could not test (another OS, real hardware). That is as useful as what you did.
- Anything that changes how Catalyst looks or behaves should come with a short plan or terminal output first.

## Rules

**Never leak**
- No personal values in code, tests, docs or screenshots: names, places, emails, hostnames, IPs. Use `example.com`, `192.168.1.20`, `10.0.0.5` and obviously fake people (Alex).
- Recorded tool output goes through you first: remove your username, serial numbers and hostnames.
- Never commit with `--no-verify`. If a check fails, fix the cause.

**Safety**
- Reading never needs permission. Changing always does. A change is shown first, goes through the journal, and has a way back or says it has none.
- Removing anything goes through `internal/trash`. No `os.RemoveAll` on a person's files, ever.
- Programs run through `internal/run`: argv only, never through a shell.
- Never print, log or put in `--json` the value of a secret. Counts only.
- Catalyst never handles a password. If something needs root, print the command for the person to run.
- No downloaded code, no telemetry, no network calls unless the person asked for that command.

**Behaviour**
- A check that could not run reports that. Only a check that ran can pass.
- Missing tools must never crash anything. A check says skipped with a reason. Never show a stack trace.
- Do not add a dependency without a clear need. Today there are two, both from the Go project (`golang.org/x/term` and `x/sys`).
- Do not grow beyond what this tool is for. It diagnoses dev environments and frees space safely: build artifacts, and caches that rebuild themselves. It does not install or manage your packages, and it never deletes someone's data or the system's.

**Style**
- No em dashes anywhere (code comments, docs, output, commits). Use commas or parentheses.
- Times shown to people are 12-hour (4:30 AM).
- Output goes through `internal/ui`, in plain words. Comments explain why, not what.
- Match the surrounding code: naming, comment density, idiom.

More: [docs/ANTIPATTERNS.md](docs/ANTIPATTERNS.md) lists mistakes that have already happened once, and [docs/HANDOFF.md](docs/HANDOFF.md) describes how the project is put together and what is not yet verified.
