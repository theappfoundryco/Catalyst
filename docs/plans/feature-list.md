# Feature list, approved 2026-11-21

The list the maintainer approved in full before the night began, and where each item went. Every item is an open pull request; nothing is merged.

| # | Feature | PR |
|---|---|---|
| P1 to P5 | Platform profile, "not available here" with a reason, helpers through the distribution's package manager, fix text per platform, honest output in containers, WSL and image-based systems | #45 |
| P6 | CI matrix: five images per PR, eighteen nightly, real systemd, macOS Intel and Apple silicon | #47 |
| 1 | Restart waiting, per family | #50 |
| 2 | Two version managers for one language | #51 |
| 3 | Docker unreachable, and why | #52 |
| 4 | File watcher limit, against real use | #48 |
| 5 | The 256 open file limit | #55 |
| 6 | Proxy and certificate variables pointing at nothing | #49 |
| 7 | Xcode path and licence after an update | #53 |
| 8 | A terminal running under Rosetta | #54 |
| 9 | git signing that makes every commit fail, and plaintext credentials others can read | #56 |
| 10 | Clock not kept in sync | #57 |
| 11 | pip told to overwrite system packages | #58 |
| 12 | `catalyst why` | #60 |
| 13 | `catalyst project` | #61 |
| 14 | `catalyst report` | #62 |
| 15 | `catalyst changes` | #63 |
| 16 | Shell completions | #64 |
| 17 | More sweep rules | #65 |
| 18 | Tool caches through their own commands | #66 |
| 19 | System Data for more distributions | #67 |
| 20 | Xcode device support and archives | #68 |
| 21 | Mute a finding | #69 |
| 22 | Fix everything that can be undone, with one yes | #70 |
| Visual | Project, Changes and Report rows, `w` for why | #71 (plan: `home-rows.md`) |

Found and fixed on the way: #46 (the "0 keys" wording), #59 (the wrong startup line credited for a PATH folder), and the root-without-sudo commit inside #45.
