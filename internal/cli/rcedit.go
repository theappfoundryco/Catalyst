package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/rcfile"
	"github.com/theappfoundryco/catalyst/internal/shellpath"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// startupEdit is one change to a shell startup file.
type startupEdit struct {
	Path   string
	Title  string
	Change func(lines []string) []string
	Ask    bool   // show the change and ask first
	DryRun bool   // show the change and what the shell makes of it, and write nothing
	Batch  string // the journal batch it joins, or "" for one of its own
	Create bool   // the file may not exist yet
	// Mends is a change meant to fix the file. It may still leave the shell rejecting a file that was rejected before,
	// since one fix can be the first of two, but it may never break a file the shell accepted.
	Mends bool
	Quiet bool // the caller says what was done
}

// editStartup changes a startup file the careful way:
//
//  1. it finds the real file behind a link, and stops at a folder, a link to nothing or a file it may not write
//  2. it works out the new text and shows exactly which lines change
//  3. the file's own shell reads the new text from a scratch copy, before the real file is touched
//  4. it keeps a copy, writes, reads the file back, and records the change, so Undo puts it back
//
// A file the shell already rejects gets nothing added to it: a line after a syntax error never runs. It returns
// true when the file changed.
func (a *App) editStartup(ed startupEdit) bool {
	u := a.U
	name := a.E.Tilde(ed.Path)
	ed.DryRun = ed.DryRun || u.DryRun
	real, text, ok := a.readStartup(ed.Path, ed.Create)
	if !ok {
		return false
	}
	old := rcfile.Lines(text)
	next := ed.Change(append([]string{}, old...))
	newText := strings.Join(next, "\n")
	if newText == text {
		if !ed.Quiet {
			u.Ok("Nothing to change in " + name + ".")
		}
		return false
	}
	if ed.Ask || ed.DryRun {
		u.Say("  " + u.Bold(ed.Title))
		a.showLineChange(ed.Path, old, next)
	}
	shell := rcfile.Shell(ed.Path)
	if shell == "" {
		shell = rcfile.Shell(real)
	}
	before, after, checked := a.parseBoth(shell, real, text, newText)
	switch {
	case !checked:
	case after == "":
	case before == "" || !ed.Mends:
		if before == "" {
			u.Stop("That change would leave " + name + " with a syntax error, so nothing was written.")
			u.Hint(shell + " says: " + after)
		} else {
			u.Stop(name + " already has a syntax error, so a line added to it would never run. Nothing was written.")
			u.Hint(shell + " says: " + before)
			u.Hint(a.seeSlips())
		}
		return false
	}
	if ed.DryRun {
		msg := "Dry run: nothing was written."
		switch {
		case !checked && shell != "":
			msg += " " + shell + " is not installed here, so the result could not be checked."
		case checked && after == "":
			msg += " " + shell + " reads the result without complaint."
		case checked:
			msg += " " + shell + " would still report: " + after
		}
		u.Say("  " + u.Dim(msg))
		return false
	}
	if ed.Ask {
		hint := "A copy of the file is kept first, and Undo puts it back."
		if !checked && shell != "" {
			hint = shell + " is not installed here, so the result cannot be checked first. " + hint
		}
		u.Hint(hint)
		if !u.Ask("Make this change?") {
			u.Say("  " + u.Dim("Left as it is."))
			return false
		}
	}
	batch := ed.Batch
	if batch == "" {
		batch = journal.NewBatch(a.E.Now())
	}
	dir := filepath.Join(a.Store.Dir, "backups")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		u.Stop("Could not keep a copy first, so nothing was changed: " + err.Error())
		return false
	}
	copyPath := filepath.Join(dir, batch+"-"+strings.TrimPrefix(filepath.Base(ed.Path), "."))
	for n := 2; fileExists(copyPath); n++ { // two edits of one file in one batch keep both copies
		copyPath = filepath.Join(dir, fmt.Sprintf("%s-%d-%s", batch, n, strings.TrimPrefix(filepath.Base(ed.Path), ".")))
	}
	if err := os.WriteFile(copyPath, []byte(text), 0o600); err != nil {
		u.Stop("Could not keep a copy first, so nothing was changed: " + err.Error())
		return false
	}
	mode := os.FileMode(0o644)
	if st, err := os.Stat(real); err == nil {
		mode = st.Mode().Perm()
	} else if err := os.MkdirAll(filepath.Dir(real), 0o755); err != nil {
		u.Stop("Could not make " + a.E.Tilde(filepath.Dir(real)) + ": " + err.Error())
		return false
	}
	putBack := func() { os.WriteFile(real, []byte(text), mode) }
	if err := os.WriteFile(real, []byte(newText), mode); err != nil {
		putBack()
		u.Stop("Could not write " + name + ", so it was left as it was: " + plainErr(err))
		return false
	}
	if b, err := os.ReadFile(real); err != nil || string(b) != newText { // a full disk can cut a write short
		putBack()
		u.Stop("The file did not keep what was written, so it was put back as it was.")
		return false
	}
	if err := a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindEdit, Title: ed.Title, From: real, To: copyPath, Sum: sum(newText)}); err != nil {
		putBack()
		u.Stop("Could not record the change for Undo, so the file was put back.")
		return false
	}
	a.outcome.Changed = true
	if checked && after != "" {
		u.Warn("That part is fixed, but " + shell + " still reports another problem: " + after)
	}
	if ed.Quiet {
		return true
	}
	if a.inSession {
		u.Ok("Done. Open a new terminal to use it. Undo is on the home screen.")
	} else {
		u.Ok("Done. Open a new terminal to use it. To take it back: catalyst undo")
	}
	return true
}

// readStartup finds the file a startup file's name leads to, and reads it. It explains, in plain words, why it will
// not touch a folder, a link to nothing or a file it cannot write.
func (a *App) readStartup(path string, create bool) (real, text string, ok bool) {
	u := a.U
	name := a.E.Tilde(path)
	real = path
	st, err := os.Lstat(path)
	switch {
	case err != nil && !os.IsNotExist(err):
		u.Stop("Could not read " + name + ": " + plainErr(err))
		return "", "", false
	case err != nil:
		if !create {
			u.Stop(name + " is not there.")
			return "", "", false
		}
		if err := writable(filepath.Dir(path)); err != nil {
			u.Stop("Could not make " + name + ": " + plainErr(err))
			return "", "", false
		}
		return real, "", true
	case st.Mode()&os.ModeSymlink != 0:
		to, _ := os.Readlink(path)
		r, err := filepath.EvalSymlinks(path)
		if err != nil {
			u.Stop(name + " is a link to " + a.E.Tilde(to) + ", which is not there, so nothing was written.")
			u.Hint("Point the link at your real startup file, or remove the link, then try again.")
			return "", "", false
		}
		real = r
		if st, err = os.Stat(r); err != nil {
			u.Stop("Could not read " + name + ": " + plainErr(err))
			return "", "", false
		}
	}
	if st.IsDir() {
		u.Stop(name + " is a folder, not a file, so nothing was written.")
		u.Hint("Your shell cannot read a folder as its startup file. Rename it, then try again.")
		return "", "", false
	}
	if !st.Mode().IsRegular() {
		u.Stop(name + " is not a plain file, so nothing was written.")
		return "", "", false
	}
	b, err := os.ReadFile(real)
	if err != nil {
		u.Stop("Could not read " + name + ": " + plainErr(err))
		return "", "", false
	}
	if err := writable(real); err != nil {
		u.Stop(name + " cannot be changed by you, so nothing was written.")
		if sys, ok := st.Sys().(*syscall.Stat_t); ok && int(sys.Uid) != os.Getuid() {
			u.Hint("It belongs to another user, often root after a sudo edit. Make it yours again: sudo chown $USER " + name)
		} else {
			u.Hint("It is read-only. Allow writing to it: chmod u+w " + name)
		}
		return "", "", false
	}
	if strings.ContainsRune(string(b), 0) {
		u.Stop(name + " does not look like a text file, so nothing was written.")
		return "", "", false
	}
	return real, string(b), true
}

// writable opens a file or folder for writing without changing it.
func writable(p string) error {
	st, err := os.Stat(p)
	if err != nil {
		return err
	}
	if st.IsDir() {
		f, err := os.CreateTemp(p, ".catalyst-check-*")
		if err != nil {
			return err
		}
		f.Close()
		return os.Remove(f.Name())
	}
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return err
	}
	return f.Close()
}

// parseBoth has the shell read the file as it is and as it would be, each from a scratch copy, so the real file is not
// touched to find out. Each result is "" when the shell accepts that text, or its complaint. checked is false when there
// is no shell to ask.
func (a *App) parseBoth(shell, real, oldText, newText string) (before, after string, checked bool) {
	if shell == "" {
		return "", "", false
	}
	if _, ok := host.FindShell(a.E, "bash"); ok && shell == "sh" {
		shell = "bash" // bash reads .profile on most systems, and dash would call its bash-isms errors
	}
	path, ok := host.FindShell(a.E, shell)
	if !ok {
		return "", "", false
	}
	shell = path
	before, ok1 := a.parseText(shell, real, oldText)
	after, ok2 := a.parseText(shell, real, newText)
	return before, after, ok1 && ok2
}

// parseText runs shell -n over text. It reports false when the shell could not be run at all.
func (a *App) parseText(shell, real, text string) (string, bool) {
	f, err := os.CreateTemp("", "catalyst-check-*-"+strings.TrimPrefix(filepath.Base(real), "."))
	if err != nil {
		return "", false
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(text); err != nil {
		f.Close()
		return "", false
	}
	f.Close()
	r := a.E.Run.Run(0, shell, "-n", f.Name())
	if r.TimedOut || r.NotFound {
		return "", false
	}
	if r.OK() {
		return "", true
	}
	msg := firstLineOf(strings.ReplaceAll(r.Stderr+r.Stdout, f.Name(), a.E.Tilde(real)))
	if msg == "" {
		msg = "it does not parse"
	}
	return msg, true
}

func (a *App) seeSlips() string {
	if a.inSession {
		return "Doctor shows where, and can fix most of these: Doctor, then the startup file finding."
	}
	return "See where, and fix most of these: catalyst doctor --only shell.syntax --fix"
}

// showLineChange prints the lines that change, with their numbers. Lines differ only around the changed part, so the
// part shared at the start and the end is left out, and a long change is cut short.
func (a *App) showLineChange(path string, old, next []string) {
	u := a.U
	p := 0
	for p < len(old) && p < len(next) && old[p] == next[p] {
		p++
	}
	s := 0
	for s < len(old)-p && s < len(next)-p && old[len(old)-1-s] == next[len(next)-1-s] {
		s++
	}
	removed, added := old[p:len(old)-s], next[p:len(next)-s]
	where := fmt.Sprintf("In %s, line %d:", a.E.Tilde(path), p+1)
	if len(removed) == 0 && p >= len(old)-1 && old[len(old)-1] == "" {
		where = "At the end of " + a.E.Tilde(path) + ":"
	}
	u.Say("  " + u.Dim(where))
	if len(removed) == 0 && len(added) == 1 && added[0] == "" && p == len(old) {
		u.Say("     " + u.Green("+ a line break after the last line"))
		return
	}
	const most = 8
	show := func(ls []string, sign string, paint func(string) string) {
		for i, l := range ls {
			if i == most {
				u.Say("     " + u.Dim(fmt.Sprintf("  and %d more", len(ls)-most)))
				return
			}
			u.Say("     " + paint(sign+" "+visibleLine(l)))
		}
	}
	show(removed, "-", u.Red)
	show(added, "+", u.Green)
}

// visibleLine shows what a startup line holds that a terminal would hide: a Windows line ending, a byte order mark.
func visibleLine(l string) string {
	l = strings.ReplaceAll(l, "\t", "    ")
	if strings.HasPrefix(l, "\ufeff") {
		l = "[byte order mark]" + strings.TrimPrefix(l, "\ufeff")
	}
	if strings.HasSuffix(l, "\r") {
		l = strings.TrimSuffix(l, "\r") + `\r`
	}
	return l
}

func sum(text string) string {
	h := sha256.Sum256([]byte(text))
	return hex.EncodeToString(h[:])
}

func fileExists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// plainErr is an error without the Go prefix that repeats the path.
func plainErr(err error) string {
	if pe, ok := err.(*os.PathError); ok {
		return pe.Err.Error()
	}
	return err.Error()
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

// changedSince reports whether a file Catalyst edited was changed again afterwards, by its contents' fingerprint. An
// entry from before fingerprints were kept says nothing either way.
func changedSince(e journal.Entry) bool {
	if e.Sum == "" {
		return false
	}
	b, err := os.ReadFile(e.From)
	return err == nil && sum(string(b)) != e.Sum
}

// pathRCFiles are the startup files Catalyst's PATH line can be in.
func (a *App) pathRCFiles() []string {
	return []string{shellpath.RCFile(a.E.Home, "zsh", a.E.OS, os.Getenv("ZDOTDIR")), shellpath.RCFile(a.E.Home, "bash", a.E.OS, ""), shellpath.RCFile(a.E.Home, "fish", a.E.OS, ""), shellpath.RCFile(a.E.Home, "", a.E.OS, "")}
}

// removePathLines takes Catalyst's PATH line out of every startup file that has it, the careful way. A line changed
// by hand under the mark is someone's own now, so it stays, and they are told. It reports whether there was a line.
func (a *App) removePathLines() bool {
	u := a.U
	found := false
	for _, rc := range a.pathRCFiles() {
		b, err := os.ReadFile(rc)
		if err != nil || !shellpath.Has(string(b)) {
			continue
		}
		found = true
		kept := ""
		if a.editStartup(startupEdit{Path: rc, Title: "Take Catalyst's PATH line out", Mends: true, Quiet: true,
			Change: func(l []string) []string { out, k := shellpath.RemoveLines(l); kept = k; return out }}) {
			u.Ok("Took Catalyst's line out of " + a.E.Tilde(rc))
		}
		if kept != "" {
			u.Note("The line under Catalyst's note was changed by hand, so it stays: " + kept)
		}
	}
	return found
}

// lostWithoutLine is what taking Catalyst's PATH line out would cost: the commands in bin, other than Catalyst's own,
// that no other folder on the PATH has. Nothing is lost when another line in the startup files adds bin as well, such
// as the one Debian and Ubuntu put in ~/.profile.
func (a *App) lostWithoutLine(bin string) []string {
	needles := []string{bin, strings.Replace(bin, a.E.Home, "$HOME", 1), a.E.Tilde(bin)}
	ours := false
	for _, rc := range a.E.RCFiles() {
		b, err := os.ReadFile(rc)
		if err != nil {
			continue
		}
		prev := ""
		for _, l := range strings.Split(string(b), "\n") {
			t := strings.TrimRight(l, "\r")
			mine := strings.HasSuffix(strings.TrimSpace(prev), shellpath.Mark) && (t == shellpath.Line || t == shellpath.Fish)
			prev = t
			if mine {
				ours = true
				continue
			}
			if !strings.HasPrefix(strings.TrimSpace(t), "#") && namesAny(t, needles) && !onlyTests(t) {
				return nil
			}
		}
	}
	if !ours {
		return nil
	}
	ents, err := os.ReadDir(bin)
	if err != nil {
		return nil
	}
	var lost []string
	for _, en := range ents {
		n := en.Name()
		if n == "catalyst" || n == "kit" {
			continue
		}
		st, err := os.Stat(filepath.Join(bin, n))
		if err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
			continue
		}
		elsewhere := false
		for _, dir := range a.E.Entries {
			if filepath.Clean(dir) == bin {
				continue
			}
			if st, err := os.Stat(filepath.Join(dir, n)); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
				elsewhere = true
				break
			}
		}
		if !elsewhere {
			lost = append(lost, ui.Printable(n))
		}
	}
	return lost
}

// lineStuck is Catalyst's line sitting in the startup file while a new terminal, asked just now, does not get it. Only
// a PATH that came from a real terminal can show that.
func (a *App) lineStuck(st shellpath.Status) bool {
	if st.State != "ready" || st.Found != "" || a.E.Vars == nil {
		return false
	}
	for _, e := range a.E.Entries {
		if filepath.Clean(e) == st.BinDir {
			return false
		}
	}
	return true
}

// confirmOnPath asks a new terminal whether the line it just added works, rather than promising that it does.
func (a *App) confirmOnPath(st shellpath.Status) int {
	u := a.U
	name := a.E.Tilde(st.RC)
	if a.E.Shell == "" {
		u.Ok("Added one line to " + name + ". Open a new terminal to use it.")
		return ExitOK
	}
	a.E.Vars = nil
	a.E.LoadShell()
	if a.E.Vars == nil {
		u.Ok("Added one line to " + name + ". Open a new terminal to use it.")
		u.Hint("A new terminal could not be asked whether it works, so check: command -v catalyst")
		return ExitOK
	}
	for _, e := range a.E.Entries {
		if filepath.Clean(e) == st.BinDir {
			u.Ok("Added one line to " + name + ". A new terminal finds catalyst now.")
			return ExitOK
		}
	}
	u.Warn("Added one line to " + name + ", but a new terminal still does not find catalyst.")
	if why := a.whyNotOnPath(st.RC); why != "" {
		u.Hint(why)
	}
	if a.inSession {
		u.Hint("Undo on the home screen takes the line back out.")
	} else {
		u.Hint("To take the line back out: catalyst undo")
	}
	return ExitIssues
}

// whyNotOnPath looks for what keeps a line in a startup file from reaching new terminals: a login shell that never
// reads the file, or a line in it that drops or stops what comes before.
func (a *App) whyNotOnPath(rc string) string {
	name := a.E.Tilde(rc)
	if filepath.Base(rc) == ".bashrc" && a.E.Linux() {
		first := ""
		for _, f := range []string{".bash_profile", ".bash_login", ".profile"} {
			if fileExists(a.E.Path(f)) {
				first = f
				break
			}
		}
		if first == "" {
			return "Login terminals (SSH, and some terminal apps) read ~/.profile, and there is none here, so they never read " + name + ". Make one that loads it: echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> ~/.profile"
		}
		if b, err := os.ReadFile(a.E.Path(first)); err == nil && !strings.Contains(string(b), "bashrc") {
			return "Login terminals (SSH, and some terminal apps) read ~/" + first + ", which does not load " + name + ". Add this line to ~/" + first + ": [ -f ~/.bashrc ] && . ~/.bashrc"
		}
	}
	b, err := os.ReadFile(rc)
	if err != nil {
		return ""
	}
	lines := rcfile.Lines(string(b))
	mark := len(lines)
	for i, l := range lines {
		if strings.HasSuffix(strings.TrimRight(l, " \t\r"), shellpath.Mark) {
			mark = i + 1
		}
	}
	// The line the mark is glued onto, such as }# added by catalyst, is before it too.
	for _, s := range rcfile.Scan(rc, string(b)) {
		switch {
		case s.Kind == rcfile.PathReset && s.Line > mark:
			return fmt.Sprintf("Line %d of %s sets PATH again without keeping what was on it, so Catalyst's folder is dropped. End that value with :$PATH.", s.Line, name)
		case s.Stops && s.Line <= mark:
			return fmt.Sprintf("Line %d of %s stops the shell before it reaches Catalyst's line: %s. %s", s.Line, name, lowerFirst(s.Title), a.seeSlips())
		}
	}
	return ""
}

func lowerFirst(s string) string {
	if s == "" || strings.HasPrefix(s, "PATH") {
		return s
	}
	return strings.ToLower(s[:1]) + s[1:]
}
