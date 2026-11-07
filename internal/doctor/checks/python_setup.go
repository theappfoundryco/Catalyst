package checks

import (
	"regexp"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.python", Group: d.GroupTools, Name: "Checking Python", Run: pythonSetup})
}

var pipFrom = regexp.MustCompile(` from (.+?) \(python`)

func pythonSetup(e *host.Env) []d.Result {
	py, ok := e.SafeTool("python3")
	if !ok {
		return []d.Result{d.Skip("Python is not installed")}
	}
	var out []d.Result
	if e.Mac() {
		if exe, ok := e.Out(py, "-c", "import sys; print(sys.executable)"); ok {
			if strings.HasPrefix(exe, "/usr/bin/python") || strings.HasPrefix(exe, "/Library/Developer/") {
				out = append(out, d.Warn("python3 is Apple's own copy").With("Installing packages into it is restricted and can break system tools. brew install python, or uv, gives you your own."))
			}
		}
	}
	// pip3 quietly belonging to another Python is why "I installed it but cannot import it" happens.
	a, ok1 := e.Out(py, "-m", "pip", "--version")
	b := ""
	ok2 := false
	if pip, found := e.SafeTool("pip3"); found {
		b, ok2 = e.Out(pip, "--version")
	}
	if ok1 && ok2 {
		ma, mb := pipFrom.FindStringSubmatch(a), pipFrom.FindStringSubmatch(b)
		if ma != nil && mb != nil && ma[1] != mb[1] {
			out = append(out, d.Warn("pip3 installs for a different Python than python3 runs").With("Packages you install will not be importable. Use: python3 -m pip install ..."))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("python3 and pip3 belong together")}
	}
	return out
}
