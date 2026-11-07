# Security policy

## Reporting a problem

Please report security problems privately, through GitHub: open the **Security** tab of this repository and choose **Report a vulnerability** ([direct link](https://github.com/theappfoundryco/catalyst/security/advisories/new)). Do not open a public issue, discussion or pull request for it.

Include what you found, how to reproduce it, and what it could let someone do. You will get a reply as soon as the maintainers can manage, and a fix or a clear answer after that. Please give us a reasonable time to fix it before you share details.

## What is in scope

- Anything that removes, moves or changes files: `catalyst sweep`, `undo`, `doctor --fix`, `legacy`, `uninstall`. Above all, sweep offering something that is not disposable
- Anything that stops or starts processes: `catalyst ports kill`, `catalyst startup`
- The installer and the update flow (`get.sh`, `catalyst update`), including checksum checks
- A secret's value appearing in any output, log, journal or `--json`
- Running a program with attacker-controlled input, or reading attacker-controlled files in an unsafe way

## What is not in scope

- Problems that need someone to already have full access to your machine or your account
- A check missing a problem. Open a normal issue for that
- Bugs in the tools Catalyst reads from (`git`, `smartctl`, `lsof`)
- Reports from automated scanners with no working proof

## Supported versions

Only the newest release and `main` get fixes. The old Catalyst Mac app is no longer maintained.
