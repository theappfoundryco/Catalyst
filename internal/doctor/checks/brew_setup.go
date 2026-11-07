package checks

import (
	"slices"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.brew", Group: d.GroupTools, Name: "Checking Homebrew", OS: "darwin", Run: brewSetup})
}

func brewSetup(e *host.Env) []d.Result { return brewAt(e, host.Exists) }

func brewAt(e *host.Env, exists func(string) bool) []d.Result {
	arm, intel := exists("/opt/homebrew/bin/brew"), exists("/usr/local/bin/brew")
	switch {
	case !arm && !intel:
		return []d.Result{d.Skip("Homebrew is not installed")}
	case e.Arch == "arm64" && !arm:
		return []d.Result{d.Warn("Homebrew is the Intel version on an Apple silicon Mac").With("Everything it installs runs slower, through Rosetta.")}
	}
	dir := "/opt/homebrew/bin"
	if !arm {
		dir = "/usr/local/bin"
	}
	if !slices.Contains(e.Entries, dir) {
		return []d.Result{d.Warn("Homebrew is installed but new terminals cannot find it").
			With(`Add this to your startup file: eval "$(` + dir + `/brew shellenv)"`)}
	}
	return []d.Result{d.Pass("Homebrew is on your PATH")}
}
