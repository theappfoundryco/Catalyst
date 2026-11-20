package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.pip", Group: d.GroupTools, Name: "Checking pip's system protection", Run: pipSystem})
}

// Debian 12, Ubuntu 23.04, Fedora 38 and Homebrew's Python mark their Python as managed by the system (PEP 668), so
// pip refuses to install into it. The common answer found online, break-system-packages set for every pip call, makes
// pip overwrite the system's own packages, and the system's tools break later in ways nobody connects to it. Only that
// setting, on a Python that is actually managed, is reported.
func pipSystem(e *host.Env) []d.Result {
	py, ok := e.SafeTool("python3")
	if !ok {
		return []d.Result{d.Skip("Python is not installed")}
	}
	marker, ok := e.Out(py, "-c", "import os, sysconfig; print(os.path.exists(os.path.join(sysconfig.get_path('stdlib'), 'EXTERNALLY-MANAGED')))")
	if !ok {
		return []d.Result{d.Skip("Could not ask python3 about itself")}
	}
	if marker != "True" {
		return []d.Result{d.Skip("This Python is not managed by the system, so pip may install into it")}
	}
	s, ok := e.Out(py, "-m", "pip", "config", "list")
	if !ok {
		return []d.Result{d.Skip("pip is not installed for python3")}
	}
	for _, key := range BreakSystemKeys(s) {
		r := d.Warn("pip is set to overwrite the system's Python packages (" + key + ")").
			With("pip install can then replace packages the system's own tools need. Use a virtual environment, pipx or uv for tools.")
		if scope, ok := strings.CutSuffix(key, ".break-system-packages"); ok && scope != ":env:" {
			r = r.Run(py, "-m", "pip", "config", "unset", scope+".break-system-packages")
		} else {
			r = r.With("PIP_BREAK_SYSTEM_PACKAGES is set in your environment. Remove the line that sets it. See where: catalyst path")
		}
		return []d.Result{r}
	}
	return []d.Result{d.Pass("pip leaves the system's Python packages alone")}
}

// BreakSystemKeys reads pip config list and returns the keys that turn the protection off, such as
// "global.break-system-packages", or ":env:.break-system-packages" for the environment variable.
func BreakSystemKeys(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(l), "=")
		if !ok || !strings.HasSuffix(k, "break-system-packages") {
			continue
		}
		switch strings.ToLower(strings.Trim(v, `'"`)) {
		case "true", "1", "yes", "on":
			out = append(out, k)
		}
	}
	return out
}
