# Home list rows for the new commands

A visual change, so it is built on its own branch (`feat/home-rows`, into `overnight/2026-11-21`) and waits for the maintainer's yes. Every piece can be dropped on its own.

## The home list

Today:

```
  ▌ Doctor     find what is wrong and fix what is safe
    Sweep      reclaim space from build artifacts
    Clean      app caches and old logs, which rebuild themselves
    Status     one-glance health of this machine
    ...
    PATH       dead folders, repeats and shadows

    More       history, settings, helpers, update, uninstall
```

Proposed: one new row under Doctor, two under More.

```
  ▌ Doctor     find what is wrong and fix what is safe
    Project    your repository: pinned versions, lockfiles, .env and hooks
    Sweep      reclaim space from build artifacts
    ...
    More       history, what changed, report, settings, helpers, update, uninstall
```

```
  More
  ▌ History    everything Catalyst has changed
    Changes    what changed in your tools since an earlier day
    Report     a summary of this machine to share, with your names taken out
    Settings   show or change settings
    ...
```

- **Project** sits beside Doctor because they are a pair: the machine, then the folder you opened Catalyst in.
- **Changes** and **Report** are occasional, so they wait under More, next to History.
- Every name stays within the ten-character name column.

## Keys on existing screens

- **Doctor:** `m` mutes a finding (#69), next to `⏎` (how to fix) and `f` (fix it).
- **PATH, "Tools hidden by an earlier folder":** `w` opens `catalyst why TOOL` for that row, next to `y` (copy path).

```
  Tools hidden by an earlier folder
  ▌ python3  runs   /home/linuxbrew/.linuxbrew/bin/python3
             hides  /usr/bin
    w why   y copy path
```

## Not changed

Kit, the header, the health dot and every other row.
