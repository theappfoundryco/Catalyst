// Package cli holds the commands. Every command returns an exit code: 0 fine, 1 issues found, 2 usage error, 3 a check could not run.
package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

// Exit codes.
const (
	ExitOK     = 0
	ExitIssues = 1
	ExitUsage  = 2
	ExitFailed = 3
)

// App is what commands share.
type App struct {
	U       *ui.UI
	E       *host.Env
	Store   *state.Store
	Journal *journal.Journal

	inSession bool
	outcome   session.Outcome         // what the session should do once this command returns
	reaction  reaction                // what Kit and the home screen say about it
	rowID     int                     // rows marked by the command running now
	SizeOf    func(path string) int64 // how big a folder is; the demo replaces it
	pages     map[string]func()
	pageID    int
}

// reaction is the home screen's response to what just ran. It is how a command shows up in Kit's mood, since Kit stays home.
type reaction struct{ mood, line string }

type command struct {
	Name, Args, Help string
	Run              func(a *App, args []string) int
}

func commands() []command {
	return []command{
		{"doctor", "[--fix] [--only group] [--json] [-v]", "find what is wrong and fix what is safe", cmdDoctor},
		{"sweep", "[paths] [--older-than 14d] [--deep] [--dry-run] [--json]", "reclaim space from build artifacts", cmdSweep},
		{"clean", "[--dry-run] [--json] [--yes]", "app caches and old logs, which rebuild themselves", cmdClean},
		{"status", "[--json]", "one-glance health of this machine", cmdStatus},
		{"space", "[--in PATH] [--json]", "where your storage goes, and what can go", cmdSpace},
		{"system", "[--dry-run] [--admin] [--json]", "what macOS calls System Data, and what can safely go", cmdSystem},
		{"undo", "[--yes]", "reverse the last change Catalyst made", cmdUndo},
		{"log", "[-n 20]", "everything Catalyst has changed", cmdLog},
		{"disk", "[--folders] [--json]", "volumes, drive health and wear", cmdDisk},
		{"battery", "[--json]", "charge, cycles and condition", cmdBattery},
		{"net", "[host]", "connection, DNS and latency", cmdNet},
		{"ports", "[kill PORT] [--json]", "what is listening, and stop it safely", cmdPorts},
		{"startup", "[disable NAME | enable NAME] [--json]", "what starts by itself", cmdStartup},
		{"ssh", "[--json]", "your keys and whether they are safe", cmdSSH},
		{"path", "[add | remove | status]", "your PATH: dead folders, repeats and shadows", cmdPath},
		{"config", "[set name NAME | set mascot on|off | set animations on|off]", "show or change settings", cmdConfig},
		{"helpers", "[install NAME]", "tools that let Catalyst see more, such as smartmontools", cmdHelpers},
		{"setup", "", "the welcome: your name, and helpers worth having", cmdSetup},
		{"legacy", "[--yes]", "clean up after the old Catalyst Mac app", cmdLegacy},
		{"update", "[--check]", "move to the newest release", cmdUpdate},
		{"uninstall", "[--yes]", "remove Catalyst from this machine", cmdUninstall},
		{"version", "", "show the version", cmdVersion},
		{"help", "", "show this list", cmdHelp},
	}
}

// Main runs one command line.
func Main(args []string) int {
	return newApp().dispatch(args)
}

func newApp() *App {
	e := host.New()
	s := state.New(e.Home, os.Getenv)
	u := ui.New()
	if !s.LoadConfig().MascotOn() {
		u.Mascot = false
	}
	return &App{U: u, E: e, Store: s, Journal: journal.New(s.Dir)}
}

func (a *App) dispatch(args []string) int {
	var rest []string
	for _, x := range args {
		switch x {
		case "--no-color", "--plain":
			a.U.Color, a.U.TTY, a.U.Mascot = false, false, false
		case "--version":
			return cmdVersion(a, nil)
		case "--help", "-h":
			if len(args) == 1 {
				return cmdHelp(a, nil)
			}
			rest = append(rest, x)
		default:
			rest = append(rest, x)
		}
	}
	if len(rest) == 0 {
		if a.U.TTY && a.U.InTTY {
			return a.session()
		}
		return cmdHelp(a, nil) // a pipe has nobody to talk to
	}
	for _, c := range commands() {
		if c.Name == rest[0] {
			return c.Run(a, rest[1:])
		}
	}
	a.U.Stop(fmt.Sprintf("There is no command called %q.", rest[0]))
	a.U.Hint("See them all: catalyst help")
	return ExitUsage
}

func (a *App) session() int {
	a.inSession = true
	return session.Run(session.Config{
		UI: a.U, Items: a.homeItems, Header: a.header,
		Run: func(args []string) session.Outcome {
			a.outcome, a.reaction, a.rowID = session.Outcome{}, reaction{}, 0
			if len(args) == 2 && args[0] == "__page" {
				if show, ok := a.pages[args[1]]; ok {
					show()
				}
				return a.outcome
			}
			a.dispatch(args)
			return a.outcome
		},
		First:  a.first(),
		Motion: a.Store.LoadConfig().MotionOn(),
	})
}

// first is the welcome, the first time the list opens.
func (a *App) first() []string {
	if a.Store.LoadConfig().SetupDone {
		return nil
	}
	return []string{"setup"}
}

// homeItems is the list on the home screen. The most-used things come first, and what is rare waits under More.
func (a *App) homeItems() []session.Item {
	helps := map[string]string{}
	for _, c := range commands() {
		helps[c.Name] = strings.TrimPrefix(c.Help, "your PATH: ") // the row is already called PATH
	}
	item := func(name, label string, gap bool) session.Item {
		return session.Item{Name: label, Help: helps[name], Args: []string{name}, Gap: gap}
	}
	more := []session.Item{item("log", "History", false), item("config", "Settings", false), item("helpers", "Helpers", false), item("update", "Update", false), item("uninstall", "Uninstall", false)}
	if a.oldAppPresent() {
		more = append(more, item("legacy", "Old app", false))
	}
	if !a.E.Mac() {
		helps["system"] = "system caches and logs, and what can safely go"
	}
	undo := item("undo", "Undo", false)
	if last := a.Journal.LastUndoable(); len(last) == 0 {
		undo.Help, undo.Disabled = "nothing to undo yet", true
	} else {
		undo.Detail = a.lastChange(last)
	}
	return []session.Item{
		item("doctor", "Doctor", false),
		item("sweep", "Sweep", false),
		item("clean", "Clean", false),
		item("status", "Status", false),
		item("space", "Space", false),
		item("system", "System", false),
		undo,
		item("disk", "Disk", false),
		item("battery", "Battery", false),
		item("net", "Network", false),
		item("ports", "Ports", false),
		item("startup", "Startup", false),
		item("ssh", "SSH keys", false),
		item("path", "PATH", false),
		{Name: "More", Help: "history, settings, helpers, update, uninstall", Gap: true, Sub: more},
	}
}

// lastChange says in one line what Undo would reverse, and when. It reads the same record Undo does, so the two cannot disagree.
func (a *App) lastChange(batch []journal.Entry) string {
	moved, folders, chmods := 0, 0, 0
	for _, e := range batch {
		switch e.Kind {
		case journal.KindTrash:
			moved++
			if st, err := os.Stat(e.To); err == nil && st.IsDir() {
				folders++
			}
		case journal.KindChmod:
			chmods++
		case journal.KindEdit:
			return "Edited " + a.E.Tilde(e.From) + ", " + whenSaid(batch[0].Time, a.E.Now())
		}
	}
	what := ""
	switch {
	case moved == 1 && chmods == 0:
		what = "Moved " + batch[0].Title + " to the Trash"
	case moved > 0 && chmods == 0 && folders == moved:
		what = "Moved " + ui.Count(moved, "folder", "folders") + " to the Trash"
	case moved > 0 && chmods == 0:
		what = "Moved " + ui.Count(moved, "item", "items") + " to the Trash"
	case chmods == 1 && moved == 0:
		what = "Changed permissions on " + a.E.Tilde(batch[0].From)
	default:
		what = ui.Count(len(batch), "change", "changes")
	}
	return what + ", " + whenSaid(batch[0].Time, a.E.Now())
}

// whenSaid is a time the way people say it: "today 2:07 PM", "yesterday 9:15 AM", or the date.
func whenSaid(t, now time.Time) string {
	t, now = t.Local(), now.Local()
	day := func(x time.Time) time.Time { return time.Date(x.Year(), x.Month(), x.Day(), 0, 0, 0, 0, time.Local) }
	switch day(now).Sub(day(t)) {
	case 0:
		return "today " + t.Format("3:04 PM")
	case 24 * time.Hour:
		return "yesterday " + t.Format("3:04 PM")
	}
	return ui.When(t)
}

// oldAppPresent looks for what the old Mac app leaves most often, so the cleanup only shows up for someone who needs it.
func (a *App) oldAppPresent() bool {
	if !a.E.Mac() {
		return false
	}
	for _, p := range []string{"/Applications/Catalyst.app", a.E.Path(legacySource)} {
		if _, err := os.Lstat(p); err == nil {
			return true
		}
	}
	return false
}

// flags builds a flag set that explains itself in plain words and never exits by itself.
func (a *App) flags(name, usage string) *flag.FlagSet {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(discard{})
	fs.Usage = func() { a.U.Say("  Usage: catalyst " + name + " " + usage) }
	return fs
}

type discard struct{}

func (discard) Write(b []byte) (int, error) { return len(b), nil }

// parse runs a flag set and reports the problem in plain words. ok is false when the command should stop.
func (a *App) parse(fs *flag.FlagSet, args []string) (code int, ok bool) {
	// Flags may come after positional arguments, the way people type them.
	var flags, plain []string
	for i := 0; i < len(args); i++ {
		x := args[i]
		if !strings.HasPrefix(x, "-") || x == "-" {
			plain = append(plain, x)
			continue
		}
		flags = append(flags, x)
		name := strings.TrimLeft(x, "-")
		if !strings.Contains(name, "=") && i+1 < len(args) {
			if f := fs.Lookup(name); f != nil {
				if _, isBool := f.Value.(interface{ IsBoolFlag() bool }); !isBool {
					i++
					flags = append(flags, args[i])
				}
			}
		}
	}
	if err := fs.Parse(append(flags, plain...)); err != nil {
		if err == flag.ErrHelp {
			fs.Usage()
			return ExitOK, false
		}
		a.U.Stop(err.Error())
		fs.Usage()
		return ExitUsage, false
	}
	return ExitOK, true
}

func emit(a *App, v any) int {
	enc := json.NewEncoder(a.U.Out)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return ExitFailed
	}
	return ExitOK
}

func cmdVersion(a *App, _ []string) int {
	fmt.Fprintln(a.U.Out, "catalyst "+version.Version)
	return ExitOK
}

func cmdHelp(a *App, _ []string) int {
	u := a.U
	u.Blank()
	u.Say("  " + u.Bold("Catalyst") + " " + u.Dim(version.Version))
	u.Say("  " + u.Dim("The doctor for your dev environment."))
	u.Say("  " + u.Dim("Run catalyst (or kit) alone to open the list, or:"))
	u.Blank()
	for _, c := range commands() {
		u.Say(fmt.Sprintf("  %s  %s", u.Cyan(fmt.Sprintf("%-10s", c.Name)), c.Help))
	}
	u.Blank()
	u.Say(u.Dim("  Exit codes: 0 fine, 1 issues found, 2 usage error, 3 a check could not run."))
	u.Say(u.Dim("  Reading never needs permission. Changing always does. Nothing is sent anywhere."))
	u.Blank()
	return ExitOK
}

// Dispatch runs one command line on a prepared App, for the demo.
func Dispatch(a *App, args []string) int { return a.dispatch(args) }
