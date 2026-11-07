package cli

import (
	"fmt"
	"os"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/clean"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/kit"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/space"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func cmdClean(a *App, args []string) int {
	fs := a.flags("clean", "[--dry-run] [--json] [--yes]")
	dry := fs.Bool("dry-run", false, "")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	if *asJSON {
		r := clean.Scan(clean.Options{Env: a.E})
		if r.Items == nil {
			r.Items = []clean.Item{}
		}
		if r.Open == nil {
			r.Open = []string{}
		}
		if r.Owned == nil {
			r.Owned = []space.Entry{}
		}
		if r.Admin == nil {
			r.Admin = []clean.Admin{}
		}
		return emit(a, r)
	}
	u := a.U
	u.Blank()
	sp := u.Spin("Looking at app caches and logs")
	r := clean.Scan(clean.Options{Env: a.E, Progress: func(p string) { sp.Detail(a.E.Tilde(p)) }})
	sp.Stop()
	defer a.cleanNotes(r)
	if len(r.Items) == 0 {
		u.Say("  " + u.Bold("Nothing to clean."))
		a.openNote(r)
		a.reaction = reaction{kit.Sleep, u.Dim("Nothing to clean right now.")}
		return ExitOK
	}
	u.Say("  " + u.Bold(fmt.Sprintf("Found %s that rebuild themselves", ui.Count(len(r.Items), "folder", "folders"))) + u.Faint("  ·  ") + u.Dim("about "+ui.Size(r.Total())))
	a.openNote(r)
	u.Blank()
	items := make([]ui.Item, len(r.Items))
	for i, it := range r.Items {
		items[i] = ui.Item{Label: it.Name, About: it.About, Size: it.Bytes, Picked: true, Path: a.E.Tilde(it.Path)}
	}
	if *dry {
		for _, it := range r.Items {
			u.Say(fmt.Sprintf("  %8s  %s", ui.Size(it.Bytes), it.Name))
			u.Hint("   " + a.E.Tilde(it.Path))
		}
		u.Blank()
		u.Say("  " + u.Dim("Dry run: nothing was moved."))
		return ExitOK
	}
	m := &ui.Menu{Items: items, Noun: "folder", Nouns: "folders", Action: "clean", Note: "everything goes to the Trash first",
		Keys: []ui.MenuKey{
			{Key: "o", Label: "open", Do: func(i int) string { return a.reveal(r.Items[i].Path) }},
			{Key: "y", Label: "copy path", Do: func(i int) string { return a.copyText(r.Items[i].Path, "the path") }},
		}}
	if a.inSession {
		m.Cancel = "back"
	}
	if !m.Run(u) {
		a.outcome.SkipWait = true
		u.Say("  " + u.Dim("Nothing was moved."))
		return ExitOK
	}
	batch := journal.NewBatch(a.E.Now())
	var moved []journal.Entry
	var freed int64
	u.Step("Moving to the Trash", "Moved to the Trash", func(s *ui.Spinner) (string, error) {
		for i, p := range m.Items {
			if !p.Picked {
				continue
			}
			it := r.Items[i]
			s.Detail(it.Name)
			if err := a.moveToTrash(it.Path, it.Name+", "+it.Kind, batch, it.Bytes); err != nil {
				u.Warn(a.E.Tilde(it.Path) + ": " + err.Error())
				continue
			}
			freed += it.Bytes
		}
		return "", nil
	})
	for _, e := range a.Journal.All() {
		if e.Batch == batch && e.Kind == journal.KindTrash {
			moved = append(moved, e)
		}
	}
	if len(moved) == 0 {
		a.outcome.SkipWait = len(r.Items) > 0
		return ExitFailed
	}
	a.outcome.Changed = true
	u.Blank()
	u.Say("  " + u.Bold(ui.Count(len(moved), "folder", "folders")+" moved") + u.Dim(", about ") + u.Bold(ui.Size(freed)) + u.Dim(" in the Trash."))
	// The space only comes back when the Trash is emptied. Offer to empty exactly these, and say plainly it is final.
	u.Hint("The space comes back once they leave the Trash. Emptying them is final: Undo cannot bring them back.")
	if u.Ask("Empty just these from the Trash now?") {
		failed := 0
		for _, e := range moved {
			if err := os.RemoveAll(e.To); err != nil {
				failed++
				continue
			}
			if e.Info != "" {
				os.Remove(e.Info)
			}
		}
		a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindEmpty, Title: "Emptied those from the Trash"})
		if failed == 0 {
			u.Ok("About " + ui.Size(freed) + " is free again.")
		} else {
			u.Warn(fmt.Sprintf("%d could not be emptied. They are still in the Trash.", failed))
		}
		a.reaction = reaction{kit.Happy, u.Green("Cleaned about "+ui.Size(freed)+".") + " " + u.Dim("They rebuild themselves.")}
		return ExitOK
	}
	u.Say("  " + u.Dim("They stay in the Trash, and Undo can put them back."))
	a.reaction = reaction{kit.Happy, u.Green("Moved about "+ui.Size(freed)+" to the Trash.") + " " + u.Dim("Undo brings it back.")}
	if a.inSession {
		a.outcome.Actions = append(a.outcome.Actions, session.Action{Key: "u", Label: "undo", Title: "Undo", Args: []string{"undo"}})
	}
	return ExitOK
}

func (a *App) openNote(r clean.Report) {
	if len(r.Open) == 0 {
		return
	}
	a.U.Say("  " + a.U.Dim("Left alone because they are open: "+strings.Join(r.Open, ", ")+". Quit them to include their caches."))
}

// cleanNotes ends a clean with what it found but will not touch, and why, so nothing big goes unexplained.
func (a *App) cleanNotes(r clean.Report) {
	u := a.U
	if len(r.Owned) > 0 {
		u.Blank()
		u.Say("  " + u.Faint("BIG, BUT YOURS TO DECIDE"))
		for _, o := range r.Owned {
			u.Say(fmt.Sprintf("  %8s  %s", ui.Size(o.Bytes), o.Name))
			u.Hint("     " + o.How)
		}
	}
	if a.inSession {
		u.Blank()
		u.Say("  " + u.Dim("Models, virtual machines and the system's own areas are on the System Data screen, each with its safe way out."))
		a.outcome.Actions = append(a.outcome.Actions, goTo("x", "System Data", "System Data", "system"))
		return
	}
	if len(r.Admin) > 0 {
		u.Blank()
		u.Say("  " + u.Faint("NEEDS ADMIN RIGHTS"))
		for _, ad := range r.Admin {
			size := ""
			switch {
			case ad.Bytes > 0:
				size = ui.Size(ad.Bytes)
			case ad.Count > 0:
				size = fmt.Sprintf("%d", ad.Count)
			}
			u.Say(fmt.Sprintf("  %8s  %s", size, ad.Name))
			u.Hint("     " + ad.Note)
			if ad.Command != "" {
				u.Say("            " + u.Accent(ad.Command))
			}
		}
	}
	u.Blank()
}
