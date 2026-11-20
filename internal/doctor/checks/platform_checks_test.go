package checks

import (
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func TestInsideAContainerHostOwnedChecksSkipWithAReason(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"ufw": "/usr/sbin/ufw", "systemctl": "/usr/bin/systemctl"}, nil)
	e.SetPlatform(host.Platform{OS: "linux", Container: "docker", Pretty: "Debian GNU/Linux 12 (bookworm)"})
	for name, fn := range map[string]func(*host.Env) []d.Result{"firewall": firewall, "startup": startupItems, "system": linuxSystem} {
		r := one(t, fn(e))
		if r.State != d.Skipped || !strings.Contains(r.Title, "container") {
			t.Errorf("%s: %+v", name, r)
		}
	}
}

func TestServicesRunByAnotherInitSaySo(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	e.SetPlatform(host.Platform{OS: "linux", Init: "openrc"})
	if r := one(t, startupItems(e)); r.State != d.Skipped || r.Title != "Services here are run by openrc, not systemd" {
		t.Fatalf("%+v", r)
	}
}

func TestBuildToolsSuggestsThisDistributionsPackage(t *testing.T) {
	e, _ := env(t, "linux", nil, nil)
	e.SetPlatform(host.Platform{OS: "linux", ID: "fedora", Family: "fedora", Sudo: true, Managers: []string{"dnf"}})
	r := one(t, buildTools(e))
	if r.Fix == nil || r.Fix.Preview() != "sudo dnf install -y @development-tools" {
		t.Fatalf("%+v", r.Fix)
	}
	e.SetPlatform(host.Platform{OS: "linux", ID: "alpine", Family: "alpine", Root: true, Managers: []string{"apk"}})
	if r := one(t, buildTools(e)); r.Fix.Preview() != "apk add build-base" {
		t.Fatalf("root needs no sudo: %+v", r.Fix)
	}
	e.SetPlatform(host.Platform{OS: "linux", ID: "alpine", Family: "alpine", Managers: []string{"apk"}})
	if r := one(t, buildTools(e)); r.Fix.Preview() != "apk add build-base" || !strings.Contains(r.Hint, "sudo is not installed") {
		t.Fatalf("no sudo: %+v", r)
	}
	e.SetPlatform(host.Platform{OS: "linux", Family: "unknown", Managers: []string{}})
	if r := one(t, buildTools(e)); r.Fix != nil || !strings.Contains(r.Hint, "No package manager here") {
		t.Fatalf("%+v", r)
	}
}

func TestASystemContainerChecksItsOwnServices(t *testing.T) {
	e, _ := env(t, "linux", map[string]string{"systemctl": "/usr/bin/systemctl"}, map[string]run.Result{
		"systemctl --failed --no-legend --plain":        {Stdout: "broken.service loaded failed failed broken.service\n"},
		"systemctl --user --failed --no-legend --plain": {Code: 1},
	})
	e.SetPlatform(host.Platform{OS: "linux", Container: "docker", Init: "systemd"})
	rs := startupItems(e)
	if len(rs) != 1 || rs[0].Title != "broken.service has failed" {
		t.Fatalf("%+v", rs)
	}
}
