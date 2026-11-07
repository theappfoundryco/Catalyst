package cli

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/trash"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

const tagline = "The doctor for your dev environment. Nothing changes without asking."

type doctorReport struct {
	Schema  int             `json:"schema"`
	Version string          `json:"version"`
	OS      string          `json:"os"`
	Score   int             `json:"score"`
	Counts  doctor.Counts   `json:"counts"`
	Results []doctor.Result `json:"results"`
}

func cmdDoctor(a *App, args []string) int {
	fs := a.flags("doctor", "[--fix] [--only group] [--json] [-v]")
	fix := fs.Bool("fix", false, "")
	asJSON := fs.Bool("json", false, "")
	only := fs.String("only", "", "")
	verbose := fs.Bool("v", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	var filter []string
	if *only != "" {
		filter = strings.Split(*only, ",")
	}
	if *asJSON {
		return a.doctorJSON(filter)
	}
	u := a.U
	u.Banner(tagline)
	sp := u.Spin("Reading what a new terminal sees")
	a.E.LoadShell()
	sp.Stop()
	scan := doctor.Start(a.E, doctor.All(), filter)
	if len(scan.Checks) == 0 {
		u.Stop("No check matches " + *only + ".")
		return ExitUsage
	}
	all := a.showScan(scan, *verbose)
	score := doctor.Score(all)
	counts := doctor.Count(all)
	if len(filter) == 0 {
		a.Store.Record(state.Health{Date: a.E.Now(), Score: score, Issues: counts.Critical + counts.Warning + counts.Info, Critical: counts.Critical})
	}
	u.Blank()
	a.verdict(all, score, counts, *fix)
	if *fix {
		a.applyFixes(all)
	}
	u.Blank()
	switch {
	case counts.Critical+counts.Warning > 0:
		return ExitIssues
	case counts.Failed > 0:
		return ExitFailed
	}
	return ExitOK
}

func (a *App) doctorJSON(filter []string) int {
	a.E.LoadShell()
	scan := doctor.Start(a.E, doctor.All(), filter)
	var all []doctor.Result
	for i := range scan.Checks {
		all = append(all, scan.Wait(i)...)
	}
	c := doctor.Count(all)
	emit(a, doctorReport{Schema: 1, Version: version.Version, OS: a.E.OS, Score: doctor.Score(all), Counts: c, Results: all})
	switch {
	case c.Critical+c.Warning > 0:
		return ExitIssues
	case c.Failed > 0:
		return ExitFailed
	}
	return ExitOK
}

// showScan prints groups in a fixed order while checks finish in any order, with a spinner on whichever it is waiting for.
func (a *App) showScan(scan *doctor.Run, verbose bool) []doctor.Result {
	u := a.U
	var all []doctor.Result
	for _, group := range doctor.GroupOrder {
		first := true
		for i, c := range scan.Checks {
			if c.Group != group {
				continue
			}
			sp := u.Spin(c.Name)
			rs := scan.Wait(i)
			took := sp.Stop()
			for j, r := range rs {
				if r.State == doctor.Skipped && !verbose {
					continue
				}
				if first { // a heading only once something will sit under it
					u.Sect(group)
					first = false
				}
				a.printResult(r, verbose, took, j == 0)
			}
			all = append(all, rs...)
		}
	}
	return all
}

func (a *App) printResult(r doctor.Result, verbose bool, took time.Duration, firstOfCheck bool) {
	u := a.U
	title := r.Title
	if firstOfCheck {
		title += u.Took(took)
	}
	switch r.State {
	case doctor.Passed:
		u.Ok(title)
	case doctor.Skipped:
		if verbose {
			u.Skip(r.Title)
		}
		return
	case doctor.Failed:
		u.Warn("Could not check: " + title)
	case doctor.Issue:
		switch r.Severity {
		case doctor.Critical:
			u.Stop(title)
		case doctor.Warning:
			u.Warn(title)
		default:
			u.Note(title)
		}
	}
	if r.Hint != "" {
		u.Hint(r.Hint)
	}
}

func (a *App) verdict(all []doctor.Result, score int, c doctor.Counts, fixing bool) {
	u := a.U
	barWidth := 24
	if u.Width() < 70 {
		barWidth = 14
	}
	head := u.Bold("Health") + " " + u.HealthBar(score, barWidth)
	if change, since, ok := state.Trend(a.Store.History()); ok {
		head += "   " + u.Dim(trendWords(change, since, a.E.Now()))
	}
	parts := []string{}
	if c.Fine > 0 {
		parts = append(parts, fmt.Sprintf("%d fine", c.Fine))
	}
	if n := c.Warning + c.Info; n > 0 {
		parts = append(parts, ui.Count(n, "worth a look", "worth a look"))
	}
	if c.Critical > 0 {
		parts = append(parts, fmt.Sprintf("%d need%s fixing", c.Critical, plural1(c.Critical)))
	}
	if c.Skipped > 0 {
		parts = append(parts, fmt.Sprintf("%d skipped", c.Skipped))
	}
	if c.Failed > 0 {
		parts = append(parts, fmt.Sprintf("%d could not run", c.Failed))
	}
	u.Say("  " + head)
	u.Say("  " + u.Dim(strings.Join(parts, ", ")))
	fixable := 0
	for _, r := range all {
		if r.State == doctor.Issue && r.Fix != nil && r.Fix.Kind != doctor.FixManual {
			fixable++
		}
	}
	switch {
	case fixable > 0 && !fixing && a.inSession:
		u.Say("  " + u.Dim("Press f to go through them. Each change is shown before it runs."))
		a.outcome.Actions = append(a.outcome.Actions, session.Action{Key: "f", Label: "fix these", Title: "Doctor", Args: []string{"doctor", "--fix"}})
	case fixable > 0 && !fixing:
		u.Say("  " + u.Bold("Next:") + " catalyst doctor --fix   " + u.Dim("shows each change before it runs"))
	case c.Critical+c.Warning+c.Info == 0 && c.Failed == 0:
		u.Say("  " + u.Dim(ui.Signoffs[a.E.Now().Nanosecond()%len(ui.Signoffs)]))
	}
	a.reaction.mood = kit.Doctor
	switch {
	case c.Critical > 0:
		a.reaction.mood = kit.Alarm
	case score == 100 && c.Failed == 0:
		a.reaction.mood = kit.Party
	}
}

func plural1(n int) string {
	if n == 1 {
		return "s"
	}
	return ""
}

func trendWords(change int, since, now time.Time) string {
	when := "since " + since.Local().Format("Jan 2")
	if now.Sub(since) < 6*24*time.Hour {
		when = "since " + since.Local().Format("Monday")
	}
	switch {
	case change > 0:
		return fmt.Sprintf("up %d %s", change, when)
	case change < 0:
		return fmt.Sprintf("down %d %s", -change, when)
	}
	return "same as " + strings.TrimPrefix(when, "since ")
}

// applyFixes offers each fix in turn. Every one is shown before it runs, and none happens without a yes.
func (a *App) applyFixes(all []doctor.Result) {
	u := a.U
	batch := journal.NewBatch(a.E.Now())
	any, changed := false, false
	for _, r := range all {
		if r.State != doctor.Issue || r.Fix == nil {
			continue
		}
		f := *r.Fix
		if !any {
			u.Sect("Fixes")
			any = true
		}
		if f.Kind == doctor.FixManual {
			u.Note(r.Title)
			u.Hint("Only you can do this one: " + f.Preview())
			continue
		}
		u.Say("  " + r.Title)
		u.Hint(f.Preview())
		if !u.Ask("Do it?") {
			continue
		}
		if err := a.applyFix(f, batch); err != nil {
			u.Stop("That did not work: " + err.Error())
			continue
		}
		u.Ok("Done")
		changed = true
	}
	if !any {
		u.Blank()
		u.Say("  " + u.Dim("Nothing here can be fixed automatically."))
		return
	}
	switch {
	case !changed:
	case a.inSession:
		u.Say("  " + u.Dim("Change your mind? Undo is on the home screen."))
	default:
		u.Say("  " + u.Dim("Change your mind? catalyst undo   See everything: catalyst log"))
	}
}

func (a *App) applyFix(f doctor.Fix, batch string) error {
	now := a.E.Now()
	switch f.Kind {
	case doctor.FixChmod:
		st, err := os.Stat(f.Path)
		if err != nil {
			return err
		}
		e := journal.Entry{Time: now, Batch: batch, Kind: journal.KindChmod, Title: f.Title, From: f.Path, OldMode: st.Mode().Perm(), NewMode: f.Mode}
		if err := a.Journal.Add(e); err != nil {
			return err
		}
		return os.Chmod(f.Path, f.Mode)
	case doctor.FixTrash:
		return a.moveToTrash(f.Path, f.Title, batch, 0)
	case doctor.FixRun:
		r := a.E.Run.Run(5*time.Minute, f.Command[0], f.Command[1:]...)
		if !r.OK() {
			msg := strings.TrimSpace(r.Stderr)
			if msg == "" {
				msg = fmt.Sprintf("it stopped with code %d", r.Code)
			}
			return fmt.Errorf("%s", msg)
		}
		return a.Journal.Add(journal.Entry{Time: now, Batch: batch, Kind: journal.KindRun, Title: f.Title, Command: f.Command})
	}
	return fmt.Errorf("this fix cannot be run automatically")
}

// moveToTrash is the one path every removal takes. If the journal cannot record it, the move is reversed: nothing may
// leave without a way back.
func (a *App) moveToTrash(path, title, batch string, size int64) error {
	bin := trash.New(a.E.Home)
	bin.OS = a.E.OS
	m, err := bin.Move(path)
	if err != nil {
		return err
	}
	e := journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindTrash, Title: title, From: m.From, To: m.To, Info: m.Info, Size: size}
	if err := a.Journal.Add(e); err != nil {
		if rerr := trash.Restore(m.From, m.To, m.Info); rerr != nil {
			return fmt.Errorf("could not record the move, and could not undo it: %v", rerr)
		}
		return fmt.Errorf("could not record the move, so it was put back: %v", err)
	}
	return nil
}
