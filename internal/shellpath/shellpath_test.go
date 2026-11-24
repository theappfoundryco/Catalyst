package shellpath

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRCFile(t *testing.T) {
	cases := []struct{ shell, goos, zdot, want string }{
		{"/bin/zsh", "darwin", "", "/h/.zshrc"}, {"/bin/zsh", "linux", "/z", "/z/.zshrc"},
		{"/bin/bash", "darwin", "", "/h/.bash_profile"}, {"/bin/bash", "linux", "", "/h/.bashrc"},
		{"/usr/bin/fish", "linux", "", "/h/.config/fish/config.fish"}, {"", "linux", "", "/h/.profile"},
	}
	for _, c := range cases {
		if got := RCFile("/h", c.shell, c.goos, c.zdot); got != c.want {
			t.Errorf("%+v: %s", c, got)
		}
	}
}

func add(text string, fish bool) string {
	return strings.Join(AddLines(strings.Split(text, "\n"), fish), "\n")
}

func remove(text string) (string, string) {
	out, kept := RemoveLines(strings.Split(text, "\n"))
	return strings.Join(out, "\n"), kept
}

func TestAddAndRemoveLeaveEverythingElseAlone(t *testing.T) {
	for _, orig := range []string{"export A=1\n# my comment\nalias x=y\n", ""} {
		got := add(orig, false)
		if add(got, false) != got { // twice is the same as once
			t.Fatal("added twice")
		}
		if strings.Count(got, Mark) != 1 || !strings.HasPrefix(got, orig) || !strings.Contains(got, Line) || !Has(got) {
			t.Fatalf("%q", got)
		}
		back, kept := remove(got)
		if back != orig || kept != "" {
			t.Fatalf("%q came back as %q", orig, back)
		}
		if again, _ := remove(back); again != back {
			t.Fatal("nothing left to remove")
		}
	}
}

// A last line with no line break would have had our mark glued onto it, which is how }export PATH=... happens.
func TestAddNeverGluesOntoALastLineWithoutABreak(t *testing.T) {
	got := add("greet() {\n  echo hi\n}", false)
	want := "greet() {\n  echo hi\n}\n\n" + Mark + "\n" + Line + "\n"
	if got != want {
		t.Fatalf("%q", got)
	}
}

func TestFishGetsFishSyntax(t *testing.T) {
	got := add("", true)
	if !strings.Contains(got, Fish) || strings.Contains(got, "export") {
		t.Fatalf("%q", got)
	}
}

func TestRemoveOnlyTakesOurLine(t *testing.T) {
	text := Line + "\nexport B=2\n" // the same line, written by the user, with no mark
	if got, _ := remove(text); got != text || Has(text) {
		t.Fatal("took the user's own line")
	}
}

// Check and remove must agree on what our line is, or path says ready while remove finds nothing to take.
func TestAMarkGluedOntoABraceIsStillOursAndTheBraceStays(t *testing.T) {
	text := "greet() {\n  echo hi\n}" + Mark + "\n" + Line + "\n"
	if !Has(text) {
		t.Fatal("not seen")
	}
	got, _ := remove(text)
	if got != "greet() {\n  echo hi\n}\n" {
		t.Fatalf("%q", got)
	}
}

func TestALineChangedByHandUnderTheMarkStays(t *testing.T) {
	mine := `export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"`
	got, kept := remove(Mark + "\n" + mine + "\n")
	if got != mine+"\n" || kept != mine {
		t.Fatalf("%q, kept %q", got, kept)
	}
}

func TestWindowsLineEndingsStillMatch(t *testing.T) {
	text := "alias a=b\r\n\r\n" + Mark + "\r\n" + Line + "\r\n"
	got, _ := remove(text)
	if got != "alias a=b\r\n" {
		t.Fatalf("%q", got)
	}
}

func TestCheck(t *testing.T) {
	dir := t.TempDir()
	self := filepath.Join(dir, "self")
	other := filepath.Join(dir, "other")
	os.WriteFile(self, nil, 0o755)
	os.WriteFile(other, nil, 0o755)
	none := func(string) (string, error) { return "", errors.New("no") }
	if s := Check(dir, "/bin/zsh", "linux", "", nil, self, none); s.State != "missing" {
		t.Fatal(s)
	}
	if s := Check(dir, "/bin/zsh", "linux", "", []string{filepath.Join(dir, ".local/bin")}, self, none); s.State != "ready" {
		t.Fatal(s)
	}
	found := func(p string) func(string) (string, error) {
		return func(string) (string, error) { return p, nil }
	}
	if s := Check(dir, "/bin/zsh", "linux", "", nil, self, found(self)); s.State != "ready" {
		t.Fatal(s)
	}
	if s := Check(dir, "/bin/zsh", "linux", "", nil, self, found(other)); s.State != "clash" || s.Found != other {
		t.Fatal(s)
	}
}
