package checks

import (
	"os"
	"strconv"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/rcfile"
)

func init() {
	d.Register(d.Check{ID: "shell.syntax", Group: d.GroupShell, Name: "Checking your shell startup files", Run: shellSyntax})
}

// shellSyntax asks each shell to parse its own files without running them, and reads them for the slips that a parse
// does not catch, or catches only at the end of the file: a line glued onto a closing brace, Windows line endings,
// quotes pasted from a web page. Each slip is reported on the line it starts on, with the edit that mends it.
func shellSyntax(e *host.Env) []d.Result {
	sets := []struct {
		shell string
		files []string
	}{
		{"zsh", []string{".zshenv", ".zprofile", ".zshrc", ".zlogin"}},
		{"bash", []string{".bash_profile", ".bash_login", ".bashrc", ".profile"}}, // bash reads .profile on most systems, bash-isms and all
		{"fish", []string{".config/fish/config.fish"}},
	}
	var out []d.Result
	for _, s := range sets {
		shell, ok := host.FindShell(e, s.shell)
		if !ok {
			continue // a file for a shell that is not here is never read
		}
		seen, bad := 0, 0
		for _, f := range s.files {
			p := e.Path(f)
			if !host.Exists(p) {
				continue
			}
			seen++
			rs := fileSlips(e, s.shell, shell, p)
			bad += len(rs)
			out = append(out, rs...)
		}
		if seen > 0 && bad == 0 {
			out = append(out, d.Pass(s.shell+" startup files have no syntax errors or slips"))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Skip("No shell startup files here")}
	}
	return out
}

// fileSlips reports one file. name is the shell's name, and shell its path.
func fileSlips(e *host.Env, name, shell, p string) []d.Result {
	r := e.Run.Run(0, shell, "-n", p)
	rejected := !(r.TimedOut || r.NotFound || r.OK())
	said := ""
	if rejected {
		said = firstLine(r.Stderr + "\n" + r.Stdout)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		if rejected {
			return []d.Result{d.Crit(e.Tilde(p) + " has a syntax error").With(said)}
		}
		return nil
	}
	var out []d.Result
	slips := rcfile.Trust(rcfile.Scan(p, string(b)), rejected)
	cause := -1 // the slip that explains the shell's error: one about how blocks nest, if any, before any other
	for i, s := range slips {
		if rejected && (s.Kind == rcfile.GluedClose || s.Kind == rcfile.Unclosed) {
			cause = i
			break
		}
		if rejected && s.Stops && cause < 0 {
			cause = i
		}
	}
	for i, s := range slips {
		title := e.Tilde(p) + " line " + strconv.Itoa(s.Line) + ": " + lower(s.Title)
		hint := s.Why
		var res d.Result
		switch {
		case i == cause:
			if said != "" {
				hint += " (" + name + " says: " + said + ")"
			}
			res = d.Crit(title)
		case s.Kind == rcfile.NoNewline:
			res = d.Note(title)
		default:
			res = d.Warn(title)
		}
		res = res.With(hint)
		if len(s.Edits) > 0 {
			res = res.Edit(p, s.Kind, s.Line, s.Edits)
		}
		out = append(out, res)
	}
	if rejected && cause < 0 { // the shell knows better than the scan: say what it said
		out = append([]d.Result{d.Crit(e.Tilde(p) + " has a syntax error").With(said)}, out...)
	}
	return out
}

func lower(s string) string {
	if s == "" {
		return s
	}
	return strings.ToLower(s[:1]) + s[1:]
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}
