package cli

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/doctor/checks"
	"github.com/theappfoundryco/catalyst/internal/host"
)

// whichCopy is one program of that name on the PATH a new terminal gets.
type whichCopy struct {
	Path     string `json:"path"`
	Target   string `json:"target,omitempty"` // where its symlinks end, when it is one
	Folder   string `json:"folder"`
	AddedBy  string `json:"added_by,omitempty"` // the startup file that puts the folder on PATH
	Line     int    `json:"line,omitempty"`
	Manager  string `json:"manager,omitempty"` // the version manager that owns it
	Kind     string `json:"kind,omitempty"`    // arm64, x86_64, universal, script (node)
	Runs     *bool  `json:"runs,omitempty"`    // only asked for the copy that wins, and only for tools whose version flag is known
	Version  string `json:"version,omitempty"`
	Problem  string `json:"problem,omitempty"`
	Shadowed bool   `json:"shadowed"`
}

type whyReport struct {
	Name   string      `json:"name"`
	Copies []whichCopy `json:"copies"`
}

// versionFlag is how to ask a tool its version without it doing anything else. Only these are ever run: an unknown
// program might treat --version as something else.
var versionFlag = map[string]string{
	"python": "--version", "python3": "--version", "pip": "--version", "pip3": "--version", "node": "--version",
	"npm": "--version", "npx": "--version", "pnpm": "--version", "yarn": "--version", "bun": "--version", "deno": "--version",
	"ruby": "--version", "gem": "--version", "java": "-version", "javac": "-version", "go": "version", "cargo": "--version",
	"rustc": "--version", "git": "--version", "make": "--version", "gcc": "--version", "clang": "--version",
	"php": "--version", "perl": "--version", "docker": "--version", "kubectl": "version --client", "terraform": "version",
	"brew": "--version", "code": "--version", "uv": "--version", "pipx": "--version", "poetry": "--version",
	"swift": "--version", "dotnet": "--version", "mvn": "--version", "gradle": "--version", "cmake": "--version",
}

// cmdWhy answers "which one runs when I type this, and why that one". Every copy on PATH in order, the file that put
// each folder there, the version manager that owns it, what it is built for, and whether the winner really runs.
func cmdWhy(a *App, args []string) int {
	fs := a.flags("why", "NAME [--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	if fs.NArg() != 1 || strings.ContainsRune(fs.Arg(0), '/') {
		fs.Usage()
		return ExitUsage
	}
	name := fs.Arg(0)
	a.E.LoadShell()
	rep := whyReport{Name: name, Copies: a.copiesOf(name)}
	if *asJSON {
		emit(a, rep)
		if len(rep.Copies) == 0 {
			return ExitIssues
		}
		return ExitOK
	}
	u := a.U
	u.Hdr("Which " + name + " runs, and why")
	if len(rep.Copies) == 0 {
		u.Note("No " + name + " on the PATH a new terminal gets.")
		u.Hint("See the folders it searches: catalyst path")
		u.Blank()
		return ExitIssues
	}
	code := ExitOK
	for i, c := range rep.Copies {
		label, mark := "Runs", u.Green("✓")
		if c.Shadowed {
			label, mark = "Hidden", u.Dim("·")
		}
		line := mark + " " + u.Bold(a.E.Tilde(c.Path))
		var tags []string
		if c.Version != "" {
			tags = append(tags, c.Version)
		}
		if c.Manager != "" {
			tags = append(tags, "from "+c.Manager)
		}
		if c.Kind != "" {
			tags = append(tags, c.Kind)
		}
		if len(tags) > 0 {
			line += "  " + u.Dim(strings.Join(tags, ", "))
		}
		u.Row(label, a.row(a.copyKey("y", "copy", c.Path, a.E.Tilde(c.Path)))+line)
		if c.Target != "" {
			u.Hint("links to " + a.E.Tilde(c.Target))
		}
		switch {
		case c.AddedBy != "":
			u.Hint("its folder is on PATH because of " + a.E.Tilde(c.AddedBy) + " line " + strconv.Itoa(c.Line))
		case i == 0 || !c.Shadowed:
			u.Hint("its folder is on PATH by default")
		}
		if c.Problem != "" {
			u.Stop(c.Problem)
			code = ExitIssues
		}
	}
	if len(rep.Copies) > 1 {
		u.Blank()
		u.Say("  " + u.Dim("The first folder on PATH wins. To change which runs, move the line that adds its folder later or earlier, or remove the one you no longer use."))
	}
	u.Blank()
	return code
}

// copiesOf finds every program of that name on PATH, in the order the shell searches.
func (a *App) copiesOf(name string) []whichCopy {
	var out []whichCopy
	seen := map[string]bool{}
	for _, dir := range a.E.Entries {
		p := filepath.Join(dir, name)
		st, err := os.Stat(p)
		if err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
			continue
		}
		// /bin and /usr/bin are one folder on most systems now, so one file can be found twice. Count it once.
		key := filepath.Clean(p)
		if rd, err := filepath.EvalSymlinks(dir); err == nil {
			key = filepath.Join(rd, name)
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		c := whichCopy{Path: p, Folder: dir, Shadowed: len(out) > 0, Manager: checks.ManagerOf(dir)}
		if t, err := filepath.EvalSymlinks(p); err == nil && t != p {
			c.Target = t
			if c.Manager == "" {
				c.Manager = checks.ManagerOf(filepath.Dir(t))
			}
		}
		c.AddedBy, c.Line = a.pathSource(dir)
		c.Kind = host.ExecKindOf(p)
		if c.Kind == "" && c.Target != "" {
			c.Kind = host.ExecKindOf(c.Target)
		}
		if why, _ := host.Broken(p, checks.MachineOf(a.E)); why != "" {
			c.Problem = "It cannot start: " + why + "."
		} else if !c.Shadowed {
			a.tryRun(&c, name)
		}
		out = append(out, c)
	}
	return out
}

// tryRun asks the winning copy for its version, so "it is there" is never mistaken for "it works". Apple's stubs are not
// run, since they open an install dialog.
func (a *App) tryRun(c *whichCopy, name string) {
	flag, ok := versionFlag[name]
	if !ok {
		return
	}
	if _, safe := a.E.SafeTool(name); !safe && c.Folder == "/usr/bin" {
		c.Problem = "This is Apple's placeholder. Install the Command Line Tools: xcode-select --install"
		return
	}
	r := a.E.Run.Run(8*time.Second, c.Path, strings.Fields(flag)...)
	ran := r.OK()
	c.Runs = &ran
	if !ran {
		c.Problem = "It is found but does not run: " + firstLineOf(r.Stderr+"\n"+r.Stdout)
		return
	}
	c.Version = firstLineOf(r.Stdout + "\n" + r.Stderr)
	if len(c.Version) > 60 {
		c.Version = c.Version[:60]
	}
}

func firstLineOf(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return l
		}
	}
	return ""
}
