package checks

import (
	"os"
	"path/filepath"
	"strings"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "tools.managers", Group: d.GroupTools, Name: "Checking version managers", Run: versionManagers})
}

// managerMarks says which version manager owns a PATH folder, by a piece of its path. Each manager installs into a
// folder of its own, so the path is proof enough. The system's copy (/usr/bin, Homebrew) is not a manager and is
// never counted here: one manager in front of the system's copy is the normal setup.
var managerMarks = []struct{ mark, name string }{
	{"/.nvm/versions/node/", "nvm"}, {"fnm_multishells", "fnm"}, {"/fnm/node-versions/", "fnm"}, {"/.volta/", "volta"},
	{"/.nodenv/", "nodenv"}, {"/.n/bin", "n"},
	{"/mise/shims", "mise"}, {"/mise/installs/", "mise"}, {"/.asdf/shims", "asdf"}, {"/.asdf/installs/", "asdf"},
	{"/.pyenv/", "pyenv"}, {"/anaconda3/", "conda"}, {"/miniconda3/", "conda"}, {"/miniforge3/", "conda"},
	{"/mambaforge/", "conda"}, {"/micromamba/", "conda"}, {"/Caskroom/miniforge/", "conda"}, {"/Caskroom/miniconda/", "conda"}, {"/opt/conda/", "conda"}, {"/.rye/shims", "rye"},
	{"/.rbenv/", "rbenv"}, {"/.rvm/", "rvm"}, {"/.rubies/", "chruby"},
	{"/.sdkman/candidates/java/", "SDKMAN"}, {"/.jenv/", "jenv"},
}

// managedTools are the commands people switch versions of, with the language name a person would use.
var managedTools = []struct{ tool, lang string }{{"node", "Node"}, {"python3", "Python"}, {"ruby", "Ruby"}, {"java", "Java"}}

// ManagerOf names the version manager that owns a folder, or "".
func ManagerOf(dir string) string {
	dir = filepath.ToSlash(dir) + "/"
	for _, m := range managerMarks {
		if strings.Contains(dir, m.mark) {
			return m.name
		}
	}
	return ""
}

// Two managers for one language is the classic "I switched versions but nothing changed": each one's startup line
// puts its folder on PATH, and whichever comes first wins in some shells and loses in others (a new tab, an editor,
// a script). Only what is really on the PATH a new terminal gets is counted.
func versionManagers(e *host.Env) []d.Result {
	var out []d.Result
	anyManager := false
	for _, t := range managedTools {
		var order []string
		seen := map[string]bool{}
		for _, dir := range e.Entries {
			m := ManagerOf(dir)
			if m == "" || !isExec(filepath.Join(dir, t.tool)) {
				continue
			}
			anyManager = true
			if !seen[m] {
				seen[m] = true
				order = append(order, m)
			}
		}
		if len(order) < 2 {
			continue
		}
		out = append(out, d.Warn(t.lang+" comes from "+joinAnd(order)+" at once").
			With(order[0]+" is first on your PATH, so its "+t.tool+" runs here, but the order can differ in an editor or a script. Keep one, and remove the others' lines from your startup file. See which file adds each: catalyst path"))
	}
	if len(out) > 0 {
		return out
	}
	if !anyManager {
		return []d.Result{d.Skip("No version managers on your PATH")}
	}
	return []d.Result{d.Pass("Each language has one version manager")}
}

func isExec(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

func joinAnd(xs []string) string {
	switch len(xs) {
	case 0:
		return ""
	case 1:
		return xs[0]
	}
	return strings.Join(xs[:len(xs)-1], ", ") + " and " + xs[len(xs)-1]
}
