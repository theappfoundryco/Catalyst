# Anti-patterns

Mistakes that already happened in this project or the Mac app before it, so they do not happen twice. Each one says what to do instead.

## Changing a machine
- **Killing by port without checking who is listening.** `lsof -i :3000 -t | xargs kill -9` also kills anything connected to that port, which can be your browser. Find the listener only, show it, send TERM, wait, and ask before KILL.
- **Writing downloaded shell code into startup files.** The Mac app did this without showing it. Nothing Catalyst runs or writes is downloaded. Anything it writes ships in the release itself.
- **Keeping a password.** The Mac app saved the admin password so people "authenticate once". Catalyst never sees one. If something needs root, print the command.
- **A delete that skips the Trash.** Every removal goes through `internal/trash`, including small ones like a plist. If the journal cannot record it, the move is put back.
- **Editing a startup file without a way back.** Back up first, have the shell parse the result, and restore if it objects.
- **Listing `~/.Trash`.** On a Mac, a terminal without Full Disk Access cannot list it, though it can stat a path and rename in and out. Do only those two things.
- **Copying across disks to trash something.** A rename either happens or does not. A copy can fail halfway through a 20 GB folder.

## Sweep
- **Treating a folder's name as proof.** A `venv` can be someone's notes and `build/` can hold hand-written scripts. Require a marker, and ask git.
- **Asking git only whether something is ignored.** A file can be tracked and ignored at once. Ask `check-ignore` and `ls-files`.
- **Taking the first date you find.** Git's index does not move when someone edits without staging. Use the newest of git state and source files, and ignore artifact folders.
- **Protection that is off by default.** Fourteen days is the default. The old toggle was off, and only skipped `.git` despite promising more.
- **Adding up file sizes.** Hard links counted repeatedly made pnpm projects look many times larger. Sum allocated blocks and count each inode once, and say "about".
- **Walking into app bundles and tool folders.** An Electron app holds a `node_modules` beside a `package.json`. So does a global tool. Removing those breaks them.

## Running programs
- **A child process in a background group with the terminal still attached.** An interactive shell freezes on SIGTTOU, which looked like a 12-second hang only in a real terminal. Every program runs in its own session.
- **Leaving stdin open.** A hidden prompt must fail, never wait where nobody can see it.
- **Reading a pipe with no limit.** A daemon that inherits the pipe (git's fsmonitor, `system_profiler`) keeps it open after the program exits. Every call has a time limit and `WaitDelay`.
- **Running `git` or `python3` on a Mac to see if they exist.** Without Command Line Tools, those are stubs that open Apple's install dialog. Use `SafeTool`.
- **Checking the environment you were started with.** A process's PATH is rarely what a new terminal gets. Ask a login shell, and tolerate whatever startup files print.
- **Finding a tool and calling it working.** A command can resolve and still fail. Run it.
- **Parsing text in the user's language.** Everything runs with `LC_ALL=C`.

## Reporting
- **An empty `catch` that reads as healthy.** A check that could not run says so. It is never a pass.
- **Calling normal things problems.** A dev server on port 3000 is not an issue, so it is not reported as one. One false alarm costs more trust than one miss.
- **Parsing a value back out of display text.** The old fix read the port number from the issue title. Fixes carry structured data.
- **Printing a secret to prove you found it.** Counts only, everywhere, including `--json`.

## Output
- **Output wider than the terminal.** A spinner line longer than the window wraps and stacks on every redraw. Fit lines to the width, and never cut text inside brackets.
- **A background key reader.** It steals the keys meant for a command's own menu. Wait for input with `select`, and read only when a key is ready.
- **Raw logs on screen.** Long steps show a spinner. Details appear only when something fails.
- **A question after a long step has started.** Ask first, then work.
- **A list and a prompt on one screen.** 0.1.0 showed a list you could arrow through with a box to type in, and Enter only obeyed the box. Pick one way to choose. The session is a list.
- **Kit on every screen.** Repeated Kits stacked up the scrollback and meant nothing. Kit is drawn once, on the home screen, and reacts there.
- **Kit in a pipe.** Kit and colour are for a person at a terminal. Never in `--json`, CI, `NO_COLOR` or narrow windows.
- **Spreading a menu to the window's edge.** Sizes far from their names are hard to read across. Columns are as wide as their content.
- **A cheerful line nobody checked.** The status card said "All systems nominal" under a red CPU bar. A sign-off prints only after the values were looked at.
- **Celebrating a failure.** The party mood is for a clean 100, and only then.
- **A stack trace.** Catch it, and say in plain words what to do.

## Scope
- **Wrapping what developers already do.** The Mac app had nine screens over `pip` and `brew`, and that is what people called overkill. Catalyst diagnoses those tools. It does not manage them.
- **Cleaning what is not a cache.** Clean takes app caches and old logs, which rebuild themselves, and nothing else. Models, virtual machines, backups and simulators are someone's chosen data: show them with their own tool's way to remove them.
- **Cleaning under a running app.** An app writing to its cache while it disappears can lose work or crash. Leave an open app's cache, and say so.
- **Touching Apple's caches or admin areas.** macOS manages `com.apple.*`, `/Library/Caches` and its logs. Measure and explain them. Where a command helps, print it.
- **Promising space that the Trash still holds.** Moving to the Trash frees nothing until it is emptied. Say so, and offer to empty only what was just moved, as a separate, final step.

## Process
- **Pushing to `main`.** Use a branch and a pull request.
- **Large pull requests that mix tasks.** One task per branch.
- **Acting on a guess.** Investigate, report, then fix.
- **Bypassing a hook with `--no-verify`.** If a guard fails, fix the cause.
- **Real output in tests or docs.** Tool output holds usernames, hostnames and serial numbers. Take them out first. Screenshots come from `make demo` only.
