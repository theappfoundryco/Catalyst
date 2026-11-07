package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/theappfoundryco/catalyst/internal/doctor"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/run"
	"github.com/theappfoundryco/catalyst/internal/session"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

// guide is how to sort one finding out by hand: why it matters, where it lives, and the steps, with the keys that help.
type guide struct {
	why      string
	where    []string // files or folders, shown with ~
	file     string   // the file to edit, when there is one
	line     int
	steps    []string
	copy     string // a command or line worth copying
	settings string // a System Settings page that holds the switch
	screen   []string
	label    string // what the screen key is called
	facts    []string
	// A change Catalyst can make to a startup file, shown and undoable.
	fixLabel, fixTitle, fixFile string
	fixChange                   func(lines []string) []string
	install                     []string // a command that installs what is missing, run on this terminal after a yes
}

var traceLine = regexp.MustCompile(`^\+(.+?):(\d+)> (?:export )?PATH=(.*)$`)

// pathCulprit traces a new login shell and finds the line that last put Apple's folders back in front of Homebrew's.
// Only PATH lines are read from the trace: anything else a startup file sets stays unread.
func (a *App) pathCulprit() (string, int) {
	if a.E.Shell == "" || !strings.HasSuffix(a.E.Shell, "zsh") {
		return "", 0
	}
	r := a.E.Run.Run(15*time.Second, a.E.Shell, "-l", "-i", "-x", "-c", "exit")
	brewFirst := func(path string) bool {
		parts := strings.Split(strings.Trim(path, `"'`), ":")
		b, sys := -1, -1
		for i, p := range parts {
			if p == "/opt/homebrew/bin" && b < 0 {
				b = i
			}
			if p == "/usr/bin" && sys < 0 {
				sys = i
			}
		}
		return b >= 0 && (sys < 0 || b < sys)
	}
	file, line := "", 0
	was := false
	for _, l := range strings.Split(r.Stderr, "\n") {
		m := traceLine.FindStringSubmatch(l)
		if m == nil || strings.HasPrefix(m[1], "(eval)") {
			continue
		}
		now := brewFirst(m[3])
		if was && !now {
			file = m[1]
			line, _ = strconv.Atoi(m[2])
		}
		was = now
	}
	if was { // the last word was Homebrew first after all
		return "", 0
	}
	return file, line
}

// findLine finds the first line in the startup files that contains any of the needles, outside comments.
func (a *App) findLine(needles ...string) (string, int) {
	for _, rc := range a.E.RCFiles() {
		b, err := os.ReadFile(rc)
		if err != nil {
			continue
		}
		for n, l := range strings.Split(string(b), "\n") {
			t := strings.TrimSpace(l)
			if strings.HasPrefix(t, "#") {
				continue
			}
			for _, needle := range needles {
				if strings.Contains(t, needle) {
					return rc, n + 1
				}
			}
		}
	}
	return "", 0
}

// startupFile is the file most people should add a line to.
func (a *App) startupFile() string {
	if strings.HasSuffix(a.E.Shell, "bash") {
		return a.E.Path(".bashrc")
	}
	if strings.HasSuffix(a.E.Shell, "fish") {
		return a.E.Path(".config", "fish", "config.fish")
	}
	return a.E.Path(".zshrc")
}

var lineNo = regexp.MustCompile(`:(\d+):`)

// guideFor writes the guide for one finding. It reads the machine again where that helps, such as which file sets a
// variable, so the steps name real files and lines.
func (a *App) guideFor(r doctor.Result) guide {
	g := guide{why: r.Hint}
	t := r.Title
	switch r.Check {
	case "shell.path":
		switch {
		case strings.Contains(t, "Apple's tools come before Homebrew's"):
			g.why = "When you type git or python3, the first folder on your PATH that has it wins. /usr/bin comes first, so Apple's older copies run and the ones Homebrew installed are ignored."
			g.file, g.line = a.findLine("brew shellenv", "/opt/homebrew/bin")
			if cf, cl := a.pathCulprit(); cf != "" {
				g.where = []string{fmt.Sprintf("%s, line %d", a.E.Tilde(cf), cl)}
				if filepath.Base(cf) == ".zshrc_catalyst" {
					g.why = "Your brew line is fine. A file the old Catalyst Mac app wrote, ~/.zshrc_catalyst, is loaded later and replaces your whole PATH with a fixed list: Apple's folders first, Homebrew's last. Everything your .zshrc set before it is thrown away."
					g.steps = []string{
						fmt.Sprintf("Remove the old app's PATH block in ~/.zshrc_catalyst (around line %d). Press f, and the lines are shown before anything changes.", cl),
						"Or clear out everything the old app left, with Old app cleanup (g).",
						"Open a new terminal and run: which git. It should say /opt/homebrew/bin/git.",
					}
					g.fixLabel, g.fixTitle, g.fixFile = "remove the old block", "Remove the old app's PATH block", cf
					g.fixChange = dropBlock("# CATALYST_BEGIN path-order", "# CATALYST_END path-order")
					g.screen, g.label = []string{"legacy"}, "Old app cleanup"
					g.file, g.line = cf, cl
				} else {
					g.why = "Your brew line runs, but a line after it puts Apple's folders back in front. The last line to change PATH wins."
					g.steps = []string{
						fmt.Sprintf("Open %s at line %d. That is the line that puts /usr/bin first.", a.E.Tilde(cf), cl),
						"Either remove it, or move your brew line below it.",
						"Open a new terminal and run: which git. It should say /opt/homebrew/bin/git.",
					}
					g.file, g.line = cf, cl
				}
				g.copy = "which -a git"
				break
			}
			if g.file != "" {
				g.steps = []string{
					fmt.Sprintf("Open %s at line %d. That line puts Homebrew on your PATH.", a.E.Tilde(g.file), g.line),
					"Move it to the end of the file, below every other line that changes PATH.",
					"Open a new terminal and run: which git. It should say /opt/homebrew/bin/git.",
				}
			} else {
				g.steps = []string{
					"Add this line to the end of " + a.E.Tilde(a.startupFile()) + ":",
					`  eval "$(/opt/homebrew/bin/brew shellenv)"`,
					"Then look for any later line that sets PATH with /usr/bin first, and remove it.",
				}
				g.file = a.startupFile()
			}
			g.copy = `eval "$(/opt/homebrew/bin/brew shellenv)"`
		case strings.Contains(t, "does not exist"), strings.Contains(t, "twice"):
			for _, p := range a.E.Entries {
				if !isDir(p) {
					src, n := a.pathSource(p)
					where := a.E.Tilde(p)
					if src != "" {
						where += "  (added by " + a.E.Tilde(src) + ", line " + strconv.Itoa(n) + ")"
						if !strings.HasPrefix(src, "/etc/") && g.file == "" {
							g.file, g.line = src, n
						}
					} else {
						where += "  (added by macOS or the shell)"
					}
					g.where = append(g.where, where)
				}
			}
			g.why = "A folder on your PATH that does not exist is searched for nothing every time you run a command. It is harmless, only slower, and often left behind by something you uninstalled."
			if g.file != "" {
				g.steps = []string{fmt.Sprintf("Open %s at line %d, and delete the line or the part of it that adds the folder.", a.E.Tilde(g.file), g.line), "Open a new terminal to check."}
			} else {
				g.steps = []string{"None of your startup files adds it: macOS or an installer did. It is harmless, so the safe choice is to leave it."}
			}
			g.screen, g.label = []string{"path"}, "PATH screen"
		case strings.Contains(t, "relative folder"):
			g.why = "A relative folder such as . means \"wherever you are\". A program in a downloaded folder could then run in place of the real one with the same name."
			g.file, g.line = a.findLine("PATH=.", "PATH=\".", ":.:", ":.\"")
			g.steps = []string{"Remove the . (or the relative folder) from the line that sets PATH.", "Run a program in this folder with ./name instead."}
		}
	case "tools.java":
		g.file, g.line = a.findLine("JAVA_HOME")
		jdks := a.jdks()
		for _, j := range jdks {
			g.facts = append(g.facts, "Installed JDK: "+j)
		}
		if strings.Contains(t, "gone") {
			g.why = "JAVA_HOME names the JDK that Gradle, Maven and Android tools use. It points at a folder that was removed, usually after a JDK was uninstalled or upgraded."
		} else {
			g.why = "Some build tools only find Java through JAVA_HOME."
		}
		line := ""
		if g.file != "" && g.line > 0 {
			if b, err := os.ReadFile(g.file); err == nil {
				if ls := strings.Split(string(b), "\n"); g.line <= len(ls) {
					line = ls[g.line-1]
				}
			}
		}
		switch {
		case len(jdks) > 0 && a.E.Mac():
			g.copy = "export JAVA_HOME=$(/usr/libexec/java_home)"
			g.steps = []string{"Replace the JAVA_HOME line with the one below. It always finds the newest JDK you have, so it never goes stale again. Press f to have it done:", "  " + g.copy}
			if line != "" && strings.Contains(t, "gone") {
				g.fixLabel, g.fixTitle, g.fixFile = "point it at your JDK", "Point JAVA_HOME at the JDK you have", g.file
				g.fixChange = replaceLine(g.line, line, g.copy)
			}
		case len(jdks) > 0:
			g.steps = []string{"Point JAVA_HOME at one of the JDKs listed above."}
		default:
			g.facts = append(g.facts, "No JDK is installed now.")
			g.steps = []string{"If you do not use Java now, turn the line off. Press f: it becomes a comment, so it is easy to bring back.", "If you do, install a JDK (press i), then come back here and press f to point JAVA_HOME at it:", "  brew install --cask temurin"}
			g.copy = "brew install --cask temurin"
			if line != "" {
				g.fixLabel, g.fixTitle, g.fixFile = "turn the line off", "Turn off the JAVA_HOME line", g.file
				g.fixChange = replaceLine(g.line, line, "# "+strings.TrimSpace(line)+"  # turned off by Catalyst: this JDK is gone")
			}
			if a.E.Mac() && a.brew() != "" {
				g.install = []string{a.brew(), "install", "--cask", "temurin"}
			}
		}
		if g.file != "" {
			g.steps = append([]string{fmt.Sprintf("Open %s at line %d.", a.E.Tilde(g.file), g.line)}, g.steps...)
		} else {
			g.file = a.startupFile()
		}
		g.steps = append(g.steps, "Open a new terminal to use it.")
	case "keys.firewall":
		g.why = "The firewall stops apps on this machine from accepting connections you did not expect. On a trusted home network it matters little. On café or office Wi-Fi it is worth having."
		if a.E.Mac() {
			g.settings = settingsFirewall
			g.steps = []string{"Open System Settings, Network, Firewall.", "Turn it on. Apps you use ask once whether they may accept connections."}
		} else {
			g.copy = "sudo ufw enable"
			g.steps = []string{"Turn it on with: " + g.copy, "Allow what you need, such as SSH: sudo ufw allow ssh"}
		}
	case "machine.memory":
		g.why = "When memory runs out, the system moves what is open onto the disk (swap). It works, but everything is slower, and the swap files take disk space until you quit apps or restart."
		g.where = []string{"/private/var/vm (macOS keeps swap here)"}
		g.facts = a.topMemory(5)
		g.steps = []string{"Quit the apps you are not using, starting with the biggest above.", "Close browser tabs you do not need. Each one can use hundreds of MB.", "Restart when convenient. That clears swap completely."}
		if a.E.Mac() {
			g.copy = "open -a \"Activity Monitor\""
		}
	case "tools.brew":
		g.file = a.E.Path(".zprofile")
		g.copy = `eval "$(/opt/homebrew/bin/brew shellenv)"`
		g.why = "Homebrew is installed, but your shell does not know where, so brew and everything it installed is not found."
		g.steps = []string{"Add this line to " + a.E.Tilde(g.file) + ":", "  " + g.copy, "Open a new terminal."}
	case "tools.build":
		if a.E.Mac() {
			g.copy = "xcode-select --install"
			g.why = "git, make, and anything that compiles code come from Apple's Command Line Tools."
			g.steps = []string{"Run this, then click Install in the window that opens:", "  " + g.copy, "It takes a few minutes and needs no Apple account."}
		} else {
			g.copy = "sudo apt-get install build-essential"
			g.steps = []string{"Install a compiler and make. On Debian or Ubuntu:", "  " + g.copy}
		}
	case "tools.git":
		g.why = "Every commit records who made it. Without a name and email, git refuses to commit, or labels it with a guess."
		g.copy = `git config --global user.name "Your Name" && git config --global user.email "you@example.com"`
		g.steps = []string{"Run this with your own name and email:", "  " + g.copy, "Use the email your GitHub account knows, so commits link to you."}
		g.where = []string{"~/.gitconfig"}
	case "shell.startup":
		g.why = "Every new terminal tab waits for your startup files to finish. A slow plugin, nvm, or a command that reaches the network is the usual cause."
		g.copy = "zsh -i -x -c exit 2>&1 | tail -40"
		if strings.HasSuffix(a.E.Shell, "bash") {
			g.copy = "bash -i -x -c exit 2>&1 | tail -40"
		}
		g.file = a.startupFile()
		g.steps = []string{"See which lines run, in order, with this:", "  " + g.copy, "Load slow tools on first use instead of at start. nvm has a lazy-load option, and many plugin managers do too."}
	case "shell.syntax":
		f := strings.Fields(t)
		if len(f) > 0 {
			g.file = strings.Replace(f[0], "~", a.E.Home, 1)
		}
		if m := lineNo.FindStringSubmatch(r.Hint); m != nil {
			g.line, _ = strconv.Atoi(m[1])
		}
		g.why = "A shell stops reading a startup file at its first error, so everything after that line never runs."
		g.steps = []string{"Open the file at the line in the error above, and fix or remove that line.", "Open a new terminal to check."}
	case "keys.ssh":
		g.why = "SSH refuses a private key that other users can read, and so should you: anyone on the machine could copy it."
		g.where = []string{"~/.ssh"}
		g.screen, g.label = []string{"ssh"}, "SSH keys"
		if strings.Contains(t, "weak") {
			g.copy = "ssh-keygen -t ed25519"
			g.steps = []string{"Make a new key:", "  " + g.copy, "Add its public half wherever the old one is used, then remove the old one."}
		}
	case "keys.history":
		g.why = "Your shell keeps every command you typed. A key pasted into one is readable by anything that reads that file, and it ends up in backups."
		g.where = []string{a.E.Tilde(a.historyFile())}
		g.file = a.historyFile()
		g.steps = []string{"First rotate each key with the service that issued it. Assume a key in the history is known.", "Then delete those lines from the history file. Catalyst never shows the values here.", "Next time, pass keys through a file or a secrets manager instead of the command line."}
	case "machine.disk":
		g.why = "Builds, updates and Docker need free space, and macOS slows down when the disk is nearly full."
		g.screen, g.label = []string{"space"}, "Space"
		g.steps = []string{"See where the space goes, and what can go, on the Space screen.", "Sweep removes build folders from old projects. Clean removes app caches."}
	case "machine.caches":
		g.screen, g.label = []string{"sweep"}, "Sweep"
		g.steps = []string{"Sweep removes them safely, through the Trash, with undo."}
	case "machine.startup":
		g.screen, g.label = []string{"startup"}, "Startup"
		g.steps = []string{"Turn it off on the Startup screen, or remove the app it belonged to."}
	case "machine.docker":
		g.why = "Stopped containers and unused images keep their disk space until they are pruned."
	case "machine.linux":
		g.copy = "sudo journalctl --vacuum-size=500M"
	}
	if r.Fix != nil && g.copy == "" {
		g.copy = r.Fix.Preview()
	}
	if len(g.steps) == 0 && r.Hint != "" {
		g.steps = []string{r.Hint}
	}
	if g.file != "" && len(g.where) == 0 {
		w := a.E.Tilde(g.file)
		if g.line > 0 {
			w += ", line " + strconv.Itoa(g.line)
		}
		g.where = []string{w}
	}
	return g
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func (a *App) historyFile() string {
	if strings.HasSuffix(a.E.Shell, "bash") {
		return a.E.Path(".bash_history")
	}
	return a.E.Path(".zsh_history")
}

// jdks lists the installed JDKs.
func (a *App) jdks() []string {
	var out []string
	if a.E.Mac() {
		r := a.E.Run.Run(0, "/usr/libexec/java_home", "-V")
		for _, l := range strings.Split(r.Stderr+"\n"+r.Stdout, "\n") {
			if i := strings.Index(l, "/Library/Java/"); i >= 0 {
				out = append(out, strings.TrimSpace(l[i:]))
			}
		}
		return out
	}
	found, _ := filepath.Glob("/usr/lib/jvm/*")
	return found
}

// topMemory names the programs using the most memory right now.
func (a *App) topMemory(n int) []string {
	s, ok := a.E.Out("ps", "-Aceo", "rss=,comm=")
	if !ok {
		return nil
	}
	type proc struct {
		name string
		kb   int64
	}
	sum := map[string]int64{}
	for _, l := range strings.Split(s, "\n") {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		kb, _ := strconv.ParseInt(f[0], 10, 64)
		name := strings.Join(f[1:], " ")
		name = strings.TrimSuffix(name, " Helper")
		name = strings.TrimSuffix(name, " Helper (Renderer)")
		sum[name] += kb
	}
	var ps []proc
	for k, v := range sum {
		ps = append(ps, proc{k, v})
	}
	sort.Slice(ps, func(i, j int) bool { return ps[i].kb > ps[j].kb })
	var out []string
	for i, p := range ps {
		if i == n {
			break
		}
		out = append(out, fmt.Sprintf("%-8s %s", ui.RAM(p.kb*1024), p.name))
	}
	return out
}

// showGuide is one finding on its own screen.
func (a *App) showGuide(r doctor.Result) {
	u := a.U
	a.outcome.Refresh = true
	g := a.guideFor(r)
	u.Hdr("How to sort it out")
	switch r.Severity {
	case doctor.Critical:
		u.Stop(u.Bold(r.Title))
	case doctor.Warning:
		u.Warn(u.Bold(r.Title))
	default:
		u.Note(u.Bold(r.Title))
	}
	sect := func(s string) { u.Blank(); u.Say("  " + u.Faint(s)) }
	if g.why != "" {
		sect("WHY IT MATTERS")
		u.Say("     " + g.why)
	}
	if len(g.facts) > 0 {
		sect("RIGHT NOW")
		for _, f := range g.facts {
			u.Say("     " + f)
		}
	}
	if len(g.where) > 0 {
		sect("WHERE")
		for _, w := range g.where {
			u.Say("     " + u.Accent(w))
		}
	}
	if len(g.steps) > 0 {
		sect("STEPS")
		n := 0
		for _, st := range g.steps {
			if strings.HasPrefix(st, "  ") {
				u.Say("        " + u.Bold(strings.TrimSpace(st)))
				continue
			}
			n++
			for i, l := range u.Wrap(st, u.Width()-8) {
				if i == 0 {
					u.Say(fmt.Sprintf("  %3d. %s", n, l))
				} else {
					u.Say("       " + l)
				}
			}
		}
	}
	if r.Fix != nil && r.Fix.Kind != doctor.FixManual {
		u.Blank()
		u.Say("  " + u.Soft("Catalyst can do this for you, showing the change first: ") + r.Fix.Preview())
	}
	u.Blank()
	acts := &a.outcome.Actions
	if r.Fix != nil && r.Fix.Kind != doctor.FixManual {
		*acts = append(*acts, goTo("f", "fix it", "Doctor", "doctor", "--fix", "--only", r.Check))
	}
	if g.fixChange != nil && g.fixFile != "" {
		file, title, change := g.fixFile, g.fixTitle, g.fixChange
		*acts = append(*acts, a.page("f", g.fixLabel, "Doctor", func() { a.editFile(file, title, change) }))
	}
	if len(g.install) > 0 {
		cmd := g.install
		*acts = append(*acts, a.page("i", "install a JDK", "Doctor", func() { a.runInstall("Install a JDK", cmd) }))
	}
	if g.file != "" {
		*acts = append(*acts, a.editKey(g.file, g.line))
	}
	if g.settings != "" && a.E.Mac() {
		*acts = append(*acts, a.urlKey("s", "open Settings", g.settings))
	}
	if g.copy != "" {
		*acts = append(*acts, a.copyKey("y", "copy command", g.copy, "the command"))
	}
	if r.Check == "machine.memory" && a.E.Mac() {
		*acts = append(*acts, session.Action{Key: "a", Label: "Activity Monitor", Do: func() string {
			if a.E.Run.Run(0, "open", "-a", "Activity Monitor").OK() {
				return "Opened Activity Monitor. Sort by Memory to see what is using it."
			}
			return "Could not open Activity Monitor."
		}})
	}
	if len(g.screen) > 0 {
		*acts = append(*acts, goTo("g", g.label, g.label, g.screen...))
	}
}

// dropBlock removes the lines from begin to end, both included.
func dropBlock(begin, end string) func([]string) []string {
	return func(lines []string) []string {
		var out []string
		in := false
		for _, l := range lines {
			t := strings.TrimSpace(l)
			if t == begin {
				in = true
				continue
			}
			if in && t == end {
				in = false
				continue
			}
			if !in {
				out = append(out, l)
			}
		}
		return out
	}
}

// replaceLine swaps one line, but only if it still reads as it did, so a file edited since is never changed blindly.
func replaceLine(n int, was, with string) func([]string) []string {
	return func(lines []string) []string {
		if n >= 1 && n <= len(lines) && lines[n-1] == was {
			lines[n-1] = with
		}
		return lines
	}
}

// runInstall shows a command, asks, and runs it on this terminal so it can ask its own questions.
func (a *App) runInstall(title string, cmd []string) {
	u := a.U
	u.Say("  " + u.Bold(title))
	u.Say("     " + u.Accent(strings.Join(cmd, " ")))
	u.Hint("It downloads from the internet, and may ask for your password itself.")
	if !u.Ask("Run it?") {
		u.Say("  " + u.Dim("Nothing was installed."))
		return
	}
	if _, code := run.Attached(false, cmd[0], cmd[1:]...); code != 0 {
		u.Warn("It did not finish. What it said is above.")
		return
	}
	a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: journal.NewBatch(a.E.Now()), Kind: journal.KindRun, Title: title, Command: cmd})
	a.outcome.Changed = true
	u.Ok("Installed. Press Esc, and the guide checks again.")
}
