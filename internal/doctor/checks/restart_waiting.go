package checks

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/host"
)

// sysRoot is where the system's files are, so tests can build one.
var sysRoot = "/"

// Restart is what this machine says about a restart after updates.
type Restart struct {
	Needed bool
	Known  bool   // false when nothing here could tell; then nothing is reported
	Why    string // what was updated, when the system says
	Ask    string // the command that answers it, for the person to run again later
}

// RestartWaiting asks each family's own tool, never a guess from dates. Inside a container the kernel is the host's,
// so there is never an answer there.
func RestartWaiting(e *host.Env) Restart {
	p := e.Platform()
	if p.InContainer() || p.Container == "wsl" {
		return Restart{}
	}
	at := func(parts ...string) string { return filepath.Join(append([]string{sysRoot}, parts...)...) }
	// Debian and Ubuntu, and anything else that keeps the same flag file.
	if host.Exists(at("var", "run", "reboot-required")) || host.Exists(at("run", "reboot-required")) {
		r := Restart{Needed: true, Known: true}
		b, _ := os.ReadFile(at("var", "run", "reboot-required.pkgs"))
		if pk := uniqueLines(string(b)); len(pk) > 0 {
			r.Why = "Updated: " + strings.Join(pk, ", ")
		}
		return r
	}
	if p.Family == "debian" {
		return Restart{Known: true}
	}
	switch p.Family {
	case "fedora", "rhel":
		// Cache only: dnf would otherwise refresh its repositories, a network call nobody asked for. The text decides,
		// because dnf also exits 1 when the plugin is missing or there is no cache.
		args := []string{"dnf", "-q", "-C", "needs-restarting", "-r"}
		if _, err := e.Look("needs-restarting"); err == nil {
			args = []string{"needs-restarting", "-r"}
		} else if _, err := e.Look("dnf"); err != nil {
			return Restart{}
		}
		r := e.Run.Run(0, args[0], args[1:]...)
		return ParseNeedsRestarting(r.Stdout+r.Stderr, strings.Join(args, " "))
	case "suse":
		if _, err := e.Look("zypper"); err != nil {
			return Restart{}
		}
		r := e.Run.Run(0, "zypper", "needs-rebooting")
		switch {
		case r.Code == 102:
			return Restart{Needed: true, Known: true, Ask: "zypper needs-rebooting"}
		case r.OK():
			return Restart{Known: true}
		}
		return Restart{}
	}
	// Arch, Alpine, Void and others replace the running kernel's modules when they update it, so the folder for the
	// kernel that is running disappears. A machine with no modules folders at all (some cloud kernels) says nothing.
	return KernelReplaced(p.Kernel, at("usr", "lib", "modules"), at("lib", "modules"))
}

// ParseNeedsRestarting reads needs-restarting -r from dnf-plugins-core or dnf 5. The wording is the plugin's own
// (needs_restarting.py), read with LC_ALL=C.
func ParseNeedsRestarting(s, ask string) Restart {
	switch {
	case strings.Contains(s, "Reboot is required"):
		r := Restart{Needed: true, Known: true, Ask: ask}
		var names []string
		for _, l := range strings.Split(s, "\n") {
			if n, ok := strings.CutPrefix(strings.TrimSpace(l), "* "); ok {
				names = append(names, n)
			}
		}
		if len(names) > 0 {
			r.Why = "Updated: " + strings.Join(names, ", ")
		}
		return r
	case strings.Contains(s, "Reboot should not be necessary"):
		return Restart{Known: true}
	}
	return Restart{}
}

// KernelReplaced says whether the running kernel's modules are gone from every modules folder that has any.
func KernelReplaced(kernel string, dirs ...string) Restart {
	if kernel == "" {
		return Restart{}
	}
	any := false
	for _, d := range dirs {
		entries, err := os.ReadDir(d)
		if err != nil || len(entries) == 0 {
			continue
		}
		any = true
		if host.Exists(filepath.Join(d, kernel)) {
			return Restart{Known: true}
		}
	}
	if !any {
		return Restart{}
	}
	return Restart{Needed: true, Known: true, Why: "The running kernel (" + kernel + ") was replaced by an update, so new hardware and modules may not load"}
}

func uniqueLines(s string) []string {
	var out []string
	seen := map[string]bool{}
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" && !seen[l] {
			seen[l] = true
			out = append(out, l)
		}
	}
	return out
}
