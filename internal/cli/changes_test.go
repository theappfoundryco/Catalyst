package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/theappfoundryco/catalyst/internal/state"
)

func TestDiffSaysWhatMovedInWords(t *testing.T) {
	old := state.Snapshot{
		OS:    "Ubuntu 24.04.1 LTS 6.8.0-49-generic",
		Tools: map[string]string{"node": "/usr/bin/node v20.11.1", "python3": "/usr/bin/python3 Python 3.12.3", "go": "/usr/local/go/bin/go go version go1.23.0", "ruby": "/usr/bin/ruby ruby 3.2.3"},
		Path:  []string{"/home/alex/.local/bin", "/usr/bin"},
		Files: map[string]string{"~/.bashrc": "aaaaaaaaaaaa", "~/.zshrc": "", "~/.profile": "bbbbbbbbbbbb"},
	}
	now := state.Snapshot{
		OS:    "Ubuntu 24.04.1 LTS 6.8.0-50-generic",
		Tools: map[string]string{"node": "/home/alex/.volta/bin/node v20.11.1", "python3": "/usr/bin/python3 Python 3.12.7", "go": "/usr/local/go/bin/go go version go1.23.0", "cargo": "/home/alex/.cargo/bin/cargo cargo 1.82.0"},
		Path:  []string{"/home/alex/.volta/bin", "/home/alex/.local/bin", "/usr/bin"},
		Files: map[string]string{"~/.bashrc": "cccccccccccc", "~/.zshrc": "dddddddddddd", "~/.profile": "bbbbbbbbbbbb"},
	}
	got := strings.Join(Diff(old, now), "\n")
	for _, want := range []string{
		"The system changed: Ubuntu 24.04.1 LTS 6.8.0-49-generic is now Ubuntu 24.04.1 LTS 6.8.0-50-generic",
		"cargo appeared: /home/alex/.cargo/bin/cargo cargo 1.82.0",
		"node now runs from /home/alex/.volta/bin/node instead of /usr/bin/node",
		"python3 changed: Python 3.12.3 is now Python 3.12.7",
		"ruby is gone (it was /usr/bin/ruby ruby 3.2.3)",
		"~/.bashrc was edited",
		"~/.zshrc was created",
		"PATH gained /home/alex/.volta/bin",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}
	if strings.Contains(got, "go changed") || strings.Contains(got, ".profile") {
		t.Errorf("unchanged things are not listed:\n%s", got)
	}
	if d := Diff(now, now); len(d) != 0 {
		t.Fatal(d)
	}
}

func TestChangesComparesWithAnEarlierDay(t *testing.T) {
	a, b := testApp(t, "linux")
	a.E.Shell = ""
	a.E.Entries = []string{"/usr/bin"}
	if code := cmdChanges(a, nil); code != ExitOK || !strings.Contains(b.String(), "Nothing to compare with yet") {
		t.Fatal(b.String())
	}
	s := a.snapshot(88)
	s.Date = time.Now().Add(-48 * time.Hour)
	s.Path = []string{"/usr/bin", "/opt/old/bin"}
	a.Store.SaveSnapshot(s)
	b.Reset()
	cmdChanges(a, nil)
	if !strings.Contains(b.String(), "when doctor scored 88") || !strings.Contains(b.String(), "PATH lost /opt/old/bin") {
		t.Fatal(b.String())
	}
}
