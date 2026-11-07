package cli

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/session"
)

// Settings pages that can be opened directly. They work on macOS 13 and later, and an older Mac just opens Settings.
const (
	settingsLoginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
	settingsFirewall   = "x-apple.systempreferences:com.apple.preference.security?Firewall"
	settingsDiskAccess = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
	settingsBattery    = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
	settingsWallpaper  = "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
	settingsUpdate     = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
	settingsStorage    = "x-apple.systempreferences:com.apple.settings.Storage"
	settingsNetwork    = "x-apple.systempreferences:com.apple.Network-Settings.extension"
)

// row makes the line printed next a row in the session, with keys that act on it. It returns the mark to print at the
// start of that line, which is empty outside a session.
func (a *App) row(keys ...session.Action) string {
	if !a.inSession {
		return ""
	}
	a.rowID++
	a.outcome.Rows = append(a.outcome.Rows, session.Row{ID: a.rowID, Keys: keys})
	return a.U.Mark(a.rowID)
}

// page is a key that opens a screen drawn by show, such as the details of one finding, without running a whole command
// again. The session keeps the screen it came from, so Esc goes straight back to it.
func (a *App) page(key, label, title string, show func()) session.Action {
	if a.pages == nil {
		a.pages = map[string]func(){}
	}
	a.pageID++
	id := strconv.Itoa(a.pageID)
	a.pages[id] = show
	return session.Action{Key: key, Label: label, Title: title, Args: []string{"__page", id}}
}

// goTo is a key that runs a command and opens the screen it draws.
func goTo(key, label, title string, args ...string) session.Action {
	return session.Action{Key: key, Label: label, Title: title, Args: args}
}

// revealKey shows a file or folder in Finder, or opens its folder on Linux.
func (a *App) revealKey(path string) session.Action {
	label := "show in Finder"
	if !a.E.Mac() {
		label = "open folder"
	}
	return session.Action{Key: "o", Label: label, Do: func() string { return a.reveal(path) }}
}

func (a *App) reveal(path string) string {
	if _, err := os.Lstat(path); err != nil {
		return a.E.Tilde(path) + " is not there any more."
	}
	var r run.Result
	if a.E.Mac() {
		r = a.E.Run.Run(0, "open", "-R", path)
	} else {
		dir := path
		if st, err := os.Stat(path); err == nil && !st.IsDir() {
			dir = filepath.Dir(path)
		}
		r = a.E.Run.Run(0, "xdg-open", dir)
	}
	if !r.OK() {
		return "Could not open it. It is at " + a.E.Tilde(path)
	}
	if a.E.Mac() {
		return "Shown in Finder: " + a.E.Tilde(path)
	}
	return "Opened " + a.E.Tilde(filepath.Dir(path))
}

// copyKey puts text on the clipboard. said is what to call it in the line that confirms it.
func (a *App) copyKey(key, label, text, said string) session.Action {
	return session.Action{Key: key, Label: label, Do: func() string { return a.copyText(text, said) }}
}

func (a *App) copyText(text, said string) string {
	var tools [][]string
	if a.E.Mac() {
		tools = [][]string{{"pbcopy"}}
	} else {
		tools = [][]string{{"wl-copy"}, {"xclip", "-selection", "clipboard"}, {"xsel", "--clipboard", "--input"}}
	}
	for _, t := range tools {
		if _, err := a.E.Look(t[0]); err != nil {
			continue
		}
		if run.Input(0, text, t[0], t[1:]...).OK() {
			return "Copied " + said + "."
		}
	}
	return "No clipboard here. Install wl-clipboard or xclip to copy."
}

// urlKey opens a web page or a System Settings page.
func (a *App) urlKey(key, label, url string) session.Action {
	return session.Action{Key: key, Label: label, Do: func() string { return a.openURL(url, label) }}
}

func (a *App) openURL(url, what string) string {
	tool := "open"
	if !a.E.Mac() {
		tool = "xdg-open"
	}
	if !a.E.Run.Run(0, tool, url).OK() {
		return "Could not open it: " + url
	}
	return "Opened. " + strings.ToUpper(what[:1]) + what[1:] + " is in the other window."
}

// editKey opens a file in an editor, at a line when VS Code is there to take it.
func (a *App) editKey(path string, line int) session.Action {
	return session.Action{Key: "e", Label: "edit " + filepath.Base(path), Do: func() string { return a.edit(path, line) }}
}

func (a *App) edit(path string, line int) string {
	if _, err := a.E.Look("code"); err == nil {
		target := path
		if line > 0 {
			target += ":" + strconv.Itoa(line)
		}
		if a.E.Run.Run(0, "code", "-g", target).OK() {
			return "Opened " + a.E.Tilde(path) + " in VS Code."
		}
	}
	var r run.Result
	if a.E.Mac() {
		r = a.E.Run.Run(0, "open", "-t", path)
	} else {
		r = a.E.Run.Run(0, "xdg-open", path)
	}
	if !r.OK() {
		return "Could not open an editor. The file is " + a.E.Tilde(path)
	}
	if line > 0 {
		return "Opened " + a.E.Tilde(path) + ". Look at line " + strconv.Itoa(line) + "."
	}
	return "Opened " + a.E.Tilde(path) + "."
}

// sudoReady explains what comes next and lets sudo ask for the password itself, on this terminal. Catalyst never sees
// the password and keeps nothing: the system remembers it for a few minutes, and after that, or if the password has
// changed since, sudo simply asks again.
func (a *App) sudoReady() bool {
	u := a.U
	u.Blank()
	who := "macOS"
	if !a.E.Mac() {
		who = "sudo"
	}
	u.Note(who + " will ask for your password next. Catalyst never sees it and never keeps it.")
	u.Hint("It is remembered for about 5 minutes. After that, or if your password has changed, you are simply asked again.")
	if _, code := run.Attached(false, "sudo", "-v", "-p", "  Password for %u: "); code != 0 {
		u.Stop("No admin rights, so nothing was changed.")
		return false
	}
	return true
}

// asRoot runs one command as root, after sudoReady. The person sees its output, as they would in their own terminal.
func (a *App) asRoot(cmd ...string) bool {
	_, code := run.Attached(false, "sudo", append([]string{"-p", "  Password for %u: "}, cmd...)...)
	return code == 0
}
