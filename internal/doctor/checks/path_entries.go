package checks

import (
	"os"
	"path/filepath"
	"slices"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func init() {
	d.Register(d.Check{ID: "shell.path", Group: d.GroupShell, Name: "Reading your PATH", Run: pathEntries})
}

func pathEntries(e *host.Env) []d.Result {
	dead, dupes := 0, 0
	seen := map[string]bool{}
	var out []d.Result
	for _, p := range e.Entries {
		if p == "." || !filepath.IsAbs(p) {
			out = append(out, d.Warn("Your PATH includes a relative folder ("+p+")").With("Programs in whatever folder you are in could run in place of real ones."))
			continue
		}
		clean := filepath.Clean(p)
		if seen[clean] {
			dupes++
		}
		seen[clean] = true
		if st, err := os.Stat(p); err != nil || !st.IsDir() {
			dead++
		}
	}
	if dead > 0 {
		out = append(out, d.Note("Your PATH has "+ui.Count(dead, "folder that does not exist", "folders that do not exist")).With("See which, and which file adds them: catalyst path"))
	}
	if dupes > 0 {
		out = append(out, d.Note("Your PATH lists "+ui.Count(dupes, "folder", "folders")+" twice").With("Harmless, but often a sign of a startup file running more than once: catalyst path"))
	}
	if e.Mac() {
		brew := slices.Index(e.Entries, "/opt/homebrew/bin")
		sys := slices.Index(e.Entries, "/usr/bin")
		if brew >= 0 && sys >= 0 && brew > sys {
			out = append(out, d.Warn("Apple's tools come before Homebrew's on your PATH").With("So brew-installed git, python3 and others are ignored. Move the brew shellenv line later in your startup file."))
		}
	}
	if len(out) == 0 {
		return []d.Result{d.Pass("PATH has no dead or repeated folders")}
	}
	return out
}
