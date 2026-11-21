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

Every read-only command, run with `scripts/distro-matrix.sh` on the build of `overnight/2026-11-21` (all PRs together), as root. The same images as uid 1000 gave the same platform, and no run crashed or printed a stack trace: 38 of 38 runs passed. "Ran" counts checks that passed or found something; "Skipped" includes every check that does not apply inside a container, each with its reason. Images have almost nothing installed, which is why git and a compiler are missing everywhere.

| Image | Detected | Family | libc | Init | Container | Package managers | Ran | Skipped | Issues found | Errors |
|---|---|---|---|---|---|---|---|---|---|---|
| `almalinux_8` | AlmaLinux 8.10 (Cerulean Leopard) | rhel | glibc 2.28 | - | docker | dnf | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `alpine_3.18` | Alpine Linux v3.18 | alpine | musl | - | docker | apk | 6 | 19 | No compiler or make here, so packages that build from source will fail; git is not installed; Your PATH has 1 folder that does not exist | - |
| `alpine_3.20` | Alpine Linux v3.20 | alpine | musl | - | docker | apk | 6 | 19 | No compiler or make here, so packages that build from source will fail; git is not installed; Your PATH has 1 folder that does not exist | - |
| `amazonlinux_2023` | Amazon Linux 2023.12.20261117 | rhel | glibc 2.34 | - | docker | dnf | 8 | 17 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `archlinux_latest` | Arch Linux | arch | glibc 2.44 | - | docker | pacman | 6 | 19 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `debian_11` | Debian GNU/Linux 11 (bullseye) | debian | glibc 2.31 | - | docker | apt | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `debian_13` | Debian GNU/Linux 13 (trixie) | debian | glibc 2.41 | - | docker | apt | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `fedora_40` | Fedora Linux 40 (Container Image) | fedora | glibc 2.39 | - | docker | dnf | 9 | 16 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `fedora_41` | Fedora Linux 41 (Container Image) | fedora | glibc 2.40 | - | docker | dnf | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `ghcr.io_void-linux_void-glibc_latest` | Void Linux | void | glibc 2.41 | - | docker | xbps | 6 | 19 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `golang_1.27` | Debian GNU/Linux 13 (trixie) | debian | glibc 2.41 | - | docker | apt | 10 | 15 | git does not know your name and email, so commits will fail or look wrong | - |
| `nixos_nix_latest` | Linux | unknown | ? | - | docker | nix | 8 | 17 | No compiler or make here, so packages that build from source will fail; git does not know your name and email, so commits will fail or look wrong | - |
| `opensuse_leap_15.6` | openSUSE Leap 15.6 | suse | glibc 2.38 | - | docker | zypper | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `opensuse_tumbleweed` | openSUSE Tumbleweed | suse | glibc 2.44 | - | docker | zypper | 6 | 19 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `rockylinux_9` | Rocky Linux 9.9 (Blue Onyx) | rhel | glibc 2.34 | - | docker | dnf | 9 | 16 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `ubuntu_20.04` | Ubuntu 20.04.6 LTS | debian | glibc 2.31 | - | docker | apt | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `ubuntu_22.04` | Ubuntu 22.04.5 LTS | debian | glibc 2.35 | - | docker | apt | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |
| `ubuntu_24.04` | Ubuntu 24.04.5 LTS | debian | glibc 2.39 | - | docker | apt | 7 | 18 | No compiler or make here, so packages that build from source will fail; git is not installed | - |

Not a problem, but worth knowing: `nixos/nix` is not NixOS and has no os-release, so it reads as "Linux, unknown family", and nothing is guessed. Alpine's default PATH names `/usr/local/sbin`, which does not exist in the image, so `shell.path` notes one missing folder there.

Also run:

| Where | What | Result |
|---|---|---|
| x86_64 Ubuntu 24.04 desktop (native, read only) | every read-only command, and the new why, project, report, changes | Ubuntu 24.04.5 LTS, x86_64, glibc 2.39, systemd; apt, snap, brew. No crash. Doctor 1.4 s. Bugs found and fixed: `path` crediting the wrong startup line (#59), "your 0 keys" (#46), `/bin` and `/usr/bin` listed twice in `why` |
| `jrei/systemd-debian:12`, privileged, `/sbin/init` | doctor with one failing unit | First run skipped services "inside a container", which is wrong for a system container. Fixed in #45; afterwards the unit was reported for root and `nobody`, and the journal read |
| macos-15-intel, macos-15, macos-latest (26.7) runners | test suite and every read-only command | Intel macOS 15.7.9 reads as x86_64, Apple silicon as ARM64; launchd; brew. No crash |
| Each family's image | install suggestions in simulate mode | All resolve. openSUSE Leap's `devel_basis` conflicts on libncurses6 inside the image itself |
