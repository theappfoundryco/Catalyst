package cli

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/run"
)

// A helper is a well-known tool that lets Catalyst read more of the machine. None is required, nothing is installed
// without a yes, and uninstalling Catalyst leaves every one of them alone.
type helper struct {
	name, label, unlocks string
	have                 func(a *App) bool
	install              func(a *App) []string // the command, shown before it runs
	root                 bool
	needsBrew            bool
}

// brewInstall is Homebrew's own one-line installer, exactly as brew.sh gives it. It is the one downloaded script
// Catalyst will run, and only after showing it and hearing a yes. The installer asks for the password itself.
const brewInstall = `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`

func (a *App) helpers() []helper {
	var out []helper
	if a.E.Mac() {
		out = append(out, helper{
			name: "brew", label: "Homebrew", unlocks: "Installs the other helpers, and most developer tools.",
			have: func(a *App) bool { return a.brew() != "" },
			install: func(a *App) []string {
				return []string{"/bin/bash", "-c", strings.TrimSuffix(strings.TrimPrefix(brewInstall, `/bin/bash -c "`), `"`)}
			},
		})
	}
	out = append(out, helper{
		name: "smartmontools", label: "smartmontools", unlocks: "Lets Disk show wear, total read and written, temperature and power-on hours.",
		have: func(a *App) bool { _, err := a.E.Look("smartctl"); return err == nil },
		install: func(a *App) []string {
			switch {
			case a.E.Mac():
				return []string{a.brew(), "install", "smartmontools"}
			case a.has("apt-get"):
				return []string{"apt-get", "install", "-y", "smartmontools"}
			case a.has("dnf"):
				return []string{"dnf", "install", "-y", "smartmontools"}
			case a.has("pacman"):
				return []string{"pacman", "-S", "--noconfirm", "smartmontools"}
			}
			return nil
		},
		root: !a.E.Mac(), needsBrew: a.E.Mac(),
	})
	return out
}

func (a *App) has(tool string) bool { _, err := a.E.Look(tool); return err == nil }

// brew finds Homebrew where it installs, even when this shell has not loaded it.
func (a *App) brew() string {
	if p, err := a.E.Look("brew"); err == nil {
		return p
	}
	for _, p := range []string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew", "/home/linuxbrew/.linuxbrew/bin/brew"} {
		if isFile(p) {
			return p
		}
	}
	return ""
}

func isFile(p string) bool { st, err := os.Stat(p); return err == nil && !st.IsDir() }

func cmdHelpers(a *App, args []string) int {
	fs := a.flags("helpers", "[install NAME]")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	if fs.NArg() == 2 && fs.Arg(0) == "install" {
		for _, h := range a.helpers() {
			if h.name == fs.Arg(1) {
				return a.installHelper(h)
			}
		}
		a.U.Stop("There is no helper called " + fs.Arg(1) + ".")
		return ExitUsage
	}
	if fs.NArg() != 0 {
		fs.Usage()
		return ExitUsage
	}
	u := a.U
	a.outcome.Refresh = true
	u.Hdr("Helpers")
	u.Say("  " + u.Dim("Well-known tools that let Catalyst see more. None is needed, nothing installs without a yes, and uninstalling Catalyst leaves them all alone."))
	u.Blank()
	cfg := a.Store.LoadConfig()
	for _, h := range a.helpers() {
		h := h
		if h.have(a) {
			u.Ok(a.row() + u.Bold(h.label) + u.Dim("  installed"))
		} else {
			note := u.Dim("  not installed")
			if cfg.Declined(h.name) {
				note = u.Dim("  not installed, you said no earlier")
			}
			u.Note(a.row(goTo("i", "install", "Helpers", "helpers", "install", h.name)) + u.Bold(h.label) + note)
		}
		u.Hint(h.unlocks)
	}
	u.Blank()
	return ExitOK
}

// installHelper shows the exact command, asks, and runs it on this terminal so it can ask its own questions.
func (a *App) installHelper(h helper) int {
	u := a.U
	if h.have(a) {
		u.Ok(h.label + " is already installed.")
		return ExitOK
	}
	if h.needsBrew && a.brew() == "" {
		u.Note(h.label + " installs with Homebrew, which is not here yet.")
		u.Hint("Install Homebrew first, from Helpers.")
		if a.inSession {
			a.outcome.Actions = append(a.outcome.Actions, goTo("b", "install Homebrew", "Helpers", "helpers", "install", "brew"))
		}
		return ExitIssues
	}
	cmd := h.install(a)
	if cmd == nil {
		u.Stop("No package manager here that Catalyst knows how to use. Install " + h.label + " the way your system does.")
		return ExitIssues
	}
	shown := strings.Join(cmd, " ")
	if h.name == "brew" {
		shown = brewInstall
	}
	if h.root {
		shown = "sudo " + shown
	}
	u.Say("  " + u.Bold("Install "+h.label) + u.Dim(". "+h.unlocks))
	u.Blank()
	u.Say("  " + u.Dim("This runs:"))
	u.Say("     " + u.Accent(shown))
	if h.name == "brew" {
		u.Hint("This is Homebrew's own installer, from brew.sh. It explains each step and asks for your password itself.")
	}
	u.Blank()
	if !u.Ask("Install it?") {
		a.decline(h.name)
		u.Say("  " + u.Dim("Not installed. It is under More, Helpers, whenever you want it."))
		return ExitOK
	}
	ok := false
	if h.root {
		ok = a.sudoReady() && a.asRoot(cmd...)
	} else {
		_, code := run.Attached(false, cmd[0], cmd[1:]...)
		ok = code == 0
	}
	u.Blank()
	if !ok || !a.helperArrived(h) {
		u.Warn(h.label + " did not finish installing. What the installer said is above.")
		return ExitIssues
	}
	a.outcome.Changed = true
	u.Ok(h.label + " is installed.")
	if h.name == "brew" {
		u.Hint("Homebrew asks you to add one line to your startup file. Doctor checks that it is there.")
	}
	return ExitOK
}

// helperArrived checks the install, a moment later, the way a new terminal would find it.
func (a *App) helperArrived(h helper) bool {
	for i := 0; i < 3; i++ {
		if h.have(a) {
			return true
		}
		if h.name == "smartmontools" && a.brew() != "" && isFile(strings.TrimSuffix(a.brew(), "brew")+"smartctl") {
			return true
		}
		time.Sleep(300 * time.Millisecond)
	}
	return false
}

func (a *App) decline(tool string) {
	c := a.Store.LoadConfig()
	if !c.Declined(tool) {
		c.NoHelpers = append(c.NoHelpers, tool)
		a.Store.SaveConfig(c)
	}
}

// helperHint is the line a screen shows when a helper would let it show more.
func (a *App) helperHint(tool, what string) {
	u := a.U
	u.Hint(what)
	if a.inSession {
		a.outcome.Actions = append(a.outcome.Actions, goTo("h", "helpers", "Helpers", "helpers"))
	}
}

// cmdSetup is the first-run welcome: what to call the person, and the helpers worth having.
func cmdSetup(a *App, _ []string) int {
	u := a.U
	c := a.Store.LoadConfig()
	u.Say("  " + u.Bold("Hi, I'm Catalyst.") + u.Dim(" I check your dev setup and free space safely. Nothing changes without asking."))
	u.Blank()
	name := strings.TrimSpace(u.Text("What should I call you? " + u.Dim("(Enter to skip) ")))
	if len(name) > 24 {
		name = name[:24]
	}
	c.Name = &name
	u.Blank()
	if name != "" {
		u.Say("  " + u.Bold("Nice to meet you, "+name+"."))
	} else {
		u.Say("  " + u.Dim("No problem. You can add a name in Settings any time."))
	}
	u.Blank()
	u.Say("  " + u.Faint("CHECKING A FEW THINGS"))
	if a.E.Mac() {
		if a.E.HasCLT() {
			u.Ok("Apple's Command Line Tools are installed")
		} else {
			u.Warn("Apple's Command Line Tools are missing. git, make and compilers come from them.")
			if u.Ask("Open Apple's installer for them now?") {
				run.Attached(false, "xcode-select", "--install")
				u.Hint("Click Install in the window that opened. It takes a few minutes.")
			}
		}
	}
	a.Store.SaveConfig(c)
	for _, h := range a.helpers() {
		if h.have(a) {
			u.Ok(h.label + " is installed")
			continue
		}
		if h.needsBrew && a.brew() == "" {
			u.Note(h.label + " needs Homebrew first")
			continue
		}
		if h.install(a) == nil {
			u.Note(h.label + " is not installed")
			continue
		}
		u.Blank()
		a.installHelper(h) // shows the command and asks once; a no is remembered
		u.Blank()
	}
	self, _ := os.Executable()
	self, _ = filepath.EvalSymlinks(self)
	switch a.linkKit(self) {
	case kitAdded, kitThere:
		u.Ok("You can type kit as well as catalyst")
	case kitTaken:
		u.Note("Something else on this machine is already called kit, so only catalyst opens Catalyst")
	}
	c = a.Store.LoadConfig()
	c.SetupDone = true
	a.Store.SaveConfig(c)
	u.Blank()
	u.Say("  " + u.Dim("You're set. Helpers are under More whenever you want them. Doctor is a good first stop."))
	u.Blank()
	return ExitOK
}

// greeting is hello for the time of day, with the person's name when they gave one.
func greeting(name string, now time.Time) string {
	h := now.Hour()
	g := "Good evening"
	switch {
	case h < 5:
		g = "Up late"
	case h < 12:
		g = "Good morning"
	case h < 17:
		g = "Good afternoon"
	}
	if name == "" {
		return g
	}
	if h < 5 {
		return g + ", " + name + "?"
	}
	return g + ", " + name
}
