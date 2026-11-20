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
		r := d.Note("No compiler or make here, so packages that build from source will fail")
		cmd, advice := e.Platform().Install(host.BuildToolsPkgs)
		if cmd == nil {
			return []d.Result{r.With(advice)}
		}
		if p := e.Platform(); !p.Root && !p.Sudo {
			r = r.With("Run it as root: sudo is not installed here.")
		}
		return []d.Result{r.Manual(asRoot(e, cmd)...)}
	}
	return []d.Result{d.Pass("Compiler and make are installed")}
}

// asRoot puts sudo in front of a command that needs root, unless this already is root (often so in a container) or
// there is no sudo to put there.
func asRoot(e *host.Env, cmd []string) []string {
	if p := e.Platform(); p.Root || !p.Sudo {
		return cmd
	}
	return append([]string{"sudo"}, cmd...)
}
