package cli

import (
	"fmt"
	"os"
	"os/user"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

// reportTools are asked their version for the report, the ones a teammate or a maintainer asks about first, each with
// the flag that only prints it.
var reportTools = []struct{ name, flag string }{
	{"git", "--version"}, {"node", "--version"}, {"npm", "--version"}, {"python3", "--version"}, {"pip3", "--version"},
	{"go", "version"}, {"ruby", "--version"}, {"java", "-version"}, {"docker", "--version"}, {"brew", "--version"},
}

// cmdReport writes a Markdown summary of this machine for a teammate or an issue: the platform, tool versions and every
// doctor finding. Home folder, user name and machine name are replaced before anything is written, and it goes to the
// terminal or a file, never anywhere else.
func cmdReport(a *App, args []string) int {
	fs := a.flags("report", "[--out FILE]")
	out := fs.String("out", "", "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	var sp *ui.Spinner
	if *out != "" {
		sp = u.Spin("Checking this machine for the report")
	}
	a.E.LoadShell()
	scan := doctor.Start(a.E, doctor.All(), nil)
	var all []doctor.Result
	for i := range scan.Checks {
		all = append(all, scan.Wait(i)...)
	}
	lines := strings.Split(a.Scrub(a.reportText(all)), "\n")
	for i, l := range lines { // a path with a newline or an escape in it would break the table, or the terminal
		lines[i] = ui.Printable(l)
	}
	text := strings.Join(lines, "\n")
	if sp != nil {
		sp.Stop()
	}
	if *out == "" {
		fmt.Fprint(u.Out, text)
		return ExitOK
	}
	if err := os.WriteFile(*out, []byte(text), 0o644); err != nil {
		u.Stop("Could not write " + *out + ": " + err.Error())
		return ExitFailed
	}
	u.Ok("Wrote " + *out + ". Your home folder, user name and machine name are replaced. Read it before you share it.")
	return ExitOK
}

func (a *App) reportText(all []doctor.Result) string {
	var b strings.Builder
	p := a.E.Platform()
	c := doctor.Count(all)
	w := func(f string, args ...any) { fmt.Fprintf(&b, f, args...) }
	w("# Catalyst report\n\n")
	w("Made %s by Catalyst %s. Home folder, user name and machine name are replaced. No secrets are included.\n\n", a.E.Now().Format("Jan 2, 2006, 3:04 PM"), version.Version)
	w("## This machine\n\n| | |\n|---|---|\n")
	w("| System | %s |\n", p.Describe())
	if p.Kernel != "" {
		w("| Kernel | %s |\n", p.Kernel)
	}
	if len(p.Managers) > 0 {
		w("| Package managers | %s |\n", strings.Join(p.Managers, ", "))
	}
	if a.E.Shell != "" {
		w("| Shell | %s |\n", a.E.Shell)
	}
	w("\n## Tools\n\n| Tool | Path | Version |\n|---|---|---|\n")
	for _, rt := range reportTools {
		t := rt.name
		path, ok := a.E.SafeTool(t)
		if !ok {
			continue
		}
		ver := "does not run"
		if r := a.E.Run.Run(8*time.Second, path, rt.flag); r.OK() {
			ver = firstOf(r.Stdout + "\n" + r.Stderr)
		}
		w("| %s | `%s` | %s |\n", t, path, strings.ReplaceAll(ver, "|", "/"))
	}
	w("\n## Doctor\n\nScore %d. %s.\n\n", doctor.Score(all), countWords(c))
	mark := map[doctor.State]string{doctor.Passed: "ok", doctor.Skipped: "skip", doctor.Failed: "error"}
	for _, g := range doctor.GroupOrder {
		var rows []string
		for _, r := range all {
			if r.Group != g {
				continue
			}
			m := mark[r.State]
			if r.State == doctor.Issue {
				m = map[doctor.Severity]string{doctor.Critical: "critical", doctor.Warning: "warning", doctor.Info: "note"}[r.Severity]
			}
			line := fmt.Sprintf("- **%s** %s", m, r.Title)
			if r.Hint != "" && r.State == doctor.Issue {
				line += ". " + strings.ReplaceAll(r.Hint, "\n", " ")
			}
			rows = append(rows, line)
		}
		if len(rows) > 0 {
			w("### %s\n\n%s\n\n", g, strings.Join(rows, "\n"))
		}
	}
	w("## PATH\n\n")
	for i, d := range a.E.Entries {
		w("%d. `%s`\n", i+1, d)
	}
	return b.String()
}

// Scrub replaces what identifies this person or machine: the home folder, the user name and the machine name. It runs
// on the whole text, so a value that reached a finding or a path is caught too.
func (a *App) Scrub(s string) string {
	if a.E.Home != "" && a.E.Home != "/" {
		s = strings.ReplaceAll(s, a.E.Home, "~")
	}
	if h := a.E.Hostname(); len(h) > 2 {
		s = strings.ReplaceAll(s, h, "this-machine")
		if short, _, ok := strings.Cut(h, "."); ok && len(short) > 2 {
			s = strings.ReplaceAll(s, short, "this-machine")
		}
	}
	// root is not a person's name, and "belongs to root" must keep its meaning.
	if u, err := user.Current(); err == nil && len(u.Username) > 2 && u.Username != "root" {
		s = replaceWord(s, u.Username, "you")
	}
	return s
}

// replaceWord replaces a name only where it stands alone, so a short user name does not eat parts of other words.
func replaceWord(s, old, repl string) string {
	isWord := func(c byte) bool {
		return c == '_' || c == '-' || c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
	}
	var b strings.Builder
	for {
		i := strings.Index(s, old)
		if i < 0 {
			b.WriteString(s)
			return b.String()
		}
		end := i + len(old)
		if (i == 0 || !isWord(s[i-1])) && (end == len(s) || !isWord(s[end])) {
			b.WriteString(s[:i] + repl)
		} else {
			b.WriteString(s[:end])
		}
		s = s[end:]
	}
}

func firstOf(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return l
		}
	}
	return ""
}
