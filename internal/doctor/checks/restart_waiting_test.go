package checks

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Recorded in rockylinux:9 with dnf-plugins-core, and in fedora:41 with no cache (dnf exits 1 there too).
const (
	dnfNoRestart = "No core libraries or services have been updated since boot-up.\nReboot should not be necessary.\n"
	dnfNoCache   = "Cache-only enabled but no cache for repository \"fedora\"\n"
	dnfNoPlugin  = "No such command: needs-restarting. Please use /usr/bin/dnf --help\n"
	// The plugin's own wording for the other answer, from needs_restarting.py.
	dnfRestart = "Core libraries or services have been updated since boot-up:\n  * kernel\n  * glibc\n\nReboot is required to fully utilize these updates.\nMore information: https://access.redhat.com/solutions/27943\n"
)

func TestNeedsRestartingReadsTheTextNotTheExitCode(t *testing.T) {
	if r := ParseNeedsRestarting(dnfRestart, "x"); !r.Needed || r.Why != "Updated: kernel, glibc" {
		t.Fatalf("%+v", r)
	}
	if r := ParseNeedsRestarting(dnfNoRestart, "x"); r.Needed || !r.Known {
		t.Fatalf("%+v", r)
	}
	for _, s := range []string{dnfNoCache, dnfNoPlugin, ""} {
		if r := ParseNeedsRestarting(s, "x"); r.Needed || r.Known {
			t.Fatalf("%q: %+v", s, r)
		}
	}
}

func TestRestartPerFamily(t *testing.T) {
	defer func(s string) { sysRoot = s }(sysRoot)
	sysRoot = t.TempDir()
	e, _ := env(t, "linux", map[string]string{"dnf": "/usr/bin/dnf", "zypper": "/usr/bin/zypper"}, map[string]run.Result{
		"dnf -q -C needs-restarting -r": {Code: 1, Stdout: dnfRestart},
		"zypper needs-rebooting":        {Code: 102, Stdout: "Core libraries or services have been updated.\nReboot is suggested to ensure that your system benefits from these updates.\n"},
	})
	e.SetPlatform(host.Platform{OS: "linux", Family: "fedora"})
	if r := RestartWaiting(e); !r.Needed || r.Ask != "dnf -q -C needs-restarting -r" {
		t.Fatalf("%+v", r)
	}
	e.SetPlatform(host.Platform{OS: "linux", Family: "suse"})
	if r := RestartWaiting(e); !r.Needed {
		t.Fatalf("%+v", r)
	}
	e.SetPlatform(host.Platform{OS: "linux", Family: "debian"})
	if r := RestartWaiting(e); r.Needed || !r.Known {
		t.Fatalf("%+v", r)
	}
	write(t, filepath.Join(sysRoot, "var", "run", "reboot-required"), "*** System restart required ***\n", 0o644)
	write(t, filepath.Join(sysRoot, "var", "run", "reboot-required.pkgs"), "linux-image-6.8.0-50-generic\nlinux-base\nlinux-base\n", 0o644)
	if r := RestartWaiting(e); !r.Needed || r.Why != "Updated: linux-image-6.8.0-50-generic, linux-base" {
		t.Fatalf("%+v", r)
	}
	e.SetPlatform(host.Platform{OS: "linux", Family: "debian", Container: "docker"})
	if r := RestartWaiting(e); r.Needed || r.Known {
		t.Fatalf("a container's kernel is the host's: %+v", r)
	}
}

func TestKernelReplaced(t *testing.T) {
	mods := t.TempDir()
	os.MkdirAll(filepath.Join(mods, "6.12.1-arch1-1"), 0o755)
	if r := KernelReplaced("6.12.1-arch1-1", mods); r.Needed || !r.Known {
		t.Fatalf("%+v", r)
	}
	if r := KernelReplaced("6.11.9-arch1-1", mods); !r.Needed || !strings.Contains(r.Why, "6.11.9-arch1-1") {
		t.Fatalf("%+v", r)
	}
	if r := KernelReplaced("6.11.9-arch1-1", t.TempDir(), filepath.Join(mods, "missing")); r.Known {
		t.Fatalf("no modules anywhere says nothing: %+v", r)
	}
}

func TestSystemCheckOnlyClaimsNoRestartWhenItKnows(t *testing.T) {
	defer func(s string) { sysRoot = s }(sysRoot)
	sysRoot = t.TempDir()
	e, _ := env(t, "linux", nil, nil)
	e.SetPlatform(host.Platform{OS: "linux", Family: "unknown", Init: "systemd"})
	if r := one(t, linuxSystem(e)); r.Title != "System logs are a normal size" {
		t.Fatalf("%+v", r)
	}
	write(t, filepath.Join(sysRoot, "var", "run", "reboot-required"), "", 0o644)
	if r := one(t, linuxSystem(e)); r.Severity != d.Info || !strings.Contains(r.Title, "restart") {
		t.Fatalf("%+v", r)
	}
}
