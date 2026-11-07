package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.git", Group: d.GroupTools, Name: "Checking git", Run: gitIdentity})
}

func gitIdentity(e *host.Env) []d.Result {
	p, ok := e.SafeTool("git")
	if !ok {
		return []d.Result{d.Crit("git is not installed")}
	}
	if r := e.Run.Run(0, p, "--version"); !r.OK() {
		return []d.Result{d.Crit(p + " is there but does not run").With(firstLine(r.Stderr))}
	}
	email, _ := e.Out(p, "config", "--global", "user.email")
	name, _ := e.Out(p, "config", "--global", "user.name")
	switch {
	case email == "" || name == "":
		return []d.Result{d.Warn("git does not know your name and email, so commits will fail or look wrong").
			With(`Set them: git config --global user.name "Your Name" and git config --global user.email you@example.com`)}
	case strings.HasSuffix(email, "@example.com"):
		return []d.Result{d.Note("git is set to a placeholder email")}
	}
	return []d.Result{d.Pass("git runs and knows who you are")}
}
