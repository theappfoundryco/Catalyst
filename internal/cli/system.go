package cli

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/space"
	"github.com/theappfoundryco/catalyst/internal/sweep"
	"github.com/theappfoundryco/catalyst/internal/sysdata"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// cmdSystem is the careful screen for what macOS calls System Data. It explains every area, offers only what has a
// supported way out, shows each command before it runs, and lets sudo ask for the password itself.
func cmdSystem(a *App, args []string) int {
	fs := a.flags("system", "[--dry-run] [--admin] [--json]")
	dry := fs.Bool("dry-run", false, "")
	asJSON := fs.Bool("json", false, "")
	admin := fs.Bool("admin", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	var sys *space.System
	if a.E.Mac() {
		if out, ok := a.E.Out("diskutil", "apfs", "list"); ok {
			vol, _ := a.E.HomeVolume()
			if s := space.ParseAPFS(out, vol.Name); s.Total() > 0 {
				sys = &s
			}
		}
	}
	if *asJSON {
		return emit(a, sysdata.Scan(a.E, sys, nil))
	}
	u.Hdr("System Data")
	if a.E.Mac() {
		u.Warning("Careful: these are your Mac's own areas",
			"Removing the wrong thing here can stop apps, or your Mac, from starting. Catalyst only offers what Apple or the app that made it supports, shows every command first, and asks for your password through macOS. Have a recent backup before you go on.")
	} else {
		u.Warning("Careful: these are the system's own areas",
			"Removing the wrong thing here can break programs, or stop this machine from starting. Catalyst only offers what your package manager supports, shows every command first, and lets sudo ask for your password. Have a recent backup before you go on.")
	}
	u.Blank()
	if a.E.Mac() {
		u.Say("  " + u.Dim("What Settings calls System Data is mostly your own apps' data: caches, virtual machines and models. What it calls macOS is the system itself, which can never be cleared. Each row below says which is which."))
		u.Blank()
	}
	sizes := map[string]int64{}
	if *admin {
		sizes = a.measureAsRoot()
	}
	sp := u.Spin("Measuring")
	r := sysdata.Scan(a.E, sys, func(p string) int64 {
		sp.Detail(a.E.Tilde(p))
		if n, ok := sizes[p]; ok {
			return n
		}
		return a.sizeOf(p)
	})
	sp.Stop()
	if len(r.Areas) == 0 {
		u.Say("  " + u.Dim("Nothing here takes enough space to be worth a look."))
		u.Blank()
		return ExitOK
	}
	if *dry || !u.TTY {
		for _, ar := range r.Areas {
			u.Say(fmt.Sprintf("  %8s  %-34s %s", sizeOr(ar), ar.Name, u.Dim(ar.WayWords())))
		}
		u.Blank()
		u.Say("  " + u.Dim("Nothing was changed."))
		return ExitOK
	}
	items := make([]ui.Item, len(r.Areas))
	for i, ar := range r.Areas {
		about := ar.About
		if ar.Cost != "" {
			about += " " + ar.Cost
		}
		if ar.Admin && !*admin && a.E.Mac() {
			about += " (Some of it can only be measured with admin rights.)"
		}
		path := ""
		if ar.Path != "" {
			path = a.E.Tilde(ar.Path)
		}
		items[i] = ui.Item{Label: ar.Name, Size: ar.Bytes, Right: ar.WayWords(), About: about, Path: path, Locked: !ar.Selectable()}
		if ar.Bytes == 0 && ar.Count > 0 {
			items[i].Right = strconv.Itoa(ar.Count) + " · " + ar.WayWords()
		}
	}
	keys := []ui.MenuKey{
		{Key: "o", Label: "open", Do: func(i int) string {
			if r.Areas[i].Path == "" {
				return "This one has no folder to show."
			}
			return a.reveal(r.Areas[i].Path)
		}},
		{Key: "y", Label: "copy path", Do: func(i int) string {
			if r.Areas[i].Path == "" {
				return "This one has no path."
			}
			return a.copyText(r.Areas[i].Path, "the path")
		}},
	}
	m := &ui.Menu{Items: items, Noun: "area", Nouns: "areas", Action: "continue", Note: "each step is shown before it runs", Keys: keys, Reserve: 10}
	if a.inSession {
		m.Cancel = "back"
	}
	if !m.Run(u) {
		a.outcome.SkipWait = true
		return ExitOK
	}
	var picked []sysdata.Area
	for i, it := range m.Items {
		if it.Picked {
			picked = append(picked, r.Areas[i])
		}
	}
	if len(picked) == 0 {
		u.Say("  " + u.Dim("Nothing was selected, so nothing changed."))
		if a.inSession && a.E.Mac() && !*admin {
			a.outcome.Actions = append(a.outcome.Actions, goTo("d", "measure all", "System Data", "system", "--admin"))
		}
		return ExitOK
	}
	return a.reclaim(picked)
}

func sizeOr(ar sysdata.Area) string {
	switch {
	case ar.Bytes == 0 && ar.Count > 0:
		return strconv.Itoa(ar.Count)
	case ar.Bytes == 0:
		return ""
	}
	return ui.Size(ar.Bytes)
}

// reclaim shows exactly what will happen to each chosen area, asks once, and then does it.
func (a *App) reclaim(picked []sysdata.Area) int {
	u := a.U
	u.Say("  " + u.Bold("This is what will happen:"))
	u.Blank()
	needRoot := false
	for _, ar := range picked {
		u.Say("  " + u.Bold(ar.Name) + u.Dim("  "+sizeOr(ar)))
		switch ar.Way {
		case sysdata.Trash:
			u.Hint("Moved to the Trash: " + a.E.Tilde(ar.Path) + ". Undo puts it back.")
		case sysdata.Owner:
			u.Hint("Runs " + strings.Join(ar.Command, " ") + " as you. It may ask its own questions. This cannot be undone.")
		case sysdata.Settings:
			u.Hint("Opens System Settings at the right page. You make the change there.")
		case sysdata.Root:
			u.Hint("Runs sudo " + strings.Join(ar.Command, " ") + ". This cannot be undone.")
			needRoot = true
		}
	}
	u.Blank()
	if !u.Ask("Go ahead?") {
		u.Say("  " + u.Dim("Nothing was changed."))
		return ExitOK
	}
	if needRoot && !a.sudoReady() {
		return ExitIssues
	}
	before, _ := a.E.HomeVolume()
	batch := journal.NewBatch(a.E.Now())
	done, trashed := 0, 0
	for _, ar := range picked {
		switch ar.Way {
		case sysdata.Trash:
			if err := a.moveToTrash(ar.Path, ar.Name, batch, ar.Bytes); err != nil {
				u.Warn(ar.Name + ": " + err.Error())
				continue
			}
			u.Ok("Moved " + ar.Name + " to the Trash")
			trashed++
		case sysdata.Owner:
			u.Say("  " + u.Faint("$ "+strings.Join(ar.Command, " ")))
			if _, code := run.Attached(false, ar.Command[0], ar.Command[1:]...); code != 0 {
				u.Warn(ar.Name + ": it stopped without finishing, so it may be unchanged.")
				continue
			}
			a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: ar.Name, Command: ar.Command})
			u.Ok(ar.Name + ": done")
		case sysdata.Settings:
			u.Ok(a.openURL(ar.Settings, "Settings"))
			continue
		case sysdata.Root:
			u.Say("  " + u.Faint("$ sudo "+strings.Join(ar.Command, " ")))
			if !a.asRoot(ar.Command...) {
				u.Warn(ar.Name + ": it did not finish, so it may be unchanged.")
				continue
			}
			a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: ar.Name, Command: append([]string{"sudo"}, ar.Command...)})
			u.Ok(ar.Name + ": done")
		}
		done++
	}
	a.outcome.Changed = done > 0
	if after, ok := a.E.HomeVolume(); ok && after.Free > before.Free {
		u.Blank()
		u.Say("  " + u.Bold("About "+ui.Size(after.Free-before.Free)+" is free again.") + u.Dim("  "+ui.Size(after.Free)+" free now."))
		a.reaction = reaction{kit.Happy, u.Green("Gave back about " + ui.Size(after.Free-before.Free) + ".")}
	} else if trashed > 0 {
		u.Blank()
		u.Hint("What went to the Trash comes back as free space once the Trash is emptied.")
	}
	return ExitOK
}

// measureAsRoot sizes the folders a person may not read, with sudo du, after sudo asks for the password itself.
func (a *App) measureAsRoot() map[string]int64 {
	out := map[string]int64{}
	paths := []string{"/private/var/folders", "/private/var/db/diagnostics", "/private/var/db/uuidtext", "/System/Library/AssetsV2", "/Library/Caches", "/private/var/vm"}
	if !a.sudoReady() {
		return out
	}
	text, _ := run.Attached(true, "sudo", append([]string{"du", "-skx"}, paths...)...)
	for _, l := range strings.Split(text, "\n") {
		f := strings.SplitN(strings.TrimSpace(l), "\t", 2)
		if len(f) != 2 {
			continue
		}
		if kb, err := strconv.ParseInt(f[0], 10, 64); err == nil {
			out[f[1]] = kb * 1024
		}
	}
	return out
}

func defaultSize(p string) int64 { return sweep.DirSize(p, sweep.NewSeen()) }

func (a *App) sizeOf(p string) int64 {
	if a.SizeOf != nil {
		return a.SizeOf(p)
	}
	return defaultSize(p)
}
