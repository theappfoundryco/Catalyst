package kit

import (
	"regexp"
	"testing"
)

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func TestEveryMoodDraws(t *testing.T) {
	for _, m := range []string{Idle, Doctor, Scan, Sweep, Happy, Party, Alarm, Sleep, Wag, Blink} {
		rows := Sprites[m]
		if len(rows) == 0 {
			t.Fatalf("%s has no sprite", m)
		}
		for _, r := range rows {
			if len(r) != len(rows[0]) {
				t.Errorf("%s: uneven rows", m)
			}
			for _, c := range []byte(r) {
				if _, ok := Palette[c]; !ok && c != '.' {
					t.Errorf("%s: no colour for %q", m, c)
				}
			}
		}
		for _, truecolor := range []bool{true, false} {
			for _, l := range Render(m, truecolor) {
				if n := len([]rune(ansi.ReplaceAllString(l, ""))); n != Width(m) {
					t.Errorf("%s: %d columns, want %d", m, n, Width(m))
				}
			}
		}
	}
}

func TestAnUnknownMoodStillDraws(t *testing.T) {
	if len(Render("nope", false)) == 0 {
		t.Fatal("nothing drawn")
	}
}
