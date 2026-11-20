package sysdata

import (
	"os"
	"os/exec"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// A tool's own cache is offered only through that tool, and is locked when the tool is gone.
func TestToolCachesUseTheirOwnCommand(t *testing.T) {
	home := t.TempDir()
	for _, d := range []string{"go/pkg/mod", ".local/share/pnpm/store", ".cache/uv", "Library/Caches/CocoaPods"} {
		os.MkdirAll(home+"/"+d, 0o755)
	}
	e := host.ForTest(home, "linux", &run.Fake{Replies: map[string]run.Result{"go env GOMODCACHE": {Stdout: home + "/go/pkg/mod\n"}}})
	e.Look = func(name string) (string, error) {
		if name == "go" || name == "uv" {
			return "/usr/bin/" + name, nil
		}
		return "", exec.ErrNotFound
	}
	got := map[string]Area{}
	for _, a := range Scan(e, nil, fixed(2_000_000_000)).Areas {
		got[a.Name] = a
	}
	if a := got["Go module cache"]; a.Way != Owner || len(a.Command) != 3 || a.Command[1] != "clean" {
		t.Fatalf("%+v", a)
	}
	if a := got["uv cache"]; a.Way != Owner || a.Command[0] != "uv" {
		t.Fatalf("%+v", a)
	}
	if a := got["pnpm store"]; a.Way != Locked || a.Command != nil {
		t.Fatalf("pnpm is not installed, so its store is locked: %+v", a)
	}
	if _, ok := got["CocoaPods cache"]; ok {
		t.Fatal("CocoaPods is a Mac cache")
	}
}
