package checks

import (
	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "shell.rosetta", Group: d.GroupShell, Name: "Checking for Rosetta", OS: "darwin", Run: rosettaShell})
}

// A terminal set to "Open using Rosetta", or started from one, runs everything as Intel. Builds come out for the wrong
// architecture, Homebrew installs into /usr/local, and nothing says so. Catalyst inherits it from the terminal, so
// its own translation is the answer.
func rosettaShell(e *host.Env) []d.Result {
	p := e.Platform()
	if p.Arch != "arm64" {
		return []d.Result{d.Skip("This is an Intel Mac, so there is no Rosetta")}
	}
	if p.Rosetta {
		return []d.Result{d.Warn("This terminal runs as Intel, through Rosetta").
			With("Everything you build or install from it is for Intel and runs slower. In Finder, select your terminal app, choose Get Info, and untick Open using Rosetta. Then open a new window.")}
	}
	return []d.Result{d.Pass("This terminal runs natively on Apple silicon")}
}
