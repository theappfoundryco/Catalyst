package checks

import (
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "shell.syntax", Group: d.GroupShell, Name: "Checking your shell startup files", Run: shellSyntax})
}

// shellSyntax asks each shell to parse its own files without running them.
func shellSyntax(e *host.Env) []d.Result {
	sets := []struct {
		shell string
		flag  string
		files []string
	}{
		{"zsh", "-n", []string{".zshenv", ".zprofile", ".zshrc", ".zlogin"}},
		{"bash", "-n", []string{".bash_profile", ".bash_login", ".bashrc", ".profile"}},
		{"fish", "-n", []string{".config/fish/config.fish"}},
	}
	var out []d.Result
	for _, s := range sets {
		if _, err := e.Look(s.shell); err != nil {
			continue
		}
		seen, bad := 0, 0
		for _, f := range s.files {
			p := e.Path(f)
			if !host.Exists(p) {
				continue
			}
			seen++
			r := e.Run.Run(0, s.shell, s.flag, p)
			if r.TimedOut || r.NotFound || r.OK() {
				continue
			}
			bad++
			out = append(out, d.Crit(e.Tilde(p)+" has a syntax error").With(firstLine(r.Stderr)))
		}
		if seen > 0 && bad == 0 {
			out = append(out, d.Pass(s.shell+" startup files have no syntax errors"))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Skip("No shell startup files here")}
	}
	return out
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
