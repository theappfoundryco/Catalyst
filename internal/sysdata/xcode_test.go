package sysdata

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func TestXcodeLeftovers(t *testing.T) {
	home := t.TempDir()
	for _, d := range []string{"iOS DeviceSupport/17.5 (21F79)", "watchOS DeviceSupport/10.5", "Archives/2026-01-02"} {
		os.MkdirAll(filepath.Join(home, "Library", "Developer", "Xcode", d), 0o755)
	}
	e := host.ForTest(home, "darwin", &run.Fake{})
	seen := map[string]Area{}
	for _, a := range Scan(e, nil, fixed(3_000_000_000)).Areas {
		seen[a.Name] = a
	}
	if a := seen["Xcode iOS DeviceSupport"]; a.Way != Trash || !a.Selectable() {
		t.Errorf("device support rebuilds when the device connects again: %+v", a)
	}
	if _, ok := seen["Xcode watchOS DeviceSupport"]; !ok {
		t.Error("watchOS")
	}
	if _, ok := seen["Xcode tvOS DeviceSupport"]; ok {
		t.Error("tvOS is not there")
	}
	if a := seen["Xcode archives"]; a.Way != Locked || a.Selectable() {
		t.Errorf("archives are someone's chosen builds: %+v", a)
	}
}
