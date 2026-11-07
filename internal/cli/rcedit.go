package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/journal"
)

// editFile changes a startup file the careful way. It shows the lines that change, asks, keeps a copy of the file as it
// was, writes, has zsh read the result, and puts the file back if zsh objects. Undo restores the copy.
func (a *App) editFile(path, title string, change func(lines []string) []string) bool {
	u := a.U
	b, err := os.ReadFile(path)
	if err != nil {
		u.Stop("Could not read " + a.E.Tilde(path) + ".")
		return false
	}
	old := strings.Split(string(b), "\n")
	next := change(append([]string{}, old...))
	removed, added := lineDiff(old, next)
	if len(removed)+len(added) == 0 {
		u.Ok("Nothing to change in " + a.E.Tilde(path) + ".")
		return false
	}
	u.Say("  " + u.Bold(title))
	u.Say("  " + u.Dim("In "+a.E.Tilde(path)+":"))
	for _, l := range removed {
		u.Say("     " + u.Red("- "+l))
	}
	for _, l := range added {
		u.Say("     " + u.Green("+ "+l))
	}
	u.Hint("A copy of the file is kept first, zsh checks the result, and Undo puts it back.")
	if !u.Ask("Make this change?") {
		u.Say("  " + u.Dim("Left as it is."))
		return false
	}
	batch := journal.NewBatch(a.E.Now())
	dir := filepath.Join(a.Store.Dir, "backups")
	os.MkdirAll(dir, 0o700)
	copyPath := filepath.Join(dir, batch+"-"+strings.TrimPrefix(filepath.Base(path), "."))
	if err := os.WriteFile(copyPath, b, 0o600); err != nil {
		u.Stop("Could not keep a copy first, so nothing was changed.")
		return false
	}
	mode := os.FileMode(0o644)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
	}
	if err := os.WriteFile(path, []byte(strings.Join(next, "\n")), mode); err != nil {
		u.Stop("Could not write it: " + err.Error())
		return false
	}
	if _, err := a.E.Look("zsh"); err == nil && strings.Contains(path, "zsh") {
		if r := a.E.Run.Run(0, "zsh", "-n", path); !r.OK() {
			os.WriteFile(path, b, mode)
			u.Stop("zsh did not accept the result, so the file was put back as it was.")
			return false
		}
	}
	if err := a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindEdit, Title: title, From: path, To: copyPath}); err != nil {
		os.WriteFile(path, b, mode)
		u.Stop("Could not record the change, so the file was put back.")
		return false
	}
	u.Ok("Done. Open a new terminal to use it. Undo is on the home screen.")
	a.outcome.Changed = true
	return true
}

// lineDiff is what left and what arrived, in order. Startup-file fixes touch a few lines, so this is enough.
func lineDiff(old, next []string) (removed, added []string) {
	count := map[string]int{}
	for _, l := range next {
		count[l]++
	}
	for _, l := range old {
		if count[l] > 0 {
			count[l]--
			continue
		}
		removed = append(removed, l)
	}
	count = map[string]int{}
	for _, l := range old {
		count[l]++
	}
	for _, l := range next {
		if count[l] > 0 {
			count[l]--
			continue
		}
		added = append(added, l)
	}
	return removed, added
}

// restoreCopy puts a kept copy back over the file it came from.
func restoreCopy(from, to string) error {
	b, err := os.ReadFile(from)
	if err != nil {
		return fmt.Errorf("the copy from before is gone: %v", err)
	}
	mode := os.FileMode(0o644)
	if st, err := os.Stat(to); err == nil {
		mode = st.Mode().Perm()
	}
	return os.WriteFile(to, b, mode)
}
