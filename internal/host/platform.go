package host

import (
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
)

// Platform is what this machine is and what it can do, read once per run. Checks and helpers ask it instead of
// assuming a Mac, Homebrew or Debian, so a suggestion is always one that can work here. See docs/plans/platform-profile.md.
type Platform struct {
	OS         string   `json:"os"`
	Arch       string   `json:"arch"` // the machine's, not the binary's: arm64 under Rosetta too
	Rosetta    bool     `json:"rosetta,omitempty"`
	Kernel     string   `json:"kernel,omitempty"`
	MacVersion string   `json:"mac_version,omitempty"`
	ID         string   `json:"id,omitempty"`
	IDLike     []string `json:"id_like,omitempty"`
	VersionID  string   `json:"version_id,omitempty"`
	Codename   string   `json:"codename,omitempty"`
	Variant    string   `json:"variant,omitempty"`
	Pretty     string   `json:"name"`
	Family     string   `json:"family,omitempty"` // debian, rhel, fedora, suse, arch, alpine, gentoo, void, nixos, unknown
	Libc       string   `json:"libc,omitempty"`   // "glibc 2.36", "musl", or "" when unknown
	Init       string   `json:"init,omitempty"`   // systemd, openrc, runit, s6, dinit, launchd, or "" for anything else
	Container  string   `json:"container,omitempty"`
	Immutable  bool     `json:"immutable,omitempty"`
	Root       bool     `json:"root,omitempty"`
	Sudo       bool     `json:"sudo"`
	Managers   []string `json:"package_managers"`
}

// Platform reads the machine the first time it is asked and keeps the answer for the rest of the run, in memory only.
// Checks run at the same time, so the first read happens under a lock.
func (e *Env) Platform() Platform {
	e.platMu.Lock()
	defer e.platMu.Unlock()
	if e.plat == nil {
		p := ReadPlatform("/", e)
		e.plat = &p
	}
	return *e.plat
}

// SetPlatform fixes the answer for tests.
func (e *Env) SetPlatform(p Platform) {
	e.platMu.Lock()
	e.plat = &p
	e.platMu.Unlock()
}

// ReadPlatform reads files under root ("/" on a real machine) and asks a few programs that are safe everywhere,
// including a Mac with no Command Line Tools.
func ReadPlatform(root string, e *Env) Platform {
	p := Platform{OS: e.OS, Arch: e.Arch, Root: os.Geteuid() == 0}
	at := func(parts ...string) string { return filepath.Join(append([]string{root}, parts...)...) }
	read := func(parts ...string) string { b, _ := os.ReadFile(at(parts...)); return string(b) }
	if _, err := e.Look("sudo"); err == nil {
		p.Sudo = true
	}
	p.Kernel, _ = e.Out("uname", "-r")
	if e.Mac() {
		p.Pretty, p.Init, p.Family = "macOS", "launchd", "macos"
		if v, ok := e.Out("sw_vers", "-productVersion"); ok {
			p.MacVersion, p.Pretty = v, "macOS "+v
		}
		// A binary built for Intel reports amd64 under Rosetta. The hardware answer is what a person needs to know.
		if v, _ := e.Out("sysctl", "-n", "hw.optional.arm64"); v == "1" {
			p.Arch = "arm64"
		}
		if v, _ := e.Out("sysctl", "-n", "sysctl.proc_translated"); v == "1" {
			p.Rosetta = true
		}
		p.Managers = macManagers(e)
		return p
	}
	text := read("etc", "os-release")
	if text == "" {
		text = read("usr", "lib", "os-release")
	}
	f := ParseOSReleaseFields(text)
	p.ID, p.VersionID, p.Codename, p.Variant = f["ID"], f["VERSION_ID"], f["VERSION_CODENAME"], f["VARIANT_ID"]
	p.IDLike = strings.Fields(f["ID_LIKE"])
	p.Pretty = f["PRETTY_NAME"]
	if p.Pretty == "" {
		p.Pretty = strings.TrimSpace(f["NAME"] + " " + f["VERSION_ID"])
	}
	if p.Pretty == "" {
		p.Pretty = "Linux"
	}
	p.Family = FamilyOf(p.ID, p.IDLike)
	musl, _ := filepath.Glob(at("lib", "ld-musl-*.so.1"))
	glibc, _ := e.Out("getconf", "GNU_LIBC_VERSION")
	p.Libc = LibcFrom(len(musl) > 0, glibc)
	p.Init = InitFrom(read("proc", "1", "comm"), Exists(at("sbin", "openrc")))
	p.Container = ContainerFrom(ContainerSigns{
		Podman:  Exists(at("run", ".containerenv")),
		Docker:  Exists(at(".dockerenv")),
		Systemd: read("run", "systemd", "container"),
		Environ: read("proc", "1", "environ"),
		Cgroup:  read("proc", "1", "cgroup"),
		Kernel:  read("proc", "sys", "kernel", "osrelease"),
	})
	p.Immutable = Exists(at("run", "ostree-booted")) || slices.Contains([]string{"nixos", "steamos", "opensuse-microos"}, p.ID) ||
		slices.Contains([]string{"microos", "aeon", "kalpa"}, p.Variant)
	p.Managers = linuxManagers(e, at)
	return p
}

// ParseOSReleaseFields reads os-release(5): KEY=value lines, values optionally quoted, with backslash escapes inside
// double quotes. Comments and malformed lines are ignored.
func ParseOSReleaseFields(text string) map[string]string {
	out := map[string]string{}
	for _, l := range strings.Split(text, "\n") {
		l = strings.TrimSpace(l)
		k, v, ok := strings.Cut(l, "=")
		if !ok || l == "" || l[0] == '#' || strings.ContainsAny(k, " \t") {
			continue
		}
		switch {
		case len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"':
			v = v[1 : len(v)-1]
			var b strings.Builder
			for i := 0; i < len(v); i++ {
				if v[i] == '\\' && i+1 < len(v) {
					i++
				}
				b.WriteByte(v[i])
			}
			v = b.String()
		case len(v) >= 2 && v[0] == '\'' && v[len(v)-1] == '\'':
			v = v[1 : len(v)-1]
		}
		out[k] = v
	}
	return out
}

// families maps an os-release id to the family whose tools and advice fit it. ID wins, then ID_LIKE in order.
var families = map[string]string{
	"debian": "debian", "ubuntu": "debian", "linuxmint": "debian", "pop": "debian", "raspbian": "debian", "kali": "debian",
	"elementary": "debian", "zorin": "debian", "neon": "debian", "devuan": "debian", "mx": "debian",
	"fedora": "fedora",
	"rhel":   "rhel", "centos": "rhel", "rocky": "rhel", "almalinux": "rhel", "ol": "rhel", "amzn": "rhel", "cloudlinux": "rhel",
	"opensuse-leap": "suse", "opensuse-tumbleweed": "suse", "opensuse-microos": "suse", "sles": "suse", "suse": "suse", "opensuse": "suse",
	"arch": "arch", "manjaro": "arch", "endeavouros": "arch", "garuda": "arch", "steamos": "arch", "artix": "arch", "cachyos": "arch",
	"alpine": "alpine", "postmarketos": "alpine",
	"gentoo": "gentoo", "void": "void", "nixos": "nixos",
}

// FamilyOf names the family of a distribution, or "unknown". It never guesses from a name it does not know.
func FamilyOf(id string, like []string) string {
	for _, x := range append([]string{id}, like...) {
		if f, ok := families[strings.ToLower(x)]; ok {
			return f
		}
	}
	return "unknown"
}

// LibcFrom names the C library: musl when its loader is there, otherwise what getconf says, such as "glibc 2.36".
func LibcFrom(musl bool, getconf string) string {
	if musl {
		return "musl"
	}
	if f := strings.Fields(getconf); len(f) == 2 && f[0] == "glibc" {
		return "glibc " + f[1]
	}
	return ""
}

// GlibcAtLeast says whether the C library is glibc of at least major.minor. Unknown is false.
func (p Platform) GlibcAtLeast(major, minor int) bool {
	v, ok := strings.CutPrefix(p.Libc, "glibc ")
	if !ok {
		return false
	}
	a, b, _ := strings.Cut(v, ".")
	x, err1 := strconv.Atoi(a)
	y, err2 := strconv.Atoi(strings.SplitN(b, ".", 2)[0])
	if err1 != nil || err2 != nil {
		return false
	}
	return x > major || x == major && y >= minor
}

// InitFrom names the init system from PID 1's command name. In a container PID 1 is usually a shell or the app
// itself, which reads as "".
func InitFrom(comm string, openrc bool) string {
	switch c := strings.TrimSpace(comm); {
	case c == "systemd":
		return "systemd"
	case c == "openrc-init" || c == "init" && openrc:
		return "openrc"
	case c == "runit" || c == "runsvdir":
		return "runit"
	case c == "s6-svscan":
		return "s6"
	case c == "dinit":
		return "dinit"
	}
	return ""
}

// ContainerSigns are the files a container leaves, read raw so the decision is a plain function.
type ContainerSigns struct {
	Podman, Docker                   bool
	Systemd, Environ, Cgroup, Kernel string
}

// ContainerFrom names the container or WSL this runs in, cheapest sign first, the way systemd's own detection does.
// "" means bare metal or a virtual machine, where the machine's own firewall, services and battery are real.
func ContainerFrom(s ContainerSigns) string {
	k := strings.ToLower(s.Kernel)
	switch {
	case strings.Contains(k, "microsoft") || strings.Contains(k, "wsl"):
		return "wsl"
	case s.Podman:
		return "podman"
	case s.Docker:
		return "docker"
	case strings.TrimSpace(s.Systemd) != "":
		return strings.TrimSpace(s.Systemd)
	}
	for _, kv := range strings.Split(s.Environ, "\x00") {
		if v, ok := strings.CutPrefix(kv, "container="); ok && v != "" {
			return v
		}
	}
	switch {
	case strings.Contains(s.Cgroup, "/docker/") || strings.Contains(s.Cgroup, "/docker-"):
		return "docker"
	case strings.Contains(s.Cgroup, "/kubepods"):
		return "kubernetes"
	case strings.Contains(s.Cgroup, "/lxc/"):
		return "lxc"
	}
	return ""
}

// InContainer is true in a container, where the host owns the firewall, services, battery and kernel. WSL is not a
// container for this purpose: it has its own kernel and, often, systemd.
func (p Platform) InContainer() bool { return p.Container != "" && p.Container != "wsl" }

// managers lists each package manager by its program and the database that proves it manages this system. A stray
// apt script on Fedora is not apt.
var managers = []struct{ name, bin, db string }{
	{"apt", "apt-get", "var/lib/dpkg/status"},
	{"dnf", "dnf", "var/lib/rpm"},
	{"yum", "yum", "var/lib/rpm"},
	{"zypper", "zypper", "var/lib/rpm"},
	{"pacman", "pacman", "var/lib/pacman"},
	{"apk", "apk", "lib/apk/db"},
	{"xbps", "xbps-install", "var/db/xbps"},
	{"emerge", "emerge", "var/db/pkg"},
	{"nix", "nix-env", "nix/store"},
	{"rpm-ostree", "rpm-ostree", "run/ostree-booted"},
	{"flatpak", "flatpak", "var/lib/flatpak"},
	{"snap", "snap", "var/lib/snapd"},
}

func linuxManagers(e *Env, at func(...string) string) []string {
	out := []string{}
	for _, m := range managers {
		if _, err := e.Look(m.bin); err == nil && Exists(at(m.db)) {
			if m.name == "yum" && slices.Contains(out, "dnf") { // yum is a link to dnf on Fedora and RHEL 8 and later
				continue
			}
			out = append(out, m.name)
		}
	}
	if Exists(at("home", "linuxbrew", ".linuxbrew", "bin", "brew")) || lookUnder(e, "brew", "/home/linuxbrew/") {
		out = append(out, "brew")
	}
	return out
}

func macManagers(e *Env) []string {
	out := []string{}
	for _, p := range []string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"} {
		if Exists(p) {
			out = append(out, "brew")
			break
		}
	}
	if Exists("/opt/local/bin/port") {
		out = append(out, "port")
	}
	if Exists("/nix/store") {
		out = append(out, "nix")
	}
	return out
}

func lookUnder(e *Env, name, prefix string) bool {
	p, err := e.Look(name)
	return err == nil && strings.HasPrefix(p, prefix)
}

// Has says whether a package manager manages this machine.
func (p Platform) Has(manager string) bool { return slices.Contains(p.Managers, manager) }

// Brew says whether Homebrew can work here and, when it cannot, why, in words for the person. Facts from
// docs.brew.sh/Support-Tiers, read 2026-11-21: Linux needs glibc (2.13 or newer, 2.39 for full support), x86_64 or
// ARM64, and a normal user.
func (p Platform) Brew() (bool, string) {
	if p.OS == "darwin" {
		return true, ""
	}
	name := p.Short()
	switch {
	case p.Libc == "musl":
		return false, "Not available on " + name + ": Homebrew needs glibc, and this system uses musl"
	case p.Arch != "amd64" && p.Arch != "arm64":
		return false, "Not available on " + p.Arch + ": Homebrew supports x86_64 and ARM64 only"
	case p.Libc != "" && !p.GlibcAtLeast(2, 13):
		return false, "Not available here: Homebrew needs glibc 2.13 or newer, and this has " + strings.TrimPrefix(p.Libc, "glibc ")
	case p.Root:
		return false, "Homebrew does not run as root. Use your normal account"
	}
	return true, ""
}

// Short is the distribution's name without its version blurb, for sentences like "Not available on Alpine".
func (p Platform) Short() string {
	if p.OS == "darwin" {
		return "macOS"
	}
	if n, ok := shortNames[p.ID]; ok {
		return n
	}
	if p.Pretty != "" {
		return strings.Fields(p.Pretty)[0]
	}
	return "Linux"
}

var shortNames = map[string]string{
	"alpine": "Alpine", "debian": "Debian", "ubuntu": "Ubuntu", "fedora": "Fedora", "arch": "Arch", "rhel": "RHEL",
	"rocky": "Rocky Linux", "almalinux": "AlmaLinux", "amzn": "Amazon Linux", "opensuse-leap": "openSUSE Leap",
	"opensuse-tumbleweed": "openSUSE Tumbleweed", "void": "Void", "nixos": "NixOS", "gentoo": "Gentoo", "centos": "CentOS",
	"manjaro": "Manjaro", "linuxmint": "Linux Mint", "pop": "Pop!_OS", "steamos": "SteamOS",
}

// Install is how to install packages on this machine with its own package manager. names maps a family (or a package
// manager) to the package name there, with "" as the name everywhere else. cmd is the exact argv, run as root, for a
// helper to show and run. When cmd is nil, advice says what to do instead, or why it cannot be done here.
func (p Platform) Install(names map[string]string) (cmd []string, advice string) {
	pick := func(keys ...string) string {
		for _, k := range keys {
			if n, ok := names[k]; ok {
				return n
			}
		}
		return names[""]
	}
	if p.OS == "darwin" {
		if p.Has("brew") {
			n := pick("brew")
			return []string{"brew", "install", n}, ""
		}
		return nil, "Install Homebrew first, from Helpers"
	}
	if p.Immutable {
		n := pick(p.Family)
		switch {
		case p.ID == "nixos":
			return nil, "On NixOS, add " + n + " to environment.systemPackages in your configuration"
		case p.Has("rpm-ostree"):
			return nil, "On an image-based system, layer it with: sudo rpm-ostree install " + n + " (then restart), or use a toolbox"
		}
		return nil, "This system's /usr is read-only. Install " + n + " the way it supports, such as distrobox"
	}
	type way struct {
		manager string
		argv    []string
	}
	for _, w := range []way{
		{"apt", []string{"apt-get", "install", "-y"}},
		{"dnf", []string{"dnf", "install", "-y"}},
		{"yum", []string{"yum", "install", "-y"}},
		{"zypper", []string{"zypper", "--non-interactive", "install"}},
		{"pacman", []string{"pacman", "-S", "--needed", "--noconfirm"}},
		{"apk", []string{"apk", "add"}},
		{"xbps", []string{"xbps-install", "-y"}},
	} {
		if p.Has(w.manager) {
			n := pick(w.manager, p.Family)
			if n == "" {
				return nil, "No package for this on " + p.Short()
			}
			return append(w.argv, strings.Fields(n)...), ""
		}
	}
	if p.Has("emerge") {
		return nil, "On Gentoo: sudo emerge --ask " + pick("emerge", p.Family)
	}
	return nil, "No package manager here that Catalyst knows. Install " + pick(p.Family) + " the way your system does"
}

// Service is how a person looks at a failed service on this machine's init system.
func (p Platform) Service(name string, user bool) string {
	switch {
	case p.Init == "openrc":
		return "rc-service " + name + " status"
	case p.Init == "runit":
		return "sv status " + name
	case user:
		return "systemctl --user status " + name
	}
	return "systemctl status " + name
}

// Describe is the platform in one line for people, like "Fedora Linux 41, x86_64, glibc 2.40, systemd".
func (p Platform) Describe() string { return p.Pretty + ", " + p.Details() }

// Details is Describe without the system's name, for a screen that already shows it.
func (p Platform) Details() string {
	parts := []string{archName(p.Arch)}
	if p.Rosetta {
		parts[0] += " (this terminal runs under Rosetta)"
	}
	if p.Libc != "" {
		parts = append(parts, p.Libc)
	}
	if p.Init != "" && p.OS != "darwin" {
		parts = append(parts, p.Init)
	}
	switch {
	case p.Container == "wsl":
		parts = append(parts, "WSL")
	case p.Container != "":
		parts = append(parts, "in a "+p.Container+" container")
	}
	if p.Immutable {
		parts = append(parts, "image-based")
	}
	return strings.Join(parts, ", ")
}

func archName(a string) string {
	switch a {
	case "amd64":
		return "x86_64"
	case "arm64":
		return "ARM64"
	}
	return a
}

// Names of packages that differ by family, for Install. "" is the name everywhere else.
var (
	BuildToolsPkgs = map[string]string{"debian": "build-essential", "fedora": "@development-tools", "rhel": "@development",
		"suse": "-t pattern devel_basis", "arch": "base-devel", "alpine": "build-base", "void": "base-devel", "gentoo": "sys-devel/gcc", "": "gcc make"}
	SmartPkgs = map[string]string{"gentoo": "sys-apps/smartmontools", "": "smartmontools"}
)
