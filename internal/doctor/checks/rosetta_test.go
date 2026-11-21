package checks

import (
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func TestRosettaShell(t *testing.T) {
	e, _ := env(t, "darwin", nil, nil)
	e.SetPlatform(host.Platform{OS: "darwin", Arch: "arm64", Rosetta: true})
	if r := one(t, rosettaShell(e)); r.Severity != d.Warning {
		t.Fatalf("%+v", r)
	}
	e.SetPlatform(host.Platform{OS: "darwin", Arch: "arm64"})
	if r := one(t, rosettaShell(e)); r.State != d.Passed {
		t.Fatalf("%+v", r)
	}
	e.SetPlatform(host.Platform{OS: "darwin", Arch: "amd64"})
	if r := one(t, rosettaShell(e)); r.State != d.Skipped {
		t.Fatalf("%+v", r)
	}
}

// The platform reader takes the hardware's answer, not the binary's: an Intel build under Rosetta still reports arm64.
func TestPlatformReadsRosettaFromSysctl(t *testing.T) {
	f := &run.Fake{Replies: map[string]run.Result{
		"sw_vers -productVersion":          {Stdout: "15.1\n"},
		"sysctl -n hw.optional.arm64":      {Stdout: "1\n"},
		"sysctl -n sysctl.proc_translated": {Stdout: "1\n"},
	}}
	e := host.ForTest(t.TempDir(), "darwin", f)
	e.Arch = "amd64"
	p := host.ReadPlatform("/", e)
	if p.Arch != "arm64" || !p.Rosetta || p.MacVersion != "15.1" || p.Pretty != "macOS 15.1" {
		t.Fatalf("%+v", p)
	}
}
