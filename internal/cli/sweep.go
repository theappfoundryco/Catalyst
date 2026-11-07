package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/sweep"
	"github.com/theappfoundryco/catalyst/internal/trash"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// ParseAge reads "14d", "2w", "3m" or "48h".
func ParseAge(s string) (time.Duration, error) {
	if s == "0" {
		return 0, nil
	}
	if len(s) >= 2 {
		if n, err := strconv.Atoi(s[:len(s)-1]); err == nil && n >= 0 {
			switch s[len(s)-1] {
			case 'd':
				return time.Duration(n) * 24 * time.Hour, nil
			case 'w':
				return time.Duration(n) * 7 * 24 * time.Hour, nil
			case 'm':
				return time.Duration(n) * 30 * 24 * time.Hour, nil
			case 'h':
				return time.Duration(n) * time.Hour, nil
			}
		}
	}
	return 0, fmt.Errorf("%q is not an age. Use 14d, 2w, 3m or 48h", s)
}

// ParseSize reads "10MB" or "1GB".
func ParseSize(s string) (int64, error) {
	t := strings.ToUpper(strings.TrimSpace(s))
	for _, u := range []struct {
		suffix string
		mult   float64
	}{{"GB", 1e9}, {"MB", 1e6}, {"KB", 1e3}, {"B", 1}} {
		if strings.HasSuffix(t, u.suffix) {
			f, err := strconv.ParseFloat(strings.TrimSuffix(t, u.suffix), 64)
			if err != nil {
				break
			}
			return int64(f * u.mult), nil
		}
	}
	return 0, fmt.Errorf("%q is not a size. Use 10MB or 1GB", s)
}

func cmdSweep(a *App, args []string) int {
	fs := a.flags("sweep", "[paths] [--older-than 14d] [--min-size 10MB] [--deep] [--all] [--dry-run] [--json] [--yes]")
	older := fs.String("older-than", "14d", "")
	minSize := fs.String("min-size", "10MB", "")
	deep := fs.Bool("deep", false, "")
	all := fs.Bool("all", false, "")
	dry := fs.Bool("dry-run", false, "")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	age, err := ParseAge(*older)
	if err != nil {
		u.Stop(err.Error())
		return ExitUsage
	}
	size, err := ParseSize(*minSize)
	if err != nil {
		u.Stop(err.Error())
		return ExitUsage
	}
	roots := fs.Args()
	givenPaths := len(roots) > 0
	for i, r := range roots {
		p, err := filepath.Abs(r)
		if err != nil {
			u.Stop(err.Error())
			return ExitUsage
		}
		st, err := os.Stat(p)
		if err != nil || !st.IsDir() {
			u.Stop(r + " is not a folder.")
			return ExitUsage
		}
		roots[i] = p
	}
	if !givenPaths {
		if *deep {
			roots = sweep.DeepRoots(a.E)
		} else {
			roots = sweep.DefaultRoots(a.E)
		}
	}
	a.E.LoadShell() // git has to resolve the way it does in a terminal
	opts := sweep.Options{Roots: roots, OlderThan: age, MinSize: size, Globals: !givenPaths, Env: a.E}
	if *asJSON {
		rep := sweep.Scan(opts)
		if rep.Items == nil {
			rep.Items = []sweep.Item{}
		}
		return emit(a, rep)
	}
	u.Blank()
	sp := u.Spin("Looking through your folders")
	opts.Progress = func(n int, path string) { sp.Detail(fmt.Sprintf("%d folders, %s", n, a.E.Tilde(path))) }
	rep := sweep.Scan(opts)
	sp.Stop()
	a.Store.SaveSweep(state.Sweep{Date: a.E.Now(), Bytes: rep.Total(), Count: len(rep.Items)})
	return a.sweepOffer(rep, age, *dry, *all)
}

func (a *App) sweepOffer(rep sweep.Report, age time.Duration, dry, pickAll bool) int {
	u := a.U
	var skipped []string
	if rep.SkippedRecent > 0 {
		skipped = append(skipped, fmt.Sprintf("%s you touched in the last %d days", ui.Count(rep.SkippedRecent, "folder", "folders"), int(age.Hours()/24)))
	}
	if rep.SkippedGit > 0 {
		skipped = append(skipped, fmt.Sprintf("%d that git did not clear", rep.SkippedGit))
	}
	skipNote := ""
	if len(skipped) > 0 {
		skipNote = "Protected " + strings.Join(skipped, " and ") + "."
	}
	if len(rep.Items) == 0 {
		u.Say("  " + u.Bold("Nothing to sweep."))
		if skipNote != "" {
			u.Say("  " + u.Dim(skipNote))
		}
		u.Blank()
		a.reaction = reaction{kit.Sleep, u.Dim("Nothing to sweep right now.")}
		return ExitOK
	}
	u.Say("  " + u.Head(fmt.Sprintf("Found %s to reclaim", ui.Count(len(rep.Items), "folder", "folders"))) + " " + u.Dim("(about "+ui.Size(rep.Total())+")"))
	if skipNote != "" {
		u.Say("  " + u.Dim(skipNote))
	}
	u.Blank()
	items := make([]ui.Item, len(rep.Items))
	for i, it := range rep.Items {
		label := it.Project
		if !it.Global {
			label = it.Project + " / " + filepath.Base(it.Path)
		}
		right := "about " + ui.Size(it.Size)
		if !it.Active.IsZero() {
			right += ", idle " + ui.Ago(it.Active, a.E.Now())
		}
		about := it.About
		switch {
		case about != "":
		case it.Cost == sweep.Safe:
			about = it.Title + ". It rebuilds itself."
		default:
			about = it.Title + ". To get it back: " + it.Restore + "."
		}
		// Only what rebuilds by itself starts ticked. Anything needing a reinstall is a choice you make.
		items[i] = ui.Item{Label: label, Right: right, About: about, Size: it.Size, Picked: pickAll || it.Cost == sweep.Safe}
	}
	if dry {
		for _, it := range items {
			u.Say("  " + it.Label + "  " + u.Dim(it.Right))
		}
		u.Blank()
		u.Say("  " + u.Dim("Dry run: nothing was moved."))
		u.Blank()
		return ExitOK
	}
	m := &ui.Menu{Items: items, Noun: "folder", Nouns: "folders", Action: "sweep", Note: "Everything goes to the Trash, and catalyst undo brings it back."}
	if a.inSession {
		m.Cancel, m.Note = "back", "Everything goes to the Trash, and Undo brings it back."
	}
	if !m.Run(u) {
		a.outcome.SkipWait = true
		u.Say("  " + u.Dim("Nothing was moved."))
		u.Blank()
		return ExitOK
	}
	return a.sweepApply(rep, m.Items)
}

func (a *App) sweepApply(rep sweep.Report, picked []ui.Item) int {
	u := a.U
	batch := journal.NewBatch(a.E.Now())
	moved, failed := 0, 0
	var freed int64
	var problems []string
	err := u.Step("Moving to the Trash", "Moved to the Trash", func(s *ui.Spinner) (string, error) {
		for i, p := range picked {
			if !p.Picked {
				continue
			}
			it := rep.Items[i]
			s.Detail(filepath.Base(filepath.Dir(it.Path)))
			if err := a.moveToTrash(it.Path, it.Title+" in "+it.Project, batch, it.Size); err != nil {
				failed++
				problems = append(problems, a.E.Tilde(it.Path)+": "+err.Error())
				continue
			}
			moved++
			freed += it.Size
		}
		return "", nil
	})
	_ = err
	for _, p := range problems {
		u.Warn(p)
	}
	u.Blank()
	switch {
	case moved == 0 && failed == 0:
		a.outcome.SkipWait = true
		u.Say("  " + u.Dim("Nothing was selected, so nothing was moved."))
	case moved == 0:
		u.Stop("Nothing could be moved.")
	default:
		a.Store.SaveSweep(state.Sweep{Date: a.E.Now()})
		u.Say("  " + u.Bold(ui.Count(moved, "folder", "folders")) + " moved, about " + u.Bold(ui.Size(freed)) + " freed once you empty the Trash.")
		if a.inSession {
			a.outcome.Actions = append(a.outcome.Actions, session.Action{Key: "u", Label: "undo", Title: "Undo", Args: []string{"undo"}})
			a.reaction = reaction{kit.Happy, u.Green(fmt.Sprintf("Moved %s, about %s.", ui.Count(moved, "folder", "folders"), ui.Size(freed))) + " " + u.Dim("Undo brings them back.")}
		} else {
			u.Say("  " + u.Dim("Change your mind? catalyst undo"))
		}
	}
	u.Blank()
	if failed > 0 {
		return ExitFailed
	}
	return ExitOK
}

func cmdUndo(a *App, args []string) int {
	fs := a.flags("undo", "[--yes]")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	batch := a.Journal.LastUndoable()
	if len(batch) == 0 {
		u.Blank()
		u.Say("  " + u.Dim("Nothing to undo."))
		u.Blank()
		return ExitOK
	}
	u.Sect("The last change, from " + ui.When(batch[0].Time))
	for _, e := range batch {
		u.Say("  " + e.Title)
		switch e.Kind {
		case journal.KindTrash:
			u.Hint("back to " + a.E.Tilde(e.From))
		case journal.KindChmod:
			u.Hint(fmt.Sprintf("back to mode %o on %s", e.OldMode, a.E.Tilde(e.From)))
		}
	}
	if !u.Ask("Undo this?") {
		u.Say("  " + u.Dim("Left as it is."))
		return ExitOK
	}
	failed := 0
	for i := len(batch) - 1; i >= 0; i-- {
		e := batch[i]
		var err error
		switch e.Kind {
		case journal.KindTrash:
			err = trash.Restore(e.From, e.To, e.Info)
		case journal.KindChmod:
			err = os.Chmod(e.From, e.OldMode)
		}
		if err != nil {
			u.Stop(a.E.Tilde(e.From) + ": " + err.Error())
			failed++
			continue
		}
		u.Ok("Put back " + a.E.Tilde(e.From))
	}
	a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch[0].Batch, Kind: journal.KindUndo, Title: "Undone"})
	u.Blank()
	if failed > 0 {
		return ExitFailed
	}
	a.reaction.line = u.Dim("Everything is back where it was.")
	return ExitOK
}

func cmdLog(a *App, args []string) int {
	fs := a.flags("log", "[-n 20]")
	n := fs.Int("n", 20, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	all := a.Journal.All()
	if len(all) == 0 {
		u.Blank()
		u.Say("  " + u.Dim("Catalyst has not changed anything yet."))
		u.Blank()
		return ExitOK
	}
	if len(all) > *n {
		all = all[len(all)-*n:]
	}
	u.Hdr("What Catalyst has changed")
	for _, e := range all {
		what := e.Title
		switch e.Kind {
		case journal.KindUndo:
			what = u.Dim("Undid the change before this")
		case journal.KindRun:
			what += u.Dim("  (" + strings.Join(e.Command, " ") + ")")
		case journal.KindChmod:
			what += u.Dim(fmt.Sprintf("  (%o to %o)", e.OldMode, e.NewMode))
		}
		u.Say("  " + u.Dim(fmt.Sprintf("%-16s", ui.When(e.Time))) + " " + what)
	}
	u.Blank()
	return ExitOK
}
