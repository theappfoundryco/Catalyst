package checks

import (
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Recorded from systemd 252 (Debian 12) and 255 (Ubuntu 24.04), and the off case as timedatectl prints it.
func TestClockSync(t *testing.T) {
	q := "timedatectl show -p NTP -p NTPSynchronized -p CanNTP"
	cases := []struct {
		out   string
		state d.State
	}{
		{"CanNTP=yes\nNTP=yes\nNTPSynchronized=yes\n", d.Passed},
		{"CanNTP=yes\nNTP=no\nNTPSynchronized=yes\n", d.Passed}, // chrony or ntpd keep it in sync
		{"CanNTP=yes\nNTP=no\nNTPSynchronized=no\n", d.Issue},
		{"CanNTP=yes\nNTP=yes\nNTPSynchronized=no\n", d.Skipped},
		{"CanNTP=no\nNTP=no\nNTPSynchronized=no\n", d.Skipped},
	}
	for _, c := range cases {
		e, _ := env(t, "linux", map[string]string{"timedatectl": "/usr/bin/timedatectl"}, map[string]run.Result{q: {Stdout: c.out}})
		e.SetPlatform(host.Platform{OS: "linux", Sudo: true})
		r := one(t, clockSync(e))
		if r.State != c.state {
			t.Errorf("%q: %+v", c.out, r)
		}
		if r.State == d.Issue && r.Fix.Preview() != "sudo timedatectl set-ntp true" {
			t.Errorf("%+v", r.Fix)
		}
	}
	e, _ := env(t, "linux", map[string]string{"timedatectl": "/usr/bin/timedatectl"}, nil)
	e.SetPlatform(host.Platform{OS: "linux", Container: "docker"})
	if r := one(t, clockSync(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
}
