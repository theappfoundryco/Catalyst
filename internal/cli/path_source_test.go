package cli

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNamesFolder(t *testing.T) {
	cases := []struct {
		line, dir string
		want      bool
	}{
		{`export PATH="/usr/bin:$PATH"`, "/usr/bin", true},
		{`export PATH=$HOME/.cargo/bin:$PATH`, "$HOME/.cargo/bin", true},
		{`[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"`, "/usr/bin", false},
		{`eval "$(/opt/homebrew/bin/brew shellenv)"`, "/opt/homebrew/bin", true},
		{`fish_add_path ~/.local/bin`, "~/.local/bin", true},
		{`alias ll="/usr/local/bin/eza -l"`, "/usr/local/bin", false},
		{`PATH=/usr/local/bin/extra:/usr/local/bin`, "/usr/local/bin", true},
		{`export PATH=/opt/a/bin:$PATH`, "/bin", false},
		{`export PATH=/opt/a/bin:/bin:$PATH`, "/bin", true},
		{`set -gx PATH "$HOME/go/bin" $PATH`, "$HOME/go/bin", true},
	}
	for _, c := range cases {
		if got := NamesFolder(c.line, c.dir); got != c.want {
			t.Errorf("%q in %q: %v", c.dir, c.line, got)
		}
	}
}

// Debian's ~/.profile names ~/bin inside "if [ -d", so when ~/bin does not exist, the line that really added it is the
// one to blame, not the guarded one that comes first.
func TestPathSourceSkipsALineGuardedByExistence(t *testing.T) {
	a, _ := testApp(t, "linux")
	home := a.E.Home
	os.WriteFile(filepath.Join(home, ".profile"), []byte("if [ -d \"$HOME/bin\" ] ; then\n    PATH=\"$HOME/bin:$PATH\"\nfi\n[ -d \"$HOME/opt\" ] && PATH=\"$HOME/opt:$PATH\"\n"), 0o644)
	os.WriteFile(filepath.Join(home, ".bashrc"), []byte("# mine\nexport PATH=\"$HOME/bin:$HOME/opt:$PATH\"\n"), 0o644)
	for _, dir := range []string{"bin", "opt"} {
		if rc, line := a.pathSource(filepath.Join(home, dir)); rc != filepath.Join(home, ".bashrc") || line != 2 {
			t.Errorf("missing ~/%s: blamed %s line %d", dir, rc, line)
		}
	}
	os.Mkdir(filepath.Join(home, "bin"), 0o755)
	if rc, line := a.pathSource(filepath.Join(home, "bin")); rc != filepath.Join(home, ".profile") || line != 2 {
		t.Errorf("an existing ~/bin is added by .profile first: %s line %d", rc, line)
	}
}
