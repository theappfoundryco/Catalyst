package checks

import (
	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.build", Group: d.GroupTools, Name: "Checking build tools", Run: buildTools})
}

func buildTools(e *host.Env) []d.Result {
	if e.Mac() {
		if !e.HasCLT() {
			return []d.Result{d.Crit("Apple's Command Line Tools are not installed").
				With("git, python3 and most compilers need them. Apple's installer opens a window.").
				Manual("xcode-select", "--install")}
		}
		return []d.Result{d.Pass("Apple's Command Line Tools are installed")}
	}
	var missing []string
	for _, t := range []string{"cc", "make"} {
		if _, err := e.Look(t); err != nil {
			missing = append(missing, t)
		}
	}
	if len(missing) > 0 {
		return []d.Result{d.Note("No compiler or make here, so packages that build from source will fail").
			With("Debian or Ubuntu: sudo apt install build-essential. Fedora: sudo dnf group install development-tools.")}
	}
	return []d.Result{d.Pass("Compiler and make are installed")}
}
