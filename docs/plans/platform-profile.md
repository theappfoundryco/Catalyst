# Platform profile

Catalyst reads one fact about Linux today (`PRETTY_NAME`) and assumes a Mac or Homebrew in several places. Helpers offers smartmontools through `brew` on a Mac and guesses the distribution's tool on Linux. Build tools tells everyone to use apt or dnf. This plan gives every check and helper one shared answer to "what is this machine, and what can it do".

Internal, not visual. The only output change is new lines in `catalyst status` and a `platform` object in `status --json` and `doctor --json`.

## The type

`internal/host/platform.go`:

```go
type Platform struct {
	OS, Arch   string   // darwin or linux; the machine's architecture, not the binary's
	Rosetta    bool     // this process is translated on Apple silicon
	Kernel     string   // uname -r
	MacVersion string   // 15.1
	ID, VersionID, Codename, Variant, Pretty string // os-release
	IDLike     []string
	Family     string   // debian, rhel, fedora, suse, arch, alpine, gentoo, void, nixos, unknown
	Libc       string   // "glibc 2.36", "musl", or "" when unknown
	Init       string   // systemd, openrc, runit, s6, dinit, launchd, or "" when PID 1 is something else
	Container  string   // docker, podman, lxc, container, wsl, or ""
	Immutable  bool     // ostree, NixOS, SteamOS, MicroOS
	Root, Sudo bool
	Managers   []string // apt, dnf, yum, zypper, pacman, apk, xbps, emerge, nix, brew, port, flatpak, snap
}
```

## How it is read

- `ReadPlatform(root, e)` reads files under `root` (`/` for real, a temporary folder in tests) and runs at most three programs through `e.Run`: `uname -r`, `getconf GNU_LIBC_VERSION`, and on a Mac `sw_vers -productVersion` and `sysctl`. All of them are safe on a Mac with no Command Line Tools.
- Every piece is a plain function over text: `ParseOSReleaseFields`, `FamilyOf`, `LibcFrom`, `InitFrom`, `ContainerFrom`. Each has tests from recorded files of many distributions.
- `e.Platform()` reads once per run, under a lock (checks run at the same time), and keeps the answer in memory only. `e.SetPlatform` fixes it for tests.
- A package manager counts only when its program is on PATH and its database exists.

## What uses it

- **Not available here.** A check that cannot apply returns `Skip` with the reason. Skip already does not count in the score and is never a pass, so the four states stay as they are, as Flutter's `notAvailable` does. Examples: "Not available on Alpine: Homebrew needs glibc, and this system uses musl". "No firewall check inside a container: the host's firewall is what counts".
- **`p.Install(pkgs)`** returns the install command for this platform's own package manager, or nothing plus a reason. Package names differ per family, so callers pass a map (`debian: build-essential`, `fedora: @development-tools`). On an immutable system it returns the advice (`rpm-ostree install`, toolbox) as text only, never a command Catalyst runs.
- **`p.Brew()`** says whether Homebrew can work here and why not: a Mac always; Linux only with glibc, on x86_64 or ARM64, not as root. Helpers offers Homebrew only on a Mac, and on Linux uses Homebrew only if it is already installed and nothing native is there.
- **Helpers** installs smartmontools with apt-get, dnf, yum, zypper, pacman, apk or xbps-install, through `run.Attached` with sudo, the command shown first.
- **Fix text** asks the platform instead of naming apt and dnf: build tools, the firewall (`ufw` or `firewalld`), the journal, services (`systemctl` or `rc-service`).
- **Containers.** The firewall, startup items, systemd units, battery and restart-waiting checks skip with a reason. **WSL** is named in `status`. **Immutable** systems never get advice to write to `/usr`.

## Not in this change

- The home list does not change.
- `get.sh` still refuses WSL2.
- Package counts. Catalyst does not need them.
