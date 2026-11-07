package cli

import (
	"fmt"
	"sort"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/space"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func cmdSpace(a *App, args []string) int {
	fs := a.flags("space", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	opts := space.Options{Env: a.E, Floor: 500_000_000}
	if *asJSON {
		r := space.Measure(opts)
		if r.Landmarks == nil {
			r.Landmarks = []space.Entry{}
		}
		return emit(a, r)
	}
	u := a.U
	u.Hdr("Space")
	sp := u.Spin("Measuring your folders")
	opts.Progress = func(p string) { sp.Detail(a.E.Tilde(p)) }
	r := space.Measure(opts)
	sp.Stop()
	if r.DiskOK {
		u.Row("Disk", u.Bar(r.Disk.UsedPercent, 18, 75, 90)+"  "+u.Dim(ui.Size(r.Disk.Free)+" free of "+ui.Size(r.Disk.Size)))
	}
	u.Blank()

	// What takes the space: the biggest folders in your home, your apps and the system, with bars against the biggest.
	type row struct {
		name  string
		bytes int64
		note  string
	}
	var rows []row
	for i, h := range r.Home {
		if i == 8 || h.Bytes < 100_000_000 {
			break
		}
		rows = append(rows, row{"~/" + h.Name, h.Bytes, ""})
	}
	if r.Apps > 0 {
		rows = append(rows, row{"Applications", r.Apps, ""})
	}
	if r.System != nil {
		rows = append(rows, row{"macOS", r.System.Total(), "Apple's own volumes"})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].bytes > rows[j].bytes })
	biggest := int64(1)
	for _, x := range rows {
		if x.bytes > biggest {
			biggest = x.bytes
		}
	}
	u.Say("  " + u.Faint("WHAT TAKES THE SPACE"))
	for _, x := range rows {
		bar := int(x.bytes * 16 / biggest)
		if bar < 1 {
			bar = 1
		}
		line := fmt.Sprintf("  %8s  %s%s  %s", ui.Size(x.bytes), u.Accent(strings.Repeat("█", bar)), strings.Repeat(" ", 16-bar), x.name)
		if x.note != "" {
			line += "  " + u.Faint(x.note)
		}
		u.Say(line)
	}
	if s := r.System; s != nil {
		u.Blank()
		u.Say("  " + u.Bold("macOS") + u.Dim(fmt.Sprintf(" is %s: the sealed system %s, boot files %s, swap and sleep %s, recovery %s.",
			ui.Size(s.Total()), ui.Size(s.Sealed), ui.Size(s.Boot), ui.Size(s.Swap), ui.Size(s.Recovery))))
		u.Hint("None of it can be cleared safely. Swap is the exception: it shrinks when you quit big apps or restart.")
	}

	if len(r.Landmarks) > 0 {
		u.Blank()
		u.Say("  " + u.Faint("BIG THINGS INSIDE"))
		nameW := 10
		for _, l := range r.Landmarks {
			if n := len(l.Name); n > nameW {
				nameW = n
			}
		}
		hows := make([]string, len(r.Landmarks))
		oneLine := true
		for i, l := range r.Landmarks {
			hows[i] = u.Dim(l.How)
			if l.Clean {
				hows[i] = u.Soft("Clean can take it. ") + u.Dim(l.How)
			}
			oneLine = oneLine && 2+8+2+nameW+2+ui.Visible(hows[i]) <= u.Width()
		}
		// One line each when every note fits beside its name. Otherwise every note goes under its name, so the
		// column of sizes and names stays one clean column.
		for i, l := range r.Landmarks {
			if oneLine {
				u.Say(fmt.Sprintf("  %8s  %-*s  %s", ui.Size(l.Bytes), nameW, l.Name, hows[i]))
				continue
			}
			u.Say(fmt.Sprintf("  %8s  %s", ui.Size(l.Bytes), l.Name))
			for _, w := range u.Wrap(strings.Repeat(" ", 12)+hows[i], u.Width()) {
				fmt.Fprintln(u.Out, w)
			}
		}
	}
	if r.Unreadable > 0 {
		u.Blank()
		u.Note(ui.Count(r.Unreadable, "folder", "folders") + " could not be read, so the real totals are a little higher.")
		if a.E.Mac() {
			u.Hint("Mail and Messages need Full Disk Access for your terminal: System Settings, Privacy and Security.")
		}
	}
	if a.inSession {
		for _, l := range r.Landmarks {
			if l.Clean {
				a.outcome.Actions = append(a.outcome.Actions, session.Action{Key: "c", Label: "clean", Title: "Clean", Args: []string{"clean"}})
				break
			}
		}
	}
	u.Blank()
	return ExitOK
}
