package session

import (
	"bytes"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/ui"
)

func editor() *Editor {
	return &Editor{Commands: []Command{{"doctor", "find problems"}, {"disk", "volumes"}, {"sweep", "reclaim"}}}
}

func typeIn(e *Editor, s string) {
	for _, r := range s {
		e.Key(string(r))
	}
}

func TestEnterRunsTheHighlightedCommand(t *testing.T) {
	e := editor()
	typeIn(e, "do")
	if e.Key("enter") != Submit || e.Line() != "doctor" {
		t.Fatal(e.Line())
	}
}

func TestArrowsChoose(t *testing.T) {
	e := editor()
	typeIn(e, "d")
	e.Key("down")
	if e.Line() != "disk" {
		t.Fatal(e.Line())
	}
	e.Key("up")
	e.Key("up")
	if e.Line() != "doctor" {
		t.Fatal(e.Line())
	}
}

func TestTabCompletesThenArgumentsPassThrough(t *testing.T) {
	e := editor()
	typeIn(e, "sw")
	e.Key("tab")
	if e.Text != "sweep " {
		t.Fatalf("%q", e.Text)
	}
	typeIn(e, "--dry-run")
	if e.Matches() != nil || e.Line() != "sweep --dry-run" {
		t.Fatal(e.Line())
	}
}

func TestSlashWorksTooAndUnknownPassesThrough(t *testing.T) {
	e := editor()
	typeIn(e, "/do")
	if e.Line() != "doctor" {
		t.Fatal(e.Line())
	}
	e = editor()
	typeIn(e, "zzz")
	if e.Line() != "zzz" {
		t.Fatal(e.Line())
	}
}

func TestBackspaceEscAndQuit(t *testing.T) {
	e := editor()
	typeIn(e, "dox")
	e.Key("backspace")
	if e.Text != "do" {
		t.Fatal(e.Text)
	}
	e.Key("esc")
	if e.Text != "" {
		t.Fatal(e.Text)
	}
	if e.Key("ctrl-c") != Quit || e.Key("ctrl-d") != Quit {
		t.Fatal("quit")
	}
}

func TestSplitKeepsAnArrowTogetherAndAPasteApart(t *testing.T) {
	if got := split([]byte("\x1b[A")); len(got) != 1 || got[0] != "up" {
		t.Fatal(got)
	}
	if got := split([]byte("doc")); strings.Join(got, "") != "doc" || len(got) != 3 {
		t.Fatal(got)
	}
	if got := split([]byte("do\r")); got[2] != "enter" {
		t.Fatal(got)
	}
}

func TestFrameFitsAtEveryWidth(t *testing.T) {
	var b bytes.Buffer
	u := ui.Plain(&b, 80)
	long := strings.Repeat("words ", 40)
	c := Config{Commands: []Command{{"doctor", long}, {"sweep", long}}, Welcome: Welcome{Lines: []string{long, long}}}
	for _, w := range []int{40, 60, 80, 120} {
		u.FixedW = w
		for _, l := range frameLines(u, c, &Editor{Commands: c.Commands}, "idle", true) {
			if ui.Visible(l) > w {
				t.Errorf("width %d: %d columns: %q", w, ui.Visible(l), l)
			}
		}
	}
}
