package ui

import (
	"bytes"
	"strings"
	"testing"
)

func TestPrintable(t *testing.T) {
	for in, want := range map[string]string{
		"node_modules":           "node_modules",
		"ünïcødé 名前":             "ünïcødé 名前",
		"new\nline":              `new\nline`,
		"tab\there":              `tab\there`,
		"x\x1b]0;PWNED\x07":      `x\x1b]0;PWNED\x07`,
		"\x1b[2Jcleared":         `\x1b[2Jcleared`,
		"\x1b]52;c;ZXZpbA==\x07": `\x1b]52;c;ZXZpbA==\x07`,
		"bad\xffbyte":            `bad\xffbyte`,
		"c1\u009bcsi":            `c1\x9bcsi`,
		"\x1b[1;36mours\x1b[0m":  "\x1b[1;36mours\x1b[0m",
		"mark\x1b[3;7770z":       "mark\x1b[3;7770z",
	} {
		if got := Printable(in); got != want {
			t.Errorf("Printable(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLinesNeverCarryAForeignEscape(t *testing.T) {
	var b bytes.Buffer
	u := Plain(&b, 60)
	u.Say("  ~/code/x\x1b]0;PWNED\x07/node_modules")
	u.Say("  ~/code/new\nline")
	if s := b.String(); strings.Contains(s, "\x1b]") || strings.Contains(s, "\x07") || strings.Count(s, "\n") != 2 {
		t.Errorf("output still carries control characters: %q", s)
	}
}

func TestWideCharacters(t *testing.T) {
	if n := Visible("名前"); n != 4 {
		t.Errorf("Visible(名前) = %d, want 4", n)
	}
	if n := Visible("🚀🫠"); n != 4 {
		t.Errorf("Visible(🚀🫠) = %d, want 4", n)
	}
	if n := Visible("é"); n != 1 {
		t.Errorf("an accent on its letter takes %d columns, want 1", n)
	}
	if got := Fit("名前名前名前", 7); got != "名前名…" || Visible(got) > 7 {
		t.Errorf("Fit = %q (%d columns)", got, Visible(got))
	}
	if got := FitPath("~/code/名前名前名前/node_modules", 20); Visible(got) > 20 || !strings.HasSuffix(got, "/node_modules") {
		t.Errorf("FitPath = %q (%d columns)", got, Visible(got))
	}
}
