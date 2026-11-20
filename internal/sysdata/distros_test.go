package sysdata

import (
	"os/exec"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/run"
)

// Recorded from snapd on Ubuntu 24.04, trimmed.
const snapList = `Name                       Version                         Rev    Tracking         Publisher    Notes
bare                       1.0                             5      latest/stable    canonical**  base
core22                     20261022                        3129   latest/stable    canonical**  base
firefox                    158.0-2                         9057   latest/stable/…  mozilla**    -
core22                     20260901                        3010   latest/stable    canonical**  base,disabled
snap-store                 0+git.d029eeda                  1504   2/stable/…       canonical**  disabled
snap-store                 0+git.319ac514                  1509   2/stable/…       canonical**  -
`

func TestParseSnapDisabled(t *testing.T) {
	got := ParseSnapDisabled(snapList)
	if len(got) != 2 || got[0] != (SnapRevision{"core22", "3010"}) || got[1] != (SnapRevision{"snap-store", "1504"}) {
		t.Fatalf("%+v", got)
	}
	if len(ParseSnapDisabled("")) != 0 {
		t.Fatal("empty")
	}
}

func linuxWith(tools []string, replies map[string]run.Result) *host.Env {
	e := host.ForTest("/home/alex", "linux", &run.Fake{Replies: replies})
	e.Look = func(name string) (string, error) {
		for _, x := range tools {
			if x == name {
				return "/usr/bin/" + name, nil
			}
		}
		return "", exec.ErrNotFound
	}
	return e
}

func TestEachFamilyGetsItsOwnCommands(t *testing.T) {
	defer func(f func(string) bool) { Exists = f }(Exists)
	Exists = func(p string) bool { return strings.HasPrefix(p, "/var/cache/") }
	cases := map[string][]string{
		"dnf":         {"dnf clean all", "dnf autoremove"},
		"pacman":      {"pacman -Sc"},
		"zypper":      {"zypper clean --all"},
		"apk":         {"apk cache clean"},
		"xbps-remove": {"xbps-remove -O", "xbps-remove -o"},
	}
	for tool, want := range cases {
		e := linuxWith([]string{tool}, nil)
		var cmds []string
		for _, a := range Scan(e, nil, fixed(500_000_000)).Areas {
			if a.Command != nil {
				cmds = append(cmds, strings.Join(a.Command, " "))
			}
		}
		for _, w := range want {
			if !strings.Contains(strings.Join(cmds, "|"), w) {
				t.Errorf("%s: missing %q in %v", tool, w, cmds)
			}
		}
	}
	e := linuxWith([]string{"pacman", "paccache"}, nil)
	n := 0
	for _, a := range Scan(e, nil, fixed(500_000_000)).Areas {
		if a.Name == "Downloaded pacman packages" {
			n++
			if a.Command[0] != "paccache" {
				t.Errorf("paccache keeps recent versions, so it wins: %v", a.Command)
			}
		}
	}
	if n != 1 {
		t.Fatalf("one pacman cache, not %d", n)
	}
}

func TestOldSnapVersionsAreShownWithTheirCommands(t *testing.T) {
	e := linuxWith([]string{"snap"}, map[string]run.Result{"snap list --all": {Stdout: snapList}})
	for _, a := range Scan(e, nil, fixed(0)).Areas {
		if a.Name == "Old snap versions" {
			if a.Count != 2 || a.Way != Locked || a.Command != nil || !strings.Contains(a.Cost, "sudo snap remove core22 --revision=3010") {
				t.Fatalf("%+v", a)
			}
			return
		}
	}
	t.Fatal("not shown")
}
