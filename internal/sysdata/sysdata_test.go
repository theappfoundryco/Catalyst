package sysdata

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/space"
)

func fixed(n int64) Measure { return func(string) int64 { return n } }

func TestLinuxOffersOnlySupportedCommands(t *testing.T) {
	home := t.TempDir()
	e := host.ForTest(home, "linux", &run.Fake{Replies: map[string]run.Result{
		"journalctl --disk-usage": {Stdout: "Archived and active journals take up 1.2G in the file system."},
	}})
	e.Look = func(name string) (string, error) {
		if name == "apt-get" {
			return "/usr/bin/apt-get", nil
		}
		return "", exec.ErrNotFound
	}
	r := Scan(e, nil, fixed(500_000_000))
	var names []string
	for _, a := range r.Areas {
		names = append(names, a.Name)
		if a.Way == Root && len(a.Command) == 0 {
			t.Errorf("%s needs a password but has no command", a.Name)
		}
		if a.Way == Locked && a.Command != nil {
			t.Errorf("%s is locked but carries a command", a.Name)
		}
	}
	want := map[string]bool{"System journal": true, "Downloaded apt packages": true, "Packages nothing needs": true}
	for _, n := range names {
		delete(want, n)
	}
	if len(want) > 0 {
		t.Fatalf("missing %v in %v", want, names)
	}
}

func TestMacOSItselfIsAlwaysLocked(t *testing.T) {
	home := t.TempDir()
	e := host.ForTest(home, "darwin", &run.Fake{Replies: map[string]run.Result{
		"tmutil listlocalsnapshots /": {Stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-11-07-101010.local\ncom.apple.TimeMachine.2026-11-07-111010.local\n"},
	}})
	os.MkdirAll(filepath.Join(home, ".colima"), 0o755)
	sys := &space.System{Sealed: 11e9, Boot: 7e9, Recovery: 1e9, Swap: 6e9}
	r := Scan(e, sys, fixed(4_000_000_000))
	seen := map[string]Area{}
	for _, a := range r.Areas {
		seen[a.Name] = a
	}
	for _, n := range []string{"The sealed system", "Boot files", "Recovery", "Swap and sleep image"} {
		if a, ok := seen[n]; !ok || a.Selectable() {
			t.Errorf("%s: %+v", n, a)
		}
	}
	if a := seen["Time Machine snapshots"]; a.Way != Root || a.Count != 2 {
		t.Errorf("snapshots: %+v", a)
	}
	// Colima's tool is not on this test's PATH, so there is no safe command, and the row is locked.
	if a := seen["Colima's virtual machine"]; a.Way != Locked {
		t.Errorf("colima: %+v", a)
	}
}
