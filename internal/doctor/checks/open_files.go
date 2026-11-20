package checks

import (
	"path/filepath"
	"strconv"
	"strings"
	"time"

	d "github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/host"
)

func init() {
	d.Register(d.Check{ID: "shell.files", Group: d.GroupShell, Name: "Checking the open file limit", Run: openFiles})
}

// macOS gives every new shell a limit of 256 open files. Test runners, bundlers and file watchers that open many files
// at once then fail with "EMFILE: too many open files", which says nothing about where the limit comes from. Linux's
// usual 1024 is enough for most, so only a limit under that is mentioned, and only as a note.
func openFiles(e *host.Env) []d.Result {
	if e.Shell == "" {
		return []d.Result{d.Skip("Could not tell which shell you use")}
	}
	r := e.Run.Run(10*time.Second, e.Shell, "-l", "-c", "ulimit -n")
	n, ok := ParseUlimit(r.Stdout)
	if !r.OK() || !ok {
		return []d.Result{d.Skip("Could not read the open file limit")}
	}
	if n < 0 {
		return []d.Result{d.Pass("New shells have no open file limit")}
	}
	if n < 1024 {
		rc := "~/.zshrc"
		switch filepath.Base(e.Shell) {
		case "bash":
			rc = "~/.bash_profile"
		case "fish":
			rc = "~/.config/fish/config.fish"
		}
		return []d.Result{d.Note("New shells can open only " + strconv.Itoa(n) + " files at once").
			With("Test runners and bundlers fail with EMFILE: too many open files. Add ulimit -n 10240 to " + rc + ", then open a new terminal.")}
	}
	return []d.Result{d.Pass("New shells can open " + strconv.Itoa(n) + " files at once")}
}

// ParseUlimit reads ulimit -n, taking the last line, since startup files may print before it. "unlimited" is -1.
func ParseUlimit(s string) (int, bool) {
	ls := strings.Split(strings.TrimSpace(s), "\n")
	last := strings.TrimSpace(ls[len(ls)-1])
	if last == "unlimited" {
		return -1, true
	}
	n, err := strconv.Atoi(last)
	return n, err == nil && n > 0
}
