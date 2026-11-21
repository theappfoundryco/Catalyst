package cli

import (
	"os"
	"path/filepath"

	proj "github.com/theappfoundryco/catalyst/internal/project"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// cmdProject is a doctor for the repository you are in: what it pins against what runs here, lockfiles that
// disagree, an uncopied .env and hooks that point nowhere. It names commands and never runs them.
func cmdProject(a *App, args []string) int {
	fs := a.flags("project", "[DIR] [--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	if fs.NArg() > 1 {
		fs.Usage()
		return ExitUsage
	}
	dir, _ := os.Getwd()
	if fs.NArg() == 1 {
		dir = fs.Arg(0)
	}
	dir, err := filepath.Abs(dir)
	if st, e2 := os.Stat(dir); err != nil || e2 != nil || !st.IsDir() {
		a.U.Stop("There is no folder at " + fs.Arg(0) + ".")
		return ExitUsage
	}
	a.E.LoadShell()
	rep := proj.Check(a.E, proj.Root(dir))
	if rep.Findings == nil {
		rep.Findings = []proj.Finding{}
	}
	code := ExitOK
	for _, f := range rep.Findings {
		if f.Level == proj.Warn {
			code = ExitIssues
		}
	}
	if *asJSON {
		emit(a, rep)
		return code
	}
	u := a.U
	a.outcome.Refresh = true
	u.Hdr("This project: " + filepath.Base(rep.Dir))
	where := a.E.Tilde(rep.Dir)
	if len(rep.Kinds) > 0 {
		kinds := joinWords(rep.Kinds) + " · "
		u.Say("  " + u.Dim(kinds+ui.FitPath(where, u.Width()-2-ui.Visible(kinds))))
	} else {
		u.Say("  " + u.Dim(ui.FitPath(where, u.Width()-2)))
	}
	u.Blank()
	if len(rep.Findings) == 0 {
		u.Say("  " + u.Dim("Nothing here pins a version, and nothing disagrees."))
		u.Blank()
		return code
	}
	for _, f := range rep.Findings {
		var keys = a.row()
		if f.File != "" {
			keys = a.row(a.editKey(filepath.Join(rep.Dir, f.File), 1))
		}
		switch f.Level {
		case proj.OK:
			u.Ok(keys + f.Title)
		case proj.Note:
			u.Note(keys + f.Title)
		default:
			u.Warn(keys + f.Title)
		}
		if f.Hint != "" {
			u.Hint(f.Hint)
		}
	}
	u.Blank()
	u.Say("  " + u.Dim("Catalyst only reads the project. Each command above is for you to run."))
	u.Blank()
	return code
}

func joinWords(xs []string) string {
	out := ""
	for i, x := range xs {
		if i > 0 {
			out += ", "
		}
		out += x
	}
	return out
}
