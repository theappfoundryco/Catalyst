package cli

import (
	"fmt"
	"os"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/state"
	"github.com/theappfoundryco/catalyst/internal/ui"
	"github.com/theappfoundryco/catalyst/internal/version"
)

func (a *App) welcome() session.Welcome {
	u := a.U
	w := session.Welcome{Lines: []string{u.Bold("Catalyst") + " " + u.Dim("v"+strings.TrimPrefix(version.Version, "v"))}}
	shell := ""
	if a.E.Shell != "" {
		s := a.E.Shell
		shell = ", " + s[strings.LastIndex(s, "/")+1:]
	}
	w.Lines = append(w.Lines, u.Dim(a.E.OSName()+", "+a.E.Arch+shell))
	h := a.Store.History()
	if len(h) == 0 {
		w.Lines = append(w.Lines, u.Dim("No checkup yet. Try doctor."))
		return w
	}
	last := h[len(h)-1]
	line := u.ScoreStyle(last.Score)(fmt.Sprintf("Health %d", last.Score))
	if change, since, ok := state.Trend(h); ok {
		line += " " + u.Dim(trendWords(change, since, a.E.Now()))
	} else {
		line += " " + u.Dim("from "+ui.When(last.Date))
	}
	w.Lines = append(w.Lines, line)
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
		w.Lines = append(w.Lines, strings.Join(bits, u.Dim("  ·  ")))
	}
	return w
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
	u.Blank()
	head := []string{u.Bold(name) + " " + u.Dim(a.E.OSName())}
	if len(h) > 0 {
		last := h[len(h)-1]
		line := u.ScoreStyle(last.Score)(fmt.Sprintf("Health %d", last.Score))
		line += " " + u.Dim("from "+ui.When(last.Date))
		head = append(head, line)
	} else {
		head = append(head, u.Dim("No checkup yet: catalyst doctor"))
	}
	u.Beside("idle", head)
	u.Say("  " + u.Rule(52))
	loadPct := 0
	if threads > 0 {
		loadPct = int(load * 100 / float64(threads))
	}
	u.Row("CPU", u.Bar(loadPct, bar, 60, 85)+"  "+u.Dim(fmt.Sprintf("load %.2f of %d", load, threads)))
	if memOK {
		u.Row("Memory", u.Bar(mem.Percent(), bar, 75, 90)+"  "+u.Dim(ui.RAM(mem.Used)+" of "+ui.RAM(mem.Total)))
	}
	if volOK {
		u.Row("Disk", u.Bar(vol.UsedPercent, bar, 75, 90)+"  "+u.Dim(ui.Size(vol.Free)+" free"))
	}
	if bat.Present {
		note := bat.Source
		if bat.Charging {
			note = "charging"
		}
		u.Row("Battery", u.Green(fmt.Sprintf("%d%%", bat.Percent))+"  "+u.Dim(note))
	}
	if s, ok := a.Store.LastSweep(); ok && s.Bytes > 0 {
		u.Row("To sweep", "about "+ui.Size(s.Bytes)+"  "+u.Dim("catalyst sweep"))
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
	u.Signoff()
	return ExitOK
}
