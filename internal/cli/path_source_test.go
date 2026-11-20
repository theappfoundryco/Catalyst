package cli

import "testing"

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
	}
	for _, c := range cases {
		if got := NamesFolder(c.line, c.dir); got != c.want {
			t.Errorf("%q in %q: %v", c.dir, c.line, got)
		}
	}
}
