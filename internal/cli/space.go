package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/space"
	"github.com/theappfoundryco/catalyst/internal/sweep"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func cmdSpace(a *App, args []string) int {
	fs := a.flags("space", "[--in PATH] [--json]")
	asJSON := fs.Bool("json", false, "")
	in := fs.String("in", "", "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	if *in != "" {
		return a.spaceIn(*in)
	}
	a.outcome.Refresh = true
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
		path  string
	}
	var rows []row
	for i, h := range r.Home {
		if i == 8 || h.Bytes < 100_000_000 {
			break
		}
		rows = append(rows, row{"~/" + h.Name, h.Bytes, "", h.Path})
	}
	if r.Apps > 0 {
		rows = append(rows, row{"Applications", r.Apps, "", "/Applications"})
	}
	if r.System != nil {
		rows = append(rows, row{"macOS", r.System.Total(), "Apple's own volumes, press Enter", ""})
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
		var keys []session.Action
		switch {
		case x.path == "" && r.System != nil:
			sys := *r.System
			keys = append(keys, a.page("⏎", "what is in it", "macOS", func() { a.explainMacOS(sys) }))
		case isDir(x.path):
			keys = append(keys, goTo("⏎", "look inside", x.name, "space", "--in", x.path), a.revealKey(x.path), a.copyKey("y", "copy path", x.path, "the path"))
		case x.path != "":
			keys = append(keys, a.revealKey(x.path), a.copyKey("y", "copy path", x.path, "the path"))
		}
		line := fmt.Sprintf("  %s%8s  %s%s  %s", a.row(keys...), ui.Size(x.bytes), u.Accent(strings.Repeat("█", bar)), strings.Repeat(" ", 16-bar), x.name)
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
			mark := a.row(goTo("⏎", "look inside", l.Name, "space", "--in", l.Path), a.revealKey(l.Path), a.copyKey("y", "copy path", l.Path, "the path"))
			if oneLine {
				u.Say(fmt.Sprintf("  %s%8s  %-*s  %s", mark, ui.Size(l.Bytes), nameW, l.Name, hows[i]))
				continue
			}
			u.Say(fmt.Sprintf("  %s%8s  %s", mark, ui.Size(l.Bytes), l.Name))
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
			if a.inSession {
				a.outcome.Actions = append(a.outcome.Actions, a.urlKey("a", "Full Disk Access", settingsDiskAccess))
			}
		}
	}
	if a.inSession {
		for _, l := range r.Landmarks {
			if l.Clean {
				a.outcome.Actions = append(a.outcome.Actions, session.Action{Key: "c", Label: "clean", Title: "Clean", Args: []string{"clean"}})
				break
			}
		}
		a.outcome.Actions = append(a.outcome.Actions, goTo("x", "System Data", "System Data", "system"))
	} else if a.E.Mac() {
		u.Blank()
		u.Hint("What macOS calls System Data, and what of it can safely go: catalyst system")
	}
	u.Blank()
	return ExitOK
}

// explainMacOS is what "macOS" means in storage settings, part by part, and why none of it can be cleared.
func (a *App) explainMacOS(s space.System) {
	u := a.U
	u.Hdr("macOS")
	u.Say("  " + u.Bold("macOS takes "+ui.Size(s.Total())+".") + u.Dim(" None of it can be cleared, and no tool should try."))
	u.Blank()
	part := func(size int64, name, about string) {
		u.Say(fmt.Sprintf("  %8s  %s", ui.Size(size), u.Bold(name)))
		for _, l := range u.Wrap("            "+about, u.Width()) {
			u.Say(u.Dim(l))
		}
	}
	part(s.Sealed, "The sealed system", "macOS itself, on a read-only volume. Apple signs it and your Mac checks it at every start, so it cannot change.")
	part(s.Boot, "Boot files", "What your Mac needs to start, and files kept for updates. It shrinks by itself after an update finishes.")
	part(s.Recovery, "Recovery", "A small macOS you can start into to repair or reinstall this one.")
	part(s.Swap, "Swap and sleep image", "The one part that moves. Swap is memory spilled onto the disk when apps need more than the Mac has. The sleep image is a copy of memory for deep sleep. Both shrink on a restart, or when you quit big apps.")
	u.Blank()
	u.Say("  " + u.Bold("System Data is different."))
	u.Say("  " + u.Dim("Settings counts your own hidden folders and app data there: caches, virtual machines, models and logs. Most space you can get back lives there, and the System Data screen shows each part with its safe way out."))
	u.Blank()
	if a.inSession {
		a.outcome.Actions = append(a.outcome.Actions, goTo("x", "System Data", "System Data", "system"))
		if a.E.Mac() {
			a.outcome.Actions = append(a.outcome.Actions, a.urlKey("s", "Storage settings", settingsStorage))
		}
	}
}

// spaceIn measures what is inside one folder, biggest first, so a person can follow the space down to where it is.
func (a *App) spaceIn(dir string) int {
	u := a.U
	a.outcome.Refresh = true
	entries, err := os.ReadDir(dir)
	if err != nil {
		u.Stop("Could not read " + a.E.Tilde(dir) + ".")
		if a.E.Mac() && os.IsPermission(err) {
			u.Hint("Your terminal may need Full Disk Access: System Settings, Privacy and Security.")
		}
		return ExitIssues
	}
	type item struct {
		name, path string
		bytes      int64
		dir        bool
	}
	var items []item
	var total int64
	sp := u.Spin("Measuring " + a.E.Tilde(dir))
	seen := sweep.NewSeen()
	for _, ent := range entries {
		p := filepath.Join(dir, ent.Name())
		sp.Detail(ent.Name())
		var n int64
		if ent.IsDir() {
			n = sweep.DirSize(p, seen)
		} else if st, err := os.Lstat(p); err == nil {
			n = st.Size()
		}
		total += n
		items = append(items, item{ent.Name(), p, n, ent.IsDir()})
	}
	sp.Stop()
	sort.Slice(items, func(i, j int) bool { return items[i].bytes > items[j].bytes })
	u.Say("  " + u.Bold(a.E.Tilde(dir)) + u.Faint("  ·  ") + u.Dim(ui.Size(total)+" in "+ui.Count(len(items), "item", "items")))
	u.Blank()
	biggest := int64(1)
	if len(items) > 0 && items[0].bytes > 0 {
		biggest = items[0].bytes
	}
	shown := 0
	for _, it := range items {
		if shown == 30 {
			u.Hint(fmt.Sprintf("and %d smaller ones", len(items)-30))
			break
		}
		shown++
		bar := int(it.bytes * 16 / biggest)
		if bar < 1 {
			bar = 1
		}
		name := it.name
		keys := []session.Action{a.revealKey(it.path), a.copyKey("y", "copy path", it.path, "the path")}
		if it.dir {
			name += "/"
			keys = append([]session.Action{goTo("⏎", "look inside", it.name, "space", "--in", it.path)}, keys...)
		}
		u.Say(fmt.Sprintf("  %s%8s  %s%s  %s", a.row(keys...), ui.Size(it.bytes), u.Accent(strings.Repeat("█", bar)), strings.Repeat(" ", 16-bar), name))
	}
	u.Blank()
	u.Hint("What to keep here is yours to decide. Sweep and Clean take what is safe to remove, with undo.")
	u.Blank()
	return ExitOK
}
