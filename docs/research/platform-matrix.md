# Platform matrix

What Catalyst needs to know about a machine, where other projects read it from, and what each platform did when Catalyst ran there. Written on 2026-11-21 from the source files linked below, read on that day. Nothing here was copied: GPL sources were read for facts only, and the MIT, BSD and Apache ones were used for facts and rewritten.

## Sources read

| Source | Licence | File | What it taught |
|---|---|---|---|
| systemd | LGPL (man page) | [man/os-release.xml](https://github.com/systemd/systemd/blob/main/man/os-release.xml) | `/etc/os-release` first, then `/usr/lib/os-release`. `ID_LIKE` is a space-separated list, closest first. Use `ID_LIKE` only as a fallback for `ID`. `VARIANT_ID` names editions (Silverblue, Kinoite, CoreOS). `PRETTY_NAME` is for people. |
| systemd | LGPL | [src/basic/virt.c](https://github.com/systemd/systemd/blob/main/src/basic/virt.c) | Container signs, cheapest first: `/run/.containerenv` (Podman), `/.dockerenv` (Docker), `/run/systemd/container`, `container=` in PID 1's environment. WSL: `/proc/sys/kernel/osrelease` contains `microsoft` or `WSL`. |
| python-distro | Apache 2.0 | [src/distro/distro.py](https://github.com/python-distro/distro/blob/master/src/distro/distro.py) | Order: os-release, then `lsb_release`, then `/etc/*-release`. Normalises old ids (`ol` is Oracle, `opensuse-leap` is openSUSE). Quotes and backslash escapes in values must be handled. |
| fastfetch | MIT | [src/detection/packages/packages_linux.c](https://github.com/fastfetch-cli/fastfetch/blob/dev/src/detection/packages/packages_linux.c), [os_linux.c](https://github.com/fastfetch-cli/fastfetch/blob/dev/src/detection/os/os_linux.c), [initsystem_linux.c](https://github.com/fastfetch-cli/fastfetch/blob/dev/src/detection/initsystem/initsystem_linux.c) | Counts packages by reading each manager's database (`/var/lib/dpkg/status`, `/var/lib/rpm/rpmdb.sqlite`, `/var/lib/pacman/local`, `/lib/apk/db/installed`, `/var/lib/snapd/snap`, flatpak under `/var/lib/flatpak`), never by running the manager. Init system from PID 1's command name. |
| Homebrew | BSD-2 | [docs/Support-Tiers.md](https://github.com/Homebrew/brew/blob/main/docs/Support-Tiers.md), [docs/Homebrew-on-Linux.md](https://github.com/Homebrew/brew/blob/main/docs/Homebrew-on-Linux.md) | On Linux Homebrew needs glibc (no musl, so not Alpine). Tier 1: glibc 2.39 or newer, kernel 3.2 or newer, x86_64 with SSSE3 or ARM64, default prefix `/home/linuxbrew/.linuxbrew`. glibc 2.13 to 2.38 is Tier 2: Homebrew installs its own glibc. 32-bit ARM is Tier 3. Real and effective user ids must match (so not as root through sudo). |
| Homebrew | BSD-2 | [Library/Homebrew/extend/os/mac/diagnostic.rb](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/extend/os/mac/diagnostic.rb) | Xcode checks worth having: active developer dir missing `usr/bin/xcodebuild` (fix `sudo xcode-select --switch`), Xcode license not agreed (`xcrun --find clang` output mentions "license"; fix `sudo xcodebuild -license`), CLT older than this macOS. |
| Homebrew | BSD-2 | [Library/Homebrew/extend/os/linux/diagnostic.rb](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/extend/os/linux/diagnostic.rb) | `/tmp` mounted `noexec`, `umask 000`, unsupported architecture, glibc too old, kernel too old. Each finding has text plus the exact commands. |
| Flutter | BSD-3 | [packages/flutter_tools/lib/src/doctor.dart](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/doctor.dart) | Validators end as success, partial, missing or **notAvailable**. "Not available here" is its own answer, never a failure. Catalyst's `Skip` with a reason is the same idea and keeps the score honest. |
| mise | MIT | [src/cli/doctor/mod.rs](https://github.com/jdx/mise/blob/main/src/cli/doctor/mod.rs) | Reports `activated` and `shims_on_path` separately, warns about shims and activation both set, and about one tool's shim shadowed by another earlier on PATH. |
| npm | Artistic 2.0 | [lib/commands/doctor.js](https://github.com/npm/cli/blob/latest/lib/commands/doctor.js) | Registry ping, versions, git on PATH, global bin on PATH, ownership of the cache and global folders. Catalyst already checks the ownership case. |

Read for facts only, not opened tonight: Ansible's `distribution.py`, topgrade, Lynis, needrestart, BleachBit. The facts below that come from their area were checked against the distributions' own documentation or tools instead.

## Facts Catalyst now uses

**Distribution and family.** `ID`, then each `ID_LIKE` entry, mapped to one family: debian (debian, ubuntu, linuxmint, pop, raspbian, kali, elementary, zorin), rhel (rhel, centos, rocky, almalinux, ol, amzn), fedora, suse (opensuse-leap, opensuse-tumbleweed, sles, opensuse-microos), arch (arch, manjaro, endeavouros, steamos, garuda), alpine, gentoo, void, nixos. Unknown stays `unknown` and nothing guesses.

**C library.** musl when `/lib/ld-musl-*.so.1` exists. Otherwise `getconf GNU_LIBC_VERSION` gives `glibc 2.36`.

**Init.** `/proc/1/comm`: `systemd`, `init` with `/sbin/openrc` present (OpenRC), `runit`, `s6-svscan`, `dinit`. In a container PID 1 is often a shell or `sleep`, which reads as none.

**Container.** As systemd's `virt.c` above, plus `/proc/1/cgroup` naming `docker`, `kubepods` or `lxc` for old runtimes. WSL from the kernel release.

**Immutable.** `/run/ostree-booted` (Silverblue, Kinoite, CoreOS, Bazzite), `ID=nixos`, `ID=steamos`, `ID=opensuse-microos` or `VARIANT_ID` of `microos`, `aeon` or `kalpa`. There, nothing suggests writing to `/usr`; the advice is `rpm-ostree install`, toolbox or distrobox, or the Nix configuration.

**Package managers.** Present when the binary is on PATH **and** its database exists, so a stray `apt` script on Fedora does not count: apt (`/var/lib/dpkg/status`), dnf and yum (`/var/lib/rpm`), zypper, pacman (`/var/lib/pacman`), apk (`/lib/apk/db`), xbps (`/var/db/xbps`), emerge, nix, brew, port, flatpak, snap.

**Restart waiting.**
- Debian and Ubuntu: `/var/run/reboot-required` exists.
- Fedora, RHEL and friends: `needs-restarting -r` (dnf-utils) or `dnf needs-restarting -r` (dnf 5), exit code 1 means a restart is needed.
- openSUSE: `zypper needs-rebooting`, exit code 102.
- Arch, Alpine and any distribution that replaces the running kernel's modules: the running kernel (`uname -r`) has no folder in `/usr/lib/modules` or `/lib/modules`. Not used inside a container, where the kernel is the host's.

**File watchers.** `/proc/sys/fs/inotify/max_user_watches`. Kernels since 5.11 size it from memory (often 60,000 to over a million). Below 65,536 is what causes `ENOSPC: System limit for number of file watchers reached` in webpack, Vite, Jest and VS Code. The supported fix is a file in `/etc/sysctl.d` and `sysctl --system`.

## Candidate checks, ranked

Score is people who hit it (1 to 5) x time it wastes (1 to 5) x how quietly it can be detected (1 to 5).

| Check | Hits | Time | Quiet | Score | Decision |
|---|---|---|---|---|---|
| A tool pinned by the project differs from the active one (`catalyst project`) | 5 | 4 | 4 | 80 | Build |
| Which program really runs, and why (`catalyst why`) | 5 | 4 | 5 | 100 | Build |
| Two version managers for one language | 4 | 4 | 4 | 64 | Build |
| Docker installed but not reachable (socket, group, dead context) | 4 | 4 | 4 | 64 | Build |
| File watcher limit too low (Linux) | 3 | 5 | 5 | 75 | Build |
| Certificate or proxy variable pointing at nothing | 3 | 5 | 5 | 75 | Build |
| Restart waiting after an update | 4 | 2 | 5 | 40 | Build (extends machine.linux) |
| Xcode path or licence broken after an update | 3 | 4 | 5 | 60 | Build |
| Open file limit too low (macOS 256) | 3 | 3 | 4 | 36 | Build, as a note |
| Shell running under Rosetta | 2 | 4 | 5 | 40 | Build |
| git signing key missing, plaintext credentials readable | 3 | 3 | 5 | 45 | Build |
| Clock not synchronised | 2 | 4 | 3 | 24 | Build, only with timedatectl's own answer |
| pip told to break system packages everywhere | 2 | 4 | 5 | 40 | Build |
| `/tmp` mounted noexec | 1 | 4 | 5 | 20 | Later |
| umask 000 | 1 | 3 | 5 | 15 | Later |

## Per image

Filled in from the container runs in `.cache/matrix/`. Each row: what was detected, what ran, what skipped and why, and anything wrong.

(see the tables appended below by the matrix run)
