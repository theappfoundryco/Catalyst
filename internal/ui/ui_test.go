package ui

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

func TestFitDropsBracketsFirst(t *testing.T) {
	if got := Fit("Downloading the apps (the first time takes minutes)", 25); got != "Downloading the apps" {
		t.Fatalf("got %q", got)
	}
	if got := Fit("short", 25); got != "short" {
		t.Fatalf("got %q", got)
	}
	if got := Fit("a very long line with no brackets", 12); Visible(got) > 12 || !strings.HasSuffix(got, "…") {
		t.Fatalf("got %q", got)
	}
}

func TestVisibleIgnoresColour(t *testing.T) {
	if n := Visible("\033[1;36mhello\033[0m"); n != 5 {
		t.Fatalf("got %d", n)
	}
}

// Output wider than the terminal wraps and stacks on every redraw, which is how the installer learned this rule.
func TestNothingIsWiderThanTheWindow(t *testing.T) {
	long := "This is a long sentence that goes on for a while and needs to wrap around at the edge of a narrow window"
	for _, w := range []int{40, 80, 120} {
		var b bytes.Buffer
		u := Plain(&b, w)
		u.Ok(long)
		u.Warn(long)
		u.Stop(long)
		u.Note(long)
		u.Hint(long)
		u.Say("  " + long)
		u.Row("Label", long)
		u.Hdr("Title")
		for _, l := range strings.Split(b.String(), "\n") {
			if Visible(l) > w && !strings.Contains(l, "Health") && !strings.HasPrefix(l, "  This is") {
				t.Errorf("width %d: %d columns: %q", w, Visible(l), l)
			}
		}
	}
}

func TestWordsWithoutColourSymbolsWithIt(t *testing.T) {
	var plain, color bytes.Buffer
	p := Plain(&plain, 80)
	p.Ok("x")
	c := &UI{Out: &color, Color: true, FixedW: 80}
	c.Ok("x")
	if !strings.HasPrefix(plain.String(), "  ok") {
		t.Fatalf("plain: %q", plain.String())
	}
	if !strings.Contains(color.String(), "✓") {
		t.Fatalf("colour: %q", color.String())
	}
}

func TestSizes(t *testing.T) {
	cases := map[int64]string{500: "500 bytes", 2_400_000_000: "2.4 GB", 12_000_000: "12 MB"}
	for in, want := range cases {
		if got := Size(in); got != want {
			t.Errorf("%d: got %q", in, got)
		}
	}
	if got := RAM(8 * 1024 * 1024 * 1024); got != "8 GB" {
		t.Errorf("RAM: %q", got)
	}
}

func TestTwelveHourTimes(t *testing.T) {
	d := time.Date(2026, 3, 4, 16, 30, 0, 0, time.UTC)
	if got := When(d); got != "Mar 4, 4:30 PM" {
		t.Fatalf("got %q", got)
	}
}

func TestAgo(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	if got := Ago(now.Add(-40*24*time.Hour), now); got != "5 weeks" {
		t.Errorf("got %q", got)
	}
	if got := Ago(now.Add(-240*24*time.Hour), now); got != "8 months" {
		t.Errorf("got %q", got)
	}
}

func testMenu() *Menu {
	return &Menu{Noun: "folder", Nouns: "folders", Action: "sweep", Items: []Item{
		{Label: "alpha / node_modules", Right: "about 2 GB, idle 8 months", About: "Node packages", Size: 2_000_000_000, Picked: true},
		{Label: "a project with a very long name that will not fit / target", Right: "about 9 GB, idle 5 months", About: "Rust", Size: 9_000_000_000},
		{Label: "gamma / .venv", Right: "about 1 GB, idle 3 weeks", About: "Python", Size: 1_000_000_000},
	}}
}

func TestMenuKeys(t *testing.T) {
	m := testMenu()
	if m.key("down"); m.cur != 1 {
		t.Fatal("down")
	}
	if m.key(" "); !m.Items[1].Picked {
		t.Fatal("space")
	}
	if n, total := m.picked(); n != 2 || total != 11_000_000_000 {
		t.Fatalf("picked %d %d", n, total)
	}
	m.key("a") // something is ticked, so a means none
	if n, _ := m.picked(); n != 0 {
		t.Fatal("a to none")
	}
	m.key("a")
	if n, _ := m.picked(); n != 3 {
		t.Fatal("a to all")
	}
	if !m.key("enter") || m.cancelled {
		t.Fatal("enter")
	}
	m = testMenu()
	if !m.key("q") || !m.cancelled {
		t.Fatal("q")
	}
	m.key("up")
	if m.cur != len(m.Items)-1 {
		t.Fatal("up from the top goes round to the bottom")
	}
}

func TestMenuFitsAndScrolls(t *testing.T) {
	var items []Item
	for i := 0; i < 40; i++ {
		items = append(items, Item{Label: strings.Repeat("x", 80), Right: "about 2 GB", About: strings.Repeat("y", 200), Size: 1})
	}
	m := &Menu{Items: items, Noun: "folder", Nouns: "folders", Action: "sweep"}
	u := Plain(&bytes.Buffer{}, 60)
	for _, size := range [][2]int{{60, 12}, {80, 24}, {120, 40}} {
		m.cur = 25
		lines := m.frame(u, size[0], size[1])
		if len(lines) > size[1]-1 {
			t.Errorf("%v: %d lines", size, len(lines))
		}
		for _, l := range lines {
			if Visible(l) > size[0] {
				t.Errorf("%v: %d columns: %q", size, Visible(l), l)
			}
		}
		joined := strings.Join(lines, "\n")
		if !strings.Contains(joined, "Selected") && !strings.Contains(joined, "Nothing selected") {
			t.Errorf("%v: no total", size)
		}
	}
}

// The sizes used to sit at the far edge of a wide window, a long way from the names they belong to.
func TestMenuKeepsSizesBesideTheNames(t *testing.T) {
	m := &Menu{Noun: "folder", Nouns: "folders", Action: "sweep", Items: []Item{{Label: "pip cache", Right: "about 1 GB", About: "x"}}}
	for _, l := range m.frame(Plain(&bytes.Buffer{}, 200), 200, 40) {
		if strings.Contains(l, "about 1 GB") && strings.Index(l, "about 1 GB") > 25 {
			t.Fatalf("too far away: %q", l)
		}
	}
}

func TestTitleTakesThePlaceOfTheFirstHeadingOnly(t *testing.T) {
	var b bytes.Buffer
	u := Plain(&b, 80)
	u.Title("Disk")
	u.Hdr("Disks")
	u.Hdr("Drive health")
	if s := b.String(); !strings.Contains(s, "Catalyst › Disk") || strings.Contains(s, "Disks") || !strings.Contains(s, "Drive health") {
		t.Fatal(s)
	}
}

func TestSqueezeKeepsOneBlankLine(t *testing.T) {
	var b bytes.Buffer
	w := Squeeze(&b)
	w.Write([]byte("one\n\n\n\n"))
	w.Write([]byte("\r\033[K\n\n"))
	w.Write([]byte("two\n"))
	if got := strings.ReplaceAll(strings.ReplaceAll(b.String(), "\r", ""), "\033[K", ""); got != "one\n\ntwo\n" {
		t.Fatalf("%q", got)
	}
	b.Reset()
	w = Squeeze(&b)
	w.Write([]byte("\n\nfirst\n")) // nothing above it, so no blank lines are owed
	if b.String() != "first\n" {
		t.Fatalf("%q", b.String())
	}
}

func TestKeysSplitsWhatArrivesTogether(t *testing.T) {
	got := Keys([]byte("\x1b[B\x1b[B\r"))
	if strings.Join(got, ",") != "down,down,enter" {
		t.Fatal(got)
	}
	if got := Keys([]byte("\x1b")); len(got) != 1 || got[0] != "esc" {
		t.Fatal(got)
	}
	if got := Keys([]byte("\x1b[1;2A")); len(got) != 0 {
		t.Fatal(got)
	}
	if got := Keys([]byte("aé")); strings.Join(got, ",") != "a,é" {
		t.Fatal(got)
	}
	if got := Keys(nil); len(got) != 0 {
		t.Fatal(got)
	}
}

func TestReadKey(t *testing.T) {
	cases := map[string]string{"\x1b[A": "up", "\x1b[B": "down", "\x1bOA": "up", "\r": "enter", "\x03": "ctrl-c", "\t": "tab", "\x7f": "backspace", "\x1b": "esc", "a": "a"}
	for in, want := range cases {
		if got := ReadKey([]byte(in)); got != want {
			t.Errorf("%q: got %q", in, got)
		}
	}
}
