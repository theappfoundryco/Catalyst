package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.run", Group: d.GroupTools, Name: "Running your tools", Run: toolsRun})
}

var versionFlags = []struct{ tool, flag string }{
	{"python3", "--version"}, {"pip3", "--version"}, {"node", "--version"}, {"npm", "--version"},
	{"ruby", "--version"}, {"go", "version"}, {"cargo", "--version"}, {"java", "-version"}, {"docker", "--version"},
}

// toolsRun catches the case nothing else does: a command that resolves on your PATH but fails when run.
// Being found is not the same as working, and shims and half-removed installs fail exactly this way.
func toolsRun(e *host.Env) []d.Result {
	var fine []string
	var out []d.Result
	for _, t := range versionFlags {
		p, ok := e.SafeTool(t.tool)
		if !ok {
			continue
		}
		// /usr/bin/java on a Mac with no JDK is a stub that only prints how to get one.
		if t.tool == "java" && e.Mac() && p == "/usr/bin/java" {
			if r := e.Run.Run(0, "/usr/libexec/java_home"); !r.OK() {
				continue
			}
		}
		r := e.Run.Run(0, p, t.flag)
		switch {
		case r.TimedOut:
			out = append(out, d.Warn(t.tool+" did not answer in time").With(p))
		case !r.OK():
			out = append(out, d.Crit(t.tool+" resolves to "+e.Tilde(p)+" but does not run").With(firstLine(r.Stderr+"\n"+r.Stdout)))
		default:
			fine = append(fine, t.tool)
		}
	}
	if len(fine) > 0 {
		out = append(out, d.Pass(strings.Join(fine, ", ")+" all run"))
	}
	if len(out) == 0 {
		return []d.Result{d.Skip("None of the usual tools are installed")}
	}
	return out
}
