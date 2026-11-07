package cli

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/theappfoundryco/catalyst/internal/host"
	"github.com/theappfoundryco/catalyst/internal/journal"
	"github.com/theappfoundryco/catalyst/internal/shellpath"
	"github.com/theappfoundryco/catalyst/internal/sweep"
	"github.com/theappfoundryco/catalyst/internal/ui"
)

func cmdDisk(a *App, args []string) int {
	fs := a.flags("disk", "[--folders] [--json]")
	folders := fs.Bool("folders", false, "")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	vols := a.E.Volumes()
	health := a.E.DriveHealth()
	if *asJSON {
		return emit(a, map[string]any{"volumes": vols, "drive": health})
	}
	u.Hdr("Disks")
	for _, v := range vols {
		label := v.Name
		u.Row(label, u.Bar(v.UsedPercent, 18, 75, 90)+"  "+u.Dim(ui.Size(v.Free)+" free of "+ui.Size(v.Size)))
	}
	u.Hdr("Drive health")
	if health.Model != "" {
		u.Row("Drive", u.Bold(health.Model))
	}
	if health.Status != "" {
		style := u.Green
		if !health.OK {
			style = u.Red
		}
		u.Row("Self-test", style(health.Status))
	}
	if health.WearPercent >= 0 && health.HasSmart {
		u.Row("Wear", fmt.Sprintf("%d%% used, %s", health.WearPercent, u.Level(health.WearPercent, 80, 90)(fmt.Sprintf("%d%% life left", 100-health.WearPercent))))
	}
	if health.TemperatureC > 0 {
		u.Row("Temperature", u.Level(health.TemperatureC, 55, 70)(fmt.Sprintf("%d°C", health.TemperatureC)))
	}
	if health.PowerOnHours > 0 {
		u.Row("Power on", fmt.Sprintf("%d hours %s", health.PowerOnHours, u.Dim(fmt.Sprintf("(%d days)", health.PowerOnHours/24))))
	}
	if health.BytesWritten > 0 {
		u.Row("Written", ui.Size(health.BytesWritten))
	}
	if health.HasSmart {
		style := u.Green
		if health.MediaErrors > 0 {
			style = u.Red
		}
		u.Row("Media errors", style(strconv.FormatInt(health.MediaErrors, 10)))
	}
	if health.Note != "" {
		u.Hint(health.Note)
	}
	if *folders {
		u.Hdr("Biggest folders in your home")
		type row struct {
			name string
			size int64
		}
		var rows []row
		entries, _ := os.ReadDir(a.E.Home)
		sp := u.Spin("Measuring")
		for _, ent := range entries {
			if !ent.IsDir() {
				continue
			}
			sp.Detail(ent.Name())
			rows = append(rows, row{ent.Name(), sweep.DirSize(a.E.Path(ent.Name()), sweep.NewSeen())})
		}
		sp.Stop()
		sort.Slice(rows, func(i, j int) bool { return rows[i].size > rows[j].size })
		for i, r := range rows {
			if i == 8 {
				break
			}
			u.Say(fmt.Sprintf("  %s  %s", u.Cyan(fmt.Sprintf("%9s", ui.Size(r.size))), r.name))
		}
	}
	u.Blank()
	return ExitOK
}

func cmdBattery(a *App, args []string) int {
	fs := a.flags("battery", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	var b host.Battery
	if *asJSON {
		b = a.E.Battery()
		return emit(a, b)
	}
	u.Blank()
	sp := u.Spin("Reading the battery")
	b = a.E.Battery()
	sp.Stop()
	if !b.Present {
		u.Say("  " + u.Dim("This machine has no battery."))
		u.Blank()
		return ExitOK
	}
	u.Hdr("Battery")
	u.Row("Charge", u.HealthBar(b.Percent, 18)+"%")
	state := b.Source
	if b.Charging {
		state = "Charging"
	}
	if b.TimeLeft != "" {
		state += u.Dim(", " + b.TimeLeft + " left")
	}
	u.Row("Now", state)
	if b.Health > 0 {
		u.Row("Capacity", u.ScoreStyle(b.Health)(fmt.Sprintf("%d%%", b.Health))+u.Dim(" of when it was new"))
	}
	if b.Condition != "" {
		u.Row("Condition", b.Condition)
	}
	if b.Cycles > 0 {
		u.Row("Cycles", strconv.Itoa(b.Cycles))
	}
	if b.TemperatureC > 0 {
		u.Row("Temperature", fmt.Sprintf("%.0f°C", b.TemperatureC))
	}
	u.Blank()
	return ExitOK
}

func cmdNet(a *App, args []string) int {
	fs := a.flags("net", "[host]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	target := "github.com"
	if fs.NArg() > 0 {
		target = fs.Arg(0)
	}
	u.Hdr("Network")
	if ip := localIP(); ip != "" {
		u.Row("This machine", ip)
	}
	gw := a.E.Gateway()
	if gw != "" {
		u.Row("Router", gw)
	} else {
		u.Warn("No route to the internet. Check your Wi-Fi or cable.")
	}
	ok := true
	resolver := &net.Resolver{}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	t0 := time.Now()
	addrs, err := resolver.LookupHost(ctx, target)
	if err != nil {
		u.Row("DNS", u.Red("✗ could not look up "+target))
		u.Hint("If the next line works, your DNS is the problem, not your connection.")
		ok = false
	} else {
		u.Row("DNS", u.Green(fmt.Sprintf("✓ %s in %d ms", target, time.Since(t0).Milliseconds()))+u.Dim(fmt.Sprintf("  (%s)", addrs[0])))
	}
	best, reached := time.Duration(0), false
	for i := 0; i < 3; i++ {
		t := time.Now()
		c, err := net.DialTimeout("tcp", "1.1.1.1:443", 3*time.Second)
		if err != nil {
			continue
		}
		c.Close()
		if d := time.Since(t); !reached || d < best {
			best, reached = d, true
		}
	}
	if reached {
		ms := int(best.Milliseconds())
		word := "excellent"
		if ms >= 100 {
			word = "slow"
		} else if ms >= 50 {
			word = "okay"
		}
		u.Row("Internet", u.Level(ms, 50, 100)(fmt.Sprintf("✓ %d ms, %s", ms, word)))
	} else {
		u.Row("Internet", u.Red("✗ could not reach the internet"))
		ok = false
	}
	if err == nil {
		t := time.Now()
		c, derr := net.DialTimeout("tcp", net.JoinHostPort(target, "443"), 4*time.Second)
		if derr == nil {
			c.Close()
			u.Row(target, u.Green(fmt.Sprintf("✓ reachable in %d ms", time.Since(t).Milliseconds())))
		} else {
			u.Row(target, u.Red("✗ does not answer on port 443"))
			ok = false
		}
	}
	u.Blank()
	if !ok {
		return ExitIssues
	}
	return ExitOK
}

func localIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, addr := range addrs {
		if n, ok := addr.(*net.IPNet); ok && n.IP.To4() != nil && n.IP.IsPrivate() {
			return n.IP.String()
		}
	}
	return ""
}

// protectedProcs must never be stopped from here, whatever port they hold.
var protectedProcs = map[string]bool{"launchd": true, "loginwindow": true, "systemd": true, "sshd": true, "ControlCenter": true, "Finder": true, "Dock": true, "init": true, "tailscaled": true, "mDNSResponder": true, "rapportd": true}

func cmdPorts(a *App, args []string) int {
	fs := a.flags("ports", "[kill PORT] [--yes] [--json]")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	if fs.NArg() >= 1 && fs.Arg(0) == "kill" {
		if fs.NArg() != 2 {
			fs.Usage()
			return ExitUsage
		}
		port, err := strconv.Atoi(fs.Arg(1))
		if err != nil || port < 1 || port > 65535 {
			a.U.Stop(fs.Arg(1) + " is not a port number.")
			return ExitUsage
		}
		return a.killPort(port)
	}
	list := a.E.Listeners()
	if *asJSON {
		if list == nil {
			list = []host.Listener{}
		}
		return emit(a, list)
	}
	u := a.U
	u.Hdr("What is listening")
	if len(list) == 0 {
		u.Say("  " + u.Dim("Nothing that this user can see."))
		u.Blank()
		return ExitOK
	}
	for _, l := range list {
		name := l.Command
		if name == "" {
			name = u.Dim("(another user's)")
		}
		scope := "this machine only"
		if l.Address == "*" || l.Address == "0.0.0.0" || l.Address == "[::]" {
			scope = u.Yellow("your whole network")
		}
		u.Say(fmt.Sprintf("  %s  %-22s %s", u.Cyan(fmt.Sprintf("%-6d", l.Port)), ui.Fit(name, 22), u.Dim(scope)))
	}
	u.Blank()
	u.Say("  " + u.Dim("Stop one safely: catalyst ports kill PORT"))
	u.Blank()
	return ExitOK
}

// killPort stops only the process listening on the port, never anything merely connected to it. The old app killed both,
// which could take your browser down with it. TERM first, and KILL only after asking.
func (a *App) killPort(port int) int {
	u := a.U
	find := func() *host.Listener {
		for _, l := range a.E.Listeners() {
			if l.Port == port && l.PID > 0 {
				return &l
			}
		}
		return nil
	}
	l := find()
	if l == nil {
		u.Say("  Nothing you can stop is listening on port " + strconv.Itoa(port) + ".")
		return ExitOK
	}
	if protectedProcs[l.Command] {
		u.Stop(fmt.Sprintf("%s is part of the system, so it stays running.", l.Command))
		return ExitIssues
	}
	if l.PID == os.Getpid() {
		u.Stop("That is Catalyst itself.")
		return ExitIssues
	}
	u.Blank()
	u.Say(fmt.Sprintf("  Port %d is held by %s %s", port, u.Bold(l.Command), u.Dim(fmt.Sprintf("(process %d)", l.PID))))
	if dir := a.E.Folder(l.PID); dir != "" {
		u.Hint("running in " + a.E.Tilde(dir))
	}
	if !u.Ask("Stop it?") {
		return ExitOK
	}
	batch := journal.NewBatch(a.E.Now())
	proc, err := os.FindProcess(l.PID)
	if err == nil {
		err = proc.Signal(syscall.SIGTERM)
	}
	if err != nil {
		u.Stop("Could not stop it: " + err.Error())
		return ExitIssues
	}
	a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: fmt.Sprintf("Stopped %s on port %d", l.Command, port), Command: []string{"kill", "-TERM", strconv.Itoa(l.PID)}})
	for i := 0; i < 25; i++ {
		time.Sleep(200 * time.Millisecond)
		if now := find(); now == nil || now.PID != l.PID {
			u.Ok(fmt.Sprintf("Stopped %s. Port %d is free.", l.Command, port))
			return ExitOK
		}
	}
	u.Warn(fmt.Sprintf("%s did not stop when asked.", l.Command))
	if !u.Ask("Force it? It will not get a chance to save anything") {
		return ExitIssues
	}
	// Check again that it is still the same process holding the port: process numbers get reused.
	if now := find(); now == nil || now.PID != l.PID {
		u.Ok(fmt.Sprintf("It stopped by itself. Port %d is free.", port))
		return ExitOK
	}
	if err := proc.Signal(syscall.SIGKILL); err != nil {
		u.Stop("Could not force it: " + err.Error())
		return ExitIssues
	}
	a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: fmt.Sprintf("Forced %s on port %d to stop", l.Command, port), Command: []string{"kill", "-KILL", strconv.Itoa(l.PID)}})
	u.Ok(fmt.Sprintf("Port %d is free.", port))
	return ExitOK
}

func cmdStartup(a *App, args []string) int {
	fs := a.flags("startup", "[disable NAME | enable NAME] [--json] [--yes]")
	asJSON := fs.Bool("json", false, "")
	yes := fs.Bool("yes", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	a.U.Yes = a.U.Yes || *yes
	u := a.U
	items := a.E.StartupItems()
	if fs.NArg() >= 1 {
		if fs.NArg() != 2 || (fs.Arg(0) != "disable" && fs.Arg(0) != "enable") {
			fs.Usage()
			return ExitUsage
		}
		return a.toggleStartup(items, fs.Arg(0), fs.Arg(1))
	}
	if *asJSON {
		if items == nil {
			items = []host.StartupItem{}
		}
		return emit(a, items)
	}
	u.Hdr("What starts by itself")
	if len(items) == 0 {
		u.Say("  " + u.Dim("Nothing found."))
	}
	group := ""
	for _, it := range items {
		if it.Kind != group {
			group = it.Kind
			u.Blank()
			u.Say("  " + u.Bold(group+"s"))
		}
		mark := u.Dim("-")
		if it.Loaded {
			mark = u.Green("●")
		}
		if it.Broken {
			mark = u.Red("✗")
		}
		line := "  " + mark + " " + ui.Fit(it.Name, u.Width()-6)
		if it.Broken {
			line += u.Red("  its program is gone")
		}
		u.Say(line)
	}
	if a.E.Mac() {
		u.Blank()
		u.Say("  " + u.Dim("Apps you added under Login Items are in System Settings, General, Login Items."))
	}
	u.Blank()
	return ExitOK
}

func (a *App) toggleStartup(items []host.StartupItem, action, name string) int {
	u := a.U
	var it *host.StartupItem
	for i := range items {
		if items[i].Name == name {
			it = &items[i]
		}
	}
	if it == nil {
		u.Stop("Nothing called " + name + " starts by itself here.")
		return ExitUsage
	}
	if !it.Mine {
		u.Stop(name + " belongs to the system, so changing it needs root.")
		if a.E.Mac() {
			u.Hint("sudo launchctl " + action + " system/" + name)
		} else {
			u.Hint("sudo systemctl " + action + " " + name)
		}
		return ExitIssues
	}
	var cmds [][]string
	switch {
	case a.E.Mac():
		target := "gui/" + strconv.Itoa(os.Getuid()) + "/" + name
		cmds = append(cmds, []string{"launchctl", action, target})
		if action == "disable" {
			cmds = append(cmds, []string{"launchctl", "bootout", target})
		}
	case it.Kind == "User service":
		cmds = append(cmds, []string{"systemctl", "--user", action, "--now", name})
	default:
		u.Stop("Change this one by hand: " + it.Kind + " items are not managed here.")
		return ExitIssues
	}
	for _, c := range cmds {
		u.Hint(strings.Join(c, " "))
	}
	if !u.Ask(strings.ToUpper(action[:1]) + action[1:] + " " + name + "?") {
		return ExitOK
	}
	batch := journal.NewBatch(a.E.Now())
	for _, c := range cmds {
		r := a.E.Run.Run(0, c[0], c[1:]...)
		// bootout reports failure when the item was not running, and that is fine: the goal is that it is stopped.
		if !r.OK() && c[1] != "bootout" {
			u.Stop(strings.TrimSpace(r.Stderr))
			return ExitIssues
		}
		a.Journal.Add(journal.Entry{Time: a.E.Now(), Batch: batch, Kind: journal.KindRun, Title: action + " " + name, Command: c})
	}
	u.Ok(strings.ToUpper(action[:1]) + action[1:] + "d " + name)
	return ExitOK
}

func cmdSSH(a *App, args []string) int {
	fs := a.flags("ssh", "[--json]")
	asJSON := fs.Bool("json", false, "")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	keys := a.E.SSHKeys()
	if *asJSON {
		if keys == nil {
			keys = []host.SSHKey{}
		}
		return emit(a, keys)
	}
	u.Hdr("SSH keys")
	dir := a.E.Path(".ssh")
	st, err := os.Stat(dir)
	if err != nil {
		u.Say("  " + u.Dim("No ~/.ssh on this machine. Make a key with: ssh-keygen -t ed25519"))
		u.Blank()
		return ExitOK
	}
	code := ExitOK
	if st.Mode().Perm()&0o077 != 0 {
		u.Warn(fmt.Sprintf("~/.ssh can be read by other users (%o). Fix: catalyst doctor --fix", st.Mode().Perm()))
		code = ExitIssues
	}
	if len(keys) == 0 {
		u.Say("  " + u.Dim("No keys in ~/.ssh."))
	}
	for _, k := range keys {
		detail := strings.TrimSpace(fmt.Sprintf("%s %d", k.Type, k.Bits))
		safe := true
		if k.Private != "" && k.Mode&0o077 != 0 {
			safe = false
			u.Stop(fmt.Sprintf("%s  %s  other users can read it (%o)", k.Name, u.Dim(detail), k.Mode))
			code = ExitIssues
		} else if k.Weak {
			safe = false
			u.Warn(fmt.Sprintf("%s  %s  weak, make a new one", k.Name, u.Dim(detail)))
			code = ExitIssues
		}
		if safe {
			kind := ""
			if k.Private == "" {
				kind = u.Dim("  public half only")
			}
			u.Ok(k.Name + "  " + u.Dim(detail) + kind)
		}
		if k.Fingerprint != "" {
			u.Hint(k.Fingerprint)
		}
	}
	u.Blank()
	return code
}

func cmdPath(a *App, args []string) int {
	fs := a.flags("path", "[add | remove | status]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	action := fs.Arg(0)
	self, _ := os.Executable()
	a.E.LoadShell()
	st := shellpath.Check(a.E.Home, a.E.Shell, a.E.OS, os.Getenv("ZDOTDIR"), a.E.Entries, self, a.E.Look)
	switch action {
	case "status":
		fmt.Fprintf(u.Out, "%s %s\n", st.State, a.E.Tilde(st.RC))
		return ExitOK
	case "add":
		switch st.State {
		case "ready":
			u.Ok("The catalyst command is already in your terminal.")
		case "clash":
			u.Warn("Something else called catalyst comes first on your PATH: " + st.Found)
			u.Hint("It was left alone. Run this copy with its full path: " + self)
			return ExitIssues
		default:
			if err := shellpath.Add(st.RC); err != nil {
				u.Stop("Could not write to " + a.E.Tilde(st.RC) + ": " + err.Error())
				return ExitIssues
			}
			u.Ok("Added one line to " + a.E.Tilde(st.RC) + ". It works in new terminals.")
		}
		return ExitOK
	case "remove":
		changed := false
		for _, rc := range []string{shellpath.RCFile(a.E.Home, "zsh", a.E.OS, os.Getenv("ZDOTDIR")), shellpath.RCFile(a.E.Home, "bash", a.E.OS, ""), shellpath.RCFile(a.E.Home, "fish", a.E.OS, ""), shellpath.RCFile(a.E.Home, "", a.E.OS, "")} {
			if did, _ := shellpath.Remove(rc); did {
				u.Ok("Removed the line from " + a.E.Tilde(rc))
				changed = true
			}
		}
		if !changed {
			u.Say("  " + u.Dim("There was no Catalyst line to remove."))
		}
		return ExitOK
	case "":
	default:
		fs.Usage()
		return ExitUsage
	}
	return a.showPath()
}

func (a *App) showPath() int {
	u := a.U
	u.Hdr("Your PATH, in the order it is searched")
	seen := map[string]bool{}
	dead, dupes := 0, 0
	for i, p := range a.E.Entries {
		clean := filepath.Clean(p)
		st, err := os.Stat(p)
		mark := u.Green("✓")
		note := ""
		switch {
		case seen[clean]:
			mark, note = u.Yellow("!"), u.Yellow("  listed twice")
			dupes++
		case err != nil || !st.IsDir():
			mark, note = u.Yellow("!"), u.Yellow("  does not exist")
			dead++
		}
		seen[clean] = true
		src := a.pathSource(p)
		if src != "" && note != "" {
			note += u.Dim("  added in " + src)
		}
		u.Say(fmt.Sprintf("  %s %s %s%s", u.Dim(fmt.Sprintf("%2d", i+1)), mark, a.E.Tilde(p), note))
	}
	u.Sect("Tools hidden by an earlier folder")
	shadows := a.shadows()
	if len(shadows) == 0 {
		u.Ok("Nothing is hidden")
	}
	for i, s := range shadows {
		if i == 12 {
			u.Hint(fmt.Sprintf("and %d more", len(shadows)-12))
			break
		}
		u.Say("  " + u.Bold(s.tool) + " runs from " + a.E.Tilde(s.winner) + u.Dim(", hiding "+a.E.Tilde(s.hidden)))
	}
	u.Blank()
	if dead+dupes > 0 {
		return ExitIssues
	}
	return ExitOK
}

// pathSource finds which startup file names a folder, so a dead entry can actually be fixed.
func (a *App) pathSource(dir string) string {
	short := strings.Replace(dir, a.E.Home, "$HOME", 1)
	tilde := a.E.Tilde(dir)
	for _, rc := range a.E.RCFiles() {
		b, err := os.ReadFile(rc)
		if err != nil {
			continue
		}
		text := string(b)
		for _, needle := range []string{dir, short, tilde} {
			if strings.Contains(text, needle) {
				return a.E.Tilde(rc)
			}
		}
	}
	return ""
}

type shadow struct{ tool, winner, hidden string }

// notableTools are the commands where running the wrong copy causes real confusion. Comparing all of them would mostly list harmless system duplicates.
var notableTools = []string{"python", "python3", "pip", "pip3", "node", "npm", "npx", "ruby", "gem", "java", "javac", "go", "cargo", "rustc", "git", "make", "gcc", "clang", "php", "perl", "docker", "kubectl", "terraform", "brew", "code"}

func (a *App) shadows() []shadow {
	first := map[string]string{}
	var out []shadow
	for _, p := range a.E.Entries {
		for _, t := range notableTools {
			full := filepath.Join(p, t)
			st, err := os.Stat(full)
			if err != nil || st.IsDir() || st.Mode()&0o111 == 0 {
				continue
			}
			w, ok := first[t]
			if !ok {
				first[t] = full
				continue
			}
			ra, _ := filepath.EvalSymlinks(w)
			rb, _ := filepath.EvalSymlinks(full)
			if ra != rb {
				out = append(out, shadow{t, w, full})
			}
		}
	}
	return out
}

func cmdConfig(a *App, args []string) int {
	fs := a.flags("config", "[set mascot on|off]")
	if code, ok := a.parse(fs, args); !ok {
		return code
	}
	u := a.U
	c := a.Store.LoadConfig()
	if fs.NArg() == 0 {
		u.Hdr("Settings")
		v := "on"
		if !c.MascotOn() {
			v = "off"
		}
		u.Row("mascot", v)
		u.Row("files", a.E.Tilde(a.Store.ConfigDir))
		u.Row("history", a.E.Tilde(a.Store.Dir))
		u.Blank()
		return ExitOK
	}
	if fs.NArg() != 3 || fs.Arg(0) != "set" || fs.Arg(1) != "mascot" || (fs.Arg(2) != "on" && fs.Arg(2) != "off") {
		fs.Usage()
		return ExitUsage
	}
	on := fs.Arg(2) == "on"
	c.Mascot = &on
	if err := a.Store.SaveConfig(c); err != nil {
		u.Stop(err.Error())
		return ExitFailed
	}
	u.Ok("Kit is " + fs.Arg(2) + ".")
	return ExitOK
}
