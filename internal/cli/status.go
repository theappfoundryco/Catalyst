package cli

import (
	"fmt"
	"os"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

// header is the text beside Kit on the home screen, read fresh each time so it follows what just ran. The name comes first,
// and the last line is the one that changes: what just happened, or else what is worth doing.
func (a *App) header() session.Header {
	u := a.U
	shell := ""
	if a.E.Shell != "" {
		s := a.E.Shell
		shell = ", " + s[strings.LastIndex(s, "/")+1:]
	}
	lines := []string{
		u.Bold("Catalyst") + " " + u.Dim("v"+strings.TrimPrefix(version.Version, "v")),
		u.Dim(a.E.OSName() + ", " + a.E.Arch + shell),
		"",
	}
	mood := a.reaction.mood
	if mood == "" {
		mood = kit.Idle
	}
	h := a.Store.History()
	if len(h) == 0 {
		line := a.reaction.line
		if line == "" {
			line = u.Dim("No checkup yet. Doctor is a good start.")
		}
		return session.Header{Mood: mood, Lines: append(lines, line)}
	}
	last := h[len(h)-1]
	health := u.ScoreStyle(last.Score)(fmt.Sprintf("Health %d", last.Score))
	if change, since, ok := state.Trend(h); ok {
		health += " " + u.Dim(trendWords(change, since, a.E.Now()))
	} else {
		health += " " + u.Dim("from "+ui.When(last.Date))
	}
	lines = append(lines, health)
	if a.reaction.line != "" {
		return session.Header{Mood: mood, Lines: append(lines, a.reaction.line)}
	}
	var bits []string
	if last.Critical > 0 {
		bits = append(bits, u.Red(ui.Count(last.Critical, "thing needs", "things need")+" fixing"))
	} else if last.Issues > 0 {
		bits = append(bits, u.Yellow(ui.Count(last.Issues, "thing", "things")+" worth a look"))
	}
	if s, ok := a.Store.LastSweep(); ok && s.Bytes > 0 {
		bits = append(bits, u.Cyan("about "+ui.Size(s.Bytes))+" "+u.Dim("to sweep"))
	}
	if len(bits) > 0 {
		lines = append(lines, strings.Join(bits, u.Dim("  ·  ")))
	}
	return session.Header{Mood: mood, Lines: lines}
}

type statusReport struct {
	Host    string  `json:"host"`
	OS      string  `json:"os"`
	Load    float64 `json:"load"`
	Threads int     `json:"threads"`
	Memory  int     `json:"memory_percent"`
	Disk    int     `json:"disk_percent"`
	Battery *int    `json:"battery_percent,omitempty"`
	Health  *int    `json:"health,omitempty"`
}

// The percentages at which a bar turns yellow and red.
const (
	cpuWarn, cpuCrit   = 60, 85
	memWarn, memCrit   = 75, 90
	diskWarn, diskCrit = 75, 90
)

// statusVerdict decides how the card ends. It only reports what is red, because a Mac's memory sits in the yellow all day
// and that is normal. allClear is true only when every bar is green, and only then may the card say something cheerful.
func statusVerdict(cpu, mem, disk int, memOK, diskOK bool) (problems []string, allClear bool) {
	if cpu >= cpuCrit {
		problems = append(problems, "The CPU is very busy right now.")
	}
	if memOK && mem >= memCrit {
		problems = append(problems, "Memory is nearly full.")
	}
	if diskOK && disk >= diskCrit {
		problems = append(problems, "The disk is nearly full.")
	}
	allClear = cpu < cpuWarn && (!memOK || mem < memWarn) && (!diskOK || disk < diskWarn)
	return problems, allClear
}

func cmdStatus(a *App, args []string) int {
	fs := a.flags("status", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	name, _ := os.Hostname()
	load, threads := a.E.Load()
	mem, memOK := a.E.Memory()
	vol, volOK := a.E.HomeVolume()
	bat := a.E.Battery()
	h := a.Store.History()
	if *asJSON {
		r := statusReport{Host: name, OS: a.E.OSName(), Load: load, Threads: threads, Memory: mem.Percent(), Disk: vol.UsedPercent}
		if bat.Present {
			r.Battery = &bat.Percent
		}
		if len(h) > 0 {
			r.Health = &h[len(h)-1].Score
		}
		return emit(a, r)
	}
	bar := 18
	if u.Width() < 60 {
		bar = 10
	}
	u.Hdr("Status")
	u.Row("Machine", name+"  "+u.Dim(a.E.OSName()))
	if len(h) > 0 {
		last := h[len(h)-1]
		u.Row("Health", u.ScoreStyle(last.Score)(fmt.Sprintf("%d", last.Score))+"  "+u.Dim("from "+ui.When(last.Date)))
	} else if a.inSession {
		u.Row("Health", u.Dim("No checkup yet"))
	} else {
		u.Row("Health", u.Dim("No checkup yet: catalyst doctor"))
	}
	loadPct := 0
	if threads > 0 {
		loadPct = int(load * 100 / float64(threads))
	}
	u.Row("CPU", u.Bar(loadPct, bar, cpuWarn, cpuCrit)+"  "+u.Dim(fmt.Sprintf("load %.2f of %d", load, threads)))
	if memOK {
		u.Row("Memory", u.Bar(mem.Percent(), bar, memWarn, memCrit)+"  "+u.Dim(ui.RAM(mem.Used)+" of "+ui.RAM(mem.Total)))
	}
	if volOK {
		u.Row("Disk", u.Bar(vol.UsedPercent, bar, diskWarn, diskCrit)+"  "+u.Dim(ui.Size(vol.Free)+" free"))
	}
	if bat.Present {
		note := bat.Source
		if bat.Charging {
			note = "charging"
		}
		u.Row("Battery", u.Green(fmt.Sprintf("%d%%", bat.Percent))+"  "+u.Dim(note))
	}
	if s, ok := a.Store.LastSweep(); ok && s.Bytes > 0 {
		if a.inSession {
			u.Row("To sweep", "about "+ui.Size(s.Bytes))
		} else {
			u.Row("To sweep", "about "+ui.Size(s.Bytes)+"  "+u.Dim("catalyst sweep"))
		}
	}
	if _, err := a.E.Look("docker"); err == nil {
		if out, ok := a.E.Out("docker", "ps", "-q"); ok {
			n := 0
			if strings.TrimSpace(out) != "" {
				n = strings.Count(strings.TrimSpace(out), "\n") + 1
			}
			u.Row("Docker", ui.Count(n, "container", "containers")+" running")
		}
	}
	problems, allClear := statusVerdict(loadPct, mem.Percent(), vol.UsedPercent, memOK, volOK)
	if len(problems) > 0 {
		u.Blank()
		for _, p := range problems {
			u.Warn(p)
		}
		u.Blank()
	} else if allClear {
		u.Signoff()
	} else {
		u.Blank()
	}
	return ExitOK
}
