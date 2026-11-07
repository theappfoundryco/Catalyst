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

func TestAddAndRemoveLeaveEverythingElseAlone(t *testing.T) {
	rc := filepath.Join(t.TempDir(), ".zshrc")
	orig := "export A=1\n# my comment\nalias x=y\n"
	os.WriteFile(rc, []byte(orig), 0o640)
	if err := Add(rc); err != nil {
		t.Fatal(err)
	}
	if err := Add(rc); err != nil { // twice is the same as once
		t.Fatal(err)
	}
	b, _ := os.ReadFile(rc)
	if strings.Count(string(b), Mark) != 1 || !strings.HasPrefix(string(b), orig) || !strings.Contains(string(b), Line) {
		t.Fatalf("%q", b)
	}
	did, err := Remove(rc)
	if !did || err != nil {
		t.Fatal(did, err)
	}
	b, _ = os.ReadFile(rc)
	if string(b) != orig {
		t.Fatalf("%q", b)
	}
	st, _ := os.Stat(rc)
	if st.Mode().Perm() != 0o640 {
		t.Fatal("mode changed", st.Mode())
	}
	if did, _ := Remove(rc); did {
		t.Fatal("nothing left to remove")
	}
}

func TestFishGetsFishSyntax(t *testing.T) {
	rc := filepath.Join(t.TempDir(), "fish", "config.fish")
	Add(rc)
	b, _ := os.ReadFile(rc)
	if !strings.Contains(string(b), Fish) || strings.Contains(string(b), "export") {
		t.Fatalf("%q", b)
	}
}

func TestRemoveOnlyTakesOurLine(t *testing.T) {
	rc := filepath.Join(t.TempDir(), ".bashrc")
	text := Line + "\nexport B=2\n" // the same line, written by the user, with no mark
	os.WriteFile(rc, []byte(text), 0o644)
	if did, _ := Remove(rc); did {
		t.Fatal("removed the user's own line")
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
