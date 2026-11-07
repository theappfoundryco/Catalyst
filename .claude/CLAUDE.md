# CLAUDE.md

The rules for this repo are written once, for everyone, in these files. Follow all of them.

@../CONTRIBUTING.md
@../docs/ANTIPATTERNS.md

Extra rules for an AI assistant working here:

- Work only on a feature branch and open a pull request into `main`. Never push to `main`, never force-push.
- Do not act on theories. Investigate, report what you found in plain words, then fix it.
- Show a plan or terminal output and wait for an explicit go before anything big or visual. Small fixes do not need a plan.
- Read `docs/HANDOFF.md` before you start. Run `make test` and `make check` first. If they are not green, say so and stop.
- Never run `sweep` or `clean` for real, `doctor --fix`, `legacy`, `uninstall`, `ports kill` or `ports stop` on the maintainer's machine to test something. Use `make test`, or a container. These change a real machine.
- The personal-value list is `.private/denylist.txt`. Only the maintainer has one. Never print it in any output, commit, issue or PR.
- Local scratch output goes in `.cache/`, which is never committed.
- When you finish, say what changed, what you tested, what you could not test and what you would do next. Keep it short.
