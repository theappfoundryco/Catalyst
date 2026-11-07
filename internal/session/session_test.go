package session

import (
	"bytes"
	"strings"
	"testing"

	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func picker() *Picker {
	return &Picker{Items: []Item{
		{Name: "Doctor", Help: "find problems", Args: []string{"doctor"}},
		{Name: "Sweep", Help: "reclaim", Args: []string{"sweep"}},
		{Name: "More", Help: "the rest", Gap: true, Sub: []Item{{Name: "History", Args: []string{"log"}}}},
	}}
}

// Moving to a row and pressing Enter has to open that row. In 0.1.0 it did nothing unless something had been typed.
func TestEnterOpensWhatIsHighlightedWithNothingTyped(t *testing.T) {
	p := picker()
	if p.Key("down") != Keep {
		t.Fatal("moving is not a choice")
	}
	if p.Key("enter") != Open || p.Items[p.Cur].Args[0] != "sweep" {
		t.Fatal(p.Cur)
	}
}

func TestEnterOnTheFirstRowWithoutMoving(t *testing.T) {
	p := picker()
	if p.Key("enter") != Open || p.Items[p.Cur].Name != "Doctor" {
		t.Fatal(p.Cur)
	}
}

func TestArrowsGoRoundBothEnds(t *testing.T) {
	p := picker()
	p.Key("up")
	if p.Cur != 2 {
		t.Fatal(p.Cur)
	}
	p.Key("down")
	if p.Cur != 0 {
		t.Fatal(p.Cur)
	}
	p.Key("j")
	if p.Cur != 1 {
		t.Fatal(p.Cur)
	}
	p.Key("k")
	if p.Cur != 0 {
		t.Fatal(p.Cur)
	}
}

func TestLettersDoNothingBecauseThereIsNothingToType(t *testing.T) {
	p := picker()
	for _, k := range []string{"d", "o", "/", " ", "tab", "backspace", ""} {
		if p.Key(k) != Keep || p.Cur != 0 {
			t.Fatalf("%q", k)
		}
	}
}

func TestLeaving(t *testing.T) {
	p := picker()
	if p.Key("q") != Leave || p.Key("esc") != Back || p.Key("left") != Back || p.Key("ctrl-c") != Quit || p.Key("ctrl-d") != Quit {
		t.Fatal("keys")
	}
}

func header(long string) Header {
	return Header{Lines: []string{"Catalyst v1", long, "", "Health 90", long}}
}

func bigList(long string) []Item {
	var items []Item
	for i := 0; i < 14; i++ {
		items = append(items, Item{Name: "Item", Help: long, Gap: i%4 == 0})
	}
	return items
}

// A line wider than the window wraps, and a screen taller than it scrolls. Either one breaks every redraw after it.
func TestFrameFitsAtEverySize(t *testing.T) {
	long := strings.Repeat("words ", 40)
	for _, size := range [][2]int{{20, 6}, {30, 8}, {40, 10}, {60, 12}, {80, 24}, {100, 30}, {200, 60}, {80, 0}} {
		cols, rows := size[0], size[1]
		var b bytes.Buffer
		u := ui.Plain(&b, cols)
		u.Mascot = true
		p := &Picker{Items: bigList(long), Cur: 9}
		lines := frame(u, p, func(withKit bool) []string {
			return headerLines(u, header(long), kit.Idle, withKit && cols >= minForKit, cols)
		}, "↑ ↓ move   Enter open   q quit", cols, rows)
		limit := rows - 1
		if rows == 0 {
			limit = 23
		}
		if len(lines) > limit {
			t.Errorf("%v: %d lines", size, len(lines))
		}
		for _, l := range lines {
			if ui.Visible(l) > cols {
				t.Errorf("%v: %d columns: %q", size, ui.Visible(l), l)
			}
		}
		if !strings.Contains(strings.Join(lines, "\n"), "›") {
			t.Errorf("%v: the cursor's row scrolled out of view", size)
		}
	}
}

// The text beside Kit must not move when the mood changes, and no mood may be wider than the room it has.
func TestEveryMoodFitsTheSameSlot(t *testing.T) {
	u := ui.Plain(&bytes.Buffer{}, 100)
	for mood := range kit.Sprites {
		if w := kit.Width(mood); w > kitColumns {
			t.Fatalf("%s is %d wide, and the slot is %d", mood, w, kitColumns)
		}
		lines := headerLines(u, Header{Lines: []string{"name"}}, mood, true, 100)
		if len(lines) != kitRows {
			t.Fatalf("%s: %d lines", mood, len(lines))
		}
		last := lines[kitRows-1]
		if at := ui.Visible(last[:strings.Index(last, "name")]); at != 2+kitColumns+2 {
			t.Fatalf("%s: text starts at column %d", mood, at)
		}
	}
}

func TestShortWindowDropsKitBeforeTheList(t *testing.T) {
	u := ui.Plain(&bytes.Buffer{}, 80)
	p := &Picker{Items: bigList("help")}
	kitUsed := false
	top := func(withKit bool) []string {
		kitUsed = withKit
		return headerLines(u, header("x"), kit.Idle, withKit, 80)
	}
	frame(u, p, top, "keys", 80, 16)
	if kitUsed {
		t.Fatal("kept Kit in a window too short for it")
	}
	frame(u, p, top, "keys", 80, 40)
	if !kitUsed {
		t.Fatal("dropped Kit with plenty of room")
	}
}

func TestDisabledRowsArePassedOver(t *testing.T) {
	p := &Picker{Items: []Item{{Name: "A"}, {Name: "Undo", Disabled: true}, {Name: "C"}}}
	p.Key("down")
	if p.Cur != 2 {
		t.Fatal(p.Cur)
	}
	p.Key("up")
	if p.Cur != 0 {
		t.Fatal(p.Cur)
	}
	p.Cur = 1
	if p.Key("enter") != Keep {
		t.Fatal("opened a disabled row")
	}
	p.Settle()
	if p.Cur != 2 {
		t.Fatal(p.Cur)
	}
	all := &Picker{Items: []Item{{Name: "A", Disabled: true}}}
	all.Key("down") // must not loop forever
	all.Settle()
}

func TestDetailSitsUnderItsRowAndFits(t *testing.T) {
	u := ui.Plain(&bytes.Buffer{}, 40)
	p := &Picker{Items: []Item{{Name: "Undo", Help: "reverse", Detail: strings.Repeat("moved things ", 10)}, {Name: "Disk"}}}
	rows, _ := p.rows(u, 40)
	if len(rows) != 3 || !strings.Contains(rows[1], "└") {
		t.Fatal(rows)
	}
	for _, r := range rows {
		if ui.Visible(r) > 40 {
			t.Fatalf("%d columns: %q", ui.Visible(r), r)
		}
	}
}
