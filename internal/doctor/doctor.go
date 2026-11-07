// Package doctor runs checks at the same time and turns their results into one score. A check is one small file in
// internal/doctor/checks. See docs/ADDING_A_CHECK.md.
package doctor

import (
	"fmt"
	"io/fs"
	"math"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
)

// State is how a check ended. Only a check that truly ran can pass, which is what keeps a crash from reading as healthy.
type State string

// The four states.
const (
	Passed  State = "pass"
	Issue   State = "issue"
	Skipped State = "skipped"
	Failed  State = "error"
)

// Severity weighs an issue in the score.
type Severity string

// The three severities.
const (
	Info     Severity = "info"
	Warning  Severity = "warning"
	Critical Severity = "critical"
)

// FixKind says what a fix does. Fixes are data, so the preview can never disagree with what runs.
type FixKind string

// The kinds of fix.
const (
	FixChmod  FixKind = "chmod"  // change a path's mode; can be undone
	FixTrash  FixKind = "trash"  // move a path to the Trash; can be undone
	FixRun    FixKind = "run"    // run a command as you; cannot be undone
	FixManual FixKind = "manual" // only you can do this, here is the command
)

// Fix is one proposed change.
type Fix struct {
	Kind    FixKind     `json:"kind"`
	Title   string      `json:"title"`
	Path    string      `json:"path,omitempty"`
	Mode    fs.FileMode `json:"mode,omitempty"`
	Command []string    `json:"command,omitempty"`
}

// Preview is the change written out the way a person would run it.
func (f Fix) Preview() string {
	switch f.Kind {
	case FixChmod:
		return fmt.Sprintf("chmod %o %s", f.Mode, f.Path)
	case FixTrash:
		return "move to the Trash: " + f.Path
	}
	return strings.Join(f.Command, " ")
}

// Result is one finding. Text fields are shown to people and may reach --json, so they must never hold a secret's value.
type Result struct {
	Check    string   `json:"check"`
	Group    string   `json:"group"`
	State    State    `json:"state"`
	Severity Severity `json:"severity,omitempty"`
	Title    string   `json:"title"`
	Hint     string   `json:"hint,omitempty"`
	Fix      *Fix     `json:"fix,omitempty"`
}

// Pass, Warn, Crit, Note, Skip and Err build results.
func Pass(title string) Result { return Result{State: Passed, Title: title} }
func Warn(title string) Result { return Result{State: Issue, Severity: Warning, Title: title} }
func Crit(title string) Result { return Result{State: Issue, Severity: Critical, Title: title} }
func Note(title string) Result { return Result{State: Issue, Severity: Info, Title: title} }
func Skip(why string) Result   { return Result{State: Skipped, Title: why} }
func Err(why string) Result    { return Result{State: Failed, Title: why} }

// With adds a hint.
func (r Result) With(hint string) Result { r.Hint = hint; return r }

// Chmod attaches a fix that changes a path's mode.
func (r Result) Chmod(path string, mode fs.FileMode) Result {
	r.Fix = &Fix{Kind: FixChmod, Title: r.Title, Path: path, Mode: mode}
	return r
}

// Trash attaches a fix that moves a path to the Trash.
func (r Result) Trash(path string) Result {
	r.Fix = &Fix{Kind: FixTrash, Title: r.Title, Path: path}
	return r
}

// Run attaches a fix that runs a command.
func (r Result) Run(command ...string) Result {
	r.Fix = &Fix{Kind: FixRun, Title: r.Title, Command: command}
	return r
}

// Manual attaches a command only the user can run.
func (r Result) Manual(command ...string) Result {
	r.Fix = &Fix{Kind: FixManual, Title: r.Title, Command: command}
	return r
}

// Groups are the sections of a report, in order.
const (
	GroupShell   = "Your shell"
	GroupTools   = "Your tools"
	GroupKeys    = "Keys and secrets"
	GroupMachine = "This machine"
)

// GroupOrder is the order sections print in.
var GroupOrder = []string{GroupShell, GroupTools, GroupKeys, GroupMachine}

// Check is one diagnosis. OS is "darwin", "linux" or "" for both.
type Check struct {
	ID    string
	Group string
	Name  string // what the spinner says while it runs, like "Checking Docker"
	OS    string
	Run   func(e *host.Env) []Result
}

var registry []Check

// Register adds a check. Each check file calls it from init.
func Register(c Check) { registry = append(registry, c) }

// All returns every registered check.
func All() []Check { return registry }

// Limit is how long one check may take. A stuck tool must not hold up the whole report.
const Limit = 45 * time.Second

// Run is a scan in progress. Results are read per check, in order, as each finishes.
type Run struct {
	Checks []Check
	done   []chan []Result
}

// Start begins every check that applies to this system, all at once. only filters by group or ID when not empty.
func Start(e *host.Env, checks []Check, only []string) *Run {
	r := &Run{}
	for _, c := range checks {
		if c.OS != "" && c.OS != e.OS {
			continue
		}
		if len(only) > 0 && !matches(c, only) {
			continue
		}
		ch := make(chan []Result, 1)
		r.Checks = append(r.Checks, c)
		r.done = append(r.done, ch)
		go func(c Check) { ch <- runOne(e, c) }(c)
	}
	return r
}

func matches(c Check, only []string) bool {
	for _, o := range only {
		o = strings.ToLower(strings.TrimSpace(o))
		if strings.HasPrefix(strings.ToLower(c.ID), o) || strings.Contains(strings.ToLower(c.Group), o) {
			return true
		}
	}
	return false
}

// Wait returns the results of check i, blocking until they are ready.
func (r *Run) Wait(i int) []Result { return <-r.done[i] }

func runOne(e *host.Env, c Check) []Result {
	type out struct{ rs []Result }
	ch := make(chan out, 1)
	go func() {
		defer func() {
			if p := recover(); p != nil { // a bug in one check is reported, and never stops the others
				ch <- out{[]Result{Err(fmt.Sprintf("%s could not finish: %v", c.Name, p))}}
			}
		}()
		ch <- out{c.Run(e)}
	}()
	var rs []Result
	select {
	case o := <-ch:
		rs = o.rs
	case <-time.After(Limit):
		rs = []Result{Err(fmt.Sprintf("%s took too long, so it was stopped", c.Name))}
	}
	if len(rs) == 0 {
		rs = []Result{Err(c.Name + " returned nothing")}
	}
	for i := range rs {
		rs[i].Check, rs[i].Group = c.ID, c.Group
	}
	return rs
}

// Score maps issues to 0 to 100 by decay, not subtraction: a bad machine and a catastrophic one should not both read 0.
// Skipped and failed checks do not count, because they say nothing about health.
func Score(rs []Result) int {
	f := 1.0
	for _, r := range rs {
		if r.State != Issue {
			continue
		}
		switch r.Severity {
		case Critical:
			f *= 0.7
		case Warning:
			f *= 0.9
		case Info:
			f *= 0.98
		}
	}
	return int(math.Round(100 * f))
}

// Counts sums results by how they ended.
type Counts struct {
	Fine, Critical, Warning, Info, Skipped, Failed int
}

// Count adds them up.
func Count(rs []Result) Counts {
	var c Counts
	for _, r := range rs {
		switch r.State {
		case Passed:
			c.Fine++
		case Skipped:
			c.Skipped++
		case Failed:
			c.Failed++
		case Issue:
			switch r.Severity {
			case Critical:
				c.Critical++
			case Warning:
				c.Warning++
			default:
				c.Info++
			}
		}
	}
	return c
}
