package checks

import (
	"strings"
	"testing"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/run"
)

func TestOpenFileLimit(t *testing.T) {
	cases := []struct {
		out   string
		state d.State
		sev   d.Severity
	}{
		{"256\n", d.Issue, d.Info},              // macOS's default for a new shell
		{"Welcome back!\n1024\n", d.Passed, ""}, // Linux's usual default, after a startup file printed a line
		{"unlimited\n", d.Passed, ""},
		{"", d.Skipped, ""},
	}
	for _, c := range cases {
		e, _ := env(t, "darwin", nil, map[string]run.Result{"/bin/zsh -l -c ulimit -n": {Stdout: c.out}})
		e.Shell = "/bin/zsh"
		r := one(t, openFiles(e))
		if r.State != c.state || r.Severity != c.sev {
			t.Errorf("%q: %+v", c.out, r)
		}
		if c.out == "256\n" && !strings.Contains(r.Hint, "~/.zshrc") {
			t.Errorf("%+v", r)
		}
	}
}
